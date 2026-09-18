<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: run-multiplexed-agent-workspaces
version: 0.1.0
status: draft
spec: 1
description: "An agent host: the dev base image plus a herdr multiplexer that runs one named workspace per agent, relaunches only what crashes, keeps every agent's state on bind-mounted directories, and accepts herdr --remote attach over a key-only SSH transport — harness-free, secret-free and outbound-only by default."
created: 2026-09-18
updated: 2026-09-18
---

# Schematic: Run Multiplexed Agent Workspaces

> **Reverse-engineered** from a running sandboxed-agent stack that hosts several
> agents in one container: a herdr server started detached, one named workspace
> per agent, a pane wrapper that relaunches only on a crash, a tailnet-bound sshd
> whose `SetEnv` carries the herdr session into SSH sessions, and bind-mounted
> per-agent homes. Behaviour was reconstructed from that stack's orchestration
> file, its pane wrapper, its plugin manifest and the container it produces, and
> confirmed by driving herdr 0.9.0 directly. Points marked `inferred:` were
> deduced rather than observed; points marked *(observed)* were confirmed against
> a running implementation while writing this.

After implementing this schematic, the implementer has **one published agent-host
image** and a running host: a container that runs **several agents at once**, one
per named herdr workspace, each in its own workspace directory with its own
mounted home, each supervised so that a crash comes back and a deliberate exit
does not, and each reachable through `herdr --remote` over a key-only SSH
transport. Stopping the container frees memory and touches no state; starting it
again resumes every agent where it left off.

It is the second part of a set. The first part is the dev base image
(`build-an-agent-dev-image`), which is harness-free, secret-free and runs one
agent in one workspace; this layer adds the multiplexer and the lifecycle around
that contract without changing it. A harness layer, built on top, supplies the
agent CLI and nothing else.

**Terms used throughout:**

- **Agent**: one named coding-agent session on the host. Its **agent id** is a
  short name (`[A-Za-z0-9._-]`, at most 64 characters) that becomes a herdr
  workspace label, a directory name, a state-directory name and a log name. The
  id is the identity every part of this package keys on.
- **Agent host**: the container this package produces and runs. One host runs N
  agents; it is not one container per agent.
- **Agent tree**: the host directory bind-mounted into the container that holds
  every agent's workspace, home and supervision state. It is the only place
  state lives.
- **Base image**: the artifact of `build-an-agent-dev-image`, pinned by its
  manifest list digest. Its account, entrypoint, working directory and `AGENT_*`
  variable names are inherited by this package and never restated.
- **Entrypoint (the base's)**: the program that runs one agent in one workspace.
  Every agent pane runs it; this package does not replace or wrap it.
- **Harness**: the coding-agent CLI a pane runs, resolved by the base's
  entrypoint from `AGENT_HARNESS`. This package ships none.
- **herdr**: the terminal multiplexer that owns workspaces, tabs and panes, and
  runs one persistent server per named session.
- **Pane wrapper**: the script that runs as the agent pane's process and
  relaunches the agent when it crashes (this package's `agent-loop.sh`).
- **Roster**: the derived, tab-separated file the boot program writes, mapping a
  herdr workspace id to an agent id, its workspace directory and its home. It is
  how a pane learns which agent it is.
- **Session leader**: a process that is its own session (`getsid() == getpid()`).
  herdr's remote attach reads this property before it will attach without
  offering a restart.

## Applicable Context

**Must discover locally** (with the discovery command/method for each):

- The container runtime and its builder (`docker version`, `docker buildx
  version`), and whether it can produce multi-platform manifests
  (`docker buildx ls`) — the layer inherits the base's platform set (`P-32`).
- The **manifest digest** of the base image (`P-2`): `docker buildx imagetools
  inspect <P-1> --format '{{.Manifest.Digest}}'`. Resolve it at build time and
  never copy one from documentation.
- The distribution release the base was built from and whether its repositories
  still serve it — the layer installs packages from the same repositories
  (`D-7`).
- Whether the herdr release named by `P-3` still publishes the two asset
  digests in `P-4` and `P-5`. Discovery: the release's asset list, e.g.
  `curl -fsSL https://api.github.com/repos/herdrdev/herdr/releases/tags/v<P-3>`,
  reading each asset's `digest`. A digest that no longer matches means the
  release was replaced: stop and pick a version whose digests you have verified.
- The owner ids of the host directory that will be mounted as the agent tree:
  `stat -c '%u:%g' <directory>`. They must match the base's runtime account, or
  the account cannot write the tree (`modules/persistence-and-mounts.md`).
- The agent ids this host will run (`P-11`) and their count: the host runs all of
  them in one container, and each costs one workspace, one pane and one process
  tree.
- Whether an SSH client and a herdr client binary exist on the machine an
  operator will attach from (`D-8`). Discovery: `ssh -V` and `herdr --version`
  on that machine.
- Whether anything already listens on the attach port on the address the
  deployment will publish (`P-19`, `P-20`). Discovery: `ss -tlnp` on the host, or
  a connection attempt to `<address>:<port>`.
- Whether this host already runs an agent host. Discovery: `docker ps` and grep
  the deployment's compose files for the image name (`P-6`). Two hosts on one
  Docker daemon is a decision, not an accident: they share the daemon's
  resources, and each needs its own agent tree and attach port.

**May assume** (each with the risk if the assumption is wrong):

- The base image publishes the platforms in `P-32`. Risk if wrong: the build
  fails with a manifest error for the missing platform, rather than producing a
  host that cannot run there.
- The base's runtime account can create and write directories under the mounted
  tree. Risk if wrong: the boot refuses with exit 78 naming the directory, which
  is visible and immediate rather than an agent failing on its first write.
- The host runs with outbound network access at run time — for the agents' own
  traffic, not for this package, which fetches nothing once built. Risk if wrong:
  agents whose work needs a network fail on their own terms; the host,
  supervision, attach and persistence are unaffected.
- herdr's CLI surface used here (`workspace create|list|close|focus`, `plugin
  link|list`, `plugin pane open`, `pane close|list`, `session list --json`,
  `server`) is present at the pinned version and keeps working across the minor
  releases of the same major. Risk if wrong: the boot refuses or the acceptance
  script fails loudly on the exact command, rather than a host that looks up but
  behaves differently.
- A herdr client attaches from an interactive terminal. Risk if wrong: attach
  from a non-interactive context cannot answer herdr's prompts — fix the server's
  session-leader property instead of relying on a prompt nobody can answer.

**Must not change:**

- The base's runtime account, its ids and its home. Every pane runs as that
  account; a second identity would break the mount parity the tree depends on.
- The base's entrypoint path, its `AGENT_*` variable names, its `78` refusal code
  and its message prefix. They are the contract every agent pane runs under and
  every harness layer writes through.
- The default workspace path of the base image. Per-agent workspace directories
  are a deliberate deployment override; the image's default stays the base's.
- The agent id of a running agent. It is the workspace label, the directory name
  and the log name: renaming it orphans all three. Add a new id and retire the
  old one instead.
- A published image digest. Treat published tags as append-only.

## Scope

**In scope:**

- The host image: the base pinned by manifest digest, the SSH daemon and its
  client tools, `jq`, `util-linux`, herdr at a pinned version, the plugin, the
  configuration template and the boot program.
- The workspace model: one agent per named herdr workspace, labelled with the
  agent id, reconciled on every boot, plus the roster that carries identity into
  the panes.
- Supervision: crash-only relaunch by an in-pane wrapper, the clean-exit stop
  marker, the crash-loop bound and the `pane.exited` fallback hook.
- Remote attach: the key-only SSH daemon, the `SetEnv` parity with the server's
  configuration context, the detached-server requirement, and a diagnostic script
  that checks all three.
- Persistence: the bind-mounted agent tree, what survives a restart and a stop,
  and the ownership rule that makes a bind mount work as the account.
- A mechanical acceptance script that drives a real herdr inside a real
  container through the whole lifecycle.

**Out of scope / non-goals:**

- **Any harness CLI.** A pane runs whatever the base's entrypoint resolves from
  `AGENT_HARNESS`; supplying it is a harness layer's job.
- **Credentials and provider keys.** They arrive from the callers of this layer:
  the pinned `encrypt-container-secrets` decrypts them at boot, and the pinned
  `run-an-llm-router` is the inference endpoint a harness points at.
- **The Docker socket.** This package never mounts it; Docker CLI access, when a
  deployment wants it, goes through the pinned `restrict-docker-api-access`
  endpoint.
- **Egress control.** Outbound internet from an agent is unmediated here; the set
  defers that to a proxy-and-tunnel mitigation, and this package does not
  pretend to have one.
- **Multi-host orchestration.** One host is one container on one machine.
- **The agent's own state semantics.** What a harness writes into its home is
  its business; this package guarantees the mount and the resume, not the
  contents.

**Preservation List** (behaviours that must match the reference implementation):

- The restart policy is crash-only, keyed on the exit status: `>= 128` (death by
  signal, including an interactive interrupt's 130) relaunches **in the same
  pane**; `< 128` is deliberate and writes the stop marker.
- The stop marker is the maintenance escape hatch and is never cleared by a
  restart of the host.
- The herdr server is started as its own session leader, and the SSH `SetEnv`
  carries exactly the `XDG_CONFIG_HOME` and `HERDR_SESSION` the server runs with.
- A workspace is labelled with the agent id, and the agent pane is a plugin pane
  in that workspace, so the workspace and its agent never disagree about identity.
- The workspace's shell pane is closed once the agent pane is open, and kept if
  opening the agent pane failed.

## Requirements

- **R-1**: The host image is built `FROM` the base image pinned by its manifest
  list digest, adds only packages and files, and inherits the base's runtime
  account, entrypoint, working directory and `AGENT_*` variable names unchanged.
  It declares no port and no volume.
- **R-2**: One agent is one herdr workspace, labelled with the agent id, whose
  working directory is that agent's workspace directory. The boot reconciles the
  set: every workspace carrying a configured label is closed, and exactly one per
  configured id exists afterwards.
- **R-3**: Each agent pane runs the base's entrypoint as the inherited account,
  as the pane's child, with `AGENT_ID`, `AGENT_WORKSPACE_DIR` and `HOME` set from
  the agent's own directories. Identity is resolved from the workspace, never
  from the pane's environment.
- **R-4**: Supervision is crash-only. An exit status at or above 128 is a crash
  and the agent is relaunched in the same pane; a status below 128 is a
  deliberate exit, writes the agent's stop marker, and leaves the pane closed.
- **R-5**: The crash path is bounded: a configured number of launches inside a
  configured window makes the wrapper back off before the next attempt, and the
  stop marker suppresses starting the agent at all.
- **R-6**: A stopped agent is never restarted by a boot, and stopping frees
  memory without deleting state.
- **R-7**: Every persistent path is a bind mount: per agent a workspace directory
  and a home, plus the host's supervision state and SSH material. A container
  recreate resumes each agent from the files in its home.
- **R-8**: Remote attach is `herdr --remote` over SSH, key-only, and the three
  properties it needs hold: a reachable key-only daemon, `SetEnv` parity with
  the running server's `XDG_CONFIG_HOME` and `HERDR_SESSION`, and a server that
  is its own session leader.
- **R-9**: Inbound is closed by default: the SSH daemon listens on the loopback
  address and nothing is published until a deployment says so. No Docker socket
  is mounted, and no agent-host process is privileged.
- **R-10**: The base's run contract stays intact: started without the
  deployment's override, the image runs one agent in one workspace exactly as the
  base does, including its refusal behaviour.
- **R-11**: herdr is pinned by version and by the publisher's per-asset digest at
  build time, and the installed configuration disables its version and
  manifest checks. The host performs no update of its own.
- **R-12**: The boot is idempotent and refuses loudly: every phase is safe to
  re-run, and a bad input exits 78 with one stderr line naming the value at
  fault.
- **R-13**: The image carries no harness, no credential and no secret, and the
  host reaches the Docker API, when a deployment enables it, only through the
  pinned `restrict-docker-api-access` endpoint.
- **R-14**: A pane survives the death of its process: when the wrapper itself is
  killed, the plugin's `pane.exited` hook reopens the agent pane — recreating the
  workspace first when herdr's auto-close cascade already removed it — with a
  bounded reopen rate and the same stop-marker respect.

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

## Dependencies

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | schematic | [build-an-agent-dev-image v0.1.0](https://github.com/cameri/schematics/blob/c1183507aa245bd443ce1ac48dbba1df0b4a3d31/schematics/build-an-agent-dev-image/SCHEMATIC.md) `sha256:c2fbb0496a84e5f4986954465070aa6519dec6acbc491a040cb66d36e2851b45` | The image this layer is built from and the contract every agent pane runs under: its account, entrypoint, working directory and `AGENT_*` names are inherited by R-1 through R-3 and restated nowhere | Its acceptance script green against its published reference; this build's `FROM` names its manifest digest | The build fails at `FROM`. Declared inputs are not re-created here — a missing base is a missing prerequisite, not something this package substitutes for |
| D-2 | schematic | [restrict-docker-api-access v0.3.1](https://github.com/cameri/schematics/blob/d405389a80eb1bc3019ecabf312535d072b1559a/schematics/restrict-docker-api-access/SCHEMATIC.md) `sha256:7444bdd603df29c072a7f7ebf9b09dda23e8c211dd9dc55d76f9a36a6ee22c58` | Docker CLI access for agents without the socket: the deny-by-default API endpoint R-9 and R-13 require | Its own audit (`A-8` there) reports every endpoint group allowed and denied; the consuming deployment's `DOCKER_HOST` names its endpoint | Without it, agents get no Docker at all. Mounting the socket instead is refused by R-9, not offered as a fallback |
| D-3 | schematic | [encrypt-container-secrets v0.2.2](https://github.com/cameri/schematics/blob/da0ac2334dd997588daffd404570292d50d6dca6/schematics/encrypt-container-secrets/SCHEMATIC.md) `sha256:7b40f292571587b0c6a57460ab5611b2bb4104b1ea0cc6e6848dddea78a45d6a` | The credential path for whatever a caller's agents need: secrets encrypted at rest, decrypted in memory at boot, per-service keys. This package ships no credential (R-13) | Its phases green on the deployment, and a boot where the expected variable is present in the process environment | With no secrets configured, the host still boots and the agents run with whatever the image carries — for a harness layer that means it refuses to authenticate and says so itself |
| D-4 | schematic | [run-an-llm-router v0.1.0](https://github.com/cameri/schematics/blob/c8b6290bb32ed99f5d8fbeab3d4c984fae7f9ccb/schematics/run-an-llm-router/SCHEMATIC.md) `sha256:6f1974708cd6e2fe8d8e26cd4fe51ac11b531ebad814953e23a823c5cfe06b39` | The inference endpoint an agent uses, so the set has no metered shared provider in the path. This package only names it as the thing a harness layer points at | Its `/v1` endpoint answers from the host's network; its health gate is what a client sees | The host boots and supervises normally; the agents' inference fails, and the harness reports it. Nothing in this package retries or substitutes a provider |
| D-5 | system | Docker Engine with Compose v2 | Builds the image and runs the host container | `docker compose version` | Hard fail at Phase 2; nothing else in the package can run |
| D-6 | system | Build-time outbound HTTPS to the herdr release assets, and to the base's package repositories | Installs herdr at its pinned version and the packages the host needs | The build's own steps: the asset download and the package install | Hard fail: the build stops at the failing step. Do not substitute an unreviewed mirror for a checksum-verified asset |
| D-7 | system | The distribution's package repositories, at the version the base was built from | `openssh-server`, `openssh-client`, `jq`, `util-linux` come from there | The build's package step | Hard fail with the repository's own error; a base whose release is out of support makes this a decision, not a workaround |
| D-8 | system | An SSH client and a herdr client binary on the operator's machine | The attach step of R-8: `herdr --remote` is a client, and it runs on the machine the operator types on | `ssh -V`, `herdr --version` on that machine | Degrade: the host runs and its agents work; attach is unavailable until a client exists, and the diagnostic script reports the transport side as OK |

## Parameters

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | `AGENT_BASE_IMAGE` | string | *(none — required at build)* | The published base reference without a tag: `<registry>/<namespace>/<name>` | What the layer is built from (R-1) |
| P-2  | `AGENT_BASE_DIGEST` | string | *(none — required at build)* | `docker buildx imagetools inspect <P-1> --format '{{.Manifest.Digest}}'` — the manifest list digest, never a tag and never a per-platform digest | Pins the base bytes. Without it the build fails; that is the point |
| P-3  | `HERDR_VERSION` | string | `0.9.0` | The multiplexer's release list; pick a version whose asset digests you verified (see Applicable Context) | The herdr binary the host runs (R-11) |
| P-4  | `HERDR_SHA256_AMD64` | string (hex) | `4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f` | The release API's `digest` for `herdr-linux-x86_64` at `P-3` | The build verifies the amd64 asset against it; a mismatch stops the build |
| P-5  | `HERDR_SHA256_ARM64` | string (hex) | `9c8db20fb7e7427b138d5367113f1621ffd319f2f65d6f009e2594029115f0d2` | The release API's `digest` for `herdr-linux-aarch64` at `P-3` | As `P-4`, for arm64 |
| P-6  | `IMAGE_NAME` | string | `agent-host` | Choose once; it is the stable human-readable half of the reference | The published image name |
| P-7  | `IMAGE_VERSION` | string (semver) | `0.1.0` | This package's own version, bumped deliberately on every published change | The tag's version half |
| P-8  | `GIT_COMMIT` | string | *(from discovery — no default)* | `git rev-parse --short HEAD` at build time | The tag's identity half and the `revision` label |
| P-9  | `IMAGE_REGISTRY` | string | `ghcr.io` | The registry the implementer is authorized to push to | Where the published host image lives |
| P-10 | `IMAGE_NAMESPACE` | string | *(from discovery — no default)* | The registry account or organization that owns the artifact | The published path `<P-9>/<P-10>/<P-6>` |
| P-11 | `AGENT_IDS` | list | *(none — required at run)* | The agents this host should run; each id must match `[A-Za-z0-9._-]`, start alphanumerically, and be at most 64 characters | The workspace set, one per id, and the roster (R-2) |
| P-12 | `AGENT_TREE` | path (in-container) | `/agents` | The path the deployment mounts the tree at; keep it unless two mounts collide | Per-agent `<P-12>/<id>/workspace` and `<P-12>/<id>/home` (R-3, R-7) |
| P-13 | `AGENT_STATE_ROOT` | path (in-container) | `<P-12>/.state` | Inside the tree, so supervision state survives a recreate | Per-agent `loop.log`, `stop` and launch timestamps (R-5) |
| P-14 | `HERDR_SESSION` | string | `agents` | Any name; it is the session an attach targets and the value the SSH `SetEnv` must carry | The named herdr session the host runs and attaches to (R-8) |
| P-15 | `XDG_CONFIG_HOME` | path (in-container) | `$HOME/.config` | The config root herdr resolves from; mount it under the tree to keep the session shape across recreates | The herdr config root, written into the SSH `SetEnv` in the same boot run (R-8) |
| P-16 | `AGENT_ENTRYPOINT` | path (in-container) | `/usr/local/bin/agent-entrypoint` | The base's entrypoint; it is inherited, not chosen here | The program each agent pane runs (R-3) |
| P-17 | `AGENT_HARNESS` | string | *(unset by this layer; a harness layer sets it)* | The CLI name or absolute path the base's entrypoint resolves | What an agent actually runs. Unset, the base's entrypoint refuses with its own code and message (R-10) |
| P-18 | `AGENT_SSH_ENABLE` | 0 or 1 | `1` | Whether this host should accept remote attach at all | Starts or omits the SSH daemon (R-8) |
| P-19 | `AGENT_SSH_PORT` | integer | `2222` | A free port on the host, and the port the deployment publishes | The daemon's port and the port an attach targets |
| P-20 | `AGENT_SSH_LISTEN` | address | `127.0.0.1` | The address attach should reach: the loopback default keeps inbound closed; a routed or tunnel address makes it reachable | What the daemon binds, and therefore the default posture (R-9). Publishing a port without moving this reaches nothing — the two are one decision |
| P-21 | `AGENT_SSHD_DIR` | path (in-container) | `<P-12>/.sshd` | Inside the mounted tree, so the host identity survives a recreate; a path outside it works and throws the key away with the container | Host key, `sshd_config`, pid file (R-7, R-8) |
| P-22 | `AGENT_SSH_AUTHORIZED_KEYS` | path (in-container) | `<P-21>/authorized_keys` | The file holding the attaching client's public key(s) | Key-only authentication: an empty file rejects every connection (R-8) |
| P-23 | `AGENT_CRASH_LIMIT` | integer | `3` | How many rapid relaunches a broken agent should get before the host stops hammering | The wrapper's backoff threshold (R-5) |
| P-24 | `AGENT_CRASH_WINDOW` | seconds | `5` | The window those launches are counted in | As `P-23` |
| P-25 | `AGENT_CRASH_BACKOFF` | seconds (≥ 1) | `30` | How long a backoff should last | The sleep before the next attempt (R-5); the wrapper refuses a value below 1, because a pause of zero is a spin |
| P-26 | `AGENT_REOPEN_LIMIT` | integer | `5` | How many pane reopens the fallback hook should allow before backing off | The hook's bound (R-14) |
| P-27 | `AGENT_REOPEN_WINDOW` | seconds | `60` | The window those reopens are counted in | As `P-26` |
| P-28 | `AGENT_REOPEN_BACKOFF` | seconds | `30` | How long the hook backs off | As `P-26` |
| P-29 | `AGENT_BOOT_FOREGROUND` | 0 or 1 | `1` | Whether the boot should become the session's client or reconcile and exit | `1`: the container's process is the session. `0`: the reconciliation mode a verification run uses |
| P-30 | `AGENT_HOST_STATE` | path (on the host) | *(none — required at run)* | The host directory to mount at `P-12`; must be local and owned by the base's account id | Where every agent's workspace, home and supervision state live (R-7) |
| P-31 | `AGENT_USER` | string | *(inherited from the base image)* | The base's runtime account; the deployment names it so one place can rename it | The identity every pane runs as (R-1, R-9) |
| P-32 | `PLATFORMS` | list | `linux/amd64,linux/arm64` | `docker buildx inspect --bootstrap` — what the builder can produce | What the published manifest covers; a subset is a decision to record |
| P-33 | `BUILDER_NAME` | string | `agent-host-builder` | `docker buildx ls` — a multi-platform builder, or create one with the `docker-container` driver | The builder used for the published multi-platform build |

## Modules

- **host-image** (`modules/host-image.md`) — the build: pinned inputs, packages,
  the plugin and boot files, publishing identity, and what the layer may not
  change about the base.
- **workspace-model** (`modules/workspace-model.md`) — one agent per named herdr
  workspace: labels, the roster, the boot's reconciliation, and the pane it
  opens.
- **supervision** (`modules/supervision.md`) — crash-only relaunch, the clean-exit
  stop marker, the crash-loop bound, the fallback hook, and what the operator
  sees in each case.
- **remote-attach** (`modules/remote-attach.md`) — the key-only SSH daemon, the
  `SetEnv` parity with the server's configuration context, the session-leader
  requirement, and the diagnostic that checks all three.
- **persistence-and-mounts** (`modules/persistence-and-mounts.md`) — the agent
  tree layout, the bind-mount ownership rule, what a restart and a stop do to
  state, and host-key stability.

## Interfaces and Contracts

**The container's process.** The image's `ENTRYPOINT` is the base's, unchanged.
A deployment starts a host by naming the boot program instead:

```
entrypoint: ["/usr/local/bin/agent-host-boot"]
```

Started without that override the image behaves exactly as the base does (R-10):
the base's entrypoint runs one agent in one workspace, or refuses with its own
code and message when the environment contract is incomplete. Both entrances are
live; neither is a wrapper around the other.

**The environment contract the boot consumes** — every variable, its meaning and
its default is `skeleton/agent-host-boot.sh.schema` (shipped in `skeleton/`). The
ones an operator sets: `AGENT_IDS`, `AGENT_TREE`, `AGENT_HOST_STATE` (the
deployment's mount), `HERDR_SESSION`, `XDG_CONFIG_HOME`, `AGENT_SSH_*`,
`AGENT_CRASH_*`.

**The herdr surface this package uses.** Verified against herdr 0.9.0:

| Command | Purpose |
|---------|---------|
| `herdr server` | run the headless server; started under `setsid` so it is its own session leader |
| `herdr session list --json` | whether the named session is running; `.sessions[].running` |
| `herdr workspace create --cwd <dir> --label <id> --no-focus` | one agent's workspace; prints `.result.workspace.workspace_id` and `.result.root_pane.pane_id` |
| `herdr workspace list` | the current set, with each workspace's `label` |
| `herdr workspace close <id>` / `focus <id>` | reconciliation and attach focus |
| `herdr plugin link <path>` / `herdr plugin list` | install and check the agent plugin |
| `herdr plugin pane open --plugin <id> --entrypoint agent --workspace <id>` | open the agent pane in a workspace |
| `herdr pane close <pane id>` / `pane list --workspace <id>` | close the workspace's shell pane once the agent pane is open; read the workspace's panes |
| `herdr --session <name>` / `herdr --remote <ssh target>` | local session client; remote attach (operator side) |

**Identity, and why it comes from the workspace.** herdr injects
`HERDR_WORKSPACE_ID`, `HERDR_PANE_ID`, `HERDR_PLUGIN_ROOT`,
`HERDR_PLUGIN_STATE_DIR`, `HERDR_PLUGIN_CONFIG_DIR` and `HERDR_BIN_PATH` into
every plugin pane. It does **not** propagate a workspace's `--env` values to a
plugin pane *(observed: a pane opened with `herdr plugin pane open` sees the
plugin environment and none of the workspace's `--env` values)*. Identity
therefore travels through the label: the wrapper reads `HERDR_WORKSPACE_ID`,
finds that workspace's line in the roster, and takes the agent id, workspace
directory and home from it.

**The roster** — `<config root>/plugins/config/<plugin id>/roster.tsv`, rewritten
at every boot, tab-separated, one line per agent:

```
# workspace_id	agent_id	workspace_dir	home_dir
```

**The plugin contract** — `skeleton/herdr-plugin.toml`: one `[[panes]]` entry
whose command is the pane wrapper, and one `[[events]]` entry on `pane.exited`
whose command is the reopen hook. The hook receives
`{"event":"pane_exited","data":{"type":"pane_exited","pane_id":"<id>","workspace_id":"<id>"}}`
*(observed)*.

**Exit codes.** The boot and both scripts refuse with `78` and one stderr line
naming the value at fault — the same discipline as the base's entrypoint, under
their own prefixes (`agent-host-boot: `, `agent-loop: `, `reopen-pane: `). A
clean exit from an agent is not an error: it is the documented way to stop one.

**Ports.** The image declares none. The SSH daemon listens inside the container;
what, if anything, publishes it is the deployment's decision, and the shipped
fragment publishes nothing.

## Implementation Phases

### Phase 1: Discovery and decisions
Goal: resolve every Must discover locally item and fix every parameter before
anything is built.
Steps:
1. Resolve `P-2` (the base's manifest digest) and record it.
2. Verify `P-4`/`P-5` against the release assets of `P-3`; if either differs, stop
   and pick a version whose digests you verified.
3. Choose `P-11` (the agent ids) and create `P-30` on the host, owned by the
   base's account id (`stat -c '%u:%g'`).
4. Choose `P-19`/`P-20`: a free port, and the address attach should reach.
   Leave `P-20` at its loopback default unless attach from another machine is
   wanted now.
5. If Docker CLI access is wanted, deploy `D-2` first and note its endpoint —
   the deployment sets `DOCKER_HOST` and friends, never a socket mount.
Verify: every parameter in the table has a value or an explicit default; the base
digest resolves; `stat` on the tree matches the base's uid.

### Phase 2: The host image
Goal: one image satisfying R-1, R-11 and R-13, built from `skeleton/`.
Steps:
1. Fill `HERDR_SHA256_AMD64`/`HERDR_SHA256_ARM64` if `P-3` is not the default.
2. Build with `--build-arg AGENT_BASE_IMAGE` and `--build-arg AGENT_BASE_DIGEST`,
   for the platforms in `P-32`.
Skip if the image with this tag already exists and its build inputs are unchanged.
Verify: `docker image inspect <tag> --format '{{.Config.User}}
{{.Config.WorkingDir}} {{json .Config.Entrypoint}} {{json .Config.ExposedPorts}}'`
reports the base's account, the base's working directory, the base's entrypoint
and `null` ports; `docker run --rm <tag>` refuses with exit `78`.

### Phase 3: Boot the host
Goal: one container running herdr with one workspace per agent id.
Steps:
1. Start with `skeleton/compose.service.yaml` (or the equivalent run command):
   the agent tree mounted at `P-12`, the SSH directory mounted if its identity
   must persist, `AGENT_IDS` set, the boot program as the entrypoint.
2. Watch the boot's own lines for the workspace it created per agent, or for the
   reason it refused.
Verify: `herdr workspace list` shows exactly the ids in `AGENT_IDS` as labels.

### Phase 4: Prove the lifecycle
Goal: R-2, R-3, R-4, R-5, R-6, R-11, R-12, R-14 hold against a real herdr.
Steps:
1. Run `scripts/verify-agent-host.sh` with `IMAGE` set to the local tag and
   `USE_PACKAGE_FILES=1`, so the shipped scripts are what is tested.
2. Fix anything the script fails; it reports per-check evidence.
   Where the base image cannot be built on the verifying machine (no BuildKit,
   for instance), `STUB_ENTRYPOINT=1` stands an entrypoint in for the base's
   inside the agent tree: the host's own rows then still run end to end, while
   every row that depends on the base's contract reports `SKIP` with that reason.
   A run in that mode proves the host, not the layer over the base.
Verify: the script prints no `FAIL` line. `SKIP` lines are acceptable only with
their stated reason.

### Phase 5: Persistence and attach from elsewhere
Goal: R-7 and R-8 hold across a container recreate, and over a real network hop.
Steps:
1. Keep the agent tree mounted across a recreate (`docker rm` then start again)
   and confirm each agent's session state is still there.
2. Publish the attach port deliberately, add the operator's public key to
   `P-22`, and run `scripts/check-remote-attach.sh` inside the host.
3. From the operator's machine: `ssh <target> 'herdr session list'`, then
   `herdr --remote <target>`.
Verify: the diagnostic prints `RESULT: all OK`; the remote session list shows the
real session, and attach lands in it rather than in a fresh one.

### Phase 6: Publish and pin
Goal: a published reference other parts and deployments can pin.
Steps:
1. `docker buildx build --platform <P-32> --push -t <P-9>/<P-10>/<P-6>:<P-7>-<P-8>`.
2. Record the manifest list digest the publish reports, and the two-platform
   check that goes with it.
Verify: `docker buildx imagetools inspect <reference>` lists both platforms and
prints a top-level digest; that digest is recorded in the deployment's notes
(this is the check that cannot run without a published reference).

### Phase 7: Ongoing changes
Goal: routine changes are a runbook, not an improvisation.
Steps:
1. Change one thing: the herdr version, the package set, a script, a default.
2. Bump `P-7`, rebuild, re-run the acceptance script, republish.
Verify: the acceptance script is green at the new tag, and the published digest
differs from the previous one.

## Verification and Acceptance

One test per requirement minimum. `scripts/verify-agent-host.sh` implements every
row below that can be executed mechanically: it inspects the image, creates and
starts one container, drives a real herdr inside it, reads what that container
reports, removes it, starts a second one on the same mounted tree, and prints
`PASS`/`FAIL`/`SKIP` per row with the evidence.

The battery is also its own subject, because a run that executes nothing must not
read as a run that found nothing wrong:

- the in-container half prints one `BODY-RESULT` line as its last act, and the
  driver fails the run when that line is absent;
- the line's count must clear a floor (`EXPECTED_BODY_CHECKS`, default 30), so a
  half that ran almost nothing fails rather than contributing zero failures;
- the half's exit status must agree with its own report — a non-zero exit with no
  failures recorded is a failure, not a pass;
- `USE_PACKAGE_FILES` selects **sources only** (the boot program, the plugin, the
  config template). The package is mounted read-only and the script runs from it
  in both modes, so `USE_PACKAGE_FILES=0` cannot produce a run in which the
  verifier itself is missing; on an image that carries the packaged boot, image
  mode runs the same rows against the image's copies instead of the package's.

- **A-1** (covers R-1): `docker image inspect` reports the base's account and
  working directory, and `null` for `ExposedPorts`. expected: the base's values,
  unchanged by the layer.
- **A-2** (covers R-2, R-12): the boot program exits 0; `herdr session list
  --json` reports the session running; `herdr workspace list` labels exactly the
  ids in `AGENT_IDS`. expected: one workspace per id, labelled with the id.
- **A-3** (covers R-3): the agent process reports its `AGENT_ID`, its working
  directory and its `HOME`. expected: the agent's own workspace directory and its
  own home, under the mounted tree.
- **A-4** (covers R-4, R-14): `kill -9` the agent process. expected: it is
  running again inside the **same pane id**, and the supervision log records the
  signal death and the relaunch.
- **A-5** (covers R-4): with the agent configured to exit cleanly, kill the
  process. expected: the stop marker exists, the agent does not run again, and
  the log names the clean exit and the marker path.
- **A-6** (covers R-5, R-6): place a stop marker for one agent, then run the boot.
  expected: that agent's workspace exists with no agent pane, the boot's log says
  why, and every other agent is running.
- **A-7** (covers R-5): an agent configured to die immediately, repeatedly.
  expected: the wrapper backs off after the configured number of launches instead
  of re-launching without pause — the announced pause is the configured one, and
  the gap between the last two relaunches of the burst is at least half of it, so
  a pause configured to zero fails rather than passing on its own log line.
- **A-8** (covers R-14): `kill -9` the pane's own process (the wrapper, not the
  agent). expected: the `pane.exited` hook opens a new agent pane — in the same
  workspace, or in a recreated one with the same label when the cascade already
  closed it — and the agent runs again; the workspace ends with exactly one pane,
  the agent's, so a recreated workspace does not keep the root shell pane the
  create came with.
- **A-9** (covers R-8, R-9): inside the host, an SSH session to the daemon.
  expected: `XDG_CONFIG_HOME` and `HERDR_SESSION` are the server's own values;
  `herdr session list --json` reports the real session running; the workspace
  labels are visible; the server process is its own session leader; password
  authentication is off; the installed `sshd_config` binds the address the
  deployment asked for; the shipped boot fragment defaults that address to the
  loopback, and the shipped compose fragment publishes no port.
  Sub-rows: `scripts/check-remote-attach.sh` reports the host's attach side
  healthy, and probes **the address the installed `sshd_config` binds** — the
  same script run against a second daemon bound to this container's own
  (non-loopback) address must report that address, not the loopback, so a
  deployment that points `AGENT_SSH_LISTEN` at a routed address is not called
  broken. And a published port with no `AGENT_SSH_LISTEN` is a failure: opening
  remote attach is two edits, checked as a pair.
- **A-10** (covers R-7): remove the container, start a new one on the same
  mounted tree. expected: the files the agent left in its home are still there
  and the agent's session continues from them; the host re-establishes its
  workspace and pane; the SSH host key sits **inside the mounted tree** and
  carries the same fingerprint before and after, which is what keeps a client's
  `known_hosts` entry valid.
- **A-11** (covers R-9): the account and uid of the agent process, read from the
  process itself. expected: the account the deployment names in `EXPECTED_USER`
  (the base's, in a real deployment), and never root.
- **A-12** (covers R-10): start the image with no override (its own entrypoint,
  no `AGENT_HARNESS`). expected: the base's refusal, exit `78`, naming
  `AGENT_HARNESS`. *(Skipped when the image under test does not carry the base's
  entrypoint — the check needs the base to refuse.)*
- **A-13** (covers R-9, R-13): inspect the running container's mounts and ports.
  expected: no `docker.sock`, the agent tree bind-mounted, no published port.
- **A-14** (covers R-11): `herdr --version` and the installed `config.toml`.
  expected: the pinned version, with onboarding and both background checks
  disabled.
- **A-15** (covers R-12): run the boot a second time on a live host. expected:
  exit 0, the same number of workspaces as before, one per agent id.
- **A-16** (covers R-1, the publish step): `docker buildx imagetools inspect
  <published reference>` lists a `linux/amd64` and a `linux/arm64` manifest and
  prints a top-level digest. expected: both platforms and a list digest.
  *(Skipped without `PUBLISHED_IMAGE`: it inspects a published reference, which
  does not exist until Phase 6. An emulated build is not evidence for it.)*
- **A-17** (covers R-1, R-11): the shipped `Containerfile`, read as text. Every
  variable its post-`FROM` instructions expand — the `LABEL`s, `USER`,
  `WORKDIR`, `ENV` and the rest Docker substitutes in — must be declared **after**
  `FROM`, or carried as an `ENV` by the base image's own `Containerfile`. An
  `ARG` declared before `FROM` is out of scope after it, so a label that names one
  expands to the empty string. *(Static, because the layer cannot be built on the
  verification machine: this applies the scoping rule to the text instead of
  reading the built image's labels. That is weaker than building it, and A-17
  says so rather than implying a build happened.)*
- **A-18** (covers R-11): the `Containerfile` carries no `<sha256 …>`
  placeholder, and its default `HERDR_SHA256_AMD64`/`HERDR_SHA256_ARM64` are
  exactly the digests `P-4`/`P-5` record. expected: one pin with three fields —
  version and both digests — so the build command the file's own header
  documents runs as written. *(Static: the digests' correctness against the
  publisher's release is a build-time matter; what is checked here is that the
  shipped file and the spec do not disagree about them.)*
- **A-19** (covers R-9): the shipped compose fragment. expected: either it
  publishes nothing and leaves the daemon on the loopback address, or it does
  both halves of opening inbound — a published port with no `AGENT_SSH_LISTEN`
  fails, because that forward reaches an address nothing listens on.
- **A-20** (covers R-12): three bad inputs, each of which must stop the program
  that reads it with exit `78` and one line naming the value, and none of which
  may leave the host altered: a roster row whose home column is empty (the
  wrapper); a home directory the account cannot write (the boot, which must
  refuse before it touches the workspace set); and a `workspace list` that fails
  (the boot, which must refuse rather than read the failure as "nothing to close"
  and create a second workspace with the same label — the workspace labels are
  compared before and after).
- **A-21** (covers R-5, R-6): with the agent crash-looping, a stop marker written
  **while the wrapper sleeps out its backoff**. expected: the wrapper stops at the
  end of that sleep with no further launch, and the log names the marker as the
  reason. This is the case the marker exists for — stopping a crash loop — and a
  check made only before the loop misses it there.

### What this package does not prove

Four claims belong to this set and no test in the package settles them. They are
limits of the artifact, not gaps to be filled in later by the same script:

- **The client half of attach.** A-9 proves the server side — the daemon, the
  parity of `XDG_CONFIG_HOME` and `HERDR_SESSION`, the session leader, the real
  session visible from inside an SSH session. That `herdr --remote <target>` from
  an operator's own machine lands in that session rather than a fresh one needs a
  second host and a real network hop; Phase 5 describes the step, and a
  loopback SSH session is not it.
- **`herdr machine add`**, the multiplexer's own machine registry. It authenticates
  to a live server on its own terms, which this package neither configures nor
  documents; a deployment that wants it adds it in its own runbook, and nothing
  here depends on it.
- **The published reference.** A-16 needs an image that has been pushed with both
  platforms; until a deployment publishes one, the manifest claim rests on the
  build, not on an inspection.
- **The layer builds, and what it builds to.** Nothing here builds the image:
  A-17 and A-18 apply Dockerfile scoping and pin agreement to the shipped text
  because the verification machine has no builder, and the acceptance run
  exercises the host against an image that is not a layer over the base the
  package pins. The labels A-17 protects, the checksum that stops a drifted
  build, and the layer's own `FROM` resolving at all are therefore reasoned, not
  observed. A machine with BuildKit closes this with one `docker build` and the
  `image inspect` lines `Containerfile.schema` gives; until then this package
  says which of its claims were not run rather than letting a green run imply
  them.

## Failure Modes and Rollback

| Phase | What can fail | Detection | Recovery |
|-------|---------------|-----------|----------|
| 1 | The base digest resolves to a per-platform digest rather than a manifest list | the other platform's build fails with `no matching manifest` | re-resolve with `imagetools inspect --format '{{.Manifest.Digest}}'` |
| 1 | The tree is owned by a different uid than the base's account | the boot refuses naming the directory, or the first write fails | `chown` the host directory to the base's account id, then re-run |
| 2 | A herdr asset digest no longer matches | the build fails at the checksum line | pick a released version whose digests you verified; do not relax the check |
| 2 | `setsid`, `sshd` or `jq` missing after the package install | the build's own `command -v` checks | fix the package list, never the runtime check |
| 3 | The boot refuses on a bad id | exit 78, one line naming the id | fix `AGENT_IDS`; ids are labels, directory names and log names |
| 3 | The herdr session does not come up in 15 s | the refusal names the server log path | read that log: a port, a config root or a permission problem is in it |
| 3 | The plugin pane cannot be opened | the boot keeps the shell pane and logs why | attach and run `herdr plugin list` and `herdr plugin pane open` by hand; the shell pane is the fallback the boot preserved |
| 4 | A killed agent does not return | A-4 fails; the pane is gone or the log has no relaunch line | check that `agent-loop.sh` is the pane's process, and that the roster has a line for the workspace |
| 4 | An agent crash-loops | the backoff line appears repeatedly; the pane stays but the agent does not run | fix the agent, or stop it with the marker and start it by hand |
| 4 | A clean exit is followed by a relaunch | A-5 fails: the marker is missing | the agent exited with a status ≥ 128; a harness that reports a deliberate exit as a signal status cannot use this policy — its wrapper must translate the status |
| 5 | Attach lands in a fresh empty session | A-9's parity or session-leader checks fail | run `scripts/check-remote-attach.sh` inside the host; it names which of the three is missing |
| 5 | An agent's state is missing after a recreate | A-10 fails | the tree was not mounted, or the deployment mounted a different host directory; `docker inspect` shows what was mounted |
| 6 | The published image cannot be pulled back by a deployment | the pull fails | the tag is append-only: publish a new version rather than overwriting the old one |
| any | The host boots but an agent never appears | the workspace exists with only a shell pane | read the supervision log under `P-13`; the pane's own exit is recorded there before the fallback hook acts |
| 3–4 | A `pane_exited` event is delivered for a workspace the boot itself closed and recreated | the fallback hook acts after reconciliation: `reopen.log` names a recreated workspace, and a second wrapper can start for one agent | not silent and not unbounded: the reconciliation marker suppresses the hook while the boot works, the reopen bound (`P-26`…`P-28`) stops a loop, and every agent id ends up with exactly one pane; the acceptance script reads its agent's pid from the process's own environment, so its own kill cannot land on a wrapper |

**On the ordering of pane events.** herdr emits `pane_exited` for every pane the
boot's reconciliation closes, and an event queued while the reconciliation marker
existed can be delivered after the boot removes it — the two are not ordered. The
hook then sees a workspace whose pane is gone, one the boot has already replaced,
and may open a pane in a recreated workspace. Three things keep that from being
harmful: the marker covers the reconciliation window, the reopen bound ends a
repeat, and the end state is one pane per agent id in the workspace the roster
names. It is **not a proven defect in a live deployment**: it was seen under the
acceptance battery's own pace, where the boot, the reconcile and the injection
follow each other inside a second, and nothing there measures a duplicate agent
process. The separate defect that run did expose — a stale pid file whose pid had
been reused by a wrapper, which the check's kill path then killed — is fixed in
`scripts/verify-agent-host.sh`, which confirms the pid against the process's own
environment first. Whether the hook should instead ignore an event for a
workspace whose pane the boot closed itself is **Q-5**.

**Rollback.** Every phase is reversible in the order it was applied. Stop and
remove the host container first — that ends the agents, the server and the
daemon, and touches no state. Then remove the published tag if it must not be
used, then the local image, then the deployment's parameters. The agent tree is
the only thing holding data, and nothing in this package removes it: after a
rollback the tree is still there, and a host started against it again finds every
agent's session where it was left. Restoring a previously working version means
starting the older image tag against the same tree; nothing in the tree is
version-specific except what a harness wrote there.

## Removal

1. Stop the agents deliberately — touch `<P-13>/<id>/stop` for the agents whose
   sessions must end cleanly, and notes that doing so keeps them stopped after a
   restart — then stop the container: `docker compose down` in the deployment's
   directory.
2. Remove the container and the image: `docker rm <container>`,
   `docker image rm <P-9>/<P-10>/<P-6>:<tag>`.
3. Remove the published tag from the registry if it must not be pulled again.
4. Remove the deployment's port publish, which is the only thing that made attach
   reachable from another machine.
5. Leave the agent tree in place until the agents' work is no longer wanted. It
   holds every workspace, every home and all supervision state; deleting
   `<P-30>` is the only operation in this package that destroys agent state, and
   it should be deliberate.
6. Remove `D-2`, `D-3` and `D-4` only when nothing else in the deployment uses
   them: they are siblings, not parts of this package.
7. If the base image is no longer needed by any layer, remove it too — this
   package is the only consumer that mounts it.

Confirm clean removal: `docker ps -a` shows no container from this deployment;
the host's `ss -tlnp` shows nothing on the attach port; `docker inspect` on any
remaining container of the deployment shows no mount of `<P-30>`; and the tree
directory is either deliberately kept for its data or deliberately deleted.

## Decisions and Open Questions

Decisions:

- 2026-09-14 — **herdr, not tmux, for the multiplexer.** herdr gives a
  first-class workspace-per-agent model, which is what makes "one agent = one
  workspace named by its id" a fact rather than a convention. tmux is the
  alternative and is ubiquitous, but it has no per-agent workspace model in this
  shape, so an agent's identity would have to live in window names and a sidebar
  the operator maintains; remote attach would need rework for the same reason,
  because tmux's attach story is a socket, not a session a client resolves by
  name.
- 2026-09-14 — **Crash-only supervision, keyed on the exit status.** A killed
  agent comes back; an exited one does not. The status is the only signal
  available without harness-specific integration, and every harness exits `0` on
  a deliberate quit. The cost is that an interactive interrupt (status 130) is a
  crash and relaunches: that is the safer direction, and the stop marker is the
  deliberate way to keep an agent down.
- 2026-09-14 — **The agent tree is the only place state lives.** Workspaces,
  homes and supervision state are all under one host directory, bind-mounted. It
  makes "stop frees memory" true by construction: there is nothing in the
  container's own filesystem that anyone would miss.
- 2026-09-18 — **The image keeps the base's entrypoint; the deployment names the
  boot program.** The base's layer contract says a layer must not replace the
  entrypoint, and it is right: the run contract is what makes the parts
  composable. So the multiplexer is selected by the deployment
  (`entrypoint: ["/usr/local/bin/agent-host-boot"]`), and the image started
  without it behaves exactly as the base. The alternative — an `ENTRYPOINT` in
  the layer, or an `AGENT_HARNESS` that points at the boot program — was
  rejected: the first breaks the contract, the second would be overwritten by
  every harness layer, since `AGENT_HARNESS` is precisely what those layers set.
- 2026-09-18 — **Identity comes from the workspace label through the roster, not
  from the pane's environment.** herdr injects workspace and pane ids into a
  plugin pane but not the workspace's `--env` values *(observed)*, so a
  per-agent environment variable is not available to a pane. The roster is
  derived state, rewritten at every boot, and it is the only file that maps a
  workspace to an agent.
- 2026-09-18 — **The wrapper is the pane's process, and the hook is the
  fallback.** Keeping the wrapper as the pane process means a crash never
  reaches herdr's auto-close cascade; that path is what makes `/exit` and
  crashes distinguishable in the first place. The hook exists because the wrapper
  cannot survive being killed itself, and because the cascade then needs the
  workspace recreated.
- 2026-09-18 — **A reconciliation marker suppresses the hook during the boot.**
  The boot closes and recreates each agent's workspace, and every close fires the
  hook. Without the marker, the hook races the boot and the agent ends up with
  two workspaces. The marker is a file, not a lock: it is written before the loop
  and removed before the host attaches, and on every exit path.
- 2026-09-18 — **A stop survives a restart.** The stop marker lives in the tree,
  not in the container's `/tmp`. A deliberate stop that a restart undid would be
  a stop an operator cannot rely on; the documented way back is to remove the
  marker, and the marker's path is logged at every boot and every clean exit.
- 2026-09-18 — **The SSH daemon listens on the loopback address by default.**
  The isolation contract of the set is outbound yes, inbound no. Keeping the
  default address at loopback and shipping no port publish means the default
  deployment is genuinely closed, and making attach reachable is one deliberate,
  visible edit.
- 2026-09-18 — **herdr is pinned by release-asset digest, and its own update and
  version checks are off.** A host that can silently become a different binary is
  not a host a deployment can pin. The checks are the only background network
  calls herdr makes by default, so disabling them also means the host fetches
  nothing on its own.
- 2026-09-18 — **The acceptance script runs the package's own files by default**
  (`USE_PACKAGE_FILES=1`). A verification that tested a copy baked into an image
  would pass while the shipped script was wrong; the mode is a parameter because
  verifying a *published* image is a different question, answered by setting it
  to `0`.
- 2026-09-18 — **The acceptance script creates and starts containers instead of
  using `docker run`.** Attaching is not needed to run a container, and a client
  can be allowed to create and start while being denied attach — the host this
  package was verified on is one. `docker create` + `start` + `logs` + `rm` works
  in both worlds.

Open questions:

- **Q-1**: Should the boot keep the workspace's shell pane instead of closing it
  once the agent pane is open? Default: close it, as the reference does — an
  attack surface and a second terminal that can write to the agent's workspace
  are worse than a slightly emptier first view. A deployment that wants a shell
  can open one with `herdr pane split`.
- **Q-2**: Should a stopped agent's workspace be removed instead of left with a
  shell pane? Default: leave it. An operator attaching after a stop is better
  served by a shell in the agent's own workspace — where the marker can be
  removed — than by a workspace that is not there.
- **Q-3**: Should the roster be herdr-independent, so a deployment could run the
  same supervision under tmux? Default: no. The roster exists because herdr
  injects a workspace id and a label is the natural identity; a tmux port would
  need its own identity mechanism, and inventing one now would be designing for a
  case nobody has asked for.
- **Q-4**: How many agents should one host run? Default: as many as the host's
  memory allows, with the deployment's own limits applied
  (`mem_limit`, `pids_limit`). The package sets none: a host with two agents and
  a host with twenty differ by one parameter, and a default limit would be a
  guess presented as a recommendation.
- **Q-5**: Should the fallback hook ignore a `pane_exited` event for a workspace
  whose pane the boot itself closed? Default: no — see *On the ordering of pane
  events* under Failure Modes. The event stream is not ordered against the boot's
  own closes, so an event queued during reconciliation can arrive after the
  marker is removed and make the hook act on a workspace the boot already
  replaced. Ignoring those events needs the boot to record the workspaces it
  closed and the hook to drop exactly those, which trades a bounded oddity for a
  durable list that must itself be reconciled; a deployment that sees duplicate
  pane opens across boots is the evidence that would settle it.
