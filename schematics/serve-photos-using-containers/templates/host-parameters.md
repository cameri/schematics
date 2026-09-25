# Host parameter record

Fill this in during Phase 0 and keep it with the project. It is the record of
what this deployment was sized against — the file to read when something is slow,
full, or hot six months from now. One row per parameter from the schematic's
Parameters table.

## Machine

| Parameter | Value | How it was found |
|-----------|-------|------------------|
| Architecture | | `uname -m` |
| CPU cores | | `nproc` |
| Total RAM | | `free -h` |
| Docker Engine version | | `docker version --format '{{.Server.Version}}'` |
| Docker Compose version | | `docker compose version --short` |
| Host timezone | | `timedatectl show -p Timezone --value` |
| inotify watch limit | | `cat /proc/sys/fs/inotify/max_user_watches` |

## Paths

| Parameter | Value | Notes |
|-----------|-------|-------|
| UPLOAD_LOCATION | | filesystem and free space: |
| DB_DATA_LOCATION | | filesystem must be local: |
| BACKUP_TARGET | | device, and whether it is a different one: |
| MODEL_CACHE_VOLUME | | named volume, size observed: |

## Images (resolve each with `docker buildx imagetools inspect <repo>:<tag>`)

| Parameter | Value |
|-----------|-------|
| IMMICH_VERSION | |
| SERVER_DIGEST | |
| ML_DIGEST | |
| DB_IMAGE_TAG | |
| DB_DIGEST | |
| CACHE_VERSION | |
| CACHE_DIGEST | |

## Inference

| Parameter | Value | Notes |
|-----------|-------|-------|
| ML_BACKEND | | from the device discovery in preflight |
| MACHINE_LEARNING_REQUEST_THREADS | | the knob to tune first |
| MACHINE_LEARNING_WORKERS | | each worker duplicates models in memory |
| MACHINE_LEARNING_MODEL_TTL | | seconds; frees memory when idle |
| ML_CPU_LIMIT | | the accepted ceiling, recorded deliberately |
| **Accepted peak load** | | the load and temperature you accept during the first index, and the trip point that must not be reached |

## Exposure

| Parameter | Value | Notes |
|-----------|-------|-------|
| EXPOSURE | | private / localhost / tsdproxy / cloudflare |
| HTTP_PORT | | |
| IMMICH_TRUSTED_PROXIES | | the proxy's address or subnet, when one exists |
| Hostname | | for the chosen option, if any |
| IMMICH_ALLOW_SETUP | | `false` once the first administrator exists |

## External libraries (optional)

| Host path (read-only) | Container path | Exclusion patterns |
|-----------------------|----------------|--------------------|
| | | |

## First index

| Fact | Value |
|------|-------|
| Date and time the first index ran | |
| Library size at the time (assets, GB) | |
| Observed peak: machine-learning CPU share | |
| Observed peak: host load average | |
| Observed peak: package temperature and trip point | |
| Was `ML_CPU_LIMIT` in force? | |
