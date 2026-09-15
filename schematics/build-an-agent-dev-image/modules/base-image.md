# Module: base-image

## Purpose

This module owns the image itself: which distribution it is built from, how
that distribution is pinned, which packages are installed, how the runtime
account is created, and which labels make the artifact traceable.

It is explicitly NOT responsible for the entrypoint's behaviour
(`entrypoint-contract.md`), for what the account may reach
(`runtime-account.md`), or for where the built image is published
(`publishing-and-pinning.md`).

## Inputs

- `P-1` `BASE_DISTRO_IMAGE` — the distribution image to build from.
- `P-2` `BASE_DISTRO_DIGEST` — its manifest digest. Required; the build has no
  usable default, by design (R-10).
- `P-3` `AGENT_USER`, `P-4` `AGENT_UID`, `P-5` `AGENT_GID` — the runtime account
  (see `runtime-account.md` for the parity rule these encode).
- `P-6` `WORKSPACE_DIR` — the workspace path baked in as the default.
- `P-10` `IMAGE_VERSION`, `P-11` `GIT_COMMIT` — label values only; they change
  nothing about the image's contents.
- The package-repository signing key's fingerprint — a build argument of the
  `Containerfile`, defaulting to the vendor's published fingerprint. It is a
  vendor constant rather than an environment-specific value, so it lives in the
  file (with a comment) instead of the parameter table; rotating it is a
  deliberate edit in response to a vendor rotation.
- The skeleton file `skeleton/Containerfile`, copied verbatim into the build
  context and then filled (`P-1`…`P-11` are build arguments, not edits).

Error inputs it must tolerate: a missing digest (fail the build with a clear
message), an unsupported architecture (fail the build), a uid or gid already
used by the base image (fail the build), a package repository that is
unreachable (fail the build — never substitute a different source).

## Outputs

An image with exactly this configuration (all four are contract, not
implementation detail):

| Field | Value |
|-------|-------|
| `Config.User` | `AGENT_USER` (`P-3`) |
| `Config.WorkingDir` | `WORKSPACE_DIR` (`P-6`) |
| `Config.Entrypoint` | `/usr/local/bin/agent-entrypoint` |
| `Config.Cmd` | unset |
| `Config.Env` | `HOME`, `AGENT_USER`, `AGENT_WORKSPACE_DIR`, `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`, `SHELL`, `PATH` with `~/.local/bin` first |
| `Config.ExposedPorts`, `Config.Volumes`, `Config.Healthcheck` | unset |

Side effects: the image layers, plus the local tag you build under. The package
set inside the image is the declared toolchain (R-8) and nothing else.

## Dependencies

- `D-1` (Docker Engine with BuildKit and Buildx) — the build itself, and the
  `TARGETARCH` value R-11 depends on.
- `D-2` (build-time network access to the distribution registry and the package
  repositories) — package installation.

Nothing else. In particular this module does not consume a `schematic`-kind
dependency, and it must not start consuming one: the base is the bottom of the
set.

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| `P-2` empty or malformed | The build fails at `FROM`, before any layer is produced. There is no "build it unpinned anyway" path (R-10). |
| `TARGETARCH` missing or unsupported | The build fails at an explicit validation step, naming the value. A build that does not say which architecture it produced is not a supported build (R-11). |
| uid/gid already present in the base image | The build fails before creating the account. Never remap silently: silent remapping moves the bind-mount parity problem to the caller (R-1). |
| A package repository unreachable or a package renamed upstream | The build fails. Installing the Docker CLI from an unversioned download script instead is a violation of R-10, not a fix. |
| The fetched repository key's fingerprint does not match the recorded one | The build fails before anything is installed from that repository, printing the observed and the expected fingerprint. Confirm a vendor rotation out of band before updating the recorded value; never remove the check to unblock a build. |
| The base image digest is a per-platform digest rather than the index digest | The build succeeds on one platform and fails on the other, with a "no matching manifest" error. Re-resolve the digest with the discovery method in `P-2` (a manifest *index* digest) — see `publishing-and-pinning.md`. |

## Idempotency Notes

Re-running the build with identical inputs converges: the `Containerfile` has
no timestamp-dependent step and no `latest` package source beyond the
distribution's own repositories, so two builds of the same commit produce the
same package set. The image is not claimed to be bit-reproducible (package
versions move in the repositories between builds); what is deterministic is the
*package list you asked for*, not the exact bytes of each package.

BuildKit cache mounts for the package indexes are shared between rebuilds but
keyed by an explicit id, so one deployment's build cannot poison another's
indexes on the same host.

Completion is detected by `docker image inspect <image>` succeeding and by the
`verification script` passing; a rebuild is always safe, and it is the normal
way to pick up distribution security updates.

## Removal Notes

What this module adds to the host: image layers, one local tag, and the build
cache. Removing them is `docker image rm` for the tag plus `docker builder
prune` if the cache is not wanted. Nothing on the host filesystem, no service,
no port, no user, and no credential is created by building this image — which
is why removal is `docker rmi` and not a runbook, as long as the image is not
published (for published versions see `publishing-and-pinning.md`).
