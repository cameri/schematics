# Module: data-layer

The database and the cache: which images, where their bytes live, how an
implementer who already runs Postgres or Redis attaches them instead, and what
the database half of a backup must contain.

## Purpose

This module owns everything the Immich server persists metadata in: a Postgres
carrying a vector extension for embeddings and a Redis-compatible cache for job
queues. It is NOT responsible for the files — the originals and generated
content belong to `media-storage` — and it does not decide exposure or
inference.

## Inputs

- `${DB_DATA_LOCATION}` and a filesystem that is local to the host.
- `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE_NAME`, and `DB_STORAGE_TYPE` from
  the Parameters table.
- The database and cache image references, both resolved to digests.
- From `media-storage`: `${UPLOAD_LOCATION}`, because the instance writes its own
  database dumps into `backups/` there.

## Outputs

- A healthy `database` service listening on the Compose network at
  `database:5432`, with its cluster in `${DB_DATA_LOCATION}` and the vector
  extension available.
- A healthy `redis` service at `redis:6379` holding the job queues, with no
  durable state of its own.
- Files under `${UPLOAD_LOCATION}/backups/` produced by the instance's own
  database-dump job — the second half of the backup contract in `media-storage`.

## Dependencies

- D-1 (Docker Engine + Compose), D-4 (database image), D-5 (cache image), D-6
  (host storage).
- P-2, P-3, P-4, P-5, P-6, P-10, P-12.

## Failure Behavior

- **`${DB_DATA_LOCATION}` is a network share.** Postgres refuses or corrupts its
  cluster. Detect it before Phase 1 with `findmnt -no FSTYPE -T`; the failure is
  not recoverable by retrying, so treat a network filesystem as a blocker.
- **Credentials disagree with an existing cluster.** The image stores the role
  and password in the data directory at first initialisation. Changing
  `DB_PASSWORD` afterwards does not change them: the server logs a
  password-authentication failure and exits. Fix by restoring the original value
  or by reinitialising the directory, which is only safe before the instance
  holds data.
- **`shm_size` left at its default.** Postgres uses shared memory for parallel
  work; a container that is too small for the instance's concurrent IO fails
  with a shared-memory error. The skeleton sets 128 MB, which the upstream
  release uses.
- **Cache unavailable.** The server starts and serves the UI, but background
  work — thumbnails, metadata extraction, machine-learning jobs — queues and
  never runs. Detect with `docker compose logs redis` and
  `Administration → Job Queues`, which shows stalled jobs rather than an error.
- **Disk full.** Postgres stops accepting writes first; uploads fail after.
  Detect with `df -h` on both paths; recovery is space, not a restart.

## Idempotency Notes

- `docker compose up -d database redis` is safe to re-run. An existing cluster in
  `${DB_DATA_LOCATION}` is used as-is; the image initialises only an empty
  directory.
- Re-running the database container does not re-run migrations; the server runs
  migrations at its own startup.
- A partially initialised cluster is recognised by a non-empty directory with no
  `PG_VERSION` file. Deleting that directory's contents is safe only when the
  instance has never held data, and it destroys the metadata if it has.

### The host-service variant

An operator who already runs Postgres and Redis can use them instead of the two
Compose services. The mechanism is the server's own resolution order: Immich
looks up the hostnames `database` and `redis` unless `DB_HOSTNAME`,
`DB_PORT`, `REDIS_HOSTNAME`, and `REDIS_PORT` say otherwise, and the reference
deployment reaches host-level services by mapping those two names onto the
host's address instead — `extra_hosts: ["redis:<address>", "database:<address>"]`
— with `REDIS_PASSWORD` set to whatever the host cache requires. *(observed)*

Three consequences, all of which must be accepted deliberately:

1. The database must already carry the vector extension; a plain Postgres does
   not satisfy R-2, and installing the extension into an existing cluster is the
   operator's own change with the operator's own backup taken first.
2. Compose no longer understands the two services, so the ordering guarantee and
   the health reporting for them are gone; the server will start before they are
   ready and must retry, which it does, but a cold host will show errors in the
   log before it settles.
3. The cache's persistence becomes the operator's concern rather than a
   container's. Losing it mid-job stalls the queue until the server re-enqueues.

## Removal Notes

`docker compose down` leaves `${DB_DATA_LOCATION}` untouched, because it is a
bind mount. Removing the capability means deciding that directory's fate: it
holds albums, faces, users, and the paths of every asset, so a library without it
is a folder of unlabelled files. The cache holds nothing that is not
reconstructible.
