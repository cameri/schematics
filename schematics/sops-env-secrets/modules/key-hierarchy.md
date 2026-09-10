# Module: Key Hierarchy

Two-tier age key model: a host-only **master** key and a **dedicated
per-service** key. Every encrypted file is readable by both; every container
receives only the dedicated one.

## Purpose

Defines which keys exist, where they live, who can use them, and what
`age1…` recipients an encrypted file must list. It does **not** cover how
values are written into the file (that is `rotation.md`) or how the file is
mounted (that is `env-secrets.md`), it only defines the key material and the
recipient contract those modules depend on.

## Inputs

- `P-1 KEY_DIR`: host directory. Must exist; created with mode `700` in
  Phase 2 if absent.
- `P-2 MASTER_KEY_FILE`: `${KEY_DIR}/keys.txt`. May be absent on first run,
  in which case it is generated; if present it is **never** regenerated.
- `P-3 SERVICE_NAME`: used to derive `${KEY_DIR}/${SERVICE_NAME}-keys.txt`.
- Existing dedicated key file for the service, if any (idempotent re-runs).

Error inputs tolerated: a dedicated key file that contains only
`AGE-SECRET-KEY-1…` with no `public key:` comment line (age-version
difference, derive the public key with `age-keygen -y`); a `KEY_DIR` that
exists with wrong permissions (warn, do not silently chmod elsewhere).

## Outputs

- `${KEY_DIR}/keys.txt`: master private key, mode `600`, host-only.
- `${KEY_DIR}/${SERVICE_NAME}-keys.txt`: dedicated private key, mode per
  `P-8` when mounted (the file itself stays `600` on the host; the **mounted
  copy's readability** is what `P-8` governs, normally by chmod on the host
  file when the container user's UID differs).
- Two public recipients, both present in every encrypted file:

```json
{"recipients": ["age1<master>", "age1<service>"]}
```

- The `sops_age__list_*_map_recipient` lines in the encrypted dotenv store
  mirror exactly those two recipients (one entry each).

## Dependencies

- `D-1` (age encryption, provided by sops or the `age` package).
- `P-1`, `P-2`, `P-3`, `P-8`.

Sibling coupling: `env-secrets.md` and `binary-secrets.md` consume the two
public recipients produced here and the dedicated private key file path;
`rotation.md` re-encrypts using the same recipient pair.

## Failure Behavior

- Master key missing and generation unavailable (no `age`, no network to pull
  `P-7`): hard fail. Phases 3+ cannot encrypt for the master recipient.
- Dedicated key unreadable by the container user at boot: the service exits
  non-zero with sops reporting a key/permission error. Remedy is `P-8`, never
  a looser mount of the master key.
- A file encrypted to only one recipient: `A-2` fails. Remedy is
  `scripts/sops-prepare-service.sh` (re-encrypt with both recipients).
- Master key present inside a container: `A-3` fails, and the blast-radius
  guarantee of R-3 is void. This is a security failure, not a convenience
  issue, treat it as an incident and rotate anything the container could
  have read.

## Idempotency Notes

Key generation is skip-if-exists for both keys, so re-running Phase 2 is safe
and changes nothing. Re-encryption (via `sops-prepare-service.sh`) is
idempotent: encrypting an already-dual-recipient file to the same two
recipients yields a valid file with the same recipient set (ciphertext bytes
differ each run, that is expected and harmless). Completion detection:
`grep -c 'AGE-SECRET-KEY-1'` on each key file, and the recipient set check in
`A-2`.

## Removal Notes

Adds two key files under `KEY_DIR`; adds nothing to the host's global
configuration. Removing the capability for one service means deleting
`${KEY_DIR}/${SERVICE_NAME}-keys.txt` and re-encrypting that file to the
master recipient only if it must stay readable by the operator. The master key
is shared with other services and MUST NOT be deleted as part of a per-service
removal.
