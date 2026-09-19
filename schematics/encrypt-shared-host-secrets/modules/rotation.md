# Module: Rotation

Rotating a shared value is one command plus the consumers the inventory names.
What makes it different from rotating a per-service store is that the consumer
set is not knowable from the file: the store has no idea who reads it, so the
inventory is the authority, and a consumer missing from the restart list keeps
serving the old value with no symptom.

## Purpose

Owns changing a value in the store end to end: the projections that carry it,
the restart or re-invocation of each consumer, the read-back that proves the new
value arrived, and the records to update. It does **not** own the store's format
(`store-and-projections.md`) or the parse-time mechanics
(`compose-interpolation.md`).

## Inputs

- `P-2 STORE_FILE`, the key to rotate, and the new value (stdin or
  `--value-file`, or an already-encoded value with `--value-json`).
- The inventory (`P-12`): every consumer that reads that key, with its class
  and its restart mechanism (unit name, container service, cron entry, script).
- `P-9 CONSUMER_KEY_PATTERN` for every projection that carries the key.
- `scripts/sops-shared.sh set` and `extract`.

Error inputs tolerated: a value containing spaces, quotes or `=` (it is written
as one dotenv line; a raw value with a leading or trailing newline is refused,
so `echo value | sops-shared.sh set …` fails loudly instead of storing the
newline — `--value-json` is the way in for a value that must keep one); a key that
does not exist yet (`set` creates it); a consumer that is already stopped
(skipped, and recorded as such).

## Outputs

- The store with the new ciphertext for that key and an unchanged recipient
  list.
- Every projection containing the key, regenerated from the store.
- Each consumer restarted or re-invoked, showing the new value through its own
  path.
- The inventory's `last rotated` note for that key (a date and the consumer
  count) — a fact about the deployment, not about this package.

**The procedure, for a key `NAME`:**

1. `scripts/sops-shared.sh set "${STORE_FILE}" NAME` with the value on stdin
   (masked prompt, `--value-file` or `--value-json`); the plaintext never reaches argv or
   history.
2. For every projection the inventory lists as carrying `NAME`:
   `scripts/sops-shared.sh extract "${STORE_FILE}" "${PROJECTION_PATTERN}" "<its keys>" --consumer-key "<its key file>"`.
   A projection that is not regenerated serves the old value indefinitely.
3. Restart or re-invoke, per class:
   - **Wrappable** — re-run the consumer (systemd: `systemctl restart <unit>`;
     cron: the next run; a documented command: re-run it). A long-lived
     process that holds the value only in its environment keeps the old value
     until it restarts; if it cannot be restarted, its inventory row says so.
   - **Path-reading (remedy (a))** — restart the consumer; the wrapper
     re-decrypts at start.
   - **Path-reading (remedy (b))** — regenerate the materialized file for the
     next invocation; a file materialized for a running consumer is stale until
     that consumer restarts.
   - **Parse-time** — the value is read at parse time, so the stack must be
     brought up again through the same wrapped or materialized invocation. A
     stack left running holds whatever it resolved at parse time; `docker
     compose up -d` alone does not re-interpolate a running container's
     environment, so the value that matters is the one the next parse sees.
   - **Container (`D-5`)** — `docker compose restart <service>` after the
     container's store is re-encrypted; no image rebuild (`R-8`).
4. Read the value back **through each consumer's own path**, never from the
   store: the store always shows the new value, and that is exactly what a
   stale projection, an un-restarted process and an unredeployed stack all hide.
5. Confirm no image was rebuilt: `docker image inspect <image> --format
   '{{.Created}}'` is unchanged for every container consumer.

## Dependencies

- `D-1`, `D-2` for the sops operations; `D-4` for value encoding.
- `P-2`, `P-9`, `P-12`.
- `D-5` for a container consumer's restart.

## Failure Behavior

- **A projection not regenerated.** Its consumer reads the old value; the store
  and the operator's own checks disagree with reality. Detect: step 4's
  read-back through the consumer's path, and `A-8`. Remedy: regenerate, then
  restart that consumer again.
- **A consumer not restarted.** Same symptom, different cause; the consumer's
  own log line at start names the value's fingerprint, not the value.
  Detect: the inventory's restart step for that consumer was not run. Remedy:
  run it.
- **A value written with a trailing newline or a quoting artefact.** The
  consumer receives a value that fails an API call with an authentication error
  naming nothing. Detect: the store line ends in `sops_encrypted` markers with
  no stray content, and `extract`'s output shows one line per key. Remedy:
  re-set the value.
- **The store's recipient list lost during a re-encryption.** Every projection
  generated afterwards is encrypted to fewer recipients than intended.
  Detect: `A-7`'s count, and the missing-key error at the consumer. Remedy:
  restore the ciphertext from version control and re-set the value.
- **Rotation attempted with the master key unavailable.** Nothing can be
  re-encrypted; the store stays as it is. Detect: `set` exits non-zero with a
  key error. Remedy: restore the master key from its off-repository copy; there
  is no alternative path.
- **A parse-time value rotated but the stack never re-parsed.** The running
  containers keep the old value while the store holds the new one. Detect:
  `docker compose config` shows the new value while the container's environment
  shows the old. Remedy: bring the stack down and up through the wrapped
  invocation.

## Idempotency Notes

`set` is a replacement, not an append: re-running it with the same value leaves
the file byte-identical apart from SOPS's own encryption randomness, which is
why the check is the decrypted content and never the file's hash. `extract`
converges a projection on the store's current content, so the recovery from a
stale projection is the same command as the rotation step. The read-back in step
4 is repeatable and starts nothing.

## Removal Notes

Rotation leaves no state to remove: it changes values that exist only in the
store, the projections and the consumers' own environments. The inventory's
`last rotated` note stays with the inventory when the capability is removed —
it records what the store holds, which is useful even after the wiring is gone.
