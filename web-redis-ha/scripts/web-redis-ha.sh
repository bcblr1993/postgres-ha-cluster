#!/bin/bash
# Web/Redis single-active helper for an existing PostgreSQL HA pair.
set +e
set -uo pipefail

CONFIG_FILE=${WEB_REDIS_HA_CONFIG:-/etc/web-redis-ha/web-redis-ha.env}
if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
fi

PG_CONTAINER_NAME=${PG_CONTAINER_NAME:-postgres-ha}
PG_PORT=${PG_PORT:-5432}
NODE_VIP=${NODE_VIP:-192.168.1.100}

WEB_CONTAINER_NAME=${WEB_CONTAINER_NAME:-web}
REDIS_CONTAINER_NAME=${REDIS_CONTAINER_NAME:-redis}
WEB_REDIS_DB=${WEB_REDIS_DB:-0}
REDIS_PASSWORD=${REDIS_PASSWORD:-}

WEB_HEALTH_URL=${WEB_HEALTH_URL:-http://127.0.0.1:8080/health}
WEB_HEALTH_TIMEOUT=${WEB_HEALTH_TIMEOUT:-60}
WEB_HEALTH_INTERVAL_SECONDS=${WEB_HEALTH_INTERVAL_SECONDS:-2}
WEB_HEALTH_REQUEST_TIMEOUT=${WEB_HEALTH_REQUEST_TIMEOUT:-3}
WEB_STOP_TIMEOUT=${WEB_STOP_TIMEOUT:-30}

CHECK_INTERVAL_SECONDS=${CHECK_INTERVAL_SECONDS:-2}
LOG_FILE=${LOG_FILE:-/var/log/web-redis-ha/web-redis-ha.log}
LOCK_FILE=${LOCK_FILE:-/var/run/web-redis-ha.lock}

log_line() {
    local level="$1"
    local message="$2"
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${message}" | tee -a "${LOG_FILE}"
}

container_exists() {
    docker inspect "$1" >/dev/null 2>&1
}

container_running() {
    docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null | grep -q '^true$'
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_line "ERROR" "docker_missing"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        log_line "ERROR" "docker_unavailable"
        return 1
    fi
    return 0
}

redis_cli() {
    if [ -n "${REDIS_PASSWORD}" ]; then
        docker exec -e "REDISCLI_AUTH=${REDIS_PASSWORD}" "${REDIS_CONTAINER_NAME}" redis-cli -n "${WEB_REDIS_DB}" "$@"
        return $?
    fi
    docker exec "${REDIS_CONTAINER_NAME}" redis-cli -n "${WEB_REDIS_DB}" "$@"
}

redis_ready() {
    local output
    output=$(redis_cli PING 2>/dev/null | tr -d '[:space:]' || true)
    [ "${output}" = "PONG" ]
}

ensure_redis() {
    if ! container_exists "${REDIS_CONTAINER_NAME}"; then
        log_line "ERROR" "redis_missing container=${REDIS_CONTAINER_NAME}"
        return 1
    fi

    if ! container_running "${REDIS_CONTAINER_NAME}"; then
        log_line "WARN" "redis_stopped_starting container=${REDIS_CONTAINER_NAME}"
        docker start "${REDIS_CONTAINER_NAME}" >/dev/null 2>&1 || {
            log_line "ERROR" "redis_start_failed container=${REDIS_CONTAINER_NAME}"
            return 1
        }
    fi

    redis_ready || {
        log_line "ERROR" "redis_not_ready container=${REDIS_CONTAINER_NAME} db=${WEB_REDIS_DB}"
        return 1
    }
}

pg_primary() {
    local result
    container_running "${PG_CONTAINER_NAME}" || return 1
    result=$(docker exec "${PG_CONTAINER_NAME}" su - postgres -c \
        "psql -p ${PG_PORT} -tAc \"SELECT NOT pg_is_in_recovery()\"" 2>/dev/null | tr -d '[:space:]' || true)
    [ "${result}" = "t" ]
}

vip_present() {
    [ -n "${NODE_VIP}" ] && ip -o addr show 2>/dev/null | grep -qw "${NODE_VIP}"
}

active_node() {
    pg_primary && vip_present
}

flush_redis() {
    local output
    output=$(redis_cli FLUSHDB 2>&1)
    if [ "$?" -ne 0 ]; then
        log_line "ERROR" "redis_flush_failed db=${WEB_REDIS_DB} output=${output}"
        return 1
    fi
    log_line "INFO" "redis_flushdb_success db=${WEB_REDIS_DB}"
}

web_health_ok() {
    [ -z "${WEB_HEALTH_URL}" ] && return 0
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS --max-time "${WEB_HEALTH_REQUEST_TIMEOUT}" "${WEB_HEALTH_URL}" >/dev/null 2>&1
}

wait_web_health() {
    local deadline
    deadline=$((SECONDS + WEB_HEALTH_TIMEOUT))
    while [ "${SECONDS}" -le "${deadline}" ]; do
        web_health_ok && return 0
        sleep "${WEB_HEALTH_INTERVAL_SECONDS}"
    done
    return 1
}

stop_web() {
    container_exists "${WEB_CONTAINER_NAME}" || {
        log_line "WARN" "web_missing container=${WEB_CONTAINER_NAME}"
        return 0
    }

    if container_running "${WEB_CONTAINER_NAME}"; then
        log_line "INFO" "web_stopping container=${WEB_CONTAINER_NAME}"
        docker stop -t "${WEB_STOP_TIMEOUT}" "${WEB_CONTAINER_NAME}" >/dev/null 2>&1 || {
            log_line "ERROR" "web_stop_failed container=${WEB_CONTAINER_NAME}"
            return 1
        }
        log_line "INFO" "web_stopped container=${WEB_CONTAINER_NAME}"
    fi
}

start_web() {
    if ! active_node; then
        log_line "WARN" "web_start_blocked reason=not_primary_or_vip_absent"
        stop_web
        return 1
    fi

    container_exists "${WEB_CONTAINER_NAME}" || {
        log_line "ERROR" "web_missing container=${WEB_CONTAINER_NAME}"
        return 1
    }

    ensure_redis || {
        stop_web
        return 1
    }

    if container_running "${WEB_CONTAINER_NAME}"; then
        if web_health_ok; then
            return 0
        fi
        log_line "WARN" "web_health_failed_stopping container=${WEB_CONTAINER_NAME}"
        stop_web
        return 1
    fi

    flush_redis || return 1

    log_line "INFO" "web_starting container=${WEB_CONTAINER_NAME}"
    docker start "${WEB_CONTAINER_NAME}" >/dev/null 2>&1 || {
        log_line "ERROR" "web_start_failed container=${WEB_CONTAINER_NAME}"
        return 1
    }

    if wait_web_health; then
        log_line "INFO" "web_started container=${WEB_CONTAINER_NAME}"
        return 0
    fi

    log_line "ERROR" "web_health_timeout_stopping container=${WEB_CONTAINER_NAME}"
    stop_web
    return 1
}

once() {
    require_docker || return 1
    ensure_redis || {
        stop_web
        return 1
    }

    if active_node; then
        start_web
    else
        stop_web
    fi
}

status() {
    require_docker >/dev/null 2>&1 || true
    printf 'PG_CONTAINER=%s running=%s primary=%s\n' "${PG_CONTAINER_NAME}" "$(container_running "${PG_CONTAINER_NAME}" && echo yes || echo no)" "$(pg_primary && echo yes || echo no)"
    printf 'VIP=%s present=%s\n' "${NODE_VIP}" "$(vip_present && echo yes || echo no)"
    printf 'REDIS_CONTAINER=%s running=%s db=%s\n' "${REDIS_CONTAINER_NAME}" "$(container_running "${REDIS_CONTAINER_NAME}" && echo yes || echo no)" "${WEB_REDIS_DB}"
    printf 'WEB_CONTAINER=%s running=%s\n' "${WEB_CONTAINER_NAME}" "$(container_running "${WEB_CONTAINER_NAME}" && echo yes || echo no)"
    printf 'TARGET_WEB_STATE=%s\n' "$(active_node && echo running || echo stopped)"
}

with_lock() {
    local command_name="$1"
    mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${LOCK_FILE}" || return 1
        flock -n 9 || return 0
        "${command_name}"
        return $?
    fi
    "${command_name}"
}

agent() {
    log_line "INFO" "agent_started interval=${CHECK_INTERVAL_SECONDS}s"
    while true; do
        with_lock once || log_line "WARN" "reconcile_failed"
        sleep "${CHECK_INTERVAL_SECONDS}"
    done
}

case "${1:-once}" in
    agent) agent ;;
    once) with_lock once ;;
    status) status ;;
    start) with_lock start_web ;;
    stop) with_lock stop_web ;;
    *)
        echo "用法: $0 {agent|once|status|start|stop}"
        exit 1
        ;;
esac
