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

# 记录事件
echo "[${TIMESTAMP}] Node=${NODE_ID} Event=${EVENT_TYPE} Success=${SUCCESS} Details=${DETAILS}" >> ${LOG_FILE}

# 对关键事件输出到控制台
case "${EVENT_TYPE}" in
    "standby_promote"|"repmgrd_failover_promote")
        /usr/local/bin/keepalived-control.sh start || true
        echo "============================================="
        echo " [REPMGR EVENT] 节点 ${NODE_ID} 已被提升为 Primary！"
        echo " 时间: ${TIMESTAMP}"
        echo " 详情: ${DETAILS}"
        echo "============================================="
        ;;
    "standby_follow"|"repmgrd_failover_follow")
        /usr/local/bin/keepalived-control.sh stop || true
        echo "============================================="
        echo " [REPMGR EVENT] 节点 ${NODE_ID} 已切换为跟随新 Primary"
        echo " 时间: ${TIMESTAMP}"
        echo " 详情: ${DETAILS}"
        echo "============================================="
        ;;
esac
