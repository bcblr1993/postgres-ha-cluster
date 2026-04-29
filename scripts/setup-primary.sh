#!/bin/bash
# =============================================================================
# Primary 节点初始化脚本
# 功能：初始化 PG 数据目录、创建 repmgr 用户/库、注册 Primary 节点
# =============================================================================
set -e

. /usr/local/bin/ha-log.sh

/usr/local/bin/wal-receiver-control.sh stop >/dev/null 2>&1 || true

PGDATA=${PGDATA:-"/var/lib/postgresql/data"}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-"repmgr123"}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-"postgres123"}
POSTGRES_DB=${POSTGRES_DB:-""}
PARTNER_IP=${PARTNER_IP:-"192.168.1.12"}
TIMING_LOG=/var/log/repmgr/recovery-timing.log
RUN_ID="primary-$(date +%s)-$$-${NODE_NAME:-unknown}"
SCRIPT_START_TS=$(date +%s)

mkdir -p /var/log/repmgr
ha_log_init "setup-primary" "${RUN_ID}"

timing_log() {
    ha_log_timing "$*"
    echo "[TIMING][${RUN_ID}] $*" >> "${TIMING_LOG}"
}

timed_postgres_cmd() {
    local label="$1"
    local cmd="$2"
    local start_ts end_ts elapsed
    start_ts=$(date +%s)
    ha_log_info "command_start label=${label} cmd=${cmd}"
    su - postgres -c "${cmd}"
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    timing_log "${label} elapsed=${elapsed}s"
}

apply_runtime_postgres_config() {
    local target_conf="$1"
    local archive_enabled="${WAL_ARCHIVE_ENABLED:-false}"
    local archive_dir="${WAL_ARCHIVE_DIR:-/var/lib/postgresql/wal-archive}"

    sed -i "s/port = 5432/port = ${PGPORT:-5432}/g" "${target_conf}"

    if [ "${archive_enabled}" = "true" ]; then
        mkdir -p "${archive_dir}"
        chown postgres:postgres "${archive_dir}"
        chmod 700 "${archive_dir}"
        cat >> "${target_conf}" <<EOF

# Runtime-managed WAL archive settings
archive_mode = on
archive_command = 'test ! -f ${archive_dir}/%f && cp %p ${archive_dir}/%f'
restore_command = '/usr/local/bin/restore-wal.sh ${archive_dir} %f %p'
recovery_target_timeline = 'latest'
EOF
        ha_log_info "runtime_pg_archive_config_applied target=${target_conf} archive_dir=${archive_dir}"
    else
        cat >> "${target_conf}" <<'EOF'

# Runtime-managed WAL archive settings
archive_mode = on
archive_command = '/bin/true'
recovery_target_timeline = 'latest'
EOF
        ha_log_info "runtime_pg_archive_config_disabled target=${target_conf}"
    fi
}

check_partner_primary_with_timing() {
    local start_ts end_ts elapsed result
    start_ts=$(date +%s)
    if partner_is_primary; then
        result=true
    else
        result=false
    fi
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    timing_log "partner_is_primary result=${result} elapsed=${elapsed}s partner=${PARTNER_IP}"
    [ "${result}" = "true" ]
}

ha_log_section "开始 Primary 节点初始化"
ha_log_event "primary_setup_start node=${NODE_NAME:-unknown} node_ip=${NODE_IP:-unknown} partner_ip=${PARTNER_IP} pgdata=${PGDATA}"
timing_log "script_start role=primary pgdata=${PGDATA} partner=${PARTNER_IP}"
ha_log_ha_snapshot "primary_setup_start"

partner_is_primary() {
    PGPASSWORD="${REPMGR_PASSWORD}" psql \
        "host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=2" \
        -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null | grep -q '^t$'
}

local_data_dir_looks_like_standby() {
    [ -f "${PGDATA}/standby.signal" ] || [ -f "${PGDATA}/recovery.signal" ]
}

# 已有数据目录时，先识别本地真实角色，避免把只读 standby 当 primary 初始化
if [ -s "${PGDATA}/PG_VERSION" ]; then
    ha_log_info "检查现有数据目录真实角色 pgdata=${PGDATA}"
    chown -R postgres:postgres ${PGDATA}
    chmod 700 ${PGDATA}

    PRECHECK_START_TS=$(date +%s)
    if local_data_dir_looks_like_standby; then
        timing_log "precheck_offline_role value=standby elapsed=0s"
        timing_log "precheck_total elapsed=$(( $(date +%s) - PRECHECK_START_TS ))s"
        ha_log_warn "检测到 standby.signal/recovery.signal，本地数据目录按 Standby 处理"
        timing_log "handoff_to_standby reason=offline_standby_signal"
        exec /usr/local/bin/setup-standby.sh
    fi
    timing_log "precheck_offline_role value=primary elapsed=0s"
    timing_log "precheck_total elapsed=$(( $(date +%s) - PRECHECK_START_TS ))s"
fi

if check_partner_primary_with_timing; then
    ha_log_warn "检测到对端已是 Primary，当前节点将自动作为 Standby 重新加入集群 partner=${PARTNER_IP}"
    timing_log "handoff_to_standby reason=partner_is_primary"
    exec /usr/local/bin/setup-standby.sh
fi

# ---------------------------------------------------------------------------
# 步骤 0：修复数据目录权限（兼容 Bind Mount 模式）
# ---------------------------------------------------------------------------
ha_log_info "检查数据目录权限 pgdata=${PGDATA}"
chown -R postgres:postgres ${PGDATA}
chmod 700 ${PGDATA}

# ---------------------------------------------------------------------------
# 步骤 1：初始化 PostgreSQL 数据目录（如果为空）
# ---------------------------------------------------------------------------
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    ha_log_info "数据目录为空，执行 initdb"
    timed_postgres_cmd "initdb" "initdb -D ${PGDATA} --encoding=UTF8 --locale=C"

    # 应用自定义配置
    ha_log_info "应用 postgresql.conf 和 pg_hba.conf"
    cp /etc/pg-ha/conf/postgresql.conf ${PGDATA}/postgresql.conf
    cp /etc/pg-ha/conf/pg_hba.conf ${PGDATA}/pg_hba.conf
    apply_runtime_postgres_config "${PGDATA}/postgresql.conf"
    chown postgres:postgres ${PGDATA}/postgresql.conf ${PGDATA}/pg_hba.conf
else
    ha_log_info "数据目录已存在，跳过 initdb"
    # 仍然更新配置文件（确保配置一致性）
    cp /etc/pg-ha/conf/postgresql.conf ${PGDATA}/postgresql.conf
    cp /etc/pg-ha/conf/pg_hba.conf ${PGDATA}/pg_hba.conf
    apply_runtime_postgres_config "${PGDATA}/postgresql.conf"
    chown postgres:postgres ${PGDATA}/postgresql.conf ${PGDATA}/pg_hba.conf
fi

# ---------------------------------------------------------------------------
# 步骤 2：启动 PostgreSQL
# ---------------------------------------------------------------------------
# 确保日志目录存在
mkdir -p ${PGDATA}/log && chown postgres:postgres ${PGDATA}/log
ha_log_info "启动 PostgreSQL"
timed_postgres_cmd "primary_pg_start" "pg_ctl -D ${PGDATA} -l ${PGDATA}/log/startup.log start -w"

# 等待 PG 就绪
ha_log_info "等待 PostgreSQL 就绪"
READY_WAIT_START_TS=$(date +%s)
for i in $(seq 1 30); do
    if su - postgres -c "pg_isready -q"; then
        ha_log_info "PostgreSQL 已就绪 attempts=${i}"
        timing_log "primary_pg_ready attempts=${i} elapsed=$(( $(date +%s) - READY_WAIT_START_TS ))s"
        ha_log_event "postgres_ready node=${NODE_NAME:-unknown} role=primary attempts=${i} elapsed=$(( $(date +%s) - READY_WAIT_START_TS ))s"
        break
    fi
    if [ $i -eq 30 ]; then
        ha_log_error "PostgreSQL 启动超时"
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# 步骤 3：创建 repmgr 用户和数据库（幂等操作）
# ---------------------------------------------------------------------------
ha_log_info "创建 repmgr 用户和数据库"
DB_SETUP_START_TS=$(date +%s)

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
    ha_log_info "初始化业务数据库 db=${POSTGRES_DB}"
    su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\"" | grep -q 1 || \
        su - postgres -c "psql -c \"CREATE DATABASE ${POSTGRES_DB} OWNER postgres\""
fi

ha_log_info "repmgr 用户和数据库创建完成"
timing_log "primary_db_setup elapsed=$(( $(date +%s) - DB_SETUP_START_TS ))s"

# ---------------------------------------------------------------------------
# 步骤 4：注册 Primary 节点到 repmgr（幂等操作）
# ---------------------------------------------------------------------------
ha_log_info "注册 Primary 节点"
ha_log_ha_snapshot "primary_before_register"
timed_postgres_cmd "primary_register" "repmgr -f /etc/repmgr.conf primary register --force"
ha_log_info "Primary 节点注册完成"
ha_log_event "repmgr_primary_registered node=${NODE_NAME:-unknown} node_id=${NODE_ID:-unknown}"
ha_log_ha_snapshot "primary_after_register"

# 查看集群状态
ha_log_capture_allow_fail "INFO" "primary_cluster_show" "su - postgres -c \"repmgr -f /etc/repmgr.conf cluster show\"" || true

# ---------------------------------------------------------------------------
# 步骤 5：启动 repmgrd 守护进程
# ---------------------------------------------------------------------------
# 清理残留 PID 文件（同 setup-standby.sh 的处理逻辑）
START_REPMGRD=true
if [ -f /tmp/repmgrd.pid ]; then
    OLD_PID=$(cat /tmp/repmgrd.pid 2>/dev/null || true)
    OLD_COMM=$(ps -p "${OLD_PID:-0}" -o comm= 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "${OLD_PID}" ] && [ "${OLD_COMM}" = "repmgrd" ] && kill -0 "${OLD_PID}" 2>/dev/null; then
        ha_log_info "repmgrd 已在运行 pid=${OLD_PID}，跳过启动"
        START_REPMGRD=false
    else
        ha_log_warn "清理残留 repmgrd PID 文件 stale_pid=${OLD_PID} stale_comm=${OLD_COMM:-unknown}"
        rm -f /tmp/repmgrd.pid
    fi
fi
if [ "${START_REPMGRD}" = "true" ]; then
    ha_log_info "启动 repmgrd 守护进程"
    timed_postgres_cmd "primary_repmgrd_start" "repmgrd -f /etc/repmgr.conf --pid-file=/tmp/repmgrd.pid --daemonize"
    ha_log_info "repmgrd 已启动"
    ha_log_event "repmgrd_started node=${NODE_NAME:-unknown} role=primary"
else
    ha_log_info "跳过 repmgrd 启动，复用现有进程"
fi
ha_log_ha_snapshot "primary_after_repmgrd"
ha_log_capture_allow_fail "INFO" "primary_runtime_snapshot" "su - postgres -c \"psql -x -c \\\"SELECT pg_is_in_recovery() AS in_recovery, pg_current_wal_lsn() AS current_wal_lsn\\\" -c \\\"SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication ORDER BY application_name\\\"\"" || true

ha_log_section "Primary 节点初始化完成"
ha_log_event "primary_available node=${NODE_NAME:-unknown} total_elapsed=$(( $(date +%s) - SCRIPT_START_TS ))s"
timing_log "script_complete role=primary total_elapsed=$(( $(date +%s) - SCRIPT_START_TS ))s"
ha_log_ha_snapshot "primary_setup_complete"
