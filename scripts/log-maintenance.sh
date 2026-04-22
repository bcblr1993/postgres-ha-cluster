#!/bin/bash
# =============================================================================
# PostgreSQL HA 日志维护脚本
# 用途：
#   1. 对 /var/log/repmgr 下的运行日志做按大小 copytruncate 轮转
#   2. 清理 PGDATA/log 下历史 PostgreSQL 日志文件
#   3. 控制 startup.log 等活跃日志体积，防止长期运行占满磁盘
# =============================================================================
set -euo pipefail

. /usr/local/bin/ha-log.sh

PGDATA=${PGDATA:-/var/lib/postgresql/data}
HA_LOG_ROOT=${HA_LOG_ROOT:-/var/log/repmgr}
HA_LOG_MAX_SIZE_MB=${HA_LOG_MAX_SIZE_MB:-20}
HA_LOG_KEEP_FILES=${HA_LOG_KEEP_FILES:-5}
HA_PG_LOG_KEEP_FILES=${HA_PG_LOG_KEEP_FILES:-10}

RUN_ID="log-maintenance-$(date +%s)-$$"
ha_log_init "log-maintenance" "${RUN_ID}"

MAX_BYTES=$((HA_LOG_MAX_SIZE_MB * 1024 * 1024))

file_size_bytes() {
    local file="$1"
    if [ ! -f "${file}" ]; then
        echo 0
        return
    fi
    wc -c < "${file}" | tr -d '[:space:]'
}

copytruncate_rotate() {
    local file="$1"
    local keep_files="$2"
    local size

    [ -f "${file}" ] || return 0

    size=$(file_size_bytes "${file}")
    if [ "${size}" -lt "${MAX_BYTES}" ]; then
        return 0
    fi

    local i
    for ((i=keep_files; i>=1; i--)); do
        if [ -f "${file}.${i}" ]; then
            if [ "${i}" -eq "${keep_files}" ]; then
                rm -f "${file}.${i}"
            else
                mv -f "${file}.${i}" "${file}.$((i + 1))"
            fi
        fi
    done

    cp -p "${file}" "${file}.1"
    : > "${file}"
    ha_log_warn "rotate_copytruncate file=${file} size_bytes=${size} keep_files=${keep_files}"
}

prune_matching_files() {
    local dir="$1"
    local pattern="$2"
    local keep_files="$3"

    [ -d "${dir}" ] || return 0

    mapfile -t files < <(find "${dir}" -maxdepth 1 -type f -name "${pattern}" -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
    local total="${#files[@]}"

    if [ "${total}" -le "${keep_files}" ]; then
        return 0
    fi

    local idx
    for ((idx=keep_files; idx<total; idx++)); do
        rm -f "${files[$idx]}"
        ha_log_warn "prune_file file=${files[$idx]} pattern=${pattern} keep_files=${keep_files}"
    done
}

maintain_repmgr_logs() {
    local file
    [ -d "${HA_LOG_ROOT}" ] || return 0

    while IFS= read -r file; do
        copytruncate_rotate "${file}" "${HA_LOG_KEEP_FILES}"
    done < <(find "${HA_LOG_ROOT}" -maxdepth 1 -type f -name '*.log' ! -name '*.log.[0-9]*' | sort)
}

maintain_pg_logs() {
    local pg_log_dir="${PGDATA}/log"
    [ -d "${pg_log_dir}" ] || return 0

    if [ -f "${pg_log_dir}/startup.log" ]; then
        copytruncate_rotate "${pg_log_dir}/startup.log" "${HA_LOG_KEEP_FILES}"
    fi

    prune_matching_files "${pg_log_dir}" 'postgresql-*.log' "${HA_PG_LOG_KEEP_FILES}"
    prune_matching_files "${pg_log_dir}" 'startup.log.[0-9]*' "${HA_LOG_KEEP_FILES}"
}

ha_log_info "log_maintenance_start max_size_mb=${HA_LOG_MAX_SIZE_MB} keep_files=${HA_LOG_KEEP_FILES} pg_keep_files=${HA_PG_LOG_KEEP_FILES}"
maintain_repmgr_logs
maintain_pg_logs
ha_log_info "log_maintenance_complete"
