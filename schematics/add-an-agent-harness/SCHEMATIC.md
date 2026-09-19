---
name: add-an-agent-harness
version: 0.2.0
status: draft
spec: 1
description: "An agent harness layer — the agent-host image plus exactly one coding-agent CLI and its configuration, wired to a local LLM router by model alias: the CLI becomes the container's process through the inherited entrypoint, its model ids come from the router's alias set with the context window and output limit the router does not report declared beside them, its version is resolved at build time and recorded in the image, and no credential exists anywhere in the image."
created: 2026-09-18
updated: 2026-09-19
---

# Schematic: Add an Agent Harness Layer

> **Reverse-engineered from a working set, then generalized.** This package is the
> third part of a set whose first two parts are already authored: the dev base
> image and the multiplexed agent host. Its shape is taken from a private
> implementation that runs coding agents in containers, generalized so nothing
> instance-specific survives. Claims marked `inferred:` were reasoned rather than
> observed; the acceptance table states which rows were run and under what.

Adds exactly one coding-agent CLI to an agent-host image, with that CLI's
configuration, so an agent pane can run it. It is the layer the multiplexer's
`P-17 AGENT_HARNESS` exists for: the multiplexer runs whatever the base's
entrypoint resolves from that variable and deliberately ships no harness, and
the base's entrypoint refuses when the variable names nothing.

## Applicable Context

**Must discover locally:**
- The agent-host image reference this layer is built on. Discovery: the deployment
  builds it from `run-multiplexed-agent-workspaces` (whose `D-1` carries the dev
  base image edge), or pulls a published tag of it. Either way it is one complete
  reference — `name:tag` for an image built locally, `name@sha256:<manifest list
  digest>` for a published one (`P-2`).
- The router's base URL and its alias set (`P-3`, `P-5`, `P-6`). Discovery: the
  router deployment's own configuration — `run-an-llm-router`'s `P-13` for the
  URL and its `P-10 ALIAS_SET` for the aliases. A client may only send aliases
  that set contains.
- The context window and maximum output tokens the aliases resolve to
  (`P-7`, `P-8`). Discovery: the operator's own knowledge of the models behind
  the aliases — the router's registry does not report them, which is why they are
  declared here (`modules/router-wiring.md`).
- The CLI version installed. Discovery: the package registry at build time —
  `npm view <package> version`. The build resolves it and records what it
  resolved; nothing in this package copies a version from documentation.

**May assume** (with the risk if wrong):
- The distribution's package repository is reachable at build time for the Node.js
  runtime when the base image lacks it. If it is not, the build stops at the
  install step; the fix is a base image that carries `node` and `npm`.
- The router serves the wire protocol the CLI speaks. Codex CLI speaks the
  Responses API only (`model_providers.<id>.wire_api = "responses"`), so a router
  that serves chat completions alone will accept the configuration and fail at
  the first request. Claude Code speaks the Anthropic Messages API.
- The harness account can write its configuration home. The base's account owns
  `HOME`, and the image writes the default configuration under it; a deployment
  that bind-mounts that home from the host must hand it to the same uid the base
  uses, or the CLI cannot write session state.

**Must not change** (inherited; restating any of them is how a layer drifts):
- The base's runtime account, its uid/gid, its home, its lack of extra groups and
  its lack of sudo.
- The base's entrypoint program, its `AGENT_*` variable names, its default
  workspace path, its `78` refusal code and its `agent-entrypoint: ` message
  prefix.
- The image's platform set: whatever the base publishes, this layer inherits.
- The absence of a listener — the host reaches nothing inbound, and the harness
  talks outbound only.

## Scope

**In scope:**
- One harness CLI installed into the image, at a version resolved at build time.
- That CLI's configuration, written in the CLI's own file shape, pointing at the
  router by alias.
- The `AGENT_HARNESS` value that makes the base's entrypoint exec the CLI.
- The harness parameter as a closed set of real implementations, with the
  procedure for adding one.
- An acceptance script that builds this layer on top of an agent-host image and
  asserts the behaviours above mechanically.

**Out of scope / non-goals:**
- **The base image and the multiplexer.** `run-multiplexed-agent-workspaces` is a
  pinned dependency; this package adds no herdr, no supervision, no SSH.
- **The inference endpoint.** `run-an-llm-router` is the endpoint a harness
  points at (`modules/router-wiring.md`); this package neither runs nor configures
  a router.
- **Credentials.** A credential arrives as an environment variable decrypted at
  boot by `encrypt-container-secrets`; nothing in this package holds one, and no
  credential-shaped file exists in the image it produces
  (`modules/credentials.md`).
- **omp, OpenCode and Cursor CLI.** Named non-goals of this version. Adding one is
  a mechanical procedure with a defined seam, not a stub (`modules/extension-path.md`).
- **A harness's own behaviour.** What the CLI does in the workspace, which model
  roles it uses, how it stores session state — its business, not this package's.
- **Publishing.** The tag and registry a deployment publishes to are the
  deployment's; this package names none.

## Requirements

- **R-1**: The layer MUST inherit the base's runtime contract unchanged — account,
  uid/gid, home, entrypoint program, `AGENT_*` names, default workspace, the `78`
  refusal code and the `agent-entrypoint: ` message prefix — and MUST NOT restate
  any of them in its own files. It declares no `USER` of its own beyond returning
  to the base's account after its install steps, and no `WORKDIR`.
- **R-2**: The layer MUST add exactly one coding-agent CLI, that CLI's
  configuration, and the binaries the boot path the deployment starts it with
  needs — today `sops`, which the composition's entrypoint wrapper execs to
  decrypt the credential, and which no other package in the chain installs. It
  adds no service, no daemon, no listener, no second CLI, and no other package.
  "Needed" is judged against the boot path as deployed, not against the CLI
  alone: a binary the wrapper execs is as necessary as the CLI it wraps, and its
  absence is invisible to every row that only starts the harness.
- **R-3**: The layer MUST set `AGENT_HARNESS` to the CLI name, so the base's
  entrypoint resolves it from `PATH` and `exec`s it. The layer MUST NOT declare an
  `ENTRYPOINT` or a `CMD`: the harness becomes PID 1 through the inherited
  entrypoint, with the workspace as its working directory and the container's
  arguments and exit status passed through.
- **R-4**: The harness MUST be a closed parameter. An unknown value MUST stop the
  build with one line naming the value, and the value MUST NOT be able to produce
  an image that starts without a harness. The accepted values MUST each have a
  real implementation, not a placeholder branch.
- **R-5**: The CLI version MUST be resolved from the package registry at build
  time — never a floating tag, never a version copied from documentation — and the
  version the build resolved MUST be recorded inside the image and readable
  without starting the CLI.
- **R-6**: The CLI MUST be wired to the router: the base URL, the name of the
  environment variable that carries the credential, and model ids drawn from the
  router's alias set, expressed in the CLI's own configuration shape. The context
  window and maximum output tokens MUST be declared per harness where the CLI
  supports declaring them, and the absence of a field MUST be stated rather than
  faked (`modules/router-wiring.md`).
- **R-7**: For every model role the router serves, the configuration MUST name
  only an alias on that router. It MUST NOT contain a second provider, a fallback
  provider, or another provider's endpoint for those roles: wiring a harness to
  the router removes configuration.
- **R-8**: The image MUST contain no credential and no credential-shaped file. The
  credential reaches the CLI as an environment variable, decrypted at boot by the
  deployment, and the maintenance procedure for a harness that persists a login
  MUST be stated (`modules/credentials.md`).
- **R-9**: The layer MUST inherit the base's platform set. Its install step MUST
  work on every platform the base publishes, and the acceptance table MUST state
  which platform it was measured on rather than claiming the set.
- **R-10**: The layer MUST NOT open a listener and MUST NOT run a daemon. The
  harness is a foreground process in an outbound-only container.
- **R-11**: Adding another harness MUST be a documented, mechanical procedure:
  the parameter gains a value, the install step gains an arm, the configuration
  gains a template, and the acceptance table gains a row — with the file names
  and the row named in `modules/extension-path.md`.

## Design Principles Binding the Implementation

1. **Vendor-agnostic** — implement with plain, portable components; no dependency
   on any specific agent or harness. The package names two CLIs because a harness
   layer must name one; nothing else in it assumes either.
2. **Portable** — no absolute paths or machine-specific values in the
   implementation; use the Parameters below. No registry, namespace or hostname
   of the author's appears anywhere: an image reference is a parameter, and so is
   the router's URL.
3. **Self-contained** — the implementation needs nothing outside this package
   except the dependencies named below and the base image it is built on.
4. **Idempotent** — every phase is safe to re-run; a rebuild produces an image
   that behaves the same, and re-running the acceptance script gives the same
   verdict.
5. **Parameterized** — every environment-specific value is a named parameter with
   a discovery method. The harness id, the base reference, the router URL, the
   alias ids and the token metadata are parameters; nothing else varies.
6. **Self-describing files** — the configuration templates ship with `.schema`
   companions, because a reader who does not know the CLI cannot tell a correct
   `settings.json` from a plausible one.
7. **Least privilege** — the install uses root inside a build layer; the produced
   image has the base's unprivileged account as its runtime identity, with no
   added group and no sudo. The CLI runs as that account.
8. **Do one thing** — the layer adds a harness. It does not supervise it (the
   multiplexer does), does not route its traffic (the router does), and does not
   hold its secret (the deployment does).
9. **Fail loudly** — an unknown harness id stops the build with a line naming it;
   the base's refusals keep their own code and message; a missing router alias
   fails at the client, not silently somewhere else.
10. **Evidence over assertion** — every requirement is mapped to a row in the
    acceptance table, and the row states what was measured and on what.

## Dependencies

| Id   | Kind      | What | Why needed | Discovery | Failure behaviour |
|------|-----------|------|------------|-----------|-------------------|
| D-1  | schematic | [run-multiplexed-agent-workspaces v0.2.1](https://github.com/cameri/schematics/blob/7dafa31ae8457969563acac703786ac42fb26654/schematics/run-multiplexed-agent-workspaces/SCHEMATIC.md) `sha256:8fed59d6c800a52c3cf8f86bee377f95b6398e4d83d5711f852e48e8e70451a6` | The image this layer is built on, and the contract an agent pane runs under: its account, entrypoint, working directory and `AGENT_*` names are inherited by R-1 and restated nowhere. That package's `P-17 AGENT_HARNESS` is exactly the parameter this layer sets, and its `D-1` carries the dev base image edge | Its acceptance script green, then this layer's acceptance script green against an image built from it | The layer cannot be built: there is no image to derive from. Nothing in this package substitutes for it |
| D-2  | schematic | [run-an-llm-router v0.2.1](https://github.com/cameri/schematics/blob/545ec07f94d3c14a0bdaaf40a87d33f5c684d875/schematics/run-an-llm-router/SCHEMATIC.md) `sha256:095db6143e4b0a3594360a522e232d23a37c10d932d42c8d875a5e455a624e9c` | The inference endpoint the harness is wired to, by alias (R-6, R-7). Its own client-wiring document defines the wire contract this package's templates implement, and its `P-10 ALIAS_SET` is the only set of model ids a client may send | The protocol **this deployment's arm needs** answers on its endpoint within the container's network — `POST /v1/messages` for the Claude arm, `POST /v1/responses` for the Codex arm — and its `P-10 ALIAS_SET` is readable from its configuration and contains `P-5` and `P-6`. A reachable `/v1` alone is not enough: a router that serves chat completions only accepts this wiring and fails at the arm's first request, which is the failure this row exists to catch | The harness starts and every request fails at the client. That is the intended failure: R-7 forbids a fallback provider, so a router outage is visible rather than absorbed |
| D-3  | schematic | [encrypt-container-secrets v0.2.2](https://github.com/cameri/schematics/blob/da0ac2334dd997588daffd404570292d50d6dca6/schematics/encrypt-container-secrets/SCHEMATIC.md) `sha256:7b40f292571587b0c6a57460ab5611b2bb4104b1ea0cc6e6848dddea78a45d6a` | The credential path: the harness's credential is encrypted at rest and decrypted in memory at boot, exposed to the process as an environment variable. This package ships no credential (R-8) | Its phases green on the deployment, and a boot in which the credential variable is present in the harness's environment | The harness starts with no credential and fails its first request with the provider's own error; the CLI names the missing variable |
| D-4  | system    | Docker Engine with Compose v2, and a builder that can build from the base image | Builds this layer's image and runs it for the acceptance rows | `docker compose version` exits 0; the base image is present locally or pullable | Hard fail at Phase 2: no image, no rows |
| D-5  | system    | Network access to the package registry at build time | Resolves and installs the CLI version (R-5) | The install step's own output: `npm view <package> version` | Hard fail at the install step, naming the package it could not resolve. Do not substitute a mirror or a vendored copy of the CLI |
| D-6  | system    | The distribution's package repository, when the base image carries no Node.js runtime | Installs `nodejs` and `npm` for a CLI that is distributed through npm | `command -v node` inside the base image | Hard fail at the runtime install step; the fix is a base image that carries the runtime, not a different CLI |

## Parameters

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | `AGENT_HARNESS_ID` | enum: `claude` \| `codex` | *(required at build)* | The CLI this deployment's agents run. Each value is a real implementation; omp, OpenCode and Cursor CLI are non-goals with a documented extension procedure | Selects the CLI installed, the configuration template used, and the value of `AGENT_HARNESS` (R-2, R-4) |
| P-2  | `AGENT_BASE_REF` | string | *(required at build)* | The agent-host image: `name:tag` when it was built locally, `name@sha256:<manifest list digest>` when it was published. Discovery: the deployment's own build or pull step | The `FROM` reference of this layer, and therefore the whole inherited contract (R-1) |
| P-3  | `ROUTER_BASE_URL` | URL | `http://llm-router:4000` | `run-an-llm-router`'s `P-13`, whose default is built from its `P-1 ROUTER_SERVICE_NAME` and `P-2 ROUTER_PORT`. This parameter is the router's **root**, with no path suffix: each CLI appends its own protocol path (`/v1/messages` for Claude Code, `/v1/responses` for Codex CLI), so the build derives the endpoint per arm and writes that into the configuration (`modules/router-wiring.md`). A value ending in `/v1` is refused at build time, because the Claude arm would then request `/v1/v1/messages` | The endpoint the harness sends inference requests to (R-6) |
| P-4  | `ROUTER_CREDENTIAL_ENV` | string | `ROUTER_API_KEY` | The name of the environment variable the deployment injects the router credential into. The *name* is configuration; the value comes from `encrypt-container-secrets` (D-3) | The variable name the configuration reads the credential from. No value is ever written to a file (R-6, R-8). **It has no effect for the `claude` harness**: that CLI reads its bearer token from `ANTHROPIC_AUTH_TOKEN` — a fixed name, because that variable is the one that sets the `Authorization: Bearer` header the router reads — so the install arm uses that name regardless of this parameter, and the deployment's secret store must carry the credential under it. The layer records which variable the harness it installed actually reads at `/usr/local/share/agent-harness/credential-env`; for the `codex` harness the value is this parameter |
| P-5  | `HARNESS_MODEL_ALIAS` | string | *(required at build)* | An alias from the router's `P-10 ALIAS_SET` — what the router is configured to serve to this deployment | The model id the harness sends for its primary role. A value the router does not serve fails per request at the client (R-6, R-7) |
| P-6  | `HARNESS_FAST_ALIAS` | string | *(required at build)* | A second alias from the same set, for the CLI's background/small-task role where the CLI has one | The model id the harness sends for background work. Required rather than optional: an unset small/fast role leaves the CLI pointing at a built-in model name the router probably does not serve, and the failure is a request that never reaches the router. Where the harness has no such role — the `codex` arm — the parameter is unused and no key is written |
| P-7  | `HARNESS_CONTEXT_WINDOW` | integer | *(required at build)* | The context window, in tokens, of the model `P-5` resolves to. The router does not report it, so the operator declares it | Written into the CLI's configuration in the field that CLI uses, so its compaction heuristics match the real window |
| P-8  | `HARNESS_MAX_OUTPUT_TOKENS` | integer | *(required at build)* | The maximum output tokens of the model `P-5` resolves to, where the operator's provider documents one | Written where the CLI supports it. The `codex` arm has no such key, so the parameter is unused there and the module says so rather than writing a plausible field the CLI would ignore |
| P-9  | `HARNESS_HOME` | path (in-container) | the base account's home plus `.<cli>` — built as `/home/${AGENT_USER}/.<cli>` from the account the base declares | The directory the CLI keeps its configuration and session state in. The CLI's own relocation variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) is set to this value. The default is composed in the Containerfile from the base's own `AGENT_USER`, because `HOME` is not in the base image's `Config.Env`; a base whose account lives outside `/home` passes this parameter, and the build says so | Where the CLI reads its configuration, and what a deployment bind-mounts to keep session state across recreates. **One root per image, shared by every pane a deployment runs from it** (see "The configuration root is per image") |
| P-11 | `HARNESS_VERIFY_ENDPOINT` | flag (empty \| `1`) | *(empty — no check)* | The deployment's choice: set it when the build runs where the router is reachable, and a build that cannot reach the endpoint this arm is wired to stops with a line naming it (exit `78`). Empty by default because a build may run where the router is not reachable — a CI runner, a laptop. **It checks reachability only**: no credential is sent, because a credential must never be a build argument (it would land in the image's history), so it cannot prove the alias is served. That check is the deployment's, before the panes start | A build that would produce an image wired to an endpoint nobody can reach fails at the build instead of at the harness's first request |
| P-10 | `HARNESS_PACKAGE_VERSION` | string | *(empty — resolved at build)* | The exact version to install. Empty resolves it from the registry at build time (`npm view <package> version`); set it to reproduce an earlier build | Pins the CLI version. The resolved value is recorded in the image either way (R-5) |

## Modules

- **Harness CLI** (`modules/harness-cli.md`) — what the layer installs, how the
  version is resolved, how the closed parameter works, how `AGENT_HARNESS` reaches
  PID 1 through the inherited entrypoint, and what the install step must not do.
- **Router Wiring** (`modules/router-wiring.md`) — the wire contract in the
  router's `client-wiring.md` expressed in each CLI's own configuration shape,
  including the token-limit and context-window metadata each CLI can and cannot
  declare.
- **Credentials** (`modules/credentials.md`) — where a harness keeps its
  credential home, how the credential reaches the process, why the image holds
  none, and the maintenance procedure for a CLI that persists a login.
- **Extension Path** (`modules/extension-path.md`) — the mechanical procedure for
  adding another harness, file by file and row by row.

## Interfaces and Contracts

### The image this layer consumes

The layer inherits, and does not restate, everything below. It is the contract of
`build-an-agent-dev-image` as carried by `run-multiplexed-agent-workspaces` (D-1);
the wording belongs to those packages.

| Consumed | Value | Consequence for this layer |
|---|---|---|
| Runtime account | the base's unprivileged account, uid/gid 1000, home under `/home` | The install runs as root and returns to `${AGENT_USER}`; the CLI runs as that account |
| Entrypoint | the base's entrypoint program, `exec`-form, at its fixed path | The layer must not declare an `ENTRYPOINT` or `CMD` |
| `AGENT_HARNESS` | the name or absolute path the entrypoint resolves and `exec`s | This layer sets it (R-3) |
| `AGENT_WORKSPACE_DIR` | the base's default workspace, `/workspace` | The harness's working directory; the layer must not change it |
| `AGENT_ID` | defaults to the container's hostname | Not set by this layer; the multiplexer sets it per agent |
| Refusals | exit `78`, one stderr line prefixed `agent-entrypoint: ` | The base's refusals must still fire unchanged in an image built from this layer, including the one for an unset `AGENT_HARNESS` |
| Platform set | whatever the base publishes | Inherited; the install step must not assume one architecture |

### The image this layer produces

| Produces | Value |
|---|---|
| The base's contract | unchanged, verified by the acceptance table rather than asserted |
| The harness CLI | installed at the version the build resolved, on `PATH`, runnable by the base's account without a credential |
| `AGENT_HARNESS` | the CLI's name (`claude`, `codex`), so the entrypoint resolves it |
| The CLI's configuration | in the CLI's own file shape, under `P-9`, naming the router (`P-3`) by alias (`P-5`) and the credential *variable* (`P-4`) |
| The resolved version | recorded in a file inside the image (R-5) |
| A credential | none (R-8) |

### The harness → router contract

Four facts, in the CLI's own shape: the base URL (`P-3`), the credential
variable's name (`P-4`, presented as a bearer token), the model alias (`P-5`),
and the model metadata the CLI can accept (`P-7`, `P-8`). The wire contract
itself — what a client must be told, and how it proves it is using the router —
belongs to the router package's `client-wiring.md` (D-2).

### The configuration root is per image, and every pane shares it

`P-9 HARNESS_HOME` is written into the image (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`),
and the deployment cannot vary it per pane: the multiplexer runs each agent with
its own home under the tree, but `herdr` does not pass a workspace's `--env` values
into a plugin pane — that package's own measured constraint. So every agent a
deployment starts from one image reads the same configuration and writes its
session state to the same directory, which is also the single path Q-1's optional
volume mounts. Two consequences, stated rather than discovered later:

- **What is shared:** the configuration file, the CLI's session state, and any
  login the maintenance path in `modules/credentials.md` leaves behind. Two panes
  of the same image are two sessions over one store.
- **What this layer cannot do about it:** per-agent configuration or per-agent
  session state needs the root to be resolved at boot, per pane. That is a
  property of the base's boot path, and this layer does not own it (R-1, R-3).

The alternative — stop pinning the root and let each CLI use `$HOME/.<cli>`, so a
per-agent home would naturally carry per-agent state — needs a boot hook in the
base image that sets the variable per pane before the harness starts. The base
offers no such hook, and adding one means replacing the entrypoint (R-1). Recorded
as the option that is out of reach, not as a thing that was overlooked.

## Implementation Phases

Run all phases from a host with the base image available (D-4).

### Phase 1: Read the base's contract
Goal: know what is inherited before adding to it.

Steps:
1. Read the agent-host image's `SCHEMATIC.md` (D-1) and the base image package it
   depends on: the account, the entrypoint, the `AGENT_*` names, the refusals,
   the default workspace.
2. Read the router package's `client-wiring.md` (D-2) and note the alias set.
3. Write down the two values that are not in either package: the context window
   and maximum output tokens of the model `P-5` resolves to.

Verify: `docker image inspect <P-2>` shows the account and the entrypoint the
contract names; if it does not, `P-2` names the wrong image.

### Phase 2: Build the layer
Goal: an image that adds one CLI to the base and nothing else.

Steps:
1. Fill the parameters: `P-1` the harness, `P-2` the base reference, `P-3` the
   router URL, `P-5` the alias, `P-7` the window.
2. Build with the shipped `skeleton/Containerfile`:

   ```
   docker build -f Containerfile \
     --build-arg AGENT_HARNESS_ID=<P-1> \
     --build-arg AGENT_BASE_REF=<P-2> \
     --build-arg ROUTER_BASE_URL=<P-3> \
     --build-arg ROUTER_CREDENTIAL_ENV=<P-4> \
     --build-arg HARNESS_MODEL_ALIAS=<P-5> \
     --build-arg HARNESS_FAST_ALIAS=<P-6> \
     --build-arg HARNESS_CONTEXT_WINDOW=<P-7> \
     --build-arg HARNESS_MAX_OUTPUT_TOKENS=<P-8> \
     --build-arg HARNESS_HOME=<P-9> \
     -t <name>:<version> .
   ```

   The command above is the full set a Claude build needs, and it works as
   written for either arm: `HARNESS_FAST_ALIAS` (`P-6`) and
   `HARNESS_MAX_OUTPUT_TOKENS` (`P-8`) are the Claude arm's own roles, and the
   Codex arm ignores them while requiring `ROUTER_CREDENTIAL_ENV` (`P-4`) to name
   the variable its provider block reads. The build refuses an arm's own missing
   argument with one line naming it (R-4's refusal code, `78`), and an empty one
   the same way. `ROUTER_BASE_URL`, `ROUTER_CREDENTIAL_ENV` and `HARNESS_HOME`
   carry the defaults the parameter table lists; `HARNESS_MODEL_ALIAS`,
   `HARNESS_FAST_ALIAS`, `HARNESS_CONTEXT_WINDOW` and `HARNESS_MAX_OUTPUT_TOKENS`
   have none, so an omitted one stops the build rather than producing a
   configuration with an empty model id.
3. The build's last lines name the CLI version it resolved.

Verify: the build exits 0, and `docker image inspect` shows the base's account as
the image's `User` and no `Entrypoint` of this layer's (R-1, R-2).

Skip conditions: re-running rebuilds idempotently; an unchanged parameter set
produces an image that behaves identically.

### Phase 3: Wire the harness to the router
Goal: R-6 and R-7 — the CLI points at the router, by alias, and nowhere else.

Steps:
1. Confirm the alias `P-5` is in the router's `P-10 ALIAS_SET`.
2. Confirm the deployment injects `P-4` from `encrypt-container-secrets` (D-3).
3. Start the image with the credential variable present and run the CLI's version
   command and then one request through the harness's headless mode.

Verify: the version command exits 0 (the CLI is installed and runnable without a
credential), and the headless request returns a completion routed through the
router — visible in the router's own log, which names the alias it served.

### Phase 4: Prove it
Goal: every requirement asserted by a row that can fail.

Steps:
1. Run `scripts/verify-harness-layer.sh` with the parameters of the deployment.
   The script builds the layer on top of a base image, runs it, and prints one
   row per requirement.
2. Read the rows: every `PASS` is a measured decision, every `SKIP` prints why.

Verify: the summary line reports zero failures, and each row's text names what it
measured.

## Verification and Acceptance

Every row is printed by `scripts/verify-harness-layer.sh`. The script takes the
base image as a parameter; rows that need a real base image built from the base
package skip with their reason when only a stand-in is available, and the summary
says so. Rows are measured, not asserted: a `PASS` means the check ran against a
real container built from this layer.

The script has **two invocation modes, and they do not cover the same rows.**
With `IMAGE` supplied it verifies that image and never builds, so the
build-dependent rows do not run: `H-16` (the build refuses an endpoint nothing
answers at) is skipped entirely and `H-7` skips its build-log half, reporting the
version recorded in the image on its own. `IMAGE` is therefore the mode for
checking a layer that is already published, and **leaving `IMAGE` unset is the
mode that gives the full row set** — it is also the only one that proves this
layer builds at all, which is why a report of the two modes' totals (for example
`35/0/2` with `IMAGE` against `36/0/1` without) is a difference in coverage, not
in the layer. One thing neither mode proves by any row is `sops`: the binary is
proved by the build's own `sops --version` line in `skeleton/Containerfile`,
which runs as part of every build and stops it when the binary is absent — no
row reads that line.

- **H-1** (covers R-1): inspect the built image. expected: `Config.User` is the
  base's account, `Config.WorkingDir` is the base's workspace, and the image
  declares no `ENTRYPOINT` or `CMD` of its own — the values are the base's.
- **H-2** (covers R-1): start the image with `AGENT_HARNESS` unset and no command
  override. expected: the base's refusal — exit `78` and one stderr line prefixed
  `agent-entrypoint: ` naming `AGENT_HARNESS`. This is the row that proves the
  entrypoint was inherited rather than replaced.
- **H-3** (covers R-2, R-3): start the image normally. expected:
  `AGENT_HARNESS` is set, `command -v` resolves it inside the container, and the
  process the container runs is that harness (PID 1 through the entrypoint).
  What the image's `Config.Env` says is a separate row, H-14: an image built with
  a wrong `AGENT_HARNESS` value is invisible to every other row.
- **H-4** (covers R-2): run the CLI's version command. expected: exit 0 and a
  version string — the CLI is installed, on `PATH`, runnable by the base's
  account, and needs no credential to report its version.
- **H-5** (covers R-3): run the image with a stub in place of the harness, through
  the documented `AGENT_HARNESS` parameter, and record what PID 1 is, what its
  working directory is, and what exit status the container reports when the stub
  exits non-zero. expected: PID 1 is the harness, the working directory is the
  base's workspace, and the exit status is the stub's own. The driver *asks* for a
  non-zero status (the body takes the value from `BODY_EXIT`, and the run sets it
  to 7) and requires the container to report exactly that, so the row measures
  propagation instead of asserting 0. *(The stub stands in for a CLI that would
  otherwise need a credential to stay alive; the real CLI is covered by H-4.)*
- **H-6** (covers R-4): build with an unknown `AGENT_HARNESS_ID`. expected: the
  build fails, its output names the value it rejected, and no image is produced.
- **H-7** (covers R-5): read the recorded version from inside the image. expected:
  a file naming the exact version installed, and that version equal to the one the
  build log resolved.
- **H-8** (covers R-6): read the CLI's configuration inside the image. expected:
  it parses in the CLI's own format; it names `P-3` as the endpoint and `P-5` as
  the model for every role the configuration sets; and it carries the credential
  *variable* the harness it installed actually reads — `P-4` for the `codex`
  arm, whose provider block names it as `env_key`, and for the `claude` arm a file
  that names no credential at all, because that CLI reads `ANTHROPIC_AUTH_TOKEN`
  from the environment. Which name applies is recorded in the image at
  `/usr/local/share/agent-harness/credential-env`, and the row reads it there
  rather than assuming one harness's answer for both. The row **compares values**,
  not substrings: the endpoint in the file against the one this arm derives from
  `P-3` (the root for `claude`, the root plus `/v1` for `codex`), the model against
  `P-5`, and — where the file names it — `env_key` against the recorded variable.
  A substring search passes a doubled `/v1` path and an alias that only looks
  right; the comparison does not.
- **H-9** (covers R-7): the same file read as text. expected: no provider endpoint
  other than `P-3` appears, and no second provider block exists. A configuration
  that could fall back to another provider fails this row.
- **H-10** (covers R-8): search the image's filesystem for credential-shaped
  files — the CLI's own stored credentials, keys, tokens, and dotenv files — in
  the harness home and the account's home. expected: none exists. The same search
  covers the configuration: the credential *name* may appear, a credential *value*
  may not.
- **H-11** (covers R-6): the same configuration, checked against the metadata the
  router does not report. expected: the context window is declared where the CLI
  can declare it, and the module's statement about the field the CLI lacks matches
  the file.
- **H-12** (covers R-9): inspect the image. expected: the image's platform is
  the base's — reported as the platform that was actually built, not as a claim
  about the set. *(The listener half of R-10 is H-15, which reads a container
  rather than this file's text.)*
- **H-14** (covers R-2, R-3): read the image's `Config.Env`. expected:
  `AGENT_HARNESS` is the CLI's name (`P-1`) and the CLI's config-root variable
  (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`, whichever this arm reads) is `P-9`. An
  image whose `ENV` line names the wrong harness or the wrong root passes every
  other row and fails in the pane.
- **H-15** (covers R-10): inspect a container of this image, and the process
  inside it. expected: nothing published (no port bindings, no bound ports) and no
  listening socket in the container's network namespace (read from
  `/proc/net/tcp`, `/proc/net/tcp6`).
- **H-16** (covers `P-11`): build with `HARNESS_VERIFY_ENDPOINT=1` pointed at an
  endpoint that answers nothing. expected: the build fails and its output names
  the parameter and the endpoint. The same flag pointed at an endpoint that
  answers produces an image. *(This is the row for the check `P-11` turns on; the
  composition's own probe uses it to prove the build refuses an unreachable
  router.)*
- **H-13** (covers R-2): read the shipped `Containerfile` as text. expected: the
  install step uses no pipe-to-shell (`curl … | sh`), and every downloaded or
  installed artifact is version-resolved (R-5) rather than fetched from a floating
  tag.

**What this package does not prove.** No row proves that the router *serves* the
aliases this image was built with: `P-11`'s check is reachability, because a
credential cannot be a build argument (it would land in the image's history), and
H-8 proves the file says what the build meant to say — not that the endpoint agrees.
That membership check is the deployment's, before the panes start. No row proves
that a model answers through the harness: that needs a router serving a real alias and a real credential, which
is the deployment's test (D-2's own acceptance rows cover the router side). No row
proves the CLI's own behaviour inside a workspace — that belongs to the harness.
The platform claim is per-platform: a row reports the platform it ran on, and
nothing here asserts a platform nobody built. And on a base image that already
carries the same CLI on PATH, H-4 answers with *that* copy's version rather than
the layer's install; the run says so, and the case of a base that ships no harness
is stated rather than measured.

## Failure Modes and Rollback

| Phase | What fails | How it is detected | How it is undone |
|---|---|---|---|
| 2 | The base reference does not resolve | The build's first line: the `FROM` cannot be pulled or found locally | Correct `P-2`; nothing was produced |
| 2 | The registry is unreachable | The install step's own error, naming the package | Fix the network or the registry mirror policy; do not vendor the CLI (D-5) |
| 2 | The base image carries no Node.js runtime and the repository cannot supply one | The runtime install step fails | Build the base image so it carries the runtime (D-6); do not switch CLI |
| 2 | An unknown `AGENT_HARNESS_ID` | The build stops with one line naming the value (H-6) | Use an implemented value, or follow `modules/extension-path.md` |
| 3 | The alias is not in the router's set | Per-request error at the client, naming the alias; every other alias keeps serving | Add the alias to the router's map (`run-an-llm-router`'s own phase), then rebuild the layer with the corrected `P-5` |
| 3 | The credential variable is empty | The CLI's own authentication error, naming the variable (D-3) | Fix the deployment's secret wiring; the image is unchanged by it |
| 4 | A row fails | The row's text names the measurement and the expectation | Fix the layer, rebuild, re-run the table. The verdict is the table's, not the commit's |

A half-applied layer is recognisable: an image whose `AGENT_HARNESS` is set but
whose CLI is absent fails H-4 while passing H-3, which is exactly the state a
build interrupted after the `ENV` line produces.

## Removal

Removing this layer means going back to the image it was built on, which still runs
one agent in one workspace and refuses without a harness.

1. Point the deployment's image reference back at the agent-host image (`run-multiplexed-agent-workspaces`,
   D-1). Its `P-17 AGENT_HARNESS` is unset, so the base's entrypoint refuses —
   which is the correct posture for a host with no harness, not a defect.
2. Delete the images this layer published; the base's own removal procedure
   belongs to that package.
3. The harness home (`P-9`) holds the CLI's session state and configuration. It is
   what a deployment mounts; removing the layer without removing it leaves the
   state where it was, and re-adding the layer finds it again.
4. Nothing else is left behind: the layer owns no service, no volume, no network
   and no credential.

## Decisions and Open Questions

Decisions:

- 2026-09-19 — **The layer bundles the decryptor the boot path execs.** The
  composition starts this image with `sops exec-env … agent-host-boot`, and no
  package in the chain installed `sops`: the layer added the CLI and nothing else,
  and the container died at `sops: not found` before the harness or the boot
  program ran. R-2 now names the boot path's own dependencies alongside the CLI,
  and the build proves the binary works (`sops --version`) in the same step that
  proves the CLI does. The lesson is recorded in the requirement rather than in a
  commit message: "needed" is judged against the deployment's entrypoint, not
  against the CLI in isolation.
- 2026-09-19 — **`P-3` is the router root, and each arm derives its own endpoint.**
  Claude Code appends `/v1/messages` to `ANTHROPIC_BASE_URL`; Codex CLI appends
  `/responses` to its provider's `base_url`, which therefore has to end in `/v1`.
  One parameter cannot be both, and writing it verbatim into both files makes the
  Claude arm request `/v1/v1/messages` — a 404 at the first turn, invisible to
  every check that only looks for a key. The layer derives per arm, records the
  result in the image, and the build refuses a `P-3` that ends in `/v1`.
- 2026-09-19 — **The configuration root is per image, and every pane shares it.**
  `P-9` is written into the image, and the deployment cannot vary it per pane:
  `herdr` does not pass a workspace's `--env` values into a plugin pane (the
  multiplexer's own measurement). Every agent a deployment runs from one image
  therefore shares one configuration and one session store, which is also the
  single path Q-1's volume mounts. The alternative — leaving the root unset so
  each CLI uses `$HOME/.<cli>` and each pane's own home follows the agent — needs
  a boot hook the base does not offer, and adding one means replacing the
  entrypoint (R-1). Stated in the Interfaces section, not left to be discovered.
- 2026-09-19 — **The build-time endpoint check is reachability, not alias
  membership** (`P-11`). A credential cannot be a build argument: build arguments
  that reach a `RUN` land in the image's history, and R-8 forbids a credential in
  the image. Without one, the models endpoint cannot be read for its alias list —
  so the check proves the router answers, and alias membership stays where it can
  be proved: the deployment's own gate, before the panes start. The check is
  opt-in, because a build in CI has no router to reach and must not be blocked by
  that absence.
- 2026-09-18 — **The layer adds a CLI, not a harness *runner*.** The base's
  entrypoint already `exec`s whatever `AGENT_HARNESS` names, and the multiplexer's
  decision log records why a layer must not add an `ENTRYPOINT` or point
  `AGENT_HARNESS` at the boot program: every harness layer sets that variable, so
  a value written by the multiplexer would be overwritten. This layer therefore
  sets it and nothing else.
- 2026-09-18 — **One base reference, not a registry and a digest.** `P-2` is one
  complete reference — `name:tag` for a locally built base, `name@sha256:<manifest
  list digest>` for a published one — so a deployment that has not published the
  base yet can still build a layer over it. Two parameters, a registry host and a
  digest, is more fields with no extra capability.
- 2026-09-18 — **The harness is a build-time parameter, so the configuration is
  written at build time.** The alias set and the router URL are deployment values,
  and the layer is built per deployment; the alternative — writing the
  configuration at boot — needs an entrypoint hook the base does not offer. The
  consequence is stated rather than hidden: changing the router's alias set means
  rebuilding the layer, and a build arg that names an alias the router does not
  serve fails at the client, which is R-7's intended direction.
- 2026-09-18 — **The token metadata is declared per harness, and where a CLI has
  no field, that is said.** Claude Code takes a context window and a maximum output
  count; Codex CLI takes a context window and has no maximum-output key. Writing a
  plausible key that the CLI ignores would be worse than stating the gap
  (`modules/router-wiring.md`).
- 2026-09-18 — **`wire_api = "responses"` for Codex CLI is a condition on the
  router, not a choice.** Codex CLI's provider block accepts only that value, so a
  router that serves chat completions alone is not a compatible endpoint for that
  harness. Recorded as a dependency condition (D-2's failure behaviour) rather than
  worked around with a proxy.
- 2026-09-18 — **No credential, and no login flow in the image.** A CLI that
  persists a login writes a credential-shaped file; the image must contain none
  (R-8), so the deployment's credential variable is the only path, and
  `modules/credentials.md` states what an operator does when a harness insists on
  a login.
- 2026-09-18 — **The acceptance script builds this layer on a base image it is
  given, and skips with a reason when it has only a stand-in.** The base is not
  published yet; a script that refused to run without a published base would
  produce no evidence at all, and one that silently substituted a different image
  would produce dishonest evidence.

Open questions:

- **Q-1** *(open)*: whether a deployment should mount `P-9` from the host. The
  layer works either way — the image writes a default configuration there and a
  bind mount takes precedence. Mounting keeps session state across recreates and
  is what the private implementation did; not mounting keeps a recreate clean. The
  default is not to mount, and the implementer decides per deployment.
- **Q-2** *(open)*: whether the layer should ship a `HEALTHCHECK` that runs the
  CLI's version command. The base declares none, and the multiplexer supervises
  the pane, so a healthcheck would report on the CLI image rather than on the
  agent. Left out; adding one is a local edit with no contract change.
- **Q-3** *(open)*: the minimum Node.js version for each CLI. The registry
  metadata is the authority and the build reads it; the package does not restate a
  number it cannot verify per release.
