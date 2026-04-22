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
    local ts line
    ts=$(date '+%F %T %z')
    line="[${ts}][${level}][${HA_LOG_COMPONENT}][${HA_LOG_RUN_ID}] ${message}"
    printf '%s\n' "${line}" | tee -a "${HA_LOG_COMPONENT_FILE}" >> "${HA_LOG_MASTER_FILE}"
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
