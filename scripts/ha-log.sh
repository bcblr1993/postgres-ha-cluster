#!/bin/bash
# =============================================================================
# PostgreSQL HA 通用日志函数
# 用途：为各脚本提供统一的控制台 + 文件日志输出
# =============================================================================

HA_LOG_ROOT=${HA_LOG_ROOT:-/var/log/repmgr}
HA_LOG_COMPONENT=${HA_LOG_COMPONENT:-runtime}
HA_LOG_RUN_ID=${HA_LOG_RUN_ID:-"${HA_LOG_COMPONENT}-$$"}
HA_LOG_COMPONENT_FILE=""
HA_LOG_MASTER_FILE=""

ha_log_init() {
    HA_LOG_COMPONENT=${1:-${HA_LOG_COMPONENT:-runtime}}
    HA_LOG_RUN_ID=${2:-${HA_LOG_RUN_ID:-"${HA_LOG_COMPONENT}-$$"}}
    HA_LOG_ROOT=${HA_LOG_ROOT:-/var/log/repmgr}
    HA_LOG_COMPONENT_FILE="${HA_LOG_ROOT}/${HA_LOG_COMPONENT}.log"
    HA_LOG_MASTER_FILE="${HA_LOG_ROOT}/ha-runtime.log"

    mkdir -p "${HA_LOG_ROOT}"
    touch "${HA_LOG_COMPONENT_FILE}" "${HA_LOG_MASTER_FILE}"
    chmod 664 "${HA_LOG_COMPONENT_FILE}" "${HA_LOG_MASTER_FILE}" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ] && id postgres >/dev/null 2>&1; then
        chown postgres:postgres "${HA_LOG_COMPONENT_FILE}" "${HA_LOG_MASTER_FILE}" 2>/dev/null || true
    fi
}

ha_log_write() {
    local level="$1"
    shift
    local message="$*"
    local ts line docker_stdout self_stdout init_stdout
    ts=$(date '+%F %T %z')
    line="[${ts}][${level}][${HA_LOG_COMPONENT}][${HA_LOG_RUN_ID}] ${message}"
    printf '%s\n' "${line}" >> "${HA_LOG_COMPONENT_FILE}"
    printf '%s\n' "${line}" >> "${HA_LOG_MASTER_FILE}"

    case "${level}" in
        EVENT|SECTION|WARN|ERROR)
            ;;
        *)
            return 0
            ;;
    esac

    printf '%s\n' "${line}"

    # Some hooks are executed by daemon children whose stdout is not Docker's
    # stdout. Mirror those lines to PID 1 so `docker logs -f` still sees them.
    docker_stdout="/proc/1/fd/1"
    if [ -w "${docker_stdout}" ]; then
        self_stdout=$(readlink "/proc/$$/fd/1" 2>/dev/null || true)
        init_stdout=$(readlink "${docker_stdout}" 2>/dev/null || true)
        if [ -n "${self_stdout}" ] && [ -n "${init_stdout}" ] && [ "${self_stdout}" != "${init_stdout}" ]; then
            printf '%s\n' "${line}" >> "${docker_stdout}" 2>/dev/null || true
        fi
    fi
}

ha_log() {
    local level="$1"
    shift
    ha_log_write "${level}" "$*"
}

ha_log_info() {
    ha_log "INFO" "$*"
}

ha_log_warn() {
    ha_log "WARN" "$*"
}

ha_log_error() {
    ha_log "ERROR" "$*"
}

ha_log_timing() {
    ha_log "TIMING" "$*"
}

ha_log_section() {
    ha_log "SECTION" "$*"
}

ha_log_event() {
    ha_log "EVENT" "$*"
}

ha_log_tail_file() {
    local level="$1"
    local label="$2"
    local file_path="$3"
    local line_count="${4:-40}"

    if [ ! -f "${file_path}" ]; then
        ha_log_write "${level}" "${label} file_missing=${file_path}"
        return 1
    fi

    while IFS= read -r line; do
        ha_log_write "${level}" "${label} file=${file_path} line=${line}"
    done < <(tail -n "${line_count}" "${file_path}" 2>/dev/null || true)
}

ha_log_capture_allow_fail() {
    local level="$1"
    local label="$2"
    local cmd="$3"
    local tmp_file start_ts end_ts elapsed rc

    tmp_file=$(mktemp)
    start_ts=$(date +%s)
    ha_log_info "command_capture_start label=${label} cmd=${cmd}"

    set +e
    bash -lc "${cmd}" >"${tmp_file}" 2>&1
    rc=$?
    set -e

    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    ha_log_write "${level}" "command_capture_end label=${label} elapsed=${elapsed}s exit_code=${rc}"

    while IFS= read -r line; do
        ha_log_write "${level}" "${label} output=${line}"
    done < "${tmp_file}"

    rm -f "${tmp_file}"
    return ${rc}
}

ha_log_capture() {
    local level="$1"
    local label="$2"
    local cmd="$3"

    ha_log_capture_allow_fail "${level}" "${label}" "${cmd}"
}

ha_pg_cmd() {
    local cmd="$1"
    if [ "$(id -un 2>/dev/null || true)" = "postgres" ]; then
        bash -lc "${cmd}"
    else
        su - postgres -c "${cmd}"
    fi
}

ha_pg_cmd_string() {
    local cmd="$1"
    if [ "$(id -un 2>/dev/null || true)" = "postgres" ]; then
        printf 'bash -lc %q' "${cmd}"
    else
        printf 'su - postgres -c %q' "${cmd}"
    fi
}

ha_log_ha_snapshot() {
    local label="${1:-ha_snapshot}"
    local vip="${NODE_VIP:-}"
    local node_ip="${NODE_IP:-}"
    local pgport="${PGPORT:-${PG_PORT:-5432}}"
    local role="unknown"
    local pg_ready="no"
    local vip_present="no"
    local keepalived_state="stopped"

    if pg_isready -q -p "${pgport}" 2>/dev/null; then
        pg_ready="yes"
        role=$(ha_pg_cmd "psql -p ${pgport} -tAc \"SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END\"" 2>/dev/null | tr -d '[:space:]' || true)
    fi

    if [ -n "${vip}" ] && ip addr show 2>/dev/null | grep -qw "${vip}"; then
        vip_present="yes"
    fi

    if pgrep -x keepalived >/dev/null 2>&1; then
        keepalived_state="running"
    fi

    ha_log_info "${label} summary node=${NODE_NAME:-unknown} node_ip=${node_ip:-unknown} partner_ip=${PARTNER_IP:-unknown} vip=${vip:-unset} vip_present=${vip_present} pg_ready=${pg_ready} local_role=${role:-unknown} keepalived=${keepalived_state}"

    if [ -n "${vip}" ] || [ -n "${node_ip}" ]; then
        ha_log_capture_allow_fail "INFO" "${label}_ip_addr" "ip -o addr show | grep -E '${vip:-__no_vip__}|${node_ip:-__no_node_ip__}'" || true
    else
        ha_log_capture_allow_fail "INFO" "${label}_ip_addr" "ip -o addr show" || true
    fi

    if [ "${pg_ready}" = "yes" ]; then
        ha_log_capture_allow_fail "INFO" "${label}_wal_lsn" "$(ha_pg_cmd_string "psql -p ${pgport} -x -c \"SELECT pg_is_in_recovery() AS in_recovery, CASE WHEN pg_is_in_recovery() THEN NULL ELSE pg_current_wal_lsn() END AS current_wal_lsn, pg_last_wal_receive_lsn() AS last_receive_lsn, pg_last_wal_replay_lsn() AS last_replay_lsn\"")" || true
        ha_log_capture_allow_fail "INFO" "${label}_pg_stat_replication" "$(ha_pg_cmd_string "psql -p ${pgport} -x -c \"SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication ORDER BY application_name\"")" || true
        ha_log_capture_allow_fail "INFO" "${label}_pg_stat_wal_receiver" "$(ha_pg_cmd_string "psql -p ${pgport} -x -c \"SELECT status, sender_host, sender_port, latest_end_lsn, latest_end_time FROM pg_stat_wal_receiver\"")" || true
    fi
}

ha_log_state_change() {
    local state_file="$1"
    local label="$2"
    local current_state="$3"
    local last_state=""

    if [ -f "${state_file}" ]; then
        last_state=$(cat "${state_file}" 2>/dev/null || true)
    fi

    if [ "${current_state}" != "${last_state}" ]; then
        ha_log_info "${label} from=${last_state:-unknown} to=${current_state}"
        printf '%s' "${current_state}" > "${state_file}"
        return 0
    fi

    return 1
}

ha_run_timed() {
    local label="$1"
    local cmd="$2"
    local start_ts end_ts elapsed rc
    start_ts=$(date +%s)
    ha_log_info "command_start label=${label} cmd=${cmd}"
    bash -lc "${cmd}"
    rc=$?
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    ha_log_timing "${label} elapsed=${elapsed}s exit_code=${rc}"
    return ${rc}
}

ha_run_timed_allow_fail() {
    local label="$1"
    local cmd="$2"
    local start_ts end_ts elapsed rc
    start_ts=$(date +%s)
    ha_log_info "command_start label=${label} cmd=${cmd}"
    set +e
    bash -lc "${cmd}"
    rc=$?
    set -e
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    if [ ${rc} -eq 0 ]; then
        ha_log_timing "${label} elapsed=${elapsed}s exit_code=${rc}"
    else
        ha_log_warn "${label} elapsed=${elapsed}s exit_code=${rc}"
    fi
    return ${rc}
}
