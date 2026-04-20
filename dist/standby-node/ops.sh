#!/bin/bash
# =============================================================================
# PostgreSQL HA - 智能运维控制台
# =============================================================================

# 读取 .env 中的环境变量
if [ -f ".env" ]; then
    export $(cat .env | grep -v '#' | awk '/=/ {print $1}')
fi

DB_NAME=${POSTGRES_DB:-thingsboard}

while true; do
    echo ""
    echo "=========================================================="
    echo "       PostgreSQL HA 智能运维控制台"
    echo "=========================================================="
    echo "  1) 查看集群主备健康状态 (Cluster Show & VIP 状态)"
    echo "  2) [主节点] 测试数据同步: 写入一条测试数据"
    echo "  3) [备节点] 检查同步到达: 查询测试数据"
    echo "  4) [备节点] 手动主备切换: 将本节点平滑升级为主节点"
    echo "  5) [灾难恢复] 销毁本地数据，以备用节点身份重新加入集群"
    echo "  0) 退出"
    echo "=========================================================="
    read -p "请输入操作编号: " choice

    case $choice in
        1)
            echo "----------------------------------------------------------"
            echo " [操作] 查看集群主备状态..."
            echo "----------------------------------------------------------"
            echo "> repmgr 集群拓扑："
            docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
            echo "> 本机持有的虚拟 IP (VIP) 情况 (如果没有显示 VIP，说明本机不是主节点)："
            docker exec -it postgres-ha ip addr show eth0 | grep -w "inet"
            ;;
        2)
            echo "----------------------------------------------------------"
            echo " [操作] 在主库 (${DB_NAME}) 中写入测试数据..."
            echo "----------------------------------------------------------"
            docker exec -it postgres-ha bash -c "echo \"CREATE TABLE IF NOT EXISTS ha_test_sync (id serial PRIMARY KEY, data text, created_at timestamp DEFAULT current_timestamp); INSERT INTO ha_test_sync (data) VALUES ('来自运维面板的测试写入');\" | su - postgres -c 'psql -d ${DB_NAME}'"
            echo "写入完成！您可以在备节点执行选项 3 检查数据是否同步过来。"
            ;;
        3)
            echo "----------------------------------------------------------"
            echo " [操作] 在本节点 (${DB_NAME}) 中查询测试数据..."
            echo "----------------------------------------------------------"
            docker exec -it postgres-ha bash -c "echo \"SELECT * FROM ha_test_sync ORDER BY id DESC LIMIT 5;\" | su - postgres -c 'psql -d ${DB_NAME}'" || echo "[提示] 如果表不存在，说明主节点还没写入过测试数据。"
            ;;
        4)
            echo "----------------------------------------------------------"
            echo " [操作] 执行手动主备切换 (Switchover)..."
            echo " 说明：此操作需在【备节点】上执行，会将本节点提拔为新的主节点。"
            echo "----------------------------------------------------------"
            read -p "确认执行切换吗？(y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo "1. 执行切换前环境检测..."
                docker exec -it postgres-ha su - postgres -c "repmgr standby switchover -f /etc/repmgr.conf --siblings-follow --dry-run"
                echo "2. 正式执行切换..."
                docker exec -it postgres-ha su - postgres -c "repmgr standby switchover -f /etc/repmgr.conf --siblings-follow"
                echo "切换指令已下发，请稍后使用选项 1 检查状态确认。"
            fi
            ;;
        5)
            echo "----------------------------------------------------------"
            echo " [操作] 灾难恢复：重置并以 Standby 身份重新加入集群"
            echo " 警告：此操作将清空本地的数据库数据，并从对端主节点重新克隆！"
            echo " 适用场景：老主节点宕机后，新的主节点已经接管业务，老节点开机后必须执行此操作。"
            echo "----------------------------------------------------------"
            read -p "您确定要销毁本地数据并重装吗？请输入大写 YES 确认: " confirm_del
            if [ "$confirm_del" = "YES" ]; then
                echo "正在停止容器..."
                docker compose down
                echo "正在销毁本地数据库数据卷..."
                docker volume rm postgres-ha-cluster_pgdata 2>/dev/null || docker volume rm $(basename "$PWD")_pgdata 2>/dev/null || true
                echo "重新启动容器（作为备节点重新克隆中）..."
                docker compose up -d
                echo "恢复流程已启动，请稍后使用选项 1 查看同步状态。"
            else
                echo "已取消。"
            fi
            ;;
        0)
            echo "退出控制台。"
            exit 0
            ;;
        *)
            echo "无效的选择，请重试。"
            ;;
    esac
done
