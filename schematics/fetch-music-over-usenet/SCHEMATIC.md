<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: fetch-music-over-usenet
version: 0.2.1
status: published
spec: 1
description: Privately acquiring music over usenet - Lidarr automating artist and album grabs through the indexer-manager and downloader the movie/series stack already runs. Shares the downloading infrastructure instead of duplicating it; imports in place into the music library the server reads.
---

# Schematic: Fetch Music Over Usenet

## Applicable Context

**Must discover locally:**

- The usenet provider and downloader this stack will use: either an
  existing SABnzbd from `fetch-over-usenet` (the intended shape -
  one downloader serves all media kinds) or a new one
- The music library root the server reads (production: `/media/music`)
- Prowlarr (or equivalent) already running for indexer management

**May assume (with risk):**

- `fetch-over-usenet` and its path contract are in place; this
  package adds a consumer to that pipeline, not a new pipeline

**Must not change:**

- The downloader's own configuration beyond adding a category
- Other arrs' quality profiles and mappings

## Scope

**In scope:**

- Lidarr as the music arr: artist/album monitoring, quality profiles,
  and imports into the music root
- The category contract on the shared downloader and indexer manager

**Out of scope / non-goals:**

- The downloader and indexer manager themselves (dependencies of
  `fetch-over-usenet`; shared, not duplicated)
- Serving music (the composite `run-a-music-library` handles the wiring)

**Preservation List (reverse-engineered):**

- One downloader for all media kinds, separated by category
- Imports in place into the shared tree; no copy step

## Requirements

- **R-1**: Lidarr registers in Prowlarr via the audio category and uses
  the shared SABnzbd via its own download-client entry (category
  `music`, or the operator's mapping) - one indexer manager, one
  downloader, no duplicates (R-1 is the shape, not a new service).
- **R-2**: Imports land in the music root (P-1) on the same host tree
  the server reads; the path contract of `fetch-over-usenet`
  applies unchanged.
- **R-3**: Quality profiles for music are operator-chosen (format,
  bitrate); defaults are reviewed, not inherited.
- **R-4**: Images digest-pinned; healthcheck present.

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

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | [fetch-over-usenet v0.1.1](https://github.com/cameri/schematics/blob/81721d8ff548ad0f4b1477e696b7899d30f999fa/schematics/fetch-over-usenet/SCHEMATIC.md) `sha256:bef7d4c87fa7227f5f6d9653365a1ab66f6e7429978e8ef221939cf772ea64a3` | The shared indexer manager and downloader | Its phases 1-2 green | Blocker: deploy it first |
| D-2 | Lidarr image | Music automation | Digest-pinned | No music fetching |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MUSIC_ROOT | path | `${MEDIA_ROOT}/music` | Server's music library | Import target |
| P-2 | MUSIC_CATEGORY | string | `music` | Operator mapping | Downloader + indexer category |
| P-3 | PUID/PGID, TZ | - | 1000, host | As the parent stack | Consistency |

## Modules

- **shared-downloader**: why music rides the same SABnzbd/Prowlarr as
  movies and series (category separation, not new instances).

## Interfaces and Contracts

### To the parent fetching stack

- Consumes Prowlarr (audio category) and SABnzbd (music category);
  adds no service of its own beyond Lidarr.

### To the serving side

- Imports into P-1 - the music library the server reads in place.

## Implementation Phases

### Phase 1: Register in the shared infrastructure

1. Add Lidarr to Prowlarr's sync targets (audio category) and to
   SABnzbd as a download client with the music category.
2. Verification: the indexer sync lands in Lidarr; a test grab routes
   to SABnzbd under the music category.

### Phase 2: Library and profiles

1. Deploy Lidarr with the P-1 mount and path contract (identical
   mapping names as the parent stack).
2. Review quality profiles (R-3); add artists.
3. Verification: an album grab completes through SABnzbd and imports
   into P-1.

## Verification and Acceptance

- **A-1** (R-1): adding an indexer in Prowlarr appears in Lidarr after
  sync; no second indexer manager exists.
- **A-2** (R-2): an imported album is inside P-1, byte-identical, with
  no manual moves.
- **A-3** (R-3): the profile choice is recorded in Lidarr config, not
  the shipped default.
- **A-4** (R-4): digest pin present; healthcheck flips on stop.

## Failure Modes and Rollback

- **Grabs routed to the wrong arr**: category mapping wrong; fix the
  Prowlarr mapping, not the arrs' indexer entries.
- **Import path errors**: the shared path contract drifted; see
  `fetch-over-usenet`'s path-contract module.
- **Rollback**: remove Lidarr; the parent stack is untouched.

## Removal

1. Remove Lidarr from Prowlarr sync and SABnzbd clients.
2. `docker compose down` for Lidarr.
3. Music library persists; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-11: Reverse-engineered from a production stack where Lidarr
  exists as a stopped container alongside a running movies/series
  pipeline that it shares Prowlarr and SABnzbd with. The shared-
  infrastructure shape (not a second downloader) is carried over as the
  requirement; the production instance's stopped state is an operator
  decision, not a design property, and is recorded here rather than
  hidden.
- 2026-09-11: No VPN layer in scope: usenet fetching rides the same
  provider config as the parent stack. If an operator wants the whole
  pipeline behind a VPN, that is `fetch-books-over-vpn`'s pattern
  applied to this stack - a deliberate composition, not a default.
- 2026-09-17: Schematic dependencies are pinned to commit `81721d8` (the full
  sha is in the link) with the SHA-256 of the file at that commit. Verify a
  pin with `curl -s https://raw.githubusercontent.com/cameri/schematics/<commit>/<path> | sha256sum`
  and compare the result with the digest in the table.

Open questions:

- **Q-1**: Whether a dedicated music server (navidrome) should be an
  alternative serving target for `run-a-music-library` alongside
  Jellyfin. Default: no until asked.
