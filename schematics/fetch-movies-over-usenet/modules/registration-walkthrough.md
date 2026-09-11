# Module: registration walkthrough

The three-part registration contract of `fetch-over-usenet`, applied
concretely to Radarr. Any arr registering with the shared infrastructure
follows the same shape; this module is the worked example.

## Part 1: Indexer side (Prowlarr)

1. In Prowlarr: Settings > Apps > add Radarr; give it the movies
   category (P-6's map: 2000) and Radarr's API key + base URL.
2. Sync applies indexers into Radarr with that category - Radarr never
   sees an indexer configured by hand.
3. Verify: Radarr's indexer list matches Prowlarr's movies-capable
   indexers after sync.

## Part 2: Downloader side (SABnzbd)

1. In Radarr: Settings > Download Clients > add SABnzbd (host, API
   key, category `movies`).
2. The category creates SABnzbd's per-client post-processing dir and
   keeps movie grabs separable from other kinds' queues.
3. Verify: a test grab in Radarr appears in SABnzbd's queue under the
   movies category, not another kind's.

## Part 3: Mount side

Radarr's container mounts (logical names must match what SABnzbd
reports):

```
${DOWNLOADS}/complete  ->  /downloads   # same name SABnzbd reports
${MOVIES_ROOT}         ->  /movies      # import target
```

If the shared infra reports `/media/downloads/complete`, Radarr's mount
must make that same path resolvable - identical names, or a Remote Path
Mapping that translates exactly once. Two translations or a guessed one
are how "import failed: file not found" is born.

## The checklist, compressed

Indexer sync: category set, appears after sync. Download client:
category set, test grab lands in the right queue. Mounts: complete-dir
name matches SABnzbd's reports; library root matches the server's view.
Three checks, then the arr's own Phase 2 begins.
