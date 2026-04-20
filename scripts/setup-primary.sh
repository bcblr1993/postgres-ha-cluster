#!/bin/bash
# =============================================================================
# Primary 节点初始化脚本
# 功能：初始化 PG 数据目录、创建 repmgr 用户/库、注册 Primary 节点
# =============================================================================
set -e

PGDATA=${PGDATA:-"/var/lib/postgresql/data"}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-"repmgr123"}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-"postgres123"}
POSTGRES_DB=${POSTGRES_DB:-""}
PARTNER_IP=${PARTNER_IP:-"192.168.1.12"}

echo "[PRIMARY] 开始 Primary 节点初始化..."

partner_is_primary() {
    PGPASSWORD="${REPMGR_PASSWORD}" psql \
        "host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=2" \
        -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null | grep -q '^t$'
}

if partner_is_primary; then
    echo "[PRIMARY][WARN] 检测到对端 ${PARTNER_IP} 已是 Primary，当前节点将自动作为 Standby 重新加入集群"
    exec /usr/local/bin/setup-standby.sh
fi

# ---------------------------------------------------------------------------
# 步骤 0：修复数据目录权限（兼容 Bind Mount 模式）
# ---------------------------------------------------------------------------
echo "[PRIMARY] 检查数据目录权限..."
chown -R postgres:postgres ${PGDATA}
chmod 700 ${PGDATA}

# ---------------------------------------------------------------------------
# 步骤 1：初始化 PostgreSQL 数据目录（如果为空）
# ---------------------------------------------------------------------------
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    echo "[PRIMARY] 数据目录为空，执行 initdb..."
    su - postgres -c "initdb -D ${PGDATA} --encoding=UTF8 --locale=C"

    # 应用自定义配置
    echo "[PRIMARY] 应用 postgresql.conf..."
    cp /etc/pg-ha/conf/postgresql.conf ${PGDATA}/postgresql.conf
    cp /etc/pg-ha/conf/pg_hba.conf ${PGDATA}/pg_hba.conf
    sed -i "s/port = 5432/port = ${PGPORT:-5432}/g" ${PGDATA}/postgresql.conf
    chown postgres:postgres ${PGDATA}/postgresql.conf ${PGDATA}/pg_hba.conf
else
    echo "[PRIMARY] 数据目录已存在，跳过 initdb"
    # 仍然更新配置文件（确保配置一致性）
    cp /etc/pg-ha/conf/postgresql.conf ${PGDATA}/postgresql.conf
    cp /etc/pg-ha/conf/pg_hba.conf ${PGDATA}/pg_hba.conf
    sed -i "s/port = 5432/port = ${PGPORT:-5432}/g" ${PGDATA}/postgresql.conf
    chown postgres:postgres ${PGDATA}/postgresql.conf ${PGDATA}/pg_hba.conf
fi

# ---------------------------------------------------------------------------
# 步骤 2：启动 PostgreSQL
# ---------------------------------------------------------------------------
# 确保日志目录存在
mkdir -p ${PGDATA}/log && chown postgres:postgres ${PGDATA}/log
echo "[PRIMARY] 启动 PostgreSQL..."
su - postgres -c "pg_ctl -D ${PGDATA} -l ${PGDATA}/log/startup.log start -w"

# 等待 PG 就绪
echo "[PRIMARY] 等待 PostgreSQL 就绪..."
for i in $(seq 1 30); do
    if su - postgres -c "pg_isready -q"; then
        echo "[PRIMARY] PostgreSQL 已就绪"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "[PRIMARY][ERROR] PostgreSQL 启动超时"
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# 步骤 3：创建 repmgr 用户和数据库（幂等操作）
# ---------------------------------------------------------------------------
echo "[PRIMARY] 创建 repmgr 用户和数据库..."

# 创建 repmgr 超级用户（如果不存在）
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='repmgr'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE USER repmgr WITH SUPERUSER LOGIN PASSWORD '${REPMGR_PASSWORD}'\""

# 创建 repmgr 数据库（如果不存在）
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='repmgr'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE DATABASE repmgr OWNER repmgr\""

# 设置 postgres 用户密码
su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${POSTGRES_PASSWORD}'\""

# 创建初始业务数据库（如果配置了）
if [ -n "${POSTGRES_DB}" ]; then
    echo "[PRIMARY] 初始化业务数据库: ${POSTGRES_DB}"
    su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\"" | grep -q 1 || \
        su - postgres -c "psql -c \"CREATE DATABASE ${POSTGRES_DB} OWNER postgres\""
fi

echo "[PRIMARY] repmgr 用户和数据库创建完成"

# ---------------------------------------------------------------------------
# 步骤 4：注册 Primary 节点到 repmgr（幂等操作）
# ---------------------------------------------------------------------------
echo "[PRIMARY] 注册 Primary 节点..."
su - postgres -c "repmgr -f /etc/repmgr.conf primary register --force"
echo "[PRIMARY] Primary 节点注册完成"

# 查看集群状态
su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"

# ---------------------------------------------------------------------------
# 步骤 5：启动 repmgrd 守护进程
# ---------------------------------------------------------------------------
echo "[PRIMARY] 启动 repmgrd 守护进程..."
su - postgres -c "repmgrd -f /etc/repmgr.conf --pid-file=/tmp/repmgrd.pid --daemonize"
echo "[PRIMARY] repmgrd 已启动"

echo "[PRIMARY] Primary 节点初始化完成！"
