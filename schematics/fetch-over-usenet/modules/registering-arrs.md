# Module: registering arrs

The interface any media-specific fetch schematic consumes to join this
pipeline. This is the contract the arr packages (movies, series, music,
books) are written against; this package validates it only at their
boundaries, not inside their internals.

## The three-part registration (the interface)

1. **Indexer side**: the arr appears as a Prowlarr sync target claiming
   exactly one category from P-6's map.
2. **Downloader side**: the arr appears in SABnzbd as a download client
   with its own category.
3. **Mount side**: the arr mounts `downloads/complete` and its library
   root with logical names matching what SABnzbd reports.

Plus two prohibitions that keep the sharing honest:

- No registering arr configures indexers directly (R-2's corollary).
- No registering arr deploys its own downloader, unpackerr, Bazarr, or
  flaresolverr - if it needs one of them, THIS package's phases cover
  it.

## Category map (P-6) as the registry

| Category | Meaning | Claimed by |
|----------|---------|------------|
| tv=5000 | Series | fetch-series-over-usenet |
| movies=2000 | Movies | fetch-movies-over-usenet |
| audio=3000 | Music | fetch-music-over-usenet |
| books=7000 | Books | (book stacks, if they join) |

Adding a media kind = adding its row here plus a new arr package. Two
arrs claiming one category is a spec bug, not a config fix.

## What this package owes its registrants

- Stable completion paths (R-1) and stable category map (P-6)
- Indexer health visibility (Prowlarr's status page is the shared
  first stop when any kind's grabs stall)
- Extraction coverage (unpackerr watches ALL clients' archives, not
  one arr's)
- If Bazarr is deployed: subtitle wiring to arrs as they register
