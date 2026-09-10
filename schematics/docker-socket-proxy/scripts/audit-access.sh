#!/bin/sh
#
# Audit a docker-socket-proxy deployment: enumerate every endpoint group
# and report allowed (2xx) vs denied (403). Run from a container ON the
# proxy's network (that is the only place the endpoint exists).
#
# Usage: audit-access.sh http://socket-proxy:2375
#
# Exit status: 0 if the matrix printed; 1 if the endpoint is unreachable.

set -u

BASE="${1:?usage: audit-access.sh <proxy-base-url>}"

# group -> one representative request per endpoint group.
# A 403 means denied; any 2xx means allowed; anything else is noted
# separately (5xx usually means the daemon or proxy is unhappy).
probe() {
  label="$1"; shift
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@")
  case "$code" in
    403) verdict=denied ;;
    2*)  verdict=ALLOWED ;;
    *)   verdict="unexpected($code)" ;;
  esac
  printf '%-12s %s\n' "$label" "$verdict"
}

if ! curl -s -o /dev/null --max-time 5 "$BASE/_ping"; then
  echo "endpoint unreachable: $BASE" >&2
  exit 1
fi

echo "docker-socket-proxy audit: $BASE"
probe CONTAINERS "$BASE/containers/json"
probe IMAGES     "$BASE/images/json"
probe INFO       "$BASE/info"
probe NETWORKS   "$BASE/networks"
probe VOLUMES    "$BASE/volumes"
probe EXEC       -X POST "$BASE/containers/0000000000000000000000000000000000000000000000000000000000000000/exec"
probe BUILD      -X POST "$BASE/build"
probe SECRETS    "$BASE/secrets"
probe SWARM      "$BASE/swarm"
probe EVENTS     "$BASE/events"
probe PLUGINS    "$BASE/plugins"
echo
echo "ALLOWED groups must match the documented allowlist exactly;"
echo "anything ALLOWED without a justification in the compose file is a finding."
