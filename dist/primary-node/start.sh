#!/bin/bash
# =============================================================================
# PostgreSQL HA - 一键启动脚本
# 交付包目录默认使用当前目录下的 docker-compose.yml
# =============================================================================
set -euo pipefail

echo "========================================="
echo " PostgreSQL HA - 节点启动"
echo "========================================="

if [ ! -f ".env" ]; then
    echo "[错误] 找不到 .env 配置文件！"
    exit 1
fi

if [ ! -f "docker-compose.yml" ]; then
    echo "[错误] 找不到 docker-compose.yml 文件！"
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

echo "[信息] 使用 Compose 命令: ${COMPOSE_CMD[*]}"
echo "[信息] 使用编排文件: docker-compose.yml"
echo "[信息] 正在拉起集群节点服务..."
"${COMPOSE_CMD[@]}" up -d

echo "[成功] 节点服务已在后台启动！"
echo "您可以使用 ./ops.sh 打开运维控制台查看运行状态。"
