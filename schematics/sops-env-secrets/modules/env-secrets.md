# Module: Environment Secrets

The `sops exec-env` boot pattern: the container decrypts its dotenv file in
memory at start and hands the values to the application as environment
variables.

## Purpose

Owns everything between "an encrypted dotenv file exists in the repository" and
"the application's process environment contains those values, with no cleartext
on disk": the sops binary in the image, the compose secret wiring and its
naming rules, the boot wrapper, and the format/quoting constraints that make
decryption succeed. It does **not** create keys (`key-hierarchy.md`), set
values (`rotation.md`), or handle binary secrets (`binary-secrets.md`).

## Inputs

- `P-4 ENV_FILE`: the SOPS dotenv store, dual-recipient (see
  `key-hierarchy.md`). Read-only inside the container.
- `P-3 SERVICE_NAME`: used to namespace the compose secret names.
- `P-5 SECRET_MOUNT_NAME`: in-container file name; **must** end in `.env` for
  the mount target, because `sops exec-env` infers the dotenv store type from
  the file extension.
- `P-6 APP_CMD`: the command to exec after injection.
- `P-10 SECRET_TARGET_PATH`: defaults to `/run/secrets/${SECRET_MOUNT_NAME}`.
- The dedicated key file as the compose secret `age-keys`, plus
  `P-9 AGE_KEY_ENV=SOPS_AGE_KEY_FILE` pointing at it.

Error inputs tolerated: an application command containing spaces, quotes, or a
shell pipeline, the wrapper runs it through `/bin/sh -c`; a dotenv file with
comment lines (preserved by sops, ignored by exec-env).

## Outputs

- A running application process whose environment contains the decrypted
  values, inherited from `sops` (which holds PID 1 and execs the child with the
  values in its environment).
- No files written: no secrets volume, no decrypted temp file, no sidecar
  container.
- Two compose secrets mounted read-only:

```yaml
secrets:
  <service>-env-encrypted:
    file: ./.env.encrypted          # SOPS dotenv store
  <service>-age-keys:
    file: ${KEY_DIR}/<service>-keys.txt
```

Consumed by `binary-secrets.md` only for the wrapper's ordering (binary
decrypt happens before `exec`).

## Dependencies

- `D-2` (sops binary in the image), `D-3` (compose secrets), `D-4` (shell in
  the final image).
- `P-3`, `P-4`, `P-5`, `P-6`, `P-7`, `P-8`, `P-9`, `P-10`.

## Failure Behavior

- Missing `/bin/sh` in the final image: `sops exec-env` cannot spawn the app;
  container exits non-zero with a spawn error. Remedy: variant B of
  `skeleton/Containerfile.sops` (base on the sops alpine image).
- Secret target name without an `.env` suffix: sops fails to detect the store
  and reports a parse error. Remedy: `P-5`, not a sops flag.
- Quoted values in the store: the application receives the quotes as part of
  the value. Remedy: re-set the value unquoted (`rotation.md`).
- Secret-name collision across merged compose files: the service silently
  receives **another service's** key file and fails to decrypt. This is the
  most expensive failure mode observed in production, because the error names
  the file, not the collision. Remedy: `P-3`-prefixed secret names (R-7).
- Non-root container user with a `0600` mounted key: permission denied at
  boot. Remedy: `P-8`.
- Decryption failure of any kind: `sops exec-env` exits non-zero and the
  application never starts (R-9), the desired failure mode, never a silent
  start with missing secrets.

## Idempotency Notes

The wrapper is idempotent by construction: every container start re-decrypts
from the mounted ciphertext, so a restart always converges to the current file
contents. Rebuilding the image is never required for a value change. Completion
detection during implementation is the Phase 7 environment check, which counts
matching environment lines rather than printing values.

## Removal Notes

Adds: a sops binary to the image, two secret entries plus one environment
variable to the service, and the wrapper command. Removing it means restoring
the original command and dropping the secret wiring (SCHEMATIC.md → Removal);
the committed ciphertext stays and no host state changes.
