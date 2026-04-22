#!/bin/bash
# =============================================================================
# 企业微信机器人通知脚本
# 用途：在主备切换/跟随事件后采集当前节点状态并发送 Markdown 通知
# 参数：
#   $1 event_type
#   $2 success
#   $3 event_time
#   $4 details
# =============================================================================
set -u

. /usr/local/bin/ha-log.sh

RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"
if [ -f "${RUNTIME_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV_FILE}"
fi

EVENT_TYPE=${1:-unknown}
SUCCESS=${2:-0}
EVENT_TIME=${3:-$(date '+%F %T %z')}
DETAILS=${4:-""}

WECOM_NOTIFY_ENABLED=${WECOM_NOTIFY_ENABLED:-false}
WECOM_WEBHOOK_URL=${WECOM_WEBHOOK_URL:-""}
WECOM_NOTIFY_SITE_NAME=${WECOM_NOTIFY_SITE_NAME:-PostgreSQL HA 现场}
WECOM_NOTIFY_TIMEOUT=${WECOM_NOTIFY_TIMEOUT:-10}
WECOM_NOTIFY_AT_ALL_ON_FAILOVER=${WECOM_NOTIFY_AT_ALL_ON_FAILOVER:-false}
WECOM_NOTIFY_STYLE=${WECOM_NOTIFY_STYLE:-compact}

NODE_NAME=${NODE_NAME:-$(hostname)}
NODE_IP=${NODE_IP:-""}
PARTNER_IP=${PARTNER_IP:-""}
NODE_VIP=${NODE_VIP:-""}

LOG_FILE="/var/log/repmgr/wecom-notify.log"
CA_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
RUN_ID="wecom-$(date +%s)-$$-${EVENT_TYPE}"
ha_log_init "wecom-notify" "${RUN_ID}"

log() {
    ha_log_info "$*"
}

is_enabled() {
    case "${1}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

run_pg_cmd() {
    if [ "$(id -un)" = "postgres" ]; then
        bash -lc "$1"
    else
        su - postgres -c "$1"
    fi
}

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'
}

trim() {
    printf '%s' "$1" | awk '{$1=$1;print}'
}

detect_local_ip() {
    if [ -n "${NODE_IP}" ]; then
        printf '%s' "${NODE_IP}"
        return
    fi

    ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

detect_pg_ready() {
    if run_pg_cmd "pg_isready -q" >/dev/null 2>&1; then
        printf 'ok'
    else
        printf 'fail'
    fi
}

detect_pg_role() {
    local value
    value=$(run_pg_cmd "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null | tr -d '[:space:]')
    case "${value}" in
        f) printf 'primary' ;;
        t) printf 'standby' ;;
        *) printf 'unknown' ;;
    esac
}

detect_primary_name() {
    local value
    value=$(run_pg_cmd "psql -d repmgr -tAc \"SELECT node_name FROM repmgr.nodes WHERE active IS TRUE AND type = 'primary' ORDER BY node_id LIMIT 1\"" 2>/dev/null | tr -d '[:space:]')
    if [ -n "${value}" ]; then
        printf '%s' "${value}"
    else
        printf 'unknown'
    fi
}

detect_vip_owner() {
    if [ -n "${NODE_VIP}" ] && ip addr show 2>/dev/null | grep -qw "${NODE_VIP}"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

detect_keepalived() {
    if pgrep -x keepalived >/dev/null 2>&1; then
        printf 'running'
    else
        printf 'stopped'
    fi
}

event_title="PostgreSQL HA 事件通知"
event_level='<font color="info">提示</font>'
event_label="集群状态更新"
event_summary="请关注当前主备状态。"

case "${EVENT_TYPE}" in
    standby_promote|repmgrd_failover_promote)
        if printf '%s' "${DETAILS}" | grep -iq 'switchover'; then
            event_title="PostgreSQL HA 切换通知"
            event_level='<font color="info">提示</font>'
            event_label="计划内主备切换完成"
            event_summary="当前节点已提升为新的 Primary。"
        else
            event_title="PostgreSQL HA 切换告警"
            event_level='<font color="warning">告警</font>'
            event_label="自动故障切换完成"
            event_summary="当前节点已提升为新的 Primary 并应接管对外服务。"
        fi
        ;;
    standby_follow|repmgrd_failover_follow)
        event_title="PostgreSQL HA 恢复通知"
        event_level='<font color="info">恢复</font>'
        event_label="节点已回归 Standby"
        event_summary="当前节点已开始跟随新的 Primary。"
        ;;
    node_rejoin)
        event_title="PostgreSQL HA 恢复通知"
        event_level='<font color="info">恢复</font>'
        event_label="旧主已回归 Standby"
        event_summary="当前节点已重新加入集群，双节点拓扑已恢复。"
        ;;
esac

ha_log_info "notify_start event=${EVENT_TYPE} success=${SUCCESS} site=${WECOM_NOTIFY_SITE_NAME} enabled=${WECOM_NOTIFY_ENABLED}"

if ! is_enabled "${WECOM_NOTIFY_ENABLED}"; then
    log "通知未启用，跳过事件 ${EVENT_TYPE}"
    exit 0
fi

if [ -z "${WECOM_WEBHOOK_URL}" ]; then
    log "未配置 WECOM_WEBHOOK_URL，跳过事件 ${EVENT_TYPE}"
    exit 0
fi

LOCAL_IP=$(detect_local_ip)
PG_READY=$(detect_pg_ready)
PG_ROLE=$(detect_pg_role)
PRIMARY_NAME=$(detect_primary_name)
VIP_PRESENT=$(detect_vip_owner)
KEEPALIVED_STATUS=$(detect_keepalived)
HOSTNAME_VALUE=$(hostname)
ha_log_info "state_snapshot node=${NODE_NAME} local_ip=${LOCAL_IP:-unknown} partner_ip=${PARTNER_IP:-unknown} role=${PG_ROLE} primary=${PRIMARY_NAME} vip_present=${VIP_PRESENT} pg_ready=${PG_READY} keepalived=${KEEPALIVED_STATUS}"

DB_WRITABLE="未知"
SERVICE_STATUS="异常"
VIP_STATUS="未知"

case "${PG_ROLE}" in
    primary)
        DB_WRITABLE="可写"
        if [ "${PG_READY}" = "ok" ] && [ "${VIP_PRESENT}" = "yes" ]; then
            SERVICE_STATUS="可用"
            VIP_STATUS="已跟随主节点"
        elif [ "${PG_READY}" = "ok" ]; then
            SERVICE_STATUS="降级可用（未持有 VIP）"
            VIP_STATUS="未切换到当前主节点"
        else
            SERVICE_STATUS="异常"
            VIP_STATUS="状态异常"
        fi
        ;;
    standby)
        DB_WRITABLE="只读"
        if [ "${PG_READY}" = "ok" ]; then
            SERVICE_STATUS="只读待机"
            VIP_STATUS="不应在本机"
        else
            SERVICE_STATUS="异常"
            VIP_STATUS="状态异常"
        fi
        ;;
    *)
        if [ "${PG_READY}" = "ok" ]; then
            SERVICE_STATUS="部分可用（角色未知）"
        fi
        if [ "${VIP_PRESENT}" = "yes" ]; then
            VIP_STATUS="在本机"
        else
            VIP_STATUS="不在本机"
        fi
        ;;
esac

if [ "${SUCCESS}" = "0" ]; then
    event_level='<font color="warning">告警</font>'
    event_summary="事件已触发，但脚本返回失败，请人工检查。"
fi

MENTION_TAG=""
if is_enabled "${WECOM_NOTIFY_AT_ALL_ON_FAILOVER}" && [ "${EVENT_TYPE}" = "repmgrd_failover_promote" ]; then
    MENTION_TAG=$'\n<@all>'
fi

SUMMARY_LINE="${event_summary}"
if [ "${PG_ROLE}" = "primary" ] && [ "${SERVICE_STATUS}" = "可用" ]; then
    SUMMARY_LINE="切换完成，当前已可对外服务。"
elif [ "${PG_ROLE}" = "primary" ]; then
    SUMMARY_LINE="已切换为主节点，但当前状态需要人工检查。"
elif [ "${PG_ROLE}" = "standby" ] && [ "${EVENT_TYPE}" = "node_rejoin" ]; then
    SUMMARY_LINE="旧主已回归为备节点，集群双节点已恢复。"
elif [ "${PG_ROLE}" = "standby" ]; then
    SUMMARY_LINE="当前节点已成为备节点，集群主备关系已调整。"
fi

if [ "${SUCCESS}" = "0" ]; then
    SUMMARY_LINE="事件已触发，但执行结果异常，请人工检查。"
fi

DISPLAY_TITLE="【${WECOM_NOTIFY_SITE_NAME}】${event_title}"

if [ "${WECOM_NOTIFY_STYLE}" = "detailed" ]; then
    MARKDOWN_CONTENT=$(cat <<EOF
# ${DISPLAY_TITLE}
> 级别：${event_level}
> 事件：**${event_label}**

- 当前主节点：\`${PRIMARY_NAME}\`
- 当前节点：\`${NODE_NAME}\`
- 当前角色：\`${PG_ROLE}\`
- 对外服务：<font color="info">${SERVICE_STATUS}</font>
- 写入状态：\`${DB_WRITABLE}\`

> VIP：\`${NODE_VIP:-unknown}\`
> VIP 是否在本机：\`${VIP_PRESENT}\`
> 本机物理 IP：\`${LOCAL_IP:-unknown}\`
> 对端物理 IP：\`${PARTNER_IP:-unknown}\`
> 宿主机：\`${HOSTNAME_VALUE}\`

> PostgreSQL：\`pg_isready=${PG_READY}\`
> Keepalived：\`${KEEPALIVED_STATUS}\`
> repmgr 事件：\`${EVENT_TYPE}\`
> 触发时间：\`${EVENT_TIME}\`
> 说明：${SUMMARY_LINE}
> 详情：${DETAILS:-无}${MENTION_TAG}
EOF
)
else
    MARKDOWN_CONTENT=$(cat <<EOF
# ${DISPLAY_TITLE}
> 事件：**${event_label}**
> 时间：\`${EVENT_TIME}\`

- 当前状态：<font color="info">${SERVICE_STATUS}</font>
- 当前主节点：\`${PRIMARY_NAME}\`
- 当前节点角色：\`${PG_ROLE}\`
- VIP 状态：\`${VIP_STATUS}\`
- 写入状态：\`${DB_WRITABLE}\`

> 结论：${SUMMARY_LINE}${MENTION_TAG}
EOF
)
fi

PAYLOAD=$(cat <<EOF
{"msgtype":"markdown","markdown":{"content":"$(json_escape "${MARKDOWN_CONTENT}")"}}
EOF
)

HTTP_RESPONSE=$(curl -sS -m "${WECOM_NOTIFY_TIMEOUT}" \
    $(if [ ! -f "${CA_CERT_FILE}" ]; then printf '%s' '-k'; fi) \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "${PAYLOAD}" \
    "${WECOM_WEBHOOK_URL}" 2>&1)
CURL_EXIT=$?

if [ ${CURL_EXIT} -ne 0 ]; then
    ha_log_error "notify_send_failed event=${EVENT_TYPE} curl_exit=${CURL_EXIT} response=${HTTP_RESPONSE}"
    exit 0
fi

if printf '%s' "${HTTP_RESPONSE}" | grep -q '"errcode"[[:space:]]*:[[:space:]]*0'; then
    ha_log_info "notify_send_success event=${EVENT_TYPE}"
else
    ha_log_warn "notify_send_unexpected_response event=${EVENT_TYPE} response=${HTTP_RESPONSE}"
fi

exit 0
