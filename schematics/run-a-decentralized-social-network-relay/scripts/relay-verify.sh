#!/usr/bin/env sh
# Acceptance checks for run-a-decentralized-social-network-relay (A-1, A-2, A-3).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

# Deploy root: directory containing docker-compose.yml and .env (optional).
DEPLOY_ROOT="${DEPLOY_ROOT:-}"

load_relay_port() {
  if [ -n "$DEPLOY_ROOT" ] && [ -f "${DEPLOY_ROOT}/.env" ]; then
    _port="$(grep -E '^RELAY_PORT=' "${DEPLOY_ROOT}/.env" | tail -1 | cut -d= -f2- | tr -d " \t\r\"'")"
    if [ -n "$_port" ]; then
      RELAY_PORT="$_port"
    fi
  fi
}

RELAY_PORT="${RELAY_PORT:-8008}"
load_relay_port
RELAY_BASE="${RELAY_BASE:-http://127.0.0.1:${RELAY_PORT}}"

FAIL=0

check() {
  name="$1"
  shift
  if "$@"; then
    printf 'ok  %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    FAIL=1
  fi
}

code() {
  curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$@"
}

healthz_ok() {
  test "$(code "${RELAY_BASE}/healthz")" = "200"
}

readyz_ok() {
  test "$(code "${RELAY_BASE}/readyz")" = "200"
}

nip11_ok() {
  _body="$(curl -sf --max-time 10 -H 'Accept: application/nostr+json' "${RELAY_BASE}/")"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$_body" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("name") or d.get("description")'
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$_body" | jq -e '.name // .description' >/dev/null
  else
    printf '%s' "$_body" | grep -q '"name"\|"description"'
  fi
}

loopback_bind_ok() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  if [ -z "$DEPLOY_ROOT" ] || [ ! -f "${DEPLOY_ROOT}/docker-compose.yml" ]; then
    return 1
  fi

  if ! ( cd "$DEPLOY_ROOT" && docker compose ps --status running nostream 2>/dev/null | grep -q nostream ); then
    return 1
  fi

  published="$( cd "$DEPLOY_ROOT" && docker compose port nostream "$RELAY_PORT" 2>/dev/null )" || published=""
  if [ -z "$published" ]; then
    return 1
  fi
  case "$published" in
    127.0.0.1:*) return 0 ;;
    *) return 1 ;;
  esac
}

check 'healthz liveness (A-2)' healthz_ok
check 'readyz readiness (A-2)' readyz_ok
check 'NIP-11 metadata (A-1)' nip11_ok
check 'loopback bind (A-3)' loopback_bind_ok

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi

printf 'All relay-verify checks passed.\n'
