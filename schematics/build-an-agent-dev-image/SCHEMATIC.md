<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: build-an-agent-dev-image
version: 0.1.0
status: draft
spec: 1
description: "The dev base image of a sandboxed coding agent: a digest-pinned distribution image that boots one agent in one workspace from an environment contract, runs as a fixed non-root account, and carries the Docker CLI, git, and build tooling — harness-free and secret-free, so a per-harness layer pins it by digest and adds only its CLI."
created: 2026-09-14
updated: 2026-09-14
---

# Schematic: Build an Agent Dev Image

> **Reverse-engineered** from a running sandboxed-agent stack in which one image
> bakes the harness, the multiplexer, every CLI tool, and a browser stack
> together, is built locally by each host from its own checkout, and boots
> through roughly a hundred lines of shell inside a container-orchestration
> command block. Behaviour was reconstructed from that stack's build file, its
> boot command, its orchestration file, and the container it produces.
> Points marked `inferred:` were deduced rather than observed; points marked
> *(observed)* were confirmed against the running implementation while writing
> this.

After implementing this schematic, the implementer has **one published base
image**: a distribution image, pinned by digest, that runs **one agent in one
workspace** and nothing else. It carries a fixed unprivileged account, the
standard entrypoint, the Docker CLI, git, and a build toolchain. It carries **no
harness CLI, no credential, no secret, no listener, and no daemon**.

The image is the bottom of a set: everything that runs an agent — a
multiplexer, a specific harness, a hardened deployment — is a **layer** built
`FROM` this image pinned by its manifest digest, adding only what it needs. The
base's guarantees are the contract those layers inherit, so the image is
versioned and published rather than rebuilt per host: a layer's identity is the
digest it pins, not the luck of last week's build.

**Terms used throughout:**

- **Base image**: the image this schematic builds and publishes. It is also the
  *only* artifact this schematic publishes.
- **Harness**: the interactive coding-agent CLI a workspace runs. The base
  ships none; a layer supplies one. The word is used generically — this
  schematic names no particular program.
- **Layer**: an image that starts from the base, pinned by digest, and adds a
  harness CLI. The base is authored first precisely because layers pin it.
- **Workspace**: the one directory an agent gets. It is the process's working
  directory and the only path the image assumes it may write.
- **Agent id**: the name of the agent running in the container. It defaults to
  the container's hostname and is the name other components label by.

## Applicable Context

**Must discover locally** (with the discovery command/method for each):

- The container runtime and its builder. Discovery: `docker version` and
  `docker buildx version`. BuildKit must be in use — the multi-platform
  contract (`R-11`) depends on the builder supplying `TARGETARCH`.
- The **manifest digest** of the distribution image to build from (`P-2`).
  Discovery: `docker buildx imagetools inspect <P-1> --format
  '{{.Manifest.Digest}}'`. Resolve it at build time; never copy a digest from
  documentation or from this package's examples.
- Whether the chosen distribution release is still supported and whether the
  Docker CLI's package repository serves it. Discovery:
  `docker run --rm <P-1> sh -c '. /etc/os-release && echo $VERSION_CODENAME'`,
  then confirm the repository advertises that suite (an HTTP request to the
  repository's `dists/<codename>/Release` path answering 200).
- Whether the ids chosen for the runtime account are free in the base image.
  Discovery: `docker run --rm <P-1> getent passwd <P-4>; docker run --rm <P-1>
  getent group <P-5>`. Both must print nothing (`R-1`).
- The owner ids of the directory that will be mounted as the workspace.
  Discovery: `stat -c '%u:%g' <directory>` on the host that will run the
  container. This is what a bind-mounted workspace's parity depends on — see
  `modules/runtime-account.md`.
- Which registry the implementer is authorized to push to, and whether they
  are logged in (`P-7`, `P-8`). Discovery: `docker login <registry>` and a test
  push of any small image; `docker buildx ls` shows whether a multi-platform
  builder exists (`P-13`).
- Whether this host already runs an image playing this role. Discovery:
  `docker image ls`, and grep the host's compose files or run commands for an
  agent base image. Two bases on one host means two divergent toolchains; pick
  one.
- Whether a **native** arm64 machine or CI runner exists (`D-4`). Discovery:
  ask the CI system, or `uname -m` on the candidate machine. This decides
  whether the second platform is verified or only published.

**May assume** (each with the risk if the assumption is wrong):

- Docker Engine with BuildKit and Buildx. Risk if wrong: the architecture
  validation fails the build at its second instruction, and no multi-platform
  manifest can be produced.
- The chosen distribution's official image publishes both `linux/amd64` and
  `linux/arm64`. Risk if wrong: the missing platform's build fails with a
  manifest error — choose a distribution image that publishes both rather than
  reinterpreting `P-12`.
- Outbound HTTPS from the build host to the distribution's package
  repositories and to the Docker CLI's package repository. Risk if wrong: the
  build fails during package installation, with the repository's own error.
- The harness CLI can be installed into an image and started as a foreground
  process by a non-root account. Risk if wrong: that harness cannot be hosted
  by this base at all — a harness that insists on root, or on a service
  manager, is out of scope here (`R-13`), and the honest response is a
  documented deviation in the layer, not a weaker base.
- The workspace can be mounted writable by the account's uid on the host that
  runs the container. Risk if wrong: the entrypoint refuses at start with
  `78`, naming the path (`R-5`) — visible and immediate, not a mystery failure
  later.

**Must not change:**

- The runtime account contract once the base is published: its name (`P-3`),
  its uid and gid (`P-4`, `P-5`), and its home path. Layers and bind mounts key
  on the ids; renaming is a breaking change for every pin.
- The entrypoint path, the `AGENT_*` variable names, and the `78` refusal code
  with its `agent-entrypoint: ` message prefix. Supervisors and harness layers
  key on all four.
- The default workspace path (`P-6`): callers mount to it.
- A published version's digest. Treat published digests as append-only: an
  image a layer pins cannot be rebuilt to the same bytes later, because the
  distribution's repositories move under it (`modules/publishing-and-pinning.md`).

## Scope

**In scope:**

- The image build: the digest-pinned distribution base, the package set (Docker
  CLI, Compose, Buildx, git, the build toolchain), the runtime account, layer
  hygiene, and provenance labels.
- The standard entrypoint: the environment contract, the checks performed
  before anything starts, workspace preparation, harness resolution from
  `PATH`, and `exec` semantics.
- The runtime account: fixed ids, home layout, writable paths, and the absence
  of any path to root inside the image.
- Multi-platform publishing: one `Containerfile` producing `linux/amd64` and
  `linux/arm64`, one manifest list, and the digest a layer pins.
- The layer contract: what a layer adds, what it must not change, and how it
  declares its base.
- A reference acceptance script that proves the whole contract against a built
  image.

**Out of scope / non-goals:**

- **Any harness CLI or its configuration.** That is a layer's whole job
  (`R-13`). The base names no harness and installs none.
- **The multiplexer layer.** Running several agents, one workspace per agent,
  attach, and supervision are a separate part of the set.
- **Credentials and daemon access.** The base carries the Docker *client* only.
  Mounting a daemon socket, scoping daemon access, encrypting secrets, and
  injecting them at boot belong to the deployment and to the published
  hardening schematics it depends on — never to this image.
- **Language runtimes beyond the declared toolchain.** Interpreters and
  version managers for languages other than the distribution's Python are a
  layer's or a caller's addition (`Q-3`), not part of the base.
- **Running the agent.** Process supervision, restart policy, resource limits,
  and orchestration are properties of the run command, not of the image.
- **A hardened variant.** There is one base, not two; hardening is a
  deployment's business.

**Preservation List** *(reverse-engineered)*:

*Must match the original's behaviour exactly:*

- **The agent never runs as root, and the account has a writable home.** The
  run contract is an unprivileged account with uid 1000 and a writable home;
  this schematic fixes the name to `user` and the home to `/home/user` so that
  layers and deployments can key on them instead of discovering them
  *(observed: the reference's image renames the distribution's uid-1000 account
  to a fixed name during the build and declares it as the image's runtime
  user)*.
- **The workspace is a bind-mounted directory the account can write, and it is
  the process's working directory.** Everything the reference's agent does
  happens inside the one mounted workspace; a session that cannot write it is
  not usable *(observed: the reference mounts the host's workspace directory at
  a fixed path and sets it as the image's working directory)*.
- **The foreground process of the container is the agent process.** The
  reference's boot block ends by `exec`-ing the multiplexer, so no shell stands
  between the container runtime and the agent; this schematic preserves the
  property at a smaller scale — the entrypoint `exec`s the harness
  *(observed: the reference's boot command's last line replaces the shell)*.
- **The image itself holds no credential.** Secrets reach the reference
  container through the orchestration layer's secret machinery and are
  materialized inside the running container, never baked into an image layer
  *(observed)*.
- **Host privilege comes from the run command, never from the image.** The
  reference's extra groups, capabilities, and devices are all declared at run
  time; the image bakes none of them *(observed)*.

*Open to reinterpretation:*

- **The distribution base.** The reference builds on a browser-testing image;
  this schematic builds on a plain slim distribution image and adds the tool
  chain explicitly, because the browser stack was mostly unused and made the
  base large. Any distribution whose official image publishes both target
  platforms and serves a Docker CLI package satisfies the contract.
- **The account name and ids.** The reference's account is named after its
  deployment; the run contract fixes `user`/`1000`/`1000` (`P-3`…`P-5`), with
  the ids re-derivable if a caller's bind mounts disagree.
- **How boot work is expressed.** The reference puts its boot logic in the
  orchestration file; this schematic packages it as one entrypoint file that
  can be tested on its own, which is also what makes the refusal codes
  meaningful.
- **What the image contains beyond the declared toolchain.** The reference
  bakes editors, file managers, and a prompt engine. Those are layers' or
  callers' choices here.
- **Whether a health check exists at all.** The reference declares one that
  probes a harness binary; this schematic declares none in the base, because
  there is nothing meaningful to probe without a harness — the layer declares
  the check that means something (`R-13`).

## Requirements

- **R-1**: The image MUST run as a fixed, unprivileged account: name `P-3`
  (`user`), uid `P-4` (1000), gid `P-5` (1000), home `/home/<P-3>`, with a
  locked password, no membership in any group beyond its own, and no `sudo` or
  other escalation path inside the image. `Config.User` MUST name that account.
  The build MUST fail rather than silently remap ids when a requested id is
  already used by the base image.
- **R-2**: The image MUST declare exactly one standard entrypoint,
  `/usr/local/bin/agent-entrypoint`, and it MUST hand control to the harness
  with `exec`: the harness becomes PID 1, receives the container's signals, and
  its exit status becomes the container's exit status unchanged.
- **R-3**: The entrypoint MUST read its runtime inputs from an environment
  contract — `AGENT_HARNESS` (required, no default in the base),
  `AGENT_WORKSPACE_DIR` (default `P-6`), `AGENT_ID` (default the container's
  hostname, restricted to `[A-Za-z0-9][A-Za-z0-9._-]*`, at most 64 characters)
  — and MUST validate each before starting anything.
- **R-4**: Every refusal MUST be a hard stop before any process starts: exit
  status `78`, one line on stderr prefixed `agent-entrypoint: `, naming the
  variable or path at fault. The entrypoint MUST NOT exit 0 without having
  exec'd a harness.
- **R-5**: The workspace (`AGENT_WORKSPACE_DIR`) MUST be created if absent, MUST
  be a directory writable by the account, and MUST be the harness's working
  directory. An unwritable or uncreatable workspace MUST be refused with the
  message and status of `R-4`. No repair requiring root is attempted.
- **R-6**: The harness MUST be resolved from `PATH` (a bare name) or accepted as
  an absolute path, through the shell's own lookup. The base image MUST ship no
  harness, and a harness that cannot be resolved MUST be refused per `R-4`.
- **R-7**: The image MUST carry the Docker CLI with its Compose and Buildx
  plugins, and MUST NOT carry daemon configuration, a socket, a group
  membership that presumes one, or any assumption that a daemon is reachable.
  Daemon access is a deployment's decision (`R-1`'s no-escalation rule still
  holds).
- **R-8**: The image MUST carry git and a build toolchain: a C/C++ compiler and
  `make`, `pkg-config`, CMake, Python 3 with its development headers and a
  working `venv`, and the common archive/transfer tools (`curl`, `wget`, `jq`,
  `unzip`, `zip`, `xz`, `tar`, `rsync`, `openssh-client`). Nothing else is
  promised; a consumer needing more installs it in its layer.
- **R-9**: The image MUST contain no secret-shaped content — no credential
  file, no key, no `.env`, no `.netrc`, no `.git-credentials`, no daemon config
  — and no harness. Secrets reach a deployment at run time or through the
  published hardening schematics; never through this image.
- **R-10**: The image MUST be built only from a digest-pinned distribution base
  and that distribution's (or the Docker CLI's own) package repositories. No
  `curl … | sh`, no unversioned installer, no language-package install from the
  network at build time. The pinned base digest MUST be recorded in the image's
  labels. Any package-repository signing key fetched at build time MUST be
  checked against a recorded fingerprint before the repository is trusted, and
  a mismatch MUST fail the build.
- **R-11**: One `Containerfile` MUST produce both `linux/amd64` and
  `linux/arm64`, validating the target architecture at build time and failing
  loudly for anything else. The two platforms MUST be publishable as one
  manifest list.
- **R-12**: The published image MUST be identifiable: tag `<P-10>-<P-11>`
  (version plus the commit that produced it), plus provenance labels for
  version, revision, source, and base digest. A consumer MUST be able to obtain
  the manifest list digest of a published version, and that digest is what a
  layer pins.
- **R-13**: A layer MUST be able to build `FROM` the base pinned by manifest
  digest, add only a harness CLI and `ENV AGENT_HARNESS`, and inherit every
  other guarantee — same account, same entrypoint, same environment contract —
  without restating any of them.
- **R-14**: The base image MUST declare no exposed port, no volume, no health
  check, and no `CMD`. At run time it MUST start exactly one process (the
  harness, per `R-2`) and open no listening socket.
- **R-15**: The image MUST run with a default `docker run` invocation: no
  capability, device, privileged mode, host namespace, or extra group is
  required for the base's own contract to hold.

**Evidence** (source of each non-obvious requirement, from the implementation
this schematic was reverse-engineered from):

| Req | Evidence |
|-----|----------|
| R-1 | The reference's build renames the distribution's uid-1000 account to a fixed name, locks nothing else about it, sets it as the image's user, and never returns to root; its runtime container reports the account's uid as non-zero *(observed)*. The reference grants no `sudo` and relies on run-time group additions instead |
| R-2 | The reference's boot block ends with an `exec` of its foreground program, so the container's PID 1 is that program and not the shell *(observed)*. That image has no packaged entrypoint at all — the whole contract this schematic standardizes is currently untestable there |
| R-3 | The reference's boot reads its inputs from the orchestration layer's environment and mounts (workspace path, session name, config directories) *(observed)*. No variable names are standardized across deployments today: each host's compose file decides them, which is exactly what makes a layer unable to assume them |
| R-4 | The reference's boot has no failure discipline: a missing mount produces a container that starts and fails later, in the harness, with a shell error. This schematic replaces that with a named refusal — `inferred:` the refusal *codes* are designed here; the failure *modes* they cover are observed |
| R-5 | The reference bind-mounts one host workspace directory into the image at a fixed path and sets it as the working directory *(observed)*. Ownership parity between the host directory and the container's uid is a standing operational hazard in that stack |
| R-6 | The reference installs the harness into the image and starts it by absolute path from its boot block *(observed)*. Resolution from `PATH` is this schematic's seam for layering — `inferred:` the choice of `PATH` lookup was made here, not observed |
| R-7 | The reference installs Docker CLI, Compose, and Buildx from the vendor's package repository and mounts the daemon socket at run time *(observed)*. The image itself carries no daemon configuration |
| R-8 | The reference's package list includes the C toolchain, `make`, `pkg-config`, Python with development headers, and the archive tools — the subset this schematic keeps *(observed)*. The rest of that list (editors, media tooling, browser libraries, language runtimes) is the part layering exists to remove |
| R-9 | The reference's image holds no credential: secrets arrive as orchestration secrets and are materialized inside the running container at boot *(observed)*. Its image also carries two harnesses and a multiplexer — the coupling this schematic removes by keeping the base harness-free |
| R-10 | The reference builds from a **tag-only** base image (no digest) and its resulting image carries no registry tag at all, so nothing downstream can pin it *(observed)*. It also fetches its vendor package repository's signing key over TLS and trusts it without checking a fingerprint *(observed)*. The digest pin, the labels, and the fingerprint check are this schematic's answer |
| R-11 | The reference builds for one architecture on whichever host runs the build *(observed)*; the same stack exists on more than one host, each rebuilding for its own architecture. Publishing one manifest list is this schematic's answer — `inferred:` the reference has no multi-platform artifact to copy |
| R-12 | The reference's image has no version, no registry entry, and no provenance labels: `docker inspect` shows a locally-generated name and the base's inherited labels *(observed)*. Two hosts' images are therefore indistinguishable artifacts of the same source |
| R-13 | The reference is a monolith: one build file installs the harness, the multiplexer, every CLI, and the browser stack, with no harness axis at all — changing the harness means editing the boot command text *(observed)* |
| R-14 | The reference's image declares a health check that probes a harness binary which is **not on `PATH`** in the running container, so it has been failing continuously: a check with nothing meaningful to probe is worse than no check *(observed)*. The same image publishes a port and mounts volumes, all declared at run time by the orchestration layer |
| R-15 | Every extra privilege the reference container has — additional groups, network capabilities, devices, host paths — is declared in its orchestration file at run time, not baked into the image *(observed)*. The base keeps that split and requires no privilege of its own |

## Design Principles Binding the Implementation

1. **Vendor-agnostic** — implement with plain, portable components; no
   dependency on any specific agent or harness.
2. **Portable** — no absolute paths or machine-specific values in the
   implementation; use the Parameters below.
3. **Self-contained** — the implementation needs nothing outside this package
   and the declared Dependencies.
4. **Predictable, intuitive, ergonomic** — the installed capability behaves
   exactly as this document describes; no surprise behaviours.
5. **Idempotent and deterministic** — every phase is safe to re-run; checks
   give the same verdict every time.
6. **Parameterized and modular** — all tunables flow from the Parameters
   table; concerns are separated per the Modules section.
7. **Dependencies called out** — implement the declared failure behaviour for
   every Dependency.
8. **Composable in kind** — a dependency may be another schematic in the
   catalog; a composition schematic owns no services, only the shared
   contracts and the end-to-end acceptance test.
9. **Applicable context respected** — discover what Must discover locally
   says; do not silently assume beyond May assume.
10. **Pluggable** — implement the attach/remove seams defined in Modules and
    Removal.

Implementation-specific binding notes:

- Principle 1 binds hardest on the **entrypoint's inputs**: `AGENT_HARNESS` is
  a name to resolve, not a program to know. Nothing in this package names a
  harness, and an implementer must not add one — the moment the base knows a
  harness, layering stops working.
- Principle 2 binds through the **digest**: the one path-like literal the
  package deliberately keeps is the image's own `/workspace` default, which is
  a contract inside the image (`P-6`), not a fact about a host.
- Principle 6 binds the **environment contract**: the three `AGENT_*`
  variables are the configuration surface of the running capability, and every
  behaviour difference between deployments should be expressible through them
  or through a layer — never through an edit to the entrypoint.
- Principle 8 binds **outward**: this package has no `schematic`-kind
  dependency of its own (it is the bottom of the set), and every later part
  depends on *it* pinned by digest. A composition that later glues the parts
  owns the end-to-end test, not this package.
- Principle 10 binds the **layer seam**: everything a consumer adds goes into
  an image that starts `FROM` this one, so removing the base means removing the
  layers above it first, in order.

## Dependencies

| Id  | Kind | What | Why needed | Discovery | Failure behaviour |
|-----|------|------|------------|-----------|-------------------|
| D-1 | system | Docker Engine with BuildKit and Buildx (`docker buildx version` exits 0) | Builds the image, supplies `TARGETARCH`, and produces the manifest list (R-11) | `docker version`, `docker buildx version` | Hard fail before Phase 2: without BuildKit there is no supported architecture-validated build, and without Buildx no multi-platform artifact |
| D-2 | system | Outbound HTTPS at build time to the distribution's package repositories and the Docker CLI's own package repository | Installs the declared toolchain (R-8) from the pinned distribution | The first build's package step | Hard fail: the build stops with the repository's error. Do not substitute an unreviewed source (R-10) |
| D-3 | system | A container registry the implementer may push to, and credentials for it | Publishing (R-12) — the act that turns a local image into something a layer can pin | `docker login <P-7>`, then a test push of any small image | Degrade: Phases 1–3 and the whole acceptance script still pass against the local image; Phase 4 (publish) cannot complete, and the base stays unpinnable until it does |
| D-4 | system | A native `linux/arm64` machine or CI runner (or a CI service that provides one) | Verifying the second platform honestly — see `modules/publishing-and-pinning.md` | `uname -m` on the candidate machine; the CI service's runner documentation | Degrade: publish the arm64 manifest anyway and record the verification basis as *unverified* in the deployment's notes. An emulated build is not a verification |

There is deliberately **no `schematic`-kind dependency**: this package is the
bottom of the set, and the hardening schematics a *deployment* may want
(scoped daemon access, encrypted secrets) attach to the deployment, not to the
base — the base mounts nothing and holds nothing secret (R-9).

## Parameters

Every environment-specific value. Referenced by name from prose and code.

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | `BASE_DISTRO_IMAGE` | string | `debian:13-slim` | The distribution's official image tags; pick a supported release whose official image publishes both platforms in `P-12` | The operating system every layer inherits — the single largest decision in the package |
| P-2  | `BASE_DISTRO_DIGEST` | string | *(none — required at build)* | `docker buildx imagetools inspect <P-1> --format '{{.Manifest.Digest}}'` — the **manifest list** digest, not a per-platform one | Pins the base bytes (R-10). Without it the build fails; that is the point |
| P-3  | `AGENT_USER` | string | `user` | Fixed by this schematic: layers and bind-mount documentation key on it. Change only with a plan for the consumers | The runtime account's name, its home directory (`/home/<P-3>`), and the group it belongs to (R-1) |
| P-4  | `AGENT_UID` | integer | `1000` | `stat -c '%u' <the directory that will be mounted as the workspace>` on the host that runs the container | The id that must own the mounted workspace for parity (R-1, R-5). The build fails if the base image already uses it |
| P-5  | `AGENT_GID` | integer | `1000` | `stat -c '%g' <the same directory>` | As `P-4`, for the group |
| P-6  | `WORKSPACE_DIR` | path (in-image) | `/workspace` | The path consumers mount to; keep it unless two mounts would collide | Baked default of `AGENT_WORKSPACE_DIR`, the account-owned directory created at build time, and the image's working directory |
| P-7  | `IMAGE_REGISTRY` | string | `ghcr.io` | The registry the implementer is authorized to push to; `docker login <registry>` | Where the published base lives; every layer's `FROM` names it |
| P-8  | `IMAGE_NAMESPACE` | string | *(from discovery — no default)* | The registry account or organization that owns the artifact (`git remote get-url origin`, or the registry's own account view) | The published path `<P-7>/<P-8>/<P-9>` |
| P-9  | `IMAGE_NAME` | string | `agent-dev-base` | Choose once; it is the stable human-readable half of the reference | The published image name; layers and deployments read it |
| P-10 | `IMAGE_VERSION` | string (semver) | `0.1.0` | This package's own version, bumped deliberately on every published change | The tag's version half (`<P-10>-<P-11>`) and the `version` label (R-12) |
| P-11 | `GIT_COMMIT` | string | *(from discovery — no default)* | `git rev-parse --short HEAD` at build time | The tag's identity half and the `revision` label: which source produced this image |
| P-12 | `PLATFORMS` | list | `linux/amd64,linux/arm64` | `docker buildx inspect --bootstrap` — the platforms the builder can produce | What the manifest list covers (R-11). Shrinking it is a decision to record, not a build fix |
| P-13 | `BUILDER_NAME` | string | `agent-base-builder` | `docker buildx ls` — an existing multi-platform builder, or create one with the `docker-container` driver | The builder used for the published multi-platform build; the default Docker driver cannot produce a manifest for a platform it cannot run |

## Modules

- **base-image** (`modules/base-image.md`) — the image itself: the pinned base,
  the package set, the account, layer hygiene, and what must never be in it.
- **entrypoint-contract** (`modules/entrypoint-contract.md`) — the runtime
  inputs, the checks, the refusal table, and the `exec` semantics layers
  inherit.
- **runtime-account** (`modules/runtime-account.md`) — the account, the
  bind-mount parity rule that decides its ids, and the no-escalation line.
- **publishing-and-pinning** (`modules/publishing-and-pinning.md`) — tags,
  the manifest list, the digest a layer pins, and the emulation honesty rule.

## Interfaces and Contracts

**Image configuration** (what a layer or a deployment reads, by inspection):

| Field | Value |
|-------|-------|
| `Config.User` | `P-3` |
| `Config.WorkingDir` | `P-6` |
| `Config.Entrypoint` | `["/usr/local/bin/agent-entrypoint"]` (exec form) |
| `Config.Cmd` | unset |
| `Config.ExposedPorts`, `Config.Volumes`, `Config.Healthcheck` | unset |
| `Config.Env` | `HOME=/home/<P-3>`, `AGENT_USER`, `AGENT_WORKSPACE_DIR=<P-6>`, `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`, `SHELL=/bin/bash`, `PATH` with `/home/<P-3>/.local/bin` first |
| Labels | `org.opencontainers.image.{title,description,licenses,version,revision,source,base.name,base.digest}` |

**Environment contract** (the running capability's inputs; normative text in
`modules/entrypoint-contract.md`):

| Variable | Card. | Default | Accepted values |
|----------|-------|---------|-----------------|
| `AGENT_HARNESS` | required | none | A bare name resolved from `PATH`, or an absolute path to an executable. Never a command with arguments and never a value starting with `-` |
| `AGENT_WORKSPACE_DIR` | optional | `P-6` | An absolute path. Created if absent; must be writable by `P-4` |
| `AGENT_ID` | optional | the container's hostname | `[A-Za-z0-9][A-Za-z0-9._-]*`, at most 64 characters |

Container arguments are forwarded to the harness unchanged. Nothing else is
read from the environment by the entrypoint, and nothing it reads is written to
disk.

**Refusal contract** (what a supervisor or a test can rely on):

- status `78` for every refusal;
- exactly one line on stderr, prefixed `agent-entrypoint: `;
- the message names the variable or path at fault;
- nothing started: no harness, no background process, no lingering directory
  beyond a workspace the entrypoint created and then found unusable.

**Filesystem contract** (paths inside the image, none of them a host path):

| Path | Meaning |
|------|---------|
| `/usr/local/bin/agent-entrypoint` | The standard entrypoint. Root-owned, mode 0755 (the runtime account cannot rewrite its own contract) |
| `/home/<P-3>` | The account's home: writable at run time, seeded with `~/.local/bin` on `PATH` |
| `P-6` | The workspace. Exists in the image (owned by the account) so that a run with no mount still works; a deployment mounts over it |

**Layer contract** (how the next part of the set attaches):

```dockerfile
ARG AGENT_DEV_BASE
ARG AGENT_DEV_BASE_DIGEST
FROM ${AGENT_DEV_BASE}@${AGENT_DEV_BASE_DIGEST}   # manifest list digest
USER root                                          # install only
RUN … install the harness CLI, pinned and verified …
USER ${AGENT_USER}                                 # back to the inherited account
ENV AGENT_HARNESS=<cli>                            # the only line the base needs
```

`skeleton/Containerfile.layer` is this contract as a template, and
`skeleton/Containerfile.layer.schema` states what a layer may and may not
change. A layer that satisfies it inherits R-1 through R-15 without restating
any of them.

**Publishing interface** (what the base offers the rest of the set):

```
docker buildx build --builder <P-13> --platform <P-12> \
  --build-arg BASE_DISTRO_DIGEST=<P-2> \
  --build-arg IMAGE_VERSION=<P-10> --build-arg GIT_COMMIT=<P-11> \
  -f Containerfile -t <P-7>/<P-8>/<P-9>:<P-10>-<P-11> --push .

docker buildx imagetools inspect <P-7>/<P-8>/<P-9>:<P-10>-<P-11>
```

The inspection's top-level `Digest:` is the value every layer pins. Per
platform digests are recorded for the audit trail, never pinned by consumers.

## Implementation Phases

Order matters in one direction: the base must exist and be published before a
layer can pin it honestly, so the publish phase precedes any layer work.

### Phase 1: Discovery and decisions

Goal: resolve every `Must discover locally` item and fix every parameter before
anything is built.

Steps:
1. Choose the distribution base (`P-1`) and resolve its manifest digest
   (`P-2`). Check that its official image publishes both platforms in `P-12`.
2. Check that the account ids (`P-4`, `P-5`) are free in that base image, and
   record the ids that own the host directory which will be mounted as the
   workspace.
3. Choose `P-7`, `P-8`, `P-9` (registry, namespace, name) and confirm the
   implementer can push (`D-3`).
4. Decide how the second platform will be verified (`D-4`): a native arm64
   machine, a CI runner, or an explicitly recorded gap.
5. Check for an existing image playing this role on the host, and decide
   whether this is replacing it or coexisting.

Skip condition: none — this phase is discovery; re-running re-confirms it.
Verify: every parameter has a value; the digest resolves; `docker run --rm <P-1>
getent passwd <P-4>` prints nothing.

### Phase 2: The image

Goal: one image that satisfies R-1 through R-11 and R-14, built from the
skeleton.

Steps:
1. Copy `skeleton/Containerfile` and `skeleton/entrypoint.sh` into the build
   context (they sit next to each other; the `COPY` in the `Containerfile`
   expects that).
2. Build for the host platform with `P-2` supplied as a build argument.
3. Read the one lint warning the build emits about the empty default of
   `BASE_DISTRO_DIGEST`: it is the unpinned-base guard, not a defect.

Skip condition: an image with the same content already exists and the package
set has not changed — rebuilding is cheap and is how distribution updates
arrive, so either way is safe.
Verify: `docker build` exits 0 and `docker image inspect` shows the account,
the entrypoint, the working directory, and the labels.

### Phase 3: Prove the contract locally

Goal: every acceptance check that does not need a registry passes.

Steps:
1. Run `scripts/verify-base-image.sh` with `BUILD=1` (it builds the image
   itself, then checks it) or point it at an image already built.
2. Read the failure lines, not just the summary: each one names the requirement
   it covers.

Skip condition: the script is read-only apart from building a throwaway layer
image and one named volume, both removed on exit; re-running is the normal way
to verify a change.
Verify: `0 failed` in the script's summary.

### Phase 4: Publish the two-platform manifest

Goal: a published reference a layer can pin (R-12).

Steps:
1. Create or select a multi-platform builder (`P-13`) if the default Docker
   driver cannot produce a manifest.
2. Run the publishing command above with `--platform <P-12>` and `--push`.
3. Inspect the published reference and record the top-level digest.
4. Verify the second platform on native hardware or a native CI runner (`D-4`);
   if neither exists, record the gap explicitly and do not claim verification.

Skip condition: re-publishing the same inputs re-pushes the same layers; a new
version is a deliberate act (`P-10` bump).
Verify: `docker buildx imagetools inspect` lists both platforms, and the
published manifest digest is written down where consumers will find it.

### Phase 5: Attach the first layer (conditional, recommended)

Goal: prove the layer contract against the published artifact — the only test
that the digest pin works end to end.

Steps:
1. Copy `skeleton/Containerfile.layer` into a layer's build context and fill
   the two placeholders: the harness installation and `AGENT_HARNESS`.
2. Build it with `AGENT_DEV_BASE_DIGEST` set to the digest recorded in Phase 4.
3. Run the layer image with `AGENT_ID` set and confirm the harness starts as
   PID 1 in the workspace.

Skip condition: `D-3` unmet (no registry) — then build the layer `FROM` the
local image by tag instead, and record that the digest pin is unverified.
Verify: the layer's `Config.User` and `Config.Entrypoint` are identical to the
base's, and the run starts the harness.

### Phase 6: Ongoing changes

Goal: the routine changes are a runbook, not an improvisation.

Steps:
1. **Distribution update**: re-resolve `P-2`, rebuild, re-run Phase 3, publish
   under a new `P-10`.
2. **Toolchain change**: edit the package list in the `Containerfile`, rebuild,
   re-run Phase 3 (the toolchain checks cover R-8), publish a new version.
3. **Account change** (`P-3`…`P-5`): treat it as breaking — every layer's
   bind-mount documentation and every deployment's directory ownership is
   affected. Do not do it to fix a build failure.
4. After any published change: tell the consumers. A layer pinning the old
   digest keeps working; a layer that wants the new base re-pins deliberately.

Skip condition: all steps are idempotent.
Verify: the specific checks named above pass for the changed image.

## Verification and Acceptance

One test per requirement minimum. Every test is runnable by the implementer
after the phases. `scripts/verify-base-image.sh` implements A-1 through A-11
and A-13 through A-16 mechanically (A-16 only when the script also does the
build, with `BUILD=1`); A-12 needs a published reference.

```
# build and verify in one step
BUILD=1 IMAGE=<local tag> scripts/verify-base-image.sh

# verify an image that already exists, and the published manifest
IMAGE=<local tag> PUBLISHED_IMAGE=<P-7>/<P-8>/<P-9>:<P-10>-<P-11> \
  scripts/verify-base-image.sh
```

- **A-1** (covers R-1): the image declares `Config.User` = `P-3`; `id -u`
  inside the container is `P-4`; `id -un` is `P-3`. expected: all three hold.
- **A-2** (covers R-1, R-7): the account is in no group but its own, and no
  `sudo` binary exists in the image. expected: neither a privileged group nor
  an escalation binary.
- **A-3** (covers R-8): `docker --version`, `docker compose version`,
  `docker buildx version`, `git --version`, `cc --version`, `make --version`,
  `cmake --version`, `pkg-config --version`, and `python3 --version` all exit 0
  inside the image, and `python3 -m venv` produces a venv whose `pip` runs.
  expected: every command reports a version.
- **A-4** (covers R-2, R-14): `Config.WorkingDir` = `P-6`, `Config.Entrypoint`
  is exactly the one path in exec form, and `Config.Cmd`,
  `Config.ExposedPorts`, `Config.Volumes`, `Config.Healthcheck` are all unset.
  expected: exactly that configuration.
- **A-5** (covers R-9): no `.env`, `.netrc`, `.git-credentials`, daemon config,
  `.ssh` directory, `.pem`, or private key exists anywhere under the account's
  home, and the home contains only the distribution's account skeleton plus
  `~/.local`. expected: no secret-shaped path.
- **A-6** (covers R-2, R-3, R-5, R-6): through a throwaway layer image that
  adds a stub CLI: with no `AGENT_ID` the stub sees the container's hostname;
  with `AGENT_ID` set it sees that value; its working directory is `P-6` (or
  the overridden `AGENT_WORKSPACE_DIR`); it is **PID 1**; and container
  arguments arrive at it unchanged. expected: all five.
- **A-7** (covers R-3, R-4, R-6): each refusal — harness not found, relative
  workspace path, invalid agent id, over-long agent id — exits `78` with a
  message naming the offending value. expected: `78` and the name, every time.
- **A-8** (covers R-6, R-9): `docker run <base image>` with no environment
  exits `78` and names `AGENT_HARNESS`. expected: a bare base image cannot
  start an agent, because it ships no harness.
- **A-9** (covers R-2): a stub harness that exits `7` makes the container exit
  `7`. expected: the harness's status, unchanged.
- **A-10** (covers R-13): the throwaway layer image, built `FROM` the base by
  digest and adding only a CLI plus `AGENT_HARNESS`, has the same
  `Config.User` and the same `Config.Entrypoint` as the base. expected:
  identical on both, with no restatement in the layer.
- **A-11** (covers R-5): with a directory mounted at `P-6` the harness starts
  there; with `AGENT_WORKSPACE_DIR` pointing at a path that does not exist yet
  under a writable parent, it is created and entered; with the mount read-only,
  the run is refused with `78` and a message naming the path. expected: all
  three.
- **A-12** (covers R-11, R-12): `docker buildx imagetools inspect <published
  reference>` lists a `linux/amd64` and a `linux/arm64` manifest, and prints a
  top-level digest. expected: both platforms and a list digest; the digest is
  recorded. (Skipped without `PUBLISHED_IMAGE`.)
- **A-13** (covers R-10, R-12): the image's labels carry version, revision,
  source, and the base digest, and that base digest equals the `P-2` value the
  image was built from. expected: four labels present, base digest matching.
- **A-14** (covers R-14): the running container has no listening TCP socket,
  and the image declares no exposed port, volume, or health check. expected:
  nothing listening, nothing declared.
- **A-15** (covers R-10): `docker history --no-trunc <image>` contains no
  pipe-to-shell (`| sh`, `| bash`) and no URL downloading an archive or
  installer (`.sh`, `.tar.gz`, `.zip`, `.deb`, `.whl`, …). expected: the build
  installs only through the distribution's and the Docker CLI's package
  repositories.
- **A-16** (covers R-10): a build whose repository key fingerprint argument is
  set to a wrong value fails, with the expected and observed fingerprints in
  its output. expected: the build stops before installing anything from that
  repository. (Run with `BUILD=1`; skipped otherwise, because the check needs
  the build.)

## Failure Modes and Rollback

| Phase | What can fail | Detection | Recovery |
|-------|---------------|-----------|----------|
| 1 | The digest resolves to a per-platform manifest rather than the list | The second platform's build fails with `no matching manifest` | Re-resolve with the discovery command in `P-2`; never hand-edit the digest |
| 1 | The requested uid or gid is already used in the base image | The build fails at account creation, naming the ids | Pick ids that match the caller's bind mounts, or change distribution base. Do not remap silently |
| 2 | A package repository is unreachable or a package was renamed upstream | The build fails during package installation | Fix the network or the package name and rebuild. Never replace the repository with an unversioned installer (R-10) |
| 2 | The vendor rotates its package-repository signing key, or the key URL serves something else | The build fails with `the package repository key fingerprint is <observed>, expected <recorded>` (A-16) | Confirm the rotation out of band — the vendor's own announcement, not the fetched file — then update the recorded fingerprint in the `Containerfile` as a deliberate change. Never delete the check to make a build pass |
| 2 | The build host lacks BuildKit, so `TARGETARCH` is empty | The build fails at the architecture validation step | Enable BuildKit; the guard exists so this cannot pass silently |
| 3 | A mounted workspace is owned by another uid | A-11's read-only case passes but the real deployment fails on first write | `chown` the host directory to `P-4`, or re-derive `P-4` from the host and rebuild — do both, not one |
| 3 | The acceptance script's throwaway layer build fails | The script exits 2 with the build's last lines | Fix the local Docker state; the script itself needs no network beyond the local daemon |
| 4 | The push is rejected (not authenticated, wrong namespace) | The publish command exits non-zero | Log in and re-run the same command; nothing about the image changes |
| 4 | The builder is not multi-platform capable | The build fails for one platform with the builder's message | Create a `docker-container`-driver builder (`P-13`) and re-run |
| 4 | The arm64 leg is built but never run | Nothing fails — that is the trap | Record the verification basis honestly; an emulated or unrun platform is *unverified* |
| 5 | The layer builds but the harness is missing from `PATH` | The container exits `78` naming `AGENT_HARNESS` | Fix the layer's installation or its `AGENT_HARNESS` value; the base is not at fault |
| any | A half-applied change: a new image built but not published, or published but not recorded | The deployment's notes name a digest that does not match the registry | Re-run Phase 4 and record the digest in the same change; a published digest is the only durable pointer |
| any | A consumer pinned a tag instead of a digest, and the tag moved | The consumer's builds change contents without a change in their own repository | Re-pin to the digest and fix the consuming layer's `FROM` |

**Rollback.** Before publishing, rollback is `docker image rm` — nothing else
exists. After publishing, rollback is re-pointing consumers to the previous
digest: published digests are not deleted, because deleting one breaks every
layer that pins it. If a published image is discovered to be wrong, publish a
new version with the fix and re-pin consumers in the same change; do not
overwrite a tag and pretend the digest did not move.

## Removal

Steps, in order:

1. **Remove the layers above it first.** Every consumer pins the base by
   digest; taking the base away while a layer still pins it makes that layer
   unbuildable and unpullable. Remove or re-pin them in this change.
2. Stop and remove any container started from the base image or a layer built
   on it: `docker rm` the containers (`docker run --rm` users have none).
3. Remove the local images and, if the build cache is not wanted,
   `docker builder prune`.
4. Delete the published version from the registry: every tag pointing at it,
   then the manifest list. Record that its digest is gone; anything pinning it
   is now broken by design and must re-pin.
5. Remove the builder, if this package created one: `docker buildx rm <P-13>`.
6. On each host that `chown`ed a workspace directory for parity, decide what
   the directory's ownership should be now. The uid has no account behind it
   once the image is gone; leaving it is a documented residue, not an error.
7. Confirm clean removal: no container, no local image, no builder, no
   published version a consumer still references, and no deployment still
   naming the digest.

Nothing on any host filesystem is owned by this schematic: the image, the
builder, and the registry entry are all the container runtime's and the
registry's. The one host-side effect is the ownership of a workspace directory
a deployment chose to align with `P-4`.

## Decisions and Open Questions

Decisions:

- 2026-09-14 — **Reverse-engineered, then deliberately narrowed.** The
  reference stack builds one image containing a harness, a multiplexer, ten CLI
  tools, a browser stack, and language runtimes. This package keeps the part
  every consumer needs (toolchain, account, entrypoint) and moves the rest to
  layers. The requirements carry an evidence table naming what was observed.
- 2026-09-14 — **The run contract's variable names are chosen here, not
  observed.** `AGENT_HARNESS`, `AGENT_WORKSPACE_DIR`, and `AGENT_ID` are fixed
  because nothing downstream can be written against an unstable name. The
  reference stack has no such contract: each deployment's orchestration file
  decides its own, which is precisely why a layer cannot assume anything there.
- 2026-09-14 — **One refusal code (`78`) and one message prefix.** A supervisor
  or a test needs one predicate ("did it refuse?"), not a taxonomy. The message
  carries the detail; the status carries the verdict.
- 2026-09-14 — **The base ships no health check.** The reference's check probes
  a harness binary that is not on `PATH`, so it fails forever: a check with
  nothing meaningful to probe is worse than none. The first layer that has a
  harness declares the check that means something.
- 2026-09-14 — **No `sudo`, and no privileged group membership.** The isolation
  posture of a sandboxed agent is worth nothing if the agent can become root
  inside its own container. Anything a deployment genuinely needs to run
  privileged belongs to the run command (`--cap-add`, a device, a group), where
  it is visible in the command rather than hidden in the image.
- 2026-09-14 — **No language runtimes beyond the distribution's Python.** A
  base that carries every language's toolchain is the monolith again. Python is
  in because "build tooling" without it is not credible for the scripts and
  data tooling agents routinely run; the rest is a layer's or a caller's
  addition (Q-3).
- 2026-09-14 — **No `AGENT_HARNESS_ARGS`.** Argument splitting in shell is a
  quoting trap, and a layer that wants default arguments can wrap its CLI in a
  three-line script — which keeps quoting out of the shared contract.
- 2026-09-14 — **No `schematic`-kind dependency.** The base is the bottom of
  the set; the hardening schematics attach to a deployment, not to the image,
  because the image mounts nothing and holds nothing secret.
- 2026-09-14 — **No `VOLUME` and no `EXPOSE` in the image.** Both instructions
  change run-time behaviour from inside the artifact (an implicit anonymous
  volume; a documented port nobody publishes). The caller's run command states
  both, visibly.
- 2026-09-14 — **Emulated multi-platform builds are not verification.** The
  building is cheap enough to do anywhere; the *verification* of the second
  platform requires running it on that architecture. Publishing an unverified
  platform is allowed; claiming it is verified is not.
- 2026-09-14 — **The run contract names the harness (`AGENT_HARNESS`), which the
  decided contract's wording does not.** The decided wording is "the entrypoint
  execs the harness CLI found in PATH"; a base that ships no harness cannot
  decide from PATH alone *which* CLI that is, so this schematic takes the CLI
  name as an input and still resolves it from `PATH` (an absolute path works
  through the same lookup). Recorded as an explicit extension rather than left
  for a reader to notice, because it moves one obligation onto every layer: a
  layer MUST set `AGENT_HARNESS`, which is why the layer template and the layer
  contract present it as the single line a layer adds. An implementation that
  bakes one fixed CLI name into the entrypoint is a different base — and a layer
  could no longer choose its harness.
- 2026-09-14 — **The package repository's signing key is fingerprint-checked.**
  Fetching a key over TLS and trusting it through `Signed-By` is the vendor's
  own documented pattern, so the alternative would not be wrong — but this
  package pins provenance at every other hop (the base by digest, the layers by
  digest), and an unchecked key would be the one input trusted on every build.
  The build therefore compares the fetched key's primary fingerprint against a
  recorded value and fails on a mismatch (A-16). The cost is stated in the
  Failure Modes table: a vendor key rotation fails the build until the recorded
  fingerprint is updated deliberately, which is the intended behaviour.

Open questions:

- **Q-1**: Must both platforms be published from day one, or is publishing
  `linux/amd64` first and adding `linux/arm64` when a native runner exists
  acceptable? **Default**: publish both (`P-12` as given) and record the arm64
  verification basis — publishing a manifest whose second platform was never
  run is honest if it is written down; silently shipping it is not.
- **Q-2**: Should the base ship an init process for child reaping? **Default**:
  no. The entrypoint `exec`s the harness, so PID 1 is the harness; a harness
  that spawns and orphans children is its own supervisor's problem, and
  `docker run --init` is available to a deployment that wants it. Revisit if a
  harness layer reports zombies.
- **Q-3**: Which language runtimes, if any, should the base carry beyond
  Python? **Default**: none. A deployment that needs Node, Go, Rust, or a JVM
  adds it in its layer (or its own layer image); adding a runtime to the base
  raises the cost of every layer and every deployment.
- **Q-4**: Should the base support a rootless or userns-remapped runtime, where
  the container's uid is not the host's? **Default**: assume the default
  namespace mapping and re-derive `P-4`/`P-5` from the host directory's owner.
  A remapped deployment re-derives the same way; what it must not do is mount a
  directory the account cannot write and expect the entrypoint to repair it.
- **Q-5**: Is `debian:13-slim` the right default distribution, or should the
  default track a longer-support release? **Default**: a current
  stable, slim distribution image whose official image publishes both
  platforms. The contract is distribution-agnostic (R-10); the default is
  chosen for a small image and a maintained package set, and `P-1` is the
  parameter that decides it.
- **Q-6**: Does the multiplexer layer keep this entrypoint and set
  `AGENT_HARNESS` to its pane wrapper, or replace the entrypoint? **Default**:
  keep it — `inferred:` the pane wrapper is a program like any other, and
  inheriting the contract keeps refusal semantics and `exec` behavior uniform
  across the set. A later part that must replace the entrypoint takes on the
  whole contract (R-2, R-4).
