#!/bin/bash
set -e

. /usr/local/bin/ha-log.sh

RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"
STATE="${1:-UNKNOWN}"
RUN_ID="keepalived-notify-${STATE}-$(date +%s)-$$"
ha_log_init "keepalived-notify" "${RUN_ID}"

if [ -f "${RUNTIME_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV_FILE}"
fi

NODE_VIP=${NODE_VIP:-}
NODE_IP=${NODE_IP:-}
PGPORT=${PGPORT:-5432}

detect_interface() {
    ip -o addr show | awk -v node_ip="${NODE_IP}" '$4 ~ "^" node_ip "/" {print $2; exit}'
}

vip_present() {
    [ -n "${NODE_VIP}" ] && ip addr show 2>/dev/null | grep -qw "${NODE_VIP}"
}

iface=$(detect_interface)
if vip_present; then
    vip_state="present"
else
    vip_state="absent"
fi

ha_log_event "keepalived_state_change state=${STATE} node=${NODE_NAME:-unknown} node_ip=${NODE_IP:-unknown} partner_ip=${PARTNER_IP:-unknown} vip=${NODE_VIP:-unset} vip_state=${vip_state} interface=${iface:-unknown}"
ha_log_ha_snapshot "keepalived_notify_${STATE}"

case "${STATE}" in
    MASTER)
        ha_log_info "keepalived_master_notice meaning=local_node_should_hold_vip"
        ;;
    BACKUP)
        ha_log_info "keepalived_backup_notice meaning=local_node_should_not_hold_vip"
        ;;
    FAULT)
        ha_log_info "keepalived_fault_notice meaning=health_check_failed_or_vrrp_fault"
        ;;
    STOP)
        ha_log_info "keepalived_stop_notice meaning=keepalived_instance_stopping"
        ;;
    *)
        ha_log_warn "keepalived_unknown_notice state=${STATE}"
        ;;
esac
