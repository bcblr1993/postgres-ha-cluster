# PostgreSQL HA 双机热备 — 安装使用手册

> 基于 Docker + repmgr + Keepalived 实现的 PostgreSQL 高可用集群。  
> 应用程序只需连接一个**虚拟 IP（VIP）**，主节点故障后备节点自动接管，VIP 自动漂移，业务无需改配置。

---

## 一、环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Linux（CentOS 7+、Ubuntu 20.04+） |
| Docker | 20.10+ |
| Docker Compose | v2.x（命令为 `docker compose`） |
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

# 机器 1（主节点）的物理 IP
NODE_IP=192.168.1.11

# 机器 2（备节点）的物理 IP
PARTNER_IP=192.168.1.12
```

> ⚠️ **两台机器的 `.env` 内容完全相同，复制粘贴即可，不需要区分主备填写。**

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
docker exec -it postgres-ha ip addr show eth0 | grep inet
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
10) 灾难恢复（重新克隆）       ← 旧主宕机后恢复使用
```

---

## 六、故障转移说明

### 自动故障转移（主节点宕机）

无需任何手动操作，系统自动完成：

```
主节点宕机
    ↓（约 30 秒，repmgr 检测）
备节点自动提升为新主节点
    ↓（约 5~10 秒，Keepalived 检测）
VIP 自动漂移到新主节点
    ↓
应用通过 VIP 恢复连接，业务继续
```

**总中断时间约 40~50 秒。**

### 旧主节点恢复后的处理

旧主节点重新上线后，会**自动以备节点身份重新加入集群**，VIP 不会被它抢回（`nopreempt` 机制保证）。

若旧主节点的数据与新主节点差距过大，无法自动同步，执行运维控制台选项 `10`（灾难恢复）重新克隆。

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
