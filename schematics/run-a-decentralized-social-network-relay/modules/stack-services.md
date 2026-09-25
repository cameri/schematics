# Module: stack-services

Responsibility: the four Compose services, startup order, and volume layout.

## Services

| Service | Image | Role |
|---------|-------|------|
| `nostream-db` | `postgres:15` | Event and settings persistence |
| `nostream-cache` | `redis:7.0.5-alpine3.16` | Cache, rate limits, pub/sub helpers |
| `nostream-migrate` | `P-3` | One-shot `knex migrate:latest` |
| `nostream` | `P-3` | Nostr relay (HTTP + WebSocket) |

## Ordering (R-1)

```
nostream-db (healthy) ──┬──► nostream-migrate (completed_successfully) ──► nostream
nostream-cache (healthy) ┘
```

The relay MUST declare:

```yaml
depends_on:
  nostream-db:
    condition: service_healthy
  nostream-cache:
    condition: service_healthy
  nostream-migrate:
    condition: service_completed_successfully
```

## Volumes

| Mount | Service | Mode | Content |
|-------|---------|------|---------|
| `${DEPLOY_ROOT}/.nostr/data` | postgres | rw | Database files |
| `${DEPLOY_ROOT}/.nostr/db-logs` | postgres | rw | Postgres logs |
| `${DEPLOY_ROOT}/postgresql.conf` | postgres | ro | Tuning |
| `cache` (named volume) | redis | rw | Redis AOF/RDB |
| `${DEPLOY_ROOT}/.nostr` → `/home/node/.nostr` | relay | rw | Settings, backups, audit log |

Postgres data and relay settings share the `.nostr` parent directory but
**different subpaths** — bootstrap creates both.

## Process identity

Reference image runs relay and migrate as **`node`** (uid **1000**). Postgres
and Redis use their upstream image users. Do not run the relay as root (R-12
analogue in preservation list).

## Restart policy

- Postgres, Redis: `always` or `unless-stopped`.
- Relay: `on-failure` with `stop_grace_period` ≥ 45s (R-9).
- Migrate: no restart — exits after one run.

## Parameters used

`P-1`, `P-3`, `P-4`, `P-5`, `P-6`, `P-9`, `P-2`, `P-7`.
