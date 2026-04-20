#!/bin/bash
# =============================================================================
# PostgreSQL HA - 一键启动脚本
# =============================================================================

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

echo "[信息] 正在拉起集群节点服务..."
docker compose up -d

if [ $? -eq 0 ]; then
    echo "[成功] 节点服务已在后台启动！"
    echo "您可以使用 ./ops.sh 打开运维控制台查看运行状态。"
else
    echo "[错误] 启动失败，请检查 Docker 服务或配置文件。"
    exit 1
fi
