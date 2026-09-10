#!/bin/bash
#
# sops-set-env.sh - set one secret value in a SOPS-encrypted dotenv file.
#
# Usage:
#   sops-set-env.sh [options] <path-to-.env.encrypted> <ENV_NAME>
#
# Options:
#   --value-file <path>  Read the secret from a file instead of stdin/prompt.
#   --age-key <path>     Age private key file. Default: $SOPS_AGE_KEY_FILE,
#                        else $KEY_DIR/keys.txt.
#   -h, --help           Show this help.
#
# The secret value is read from stdin when piped, or prompted masked on a
# terminal (each character echoes as *, backspace works, and the captured
# length is printed on Enter so a paste is never silently truncated). It is
# held only in a 0600 temp file that is deleted on exit, JSON-encoded, and
# piped into `sops set --value-stdin`, so it never appears on the command
# line, in shell history, or in any sops process argv.
#
# Environment:
#   KEY_DIR      Master key directory. Default: $HOME/sops/age
#   SOPS_IMAGE   Image used when no host sops binary exists.
#                Default: ghcr.io/getsops/sops:v3.11.0-alpine
#
# Run this on the Docker host (the machine whose paths the daemon sees): the
# container fallback bind-mounts the key file and the env file's directory.
#
# Example:
#   ./sops-set-env.sh services/experiential/.env.encrypted ZAI_API_KEY

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

KEY_DIR="${KEY_DIR:-$HOME/sops/age}"
SOPS_IMAGE="${SOPS_IMAGE:-ghcr.io/getsops/sops:v3.11.0-alpine}"

SRC_VALUE_FILE=""
AGE_KEY="${SOPS_AGE_KEY_FILE:-}"

usage() {
  grep '^#' "$0" | sed -e 's/^# \{0,1\}//' | sed -n '2,28p'
  exit 0
}

# Masked secret read: echo '*' per character, handle backspace, print the
# captured length on Enter. Sets the global VAL.
read_secret() {
  local prompt="$1" c saved
  VAL=""
  saved="$(stty -g 2>/dev/null || true)"
  trap 'stty "$saved" 2>/dev/null || true' INT TERM
  stty -echo -icanon 2>/dev/null || true
  printf '%s' "$prompt"
  while :; do
    IFS= read -r -n1 c || true
    case "$c" in
      ""|$'\r'|$'\n') break ;;                          # Enter / EOF
      $'\x7f'|$'\x08')                                   # DEL / backspace
        if [[ -n "$VAL" ]]; then
          VAL="${VAL%?}"
          printf '\b \b'
        fi
        ;;
      *)
        VAL+="$c"
        printf '*'
        ;;
    esac
  done
  stty "$saved" 2>/dev/null || true
  trap - INT TERM
  printf '\n%d characters captured\n' "${#VAL}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --value-file)
      [[ $# -ge 2 ]] || { echo -e "${RED}--value-file needs an argument${NC}" >&2; exit 1; }
      SRC_VALUE_FILE="$2"
      shift 2
      ;;
    --age-key)
      [[ $# -ge 2 ]] || { echo -e "${RED}--age-key needs an argument${NC}" >&2; exit 1; }
      AGE_KEY="$2"
      shift 2
      ;;
    --) shift; break ;;
    -*) echo -e "${RED}Unknown option: $1${NC}" >&2; exit 1 ;;
    *) break ;;
  esac
done

if [[ $# -ne 2 ]]; then
  echo -e "${RED}Usage: sops-set-env.sh [--value-file <path>] [--age-key <path>] <env-file> <ENV_NAME>${NC}" >&2
  exit 1
fi

ENV_FILE="$1"
ENV_NAME="$2"

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}Error: env file not found: $ENV_FILE${NC}" >&2
  exit 1
fi
if ! [[ "$ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo -e "${RED}Error: invalid env name: $ENV_NAME${NC}" >&2
  exit 1
fi

# Resolve the age private key.
if [[ -z "$AGE_KEY" ]]; then
  AGE_KEY="$KEY_DIR/keys.txt"
fi
if [[ ! -f "$AGE_KEY" ]]; then
  echo -e "${RED}Error: age key not found at $AGE_KEY (pass --age-key or set SOPS_AGE_KEY_FILE/KEY_DIR)${NC}" >&2
  exit 1
fi

# Capture the secret value into a 0600 temp file; never into argv or history.
TMPF="$(mktemp)"
trap 'rm -f "$TMPF" "$TMPF.json"' EXIT
chmod 600 "$TMPF"

if [[ -n "$SRC_VALUE_FILE" ]]; then
  if [[ ! -f "$SRC_VALUE_FILE" ]]; then
    echo -e "${RED}Error: --value-file not found: $SRC_VALUE_FILE${NC}" >&2
    exit 1
  fi
  cp "$SRC_VALUE_FILE" "$TMPF"
elif [[ -t 0 ]]; then
  read_secret "Paste value for $ENV_NAME: "
  printf '%s' "$VAL" > "$TMPF"
else
  read -r VAL || true
  printf '%s' "$VAL" > "$TMPF"
fi

if [[ ! -s "$TMPF" ]]; then
  echo -e "${RED}Error: empty value for $ENV_NAME${NC}" >&2
  exit 1
fi

# `sops set` parses the value as a JSON literal, so encode the raw secret (a
# plain API key is fine, but this also handles quotes/backslashes/newlines).
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' < "$TMPF" > "$TMPF.json"
elif command -v jq >/dev/null 2>&1; then
  jq -Rn '[inputs] | join("\n")' < "$TMPF" > "$TMPF.json"
else
  echo -e "${RED}Error: need python3 or jq to JSON-encode the value${NC}" >&2
  exit 1
fi
mv "$TMPF.json" "$TMPF"

# Perform the set. The JSON-encoded value is piped into `sops set --value-stdin`
# so it never appears in argv (host or container). Two details sops needs for a
# `.env.encrypted` file:
#   - `--input-type dotenv --output-type dotenv`: the `.encrypted` extension is
#     not in sops' dotenv mapping, so without this sops misdetects the store.
#   - `set` index format is ["KEY"]: the double quotes inside the brackets are
#     required (an unquoted key fails with "Invalid set index format").
if command -v sops >/dev/null 2>&1; then
  SOPS_AGE_KEY_FILE="$AGE_KEY" sops set --input-type dotenv --output-type dotenv --value-stdin "$ENV_FILE" "[\"$ENV_NAME\"]" < "$TMPF"
else
  PARENT="$(cd "$(dirname "$ENV_FILE")" && pwd)"
  BASE="$(basename "$ENV_FILE")"
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}Error: no sops binary and no docker available${NC}" >&2
    exit 1
  fi
  docker run --rm -i --entrypoint sh \
    -e SOPS_AGE_KEY_FILE=/run/secrets/age-keys \
    --mount "type=bind,source=$AGE_KEY,target=/run/secrets/age-keys,ro" \
    --mount "type=bind,source=$PARENT,target=/work" \
    "$SOPS_IMAGE" \
    -c "sops set --input-type dotenv --output-type dotenv --value-stdin /work/$BASE '[\"$ENV_NAME\"]'" < "$TMPF"
fi

echo -e "${GREEN}Updated $ENV_NAME in $ENV_FILE${NC}"

# Hint to restart the consuming service if a compose file sits next to it.
COMPOSE_DIR="$(dirname "$ENV_FILE")"
if [[ -f "$COMPOSE_DIR/compose.yml" || -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  echo -e "${YELLOW}Restart to activate: docker compose -f $COMPOSE_DIR/compose.yml restart <svc>${NC}"
fi
