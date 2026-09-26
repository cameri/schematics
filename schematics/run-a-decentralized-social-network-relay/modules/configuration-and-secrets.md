# Module: configuration-and-secrets

Responsibility: `.env` secrets, relay tuning, and optional YAML overrides.

## Inputs

- **`P-13`**–**`P-18`**, **`P-5`**, **`P-6`**, **`P-7`**, **`P-2`**, **`P-11`**, **`P-10`**.

## Outputs

- `${DEPLOY_ROOT}/.env` (mode 600); optional **`P-11`** overrides merged at relay start.

## Idempotency

Re-editing `.env` and `docker compose up -d --force-recreate nostream` applies
new secrets; rotating **`P-13`** may invalidate admin sessions.

## Failure behaviour

Missing or placeholder **`P-13`** / DB / Redis passwords prevent a healthy relay;
migrate may fail before the relay starts. Invalid YAML in **`P-11`** can block
relay startup — validate with a YAML linter before recreate.

## Removal notes

Delete `${DEPLOY_ROOT}/.env` only after rotating clients away; scrub secrets from
backups if `.env` was archived.

## `.env` (host only, mode 600)

Required keys (see `skeleton/.env.example`):

| Variable | Purpose |
|----------|---------|
| `SECRET` | Relay signing and crypto (128-byte hex typical) |
| `DB_USER`, `DB_PASSWORD`, `DB_NAME` | Postgres credentials |
| `REDIS_PASSWORD` | Redis AUTH |
| `RELAY_PORT` | Must match compose mapping |
| `NOSTR_CONFIG_DIR` | `/home/node/.nostr` in container |
| `WORKER_COUNT` | Client workers (`P-7`) |
| `DB_MIN_POOL_SIZE`, `DB_MAX_POOL_SIZE`, `DB_ACQUIRE_CONNECTION_TIMEOUT` | Pool tuning |

Generate example:

```bash
openssl rand -hex 128   # SECRET
openssl rand -hex 32    # DB_PASSWORD, REDIS_PASSWORD
```

Never commit `.env` (R-4).

## Settings overrides (`P-11`)

Optional. When absent, the relay uses **`resources/default-settings.yaml`**
from **`P-3`**.

When present:

- Deep-merge over image defaults.
- MUST set `info.relay_url` to **`P-10`** before public clients connect.
- File mode **600**, owner **1000:1000** (relay user).
- Directory **`.nostr`** must be writable by uid 1000 for backups and audit log.

Start minimal (from `skeleton/settings.yaml.example`):

```yaml
info:
  relay_url: wss://relay.example.com
  name: relay.example.com
  description: A Nostr relay powered by nostream.
  contact: mailto:operator@example.com
```

Enable `admin`, `payments`, `nip66` only when the operator understands upstream
docs — not required for a public read/write relay.

## What not to copy onto the host

Per upstream deploy README: do **not** copy full `settings.yaml` from old docs,
`migrations/`, or `knexfile.js` — migrations run from the image.

## Rotation

| Secret | Action |
|--------|--------|
| `DB_PASSWORD` | Change in Postgres + `.env`, recreate stack |
| `REDIS_PASSWORD` | Update `.env`, recreate redis + relay |
| `SECRET` | Update `.env`, recreate relay; may invalidate admin sessions |
