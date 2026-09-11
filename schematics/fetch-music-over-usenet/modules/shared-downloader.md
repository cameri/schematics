# Module: shared downloader

Music fetching adds no downloader and no indexer manager. It registers
with the ones the movies/series stack already runs. This module is the
rationale and the collision rules.

## Why share

- SABnzbd is per-provider, not per-media-type: the provider account,
  connection limits, and server configs are operator-level facts.
  Duplicating them doubles the failure surface and halves the clarity
  of "what is downloading right now".
- Prowlarr is the single indexer authority (its module in
  `fetch-movies-and-series` says why). A second indexer manager for
  music would recreate exactly the drift problem that module exists to
  prevent.

## Category separation (the collision rules)

| Concern | Mechanism |
|---------|-----------|
| Which arr sees which indexer content | Prowlarr sync categories: 5000 TV, 2000 movies, 3000 audio |
| Which downloads go where | SABnzbd per-client category: each arr's download-client entry carries its own category (`tv`, `movies`, `music`), which maps to its post-processing dir |
| Who may pause/restart whose queue | Nothing at the category level - SABnzbd is shared, so one arr pausing affects all. This is the accepted trade: coordination via operator discipline, not isolation |

If isolation of queue control ever becomes necessary, that is the point
to reconsider sharing - as a deliberate spec change, not an ad hoc
second instance.
