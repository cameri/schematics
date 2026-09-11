# Module: indexer topology

Prowlarr is the single authority on indexers; the arrs are consumers.
This module records why that shape beats per-app indexer config, and the
sync ordering that keeps it true.

## Why one authority

- Indexer credentials and rate limits are per-operator, not per-app.
  Configuring them once removes a whole class of drift ("Radarr's copy
  of this indexer still has the old API key").
- Adding an indexer becomes one operation (R-2) instead of N.
- Health monitoring lives in one place: Prowlarr's indexer status page
  is the first stop when grabs stop flowing.

## Sync order

1. Prowlarr: add indexer, test, confirm query works.
2. Prowlarr → Sonarr / Radarr / (Lidarr where present) via its sync
   profiles; each arr gets the indexer with a mapped category.
3. In each arr: confirm the indexer appears and a test search returns
   results.

## Categories are the collision avoidance

Prowlarr maps each indexer's categories to per-app categories (5000 =
TV, 2000 = movies, 3000 = audio). Keep those mappings deliberate: a
mis-mapped category sends Sonarr after music packs or Lidarr after box
sets.

## When an indexer needs flaresolverr

Cloudflare-gated indexers fail Prowlarr's test with an HTML challenge
page. Attach flaresolverr, set the indexer's flaresolverr base URL in
Prowlarr, retest. Flaresolverr is a browser in a can - keep it optional
(D-8) and only on for indexers that need it.
