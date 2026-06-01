# PostgreSQL 双机热备测试场景总览

> 目标：把双机热备的关键验收场景整理成一份可执行、可复盘的测试矩阵。更细的命令级用例见 [ha-failover-test-cases.md](ha-failover-test-cases.md)。

## 1. 测试目标

- 验证 PostgreSQL 主备角色能正确收敛，任意时刻最多一个 `primary`。
- 验证 VIP 始终跟随当前 `primary`，应用只需要连接 VIP。
- 验证正常停止、突然断电、双节点同时断电后集群可以恢复。
- 验证旧主回归优先走 `pg_rewind / repmgr node rejoin`，必要时才全量 clone。
- 验证全量 clone 失败不会提前删除原 `current` 数据目录。
- 验证多次全量 clone 成功后只保留最新一份旧数据。
- 验证 `docker logs -f postgres-ha` 能看到启动、切换、clone、VIP、企业微信通知等关键日志。

## 2. 核心验收口径

| 检查项 | 通过标准 |
| --- | --- |
| 主备角色 | 只有一个节点 `pg_is_in_recovery() = false` |
| VIP | VIP 只出现在当前主节点，备节点不持有 VIP |
| 可写入口 | 通过 VIP 写入成功，直接连备库只读 |
| 数据一致性 | 主备 `count(*) / max(id) / sum(id)` 一致 |
| 复制状态 | 主库 `pg_stat_replication.state = streaming` |
| 旧主回归 | 旧主恢复后变为 standby，repmgr 节点状态 active |
| Clone 失败保护 | clone 失败时原 `current` 仍存在，并出现等待主库恢复日志 |
| Clone 成功保留 | 只存在一份 `pg-ha-retained-before-clone/latest` |
| 日志可观测 | 关键事件均能通过 `docker logs -f postgres-ha` 看到 |
| 企业微信 | promote / rejoin 事件按配置发送成功或明确记录失败原因 |

## 3. 场景矩阵

| 编号 | 场景 | 操作 | 重点观察 | 预期结果 |
| --- | --- | --- | --- | --- |
| S01 | 首次启动主节点 | 启动 Node1 primary | 初始化、repmgr 注册、VIP 绑定 | Node1 为 primary，VIP 在 Node1 |
| S02 | 首次启动备节点 | 启动 Node2 standby | standby clone、注册、WAL receiver | Node2 为 standby，复制 streaming |
| S03 | 持续写入同步 | 通过 VIP 持续插入大批数据 | WAL LSN、复制延迟、数据量 | 主备最终数据一致 |
| S04 | 正常停止主库 | `docker stop` 当前 primary | promote、VIP 漂移、通知 | 备库升主，VIP 跟随新主 |
| S05 | 突然断电主库 | `docker kill` 当前 primary | 故障检测、RTO、旧主回归 | 新主可写，旧主恢复为 standby |
| S06 | PostgreSQL 进程异常 | 停止容器内 PostgreSQL 进程 | Keepalived 释放 VIP、repmgr promote | VIP 不提前漂到只读节点 |
| S07 | 双节点同时断电 | 同时停止/kill 两个节点后恢复 | 恢复顺序、最终角色 | 最终只有一个 primary，VIP 跟随 primary |
| S08 | 旧主快速回归 | 故障后恢复旧主 | `pg_rewind`、`node rejoin` 日志 | 优先增量回归，避免不必要全量 clone |
| S09 | WAL/时间线差异过大 | 制造 timeline/WAL 不可追 | fallback 日志、clone 耗时 | 自动降级全量 clone 并重新加入 |
| S10 | 全量 clone 中主库断电 | standby clone 过程中 kill primary | `standby_clone_failed`、原 current | 原数据保留，等待主库恢复 |
| S11 | 全量 clone 成功激活 | 主库恢复后重新 clone | clone size、elapsed、activated | clone 成功后切换 current |
| S12 | 多次全量 clone | 连续触发多次成功 clone | retained 目录数量 | 始终只保留最新一份旧数据 |
| S13 | VIP 顺序不变量 | 高频采样角色和 VIP | promote 与 VIP 时间顺序 | VIP 只在新主完成 promote 后出现 |
| S14 | 企业微信通知 | 开启 webhook 后切换 | `wecom_notify_success/failed` | 成功发送或明确失败原因 |
| S15 | 日志时区一致 | 查看容器时间和 PostgreSQL `TimeZone` | `date`、`current_setting('TimeZone')` | 容器和 PG 均为预期时区 |
| S16 | 大数据压力切换 | 大量持续写入下重复切换 | 切换耗时、数据一致性、日志量 | 可收敛，日志不过度刷屏 |
| S17 | 备份风险确认 | 模拟误删/误改 | 主备复制行为 | 误操作会同步到备库，需独立备份 |

## 4. 推荐执行顺序

1. 先执行 `S01 ~ S03`，确认基础主备复制和 VIP 可写。
2. 再执行 `S04 ~ S08`，覆盖常规故障切换和旧主回归。
3. 再执行 `S09 ~ S12`，重点验证全量 clone、安全保留和失败保护。
4. 最后执行 `S13 ~ S16`，做顺序不变量、通知、日志和大写入压力验证。
5. `S17` 属于生产风险确认，不是 HA 自动恢复能力，必须在上线评审中单独说明。

## 5. 最近一次压力验证摘要

最近一次外部数据卷回归中，重点覆盖了正常停止、突然断电、双节点同时断电、大量持续写入、企业微信通知、clone 失败保护和多次 clone 成功保留策略。

| 项目 | 结果 |
| --- | --- |
| 总切换轮次 | 33 轮 |
| 有效大写入切换轮次 | 19 轮 |
| 最终数据量 | 13,923,000 行 |
| VIP 跟随异常 | 0 次 |
| 主备数据不一致 | 0 次 |
| 当前最终角色 | Node2 primary，Node1 standby |
| Clone 失败保护 | 通过，原 `current` 保留 |
| Clone 成功保留策略 | 通过，仅保留最新一份旧数据 |
| 企业微信发送失败 | 未发现失败日志 |

> 注意：当前方案是异步复制。故障时可以保证最终主备收敛一致，但不能承诺 `RPO=0`，旧主断电前尚未复制到备库的事务仍可能丢失。

## 6. 关键日志关键词

排查时优先过滤这些关键词：

```text
ha_state_snapshot
standby_clone_workspace_ready
standby_clone_done
standby_clone_failed
standby_clone_interrupted_waiting_primary
standby_clone_previous_retained_replaced
standby_clone_activated
old_primary_rejoin_fallback
keepalived_state_change
vip_present
service_available
wecom_notify_success
wecom_notify_failed
```

## 7. 常用结果记录模板

| 轮次 | 场景 | 原主 | 新主 | 切换耗时 | 回归耗时 | VIP 所在 | 数据一致 | 企业微信 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | normal_stop | Node1 | Node2 |  |  |  |  |  |  |
| 2 | power_off | Node2 | Node1 |  |  |  |  |  |  |
| 3 | both_power | Node1 | Node1/Node2 |  |  |  |  |  |  |
