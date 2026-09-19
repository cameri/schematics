---
name: assemble-a-sandboxed-agent-set
version: 0.2.0
status: draft
spec: 1
description: "The composition package for the sandboxed-agent set: the deployment order with the reason for every edge, the isolation rules between the parts, the shared contracts, and one end-to-end acceptance test that proves the chain — the base image, the agent host, the harness layer and their neighbours — rather than the parts."
created: 2026-09-19
updated: 2026-09-19
---

# Schematic: Assemble a Sandboxed Agent Set

This package turns four independently implementable parts and their neighbours
into one running capability: an agent host whose panes execute exactly one
coding-agent CLI, and that CLI reaches a private model router by model alias.
Each part already knows its own contract; none of them knows the others'. This
package owns the missing knowledge — the order the parts must be built and
started in, the isolation rules between them, the values they must agree on, and
one test that fails if the chain is broken anywhere. After the implementer
finishes, a container runs the host image, an agent pane inside it runs the
harness, and a request from that pane reaches the router by alias and is
answered by a model the operator chose.

It is a composition in the sense of binding principle 8: it owns no images, no
services, and no files of its own beyond the shared contracts and the
end-to-end acceptance test. Everything it deploys belongs to a part.

## Applicable Context

**Must discover locally** (with the discovery command/method for each):

- The container runtime and its builder: `docker version`, `docker compose
  version`, `docker buildx version`. The base image build needs BuildKit
  (`DOCKER_BUILDKIT=1`, the default on a current Engine); a host where the
  legacy builder is forced cannot build the base image at all.
- Whether the builder can produce a multi-platform manifest list (`docker
  buildx ls`) — the base part's `P-12 PLATFORMS` is inherited, not re-decided.
- The base image reference this deployment will consume (`AGENT_BASE_REF`): for
  a published base, the manifest list digest — `docker buildx imagetools inspect
  <published ref> --format '{{.Manifest.Digest}}'`; for a base built on this
  machine, its local tag. Resolve the digest now, never copy one from
  documentation.
- The router's alias set before the harness layer is built
  (`GET /v1/models` with the router credential returns exactly the ids the
  client may send). The harness build validates its alias against this set, so
  the set must be readable at build time.
- The uid and gid that own the agent tree directory (`stat -c '%u:%g'
  <AGENT_TREE_DIR>`) and the uid the base image's account uses (part 1's
  `P-4`/`P-5`). The secrets part's key-file mode parameter depends on whether
  they match.
- Whether a registry is in play (`docker info --format '{{.RegistryConfig}}'` is
  not the question — ask the operator). Nothing here requires one; the choice
  only decides whether the image references are digests or tags.
- Whether a real provider credential exists for the end-to-end completion row.
  If it does not, that row skips with its reason printed (`A-15`).

**May assume** (each with the risk if the assumption is wrong):

- A single Docker host reachable by the operator with a shell, and the Compose
  plugin — risk: without Compose the glue file cannot be merged and every phase
  becomes manual `docker run` work; the shared contracts still apply.
- The parts' own acceptance suites have been read and can be run on this host —
  risk: a part that was never verified in isolation fails inside the chain
  where the failure is harder to attribute. `A-3` catches this by running them.
- Outbound HTTPS at build time to the distribution's package repositories and
  to whatever release host the parts pin — risk: builds stop at the failing
  step; nothing in this package retries or substitutes a mirror.
- No inbound network reachability is required for the set to work — risk: an
  operator who wants off-host access must set the router's exposure parameter
  and part 2's listen parameter deliberately; the defaults are loopback.

**Must not change** (host constraints the capability works within):

- The parts' pinned commits and their published contracts. This package may set
  a part's parameters; it may not edit a part, fork it, or restate its contract.
- The runtime account, entrypoint, working directory, and `AGENT_*` variable
  names the base image establishes (part 1's `R-1`–`R-13`).
- The host default of no published port and no socket mount (part 2's `R-9`,
  part 2's `R-13`). A deployment that needs either is a deliberate override
  recorded outside this package, not a variant of it.

## Scope

**In scope:**

- The dependency order across the parts and their neighbours, as build and start
  edges, each with the reason it exists and the failure it prevents.
- The isolation rules between the parts: which container sees which mount,
  which capability, which network, and what is forbidden to all of them.
- The shared contracts: the values two parts must agree on to work together
  (network name, mount paths, image references, the alias and credential path).
- The composition's own acceptance script, whose rows prove the chain.
- The pin set: every part named by commit plus file hash, with the procedure for
  moving a pin when a part is published in a new revision.

**Out of scope / non-goals:**

- Implementing, patching, or vendoring any part. Each part stays the only place
  its contract lives.
- Building a part's own artifact where the part already specifies how (a
  deployment that consumes a published base image starts at Phase 4, not at the
  base build).
- Model choice, provider choice, or prompt/harness configuration: the alias set
  and the harness arm are parameters, and everything about what the agent does
  once it starts belongs to the harness part and the operator.
- Secrets management beyond naming where the material comes from. No key,
  token, or credential is created, transported, or stored by this package.

## Requirements

- **R-1**: The set MUST be deployed in dependency order, and every phase MUST
  refuse to proceed when an input does not yet exist: the base reference before
  the host image build, the host image before the harness layer build, a running
  router serving the chosen alias set before the layer is built *or*, failing
  that, before the set is started — the composition's own gate (Phase 3 step 3,
  the bring-up script's step 7) is where alias membership is enforced, and the
  layer's build-time check (part 3's `P-11`) is opt-in and proves reachability
  only, because a credential may not be a build argument — and the store's key
  material before any container that decrypts at boot.
- **R-2**: This package MUST own no image, no service, and no file beyond the
  shared contracts and the end-to-end test (binding principle 8). For every
  service a part defines it MUST declare no `image`, no `build`, no `command`,
  no `entrypoint`, no `environment`, no `user`, and no mount; what its compose
  file may add is the network a service joins and the secret names a service
  references, because those are the shared contracts rather than the service.
- **R-3**: Every part MUST pass its own acceptance rows in isolation before the
  chain is assembled, and a part that fails them MUST stop the assembly rather
  than be worked around inside the chain.
- **R-4**: Every container in the set MUST run with no published port, no
  `--privileged`, no added capability, no device, and no host root; Docker
  access from a container MUST go through the proxy endpoint the Docker-access
  part provides, never a mounted socket. The proxy MUST keep the internal
  network its own fragment declares: no other container of the set is attached
  to it, and the container that needs Docker joins that network — the proxy does
  not join the set's, because a proxy on the set's network puts an
  unauthenticated daemon port in front of every service in it.
- **R-5**: The set MUST NOT require a registry: the whole chain MUST build and
  run from images on the local daemon. When a registry is used, the digest form
  of every image reference MUST be accepted unchanged.
- **R-6**: The agent tree MUST be the only stateful host path the set mounts
  read-write. Every other host mount MUST be read-only or a single credential
  file.
- **R-7**: The harness layer MUST add exactly one CLI wired to the router by
  alias, and the credential MUST reach that CLI at run time through its
  environment, never in an image (part 3's `R-2`, `R-6`, `R-8`).
- **R-8**: The store's master key MUST never enter a container. Only a
  service-scoped key file is mounted, with the mode the deployment's uid
  relationship requires.
- **R-9**: The composition's acceptance MUST prove the chain and not the parts:
  the image chain builds in order, the host starts, a pane runs the harness, and
  a request from that pane reaches the router by alias — each of those as its
  own row, each able to fail.
- **R-10**: Every dependency MUST be pinned to a commit reachable from the
  checked-out history plus the SHA-256 of the pinned file at that commit, and
  the package MUST state where a pin moves when a part is published under a new
  commit.
- **R-11**: A row that cannot run on the host — no real provider credential, no
  usable BuildKit, no native second architecture — MUST skip with its reason
  printed, and MUST NOT be reported as a pass. Unknown is reported as unknown.
- **R-12**: No artifact of this package may name a registry, namespace,
  hostname, or personal path. Every value that could differ between deployments
  is a parameter with a discovery method.
- **R-13**: Removal MUST detach the composition without touching a part: stop
  the containers, remove the network and the glue file, leave the images, the
  parts, and their state directories as they were.
- **R-14**: Every phase MUST be idempotent: re-running it detects completion and
  skips, and re-running the acceptance script gives the same verdict.

## Design Principles Binding the Implementation

The ten binding principles, and where this composition leans on them:

1. **Vendor-agnostic** — implement with plain, portable components; no
   dependency on any specific agent or harness.
2. **Portable** — no absolute paths or machine-specific values in the
   implementation; use the Parameters below.
3. **Self-contained** — the implementation needs nothing outside this package
   and the declared Dependencies. Here that means the parts are *pinned*, not
   vendored: the pin is the only copy of their contracts this package keeps.
4. **Predictable, intuitive, ergonomic** — the installed capability behaves
   exactly as this document describes; no surprise behaviors.
5. **Idempotent and deterministic** — every phase is safe to re-run; checks give
   the same verdict every time.
6. **Parameterized and modular** — all tunables flow from the Parameters table;
   concerns are separated per the Modules section; behavior differences between
   deployments are configuration, never code edits.
7. **Dependencies called out** — implement the declared failure behavior for
   every Dependency.
8. **Composable in kind** — a dependency may be another schematic in the
   catalog, pinned to a commit and a content hash; a composition schematic owns
   no services, only the shared contracts and the end-to-end acceptance test.
   **Binding note:** this is the principle this package exists to exercise. Its
   deliverable is an order, a set of rules, and a test; a service appearing in
   its skeleton would mean a part was re-implemented instead of pinned.
9. **Applicable context stated** — discover what Must discover locally says; do
   not silently assume beyond May assume.
10. **Pluggable** — implement the attach/remove seams defined in Modules and
    Removal.

## Dependencies

Each `schematic` row is pinned to a commit **reachable from the checked-out
history** plus the SHA-256 of that file at that commit. Recompute the hash at
the named commit; never copy one from this table into your own downstream pin
without recomputing it.

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | schematic | [build-an-agent-dev-image v0.2.0](https://github.com/cameri/schematics/blob/46e27a62ea52ca897a27d2e07fff73e3da1fcda3/schematics/build-an-agent-dev-image/SCHEMATIC.md) `sha256:68bd6b56d702fd8d5cb875db64aafeadb2b02c6d438d07a4463b6b734038b122` | The bottom of the image chain: the distro-derived base whose account, entrypoint, workspace and `AGENT_*` contract every later part inherits | Its own acceptance script green against the reference this deployment consumes | No base reference means no host image: Phase 4 stops. A published base that cannot be resolved is a missing prerequisite, not a build to improvise |
| D-2 | schematic | [run-multiplexed-agent-workspaces v0.2.1](https://github.com/cameri/schematics/blob/7dafa31ae8457969563acac703786ac42fb26654/schematics/run-multiplexed-agent-workspaces/SCHEMATIC.md) `sha256:8fed59d6c800a52c3cf8f86bee377f95b6398e4d83d5711f852e48e8e70451a6` | The agent host: herdr, one workspace per agent, crash-only supervision, and the boot program the deployment runs. Its `P-17 AGENT_HARNESS` arrives unset, which is why a harness layer must be attached before an agent can run | `herdr --version` inside the host image; its own acceptance script green | A host image without a harness refuses to start an agent (its entrypoint's documented refusal, exit `78`). The chain is incomplete, not broken: attach the harness layer |
| D-3 | schematic | [add-an-agent-harness v0.3.0](https://github.com/cameri/schematics/blob/7c79c0836fa48db3e3e26ccd3a77fbd940a79382/schematics/add-an-agent-harness/SCHEMATIC.md) `sha256:bedfbebecb3584423f50eafd6db85a5cd630795e0839b906e3af903286e2fcac` | The harness layer: exactly one coding-agent CLI plus its configuration, wired to the router by root URL, with no credential in the image, and with `sops` bundled because the composition's own boot command decrypts with it. It is the top of the image chain and the thing an agent pane actually runs | Its own acceptance script green against the host image it was built from (claude 35 checks 0 failures, codex 36 checks 0 failures, on the reference host); the third arm's rows were run the same way over a Debian stand-in base built for the check — 44 checks, 0 failures, 3 skips (a `docker top` this host does not support, a YAML parse check whose interpreter the image does not carry, and a build-log row that a supplied image cannot produce) — and that base also re-ran both registry arms on the rewritten install step (claude 36 checks 0 failures, codex 36 checks 0 failures), so the release channel is measured along the image chain and the two arms it shares a step with are shown unchanged; `AGENT_HARNESS` set in the layer image | Without it the host starts but no agent runs. Its build needs the router only when the deployment asks for that check (part 3's `P-11`), because a credential cannot be a build argument; alias membership is enforced by this composition's own gate instead |
| D-4 | schematic | [run-an-llm-router v0.2.1](https://github.com/cameri/schematics/blob/545ec07f94d3c14a0bdaaf40a87d33f5c684d875/schematics/run-an-llm-router/SCHEMATIC.md) `sha256:095db6143e4b0a3594360a522e232d23a37c10d932d42c8d875a5e455a624e9c` | The inference endpoint the harness sends requests to, addressed by model alias so a provider can be swapped without touching the harness. Ready before the harness layer is built | `GET /health/liveliness` answers; `GET /v1/models` with the router credential returns the alias set | This composition refuses to start the set when the router does not serve an alias the set names (`A-11`); if a router is already built into an image, requests fail visibly at run time and no other provider answers (its `A-11`). Nothing here retries or falls back |
| D-5 | schematic | [encrypt-container-secrets v0.2.2](https://github.com/cameri/schematics/blob/da0ac2334dd997588daffd404570292d50d6dca6/schematics/encrypt-container-secrets/SCHEMATIC.md) `sha256:7b40f292571587b0c6a57460ab5611b2bb4104b1ea0cc6e6848dddea78a45d6a` | The credential path: values encrypted at rest, decrypted into a process's environment at boot, one key per service, master key host-only. It is how the router's provider keys and the harness's router credential reach their processes | Its own acceptance green; a container started without its key file must fail loudly (its `A-9`) | A container whose store or key is missing exits non-zero and never starts the application (its `R-9`). That is the intended refusal — do not start the service with a stale or hand-edited environment instead |
| D-6 | schematic | [restrict-docker-api-access v0.3.1](https://github.com/cameri/schematics/blob/d405389a80eb1bc3019ecabf312535d072b1559a/schematics/restrict-docker-api-access/SCHEMATIC.md) `sha256:7444bdd603df29c072a7f7ebf9b09dda23e8c211dd9dc55d76f9a36a6ee22c58` | Docker access for the agents without a socket: a deny-by-default HTTP proxy on an internal network, socket mounted read-only into the proxy only. Chosen because the host part names it (part 2's `D-2`) and forbids socket mounts (part 2's `R-9`) | Its audit script matches its allowlist (its `A-2`); no consumer mounts a socket (its `A-1`) | Agents have no Docker at all. Mounting the socket instead is refused by this composition's `R-4`, not offered as a fallback |
| D-7 | system | Docker Engine with the Compose plugin, and BuildKit usable by the build | Merges the parts' fragments, starts the set, and builds the base image | `docker version`, `docker compose version`, `docker buildx version`, and one real build that gets past the architecture guard | Hard fail at Phase 4: a host that cannot build the base image cannot assemble the set. Do not substitute a legacy-builder build of the base image — it fails at its architecture guard and its cache mounts |
| D-8 | system | Outbound HTTPS at build time to the distribution's and the parts' pinned release hosts | Installs the toolchain, the multiplexer and the harness CLI at their pinned versions | The builds' own download and package steps | Hard fail at the failing step; never substitute an unreviewed mirror for a checksum-verified asset |
| D-9 | system | A real provider credential, held by the operator, present only in the deployment's encrypted store | `A-15` (a completion through the alias) needs a provider that actually answers. Every other row is credential-free | The deployment's own store, in the form `D-5` defines | Degrade by design: without it the alias path is still proven (`A-11`) and the completion row skips with its reason printed. Never invented, never committed |

**Recommended** (declinable — every phase and every row above completes with all
of these declined):

| Id  | Kind | What | Why recommended | What the composition does without it |
|-----|------|------|-----------------|--------------------------------------|
| D-10 | schematic | [authorize-docker-requests v0.6.1](https://github.com/cameri/schematics/blob/e1a3c4a51f9f439cdeab269f7e16ceeec47f0ecc/schematics/authorize-docker-requests/SCHEMATIC.md) `sha256:ca312f8cd44e1edd0135f6f2ae7ea6a9353493447f3d7b746f9a67608123e5cb` | The daemon-side alternative to `D-6`: an authenticated TCP listener with a policy plugin, which can gate requests a proxy cannot see (a container's own mount options, for instance) | Not chained: it needs host root, a PKI, and a policy file, and it leaves the unix socket itself unrestricted. A host that already runs that mechanism, and wants policy enforced by the daemon rather than by a proxy, may deploy it alongside; agents then point at its endpoint instead of `D-6`'s | The chain is unchanged: Docker access is `D-6`'s proxy endpoint. Both are legitimate; `D-6` is what the host part already names, so it is what the composition verifies |

## Parameters

Every value that differs between deployments is here, with the discovery method
that resolves it. Rows whose Effect names a part parameter are the values this
composition **hands to that part**; the part's own table remains the place where
that parameter's contract lives.

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | `AGENT_SET_NETWORK` | string | `agent-set` | `docker network ls` — pick a name that does not collide | The internal network every service of the set joins — every service **except** the Docker-access proxy, which keeps the internal network its own fragment declares and is reached only by the host container (`R-4`) — and the only path between them that is not a bind mount |
| P-2  | `AGENT_TREE_DIR` | path (host) | *(none — required)* | Operator's choice of a directory on the host; `stat -c '%u:%g'` reads its owner | The bind mount that holds every agent's workspace and home. It is the set's only stateful host path (part 2's `P-30`) |
| P-3  | `AGENT_IDS` | list | *(none — required)* | The operator's agent names; each becomes one herdr workspace | Which agents exist in the host, and the workspace labels their panes carry (part 2's `P-11`) |
| P-4  | `AGENT_BASE_REF` | string | *(none — required)* | `<name>:<tag>` for a base built on this host, `<registry>/…/<name>@sha256:<manifest list digest>` for a published one | The `FROM` of the host image build (part 2's `P-1`). The digest form is required whenever the base came from a registry |
| P-5  | `AGENT_HOST_IMAGE` | string | *(none — required)* | `docker image ls` after the host image build, or the published reference | The `FROM` of the harness layer build (part 3's `P-2`) and the image the host container runs |
| P-6  | `HARNESS_IMAGE` | string | *(none — required)* | `docker image ls` after the harness layer build, or the published reference | The image an agent pane's CLI comes from; the top of the chain |
| P-7  | `HARNESS_ID` | string | *(none — required)* | The harness arm this deployment wants; the layer part's templates name the arms it ships | Which CLI the layer installs and what `AGENT_HARNESS` becomes (part 3's `P-1`). Empty is not a default: a build that names no harness is refused, so it must be chosen here |
| P-8  | `ROUTER_BASE_URL` | string (URL) | `http://llm-router:4000` | The router's endpoint on `P-1`'s network: its service name and port (the router part's `P-1`, `P-2`) | Where the harness sends inference requests. It is the router ROOT, with no `/v1`: the harness layer takes it as part 3's `P-3` and derives each arm's protocol path (the root for Claude Code's `ANTHROPIC_BASE_URL`, root plus `/v1` for Codex's `base_url` and for the omp arm's `baseUrl`, which its OpenAI-compatible client appends `/chat/completions` to), which is why the router's own API paths are written as `<root>/v1/…` wherever this package reads them (`A-11`). A value ending in `/v1` is refused by the layer's build |
| P-9  | `ROUTER_CREDENTIAL_ENV` | string | *(derived — arm-dependent, from `P-7 HARNESS_ID`)* | The variable the CLI reads at runtime, derived from the arm rather than chosen: `ANTHROPIC_AUTH_TOKEN` when `HARNESS_ID=claude`, the layer's `ROUTER_CREDENTIAL_ENV` (default `ROUTER_API_KEY`) when `HARNESS_ID=codex` or `HARNESS_ID=omp`. The pinned layer records the name the harness it installed actually reads at `/usr/local/share/agent-harness/credential-env` inside the image — `cat` it; that record is the authority for the arm that was built | The one name the router credential is carried under: the store's dotenv entry, the harness process's environment, and `A-10`/`A-11`/`A-15` all use it (part 3's `P-4`, whose per-arm record is the file above) |
| P-10 | `ROUTER_ALIAS` | string | *(none — required)* | Read the alias set from the running router: `GET /v1/models` with the router credential | The model id the harness sends for its primary role (part 3's `P-5`). It must be a member of the router's alias set (`P-11` here), and this composition's own gate checks that before the set starts (the bring-up script's step 7, `A-11`), because the layer's build-time check proves reachability only |
| P-11 | `ROUTER_ALIAS_SET` | list | *(none — required)* | `GET /v1/models` returns it exactly; the operator chooses what it contains in the router's own configuration | The ids any client may send (the router part's `P-10`). `ROUTER_ALIAS` and `ROUTER_FAST_ALIAS` must both be members |
| P-12 | `ROUTER_FAST_ALIAS` | string | *(empty — arm-dependent)* | As `ROUTER_ALIAS`; some harness arms have no second role | The model id for the harness's background/small-task role (part 3's `P-6`) |
| P-13 | `HARNESS_CONTEXT_WINDOW` | int (tokens) | *(none — required)* | The model behind `ROUTER_ALIAS` on the router's side: the operator's record of it, or the provider's documentation for that alias | Written into the harness configuration (part 3's `P-7`); a wrong value is a run-time symptom, not a build failure |
| P-14 | `HARNESS_MAX_OUTPUT_TOKENS` | int (tokens) | *(none — required for arms that have the key)* | As `HARNESS_CONTEXT_WINDOW` | Written into the harness configuration (part 3's `P-8`) |
| P-15 | `DOCKER_PROXY_URL` | string (URL) | `tcp://socket-proxy:2375` | The Docker-access part's endpoint on its own network — proxy service name and port (its `P-5`, `P-6`) under a Docker client scheme, `tcp://`; the part documents the same endpoint as the HTTP URL `http://socket-proxy:2375` for its own audit script, and that form is not a `DOCKER_HOST` value | The `DOCKER_HOST` a consumer exports to reach the daemon through the proxy; the only Docker path an agent has (`D-6`, exercised by `A-13`) |
| P-16 | `DOCKER_PROXY_ALLOWLIST` | string | *(none — required)* | What the agents genuinely need: read image and container state, for example — nothing that changes the host | The proxy's allowed endpoint groups (the Docker-access part's `P-4`). An allowlist wider than the need is the whole risk of this row |
| P-17 | `SECRETS_KEY_DIR` | path (host) | `~/sops/age` | Where the operator keeps age keys; the store part's `P-1` | Where the key material for `D-5` lives. The master key never leaves this directory into a container; each service's dedicated key is `<SECRETS_KEY_DIR>/<service>-keys.txt` |
| P-18 | `SECRETS_STORE_DIR` | path (host) | *(none — required)* | Where the operator keeps each service's encrypted dotenv file: one directory per service, `<service>/.env.encrypted` (the store part's `P-4`, `P-11`) | Where the two encrypted stores the set needs are read from when the compose file declares them as secrets |
| P-19 | `ROUTER_SECRETS_SERVICE` | string | `llm-router` | The name of the store service holding the router's provider keys; it is also the router's own service-name parameter (the router part's `P-3`) | Which encrypted file and dedicated key the router boots with (the store part's `P-3`) |
| P-20 | `AGENT_HOST_SECRETS_SERVICE` | string | `agent-host` | The name of the store service holding the one credential an agent needs, as a dotenv entry under the name `P-9` resolves to for this arm | Which encrypted file and dedicated key the host container decrypts at boot (the store part's `P-3`) |
| P-21 | `HARNESS_CONFIG_PATH` | path (in-container) | *(none — required)* | The layer part's harness-home parameter (`P-9`) plus the file name that arm writes | The CLI's configuration file inside the image, which `A-10` reads to prove the wiring names only aliases and carries no provider credential |

## Modules

- **deployment-order** (`modules/deployment-order.md`) — the build and start
  edges between the parts, each with the reason it exists and the failure it
  prevents.
- **isolation-rules** (`modules/isolation-rules.md`) — what each container may
  see, mount, and hold; what no container in the set may have.
- **shared-contracts** (`modules/shared-contracts.md`) — the values and file
  shapes two parts must agree on, and which part owns each of them.
- **end-to-end-acceptance** (`modules/end-to-end-acceptance.md`) — what the
  end-to-end script proves, what it deliberately does not, and how it reports
  a row it could not run.

## Interfaces and Contracts

The surfaces this package exposes and consumes. Anything not listed here belongs
to a part and is named by pin, never restated.

**Between the parts (what the composition guarantees):**

- One Docker network, `P-1 AGENT_SET_NETWORK`, joined by every service of the
  set and by nothing else — with one deliberate exception: the Docker-access
  proxy keeps the internal network its own fragment declares and is not attached
  to this one, so the host container joins both and the proxy's port never faces
  the set (`R-4`, checked by `A-13`). All in-network addressing is by service
  name.
- The image chain, in one direction: `AGENT_BASE_REF` → `AGENT_HOST_IMAGE` →
  `HARNESS_IMAGE`. Each reference is a complete image reference: a local tag
  when built here, `name@sha256:<manifest list digest>` when published.
- The alias path, in one direction: the harness configuration names
  `ROUTER_BASE_URL` and a model alias from `ROUTER_ALIAS_SET`; the router
  resolves that alias to a provider and a model. No harness configuration names
  a provider, a provider key, or a model id that is not an alias.
- The credential path: provider keys live only in the router's encrypted store;
  the router credential is the only credential a harness process sees, and it
  arrives in that process's environment at run time under the name `P-9`
  resolves to for this arm — `ANTHROPIC_AUTH_TOKEN` when `HARNESS_ID=claude`,
  the layer's `ROUTER_CREDENTIAL_ENV` (default `ROUTER_API_KEY`) when
  `HARNESS_ID=codex` or `HARNESS_ID=omp` — and the store's dotenv entry must
  carry the credential
  under that same name.

**Compose merge order** (each part ships a fragment; the deployment merges *its
own filled-in copy* of each — several fragments are starting points a deployment
edits, such as the Docker-access part's, whose `environment:` is empty until the
consumer enables the groups it needs — and the composition ships the glue, last):

```sh
docker compose \
  -f <part: run-an-llm-router>/skeleton/compose.yml \
  -f <part: restrict-docker-api-access>/skeleton/compose-socket-proxy.yml \
  -f <part: run-multiplexed-agent-workspaces>/skeleton/compose.service.yaml \
  -f <part: add-an-agent-harness>/skeleton/compose.service.yaml \
  -f skeleton/compose.yaml \
  config
```

Five fragments, not one per part. The store part ships
`<part: encrypt-container-secrets>/skeleton/compose-secrets.yml`, and that file
is **not** merged and MUST NOT be added to this list: it is a generic example of
the wiring for ONE service, carrying `services.myservice` with an image and a
`sops exec-env` command, so merging it adds a service no part defines where
`R-2` and `A-2` require the merged configuration's services to be exactly the
parts' own — and since the later file wins a single-value field, a copy that
named `llm-router` would override the router fragment's own `command`. Nothing
in the set needs it: each consumer's own fragment already carries its `secrets:`
list, its mount targets and its `SOPS_AGE_KEY_FILE`, and the glue declares the
four secret **sources** those references resolve to. A deployment that adds a
service of its own fills that service's wiring into THAT service's fragment.
`skeleton/compose.yaml`'s header states the same rule beside the list it ships.

Compose merges in the order given, and the **later** file wins a single-value
field while list-valued fields such as `networks:` are unioned (measured with
`docker compose config` on two fragments that both set `image`, `environment`
and `networks`). Two consequences the composition depends on: the glue comes
last so nothing about a part can be overridden by accident, and a service a part
already attached to its own network keeps that network and gains this one — the
shared network is additive, never a replacement. Every entry this package's file
makes under `services:` carries `networks:` and nothing else; an `image`,
`command`, `entrypoint`, `environment`, `user`, or mount there would be this
package re-implementing a part (`R-2`, checked by `A-2`).

**Readiness gates** (a phase does not advance until its gate passes):

| Component | Gate |
|-----------|------|
| Router | `GET /health/liveliness` on its port answers; then `GET /v1/models` with the router credential returns the alias set |
| Store | A container started with the store and key present reaches its application; one started without them exits non-zero |
| Docker-access proxy | Its own audit script matches the allowlist; no consumer mounts a socket |
| Host | The host container is up and its herdr session is alive; a `docker exec`/pane check runs the harness only after the harness layer is attached |
| Chain (the composition's own gate) | `scripts/verify-set.sh` exits 0, or its skipped rows state their reasons |

**Files this package ships**: `skeleton/compose.yaml` — the glue, which defines
no service of its own: the shared network, the secret sources the parts reference
by name, and one `networks:` line per service — with `skeleton/compose.yaml.schema`
beside it; `skeleton/bring-up.sh`,
which walks the dependency order of Phases 2–5 as a sequence of guarded steps,
with `skeleton/bring-up.sh.schema` beside it; and `scripts/verify-set.sh`, the
end-to-end acceptance script.

**Acceptance script interface**: `scripts/verify-set.sh` takes its inputs from
the environment (image references, network name, agent id, alias, and the paths
to the parts' own scripts), prints one line per row as `PASS`, `FAIL`, or
`SKIP <reason>`, exits 0 when nothing failed, and never reports a skipped row as
a pass.

## Implementation Phases

### Phase 1: Discovery and decisions

Goal: every parameter above has a value or an explicit default, and every
part's own acceptance status is known before anything is assembled.

Steps:
1. Resolve `AGENT_BASE_REF` (digest form if it came from a registry) and
   `AGENT_HOST_IMAGE`/`HARNESS_IMAGE` naming.
2. Choose `HARNESS_ID` and confirm the arms the layer part ships.
3. Decide the alias set with the operator, then read it back from the running
   router once Phase 3 is done — the decided list and the observed list must be
   the same.
4. Decide `DOCKER_PROXY_ALLOWLIST` from what the agents actually need.
5. Read each part's acceptance script and record whether it can run on this
   host (their build-dependent rows may not).

Skip condition: a parameter set already recorded for this deployment — re-read
it and confirm the parts' versions still match the pins in this document.

Verify: every row of the Parameters table resolves; `stat -c '%u:%g'
"$AGENT_TREE_DIR"` answers; the parts' scripts are executable and present.

### Phase 2: The shared contracts

Goal: the things two parts must agree on exist before either starts.

Steps:
1. Create the network `AGENT_SET_NETWORK`.
2. Create `AGENT_TREE_DIR` and confirm its owner matches the base image's
   account ids (part 1's `P-4`/`P-5`); the host part's own phase says how to
   re-derive them if they do not.
3. Create the store layout the deployment will use: the key directory
   (`SECRETS_KEY_DIR`) with one dedicated key per service
   (`ROUTER_SECRETS_SERVICE`, `AGENT_HOST_SECRETS_SERVICE`), and each service's
   directory under `SECRETS_STORE_DIR` holding its `.env.encrypted`. The store
   part's phases own key creation and encryption; this phase only ensures the
   layout exists where that part's parameters say it does.
4. Write the deployment's environment file for the composition's parameters.
   It holds parameter values, never secrets.

Skip condition: the network exists, the directory exists with the right owner,
and the store's files are present.

Verify: `docker network inspect "$AGENT_SET_NETWORK"` exits 0; the tree's owner
equals the base's account ids; the store files exist with the modes the store
part's parameter expects.

### Phase 3: The credential path and the router

Goal: a running router that serves the decided alias set, and a store whose
absence is a loud failure rather than a silent empty environment.

Steps:
1. Deploy the store's material for the router service (`D-5`'s phases own the
   key creation and encryption) and confirm a container with the store starts,
   and one without it fails (its `R-9`/`A-9`).
2. Deploy the router (`D-4`) with its configuration naming the alias set
   (`ROUTER_ALIAS_SET`) and its store file.
3. Wait for its health gate, then read `GET /v1/models` with the router
   credential and compare it to the decided set. A mismatch stops the assembly
   here: this is the only place membership is decided, because the harness build
   in Phase 4 can prove the endpoint answers but cannot carry the credential
   such a check needs.

Skip condition: the router already runs and `GET /v1/models` returns the
decided set.

Verify: the health endpoint answers; the alias set read from the router equals
the decided list exactly.

### Phase 4: The image chain

Goal: `HARNESS_IMAGE`, built from `AGENT_HOST_IMAGE`, built from
`AGENT_BASE_REF`, with each step's own acceptance rows passing.

Steps:
1. Obtain the base: consume a published base image, or build it from `D-1`
   (its phases own the build; its architecture guard fails loudly on a host
   without BuildKit).
2. Build the host image from `D-2` with `--build-arg AGENT_BASE_REF` set to the
   complete reference from Phase 1. Verify it inherits the base's account,
   working directory, and entrypoint (part 2's own acceptance script does this).
3. Build the harness layer from `D-3` with the router **up**: `AGENT_BASE_REF`
   set to `AGENT_HOST_IMAGE`, `HARNESS_ID`, `ROUTER_BASE_URL`,
   `ROUTER_CREDENTIAL_ENV`, `ROUTER_ALIAS`, `ROUTER_FAST_ALIAS`,
   `HARNESS_CONTEXT_WINDOW`, `HARNESS_MAX_OUTPUT_TOKENS`. The router is up
   because the layer's endpoint check (part 3's `P-11`, opt-in) proves the
   endpoint answers at build time; what that check cannot decide is alias
   membership, because a credential cannot be a build argument (part 3's `R-8`).
   Membership is this composition's own gate: step 7 of `bring-up.sh`, row
   `A-11`, reads the router's model list back and refuses to start a set whose
   alias is not in it.
4. Confirm the layer's config: `AGENT_HARNESS` set, no `ENTRYPOINT`, no `CMD`,
   no credential-shaped file.

Skip condition: each image already exists at the intended reference and its
build inputs are unchanged.

Verify: `docker image inspect` on the harness image reports the base's account
and entrypoint and the layer's `AGENT_HARNESS`; the layer's build completed with
the router reachable.

### Phase 5: Isolation bring-up

Goal: every container of the set running with the mounts, network, and
capabilities the isolation rules allow — and nothing else.

Steps:
1. Deploy the Docker-access proxy (`D-6`) with `DOCKER_PROXY_ALLOWLIST`, on its
   own network, and confirm no consumer mounts a socket.
2. Start the host container from the harness image, joined to
   `AGENT_SET_NETWORK` and to the proxy's network, with the agent tree
   bind-mounted, the router credential in its environment from the store, and no
   published port.
3. Confirm the run contract: the host's boot program starts, its herdr session
   is alive, and one workspace exists per `AGENT_IDS` entry.
4. Run the parts' own acceptance scripts that this host can run, and record the
   rest as skipped with reasons.

Skip condition: the set is already up and the containers' inspect output
matches these rules.

Verify: `docker inspect` on every container of the set shows no published port
and no socket mount; the agent tree is the only read-write host path; the host
process runs as the base's account, not root.

### Phase 6: The chain proof, and ongoing change

Goal: the end-to-end script passes, and a part upgrade has a defined path.

Steps:
1. Run `scripts/verify-set.sh` with the deployment's inputs. Every row that can
   run must pass; every row that cannot must print `SKIP` with its reason.
2. Run the parts' own acceptance scripts once more, listed in the script's
   output, so a chain failure can be attributed to a part or to the glue.
3. Record the pins this deployment was built from (the parts' versions and the
   commits in the Dependencies table) in the deployment's notes.

Skip condition (ongoing change): upgrading one part is a pin move, not an edit —
read the new revision, recompute its hash at the new commit, confirm the commit
is reachable from the branch the deployment validates on, rebuild from that
part upward in the chain, and re-run `verify-set.sh`.

Verify: `scripts/verify-set.sh` exits 0 with every runnable row passing; the
recorded pins match the images actually running
(`docker image inspect --format '{{index .Config.Labels
"org.opencontainers.image.revision"}}'`).

## Verification and Acceptance

Every row states what it checks and what it expects. Rows that need something a
given host does not have skip with the reason printed; none of them may be
reported as a pass.

- **A-1** (covers R-10): for every `schematic` row in Dependencies, the pinned
  commit exists, is reachable from the checked-out history
  (`git merge-base --is-ancestor <commit> HEAD`), the file exists at that
  commit, and `sha256sum` of that file at that commit equals the hash in the
  row. expected: every pin resolves and matches; a mismatch names the row.
- **A-2** (covers R-2): the glue file's every `services:` entry carries only
  `networks:`, and merging it with the parts' fragments produces a configuration
  whose services are exactly the parts' own — every service in
  `EXPECTED_SERVICES` present, and no service outside that list. expected: the
  composition defines no service, and every service in the merged configuration
  belongs to a part. Stated limit: the "no service outside it" half needs
  `EXPECTED_SERVICES`; without it the row checks that the merge renders and says
  in its own output that completeness was not asserted.
- **A-3** (covers R-3): each part's own acceptance script is present — a script
  named in `PART_SCRIPTS` that is not on disk FAILS the row, the same condition
  the bring-up script's step 9 refuses — and, where this host can run it, exits
  0; where the host cannot run it, the check prints `SKIP` and the reason.
  expected: no part is assembled before it is verified, and every gap is named.
- **A-4** (covers R-1): building the harness layer with its endpoint check
  pointed at an address nothing answers at fails with the layer's own refusal
  code (`78`) and a line naming the parameter — the row supplies every argument
  the build requires for the chosen arm, so a build that failed on a missing
  argument FAILS this row instead of satisfying it. expected: the ordering edge
  is enforced by the part's build when the deployment asks for it (part 3's
  `P-11`), and by this composition's own gate (`A-11`, Phase 3 step 3) either
  way. Stated limit: the build check proves reachability, not alias membership —
  a credential cannot be a build argument (part 3's `R-8`).
- **A-5** (covers R-4, R-6): `docker inspect` on every container of the set,
  read from `docker ps -a` so a stopped container is inspected too — the proxy
  included, when `PROXY_CONTAINER` is supplied — reports no published
  port, no `Privileged`, no added `CapAdd`, no `Devices`, and no bind from
  `/var/run/docker.sock`, with exactly one exception: the proxy's own socket
  mount, which must be the only one and read-only. expected: nothing published,
  nothing privileged, and the socket in the one container whose job it is, under
  the mode the Docker-access part requires. The row asserts the whole set or
  SKIPs: a container the script cannot name, or an inspect it cannot read
  (denied, empty, no `priv=` field), SKIPs the row naming that container —
  a subset inspected is not the set.
- **A-6** (covers R-6): the same inspect output lists exactly one read-write
  host path (the agent tree, equal to `AGENT_TREE_DIR`) plus read-only or secret
  mounts. expected: one stateful path.
- **A-7** (covers R-4): the user reported by the running host container is the
  base's account and the process's own `id -u` is not `0` (`docker inspect …
  '{{.Config.User}}'` and `docker exec … id -u`); the script reads `id -u` in
  every other container of the set too. expected: no container of the set is
  host root. R-4's prohibition is host root, and a uid of `0` **inside** a
  container that holds no host namespace, no socket and no bind of `/` is not
  that — so a container other than the host reporting uid 0 is printed in a note
  rather than failed, naming the two this composition's parts ship that way (the
  Docker-access proxy, whose own `SCHEMATIC.md` states it runs as root inside
  its container, and the router, whose `Containerfile` declares no `USER`). The
  note is there because a deployment should know; the row does not fail them,
  because R-4 does not reach them and `A-5` covers their privileged, capability
  and device half. A uid the script cannot read SKIPs the row naming the
  container — an unread container is not a clean one.
- **A-8** (covers R-7): the harness image reports `AGENT_HARNESS` set, its
  entrypoint and `CMD` are the base image's unchanged, its history carries no
  credential-shaped value, and a
  scan run inside a container made from the image finds no credential-shaped
  file or value in the harness configuration directory or the account's homes.
  expected: one CLI, no credential in the artifact. Stated limit: the filesystem
  scan sees the final image, so a value written in one layer and deleted in a
  later one is absent from it while remaining in the earlier layer's tar — the
  history scan is what covers that case, and neither sees a value assembled at
  build time and never written.
- **A-9** (covers R-7): an agent pane, started through the host's own boot
  program, has the harness CLI as its process, and each such process runs in its
  own agent workspace: the `AGENT_WORKSPACE_DIR` read from that pane's **own**
  process environment (the multiplexer exports one per pane, as its
  `agent-loop.sh` does) ends in `workspace` with a directory name that is one of
  the host's rostered agents, and the pane's working directory equals it — under
  an `AGENT_WORKSPACE_DIR` the row is given, when it is given, rather than under
  a default this composition cannot honour. expected: the pane runs that CLI and
  not a shell wrapper, in the state directory it was given — the harness is what
  the pane's process tree contains, and the tree is where `R-6` says state
  lives. A pane carrying no such variable, or one outside the tree it was given,
  FAILs naming the process.
- **A-10** (covers R-9): the pane's own process environment carries the router
  credential under the name `P-9` resolves to for this arm, and carries no other
  credential-shaped variable — **names only are read, never values**, so a
  second entry in the encrypted store, or a provider key left in the
  environment, shows up here as a failure. The endpoint is deliberately not
  required of the environment: the harness layer writes it into the arm's own
  configuration (`ANTHROPIC_BASE_URL` for Claude Code, `base_url` for Codex),
  which is where the CLI reads it, so the row reads it there and compares it
  against `P-8` (the root, or the root plus `/v1` for Codex). It also checks, at
  that arm's own keys, that the model equals `P-10`'s alias, the fast model
  equals `P-12`'s when the arm has one, every model the configuration names is a
  member of `ROUTER_ALIAS_SET` (`P-11`), Codex's `env_key` is the derived
  credential name, and the configuration names no provider credential or key. A
  `ROUTER_BASE_URL` that **is** present in the environment is compared with
  `P-8`'s root rather than ignored; its absence is a note, because this
  composition's endpoint lives elsewhere and requiring it would fail a set wired
  exactly as specified. expected: the wiring is the one this document specifies,
  read from inside the container that matters and at the keys each arm actually
  uses — a wrong value can no longer satisfy the row the way a string match
  could.
- **A-11** (covers R-9): a request to
  `ROUTER_BASE_URL` + `/v1/models` (P-8 is the router ROOT; the protocol path is
  appended here exactly as the harness layer appends it per arm), made from
  inside the host container — the container the panes run in, and **not** the
  pane's own shell — carries the credential the pane's process itself holds
  (read from that process's environment and used in place, never printed) and
  returns 200 with a body whose `id` values include `ROUTER_ALIAS`; the same
  request without the credential is rejected (401/403). Membership is compared
  against the model list's ids, so an alias that appears only as another field's
  metadata does not satisfy the row. expected: the alias path works end to end
  and the router's own credential gate is intact. Stated limit: a portable check
  cannot drive the CLI's interactive call — that is what `A-9` and `A-10` prove
  — so this row issues the request the way any client of the router does, and
  proves the router's path, the alias and the credential, not the CLI's own
  turn. **If the router credential cannot be
  obtained:** `SKIP` with that reason — never assert.
- **A-12** (covers R-9): with the router stopped, the same request
  (`<root>/v1/models`, issued from inside the host container as `A-11` issues it)
  fails visibly and no completion is produced elsewhere. expected: a failure
  that names the router, not a silent fallback.
- **A-13** (covers R-4): the host container's own environment carries
  `DOCKER_HOST` — read from one of the container's pane processes, falling back
  to its configured environment, never injected by the check — and
  `docker version` through that value answers; a denied verb is
  refused by policy in terms that name the proxy's own decision (any other
  daemon error SKIPs — it is not evidence of a refusal); and the socket path is
  absent from the container's filesystem. It also checks the network contract:
  every network the proxy is attached to reports `internal=true`, and the router
  container cannot resolve the proxy by name while the host container can.
  expected: Docker works through the proxy the deployment wired the container
  to, the socket is not reachable from where the agent runs, and the proxy is not
  exposed to the rest of the set. **Without either `PROXY_CONTAINER` or
  `ROUTER_CONTAINER` the row SKIPs** rather than passing on the half it could
  still read: the proxy's network contract is the point of that half, and a
  green row over an unchecked contract is the failure mode this row exists to
  prevent.
- **A-14** (covers R-8): a container started without its key material exits
  non-zero, and its own output names **the key file it was given** — the probe
  supplies a key path that does not exist, so a message about the encrypted
  store file it also cannot open is not evidence about the key path and is not
  accepted as one. expected: the credential path fails loudly and identifiably.
  The positive half (a container *with* the store reaches its application) is
  Phase 3's verification, because it needs the store prepared to be meaningful.
  **If the probe cannot be created on this host, or the failure does not name
  the key path:** `SKIP` with that reason — an unrelated failure is not evidence
  about the store, and this row never turns one into a pass. The probe runs the
  composition's own boot command — `sops exec-env <file> <program>` — inside the
  harness image, with a key path that does not exist; it needs no store of its
  own, and its log is read while the container still exists so a genuine failure
  cannot be lost.
- **A-15** (covers R-9, R-11): one real completion through the alias returns
  200 **and a completion body** (the `choices` the API contract carries),
  requested with the router credential the pane's own process carries. The
  request itself is issued from the host container, the way any client of the
  router issues one, not from inside an interactive pane — a portable check
  cannot drive one. expected: a real answer, not a simulated one. Stated limit:
  this proves the router's path to its provider and the alias, not the harness
  CLI's interactive call — that is checked by `A-9` and `A-10`. **If no real
  provider credential exists:** `SKIP` with that reason — this row is never
  asserted, and the alias path is still proven by `A-11`.
- **A-16** (covers R-13): after `docker compose down` exits 0, the network is
  gone (its removal is verified, not merely attempted), no container of the set
  remains — running or stopped, the proxy included — every part's own acceptance
  script still runs against its images, and the agent tree directory is
  untouched. expected: removal detaches the composition and changes no part.

## Failure Modes and Rollback

| Phase | What can fail | Detection | Recovery |
|-------|---------------|-----------|----------|
| 1 | A parameter resolves to something the parts reject (an alias not in the set, a base reference that does not resolve) | Phase 1's verification: the reference does not resolve, or the alias set read back differs from the decided list | Fix the parameter, not the part. An alias that the router does not serve is a Phase 3 item; do not build a layer that names it |
| 1 | The agent tree's owner does not match the base's account ids | `stat -c '%u:%g'` differs from part 1's `P-4`/`P-5` | Re-derive the ids from the base image's own build (part 1's phases) and rebuild, or `chown` the tree to match — do both, not one, or a later rebuild reintroduces the mismatch |
| 2 | Two parts declare the same secret name or network | `docker compose config` errors on a duplicate, or a service attaches to the wrong network | Use the service-name-prefixed secret names the store part requires (its `R-7`), and keep one network name (`P-1`) as the single value every service uses |
| 3 | The store or key is missing | The container exits before the application starts (the store part's `R-9`) | Restore the store file and key file, then start again. Do not export the values into the deployment's environment as a workaround: that moves a secret out of the store and into a shell history |
| 3 | The router's alias set is not the decided one | `GET /v1/models` differs from `ROUTER_ALIAS_SET` | Stop here. Fix the router configuration first; a harness built against a different set fails at its own alias check, after a pointless build |
| 4 | The base image cannot be built | The build fails at the architecture guard (`unsupported TARGETARCH ''`) or at a package step | That is a dependency failure (`D-7`, `D-8`), not a composition one: enable BuildKit, or consume a published base instead of building one. Do not force a legacy build |
| 4 | The harness build fails on the alias check | The build's own message names the alias and the set it queried | The alias is not on the router (Phase 3) or the router is not reachable from the build's context. Fix that edge; never relax the check by hand-editing the layer's configuration |
| 5 | The host starts but no agent runs | The pane exits or the host's boot reports a missing harness | The harness layer is not attached, or `AGENT_HARNESS` is unset (part 2's `P-17`): rebuild the layer, or start the host from the harness image, not the host image |
| 5 | An agent has Docker access it should not | The proxy's audit or `A-13` shows a broader allowlist than needed, or a socket appears in a container | Narrow `DOCKER_PROXY_ALLOWLIST` and restart the proxy; a socket mount anywhere in the set is a stop-the-line finding: remove the container that has it |
| 6 | `verify-set.sh` fails on a row that the parts' own scripts pass | The failing row names the container and the check | The glue is wrong, not the parts: re-read the row's contract in `modules/end-to-end-acceptance.md`, then re-check the merged compose configuration (`docker compose … config`) |
| 6 | A part is upgraded and the chain stops working | The failing row names the part | Re-pin, rebuild from that part upward, and re-run the script. A part upgrade is a pin move (Phase 6's skip condition), never an edit inside this package |

Half-applied phases are recognizable because every phase's verify step is a
read, not a mutation: re-running the verify answers whether the phase completed.
Rollback is per phase — remove the network and the glue file (Phase 2), stop the
containers (Phase 5), and leave the images and the parts alone. Removing an
image is safe because nothing in this package names an image that it also built;
the parts built them.

## Removal

1. Stop and remove the set's containers: `docker compose … down`.
2. Remove the composition's glue: delete `skeleton/compose.yaml`'s deployed
   copy from the deployment's directory.
3. Remove the network if nothing else uses it: `docker network rm
   "$AGENT_SET_NETWORK"`.
4. Leave the images: they were built by the parts, and a part's own acceptance
   script still needs them. Removing them is a separate decision.
5. Leave the agent tree directory and its contents. It holds the agents' state;
   nothing in this package deletes it. Removing it is the operator's explicit
   act, after the agents' work has been exported.
6. Confirm clean removal: each part's own acceptance script still runs, and the
   parts' containers are gone (`docker ps` shows none of the set). What was
   added to the host by this package — one compose file, one network — is what
   the removal steps delete.

## Decisions and Open Questions

Decisions:

- 2026-09-19 — **A composition package, not a fifth part.** The set's parts each
  refuse to restate a neighbour's contract, which is what makes them
  independently implementable — and what leaves the ordering edges homeless.
  This package holds exactly those edges, the isolation rules, and one chain
  test; binding principle 8 already defines that shape, so nothing here is a
  new kind of artifact.
- 2026-09-19 — **`restrict-docker-api-access` rather than
  `authorize-docker-requests`.** The host part already names the former as its
  dependency (`D-2` there) and forbids socket mounts (`R-9` there); a
  composition that disagreed with the part it composes would be inventing a
  variant. The former is also the smaller prerequisite (an internal proxy, no
  host root, no PKI), and its deny-by-default allowlist is the property this
  package's isolation rules depend on. The daemon-side alternative is recorded
  as a declinable recommendation (`D-10`) with the case where it wins: policy
  a proxy cannot see, on a host that already runs the mechanism.
- 2026-09-19 — **The store and router precede the harness build, because the
  build reaches for the router.** The layer's endpoint check (part 3's `P-11`)
  runs at build time when the deployment asks for it, and it needs the endpoint
  to answer; treating that as a run-time concern would move a cheap failure to
  the most expensive place. The check proves reachability, not alias membership
  (`A-4`), so membership stays this composition's gate (`A-11`). Phase 3
  therefore completes before Phase 4, and `A-4` asserts the edge by building
  with the router stopped.
- 2026-09-19 — **The completion row skips, never asserts.** A chain test that
  reports a pass it did not obtain is worse than one that admits a gap: `A-15`
  needs a real provider credential and prints `SKIP` with that reason when the
  operator has none, while `A-11` proves the alias path without one.
- 2026-09-19 — **Pins name a commit reachable from the checked-out history.**
  A pin written at a branch tip passes that branch's checks and fails only after
  a squash merge, which has already turned a default branch red. `D-3` therefore
  names the harness layer's **squash commit** `8d87d2a4` — reachable from
  `main` — at v0.2.0, and its hash was recomputed at that commit rather than
  carried over from the branch. The method was control-tested by reproducing the
  value pinned before the move (`d170abc7…` at `2b3e4b08`), because a hash that
  matches nothing is indistinguishable from a hash computed the wrong way.
  Moving a pin is a change to the Dependencies table, not a formality.

Open questions:

- **Q-1**: Should the composition ship a merged compose file for the whole set,
  or only its glue and the merge order (as it does now)? **Default**: glue plus
  the documented merge order. A merged file duplicates the parts' service
  definitions and drifts the moment a part publishes; the merge is one command.
- **Q-2**: Should the composition run the parts' own acceptance scripts as part
  of `verify-set.sh`, or only print how to run them? **Default**: run the ones
  this host can run, print `SKIP` for the rest (as `A-3` does). A chain failure
  whose parts were never verified is the expensive kind to debug.
- **Q-3**: Is one agent id per host the common case, and should the composition
  default to a single agent? **Default**: no default — `AGENT_IDS` is required.
  A composition that invents an agent name makes the first deployment's identity
  a guess, and the host part already refuses to guess a harness.
- **Q-4**: Should the composition manage the parts' image builds, or require
  pre-built images? **Default**: manage them in Phase 4 and accept pre-built
  ones by skip condition. A deployment consuming published images should not
  have to satisfy the base image's build dependencies.

