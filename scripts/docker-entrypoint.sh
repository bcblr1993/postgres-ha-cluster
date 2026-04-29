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
HA_PGDATA_WORK_ROOT=${HA_PGDATA_WORK_ROOT:-}
HA_RETAINED_PGDATA_DIR=${HA_RETAINED_PGDATA_DIR:-"/var/lib/postgresql/pg-ha-retained-before-clone"}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-"repmgr123"}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-"postgres123"}
export PGPORT=${PG_PORT:-5432}
WAL_ARCHIVE_ENABLED=${WAL_ARCHIVE_ENABLED:-"false"}
WAL_ARCHIVE_DIR=${WAL_ARCHIVE_DIR:-"/var/lib/postgresql/wal-archive"}
WAL_RECEIVER_ENABLED=${WAL_RECEIVER_ENABLED:-"false"}
WAL_ARCHIVE_CLEANUP_ENABLED=${WAL_ARCHIVE_CLEANUP_ENABLED:-"false"}
WAL_ARCHIVE_MAX_SIZE_MB=${WAL_ARCHIVE_MAX_SIZE_MB:-"10240"}
WAL_ARCHIVE_MIN_KEEP_SEGMENTS=${WAL_ARCHIVE_MIN_KEEP_SEGMENTS:-"64"}
HA_LOG_MAX_SIZE_MB=${HA_LOG_MAX_SIZE_MB:-20}
HA_LOG_KEEP_FILES=${HA_LOG_KEEP_FILES:-5}
HA_PG_LOG_KEEP_FILES=${HA_PG_LOG_KEEP_FILES:-10}
HA_LOG_SWEEP_INTERVAL_SECS=${HA_LOG_SWEEP_INTERVAL_SECS:-60}
export PGDATA HA_PGDATA_WORK_ROOT HA_RETAINED_PGDATA_DIR
RUN_ID="entrypoint-$(date +%s)-$$-${NODE_NAME}"
ha_log_init "docker-entrypoint" "${RUN_ID}"
SCRIPT_START_TS=$(date +%s)
FOCUSED_LOG_TAIL_PID=""

echo "============================================="
echo " PostgreSQL HA 节点启动"
echo " 节点: ${NODE_NAME}(${NODE_ID})"
echo " 配置角色: ${NODE_ROLE}"
echo " 本机/对端/VIP: ${NODE_IP} / ${PARTNER_IP} / ${NODE_VIP}"
echo " PG 端口: ${PGPORT}"
echo "============================================="
ha_log_section "容器入口启动 role=${NODE_ROLE} node_id=${NODE_ID} node_name=${NODE_NAME} node_ip=${NODE_IP} partner_ip=${PARTNER_IP} vip=${NODE_VIP} pgport=${PGPORT}"
ha_log_event "ha_node_start node=${NODE_NAME} configured_role=${NODE_ROLE} node_ip=${NODE_IP} partner_ip=${PARTNER_IP} vip=${NODE_VIP} pgport=${PGPORT}"

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
        printf 'export TZ=%q\n' "${TZ:-Asia/Shanghai}"
        printf 'REPMGR_PASSWORD=%q\n' "${REPMGR_PASSWORD}"
        printf 'WAL_ARCHIVE_ENABLED=%q\n' "${WAL_ARCHIVE_ENABLED}"
        printf 'WAL_ARCHIVE_DIR=%q\n' "${WAL_ARCHIVE_DIR}"
        printf 'WAL_RECEIVER_ENABLED=%q\n' "${WAL_RECEIVER_ENABLED}"
        printf 'WAL_ARCHIVE_CLEANUP_ENABLED=%q\n' "${WAL_ARCHIVE_CLEANUP_ENABLED}"
        printf 'WAL_ARCHIVE_MAX_SIZE_MB=%q\n' "${WAL_ARCHIVE_MAX_SIZE_MB}"
        printf 'WAL_ARCHIVE_MIN_KEEP_SEGMENTS=%q\n' "${WAL_ARCHIVE_MIN_KEEP_SEGMENTS}"
        printf 'HA_LOG_MAX_SIZE_MB=%q\n' "${HA_LOG_MAX_SIZE_MB}"
        printf 'HA_LOG_KEEP_FILES=%q\n' "${HA_LOG_KEEP_FILES}"
        printf 'HA_PG_LOG_KEEP_FILES=%q\n' "${HA_PG_LOG_KEEP_FILES}"
        printf 'HA_LOG_SWEEP_INTERVAL_SECS=%q\n' "${HA_LOG_SWEEP_INTERVAL_SECS}"
        printf 'HA_PGDATA_WORK_ROOT=%q\n' "${HA_PGDATA_WORK_ROOT}"
        printf 'HA_RETAINED_PGDATA_DIR=%q\n' "${HA_RETAINED_PGDATA_DIR}"
    } > "${RUNTIME_ENV_FILE}"
}

write_runtime_env
chmod 644 "${RUNTIME_ENV_FILE}"
ha_log_info "runtime_notify_env_written path=${RUNTIME_ENV_FILE}"

# ---------------------------------------------------------------------------
# repmgrd 以 postgres 用户触发事件钩子时不能直接写 Docker stdout。
# 这里只转发关键事件行，保证 docker logs 能看到切换/通知链路，同时避免 SQL 快照刷屏。
# ---------------------------------------------------------------------------
start_focused_log_tail() {
    local event_log="/var/log/repmgr/repmgr-event-hook.log"
    local wecom_log="/var/log/repmgr/wecom-notify.log"

    touch "${event_log}" "${wecom_log}"
    chown postgres:postgres "${event_log}" "${wecom_log}" 2>/dev/null || true

    tail -n 0 -F "${event_log}" "${wecom_log}" 2>/dev/null | \
        awk '/\[EVENT\]|\[WARN\]|\[ERROR\]/ { print; fflush(); }' &
    FOCUSED_LOG_TAIL_PID=$!
    ha_log_info "focused_log_tail_started pid=${FOCUSED_LOG_TAIL_PID} files=${event_log},${wecom_log}"
}

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
    if /usr/local/bin/keepalived-control.sh start; then
        KEEPALIVED_PID=$(cat /var/run/keepalived.pid 2>/dev/null || true)
        ha_log_info "keepalived_started pid=${KEEPALIVED_PID:-unknown}"
        ha_log_event "keepalived_started node=${NODE_NAME} pid=${KEEPALIVED_PID:-unknown}"
    else
        KEEPALIVED_RC=$?
        ha_log_warn "keepalived_start_failed_nonfatal node=${NODE_NAME} exit_code=${KEEPALIVED_RC} action=continue_postgres_start"
        ha_log_event "keepalived_unavailable node=${NODE_NAME} exit_code=${KEEPALIVED_RC} action=continue_postgres_start"
        return 0
    fi
}

stop_keepalived() {
    ha_log_info "keepalived_stop_requested"
    /usr/local/bin/keepalived-control.sh stop || true
}

move_retained_pgdata_dirs_outside_pgdata() {
    local retained_base retained_node_dir retained_dir retained_name dest replaced_dir stale_dir newest_dir
    retained_base="${HA_RETAINED_PGDATA_DIR}"
    retained_node_dir="${retained_base}/${NODE_NAME}"

    mkdir -p "${PGDATA}" "${retained_node_dir}"
    chown postgres:postgres "${retained_base}" "${retained_node_dir}" 2>/dev/null || true

    dest="${retained_node_dir}/latest"
    if [ ! -e "${dest}" ]; then
        newest_dir=$(ls -1dt "${retained_node_dir}"/.pg-ha-retained-before-clone-* 2>/dev/null | head -n 1 || true)
        if [ -n "${newest_dir}" ] && [ -d "${newest_dir}" ]; then
            mv "${newest_dir}" "${dest}"
            ha_log_event "retained_pgdata_history_normalized node=${NODE_NAME} source=${newest_dir} target=${dest} policy=keep_latest_only"
        fi
    fi

    for stale_dir in "${retained_node_dir}"/.pg-ha-retained-before-clone-* "${retained_node_dir}"/.pg-ha-retained-replaced-*; do
        [ -e "${stale_dir}" ] || continue
        rm -rf "${stale_dir}" >/dev/null 2>&1 &
        ha_log_event "retained_pgdata_history_cleanup_started node=${NODE_NAME} path=${stale_dir} policy=keep_latest_only pid=$!"
    done

    for retained_dir in "${PGDATA}"/.pg-ha-retained-before-clone-*; do
        [ -d "${retained_dir}" ] || continue
        retained_name=$(basename "${retained_dir}")
        dest="${retained_node_dir}/latest"
        if [ -e "${dest}" ]; then
            replaced_dir="${retained_node_dir}/.pg-ha-retained-replaced-entrypoint-$(date +%s)-$$"
            mv "${dest}" "${replaced_dir}"
            rm -rf "${replaced_dir}" >/dev/null 2>&1 &
            ha_log_event "retained_pgdata_previous_cleanup_started node=${NODE_NAME} replaced_dir=${replaced_dir} source=${retained_dir} policy=keep_latest_only pid=$!"
        fi

        ha_log_warn "retained_pgdata_inside_active_pgdata_moving source=${retained_dir} target=${dest}"
        mv "${retained_dir}" "${dest}"
        chown -R postgres:postgres "${dest}" 2>/dev/null || true
        ha_log_event "retained_pgdata_moved_outside_pgdata node=${NODE_NAME} source=${retained_dir} target=${dest} original_name=${retained_name} policy=keep_latest_only"
    done
}

migrate_legacy_pgdata_root_if_needed() {
    local work_root active_base retained_base migrated_count

    work_root="${HA_PGDATA_WORK_ROOT:-}"
    [ -n "${work_root}" ] || return 0
    [ "${work_root}" != "${PGDATA}" ] || return 0

    mkdir -p "${work_root}" "${PGDATA}"
    chown postgres:postgres "${work_root}" "${PGDATA}" 2>/dev/null || true

    if [ -s "${PGDATA}/PG_VERSION" ] || [ ! -s "${work_root}/PG_VERSION" ]; then
        return 0
    fi

    active_base=$(basename "${PGDATA}")
    retained_base=$(basename "${HA_RETAINED_PGDATA_DIR}")
    ha_log_warn "legacy_pgdata_layout_detected work_root=${work_root} active_pgdata=${PGDATA} action=migrate_to_current"

    migrated_count=$(find "${work_root}" -mindepth 1 -maxdepth 1 \
        ! -name "${active_base}" \
        ! -name "${retained_base}" \
        ! -name '.pg-ha-clone-*' \
        -print 2>/dev/null | wc -l | tr -d '[:space:]')

    while IFS= read -r path; do
        mv "${path}" "${PGDATA}/"
    done < <(find "${work_root}" -mindepth 1 -maxdepth 1 \
        ! -name "${active_base}" \
        ! -name "${retained_base}" \
        ! -name '.pg-ha-clone-*' \
        -print)

    chown postgres:postgres "${PGDATA}" 2>/dev/null || true
    chmod 700 "${PGDATA}" 2>/dev/null || true
    ha_log_event "legacy_pgdata_layout_migrated node=${NODE_NAME} work_root=${work_root} active_pgdata=${PGDATA} moved_items=${migrated_count:-0}"
}

# ---------------------------------------------------------------------------
# 复制并动态替换配置文件中的 IP 地址
# ---------------------------------------------------------------------------
ha_log_info "copy_repmgr_config source=/etc/pg-ha/conf/repmgr-node${NODE_ID}.conf target=/etc/repmgr.conf"
cp /etc/pg-ha/conf/repmgr-node${NODE_ID}.conf /etc/repmgr.conf
# 动态替换 conninfo 中的 IP 和端口
sed -i "s|host=192.168.1.1[0-9]*|host=${NODE_IP}|g" /etc/repmgr.conf
sed -i "s|connect_timeout=2|connect_timeout=2 port=${PGPORT}|g" /etc/repmgr.conf
sed -i "s|^data_directory=.*|data_directory='${PGDATA}'|g" /etc/repmgr.conf
sed -i "s|pg_ctl -D /var/lib/postgresql/data|pg_ctl -D ${PGDATA}|g" /etc/repmgr.conf
chown postgres:postgres /etc/repmgr.conf
ha_log_info "repmgr_config_ready node_ip=${NODE_IP} pgport=${PGPORT} data_directory=${PGDATA}"

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

migrate_legacy_pgdata_root_if_needed
move_retained_pgdata_dirs_outside_pgdata

start_focused_log_tail

# ---------------------------------------------------------------------------
# 两个节点都提前启动 Keepalived，由 track_script 决定是否具备持有 VIP 的资格。
# 这样在 PostgreSQL 角色变化时，VRRP 能直接收敛，不必额外等待进程启动。
# ---------------------------------------------------------------------------
start_keepalived

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

/usr/local/bin/vip-control.sh ensure || true
ha_log_ha_snapshot "entrypoint_after_setup"

# ---------------------------------------------------------------------------
# 信号处理 - 优雅关闭
# ---------------------------------------------------------------------------
cleanup() {
    ha_log_warn "signal_received action=cleanup"

    if [ -n "${FOCUSED_LOG_TAIL_PID}" ]; then
        kill "${FOCUSED_LOG_TAIL_PID}" 2>/dev/null || true
    fi

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
ha_log_event "ha_node_available node=${NODE_NAME} configured_role=${NODE_ROLE} total_elapsed=$(( $(date +%s) - SCRIPT_START_TS ))s"
echo "============================================="
echo " PostgreSQL HA 节点就绪"
echo " 角色: ${NODE_ROLE}"
echo " PG 端口: ${PGPORT}"
echo "============================================="

# 持续监控子进程，任一退出则重启
MAIN_LOOP_LAST_PG_STATE="ready"
LAST_LOG_SWEEP_TS=0
HA_RUNTIME_STATE_FILE="/tmp/ha-runtime.state"

build_ha_runtime_state() {
    local pg_state role wal_receiver vip_present keepalived_state
    pg_state="unready"
    role="unknown"
    wal_receiver="none"
    vip_present="no"
    keepalived_state="stopped"

    if su - postgres -c "pg_isready -q" 2>/dev/null; then
        pg_state="ready"
        role=$(su - postgres -c "psql -p ${PGPORT} -tAc \"SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END\"" 2>/dev/null | tr -d '[:space:]' || true)
        wal_receiver=$(su - postgres -c "psql -p ${PGPORT} -tAc \"SELECT COALESCE(MAX(status), 'none') FROM pg_stat_wal_receiver\"" 2>/dev/null | tr -d '[:space:]' || true)
    fi

    if [ -n "${NODE_VIP}" ] && ip addr show 2>/dev/null | grep -qw "${NODE_VIP}"; then
        vip_present="yes"
    fi

    if pgrep -x keepalived >/dev/null 2>&1; then
        keepalived_state="running"
    fi

    printf 'pg=%s role=%s wal_receiver=%s vip=%s keepalived=%s' \
        "${pg_state}" "${role:-unknown}" "${wal_receiver:-none}" "${vip_present}" "${keepalived_state}"
}

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

    CURRENT_HA_STATE=$(build_ha_runtime_state)
    if ha_log_state_change "${HA_RUNTIME_STATE_FILE}" "ha_runtime_state_change" "${CURRENT_HA_STATE}"; then
        ha_log_event "ha_state_change node=${NODE_NAME} ${CURRENT_HA_STATE}"
        ha_log_ha_snapshot "entrypoint_state_change"
    fi

    sleep 5
done
