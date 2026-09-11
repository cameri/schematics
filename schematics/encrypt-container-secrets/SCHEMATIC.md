<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: encrypt-container-secrets
version: 0.2.1
status: stable
spec: 1
description: Encrypt service secrets with SOPS + age and inject them into container processes as environment variables at boot, in-memory, dual-recipient encryption, per-service key blast-radius, docker-secret wiring, and rotation without rebuilds.
created: 2026-09-10
updated: 2026-09-10
---

# Schematic: SOPS-Encrypted Secrets as Container Environment Variables

> **Reverse-engineered** from a production Docker Compose fleet where this
> pattern runs in a dozen services. Behaviour was reconstructed from the
> running implementation and its operational notes. Points marked `inferred:`
> were deduced from code and documentation rather than observed live.

After implementing this schematic, a service keeps its secrets **encrypted at
rest in its own repository** (SOPS + age), and at container boot the image
decrypts them **in memory** and injects the plaintext values into the
application process environment. There is no sidecar container, no shared
secrets volume, and no cleartext on disk. Rotating a secret is one command plus
a container restart, no rebuild, no ciphertext re-templating.

**Terms used throughout:**
- **SOPS** (Secrets OPerationS): the encryption tool that encrypts *values*
  inside a structured file while leaving keys and comments readable, so the
  result is diffable.
- **age**: the modern file-encryption tool SOPS uses as its key type here. Each
  key file holds a private key (`AGE-SECRET-KEY-1...`); the matching public
  half is the `age1...` string called a *recipient*.
- **dotenv**: the `KEY=value` line format of a `.env` file.
- **UID**: the numeric user identifier a process runs as.

Two encryption recipients are used for every secret file: a **host-only master
key** (break-glass, never inside any container) and a **dedicated per-service
key** (the only key mounted into that service). A compromised service can
therefore decrypt nothing beyond its own secrets.

## Applicable Context

**Must discover locally** (with the discovery command/method for each):
- The host key directory where age private keys live (`P-1`). Discovery:
  check for an existing `${HOME}/sops/age/keys.txt`; if absent, choose a
  directory and create the master key per Phase 2.
- Whether a `sops` binary exists on the host. Discovery:
  `command -v sops` returns a path. If not, every host-side operation runs
  inside the `sops` container image (all reference scripts do this
  automatically), the host then needs only Docker.
- Whether the host user's UID matches the container user's UID. Discovery:
  compare `id -u` on the host with the UID the image runs as
  (`docker image inspect <image> --format '{{.Config.User}}'`). Mismatch
  affects the permissions the mounted key file must carry (`P-8`).
- The service's application entrypoint command (`P-6`). Discovery: the
  service's existing `CMD`/`ENTRYPOINT` in `Containerfile` or `compose.yml`.

**May assume** (each with the risk if the assumption is wrong):
- Docker with Compose v2 and compose `secrets:` support (file-backed secrets).
  Risk if wrong: the secrets must instead be bind-mounted and their paths
  parameterized.
- The final image has a POSIX shell (`/bin/sh`). Risk if wrong: `sops exec-env`
  cannot spawn the app; use the binary-copy variant (base the image on the sops
  alpine image and copy the application binary in), see
  `skeleton/Containerfile.sops` variant B.
- The service runs as a single container. Risk if wrong: the sidecar pattern
  must be retained, which this schematic deliberately does not cover.

**Must not change:**
- The host's existing master age key: never regenerate or rotate it as part of
  this schematic; other services already depend on it.
- Existing cleartext `.env` files that other tooling reads: this schematic adds
  a SOPS path alongside them; migrating or deleting them is out of scope.

## Scope

**In scope:**
- age key hierarchy: master (host-only) + dedicated per-service key
  (dual-recipient encryption).
- Creating and editing the encrypted secrets file with values supplied over
  stdin, never on a command line.
- Image changes: bundling a pinned `sops` binary.
- Compose wiring: file-backed secrets, per-service secret names, read-only
  mounts, the age-key path environment variable.
- The boot wrapper that decrypts in memory and execs the application.
- Non-env/binary secrets (e.g. an SSH private key) via the binary
  decrypt round-trip.
- Verification that the master key is absent from the container and no
  cleartext persists on disk.
- Rotation runbook that requires no image rebuild.

**Out of scope / non-goals:**
- Cloud KMS / Vault / external secret managers; SOPS with age only.
- Automatic key rotation or certificate-style expiry policy.
- Multi-host orchestration or distributing keys between hosts.
- Migrating an application to read config files instead of environment
  variables.

**Preservation List** *(reverse-engineered)*:

*Must match original behaviour exactly:*
- Secrets are decrypted **in memory** at boot and exported into the
  application's process environment; no plaintext file is written anywhere
  inside the container.
- Every service holds a **dedicated** key; the master key never enters a
  container.
- The encrypted file mounts under a name ending in `.env` (e.g. `secrets.env`)
  because `sops exec-env` detects the dotenv format from the file extension.
- Secret values are stored **unquoted** in the dotenv store; `sops exec-env`
  does not strip quotes the way a shell `source` does.
- The wrapper invokes `sops exec-env` **without** a `--` separator (it breaks
  argument parsing).
- Host-side value setting goes through stdin and never appears in argv or
  shell history.

*Open to reinterpretation:*
- The exact pinned sops version (`P-7`): any current release with `exec-env`.
- Whether the sops binary is copied from the upstream alpine image or the
  final image is based on it.
- The naming of the boot wrapper (`skeleton/entrypoint.sh` here).

## Requirements

- **R-1**: Secret values MUST exist in the repository only as SOPS ciphertext;
  no plaintext secret is committed, and none appears in shell history or
  process argv anywhere in the workflow.
- **R-2**: Each encrypted secrets file MUST be encrypted to two recipients: the
  host-only master key AND a dedicated per-service key.
- **R-3**: Only the dedicated per-service key MUST be exposed to the service's
  container; the master key MUST NOT be mounted, copied, or otherwise reachable
  inside any container at runtime.
- **R-4**: At container start, secrets MUST be decrypted in memory and exposed
  to the application as environment variables; no plaintext MUST be written to
  the container filesystem (no secrets volume, no sidecar, no temp file
  containing the decrypted values).
- **R-5**: Changing a secret value MUST NOT require rebuilding the image;
  re-encrypting the file and restarting the container suffices.
- **R-6**: The image MUST contain the sops binary and a POSIX shell capable of
  running `sops exec-env`, or satisfy the distroless variant (application
  binary copied into a sops-based image).
- **R-7**: Compose secret names MUST be namespaced per service so that merging
  multiple compose files into one project cannot silently bind another
  service's key file.
- **R-8**: A non-environment binary secret (e.g. an SSH private key) MUST be
  decryptable at boot with a binary-safe round trip and written only to its
  intended in-container path with owner-only permissions.
- **R-9**: Failure to decrypt MUST FAIL the container start loudly, never start
  the application with missing or partial secrets.
- **R-10**: Removing the capability MUST be a stated, reversible procedure that
  leaves the host, the application image, and the encrypted file intact.

**Evidence** (source of each non-obvious requirement, from the implementation
this schematic was reverse-engineered from):

| Req | Evidence |
|-----|----------|
| R-1 | Operator tooling reads the value into a 0600 temp file and pipes it to `sops set --value-stdin`; the repository holds only `ENC[AES256_GCM,…]` values |
| R-2, R-3 | Per-service key files exist next to the master key; compose mounts only `<service>-keys.txt` |
| R-4 | Service `command:` values read `exec sops exec-env <file> <app>`; no shared secrets volume or sidecar presents in the running stacks |
| R-5 | The established rotation procedure is "set the value, restart the container"; images are not rebuilt |
| R-6 | Two Containerfile shapes exist in production: `COPY --from=sops` for shell images, and an image based on the sops alpine image for a distroless service |
| R-7 | Observed incident: merging compose files into one project (`include:`) put every service's secrets in one flat namespace, so a generic secret name bound the wrong key file |
| R-8 | One service decrypts its SSH private key at boot and derives the public half with `ssh-keygen -y -f` |
| R-9 | `inferred:` from sops' execution model (`exec-env` exits non-zero when decryption fails): not reproduced live; `A-9` is the test that would confirm it |
| R-10 | Design requirement of this schematic |

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

## Dependencies

| Id  | What | Why needed | Discovery | Failure behaviour |
|-----|------|------------|-----------|-------------------|
| D-1 | age encryption (keygen, recipients) | Generate the master and per-service keys, decrypt | Provided by `sops` (age built in) or the `age` package | Hard fail before Phase 2: without keys nothing encrypts |
| D-2 | SOPS binary (host or container image `P-7`) | Encrypt/decrypt the secrets file | `command -v sops`, else `docker image inspect $SOPS_IMAGE` | Hard fail before Phase 3; scripts fall back to running sops inside the image |
| D-3 | Docker Engine + Compose v2 with `secrets:` support | Run the service, mount file-backed secrets | `docker compose version` exits 0 | Hard fail before Phase 5 |
| D-4 | POSIX shell in the final image | `sops exec-env` spawns the app through `/bin/sh` | `docker run --rm <image> sh -c 'echo ok'` | Use the distroless variant (Phase 4, variant B); otherwise hard fail in Phase 6 |
| D-5 | `python3` or `jq` (host) | JSON-encode the value before `sops set --value-stdin` | `command -v python3 || command -v jq` | Degrade: the operator may pass `--value-file` with a pre-encoded value, or install one of them |
| D-6 | Application image (the service being secured) | The thing that receives the secrets | `docker compose config` resolves the service | Hard fail before Phase 4 |

## Parameters

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | KEY_DIR | path | `~/sops/age` | `ls` the default; if absent, create it in Phase 2 | Host directory holding the master key and every dedicated key |
| P-2  | MASTER_KEY_FILE | path | `${KEY_DIR}/keys.txt` | `test -f`; create with `age-keygen` if absent | Break-glass key; encrypts every service file, never enters a container |
| P-3  | SERVICE_NAME | string | (required) | The service's compose service name | Names the dedicated key `${KEY_DIR}/${SERVICE_NAME}-keys.txt` and prefixes secret names |
| P-4  | ENV_FILE | path | `<service-dir>/.env.encrypted` | `test -f`; create in Phase 3 | The committed SOPS dotenv store holding the secrets |
| P-5  | SECRET_MOUNT_NAME | string | `secrets.env` | N/A: a design decision | In-container name of the encrypted file; the `.env` suffix is what makes `sops exec-env` detect dotenv format |
| P-6  | APP_CMD | string | (required) | The service's existing `CMD`/`ENTRYPOINT` | Command `sops exec-env` execs after injecting the secrets |
| P-7  | SOPS_IMAGE | string | `ghcr.io/getsops/sops:v3.11.0-alpine` | Pull and `sops --version` inside it | Supplies the pinned sops binary for host-side operations and for image bundling |
| P-8  | KEY_FILE_MODE | octal | `0644` | Compare host UID to container UID (Applicable Context) | Permissions on the mounted dedicated key; `0600` when host UID == container UID, `0644` for a non-root container on a differently-numbered host user |
| P-9  | AGE_KEY_ENV | string | `SOPS_AGE_KEY_FILE` | N/A: a sops convention | Environment variable pointing sops at the mounted dedicated key |
| P-10 | SECRET_TARGET_PATH | path | `/run/secrets/${SECRET_MOUNT_NAME}` | N/A: a design decision | Where compose mounts the encrypted file inside the container |
| P-11 | ENV_FILE_NAME | string | `.env.encrypted` | `test -f` in the service directory | File name the helper scripts operate on inside `P-3`'s service directory (the `.encrypted` suffix is why every sops call passes an explicit `--input-type`) |

## Modules

- **Key hierarchy** (`modules/key-hierarchy.md`): master vs dedicated keys,
  dual-recipient encryption, storage layout, blast-radius reasoning.
- **Environment secrets** (`modules/env-secrets.md`): the `sops exec-env` boot
  pattern: image bundling, compose wiring, per-service secret naming, the
  quoting and format-detection constraints.
- **Binary secrets** (`modules/binary-secrets.md`): non-env secrets (SSH keys,
  keystores) decrypted at boot with the binary round trip.
- **Rotation** (`modules/rotation.md`): changing a value end to end without a
  rebuild, including the re-encryption path for adding recipients.

## Interfaces and Contracts

### Docker Compose secrets (consumed by the container)

Two file-backed secrets per service. Names are prefixed with the service name
because compose merges multiple files' secrets into one flat namespace:

```yaml
services:
  <service>:
    environment:
      - SOPS_AGE_KEY_FILE=/run/secrets/age-keys
    secrets:
      - source: <service>-env-encrypted
        target: secrets.env
      - source: <service>-age-keys
        target: age-keys

secrets:
  <service>-env-encrypted:
    file: ./.env.encrypted
  <service>-age-keys:
    file: ${KEY_DIR}/<service>-keys.txt
```

### SOPS dotenv store (the encrypted file)

Format: SOPS dotenv, one `KEY=value` per line plus a `sops_` metadata block.
Contract points:
- File name ends in `.encrypted` → sops cannot infer the store type, so every
  invocation passes `--input-type dotenv --output-type dotenv`.
- Values are stored unquoted.
- The `sops_age__list_N__map_recipient` entries must contain both the master
  public key and the service's dedicated public key.

### `sops exec-env` invocation (the boot contract)

```
exec sops exec-env <SECRET_TARGET_PATH> <APP_CMD>
```

- No `--` separator.
- Requires `SOPS_AGE_KEY_FILE` to point at the mounted dedicated key.
- Spawns the command through `/bin/sh`.
- Exits non-zero and does not exec the app if decryption fails (satisfies R-9).

### Host-side value setting (operator interface)

```
sops-set-env.sh [--value-file <path>] [--age-key <path>] <env-file> <ENV_NAME>
```

Value arrives on stdin (masked prompt) or from a file; it is JSON-encoded and
piped to `sops set --value-stdin`, so it never appears in argv. See
`scripts/sops-set-env.sh`.

## Implementation Phases

Run from the **host** in the service's repository directory. Phases are
idempotent: every step states its skip condition.

### Phase 1: System checks
Goal: verify dependencies before changing anything.

Steps:
1. `command -v docker && docker compose version`: D-3 present.
2. `command -v sops` OR confirm the container path works:
   `docker run --rm --entrypoint sops $SOPS_IMAGE --version`, D-2 present.
3. `command -v python3 || command -v jq`: D-5 present (else use
   `--value-file`).
4. `test -d "$KEY_DIR"`: note the result for Phase 2.

Verify: all four checks exit 0 (or the D-5 fallback is acknowledged).

### Phase 2: Establish the key hierarchy
Goal: a master key (if none exists) and a dedicated key for this service.

Steps:
1. Skip if `$MASTER_KEY_FILE` exists; otherwise
   `mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"` and
   `age-keygen -o "$MASTER_KEY_FILE"` (or, with no host `age`:
   `docker run --rm -v "$KEY_DIR":/out $SOPS_IMAGE sh -c 'apk add --no-cache age >/dev/null && age-keygen -o /out/keys.txt'`).
2. Derive and record the master public key: `age-keygen -y "$MASTER_KEY_FILE"`
   (or `grep 'public key:' "$MASTER_KEY_FILE"`).
3. Skip if `${KEY_DIR}/${SERVICE_NAME}-keys.txt` exists; otherwise create it
   the same way (it is written **without** the `public key:` comment line on
   some versions, verify it contains `AGE-SECRET-KEY-1`).
4. Extract the dedicated public key for the re-encryption step.

Verify:
```
grep -q 'AGE-SECRET-KEY-1' "$MASTER_KEY_FILE"
grep -q 'AGE-SECRET-KEY-1' "$KEY_DIR/${SERVICE_NAME}-keys.txt"
```
Both exit 0.

### Phase 3: Create or extend the encrypted secrets file
Goal: `$ENV_FILE` exists, dual-recipient, containing each secret unquoted.

Steps:
1. If `$ENV_FILE` does not exist, create it from a plaintext template and
   encrypt in one pass:
   `sops --input-type dotenv --output-type dotenv --encrypt --age "<MASTER_PUB>,<SERVICE_PUB>" /dev/stdin > "$ENV_FILE"`
   (with values already substituted, or empty placeholders if values arrive
   later via Phase 3 step 3).
2. If it exists but lacks the dedicated recipient, re-encrypt with both
   recipients, `scripts/sops-prepare-service.sh` performs exactly this
   (decrypt with the master key, re-encrypt to both recipients, write back).
3. Set each value:
   `scripts/sops-set-env.sh "$ENV_FILE" SOME_SECRET`
   (masked prompt; the value never reaches argv).
4. Do not commit any plaintext intermediate; the temp file used by the script
   is 0600 and removed on exit.

Verify:
```
grep -c '^sops_' "$ENV_FILE"          # >= 1
grep -c '^SOME_SECRET=' "$ENV_FILE"   # == 1
grep -o 'age1[a-z0-9]*' "$ENV_FILE" | sort -u   # exactly the two recipients
```
No plaintext value appears in the file (each value line ends in
`sops_encrypted` metadata markers, e.g. `ENC[AES256_GCM,...]`).

### Phase 4: Bundle sops in the image
Goal: the built image contains a pinned sops binary and can run `sh`.

Steps:
1. Variant A (shell already present: debian/alpine/ubuntu bases): add a
   builder stage from the sops image and copy the binary:
   `COPY --from=sops /usr/local/bin/sops /usr/local/bin/sops`
   (see `skeleton/Containerfile.sops`, variant A).
2. Variant B (distroless / scratch / no shell): base the final image on the
   sops alpine image and copy the application's binary and dependencies in
   from its original image (variant B of the same skeleton).
3. Rebuild the image. This is the only phase that ever requires a rebuild.

Verify:
```
docker run --rm <image> sh -c 'sops --version'
```
Prints a version and exits 0.

### Phase 5: Wire compose
Goal: the encrypted file and the dedicated key are mounted read-only and
pointed at by environment.

Steps:
1. Add the two secrets and the `SOPS_AGE_KEY_FILE` environment entry to the
   service (see Interfaces and Contracts above, and
   `skeleton/compose-secrets.yml`).
2. Prefix every secret name with the service name (R-7); never use a generic
   name like `age-keys` in a repository whose compose files are merged by
   `include:`.
3. Set the key file's mode per `P-8` before deploying.

Verify:
```
docker compose config | grep -A2 'source: <service>-age-keys'
docker compose config >/dev/null   # exits 0
```

### Phase 6: Boot wrapper
Goal: the container starts the application under `sops exec-env`.

Steps:
1. If the image can be based on the sops image (variant B), set
   `ENTRYPOINT ["sh","-c","exec sops exec-env /run/secrets/${SECRET_MOUNT_NAME} \"${APP_CMD}\""]`.
2. Otherwise override `command:` in compose with the same shell line
   (see `skeleton/entrypoint.sh` and `skeleton/compose-secrets.yml`).
3. Ensure no `--` separator and no shell quoting around `${SECRET_MOUNT_NAME}`.

Verify: `docker compose config` shows the wrapper as the effective command.

### Phase 7: Deploy and verify in memory
Goal: the running container holds the secrets in its process environment, the
master key is absent, and nothing cleartext is on disk.

Steps:
1. `docker compose up -d <service>` (or `docker compose restart <service>`).
2. Confirm the process environment carries the values **without printing
   them**, count matches only:
   `docker exec <service> sh -c 'tr "\0" "\n" < /proc/<pid>/environ | grep -c "^SOME_SECRET="'`
   (find `<pid>` with `docker top <service>`; with `sops exec-env` the app is a
   child of PID 1, so enumerate candidate PIDs rather than assuming PID 1).
3. Confirm the master key is not present anywhere in the container:
   `docker exec <service> sh -c 'grep -rl AGE-SECRET-KEY-1 / 2>/dev/null | head'`
   → no output.
4. Confirm no cleartext on disk: search the writable layer and volumes for a
   substring of a known secret value → no output.

Verify:
- Step 2 exits 0 (grep found exactly the expected number of lines).
- Steps 3 and 4 produce no output.

### Phase 8: Binary secret (only if the service needs one)
Goal: a non-env secret is available at its intended path with owner-only
permissions.

Steps:
1. Encrypt the file as binary:
   `sops --input-type binary --output-type binary --encrypt --age "<MASTER_PUB>,<SERVICE_PUB>" <plaintext-file> > <service-dir>/<name>.encrypted`
   (then delete the plaintext source).
2. Mount the encrypted file and the dedicated key as secrets.
3. In the boot script, before exec:
   `sops --decrypt --input-type binary --output-type binary /run/secrets/<name>.encrypted > <target-path> && chmod 600 <target-path>`
4. Derive any public counterpart the application needs (e.g.
   `ssh-keygen -y -f <target-path> > <target-path>.pub`).

Verify: the target file exists with mode 600 in the running container, and the
encrypted source remains the only committed artifact.

## Verification and Acceptance

- **A-1** (covers R-1): `git log -p -- . | grep -c '<known-distinctive-characters-of-a-secret>'`
  returns 0, no plaintext ever entered history. Also: no plaintext file is
  present in the working tree (`git status --porcelain` clean of `.env`
  additions).
- **A-2** (covers R-2): `grep -o 'age1[a-z0-9]*' "$ENV_FILE" | sort -u` lists
  exactly two recipients: the master public key and the service's dedicated
  public key.
- **A-3** (covers R-3): `docker exec <service> sh -c 'grep -rl AGE-SECRET-KEY-1 / 2>/dev/null'`
  prints nothing, while
  `docker compose config | grep "${KEY_DIR}/<service>-keys.txt"` shows the
  dedicated key is mounted.
- **A-4** (covers R-4): `docker exec <service> sh -c 'tr "\0" "\n" < /proc/<pid>/environ | grep -c "^SOME_SECRET="'`
  reports the expected count, and `docker exec <service> sh -c 'grep -rl "<distinctive-secret-substring>" / 2>/dev/null'`
  prints nothing.
- **A-5** (covers R-5): run `scripts/sops-set-env.sh` for an existing key with a
  new value, `docker restart <service>`, and A-4 still passes with the new
  value, with no image rebuild (`docker image inspect <image> --format '{{.Created}}'`
  is unchanged).
- **A-6** (covers R-6): `docker run --rm <image> sh -c 'sops --version'` exits 0.
- **A-7** (covers R-7): with every compose file in the repository merged
  (`docker compose config`), the effective secret mount for the service still
  resolves to `./.env.encrypted` and `${KEY_DIR}/<service>-keys.txt`.
- **A-8** (covers R-8, when a binary secret exists): the decrypted file exists
  in the container at its target path with mode 600 and the derived public half
  is present; the host copy of the plaintext has been deleted.
- **A-9** (covers R-9): corrupt the mounted encrypted file (append a byte),
  `docker restart <service>` → the container exits non-zero and the
  application is not running; restore the file and confirm it starts.
- **A-10** (covers R-10): after running the Removal procedure, the service
  starts with its previous configuration and the encrypted file is still in the
  working tree.

## Failure Modes and Rollback

**Phase 2 (key creation):** a lost or overwritten master key makes every
encrypted file undecryptable. Rollback: keys are files, keep a copy of
`$MASTER_KEY_FILE` outside the repository; if it was destroyed and no other
copy exists, every file must be re-encrypted from plaintext sources, which may
not exist. Treat this phase as destructive and non-recoverable by design.

**Phase 3 (encrypted file):** a botched re-encryption can drop a value. Always
work on a copy: `cp "$ENV_FILE" "$ENV_FILE.bak"` before re-encrypting, verify
the recipient list and key count afterwards, then delete the backup. To inspect
without risk: `sops --decrypt --input-type dotenv --output-type dotenv "$ENV_FILE"`
(never commit the output).

**Phase 4 (image):** variant B loses the base image's package manager and
entrypoint assumptions; if the application cannot run on alpine, keep variant A
and confirm `/bin/sh` exists in the final layer.

**Phase 6 (wrapper):** a missing shell or a stray `--` produces
`exec-env` argument errors at boot. Detect: container logs show sops usage
output. Fix the wrapper; no other phase is affected.

**Phase 7 (verification):** if the value is absent from the process environment,
the usual causes are, in order: wrong target name (no `.env` suffix → format
misdetection), quoted value in the store, wrong key mounted (secret-name
collision), or key file mode rejecting the container user. Check the recipient
list first, then the secret-name namespacing, then permissions.

**Phase 8 (binary secret):** a wrong `--input-type` on either side corrupts the
file. Detect: the decrypted file fails its consumer (e.g. `ssh -T`). Rollback:
re-encrypt from the plaintext source.

## Removal

Reverse the wiring; the encrypted artifact stays:

1. Remove the two `secrets:` entries and the `SOPS_AGE_KEY_FILE` environment
   variable from the service in `compose.yml`.
2. Restore the original `command:`/`ENTRYPOINT` (without `sops exec-env`).
3. Optionally remove the sops binary from the image and rebuild.
4. `docker compose up -d <service>`.

Confirm after removal:
```bash
docker compose config | grep -c 'SOPS_AGE_KEY_FILE'   # 0, no key wiring remains
docker compose up -d <service> && docker compose ps <service>   # running
git status --porcelain .env.encrypted       # still tracked, untouched
```

Keeping the encrypted file is intentional: it is the only artifact that cannot
be reconstructed if the keys are ever rotated back into use.

## Decisions and Open Questions

Decisions:

- 2026-09-10: Reverse-engineered from a production Docker Compose fleet where
  the single-container `sops exec-env` pattern runs in a dozen services. Two
  things were deliberately simplified out of the original: the older
  sidecar/watcher container pattern (superseded; it appears only in Removal
  context as historical), and repository-specific helper naming. The public
  contract kept intact is the in-memory decrypt + per-service key blast radius.

Open questions:

- **Q-1**: Exact `age-keygen` behaviour differs across age versions: some write
  the public key as a comment line in the private key file, some do not.
  Default: derive the public key with `age-keygen -y <keyfile>` inside the sops
  image rather than parsing a comment.
- **Q-2**: `sops exec-env` child-PID discovery for the environment check
  (`/proc/<pid>/environ`) varies with the application's process fan-out.
  Default: enumerate PIDs and assert at least one environment carries the
  variable, rather than hard-coding a PID.
- **Q-3**: Whether to commit the dedicated public keys outside the encrypted
  files (e.g. a `recipients.txt`) to make re-encryption easier for a new
  operator. Default: no, the recipient list is recoverable from the encrypted
  file with `grep -o 'age1[a-z0-9]*'`.



