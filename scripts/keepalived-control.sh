#!/bin/bash
set -e

. /usr/local/bin/ha-log.sh

PID_FILE="/var/run/keepalived.pid"
LOG_FILE="/var/log/repmgr/keepalived.log"
RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"
RUN_ID="keepalived-$(date +%s)-$$"
ha_log_init "keepalived-control" "${RUN_ID}"

if [ -f "${RUNTIME_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV_FILE}"
fi

log_vip_snapshot() {
    local vip="${NODE_VIP:-}"
    local node_ip="${NODE_IP:-}"
    if [ -n "${vip}" ]; then
        ha_log_capture_allow_fail "INFO" "keepalived_vip_snapshot" "ip -o addr show | grep -E '${vip}|${node_ip}'"
    else
        ha_log_capture_allow_fail "INFO" "keepalived_vip_snapshot" "ip -o addr show"
    fi
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

start_keepalived() {
    if pgrep -x keepalived >/dev/null 2>&1; then
        ha_log_info "keepalived_already_running"
        return 0
    fi

    ha_log_info "keepalived_start command=/usr/sbin/keepalived"
    run_as_root /usr/sbin/keepalived --no-syslog --log-console --log-detail --pid="${PID_FILE}" >"${LOG_FILE}" 2>&1 &
    sleep 1

    if ! pgrep -x keepalived >/dev/null 2>&1; then
        ha_log_error "keepalived_start_failed pid_file=${PID_FILE} log_file=${LOG_FILE}"
        ha_log_tail_file "ERROR" "keepalived_start_failed_tail" "${LOG_FILE}" 80 || true
        exit 1
    fi
    ha_log_info "keepalived_started pid=$(cat "${PID_FILE}" 2>/dev/null || echo unknown)"
    log_vip_snapshot || true
    ha_log_tail_file "INFO" "keepalived_start_tail" "${LOG_FILE}" 20 || true
}

stop_keepalived() {
    ha_log_info "keepalived_stop_requested"
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
        run_as_root /bin/kill "$(cat "${PID_FILE}")" 2>/dev/null || true
    else
        run_as_root /usr/bin/killall keepalived 2>/dev/null || true
    fi

    rm -f "${PID_FILE}"
    ha_log_info "keepalived_stopped"
    log_vip_snapshot || true
}

case "${1:-}" in
    start)
        start_keepalived
        ;;
    stop)
        stop_keepalived
        ;;
    restart)
        stop_keepalived
        start_keepalived
        ;;
    status)
        if pgrep -x keepalived >/dev/null 2>&1; then
            ha_log_info "keepalived_status running=true"
            log_vip_snapshot || true
            exit 0
        fi
        ha_log_warn "keepalived_status running=false"
        log_vip_snapshot || true
        exit 1
        ;;
    *)
        ha_log_error "invalid_usage usage=$0{start|stop|restart|status}"
        exit 1
        ;;
esac
