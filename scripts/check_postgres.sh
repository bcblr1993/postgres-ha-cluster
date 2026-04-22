#!/bin/bash
# =============================================================================
# Keepalived 健康检查脚本
# 功能：检查本地 PostgreSQL 是否为 Primary (非 recovery 模式)
# 返回值：0 = Primary (健康)，1 = Standby 或不可达 (不健康)
# 被 Keepalived vrrp_script 每 2 秒调用一次
# =============================================================================

. /usr/local/bin/ha-log.sh

RUN_ID="check-postgres"
ha_log_init "check-postgres" "${RUN_ID}"
STATE_FILE="/tmp/check-postgres.state"
COUNT_FILE="/tmp/check-postgres.failcount"

record_state() {
    local current_state="$1"
    local last_state=""

    if [ -f "${STATE_FILE}" ]; then
        last_state=$(cat "${STATE_FILE}" 2>/dev/null || true)
    fi

    if [ "${current_state}" != "${last_state}" ]; then
        ha_log_info "health_state_change from=${last_state:-unknown} to=${current_state}"
        printf '%s' "${current_state}" > "${STATE_FILE}"
    fi
}

record_failure_count() {
    local reason="$1"
    local count=0

    if [ -f "${COUNT_FILE}" ]; then
        count=$(cat "${COUNT_FILE}" 2>/dev/null || echo 0)
    fi
    count=$((count + 1))
    printf '%s' "${count}" > "${COUNT_FILE}"

    if [ ${count} -eq 1 ] || [ $((count % 30)) -eq 0 ]; then
        ha_log_warn "health_check_failure reason=${reason} consecutive=${count}"
    fi
}

reset_failure_count() {
    rm -f "${COUNT_FILE}"
}

# 检查 PostgreSQL 是否可达
if ! pg_isready -q 2>/dev/null; then
    record_state "down"
    record_failure_count "pg_isready_failed"
    exit 1
fi

# 检查是否为 Primary（pg_is_in_recovery() 返回 f 表示 Primary）
PG_IS_IN_RECOVERY=$(su - postgres -c "psql -tAc \"SELECT pg_is_in_recovery()\"" 2>/dev/null)

if [ "$PG_IS_IN_RECOVERY" = "f" ]; then
    # 是 Primary 节点 - VIP 应该在此节点
    record_state "primary"
    reset_failure_count
    exit 0
else
    # 是 Standby 节点或无法获取状态 - VIP 不应在此节点
    record_state "standby"
    record_failure_count "node_not_primary"
    exit 1
fi
