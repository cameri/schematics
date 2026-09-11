<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: run-a-book-library
version: 0.3.1
status: published
description: A composition schematic - assembles the fetch-books-over-vpn and serve-books-using-containers schematics into one operating system for a self-hosted digital library, and defines the shared volume contract between them. Contains no images of its own; its content is the wiring, the shared paths, and the isolation rule that keeps the fetching stack and the serving stack from contaminating each other.
---

# Schematic: Run a Book Library (Composition)

This is a **composition schematic**: it has no images and no services of
its own. It consumes two sibling schematics as dependencies and its
content is the contract between them - the volume layout both sides
share, the network isolation rule, the startup ordering, and the
operational runbook for the assembled whole. Its existence tests and
demonstrates composition in the schematic format (first-class schematic
dependencies); see the composition-convention module for the general
rules this package also establishes.

## Applicable Context

**Must discover locally:**

- Both dependencies installed and their phases verified individually
  (that is a hard prerequisite - composing two broken stacks only
  entangles the failures)
- The media root both stacks will share (production: `/media`)
- The exposure choice for the serving side (P-2 of serve-books-using-containers)

**May assume (with risk):**

- The two dependencies came from this same catalog and versions match
  the marketplace pins

**Must not change:**

- Anything inside either dependency's package; composition edits the
  glue, never the parts

## Scope

**In scope:**

- The shared volume contract (paths both stacks mount)
- The network isolation rule between the stacks
- Assembly ordering and the combined runbook
- Which parameters of the two dependencies must be reconciled

**Out of scope / non-goals:**

- Any service, image, or network of its own
- Re-stating the dependencies' requirements; they remain authoritative
  within their packages

## Requirements

- **R-1**: The fetching stack's completed-downloads path and the
  serving stack's library paths MUST be host paths under one shared
  media root; both compose files reference the SAME host directories,
  never copies.
- **R-2**: The importing side MUST be the only writer of library data
  (serve-books-using-containers R-2 enforced stack-wide); the composition adds no
  mount that lets the serving side write.
- **R-3**: Network isolation: the fetching stack's containers (behind
  gluetun) and the serving stack's containers MUST NOT share a docker
  network beyond what each schematic already requires. The serving
  side MUST have no route through the VPN and the fetching side MUST
  have no route to the serving side's exposure surface.
- **R-4**: Parameters that must agree are declared once and referenced:
  MEDIA_ROOT (P-1 of both), uid/gid, and TZ MUST come from one source
  (one .env included by both stacks) so they cannot drift.
- **R-5**: Startup ordering across stacks: VPN sidecar -> fetchers ->
  (independent) server; shutdown may be any order, but the VPN MUST
  come down last to keep the kill-switch property observable during
  teardown.
- **R-6**: The composition MUST verify end-to-end (grab to listen) as
  one acceptance test; passing both stacks' own tests is necessary but
  not sufficient.

## Dependencies

Dependencies of kind `schematic` point at sibling packages in this
catalog. They are installed as packages (not pulled at runtime); the
composition treats their SCHEMATIC.md as the contract and their
marketplace entries as the version pins.

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | system | Docker + Compose v2 | Runs both stacks | `docker compose version` | Blocker |
| D-2 | schematic | [fetch-books-over-vpn v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/fetch-books-over-vpn/SCHEMATIC.md) `sha256:973e73f65376d1f54353ab94be05975cd60fce4f13f486b61390cd970030b3fa` | Acquires books/audiobooks privately | Its phases 1-4 green | No new content; serving still works |
| D-3 | schematic | [serve-books-using-containers v0.2.1](https://github.com/cameri/schematics/blob/56e02f9/schematics/serve-books-using-containers/SCHEMATIC.md) `sha256:5f09a47942d10f401a09753ead33e8c52bf26b298c26eb0101e189b6793588b7` | Serves the library | Its phases 1-3 green | Library present but silent |
| D-4 | system | One shared media root on the host | The R-1 contract | `ls <media root>` | Blocker: no common tree |

## Parameters

Only the reconciliation surface; the dependencies keep their own.

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | MEDIA_ROOT | path | `/media` | One shared value | Feeds fetch-books-over-vpn P-3 and serve-books-using-containers P-1 (must be equal, R-4) |
| P-2 | EXPOSURE | enum | `tailscale` | Operator choice | Passed straight to serve-books-using-containers P-2 |
| P-3 | PUID/PGID/TZ | int/str | 1000/1000/host | Host facts | Passed to both stacks from one .env (R-4) |

## Modules

- **composition-convention**: the general rules for schematic-to-
  schematic dependencies (kind `schematic` in the dependency table,
  contracts not copies, glue-only scope). Established by this package;
  future composition schematics follow it.
- **volume-contract**: the exact host path tree both stacks share, who
  writes what, and the mounts each side takes.

## Interfaces and Contracts

### The volume contract (the heart of the composition)

```
<MEDIA_ROOT>/                     # one host root (R-1)
  downloads/
    incomplete/                   # fetching stack writes (deluge)
    complete/                     # fetching stack writes; importers read
  books/                          # chaptarr imports here (writer)
                                  # audiobookshelf reads here (:ro)
  audiobooks/                     # same pair as books
  podcasts/                       # serving side only (manual content)
  apps/
    chaptarr/ deluge/ mousehole/  # fetching side state
    audiobookshelf/               # serving side state (config + metadata)
```

- Fetching stack mounts `books` and `audiobooks` **read-write** (it
  imports into them) and `downloads` read-write.
- Serving stack mounts `books`, `audiobooks`, `podcasts` **read-only**,
  and `apps/audiobookshelf` read-write.
- No other cross-stack mount exists. Any new one requires editing this
  contract, not improvising a compose line (R-2's spirit).

### The network contract

- Fetching stack: gluetun netns + its tailnet bindings. No path from
  the serving containers into that netns exists (R-3).
- Serving stack: its exposure network (per P-2). The fetching side
  never joins it - a compromised client cannot pivot from the
  torrent side to the public hostname.

### The end-to-end contract

Search -> grab -> download (VPN) -> import -> visible in the server ->
playable. One chain, tested as one (R-6).

## Implementation Phases

### Phase 0: Install dependencies

1. Execute fetch-books-over-vpn phases 1-4 and serve-books-using-containers phases 1-3
   separately; each stack's own acceptance tests pass.
2. Verification: both stacks' A-sets green BEFORE any glue exists.

### Phase 1: Reconcile parameters

1. Create one shared env file for both stacks: MEDIA_ROOT, PUID/PGID,
   TZ (R-4). Both compose files include it; neither redefines these.
2. Verification: `docker inspect` on both stacks' containers shows
   identical media-root bind sources and uid.

### Phase 2: Apply the volume contract

1. Adjust the fetching stack's root-folder paths and the serving
   stack's library mounts to the tree above.
2. Verification: chaptarr's root folders and audiobookshelf's libraries
   resolve to the same host inodes (`stat` the host dirs).

### Phase 3: Verify isolation and ordering

1. Verification: the serving containers cannot resolve or reach
   gluetun/deluge; the fetching containers cannot reach the serving
   exposure (R-3). Confirm the teardown rule (R-5) in the runbook.

### Phase 4: Prove end to end

1. Grab a known book through the full chain.
2. Verification: it appears in the server within one scan interval,
   playable, and md5-identical to the source file (R-6; this subsumes
   the dependencies' import tests at the composition level).

## Verification and Acceptance

- **A-1** (R-1): both stacks' bind mounts resolve to identical host
  paths under MEDIA_ROOT; `findmnt`/`docker inspect` agree.
- **A-2** (R-2): a write attempt from the serving container inside a
  library fails; the same attempt from chaptarr succeeds.
- **A-3** (R-3): from an audiobookshelf container, connecting to
  `gluetun:8112` fails (no route); from the tailnet, the fetching UIs
  and the serving surface are reachable only per their own exposure
  rules.
- **A-4** (R-4): one env file feeds both stacks; changing MEDIA_ROOT in
  it and recreating moves BOTH stacks' binds together.
- **A-5** (R-5): a scripted down-up cycle follows the documented order
  and the kill-switch test (fetch-books-over-vpn A-1) still passes after.
- **A-6** (R-6): the full grab-to-play chain completes without manual
  file moves; the file is byte-identical in the library.

## Failure Modes and Rollback

- **Import lands, server blind**: volume contract drifted (paths
  differ). Re-check Phase 2; `stat` both views of the same logical dir.
- **Serving side can reach the VPN netns**: someone added a shared
  network. Remove it; R-3 has no waivers.
- **Parameters drift between stacks**: R-4 broken; consolidate back to
  the one env file.
- **Rollback**: decompose, don't debug entanglement: `docker compose
  down` both stacks, re-verify each stack's own tests in isolation,
  then reapply the glue. The parts must always pass alone first.

## Removal

1. Remove the serving stack (its own Removal).
2. Remove the fetching stack (its own Removal).
3. The shared media tree and the env file persist; they are the
   operator's data, not the composition's.

## Decisions and Open Questions

Decisions:

- 2026-09-10: This package is deliberately contentless (no images, no
  services) - a composition schematic earns its place only if the glue
  alone is non-trivial: the shared volume contract, the isolation rule,
  and the reconciliation of duplicated parameters. If it needed images,
  it would be a third ordinary schematic, not a composition.
- 2026-09-11: Dependency links upgraded to commit-pinned remote URLs with
  content SHA-256 (convention v2; see improve-docker-security's
  composition-convention module). Relative links are gone: the pinned
  URL is the version-of-record for the contract.

Open questions:

- **Q-1**: Whether the format should gain a `composes:` field in the
  marketplace catalog so the site can render composition edges natively
  (the site currently shows composition via this schematic's
  description). Leaning yes once a second composition schematic exists
  to justify the field.
