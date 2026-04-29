#!/bin/bash
# =============================================================================
# Standby 节点初始化脚本
# 功能：等待 Primary、从 Primary 克隆数据、注册 Standby 节点
# =============================================================================
set -e

. /usr/local/bin/ha-log.sh

PGDATA=${PGDATA:-"/var/lib/postgresql/data"}
HA_PGDATA_WORK_ROOT=${HA_PGDATA_WORK_ROOT:-${PGDATA}}
PARTNER_IP=${PARTNER_IP:-"192.168.1.11"}
MAX_WAIT=${MAX_WAIT:-120}
REJOIN_VERIFY_TIMEOUT=${REJOIN_VERIFY_TIMEOUT:-30}
CLONE_FAILURE_MARKER="${PGDATA}/.pg-ha-clone-failed"
REJOIN_REASON=""
LOCAL_DATA_ROLE_HINT=""
goto_register=false
TIMING_LOG=/var/log/repmgr/recovery-timing.log
RUN_ID="standby-$(date +%s)-$$-${NODE_NAME:-unknown}"
SCRIPT_START_TS=$(date +%s)

mkdir -p /var/log/repmgr
ha_log_init "setup-standby" "${RUN_ID}"

timing_log() {
    ha_log_timing "$*"
    echo "[TIMING][${RUN_ID}] $*" >> "${TIMING_LOG}"
}

ensure_pgdata_permissions() {
    local owner

    mkdir -p "${PGDATA}"
    owner=$(stat -c '%U:%G' "${PGDATA}" 2>/dev/null || true)
    if [ "${owner}" != "postgres:postgres" ]; then
        ha_log_warn "pgdata_ownership_recursive_fix_start pgdata=${PGDATA} owner=${owner:-unknown}"
        chown -R postgres:postgres "${PGDATA}"
        ha_log_warn "pgdata_ownership_recursive_fix_done pgdata=${PGDATA}"
    else
        chown postgres:postgres "${PGDATA}" 2>/dev/null || true
    fi
    chmod 700 "${PGDATA}"
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

timed_postgres_capture_cmd() {
    local label="$1"
    local cmd="$2"
    local start_ts end_ts elapsed rc
    rc=0
    start_ts=$(date +%s)
    ha_log_info "command_capture_start label=${label} cmd=${cmd}"
    ha_log_capture_allow_fail "INFO" "${label}" "su - postgres -c \"${cmd}\"" || rc=$?
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    if [ ${rc} -eq 0 ]; then
        timing_log "${label} elapsed=${elapsed}s exit_code=${rc}"
    else
        timing_log "${label}_failed elapsed=${elapsed}s exit_code=${rc}"
    fi
    return ${rc}
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

log_local_standby_snapshot() {
    local context="$1"
    local in_recovery wal_status
    in_recovery=$(su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null | tr -d '[:space:]' || true)
    wal_status=$(su - postgres -c "psql -tAc \"SELECT status FROM pg_stat_wal_receiver\"" 2>/dev/null | tr -d '[:space:]' || true)
    timing_log "${context} local_in_recovery=${in_recovery:-unknown} wal_receiver_status=${wal_status:-none}"
}

ha_log_section "开始 Standby 节点初始化"
ha_log_event "standby_setup_start node=${NODE_NAME:-unknown} node_ip=${NODE_IP:-unknown} primary_candidate=${PARTNER_IP} pgdata=${PGDATA}"
timing_log "script_start role=standby pgdata=${PGDATA} partner=${PARTNER_IP}"
ha_log_ha_snapshot "standby_setup_start"

partner_is_primary() {
    PGPASSWORD="${REPMGR_PASSWORD:-repmgr123}" psql \
        "host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=2" \
        -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null | grep -q '^t$'
}

local_data_dir_has_standby_signal() {
    [ -f "${PGDATA}/standby.signal" ] || [ -f "${PGDATA}/recovery.signal" ]
}

pg_controldata_value() {
    local key="$1"
    su - postgres -c "pg_controldata '${PGDATA}'" 2>/dev/null | awk -F': *' -v key="${key}" '$1 == key {print $2; exit}'
}

log_offline_cluster_state() {
    local context="$1"
    local cluster_state checkpoint_lsn
    cluster_state=$(pg_controldata_value "Database cluster state" | tr -d '\r')
    checkpoint_lsn=$(pg_controldata_value "Latest checkpoint location" | tr -d '\r')
    timing_log "${context} cluster_state=${cluster_state:-unknown} checkpoint_lsn=${checkpoint_lsn:-unknown}"
}

local_is_streaming_standby() {
    local in_recovery wal_status
    in_recovery=$(su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null | tr -d '[:space:]')
    wal_status=$(su - postgres -c "psql -tAc \"SELECT status FROM pg_stat_wal_receiver\"" 2>/dev/null | tr -d '[:space:]')
    [ "${in_recovery}" = "t" ] && [ "${wal_status}" = "streaming" ]
}

remote_sees_local_replication() {
    PGPASSWORD="${REPMGR_PASSWORD:-repmgr123}" psql \
        "host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=2" \
        -tAc "SELECT COUNT(*) FROM pg_stat_replication WHERE client_addr = inet '${NODE_IP}'" 2>/dev/null | \
        tr -d '[:space:]' | grep -q '^[1-9][0-9]*$'
}

rejoin_timeline_error_detected() {
    local latest_log
    latest_log=$(ls -1t "${PGDATA}"/log/postgresql-*.log "${PGDATA}/log/startup.log" 2>/dev/null | head -n 1 || true)
    [ -n "${latest_log}" ] || return 1
    grep -E -q \
        "requested starting point .* is not in this server's history|could not start WAL streaming|End of WAL reached on timeline" \
        "${latest_log}" 2>/dev/null
}

wait_for_rejoin_streaming() {
    local timeout="${1:-30}"
    local start_ts now role wal
    start_ts=$(date +%s)

    while true; do
        if local_is_streaming_standby || remote_sees_local_replication; then
            log_local_standby_snapshot "node_rejoin_verify_success"
            return 0
        fi

        if rejoin_timeline_error_detected; then
            ha_log_warn "检测到 WAL streaming timeline 致命错误，提前终止 rejoin 校验等待"
            return 2
        fi

        now=$(date +%s)
        if (( now - start_ts >= timeout )); then
            role=$(su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null | tr -d '[:space:]' || true)
            wal=$(su - postgres -c "psql -tAc \"SELECT status FROM pg_stat_wal_receiver\"" 2>/dev/null | tr -d '[:space:]' || true)
            ha_log_warn "rejoin_verify_timeout timeout=${timeout}s local_role=${role:-unknown} wal_receiver=${wal:-none}"
            return 1
        fi

        sleep 1
    done
}

print_rejoin_diagnostics() {
    ha_log_warn "===== rejoin diagnostics begin ====="
    ha_log_warn "local pg_isready:"
    su - postgres -c "pg_isready" 2>&1 || true
    ha_log_warn "local recovery / wal receiver:"
    su - postgres -c "psql -x -c \"SELECT pg_is_in_recovery() AS in_recovery\"" 2>&1 || true
    su - postgres -c "psql -x -c \"SELECT status, sender_host, sender_port, conninfo FROM pg_stat_wal_receiver\"" 2>&1 || true
    ha_log_warn "local primary_conninfo:"
    su - postgres -c "psql -tAc 'SHOW primary_conninfo'" 2>&1 || true
    ha_log_warn "remote pg_stat_replication:"
    PGPASSWORD="${REPMGR_PASSWORD:-repmgr123}" psql \
        "host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=2" \
        -x -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication" 2>&1 || true
    ha_log_warn "archive directory snapshot:"
    ls -1t "${WAL_ARCHIVE_DIR:-/var/lib/postgresql/wal-archive}" 2>/dev/null | head -n 40 || true
    ha_log_warn "restore-wal recent log:"
    tail -n 80 /var/log/repmgr/restore-wal.log 2>/dev/null || true
    ha_log_warn "pg-receivewal recent log:"
    tail -n 80 /var/log/repmgr/pg-receivewal.log 2>/dev/null || true
    ha_log_warn "local PostgreSQL recent log:"
    tail -n 80 "${PGDATA}/log/"postgresql-*.log 2>/dev/null || true
    tail -n 80 "${PGDATA}/log/startup.log" 2>/dev/null || true
    ha_log_warn "===== rejoin diagnostics end ====="
}

stop_local_postgres_if_running() {
    if su - postgres -c "pg_isready -q" 2>/dev/null; then
        ha_log_warn "停止当前本地 PostgreSQL，准备重新加入或全量克隆"
        su - postgres -c "pg_ctl -D ${PGDATA} stop -m fast" 2>/dev/null || true
    fi
}

record_clone_failure_marker() {
    local reason="$1"
    local exit_code="$2"
    local clone_dir="$3"

    mkdir -p "${PGDATA}"
    {
        printf 'failed_at=%s\n' "$(date '+%F %T %z')"
        printf 'node=%s\n' "${NODE_NAME:-unknown}"
        printf 'source_primary=%s\n' "${PARTNER_IP}"
        printf 'reason=%s\n' "${reason}"
        printf 'exit_code=%s\n' "${exit_code}"
        printf 'clone_dir=%s\n' "${clone_dir}"
        printf 'run_id=%s\n' "${RUN_ID}"
    } > "${CLONE_FAILURE_MARKER}"
    chown postgres:postgres "${CLONE_FAILURE_MARKER}" 2>/dev/null || true
}

clear_clone_failure_marker() {
    local reason="${1:-recovered}"

    if [ -f "${CLONE_FAILURE_MARKER}" ]; then
        rm -f "${CLONE_FAILURE_MARKER}"
        ha_log_event "standby_clone_failure_cleared node=${NODE_NAME:-unknown} reason=${reason}"
    fi
}

cleanup_stale_clone_workdirs() {
    local root
    for root in "${PGDATA}" "${HA_PGDATA_WORK_ROOT}"; do
        [ -d "${root}" ] || continue
        find "${root}" -mindepth 1 -maxdepth 1 -type d -name '.pg-ha-clone-*' \
            -exec rm -rf {} + 2>/dev/null || true
    done
}

prepare_clone_workdir() {
    local clone_dir="$1"

    mkdir -p "${PGDATA}"
    mkdir -p "${HA_PGDATA_WORK_ROOT}"
    chmod 700 "${PGDATA}"
    chmod 700 "${HA_PGDATA_WORK_ROOT}" 2>/dev/null || true
    chown postgres:postgres "${PGDATA}" "${HA_PGDATA_WORK_ROOT}" 2>/dev/null || true

    cleanup_stale_clone_workdirs
    mkdir -p "${clone_dir}"
    chmod 700 "${clone_dir}"
    chown postgres:postgres "${clone_dir}"
    ha_log_event "standby_clone_workspace_ready node=${NODE_NAME:-unknown} clone_dir=${clone_dir} old_pgdata_preserved=yes"
}

prepare_clone_repmgr_config() {
    local clone_dir="$1"
    local clone_conf="$2"

    cp /etc/repmgr.conf "${clone_conf}"
    sed -i "s|^data_directory=.*|data_directory='${clone_dir}'|" "${clone_conf}"
    chmod 600 "${clone_conf}"
    chown postgres:postgres "${clone_conf}"
    ha_log_info "standby_clone_repmgr_config_ready clone_conf=${clone_conf} clone_dir=${clone_dir}"
}

cleanup_retained_path_async() {
    local path="$1"
    local reason="$2"

    [ -e "${path}" ] || return 0
    rm -rf "${path}" >/dev/null 2>&1 &
    ha_log_event "standby_clone_retained_cleanup_started node=${NODE_NAME:-unknown} path=${path} reason=${reason} pid=$!"
}

prepare_single_retained_pgdata_dir() {
    local retained_dir="$1"
    local retained_base replaced_dir old_dir

    retained_base=$(dirname "${retained_dir}")
    mkdir -p "${retained_base}"
    chmod 700 "${retained_base}"
    chown postgres:postgres "${retained_base}"

    if [ -e "${retained_dir}" ]; then
        replaced_dir="${retained_base}/.pg-ha-retained-replaced-${RUN_ID}"
        if [ -e "${replaced_dir}" ]; then
            replaced_dir="${replaced_dir}.$(date +%s)"
        fi
        mv "${retained_dir}" "${replaced_dir}"
        ha_log_event "standby_clone_previous_retained_replaced node=${NODE_NAME:-unknown} old_retained_dir=${retained_dir} cleanup_dir=${replaced_dir} policy=keep_latest_only"
        cleanup_retained_path_async "${replaced_dir}" "replaced_by_new_clone"
    fi

    for old_dir in "${retained_base}"/.pg-ha-retained-before-clone-* "${retained_base}"/.pg-ha-retained-replaced-*; do
        [ -e "${old_dir}" ] || continue
        cleanup_retained_path_async "${old_dir}" "cleanup_old_retained_history"
    done
}

activate_cloned_pgdata() {
    local clone_dir="$1"
    local backup_dir="$2"
    local clone_base backup_base active_count backup_size_human

    clone_base=$(basename "${clone_dir}")
    backup_base=$(basename "${backup_dir}")

    active_count=$(find "${PGDATA}" -mindepth 1 -maxdepth 1 \
        ! -name "${clone_base}" \
        ! -name '.pg-ha-retained-before-clone-*' \
        -print 2>/dev/null | wc -l | tr -d '[:space:]')

    ha_log_event "standby_clone_activate_start node=${NODE_NAME:-unknown} clone_dir=${clone_dir} active_items=${active_count:-0}"

    if [ "${active_count:-0}" -gt 0 ]; then
        prepare_single_retained_pgdata_dir "${backup_dir}"
        mkdir -p "${backup_dir}"
        chmod 700 "${backup_dir}"
        chown postgres:postgres "${backup_dir}"

        while IFS= read -r path; do
            mv "${path}" "${backup_dir}/"
        done < <(find "${PGDATA}" -mindepth 1 -maxdepth 1 \
            ! -name "${clone_base}" \
            ! -name "${backup_base}" \
            ! -name '.pg-ha-retained-before-clone-*' \
            -print)

        backup_size_human=$(du -sh "${backup_dir}" 2>/dev/null | awk '{print $1}' || echo unknown)
        ha_log_event "standby_clone_old_pgdata_retained node=${NODE_NAME:-unknown} retained_dir=${backup_dir} size_human=${backup_size_human:-unknown}"
    fi

    while IFS= read -r path; do
        mv "${path}" "${PGDATA}/"
    done < <(find "${clone_dir}" -mindepth 1 -maxdepth 1 -print)
    rmdir "${clone_dir}" 2>/dev/null || true

    chown postgres:postgres "${PGDATA}"
    chmod 700 "${PGDATA}"
    ha_log_event "standby_clone_activated node=${NODE_NAME:-unknown} pgdata=${PGDATA} retained_old_data=$([ "${active_count:-0}" -gt 0 ] && printf '%s' "${backup_dir}" || printf 'none')"
}

ensure_clean_shutdown_for_rejoin() {
    local prep_start_ts state signal_file
    prep_start_ts=$(date +%s)
    log_offline_cluster_state "rejoin_prepare_before"
    state=$(pg_controldata_value "Database cluster state" | tr -d '\r')

    case "${state}" in
        "shut down"|"shut down in recovery")
            timing_log "rejoin_prepare_clean_shutdown elapsed=$(( $(date +%s) - prep_start_ts ))s state=${state}"
            return 0
            ;;
    esac

    ha_log_warn "本地数据目录未干净关闭，按 repmgr 官方建议先离线恢复到一致点 state=${state:-unknown}"

    for signal_file in standby.signal recovery.signal; do
        if [ -f "${PGDATA}/${signal_file}" ]; then
            mv "${PGDATA}/${signal_file}" "${PGDATA}/${signal_file}.rejoin.bak"
        fi
    done

    if su - postgres -c "postgres --single -D '${PGDATA}' postgres < /dev/null" >/tmp/rejoin-single-user.log 2>&1; then
        ha_log_info "单用户模式一致性恢复完成"
    else
        ha_log_warn "单用户模式一致性恢复失败，输出如下"
        cat /tmp/rejoin-single-user.log 2>/dev/null || true
        for signal_file in standby.signal recovery.signal; do
            if [ -f "${PGDATA}/${signal_file}.rejoin.bak" ]; then
                mv "${PGDATA}/${signal_file}.rejoin.bak" "${PGDATA}/${signal_file}"
            fi
        done
        timing_log "rejoin_prepare_single_user_failed elapsed=$(( $(date +%s) - prep_start_ts ))s"
        return 1
    fi

    for signal_file in standby.signal recovery.signal; do
        if [ -f "${PGDATA}/${signal_file}.rejoin.bak" ]; then
            mv "${PGDATA}/${signal_file}.rejoin.bak" "${PGDATA}/${signal_file}"
        fi
    done

    state=$(pg_controldata_value "Database cluster state" | tr -d '\r')
    log_offline_cluster_state "rejoin_prepare_after"
    timing_log "rejoin_prepare_single_user elapsed=$(( $(date +%s) - prep_start_ts ))s state=${state:-unknown}"
    case "${state}" in
        "shut down"|"shut down in recovery")
            return 0
            ;;
    esac

    ha_log_warn "单用户模式后数据目录仍非干净关闭 state=${state:-unknown}"
    return 1
}

# ---------------------------------------------------------------------------
# 步骤 0：优先识别本地数据目录角色，兼容双节点同时断电后的恢复
# ---------------------------------------------------------------------------
ha_log_info "检查数据目录权限 pgdata=${PGDATA}"
ensure_pgdata_permissions

if [ -s "${PGDATA}/PG_VERSION" ]; then
    ha_log_info "预检查本地数据目录角色"

    PRECHECK_START_TS=$(date +%s)
    log_offline_cluster_state "precheck_offline"
    if local_data_dir_has_standby_signal; then
        LOCAL_DATA_ROLE_HINT="standby"
        timing_log "precheck_offline_role value=standby elapsed=0s"
        ha_log_info "检测到 standby.signal/recovery.signal，本地数据目录按 Standby 处理"
    else
        LOCAL_DATA_ROLE_HINT="primary"
        timing_log "precheck_offline_role value=primary elapsed=0s"
        ha_log_warn "未检测到 standby.signal/recovery.signal，本地数据目录按旧主/Primary 目录处理"

        if partner_is_primary; then
            ha_log_warn "对端已是 Primary，当前节点将以旧主回归路径重新加入为 Standby"
            REJOIN_REASON="detected-old-primary"
            timing_log "detected_old_primary partner=${PARTNER_IP}"
        else
            ha_log_warn "对端未成为 Primary，当前节点恢复为 Primary 提供服务"
            timing_log "handoff_to_primary reason=partner_not_primary"
            exec /usr/local/bin/setup-primary.sh
        fi
    fi
    timing_log "precheck_total elapsed=$(( $(date +%s) - PRECHECK_START_TS ))s"
fi

# ---------------------------------------------------------------------------
# 步骤 1：等待 Primary 节点可达
# ---------------------------------------------------------------------------
ha_log_info "等待 Primary 节点就绪 partner=${PARTNER_IP}"
WAIT_PRIMARY_START_TS=$(date +%s)
CLONE_FAILURE_WAIT_LOGGED=false
for i in $(seq 1 ${MAX_WAIT}); do
    if pg_isready -h ${PARTNER_IP} -p ${PGPORT:-5432} -U repmgr -q 2>/dev/null; then
        ha_log_info "Primary 节点已就绪 attempts=${i}"
        timing_log "wait_primary_ready attempts=${i} elapsed=$(( $(date +%s) - WAIT_PRIMARY_START_TS ))s"
        ha_log_event "primary_reachable node=${NODE_NAME:-unknown} primary_ip=${PARTNER_IP} attempts=${i} elapsed=$(( $(date +%s) - WAIT_PRIMARY_START_TS ))s"
        if [ -f "${CLONE_FAILURE_MARKER}" ]; then
            ha_log_event "standby_clone_retry_primary_reachable node=${NODE_NAME:-unknown} primary_ip=${PARTNER_IP} marker=${CLONE_FAILURE_MARKER} message=主库已恢复可达，备库开始重新尝试全量克隆"
        fi
        ha_log_ha_snapshot "standby_wait_primary_ready"
        break
    fi
    if [ $i -eq ${MAX_WAIT} ]; then
        ha_log_error "等待 Primary 节点超时 max_wait=${MAX_WAIT}s"
        exit 1
    fi
    if [ -f "${CLONE_FAILURE_MARKER}" ] && [ "${CLONE_FAILURE_WAIT_LOGGED}" != "true" ]; then
        ha_log_event "standby_clone_interrupted_waiting_primary node=${NODE_NAME:-unknown} primary_ip=${PARTNER_IP} marker=${CLONE_FAILURE_MARKER} message=当前备库全量克隆发生意外，正在等待主库启动"
        CLONE_FAILURE_WAIT_LOGGED=true
    fi
    ha_log_info "等待 Primary 进度 attempt=${i}/${MAX_WAIT}"
    sleep 1
done

# 额外等待几秒确保 Primary 完全就绪（repmgr 已注册）
sleep 3

# ---------------------------------------------------------------------------
# 步骤 2：从 Primary 克隆数据
# ---------------------------------------------------------------------------
# 如果数据目录已存在且有效，检查是否需要重新克隆
if [ -s "${PGDATA}/PG_VERSION" ]; then
    ha_log_info "数据目录已存在，检查复制状态"
    ha_log_ha_snapshot "standby_existing_data_detected"
    if [ "${LOCAL_DATA_ROLE_HINT}" = "primary" ]; then
        ha_log_warn "数据目录按旧主节点处理，尝试按 repmgr 标准方式执行 pg_rewind + node rejoin"
        REJOIN_REASON="old-primary-rejoin"

        if ensure_clean_shutdown_for_rejoin; then
            REJOIN_DRY_RUN_OK=true
            REJOIN_DRY_RUN_START_TS=$(date +%s)
            ha_log_event "old_primary_rejoin_dry_run_start node=${NODE_NAME:-unknown} target_primary=${PARTNER_IP}"
            if timed_postgres_capture_cmd "node_rejoin_dry_run" "repmgr node rejoin -f /etc/repmgr.conf \
                -d 'host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=5' \
                --force-rewind --config-files=postgresql.conf,pg_hba.conf --verbose --dry-run"; then
                timing_log "node_rejoin_dry_run elapsed=$(( $(date +%s) - REJOIN_DRY_RUN_START_TS ))s"
                ha_log_event "old_primary_rejoin_dry_run_success node=${NODE_NAME:-unknown} elapsed=$(( $(date +%s) - REJOIN_DRY_RUN_START_TS ))s"
            else
                REJOIN_DRY_RUN_OK=false
                timing_log "node_rejoin_dry_run_failed elapsed=$(( $(date +%s) - REJOIN_DRY_RUN_START_TS ))s"
                ha_log_warn "repmgr node rejoin --dry-run 失败，直接降级为全量克隆"
                ha_log_event "old_primary_rejoin_fallback node=${NODE_NAME:-unknown} reason=dry_run_failed elapsed=$(( $(date +%s) - REJOIN_DRY_RUN_START_TS ))s"
                print_rejoin_diagnostics
                stop_local_postgres_if_running
            fi

            if [ "${REJOIN_DRY_RUN_OK}" = "true" ] && [ "${goto_register}" != "true" ]; then
                REJOIN_START_TS=$(date +%s)
                ha_log_event "old_primary_rejoin_start node=${NODE_NAME:-unknown} target_primary=${PARTNER_IP}"
                ha_log_ha_snapshot "standby_before_node_rejoin"
                if timed_postgres_capture_cmd "node_rejoin" "repmgr node rejoin -f /etc/repmgr.conf \
                    -d 'host=${PARTNER_IP} port=${PGPORT:-5432} user=repmgr dbname=repmgr connect_timeout=5' \
                    --force-rewind --config-files=postgresql.conf,pg_hba.conf --verbose --no-wait"; then
                    timing_log "node_rejoin_command_return elapsed=$(( $(date +%s) - REJOIN_START_TS ))s"
                    ha_log_info "repmgr node rejoin 命令已返回，等待本地进入 streaming"
                    if wait_for_rejoin_streaming "${REJOIN_VERIFY_TIMEOUT}"; then
                        ha_log_info "pg_rewind 增量同步成功，跳过全量克隆"
                        timing_log "node_rejoin_success elapsed=$(( $(date +%s) - REJOIN_START_TS ))s verify_timeout=${REJOIN_VERIFY_TIMEOUT}s"
                        ha_log_event "old_primary_rejoin_success node=${NODE_NAME:-unknown} target_primary=${PARTNER_IP} elapsed=$(( $(date +%s) - REJOIN_START_TS ))s wal_receiver=streaming"
                        cp /etc/pg-ha/conf/postgresql.conf ${PGDATA}/postgresql.conf
                        cp /etc/pg-ha/conf/pg_hba.conf ${PGDATA}/pg_hba.conf
                        apply_runtime_postgres_config "${PGDATA}/postgresql.conf"
                        chown postgres:postgres ${PGDATA}/postgresql.conf ${PGDATA}/pg_hba.conf
                        su - postgres -c "pg_ctl -D ${PGDATA} reload" 2>/dev/null || true
                        log_local_standby_snapshot "node_rejoin_postcheck"
                        ha_log_ha_snapshot "standby_after_node_rejoin_success"
                        goto_register=true
                    else
                        REJOIN_VERIFY_RC=$?
                        timing_log "node_rejoin_verify_failed elapsed=$(( $(date +%s) - REJOIN_START_TS ))s verify_timeout=${REJOIN_VERIFY_TIMEOUT}s"
                        print_rejoin_diagnostics
                        if local_is_streaming_standby || remote_sees_local_replication; then
                            ha_log_warn "verify 超时后检测到本地已建立流复制，按成功处理"
                            log_local_standby_snapshot "node_rejoin_soft_success_after_verify"
                            goto_register=true
                        else
                            if [ "${REJOIN_VERIFY_RC}" = "2" ]; then
                                ha_log_warn "检测到 timeline/WAL 致命错误，快速降级为全量克隆"
                                ha_log_event "old_primary_rejoin_fallback node=${NODE_NAME:-unknown} reason=timeline_or_wal_error elapsed=$(( $(date +%s) - REJOIN_START_TS ))s"
                            else
                                ha_log_warn "node rejoin 校验失败，降级为全量克隆"
                                ha_log_event "old_primary_rejoin_fallback node=${NODE_NAME:-unknown} reason=verify_failed elapsed=$(( $(date +%s) - REJOIN_START_TS ))s"
                            fi
                            stop_local_postgres_if_running
                        fi
                    fi
                else
                    timing_log "node_rejoin_failed elapsed=$(( $(date +%s) - REJOIN_START_TS ))s"
                    print_rejoin_diagnostics

                    if local_is_streaming_standby || remote_sees_local_replication; then
                        ha_log_warn "rejoin 返回失败，但检测到本地已作为 Standby 建立流复制，按成功处理"
                        log_local_standby_snapshot "node_rejoin_soft_success"
                        goto_register=true
                    else
                        ha_log_warn "pg_rewind 失败，降级为全量克隆"
                        ha_log_event "old_primary_rejoin_fallback node=${NODE_NAME:-unknown} reason=rejoin_failed elapsed=$(( $(date +%s) - REJOIN_START_TS ))s"
                        stop_local_postgres_if_running
                    fi
                fi
            fi
        else
            ha_log_warn "旧主回归前的一致性准备失败，降级为全量克隆"
            ha_log_event "old_primary_rejoin_fallback node=${NODE_NAME:-unknown} reason=prepare_failed"
            stop_local_postgres_if_running
        fi
    else
        EXISTING_DATA_START_TS=$(date +%s)
        if timed_postgres_cmd "existing_data_local_pg_start" "pg_ctl -D ${PGDATA} start -w -t 10" 2>/dev/null; then
            :
        fi || true

        if su - postgres -c "pg_isready -q" 2>/dev/null; then
            IS_STANDBY=$(su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null || echo "error")
            timing_log "existing_data_role value=${IS_STANDBY:-unknown} elapsed=$(( $(date +%s) - EXISTING_DATA_START_TS ))s"
            if [ "${IS_STANDBY}" = "t" ]; then
                ha_log_info "数据目录已为 Standby 模式，验证 WAL streaming 是否正常"
                STREAMING=""
                for _i in $(seq 1 5); do
                    STREAMING=$(su - postgres -c \
                        "psql -tAc 'SELECT status FROM pg_stat_wal_receiver' 2>/dev/null" 2>/dev/null)
                    [ "${STREAMING}" = "streaming" ] && break
                    sleep 1
                done

                if [ "${STREAMING}" = "streaming" ]; then
                    ha_log_info "WAL streaming 正常，跳过克隆直接注册"
                    goto_register=true
                    timing_log "existing_data_streaming_ready elapsed=$(( $(date +%s) - EXISTING_DATA_START_TS ))s"
                else
                    ha_log_warn "WAL streaming 未能建立，将重新克隆"
                    stop_local_postgres_if_running
                fi
            else
                ha_log_warn "数据目录存在但当前不在恢复模式，将重新克隆"
                stop_local_postgres_if_running
            fi
        else
            ha_log_warn "数据目录存在但无法启动，将重新克隆"
            stop_local_postgres_if_running
        fi
    fi
fi

if [ "${goto_register}" != "true" ]; then
    ha_log_info "从 Primary 克隆数据 partner=${PARTNER_IP}"
    CLONE_START_TS=$(date +%s)
    CLONE_WORK_DIR="${HA_PGDATA_WORK_ROOT}/.pg-ha-clone-${RUN_ID}"
    CLONE_RETAINED_BASE="${HA_RETAINED_PGDATA_DIR:-/var/lib/postgresql/pg-ha-retained-before-clone}/${NODE_NAME:-unknown}"
    CLONE_RETAINED_DIR="${CLONE_RETAINED_BASE}/latest"
    CLONE_REPMGR_CONF="/tmp/repmgr-clone-${RUN_ID}.conf"
    ha_log_event "standby_clone_start node=${NODE_NAME:-unknown} source_primary=${PARTNER_IP} target_pgdata=${PGDATA} mode=safe_two_phase"
    ha_log_ha_snapshot "standby_before_clone"

    mkdir -p "${CLONE_RETAINED_BASE}"
    chown postgres:postgres "${CLONE_RETAINED_BASE}" 2>/dev/null || true
    prepare_clone_workdir "${CLONE_WORK_DIR}"
    prepare_clone_repmgr_config "${CLONE_WORK_DIR}" "${CLONE_REPMGR_CONF}"

    if timed_postgres_capture_cmd "standby_clone" "repmgr -h ${PARTNER_IP} -U repmgr -d repmgr -f '${CLONE_REPMGR_CONF}' standby clone --force --fast-checkpoint"; then
        :
    else
        CLONE_RC=$?
        record_clone_failure_marker "standby_clone_failed" "${CLONE_RC}" "${CLONE_WORK_DIR}"
        ha_log_event "standby_clone_failed node=${NODE_NAME:-unknown} source_primary=${PARTNER_IP} elapsed=$(( $(date +%s) - CLONE_START_TS ))s exit_code=${CLONE_RC} old_pgdata_preserved=yes clone_dir=${CLONE_WORK_DIR}"
        ha_log_event "standby_clone_interrupted_waiting_primary node=${NODE_NAME:-unknown} primary_ip=${PARTNER_IP} marker=${CLONE_FAILURE_MARKER} message=当前备库全量克隆发生意外，正在等待主库启动"
        rm -f "${CLONE_REPMGR_CONF}" 2>/dev/null || true
        exit ${CLONE_RC}
    fi
    rm -f "${CLONE_REPMGR_CONF}" 2>/dev/null || true
    ha_log_info "数据克隆完成"
    timing_log "standby_clone_total elapsed=$(( $(date +%s) - CLONE_START_TS ))s"
    CLONE_SIZE_BYTES=$(du -sb "${CLONE_WORK_DIR}" 2>/dev/null | awk '{print $1}' || echo unknown)
    CLONE_SIZE_HUMAN=$(du -sh "${CLONE_WORK_DIR}" 2>/dev/null | awk '{print $1}' || echo unknown)
    ha_log_event "standby_clone_done node=${NODE_NAME:-unknown} source_primary=${PARTNER_IP} elapsed=$(( $(date +%s) - CLONE_START_TS ))s size_bytes=${CLONE_SIZE_BYTES:-unknown} size_human=${CLONE_SIZE_HUMAN:-unknown} old_pgdata_preserved=yes"
    ha_log_ha_snapshot "standby_after_clone"

    # 应用自定义配置（先写入新 clone，再激活到正式 PGDATA）
    cp /etc/pg-ha/conf/postgresql.conf ${CLONE_WORK_DIR}/postgresql.conf
    cp /etc/pg-ha/conf/pg_hba.conf ${CLONE_WORK_DIR}/pg_hba.conf
    apply_runtime_postgres_config "${CLONE_WORK_DIR}/postgresql.conf"
    chown postgres:postgres ${CLONE_WORK_DIR}/postgresql.conf ${CLONE_WORK_DIR}/pg_hba.conf

    activate_cloned_pgdata "${CLONE_WORK_DIR}" "${CLONE_RETAINED_DIR}"

    # ---------------------------------------------------------------------------
    # 步骤 3：启动 Standby PostgreSQL
    # ---------------------------------------------------------------------------
    ha_log_info "启动 PostgreSQL"
    mkdir -p ${PGDATA}/log && chown postgres:postgres ${PGDATA}/log
    timed_postgres_cmd "standby_pg_start" "pg_ctl -D ${PGDATA} -l ${PGDATA}/log/startup.log start -w"

    # 等待 PG 就绪
    READY_WAIT_START_TS=$(date +%s)
    for i in $(seq 1 30); do
        if su - postgres -c "pg_isready -q"; then
            ha_log_info "PostgreSQL 已就绪 attempts=${i}"
            timing_log "standby_pg_ready attempts=${i} elapsed=$(( $(date +%s) - READY_WAIT_START_TS ))s"
            ha_log_event "postgres_ready node=${NODE_NAME:-unknown} role=standby attempts=${i} elapsed=$(( $(date +%s) - READY_WAIT_START_TS ))s"
            log_local_standby_snapshot "standby_pg_ready"
            ha_log_ha_snapshot "standby_pg_ready"
            break
        fi
        if [ $i -eq 30 ]; then
            ha_log_error "PostgreSQL 启动超时"
            exit 1
        fi
        sleep 1
    done
fi

# ---------------------------------------------------------------------------
# 步骤 4：注册 Standby 节点到 repmgr
# ---------------------------------------------------------------------------
ha_log_info "注册 Standby 节点"
ha_log_ha_snapshot "standby_before_register"
timed_postgres_cmd "standby_register" "repmgr -f /etc/repmgr.conf standby register --force --wait-sync=30"
ha_log_info "Standby 节点注册完成"
ha_log_event "repmgr_standby_registered node=${NODE_NAME:-unknown} node_id=${NODE_ID:-unknown} upstream=${PARTNER_IP}"

REGISTER_SYNC_START_TS=$(date +%s)
EXPECTED_UPSTREAM_NODE_ID=""
if [ "${NODE_ID:-}" = "1" ]; then
    EXPECTED_UPSTREAM_NODE_ID="2"
elif [ "${NODE_ID:-}" = "2" ]; then
    EXPECTED_UPSTREAM_NODE_ID="1"
fi
for i in $(seq 1 30); do
    LOCAL_REPMGR_RECORD=$(su - postgres -c "psql -p ${PGPORT} -d repmgr -tAc \"SELECT concat(type, '|', COALESCE(upstream_node_id::text, ''), '|', active::text) FROM repmgr.nodes WHERE node_id = ${NODE_ID}\"" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "${EXPECTED_UPSTREAM_NODE_ID}" ] && [ "${LOCAL_REPMGR_RECORD}" = "standby|${EXPECTED_UPSTREAM_NODE_ID}|true" ]; then
        ha_log_info "standby_register_local_sync_ready record=${LOCAL_REPMGR_RECORD} attempts=${i}"
        timing_log "standby_register_local_sync elapsed=$(( $(date +%s) - REGISTER_SYNC_START_TS ))s attempts=${i}"
        break
    fi
    if [ -z "${EXPECTED_UPSTREAM_NODE_ID}" ] && echo "${LOCAL_REPMGR_RECORD}" | grep -q '^standby|'; then
        ha_log_info "standby_register_local_sync_ready record=${LOCAL_REPMGR_RECORD} attempts=${i}"
        timing_log "standby_register_local_sync elapsed=$(( $(date +%s) - REGISTER_SYNC_START_TS ))s attempts=${i}"
        break
    fi
    if [ "${i}" -eq 30 ]; then
        ha_log_warn "standby_register_local_sync_timeout last_record=${LOCAL_REPMGR_RECORD:-none} elapsed=$(( $(date +%s) - REGISTER_SYNC_START_TS ))s"
        timing_log "standby_register_local_sync_timeout elapsed=$(( $(date +%s) - REGISTER_SYNC_START_TS ))s last_record=${LOCAL_REPMGR_RECORD:-none}"
        break
    fi
    sleep 1
done

ha_log_ha_snapshot "standby_after_register"

# 查看集群状态
ha_log_capture_allow_fail "INFO" "standby_cluster_show" "su - postgres -c \"repmgr -f /etc/repmgr.conf cluster show\"" || true

# ---------------------------------------------------------------------------
# 步骤 5：启动 repmgrd 守护进程
# ---------------------------------------------------------------------------
# 清理残留 PID 文件：kill -9 / docker kill 等非正常关闭不会触发 SIGTERM 处理器，
# 导致 /tmp/repmgrd.pid 遗留，下次启动时 repmgrd 误判为已运行而拒绝启动
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
    timed_postgres_cmd "standby_repmgrd_start" "repmgrd -f /etc/repmgr.conf --pid-file=/tmp/repmgrd.pid --daemonize"
    ha_log_info "repmgrd 已启动"
    ha_log_event "repmgrd_started node=${NODE_NAME:-unknown} role=standby"
else
    ha_log_info "跳过 repmgrd 启动，复用现有进程"
fi
/usr/local/bin/wal-receiver-control.sh restart || true
ha_log_info "standby_wal_receiver_started"
ha_log_ha_snapshot "standby_after_wal_receiver"
ha_log_capture_allow_fail "INFO" "standby_runtime_snapshot" "su - postgres -c \"psql -x -c \\\"SELECT pg_is_in_recovery() AS in_recovery\\\" -c \\\"SELECT status, sender_host, sender_port, latest_end_lsn, latest_end_time FROM pg_stat_wal_receiver\\\"\"" || true

if [ -n "${REJOIN_REASON}" ]; then
    /usr/local/bin/wecom-notify.sh \
        "node_rejoin" \
        "1" \
        "$(date '+%F %T %z')" \
        "node \"${NODE_NAME:-unknown}\" 已重新加入集群并以 Standby 跟随 \"${PARTNER_IP}\"" || true
fi

ha_log_section "Standby 节点初始化完成"
ha_log_event "standby_available node=${NODE_NAME:-unknown} upstream=${PARTNER_IP} total_elapsed=$(( $(date +%s) - SCRIPT_START_TS ))s"
timing_log "script_complete role=standby total_elapsed=$(( $(date +%s) - SCRIPT_START_TS ))s rejoin_reason=${REJOIN_REASON:-none}"
clear_clone_failure_marker "standby_available"
ha_log_ha_snapshot "standby_setup_complete"
