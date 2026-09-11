<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: fetch-movies-over-usenet
version: 0.1.1
status: published
description: Privately acquiring movies over usenet - Radarr automating grabs through the shared downloading infrastructure (Prowlarr, SABnzbd, unpackerr) instead of deploying any of it again. Imports in place into the movies library the server reads.
---

# Schematic: Fetch Movies Over Usenet

## Applicable Context

**Must discover locally:**

- `fetch-over-usenet` installed and verified (its phases 1-2 green) -
  it OWNS the downloader and indexer authority this package registers
  with
- The movies library root the serving side reads
- Whether the shared Bazarr is deployed (subtitles then come from it)

**May assume (with risk):**

- The path contract of `fetch-over-usenet`; this package inherits it,
  it does not redefine it

**Must not change:**

- The shared infrastructure's configuration beyond adding this arr's
  registrations (categories, download-client entry, API keys)
- Other arrs' profiles and mappings

## Scope

**In scope:**

- Radarr: movie monitoring, quality profiles, imports into the movies
  root
- Registration with the shared infrastructure (the three-part contract)
- If the shared Bazarr is NOT deployed: movie subtitle handling is this
  package's gap to note (deploy Bazarr in the shared infra instead -
  one Bazarr for all media kinds)

**Out of scope / non-goals:**

- The downloader, indexer manager, unpackerr, Bazarr, flaresolverr
  (all owned by `fetch-over-usenet`)
- Series (see `fetch-series-over-usenet`), music, serving

## Requirements

- **R-1**: Registration follows the three-part contract: indexer sync
  via the Prowlarr movies category, a SABnzbd download-client entry
  with the movies category, and mounts whose logical names match what
  SABnzbd reports.
- **R-2**: Imports land in the movies root (P-1) on the same host tree
  the server reads; import is a move on one filesystem.
- **R-3**: Quality profiles are operator-chosen; image defaults are
  reviewed, not inherited.
- **R-4**: API keys generated per deployment, never committed.
- **R-5**: Image digest-pinned; healthcheck present.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | [fetch-over-usenet v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-over-usenet/SCHEMATIC.md) `sha256:bef7d4c87fa7227f5f6d9653365a1ab66f6e7429978e8ef221939cf772ea64a3` | The shared downloader, indexer authority, unpackerr | Its phases 1-2 green | Blocker: nothing to register with |
| D-2 | Radarr image | Movie automation | Digest-pinned | No movie fetching |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MOVIES_ROOT | path | `${MEDIA_ROOT}/movies` | Server's movies library | Import target |
| P-2 | MOVIES_CATEGORY | string | `movies` | Shared P-6 category map | Downloader + indexer category |
| P-3 | PUID/PGID, TZ | - | 1000, host tz | As the shared infra | Consistency |

## Modules

- **registration-walkthrough**: the three-part contract applied
  concretely to Radarr, step by step.

## Interfaces and Contracts

### To fetch-over-usenet

- Consumes Prowlarr (movies category) and SABnzbd (movies category);
  deploys neither.

### To the serving side

- Imports into P-1 - the movies library the server reads in place.

## Implementation Phases

### Phase 1: Register

1. Add Radarr as a Prowlarr sync target (movies category) and a SABnzbd
   download client (movies category); mount per the inherited path
   contract.
2. Verification: the indexer sync lands; a test grab routes to SABnzbd
   under the movies category.

### Phase 2: Library and profiles

1. Deploy Radarr with the P-1 mount and path contract; review quality
   profiles (R-3); add movies to monitor.
2. Verification: a grab completes through SABnzbd and imports into
   P-1; if shared Bazarr is deployed, a subtitle arrives automatically.

## Verification and Acceptance

- **A-1** (R-1): registration matches the contract; no second
  downloader or indexer manager exists.
- **A-2** (R-2): an imported movie is in P-1, byte-identical, no manual
  moves.
- **A-3** (R-3): profile choice recorded in Radarr config, not default.
- **A-4** (R-4/R-5): no keys committed; digest pin and healthcheck
  present.

## Failure Modes and Rollback

- **Grabs land in the wrong category**: mapping error; fix the Prowlarr
  mapping.
- **Import path errors**: the path contract drifted; see
  fetch-over-usenet's path-contract module.
- **Rollback**: remove Radarr's registrations, then the container; the
  shared infra is untouched.

## Removal

1. Remove Radarr from Prowlarr sync and SABnzbd clients.
2. `docker compose down`.
3. The movies library persists; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-11: Split out of `fetch-movies-and-series` so movies and
  series are independently deployable halves over one shared
  infrastructure package. Everything infrastructure-shaped (Prowlarr,
  SABnzbd, unpackerr, Bazarr, flaresolverr) moved to
  `fetch-over-usenet`; this package keeps only what is genuinely
  movie-specific.

Open questions:

- **Q-1**: Movie collections management (production has a
  `movie-collections` tree) - whether Radarr collection handling needs
  spec treatment. Default: out of scope until asked.
