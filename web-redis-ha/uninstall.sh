#!/bin/bash
# =============================================================================
# Web/Redis HA 宿主机 agent 卸载脚本
# 用法：
#   ./uninstall.sh
#   ./uninstall.sh --purge
# =============================================================================
set -euo pipefail

PURGE=false

for arg in "$@"; do
    case "${arg}" in
        --purge)
            PURGE=true
            ;;
        *)
            echo "[错误] 未知参数: ${arg}"
            echo "用法: $0 [--purge]"
            exit 1
            ;;
    esac
done

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

echo "========================================="
echo " Web/Redis HA - 卸载"
echo "========================================="

if command -v systemctl >/dev/null 2>&1; then
    run_as_root systemctl stop web-redis-ha-agent.service >/dev/null 2>&1 || true
    run_as_root systemctl disable web-redis-ha-agent.service >/dev/null 2>&1 || true
    run_as_root rm -f /etc/systemd/system/web-redis-ha-agent.service
    run_as_root systemctl daemon-reload >/dev/null 2>&1 || true
    echo "[信息] systemd 服务已停止并移除。"
else
    echo "[提示] 未找到 systemctl，跳过 systemd 清理。"
fi

run_as_root rm -f /usr/local/bin/web-redis-ha.sh
run_as_root rm -f /var/run/web-redis-ha.lock
echo "[信息] 已移除 /usr/local/bin/web-redis-ha.sh 和运行锁。"

if [ "${PURGE}" = "true" ]; then
    run_as_root rm -rf /etc/web-redis-ha
    run_as_root rm -rf /var/log/web-redis-ha
    echo "[信息] 已清理配置目录和日志目录。"
else
    echo "[信息] 已保留配置和日志："
    echo "  /etc/web-redis-ha"
    echo "  /var/log/web-redis-ha"
    echo "如需一并删除，请执行: ./uninstall.sh --purge"
fi

echo "[成功] Web/Redis HA 卸载完成。"
