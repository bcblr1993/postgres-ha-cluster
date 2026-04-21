#!/bin/bash
# =============================================================================
# PostgreSQL HA - 镜像导入脚本
# 用法：
#   ./install.sh
#   ./install.sh postgres-ha-v1.0.tar
# =============================================================================
set -euo pipefail

echo "========================================="
echo " PostgreSQL HA - 离线镜像导入"
echo "========================================="

IMAGE_TAR="${1:-postgres-ha-v1.0.tar}"

if ! command -v docker >/dev/null 2>&1; then
    echo "[错误] 未找到 docker 命令，请先安装 Docker。"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "[错误] Docker 服务不可用，请先启动 Docker。"
    exit 1
fi

if [ ! -f "${IMAGE_TAR}" ]; then
    echo "[错误] 找不到镜像包 ${IMAGE_TAR}，请确保它与本脚本在同一目录下，或通过参数传入正确路径。"
    exit 1
fi

echo "[信息] 开始导入 Docker 镜像，这可能需要几十秒钟，请稍候..."
docker load -i "${IMAGE_TAR}"

echo "[成功] 镜像导入完成！"
echo "下一步："
echo "  1. 确认 .env 文件中的 IP / VIP / 密码配置正确"
echo "  2. 执行 ./start.sh 启动当前交付包中的节点"
echo "  3. 新版 Docker 使用 docker compose，旧版 Docker 使用 docker-compose，start.sh 会自动兼容"
