#!/bin/bash
set -e

PID_FILE="/var/run/keepalived.pid"
LOG_FILE="/var/log/repmgr/keepalived.log"

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

start_keepalived() {
    if pgrep -x keepalived >/dev/null 2>&1; then
        echo "keepalived is already running"
        return 0
    fi

    run_as_root /usr/sbin/keepalived --no-syslog --log-console --log-detail --pid="${PID_FILE}" >"${LOG_FILE}" 2>&1 &
    sleep 1

    if ! pgrep -x keepalived >/dev/null 2>&1; then
        echo "failed to start keepalived"
        exit 1
    fi
}

stop_keepalived() {
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
        run_as_root /bin/kill "$(cat "${PID_FILE}")" 2>/dev/null || true
    else
        run_as_root /usr/bin/killall keepalived 2>/dev/null || true
    fi

    rm -f "${PID_FILE}"
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
            exit 0
        fi
        exit 1
        ;;
    *)
        echo "usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
