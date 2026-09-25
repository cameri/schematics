---
name: serve-photos-using-containers
version: 0.1.0
status: draft
spec: 1
description: Serving a self-hosted private photo and video library with Immich - its own Postgres carrying a vector extension and its own Valkey cache, a separate machine-learning service whose first index saturates a CPU, hardware acceleration as a parameter, tailnet-first exposure, and one backup contract that keeps the database and the originals in sync.
created: 2026-09-25
updated: 2026-09-25
---

# Schematic: Serve Photos Using Containers (Immich + Data Layer + Machine Learning)

This capability is a private photo and video library: a web application your
phone and browser talk to, the originals on your own storage, and the metadata
in your own database. It is Immich — a server, a machine-learning service that
gives you smart search and face recognition, a Postgres carrying a vector
extension for those embeddings, and a Redis-compatible cache for the job queues.
After implementing this schematic the implementer has a working instance, a
record of the host facts it was sized against, and a backup whose database half
and file half are known to belong to the same moment.

This spec was distilled from a running deployment and from the upstream
project's own release files and documentation. Statements marked *(observed)*
were verified against that deployment; statements marked `inferred:` are
reconstruction and are listed again in Open Questions.

## Applicable Context

**Must discover locally** (with the discovery method for each):

- A host path for the upload location — originals and all generated content
  (`UPLOAD_LOCATION`): `df -h` on the chosen filesystem. Size it for the
  originals plus generated content (thumbnails, previews, re-encoded video,
  database dumps), then leave room to grow.
- A separate host path for the database (`DB_DATA_LOCATION`): `df -h`, and
  `findmnt -no FSTYPE -T <path>` to confirm it is a local filesystem. A network
  share is not usable for the database.
- CPU core count and total RAM: `nproc`, `free -h`. These size the
  machine-learning service (`MACHINE_LEARNING_*` in the Parameters table).
- Whether a GPU is present, and which kind: `ls -l /dev/dri` for Intel and AMD
  integrated GPUs, `nvidia-smi -L` for NVIDIA, `cat /sys/kernel/debug/rknpu/version`
  for Rockchip. Absent devices mean the CPU backend.
- Docker Engine and Compose versions: `docker version --format '{{.Server.Version}}'`
  and `docker compose version`. An Engine older than v25 rejects a
  `healthcheck.start_interval` key.
- The account that must own the upload path on the host, so the container can
  write into it: `stat -c '%u:%g' <UPLOAD_LOCATION>`.
- Whether a tailnet, reverse proxy, or tunnel already exists, if exposure other
  than local-only is wanted (see the `exposure-and-clients` module).

**May assume** (with the risk if the assumption is wrong):

- The host is x86-64 or arm64 Linux. Risk: no published image for the
  architecture, and the pull fails at Phase 2.
- The chosen storage survives reboots and has a filesystem the kernel agrees to
  mount at boot. Risk: the library appears empty after a reboot, and the
  database may refuse to start.
- The operator can add a DNS name or tailnet hostname if phones are to reach the
  instance from outside the LAN. Risk: exposure option B or C is unavailable and
  the instance stays local-only.

**Must not change**:

- The contents of the upload location. Immich does not scan it for originals; it
  records file paths in the database, so a file moved, renamed, or deleted
  outside the application becomes an untracked or missing asset. Only copies
  taken for backup leave it.
- The database directory. The Postgres image owns its layout and its data
  directory; deleting files inside it corrupts the cluster.

## Scope

**In scope:**

- Four services in one Compose project: server, machine learning, database, cache
- The data layer as a decision: which images, which storage, where the paths are
- Machine-learning sizing stated as a parameter, including the CPU ceiling and a
  GPU backend when one exists
- The exposure decision as an explicit parameter, private by default
- A backup contract covering the database and the originals together, with the
  restore direction that keeps them consistent
- Optional indexing of photo directories the operator already owns, mounted
  read-only

**Out of scope / non-goals:**

- Photo editing, RAW development, or DAM features Immich does not provide
- Reverse-proxy or tunnel installation itself — this spec attaches to one that
  exists (`expose-container-services-privately` covers the tailnet vehicle)
- Monitoring dashboards, alerting, and off-host replication tooling; the backup
  requirement names what must be covered, not which tool copies it
- Migrating an existing library from another application

**Preservation List (reverse-engineered)** — behaviour that MUST match the
original, separated from behaviour open to reinterpretation:

- MUST match exactly: the service names Immich resolves by default
  (`DB_HOSTNAME` defaults to `database`, `REDIS_HOSTNAME` to `redis`), the
  `/data` mount point inside the server container, the database's
  `POSTGRES_INITDB_ARGS: --data-checksums`, and the cached-model volume path
  `/cache`.
- MUST match exactly: the split between originals and generated content in the
  upload location, because the backup contract depends on which folders are
  irreplaceable.
- Open to reinterpretation: which host publishes the HTTP port, whether the
  database and cache run as Compose services or as services reachable on the
  host, the machine-learning backend, and the storage layout of the host paths.

## Requirements

- **R-1**: The stack MUST run as four services — server, machine learning,
  database, cache — with exactly one of them reachable from clients; how the
  server is exposed is a parameter (`EXPOSURE`), never an accident of a
  published port. *(observed)*
- **R-2**: The database MUST be the Immich-maintained Postgres image, whose tag
  ships the vector extension; a stock Postgres defeats smart search, which is
  the feature that motivates running the machine-learning service at all.
  *(observed)*
- **R-3**: The database directory MUST be a local filesystem path on the host,
  not a network share, and its storage type MUST be declared (`DB_STORAGE_TYPE`)
  so Postgres' IO settings match the medium. *(observed)*
- **R-4**: Every image — server, machine learning, database, cache — MUST be
  digest-pinned; an upgrade resolves a new digest deliberately and records it.
  *(observed)*
- **R-5**: The upload location MUST be one host path holding both originals and
  generated content, and the downloaded models MUST live in a volume of their
  own whose loss costs a re-download rather than data. *(observed)*
- **R-6**: The backup MUST cover the database and the originals together, taken
  database-first, with the server stopped when the operator can stop it; a
  restore MUST be rehearsed once, into a scratch path, before the instance holds
  anything the operator would mourn. *(observed)*
- **R-7**: Machine-learning sizing MUST be explicit. The first index of an
  existing library is the peak-load event, so the implementation MUST set the
  concurrency knobs deliberately and MUST NOT run that first index on a host
  without thermal headroom. *(observed)*
- **R-8**: Hardware acceleration MUST be a parameter — backend, image tag
  suffix, and device passthrough — with the CPU backend as the documented
  fallback, and enabling it later MUST NOT require re-running machine-learning
  jobs. *(observed)*
- **R-9**: Exposure MUST default to private. Reaching the instance from phones
  over a public hostname requires HTTPS, and when a reverse proxy fronts the
  server the proxy's address MUST be declared (`IMMICH_TRUSTED_PROXIES`) or
  request handling attributes every client to the proxy. `inferred:`
- **R-10**: Before any exposure beyond the local host, an administrator account
  MUST exist, and after setup the sign-up endpoint SHOULD be closed
  (`IMMICH_ALLOW_SETUP=false`), because otherwise the first visitor to the URL
  becomes the owner. *(observed)*
- **R-11**: Directories the operator already owns MAY be indexed as external
  libraries, mounted read-only, with import paths expressed as container paths;
  Immich MUST NOT be the tool that reorganises those files. *(observed)*
- **R-12**: Removal MUST leave the host working and the data intact:
  `docker compose down` keeps every host path, while deleting volumes discards
  the model cache and is a separate, deliberate act. *(observed)*

### Evidence

| Requirement | Observed behaviour it was derived from |
|-------------|----------------------------------------|
| R-1 | A Compose project with a server, a machine-learning service, a database and a cache; clients reach the server over a private network attachment, and no other service is reachable. |
| R-2 | The reference deployment's database service runs the Immich-maintained Postgres image; the upstream environment documentation lists the vector extension as one of `vectorchord` and `pgvector`, auto-detected at startup. |
| R-3 | The reference deployment stores the database in a host directory; the upstream `.env` example states that network shares are not supported for the database, and the environment documentation describes `DB_STORAGE_TYPE` selecting IO tuning for SSDs or HDDs. |
| R-4 | Both Immich images in the reference deployment are referenced as `image:tag@sha256:…`. |
| R-5 | The reference deployment mounts a named volume at `/cache` for machine learning; the upstream backup documentation lists which folders under the upload location hold originals (`library`, `upload`, `profile`) and which are generated (`thumbs`, `encoded-video`). |
| R-6 | The upstream backup documentation states that database dumps contain metadata only, are written under the upload location, and that a backup of one half alone leaves broken or orphaned assets; it recommends stopping the server or backing up the database first. |
| R-7 | During a first-time index of a library on the reference host, the machine-learning container consumed roughly 40% of total host CPU and the package temperature moved from 55 to 58 °C on a host whose trip point is 120 °C. |
| R-8 | The upstream hardware-acceleration documentation lists the backends, the tag suffix per backend, the `extends` file that carries the device passthrough, and states that machine-learning jobs need no re-run after enabling acceleration. |
| R-9 | The upstream environment documentation defines `IMMICH_TRUSTED_PROXIES`, and notes that a default security header forces browser requests to HTTPS — which breaks an HTTP-only deployment. |
| R-10 | The upstream environment documentation defines `IMMICH_ALLOW_SETUP`, which disables the admin sign-up endpoint. |
| R-11 | The upstream external-library documentation states that read-only mounts prevent deletion and metadata sidecars, that import paths are container paths, and that moving a file outside Immich loses the metadata attached to it. |
| R-12 | The reference deployment's data lives entirely in host paths plus one model-cache volume, so taking the project down leaves the library readable. |

## Design Principles Binding the Implementation

1. **Vendor-agnostic** — implement with plain, portable components; no
   dependency on any specific agent or harness.
2. **Portable** — no absolute paths or machine-specific values in the
   implementation; use the Parameters below.
3. **Self-contained** — the implementation needs nothing outside this package
   and the declared Dependencies.
4. **Predictable, intuitive, ergonomic** — the installed capability behaves
   exactly as this document describes; no surprise behaviors.
5. **Idempotent and deterministic** — every phase is safe to re-run; checks
   give the same verdict every time.
6. **Parameterized and modular** — all tunables flow from the Parameters
   table; concerns are separated per the Modules section; behavior
   differences between deployments are configuration, never code edits.
7. **Dependencies called out** — implement the declared failure behavior for
   every Dependency.
8. **Composable in kind** — a dependency may be another schematic in the
   catalog, pinned to a commit and a content hash; a composition schematic
   owns no services, only the shared contracts and the end-to-end
   acceptance test.
9. **Applicable context stated** — discover what Must discover locally
   says; do not silently assume beyond May assume.
10. **Pluggable** — implement the attach/remove seams defined in Modules and
    Removal.

Binding notes for this implementation:

- Every environment variable keeps the upstream project's own name. The
  Parameters table is a contract with that project, not a renaming layer: an
  implementer who reads the upstream documentation must need no translation.
- Exposure is one parameter with four options, not four schematics: R-9 and
  R-10 state what holds under each, and the compose delta between options is one
  network attachment plus one environment variable.
- The data layer is owned by this schematic: the database and the cache are
  services in the same Compose project by default, because that is the shape
  that needs no host-level decisions. A deployment that already runs Postgres or
  Redis on the host is a documented variant, not a fork of the spec — see the
  `data-layer` module.

## Dependencies

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | system | Docker Engine + Compose v2 | Runs all four services | `docker compose version` | Blocker: nothing starts. Engine older than v25 requires dropping the `start_interval` key, see the `data-layer` module |
| D-2 | service | Immich server image | The application | Resolve the digest per Phase 1 | Blocker: no UI, no API, no uploads |
| D-3 | service | Immich machine-learning image | Smart search, face and object recognition | Same registry as D-2, tag suffixed per `ML_BACKEND` | Degrade: the library browses and uploads fine; smart search and recognition wait |
| D-4 | service | Immich Postgres image | Metadata and vector storage | Resolve the digest per Phase 1 | Blocker: the server exits at startup without its database |
| D-5 | service | Valkey (Redis-compatible) image | Job queues and background work | Resolve the digest per Phase 1 | Blocker: jobs queue but never run; thumbnails and indexing stall |
| D-6 | system | Host storage for originals, database, and model cache | Where the data lives | `df -h` and `findmnt -no FSTYPE -T` on each path | Blocker: the database refuses a network share; a full filesystem fails uploads |
| D-7 | system | A supported GPU and driver | Hardware-accelerated inference | `ls -l /dev/dri`, `nvidia-smi -L`, `cat /sys/kernel/debug/rknpu/version` | Degrade: CPU backend, at the CPU cost R-7 requires be planned for |
| D-8 | service | Tailnet, reverse proxy, or tunnel | Reaching the instance from phones | `tailscale status`, or an existing proxy's configuration | Degrade: local-only access; choose `EXPOSURE=private` |
| D-9 | service | SMTP relay | User invitations and password resets | Operator's mail service | Degrade: accounts are created by the administrator, mail is unset |

## Parameters

Every environment-specific value lives here and nowhere else.

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | UPLOAD_LOCATION | path | `/srv/immich/library` | `df -h` on the chosen filesystem | Host path mounted at `/data` in the server: originals plus generated content |
| P-2 | DB_DATA_LOCATION | path | `/srv/immich/postgres` | `findmnt -no FSTYPE -T <path>` must not be a network filesystem | Postgres data directory, mounted at `/var/lib/postgresql/data` |
| P-3 | DB_USERNAME | string | `postgres` | Upstream default | Database role |
| P-4 | DB_PASSWORD | secret | (required) | Generate with `openssl rand -hex 24`; letters and digits only | Database password for that role |
| P-5 | DB_DATABASE_NAME | string | `immich` | Upstream default | Database name |
| P-6 | DB_STORAGE_TYPE | enum | `SSD` | `findmnt -no FSTYPE`/physical medium | Postgres IO tuning: `SSD` for concurrent IO, `HDD` for sequential |
| P-7 | IMMICH_VERSION | string | `release` | Upstream release tag, or a fixed version such as `v3` | Tag half of the three Immich image references |
| P-8 | SERVER_DIGEST | string | (required) | `docker buildx imagetools inspect ghcr.io/immich-app/immich-server:${P-7}` | Digest half of the server image reference |
| P-9 | ML_DIGEST | string | (required) | Same command against the machine-learning image, tag suffixed per P-11 | Digest half of the machine-learning image reference |
| P-10 | DB_DIGEST | string | (required) | Same command against the Immich Postgres image | Digest half of the database image reference |
| P-11 | ML_BACKEND | enum | `cpu` | `ls -l /dev/dri`, `nvidia-smi -L`, `cat /sys/kernel/debug/rknpu/version` | Appends `-armnn`/`-cuda`/`-rocm`/`-openvino`/`-rknn` to the machine-learning tag and selects the device passthrough |
| P-12 | CACHE_DIGEST | string | (required) | Same command against the Valkey image | Digest half of the cache image reference |
| P-13 | TZ | string | (host timezone, e.g. `Etc/UTC`) | `timedatectl show -p Timezone --value` | Timestamps, and the fallback used when a photo carries no timezone |
| P-14 | HTTP_PORT | int | `2283` | First free port when publishing: `ss -tlnp` | Port the server listens on inside the container; published only under `EXPOSURE=localhost` |
| P-15 | EXPOSURE | enum | `private` | Operator choice: `private` (attached to an existing private network), `localhost` (published on the loopback interface), `tsdproxy`, `cloudflare` | Which network attachment the server gets, and whether a port is published |
| P-16 | IMMICH_TRUSTED_PROXIES | string | (empty) | Address or subnet of the reverse proxy, `docker network inspect` | Value of `IMMICH_TRUSTED_PROXIES`; empty means no proxy is trusted |
| P-17 | MACHINE_LEARNING_REQUEST_THREADS | int | (unset = all cores) | `nproc` | Machine-learning request thread pool; the upstream documentation names this the first knob to tune |
| P-18 | MACHINE_LEARNING_WORKERS | int | `1` | `free -h` | Machine-learning worker processes; each duplicates models in memory |
| P-19 | MACHINE_LEARNING_MODEL_TTL | int | `300` | Operator choice | Seconds of inactivity before a model unloads, and the memory it frees |
| P-20 | ML_CPU_LIMIT | string | (unset) | `nproc` | Compose CPU ceiling for the machine-learning container, e.g. `"4.0"` |
| P-21 | STORAGE_OWNER | string | (discovered) | `stat -c '%u:%g' ${P-1}` | Owner the container must be able to write as; on a mismatch, grant group access |
| P-22 | BACKUP_TARGET | path | (required for A-8) | Operator choice, ideally another device | Where the database dump and the originals' copy are written |
| P-23 | EXTERNAL_LIBRARY_PATHS | list | (empty) | Directories the operator already owns | Read-only mounts offered to external libraries, colon-separated `host:container` pairs |
| P-24 | DB_IMAGE_TAG | string | (required) | The tag the release's compose file names for its Postgres image | Tag half of the database image reference; the tag carries the vector extension |
| P-25 | CACHE_VERSION | string | (required) | The major version the release's compose file names for Valkey | Tag half of the cache image reference |
| P-26 | IMMICH_ALLOW_SETUP | enum | `true` | Operator choice | `false` closes the admin sign-up endpoint; set it once the first administrator exists |
| P-27 | REDIS_PASSWORD | secret | (empty) | Generate with `openssl rand -hex 24` | Password for the cache. Leave it empty: the cache runs without authentication and is reachable only inside the project network, and the server sends no `AUTH` when this is empty. The cache image ignores this variable, so a password takes three edits — a `command: --requirepass <value>` on the cache service, the cache's healthcheck (which would otherwise fail with `NOAUTH`), and this value |

## Modules

- **data-layer** (`modules/data-layer.md`) — the database, the cache, their
  storage contract, the host-service variant, and the database half of the
  backup.
- **machine-learning** (`modules/machine-learning.md`) — the inference service:
  what it costs, how to bound it, the acceleration backends, and the model
  cache.
- **media-storage** (`modules/media-storage.md`) — the upload location's layout,
  which folders are irreplaceable, external libraries, and the backup contract.
- **exposure-and-clients** (`modules/exposure-and-clients.md`) — how phones and
  browsers reach the instance, what each exposure option requires, and the
  first-administrator rule.

## Interfaces and Contracts

### Server HTTP surface

- `http://<host>:<HTTP_PORT>/` — the web application.
- `GET /api/server/ping` → a JSON body whose `res` field is `pong`. This is the
  liveness check every acceptance test in this spec uses.
- `GET /api/server/version` → the running version, which proves the deployed
  digest matches the intended release.
- `/api/**` — the documented API the mobile applications use. Nothing in this
  spec depends on an endpoint beyond the two above.

### Data layer contract

- Database: TCP `database:5432` on the Compose network (overridable by
  `DB_HOSTNAME`/`DB_PORT`/`DB_URL`), role `${DB_USERNAME}`, database
  `${DB_DATABASE_NAME}`.
- Cache: TCP `redis:6379` (overridable by `REDIS_HOSTNAME`/`REDIS_PORT`/
  `REDIS_URL`), no password unless one is set on both sides.
- All `DB_*` and `REDIS_*` variables must reach every worker of the server
  container, not a subset.

### Storage contract

- `${UPLOAD_LOCATION}` is mounted at `/data` inside the server container and
  contains, after first use: `upload/` and `profile/` (originals and avatars),
  `library/` (originals, only when the storage-template engine is enabled),
  `thumbs/` and `encoded-video/` (generated and re-creatable), and `backups/`
  (the instance's own database dumps).
- `${DB_DATA_LOCATION}` is mounted at `/var/lib/postgresql/data` in the
  database container and holds the cluster.
- The model cache is a named volume mounted at `/cache` in the machine-learning
  container.

### Client contract

- The mobile applications need a reachable URL and, for uploads over anything
  other than a trusted local network, TLS. The URL is set as the instance's
  external domain in the administration settings; `inferred:` the exact field
  label.
- Auth: local accounts created by the first administrator; `IMMICH_ALLOW_SETUP`
  governs whether the sign-up endpoint is open.

## Implementation Phases

Each phase states what is skipped when it has already run, and its own
verification. A phase is complete only when its verification passes.

### Phase 0: Discover the host and record it

Goal: the parameter values exist before any file is written.

Steps:

1. Run `scripts/preflight.sh`, which reports the Docker and Compose versions,
   the architecture, core count and RAM, candidate storage paths and their
   free space, any GPU devices, the inotify watch limit, and whether ports are
   free. It writes nothing.
2. Copy `templates/host-parameters.md` to a working location and fill every
   field from the preflight output; resolve the four image digests with
   `docker buildx imagetools inspect` (or `docker manifest inspect`) and record
   them.
3. Skip condition: none — the record is cheap and goes stale.

Verify: every parameter in the record has a value; no field still reads as an
instruction.

### Phase 1: Data layer

Goal: a database with the vector extension available, and a cache, both on host
storage.

Steps:

1. Create `${DB_DATA_LOCATION}` and `${UPLOAD_LOCATION}` on the host, with the
   ownership and permissions the containers can write to (P-21).
2. Copy `skeleton/compose.yml` and `skeleton/.env.example` into the project
   directory; rename the latter to `.env` and fill it from Phase 0's record.
3. Bring up only the database and the cache:
   `docker compose up -d database redis`.
4. Skip condition: the two containers are already healthy and the database
   directory is not empty — inspect with `docker compose ps` before acting.

Verify: `docker compose ps` shows both healthy; the vector extension is present
(`docker compose exec -T database psql -U "${DB_USERNAME}" -d "${DB_DATABASE_NAME}"
-c "SELECT name FROM pg_available_extensions WHERE name IN ('vectorchord','vector')"`
returns at least one row).

### Phase 2: Server

Goal: the application serves the web UI and the API.

Steps:

1. `docker compose up -d immich-server`.
2. Watch the logs until migrations finish: `docker compose logs -f immich-server`
   reports the API listening on `${HTTP_PORT}`.
3. Skip condition: `GET /api/server/ping` already answers `pong` — the server
   is up and nothing else in this phase is needed.

Verify: `scripts/verify-deployment.sh` passes its server section; create the
administrator account through the UI now, before any exposure exists (R-10).

### Phase 3: Machine learning

Goal: inference runs, at a cost the operator has chosen.

Steps:

1. Set the sizing parameters (P-17..P-20) — at minimum decide
   `MACHINE_LEARNING_REQUEST_THREADS`, because it is the knob the upstream
   documentation names first.
2. `docker compose up -d immich-machine-learning`.
3. Skip condition: the container is up and its logs show a provider or model
   load line, per the `machine-learning` module.

Verify: the container reports healthy after a warm-up request; a smart search
from the UI over an existing photo returns a result.

### Phase 4: Exposure

Goal: the instance is reachable exactly as far as intended.

Steps:

1. Set `EXPOSURE` (P-15) and, if a proxy or tunnel is in play,
   `IMMICH_TRUSTED_PROXIES` (P-16).
2. Apply only the branch that matches: attach to the existing private network,
   publish on the loopback interface, or attach to the tsdproxy or tunnel
   network with the hostname mapping.
3. Skip condition: the chosen option is already in place and the verification
   below passes.

Verify: from the chosen vantage the web UI loads and `GET /api/server/ping`
answers; from the public internet (unless the option is `cloudflare` with an
authenticating policy) the same request fails to connect.

### Phase 5: Existing photo directories (optional)

Goal: photos the operator already owns appear in the timeline without being
moved.

Steps:

1. Add read-only mounts (P-23) to the server service and bring it up again.
2. In `Administration → External Libraries`, create a library, add the
   container-side import paths, add exclusion patterns for file types not
   wanted, and scan.

Verify: assets appear in the timeline; the mounted directories are unchanged
(same file count and modification times as before the scan), and a write attempt
inside them from the container fails.

### Phase 6: Backup

Goal: one backup whose two halves belong to the same moment, and a restore that
has actually been performed.

Steps:

1. Create `${BACKUP_TARGET}`.
2. Take the database first, then the filesystem:
   `docker compose exec -T database pg_dump --clean --if-exists -U "${DB_USERNAME}"
   "${DB_DATABASE_NAME}" | gzip > "${BACKUP_TARGET}/dump-$(date +%F).sql.gz"`,
   then copy the originals folders. Stop the server first if the operator can.
3. Rehearse the restore into a scratch path per `templates/backup-and-restore.md`.

Verify: A-8.

### Phase 7: First index under observation

Goal: the expensive pass happens once, knowingly.

Steps:

1. Trigger smart-search and face-recognition jobs from `Administration → Job
   Queues` rather than waiting for them to schedule themselves.
2. Watch host load and temperature during the run (`uptime`, `sensors`).
3. Skip condition: the library has already been indexed and jobs run empty.

Verify: A-9.

## Verification and Acceptance

`scripts/verify-deployment.sh` implements the mechanical checks below; run it
from the project directory after the phases. Its sections map to these tests.

- **A-1** (covers R-1): `docker compose ps --format '{{.Service}} {{.Status}}'`
  lists four services, all `Up` (healthy where a healthcheck exists), and
  `docker compose port immich-server ${HTTP_PORT}` prints a mapping only under
  `EXPOSURE=localhost`. Expected: four services up; no published port on the
  other three.
- **A-2** (covers R-2): the database image reference contains the
  Immich-maintained repository, and
  `docker compose exec -T database psql -U "${DB_USERNAME}" -d "${DB_DATABASE_NAME}"
  -c "SELECT name FROM pg_available_extensions WHERE name IN ('vectorchord','vector')"`
  returns at least one row. Expected: one row.
- **A-3** (covers R-3): `findmnt -no FSTYPE -T "${DB_DATA_LOCATION}"` prints a
  local filesystem type, and `DB_STORAGE_TYPE` is set to a value matching the
  medium. Expected: not `nfs*`, `cifs`, or `fuseblk`.
- **A-4** (covers R-4): for each of the four services,
  `docker inspect --format '{{index .Config.Image}}' <container>` prints a
  reference containing `@sha256:`. Expected: four of four.
- **A-5** (covers R-5): `docker volume ls` shows the model cache volume, and
  `docker compose exec -T immich-machine-learning ls /cache` is non-empty after
  the first inference (it fills on demand). Expected: volume exists; contents
  appear after A-9's first search, not before.
- **A-6** (covers R-6): a dump exists under `${UPLOAD_LOCATION}/backups/` from
  the instance's own schedule, and `${BACKUP_TARGET}` holds both a dump and a
  copy of the originals from the same run. Expected: both present.
- **A-7** (covers R-10): with the instance reachable, `IMMICH_ALLOW_SETUP` is
  `false` once the administrator exists, and an unauthenticated request to the
  sign-up endpoint is refused. Expected: refused after setup.
- **A-8** (covers R-6): the rehearsal in `templates/backup-and-restore.md` was
  performed: the scratch stack started from the dump and the original files, and
  a photo known to predate the backup opens in the scratch instance. Expected:
  the photo renders; the scratch stack is then removed.
- **A-9** (covers R-7, R-8): during the first index, `docker stats --no-stream`
  shows the machine-learning container inside `ML_CPU_LIMIT` when that parameter
  is set, and the host's temperature and load stay within the operator's stated
  ceiling. With a GPU backend selected, the container's logs name the
  acceleration provider. Expected: the observed peak matches the recorded
  ceiling; with CPU backend, the operator has accepted it.
- **A-10** (covers R-9): from the chosen vantage the UI loads; from a network the
  option does not serve, the port is unreachable. With a proxy in front, the
  server's logs record client addresses rather than only the proxy's. Expected:
  both hold.
- **A-11** (covers R-11, optional): the external library's assets appear in the
  timeline, and `docker compose exec -T immich-server touch
  <container-side-import-path>/.write-test` fails with a read-only filesystem
  error. Expected: failure, and the mount removed from the compose file
  afterwards.
- **A-12** (covers R-12): `docker compose down` followed by `docker compose up -d`
  returns every service to `Up` with the library and database unchanged.
  Expected: same content, no re-download of models if the volume was kept.

## Failure Modes and Rollback

- **Phase 1 — the database exits immediately**: usually a network filesystem at
  `${DB_DATA_LOCATION}` or a permissions mismatch on the directory. Check
  `docker compose logs database`, then `findmnt` and `stat -c '%u:%g'`. Undo: none
  needed; fix the path and start again. A half-created cluster is recognised by
  a non-empty directory with no `PG_VERSION` file — delete the directory's
  contents only if the instance has never held data.
- **Phase 1 — `unknown shorthand flag` or an `InvalidDefaultArgInFrom`-style
  complaint**: the Docker CLI is the distribution's package rather than the
  official engine; install the official engine.
- **Phase 1 — `can't set healthcheck.start_interval as feature require Docker
  Engine v25 or later`**: remove the `start_interval` key from the database
  service; it is the only key in the skeleton that needs an Engine this new.
- **Phase 2 — the server starts, then exits on a database error**: the password
  or role in `.env` disagrees with what the database was initialised with.
  Postgres keeps its credentials in the data directory, so changing
  `DB_PASSWORD` afterwards does not change them. Undo: restore the old value, or
  reinitialise before the instance holds data.
- **Phase 2 — the UI loads but uploads fail**: the container cannot write to
  `${UPLOAD_LOCATION}`; check A-5's ownership (P-21).
- **Phase 3 — machine learning restarts under load**: it exceeded memory (models
  are held per worker) or the worker timeout. Lower `MACHINE_LEARNING_WORKERS`,
  lower `MACHINE_LEARNING_REQUEST_THREADS`, or raise
  `MACHINE_LEARNING_MODEL_TTL` so models unload sooner.
- **Phase 3 — smart search returns nothing**: the vector extension is missing
  (A-2) or the jobs have not run; check `Administration → Job Queues` before
  suspecting the model.
- **Phase 4 — clients see wrong addresses or rate limits trigger behind a
  proxy**: `IMMICH_TRUSTED_PROXIES` does not match the proxy's network.
- **Phase 4 — the browser refuses to load the UI over plain HTTP**: the default
  security headers upgrade requests to HTTPS. Use TLS, or serve the alternative
  security-header configuration the upstream documentation describes.
- **Phase 5 — an external library scans nothing**: the import path is the host
  path rather than the container path; also check for symlinks across mounts and
  forward slashes in the pattern.
- **Phase 5 — `ENOSPC` in the server log while watching libraries**: the kernel's
  inotify watch limit is below the number of files being watched; raise
  `fs.inotify.max_user_watches` or disable the watcher.
- **Phase 6 — the restore fails with relation or constraint errors**: the
  database was not fresh. Start the database alone with
  `DB_SKIP_MIGRATIONS=true`, restore, then unset it — the full procedure is in
  `templates/backup-and-restore.md`.
- **Rollback of any phase**: `docker compose down` stops the stack and keeps
  every host path. `docker compose down -v` additionally deletes the model cache;
  it does not touch `${UPLOAD_LOCATION}` or `${DB_DATA_LOCATION}`, both of which
  are bind mounts. Treat `-v` as a deliberate act.
- **Half-applied phase**: Phases 1, 2, and 3 are separate services, so a failed
  phase is recognisable from `docker compose ps`. Phase 5 is half-applied when
  mounts exist without a library entry (harmless) or a library exists without
  its mounts (scan fails loudly). Phase 6 is half-applied when a dump exists
  without the filesystem copy — take the copy before calling the backup done.

## Removal

1. Stop everything: `docker compose down` from the project directory. Every host
   path survives.
2. Remove the network attachment or published port if `EXPOSURE` added one.
3. Decide the data's fate explicitly, per path:
   - `${UPLOAD_LOCATION}` — the photos. Keep it; it is readable without Immich,
     because originals are ordinary files in `upload/` and, when the
     storage-template engine is enabled, in `library/`.
   - `${DB_DATA_LOCATION}` — metadata only. Keep it only if the instance may
     return; otherwise the library's organisation, albums, faces, and users are
     gone with it.
   - The model cache volume — safe to delete; it re-downloads.
4. Delete the project directory's `.env` if it holds the database password and
   the instance is not coming back.
5. Confirm removal: `docker compose ps` reports nothing, `docker ps -a` shows no
   container with the project's names, and `docker volume ls` shows no cache
   volume for the project. The photos under `${UPLOAD_LOCATION}` remain.

## Decisions and Open Questions

Decisions:

- 2026-09-25 — Reverse-engineered from a running deployment of this capability
  plus the upstream project's release compose files and documentation. The
  spec keeps the four-service shape because the machine-learning service is the
  component that needs its own sizing and its own failure behaviour.
- 2026-09-25 — The data layer is owned here rather than left to the
  implementer: the reference deployment reaches host-level Postgres and Redis
  through name remapping, which is a legitimate variant but a poor default,
  because it makes the stack's correctness depend on services this spec cannot
  see. The variant is documented in the `data-layer` module with the mechanism
  the reference deployment uses.
- 2026-09-25 — No digest value, version number, or release tag is written into
  this spec. Digests move with every release, and a spec quoting one would be
  stale the day it published; the requirement is that a digest is pinned, and
  the discovery method is how the implementer resolves it.
- 2026-09-25 — The machine-learning peak load is a requirement rather than a
  note, because the size of that burst is the single fact most likely to
  surprise an implementer who has sized the host for idle storage.

Open questions:

- **Q-1**: Whether to index existing photo directories in place
  (`EXPOSURE`-independent, Phase 5) or to import them through the upload flow.
  Default: index in place, read-only, which leaves the originals where the
  operator put them.
- **Q-2**: Whether the storage-template engine should be enabled, which moves
  new originals into `library/` under a generated structure. Default: leave it
  disabled, so originals stay exactly where the application first wrote them and
  the backup contract stays simple.
- **Q-3**: Whether to configure an SMTP relay (D-9). Default: not configured;
  the administrator creates accounts directly, and password resets are manual.
- **Q-4**: Whether the database and cache should be services in this project or
  shared host services as the reference deployment has them. Default: in this
  project, per the decision above; the variant is documented for operators who
  already run both.
