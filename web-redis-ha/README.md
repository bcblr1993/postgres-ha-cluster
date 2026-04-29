# Web/Redis 独立容器单活 HA

这个目录是独立的 Web/Redis HA 组件，用来在两台 PostgreSQL HA 宿主机上控制独立 `web` / `redis` Docker 容器。

## 设计行为

- Redis 在 A/B 两台机器上都保持运行。
- Web 只在“本机是 PostgreSQL Primary 且本机持有 VIP”时运行。
- Web 每次启动前都会清空本机 Redis 的指定 DB，默认执行 `FLUSHDB`，不会执行 `FLUSHALL`。
- Web/Redis 控制发生在宿主机，不需要把 Docker socket 暴露给 `postgres-ha` 容器。

## 安装

在 A/B 两台机器都执行：

```bash
cd web-redis-ha
./install.sh
```

安装脚本会复制以下文件：

- `/usr/local/bin/web-redis-ha.sh`
- `/etc/web-redis-ha/web-redis-ha.env`
- `/etc/systemd/system/web-redis-ha-agent.service`

如果只想安装但暂不启动：

```bash
./install.sh --no-start
```

## 卸载

保留配置和日志，仅移除服务与命令：

```bash
cd web-redis-ha
./uninstall.sh
```

彻底清理配置和日志：

```bash
./uninstall.sh --purge
```

## 配置

编辑：

```bash
vi /etc/web-redis-ha/web-redis-ha.env
```

关键配置：

```bash
WEB_CONTAINER_NAME=web
REDIS_CONTAINER_NAME=redis
WEB_REDIS_DB=0
REDIS_PASSWORD=your_redis_password
WEB_HEALTH_URL=http://127.0.0.1:8080/health
NODE_VIP=192.168.1.100
PG_PORT=5432
```

如果 Redis 没有密码，保留为空即可：

```bash
REDIS_PASSWORD=
```

注意：Web 的 `docker-compose.yml` 里不要配置 `restart`，避免备用节点误启动。示例：

```yaml
services:
  web:
    # 不要写 restart: always / unless-stopped
    image: your-web-image
```

注意：Redis 的 `docker-compose.yml` 建议配置为自动恢复，因为 Redis 两边都可以一直运行。示例：

```yaml
services:
  redis:
    restart: unless-stopped
    image: redis:7
```

## 日常命令

查看当前判断结果和容器状态：

```bash
/usr/local/bin/web-redis-ha.sh status
```

说明：只查看，不会启动或停止容器。重点看：

- `PG primary=yes/no`：本机 PostgreSQL 是否为主库
- `VIP present=yes/no`：VIP 是否在本机
- `TARGET_WEB_STATE=running/stopped`：Web 在本机应该运行还是停止
- `WEB_CONTAINER=web running=yes/no`：Web 当前实际状态
- `REDIS_CONTAINER=redis running=yes/no`：Redis 当前实际状态

手工执行一次状态收敛：

```bash
/usr/local/bin/web-redis-ha.sh once
```

说明：立即检查一次 `PG Primary + VIP` 状态，并执行对应动作。主节点会确保 Redis 运行、清空 Redis DB、启动 Web；备节点会停止 Web。适合安装后或切换后手工验证。

启动常驻 agent：

```bash
systemctl start web-redis-ha-agent.service
```

说明：让 Web/Redis HA 进入后台持续检查模式。安装脚本默认已经执行 `systemctl enable web-redis-ha-agent.service`，会开机自动启动；默认也会立即启动服务。只有使用 `./install.sh --no-start` 或手工停过服务时，才需要执行这条命令。

设置开机自动启动：

```bash
systemctl enable web-redis-ha-agent.service
```

说明：`./install.sh` 已经自动执行过这条命令，正常安装后不需要重复执行。

停止常驻 agent：

```bash
systemctl stop web-redis-ha-agent.service
```

说明：只停止 Web/Redis HA 检查进程，不会自动停止 Web 或 Redis 容器。

查看服务状态：

```bash
systemctl status web-redis-ha-agent.service
```

说明：确认 agent 是否正在运行，以及最近是否异常退出。

查看运行日志：

```bash
tail -f /var/log/web-redis-ha/web-redis-ha.log
```

说明：观察最近一次收敛动作。切换时重点看 `redis_flushdb_success`、`web_started`、`web_stopped`、`redis_not_ready`、`web_health_timeout_stopping`。

## 验证

主节点预期：

```text
PG primary=yes
VIP present=yes
TARGET_WEB_STATE=running
WEB_CONTAINER=web running=yes
REDIS_CONTAINER=redis running=yes
```

备节点预期：

```text
PG primary=no
VIP present=no
TARGET_WEB_STATE=stopped
WEB_CONTAINER=web running=no
REDIS_CONTAINER=redis running=yes
```

切换测试时，观察新主节点日志中应出现：

```text
redis_flushdb_success
web_started
```

旧主或备节点日志中应出现：

```text
web_stopped
```
