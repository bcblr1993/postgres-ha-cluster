#!/bin/bash
set -euo pipefail

. /usr/local/bin/ha-log.sh

PGDATA=${PGDATA:-/var/lib/postgresql/data}
WAL_ARCHIVE_ENABLED=${WAL_ARCHIVE_ENABLED:-true}
WAL_ARCHIVE_DIR=${WAL_ARCHIVE_DIR:-/var/lib/postgresql/wal-archive}
RUN_ID="archive-promote-wal-$(date +%s)-$$-${NODE_NAME:-unknown}"
ha_log_init "archive-promote-wal" "${RUN_ID}"

if [ "${WAL_ARCHIVE_ENABLED}" != "true" ]; then
    ha_log_info "promote_wal_archive_skip reason=disabled"
    exit 0
fi

mkdir -p "${WAL_ARCHIVE_DIR}"
chown postgres:postgres "${WAL_ARCHIVE_DIR}" 2>/dev/null || true
chmod 700 "${WAL_ARCHIVE_DIR}" 2>/dev/null || true

current_tli=$(su - postgres -c "psql -tAc \"SELECT lpad(to_hex(timeline_id), 8, '0') FROM pg_control_checkpoint()\"" 2>/dev/null | tr -d '[:space:]' || true)
if [ -z "${current_tli}" ]; then
    ha_log_warn "promote_wal_archive_skip reason=missing_current_timeline"
    exit 0
fi
ha_log_capture_allow_fail "INFO" "promote_wal_pg_wal_before" "ls -1t '${PGDATA}/pg_wal' | head -n 40" || true
ha_log_capture_allow_fail "INFO" "promote_wal_archive_before" "ls -1t '${WAL_ARCHIVE_DIR}' | head -n 40" || true

copied=0
skipped=0

copy_candidate() {
    local source_file="$1"
    local base_name
    base_name=$(basename "${source_file}")

    case "${base_name}" in
        *.history)
            ;;
        ????????????????????????)
            if [ "${base_name:0:8}" = "${current_tli}" ]; then
                skipped=$((skipped + 1))
                return 0
            fi
            ;;
        ????????????????????????.partial)
            if [ "${base_name:0:8}" = "${current_tli}" ]; then
                skipped=$((skipped + 1))
                return 0
            fi
            ;;
        *)
            skipped=$((skipped + 1))
            return 0
            ;;
    esac

    if [ -f "${WAL_ARCHIVE_DIR}/${base_name}" ]; then
        skipped=$((skipped + 1))
        return 0
    fi

    cp "${source_file}" "${WAL_ARCHIVE_DIR}/${base_name}"
    chown postgres:postgres "${WAL_ARCHIVE_DIR}/${base_name}" 2>/dev/null || true
    copied=$((copied + 1))
    ha_log_info "promote_wal_archived file=${base_name}"
}

for wal_file in "${PGDATA}/pg_wal"/*; do
    [ -e "${wal_file}" ] || continue
    copy_candidate "${wal_file}"
done

ha_log_info "promote_wal_archive_complete current_tli=${current_tli} copied=${copied} skipped=${skipped}"
ha_log_capture_allow_fail "INFO" "promote_wal_archive_after" "ls -1t '${WAL_ARCHIVE_DIR}' | head -n 40" || true
