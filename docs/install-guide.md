# PostgreSQL HA 双机热备 — 安装使用手册

> 基于 Docker + repmgr + Keepalived 实现的 PostgreSQL 高可用集群。  
> 应用程序只需连接一个**虚拟 IP（VIP）**，主节点故障后备节点自动接管，VIP 自动漂移，业务无需改配置。

---

## 一、环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Linux（CentOS 7+、Ubuntu 20.04+） |
| Docker | 20.10+ |
| Docker Compose | 支持 v2.x `docker compose`，也兼容旧版 `docker-compose` |
| 网络 | 两台机器在**同一局域网**，三个 IP 需提前规划好 |
| 权限 | root 或具有 docker 权限的用户 |

---

## 二、IP 规划

部署前需要确定三个 IP 地址，全程不再改动：

| 名称 | 说明 | 示例 |
|------|------|------|
| 主节点物理 IP | 机器 1 的固定 IP | `192.168.1.11` |
| 备节点物理 IP | 机器 2 的固定 IP | `192.168.1.12` |
| 虚拟 IP（VIP） | 应用连接的统一入口，不属于任何一台机器 | `192.168.1.100` |

> **VIP 必须与两台机器在同一网段，且当前未被任何设备占用。**

---

## 三、安装步骤

### 3.1 解压安装包

分别在**主节点机器**和**备节点机器**上操作：

**主节点机器：**
```bash
tar -zxf postgres-ha-primary.tar.gz
cd primary-node
```

**备节点机器：**
```bash
tar -zxf postgres-ha-standby.tar.gz
cd standby-node
```

### 3.2 修改配置文件（两台机器都要改，内容完全一样）

编辑目录下的 `.env` 文件：

```bash
vi .env
```

按实际情况填写以下内容：

```dotenv
# 虚拟 IP（应用连接这个 IP）
NODE_VIP=192.168.1.100

# 业务数据库名称
POSTGRES_DB=thingsboard

# 数据库密码（postgres 超级用户）
POSTGRES_PASSWORD=your_strong_password

# PostgreSQL 端口（默认 5432）
PG_PORT=5432

# 企业微信切换通知（可选）
WECOM_NOTIFY_ENABLED=false
WECOM_WEBHOOK_URL=
WECOM_NOTIFY_SITE_NAME=xxxx现场
WECOM_NOTIFY_TIMEOUT=10
WECOM_NOTIFY_AT_ALL_ON_FAILOVER=false

# 机器 1（主节点）的物理 IP
NODE_IP=192.168.1.11

# 机器 2（备节点）的物理 IP
PARTNER_IP=192.168.1.12
```

> ⚠️ **两台机器的 `.env` 内容完全相同，复制粘贴即可，不需要区分主备填写。**
>
> 如果需要企业微信通知，请把 `WECOM_NOTIFY_ENABLED` 改为 `true`，并填写 `WECOM_WEBHOOK_URL` 和 `WECOM_NOTIFY_SITE_NAME`。

### 3.3 导入 Docker 镜像

在**每台机器**上执行（需要一点时间，请耐心等待）：

```bash
./install.sh
```

成功后会显示：
```
[成功] 镜像导入完成！
```

### 3.4 启动服务

> **必须先启动主节点，等待约 30 秒后再启动备节点。**
>
> 说明：交付包中的 `start.sh` 会自动识别现场环境使用 `docker compose` 还是 `docker-compose`，无需手工修改脚本。

**第一步 — 主节点机器：**
```bash
./start.sh
```

等待约 30 秒，确认主节点已就绪：
```bash
docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
```

输出中看到 `primary * running` 即表示主节点已就绪：
```
 ID | Name     | Role    | Status    | Upstream |
----+----------+---------+-----------+----------+
  1 | pg-node1 | primary | * running |          |
```

**第二步 — 备节点机器：**
```bash
./start.sh
```

备节点会自动从主节点克隆数据（约需 1~3 分钟，取决于数据量大小）。

---

## 四、验证部署结果

在任意一台机器上执行以下检查：

**① 集群拓扑正常**
```bash
docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
```

预期输出（两个节点都是 `running`）：
```
 ID | Name     | Role    | Status    | Upstream |
----+----------+---------+-----------+----------+
  1 | pg-node1 | primary | * running |          |
  2 | pg-node2 | standby |   running | pg-node1 |
```

**② VIP 在主节点上**
```bash
# 在主节点机器执行
docker exec -it postgres-ha ip addr show eth0(注意更换网卡名称) | grep inet
```

能看到 VIP 地址（如 `172.40.0.100`）说明正常：
```
inet 192.168.1.11/24 ...
inet 192.168.1.100/24 ...   ← VIP 在这里
```

**③ 通过 VIP 可以连接数据库**
```bash
psql -h 192.168.1.100 -U postgres -d thingsboard -c "SELECT version();"
```

---

## 五、日常运维

所有日常操作均可通过运维控制台完成：

```bash
./ops.sh
```

控制台菜单说明：

```
1) 查看集群完整健康状态        ← 日常巡检，最常用
2) 查看流复制延迟与同步状态    ← 确认备节点数据是否跟上
3) [主节点] 写入一条测试数据   ← 验证主库可写
4) [备节点] 查询测试数据       ← 验证数据同步到备库
5) 查看 repmgr 日志           ← 排查故障转移问题
6) 查看 Keepalived 日志       ← 排查 VIP 漂移问题
7) 查看主备切换历史记录        ← 查看历次切换时间和原因
8) 手动主备切换（Switchover）  ← 计划内切换，需 SSH 互通
9) 重启容器内服务              ← keepalived / repmgrd 单独重启
10) 强制销毁本地数据并重建为 Standby（最后手段）
11) 查看双节点同时断电后的推荐恢复顺序
```

---

## 六、故障转移说明

### 自动故障转移（主节点宕机）

无需任何手动操作，系统自动完成：

```
主节点宕机
    ↓（约 30 秒，repmgr 检测）
备节点自动提升为新主节点
    ↓（完成 promote 后）
VIP 自动漂移到新主节点
    ↓
应用通过 VIP 恢复连接，业务继续
```

当前版本中，VIP 只会在本机数据库角色已经成为 `primary` 后才会被 Keepalived 接管，不会再出现 VIP 先于数据库主角色漂移的问题。

### 旧主节点恢复后的处理

旧主节点重新上线后，会**自动以备节点身份重新加入集群**，VIP 不会被它抢回（`nopreempt` 机制保证）。

若旧主节点的数据与新主节点差距过大，无法自动同步，再执行运维控制台选项 `10` 强制重建为 `standby`。该操作属于最后手段，常规恢复不需要先清空数据卷。

当前版本中，旧主恢复会优先尝试：

1. 通过 `pg_rewind` 回退时间线分叉。
2. 通过 `repmgr node rejoin` 挂回新的主节点。
3. 只有在旧主无法重新建立流复制时，才会降级为全量克隆。

为降低“旧主恢复特别慢”或被误判为失败的概率，当前版本额外做了两项处理：

1. `repmgr conninfo` 中显式增加了 `application_name=<node_name>`，确保新主可以在 `pg_stat_replication` 中准确识别旧主回归连接。
2. `node_rejoin_timeout` / `standby_reconnect_timeout` 已调整为 `180` 秒，避免旧主恢复时因为连接建立略慢而被过早判定失败。

### 企业微信通知（可选）

启用企业微信通知后，系统会在以下场景主动发送 Markdown 消息：

1. 自动故障切换完成
2. 旧主节点回归为 `standby`

通知内容包含：

1. 现场名称
2. 当前主节点
3. 当前节点角色
4. VIP 是否已接管
5. 数据库是否可写
6. 本机物理 IP、对端物理 IP、宿主机名
7. PostgreSQL / Keepalived 当前状态

如果配置了 `WECOM_NOTIFY_AT_ALL_ON_FAILOVER=true`，则自动故障切换告警会额外带 `<@all>` 提醒。建议 `WECOM_NOTIFY_TIMEOUT` 不低于 `10` 秒。

### 双节点同时宕机后的恢复

推荐恢复顺序如下：

1. 优先启动上次已知的主节点。
2. 如果无法确认谁是上次主节点，优先启动您希望恢复为主节点的那台机器。
3. 等待第一台机器完成 PostgreSQL 启动、`repmgr` 注册以及 VIP 接管。
4. 再启动另一台机器，它会自动识别本地数据目录角色，并根据对端状态回归为 `primary` 或 `standby`。

已完成的回归验证包括：

1. 连续 3 轮主备切换后，集群仍可正常收敛。
2. 两个节点同时宕机后，`pg-node2` 先恢复、`pg-node1` 后恢复，最终可自动收敛为 `pg-node2=primary`、`pg-node1=standby`。
3. 在上述过程中，VIP 始终跟随当前 `primary`，测试数据保持一致。

### 最近一次完整回归结果（6 轮切换 + 全断电恢复）

最近一轮完整回归覆盖了：

1. 连续 `6` 轮主备切换。
2. `VIP` 跟随检查。
3. 旧主自动回归检查。
4. 双节点同时断电后的恢复。
5. 最终数据一致性校验。

切换耗时结果如下：

1. `round1`：`pg-node1 -> pg-node2`，切换 `22s`，旧主回归 `187s`
2. `round2`：`pg-node2 -> pg-node1`，切换 `22s`，旧主回归 `4s`
3. `round3`：`pg-node1 -> pg-node2`，切换 `22s`，旧主回归 `5s`
4. `round4`：`pg-node2 -> pg-node1`，切换 `22s`，旧主回归 `4s`
5. `round5`：`pg-node1 -> pg-node2`，切换 `23s`，旧主回归 `5s`
6. `round6`：`pg-node2 -> pg-node1`，切换 `24s`，旧主回归 `4s`

双节点同时断电恢复结果如下：

1. 先恢复 `pg-node1`：`9s` 内恢复为 `primary` 并接管 `VIP`
2. 再恢复 `pg-node2`：`4s` 内回归为 `standby`

最终一致性结果如下：

1. 最终主节点：`pg-node1`
2. 最终备节点：`pg-node2`
3. `VIP` 在主节点：`yes`
4. 备节点不持有 `VIP`：`yes`
5. 主备两侧测试数据哈希一致：
   `22:d31f77c8755dbafee7ba9d8cb3e01ec0`

结论：

1. 自动切换耗时稳定在 `22s~24s`
2. `VIP` 始终跟随当前 `primary`
3. 双节点同时断电后的恢复路径可用
4. 数据一致性校验通过
5. 第 1 轮旧主回归时间较长，其后回归时间稳定在 `4s~5s`

### 网络分区（链路中断）场景说明

网络分区指的是：

1. 两台机器本身都还在运行
2. 但两台机器之间的网络链路中断，彼此无法访问
3. 或者 VRRP / PostgreSQL / repmgr 使用的网络出现单向或双向不通

典型表现包括：

1. 两台机器都能登录，但互相 `ping` 不通
2. `repmgr cluster show` 提示对端 `unreachable`
3. VIP 漂移结果和您预期不一致
4. 一侧业务还能写，另一侧日志里也开始尝试提升为 `primary`

> 重要：当前这套双节点架构对“节点宕机”恢复较完善，但对“网络分区”不能像三节点仲裁架构那样自动、可靠地避免脑裂。  
> 一旦怀疑是网络分区，请按**人工接管故障**处理，而不要把它当作普通自动切换场景。

推荐处理原则：

1. 先判断是“机器宕机”还是“链路中断”。
2. 如果两台机器都还活着，只是互相不通，优先保留一侧为唯一写主。
3. 另一侧必须停止对外写服务，必要时直接停容器。
4. 待网络恢复后，再让被保留的一侧作为主节点，另一侧重新回归 `standby`。

推荐处理步骤：

1. 分别登录两台机器，确认机器都在线。
2. 执行运维控制台选项 `1`，记录两边看到的角色和 VIP 情况。
3. 明确当前业务实际连接的是哪一侧，或哪一侧仍持有 VIP 并且可写。
4. 选定这一侧作为**唯一保留主节点**。
5. 在另一侧执行停容器操作，避免继续提供写服务：
   ```bash
   docker compose down
   ```
   旧版 Docker 写法：
   ```bash
   docker-compose down
   ```
6. 等网络恢复后，在保留主节点的一侧确认其仍为 `primary` 且 VIP 正常。
7. 再到被停掉的一侧重新启动容器，让它自动回归为 `standby`：
   ```bash
   ./start.sh
   ```
8. 如果自动回归失败，再使用运维控制台选项 `10` 强制重建为 `standby`。

判断哪一侧可以保留为主，建议优先按以下顺序判断：

1. 当前业务仍在正常写入的那一侧
2. 当前仍持有 VIP 且数据库可写的那一侧
3. 您确认数据最新、业务连接未中断的那一侧

不建议的操作：

1. 在网络分区尚未排除前，手工把两边都启动成可写主库
2. 仅凭“某一侧看不到对端”就立即认定对端已经宕机
3. 在没有确认唯一主节点前，直接让业务切到另一侧继续写入

### 计划内切换（手动 Switchover）

如需有计划地将主节点切换回原始机器，在备节点上执行运维控制台选项 `8`。  
> 注意：此操作要求两台宿主机之间已配置 SSH 免密登录。

---

## 七、应用接入

应用程序连接数据库时，**统一使用 VIP 地址**，无需关心哪台是主节点：

```
Host:     192.168.1.100   ← VIP，永远指向当前主节点
Port:     5432
Database: thingsboard
User:     postgres
Password: （.env 中配置的密码）
```

ThingsBoard 等应用的 JDBC 连接串示例：
```
jdbc:postgresql://192.168.1.100:5432/thingsboard
```

---

## 八、常见问题

**Q：备节点启动后一直显示 `unhealthy`，怎么办？**  
A：备节点需要从主节点克隆数据，若数据量较大可能需要数分钟。可执行以下命令查看进度：
```bash
docker logs -f postgres-ha
```

**Q：现场机器没有 `docker compose`，只有 `docker-compose`，能用吗？**  
A：可以。当前交付包中的 `install.sh`、`start.sh`、`ops.sh` 都会自动识别新旧 Compose 命令。若您手工执行命令，也可以把文档中的 `docker compose` 等价替换为 `docker-compose`。

**Q：两台机器都启动了，但集群显示只有一个节点？**  
A：检查两台机器的网络是否互通（互相 `ping` 对方 IP），以及防火墙是否开放了 5432 端口。

**Q：VIP 无法 ping 通？**  
A：在主节点机器上确认 Keepalived 进程在运行：
```bash
docker exec postgres-ha pgrep -a keepalived
```
若无输出，使用运维控制台选项 `9` 重启 Keepalived。

**Q：主节点恢复后想切换回来，怎么做？**  
A：使用运维控制台选项 `8`（Switchover），或直接停止当前主节点触发自动故障转移（备节点会自动接管）。

**Q：两台机器同时断电后，应该先启动哪一台？**  
A：优先启动上次已知的主节点；如果无法确认，就先启动您希望恢复为主节点的那台。等它完成启动并接管 VIP 后，再启动另一台机器，让其自动回归为 `standby`。

**Q：什么叫网络分区？现场一般怎么发现？**  
A：网络分区就是两台机器都活着，但它们之间的链路断了，彼此看不到对方。常见现象是：两边都能登录、互相 `ping` 不通、`repmgr cluster show` 提示对端 `unreachable`，或者一边业务还能写、另一边也开始尝试升主。

**Q：网络分区时，这套系统能自动安全恢复吗？**  
A：不能完全依赖自动恢复。当前双节点架构没有第三方仲裁，网络分区时存在脑裂风险。遇到这类故障，应按人工接管场景处理，而不是把它当作普通节点宕机。

**Q：网络分区时我应该怎么运维？**  
A：先选定一侧作为唯一保留主节点，原则上优先保留“当前业务仍在写入、仍持有 VIP、数据最新”的那一侧；另一侧立刻执行 `docker compose down`（旧版是 `docker-compose down`）停止对外服务。等网络恢复后，再启动被停的一侧，让它自动回归为 `standby`；若自动回归失败，再使用运维控制台选项 `10` 强制重建。

**Q：网络恢复后，怎么确认容器已经手动恢复正常？**  
A：恢复后至少检查以下三项：
```bash
docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
docker exec -it postgres-ha ip addr show eth0 | grep inet
docker exec -it postgres-ha su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'"
```
预期结果是：一侧显示 `primary` 且持有 VIP，另一侧显示 `standby`，并且 `pg_is_in_recovery()` 分别返回 `f` / `t`。

**Q：现场最常用的基础运维命令有哪些？**  
A：建议至少掌握以下几类：
```bash
# 1. 查看容器状态
docker ps -a | grep postgres-ha

# 2. 启动 / 停止当前节点容器
./start.sh
docker compose down

# 旧版 Docker Compose 写法
docker-compose down

# 3. 查看当前主备拓扑
docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"

# 4. 查看本机是否主库（f=primary, t=standby）
docker exec -it postgres-ha su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'"

# 5. 查看本机是否持有 VIP
docker exec -it postgres-ha ip addr show eth0 | grep inet

# 6. 查看数据库是否可写
docker exec -it postgres-ha su - postgres -c "psql -tAc 'SELECT NOT pg_is_in_recovery()'"

# 7. 查看复制状态 / 延迟
docker exec -it postgres-ha su - postgres -c "psql -x -c 'SELECT * FROM pg_stat_replication'"
docker exec -it postgres-ha su - postgres -c "psql -x -c 'SELECT * FROM pg_stat_wal_receiver'" 2>/dev/null

# 8. 查看 PostgreSQL / repmgr / keepalived 最近日志
docker logs --tail 200 postgres-ha
docker exec -it postgres-ha tail -n 100 /var/log/repmgr/repmgr.log
docker exec -it postgres-ha cat /var/log/repmgr/events.log
docker exec -it postgres-ha pgrep -a keepalived

# 9. 检查数据库连通性
docker exec -it postgres-ha pg_isready -h 127.0.0.1 -p 5432

# 10. 导出业务库（大故障前先留证据）
docker exec -it postgres-ha su - postgres -c "pg_dump thingsboard -f /tmp/thingsboard.sql"
```

如果您平时只想记最关键的 4 条，优先记下面这组：

```bash
docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
docker exec -it postgres-ha su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'"
docker exec -it postgres-ha ip addr show eth0 | grep inet
docker logs --tail 200 postgres-ha
```

**Q：如果我想“强制让一台机器重新同步主库数据”，应该怎么做？**  
A：分三种情况处理：

1. 如果只是旧主刚恢复，优先直接启动容器，让它自动回归：
```bash
./start.sh
```

2. 如果自动回归失败，但您确认另一侧已经是唯一主节点，可使用运维控制台选项 `10` 强制重建为 `standby`。

3. 如果您要手工执行，步骤等价于：
```bash
# 在要被重建为 standby 的那一侧执行
docker compose down
docker volume rm $(basename "$PWD")_pgdata
docker compose up -d
```
旧版 Docker 写法：
```bash
docker-compose down
docker volume rm $(basename "$PWD")_pgdata
docker-compose up -d
```
> 这会丢弃本机现有数据目录，只保留对端主节点上的数据，所以只能在您已经确认“另一侧是唯一正确主库”时使用。

执行强制重同步前，建议先多做两步确认：

```bash
# 1. 在保留主节点的一侧确认它确实是 primary
docker exec -it postgres-ha su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'"

# 2. 在待重建节点这一侧先导出一次日志或业务库，避免误删
docker logs postgres-ha > postgres-ha-before-rebuild.log 2>&1
docker exec -it postgres-ha su - postgres -c "pg_dump thingsboard -f /tmp/thingsboard-before-rebuild.sql"
```

**Q：如果怀疑发生脑裂，我还能保证不丢失数据吗？**  
A：如果脑裂期间只有一侧继续写入，通常可以通过 `pg_rewind` 或重建把另一侧拉回，不一定丢数据。  
但如果脑裂期间**两侧都接受了写入**，则不能保证“自动恢复且完全不丢数据”。这是 PostgreSQL 双主分叉后的通用限制，不是当前脚本单独造成的。

**Q：脑裂后，怎样尽量不丢数据地恢复？**  
A：建议按以下顺序操作：

1. 立即停止其中一侧，避免继续双写：
```bash
docker compose down
```

2. 先保留现场证据和可能分叉的数据：
```bash
# 导出当前容器日志
docker logs postgres-ha > postgres-ha.log 2>&1

# 如果故障侧还能启动，先导出业务库
docker exec -it postgres-ha su - postgres -c "pg_dump thingsboard -f /tmp/thingsboard.sql"
```

3. 选定一侧作为唯一保留主节点，原则上优先保留：
   - 当前业务仍在写入的一侧
   - 当前持有 VIP 且可写的一侧
   - 您确认数据最新的一侧

4. 将另一侧作为待恢复节点：
   - 先尝试自动回归
   - 自动回归失败，再用选项 `10` 强制重建为 `standby`

5. 如果两侧都发生过业务写入，而您又不能接受丢弃其中一侧的写入：
   - 不要立即重建
   - 先对两侧分别做逻辑导出
   - 再由业务或 DBA 手工比对差异数据并补录

现场可以按这组命令执行：

```bash
# 第 1 步：先在一侧停服务，阻止继续双写
docker compose down

# 第 2 步：在两侧分别留取日志
docker logs postgres-ha > postgres-ha.log 2>&1

# 第 3 步：如果容器还能启动，分别导出业务库
docker exec -it postgres-ha su - postgres -c "pg_dump thingsboard -f /tmp/thingsboard.sql"

# 第 4 步：在两侧分别确认谁是 primary / 是否持有 VIP
docker exec -it postgres-ha su - postgres -c "psql -tAc 'SELECT pg_is_in_recovery()'"
docker exec -it postgres-ha ip addr show eth0 | grep inet
```

如果最终判断“只有一侧发生过写入”，另一侧可以直接作为待恢复节点重建。  
如果最终判断“两侧都写过”，就不要追求脚本自动收敛，而是先做导出、对比、补录，再重建其中一侧。

**Q：脑裂后为什么不能直接“强制双向同步”把两边数据合并？**  
A：当前这套方案是单主复制，不是多主冲突合并架构。`repmgr` / `pg_rewind` 的设计目标是“选定一侧为准，另一侧回归”，不是自动合并两边已经分叉的业务写入。  
如果两边都写过数据，正确做法是先选主、保日志/保导出，再人工比对补数据，而不是直接让系统自动合并。
