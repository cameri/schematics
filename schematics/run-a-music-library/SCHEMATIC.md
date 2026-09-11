<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: run-a-music-library
version: 0.2.1
status: published
description: A composition schematic - runs a complete music library by wiring the music-fetching half (Lidarr over the shared usenet pipeline) to the serving half (the Jellyfin instance from the movies-and-series serving stack, gaining music libraries). Shares infrastructure instead of duplicating it - one downloader, one indexer manager, one server. Recommended but optional: hardening the Docker host and keeping deployments current. No images of its own; the glue is the sharing contracts and the artist-to-playlist loop.
---

# Schematic: Run a Music Library (Composition)

A **composition schematic**: no images, no services of its own. It
wires music fetching to music serving while deliberately SHARING the
downloading and serving infrastructure with other media stacks:

```
Lidarr (artist/album watch) ──► shared Prowlarr + SABnzbd
  ──► import in place ──► Jellyfin music libraries ──► listen
```

The distinctive glue here is the sharing contract: music adds no second
downloader, no second indexer manager, no second media server. It
registers with the existing ones under category separation.

## Applicable Context

**Must discover locally:**

- The parent fetching stack (`fetch-over-usenet`) installed and
  verified - its Prowlarr and SABnzbd are the shared infrastructure
- The serving stack (`serve-movies-and-series`) installed and verified -
  its Jellyfin gains the music libraries
- The music library root on the shared tree

**May assume (with risk):**

- All dependencies came from this catalog at the pinned commits

## Scope

**In scope:**

- The sharing contracts (categories, mounts, one-server rule)
- The artist-to-playlist loop as the core acceptance test
- Parameter reconciliation and deployment order
- Recommended optional dependencies

**Out of scope / non-goals:**

- Any service, image, or network of its own
- A dedicated music server (navidrome et al.) - revisit as a sibling if
  asked (Q-1 in fetch-music-over-usenet)

## Requirements

- **R-1**: Music fetching registers with the SHARED Prowlarr and
  SABnzBD under its own categories; no second indexer manager or
  downloader is deployed (fetch-music-over-usenet R-1, enforced
  stack-wide).
- **R-2**: Music imports land in the shared tree's music root, which
  the serving half reads in place; no copy between halves.
- **R-3**: ONE Jellyfin instance serves all media kinds; music is a
  library on the existing instance, never a second server.
- **R-4**: Parameters duplicated across the parts (media root, uid, TZ,
  categories) come from one source; they cannot drift.
- **R-5**: The loop is hands-off: a monitored artist's new album
  reaches the playable state with no manual file operations.
- **R-6**: With every recommended dependency declined, all required
  phases and acceptance tests still pass.

## Dependencies

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | system | Docker + Compose v2 | Runs everything | `docker compose version` | Blocker |
| D-2 | schematic | [fetch-music-over-usenet v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-music-over-usenet/SCHEMATIC.md) `sha256:d1ece75f0f3cf939a17fb9aea85f1095476796d40efe9ac3ddaa01b49aeb80ae` | Acquires music | Its phases 1-2 green | Music static; other media unaffected |
| D-3 | schematic | [fetch-over-usenet v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-over-usenet/SCHEMATIC.md) `sha256:bef7d4c87fa7227f5f6d9653365a1ab66f6e7429978e8ef221939cf772ea64a3` | OWNS the shared Prowlarr + SABnzbd that music registers to | Its phases 1-2 green | Blocker for D-2: no shared infra to register with |
| D-4 | schematic | [serve-movies-and-series v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/serve-movies-and-series/SCHEMATIC.md) `sha256:384ec85884529472943287701cc9912eeceedd4fa53591d77a7fd45a6c3745ce` | OWNS the Jellyfin instance that gains music libraries | Its phases 1-2 green | Music fetches fine, nothing plays |

Note the shape: D-3 and D-4 are dependencies of D-2's and this
composition's design respectively - music composes with stacks that own
shared infrastructure, which is why this composition requires them even
though D-2 alone might look sufficient. A music library without the
movies/series stacks means deploying those packages anyway, degraded to
just their shared-infra role - deliberate, not accidental.

## Recommended

Optional, pinned the same way; declining any keeps R-6 satisfiable.

| Id  | Kind | What | Adds | Without it |
|-----|------|------|------|------------|
| RD-1 | schematic | [improve-docker-security v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/improve-docker-security/SCHEMATIC.md) `sha256:08b9f072a0a96047fcce8036c519d61e5b76b9fd02c98b1ce85ed43324ff153b` | Hardens the Docker host: scoped API, OPA-policed control, encrypted secrets | Accepted risk of socket mounts and plaintext keys |
| RD-2 | schematic | [update-images-on-push v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/update-images-on-push/SCHEMATIC.md) `sha256:810129ef2839e77f88b469601e494e6367a9cc5afd1b1c904fb9e1fe37705067` | Keeps pushed images current | Manual upgrades |
| RD-3 | schematic | [run-a-movies-and-series-library v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/run-a-movies-and-series-library/SCHEMATIC.md) `sha256:b3cbc5bd8bfdac62725f2058fd2a4cb273b8032838ca11fd97b122d35bbc3356` | The full movies-and-series loop around the same shared infrastructure, with Jellyseerr requests | Music-only deployment; the serving and fetching halves still exist per D-3/D-4, just without the request front |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MEDIA_ROOT | path | `/media` | One shared value | Feeds all parts (R-4) |
| P-2 | MUSIC_ROOT | path | `${P-1}/music` | Server's music library | Lidarr import target, Jellyfin music library |
| P-3 | MUSIC_CATEGORY | string | `music` | Operator mapping | Shared-infra category (R-1) |
| P-4 | PUID/PGID/TZ | int/str | 1000, host tz | Host facts | One env file (R-4) |

## Modules

- **sharing-contracts**: the category/mount/one-server rules that let
  three media kinds share one pipeline without collision.
- **recommended-attachments**: where the RDs attach and what declining
  means.

## Interfaces and Contracts

### The sharing contract (R-1/R-3)

```
Prowlarr:  one instance; Lidarr joins via audio category (3000)
SABnzbd:   one instance; Lidarr joins via music client category
Jellyfin:  one instance; music is a new library, not a new server
```

Collision rules from fetch-music-over-usenet's shared-downloader
module apply stack-wide: category mapping is deliberate; queue control
is shared (accepted trade, documented there).

### The loop contract (R-5)

Monitor artist → release appears → grab → import → scan → playable.
The music loop reuses every arrow of the movies loop with audio
categories; the composition adds none.

## Implementation Phases

### Phase 0: Install dependencies in isolation

1. D-3's phases 1-2 (shared infra), D-4's phases 1-2 (server), then
   D-2's phases 1-2 (Lidarr registered with the shared infra) - each
   acceptance set green before glue.

### Phase 1: Reconcile parameters

1. One env file: MEDIA_ROOT, MUSIC_ROOT, category, uid/TZ (R-4).
2. Verification: binds and categories agree across all parts.

### Phase 2: Wire the music libraries

1. Add the music library to the existing Jellyfin (read-only mount of
   P-2, R-2/R-3); confirm Lidarr imports land where the library scans.
2. Verification: the loop (R-5) - a monitored release reaches playable
   hands-off, byte-identical.

### Phase 3 (recommended): attach RD-1, RD-2, RD-3

1. RD-1/RD-2 per their own phases; RD-3 if the operator wants the
   movies-and-series loop around the same infrastructure.
2. Verification: their acceptance sets green; this composition's
   A-1..A-5 still pass (hardening did not break the music loop).

## Verification and Acceptance

- **A-1** (R-1): exactly one Prowlarr and one SABnzbd exist; Lidarr
  appears in neither as a duplicate instance.
- **A-2** (R-2/R-3): an imported album sits in P-2, is served by the
  existing Jellyfin, and no second media server exists.
- **A-3** (R-4): changing P-1/P-4 in the env moves every part together.
- **A-4** (R-5): artist-to-playable completes hands-off, hash-verified.
- **A-5** (R-6): with all RDs declined, A-1..A-4 pass.
- **A-6**: every dependency and recommended link resolves at its
  pinned commit and hashes match.

## Failure Modes and Rollback

- **Album grabbed by the wrong arr**: category mapping; fix the
  mapping, not the arrs.
- **Music in Jellyfin but not Lidarr-tracked**: library added outside
  the loop; re-register the artist in Lidarr - never import by hand.
- **Queue contention** (shared downloader): accepted trade; see the
  shared-downloader module before reaching for a second instance.
- **Rollback**: remove Lidarr's registrations, then the Jellyfin music
  library; shared infra stays for the other media kinds.

## Removal

1. Remove the Jellyfin music library.
2. Remove Lidarr and its registrations (fetch-music-over-usenet's
   removal).
3. Shared infrastructure stays (it belongs to D-3).

## Decisions and Open Questions

Decisions:

- 2026-09-11: The composition exists because "run a music library" is a
  job that spans acquisition and serving, but its distinctive design
  decision is SHARING - one downloader, one indexer manager, one
  server. The glue is the sharing contracts; the parts stay
  authoritative.
- 2026-09-11: RD-3 (the movies-and-series composition) is itself
  recommended rather than required: music can run beside the shared
  infrastructure without the request front. Recommended dependencies
  may be compositions, not just capability schematics.

Open questions:

- **Q-1**: A dedicated music server sibling (navidrome) as an
  alternative serving target. Default: no until asked.
- **Q-2**: Whether podcasts belong here (Jellyfin serves them too;
  production has a podcasts tree). Default: out of scope until asked.
