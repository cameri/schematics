# Module: Binary Secrets

For secrets that are *files* rather than environment values, an SSH private
key, a keystore, a certificate bundle with a private half. The container
decrypts them at boot with SOPS's binary round trip and writes them only to
their intended in-container path.

## Purpose

Extends the `env-secrets.md` boot wrapper with a decrypt-to-path step for
non-dotenv secrets, and derives any public counterpart the application needs.
It does **not** define the key material (`key-hierarchy.md`) nor the dotenv
injection path (`env-secrets.md`), it runs before that module's `exec`.

## Inputs

- `<service-dir>/<name>.encrypted`: a SOPS **binary** store, dual-recipient
  (same recipients as the dotenv file).
- The dedicated key file, mounted as the same compose secret the dotenv path
  uses (`age-keys` + `P-9`).
- `<SECRET_TARGET_PATH>`: where the plaintext must land in the container
  (e.g. `~/.ssh/id_ed25519`), and the mode it requires.

Error inputs tolerated: a binary store encrypted with the wrong
`--input-type`/`--output-type` pair (detectable, the decrypted bytes start
with the SOPS metadata block instead of the expected file header); a target
directory that does not yet exist (create it with mode `700` before writing).

## Outputs

- The plaintext secret at its target path with mode `600` (or the tightest mode
  the consumer accepts).
- Any derived public counterpart the application requires, e.g.:

```sh
sops --decrypt --input-type binary --output-type binary \
  /run/secrets/github_phoenix.encrypted > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub
chmod 644 ~/.ssh/id_ed25519.pub
```

- Side effect: the plaintext exists inside the container's writable layer for
  the container's lifetime. This is the deliberate trade-off of this module
  versus the env path: files cannot be injected as environment variables. Keep
  the blast radius the same by keeping the plaintext out of any volume that
  outlives the container.

## Dependencies

- `D-2` (sops in the image), `D-4` (shell: the redirect is a shell feature).
- `P-7`, `P-9`; the dedicated key from `key-hierarchy.md`.

## Failure Behavior

- Wrong `--input-type` on decrypt: the output is the raw SOPS payload, so the
  consumer fails on a malformed key rather than at decrypt time. Detect by
  checking the first bytes of the result; remedy is to re-encrypt with the
  matched pair.
- Missing target directory: the redirect fails and, under the wrapper's
  `set -e`-style sequencing, the container exits before the application starts.
  Create the directory first.
- Plaintext written into a persistent volume: the secret survives the container
  and is no longer protected by the encrypted-at-rest guarantee. This is a
  failure of the implementation, not of sops; mount the target path on the
  container's writable layer or a tmpfs, never on a named volume.
- Decrypt failure: non-zero exit, application never starts (same as R-9).

## Idempotency Notes

Safe to re-run: each container start decrypts afresh; a second run overwrites
the same target path. There is no accumulation and no state to reconcile.
Completion detection: the target file exists with the expected mode and the
consumer accepts it (e.g. `ssh-keygen -y -f` succeeds).

## Removal Notes

Adds one encrypted file per secret to the repository, one compose secret entry,
and the decrypt step in the wrapper. Removal drops the wiring; the encrypted
file may be kept like the dotenv store or deleted if the plaintext source is
still available.
