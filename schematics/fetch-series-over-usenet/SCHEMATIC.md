<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: fetch-series-over-usenet
version: 0.1.1
status: published
description: Privately acquiring series over usenet - Sonarr automating episode and season grabs through the shared downloading infrastructure (Prowlarr, SABnzbd, unpackerr) instead of deploying any of it again. Imports in place into the series library the server reads.
---

# Schematic: Fetch Series Over Usenet

## Applicable Context

**Must discover locally:**

- `fetch-over-usenet` installed and verified (its phases 1-2 green) -
  it OWNS the downloader and indexer authority this package registers
  with
- The series library root the serving side reads (production:
  `tvseries`)
- Whether the shared Bazarr is deployed (subtitles then come from it)

**May assume (with risk):**

- The path contract of `fetch-over-usenet`; this package inherits it

**Must not change:**

- The shared infrastructure's configuration beyond this arr's
  registrations
- Other arrs' profiles and mappings

## Scope

**In scope:**

- Sonarr: series monitoring, season/episode handling, quality profiles,
  imports into the series root
- Registration with the shared infrastructure (the three-part contract)

**Out of scope / non-goals:**

- The downloader, indexer manager, unpackerr, Bazarr, flaresolverr
  (owned by `fetch-over-usenet`)
- Movies (see `fetch-movies-over-usenet`), music, serving

## Requirements

- **R-1**: Registration follows the three-part contract: indexer sync
  via the Prowlarr TV category, a SABnzbd download-client entry with
  the TV category, mounts whose logical names match SABnzbd's reports.
- **R-2**: Imports land in the series root (P-1) on the same host tree
  the server reads; import is a move on one filesystem.
- **R-3**: Quality profiles are operator-chosen (season packs vs
  episodes, release formats); defaults reviewed, not inherited.
- **R-4**: API keys generated per deployment, never committed.
- **R-5**: Image digest-pinned; healthcheck present.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | [fetch-over-usenet v0.1.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-over-usenet/SCHEMATIC.md) `sha256:bef7d4c87fa7227f5f6d9653365a1ab66f6e7429978e8ef221939cf772ea64a3` | The shared downloader, indexer authority, unpackerr | Its phases 1-2 green | Blocker: nothing to register with |
| D-2 | Sonarr image | Series automation | Digest-pinned | No series fetching |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | SERIES_ROOT | path | `${MEDIA_ROOT}/tvseries` | Server's series library | Import target |
| P-2 | TV_CATEGORY | string | `tv` | Shared P-6 category map | Downloader + indexer category |
| P-3 | PUID/PGID, TZ | - | 1000, host tz | As the shared infra | Consistency |

## Modules

- **season-handling**: the season-pack vs episode decision and how
  unpackerr interacts with multi-episode archives.

## Interfaces and Contracts

### To fetch-over-usenet

- Consumes Prowlarr (TV category) and SABnzbd (TV category); deploys
  neither.

### To the serving side

- Imports into P-1 - the series library the server reads in place.

## Implementation Phases

### Phase 1: Register

1. Add Sonarr as a Prowlarr sync target (TV category) and a SABnzbd
   download client (TV category); mount per the inherited path
   contract.
2. Verification: sync lands; a test grab routes to SABnzbd under the
   TV category.

### Phase 2: Library and profiles

1. Deploy Sonarr with the P-1 mount and path contract; review quality
   profiles (R-3); add series to monitor.
2. Verification: a grab completes through SABnzbd, imports into P-1;
   if shared Bazarr is deployed, subtitles arrive automatically.

## Verification and Acceptance

- **A-1** (R-1): registration matches the contract; no second
  downloader or indexer manager exists.
- **A-2** (R-2): an imported episode is in P-1, byte-identical, no
  manual moves.
- **A-3** (R-3): profile choice recorded in Sonarr config, not default.
- **A-4** (R-4/R-5): no keys committed; digest pin and healthcheck
  present.

## Failure Modes and Rollback

- **Grabs land in the wrong category**: mapping error; fix the Prowlarr
  mapping.
- **Season packs stuck**: profile vs indexer availability; see the
  season-handling module before retriggering searches.
- **Import path errors**: path contract drift; see fetch-over-usenet's
  path-contract module.
- **Rollback**: remove Sonarr's registrations, then the container; the
  shared infra is untouched.

## Removal

1. Remove Sonarr from Prowlarr sync and SABnzbd clients.
2. `docker compose down`.
3. The series library persists; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-11: Split out of `fetch-movies-and-series` so movies and
  series are independently deployable halves over one shared
  infrastructure package; everything infrastructure-shaped moved to
  `fetch-over-usenet`.

Open questions:

- **Q-1**: Anime-specific handling (Sonarr's anime profile quirks) -
  out of scope until an operator needs it.
