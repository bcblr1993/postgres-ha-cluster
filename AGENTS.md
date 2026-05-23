# AGENTS.md

本文件给后续在本仓库工作的 AI agent / 自动化助手使用。目标是让修改保持可回归、可交付，并避免破坏 PostgreSQL HA 的既有行为。

## 项目概览

这是一个基于 PostgreSQL 15.4、repmgr、Keepalived 和 Docker Compose 的双机热备项目。核心能力包括：

- 主备流复制与自动故障转移。
- VIP 随主节点漂移。
- 旧主恢复后自动 rejoin，必要时降级为全量 clone。
- HA 过程日志、企业微信通知、WAL 归档/接收相关辅助脚本。
- 独立的 `web-redis-ha/` 单活 HA 辅助组件。

## 主要目录

- `scripts/`：容器入口、主备初始化、repmgr 事件钩子、VIP/Keepalived/WAL/日志控制脚本。
- `conf/`：PostgreSQL、repmgr、Keepalived 配置模板。
- `docker-compose-primary.yml`：Node1 主节点启动配置。
- `docker-compose-standby.yml`：Node2 备节点启动配置。
- `docs/`：安装、运维、故障切换测试和已知风险文档。
- `web-redis-ha/`：配合 PostgreSQL HA 使用的 Web/Redis 单活组件。
- `dist/`：离线交付包目录，修改前确认是否确实需要同步更新。

## 修改原则

- 不要在没有明确需求时改变主备切换、复制、VIP 漂移、clone/rejoin 的实际行为。
- 优先保持现有 shell 风格：`set -euo pipefail`、清晰日志、显式错误处理。
- 对 HA 行为相关脚本做变更时，必须同时关注主节点、备节点、旧主回归和双节点重启场景。
- 不要提交临时测试目录、Docker volume 数据、镜像 tar 包、压测日志或本机环境文件。
- 涉及生产风险的改动，需要同步检查 `docs/install-guide.md`、`docs/operations-guide.md` 和 `docs/known-risks.md` 是否需要更新。
- 保持中文文档表达直接、面向现场运维，不使用模糊描述。

## 常用验证命令

Shell 语法检查：

```bash
bash -n scripts/*.sh
bash -n build.sh install.sh start.sh ops.sh
bash -n web-redis-ha/*.sh web-redis-ha/scripts/*.sh
```

构建镜像：

```bash
./build.sh
```

或指定标签：

```bash
BASE_IMAGE=postgres-ha-base:dev APP_IMAGE=postgres-ha:dev ./build.sh
```

基础 Compose 检查：

```bash
docker compose -f docker-compose-primary.yml config
docker compose -f docker-compose-standby.yml config
```

Git 提交前检查：

```bash
git diff --check
git status --short --branch
```

## HA 回归关注点

如果变更触及 `scripts/`、`conf/`、Compose 文件或 Dockerfile，至少需要考虑以下场景：

- 首次启动 primary，确认 PostgreSQL 初始化、repmgr 注册、VIP 绑定。
- 首次启动 standby，确认 clone、standby 注册、WAL receiver 建立。
- 正常停止主库，确认备库 promote、VIP 漂移、旧主回归。
- kill/断电主库，确认故障转移时间、数据一致性、企业微信通知。
- 两节点同时断电后按顺序恢复，确认最终只有一个 primary。
- 全量 clone 失败，确认原 `current` 数据目录不会被提前删除。
- 多次全量 clone 成功，确认只保留最新一份旧数据目录。

## 日志要求

本项目重视 `docker logs -f postgres-ha` 可观测性。新增日志时应满足：

- 关键事件立即输出：启动、注册、promote、follow、rejoin、clone、VIP 绑定/释放、Keepalived 状态变化、企业微信通知结果。
- 日志要包含时间、节点、角色、VIP 状态、耗时、数据目录路径或 clone 大小等排障字段。
- 健康检查类日志保持降噪，只在状态变化或累计失败阈值时输出。
- 不要在热循环里每秒刷大量重复日志。

## 数据安全边界

- 全量 clone 必须先写入临时目录，成功后再切换 `current`。
- clone 失败时必须保留原 `current`，并输出明确等待主库恢复的日志。
- clone 成功后只保留最近一份旧数据目录，旧保留目录应自动清理。
- 当前方案是异步复制，不能承诺 `RPO=0`；文档和结论中必须明确这一点。
- `pg-ha-retained-before-clone/latest` 只是短期保留，不是正式备份。

## Git 约定

提交信息使用中文 emoji Conventional Commit，例如：

```text
✨ feat: 初始化 AGENTS 项目说明
📝 docs: 补充 HA 已知风险说明
🐛 fix: 修复 standby clone 失败保留逻辑
```

推送前确认当前分支和远程地址，不要覆盖用户已有远程。当前仓库可能同时存在内网 Gogs 远程和 GitHub 远程。
