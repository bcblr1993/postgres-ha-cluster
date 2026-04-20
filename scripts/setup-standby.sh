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
            echo "[STANDBY] 数据目录有效且已为 Standby 模式，跳过克隆"
            # 直接跳到注册步骤
            goto_register=true
        else
            echo "[STANDBY] 数据目录存在但非 Standby 模式，停止并重新克隆..."
            su - postgres -c "pg_ctl -D ${PGDATA} stop -m fast" 2>/dev/null || true
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
echo "[STANDBY] 启动 repmgrd 守护进程..."
su - postgres -c "repmgrd -f /etc/repmgr.conf --pid-file=/tmp/repmgrd.pid --daemonize"
echo "[STANDBY] repmgrd 已启动"

echo "[STANDBY] Standby 节点初始化完成！"
