# Module: operations

Responsibility: upgrades, bootstrap refresh, and backups. Image transfer and
pinning live in `modules/image-delivery-and-pinning.md`; public hostname setup
in `modules/reverse-proxy-sketch.md`.

## Inputs

- Running stack at **`P-1`**, **`P-3`** / `NOSTREAM_IMAGE` in `.env`, schematic
  package path for verification scripts.

## Outputs

- Upgraded containers, refreshed release-managed files, backup artefacts per operator schedule.

## Idempotency

`docker compose up -d` and bootstrap refresh are safe to re-run; bootstrap never
overwrites existing `.env` or `settings.yaml`.

## First start

```bash
cd ${DEPLOY_ROOT}
docker compose up -d
docker compose logs -f nostream-migrate
docker compose ps
```

## Upgrade image (`P-3`)

See `modules/image-delivery-and-pinning.md` for pull vs save/load.

```bash
cd "${DEPLOY_ROOT}"
NOSTREAM_IMAGE="$(grep -E '^NOSTREAM_IMAGE=' .env | tail -1 | cut -d= -f2- | tr -d " \t\r\"'")"
docker pull "${NOSTREAM_IMAGE}"   # or docker load the same tag
docker compose up -d
```

If migrate does not re-run after load:

```bash
docker compose up -d --force-recreate nostream-migrate nostream
```

Fleet upgrades with a load balancer: `modules/load-balancer-cutover.md`.

## Refresh release-managed files

Re-run `bootstrap.sh` from a checkout matching the release — updates
`docker-compose.yml` and `postgresql.conf` without overwriting `.env` or
existing `settings.yaml`.

## Backup

Critical path: **`${DEPLOY_ROOT}/.nostr/data`** (Postgres). Schedule
`pg_dump` or volume snapshots consistent with your RPO.

Redis volume is rebuildable; Postgres is not.

## Logs

```bash
docker compose logs -f nostream
docker compose logs nostream-migrate
```

## Local verification

Run from **`P-1`** after the stack is up. The verify script lives in the
schematic package, not in the deploy root (bootstrap does not copy it).

```bash
cd "${DEPLOY_ROOT}"
DEPLOY_ROOT="${DEPLOY_ROOT}" \
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}" \
  "${SCHEMATIC_PKG}/scripts/relay-verify.sh"
```

Set **`SCHEMATIC_PKG`** to the checkout path of this schematic (the directory
that contains `scripts/` and `SCHEMATIC.md`). The script reads **`RELAY_PORT`**
from `${DEPLOY_ROOT}/.env`; do not set **`RELAY_BASE`** unless overriding that.
For blue/green stacks, set **`COMPOSE_PROJECT_NAME`** (**`P-20`**) to match
`docker compose -p`. Bootstrap prints the same invocation using its package root.

## Failure behaviour

Upgrade or migrate failure leaves the previous relay image running if recreate
was not forced; a failed migrate exit blocks the relay from starting (R-1).

## Removal notes

Follow schematic **Removal** — this module does not delete `${DEPLOY_ROOT}` data;
`docker compose down -v` drops the Redis named volume only when explicitly requested.

## Pull policy

Online hosts may set `PULL_POLICY=missing` in `.env` instead of `never`; see
`modules/image-delivery-and-pinning.md`. Air-gapped hosts keep `never` after
`docker load`.
