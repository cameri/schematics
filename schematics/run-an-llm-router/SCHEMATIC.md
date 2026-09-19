<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: run-an-llm-router
version: 0.2.1
status: draft
spec: 1
description: A self-hosted OpenAI-compatible model router — one private /v1 endpoint in front of several BYOK providers, stable model aliases so clients never change when a provider does, provider keys encrypted at rest and decrypted in memory at boot, and a health-gated service clients point at instead of a metered shared provider.
created: 2026-09-14
updated: 2026-09-19
---

# Schematic: Run an LLM Router

> **Reverse-engineered** from a production deployment where this capability
> replaced a metered shared gateway with zero client changes, and where it is
> the single inference path for a fleet's agents. Behaviour was reconstructed
> from the running stack, its configuration, its images, its operational
> notes, and live probes against the running service. Points marked
> `inferred:` were deduced rather than observed; points marked *(observed)*
> were confirmed against the running implementation while writing this.

After implementing this schematic, the host runs **one private, OpenAI-
compatible model router**: clients point at one base URL with one credential
and ask for model **aliases**; the router forwards each alias to exactly one
provider binding, using credentials only the router holds. Provider keys are
encrypted at rest in the repository, decrypted **in memory** at container boot,
and exist only inside the router process. Adding a provider or changing the
model behind an alias is a config edit plus a restart — never a rebuild, never
a client change — because the alias is the contract and the provider is an
implementation detail.

This is the capability that lets an agent, a script, or a service **stop
depending on a metered shared provider** without depending on a different one
instead: it makes the operator's own provider accounts the source of inference,
behind an alias set they control.

**Terms used throughout:**

- **Router**: the proxy process serving the OpenAI-compatible API. The
  reference implementation is LiteLLM; the requirements below are what bind.
- **Provider family**: an upstream API the operator holds credentials for
  (each family has its own base URL, key, and model-id namespace).
- **Alias**: the model id a client sends (`model_name` in the config). It is
  the client-facing contract.
- **Binding**: the provider family + upstream model id an alias resolves to.
- **Router credential**: the single credential clients present. It belongs to
  the router, not to any provider (LiteLLM calls it the master key).
- **Store**: the encrypted key file holding the router credential and the
  provider keys — a dependency of this schematic, not part of it (`D-3`).
- **BYOK**: bring your own key — every upstream call spends the operator's own
  provider credentials, with no public intermediary in the path.

## Applicable Context

**Must discover locally** (with the discovery command/method for each):

- Whether the host already runs an OpenAI-compatible gateway. Discovery: look
  for a service publishing or listening on `P-2`, and grep the host's compose
  files for a `/v1` base URL. A second router on one host splits the client
  base URLs — decide one or the other before building.
- Which provider families the operator holds credentials for, and each
  provider's **API base as the account is provisioned** (`P-9`). Discovery:
  the provider's console or docs, then a direct call with the key *before*
  wiring it into the router — a key that 401s directly will 401 through the
  router too.
- The exact upstream model ids each family serves (`P-10`). Discovery: the
  provider's own `GET /models`, or its docs.
- Which client will consume the router, and what that client calls an
  OpenAI-compatible base URL, credential, and model list (`P-13`).
  Discovery: the client's own configuration surface (`D-4`).
- Whether `D-3` is already implemented on this host (an encrypted store, an
  age key, and its scripts). Discovery: look for an existing `*.encrypted`
  store and a key directory such as `${HOME}/sops/age/`. If it exists, add to
  it; do **not** create a second secret hierarchy.
- Whether clients run on this host or elsewhere (`P-12`, `D-5`). Discovery:
  `docker network ls`, and whether a client container can resolve `P-1`.
- The modes and ownership of the files this deployment mounts for the router
  to read: `P-4` (the alias map) and `P-6` (its age key). Discovery:
  `stat -c '%a %U %n' <path>`. Both MUST be readable by the account the
  container runs as (uid/gid 65532, R-12). A file the operator owns at mode
  0600 is not: the key file then fails decryption with an error that reads like
  a wrong key, and an unreadable alias map exits the proxy.
- The host's outbound HTTPS path to each provider. Discovery: the first
  successful completion in Phase 6 — an egress-restricted host fails there,
  with the provider's error, not at boot.

**May assume** (each with the risk if the assumption is wrong):

- Docker Engine with Compose v2 and file-backed `secrets:` support. Risk if
  wrong: the store and key file must be bind-mounted instead, and their paths
  parameterized (`P-5`, `P-6`).
- At least one provider speaks the OpenAI-compatible chat-completions API.
  Risk if wrong: a provider with its own protocol needs an adapter the router
  may not have; it cannot be served until one exists.
- The router's image contains `python3`. Risk if wrong: the healthcheck in
  `skeleton/compose.yml` must be replaced by one using a tool the image does
  have (the reference image has no `curl`).
- Every client that must use the router is reconfigurable — its base URL,
  credential, and model ids are settable. Risk if wrong: the router can still
  run, but nothing consumes it, and R-11 cannot be satisfied.
- The host can reach the providers over HTTPS. Risk if wrong: allowlist the
  provider hosts; the router is the only place that egress originates.

**Must not change:**

- The credential clients already hold, when this router replaces an existing
  gateway on the same host: adopt it as the router's own credential (`P-7`)
  rather than issuing a new one. Changing it means re-keying every client in
  the same change.
- The provider accounts, their quotas, and their billing: the router spends
  the operator's own credentials and creates nothing upstream.
- Alias ids already in use by clients. Adding an alias is safe; renaming or
  removing one is a breaking change and requires updating its consumers first.
- The `D-3` key hierarchy: this deployment adds one recipient (its own
  per-service key) to an existing store; it never replaces the master key or
  the recipient list.

## Scope

**In scope:**

- The router service: pinned official image, config mount, listen port, health
  endpoint, restart policy, the account its process runs as, and its place in
  the container network.
- The alias → provider map: the entry format, adding, removing, and swapping
  the binding behind an alias, and the no-silent-fallback rule.
- Credential handling: the encrypted store, the router's dedicated key,
  in-memory decryption at boot, the router's own client-facing credential, and
  rotation without a rebuild.
- The client-facing wire contract, plus wiring at least one client end to end
  and removing its metered provider.
- Verification of the model surface, the authentication boundary, the
  credentials at rest, per-alias isolation, and the client path.

**Out of scope / non-goals:**

- Running models locally (GPU inference): the router fronts provider APIs; it
  is not an inference engine.
- Per-client or per-user credentials, budgets, and spend accounting. This
  schematic uses one router credential; issuing keys per consumer is a
  different capability, and its absence is a stated limitation (Q-4).
- Prompt or response logging, caching, moderation, and analytics.
- Public exposure of the router (see `client-wiring.md` for why).
- High availability across hosts: one router instance per host or host group.
- Inventorying which clients still use a metered provider fleet-wide. R-11
  states the rule for the client being wired; sweeping a fleet is an operator
  task, not a phase here.

**Preservation List** *(reverse-engineered)*:

*Must match original behaviour exactly:*

- The client-facing surface is OpenAI-compatible: a models list and chat
  completions under `/v1`, authenticated by one `Authorization: Bearer`
  credential. Clients keep their base URL, credential, and alias ids.
- The router holds the provider credentials; a client never does. Every
  upstream call is made by the router, and every upstream endpoint is one the
  operator configured.
- Aliases are the client-facing ids, and each alias resolves to exactly one
  provider binding. A request is never silently served by a different
  provider — not on error, not on rate limits, not ever.
- Client parameters a bound provider does not support are **dropped, not
  rejected** (the reference sets `drop_params: true`). A client may send a
  superset of parameters and still work against every alias. *(observed: a
  request carrying `store: false` returns 200 through the running router.)*
- Provider keys are decrypted **in memory** at container boot and live in the
  router process's environment; no cleartext store is written to disk, and no
  sidecar holds one. The store and the router's key file mount read-only.
- The router software comes from its **official prebuilt image**, version
  pinned — never installed from a package registry inside the build.
- The router's image is excluded from automatic updates: an unplanned upgrade
  changes the model surface for every client at once.
- The health endpoint is a liveliness probe, separate from readiness, and
  orchestration may gate dependents on it.
- The service publishes **no host port** by default: reachability is through
  the container network, plus a private path when a client is off-host.

*Open to reinterpretation:*

- **The router software.** The reference is LiteLLM and the skeleton is shaped
  for it; R-1…R-11 are what bind. A different OpenAI-compatible router that
  satisfies every requirement is acceptable — but then `skeleton/` does not
  apply and the implementer writes the equivalent compose/config pairs.
- **Where the alias map lives.** This schematic mounts it read-only, so an
  alias change is a restart (R-5); the reference bakes it into the image and
  rebuilds. Mounting is preferred here and changes nothing for clients.
- **Where the router's own credential comes from.** The reference reads it
  from a file on a legacy data volume (a migration artifact); this schematic
  takes it from the store (`P-7`), which is the cleaner form for a new
  deployment.
- **Service name, port, and network name** (`P-1`, `P-2`, `P-11`).
- **Alias id style.** The reference's ids name the provider family; a new
  deployment should prefer ids that do not (Q-5).
- **Who holds PID 1 and how shutdown signals reach the router** (Q-2).
- **The account the container runs as.** The reference runs as root: the pinned
  base image's config states `"User": "root"`, and neither the reference's own
  layer nor its deployment changes it. This
  schematic requires a non-root account and names it (R-12). Nothing on the
  wire changes: no client can see the router's uid.

## Requirements

- **R-1**: The router MUST expose one OpenAI-compatible `/v1` surface serving
  every configured alias, reachable by a client with exactly one base URL and
  one credential.
- **R-2**: Every request MUST be authenticated with the router's own
  credential; provider credentials MUST NOT reach a client, and every upstream
  call MUST go to an endpoint the operator configured explicitly — never to a
  shared or metered intermediary.
- **R-3**: Each alias MUST resolve to exactly one provider binding. The router
  MUST NOT silently substitute another provider, model, or alias for a request
  — including when the bound provider errors, rate-limits, or is unreachable.
  A request that cannot be served by its own alias MUST fail visibly.
- **R-4**: Provider credentials MUST exist at rest only as ciphertext, MUST be
  decrypted in memory at container boot, and MUST NOT be written to the
  container filesystem or held by any sidecar. Only the router's own dedicated
  key may be mounted into its container.
- **R-5**: Changing an alias, adding a provider, or rotating a credential MUST
  NOT require rebuilding the image: a config edit or a store edit plus a
  container recreate suffices.
- **R-6**: The router MUST be reachable by its clients and MUST NOT be
  publicly reachable unless the operator explicitly chooses an exposure. The
  default exposes no host port.
- **R-7**: The router MUST expose a health endpoint that reports liveness and
  that orchestration can gate dependent services on, so nothing that needs
  inference starts before the router can answer.
- **R-8**: Alias identities MUST be stable: swapping the provider family or
  the upstream model id behind an alias MUST NOT change the id a client sends.
- **R-9**: Request parameters a bound provider does not support MUST be
  dropped rather than rejected, so a client may send a superset of parameters
  to every alias (see the Preservation List for the observed behaviour).
- **R-10**: The router image MUST be version-pinned and MUST be excluded from
  automatic image updates.
- **R-11**: Every model role the client needs MUST be served by an alias on
  this router, and the client MUST NOT keep a metered or shared provider as a
  fallback for those roles. When the router is down, the client MUST fail
  visibly rather than silently switch providers.
- **R-12**: The router process MUST NOT run as root. The image MUST state the
  account the process runs as, every file mounted for it to read MUST be
  readable by that account, and the boot MUST need no privilege: the listen
  port is above 1024 (`P-2`). An implementation that keeps any part of the boot
  at uid 0 MUST name that part and the reason it cannot drop the privilege.

**Evidence** (source of each non-obvious requirement, from the implementation
this schematic was reverse-engineered from):

| Req | Evidence |
|-----|----------|
| R-1 | The reference serves every client from one `/v1` base URL behind one bearer credential; the deployment's own notes record "same URL, same auth, same model ids" when the previous gateway was replaced *(observed: `GET /v1/models` returns 15 aliases to one credential)* |
| R-2 | Only the router holds provider keys: the store is mounted into the router alone, and a request with a wrong or absent bearer is rejected `401` *(observed)*. A client-config grep shows no provider key anywhere but the router's store |
| R-3 | Every `model_list` entry names exactly one `model:` target, and the config contains no fallback or model-group-alias setting. An unlisted model id returns `400` from the router rather than being forwarded *(observed)* |
| R-4 | Compose mounts the ciphertext store and a dedicated `*-keys.txt` read-only; the entrypoint exports the decrypted values into the router process's environment. Probing the running container: the decrypted names appear in the **router child process's** environment and the mounted store holds ciphertext only *(observed)* |
| R-5 | The reference's rotation runbook is "set the value in the store, then recreate"; it also records that a plain `docker restart` is not enough, because the store rewrite changes the file's inode and the mounted secret still points at the old one (`provider-credentials.md`). Its config changes additionally rebuild, which this schematic removes by mounting the map |
| R-6 | The reference publishes no host ports; its only exposure is a private overlay route to the container `P-2` *(observed: `docker ps` shows no published port; the service is reachable from the container network and over a private hostname)* |
| R-7 | A healthcheck hits the router's liveliness path every 30 s, and a consumer service declares `depends_on: <router>: condition: service_healthy` *(observed)* |
| R-8 | Alias ids were carried over unchanged across a gateway replacement, with the explicit note that clients needed no change |
| R-9 | `drop_params: true` in the reference config, with the recorded reason: a client sends a parameter some providers do not support, and an earlier gateway rejected it with a 400 *(observed: the same request returns 200 through the router)* |
| R-10 | The pinned `FROM` in the Containerfile plus the auto-updater opt-out label on the service; the notes say the pin is bumped deliberately |
| R-11 | Design requirement of this schematic, stated because the deployment it was derived from exists precisely to remove a metered shared provider from the inference path — its clients still carried per-role providers, some of them metered, which is the failure this requirement prevents |
| R-12 | Measured 2026-09-19 on the pinned base image: its config states `"User": "root"` and no layer above it changes that, so an image built without this requirement runs uid 0 — `docker top` on such a build shows the decrypt wrapper and the proxy as root. The base ships the account to use instead (`nonroot`, uid/gid 65532, with a home directory it owns), and nothing in the boot needs root: the proxy binds `P-2` (4000, above the privileged range) and `sops exec-env` only reads two read-only mounts. Built with `USER 65532:65532`, `docker top` shows both processes as 65532 and the surface answers identically *(observed)* |

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

- Principle 1 binds the **client** side hardest: the wire contract here is
  plain OpenAI-compatible HTTP precisely so no harness or agent is required to
  consume it.
- Principle 3 binds through `D-3`: the key store, its encryption, and its
  editing tooling are a declared dependency, not restated here.
- Principle 9 is the whole point of the alias map: every provider difference
  is configuration in `P-4`, and no phase edits code to add a provider.
- Principle 10: the router is one container plus one config file plus two
  secret mounts — no state beyond that, which is what makes Removal trivial.

## Dependencies

Dependencies of kind `schematic` are pinned: the link targets the file at a
specific commit in the remote repository and carries the SHA-256 of the file's
contents at that commit, so an implementer can verify the contract they are
reading is the contract this schematic was built against. Verify with
`curl <raw-url-at-commit> | sha256sum`.

| Id  | Kind | What | Why needed | Discovery | Failure behaviour |
|-----|------|------|------------|-----------|-------------------|
| D-1 | system | Docker Engine + Compose v2 with file-backed `secrets:` | Runs the router and mounts the store | `docker compose version` exits 0 | Hard fail before Phase 5: without compose secrets, bind-mount the store and key instead and parameterize their paths |
| D-2 | system | Provider accounts the operator controls: one credential, one API base, and the upstream model ids per family (`P-8`, `P-9`, `P-10`) | The router has nothing to route to; BYOK is the point (R-2) | The provider console, then a direct call with the key to confirm the correct API base | Hard fail for that family's aliases: those aliases return the provider's error while other families keep serving. Never remedied by routing them elsewhere (R-3) |
| D-3 | schematic | [encrypt-container-secrets v0.2.1](https://github.com/cameri/schematics/blob/81721d8ff548ad0f4b1477e696b7899d30f999fa/schematics/encrypt-container-secrets/SCHEMATIC.md) `sha256:a776b9b1d34d5fc7883ecee8f7616d39860a9236f5d875dc476013fae413ba45` | Keys encrypted at rest, decrypted in memory at boot, and a per-service key so the router can decrypt nothing else (R-4) | Its own phases green: an encrypted store exists and its editing script runs | Hard fail before Phase 3: the deployment halts rather than falling back to provider keys in plaintext environment variables |
| D-4 | system | A client that can set an OpenAI-compatible base URL, credential, and model ids | Consumes the router; without it R-11 cannot be met | Inspect the client's configuration surface | Degrade: the router serves and passes every acceptance test up to Phase 7; nothing consumes it |
| D-5 | system | A private network path between client and router when they are not containers on one network | Reachability only (R-6) | From the client host, resolve `P-12` and connect to `P-2` | Hard fail for off-host clients only; on-host clients are unaffected |

## Parameters

Every environment-specific value. Referenced by name from prose and code.

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | `ROUTER_SERVICE_NAME` | string | `llm-router` | Choose a name not already used by a host service (`docker ps`) | Compose service/container name, in-network DNS name, and the `depends_on` key consumers use |
| P-2  | `ROUTER_PORT` | integer | `4000` (the reference software's default) | The router's own docs; the healthcheck and the API share it | The port the client base URL names |
| P-3  | `ROUTER_IMAGE` | string | `litellm/litellm:<pinned version>` | The router's official image tags; pick a release, never `latest` | The software version serving every alias; bumping it is a deliberate change (R-10) |
| P-4  | `CONFIG_PATH` | path | `./config.yaml` | Next to the compose file; created from `skeleton/config.example.yaml` | The alias → provider map — the client-visible model surface (R-8) |
| P-5  | `ROUTER_ENV_FILE` | path | `./.env.encrypted` | The store path used by `D-3` on this host | Which provider keys and router credential the router boots with |
| P-6  | `ROUTER_AGE_KEY_FILE` | path | `${HOME}/sops/age/llm-router-keys.txt` | The key directory `D-3` uses for this host; create this router's key there | Decryption at boot; the blast radius of a compromised router container (R-4) |
| P-7  | `ROUTER_MASTER_KEY_ENV` | string | `ROUTER_MASTER_KEY` | Chosen when the store is written; if replacing an existing gateway, reuse the credential clients already hold | The name of the router's own credential inside the store — the only credential a client ever sees (R-1, R-2) |
| P-8  | `PROVIDER_KEYS` | list | *(operator-declared)* | Each provider's console; name them by provider, e.g. `PROVIDER1_API_KEY` | Which provider families can serve, and what `config.yaml` references as `os.environ/<NAME>` |
| P-9  | `PROVIDER_BASE_URLS` | list | *(operator-declared)* | The provider's docs **and** the path the account is provisioned on; confirm with a direct call | Where requests actually go; a wrong or unpinned base moves traffic to a different API version (R-2) |
| P-10 | `ALIAS_SET` | list | *(operator-declared)* | The upstream ids `P-9`'s providers serve, mapped to client-facing ids | What `GET /v1/models` returns and what clients may send (R-1, R-8) |
| P-11 | `ROUTER_NETWORK` | string | `llm-router` | `docker network ls`; create if absent | The reachability boundary: who can talk to the router without any exposure (R-6) |
| P-12 | `EXPOSURE_HOSTNAME` | string | *(empty)* | The private path the operator already runs (tailnet, VPN, or a reverse proxy), if any | Whether off-host clients reach the router, and by what name — empty means on-host clients only |
| P-13 | `ROUTER_BASE_URL` | string | `http://${ROUTER_SERVICE_NAME}:${ROUTER_PORT}/v1` (in-network); `https://${EXPOSURE_HOSTNAME}/v1` off-host | Derived from `P-1`, `P-2`, and `P-12` | What every client sets as its base URL (R-1) |

## Modules

- **router-service** (`modules/router-service.md`) — the container: pinned
  image, config mount, port, health endpoint, restart policy, and the failures
  that hide in a mounted file that does not exist.
- **model-aliases** (`modules/model-aliases.md`) — the alias → provider map:
  one target per alias, no silent substitution, and how adding, swapping, or
  removing an alias works.
- **provider-credentials** (`modules/provider-credentials.md`) — how the two
  classes of credential enter the process, stay out of the image and the
  config, and rotate without a rebuild.
- **client-wiring** (`modules/client-wiring.md`) — the wire contract clients
  consume, reachability, and the rule that removes a metered fallback from the
  client's configuration (R-11).

## Interfaces and Contracts

**HTTP surface** (the whole client contract; nothing else is client-visible):

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `GET` | `/v1/models` | bearer | Returns exactly the `P-10` alias set; a client that discovers models here can treat every id as usable |
| `POST` | `/v1/chat/completions` | bearer | OpenAI-compatible chat completion; `model` is an alias from `P-10` |
| `POST` | `/v1/completions` | bearer | The legacy OpenAI completion route, same alias rule |
| `POST` | `/v1/embeddings` | bearer | Embeddings, same alias rule; the alias must be bound to a provider that serves embeddings |
| `POST` | `/v1/messages` | bearer | **Anthropic Messages** shape — the route a Claude Code client appends to its base URL. Same alias rule, Anthropic request and response shape |
| `POST` | `/v1/responses` | bearer | **OpenAI Responses** shape — the route a Codex CLI lands on, since Codex appends only `/responses` to a base ending in `/v1`. Same alias rule |
| `POST` | `/v1/rerank` | bearer | Reranking, same alias rule |
| `POST` | `/v1/moderations` | bearer | Moderation, same alias rule |
| `POST` | `/v1/images/generations` | bearer | Image generation, same alias rule |
| `POST` | `/v1/batches` | bearer | Batch submission, same alias rule |
| `GET` | `/health/liveliness` | none | Liveness for orchestration (R-7). The reference implementation's path; a different router exposes its own, and `P-2` is what stays fixed |
| `GET` | `/health/readiness` | none | Readiness: the proxy is up and its backing store is connected. The reference answers `{"status":"healthy","db":"connected"}` |

A router that serves a narrower surface is still conformant — the table is the
reference implementation's, and R-1 and R-11 are what every router must meet —
but a deployment that wires a coding-agent CLI to it needs the two protocol rows
above, and they are exactly the rows an OpenAI-only build can silently lack.
A-14 is written as that floor rather than as this table: it fails on the routes a
deployment's clients need and reports the rest, and the two protocol rows are the
ones an OpenAI-only build can silently lack.

- Authentication is `Authorization: Bearer <router credential>` on every
  `/v1` request; a missing or wrong credential is `401` *(observed; the reference
  answers `401` and `scripts/router-verify.sh` accepts `401` or `403`, because a
  router that rejects an unauthenticated request with `403` has registered the
  route just as plainly)*.
- **What a `401` proves, and how this table was measured (2026-09-19):** against
  the reference deployment, every `/v1` row above answers `401` with no
  credential, the two `/health` rows answer `200`, and a path the router does
  not serve answers `404 {"detail":"Not Found"}`. The `404` is the control that
  makes the others evidence: an unregistered path is distinguishable from a
  registered one, so an unauthenticated probe establishes that a route is
  registered rather than that a blanket gate rejected the request — which is how
  this table was established rather than copied from the router's documentation.
- **A client's base URL is `P-13`, or the router root, decided by the path that
  client appends — not by which protocol it speaks.** `P-13` ends in `/v1`. A
  client that appends a bare resource MUST be given `P-13`: the OpenAI family
  (`/chat/completions`, `/models`) and the Codex CLI, which appends `/responses`
  and therefore takes the base that already ends in `/v1`. A client whose own
  appended path already begins with `/v1` MUST be given the **root**
  (`http://<service>:<port>`) — Claude Code, which appends `/v1/messages`; given
  `P-13` it requests `/v1/v1/messages` and gets a 404. Both forms address the
  same server; the only difference is where the client stops. This is the one
  contract detail that has already cost a downstream package a broken build, so
  a client-wiring step reads the suffix the client appends before it writes the
  base URL.
- Whether an alias can *answer* a route is a second question: the alias is bound
  to one provider (R-3), and a provider that does not serve the operation
  returns its own error rather than another provider's success.
- A model id that is not in the alias set is a client error, not a
  passthrough: `400` from the router *(observed)*.
- A provider-side failure is returned as an error naming the provider's
  failure; it is never converted into another provider's success (R-3).
- Request and response bodies are the standard OpenAI chat-completion shape.
  Streaming (`"stream": true`) is part of that shape and passes through.
- Response `model` may name the alias or the upstream id depending on the
  router implementation: clients MUST NOT depend on which *(observed both)*.

**Config file** (`P-4`): YAML, `model_list` entries of
`{model_name, litellm_params{model, api_base, api_key}}` plus
`litellm_settings.drop_params: true`. Full field contract in
`skeleton/config.example.yaml.schema`. The file contains no credential — only
`os.environ/<NAME>` references.

**Process environment of the router** (produced by the boot wrapper, consumed
by the config): the provider keys named in `P-8`, plus the router credential
from `P-7`'s store entry, exported as the router software's master key.

**Process identity:** the whole chain runs as one non-root account, uid/gid
65532 (`nonroot`) — the decrypt wrapper, the proxy, and anything `docker exec`
starts inside the container, since exec takes the image's account unless told
otherwise. No privilege is used at runtime: the proxy binds `P-2`, above the
privileged range, and the wrapper only reads mounts (R-12). A `docker exec`
therefore reads the router child's `/proc/<pid>/environ` (same account), which
is what A-6 relies on.

**Compose contract:** service `P-1` on network `P-11`, no published ports;
secret `router-env-encrypted` mounted as `router-secrets.env` (the `.env`
extension is what makes the decryption tool detect the store format) and
secret `router-age-keys` mounted as `age-keys` with `SOPS_AGE_KEY_FILE`
pointing at it.

**Client contract:** base URL `P-13`, credential from `P-7`, model ids from
`P-10`, and nothing else. Any client that speaks OpenAI-compatible HTTP
integrates without router-specific knowledge.

## Implementation Phases

Phase order matters in one direction only: the store (2) and the map (3) must
exist before the service starts (5), because a service that starts without
them fails in ways that look like network problems.

### Phase 1: Discovery and decisions

Goal: resolve every `Must discover locally` item and fix the parameter values
before anything is built.

Steps:
1. Check for an existing gateway on this host (see Applicable Context) and
   decide whether this is the host's single router or a second one.
2. Collect `P-8`/`P-9`/`P-10`: for each provider family, a credential, the API
   base as the account is provisioned, and the upstream model ids.
3. Choose the alias set (`P-10`) and the client-facing credential name
   (`P-7`). If an existing gateway's credential is being adopted, record that
   it stays the same.
4. Choose `P-1`, `P-2`, `P-11`, and whether off-host clients exist (`P-12`).
5. Identify the first client to wire (`D-4`) and how it configures a provider.

Skip condition: none — this phase is discovery; re-running it re-confirms.
Verify: every parameter has a value, and every provider's credential has been
confirmed with one direct call to that provider (a key that fails directly
fails through the router too).

### Phase 2: The encrypted key store

Goal: the router's credential and every provider key exist as ciphertext, and
only the router can decrypt them.

Steps:
1. Implement `D-3` on this host if it is not already implemented, following
   that schematic — do not improvise a secret layout here.
2. Create this router's dedicated key (`P-6`) using `D-3`'s tooling, and add
   it as a recipient of the store (`P-5`) alongside the existing master
   recipient.
3. Write the router's own credential (`P-7`) and every provider key (`P-8`)
   into the store with `D-3`'s value-setting script — values over stdin, never
   on a command line.

Skip condition: an existing store already carrying these names — re-running
overwrites the same entries idempotently.
Verify: a decrypt of the store shows the key **names** (never print values),
and the store's recipient list includes this router's key.

### Phase 3: The alias map

Goal: `P-4` describes every alias, each bound to exactly one provider target.

Steps:
1. Copy `skeleton/config.example.yaml` to `P-4`.
2. Replace the placeholders: one entry per alias (`P-10`), with the family and
   upstream id as `model:`, the family's base as `api_base:`, and the key name
   as `api_key: os.environ/<P-8 name>`.
3. Keep `drop_params: true` (R-9). Do not add fallbacks, retries across
   providers, or model-group aliases (R-3).

Skip condition: the file already describes the same alias set — editing it is
idempotent.
Verify: the file parses as YAML, every `api_key` value starts with
`os.environ/`, and the alias names match the set clients will send.

### Phase 4: The image

Goal: a router image carrying the pinned upstream version and the decryption
binary, with no package-manager step.

Steps:
1. Copy `skeleton/Containerfile` and `skeleton/entrypoint.sh` next to the
   compose file.
2. Set `P-3` in the `FROM` line to the chosen release.
3. Build it.

Skip condition: an image with the same pin already exists
(`docker image ls`); rebuilding is cheap, so this is safe either way.
Verify: the build exits 0, the decryption binary runs inside the image, and the
image states the account it runs as (R-12):
`docker image inspect <the image built in step 3> --format '{{.Config.User}}'`
prints it — never empty, never `root`.

### Phase 5: The service

Goal: the router runs, publishes nothing, and reports healthy.

Steps:
1. Copy `skeleton/compose.yml` next to the Containerfile.
2. Set the parameters it interpolates (`P-1`, `P-2`, `P-4`, `P-5`, `P-6`,
   `P-7`, `P-11`).
3. Bring it up.

Skip condition: it is already up with the same inputs — `compose up -d`
converges.
Verify: the resolved compose file shows the expected secret paths and no
published ports (`docker compose config`); the container reaches healthy; and
the running processes are that non-root account rather than uid 0
(`docker top <P-1>`, A-15). A service that reaches healthy has thereby read both
mounts as that account, which is the readability half of R-12.

### Phase 6: Serve and verify the surface

Goal: prove the model surface, the auth boundary, and per-alias isolation.

Steps:
1. Confirm the credential works and the alias set is exactly right (A-1).
2. Run one real completion per alias (A-4) — this is the check that proves the
   binding, the base URL, and the credential together.
3. Confirm the negatives: no credential and a wrong credential are rejected
   (A-3), an unlisted model id is an error (A-4), and a provider failure is
   confined to its own aliases with no substitution (A-5).

Skip condition: the checks are read-only apart from spent tokens; re-running
is the normal way to verify a change.
Verify: `scripts/router-verify.sh` reports no failures.

### Phase 7: Wire the first client

Goal: one real client draws inference through the router, and keeps no
metered fallback.

Steps:
1. Set the client's OpenAI-compatible provider to `P-13` with the `P-7`
   credential and the `P-10` alias set; declare token limits client-side where
   the client needs them (see `modules/client-wiring.md`).
2. Point every model role the client uses at an alias, and **remove** its
   metered or shared provider for those roles (R-11).
3. Complete a real request through the client (A-10), then stop the router and
   confirm the client fails loudly instead of switching providers (A-11).
4. Start the router again and confirm the client recovers with no config
   change.

Skip condition: re-applying the same client configuration converges.
Verify: A-10 and A-11 as described.

### Phase 8: Reachability for off-host clients (conditional)

Goal: clients not on the router's network reach it over a private path, and
only over that path.

Steps:
1. If every client is a container on `P-11`, skip this phase entirely.
2. Otherwise, put the private path in place — the operator's existing tailnet,
   VPN, or a reverse proxy on that private network whose upstream is
   `http://<P-1>:<P-2>` on `P-11` — and set `P-12`.
3. Confirm the path works from a client host (A-9) and that the router remains
   unpublished.

Skip condition: `P-12` empty.
Verify: a client host resolves `P-12` and completes a request through it,
while the router host still publishes no port.

### Phase 9: Ongoing operations

Goal: the two routine changes are a runbook, not an improvisation.

Steps:
1. **Rotate a provider key**: set the new value in the store, recreate the
   container (not a plain restart — see `provider-credentials.md`), then run
   the completion check for that provider's aliases only.
2. **Change an alias**: edit `P-4`, recreate, run A-1 and the completion check
   for the changed alias.
3. **Add a provider family**: add its key name and value to the store, add its
   entries to `P-4`, recreate.
4. Re-run the full verification after any change.

Skip condition: all steps are idempotent.
Verify: the specific checks named above pass.

## Verification and Acceptance

One test per requirement minimum. All of them are runnable by the implementer
after the phases. `scripts/router-verify.sh` implements A-1, A-2, A-3, A-4's
negative, A-6, A-14, A-15, and the R-9 check mechanically:

```
ROUTER_BASE_URL=<P-13> ROUTER_API_KEY_FILE=<file with the P-7 credential> \
EXPECTED_ALIASES=<P-10, comma-separated> \
ROUTER_CONTAINER=<P-1> STORE_PATH=/run/secrets/router-secrets.env \
scripts/router-verify.sh
```

- **A-1** (covers R-1, R-8): `GET /v1/models` with the router credential
  returns exactly the `P-10` alias set — no more, no fewer. expected: the
  served set equals the declared set.
- **A-2** (covers R-7): `GET /health/liveliness` returns 200, the container
  reaches `healthy` within its `start_period`, and any service configured
  `depends_on` the router starts after it is healthy. expected: 200 and
  `healthy`.
- **A-3** (covers R-2): a `/v1` request with no credential, and one with a
  wrong credential, are both rejected. expected: `401` (or `403`) for both,
  never a completion.
- **A-4** (covers R-3, R-8): one real completion per alias returns a 200 with
  non-empty assistant text; a request for a model id that is not in the alias
  set is refused. expected: a completion for every declared alias; a 4xx for
  the unlisted id.
- **A-5** (covers R-3): with one provider family's credential deliberately
  invalidated (temporarily — in a scratch copy of the store, or by rotating
  that provider to a wrong value and rotating back), that family's aliases
  fail and **every other alias still completes**. expected: failures confined
  to the affected aliases, no other provider answering for them. *(The
  reference deployment exhibits exactly this shape in production: one family
  returning `401 Authentication Failed` while three aliases of another family
  and two of a third complete normally.)*
- **A-6** (covers R-4): the mounted store file inside the container is
  ciphertext — the router credential does not appear in it; no other file in
  the container filesystem holds it; and the decrypted names appear in the
  **router process's** environment only. expected: ciphertext at rest,
  plaintext only in the router process. Inspect the process chain with:
  `docker exec <P-1> sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline | grep -q <router binary> && tr "\0" "\n" < $p/environ | cut -d= -f1; done'`
  (names only — never print values). Note: the *container's* PID 1 is the
  wrapper, whose environment is the container config, not the decrypted set
  (Q-2).
- **A-7** (covers R-5): rotate one provider key in the store, recreate the
  container, and re-run that provider's completion check; then change one
  alias's binding in `P-4`, recreate, and re-run A-1 and that alias's
  completion. expected: both pass with no image rebuild and no client change.
- **A-8** (covers R-6): the service publishes no host port (`docker compose ps`
  and `docker inspect` show no host binding), and a connection to `P-2` on the
  host's own external address is refused while the in-network URL works.
  expected: no published port; in-network reachability only.
- **A-9** (covers R-6, D-5, conditional): from a client host that is not on
  `P-11`, the private path (`P-12`) resolves and serves `/v1/models`.
  expected: reachable over the private path; still unpublished publicly.
- **A-10** (covers R-1, R-11): the wired client completes a real request end
  to end using an alias. expected: a successful response, and the router's
  logs show the request arriving from that client.
- **A-11** (covers R-11): with the router stopped, the client's request fails
  visibly and **no completion is produced by any other provider**; after the
  router is started again, the same request succeeds with no config change.
  expected: a loud failure while down, recovery without edits. A silent
  success while the router is down means a fallback provider is still
  configured — remove it.
- **A-12** (covers R-10): the running image's tag matches `P-3` and the
  auto-updater opt-out label is present. expected: the pin holds.
- **A-13** (covers any `schematic` dependency): the `D-3` link resolves at its
  pinned commit and the file's SHA-256 matches the recorded value. expected:
  `curl <raw-url-at-commit> | sha256sum` equals the recorded digest.
- **A-14** (covers R-1, R-11): the route table is registered, checked as the
  conformance FLOOR rather than as the reference's whole surface — a router that
  serves a narrower surface is still conformant, so only the routes a
  deployment's clients actually need may fail. An unauthenticated request to
  each `/v1` row answers `401`, the two `/health` rows answer `200`, and a path
  the router does not serve answers `404` — measured against the reference
  deployment on 2026-09-19: ten `/v1` routes `401` (one `GET`, nine `POST`), two
  `/health` routes `200`, `/v1/bogus-route-xyz` `404`, so the answers are
  distinguishable and a `401` is evidence of registration.
  `scripts/router-verify.sh` runs this row mechanically. expected:
  `/v1/models`, `/v1/chat/completions`, and the protocol route of every client
  family the run declares in its `CLIENT_ARMS` input (default `claude,codex`;
  `/v1/messages` for a Claude-family client, `/v1/responses` for a Codex-family
  one) answer `401`, and an unknown path answers `404`. So a router built for
  one protocol FAILS for the family it does not serve — the failure this row
  exists to catch — while a router that serves that family and omits the rest of
  the table is reported, not failed. The `404` control is probed with `GET` as
  well as `POST`, so method-specific `404` handling cannot carry it.
- **A-15** (covers R-12): the container's configured account is stated and is not
  root, and every process running inside it is that account. expected:
  `docker inspect --format '{{.Config.User}}' <P-1>` prints a non-root account
  and `docker top <P-1>` shows its uid in every row — never `root` or `0`.
  Two checks because either alone is silenceable: the configured account is what
  the deployment asked for, the running uids are what it got. The second check
  **compares** them — every identity `docker top` reports is resolved to a uid
  and must equal the configured account — so a non-root account that is not the
  stated one fails as well; a deployment whose account and behaviour disagree is
  exactly the case a check for "not root" alone lets through. Names resolve
  against the running host's passwd, the database `ps` read them from, so a name
  and its number compare equal; an account this host cannot resolve is reported
  as a failure rather than assumed to match. Groups are outside the check:
  `docker top` prints no gid, so only the uid is compared. A root container
  passes A-1 and A-2 unharmed, so nothing else in this section catches it, and
  the health state carries the readability half — a container that reached
  healthy read `P-4` and the mounted store as an account, which is only possible
  if that account can read them. `scripts/router-verify.sh` runs the row
  mechanically when `ROUTER_CONTAINER` is set, as for A-6.

## Failure Modes and Rollback

| Phase | What can fail | Detection | Recovery |
|-------|---------------|-----------|----------|
| 1 | A provider key is invalid, or the API base is not the one the account is provisioned on | The direct call in Phase 1's verification fails | Fix the credential or the base before building anything; the router cannot fix either |
| 2 | The store is created with the wrong recipients, or the router's key is unreadable inside the container | The container exits at boot with a decrypt error — and when the cause is the file's mode, the error reads as a **wrong key**, because the decrypt tool skips a key file it cannot open rather than reporting it | Re-add the recipient with `D-3`'s tooling; check the key file's mode and owner against the container's user (uid 65532, R-12) — the mounted key must be readable by that account, and `D-3`'s `P-8` is what decides that mode |
| 3 | An alias is bound to a provider the store has no key for | That alias 401s at request time while others work (A-5's shape) | Add the missing key name and value, recreate |
| 3 | An `api_base` is wrong or unpinned to a different API version | That family's aliases fail with the provider's error | Correct the base; the alias id does not change |
| 4 | The build fails (bad pin, or the base image changed) | `docker build` exits non-zero | Fix the pin; never remove it to "make it build" |
| 4 | The image states no account, or the deployment overrides it, so the router runs as root | A-15: `docker top <P-1>` shows uid 0 | Add `USER <uid>:<gid>` to the Containerfile — or `user:` to the service, when `P-3` names an image this package did not build — then rebuild and recreate. Never fix it by removing the check |
| 5 | `P-4` or `P-6` is not readable by the container's account (mode 0600, owner the operator) | The boot fails loudly rather than silently: an unreadable `P-6` leaves the decrypt tool with no usable key (`no master key was able to decrypt the file`), and an unreadable `P-4` exits the proxy with `PermissionError: [Errno 13]` | Make the file readable by uid 65532 — `chmod 0644`, per `D-3`'s `P-8` for the key. Never run the container as root to make a mode work: that trades a one-line permission fix for exactly the exposure R-12 exists to prevent |
| 5 | `P-4` does not exist on the host: compose creates a **directory** at the mount point and the router boots with an empty model surface | A-1 fails while the container reports healthy | Create the file and recreate; this is the quietest failure in the schematic |
| 5 | A secret name collides with another service's in a merged compose project and the wrong key file mounts | The container exits with a decrypt error that names the file, not the collision | Keep the `P-1`-prefixed secret names from the skeleton; never rename them to generic ones |
| 6 | A provider family fails wholesale (expired or mis-copied credential) | A-4 fails for that family only | Rotate that key (Phase 9); expect other families to be unaffected |
| 7 | The client keeps a metered fallback, so failures are invisible | A-11 succeeds while the router is down | Remove the fallback provider for those roles (R-11); re-run A-11 |
| 8 | The private path is misconfigured, or the router accidentally becomes public | A-9 or A-8 fails | Fix the proxy/tailnet route; verify A-8 again — a publicly reachable BYOK gateway is a credential-guessing surface and a metered one |
| any | A half-applied change: config edited but not recreated, or store edited but only restarted | The old behaviour persists with no error | Recreate, then re-run the affected checks: `docker compose up -d --force-recreate <P-1>` |

Rollback of the whole capability is Phase order reversed, and it is safe at
any point: the router holds no state of its own, so stopping it removes
nothing but inference. Restore each client's previous provider configuration
in the same change that removes the router, or the client loses inference
entirely (see Removal).

## Removal

Steps, in order:

1. Point every wired client back at whatever it used before — or at nothing,
   if the router replaced a metered provider and there is nothing to fall
   back to. Do this in the same change as step 2, so no window exists in which
   a client has neither.
2. Stop and remove the service and its network:
   `docker compose down` (add `--rmi local` only if the image is not needed
   elsewhere).
3. Delete the router's entries from the store, and remove the router's key
   from the host's key directory.
4. Remove the router's recipient from the store's recipient list (only if the
   store is used by other services — otherwise remove the store with `D-3`'s
   own removal procedure).
5. **Rotate every provider credential that was in the store, at the
   provider.** A credential that has been decrypted into a running container
   is treated as exposed on removal.
6. Confirm clean removal: the container and network are gone, no published
   port remains, no client still points at `P-13`, and the store no longer
   holds the router's keys.

Nothing in the host's filesystem is owned by this schematic: `P-4` and the
store are files the operator created, and they stay until the operator deletes
them. The image is rebuildable from `skeleton/` and can be dropped with
`docker rmi`.

## Decisions and Open Questions

Decisions:

- 2026-09-14 — Reverse-engineered rather than invented: the capability runs in
  production on the authoring host, so requirements came from observed
  behaviour (the Evidence table under Requirements names the source of each)
  and every reconstruction is marked `inferred:` or *(observed)*.
- 2026-09-14 — **The key store is a dependency, not part of this schematic.**
  `D-3` already publishes the encryption, key hierarchy, and store-editing
  tooling; restating it here would duplicate a published contract and let the
  two drift. This package states only how the router *consumes* it.
- 2026-09-14 — **No silent fallback is a requirement (R-3), not a
  preference.** A router that quietly fails over to whatever is available
  defeats the reason this capability exists: knowing which provider served a
  request and spending only the credit the operator chose. The reference
  config carries no fallback setting, and this spec forbids adding one.
- 2026-09-14 — **The alias map is mounted, not baked into the image** (R-5).
  The reference bakes it and rebuilds for each change; mounting makes an alias
  change a restart. Clients see no difference, and the change removes a build
  step from routine operations.
- 2026-09-14 — **The router's credential comes from the store** (`P-7`). The
  reference reads it from a file on a legacy data volume, which exists to keep
  a pre-existing credential stable across a migration — worth doing during a
  migration (adopt the client's credential, change nothing client-side) and
  worth not doing in a fresh deployment.
- 2026-09-14 — **Client wiring is in scope** even though it edits no container
  here. The capability is only complete when something uses it, and R-11 —
  removing the metered fallback — can only be satisfied at the client. The
  scope line is drawn at one wired client, not a fleet sweep.
- 2026-09-14 — **One router credential; no key issuer.** Virtual keys, budgets,
  and per-consumer credentials are deliberately out (Q-4): they change the
  trust model (the router becomes an authorization boundary, not just a
  routing one) and deserve their own schematic.
- 2026-09-17 — Schematic dependencies are pinned to commit `81721d8` (the full
  sha is in the link) with the SHA-256 of the file at that commit. Verify a
  pin with `curl -s https://raw.githubusercontent.com/cameri/schematics/81721d8ff548ad0f4b1477e696b7899d30f999fa/schematics/encrypt-container-secrets/SCHEMATIC.md | sha256sum`: take the sha and the path from the pin's own link (here `encrypt-container-secrets v0.2.1`)
  and compare the result with the digest in the table.

- 2026-09-19 — **The container runs as the base image's own non-root account,
  and the package states it (R-12).** Measured: the pinned base image's config
  says `"User": "root"`, so a build that does not state an account runs a
  network-facing proxy — holding every provider key in its process environment
  — as uid 0 by inheritance rather than by decision. The account is
  the base's `nonroot` (uid/gid 65532, with a home directory it owns), not a
  number invented here, and nothing in the boot needs root. The price is a mode
  rule the operator now has to satisfy: files mounted for the router must be
  readable by that uid, which is the same number `D-3`'s `P-8` already keys the
  key file's mode on — so the two packages resolve to one stated answer instead
  of leaving "the container's user" undefined in both.

Open questions:

- **Q-1**: Does the router's built-in registry know the token limits and cost
  of every upstream model in `P-10`? Providers add models faster than routers
  map them, and an unmapped model still serves but reports no limits.
  **Default**: assume not for any model newer than the pinned router release;
  declare context window and max output tokens in the *client's* model list
  (`modules/client-wiring.md`), and treat the router's metadata as unknown.
- **Q-2**: Who holds PID 1 in the router container, and does the decrypt
  wrapper forward `SIGTERM` to the router process? *(observed: the decryption
  tool `exec-env` forks rather than execs, so the wrapper stays PID 1 and the
  router is its child; consequently a `docker exec` into the container does
  **not** see the decrypted environment — docker builds that from the
  container config.)* What is not confirmed is graceful shutdown.
  **Default**: accept a slower `docker stop` and verify it by timing one; if
  shutdown latency matters, revisit the wrapper (e.g. decryption performed by
  an init step that execs the router), and record the tradeoff — the
  in-memory decryption pattern is worth more than a fast stop.
- **Q-3**: One router per host, or one shared by a group? **Default**: one per
  host; sharing works over the private path (Phase 8) but concentrates every
  client's availability on one container, which is a decision, not an
  accident.
- **Q-4**: Should the router issue per-client credentials, with budgets?
  **Default**: no. One credential until a second consumer makes accountability
  necessary; then it is a new schematic, because the review questions change
  (who may spend, how much, and what is logged).
- **Q-5**: Should alias ids name the provider family (as the reference's do) or
  hide it? **Default**: hide it — an id like `glm-5.3-flash` tells every client
  which vendor is behind it and makes a provider migration look like a client
  change. Keep existing ids when migrating (R-8); choose provider-free ids for
  new deployments.
