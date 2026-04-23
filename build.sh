#!/bin/bash
# =============================================================================
# PostgreSQL HA 镜像构建脚本
# 用途：
#   1. 先构建 Dockerfile.base 对应的基础镜像
#   2. 再基于基础镜像构建业务镜像
# 用法：
#   ./build.sh
#   BASE_IMAGE=postgres-ha-base:dev APP_IMAGE=postgres-ha:dev ./build.sh
# =============================================================================
set -euo pipefail

BASE_IMAGE="${BASE_IMAGE:-postgres-ha-base:15.4-bookworm}"
APP_IMAGE="${APP_IMAGE:-postgres-ha:1.0}"

echo "========================================="
echo " PostgreSQL HA - 镜像构建"
echo "========================================="
echo "[信息] 基础镜像标签: ${BASE_IMAGE}"
echo "[信息] 业务镜像标签: ${APP_IMAGE}"

echo "[信息] 开始构建基础镜像..."
docker build -f Dockerfile.base -t "${BASE_IMAGE}" .

echo "[信息] 开始构建业务镜像..."
docker build --build-arg "BASE_IMAGE=${BASE_IMAGE}" -t "${APP_IMAGE}" .

echo "[成功] 镜像构建完成！"
echo "  基础镜像: ${BASE_IMAGE}"
echo "  业务镜像: ${APP_IMAGE}"
