# Module: media-storage

The upload location: its layout, which folders are irreplaceable, how existing
directories join the library without being moved, and the backup contract that
keeps the files and the database in one consistent pair.

## Purpose

This module owns every byte the library keeps on disk — originals, generated
content, the instance's own database dumps, and the model cache — and the
rules for backing them up. It is NOT responsible for the database's own
directory, which belongs to `data-layer`, and it does not decide when a scan
runs.

## Inputs

- `${UPLOAD_LOCATION}` on host storage with room for originals plus generated
  content.
- The `STORAGE_OWNER` the container must be able to write as.
- `EXTERNAL_LIBRARY_PATHS`, when directories the operator already owns are to be
  indexed.
- `BACKUP_TARGET` for the backup half of the contract.

## Outputs

- A mounted `/data` inside the server container containing, once the instance is
  in use:
  - `upload/<user>/` — originals uploaded through the browser, mobile apps, or
    the CLI. Irreplaceable.
  - `profile/<user>/` — avatars. Irreplaceable, tiny.
  - `library/` — originals, present only when the storage-template engine is
    enabled, which moves new uploads into a generated structure. Irreplaceable
    when present.
  - `thumbs/<user>/` and `encoded-video/<user>/` — generated previews and
    re-encoded video. Re-creatable by re-running jobs, at the cost of a long
    pass.
  - `backups/` — the instance's own database dumps, written on a schedule the
    administration settings control.
- A model-cache volume belonging to `machine-learning`.
- A backup under `${BACKUP_TARGET}` holding a database dump and a copy of the
  originals from the same run.

## Dependencies

- D-6 (host storage), D-1 (Docker Engine + Compose).
- P-1, P-21, P-22, P-23.
- From `data-layer`: the dump job that writes into `backups/`.

## Failure Behavior

- **The container cannot write to `${UPLOAD_LOCATION}`.** Uploads fail with a
  permission error visible in the server log; the UI may accept the file and then
  show a failed upload. Check ownership (P-21) before suspecting the application.
- **Files moved, renamed, or deleted outside the application.** Immich stores
  paths in the database and does not scan the upload location, so an external
  change produces missing or untracked assets rather than a rescan that fixes
  itself. The files are the application's to manage; the operator's access is
  through the UI, or through a copy taken for backup.
- **A backup of one half only.** A database restored without its files references
  assets that are absent, and files restored without their database appear as an
  empty library with the bytes still on disk. Both halves are required, and the
  order matters: with the server stopped the pair is consistent by construction;
  without stopping it, the database goes first, so the worst case is files the
  database has not yet heard of rather than a database pointing at files that
  never made it into the copy.
- **External library mounted read-write by accident.** A mount without the
  read-only marker lets the application delete files the operator never uploaded
  into it. The mount is the guard; there is no setting that substitutes for it.
- **An external library's files moved after Immich has indexed them.** Metadata
  attached inside Immich is lost on the next scan, because the asset is treated
  as a new one. Moving files is a decision that must be made outside Immich and
  knowingly.

## Idempotency Notes

- Taking a backup twice in a row is safe; the second copy is simply newer. The
  dump's filename should carry the date, and old copies are removed by the
  operator's own retention, not by Immich.
- The instance's own automatic dumps are written into `backups/` on their own
  schedule and count against a retention limit set in the administration
  settings; they are not a substitute for the operator's backup, because they
  live inside the very directory being backed up.
- Re-running a scan of an external library is safe and re-reads the disk; it does
  not move or modify the mounted files.
- Re-running thumbnail and preview generation is safe and re-creates only what is
  missing.

## The backup contract

Two artefacts, one moment. The database contains the library's organisation —
albums, people, the path of every asset — and the upload location contains the
assets themselves. Neither is a backup of the other.

The procedure the rehearsal in `templates/backup-and-restore.md` follows:

1. Prefer stopping the server for the duration; then both halves are frozen and
   the copy is consistent by construction.
2. If the instance must stay up, take the database first and the files second.
3. Copy the originals folders (`upload/`, `profile/`, and `library/` when the
   storage-template engine is enabled). Generated content may be omitted, at the
   price of re-running thumbnail and video jobs after a restore.
4. Restore into a scratch path once, and open a photograph that predates the
   backup. A backup that has never been restored is a hope.

## Removal Notes

Deleting the compose project removes no files: `${UPLOAD_LOCATION}` is a bind
mount. The originals are ordinary files in `upload/`, and, when the
storage-template engine is enabled, in `library/` under a generated structure;
either way the library remains readable without Immich, minus everything the
database knew about it. The model-cache volume is safe to delete. External
library mounts leave their directories exactly as they were.
