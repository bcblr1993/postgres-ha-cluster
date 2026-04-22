#!/bin/bash
set -euo pipefail

. /usr/local/bin/ha-log.sh

ARCHIVE_DIR=${1:?archive dir required}
WAL_FILE=${2:?wal file required}
DEST_FILE=${3:?dest file required}

RUN_ID="restore-wal-$(date +%s)-$$"
ha_log_init "restore-wal" "${RUN_ID}"

copy_wal_file() {
    local source_file="$1"
    cp "${source_file}" "${DEST_FILE}"
    ha_log_info "restore_wal_success wal_file=${WAL_FILE} source=${source_file} dest=${DEST_FILE}"
}

if [ -f "${ARCHIVE_DIR}/${WAL_FILE}" ]; then
    copy_wal_file "${ARCHIVE_DIR}/${WAL_FILE}"
    exit 0
fi

if [ -f "${ARCHIVE_DIR}/${WAL_FILE}.partial" ]; then
    copy_wal_file "${ARCHIVE_DIR}/${WAL_FILE}.partial"
    exit 0
fi

ha_log_warn "restore_wal_miss wal_file=${WAL_FILE} archive_dir=${ARCHIVE_DIR}"
exit 1
