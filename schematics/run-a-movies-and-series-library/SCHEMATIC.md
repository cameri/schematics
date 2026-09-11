<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: run-a-movies-and-series-library
version: 0.2.1
status: published
description: A composition schematic - runs a complete movies-and-series library by wiring the fetching half (Prowlarr, Sonarr, Radarr, Bazarr, SABnzbd, unpackerr) to the serving half (Jellyfin, Jellyseerr) through the shared media tree, with the request flow closing the loop from "I want to watch X" to "X is playing". Recommended but optional: hardening the Docker host and keeping deployments current. No images of its own; the glue is the loop, the ordering, and the cross-verification.
---

# Schematic: Run a Movies-and-Series Library (Composition)

A **composition schematic**: no images, no services of its own. It
wires two sibling packages into the loop that defines the job:

```
request (Jellyseerr) ──► grab (Sonarr/Radarr via Prowlarr) ──►
download (SABnzbd) ──► import in place ──► serve (Jellyfin) ──► watch
```

The glue is: the end-to-end loop as one acceptance test, the parameter
reconciliation between the halves, the deployment order, and the
recommended (optional) hardening dependencies.

## Applicable Context

**Must discover locally:**

- Both dependencies installed and individually verified (parts pass
  alone first - see the composition-convention module)
- The shared media tree both halves mount
- The exposure choice for the serving half

**May assume (with risk):**

- Both dependencies came from this catalog at the pinned commits

## Scope

**In scope:**

- The request-to-watch loop as the composition's core contract
- Parameter reconciliation (media tree, path contract, API keys)
- Deployment order and the combined runbook
- Recommended optional dependencies and where they attach

**Out of scope / non-goals:**

- Any service, image, or network of its own
- Re-stating the dependencies' requirements

## Requirements

- **R-1**: Both halves reference the SAME host media tree (the path
  contract of `fetch-over-usenet` holds stack-wide); the server's
  library roots are the arrs' import targets, byte-for-byte.
- **R-2**: The full loop is hands-off: a request raised in Jellyseerr
  reaches the playing state with no manual file operations.
- **R-3**: Cross-half API keys (Jellyseerr → Radarr/Sonarr) follow the
  fetching stack's key rules (R-5 there): generated, uncommitted.
- **R-4**: Parameters duplicated between the halves (media root, uid,
  TZ) come from ONE source included by both stacks; they cannot drift.
- **R-5**: Deployment order: fetching half first (it creates the tree
  shape), then serving half, then the request front wired last (it
  needs both).
- **R-6**: With every recommended dependency declined, all required
  phases and acceptance tests still pass.

## Dependencies

Dependencies of kind `schematic` are pinned to a specific commit with
the file's content SHA-256 (composition-convention, rule 2).

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | system | Docker + Compose v2 | Runs both halves | `docker compose version` | Blocker |
| D-2 | schematic | [fetch-over-usenet v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-over-usenet/SCHEMATIC.md) `sha256:bef7d4c87fa7227f5f6d9653365a1ab66f6e7429978e8ef221939cf772ea64a3` | The shared downloading infrastructure | Its phases 1-3 green | Blocker: nothing to grab with |
| D-3 | schematic | [fetch-movies-over-usenet v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-movies-over-usenet/SCHEMATIC.md) `sha256:372c9af317196df3ef6a71f42151aaa0076eb47c6cfad7d6123f90e3af55ca64` | Acquires movies | Its phases 1-2 green | Series-only fetching |
| D-4 | schematic | [fetch-series-over-usenet v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-series-over-usenet/SCHEMATIC.md) `sha256:06b6fc8df40c70568be9323a8a670746e8c1ebbaefa166628b98accaf8c12d28` | Acquires series | Its phases 1-2 green | Movies-only fetching |
| D-5 | schematic | [serve-movies-and-series v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/serve-movies-and-series/SCHEMATIC.md) `sha256:384ec85884529472943287701cc9912eeceedd4fa53591d77a7fd45a6c3745ce` | Serves content, takes requests | Its phases 1-2 green | Fetching continues; nothing watchable |

## Recommended

Optional schematic dependencies, pinned the same way. Declining any of
them leaves every requirement above satisfiable (R-6).

| Id  | Kind | What | Adds | Without it |
|-----|------|------|------|------------|
| RD-1 | schematic | [improve-docker-security v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/improve-docker-security/SCHEMATIC.md) `sha256:08b9f072a0a96047fcce8036c519d61e5b76b9fd02c98b1ce85ed43324ff153b` | Hardens the Docker host this stack runs on: scoped API access, OPA-policed control, encrypted secrets (including this stack's many API keys, R-3's rule enforced mechanically) | The stack works, but socket-mounting consumers and plaintext keys remain accepted risk |
| RD-2 | schematic | [update-images-on-push v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/update-images-on-push/SCHEMATIC.md) `sha256:810129ef2839e77f88b469601e494e6367a9cc5afd1b1c904fb9e1fe37705067` | Keeps the images current from git pushes without cron-based full-socket updaters | Manual or watchtower-style updates |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MEDIA_ROOT | path | `/media` | One shared value | Feeds fetch P-1/P-2/P-3/P-4 and serve P-1 (must be equal, R-4) |
| P-2 | EXPOSURE | enum | per serve P-2 | Operator choice | Passed to serve P-2 |
| P-3 | PUID/PGID/TZ | int/str | 1000, host tz | Host facts | One env file feeding both halves (R-4) |

## Modules

- **the-loop**: the request-to-watch cycle as a chain of contracts,
  and where it commonly breaks.
- **recommended-attachments**: where RD-1 and RD-2 attach to this
  stack's phases, and what declining them means operationally.

## Interfaces and Contracts

### The loop contract (R-2)

Request → arr queue → SABnzbd → import → scan → playable. Each arrow
is an existing contract in a dependency; the composition adds no arrow
and forbids bypasses (Jellyseerr never writes files; SABnzbd never
imports into libraries; Jellyfin never requests grabs).

### The parameter contract (R-4)

MEDIA_ROOT, uid/gid, TZ: declared once (P-3), referenced by both
halves. Any new duplicated value joins this table, not a compose line.

## Implementation Phases

### Phase 0: Install dependencies in isolation

1. Execute D-2's and D-3's phases separately; each acceptance set
   green before glue.
2. Verification: two green lists, no cross-wiring.

### Phase 1: Reconcile parameters

1. One env file for both stacks: MEDIA_ROOT, PUID/PGID, TZ (R-4).
2. Verification: `docker inspect` across both halves shows identical
   bind sources and uid.

### Phase 2: Wire the loop (fetching first, per R-5)

1. Confirm the fetching half's imports land in the tree the serving
   half reads (R-1); attach Jellyseerr to Jellyfin, Radarr, Sonarr.
2. Verification: the full loop (R-2) - request to playing, hands off,
   file byte-identical at the end.

### Phase 3 (recommended): attach RD-1, RD-2

1. Execute improve-docker-security's phases against this host; its
   secrets pattern subsumes this stack's API keys.
2. Execute update-images-on-push for the images this stack runs that
   come from a registry you push to.
3. Verification: their own acceptance sets green; this composition's
   A-1..A-4 still pass unchanged afterward (the hardening did not
   break the loop - e.g. the scoped proxy allowlist covers Jellyseerr's
   arr calls and any Docker-API-using member).

## Verification and Acceptance

- **A-1** (R-1): both halves' binds resolve to identical host paths;
  `stat` agrees on inodes.
- **A-2** (R-2): one full request-to-watch cycle completes hands-off.
- **A-3** (R-3): no API key in any committed file; keys per pair.
- **A-4** (R-4): changing P-3's env moves both halves together.
- **A-5** (R-5): a scripted down-up follows the documented order and
  the loop still completes.
- **A-6** (R-6): with RD-1/RD-2 declined, A-1..A-5 pass.
- **A-7**: every dependency and recommended link resolves at its
  pinned commit and hashes match.

## Failure Modes and Rollback

- **Request stalls in the arr**: indexer or profile problem (fetching
  half's runbook).
- **Downloaded but not served**: path contract drift between halves;
  re-check Phase 1 before touching either package.
- **Hardening broke the loop (after Phase 3)**: the scoped proxy
  allowlist is missing a group the loop needs; re-run the scoping
  derivation with justification. Never widen OPA to fix an allowlist
  gap or vice versa.
- **Rollback**: decompose - request front off, serving half down,
  fetching half down; each package's own removal applies.

## Removal

1. Remove Jellyseerr (the loop's entry point) first.
2. Remove the serving half, then the fetching half (their removals).
3. The media tree persists; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-11: The composition's core is the LOOP (request → watch),
  not the two stacks separately - that is what "run a library" means as
  a job. Any glue requirement that does not serve the loop is out.
- 2026-09-11: Recommended dependencies introduced here as a convention
  feature (separate table, same pinning, degraded-mode behavior stated
  per row); canonical text in improve-docker-security's
  composition-convention module.

Open questions:

- **Q-1**: Whether reclaimerr's disk-reclaim policy deserves its own
  sibling package (it is optional infrastructure D-9 in the fetching
  half today). Default: stays a fetching-half option until a second
  stack wants it.
