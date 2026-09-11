# Module: recommended attachments

Where the recommended (optional) dependencies attach; declining any
keeps R-6 intact.

## RD-1: improve-docker-security

- **Attaches at Phase 3**, after the loop works. Wraps the host in the
  three hardening layers; the stack's API keys move into encrypted
  secrets.
- **Integration risk**: same as everywhere - the scoped proxy allowlist
  must cover every Docker-API call the loop's members make; re-run the
  scoping derivation if A-4 breaks after attaching.

## RD-2: update-images-on-push

- **Attaches at Phase 3**, for registry-pushed images only. Pulls only,
  never recreates containers; upgrades otherwise stay manual.

## RD-3: run-a-movies-and-series-library

- **Attaches whenever the operator wants the request-driven loop for
  movies and series** around the same shared infrastructure. This is
  the same Jellyfin, Prowlarr, and SABnzbd gaining the request front
  and the movies/series arrs' full loop.
- **What declining means**: music-only deployment. The shared
  infrastructure still exists (D-3 owns it; D-4's server still serves),
  just without Jellyseerr and the movies/series request flow.
- **Order note**: RD-3 composes the same D-3/D-4 packages this
  composition depends on. Deploy it after this composition's Phase 2 so
  its loop test runs against an already-shared, already-working base.
