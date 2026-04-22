###############################################################################
# PostgreSQL 15.4 + repmgr 5.4 + Keepalived 高可用镜像
# 用途：双机热备，支持自动故障转移与手动主备切换
###############################################################################
FROM postgres:15.4-bookworm

LABEL maintainer="postgres-ha-cluster"
LABEL description="PostgreSQL 15.4 with repmgr and Keepalived for HA"

# 设置环境变量，避免交互式安装提示
ENV DEBIAN_FRONTEND=noninteractive

# 替换为国内镜像源（阿里云 Debian 镜像加速）
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources

# 安装 repmgr、keepalived 及辅助工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    # repmgr（从 PostgreSQL 官方仓库获取）
    postgresql-15-repmgr \
    # Keepalived - VRRP 虚拟 IP 管理
    keepalived \
    # 辅助工具
    iputils-ping \
    net-tools \
    iproute2 \
    sudo \
    procps \
    curl \
    && rm -rf /var/lib/apt/lists/*

# --- 以下为新增层，以上层全部命中缓存 ---

# 确保 PG 二进制在 PATH 中（su - postgres 时也生效）
ENV PATH=/usr/lib/postgresql/15/bin:$PATH
RUN echo 'export PATH=/usr/lib/postgresql/15/bin:$PATH' >> /var/lib/postgresql/.profile \
    && chown postgres:postgres /var/lib/postgresql/.profile

# 创建 repmgr 日志目录，预建 keepalived.log 并归属 postgres，
# 否则首次由 root 启动 keepalived 会以 root 创建该文件，
# 导致后续 postgres 用户的 repmgrd 事件钩子无权写入，Keepalived 无法启动
RUN mkdir -p /var/log/repmgr \
    && touch /var/log/repmgr/keepalived.log \
    && chown -R postgres:postgres /var/log/repmgr

# 创建 repmgr 配置目录
RUN mkdir -p /etc/repmgr

# 允许 postgres 用户执行 keepalived 相关命令（无密码 sudo）
RUN echo "postgres ALL=(ALL) NOPASSWD: /usr/sbin/keepalived, /usr/bin/killall, /sbin/ip, /bin/kill" >> /etc/sudoers.d/postgres

# 复制配置文件目录
COPY conf/ /etc/pg-ha/conf/

# 复制脚本
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY scripts/ha-log.sh /usr/local/bin/ha-log.sh
COPY scripts/setup-primary.sh /usr/local/bin/setup-primary.sh
COPY scripts/setup-standby.sh /usr/local/bin/setup-standby.sh
COPY scripts/check_postgres.sh /usr/local/bin/check_postgres.sh
COPY scripts/repmgr-event-hook.sh /usr/local/bin/repmgr-event-hook.sh
COPY scripts/keepalived-control.sh /usr/local/bin/keepalived-control.sh
COPY scripts/wecom-notify.sh /usr/local/bin/wecom-notify.sh
COPY scripts/restore-wal.sh /usr/local/bin/restore-wal.sh
COPY scripts/wal-receiver-control.sh /usr/local/bin/wal-receiver-control.sh
COPY scripts/archive-promote-wal.sh /usr/local/bin/archive-promote-wal.sh
COPY scripts/log-maintenance.sh /usr/local/bin/log-maintenance.sh

# 设置脚本可执行权限
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    /usr/local/bin/ha-log.sh \
    /usr/local/bin/setup-primary.sh \
    /usr/local/bin/setup-standby.sh \
    /usr/local/bin/check_postgres.sh \
    /usr/local/bin/repmgr-event-hook.sh \
    /usr/local/bin/keepalived-control.sh \
    /usr/local/bin/wecom-notify.sh \
    /usr/local/bin/restore-wal.sh \
    /usr/local/bin/wal-receiver-control.sh \
    /usr/local/bin/archive-promote-wal.sh \
    /usr/local/bin/log-maintenance.sh

# 暴露 PostgreSQL 端口
EXPOSE 5432

# 使用自定义入口脚本
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
