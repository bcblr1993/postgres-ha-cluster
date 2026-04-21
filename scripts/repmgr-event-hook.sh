#!/bin/bash
# =============================================================================
# repmgr 事件通知钩子脚本
# 功能：记录 repmgr 关键事件到日志
# 参数：%n=node_id  %e=event_type  %s=success(1/0)  %t=timestamp  %d=details
# =============================================================================

NODE_ID=$1
EVENT_TYPE=$2
SUCCESS=$3
TIMESTAMP=$4
DETAILS=$5

LOG_FILE="/var/log/repmgr/events.log"
WECOM_LOG_FILE="/var/log/repmgr/wecom-notify.log"
WECOM_FLAG_DIR="/tmp/repmgr-wecom"

# 记录事件
echo "[${TIMESTAMP}] Node=${NODE_ID} Event=${EVENT_TYPE} Success=${SUCCESS} Details=${DETAILS}" >> ${LOG_FILE}

mkdir -p "${WECOM_FLAG_DIR}"

trigger_wecom_notify() {
    local suppress_flag="${1:-}"
    local create_flag="${2:-}"

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
    ) >> "${WECOM_LOG_FILE}" 2>&1 &
}

# 对关键事件输出到控制台
case "${EVENT_TYPE}" in
    "standby_promote"|"repmgrd_failover_promote")
        /usr/local/bin/keepalived-control.sh start || true
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
        /usr/local/bin/keepalived-control.sh stop || true
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
esac
