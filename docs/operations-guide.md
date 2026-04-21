# PostgreSQL HA 运维操作手册

本手册记录了针对基于 Docker + Keepalived + repmgr 的高可用 PostgreSQL 集群的日常排查与维护命令。

说明：
本文档默认对应单机部署编排 `docker-compose-primary.yml` / `docker-compose-standby.yml`，两台机器上的容器名都为 `postgres-ha`。
如果您使用的是本地联调编排 `docker-compose-test.yml`，请把文中的 `postgres-ha` 替换为 `pg-node1` 或 `pg-node2`。
如果您的 Docker 版本较新，请使用 `docker compose`；如果现场机器 Docker 版本较旧，请使用 `docker-compose`。本文中的两种写法含义等价。

---

## 一、 日常运行状态检查

您可以通过以下几条核心命令，了解当前数据库主备的状态。

### 1.1 查看集群主备拓扑 (Cluster Show)
在任意一台机器的宿主机终端中执行：
```bash
docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
```
**输出示例：** 确认 `Role` 字段，谁是 `primary`，谁是 `standby`。

### 1.2 查看虚拟 IP (VIP) 在哪里
```bash
docker exec -it postgres-ha ip addr show eth0
```
如果您在输出中看到了您配置的 `NODE_VIP`（例如 `192.168.1.100`），说明这台机器当前正承载着数据库的主节点流量。
当前版本中，VIP 只会在本机数据库角色已经是 `primary` 时才会被 Keepalived 接管。

### 1.3 查看日志
排查故障时，可以快速抓取日志：
```bash
# 抓取 Keepalived (负责 VIP 漂移) 日志
docker logs postgres-ha | grep -i keepalived

# 抓取 repmgrd (负责集群故障转移) 日志
docker exec -it postgres-ha tail -n 100 /var/log/repmgr/repmgr.log
```

---

## 二、 手动主备互换 (Switchover)

**场景：** 您需要对当前的主服务器（Primary）进行停机维护、升级硬件等操作，需要在**业务不停机**的情况下，将主节点平滑切换到备节点。

### 执行步骤：
1. **登录到当前的备节点 (Standby)** 的宿主机终端。
2. 运行干跑测试，确认切换条件安全：
   ```bash
   docker exec -it postgres-ha su - postgres -c "repmgr standby switchover -f /etc/repmgr.conf --siblings-follow --dry-run"
   ```
3. 确认无误后，执行正式切换：
   ```bash
   docker exec -it postgres-ha su - postgres -c "repmgr standby switchover -f /etc/repmgr.conf --siblings-follow"
   ```
4. 切换完成后，Keepalived 会在新的 Primary 节点完成角色切换后自动接管 VIP。

---

## 三、 应对宕机灾难与节点恢复 (Failover)

**场景：** 真实主节点遭遇断电、网络中断等硬故障。此时集群已经自动进行了转移，备节点会先被 `repmgr` 提升为新的主节点，随后由 `Keepalived` 接管 VIP。
**重点：** 当前版本下，**旧的主节点**修好并重新开机后，不会继续以旧主身份提供服务；它会检测对端是否已成为新的主节点，如已切主，则自动降级并重新加入集群作为**新的备节点 (Standby)**。

### 恢复旧的主节点 (重新加入集群)

请在**旧主节点**的机器上，执行以下步骤：

1. 确认当前机器的 `.env` 文件仍然和对端保持一致，尤其是 `NODE_IP`、`PARTNER_IP`、`NODE_VIP`、`POSTGRES_PASSWORD`、`POSTGRES_DB`。

2. 直接重新启动原有容器：
   ```bash
   docker compose -f docker-compose-primary.yml up -d
   ```
   旧版 Docker 写法：
   ```bash
   docker-compose -f docker-compose-primary.yml up -d
   ```

3. 启动后，容器会自动检测对端是否已经是新的主节点：
   - 如果对端仍不可达，它会按原始角色继续尝试启动。
   - 如果检测到对端已经成为新的主节点，它会自动切换为 `standby`，重新克隆数据并注册回集群。

4. 使用以下命令确认恢复结果：
   ```bash
   docker exec -it postgres-ha su - postgres -c "repmgr -f /etc/repmgr.conf cluster show"
   ```

5. 只有在本地数据卷已经严重损坏、无法完成自动回归时，才建议手工删除容器和数据卷后再重新拉起。常规恢复场景不再需要先手动清卷。

### 3.2 企业微信通知说明

如果在 `.env` 中启用了企业微信通知：

1. 主备自动切换完成后，会推送一条切换告警
2. 旧主自动回归为 `standby` 后，会推送一条恢复通知

通知中会包含当前主节点、VIP、数据库可写性、本机和对端物理 IP、宿主机名、Keepalived 状态等信息。
如果设置了 `WECOM_NOTIFY_AT_ALL_ON_FAILOVER=true`，自动故障切换告警会额外 `@all`。建议 `WECOM_NOTIFY_TIMEOUT` 不低于 `10` 秒。

### 3.1 双节点同时断电后的恢复

**场景：** 两台机器同时断电，随后需要逐台恢复。

推荐恢复顺序：

1. 优先启动上次已知的主节点。
2. 如果不能确认谁是上次主节点，优先启动您希望作为主节点恢复的那台机器。
3. 等待该节点完成 PostgreSQL 启动、`repmgr` 注册以及 VIP 接管。
4. 再启动另一台机器，它会自动识别本地数据目录角色，并根据对端状态选择：
   - 直接恢复为 `primary`
   - 或者通过 `pg_rewind` / 全量克隆重新加入为 `standby`

已验证通过的典型场景：

1. 连续 3 轮主备切换。
2. 双节点同时停止后，`pg-node2` 先恢复。
3. `pg-node1` 随后恢复并自动回归为 `standby`。
4. VIP 始终跟随当前 `primary`，测试数据保持一致。

---

## 四、 数据备份与恢复

虽然有了双机热备，定期的**逻辑备份**依然是防范"人为删表/删库"等误操作的最后一道防线。

### 执行每日逻辑备份
建议在任何一台机器上设置一个 Cron 计划任务：
```bash
# 通过 VIP 连接进行全库备份（始终从当前 Primary 备份）
# 注意：密码在交互时会被要求，建议通过 ~/.pgpass 或环境变量 PGPASSWORD 注入
docker exec -it postgres-ha pg_dumpall -h 192.168.1.100 -U postgres > /root/db_backup_$(date +%Y%m%d).sql
```
