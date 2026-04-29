###############################################################################
# PostgreSQL 15.4 + repmgr 5.4 + Keepalived 高可用镜像
# 用途：双机热备，支持自动故障转移与手动主备切换
# 说明：业务镜像基于 Dockerfile.base 产出的基础镜像构建
###############################################################################
ARG BASE_IMAGE=postgres-ha-base:15.4-bookworm
FROM ${BASE_IMAGE}

LABEL maintainer="postgres-ha-cluster"
LABEL description="PostgreSQL 15.4 with repmgr and Keepalived for HA"

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
COPY scripts/keepalived-notify.sh /usr/local/bin/keepalived-notify.sh
COPY scripts/vip-control.sh /usr/local/bin/vip-control.sh
COPY scripts/wecom-notify.sh /usr/local/bin/wecom-notify.sh
COPY scripts/restore-wal.sh /usr/local/bin/restore-wal.sh
COPY scripts/wal-receiver-control.sh /usr/local/bin/wal-receiver-control.sh
COPY scripts/archive-promote-wal.sh /usr/local/bin/archive-promote-wal.sh
COPY scripts/log-maintenance.sh /usr/local/bin/log-maintenance.sh
COPY scripts/wal-archive-maintenance.sh /usr/local/bin/wal-archive-maintenance.sh

# 设置脚本可执行权限
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    /usr/local/bin/ha-log.sh \
    /usr/local/bin/setup-primary.sh \
    /usr/local/bin/setup-standby.sh \
    /usr/local/bin/check_postgres.sh \
    /usr/local/bin/repmgr-event-hook.sh \
    /usr/local/bin/keepalived-control.sh \
    /usr/local/bin/keepalived-notify.sh \
    /usr/local/bin/vip-control.sh \
    /usr/local/bin/wecom-notify.sh \
    /usr/local/bin/restore-wal.sh \
    /usr/local/bin/wal-receiver-control.sh \
    /usr/local/bin/archive-promote-wal.sh \
    /usr/local/bin/log-maintenance.sh \
    /usr/local/bin/wal-archive-maintenance.sh

# 暴露 PostgreSQL 端口
EXPOSE 5432

# 使用自定义入口脚本
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
