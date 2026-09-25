# Backup and restore runbook

Two artefacts, one moment. This runbook is the procedure A-6 and A-8 check; the
rehearsal in step 4 is not optional, because a backup that has never been
restored is a hope rather than a copy.

Replace `<...>` placeholders with this deployment's values from the host
parameter record. Never write a password into this file.

## What is being protected

| Path | Content | If lost |
|------|---------|---------|
| `${DB_DATA_LOCATION}` (via a database dump) | albums, people, users, the path of every asset | The library becomes unlabelled files |
| `${UPLOAD_LOCATION}/upload`, `profile`, and `library` when present | the originals and avatars | The photos themselves — unrecoverable |
| `${UPLOAD_LOCATION}/thumbs`, `encoded-video` | previews and re-encoded video | Slower browsing until jobs re-run |
| `${UPLOAD_LOCATION}/backups` | the instance's own dumps | Nothing, if the operator keeps their own copy elsewhere |
| Model-cache volume | downloaded models | A re-download |

## 1. Take a backup

Prefer stopping the server for the duration: frozen, both halves belong to the
same moment by construction.

```sh
cd <project-directory>
docker compose stop immich-server immich-machine-learning

# Database first - it is the half that would otherwise point at files the copy
# does not have. Write to a temporary name and prove the dump is complete before
# replacing anything: a failed pg_dump still leaves a readable (nearly empty)
# archive, so a day-only filename would overwrite a good dump with a bad one.
dump="<BACKUP_TARGET>/dump-$(date +%Y-%m-%d).sql.gz"
raw="${dump}.part"
bad=0
docker compose exec -T database pg_dump --clean --if-exists \
  -U "<DB_USERNAME>" "<DB_DATABASE_NAME>" > "$raw" || bad=1
[ -s "$raw" ] || bad=1
grep -q 'database dump complete' "$raw" 2>/dev/null || bad=1
if [ "$bad" -eq 0 ]; then
  gzip -c "$raw" > "$dump" && rm -f "$raw"
else
  echo "dump incomplete - $dump is untouched" >&2
  rm -f "$raw"
fi

# Then the filesystem: the upload location is one host path, so copy it whole.
# When space is tight, `upload/` and `library/` hold the originals and `profile/`
# the avatars - those are the irreplaceable ones - while `thumbs/` and
# `encoded-video/` regenerate and `backups/` is the instance's own copy.
cp -a "<UPLOAD_LOCATION>/." "<BACKUP_TARGET>/upload-location/"

docker compose start immich-server immich-machine-learning
```

If the instance must stay up, keep the same order and know what it buys: a file
uploaded between the dump and the copy is an extra the database has not recorded
yet, which is harmless; a photo **deleted or moved** in that window is a row
pointing at an original the copy no longer holds. The pair is consistent only
while nothing writes, so keep the window short - and prefer the stop above, where
both halves belong to the same moment by construction.

Keep at least one copy on a device that is not the one holding the library, and
check the copy is readable rather than only present.

## 2. Recognise a half-applied backup

- Dump present, files absent: not a backup. Take the copy.
- Files present, dump absent: restore gives an empty library with the bytes on
  disk. Take the dump.
- Copy in progress when the run was interrupted: the archive's size keeps
  changing. Re-run the step rather than resuming by hand.

## 3. Restore into production

Use the application's own restore path when the instance is reachable:
`Administration → Maintenance → Restore database backup`. It takes a restore
point first and rolls back if the restore fails. A restore replaces the current
database, so anything uploaded since the backup is lost unless it also exists in
the file copy.

When the instance is not reachable, the procedure that matters is the rehearsal
below, driven from a fresh database.

## 4. Rehearse the restore (acceptance test A-8)

This proves the backup, using a scratch copy so nothing in production is at risk.

```sh
# 1. A scratch directory pair — same filesystem types as production.
mkdir -p /tmp/immich-rehearsal/data /tmp/immich-rehearsal/postgres
cp -a "<BACKUP_TARGET>/upload-location/." /tmp/immich-rehearsal/data/

# 2. A scratch project. All three project files are needed: the Compose file
#    extends hwaccel.ml.yml, so copying compose.yml alone leaves the stack
#    unable to load.
cd <project-directory>
cp compose.yml hwaccel.ml.yml .env /tmp/immich-rehearsal/
cd /tmp/immich-rehearsal
#    edit: UPLOAD_LOCATION, DB_DATA_LOCATION, HTTP_PORT

# 3. Give the rehearsal its own identity. Production's Compose file fixes the
#    project name and all four container names, so without these two changes the
#    scratch stack cannot start beside production and the `down -v` below would
#    target production's own containers.
cat > renames.override.yml <<'YAML'
services:
  immich-server:
    container_name: immich_rehearsal_server
  immich-machine-learning:
    container_name: immich_rehearsal_machine_learning
  redis:
    container_name: immich_rehearsal_redis
  database:
    container_name: immich_rehearsal_postgres
YAML
compose="docker compose -p immich-rehearsal -f compose.yml -f renames.override.yml"

# 4. Start the database alone and restore into it, with migrations held back so
#    the restore itself is what defines the schema.
$compose up -d database
gunzip -c "<BACKUP_TARGET>/dump-<date>.sql.gz" \
  | $compose exec -T database psql -U "<DB_USERNAME>" -d "<DB_DATABASE_NAME>" \
      --single-transaction --set ON_ERROR_STOP=on

# 5. Start the rest and look at a photograph that predates the backup.
$compose up -d
```

Expected result: the scratch instance opens, the timeline is as the backup left
it, and an original photo renders. Record the date you rehearsed and the photo
you opened in the host parameter record.

If the restore fails with relation or foreign-key errors, the database was not
fresh. Start only the database with `DB_SKIP_MIGRATIONS=true` set for the server
so it cannot migrate while you restore, then unset it and start the server.

Clean up afterwards — the project name and the override file are what keep this
`down` from touching production:

```sh
cd /tmp/immich-rehearsal
docker compose -p immich-rehearsal -f compose.yml -f renames.override.yml down -v
rm -rf /tmp/immich-rehearsal
```

## 5. Removing the scratch project

`down -v` in the scratch directory removes its cache volume only; the scratch
paths under `/tmp` hold copies of real photos, so delete them explicitly, as
above.
