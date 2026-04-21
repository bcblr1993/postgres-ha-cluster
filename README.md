# PostgreSQL 高可用双机热备集群 (PostgreSQL 15.4 HA)

这是一个基于 `PostgreSQL 15.4` + `repmgr` + `Keepalived` 构建的工业级高可用架构。
只需修改简单的配置并在两台机器上启动 Docker，即可实现自动主备流复制、毫秒级数据同步、以及故障时的虚拟 IP (VIP) 自动漂移。

## 🌟 核心特性
1. **傻瓜式配置**：用户只需关心初始数据库名称、密码、机器IP 和 VIP，其他均自动化处理。
2. **自动故障转移 (Auto Failover)**：主节点宕机后，`repmgr` 自动将备节点拉升为主节点，`Keepalived` 仅在新主节点完成提升后接管 VIP，避免 VIP 早于数据库角色漂移。
3. **初始数据库自动创建**：支持启动时一键创建好您的业务数据库（如 `thingsboard`），开箱即用。
4. **自适应网络互信**：内部通过 `samenet` 配置网络互信，告别复杂的网段白名单。
5. **旧主自动回归为备库**：故障节点恢复后会检测对端是否已经成为新的主库，若已切主，则自动重新克隆并以 `standby` 身份重新加入，降低脑裂风险。

---

## 🚀 极简部署指南

### 第一步：准备离线镜像与环境
由于本系统采用离线镜像交付，您需要先将构建好的镜像包 (`postgres-ha-v1.0.tar`) 传输到两台服务器上，并导入 Docker。

1. 假设两台服务器 IP 分别为 `192.168.1.11` (Node1) 和 `192.168.1.12` (Node2)，规划一个未被占用的虚拟 IP：`192.168.1.100` (VIP)。
> **注意：** 这三个 IP 必须在同一个物理局域网网段内。
2. 在两台机器上分别执行镜像导入：
   ```bash
   docker load -i postgres-ha-v1.0.tar
   ```

> **Docker Compose 兼容说明：**
> - Docker 新版本请使用 `docker compose`
> - Docker 旧版本请使用 `docker-compose`
> - 下文默认使用 `docker compose` 作为示例，如现场机器较旧，请将命令等价替换为 `docker-compose`

### 第二步：统一配置环境
在**两台机器**上都拉取本项目代码（或解压配置文件），并在两台机器的 `.env` 文件中填入**完全相同**的配置：
```env
# 虚拟 IP (VIP) - 供所有前端/应用直接连接的高可用统一 IP
NODE_VIP=192.168.1.100

# 初始业务数据库名称
POSTGRES_DB=thingsboard

# 业务数据库密码 (postgres 超级用户密码)
POSTGRES_PASSWORD=JvUcMbDxjYY4M8sj

# 当前机器的物理 IP (Node1 填 192.168.1.11，Node2 也填这个) 
# 注意：以下两个 IP 请根据您部署时的实际物理 IP 填写。
NODE_IP=192.168.1.11
PARTNER_IP=192.168.1.12
```
> **提示：** NODE_IP 必须是主节点机器的物理 IP，PARTNER_IP 必须是备用节点机器的物理 IP。**两台机器的 `.env` 文件内容完全一模一样即可**，不需要分别修改。

### 第三步：启动主节点 (Node1 服务器)
登录到第一台机器 (Node1)，执行以下命令启动主节点：
```bash
docker compose -f docker-compose-primary.yml up -d
```
旧版 Docker 写法：
```bash
docker-compose -f docker-compose-primary.yml up -d
```

### 第四步：启动备节点 (Node2 服务器)
登录到第二台机器 (Node2)，在 **Node1 启动成功后** 执行以下命令启动备节点：
```bash
docker compose -f docker-compose-standby.yml up -d
```
旧版 Docker 写法：
```bash
docker-compose -f docker-compose-standby.yml up -d
```

### 第五步：测试与验证
完成以上步骤后，您的应用代码只需连接 `192.168.1.100:5432`，使用用户 `postgres` 密码 `JvUcMbDxjYY4M8sj` 连接 `thingsboard` 数据库即可。

### 第六步：故障恢复行为说明
当主节点发生故障并由备节点自动接管后：

1. VIP 会在新主节点真正完成 `promote` 之后才漂移过去。
2. 原主节点恢复启动时，会先检测对端是否已经成为新的主节点。
3. 如果检测到对端已是主节点，原主节点会自动转为 `standby`，重新克隆并加入集群，而不会继续以旧主身份对外提供写服务。

### 第七步：双节点同时断电后的恢复顺序
如果两台机器同时断电或同时宕机，推荐按以下顺序恢复：

1. 先启动最近一次的主节点。
2. 如果无法确认最后的主节点，优先启动您希望恢复为主节点的那台机器。
3. 当前版本会先识别本地数据目录的真实角色：
   - 如果本地数据目录是上次的 `primary`，且对端尚未恢复为 `primary`，本机会直接恢复为 `primary` 并接管 VIP。
   - 如果对端已经恢复为 `primary`，本机会自动以 `standby` 身份回归。
4. 等第一台机器恢复完成后，再启动另一台机器，它会自动重新加入集群。

经过回归测试，以下场景已经通过：
- 连续 3 轮主备切换后，集群仍可正常收敛。
- 双节点同时宕机后，`pg-node2` 先恢复、`pg-node1` 后恢复，最终可自动收敛为 `pg-node2=primary`、`pg-node1=standby`。

> **详细的故障排查、主备切换等运维命令，请参阅 `docs/operations-guide.md`。**
