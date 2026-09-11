# Module: volume contract

The exact host tree both stacks share, who writes what, and the mounts
each side takes. This is the composition's core artifact; treat changes
to it as a spec change, not a config tweak.

```
<MEDIA_ROOT>/                     # one host root, parameterized as P-1
  downloads/
    incomplete/                   # deluge writes (active downloads)
    complete/                     # deluge writes; chaptarr imports from
  books/                          # chaptarr imports (rw) ; ABS reads (:ro)
  audiobooks/                     # same pair as books
  podcasts/                       # ABS only (manual content, :ro for ABS
                                  # would block nothing since only ABS
                                  # touches it; keep :ro for posture)
  apps/
    chaptarr/                     # chaptarr state
    deluge/                       # deluge state
    mousehole/                    # mousehole state (incl. the session)
    audiobookshelf/               # ABS state (config + metadata)
```

## Mount table

| Path | Fetching stack | Serving stack |
|------|----------------|---------------|
| `downloads/incomplete`, `downloads/complete` | rw | not mounted |
| `books`, `audiobooks` | rw (import target) | :ro (library source) |
| `podcasts` | not mounted | :ro |
| `apps/<their own>` | rw, per app | rw, per app |

## Rules encoded by this table

1. Exactly one writer per path: fetchers own media data, the server owns
   only `apps/audiobookshelf`.
2. The server never mounts `downloads/` - it has no business there, and
   not mounting it removes the temptation to "just move it myself".
3. State lives under `apps/`, never inside library folders - metadata
   next to books is how libraries grow junk directories that scanners
   index.

## Adding a path

A new shared path (say `manga/`) means: add it to this tree, decide the
writer, add the row to the table, add the mounts to the two packages'
compose, and extend A-1's check. Doing it purely as compose edits on
one host is how the contract silently forks from the spec.
