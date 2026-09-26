#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a nostream deploy root from this schematic package.
#
# Usage:
#   ./bootstrap.sh [/opt/nostream]
#
# Requires: skeleton/compose.yml, skeleton/.env.example, and postgresql.conf
# `skeleton/postgresql.conf` (bundled, air-gap safe) or fetch via NOSTREAM_GITHUB_REF.

TARGET="${1:-/opt/nostream}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NOSTREAM_GITHUB_REF="${NOSTREAM_GITHUB_REF:-main}"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "error: required file not found: $1" >&2
    exit 1
  fi
}

require_file "$SCRIPT_DIR/compose.yml"
require_file "$SCRIPT_DIR/.env.example"

mkdir -p "$TARGET/.nostr/data" "$TARGET/.nostr/db-logs"

install -m 644 "$SCRIPT_DIR/compose.yml" "$TARGET/docker-compose.yml"

if [[ -f "$SCRIPT_DIR/postgresql.conf" ]]; then
  install -m 644 "$SCRIPT_DIR/postgresql.conf" "$TARGET/postgresql.conf"
elif [[ -f "$PKG_ROOT/postgresql.conf" ]]; then
  install -m 644 "$PKG_ROOT/postgresql.conf" "$TARGET/postgresql.conf"
elif [[ "${NOSTREAM_BOOTSTRAP_OFFLINE:-}" = "1" ]]; then
  echo "error: offline bootstrap requires skeleton/postgresql.conf in this package" >&2
  exit 1
else
  echo "Fetching postgresql.conf from cameri/nostream@${NOSTREAM_GITHUB_REF}..."
  if ! curl -fsSL \
    "https://raw.githubusercontent.com/cameri/nostream/${NOSTREAM_GITHUB_REF}/postgresql.conf" \
    -o "$TARGET/postgresql.conf"; then
    echo "error: fetch failed — use bundled skeleton/postgresql.conf or set NOSTREAM_BOOTSTRAP_OFFLINE=1 with a local file" >&2
    exit 1
  fi
fi
require_file "$TARGET/postgresql.conf"

if [[ ! -f "$TARGET/.env" ]]; then
  install -m 600 "$SCRIPT_DIR/.env.example" "$TARGET/.env"
  echo "Created $TARGET/.env — edit secrets before starting the stack."
else
  echo "Keeping existing $TARGET/.env"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  chown 1000:1000 "$TARGET/.nostr"
fi
chmod 755 "$TARGET/.nostr"

cat <<EOF

Bootstrap complete: $TARGET

Next steps:
  1. Edit $TARGET/.env (SECRET, DB_PASSWORD, REDIS_PASSWORD, NOSTREAM_IMAGE)
  2. Load or pull the nostream image on this host
  3. cd $TARGET && docker compose up -d
  4. DEPLOY_ROOT=$TARGET RELAY_BASE=http://127.0.0.1:\${RELAY_PORT:-8008} $PKG_ROOT/scripts/relay-verify.sh

Optional overrides:
  cp $SCRIPT_DIR/settings.yaml.example $TARGET/.nostr/settings.yaml
  chown 1000:1000 $TARGET/.nostr/settings.yaml
  chmod 600 $TARGET/.nostr/settings.yaml

EOF
