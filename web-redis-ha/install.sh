#!/bin/bash
# =============================================================================
# Web/Redis HA 宿主机 agent 安装脚本
# 用法：
#   ./install.sh
#   ./install.sh --no-start
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NO_START=false

for arg in "$@"; do
    case "${arg}" in
        --no-start)
            NO_START=true
            ;;
        *)
            echo "[错误] 未知参数: ${arg}"
            echo "用法: $0 [--no-start]"
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

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

replace_config_value() {
    local key="$1"
    local value="$2"
    local escaped_value

    if [ -z "${value}" ]; then
        return 0
    fi

    escaped_value=$(escape_sed_replacement "${value}")
    run_as_root sed -i "s|^${key}=.*|${key}=${escaped_value}|" /etc/web-redis-ha/web-redis-ha.env
}

echo "========================================="
echo " Web/Redis HA - 单活 agent 安装"
echo "========================================="

if ! command -v docker >/dev/null 2>&1; then
    echo "[错误] 未找到 docker 命令，请先安装 Docker。"
    exit 1
fi

run_as_root install -d -m 0755 /etc/web-redis-ha
run_as_root install -d -m 0755 /var/log/web-redis-ha

run_as_root install -m 0755 "${SCRIPT_DIR}/scripts/web-redis-ha.sh" /usr/local/bin/web-redis-ha.sh

if [ ! -f /etc/web-redis-ha/web-redis-ha.env ]; then
    run_as_root install -m 0644 "${SCRIPT_DIR}/conf/web-redis-ha.env.example" /etc/web-redis-ha/web-redis-ha.env

    ENV_SOURCE=""
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        ENV_SOURCE="${SCRIPT_DIR}/.env"
    elif [ -f "${SCRIPT_DIR}/../.env" ]; then
        ENV_SOURCE="${SCRIPT_DIR}/../.env"
    fi

    if [ -n "${ENV_SOURCE}" ]; then
        NODE_VIP_VALUE=$(grep -E '^NODE_VIP=' "${ENV_SOURCE}" | tail -n 1 | cut -d= -f2- || true)
        PG_PORT_VALUE=$(grep -E '^PG_PORT=' "${ENV_SOURCE}" | tail -n 1 | cut -d= -f2- || true)
        REDIS_PASSWORD_VALUE=$(grep -E '^REDIS_PASSWORD=' "${ENV_SOURCE}" | tail -n 1 | cut -d= -f2- || true)

        replace_config_value "NODE_VIP" "${NODE_VIP_VALUE}"
        replace_config_value "PG_PORT" "${PG_PORT_VALUE}"
        replace_config_value "REDIS_PASSWORD" "${REDIS_PASSWORD_VALUE}"
        echo "[信息] 已从 ${ENV_SOURCE} 同步 NODE_VIP / PG_PORT / REDIS_PASSWORD。"
    fi
    echo "[信息] 已创建默认配置: /etc/web-redis-ha/web-redis-ha.env"
else
    echo "[信息] 保留已有配置: /etc/web-redis-ha/web-redis-ha.env"
fi

# shellcheck disable=SC1091
. /etc/web-redis-ha/web-redis-ha.env
WEB_CONTAINER_NAME=${WEB_CONTAINER_NAME:-web}
REDIS_CONTAINER_NAME=${REDIS_CONTAINER_NAME:-redis}

echo "[提示] 请确认 Web 的 docker-compose.yml 中不要配置 restart，避免备用节点误启动。"
echo "       Web 容器名配置为: ${WEB_CONTAINER_NAME}"
echo "[提示] 请确认 Redis 的 docker-compose.yml 中配置 restart: unless-stopped。"
echo "       Redis 容器名配置为: ${REDIS_CONTAINER_NAME}"

if command -v systemctl >/dev/null 2>&1; then
    run_as_root install -m 0644 "${SCRIPT_DIR}/systemd/web-redis-ha-agent.service" /etc/systemd/system/web-redis-ha-agent.service
    run_as_root systemctl daemon-reload
    run_as_root systemctl enable web-redis-ha-agent.service >/dev/null
    if [ "${NO_START}" = "false" ]; then
        run_as_root systemctl restart web-redis-ha-agent.service
        echo "[成功] systemd 服务已启用并启动: web-redis-ha-agent.service"
    else
        echo "[成功] systemd 服务已启用，未启动。可手工执行: systemctl start web-redis-ha-agent.service"
    fi
else
    echo "[提示] 当前系统未找到 systemctl，请用以下命令手工启动 agent："
    echo "  /usr/local/bin/web-redis-ha.sh agent"
fi

echo ""
echo "下一步："
echo "  1. 检查 /etc/web-redis-ha/web-redis-ha.env 中的 Web/Redis 容器名、Redis DB、健康检查 URL"
echo "  2. 查看状态: /usr/local/bin/web-redis-ha.sh status"
echo "  3. 查看日志: tail -f /var/log/web-redis-ha/web-redis-ha.log"
