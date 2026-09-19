#!/bin/sh
#
# preflight-compose-secrets.sh - fail before a Compose run starts with an empty
# secret.
#
# Usage:
#   preflight-compose-secrets.sh [--var <NAME>]… [--dir <compose-dir>] [-- <compose args…>]
#
#   --var   a variable that must resolve to a NON-EMPTY value. Repeat it for
#           each one. The classic mistake this catches is a file that holds
#           `NAME=` or a store that never reached the parser: the parse succeeds
#           and the stack starts with an empty value.
#   --dir   the directory to run the Compose command in. Default: $PWD.
#   --      everything after it is passed to the Compose CLI verbatim.
#           Default: `config`.
#
# Runs the Compose command, capturing its output, and then checks the *resolved*
# configuration — the same text `docker compose config` prints, where every
# `${VAR}` is already substituted. Exit status:
#
#   0  the command succeeded and every named variable has a non-empty value
#   1  the command failed, or a named variable is missing or empty
#   2  usage error
#
# Nothing is started: `config` parses and interpolates without touching the
# daemon, which is what makes this usable as a unit's first step.
#
# The fail-fast form `${VAR:?message}` in the compose file is the other half:
# it aborts the parse wherever the stack is brought up, including places this
# script never runs. Use both: the guard names the variable, the preflight prints
# the resolved value's shape.
#
# POSIX sh.

set -eu

VARS=""
DIR="${COMPOSE_DIR:-$PWD}"
COMPOSE_ARGS=""

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --var) [ "$#" -ge 2 ] || usage; VARS="$VARS $2"; shift 2 ;;
        --dir) [ "$#" -ge 2 ] || usage; DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        --) shift; while [ "$#" -gt 0 ]; do COMPOSE_ARGS="$COMPOSE_ARGS $1"; shift; done ;;
        *) usage ;;
    esac
done

[ -n "$VARS" ] || { echo "preflight-compose-secrets: give at least one --var NAME" >&2; usage; }
[ -d "$DIR" ] || { echo "preflight-compose-secrets: no such directory: $DIR" >&2; exit 1; }

for NAME in $VARS; do
    case "$NAME" in
        ''|[0-9]*|*[!A-Za-z0-9_]*) echo "preflight-compose-secrets: not a variable name: $NAME" >&2; exit 2 ;;
    esac
done

if [ -z "$COMPOSE_ARGS" ]; then
    COMPOSE_ARGS=" config"
fi

OUT="$(mktemp)"
ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR"' EXIT INT TERM

# shellcheck disable=SC2086  # deliberate word splitting: the ops/dev may pass several args
if ! ( cd "$DIR" && docker compose $COMPOSE_ARGS ) > "$OUT" 2> "$ERR"; then
    echo "preflight-compose-secrets: the Compose command failed in $DIR:" >&2
    sed 's/^/  /' "$ERR" >&2
    exit 1
fi
if [ -s "$ERR" ]; then
    # Warnings are not failures, but the blank-value warning is the symptom this
    # script exists for, so surface it rather than swallowing it.
    sed 's/^/  warning: /' "$ERR" >&2
fi

FAILED=0
for NAME in $VARS; do
    # Resolved form: `NAME: value` on its own line, possibly quoted.
    if ! grep -qE "^[[:space:]]*$NAME:[[:space:]]+" "$OUT"; then
        echo "preflight-compose-secrets: $NAME is not in the resolved configuration" >&2
        FAILED=1
        continue
    fi
    if grep -qE "^[[:space:]]*$NAME:[[:space:]]*(\"\"|'')?[[:space:]]*$" "$OUT"; then
        echo "preflight-compose-secrets: $NAME resolves to an EMPTY value" >&2
        echo "preflight-compose-secrets: a container would start with it blank; refusing" >&2
        FAILED=1
    fi
done

[ "$FAILED" -eq 0 ] || exit 1
echo "preflight-compose-secrets: $(printf '%s' "$VARS" | wc -w) variable(s) resolve non-empty" >&2
