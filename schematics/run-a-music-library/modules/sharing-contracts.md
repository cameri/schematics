# Module: sharing contracts

Three media kinds, one pipeline. This module is the full set of
collision rules that make sharing work - the composition's core
contribution over its parts.

## The rules

### 1. One instance per infrastructure service

Prowlarr, SABnzbd, Jellyfin: exactly one each. A "music instance" of
any of them is a violation (R-1/R-3). Sharing is the design; isolation
problems get solved by categories, not clones.

### 2. Categories are the only separation

| Service | Separation mechanism |
|---------|---------------------|
| Prowlarr | Sync categories per arr (TV 5000, movies 2000, audio 3000) |
| SABnzbd | Per-client category on each arr's download-client entry |
| Jellyfin | Library-level: each media kind is its own library with its own root |

### 3. Mounts are per-root, never per-stack

Every part binds the shared tree at the same root (or the subtree it
owns). No part binds another part's config state. The server reads
libraries read-only; only the arrs write library data.

### 4. Queue control is shared (the accepted trade)

One arr's pause or priority change affects the shared queue. Coordinate
by operator discipline. If this ever breaks down, the fix is a spec
change to split the downloader per kind - not an undocumented second
instance.

### 5. Upgrades of shared infra test all consumers

Upgrading Prowlarr/SABnzbd/Jellyfin affects every media kind at once.
The upgrade runbook per package applies, but the verification matrix is
cross-media: after an upgrade of shared infra, run each consumer loop's
test (a series grab, a movie grab, an album grab), not just the one you
were thinking about.
