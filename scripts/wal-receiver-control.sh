#!/bin/bash
set -euo pipefail

. /usr/local/bin/ha-log.sh

PID_FILE="/tmp/pg_receivewal.pid"
LOG_FILE="/var/log/repmgr/pg-receivewal.log"
RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"

if [ -f "${RUNTIME_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV_FILE}"
fi

PGPORT=${PGPORT:-5432}
PARTNER_IP=${PARTNER_IP:-}
WAL_ARCHIVE_ENABLED=${WAL_ARCHIVE_ENABLED:-false}
WAL_RECEIVER_ENABLED=${WAL_RECEIVER_ENABLED:-false}
WAL_ARCHIVE_DIR=${WAL_ARCHIVE_DIR:-/var/lib/postgresql/wal-archive}
NODE_NAME=${NODE_NAME:-unknown}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-repmgr123}
WAL_RECEIVER_SLOT_NAME=${WAL_RECEIVER_SLOT_NAME:-"pgreceivewal_${NODE_NAME//[^a-zA-Z0-9_]/_}"}
WAL_RECEIVER_APP_NAME=${WAL_RECEIVER_APP_NAME:-"${NODE_NAME}_pgreceivewal"}
WAL_RECEIVER_STATUS_INTERVAL=${WAL_RECEIVER_STATUS_INTERVAL:-2}
RUN_ID="wal-receiver-$(date +%s)-$$-${NODE_NAME}"
ha_log_init "wal-receiver-control" "${RUN_ID}"

conninfo() {
    printf "host=%s port=%s user=repmgr dbname=replication application_name=%s connect_timeout=2" \
        "${PARTNER_IP}" "${PGPORT}" "${WAL_RECEIVER_APP_NAME}"
}

is_running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

log_archive_snapshot() {
    ha_log_capture_allow_fail "INFO" "wal_archive_snapshot" "ls -1t '${WAL_ARCHIVE_DIR}' | head -n 20" || true
}

start_receiver() {
    if [ "${WAL_ARCHIVE_ENABLED}" != "true" ] || [ "${WAL_RECEIVER_ENABLED}" != "true" ]; then
        ha_log_info "wal_receiver_skip reason=disabled archive_enabled=${WAL_ARCHIVE_ENABLED} receiver_enabled=${WAL_RECEIVER_ENABLED}"
        return 0
    fi

    if [ -z "${PARTNER_IP}" ]; then
        ha_log_warn "wal_receiver_skip reason=missing_partner_ip"
        return 0
    fi

    if is_running; then
        ha_log_info "wal_receiver_already_running pid=$(cat "${PID_FILE}") slot=${WAL_RECEIVER_SLOT_NAME}"
        return 0
    fi

    mkdir -p "${WAL_ARCHIVE_DIR}"
    touch "${LOG_FILE}"
    chown postgres:postgres "${WAL_ARCHIVE_DIR}" "${LOG_FILE}" 2>/dev/null || true
    chmod 664 "${LOG_FILE}" 2>/dev/null || true

    ha_log_info "wal_receiver_start target=${PARTNER_IP}:${PGPORT} slot=${WAL_RECEIVER_SLOT_NAME} archive_dir=${WAL_ARCHIVE_DIR}"
    su - postgres -c "PGPASSWORD='${REPMGR_PASSWORD}' pg_receivewal --directory='${WAL_ARCHIVE_DIR}' --slot='${WAL_RECEIVER_SLOT_NAME}' --create-slot --if-not-exists --dbname='$(conninfo)'" >> "${LOG_FILE}" 2>&1 || true

    su - postgres -c "nohup env PGPASSWORD='${REPMGR_PASSWORD}' pg_receivewal --directory='${WAL_ARCHIVE_DIR}' --slot='${WAL_RECEIVER_SLOT_NAME}' --status-interval='${WAL_RECEIVER_STATUS_INTERVAL}' --synchronous --verbose --dbname='$(conninfo)' >> '${LOG_FILE}' 2>&1 & echo \$! > '${PID_FILE}'"
    sleep 1

    if is_running; then
        ha_log_info "wal_receiver_started pid=$(cat "${PID_FILE}") slot=${WAL_RECEIVER_SLOT_NAME}"
        log_archive_snapshot
        ha_log_tail_file "INFO" "wal_receiver_start_tail" "${LOG_FILE}" 20 || true
        return 0
    fi

    ha_log_error "wal_receiver_start_failed slot=${WAL_RECEIVER_SLOT_NAME} log_file=${LOG_FILE}"
    ha_log_tail_file "ERROR" "wal_receiver_failure_tail" "${LOG_FILE}" 80 || true
    return 1
}

stop_receiver() {
    if is_running; then
        ha_log_info "wal_receiver_stop pid=$(cat "${PID_FILE}")"
        kill "$(cat "${PID_FILE}")" 2>/dev/null || true
        sleep 1
    else
        ha_log_info "wal_receiver_stop_skip reason=not_running"
    fi
    rm -f "${PID_FILE}"
    pkill -f "pg_receivewal.*${WAL_RECEIVER_SLOT_NAME}" 2>/dev/null || true
    ha_log_info "wal_receiver_stopped slot=${WAL_RECEIVER_SLOT_NAME}"
    log_archive_snapshot
}

case "${1:-}" in
    start)
        start_receiver
        ;;
    stop)
        stop_receiver
        ;;
    restart)
        stop_receiver
        start_receiver
        ;;
    status)
        if is_running; then
            ha_log_info "wal_receiver_status running=true pid=$(cat "${PID_FILE}") slot=${WAL_RECEIVER_SLOT_NAME}"
            log_archive_snapshot
            exit 0
        fi
        ha_log_warn "wal_receiver_status running=false slot=${WAL_RECEIVER_SLOT_NAME}"
        ha_log_tail_file "WARN" "wal_receiver_status_tail" "${LOG_FILE}" 40 || true
        exit 1
        ;;
    *)
        ha_log_error "invalid_usage usage=$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
