#!/bin/bash
# =============================================================================
# PostgreSQL HA - 一键启动脚本
# 用法：
#   ./start.sh primary
#   ./start.sh standby
#   ./start.sh                 # 当前目录存在 docker-compose.yml 时可直接启动
# =============================================================================
set -euo pipefail

echo "========================================="
echo " PostgreSQL HA - 节点启动"
echo "========================================="

if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
else
    echo "[错误] 找不到 .env 配置文件！"
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
else
    echo "[错误] 未找到 docker compose / docker-compose 命令。"
    exit 1
fi

ROLE_ARG="${1:-${NODE_ROLE:-}}"
COMPOSE_FILE=""

case "${ROLE_ARG}" in
    primary)
        COMPOSE_FILE="docker-compose-primary.yml"
        ;;
    standby)
        COMPOSE_FILE="docker-compose-standby.yml"
        ;;
    "")
        if [ -f "docker-compose.yml" ]; then
            COMPOSE_FILE="docker-compose.yml"
        fi
        ;;
    *)
        echo "[错误] 无效角色: ${ROLE_ARG}"
        echo "用法: ./start.sh [primary|standby]"
        exit 1
        ;;
esac

if [ -z "${COMPOSE_FILE}" ]; then
    echo "[错误] 未能确定要启动的 Compose 文件。"
    echo "请使用以下方式之一："
    echo "  1. ./start.sh primary"
    echo "  2. ./start.sh standby"
    echo "  3. 在当前目录提供 docker-compose.yml 后执行 ./start.sh"
    exit 1
fi

if [ ! -f "${COMPOSE_FILE}" ]; then
    echo "[错误] 找不到 ${COMPOSE_FILE} 文件！"
    exit 1
fi

echo "[信息] 使用 Compose 命令: ${COMPOSE_CMD[*]}"
echo "[信息] 使用编排文件: ${COMPOSE_FILE}"
echo "[信息] 正在拉起集群节点服务..."
"${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d

echo "[成功] 节点服务已在后台启动！"
echo "您可以使用 ./ops.sh 打开运维控制台查看运行状态。"
