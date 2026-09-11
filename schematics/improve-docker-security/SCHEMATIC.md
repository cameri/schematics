<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: improve-docker-security
version: 0.1.1
status: published
description: A composition schematic - hardens a Docker host's three weakest points by wiring together three sibling schematics: restrict raw Docker API access behind a deny-by-default proxy, policy-police what the daemon itself may do through OPA authorization, and encrypt every container secret at rest with per-service keys. No images of its own; the glue is the threat model, the deployment order, and the cross-verification between the three.
---

# Schematic: Improve Docker Security (Composition)

This is a **composition schematic**: it deploys no images and defines no
services. It assembles three sibling schematics that each harden one
attack surface of a Docker host, and its content is the glue between
them: the threat model that explains why all three, the deployment order
that avoids deadlock, the parameter reconciliation, and the
cross-verification that proves the three work as one posture.

The three surfaces, and which sibling closes each:

| Attack surface | Without the sibling | Closed by |
|----------------|---------------------|-----------|
| Container → daemon (API access) | Any container with a socket mount is root on the host | [restrict-docker-api-access](#d-2) |
| Client → daemon (unpoliced control) | Every allowed API call is trusted, even destructive ones | [authorize-docker-requests](#d-3) |
| Secrets at rest | Credentials in plaintext `.env` and compose files, one leak reads them all | [encrypt-container-secrets](#d-4) |

## Applicable Context

**Must discover locally:**

- All three dependencies installed and individually verified (their own
  acceptance tests green - composing unverified parts entangles failures)
- Which containers currently mount `docker.sock` (the surface D-2 closes)
- Which clients drive the daemon over TCP/TLS today, if any (decides
  whether D-3 deploys now or is deferred - see Deployment order)
- The host's secret inventory: which services carry credentials in
  plaintext compose/env files (the surface D-4 closes)

**May assume (with risk):**

- The three dependencies came from this catalog, at the pinned commits
  recorded in the dependency table

**Must not change:**

- Anything inside a dependency's package; composition edits the glue,
  never the parts

## Scope

**In scope:**

- The combined threat model and why the three parts are ordered
- Parameter reconciliation across the three (networks, secret naming,
  TLS material)
- The cross-verification: each part's controls must not interfere with
  the others, and together must not leave a bypass

**Out of scope / non-goals:**

- Host hardening beyond the Docker daemon (users, kernel, firewall)
- Image scanning and supply-chain policy (a future sibling could compose
  in here the same way)
- Runtime threat detection

## Requirements

- **R-1**: Every container that needs Docker API access reaches the
  daemon only through the scoped proxy (D-2's R-1/R-2); no socket mounts
  remain on any consumer.
- **R-2**: Docker clients that control the daemon over the network are
  policed by the OPA authorization policy (D-3); the proxy's allowlist
  narrows what a consumer can *request*, OPA narrows what the daemon
  *executes*. The two layers must both be present for network clients -
  neither substitutes for the other.
- **R-3**: All service credentials are deployed via the encrypted-secrets
  pattern (D-4): no plaintext secret file ships in any deployed
  directory, and each service's blast radius is its own key.
- **R-4**: The three parts share one source of truth for every duplicated
  parameter (TLS material paths, network names, secret file names);
  each is declared once in this package's Parameters and referenced by
  the dependencies' own parameters.
- **R-5**: Deployment order MUST avoid the deadlock where the OPA
  listener is down and Docker clients cannot reach the daemon: OPA's
  authorization is configured on the daemon only after the OPA service
  is verified running, and the daemon-config change documents the
  rollback line that disables it.
- **R-6**: The composition MUST verify the parts do not fight: the proxy
  allowlist must not silently authorize groups that OPA would deny
  (defense in depth, not conflicting policy), and the secrets entrypoints
  must keep working for the proxy and OPA services themselves.

## Dependencies

Dependencies of kind `schematic` are pinned: the link targets the file at
a specific commit in the remote repository, and carries the SHA-256 of
the file's contents at that commit, so an implementer can verify the
contract they are reading is the contract the composition was built
against. See the composition-convention module for the full rules.

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | system | Docker Engine + Compose v2 | Runs everything | `docker compose version` | Blocker |
| D-2 | schematic | [restrict-docker-api-access v0.3.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/restrict-docker-api-access/SCHEMATIC.md) `sha256:29951fd2252a342d2863e960b4eaa8095599227d70d7e36694769af84ccaa50a` | Closes container→daemon access (R-1) | Its phases green | Consumers fall back to socket mounts - forbidden (R-1) |
| D-3 | schematic | [authorize-docker-requests v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/authorize-docker-requests/SCHEMATIC.md) `sha256:73a1a2423df279ea1c163ae51496ef12b68882b7801cca819126ad4b192af506` | Polices daemon control (R-2) | Its phases green | OPA down → clients blocked by design; rollback line re-opens |
| D-4 | schematic | [encrypt-container-secrets v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/encrypt-container-secrets/SCHEMATIC.md) `sha256:a776b9b1d34d5fc7883ecee8f7616d39860a9236f5d875dc476013fae413ba45` | Closes secrets at rest (R-3) | Its phases green | Deployment halts rather than falling back to plaintext |

## Parameters

Only the reconciliation surface; the dependencies keep their own.

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | SECURE_NET | string | `docker-security` | This composition | The internal network the proxy (and optionally the OPA sidecar) lives on |
| P-2 | SECRETS_ROOT | path | `${HOME}/sops/age` | D-4's convention | Where per-service age keys live; shared by every service D-4 converts |
| P-3 | TLS_DIR | path | (required if D-3 deploys) | D-3's cert infra | Where daemon + client TLS certs live; OPA reads its own under it |
| P-4 | CONVERT_LIST | list | (required) | Secret inventory discovery | Which services D-4 converts, in dependency order |

## Modules

- **composition-convention**: the rules this package follows for
  schematic dependencies - commit-pinned remote links with content
  SHA-256, contracts not copies, glue-only scope, parts-standalone-first.
- **defense-in-depth-mapping**: which layer answers which attack, and
  why proxy allowlists and OPA policy are different questions (what a
  client may ask vs what the daemon may do).

## Interfaces and Contracts

### Layering contract (the heart of the composition)

```
container ──(scoped allowlist)──► proxy ──► daemon socket
remote client ──(OPA policy)────► daemon TCP/TLS
every service ──(age key)───────► decrypted env in memory only
```

- The proxy narrows *requests*; OPA narrows *executions*; SOPS narrows
  *data at rest*. A compromise of one layer does not widen the others.
- Conflict rule (R-6): if the proxy allowlists a group, OPA policy must
  either allow it for the proxy's consumers or never see those requests
  (the proxy path is the unix socket, not the TLS listener - the layers
  intersect only for network clients). Document any group where both
  layers can see the same request.

### Parameter contract

Every duplicated value flows from this package's Parameters (R-4):
network name P-1 feeds D-2's P-5; SECRETS_ROOT P-2 feeds D-4's per-
service key paths; TLS_DIR P-3 feeds D-3's cert paths.

## Implementation Phases

### Phase 0: Install and verify dependencies in isolation

1. Execute each dependency's phases on its own; each package's
   acceptance set green before any glue (see composition-convention).
2. Verification: three green acceptance lists, no cross-wiring yet.

### Phase 1: Deploy the access-restriction layer (D-2)

1. Follow D-2's phases with the allowlist derived from THIS host's
   consumers.
2. Verification: its audit matrix matches the allowlist; zero socket
   mounts remain (R-1).

### Phase 2: Deploy the secrets layer (D-4)

1. Convert the services in P-4's order, using D-4's per-service pattern
   with keys under P-2.
2. Verification: no plaintext secret file remains in any deployed
   directory; each service healthy after its own conversion (R-3).

### Phase 3: Deploy the policy layer (D-3)

1. Deploy OPA and verify the policy, THEN configure the daemon's TLS
   listener with authorization (R-5's ordering, from D-3's phases).
2. Verification: authorized clients operate; a disallowed operation gets
   the policy denial; the rollback line is documented and tested once.

### Phase 4: Cross-verification

1. Run each dependency's audit/verification against the assembled whole.
2. Verification: the proxy audit still matches (R-6), OPA denies a
   deliberately destructive request from an authorized client, and a
   converted service's process environment shows the secret while its
   disk shows only ciphertext (R-3, live).

## Verification and Acceptance

- **A-1** (R-1): `docker inspect` on every consumer shows no socket
  mount; the D-2 audit matrix matches the allowlist.
- **A-2** (R-2): a network client attempting a policy-denied operation
  receives OPA's denial; the same client's allowed operations work.
- **A-3** (R-3): for each converted service: ciphertext on disk, secret
  present in `/proc/<pid>/environ` only, and per-service age key fails
  to decrypt a neighbor's `.env.encrypted`.
- **A-4** (R-4): changing P-1/P-2/P-3 in this composition's env
  propagates to all three dependencies on recreate; no dependency
  carries its own hardcoded copy.
- **A-5** (R-5): stopping OPA blocks network control of the daemon (fail
  closed); applying D-3's documented rollback line re-opens it, and
  re-applying the daemon config closes it again.
- **A-6** (R-6): the D-2 audit run against the final assembly matches
  the allowlist exactly - the policy layer did not widen the proxy, and
  the proxy did not authorize around the policy.
- **A-7**: every dependency link in the table above resolves at its
  pinned commit and the file's SHA-256 matches the recorded value.

## Failure Modes and Rollback

- **OPA down, clients locked out**: by design (fail closed). Use D-3's
  rollback line, fix OPA, re-enable.
- **A converted service won't boot after secrets migration**: D-4's
  entrypoint contract broken (wrong key file or sops path); check the
  docker logs for the sops error before reverting - revert is documented
  in D-4's rollback.
- **Proxy denies a legitimate consumer**: the allowlist derivation
  missed a group; re-run the scoping derivation, add the group with a
  justification.
- **Rollback**: decompose in reverse order (D-3's daemon config first,
  then D-4 per service, then D-2) - each dependency's own removal
  procedure applies to its part.

## Removal

1. Revert the daemon config (D-3's rollback line) - do this FIRST.
2. Remove the OPA service (D-3's removal).
3. Re-convert or retire services per D-4's removal.
4. Remove the proxy and re-point consumers only if they are being
   retired too; otherwise they return to the socket with a documented
   exception.

## Decisions and Open Questions

Decisions:

- 2026-09-11: The composition exists because the three siblings answer
  three different questions about the same daemon (what may a container
  ask; what may the daemon do; where may secrets rest) and deploying
  one without the others leaves a known hole. The glue is the threat
  model and the ordering; the packages stay authoritative.
- 2026-09-11: Dependency links are commit-pinned with content SHA-256
  (composition-convention): the composition states exactly which contract
  it was built against, and verification is a hash comparison, not a
  trust statement.

Open questions:

- **Q-1**: Whether a fourth sibling (image scanning / supply-chain
  policy) should eventually compose in. Left open until such a package
  exists.
