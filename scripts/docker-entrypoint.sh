#!/bin/bash
# =============================================================================
# PostgreSQL HA 容器启动入口脚本
# 功能：根据 NODE_ROLE 环境变量初始化 Primary 或 Standby 节点
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# 环境变量（由 docker-compose 注入）
# ---------------------------------------------------------------------------
NODE_ROLE=${NODE_ROLE:-"primary"}        # primary 或 standby
NODE_ID=${NODE_ID:-1}                     # repmgr 节点 ID
NODE_NAME=${NODE_NAME:-"pg-node1"}        # repmgr 节点名称
NODE_IP=${NODE_IP:-"192.168.1.11"}        # 本节点 IP
PARTNER_IP=${PARTNER_IP:-"192.168.1.12"}  # 对端节点 IP
NODE_VIP=${NODE_VIP:-"192.168.1.100"}     # 虚拟 IP
PGDATA=${PGDATA:-"/var/lib/postgresql/data"}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-"repmgr123"}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-"postgres123"}
export PGPORT=${PG_PORT:-5432}

echo "============================================="
echo " PostgreSQL HA 节点启动"
echo " 角色: ${NODE_ROLE}"
echo " 节点 ID: ${NODE_ID}"
echo " 节点名称: ${NODE_NAME}"
echo " 本机 IP: ${NODE_IP}"
echo " 对端 IP: ${PARTNER_IP}"
echo " 虚拟 IP: ${NODE_VIP}"
echo "============================================="

RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"

cat > "${RUNTIME_ENV_FILE}" <<EOF
NODE_NAME=${NODE_NAME}
NODE_IP=${NODE_IP}
PARTNER_IP=${PARTNER_IP}
NODE_VIP=${NODE_VIP}
WECOM_NOTIFY_ENABLED=${WECOM_NOTIFY_ENABLED:-false}
WECOM_WEBHOOK_URL=${WECOM_WEBHOOK_URL:-}
WECOM_NOTIFY_SITE_NAME=${WECOM_NOTIFY_SITE_NAME:-PostgreSQL HA 现场}
WECOM_NOTIFY_TIMEOUT=${WECOM_NOTIFY_TIMEOUT:-10}
WECOM_NOTIFY_AT_ALL_ON_FAILOVER=${WECOM_NOTIFY_AT_ALL_ON_FAILOVER:-false}
EOF
chmod 644 "${RUNTIME_ENV_FILE}"

# ---------------------------------------------------------------------------
# Keepalived 控制函数
# ---------------------------------------------------------------------------
start_keepalived() {
    if pgrep -x keepalived >/dev/null 2>&1; then
        KEEPALIVED_PID=$(pgrep -x keepalived | head -n 1)
        echo "[INFO] Keepalived 已在运行 (PID: ${KEEPALIVED_PID})"
        return 0
    fi

    echo "[INFO] 启动 Keepalived..."
    /usr/local/bin/keepalived-control.sh start
    KEEPALIVED_PID=$(cat /var/run/keepalived.pid 2>/dev/null || true)
    echo "[INFO] Keepalived 已启动 (PID: ${KEEPALIVED_PID:-unknown})"
}

stop_keepalived() {
    echo "[INFO] 停止 Keepalived..."
    /usr/local/bin/keepalived-control.sh stop || true
}

# ---------------------------------------------------------------------------
# 复制并动态替换配置文件中的 IP 地址
# ---------------------------------------------------------------------------
echo "[INFO] 复制 repmgr 配置文件..."
cp /etc/pg-ha/conf/repmgr-node${NODE_ID}.conf /etc/repmgr.conf
# 动态替换 conninfo 中的 IP 和端口
sed -i "s|host=192.168.1.1[0-9]*|host=${NODE_IP}|g" /etc/repmgr.conf
sed -i "s|connect_timeout=2|connect_timeout=2 port=${PGPORT}|g" /etc/repmgr.conf
chown postgres:postgres /etc/repmgr.conf

echo "[INFO] 复制 keepalived 配置文件..."
cp /etc/pg-ha/conf/keepalived-node${NODE_ID}.conf /etc/keepalived/keepalived.conf
# 动态替换 Keepalived 中的 IP
sed -i "s|unicast_src_ip 192.168.1.1[0-9]*|unicast_src_ip ${NODE_IP}|g" /etc/keepalived/keepalived.conf
sed -i "s|192.168.1.1[0-9]*$|${PARTNER_IP}|g" /etc/keepalived/keepalived.conf
sed -i "s|192.168.1.100|${NODE_VIP}|g" /etc/keepalived/keepalived.conf

# 自动推断真实的网卡名称并替换 Keepalived 配置中的 interface eth0
NODE_INTERFACE=$(ip -o addr show | grep -w "${NODE_IP}" | awk '{print $2}' | head -n 1)
if [ -z "${NODE_INTERFACE}" ]; then
    NODE_INTERFACE="eth0"
    echo "[WARN] 无法自动推断 ${NODE_IP} 的网卡名称，默认回退使用 ${NODE_INTERFACE}"
else
    echo "[INFO] 自动推断 ${NODE_IP} 所在网卡为: ${NODE_INTERFACE}"
fi
sed -i "s|interface eth0|interface ${NODE_INTERFACE}|g" /etc/keepalived/keepalived.conf

# ---------------------------------------------------------------------------
# 确保日志目录存在
# ---------------------------------------------------------------------------
mkdir -p /var/log/repmgr
chown postgres:postgres /var/log/repmgr

# ---------------------------------------------------------------------------
# 根据角色执行初始化
# ---------------------------------------------------------------------------
if [ "${NODE_ROLE}" = "primary" ]; then
    echo "[INFO] 以 Primary 角色启动..."
    /usr/local/bin/setup-primary.sh
elif [ "${NODE_ROLE}" = "standby" ]; then
    echo "[INFO] 以 Standby 角色启动..."
    /usr/local/bin/setup-standby.sh
else
    echo "[ERROR] 未知的 NODE_ROLE: ${NODE_ROLE}，必须为 primary 或 standby"
    exit 1
fi

# ---------------------------------------------------------------------------
# 仅 Primary 启动 Keepalived，避免 VIP 先于数据库角色漂移
# ---------------------------------------------------------------------------
if su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null | grep -q '^f$'; then
    start_keepalived
else
    echo "[INFO] 当前节点不是 Primary，跳过 Keepalived 启动"
fi

# ---------------------------------------------------------------------------
# 信号处理 - 优雅关闭
# ---------------------------------------------------------------------------
cleanup() {
    echo "[INFO] 收到停止信号，开始优雅关闭..."

    # 停止 Keepalived
    stop_keepalived

    # 停止 repmgrd
    echo "[INFO] 停止 repmgrd..."
    su - postgres -c "kill \$(cat /tmp/repmgrd.pid 2>/dev/null) 2>/dev/null" || true

    # 停止 PostgreSQL
    echo "[INFO] 停止 PostgreSQL..."
    su - postgres -c "pg_ctl -D ${PGDATA} stop -m fast" || true

    echo "[INFO] 所有服务已停止"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ---------------------------------------------------------------------------
# 前台等待（保持容器运行）
# ---------------------------------------------------------------------------
echo "[INFO] 所有服务已启动，等待信号..."
echo "============================================="
echo " PostgreSQL HA 节点就绪"
echo " 角色: ${NODE_ROLE}"
echo " PG 端口: ${PGPORT}"
echo "============================================="

# 持续监控子进程，任一退出则重启
while true; do
    # 检查 PostgreSQL 是否存活
    if ! su - postgres -c "pg_isready -q" 2>/dev/null; then
        echo "[WARN] PostgreSQL 进程异常，等待恢复..."
    fi
    sleep 5
done
