#!/bin/bash
# =============================================================================
# PostgreSQL HA WAL 归档目录维护脚本
# 用途：
#   1. 在 WAL 归档目录超过阈值时，按时间顺序清理最旧的已归档完整 WAL 段
#   2. 保留 timeline history 和 partial 文件，避免影响最近恢复/追赶
#   3. 通过目录锁避免主备节点并发清理同一归档目录
# =============================================================================
set -euo pipefail

. /usr/local/bin/ha-log.sh

WAL_ARCHIVE_ENABLED=${WAL_ARCHIVE_ENABLED:-false}
WAL_ARCHIVE_DIR=${WAL_ARCHIVE_DIR:-/var/lib/postgresql/wal-archive}
WAL_ARCHIVE_CLEANUP_ENABLED=${WAL_ARCHIVE_CLEANUP_ENABLED:-false}
WAL_ARCHIVE_MAX_SIZE_MB=${WAL_ARCHIVE_MAX_SIZE_MB:-10240}
WAL_ARCHIVE_MIN_KEEP_SEGMENTS=${WAL_ARCHIVE_MIN_KEEP_SEGMENTS:-64}
WAL_ARCHIVE_LOCK_DIR="${WAL_ARCHIVE_DIR}/.cleanup.lock"

RUN_ID="wal-archive-maintenance-$(date +%s)-$$"
ha_log_init "wal-archive-maintenance" "${RUN_ID}"

SEGMENT_SIZE_BYTES=$((16 * 1024 * 1024))
MAX_BYTES=$((WAL_ARCHIVE_MAX_SIZE_MB * 1024 * 1024))

release_lock() {
    rmdir "${WAL_ARCHIVE_LOCK_DIR}" 2>/dev/null || true
}

archive_total_bytes() {
    local dir="$1"
    find "${dir}" -maxdepth 1 -type f -print0 2>/dev/null | xargs -0r wc -c | awk 'END {print $1 + 0}'
}

list_full_segments_oldest_first() {
    local dir="$1"
    find "${dir}" -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null \
        | awk '
            {
                name=$2
                if (length(name) == 24 && name ~ /^[0-9A-F]+$/) {
                    print $0
                }
            }
        ' \
        | sort -n \
        | awk '{print $2}'
}

if [ "${WAL_ARCHIVE_ENABLED}" != "true" ]; then
    ha_log_info "wal_archive_cleanup_skip reason=archive_disabled"
    exit 0
fi

if [ "${WAL_ARCHIVE_CLEANUP_ENABLED}" != "true" ]; then
    ha_log_info "wal_archive_cleanup_skip reason=cleanup_disabled max_size_mb=${WAL_ARCHIVE_MAX_SIZE_MB} min_keep_segments=${WAL_ARCHIVE_MIN_KEEP_SEGMENTS}"
    exit 0
fi

if [ ! -d "${WAL_ARCHIVE_DIR}" ]; then
    ha_log_info "wal_archive_cleanup_skip reason=missing_archive_dir path=${WAL_ARCHIVE_DIR}"
    exit 0
fi

if ! mkdir "${WAL_ARCHIVE_LOCK_DIR}" 2>/dev/null; then
    ha_log_info "wal_archive_cleanup_skip reason=lock_busy lock_dir=${WAL_ARCHIVE_LOCK_DIR}"
    exit 0
fi
trap release_lock EXIT

current_bytes=$(archive_total_bytes "${WAL_ARCHIVE_DIR}")
mapfile -t full_segments < <(list_full_segments_oldest_first "${WAL_ARCHIVE_DIR}")
full_count=${#full_segments[@]}

ha_log_info "wal_archive_cleanup_start path=${WAL_ARCHIVE_DIR} current_bytes=${current_bytes} max_bytes=${MAX_BYTES} full_segments=${full_count} min_keep_segments=${WAL_ARCHIVE_MIN_KEEP_SEGMENTS}"

if [ "${current_bytes}" -le "${MAX_BYTES}" ]; then
    ha_log_info "wal_archive_cleanup_skip reason=below_threshold current_bytes=${current_bytes} max_bytes=${MAX_BYTES}"
    exit 0
fi

removed_count=0
removed_bytes=0

for seg in "${full_segments[@]}"; do
    remaining_full=$((full_count - removed_count))
    if [ "${remaining_full}" -le "${WAL_ARCHIVE_MIN_KEEP_SEGMENTS}" ]; then
        ha_log_warn "wal_archive_cleanup_stop reason=min_keep_reached remaining_full=${remaining_full} min_keep_segments=${WAL_ARCHIVE_MIN_KEEP_SEGMENTS}"
        break
    fi

    if [ "${current_bytes}" -le "${MAX_BYTES}" ]; then
        break
    fi

    seg_path="${WAL_ARCHIVE_DIR}/${seg}"
    [ -f "${seg_path}" ] || continue

    seg_bytes=$(wc -c < "${seg_path}" | tr -d '[:space:]')
    rm -f "${seg_path}"
    removed_count=$((removed_count + 1))
    removed_bytes=$((removed_bytes + seg_bytes))
    current_bytes=$((current_bytes - seg_bytes))
    ha_log_warn "wal_archive_segment_pruned file=${seg} bytes=${seg_bytes} current_bytes=${current_bytes}"
done

ha_log_info "wal_archive_cleanup_complete removed_count=${removed_count} removed_bytes=${removed_bytes} current_bytes=${current_bytes} max_bytes=${MAX_BYTES}"
