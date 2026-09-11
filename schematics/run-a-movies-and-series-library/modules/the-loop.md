# Module: the loop

The composition's job is a cycle, not two stacks. This module is the
chain and its known weak links.

## The chain

```
Jellyseerr "I want X"
  → Radarr/Sonarr search (Prowlarr indexers)
  → grab → SABnzbd queue → download → complete
  → unpackerr extracts
  → arr imports (move) into tvseries/ or movies/
  → Jellyfin scan → playable; Jellyseerr marks available
```

Each arrow is a dependency's own contract (path contract, indexer
topology, request front). The composition adds none and forbids
bypasses: Jellyseerr never touches the filesystem; SABnzbd never
imports into libraries; Jellyfin never asks for grabs.

## Where the loop actually breaks (in order of frequency)

1. **Path mapping drift** between halves - the "import failed" class.
   Fix per the path-contract module; never hand-copy files.
2. **Indexer health** - Prowlarr's status page first; flaresolverr for
   gated ones.
3. **Quality-profile deadlocks** - a profile demanding a format no
   indexer carries; grabs never appear. Profile review, not retries.
4. **Scan lag** - looks like "not served yet" but is just the scan
   interval; distinguish before debugging.

## The handoff test

A-2 is the loop test and it is intentionally end-to-end: one real
request, timed hands-off, file hash unchanged, playable at the end.
Any intermediate green check that cannot survive this test is
decorating.
