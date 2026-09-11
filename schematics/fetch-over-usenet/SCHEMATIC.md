<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: fetch-over-usenet
version: 0.1.1
status: published
description: The shared usenet downloading infrastructure every media *arr registers with - SABnzbd as the one downloader, Prowlarr as the one indexer authority, unpackerr cleaning archives, and optional Bazarr and flaresolverr as shared services. Deploys once per host; media kinds (movies, series, music, books) join by category, never by second instance.
---

# Schematic: Fetch Over Usenet (Shared Infrastructure)

## Applicable Context

**Must discover locally:**

- Usenet provider account(s) (server host, ports, connections, auth)
- The media tree: `downloads/incomplete` and `downloads/complete` (the
  handoff point every registering arr will use)
- Whether any indexer sits behind Cloudflare (decides flaresolverr)
- Which media kinds will register now or later (informs Bazarr)

**May assume (with risk):**

- Docker + Compose v2 on a Linux host; uid 1000 owns the media tree

**Must not change:**

- Other stacks' networks or state directories

## Scope

**In scope:**

- SABnzbd (the downloader), Prowlarr (the indexer authority), unpackerr
  (archive cleanup) - the three required services
- Optional shared services: Bazarr (subtitles, attaches to arrs as they
  register) and flaresolverr (CF-gated indexers)

**Out of scope / non-goals:**

- Any media-specific automation (Sonarr, Radarr, Lidarr, ...): they are
  separate schematics that REGISTER with this one
- Serving, VPN routing, torrents

**Preservation List (reverse-engineered):**

- One downloader, one indexer manager per host - media kinds join by
  category, never by second instance
- `downloads/incomplete` → `downloads/complete` is the only handoff
  point; importers read from `complete`

## Requirements

- **R-1**: SABnzbd completes into `downloads/complete` (per-release
  subdirectories) and reports paths consistent with how registering
  arrs will mount the tree (the path contract every consumer inherits).
- **R-2**: Prowlarr is the only place indexers are configured; it
  exposes sync to any registering arr. Adding an indexer never touches
  more than one place.
- **R-3**: unpackerr watches SABnzbd's queue, extracts completed
  archives in place, and removes them, so `complete` never doubles as
  storage.
- **R-4**: If Bazarr is deployed, it runs ONCE and attaches to arrs via
  their APIs as they register; if flaresolverr is deployed, it serves
  only the indexers that need it.
- **R-5**: API keys (Prowlarr ↔ arrs, SABnzbd ↔ arrs) are generated per
  deployment and never committed.
- **R-6**: Images digest-pinned; healthchecks on all long-running
  services.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | Docker + Compose v2 | Runs the services | `docker compose version` | Blocker |
| D-2 | Usenet provider account | The actual downloads | Provider creds into SABnzbd | Grabs stall |
| D-3 | SABnzbd image | The downloader | Digest-pinned | Nothing downloads |
| D-4 | Prowlarr image | Indexer authority | Digest-pinned | No indexer sync |
| D-5 | unpackerr image | Archive extraction | Digest-pinned | Archived releases bloat or fail imports |
| D-6 | Bazarr image (optional) | Shared subtitles | Digest-pinned | Arrs handle subtitles themselves or not at all |
| D-7 | flaresolverr image (optional) | CF-gated indexers | Digest-pinned | Those indexers fail in Prowlarr |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MEDIA_ROOT | path | `/media` | Host dataset | Downloads tree lives under it |
| P-2 | DOWNLOADS | path | `${P-1}/downloads` | Host tree | incomplete/ + complete/ |
| P-3 | APPS_ROOT | path | `${P-1}/config` | State convention | Per-app config dirs |
| P-4 | PUID/PGID | int | 1000 | Media owner | Container user |
| P-5 | TZ | string | (host tz) | `date +%Z` | Logs |
| P-6 | CATEGORY_MAP | map | tv=5000, movies=2000, audio=3000, books=7000 | Prowlarr conventions | The categories registering arrs claim |

## Modules

- **path-contract**: the directory flow and the remote-mapping rule
  every registering arr inherits.
- **indexer-topology**: why Prowlarr is the single authority, sync
  ordering, and category collision avoidance.
- **registering-arrs**: the exact contract a media arr must satisfy to
  join (categories, download-client entry, mounts) - the interface the
  media-specific fetch schematics consume.

## Interfaces and Contracts

### The registration contract (the heart of this package)

An arr registers by doing exactly three things:

1. **Indexer side**: appear as a Prowlarr sync target claiming one
   category from P-6.
2. **Downloader side**: appear in SABnzbd as a download client with its
   own category, mapped to its post-processing dir.
3. **Mount side**: mount `downloads/complete` (and its own library
   root) with the SAME logical names this package uses, so SABnzbd's
   reported paths resolve inside the arr.

No registering arr may configure indexers directly, deploy its own
downloader, or mount another arr's state.

### To the serving side

- This package never touches library roots; importers (the arrs) own
  those. The serving side reads libraries, not `complete`.

## Implementation Phases

### Phase 1: Downloader

1. Deploy SABnzbd with provider config and the P-2 mount layout.
2. Verification: a test nzb completes into `downloads/complete`.

### Phase 2: Indexer authority

1. Deploy Prowlarr; add indexers; confirm test queries (attach
   flaresolverr first if any indexer needs it, R-4).
2. Verification: indexer status page all green.

### Phase 3: Cleanup and optional shared services

1. Deploy unpackerr pointed at SABnzbd.
2. Optional: Bazarr (it waits for arrs to register) per D-6.
3. Verification: an archived release extracts in place, archive removed.

## Verification and Acceptance

- **A-1** (R-1): test download completes into `complete/`, reported
  paths resolve under the documented mount names.
- **A-2** (R-2): indexers exist only in Prowlarr (`git ls-files` and
  Prowlarr config confirm no per-arr indexer setup exists yet).
- **A-3** (R-3): after an archived grab, `complete/` holds no archive.
- **A-4** (R-4): Bazarr runs once and has no arr connections until an
  arr registers; flaresolverr serves only gated indexers.
- **A-5** (R-5): no API keys committed.
- **A-6** (R-6): digest pins and healthchecks present.

## Failure Modes and Rollback

- **SABnzbd queue stalls**: provider outage or connection limits; check
  provider status first.
- **Indexer failing in Prowlarr only**: Cloudflare gate; flaresolverr.
- **Imports later fail with path errors**: a registering arr broke the
  path contract; fix the arr's mapping, never this package's layout.
- **Rollback**: `docker compose down`; the downloads tree is state.

## Removal

1. Remove optional services (Bazarr, flaresolverr), then unpackerr,
   Prowlarr, SABnzbd - after every registered arr has been removed (an
   arr's removal procedure runs first, not this package's).
2. The downloads tree persists; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-11: Split out of `fetch-movies-and-series` (which bundled the
  shared infrastructure with two media-specific arrs) so that any media
  kind - movies, series, music, books - registers with ONE shared
  infrastructure package. Prowlarr, Bazarr, and flaresolverr live here
  (not in the arr packages) because production runs exactly one of
  each for all media kinds; the arr packages consume them via the
  registration contract.
- 2026-09-11: Registration is a three-part contract (indexer category,
  downloader category, mount names) so that "join the pipeline" is
  mechanical and testable rather than folklore.

Open questions:

- **Q-1**: Whether a registration-conformance test script belongs in
  `scripts/` (probe Prowlarr/SABnzbd APIs for a well-formed
  registration). Default: not yet; the contract is documented and the
  arr packages' acceptance tests cover their own side.
