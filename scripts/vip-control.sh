#!/bin/bash
set -e

. /usr/local/bin/ha-log.sh

RUNTIME_ENV_FILE="/etc/pg-ha/runtime-notify.env"
RUN_ID="vip-control-$(date +%s)-$$"
ha_log_init "vip-control" "${RUN_ID}"

if [ -f "${RUNTIME_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV_FILE}"
fi

NODE_VIP=${NODE_VIP:-""}
NODE_IP=${NODE_IP:-""}
PGPORT=${PGPORT:-5432}
VIP_CIDR=${NODE_VIP_CIDR:-${NODE_VIP}/24}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

detect_interface() {
    ip -o addr show | awk -v node_ip="${NODE_IP}" '$4 ~ "^" node_ip "/" {print $2; exit}'
}

ensure_primary() {
    if ! pg_isready -q -p "${PGPORT}" 2>/dev/null; then
        ha_log_warn "vip_ensure_skipped reason=postgres_unready"
        return 1
    fi

    if ! su - postgres -c "psql -p ${PGPORT} -tAc \"SELECT NOT pg_is_in_recovery()\"" 2>/dev/null | grep -q '^t$'; then
        ha_log_warn "vip_ensure_skipped reason=node_not_primary"
        return 1
    fi

    return 0
}

ensure_vip() {
    local iface

    if [ -z "${NODE_VIP}" ] || [ -z "${NODE_IP}" ]; then
        ha_log_error "vip_ensure_failed reason=missing_runtime_env node_ip=${NODE_IP:-unset} vip=${NODE_VIP:-unset}"
        return 1
    fi

    ensure_primary || return 1

    iface=$(detect_interface)
    if [ -z "${iface}" ]; then
        ha_log_error "vip_ensure_failed reason=interface_not_found node_ip=${NODE_IP}"
        return 1
    fi

    if ip -o addr show dev "${iface}" 2>/dev/null | grep -qw "${NODE_VIP}"; then
        ha_log_info "vip_already_present vip=${NODE_VIP} interface=${iface}"
        return 0
    fi

    run_as_root /sbin/ip addr add "${VIP_CIDR}" dev "${iface}" || true

    if ip -o addr show dev "${iface}" 2>/dev/null | grep -qw "${NODE_VIP}"; then
        ha_log_info "vip_added vip=${NODE_VIP} cidr=${VIP_CIDR} interface=${iface}"
        return 0
    fi

    ha_log_error "vip_ensure_failed reason=vip_not_visible_after_add vip=${NODE_VIP} interface=${iface}"
    return 1
}

remove_vip() {
    local iface

    if [ -z "${NODE_VIP}" ] || [ -z "${NODE_IP}" ]; then
        ha_log_warn "vip_remove_skipped reason=missing_runtime_env"
        return 0
    fi

    iface=$(detect_interface)
    if [ -z "${iface}" ]; then
        ha_log_warn "vip_remove_skipped reason=interface_not_found node_ip=${NODE_IP}"
        return 0
    fi

    if ! ip -o addr show dev "${iface}" 2>/dev/null | grep -qw "${NODE_VIP}"; then
        ha_log_info "vip_absent vip=${NODE_VIP} interface=${iface}"
        return 0
    fi

    run_as_root /sbin/ip addr del "${VIP_CIDR}" dev "${iface}" || true

    if ip -o addr show dev "${iface}" 2>/dev/null | grep -qw "${NODE_VIP}"; then
        ha_log_warn "vip_remove_incomplete vip=${NODE_VIP} interface=${iface}"
        return 1
    fi

    ha_log_info "vip_removed vip=${NODE_VIP} interface=${iface}"
    return 0
}

case "${1:-}" in
    ensure)
        ensure_vip
        ;;
    remove)
        remove_vip
        ;;
    *)
        ha_log_error "invalid_usage usage=$0 {ensure|remove}"
        exit 1
        ;;
esac
