# Module: stack-services

Responsibility: the four Compose services, startup order, and volume layout.

## Inputs

- **`P-1`**, **`P-3`**, **`P-4`**, **`P-5`**, **`P-6`**, **`P-2`**, **`P-7`**, **`P-9`**
- `${DEPLOY_ROOT}/docker-compose.yml` (from skeleton), `.env`, bundled or fetched
  `postgresql.conf`.

## Outputs

- Running containers: `nostream-db`, `nostream-cache`, `nostream-migrate` (exited 0),
  `nostream` (listening on **`P-2`** inside the relay container).

## Idempotency

Re-running `docker compose up -d` is safe; migrate re-applies only pending
migrations; Postgres and Redis data persist on host paths.

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

Postgres data and relay settings share **`P-4`** (`.nostr` under **`P-1`**) but
**different subpaths** — bootstrap creates **`${P-4}/data`** and **`${P-4}/db-logs`**
(relay settings file is optional later).

## Process identity

Reference image runs relay and migrate as **`node`** (uid **1000**). Postgres
and Redis use their upstream image users. Match the reference image:
**`user: node:node`** (uid 1000) for relay and migrate — not root.

## Restart policy

- Postgres, Redis: `always` or `unless-stopped`.
- Relay: `on-failure` with `stop_grace_period` ≥ 45s (R-9).
- Migrate: no restart — exits after one run.

## Failure behaviour

If `nostream-db` or `nostream-cache` fails healthchecks, migrate and relay do not
start (`depends_on` conditions stay unmet). If migrate exits non-zero, the relay
must not start (R-1). If the relay starts without Redis/Postgres, `/readyz` fails (R-7).

## Removal notes

`docker compose down` stops containers; Postgres files remain under **`P-4`/data**
until the operator deletes them (see schematic Removal).

## Parameters used

`P-1`, `P-3`, `P-4`, `P-5`, `P-6`, `P-9`, `P-2`, `P-7`.
