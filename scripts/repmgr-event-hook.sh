#!/bin/bash
# =============================================================================
# repmgr 事件通知钩子脚本
# 功能：记录 repmgr 关键事件到日志
# 参数：%n=node_id  %e=event_type  %s=success(1/0)  %t=timestamp  %d=details
# =============================================================================

. /usr/local/bin/ha-log.sh

NODE_ID=$1
EVENT_TYPE=$2
SUCCESS=$3
TIMESTAMP=$4
DETAILS=$5

LOG_FILE="/var/log/repmgr/events.log"
WECOM_LOG_FILE="/var/log/repmgr/wecom-notify.log"
WECOM_FLAG_DIR="/tmp/repmgr-wecom"
RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"
if [ -f "${RUNTIME_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV_FILE}"
fi
export TZ=${TZ:-Asia/Shanghai}

RUN_ID="repmgr-event-${EVENT_TYPE}-$(date +%s)-$$-node${NODE_ID}"
ha_log_init "repmgr-event-hook" "${RUN_ID}"

log_event_snapshot() {
    local local_role vip_present keepalived_state primary_name
    local_role=$(ha_pg_cmd "psql -tAc \"SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END\"" 2>/dev/null | tr -d '[:space:]' || true)
    if ip addr show 2>/dev/null | grep -qw "${NODE_VIP:-}"; then
        vip_present="yes"
    else
        vip_present="no"
    fi
    if pgrep -x keepalived >/dev/null 2>&1; then
        keepalived_state="running"
    else
        keepalived_state="stopped"
    fi
    primary_name=$(ha_pg_cmd "psql -d repmgr -tAc \"SELECT node_name FROM repmgr.nodes WHERE active IS TRUE AND type = 'primary' ORDER BY node_id LIMIT 1\"" 2>/dev/null | tr -d '[:space:]' || true)
    ha_log_info "event_snapshot local_role=${local_role:-unknown} vip_present=${vip_present} keepalived=${keepalived_state} primary=${primary_name:-unknown}"
    ha_log_ha_snapshot "event_${EVENT_TYPE}_state"
    ha_log_capture_allow_fail "INFO" "event_cluster_show" "$(ha_pg_cmd_string "repmgr -f /etc/repmgr.conf cluster show")" || true
}

# 记录事件
echo "[${TIMESTAMP}] Node=${NODE_ID} Event=${EVENT_TYPE} Success=${SUCCESS} Details=${DETAILS}" >> ${LOG_FILE}
ha_log_info "event_received node_id=${NODE_ID} event=${EVENT_TYPE} success=${SUCCESS} details=${DETAILS}"
ha_log_event "repmgr_event_received node_id=${NODE_ID} event=${EVENT_TYPE} success=${SUCCESS} details=${DETAILS}"
log_event_snapshot

mkdir -p "${WECOM_FLAG_DIR}"

trigger_wecom_notify() {
    local suppress_flag="${1:-}"
    local create_flag="${2:-}"
    ha_log_info "wecom_notify_scheduled event=${EVENT_TYPE} suppress_flag=${suppress_flag:-none} create_flag=${create_flag:-none}"

    (
        if [ -n "${create_flag}" ]; then
            touch "${create_flag}"
        fi
        sleep 4
        if [ -n "${suppress_flag}" ] && [ -f "${suppress_flag}" ]; then
            rm -f "${suppress_flag}"
            exit 0
        fi
        /usr/local/bin/wecom-notify.sh "${EVENT_TYPE}" "${SUCCESS}" "${TIMESTAMP}" "${DETAILS}"
        if [ -n "${create_flag}" ]; then
            rm -f "${create_flag}"
        fi
    ) &
}

# 对关键事件输出到控制台
case "${EVENT_TYPE}" in
    "standby_promote"|"repmgrd_failover_promote")
        ha_log_warn "event_action promote keepalived=managed_by_vrrp"
        ha_log_event "failover_promote_start node_id=${NODE_ID} event=${EVENT_TYPE} timestamp=${TIMESTAMP}"
        ha_log_ha_snapshot "event_${EVENT_TYPE}_before_promote_actions"
        /usr/local/bin/wal-receiver-control.sh stop || true
        /usr/local/bin/archive-promote-wal.sh || true
        /usr/local/bin/vip-control.sh ensure || true
        ha_log_ha_snapshot "event_${EVENT_TYPE}_after_promote_actions"
        ha_log_event "failover_promote_done node_id=${NODE_ID} event=${EVENT_TYPE} timestamp=${TIMESTAMP}"
        if [ "${EVENT_TYPE}" = "standby_promote" ]; then
            trigger_wecom_notify "${WECOM_FLAG_DIR}/failover-promote-${NODE_ID}.flag" ""
        else
            trigger_wecom_notify "" "${WECOM_FLAG_DIR}/failover-promote-${NODE_ID}.flag"
        fi
        echo "============================================="
        echo " [REPMGR EVENT] 节点 ${NODE_ID} 已被提升为 Primary！"
        echo " 时间: ${TIMESTAMP}"
        echo " 详情: ${DETAILS}"
        echo "============================================="
        ;;
    "standby_follow"|"repmgrd_failover_follow")
        ha_log_info "event_action follow keepalived=managed_by_vrrp"
        ha_log_event "standby_follow_start node_id=${NODE_ID} event=${EVENT_TYPE} timestamp=${TIMESTAMP}"
        ha_log_ha_snapshot "event_${EVENT_TYPE}_before_follow_actions"
        /usr/local/bin/vip-control.sh remove || true
        /usr/local/bin/wal-receiver-control.sh start || true
        ha_log_ha_snapshot "event_${EVENT_TYPE}_after_follow_actions"
        ha_log_event "standby_follow_done node_id=${NODE_ID} event=${EVENT_TYPE} timestamp=${TIMESTAMP}"
        if [ "${EVENT_TYPE}" = "standby_follow" ]; then
            trigger_wecom_notify "${WECOM_FLAG_DIR}/failover-follow-${NODE_ID}.flag" ""
        else
            trigger_wecom_notify "" "${WECOM_FLAG_DIR}/failover-follow-${NODE_ID}.flag"
        fi
        echo "============================================="
        echo " [REPMGR EVENT] 节点 ${NODE_ID} 已切换为跟随新 Primary"
        echo " 时间: ${TIMESTAMP}"
        echo " 详情: ${DETAILS}"
        echo "============================================="
        ;;
    *)
        ha_log_info "event_ignored event=${EVENT_TYPE}"
        ;;
esac

log_event_snapshot
ha_log_info "event_processed node_id=${NODE_ID} event=${EVENT_TYPE} success=${SUCCESS}"
ha_log_event "repmgr_event_processed node_id=${NODE_ID} event=${EVENT_TYPE} success=${SUCCESS}"
