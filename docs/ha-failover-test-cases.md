# PostgreSQL 双机热备 — 主备切换全面测试用例

> 适用范围：本仓库 `postgres-ha:1.0` 镜像（PostgreSQL 15.4 + repmgr + Keepalived）
> 测试目标：A/B 两台节点在数据库层面的**主备切换正确性、角色收敛性、数据一致性**
> 测试环境：默认基于 `docker-compose-test.yml`（同宿主 bridge 网络），生产环境用 `docker-compose-primary/standby.yml` 时除非显式标注 `[宿主级]`，其余用例完全等价

---

## 0. 测试约定

### 0.1 环境与变量

| 变量 | 本地联调 (`docker-compose-test.yml`) | 生产 (`docker-compose-primary/standby.yml`) |
|---|---|---|
| Node1 IP | `172.40.0.11` | `.env` 中 `NODE_IP` |
| Node2 IP | `172.40.0.12` | `.env` 中 `PARTNER_IP` |
| VIP | `172.40.0.100` | `.env` 中 `NODE_VIP` |
| 容器名 | `pg-node1` / `pg-node2` | `.env` 中 `CONTAINER_NAME`（默认 `postgres-ha`）|
| DB | `thingsboard` | 同 |
| 端口 | `5432` | 同 |

下文统一记号：
- `$N1` = Node1 IP，`$N2` = Node2 IP，`$VIP` = VIP
- `$C1` / `$C2` = 两个容器名
- `$DB` = 业务库名
- `$PASSWORD` = postgres 超级用户密码

### 0.2 通用前置

每个用例开始前必须满足"基线 OK 状态"：
```
[基线-1] $C1 healthy 且 pg_is_in_recovery()=false
[基线-2] $C2 healthy 且 pg_is_in_recovery()=true
[基线-3] VIP 恰好绑在 $C1
[基线-4] $C1 上 pg_stat_replication 有 1 行 state=streaming，client_addr=$N2
[基线-5] $C2 上 pg_stat_wal_receiver.status=streaming
[基线-6] 双节点 timeline_id 相同
```

> 如基线不满足，先执行 `bash tests/reset-baseline.sh`（见附录 A.0）。

### 0.3 探针（贯穿所有切换类用例）

在第三方机器（或宿主）上以 VIP 为目标的写入探针，用于精确测量 RTO 与丢数：

```bash
# tests/probe.sh
export PGPASSWORD=$PASSWORD
psql -h $VIP -U postgres -d $DB -c \
  "CREATE TABLE IF NOT EXISTS ha_probe(seq bigserial PRIMARY KEY, ts timestamptz DEFAULT now())"

i=0
while true; do
  i=$((i+1))
  ts=$(date +%s.%N)
  if psql -h $VIP -U postgres -d $DB -v ON_ERROR_STOP=1 -tAc \
       "INSERT INTO ha_probe(seq) VALUES ($i)" >/dev/null 2>&1; then
    echo "$ts ok  $i"
  else
    echo "$ts err $i"
  fi
  sleep 0.2
done
```

### 0.4 通过判定 7 项硬指标（附录 B 详细 SQL）

每个切换类用例完成后，**必须同时满足 A~G 全部**：

```
[A] 全集群恰好 1 个 pg_is_in_recovery()=false
[B] VIP 恰好绑在该节点
[C] 该节点可通过 VIP 写入成功
[D] 另一节点 pg_stat_wal_receiver.status='streaming'
[E] 业务表 checksum 与"切换前 + 探针写入"一致
[F] repmgr.events 最新一条 event='standby_promote' AND successful=t
[G] 双节点 timeline_id 一致且较切换前 +1
```

### 0.5 优先级

- **P0**：上线前必跑、回归必跑
- **P1**：版本升级 / 配置变更必跑
- **P2**：季度演练

### 0.6 用例编号规则

```
TC-<域>-<编号>
域：BASE / REPL / FAIL / VIP / DATA / REJOIN / DUAL / NET / CYCLE / NOTIFY
```

---

## 1. 部署与基线（TC-BASE-*）

### TC-BASE-01：主节点首次启动

- **优先级**：P0
- **目的**：验证空目录下主节点能完成 PG 初始化、repmgr 注册、VIP 绑定
- **前置**：销毁所有数据卷 `docker volume rm $(docker volume ls -q | grep pgdata)`
- **步骤**：
  1. `docker compose -f docker-compose-test.yml up -d pg-node1`
  2. 等待 `docker inspect --format='{{.State.Health.Status}}' $C1` = `healthy`（≤ 60s）
- **期望**：
  - `psql -h $N1 -U postgres -tAc "SELECT pg_is_in_recovery()"` → `f`
  - `psql -h $N1 -U postgres -tAc "SELECT datname FROM pg_database WHERE datname='$DB'"` 返回 1 行
  - `docker exec $C1 ip -o addr | grep $VIP` 命中
  - `docker exec $C1 su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"` 显示 1 个 primary
- **通过**：以上四条全部满足
- **失败处理**：收集 `docker logs $C1`、`/var/log/repmgr/*`、容器内 `/var/lib/postgresql/data/log/*`

### TC-BASE-02：备节点首次启动并加入

- **优先级**：P0
- **目的**：验证备节点能从主节点全量克隆并建立流复制
- **前置**：TC-BASE-01 已通过
- **步骤**：
  1. `docker compose -f docker-compose-test.yml up -d pg-node2`
  2. 等待 `$C2` healthy（≤ 180s，含克隆时间）
- **期望**：
  - `psql -h $N2 -U postgres -tAc "SELECT pg_is_in_recovery()"` → `t`
  - 主上 `SELECT count(*) FROM pg_stat_replication WHERE state='streaming'` = 1
  - 备上 `SELECT status FROM pg_stat_wal_receiver` = `streaming`
  - `repmgr cluster show` 显示 primary + standby 各一
- **通过**：基线-1 至基线-6 全部满足

### TC-BASE-03：业务库与扩展自动创建

- **优先级**：P0
- **目的**：`POSTGRES_DB` 指定的初始业务库开箱即用
- **步骤**：连主写一行普通业务表
  ```sql
  CREATE TABLE bench(id int PRIMARY KEY, payload text);
  INSERT INTO bench VALUES (1,'hello');
  ```
- **期望**：备库 `SELECT * FROM bench` 返回相同行（≤ 1s）
- **通过**：备数据一致

### TC-BASE-04：repmgr 节点注册一致性

- **优先级**：P0
- **目的**：`repmgr.nodes` 表中两节点信息正确
- **步骤**：在主上执行
  ```sql
  SELECT node_id, node_name, type, upstream_node_id, active
  FROM repmgr.nodes ORDER BY node_id;
  ```
- **期望**：
  - 2 行，`type` 分别为 `primary` 与 `standby`
  - `active = true`
  - `standby` 的 `upstream_node_id` 等于 `primary` 的 `node_id`

### TC-BASE-05：同步/异步复制模式与项目设计一致

- **优先级**：P1
- **目的**：确认 `synchronous_commit` / `synchronous_standby_names` 与 `conf/postgresql.conf` 设计一致
- **步骤**：
  ```sql
  SHOW synchronous_commit;
  SHOW synchronous_standby_names;
  ```
- **期望**：与 [conf/postgresql.conf](../conf/postgresql.conf) 的设定一致；如为同步模式需在 `pg_stat_replication.sync_state='sync'`

---

## 2. 数据复制功能（TC-REPL-*）

### TC-REPL-01：主写、备读、毫秒级同步

- **优先级**：P0
- **步骤**：
  1. 主：`INSERT INTO ha_probe DEFAULT VALUES` 重复 1000 次
  2. 备：每 100ms 轮询 `SELECT count(*) FROM ha_probe`
- **期望**：备最终 count = 1000；落后 ≤ 1s

### TC-REPL-02：备节点写保护

- **优先级**：P0
- **步骤**：备执行 `INSERT INTO ha_probe DEFAULT VALUES`
- **期望**：报错 `cannot execute INSERT in a read-only transaction`

### TC-REPL-03：备节点 WAL receiver 异常重连

- **优先级**：P0
- **步骤**：
  1. 备容器：`docker exec $C2 pkill -f walreceiver`
  2. 等待 30s
- **期望**：备 `pg_stat_wal_receiver.status` 自动回到 `streaming`，无需人工介入

### TC-REPL-04：大事务复制不阻塞

- **优先级**：P1
- **步骤**：
  1. 主：`pgbench -i -s 20 -h $VIP -U postgres $DB`（约 2GB WAL）
  2. 期间备每秒采样 `pg_last_wal_receive_lsn()`
- **期望**：
  - 备 LSN 持续推进
  - `pg_size_pretty(pg_wal_lsn_diff(sent_lsn,replay_lsn))` 在主侧 < 100MB（同步）或 < 1GB（异步）

### TC-REPL-05：复制延迟基线

- **优先级**：P1
- **步骤**：稳态空载 5 min，每 10s 采样
  ```sql
  SELECT now() - reply_time AS lag, sync_state FROM pg_stat_replication;
  ```
- **期望**：`lag` 中位数 < 200ms

---

## 3. 切换触发场景（TC-FAIL-*）

> 所有 TC-FAIL-* 均启动探针，结束后跑附录 B 的 A~G 断言。

### TC-FAIL-01：优雅停主

- **优先级**：P0
- **故障注入**：`docker stop $C1`
- **期望**：
  - 30s 内 `$C2` 上 `pg_is_in_recovery()` 翻为 `f`
  - VIP 漂到 Node2
  - 探针 `err` 行连续段 < 30 行（即 RTO < 6s 视目标而定）
  - `repmgr.events` 出现 `standby_promote successful=t`
- **通过**：A~G 全部满足

### TC-FAIL-02：暴力崩溃主（SIGKILL）

- **优先级**：P0
- **故障注入**：`docker kill $C1`
- **期望**：同 TC-FAIL-01；`repmgrd` 走超时检测路径，RTO 通常略长于 01

### TC-FAIL-03：PG 进程死、容器活

- **优先级**：P0
- **故障注入**：`docker exec $C1 pkill -9 postgres`
- **期望**：
  - `check_postgres.sh` 健康检查失败 → keepalived 让出 VIP
  - 备升主、VIP 漂移
- **额外断言**：旧主容器仍在运行但无 PG 进程；下次 docker-entrypoint 重建时能识别角色变化（参考 TC-REJOIN-01）

### TC-FAIL-04：PG hang 假活

- **优先级**：P0
- **目的**：防止「PG 看似活着但不响应」导致的无切换悬挂
- **故障注入**：
  ```bash
  PID=$(docker exec $C1 pgrep -x postgres | head -1)
  docker exec $C1 kill -STOP $PID
  ```
- **期望**：
  - `check_postgres.sh` 超时 → keepalived 让出 VIP
  - 备升主成功
- **清理**：用例后 `kill -CONT $PID` 恢复（如需）

### TC-FAIL-05：主宿主断电 [宿主级]

- **优先级**：P0
- **故障注入**（仅生产环境可做）：直接拔电或 `echo b > /proc/sysrq-trigger`
- **期望**：备升主；旧主上电恢复后走 pg_rewind（参考 TC-REJOIN-01）
- **通过**：RTO ≤ 60s；A~G 全部满足

### TC-FAIL-06：keepalived 单独崩溃（不应触发切换）

- **优先级**：P0
- **目的**：验证不会"假切"
- **故障注入**：`docker exec $C1 pkill keepalived`
- **期望**：
  - 主 PG 仍可写
  - VIP 短暂漂到备（备的 keepalived 仍在 BACKUP→MASTER）
  - **但** `pg_is_in_recovery()` 双节点不变（备仍是 standby）
  - 重启 keepalived：`docker exec $C1 /usr/local/bin/keepalived-control.sh start`
  - VIP 通过 priority 抢占回 Node1
- **通过**：整个过程没有任何 promote 事件
- **关键**：`SELECT count(*) FROM repmgr.events WHERE event='standby_promote' AND event_timestamp > <开始时间>` = 0

### TC-FAIL-07：repmgrd 单独崩溃（不应影响数据面）

- **优先级**：P0
- **故障注入**：`docker exec $C1 pkill -f repmgrd`
- **期望**：
  - 主备角色不变，复制不中断
  - 重启 repmgrd 后事件订阅恢复
- **通过**：期间数据面 0 中断

---

## 4. VIP 顺序不变量（TC-VIP-*）

### TC-VIP-01：VIP 必在 promote 之后才漂移

- **优先级**：P0
- **目的**：项目核心承诺（README §6）—— **绝不**在新主完成 promote 之前把 VIP 漂过去
- **观察方法**：触发 TC-FAIL-02 期间，开启每 100ms 采样的并行观察脚本
  ```bash
  # tests/observe-vip-vs-role.sh
  while true; do
    ts=$(date +%s.%N)
    vip_on1=$(docker exec $C1 ip -o addr | grep -c $VIP)
    vip_on2=$(docker exec $C2 ip -o addr | grep -c $VIP)
    role1=$(docker exec $C1 su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null || echo "down")
    role2=$(docker exec $C2 su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null || echo "down")
    echo "$ts vip1=$vip_on1 vip2=$vip_on2 r1=$role1 r2=$role2"
    sleep 0.1
  done
  ```
- **期望**：不存在样本满足 `vip_on2=1 AND role2=t`（即 VIP 已到 Node2 但 Node2 还在 recovery）
- **通过**：上述违例样本数 = 0

### TC-VIP-02：切换瞬间客户端写入只命中新主

- **优先级**：P0
- **目的**：探针 `ok` 的写入要么在旧主、要么在新主，不会两边各有一半（错乱）
- **方法**：
  1. 探针运行
  2. 触发 TC-FAIL-01
  3. 切换完成后查 `SELECT seq FROM ha_probe ORDER BY seq` 检查序列连续性 + 检查每行所在 timeline
- **期望**：
  - `seq` 递增连续，无重复
  - 任何 `ok` 的探针 seq 必然在最终新主可见

### TC-VIP-03：VIP 全集群唯一性

- **优先级**：P0
- **持续断言**（每 1s 跑一次）：
  ```bash
  c1=$(docker exec $C1 ip -o addr | grep -c $VIP)
  c2=$(docker exec $C2 ip -o addr | grep -c $VIP)
  test $((c1+c2)) -le 1 || echo "FAIL: dup VIP at $(date)"
  ```
- **期望**：整个测试周期内**始终** `c1+c2 ≤ 1`；切换瞬间允许短暂 0
- **通过**：无任何 FAIL 输出

---

## 5. 数据一致性（TC-DATA-*）

### TC-DATA-01：探针无丢数

- **优先级**：P0
- **依附**：TC-FAIL-01/02/03/04 之后立即跑
- **方法**：
  ```bash
  ok_count=$(grep -c '^[0-9.]* ok ' rto.log)
  in_db=$(psql -h $VIP -U postgres -d $DB -tAc "SELECT count(*) FROM ha_probe")
  ```
- **期望**：`in_db >= ok_count`（探针 ok 写入全部存活）
- **通过**：等式成立

### TC-DATA-02：schema 完全一致

- **优先级**：P0
- **方法**：
  ```bash
  docker exec $C1 su - postgres -c "pg_dump --schema-only $DB" | sha256sum
  docker exec $C2 su - postgres -c "pg_dump --schema-only $DB" | sha256sum
  ```
- **期望**：两个 sha256 相同（注意：要在切换并稳定后采样）

### TC-DATA-03：业务表 checksum 一致

- **优先级**：P0
- **方法**：双节点同时跑
  ```sql
  SELECT count(*), md5(string_agg(seq::text, ',' ORDER BY seq)) FROM ha_probe;
  ```
- **期望**：双节点结果完全相同（备节点要等 LSN 追平）

### TC-DATA-04：同步提交事务在断电后存活

- **优先级**：P0
- **前置**：`synchronous_commit=on` 且有同步备机
- **方法**：
  1. 主开事务 `BEGIN; INSERT INTO ha_probe VALUES (-100); COMMIT;`，确认 `COMMIT` 返回成功
  2. **立即**对主执行 `docker kill -9` 模拟断电
  3. 备升主后查 `SELECT * FROM ha_probe WHERE seq=-100`
- **期望**：返回 1 行（已提交事务不丢）

### TC-DATA-05：时间线推进可解释

- **优先级**：P0
- **方法**：每次切换前后采样
  ```sql
  SELECT timeline_id FROM pg_control_checkpoint();
  ```
- **期望**：每次 promote 后，新主的 `timeline_id` = 切换前 + 1；老主重新加入后追到相同 timeline

---

## 6. 旧主回归（TC-REJOIN-*）

> README §9 专门针对此场景做过修复，必须重点验证。

### TC-REJOIN-01：短停旧主走 pg_rewind

- **优先级**：P0
- **步骤**：
  1. 触发 TC-FAIL-01 或 TC-FAIL-02
  2. 等切换完成 30s
  3. `docker start $C1`（或重新 `up -d`）
- **期望**：
  - $C1 容器在 30s 内恢复 healthy
  - `psql -h $N1 -U postgres -tAc "SELECT pg_is_in_recovery()"` → `t`
  - $C1 日志（`/var/log/repmgr/repmgr.log`）出现 `pg_rewind` 关键字，**没有**全量 clone 关键字
  - $C1 容器日志中可见 "node rejoin" 路径
- **通过**：rejoin 耗时 ≤ 10s（README 基线 4–5s，不含容器拉起时间）

### TC-REJOIN-02：长停旧主降级全量克隆

- **优先级**：P1
- **步骤**：
  1. 触发 TC-FAIL-01
  2. 在新主上人为加速 WAL 清理：
     ```sql
     CHECKPOINT;
     SELECT pg_switch_wal();  -- 多次执行
     ```
     或等 1h+
  3. 启动 $C1
- **期望**：
  - pg_rewind 失败 → 自动降级走 pg_basebackup 全量克隆
  - 日志中明确出现降级原因（如 `WAL not found`）
  - 最终成功成为 standby
- **通过**：A~G 全部满足；日志可解释

### TC-REJOIN-03：application_name 在新主侧正确显示

- **优先级**：P0
- **目的**：验证 README §9 修复点 #1
- **方法**：旧主回归后，新主上执行
  ```sql
  SELECT application_name, client_addr, state
  FROM pg_stat_replication;
  ```
- **期望**：`application_name` = 旧主的 `node_name`（如 `pg-node1`），不为空、不是 `walreceiver`

### TC-REJOIN-04：node_rejoin_timeout 边界

- **优先级**：P1
- **目的**：验证 README §9 修复点 #2 —— `node_rejoin_timeout=180`
- **方法**：
  1. 旧主启动前先暂停其网络 60s（`tc qdisc add dev eth0 root netem delay 100ms loss 5%`）
  2. 然后启动 $C1
- **期望**：rejoin 在最终 180s 内成功，不会因 60s 超时被误判
- **通过**：日志看到延迟但没有 `NODE REJOIN failed`

### TC-REJOIN-05：多次切换后旧主时间线落后回归

- **优先级**：P1
- **步骤**：
  1. 在 $C1 关停的情况下，触发 $C2→primary，再 switchover 回去若干轮（可让 $C2 多走几个 timeline）
  2. 启动 $C1
- **期望**：repmgr 报告 timeline mismatch，自动通过 pg_rewind 或 reclone 跨越多个 timeline 加入

---

## 7. 双机宕机收敛（TC-DUAL-*）

> README §8 承诺的语义。

### TC-DUAL-01：同时断电、先启原主

- **优先级**：P0
- **步骤**：
  1. 双机正常运行（基线 OK）
  2. 同时 `docker kill $C1 $C2`
  3. 30s 后 `docker start $C1`
  4. $C1 healthy 后 `docker start $C2`
- **期望**：
  - $C1 自检本地数据目录角色 = primary
  - 启动后绑 VIP，可写
  - $C2 启动后自动作为 standby 加入

### TC-DUAL-02：同时断电、先启原备（README 已验证场景）

- **优先级**：P0
- **步骤**：
  1. 同时 kill 双机
  2. 30s 后先 `docker start $C2`
  3. $C2 healthy 后 `docker start $C1`
- **期望**：
  - $C2 升为 primary，绑 VIP
  - $C1 启动时检测到对端已是 primary → 自动降级 standby 并通过 pg_rewind 加入
- **通过**：A~G 全部满足；最终 `repmgr cluster show` 显示 `pg-node2=primary`、`pg-node1=standby`

### TC-DUAL-03：错峰恢复 60s 间隔

- **优先级**：P1
- **目的**：避免两边都尝试当 primary 的瞬时窗口
- **步骤**：在 TC-DUAL-02 基础上把启动间隔拉到 60s，期间用 `tests/observe-vip-vs-role.sh` 持续采样
- **期望**：整段时间内 `pg_is_in_recovery()=false` 的节点数 ≤ 1

---

## 8. 网络故障（TC-NET-*）

> 在 `docker-compose-test.yml` 环境中用 `iptables` 或 `tc`，注意需要 `--cap-add=NET_ADMIN`（已有）。

### TC-NET-01：单向丢包（主→备）

- **优先级**：P0
- **故障注入**：
  ```bash
  docker exec $C1 iptables -A OUTPUT -d $N2 -j DROP
  ```
- **期望**：
  - 备的 WAL receiver 检测到流复制中断
  - repmgrd 根据策略决定是否升主（取决于 [conf/repmgr-node1.conf](../conf/repmgr-node1.conf) 中 `failover` 与 `degraded_monitoring` 配置）
  - 不出现两个 primary
- **清理**：`docker exec $C1 iptables -F`

### TC-NET-02：双向全断 5 分钟

- **优先级**：P0
- **故障注入**：双向 DROP
  ```bash
  docker exec $C1 iptables -A INPUT -s $N2 -j DROP
  docker exec $C1 iptables -A OUTPUT -d $N2 -j DROP
  docker exec $C2 iptables -A INPUT -s $N1 -j DROP
  docker exec $C2 iptables -A OUTPUT -d $N1 -j DROP
  ```
- **观察**：
  - 5 min 内：用 `tests/observe-vip-vs-role.sh` 采样
  - 解除分区后：观察哪一方降级
- **期望**：
  - 分区期间：**最多** 1 方持有 VIP（单宿主 bridge 网络下两方各自看到对端死，可能均尝试持有 VIP；这是已知限制，需要明确配置防止同 LAN 下双 master，参考 keepalived 配置中 priority + unicast_peer 设置）
  - 分区恢复后：双方角色冲突时，repmgr 介入降级一方
- **通过**：分区恢复后 A~G 全部满足；过程中无双写

### TC-NET-03：仅 PG 端口阻断

- **优先级**：P1
- **故障注入**：
  ```bash
  docker exec $C1 iptables -A INPUT -p tcp --dport 5432 -j DROP
  ```
- **期望**：repmgr 走 SSH（如配置）或心跳路径仍能通信；行为可解释、可配置

### TC-NET-04：高延迟抖动

- **优先级**：P1
- **故障注入**：
  ```bash
  docker exec $C1 tc qdisc add dev eth0 root netem delay 500ms 100ms loss 1%
  ```
- **期望**：
  - 不会因为短期抖动触发 promote
  - 流复制能维持，`pg_stat_replication.state=streaming`
- **清理**：`tc qdisc del dev eth0 root netem`

---

## 9. 反复切换稳定性（TC-CYCLE-*）

### TC-CYCLE-01：6 轮交替矩阵（已有自动化）

- **优先级**：P0
- **方法**：调用现有 `ha_external_matrix` 框架（参考 [ha_external_matrix_report.md](../ha_external_matrix_report.md)），跑 6 轮 graceful_stop + power_loss 交替
- **期望**：
  - 每轮 RTO 与 baseline 偏差 < 30%
  - timeline_id 单调 +1
  - 6 轮结束后 A~G 全部满足
- **通过**：报告 JSON 与基线对比无 regression

### TC-CYCLE-02：10 次连续 switchover

- **优先级**：P0
- **方法**：在备节点循环
  ```bash
  for i in $(seq 1 10); do
    docker exec $current_standby su - postgres -c \
      "repmgr standby switchover -f /etc/repmgr.conf --siblings-follow"
    # 等 30s 让 VIP 漂移与 rejoin 完成
    sleep 30
    # 切换 $current_primary 与 $current_standby
  done
  ```
- **期望**：
  - 每次 switchover dry-run + 实际执行均成功
  - 10 次后双节点都还能正常工作
  - timeline_id = 起始 + 10
- **通过**：A~G 全部满足；无失败 switchover

---

## 10. 通知（TC-NOTIFY-*）

### TC-NOTIFY-01：故障切换企业微信通知

- **优先级**：P1
- **前置**：`.env` 设置 `WECOM_NOTIFY_ENABLED=true` 与有效 `WECOM_WEBHOOK_URL`
- **方法**：触发 TC-FAIL-01
- **期望**：群机器人 ≤ 30s 内收到包含以下字段的卡片
  - 当前主节点（新主 node_name）
  - VIP
  - 可写状态
  - 本机物理 IP
- **通过**：消息送达且字段正确

### TC-NOTIFY-02：旧主回归通知

- **优先级**：P1
- **方法**：在 TC-NOTIFY-01 之后，启动旧主
- **期望**：群机器人收到「双节点拓扑已恢复」卡片，含「只读待机」字样

### TC-NOTIFY-03：webhook 故障容错

- **优先级**：P1
- **方法**：把 `WECOM_WEBHOOK_URL` 改成无效地址，触发切换
- **期望**：
  - 切换流程不被通知失败阻塞
  - `/var/log/repmgr/` 中可见 wecom-notify 失败日志
- **通过**：A~G 全部满足，只有通知失败

### TC-NOTIFY-04：@all 仅在 failover

- **优先级**：P2
- **方法**：`WECOM_NOTIFY_AT_ALL_ON_FAILOVER=true`
- **期望**：
  - 故障切换通知带 `@all`
  - 旧主回归通知不带 `@all`

---

## 附录 A：配套脚本

### A.0 重置基线
```bash
# tests/reset-baseline.sh
#!/usr/bin/env bash
set -euo pipefail
docker compose -f docker-compose-test.yml down -v
docker compose -f docker-compose-test.yml up -d pg-node1
until docker inspect --format='{{.State.Health.Status}}' pg-node1 | grep -q healthy; do sleep 2; done
docker compose -f docker-compose-test.yml up -d pg-node2
until docker inspect --format='{{.State.Health.Status}}' pg-node2 | grep -q healthy; do sleep 2; done
echo "baseline OK"
```

### A.1 切换前/后快照
```bash
# tests/snapshot.sh  用法: tests/snapshot.sh before|after
phase=$1
for c in pg-node1 pg-node2; do
  echo "=== $c ($phase) ==="
  docker exec $c su - postgres -c "psql -tA -c \"
    SELECT 'role',  pg_is_in_recovery();
    SELECT 'lsn',   coalesce(pg_current_wal_lsn()::text, pg_last_wal_replay_lsn()::text);
    SELECT 'tl',   timeline_id FROM pg_control_checkpoint();
    SELECT 'cnt',  count(*), md5(string_agg(seq::text,',' ORDER BY seq))
      FROM ha_probe;
  \"" 2>/dev/null || echo "$c down"
done > snapshot.$phase.txt
```

### A.2 七项断言
```bash
# tests/assert.sh  在切换稳定后跑
set -e
VIP=${VIP:-172.40.0.100}
DB=${DB:-thingsboard}

# A 角色唯一
roles=$(for c in pg-node1 pg-node2; do
  docker exec $c su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null
done | grep -c '^f$' || true)
[[ "$roles" == "1" ]] || { echo "FAIL [A] primary count=$roles"; exit 1; }

# B VIP 唯一
vipc=0
for c in pg-node1 pg-node2; do
  docker exec $c ip -o addr | grep -q "$VIP" && vipc=$((vipc+1)) || true
done
[[ "$vipc" == "1" ]] || { echo "FAIL [B] vip count=$vipc"; exit 1; }

# C VIP 可写
PGPASSWORD=$POSTGRES_PASSWORD psql -h $VIP -U postgres -d $DB -c \
  "INSERT INTO ha_probe(seq) VALUES (-999)" >/dev/null \
  || { echo "FAIL [C] vip not writable"; exit 1; }

# D 备复制 streaming
sb=$(for c in pg-node1 pg-node2; do
  r=$(docker exec $c su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null)
  if [[ "$r" == "t" ]]; then
    docker exec $c su - postgres -c "psql -tAc \"SELECT status FROM pg_stat_wal_receiver\""
  fi
done)
[[ "$sb" == "streaming" ]] || { echo "FAIL [D] wal_receiver=$sb"; exit 1; }

# E checksum 与 before 对比 (调用方负责传 before checksum)
# F repmgr.events 最新一条
ev=$(docker exec pg-node1 su - postgres -c "psql -d repmgr -tAc \"
  SELECT event||':'||successful FROM repmgr.events
  ORDER BY event_timestamp DESC LIMIT 1\"" 2>/dev/null \
  || docker exec pg-node2 su - postgres -c "psql -d repmgr -tAc \"
  SELECT event||':'||successful FROM repmgr.events
  ORDER BY event_timestamp DESC LIMIT 1\"")
[[ "$ev" == "standby_promote:t" ]] || { echo "FAIL [F] last event=$ev"; exit 1; }

# G timeline 一致
tls=$(for c in pg-node1 pg-node2; do
  docker exec $c su - postgres -c "psql -tAc 'SELECT timeline_id FROM pg_control_checkpoint()'" 2>/dev/null
done | sort -u | wc -l | tr -d ' ')
[[ "$tls" == "1" ]] || { echo "FAIL [G] timelines differ"; exit 1; }

echo "PASS A-G"
```

### A.3 VIP 顺序观察
见 TC-VIP-01 中的 `tests/observe-vip-vs-role.sh`。

---

## 附录 B：通过判定 7 项硬指标 SQL/命令对照

| 指标 | 命令/SQL |
|---|---|
| A 主唯一 | `for c in $C1 $C2; do docker exec $c su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'"; done` 中恰好 1 个 `f` |
| B VIP 唯一 | `for c in $C1 $C2; do docker exec $c ip -o addr; done \| grep -c $VIP` = 1 |
| C 可写 | `psql -h $VIP -U postgres -d $DB -c "INSERT INTO ha_probe(seq) VALUES(-999)"` 成功 |
| D 复制 | 备上 `SELECT status FROM pg_stat_wal_receiver` = `streaming` |
| E 数据 | `SELECT count(*), md5(string_agg(seq::text,',' ORDER BY seq)) FROM ha_probe` 双节点一致 |
| F 事件 | `SELECT event, successful FROM repmgr.events ORDER BY event_timestamp DESC LIMIT 1` = `standby_promote, t` |
| G 时间线 | `SELECT timeline_id FROM pg_control_checkpoint()` 双节点相同且 = 切换前 +1 |

---

## 附录 C：执行优先级与频率

| 频率 | 用例集合 |
|---|---|
| 每次代码改动 | TC-BASE-01/02、TC-REPL-01/02、TC-FAIL-01、TC-DATA-01/03 |
| 每次镜像构建 | 上述 + TC-FAIL-02/03/04、TC-VIP-01/02/03、TC-REJOIN-01/03 |
| 上线前 | 全部 P0 |
| 季度演练 | 全部 P0 + P1（含 TC-DUAL-*、TC-NET-02、TC-CYCLE-01） |

---

## 附录 D：测试结果记录模板

每个用例执行后写一条 JSON，与现有 `ha_external_matrix_report.json` 对齐：

```json
{
  "case_id": "TC-FAIL-01",
  "run_id": "20260429-001",
  "started_at": "2026-04-29T10:30:00+08:00",
  "duration_seconds": 28.4,
  "rto_seconds": 5.2,
  "vip_drift_seconds": 6.1,
  "rejoin_seconds": null,
  "assertions": {"A": "pass", "B": "pass", "C": "pass", "D": "pass", "E": "pass", "F": "pass", "G": "pass"},
  "probe_ok_count": 138,
  "probe_err_count": 26,
  "rows_in_db_after": 138,
  "data_loss_count": 0,
  "verdict": "PASS",
  "artifacts": ["rto.log", "snapshot.before.txt", "snapshot.after.txt", "docker-logs/*"]
}
```

---

## 附录 E：常见误判与排查

| 现象 | 可能原因 | 排查命令 |
|---|---|---|
| 切换后 VIP 双绑 | keepalived 单播 peer 未配 / 优先级一样 | `cat /etc/keepalived/keepalived.conf` |
| 切换后无 promote | repmgrd 未运行 | `docker exec $c pgrep -f repmgrd` |
| 旧主回归慢 | pg_rewind 找不到分歧点 → 走全量 | `tail -200 /var/log/repmgr/repmgr.log` |
| 复制不 streaming | `application_name` 不匹配 | 主上 `SELECT * FROM pg_stat_replication` |
| 探针 ok 数 > DB 行数 | 异步复制下断电丢数 | 检查 `synchronous_commit` 配置 |
| timeline 不一致 | 旧主未走 rejoin 直接启 PG | 走 TC-REJOIN-02 路径或 ops.sh 选项 10 |
