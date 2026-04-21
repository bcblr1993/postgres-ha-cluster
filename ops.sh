#!/bin/bash
# =============================================================================
# PostgreSQL HA - 智能运维控制台
# =============================================================================

# 读取 .env 中的环境变量
if [ -f ".env" ]; then
    export $(cat .env | grep -v '#' | awk '/=/ {print $1}')
fi

DB_NAME=${POSTGRES_DB:-thingsboard}
CONTAINER=${CONTAINER_NAME:-postgres-ha}
PRIMARY_COMPOSE_FILE=${PRIMARY_COMPOSE_FILE:-docker-compose-primary.yml}
STANDBY_COMPOSE_FILE=${STANDBY_COMPOSE_FILE:-docker-compose-standby.yml}

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
else
    echo "[错误] 未找到 docker compose / docker-compose 命令。"
    exit 1
fi

compose_run() {
    "${COMPOSE_CMD[@]}" "$@"
}

# 检查容器是否在运行
check_container() {
    if ! docker inspect --format='{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -q true; then
        echo "[错误] 容器 '${CONTAINER}' 未运行，请先启动。"
        return 1
    fi
    return 0
}

while true; do
    echo ""
    echo "=========================================================="
    echo "       PostgreSQL HA 智能运维控制台  [容器: ${CONTAINER}]"
    echo "=========================================================="
    echo "  --- 状态监控 ---"
    echo "  1) 查看集群完整健康状态 (repmgr + VIP + Keepalived)"
    echo "  2) 查看流复制延迟与同步状态"
    echo "  --- 数据验证 ---"
    echo "  3) [主节点] 写入一条测试数据"
    echo "  4) [备节点] 查询测试数据（验证同步）"
    echo "  --- 日志查看 ---"
    echo "  5) 查看 repmgr 日志（最近 50 行）"
    echo "  6) 查看 Keepalived 日志（最近 50 行）"
    echo "  7) 查看 repmgr 事件日志（切换历史）"
    echo "  --- 切换操作 ---"
    echo "  8) [备节点] 手动主备切换 (Switchover，需 SSH 互通)"
    echo "  9) 重启容器内服务 (keepalived / repmgrd)"
    echo "  --- 灾难恢复 ---"
    echo "  10) 强制销毁本地数据并重建为 Standby（最后手段）"
    echo "  11) 查看双节点同时断电后的推荐恢复顺序"
    echo "  0) 退出"
    echo "=========================================================="
    read -p "请输入操作编号: " choice

    case $choice in
        1)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] 查看集群主备完整状态"
            echo "----------------------------------------------------------"
            echo ">>> repmgr 集群拓扑："
            docker exec -it "${CONTAINER}" su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
            echo ""
            echo ">>> 本机 VIP 持有情况（有 VIP 地址 = 当前是主节点）："
            docker exec -it "${CONTAINER}" ip addr show eth0 | grep -w "inet"
            echo ""
            echo ">>> Keepalived 进程状态："
            if docker exec "${CONTAINER}" pgrep -x keepalived >/dev/null 2>&1; then
                echo "  [运行中] keepalived 进程存在"
            else
                echo "  [未运行] keepalived 进程不存在（备节点正常，主节点异常）"
            fi
            echo ""
            echo ">>> PostgreSQL 角色确认："
            docker exec -it "${CONTAINER}" su - postgres -c \
                "psql -tAc \"SELECT CASE WHEN pg_is_in_recovery() THEN '当前角色: STANDBY（备节点）' ELSE '当前角色: PRIMARY（主节点）' END\""
            ;;
        2)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] 流复制延迟与同步状态"
            echo "----------------------------------------------------------"
            echo ">>> 流复制连接（仅主节点有输出）："
            docker exec -it "${CONTAINER}" su - postgres -c "psql -x -c \"
SELECT
    client_addr                                         AS 备节点地址,
    state                                               AS 状态,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS 复制延迟,
    sync_state                                          AS 同步模式,
    to_char(reply_time, 'HH24:MI:SS')                  AS 最后心跳
FROM pg_stat_replication;\""
            echo ""
            echo ">>> 本节点 WAL 接收状态（仅备节点有输出）："
            docker exec -it "${CONTAINER}" su - postgres -c "psql -x -c \"
SELECT
    status                                              AS 状态,
    pg_size_pretty(pg_wal_lsn_diff(received_lsn, written_lsn)) AS 写入延迟,
    pg_size_pretty(pg_wal_lsn_diff(written_lsn, flushed_lsn))  AS 刷盘延迟,
    to_char(last_msg_receipt_time, 'HH24:MI:SS')        AS 最后收包时间
FROM pg_stat_wal_receiver;\" 2>/dev/null || echo '（主节点无此视图，正常）'"
            ;;
        3)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] 在主库 (${DB_NAME}) 中写入测试数据"
            echo "----------------------------------------------------------"
            docker exec -it "${CONTAINER}" su - postgres -c "psql -d ${DB_NAME} -c \"
CREATE TABLE IF NOT EXISTS ha_test_sync (
    id serial PRIMARY KEY,
    data text,
    created_at timestamptz DEFAULT current_timestamp
);
INSERT INTO ha_test_sync (data) VALUES ('来自运维面板的测试写入 - $(date +\"%Y-%m-%d %H:%M:%S\")');
SELECT id, data, to_char(created_at,'HH24:MI:SS') AS 写入时间 FROM ha_test_sync ORDER BY id DESC LIMIT 3;\""
            echo "写入完成！可在备节点执行选项 4 验证数据是否同步。"
            ;;
        4)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] 在本节点 (${DB_NAME}) 中查询最近测试数据"
            echo "----------------------------------------------------------"
            docker exec -it "${CONTAINER}" su - postgres -c \
                "psql -d ${DB_NAME} -c \"SELECT id, data, to_char(created_at,'HH24:MI:SS') AS 时间 FROM ha_test_sync ORDER BY id DESC LIMIT 5;\"" \
                2>/dev/null || echo "[提示] 表不存在，说明主节点还未执行过选项 3。"
            ;;
        5)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] repmgr 日志（最近 50 行）"
            echo "----------------------------------------------------------"
            docker exec -it "${CONTAINER}" tail -n 50 /var/log/repmgr/repmgr.log
            ;;
        6)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] Keepalived 日志（最近 50 行）"
            echo "----------------------------------------------------------"
            docker exec -it "${CONTAINER}" tail -n 50 /var/log/repmgr/keepalived.log
            ;;
        7)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] repmgr 事件日志（主备切换历史）"
            echo "----------------------------------------------------------"
            docker exec -it "${CONTAINER}" cat /var/log/repmgr/events.log 2>/dev/null || \
                echo "[提示] 事件日志为空，尚未发生过故障转移。"
            echo ""
            echo ">>> repmgr 数据库中的事件记录："
            docker exec -it "${CONTAINER}" su - postgres -c "psql -d repmgr -c \"
SELECT node_id, event, successful,
       to_char(event_timestamp,'YYYY-MM-DD HH24:MI:SS') AS 时间,
       details
FROM repmgr.events
ORDER BY event_timestamp DESC LIMIT 20;\"" 2>/dev/null
            ;;
        8)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] 手动主备切换 (Switchover)"
            echo " 说明：在【备节点】上执行，将本节点提拔为主节点。"
            echo " 注意：需要两台宿主机之间配置 SSH 免密互通！"
            echo "----------------------------------------------------------"
            read -p "确认执行切换吗？(y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo "1. 检测切换前置条件..."
                docker exec -it "${CONTAINER}" su - postgres -c \
                    "repmgr standby switchover -f /etc/repmgr.conf --siblings-follow --dry-run"
                if [ $? -ne 0 ]; then
                    echo "[中止] dry-run 检测失败，切换取消。请检查 SSH 配置及集群状态。"
                    continue
                fi
                echo "2. 正式执行切换..."
                docker exec -it "${CONTAINER}" su - postgres -c \
                    "repmgr standby switchover -f /etc/repmgr.conf --siblings-follow"
                echo "切换指令已下发，请稍后使用选项 1 检查状态。"
                echo "[提示] 切换后 VIP 会自动跟随新主节点，约 5~10 秒完成漂移。"
            fi
            ;;
        9)
            check_container || continue
            echo "----------------------------------------------------------"
            echo " [操作] 重启容器内服务"
            echo "----------------------------------------------------------"
            echo "  a) 重启 Keepalived（VIP 管理）"
            echo "  b) 重启 repmgrd（故障检测守护进程）"
            echo "  c) 返回主菜单"
            read -p "请选择: " svc_choice
            case $svc_choice in
                a)
                    echo "正在重启 Keepalived..."
                    docker exec "${CONTAINER}" /usr/local/bin/keepalived-control.sh restart
                    sleep 2
                    if docker exec "${CONTAINER}" pgrep -x keepalived >/dev/null 2>&1; then
                        echo "✅ Keepalived 重启成功"
                        docker exec "${CONTAINER}" ip addr show eth0 | grep inet
                    else
                        echo "❌ Keepalived 重启失败，请查看日志（选项 6）"
                    fi
                    ;;
                b)
                    echo "正在重启 repmgrd..."
                    docker exec "${CONTAINER}" bash -c \
                        "pkill -f repmgrd 2>/dev/null; sleep 2; su - postgres -c 'repmgrd -f /etc/repmgr.conf --pid-file=/tmp/repmgrd.pid --daemonize'"
                    sleep 2
                    if docker exec "${CONTAINER}" pgrep -f repmgrd >/dev/null 2>&1; then
                        echo "✅ repmgrd 重启成功"
                    else
                        echo "❌ repmgrd 重启失败，请查看日志（选项 5）"
                    fi
                    ;;
                c) continue ;;
                *) echo "无效选择" ;;
            esac
            ;;
        10)
            check_container || true
            echo "----------------------------------------------------------"
            echo " [操作] 灾难恢复：重置并以 Standby 身份重新加入集群"
            echo " 警告：此操作将清空本地数据库数据，从对端主节点重新全量克隆！"
            echo " 说明：当前版本默认优先支持自动恢复。"
            echo " 仅在 pg_rewind / 自动回归失败、本地数据卷损坏时使用此操作。"
            echo "----------------------------------------------------------"
            read -p "请输入大写 YES 确认销毁本地数据: " confirm_del
            if [ "$confirm_del" = "YES" ]; then
                echo "正在停止容器..."
                compose_run -f "${STANDBY_COMPOSE_FILE}" down
                echo "正在销毁本地数据卷..."
                # 优先用当前目录名作前缀（Docker Compose 默认行为）
                VOL_NAME="$(basename "$PWD")_pgdata"
                docker volume rm "${VOL_NAME}" 2>/dev/null || \
                    docker volume rm "postgres-ha-cluster_pgdata" 2>/dev/null || \
                    echo "[提示] 未找到数据卷，可能已清理。"
                echo "重新启动容器（以备节点身份重新克隆中）..."
                compose_run -f "${STANDBY_COMPOSE_FILE}" up -d
                echo "恢复流程已启动，请稍后使用选项 1 查看同步状态。"
                echo "[提示] 首次启动需从主节点克隆数据，约需 1~3 分钟。"
            else
                echo "已取消。"
            fi
            ;;
        11)
            echo "----------------------------------------------------------"
            echo " [操作] 双节点同时断电后的推荐恢复顺序"
            echo "----------------------------------------------------------"
            echo " 1. 优先启动上次已知的主节点。"
            echo " 2. 如果无法确认谁是上次主节点，优先启动希望恢复为主节点的那台机器。"
            echo " 3. 等待该节点恢复完成并接管 VIP。"
            echo " 4. 再启动另一台机器，它会自动回归为 Standby。"
            echo ""
            echo ">>> 启动本机为主节点："
            printf '  %s -f %s up -d\n' "${COMPOSE_CMD[*]}" "${PRIMARY_COMPOSE_FILE}"
            echo ""
            echo ">>> 启动本机为备节点："
            printf '  %s -f %s up -d\n' "${COMPOSE_CMD[*]}" "${STANDBY_COMPOSE_FILE}"
            echo ""
            echo ">>> 恢复完成后检查集群："
            echo "  docker exec -it ${CONTAINER} su - postgres -c \"repmgr -f /etc/repmgr.conf cluster show\""
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
