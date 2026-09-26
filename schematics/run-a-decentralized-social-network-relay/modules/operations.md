# Module: operations

Responsibility: upgrades, bootstrap refresh, and backups. Image transfer and
pinning live in `modules/image-delivery-and-pinning.md`; public hostname setup
in `modules/reverse-proxy-sketch.md`.

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
RELAY_PORT="$(grep -E '^RELAY_PORT=' .env | tail -1 | cut -d= -f2- | tr -d " \t\r\"'")"
RELAY_PORT="${RELAY_PORT:-8008}"
DEPLOY_ROOT="${DEPLOY_ROOT}" RELAY_BASE="http://127.0.0.1:${RELAY_PORT}" \
  "${SCHEMATIC_PKG}/scripts/relay-verify.sh"
```

Set **`SCHEMATIC_PKG`** to the checkout path of this schematic (the directory
that contains `scripts/` and `SCHEMATIC.md`). Bootstrap prints the same
invocation using its package root.
