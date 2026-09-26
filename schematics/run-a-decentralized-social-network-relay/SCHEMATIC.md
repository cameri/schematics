<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: run-a-decentralized-social-network-relay
version: 0.1.0
status: draft
spec: 1
description: A production Nostr relay (nostream) on Docker — host prep, Postgres and Redis, GHCR image pinning, migrations-before-start, loopback HTTP, reverse-proxy sketches, NIP-11 and /readyz probes, optional settings and tailnet exposure.
created: 2026-09-26
updated: 2026-09-28
---

# Schematic: Run a Decentralized Social Network Relay

> **Reverse-engineered** from the [nostream](https://github.com/cameri/nostream)
> production deploy path (`deploy/docker-compose.prod.yml`, `deploy/bootstrap.sh`,
> `deploy/README.md`). Behaviour was reconstructed from the published compose
> contract, operator docs, and the relay's HTTP/Nostr surfaces. Items marked
> *(observed)* were checked against a running dev stack; others follow upstream
> documentation.

After implementing this schematic, the host runs **one Nostr relay** that
speaks the WebSocket protocol clients expect, persists events in **PostgreSQL**,
uses **Redis** for cache and coordination, and exposes **HTTP** on the loopback
interface for NIP-11 discovery, health probes, and optional admin. Schema
migrations run **once per upgrade** in a short-lived container; the long-lived
relay starts only after migrations succeed. Settings defaults ship **inside the
image**; the operator keeps secrets in `.env` and optional overrides in
`.nostr/settings.yaml`.

This is the capability that lets an operator **self-host a relay** for the
decentralized social graph (Nostr) without running a from-source Node build on
the host: the relay is a pinned container, the data plane is Postgres, and
exposure to the Internet is an explicit, separate decision.

**Terms used throughout:**

- **Relay**: the nostream application container (WebSocket + HTTP).
- **Migrate job**: one-shot `knex migrate:latest` using the **same image** as the relay.
- **Deploy root**: host directory holding `docker-compose.yml`, `.env`, and `.nostr/`.
- **Settings overrides**: optional YAML merged on top of image defaults — not a full copy of defaults.
- **NIP-11**: relay metadata document served over HTTP (`Accept: application/nostr+json`).

## Applicable Context

**Must discover locally** (with the discovery command/method for each):

- Whether another service already binds **`P-2`** on the host. Discovery:
  `ss -ltn | grep ":${P-2}"` or `lsof -i :${P-2}`. A port collision blocks
  the default layout.
- Disk for Postgres (`P-4` data directory) and retention expectations.
  Discovery: `df -h ${DEPLOY_ROOT}`; plan for event volume growth.
- Whether the host can reach **`P-3`** (GHCR) or must use image save/load.
  Discovery: `docker pull ${P-3}` or operator policy (air-gapped save/load).
- How clients will reach the relay WebSocket URL (**`P-10`**, usually
  `wss://…`). Discovery: DNS/TLS plan; the default compose does **not**
  publish a public port.
- Whether **`P-11`** (optional settings overrides) is needed on day one.
  Discovery: need for custom `info.relay_url`, payments, admin, NIP-66, etc.
  Omitting the file is valid — image defaults apply.

**May assume** (each with the risk if the assumption is wrong):

- Docker Engine with Compose v2. Risk: without healthchecks and
  `depends_on`, ordering must be enforced manually.
- Linux host for production (upstream deploy docs target Linux). Risk on
  other OS: path permissions and `127.0.0.1` binding may differ.
- The relay image includes migrations and default settings. Risk if using a
  custom image: migrate command and config paths must match (R-2).
- **`WORKER_COUNT`** and pool sizes in `.env` suit CPU/RAM. Risk: under-
  provisioning shows up as pool timeouts under load.

**Must not change:**

- The rule that **migrations complete before the relay starts** (R-1).
- Postgres data under **`P-4`** without a backup/restore plan — deleting it
  destroys the event store.
- **`SECRET`** rotation without understanding session invalidation for admin
  and signed URLs that depend on it.

## Scope

**In scope:**

- Linux host prerequisites: Docker, disk, firewall, reboot (`modules/server-host-prerequisites.md`).
- Four-service Compose stack: Postgres, Redis, migrate job, relay.
- Bootstrap layout: deploy root, `.env`, `.nostr/data`, optional settings.
- GHCR pull, digest/`sha-*` pinning, and air-gapped save/load (`modules/image-delivery-and-pinning.md`).
- Secrets and tuning via environment variables (`modules/configuration-and-secrets.md`).
- Health and readiness endpoints for automation (`modules/exposure-and-health.md`).
- Reverse proxy sketches for public `wss://` (`modules/reverse-proxy-sketch.md`).
- Load-balancer cutover using `/readyz` (`modules/load-balancer-cutover.md`).
- Verification script and acceptance tests for a minimal public relay.

**Out of scope / non-goals:**

- Building nostream from source on the host (use **`P-3`** image).
- Full HAProxy blue/green fleet compose (probe and drain contract is in
  `modules/load-balancer-cutover.md`; upstream [`deploy/README.md` — Health checks](https://github.com/cameri/nostream/blob/main/deploy/README.md#health-checks)
  and optional `docker-compose.nginx.yml` at the nostream repo root).
- Prometheus/Grafana/OTEL stacks (optional upstream compose overlays).
- Content moderation policy — configured via settings, not repeated here.
- Federated mirroring, DVM workers, and Tor/I2P overlays unless enabled in
  settings overrides.

**Preservation List** *(reverse-engineered)*:

*Must match upstream production behaviour:*

- Migrate container exits **0** before relay starts (`depends_on:
  service_completed_successfully`).
- Relay and migrate use the **same image reference** (`P-3`).
- Relay listens on **`P-2`** inside the container; default publish is
  **`127.0.0.1:P-2`** only (R-5).
- Settings defaults come from the **image**; overrides merge shallowly from
  `.nostr/settings.yaml` when present.
- Relay process runs as **non-root** (`node`, uid 1000) in the reference image.
- **`/healthz`** liveness and **`/readyz`** readiness are distinct (R-6, R-7).

*Open to reinterpretation:*

- Exact Postgres tuning file (reference uses `postgresql.conf` from the
  nostream release matching **`P-3`**).
- Reverse proxy choice (nginx, Caddy, Cloudflare Tunnel, tailnet serve).
- Image tag pinning strategy (`main` vs digest pin).

## Requirements

- **R-1**: Database migrations MUST complete successfully before the relay
  container is allowed to start serving traffic.
- **R-2**: The migrate job and the relay MUST use the same application image
  so schema version and application version stay aligned.
- **R-3**: PostgreSQL MUST persist to a host path (`P-4`) that survives
  container recreation; Redis MAY use a named volume.
- **R-4**: **`SECRET`**, database password, and Redis password MUST NOT be
  committed to version control; they live in `.env` on the host only.
- **R-5**: The relay HTTP port MUST NOT be published on all interfaces unless
  the operator explicitly changes the compose port mapping; the reference
  binds loopback only.
- **R-6**: **`GET /healthz`** MUST return success while the process is up,
  without requiring database connectivity (liveness).
- **R-7**: **`GET /readyz`** MUST return non-success when Postgres or Redis
  is unreachable (readiness for load balancers).
- **R-8**: **`GET /`** with `Accept: application/nostr+json` MUST return NIP-11
  metadata including the configured relay identity when settings are valid.
- **R-9**: On **`SIGTERM`**, the relay MUST drain WebSocket clients within
  configured grace before exit; compose `stop_grace_period` MUST exceed the
  drain timeout.
- **R-10**: Image reference **`P-3`** MUST be pinned to a deliberate tag or
  digest; floating `latest` without operator intent is discouraged.

**Evidence** (source of each requirement, from nostream production deploy
artefacts and *(observed)* checks where noted):

| Req | Evidence |
|-----|----------|
| R-1 | `deploy/docker-compose.prod.yml`: `nostream` `depends_on` `nostream-migrate` with `condition: service_completed_successfully` *(observed in compose)* |
| R-2 | Same file: `nostream` and `nostream-migrate` share one image reference (`ghcr.io/cameri/nostream:main` or `${NOSTREAM_IMAGE}`) *(observed in compose)* |
| R-3 | Postgres bind mount `./.nostr/data` (relative to `${DEPLOY_ROOT}` compose file); Redis uses named volume `cache` *(observed in skeleton compose)* |
| R-4 | `deploy/README.md`: `.env` secrets on host only; bootstrap creates `.env` mode 600 |
| R-5 | Prod compose publishes `127.0.0.1:8008:8008` only *(observed in compose)* |
| R-6 | `deploy/README.md`: `/healthz` liveness — 200 while process runs, no DB check |
| R-7 | `deploy/README.md`: `/readyz` readiness — Postgres + Redis; 503 when draining on SIGTERM *(observed: `/readyz` JSON when stack healthy)* |
| R-8 | NIP-11 over `GET /` with `Accept: application/nostr+json` *(observed on dev stack)* |
| R-9 | `deploy/README.md`: drain via `WS_DRAIN_TIMEOUT_MS` (default 30s); compose `stop_grace_period: 45s` *(observed in prod compose)* |
| R-10 | `deploy/README.md` + `docs/DEPLOYMENT.md`: deliberate GHCR tag (`main` or `sha-<commit>`), not anonymous `latest` |

## Design Principles Binding the Implementation

1. **Vendor-agnostic**: implement with plain, portable components; no
   dependency on any specific agent or harness.
2. **Portable**: no absolute paths or machine-specific values in the
   implementation; use the Parameters below.
3. **Self-contained**: the implementation needs nothing outside this package
   and the declared Dependencies.
4. **Predictable, intuitive, ergonomic**: the installed capability behaves
   exactly as this document describes; no surprise behaviours.
5. **Idempotent and deterministic**: every phase is safe to re-run; checks
   give the same verdict every time.
6. **Parameterized and modular**: all tunables flow from the Parameters
   table; concerns are separated per the Modules section.
7. **Dependencies called out**: implement the declared failure behaviour for
   every Dependency.
8. **Applicable context respected**: discover what Must discover locally
   says; do not silently assume beyond May assume.
9. **Configuration flexibility**: behaviour differences come from
   configuration, never source edits.
10. **Pluggable**: implement the attach/remove seams defined in Modules and
    Removal.

Implementation-specific binding notes:

- **Portable**: `${DEPLOY_ROOT}`, `${P-2}`, `${P-3}` — bootstrap accepts target path.
- **Self-contained**: skeleton ships compose, env example, bootstrap, bundled
  `postgresql.conf`, and settings example.
- **Parameterized**: exposure mode, worker count, pool sizes, secrets — `.env` only.

## Dependencies

| Id  | Kind | What | Why needed | Discovery | Failure behaviour |
|-----|------|------|------------|-----------|-------------------|
| D-1 | system | Docker Engine + Compose v2 | Runs the stack | `docker compose version` | Hard fail before Phase 4 |
| D-2 | system | Host disk for `P-4` | Event persistence | `df -h` | Hard fail when Postgres cannot write |
| D-3 | system | `P-3` image on the host | Relay + migrate | `docker image inspect ${P-3}` | Hard fail: use save/load per Phase 1 |
| D-4 | system | TLS/WebSocket front door (optional) | Public `wss://` clients | Operator DNS/reverse proxy | Degrade: relay runs locally only |

### Recommended schematic dependencies (optional)

| Id  | Kind | What | Why | If declined |
|-----|------|------|-----|-------------|
| D-5 | schematic | [expose-container-services-privately v0.1.0](https://github.com/cameri/schematics/blob/37547e445759b652e4ad55364b0ed3b96240894e/schematics/expose-container-services-privately/SCHEMATIC.md) `sha256:ffd08754870e4aeb5ea9d375609ab7cf596795b3ae3b1ed06c97721f3425ea87` | Tailnet hostname to loopback upstream without a public port | Use nginx/Caddy/Cloudflare in Phase 7 instead |

## Parameters

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | `DEPLOY_ROOT` | path | `/opt/nostream` | Operator convention | Where compose, `.env`, and `.nostr/` live |
| P-2  | `RELAY_PORT` | integer | `8008` | `.env` / compose | HTTP + WebSocket port inside relay |
| P-3  | `NOSTREAM_IMAGE` | string | `ghcr.io/cameri/nostream:main` | GHCR or loaded tar | Relay and migrate image |
| P-4  | `NOSTR_DATA_DIR` | path | `${DEPLOY_ROOT}/.nostr` | Bootstrap | Settings, backups, Postgres bind mount parent |
| P-5  | `DB_NAME` | string | `nostr_ts_relay` | `.env` | Postgres database name |
| P-6  | `DB_USER` | string | `nostr_ts_relay` | `.env` | Postgres user |
| P-7  | `WORKER_COUNT` | integer | `2` | `.env` | Client worker processes in relay |
| P-8  | `NOSTREAM_GITHUB_REF` | string | `main` | Match `P-3` tag | Raw URL fetch for `postgresql.conf` |
| P-9  | `PULL_POLICY` | string | `never` | Air-gap vs online | When image is pre-loaded, set `never` |
| P-10 | `RELAY_PUBLIC_URL` | string | *(operator)* | DNS + TLS plan | `info.relay_url` in settings (`wss://…`) |
| P-11 | `SETTINGS_OVERRIDES` | path | `${NOSTR_DATA_DIR}/settings.yaml` | Optional file | Deep-merged overrides |
| P-12 | `EXPOSURE_MODE` | enum | `loopback` | `loopback` \| `proxy` \| `tailnet` | Whether Phase 7 runs |
| P-13 | `SECRET` | string | *(generated)* | `openssl rand -hex 128` in `.env` | Relay signing/crypto; never commit |
| P-14 | `DB_PASSWORD` | string | *(generated)* | `openssl rand -hex 32` in `.env` | Postgres password |
| P-15 | `REDIS_PASSWORD` | string | *(generated)* | `openssl rand -hex 32` in `.env` | Redis AUTH |
| P-16 | `DB_MIN_POOL_SIZE` | integer | `16` | `.env` | Knex pool minimum |
| P-17 | `DB_MAX_POOL_SIZE` | integer | `64` | `.env` | Knex pool maximum |
| P-18 | `DB_ACQUIRE_CONNECTION_TIMEOUT` | integer ms | `60000` | `.env` | Pool acquire timeout |

Compose sets **`DB_HOST`**, **`DB_PORT`**, **`REDIS_HOST`**, **`REDIS_PORT`**, and
**`NOSTR_CONFIG_DIR`** in `skeleton/compose.yml`; operators normally do not tune
those separately from the skeleton (see `skeleton/.env.example`).

## Modules

- **server-host-prerequisites** (`modules/server-host-prerequisites.md`) —
  Docker Engine, disk/RAM, firewall, SSH, compose-on-boot expectations.
- **image-delivery-and-pinning** (`modules/image-delivery-and-pinning.md`) —
  GHCR tags, `pull_policy`, save/load, bootstrap refresh vs `.env`.
- **stack-services** (`modules/stack-services.md`) — Postgres, Redis, migrate
  job, relay: ordering, volumes, users, restart policies.
- **configuration-and-secrets** (`modules/configuration-and-secrets.md`) —
  `.env`, `SECRET`, pool sizes, optional settings YAML and ownership (uid 1000).
- **exposure-and-health** (`modules/exposure-and-health.md`) — loopback bind,
  `/healthz` vs `/readyz`, reverse proxy and drain behaviour.
- **reverse-proxy-sketch** (`modules/reverse-proxy-sketch.md`) — Caddy, nginx,
  Cloudflare Tunnel, tailnet pointer; WebSocket + NIP-11 on one hostname.
- **load-balancer-cutover** (`modules/load-balancer-cutover.md`) — `/readyz`
  probes and drain for HAProxy-style rolling upgrades (advanced).
- **operations** (`modules/operations.md`) — upgrades, migrate recreate, bootstrap
  refresh, backups.

## Interfaces and Contracts

**Nostr / HTTP (relay on `P-2`):**

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `GET` | `/` | none | NIP-11 when `Accept: application/nostr+json` |
| `GET` | `/healthz` | none | Liveness (R-6) |
| `GET` | `/readyz` | none | Readiness — Postgres + Redis (R-7) |
| WebSocket | `/` | Nostr client protocol | Event pub/sub |

**Admin** (optional via settings): `/admin` when `admin.enabled` — out of
default acceptance unless operator enables it.

**Compose service names (reference skeleton):** `nostream`, `nostream-db`,
`nostream-cache`, `nostream-migrate`.

**Environment contract:** see `skeleton/.env.example` — `SECRET`, `DB_*`,
`REDIS_*`, `RELAY_PORT`, `NOSTR_CONFIG_DIR=/home/node/.nostr`, worker and pool
tuning.

## Implementation Phases

### Phase 0: Host preparation

Goal: satisfy `modules/server-host-prerequisites.md`.

Steps:
1. Install Docker Engine and Compose v2; enable `docker` at boot.
2. Choose **`P-1`** on a volume with enough free space for Postgres.
3. Configure host firewall: no public **`P-2`**; open **443** only when using
   **`P-12=proxy`** on this host.

Verify: `docker compose version`; `df -h ${DEPLOY_ROOT}`; firewall matches **`P-12`**.

### Phase 1: Discovery and image

Goal: confirm port and image availability per `modules/image-delivery-and-pinning.md`.

Steps:
1. Choose `DEPLOY_ROOT`, `P-3`, and `P-10`.
2. Pull or load `P-3`; set `PULL_POLICY` accordingly.
3. Prefer bundled `skeleton/postgresql.conf` via bootstrap; optional fetch from
   nostream at `P-8` when refreshing tuning for a new release.

Verify: `docker image inspect ${P-3}` succeeds; port `P-2` is free on host.

### Phase 2: Bootstrap deploy root

Goal: create layout and non-secret config files.

Steps:
1. Run `skeleton/bootstrap.sh ${DEPLOY_ROOT}` (from this package).
2. Copy `skeleton/.env.example` to `${DEPLOY_ROOT}/.env` if bootstrap did not.
3. Generate secrets (`openssl rand -hex 128` for `SECRET`, hex for passwords).

Verify: files exist; `.env` mode `600`; `.nostr` owned uid 1000 when root bootstrap.

### Phase 3: Optional settings overrides

Goal: set public relay identity.

Steps:
1. If needed, copy `skeleton/settings.yaml.example` to `P-11`.
2. Set `info.relay_url` to `P-10`, name, description, contact.
3. `chown 1000:1000` and `chmod 600` on settings file.

Skip: no overrides — defaults apply.
Verify: YAML parses.

### Phase 4: Start stack

Goal: migrations then relay healthy.

Steps:
1. Copy `skeleton/compose.yml` to `${DEPLOY_ROOT}/docker-compose.yml`; set `P-3`, paths.
2. `cd ${DEPLOY_ROOT} && docker compose up -d`.

Verify: A-6 (migrate before relay); `docker compose ps` shows relay up; A-2 passes.

### Phase 5: Verify relay surface

Goal: NIP-11 and readiness.

Steps:
1. Run `scripts/relay-verify.sh` from the schematic package with
   `DEPLOY_ROOT=${P-1}` and `RELAY_BASE=http://127.0.0.1:${P-2}` (see
   `modules/operations.md`).

Verify: A-1, A-2, A-3 pass.

### Phase 6: WebSocket smoke test (optional)

Goal: confirm protocol path.

Steps:
1. Use a Nostr client or `nak`/`nostr-tools` against `P-10` once exposure exists,
   or `ws://127.0.0.1:${P-2}` locally.

Verify: connection and `REQ`/`EVENT` round-trip.

### Phase 7: Exposure (conditional)

Goal: clients reach `wss://` without publishing relay on `0.0.0.0`.

Steps:
1. If `P-12=loopback`, skip.
2. If `P-12=proxy`, implement one option in `modules/reverse-proxy-sketch.md`
   (Caddy, nginx, or Cloudflare Tunnel) to `127.0.0.1:P-2`.
3. If `P-12=tailnet`, follow **expose-container-services-privately** to loopback upstream.
4. Set **`P-11`** `info.relay_url` to **`P-10`**; recreate relay if already running.
5. TLS terminates at proxy or tailnet edge; WebSocket upgrade forwarded.

Verify: external client loads NIP-11 from public URL; A-12.

## Verification and Acceptance

Automated (from schematic package):

```
DEPLOY_ROOT=${P-1} RELAY_BASE=http://127.0.0.1:${P-2} /path/to/schematic/scripts/relay-verify.sh
```

Manual or scripted (run from **`P-1`** after `docker compose up -d` unless noted):

- **A-1** (R-8): NIP-11 — script checks JSON with `name` or `description` (HTTP 200).
- **A-2** (R-6, R-7): `/healthz` → 200; `/readyz` → 200 when dependencies up (script).
- **A-3** (R-5): Loopback bind — `docker compose port nostream ${P-2}` → `127.0.0.1:*`,
  not `0.0.0.0` (script when `DEPLOY_ROOT` set).
- **A-4** (R-4): `.env` exists only on host: `stat -c '%a' ${P-1}/.env` → `600`.
  Grep this schematic package (not `${P-1}`) for committed secrets:
  `grep -rE '^SECRET=|^DB_PASSWORD=|^REDIS_PASSWORD=' schematics/run-a-decentralized-social-network-relay/skeleton/`
  → matches only placeholders in `.env.example`, never live values.
- **A-5** (R-2): Migrate and relay share one image:
  `cd ${P-1} && docker compose config --format json | jq -r '.services | ."nostream".image, ."nostream-migrate".image'`
  → two identical lines.
- **A-6** (R-1): Migrate succeeded before relay start (from **`P-1`**):
  `cd ${P-1} && docker compose ps -a --format json nostream-migrate | jq -e '.ExitCode == 0'`;
  relay `StartedAt` after migrate `FinishedAt` (compare IDs from
  `docker compose ps -aq nostream` and `docker compose ps -aq nostream-migrate`).
- **A-7** (R-3): Postgres data on host path:
  `test -d ${P-1}/.nostr/data && stat -c '%F' ${P-1}/.nostr/data` → `directory`.
  Optional persistence: insert a marker row or note, `docker compose down &&
  docker compose up -d`, confirm data still present.
- **A-8** (R-7): With Postgres stopped (`docker compose stop nostream-db`),
  `/readyz` → non-200 while `/healthz` may still → 200; restore DB and relay,
  `/readyz` recovers.
- **A-9** (R-10): Deliberate image pin recorded:
  `grep -E '^NOSTREAM_IMAGE=' ${P-1}/.env` shows a non-empty tag or digest;
  `docker image inspect "$(grep -E '^NOSTREAM_IMAGE=' ${P-1}/.env | cut -d= -f2-)" --format '{{index .RepoDigests 0}}'`
  → non-empty when pulled from GHCR (digest pin proof).
- **A-10** (R-9): Graceful drain — connect a WebSocket client, run
  `cd ${P-1} && docker compose stop -t 45 nostream`; while stopping, `/readyz` → 503 with
  `"status":"draining"` *(observed per deploy README)*; container exits before
  `stop_grace_period` elapses after drain timeout (default 30s vs 45s grace).
- **A-11** (R-8, R-6, R-7, R-5): Run `scripts/relay-verify.sh` — aggregates A-1–A-3.
- **A-12** (conditional, Phase 7): Public **`P-10`** serves NIP-11 over HTTPS
  (`curl -sS -H 'Accept: application/nostr+json' https://<host>/`).

## Failure Modes and Rollback

| Phase | Failure | Detection | Recovery |
|-------|---------|-----------|----------|
| 1 | Image missing | `docker compose up` pull error | `docker load` or fix registry access |
| 2 | Weak/missing `SECRET` | relay refuses start | Regenerate `.env`, recreate |
| 4 | Migrate fails | migrate exit non-zero | Read migrate logs; fix DB creds; do not start relay alone |
| 4 | Pool exhaustion | logs mention knex timeout | Raise `DB_MAX_POOL_SIZE` in `.env` |
| 7 | Proxy without WS upgrade | clients disconnect | Enable WebSocket pass-through on proxy |
| upgrade | Schema drift | migrate fails after image bump | Restore DB backup or fix forward with upstream migration docs |

Rollback: `docker compose down`; restore `.nostr/data` from backup if needed;
revert `P-3` tag and recreate.

## Removal

1. Stop clients pointing at `P-10`.
2. `cd ${DEPLOY_ROOT} && docker compose down` (add `-v` only if Redis volume may go).
3. Archive or delete `${DEPLOY_ROOT}/.nostr/data` only after explicit data retention decision.
4. Remove proxy/tunnel routes.
5. Confirm: nothing listens on `P-2`; no public DNS to old host.

## Decisions and Open Questions

Decisions:

- 2026-09-26 — Authored from nostream **`deploy/`** production path rather than
  dev `docker-compose.yml` (which builds from source). Operators following this
  schematic match GHCR production layout.
- 2026-09-26 — **`pull_policy: never`** default suits air-gapped and CI-loaded
  images; online hosts may set `missing` if desired (document in operations module).

Open questions:

- **Q-1**: Pin by digest vs `:main` tag? **Default**: tag matching release process;
  digest pin for highest reproducibility.
- **Q-2**: Single-host vs fleet LB cutover? **Default**: single host here;
  fleet behaviour uses `modules/load-balancer-cutover.md` and upstream
  `deploy/README.md` health-check section.
