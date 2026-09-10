#!/bin/bash
#
# sops-prepare-service.sh - give a service its own SOPS age key.
#
# For the single-container `sops exec-env` pattern: ensure a dedicated
# per-service age key exists, and re-encrypt the service's .env.encrypted so it
# is dual-recipient (master repository key + the dedicated key). The container
# holds only the dedicated key, so a compromise leaks nothing beyond that
# service's own secrets. Host tooling (scripts/sops-set-env.sh) keeps using the
# master key.
#
# Usage:
#   sops-prepare-service.sh <service-dir>                 # e.g. containers/alby-hub
#   sops-prepare-service.sh <service-dir> --key <age1...> # reuse an existing key
#
# Environment:
#   KEY_DIR      Where keys live. Default: $HOME/sops/age
#   SOPS_IMAGE   Image used for keygen and re-encryption.
#                Default: ghcr.io/getsops/sops:v3.11.0-alpine
#   ENV_FILE_NAME  Encrypted store file name. Default: .env.encrypted
#
# Run this on the Docker host (the machine whose paths the daemon sees): the
# re-encryption bind-mounts the key directory and the env file.
#
# Requirements: docker, the sops image (it contains age via `apk add age`).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

KEY_DIR="${KEY_DIR:-$HOME/sops/age}"
SOPS_IMAGE="${SOPS_IMAGE:-ghcr.io/getsops/sops:v3.11.0-alpine}"
ENV_FILE_NAME="${ENV_FILE_NAME:-.env.encrypted}"

if [[ $# -lt 1 ]]; then
  echo -e "${RED}Usage: sops-prepare-service.sh <service-dir> [--key <age1...>]${NC}" >&2
  exit 1
fi

SERVICE_DIR="$1"
shift
SERVICE="$(basename "$(cd "$SERVICE_DIR" && pwd)")"
ENCFILE="$(cd "$SERVICE_DIR" && pwd)/$ENV_FILE_NAME"

[[ -f "$ENCFILE" ]] || { echo -e "${RED}Error: no $ENCFILE${NC}" >&2; exit 1; }
[[ -d "$KEY_DIR" ]] || { echo -e "${RED}Error: KEY_DIR not found: $KEY_DIR${NC}" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo -e "${RED}Error: docker not found${NC}" >&2; exit 1; }

MASTER_KEY="$KEY_DIR/keys.txt"
MASTER_PUB=""
DED_KEY_FILE="$KEY_DIR/$SERVICE-keys.txt"

# --key <age1...> reuses an existing dedicated public key; otherwise one is
# created (or reused) at $DED_KEY_FILE.
if [[ "${1:-}" == "--key" ]]; then
  DED_KEY="${2:?--key needs an age public key}"
else
  docker run --rm --mount "type=bind,source=$KEY_DIR,target=/out" \
    --entrypoint sh "$SOPS_IMAGE" -c "
      apk add --no-cache age >/dev/null 2>&1
      test -f /out/$SERVICE-keys.txt || age-keygen -o /out/$SERVICE-keys.txt
      age-keygen -y /out/$SERVICE-keys.txt
    " | tail -n1
  DED_KEY="$(docker run --rm --mount "type=bind,source=$KEY_DIR,target=/out" \
    --entrypoint sh "$SOPS_IMAGE" -c "age-keygen -y /out/$SERVICE-keys.txt" | tail -n1)"
fi

if [[ "$DED_KEY" != age1* ]]; then
  echo -e "${RED}Error: could not determine a dedicated public key (got: $DED_KEY)${NC}" >&2
  exit 1
fi
echo "dedicated key: $DED_KEY"

# Master public key is derived from the private key, never hard-coded, so this
# works on any host. If the master key is missing, create it first.
if [[ ! -f "$MASTER_KEY" ]]; then
  echo -e "${RED}Error: master key not found at $MASTER_KEY${NC}" >&2
  echo "Create it with:  mkdir -p '$KEY_DIR' && chmod 700 '$KEY_DIR'" >&2
  echo "                 docker run --rm --mount type=bind,source='$KEY_DIR',target=/out \\" >&2
  echo "                   --entrypoint sh $SOPS_IMAGE -c 'apk add --no-cache age >/dev/null && age-keygen -o /out/keys.txt'" >&2
  exit 1
fi
MASTER_PUB="$(docker run --rm --mount "type=bind,source=$MASTER_KEY,target=/k,ro" \
  --entrypoint sh "$SOPS_IMAGE" -c "apk add --no-cache age >/dev/null 2>&1; age-keygen -y /k" | tail -n1)"

# Re-encrypt to master + dedicated. The new file is written to a sibling temp
# path on the host and moved into place, so a failure leaves the original
# untouched.
TMP_FILE="$ENCFILE.tmp.$$"
touch "$TMP_FILE"

docker run --rm \
  -e SOPS_AGE_KEY_FILE=/run/secrets/master-key \
  --mount "type=bind,source=$MASTER_KEY,target=/run/secrets/master-key,ro" \
  --mount "type=bind,source=$ENCFILE,target=/work/env.encrypted,ro" \
  --mount "type=bind,source=$TMP_FILE,target=/work/env.encrypted.new" \
  --entrypoint sh "$SOPS_IMAGE" -c "
    sops --input-type dotenv --output-type dotenv --decrypt /work/env.encrypted > /tmp/plain.env
    sops --input-type dotenv --output-type dotenv --encrypt --age '$MASTER_PUB,$DED_KEY' /tmp/plain.env > /work/env.encrypted.new
    rm -f /tmp/plain.env
    echo 'recipients:'
    grep -o 'age1[a-z0-9]*' /work/env.encrypted.new | sort -u
  "

COUNT="$(grep -c '^' "$TMP_FILE" || true)"
if [[ "$COUNT" -lt 1 ]]; then
  rm -f "$TMP_FILE"
  echo -e "${RED}Error: re-encryption produced an empty file; original untouched${NC}" >&2
  exit 1
fi

mv "$TMP_FILE" "$ENCFILE"
chmod 644 "$ENCFILE"
echo -e "${GREEN}$SERVICE: $ENCFILE is now dual-recipient (master + $SERVICE)${NC}"
echo "The container needs only:  ${KEY_DIR}/${SERVICE}-keys.txt"
