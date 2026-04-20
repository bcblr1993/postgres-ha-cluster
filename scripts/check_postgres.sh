#!/bin/bash
# =============================================================================
# Keepalived 健康检查脚本
# 功能：检查本地 PostgreSQL 是否为 Primary (非 recovery 模式)
# 返回值：0 = Primary (健康)，1 = Standby 或不可达 (不健康)
# 被 Keepalived vrrp_script 每 2 秒调用一次
# =============================================================================

# 检查 PostgreSQL 是否可达
if ! pg_isready -q 2>/dev/null; then
    exit 1
fi

# 检查是否为 Primary（pg_is_in_recovery() 返回 f 表示 Primary）
PG_IS_IN_RECOVERY=$(su - postgres -c "psql -tAc \"SELECT pg_is_in_recovery()\"" 2>/dev/null)

if [ "$PG_IS_IN_RECOVERY" = "f" ]; then
    # 是 Primary 节点 - VIP 应该在此节点
    exit 0
else
    # 是 Standby 节点或无法获取状态 - VIP 不应在此节点
    exit 1
fi
