<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: serve-movies-and-series
version: 0.2.1
status: published
description: Serving a movies-and-series library - Jellyfin reading the same tree the fetching stack imports into, with Jellyseerr as the request front. Exposure as a first-class choice (local, tailnet, or a gated public hostname), read-only by posture over the media.
---

# Schematic: Serve Movies and Series

## Applicable Context

**Must discover locally:**

- The library roots the fetching stack imports into (production:
  `/media/movies`, `/media/tvseries`; Jellyfin production mounts the
  whole `/media` tree)
- The exposure vehicle: local-only, tailnet, tsdproxy, or Cloudflare
- Whether a request front (Jellyseerr) is wanted
- uid/gid owning the media files

**May assume (with risk):**

- A sibling fetching stack (`fetch-movies-and-series`) imports into the
  same tree; nothing here breaks with hand-populated libraries

**Must not change:**

- Library tree ownership and permissions; the server reads libraries

## Scope

**In scope:**

- Jellyfin deployment with library, config, and cache paths
- Jellyseerr as the request front wired to the arrs via the fetching
  stack's APIs
- The exposure decision as an explicit parameter (mirrors
  `serve-books-using-containers`'s exposure-options)

**Out of scope / non-goals:**

- Transcoding hardware configuration beyond a parameter (P-6)
- Fetching (see `fetch-movies-and-series`)

**Preservation List (reverse-engineered):**

- Libraries, config, and cache are separate host paths
- The serving stack never writes library folders
- The request front talks to the arrs, never moves files itself

## Requirements

- **R-1**: The server reads libraries in place from the same host paths
  the fetcher imports into; an import is watchable within one scan.
- **R-2**: Library folders are mounted read-only into the serving
  container; config and cache are the only writable mounts.
- **R-3**: Exposure follows the chosen option and nothing wider: local
  or tailnet options must not be publicly routable; a public hostname
  requires edge auth gating on top of the Jellyfin login (same rule as
  `serve-books-using-containers` R-3/R-4).
- **R-4**: Jellyseerr authenticates users separately from Jellyfin and
  its requests land in the fetching stack's arrs (Radarr/Sonarr), not
  on the filesystem.
- **R-5**: Images digest-pinned; healthchecks present.
- **R-6**: Config and cache persisted on the host (users, watch state,
  artwork cache).

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | Docker + Compose v2 | Runs the server | `docker compose version` | Blocker |
| D-2 | Jellyfin image | The server | Digest-pinned | Serving down |
| D-3 | Library tree on host | What gets served | `ls <media root>` | Empty server |
| D-4 | Jellyseerr image (optional) | Request front | Digest-pinned | Requests go directly in the arrs |
| D-5 | Tailnet / tsdproxy / Cloudflare (optional) | Exposure beyond local | Existing infra | Falls back to local |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MEDIA_ROOT | path | `/media` | Host dataset | Library trees (and production: the whole tree mount) |
| P-2 | EXPOSURE | enum | `local` | Operator choice | local / tailnet / tsdproxy / cloudflare |
| P-3 | APPS_ROOT | path | `${P-1}/config/jellyfin` | State convention | Config + cache home |
| P-4 | PUID/PGID | int | 1000 | Media owner | Container user |
| P-5 | TZ | string | (host tz) | `date +%Z` | Logs |
| P-6 | TRANSICODE | bool | false | GPU presence | Enable hardware transcoding params |

## Modules

- **exposure-options**: the four vehicles (local, tailnet, tsdproxy,
  cloudflare) and the shared-tunnel rule; mirrors the book-serving
  module of the same name and defers to it for the decision table.

## Interfaces and Contracts

### To the fetching stack

- Reads the library roots `fetch-movies-and-series` imports into
  (R-1); scan instead of move.

### To Jellyseerr

- Jellyseerr authenticates against Jellyfin users; requests go to
  Radarr/Sonarr APIs; it never touches the filesystem (R-4).

## Implementation Phases

### Phase 1: Server

1. Deploy Jellyfin: libraries read-only (R-2), config + cache writable
   (R-6), digest-pinned, healthcheck.
2. Verification: UI reachable on the chosen exposure; libraries scan.

### Phase 2: Exposure

1. Apply P-2: bind/publish per option; if cloudflare, edge auth is
   REQUIRED (R-3).
2. Verification: chosen vantage works; non-chosen public vantage times
   out (local/tailnet/tsdproxy).

### Phase 3: Request front (optional, D-4)

1. Deploy Jellyseerr; connect it to Jellyfin (auth) and to Radarr and
   Sonarr (API keys from the fetching stack).
2. Verification: a request from Jellyseerr appears in the arr's queue
   and completes into the library without manual steps.

## Verification and Acceptance

- **A-1** (R-1): an imported file becomes playable within one scan
  interval, byte-identical.
- **A-2** (R-2): library binds are `:ro`; writes inside fail.
- **A-3** (R-3): exposure matches P-2 exactly; public probes time out
  for local/tailnet/tsdproxy; cloudflare requires the edge policy.
- **A-4** (R-4): a Jellyseerr request lands in the arr queue, never on
  disk directly.
- **A-5** (R-5/R-6): digest pins present; a container restart keeps
  users and watch state (host-persisted config).

## Failure Modes and Rollback

- **Server blind to imports**: path mapping drift; compare container
  views with the host tree.
- **Transcoding stutters**: enable P-6 only with real GPU; otherwise
  direct play is the norm.
- **Rollback**: `docker compose down`; media untouched.

## Removal

1. Drop the exposure attachment.
2. `docker compose down`.
3. Config/cache persist under P-3; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-11: Reverse-engineered from a production Jellyfin + Jellyseerr
  stack where Jellyfin mounts the whole `/media` tree and every library
  root is shared with the fetchers. Jellyseerr's request path (arrs,
  never filesystem) is production behavior carried over as a
  requirement.
- 2026-09-11: Exposure reuses the four-option model from
  `serve-books-using-containers` rather than redefining it - the
  decision table is identical, only the default differs (this stack's
  production runs a gated public hostname; the book stack's runs
  tailnet).

Open questions:

- **Q-1**: Whether music libraries belong in this package's scope via
  the same Jellyfin instance (production serves music the same way).
  Default: yes as a note, formal contract in `run-a-music-library`.
