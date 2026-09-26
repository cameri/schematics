# Module: image delivery and pinning

Responsibility: get **`P-3`** on the host, pin a deliberate version, and refresh
release-managed files without clobbering secrets.

## Inputs

- Registry access or image tarballs, **`P-3`**, **`P-9`**, **`P-8`**, bootstrap package.

## Outputs

- Images present locally; `${DEPLOY_ROOT}` release-managed files match target release.

## Idempotency

`docker pull`, `docker load`, and `bootstrap.sh` may be repeated; operator `.env`
is preserved.

## Where images come from

The reference relay image is published to GHCR as **`ghcr.io/cameri/nostream`**.

After each successful CI run on the upstream **`main`** branch, two useful tags
exist:

| Tag pattern | Meaning |
|-------------|---------|
| `main` | Latest successful build from main (moving tag) |
| `sha-<git-commit>` | Immutable pointer to that build |

Discovery on a registry-connected host:

```bash
docker pull ghcr.io/cameri/nostream:main
docker image inspect ghcr.io/cameri/nostream:main --format '{{.Id}}'
```

For highest reproducibility, pin **`P-3`** to **`sha-<commit>`** or to the
image digest (`ghcr.io/cameri/nostream@sha256:…`) instead of floating `main`
(R-10).

Set the same value for migrate and relay (R-2) — one variable in compose.

## Pull policy (**`P-9`**)

| Situation | `PULL_POLICY` | Action |
|-----------|-----------------|--------|
| Image pre-loaded or air-gapped | `never` | Reference skeleton default |
| Online host, pull on deploy | `missing` or `always` | Operator choice; document in `.env` |

When **`never`**, `docker compose up` fails if **`P-3`** is absent — run pull or
load first.

## Air-gapped or restricted networks

Some hosts cannot reach GHCR (IPv4, firewall, policy). Transfer images manually.

**On a connected machine:**

```bash
P3=ghcr.io/cameri/nostream:main
docker pull "$P3"
docker pull postgres:15
docker pull redis:7.0.5-alpine3.16

docker save "$P3" | gzip -c > nostream-main.tar.gz
docker save postgres:15 | gzip -c > postgres-15.tar.gz
docker save redis:7.0.5-alpine3.16 | gzip -c > redis-alpine.tar.gz
```

**On the deploy host:**

```bash
docker load -i nostream-main.tar.gz
docker load -i postgres-15.tar.gz
docker load -i redis-alpine.tar.gz
docker image inspect "$P3"
```

Keep **`PULL_POLICY=never`** for nostream services after load.

## Release-managed files vs operator files

Bootstrap and refresh copy **only** files that track upstream releases:

| File | Operator edits? |
|------|-----------------|
| `docker-compose.yml` | No — re-run bootstrap or merge upstream changes |
| `postgresql.conf` | Rarely — fetch matching **`P-8`** / **`P-3`** |
| `.env` | **Yes** — secrets and tuning |
| `.nostr/settings.yaml` | **Optional** overrides only |

Re-run `skeleton/bootstrap.sh ${DEPLOY_ROOT}` after a nostream release when
compose or Postgres tuning changed. Existing `.env` and settings are preserved.

**Air-gapped bootstrap:** this package ships `skeleton/postgresql.conf` (matched
to upstream nostream at authoring time). Bootstrap installs it without GitHub
access; refresh the bundled file when rebasing the schematic on a new nostream
release.

## Upgrade sequence

Use the image tag from **`.env`** (`NOSTREAM_IMAGE`, same as **`P-3`** in the
schematic). Compose reads `.env` for `${NOSTREAM_IMAGE}`; a bare shell variable
`${P-3}` is schematic notation only and will not pull the right image.

```bash
cd "${DEPLOY_ROOT}"
NOSTREAM_IMAGE="$(grep -E '^NOSTREAM_IMAGE=' .env | tail -1 | cut -d= -f2- | tr -d " \t\r\"'")"
docker pull "${NOSTREAM_IMAGE}"    # or docker load
docker compose up -d
```

If migrate did not run:

```bash
docker compose up -d --force-recreate nostream-migrate nostream
```

Align **`P-8`** / `postgresql.conf` with the new image when upstream changes
Postgres settings.

## Parameters used

`P-1`, `P-3`, `P-8`, `P-9`.
