#!/bin/bash
# =============================================================================
# Standby 节点初始化脚本
# 功能：等待 Primary、从 Primary 克隆数据、注册 Standby 节点
# =============================================================================
set -e

PGDATA=${PGDATA:-"/var/lib/postgresql/data"}
PARTNER_IP=${PARTNER_IP:-"192.168.1.11"}
MAX_WAIT=${MAX_WAIT:-120}

echo "[STANDBY] 开始 Standby 节点初始化..."

# ---------------------------------------------------------------------------
# 步骤 1：等待 Primary 节点可达
# ---------------------------------------------------------------------------
echo "[STANDBY] 等待 Primary 节点 (${PARTNER_IP}) 就绪..."
for i in $(seq 1 ${MAX_WAIT}); do
    if pg_isready -h ${PARTNER_IP} -p ${PGPORT:-5432} -U repmgr -q 2>/dev/null; then
        echo "[STANDBY] Primary 节点已就绪 (等待了 ${i} 秒)"
        break
    fi
    if [ $i -eq ${MAX_WAIT} ]; then
        echo "[STANDBY][ERROR] 等待 Primary 节点超时 (${MAX_WAIT}秒)"
        exit 1
    fi
    echo "[STANDBY] 等待 Primary... (${i}/${MAX_WAIT})"
    sleep 1
done

# 额外等待几秒确保 Primary 完全就绪（repmgr 已注册）
sleep 3

# ---------------------------------------------------------------------------
# 步骤 1.5：修复数据目录权限（兼容 Bind Mount 模式）
# ---------------------------------------------------------------------------
echo "[STANDBY] 检查数据目录权限..."
chown -R postgres:postgres ${PGDATA}
chmod 700 ${PGDATA}

# ---------------------------------------------------------------------------
# 步骤 2：从 Primary 克隆数据
# ---------------------------------------------------------------------------
# 如果数据目录已存在且有效，检查是否需要重新克隆
if [ -s "${PGDATA}/PG_VERSION" ]; then
    echo "[STANDBY] 数据目录已存在，检查复制状态..."

    # 尝试启动并检查是否能正常连接到 Primary
    su - postgres -c "pg_ctl -D ${PGDATA} start -w -t 10" 2>/dev/null || true

    if su - postgres -c "pg_isready -q" 2>/dev/null; then
        # PG 可启动，检查是否为 Standby
        IS_STANDBY=$(su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null || echo "error")
        if [ "${IS_STANDBY}" = "t" ]; then
            echo "[STANDBY] 数据目录已为 Standby 模式，验证 WAL streaming 是否正常..."
            # 等待最多 5 秒确认 WAL streaming 已建立
            # 若无法建立说明时间线不兼容（曾为 Primary 的崩溃恢复误判），需走 pg_rewind
            STREAMING=""
            for _i in $(seq 1 5); do
                STREAMING=$(su - postgres -c \
                    "psql -tAc 'SELECT status FROM pg_stat_wal_receiver' 2>/dev/null" 2>/dev/null)
                [ "${STREAMING}" = "streaming" ] && break
                sleep 1
            done

            if [ "${STREAMING}" = "streaming" ]; then
                echo "[STANDBY] WAL streaming 正常，跳过克隆直接注册"
                goto_register=true
            else
                echo "[STANDBY] WAL streaming 未能建立（时间线可能不兼容），停止并走 pg_rewind..."
                su - postgres -c "pg_ctl -D ${PGDATA} stop -m fast" 2>/dev/null || true
            fi
        else
            echo "[STANDBY] 数据目录存在但非 Standby 模式（旧主节点），尝试 pg_rewind 增量同步..."
            su - postgres -c "pg_ctl -D ${PGDATA} stop -m fast" 2>/dev/null || true

            # repmgr node rejoin 内部调用 pg_rewind 回退时间线分叉，只传输差异 WAL
            # 比全量 pg_basebackup 克隆快数倍（大库尤为明显）
            # --force-rewind：授权调用 pg_rewind；需要 wal_log_hints=on（已配置）
            if su - postgres -c "repmgr node rejoin -f /etc/repmgr.conf \
                -d 'host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=5' \
                --force-rewind --verbose"; then
                echo "[STANDBY] pg_rewind 增量同步成功，跳过全量克隆"
                # 确保自定义配置与模板一致，热重载生效
                cp /etc/pg-ha/conf/postgresql.conf ${PGDATA}/postgresql.conf
                cp /etc/pg-ha/conf/pg_hba.conf ${PGDATA}/pg_hba.conf
                sed -i "s/port = 5432/port = ${PGPORT:-5432}/g" ${PGDATA}/postgresql.conf
                chown postgres:postgres ${PGDATA}/postgresql.conf ${PGDATA}/pg_hba.conf
                su - postgres -c "pg_ctl -D ${PGDATA} reload" 2>/dev/null || true
                goto_register=true
            else
                echo "[STANDBY] pg_rewind 失败，降级为全量克隆..."
            fi
        fi
    else
        echo "[STANDBY] 数据目录存在但无法启动，将重新克隆..."
        su - postgres -c "pg_ctl -D ${PGDATA} stop -m fast" 2>/dev/null || true
    fi
fi

if [ "${goto_register}" != "true" ]; then
    echo "[STANDBY] 从 Primary (${PARTNER_IP}) 克隆数据..."

    # 清空数据目录（repmgr standby clone 需要空目录或使用 --force）
    if [ -d "${PGDATA}" ]; then
        rm -rf ${PGDATA}/*
    fi

    su - postgres -c "repmgr -h ${PARTNER_IP} -U repmgr -d repmgr -f /etc/repmgr.conf standby clone --force"
    echo "[STANDBY] 数据克隆完成"

    # 应用自定义配置（克隆后覆盖，确保一致性）
    cp /etc/pg-ha/conf/postgresql.conf ${PGDATA}/postgresql.conf
    cp /etc/pg-ha/conf/pg_hba.conf ${PGDATA}/pg_hba.conf
    sed -i "s/port = 5432/port = ${PGPORT:-5432}/g" ${PGDATA}/postgresql.conf
    chown postgres:postgres ${PGDATA}/postgresql.conf ${PGDATA}/pg_hba.conf

    # ---------------------------------------------------------------------------
    # 步骤 3：启动 Standby PostgreSQL
    # ---------------------------------------------------------------------------
    echo "[STANDBY] 启动 PostgreSQL..."
    mkdir -p ${PGDATA}/log && chown postgres:postgres ${PGDATA}/log
    su - postgres -c "pg_ctl -D ${PGDATA} -l ${PGDATA}/log/startup.log start -w"

    # 等待 PG 就绪
    for i in $(seq 1 30); do
        if su - postgres -c "pg_isready -q"; then
            echo "[STANDBY] PostgreSQL 已就绪"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "[STANDBY][ERROR] PostgreSQL 启动超时"
            exit 1
        fi
        sleep 1
    done
fi

# ---------------------------------------------------------------------------
# 步骤 4：注册 Standby 节点到 repmgr
# ---------------------------------------------------------------------------
echo "[STANDBY] 注册 Standby 节点..."
su - postgres -c "repmgr -f /etc/repmgr.conf standby register --force"
echo "[STANDBY] Standby 节点注册完成"

# 查看集群状态
su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"

# ---------------------------------------------------------------------------
# 步骤 5：启动 repmgrd 守护进程
# ---------------------------------------------------------------------------
# 清理残留 PID 文件：kill -9 / docker kill 等非正常关闭不会触发 SIGTERM 处理器，
# 导致 /tmp/repmgrd.pid 遗留，下次启动时 repmgrd 误判为已运行而拒绝启动
if [ -f /tmp/repmgrd.pid ]; then
    OLD_PID=$(cat /tmp/repmgrd.pid 2>/dev/null || true)
    if [ -n "${OLD_PID}" ] && kill -0 "${OLD_PID}" 2>/dev/null; then
        echo "[STANDBY] repmgrd 已在运行 (PID=${OLD_PID})，跳过启动"
    else
        echo "[STANDBY] 清理残留 repmgrd PID 文件 (PID=${OLD_PID} 进程已不存在)..."
        rm -f /tmp/repmgrd.pid
    fi
fi
echo "[STANDBY] 启动 repmgrd 守护进程..."
su - postgres -c "repmgrd -f /etc/repmgr.conf --pid-file=/tmp/repmgrd.pid --daemonize"
echo "[STANDBY] repmgrd 已启动"

echo "[STANDBY] Standby 节点初始化完成！"
