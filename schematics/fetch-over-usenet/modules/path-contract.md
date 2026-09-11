# Module: path contract

The one agreement that makes downloader, arrs, and server work as a
pipeline: everyone sees the SAME host tree with the SAME logical names.

## The contract

```
${MEDIA_ROOT}/
  downloads/
    incomplete/     # SABnzbd writes here while downloading
    complete/       # SABnzbd moves here on completion (per-release dir)
  tvseries/         # Sonarr's import target  = the server's library
  movies/           # Radarr's import target  = the server's library
  config/           # per-app state, never media
```

Rules:

1. **Identical mapping everywhere.** If Sonarr sees the completed dir as
   `/downloads`, SABnzbd must REPORT that same path in its API. Mismatched
   remote mappings are the number-one cause of "import failed: file not
   found" - the arr reads SABnzbd's reported path and looks for it under
   its own mount names.
2. **One writer per path.** SABnzbd owns `downloads/`; the arrs own
   their library roots (they move files in); the server is read-only
   over libraries.
3. **Import is a move, not a copy** (same filesystem): instant, no
   duplicate space, and the server's next scan picks it up.

## Failure signature to recognize

`Import failed: Unable to determine file` or paths like
`/downloads/...` inside an arr whose mount is `/media/downloads/...`:
a remote-path mapping problem, not a broken download. Fix the mapping
(arr settings: Remote Path Mappings, or unify the mount names) - never
"fix" it by copying files by hand.
