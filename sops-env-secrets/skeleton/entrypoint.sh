#!/bin/sh
#
# Skeleton: entrypoint.sh, the boot wrapper.
#
# Decrypts the mounted SOPS secret files and starts the application. Use this
# as the image's ENTRYPOINT (or inline its body into a `command:` line in
# compose, as skeleton/compose-secrets.yml does). POSIX sh on purpose: it must
# run on alpine/busybox as well as debian.
#
# Parameters:
#   P-5/P-10      SECRET_TARGET_PATH  in-container path of the encrypted dotenv store
#                              default /run/secrets/secrets.env (MUST end .env)
#   P-9           AGE_KEY_ENV  SOPS_AGE_KEY_FILE=/run/secrets/age-keys
#   P-6           APP_CMD      the application command line

set -e

SECRET_TARGET_PATH="${SECRET_TARGET_PATH:-/run/secrets/secrets.env}"
AGE_KEY_ENV="${AGE_KEY_ENV:-SOPS_AGE_KEY_FILE}"
export "$AGE_KEY_ENV=${SOPS_AGE_KEY_FILE:-/run/secrets/age-keys}"

# --- Optional: non-env binary secrets (see modules/binary-secrets.md) -------
# Decrypt a binary store to its target path before the app starts. Keep the
# plaintext on the container's writable layer, never on a persistent volume.
#
# if [ -f /run/secrets/ssh-key.encrypted ]; then
#   mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
#   sops --decrypt --input-type binary --output-type binary \
#     /run/secrets/ssh-key.encrypted > "$HOME/.ssh/id_ed25519"
#   chmod 600 "$HOME/.ssh/id_ed25519"
#   ssh-keygen -y -f "$HOME/.ssh/id_ed25519" > "$HOME/.ssh/id_ed25519.pub"
# fi
# ---------------------------------------------------------------------------

# Fail loudly if the secret file is missing: a container that starts without
# its secrets is worse than one that does not start at all (R-9).
if [ ! -f "$SECRET_TARGET_PATH" ]; then
  echo "entrypoint: secret file not found: $SECRET_TARGET_PATH" >&2
  exit 1
fi

# APP_CMD may be given as the container command (preferred) or as an env var.
if [ "$#" -gt 0 ]; then
  APP_CMD="$*"
fi
if [ -z "${APP_CMD:-}" ]; then
  echo "entrypoint: no application command given (set APP_CMD or pass argv)" >&2
  exit 1
fi

# Decrypt into the process environment and replace this shell with the app.
# No `--` separator: exec-env takes the command directly after the file.
exec sops exec-env "$SECRET_TARGET_PATH" "$APP_CMD"
