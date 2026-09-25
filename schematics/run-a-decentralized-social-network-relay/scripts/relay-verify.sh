#!/usr/bin/env sh
# Acceptance checks for run-a-decentralized-social-network-relay (A-1, A-2, A-3).
set -eu

RELAY_BASE="${RELAY_BASE:-http://127.0.0.1:8008}"
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
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

check 'healthz liveness (A-2)' \
  test "$(code "${RELAY_BASE}/healthz")" = "200"

check 'readyz readiness (A-2)' \
  test "$(code "${RELAY_BASE}/readyz")" = "200"

check 'NIP-11 metadata (A-1)' \
  curl -sf -H 'Accept: application/nostr+json' "${RELAY_BASE}/" | grep -q '"name"\|"description"'

if command -v docker >/dev/null 2>&1 && docker compose ps nostream 2>/dev/null | grep -q nostream; then
  published="$(docker compose port nostream "${RELAY_PORT:-8008}" 2>/dev/null || true)"
  case "$published" in
    127.0.0.1:*|"") check 'loopback bind (A-3)' true ;;
    *) check 'loopback bind (A-3)' false ;;
  esac
fi

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi

printf 'All relay-verify checks passed.\n'
