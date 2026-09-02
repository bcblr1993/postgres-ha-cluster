# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PostgreSQL 15.4 two-node hot-standby HA cluster with automatic failover, built on **repmgr** (replication management) + **Keepalived** (VIP floating). Delivered as offline Docker images for on-premise deployment. The companion `web-redis-ha/` component controls web/redis containers on the host to follow the primary node.

## Build & Run Commands

```bash
# Build Docker images (two-stage: base then app)
./build.sh
# Override image tags:
# BASE_IMAGE=postgres-ha-base:dev APP_IMAGE=postgres-ha:dev ./build.sh

# Import offline image on target machines
./install.sh [postgres-ha-v1.0.tar]

# Start a node (reads .env for config)
./start.sh primary    # uses docker-compose-primary.yml
./start.sh standby    # uses docker-compose-standby.yml

# Local testing (both nodes on a bridge network, no .env needed)
docker compose -f docker-compose-test.yml up -d

# Interactive ops console (status, logs, switchover, disaster recovery)
./ops.sh
```

All scripts auto-detect `docker compose` vs `docker-compose`.

## Architecture

### Startup Flow (inside container)

`docker-entrypoint.sh` is the ENTRYPOINT. It:
1. Sources `ha-log.sh` (unified logging framework writing to `/var/log/repmgr/`)
2. Copies node-specific config templates from `/etc/pg-ha/conf/` and does sed replacement of placeholder IPs with runtime values from env vars
3. Writes runtime env to `/etc/pg-ha/runtime-notify.env` for child scripts
4. Starts Keepalived on both nodes (VIP eligibility controlled by track_script, not process presence)
5. Hands off to `setup-primary.sh` or `setup-standby.sh` based on `NODE_ROLE`

### Role Detection & Auto-Recovery

Both setup scripts perform **runtime role detection** before proceeding with their configured role:

- `setup-primary.sh` checks if `standby.signal` exists locally or if the partner is already primary — if either is true, it `exec`-s into `setup-standby.sh`
- `setup-standby.sh` checks if local data has no standby signal and partner is NOT primary — if so, it `exec`-s into `setup-primary.sh`
- This bidirectional handoff handles dual-power-loss recovery and stale docker-compose role assignments

### Failover Sequence

1. `repmgrd` detects primary failure, promotes standby
2. `repmgr-event-hook.sh` fires on `standby_promote` / `standby_follow` events
3. On promote: stops WAL receiver, archives promote WAL, runs `vip-control.sh ensure` (adds VIP if node is primary)
4. On follow: runs `vip-control.sh remove`, restarts WAL receiver
5. Keepalived track_script (`check_postgres.sh`) verifies PostgreSQL is primary before allowing VIP hold
6. Old primary recovery: `pg_rewind` + `repmgr node rejoin` first, full clone only as fallback

### Key Environment Variables

All configured in `.env` (same content on both machines):

| Variable | Purpose |
|---|---|
| `NODE_IP` / `PARTNER_IP` | Physical IPs of the two machines |
| `NODE_VIP` | Floating virtual IP for client connections |
| `POSTGRES_PASSWORD` | Superuser password |
| `POSTGRES_DB` | Business database created on first init |
| `WECOM_*` | WeChat enterprise notification settings |
| `WAL_ARCHIVE_ENABLED` | Enable WAL archiving for PITR |

### Logging

All scripts use `ha-log.sh` which writes to both a component-specific log and a master log at `/var/log/repmgr/ha-runtime.log`. Key log levels: EVENT, SECTION, WARN, ERROR are also mirrored to Docker stdout. The `ha_log_ha_snapshot` function captures full cluster state (role, VIP, replication stats, Keepalived status) at critical points.

### Configuration Templates

`conf/` contains per-node templates with placeholder IPs (`192.168.1.1*` / `192.168.1.100`). The entrypoint copies the matching template and replaces IPs at runtime. Config files are also re-applied after clone/rejoin to ensure consistency.

### Clone Safety (setup-standby.sh)

Standby cloning uses a two-phase approach: clone into a `.pg-ha-clone-*` work directory, then atomically swap it into PGDATA while retaining old data in a `.pg-ha-retained-before-clone` directory. This prevents data loss if clone is interrupted.

## File Organization

- `scripts/` — All shell scripts copied into the Docker image under `/usr/local/bin/`
- `conf/` — Config templates (postgresql.conf, pg_hba.conf, repmgr, keepalived) per node
- `dist/` — Per-node deployment bundles (docker-compose.yml + ops scripts) for shipping to target machines
- `docs/` — Operations guide, install guide, HA failover test cases
- `web-redis-ha/` — Host-level systemd agent ensuring web container only runs on primary
