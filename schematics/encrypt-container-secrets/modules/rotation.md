# Module: Rotation

Changing a secret value, and adding or replacing a recipient, without
rebuilding anything.

## Purpose

Defines the operator-facing operations on an encrypted file: set one value,
re-encrypt to a recipient pair, and confirm the change took effect in the
running service. It does **not** define the key material
(`key-hierarchy.md`) or the boot path (`env-secrets.md`), only how the
committed ciphertext is edited and rolled out.

## Inputs

- `P-4 ENV_FILE`: the file to edit.
- `P-2 MASTER_KEY_FILE`: the host-side key that makes the file readable
  without any container.
- The service's dedicated public key: required only when re-encrypting; it is
  recoverable from the file itself with `grep -o 'age1[a-z0-9]*'`.
- `SERVICE_NAME`: to locate `${KEY_DIR}/${SERVICE_NAME}-keys.txt` and print
  the correct restart command hint.

Error inputs tolerated: a value containing quotes, backslashes, or newlines
(the set path JSON-encodes it); a value supplied from a file instead of a
prompt; an `sops` binary absent from the host (the script runs it in `P-7`
instead).

## Outputs

- The same `P-4` file, re-encrypted, with the changed value and an unchanged
  recipient set.
- A 0600 temp file that is removed on exit; the value never appears in argv,
  shell history, or any process's command line.

Two operations, both in `scripts/`:

```
sops-set-env.sh [--value-file <path>] [--age-key <path>] <env-file> <ENV_NAME>
sops-prepare-service.sh <service-dir> [--key <age1...>]
```

Rollout: `docker restart <service>`, the container re-decrypts at start
(`env-secrets.md`), so the new value is live with no rebuild.

## Dependencies

- `D-2` (sops: host binary or the `P-7` image), `D-5` (`python3` or `jq` to
  JSON-encode the value), `D-3` (docker, for the restart and for the
  image-backed fallback).

## Failure Behavior

- Empty value: `sops-set-env.sh` refuses before touching the file: an empty
  secret is nearly always a mistake (a paste that did not land).
- No `python3` and no `jq`: hard fail with an explicit message; pass
  `--value-file` with a pre-encoded value to proceed.
- Re-encryption that silently drops a value: guarded by the backup-then-verify
  sequence below; a recipient-list check after writing is mandatory.
- Encrypted with the wrong recipient set (e.g. only the dedicated key): the
  host can no longer read the file with the master key. Detect with
  `grep -o 'age1[a-z0-9]*'`; fix by re-encrypting to both recipients.
- Value with literal quotes in the store: surfaces as a mangled application
  value (`env-secrets.md` covers the symptom). Re-set it through the script,
  which never adds quotes.

## Idempotency Notes

`set` on an existing key replaces that key and leaves other values intact;
re-running with the same value rewrites the ciphertext but changes nothing
semantically. `sops-prepare-service.sh` is idempotent for the same recipient
pair. Safe re-run sequence for a real change:

```sh
cp "$ENV_FILE" "$ENV_FILE.bak"                       # 1. backup
scripts/sops-set-env.sh "$ENV_FILE" SOME_SECRET      # 2. masked prompt
diff <(grep -c '^' "$ENV_FILE.bak") <(grep -c '^' "$ENV_FILE")   # 3. same line count
grep -o 'age1[a-z0-9]*' "$ENV_FILE" | sort -u        # 4. same recipients
docker restart <service>                             # 5. activate
rm "$ENV_FILE.bak"                                   # 6. clean up
```

Completion detection: step 4 lists exactly two recipients and the Phase 7
environment count matches the new value's presence.

## Removal Notes

Adds the two helper scripts (repository-local, no host install) and nothing
else. Removing the capability deletes them along with the wiring in
SCHEMATIC.md → Removal; no host state, cron entry, or global config is
involved, and the encrypted file remains readable with the master key
regardless.
