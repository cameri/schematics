# Module: season handling

Series are the one media kind where the release shape varies: a single
episode, a multi-episode file, or a full season pack. The profile
decides which shapes are acceptable; this module records how the shapes
flow through the shared pipeline.

## The three shapes

| Shape | Usenet origin | unpackerr's role | Import behavior |
|-------|---------------|------------------|-----------------|
| Single episode | One nzb per episode | Nothing to do | Imports immediately on completion |
| Multi-episode file | One nzb containing E1-E2 | Extracts if archived | Sonarr splits on import (per its mapping) |
| Season pack | One huge nzb or archive | Extracts into place; cleanup matters most here | Sonarr imports all episodes at once |

## Profile guidance (R-3 in practice)

- Prefer season packs for bulk acquisition (a monitored series' back
  catalog) and single episodes for ongoing shows - Sonarr's quality
  profiles can express both via "Season Pack" filtering.
- Archive-heavy season packs are where unpackerr earns its place: a
  packed RAR set lands in `complete/`, unpackerr extracts it in place,
  and Sonarr imports only after extraction completes. Without unpackerr
  the import fails with "video not found inside" - that error means the
  extraction step, not Sonarr.
- Disk ceiling: a season pack occupies roughly double its size between
  completion and import cleanup. If `complete/` fills, imports stall
  globally (shared infra) - the reclaimerr option exists for this.

## The failure signature to recognize

"Import failed: no video files found in the downloaded season" with the
archive still sitting in `complete/`: unpackerr is down or lagging, not
a Sonarr problem. Check unpackerr's log before retriggering searches -
retriggering on an unextracted pack doubles the storage cost for zero
gain.
