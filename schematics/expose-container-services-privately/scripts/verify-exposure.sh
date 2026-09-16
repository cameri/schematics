#!/bin/sh
#
# Verify an expose-container-services-privately deployment: every exposed
# hostname on the tailnet resolves and serves its service.
#
# Usage:
#   verify-exposure.sh [--http] <TAILNET> <name> [<name>...]
#   verify-exposure.sh --from-list <TAILNET> <list-file>...
#
#   TAILNET    the tailnet DNS suffix (P-1), e.g. example.ts.net
#   <name>     exposed hostnames to check (A-2)
#   --from-list  read hostname keys from tsdproxy list files (the top-level
#              YAML keys) instead of naming them on the command line
#   --http     use http://<name> instead of https://<name>.<TAILNET>
#              (P-2 = off)
#
# Run FROM a tailnet-connected device (that is the only place the
# hostnames resolve). Exit status: 0 if every hostname answered; 1
# otherwise.
#
# No secrets, no instance values: everything comes from arguments.

set -u

PROTO=https
TAILNET=""
NAMES=""
FROM_LIST=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --http) PROTO=http; shift ;;
    --from-list) FROM_LIST=1; shift ;;
    -h|--help) usage ;;
    *)
      if [ -z "$TAILNET" ]; then TAILNET="$1"; else
        if [ "$FROM_LIST" = 1 ]; then
          # top-level YAML keys of a list file = the exposed hostnames
          NAMES="$NAMES $(sed -n 's/^\([A-Za-z0-9_-][A-Za-z0-9_-]*\):.*/\1/p' "$1" | tr '\n' ' ')"
        else
          NAMES="$NAMES $1"
        fi
      fi
      shift ;;
  esac
done

[ -n "$TAILNET" ] || { echo "TAILNET is required" >&2; usage; }
[ -n "$NAMES" ] || { echo "no hostnames to check" >&2; usage; }

fail=0
for name in $NAMES; do
  url="$PROTO://$name.$TAILNET"
  if curl -fsSI --max-time 15 "$url" >/dev/null 2>&1; then
    echo "OK   $url"
  else
    echo "FAIL $url"
    fail=1
  fi
done

[ "$fail" = 0 ] && echo "all exposed hostnames answered" || echo "one or more hostnames failed" >&2
exit "$fail"