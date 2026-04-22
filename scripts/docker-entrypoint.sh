#!/bin/bash
# =============================================================================
# PostgreSQL HA 容器启动入口脚本
# 功能：根据 NODE_ROLE 环境变量初始化 Primary 或 Standby 节点
# =============================================================================
set -e

. /usr/local/bin/ha-log.sh

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
WAL_ARCHIVE_ENABLED=${WAL_ARCHIVE_ENABLED:-"true"}
WAL_ARCHIVE_DIR=${WAL_ARCHIVE_DIR:-"/var/lib/postgresql/wal-archive"}
WAL_RECEIVER_ENABLED=${WAL_RECEIVER_ENABLED:-"true"}
HA_LOG_MAX_SIZE_MB=${HA_LOG_MAX_SIZE_MB:-20}
HA_LOG_KEEP_FILES=${HA_LOG_KEEP_FILES:-5}
HA_PG_LOG_KEEP_FILES=${HA_PG_LOG_KEEP_FILES:-10}
HA_LOG_SWEEP_INTERVAL_SECS=${HA_LOG_SWEEP_INTERVAL_SECS:-60}
RUN_ID="entrypoint-$(date +%s)-$$-${NODE_NAME}"
ha_log_init "docker-entrypoint" "${RUN_ID}"
SCRIPT_START_TS=$(date +%s)

echo "============================================="
echo " PostgreSQL HA 节点启动"
echo " 角色: ${NODE_ROLE}"
echo " 节点 ID: ${NODE_ID}"
echo " 节点名称: ${NODE_NAME}"
echo " 本机 IP: ${NODE_IP}"
echo " 对端 IP: ${PARTNER_IP}"
echo " 虚拟 IP: ${NODE_VIP}"
echo " WAL 归档: ${WAL_ARCHIVE_ENABLED}"
echo " WAL 目录: ${WAL_ARCHIVE_DIR}"
echo " WAL 接收: ${WAL_RECEIVER_ENABLED}"
echo " 日志轮转: ${HA_LOG_MAX_SIZE_MB}MB/${HA_LOG_KEEP_FILES}份"
echo "============================================="
ha_log_section "容器入口启动 role=${NODE_ROLE} node_id=${NODE_ID} node_name=${NODE_NAME} node_ip=${NODE_IP} partner_ip=${PARTNER_IP} vip=${NODE_VIP} pgport=${PGPORT} wal_archive_enabled=${WAL_ARCHIVE_ENABLED} wal_archive_dir=${WAL_ARCHIVE_DIR} wal_receiver_enabled=${WAL_RECEIVER_ENABLED} ha_log_max_size_mb=${HA_LOG_MAX_SIZE_MB} ha_log_keep_files=${HA_LOG_KEEP_FILES} ha_pg_log_keep_files=${HA_PG_LOG_KEEP_FILES} ha_log_sweep_interval_secs=${HA_LOG_SWEEP_INTERVAL_SECS}"

RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"

write_runtime_env() {
    {
        printf 'NODE_NAME=%q\n' "${NODE_NAME}"
        printf 'NODE_IP=%q\n' "${NODE_IP}"
        printf 'PARTNER_IP=%q\n' "${PARTNER_IP}"
        printf 'NODE_VIP=%q\n' "${NODE_VIP}"
        printf 'PGPORT=%q\n' "${PGPORT}"
        printf 'WECOM_NOTIFY_ENABLED=%q\n' "${WECOM_NOTIFY_ENABLED:-false}"
        printf 'WECOM_WEBHOOK_URL=%q\n' "${WECOM_WEBHOOK_URL:-}"
        printf 'WECOM_NOTIFY_SITE_NAME=%q\n' "${WECOM_NOTIFY_SITE_NAME:-PostgreSQL HA 现场}"
        printf 'WECOM_NOTIFY_TIMEOUT=%q\n' "${WECOM_NOTIFY_TIMEOUT:-10}"
        printf 'WECOM_NOTIFY_AT_ALL_ON_FAILOVER=%q\n' "${WECOM_NOTIFY_AT_ALL_ON_FAILOVER:-false}"
        printf 'REPMGR_PASSWORD=%q\n' "${REPMGR_PASSWORD}"
        printf 'WAL_ARCHIVE_ENABLED=%q\n' "${WAL_ARCHIVE_ENABLED}"
        printf 'WAL_ARCHIVE_DIR=%q\n' "${WAL_ARCHIVE_DIR}"
        printf 'WAL_RECEIVER_ENABLED=%q\n' "${WAL_RECEIVER_ENABLED}"
        printf 'HA_LOG_MAX_SIZE_MB=%q\n' "${HA_LOG_MAX_SIZE_MB}"
        printf 'HA_LOG_KEEP_FILES=%q\n' "${HA_LOG_KEEP_FILES}"
        printf 'HA_PG_LOG_KEEP_FILES=%q\n' "${HA_PG_LOG_KEEP_FILES}"
        printf 'HA_LOG_SWEEP_INTERVAL_SECS=%q\n' "${HA_LOG_SWEEP_INTERVAL_SECS}"
    } > "${RUNTIME_ENV_FILE}"
}

write_runtime_env
chmod 644 "${RUNTIME_ENV_FILE}"
ha_log_info "runtime_notify_env_written path=${RUNTIME_ENV_FILE}"

# ---------------------------------------------------------------------------
# Keepalived 控制函数
# ---------------------------------------------------------------------------
start_keepalived() {
    if pgrep -x keepalived >/dev/null 2>&1; then
        KEEPALIVED_PID=$(pgrep -x keepalived | head -n 1)
        ha_log_info "keepalived_already_running pid=${KEEPALIVED_PID}"
        return 0
    fi

    ha_log_info "keepalived_start_requested"
    /usr/local/bin/keepalived-control.sh start
    KEEPALIVED_PID=$(cat /var/run/keepalived.pid 2>/dev/null || true)
    ha_log_info "keepalived_started pid=${KEEPALIVED_PID:-unknown}"
}

stop_keepalived() {
    ha_log_info "keepalived_stop_requested"
    /usr/local/bin/keepalived-control.sh stop || true
}

# ---------------------------------------------------------------------------
# 复制并动态替换配置文件中的 IP 地址
# ---------------------------------------------------------------------------
ha_log_info "copy_repmgr_config source=/etc/pg-ha/conf/repmgr-node${NODE_ID}.conf target=/etc/repmgr.conf"
cp /etc/pg-ha/conf/repmgr-node${NODE_ID}.conf /etc/repmgr.conf
# 动态替换 conninfo 中的 IP 和端口
sed -i "s|host=192.168.1.1[0-9]*|host=${NODE_IP}|g" /etc/repmgr.conf
sed -i "s|connect_timeout=2|connect_timeout=2 port=${PGPORT}|g" /etc/repmgr.conf
chown postgres:postgres /etc/repmgr.conf
ha_log_info "repmgr_config_ready node_ip=${NODE_IP} pgport=${PGPORT}"

ha_log_info "copy_keepalived_config source=/etc/pg-ha/conf/keepalived-node${NODE_ID}.conf target=/etc/keepalived/keepalived.conf"
cp /etc/pg-ha/conf/keepalived-node${NODE_ID}.conf /etc/keepalived/keepalived.conf
# 动态替换 Keepalived 中的 IP
sed -i "s|unicast_src_ip 192.168.1.1[0-9]*|unicast_src_ip ${NODE_IP}|g" /etc/keepalived/keepalived.conf
sed -i "s|192.168.1.1[0-9]*$|${PARTNER_IP}|g" /etc/keepalived/keepalived.conf
sed -i "s|192.168.1.100|${NODE_VIP}|g" /etc/keepalived/keepalived.conf

# 自动推断真实的网卡名称并替换 Keepalived 配置中的 interface eth0
NODE_INTERFACE=$(ip -o addr show | grep -w "${NODE_IP}" | awk '{print $2}' | head -n 1)
if [ -z "${NODE_INTERFACE}" ]; then
    NODE_INTERFACE="eth0"
    ha_log_warn "interface_detect_failed node_ip=${NODE_IP} fallback=${NODE_INTERFACE}"
else
    ha_log_info "interface_detected node_ip=${NODE_IP} interface=${NODE_INTERFACE}"
fi
sed -i "s|interface eth0|interface ${NODE_INTERFACE}|g" /etc/keepalived/keepalived.conf
ha_log_info "keepalived_config_ready interface=${NODE_INTERFACE} partner_ip=${PARTNER_IP} vip=${NODE_VIP}"

# ---------------------------------------------------------------------------
# 确保日志目录存在
# ---------------------------------------------------------------------------
mkdir -p /var/log/repmgr
chown postgres:postgres /var/log/repmgr
ha_log_info "log_directory_ready path=/var/log/repmgr"

mkdir -p "${WAL_ARCHIVE_DIR}"
chown postgres:postgres "${WAL_ARCHIVE_DIR}"
chmod 700 "${WAL_ARCHIVE_DIR}"
ha_log_info "wal_archive_directory_ready path=${WAL_ARCHIVE_DIR} enabled=${WAL_ARCHIVE_ENABLED}"

# ---------------------------------------------------------------------------
# 根据角色执行初始化
# ---------------------------------------------------------------------------
if [ "${NODE_ROLE}" = "primary" ]; then
    ha_log_info "handoff_setup role=primary script=/usr/local/bin/setup-primary.sh"
    /usr/local/bin/setup-primary.sh
elif [ "${NODE_ROLE}" = "standby" ]; then
    ha_log_info "handoff_setup role=standby script=/usr/local/bin/setup-standby.sh"
    /usr/local/bin/setup-standby.sh
else
    ha_log_error "unknown_node_role value=${NODE_ROLE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 仅 Primary 启动 Keepalived，避免 VIP 先于数据库角色漂移
# ---------------------------------------------------------------------------
if su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null | grep -q '^f$'; then
    start_keepalived
else
    ha_log_info "skip_keepalived_start reason=node_not_primary"
fi

# ---------------------------------------------------------------------------
# 信号处理 - 优雅关闭
# ---------------------------------------------------------------------------
cleanup() {
    ha_log_warn "signal_received action=cleanup"

    # 停止 Keepalived
    stop_keepalived

    /usr/local/bin/wal-receiver-control.sh stop || true

    # 停止 repmgrd
    ha_log_info "repmgrd_stop_requested"
    su - postgres -c "kill \$(cat /tmp/repmgrd.pid 2>/dev/null) 2>/dev/null" || true

    # 停止 PostgreSQL
    ha_log_info "postgres_stop_requested pgdata=${PGDATA}"
    su - postgres -c "pg_ctl -D ${PGDATA} stop -m fast" || true

    ha_log_info "cleanup_complete total_elapsed=$(( $(date +%s) - SCRIPT_START_TS ))s"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ---------------------------------------------------------------------------
# 前台等待（保持容器运行）
# ---------------------------------------------------------------------------
ha_log_info "services_ready wait_loop=enabled total_elapsed=$(( $(date +%s) - SCRIPT_START_TS ))s"
echo "============================================="
echo " PostgreSQL HA 节点就绪"
echo " 角色: ${NODE_ROLE}"
echo " PG 端口: ${PGPORT}"
echo "============================================="

# 持续监控子进程，任一退出则重启
MAIN_LOOP_LAST_PG_STATE="ready"
LAST_LOG_SWEEP_TS=0
while true; do
    # 检查 PostgreSQL 是否存活
    if ! su - postgres -c "pg_isready -q" 2>/dev/null; then
        if [ "${MAIN_LOOP_LAST_PG_STATE}" != "unready" ]; then
            ha_log_warn "postgres_unready_in_main_loop"
            MAIN_LOOP_LAST_PG_STATE="unready"
        fi
    else
        if [ "${MAIN_LOOP_LAST_PG_STATE}" != "ready" ]; then
            ha_log_info "postgres_ready_in_main_loop"
            MAIN_LOOP_LAST_PG_STATE="ready"
        fi
    fi

    if [ "${HA_LOG_SWEEP_INTERVAL_SECS}" -gt 0 ]; then
        NOW_TS=$(date +%s)
        if [ $(( NOW_TS - LAST_LOG_SWEEP_TS )) -ge "${HA_LOG_SWEEP_INTERVAL_SECS}" ]; then
            /usr/local/bin/log-maintenance.sh >/dev/null 2>&1 || \
                ha_log_warn "log_maintenance_failed interval=${HA_LOG_SWEEP_INTERVAL_SECS}"
            LAST_LOG_SWEEP_TS=${NOW_TS}
        fi
    fi
    sleep 5
done
