# Module: read-only posture

The serving stack reads the same tree the fetching stack writes. Two
writers on a media library are how metadata gets corrupted and imports
get double-moved; the boundary in this stack is one-directional.

## The boundary

- Fetching side (fetch-books-over-vpn): owns the files. Imports rename and
  move within the tree, tag, and organize per library format.
- Serving side (this schematic): mounts libraries `:ro` and only reads.
  Its writable surface is exactly two paths: config and metadata.

## Why the server never writes libraries

1. ABS can rename and relocate on "move" operations; if it did, the
   importer's db would point at paths that no longer exist, and the
   next import would fail or duplicate.
2. A read-only mount turns a server bug or a misconfigured "organize"
   feature into a permission error instead of silent file churn.
3. It makes the contract testable (A-2): attempt a write inside the
   mount, expect failure.

## What stays writable, and why it is safe

- **Config** (`/config`): server settings, users, library definitions.
- **Metadata** (`/metadata`): per-user progress, sessions, item
  metadata. Both live under P-5, outside any library folder - which is
  also why the metadata path is a separate host directory, never a
  subfolder of a library.

## The scan instead of the move

Because the importer writes in place and the server only scans, an
import is just: file lands -> ABS notices (scan interval or manual
scan) -> playable. No "media server sync" job, no rsync, no copy
between stacks. If someone proposes adding a move step between the
stacks, that is the boundary regressing - decline and point here.
