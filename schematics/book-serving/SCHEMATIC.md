---
name: book-serving
version: 0.1.0
status: published
description: Serving a self-hosted digital library - Audiobookshelf reading the same dataset the fetching stack writes, with the public surface as a first-class choice: Tailscale serve by default, tsdproxy or a Cloudflare tunnel when you want a real hostname. Read-only by posture; the media never moves.
---

# Schematic: Book Serving (Audiobookshelf + Optional Tunnel)

## Applicable Context

**Must discover locally:**

- The library tree(s): folders for audiobooks, ebooks, podcasts
  (production: `/media/audiobooks`, `/media/books`, `/media/podcasts`)
- Whether a tailnet exists (for the default exposure) or which hostname
  vehicle to use (tsdproxy, Cloudflare tunnel)
- If a Cloudflare tunnel: whether it is dedicated to this service or a
  shared remotely-managed tunnel (see the exposure module for when
  shared is acceptable)
- uid/gid owning the media files (production: 1000:1000)

**May assume (with risk):**

- A sibling fetching stack writes into the same tree (see
  `book-stack`); nothing here breaks if libraries are populated by
  hand instead
- The host runs the media on ZFS or similar (irrelevant to the wiring;
  relevant to capacity)

**Must not change:**

- The media tree's ownership and permissions (the serving container
  reads; it must not need write access to libraries)

## Scope

**In scope:**

- Audiobookshelf deployment with library, config, and metadata paths
- The exposure decision as an explicit parameter (three documented
  options) and the requirement each option must satisfy
- The read-only posture on library data

**Out of scope / non-goals:**

- Fetching (see `book-fetching`)
- Mobile-client configuration beyond server URLs
- Transcoding tuning (Audiobookshelf handles on-the-fly; direct play is
  the norm for audio)

**Preservation List (reverse-engineered):**

- Libraries, config, and metadata are separate host paths; metadata
  MUST NOT live inside a library folder
- The serving stack NEVER writes into library folders (imports happen
  on the fetching side)
- Exposure defaults to tailnet-only; a public hostname is a deliberate
  upgrade, not the default

## Requirements

- **R-1**: The server MUST read media in place from the same host paths
  the importing side writes; no copy step between stacks exists, so an
  import is audible within seconds of landing.
- **R-2**: Library folders MUST be mounted read-only into the serving
  container; config and metadata paths are the only writable mounts.
- **R-3**: Whatever exposure option is chosen, the server MUST NOT be
  reachable from the public internet unless the operator explicitly
  picked the tsdproxy or Cloudflare option; the default posture is
  tailnet-only.
- **R-4**: If a Cloudflare tunnel serves the hostname, auth at the
  tunnel edge (Zero Trust application policy) MUST gate the hostname;
  the ABS login screen is the second factor, not the only one.
- **R-5**: A tsdproxy or Cloudflare option MUST keep the origin
  connection host-local (proxy network / tailnet), publishing nothing.
- **R-6**: Images MUST be digest-pinned; tags frozen to a version line
  the operator upgrades deliberately.
- **R-7**: A healthcheck MUST exist and gate any proxy that uses
  container-internal health gating.
- **R-8**: The metadata path MUST be persisted on the host (it holds
  user sessions, progress, and scan state; losing it logs everyone out
  and restarts listening progress).

## Design Principles Binding the Implementation

The ten binding principles apply as published in the repository README.
Implementation-specific binding choices:

- The exposure is one parameter with three options, not three
  schematics: requirements R-3..R-5 phrase what must hold under each,
  and the compose delta between options is one network attachment plus
  one service.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | Docker Engine + Compose v2 | Runs the server | `docker compose version` | Blocker |
| D-2 | Audiobookshelf image | The server | Digest-pinned | Serving down |
| D-3 | Library tree on the host | What gets served | `ls <media root>` | Empty server; no failure |
| D-4 | Tailscale on the host (option A) | Default exposure | `tailscale ip -4` | Falls back to local-only access |
| D-5 | tsdproxy on the host (option B) | Hostname exposure via tailnet identity | Existing deployment | Option B unavailable; use A or C |
| D-6 | Cloudflare tunnel (option C) | Public hostname behind edge auth | Zero Trust account | Option C unavailable; use A or B |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MEDIA_ROOT | path | `/media` | Host dataset | Library trees live under it |
| P-2 | EXPOSURE | enum | `tailscale` | Operator choice (A tailscale serve, B tsdproxy, C cloudflare) | Which network attachment the server gets |
| P-3 | TAILNET_IP | string | (required if A) | `tailscale ip -4` | Bind address |
| P-4 | HOSTNAME | string | (required if B/C) | DNS name | Public URL |
| P-5 | APPS_ROOT | path | `${P-1}/apps/audiobookshelf` | State convention | Config + metadata home |
| P-6 | PUID/PGID | int | 1000 | Media owner | Container user |
| P-7 | TZ | string | (host tz) | `date +%Z` | Logs |
| P-8 | ABS_PORT | int | 80 (internal) / 13378 | Image default | Listener |

## Modules

- **exposure-options**: the three vehicles compared - what each exposes,
  what each requires, and the shared-tunnel caveat that decides when a
  Cloudflare tunnel must be dedicated.
- **read-only-posture**: why the serving side never writes libraries,
  and how progress/metadata stay writable without it.

## Interfaces and Contracts

### To the fetching stack (see book-stack)

- Reads `${P-1}/books`, `${P-1}/audiobooks` (read-only) - the same
  paths Chaptarr imports into. Contract: importing side owns the files,
  this side serves them; delete nothing.
- Directory layout inside a library is the importer's business; ABS
  scans, it does not rearrange (folder-format per library type:
  audiobooks per-book, ebooks flat).

### To clients

- Stream over HTTP(S) direct play; transcoding is on-demand and rare
  for audio.
- Per-user progress lives in P-5 metadata - the reason R-8 exists.

## Implementation Phases

### Phase 1: Server

1. Deploy Audiobookshelf with library mounts read-only (R-2), config +
   metadata writable (R-8), digest-pinned image, healthcheck.
2. Verification: UI reachable locally; create the admin account; add
   libraries pointing at the read-only mounts.

### Phase 2: Exposure

1. Option A (default): bind/publish on the tailnet IP only, or leave
   unpublished and reach via the tailnet directly.
2. Option B: attach to the tsdproxy network, add the hostname mapping.
3. Option C: attach to the tunnel network, add the ingress hostname,
   AND gate the hostname with a Zero Trust application policy (R-4).
4. Verification: from the chosen vantage the server answers; from the
   public internet, option A and B time out entirely (R-3).

### Phase 3: Prove the contract with a sibling fetcher

1. Have a book or audiobook import land in a root folder (hand-copy if
   no fetching stack yet).
2. Verification: a library scan picks it up without any file moving;
   the file's mtime/owner are untouched (R-1, R-2).

## Verification and Acceptance

- **A-1** (R-1): imported file becomes playable in ABS within one scan
  interval, byte-identical (`md5sum` before/after import).
- **A-2** (R-2): `docker inspect` shows library binds with `:ro`;
  writing inside a library from the container fails.
- **A-3** (R-3): per P-2: tailscale/tsdproxy - external probe of the
  port times out; cloudflare - hostname requires the tunnel policy
  (unauthenticated fetch gets the Zero Trust login, not ABS).
- **A-4** (R-4, option C only): revoking the Zero Trust session blocks
  access even with valid ABS credentials.
- **A-5** (R-6): `docker inspect` image ref carries `@sha256:`.
- **A-6** (R-7): stopping the container flips the healthcheck within
  one interval; any proxy using it pauses routing.
- **A-7** (R-8): restart the container; listening progress and sessions
  survive (they live on the host metadata path).

## Failure Modes and Rollback

- **Server up, library empty**: wrong path mount or library config;
  compare the container's view (`ls /books`) with the host tree.
- **Zero Trust blocks everyone (option C)**: policy misconfig; check
  the application's email/identity rules before the tunnel itself.
- **Metadata loss**: P-5 path was ephemeral; restore from backup or
  re-add users and accept progress reset - this is why R-8 is a
  requirement, not advice.
- **Rollback**: `docker compose down`; media untouched. Removing the
  exposure is just removing the network attachment.

## Removal

1. Drop the exposure attachment (tunnel hostname or tsdproxy mapping).
2. `docker compose down`.
3. Config/metadata under P-5 persist; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-10: Reverse-engineered from the phoenix stack (Audiobookshelf
  reading the same `/media` tree Chaptarr imports into; exposure via a
  shared remotely-managed Cloudflare tunnel with Zero Trust policy).
  The shared-tunnel usage is honest production reality for a read-only
  service with edge auth - see the exposure-options module for exactly
  when shared is acceptable and when it must be dedicated.
- 2026-09-10: Exposure became a parameter with three options rather
  than a fixed choice because production uses a public hostname while
  the sibling fetching stack is tailnet-only; the format should let
  both postures live in one spec.

Open questions:

- **Q-1**: Whether to add an option D (Tailscale Serve on the host, no
  docker network involvement). It is the zero-config tailnet path but
  ties exposure to host CLI state rather than compose. Default: not
  included until requested.
