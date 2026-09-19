#!/bin/sh
#
# host-wrapper.sh - run a command with a shared SOPS store's values in its
# environment, decrypting in memory.
#
# Usage:
#   sops-env-exec [--store <store-file>] [--age-key <path>] \
#                 [--require <NAME>[,<NAME>…]] [--pristine] [--alias-dir <dir>] \
#                 '<command string>'
#
#   --store      the encrypted store (default: $STORE_FILE).
#   --age-key    age private key (default: $SOPS_AGE_KEY_FILE, else the master
#                key at $KEY_DIR/keys.txt).
#   --require    the variable names the consumer reads. Each MUST be present in
#                the store, or the wrapper exits non-zero before running
#                anything. Only names are compared; no value is printed.
#   --pristine   do not forward the wrapper's own environment to the child:
#                the child gets the store's values and nothing else.
#   --alias-dir  where the `.env`-named alias to the ciphertext is created.
#                Default: ${RUNTIME_DIR:-/run}/sops-alias
#
# `<command string>` is ONE argument, run through `/bin/sh -c`. Several argv
# words fail with sops' own "missing file to decrypt", so the wrapper refuses
# them instead of forwarding a confusing error.
#
# Why an alias: `sops exec-env` selects its parser from the file NAME and
# accepts no input-type flag of its own, so a store called `*.encrypted` fails
# to parse even though its content is dotenv. The alias is a symlink whose name
# ends in `.env`; the content stays ciphertext, so an alias left behind leaks
# nothing.
#
# Requires a sops binary on this host: a container fallback cannot put a value
# into *this* process's environment, which is the whole point of the wrapper.
#
# POSIX sh. Writes nothing but the alias symlink.

set -eu

STORE="${STORE_FILE:-}"
AGE_KEY="${SOPS_AGE_KEY_FILE:-}"
REQUIRE=""
PRISTINE=0
ALIAS_DIR="${RUNTIME_DIR:-/run}/sops-alias"

usage() {
    # Print the leading comment block verbatim (from `#` through the first
    # non-comment line): a hard-coded line range goes stale on the next edit.
    awk 'NR > 2 { if (sub(/^# ?/, "")) { print; next } exit }' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --store)     [ "$#" -ge 2 ] || usage; STORE="$2"; shift 2 ;;
        --age-key)   [ "$#" -ge 2 ] || usage; AGE_KEY="$2"; shift 2 ;;
        --require)   [ "$#" -ge 2 ] || usage; REQUIRE="$2"; shift 2 ;;
        --alias-dir) [ "$#" -ge 2 ] || usage; ALIAS_DIR="$2"; shift 2 ;;
        --pristine)  PRISTINE=1; shift ;;
        -h|--help)   usage ;;
        --)          shift; break ;;
        -*)          echo "sops-env-exec: unknown option: $1" >&2; usage ;;
        *)           break ;;
    esac
done

case "$#" in
    1) COMMAND="$1" ;;
    0) echo "sops-env-exec: no command given" >&2; usage ;;
    *)
        echo "sops-env-exec: the command must be ONE argument; got $# argv words." >&2
        echo "sops-env-exec: quote it: sops-env-exec '<command with its arguments>'" >&2
        exit 2
        ;;
esac

[ -n "$STORE" ] || { echo "sops-env-exec: no store given (--store or \$STORE_FILE)" >&2; exit 2; }
[ -f "$STORE" ] || { echo "sops-env-exec: no such store: $STORE" >&2; exit 1; }

command -v sops >/dev/null 2>&1 || {
    echo "sops-env-exec: no sops binary on this host." >&2
    echo "sops-env-exec: the wrapper injects values into this process's environment," >&2
    echo "sops-env-exec: so it cannot run sops elsewhere. Install sops, or give the" >&2
    echo "sops-env-exec: consumer a container of its own and decrypt there." >&2
    exit 1
}

if [ -z "$AGE_KEY" ]; then
    AGE_KEY="${KEY_DIR:-$HOME/sops/age}/keys.txt"
fi
[ -f "$AGE_KEY" ] || { echo "sops-env-exec: no such age key: $AGE_KEY" >&2; exit 1; }
export SOPS_AGE_KEY_FILE="$AGE_KEY"

# --- required names --------------------------------------------------------
# A key that is absent from the store is simply unset in the child, with no
# error from sops and none from the shell: that is the silent-blank failure.
# Comparing names is what turns it into a refusal, and names are all this reads.
if [ -n "$REQUIRE" ]; then
    # Two steps on purpose: piping the decryption into grep would hand grep's
    # status to the shell, so an unreadable store (wrong key, corrupt file) would
    # be reported as a missing name instead of as the failure it is.
    if ! sops --decrypt --input-type dotenv --output-type dotenv "$STORE" >/dev/null 2>&1; then
        echo "sops-env-exec: cannot decrypt $STORE with $AGE_KEY; nothing was run" >&2
        exit 1
    fi
    PRESENT="$(sops --decrypt --input-type dotenv --output-type dotenv "$STORE" \
        | grep -oE '^[A-Za-z_][A-Za-z0-9_]*' | grep -v '^sops_' | sort -u)" || true
    MISSING=""
    for NAME in $(printf '%s' "$REQUIRE" | tr ',' ' '); do
        printf '%s\n' "$PRESENT" | grep -qx "$NAME" || MISSING="$MISSING $NAME"
    done
    if [ -n "$MISSING" ]; then
        echo "sops-env-exec: not in $STORE:$MISSING" >&2
        echo "sops-env-exec: a name absent from the store reaches the consumer unset," >&2
        echo "sops-env-exec: so this run is refused before anything starts." >&2
        exit 1
    fi
fi

# --- alias -----------------------------------------------------------------
# sops exec-env decides the format from the file name; the name must end .env.
STORE_ABS="$(cd "$(dirname "$STORE")" && pwd)/$(basename "$STORE")"
ALIAS_NAME="$(basename "$STORE")"
case "$ALIAS_NAME" in
    *.encrypted) ALIAS_NAME="${ALIAS_NAME%.encrypted}" ;;
esac
case "$ALIAS_NAME" in
    *.env) : ;;
    *) ALIAS_NAME="$ALIAS_NAME.env" ;;
esac

mkdir -p "$ALIAS_DIR"
chmod 700 "$ALIAS_DIR"
ALIAS="$ALIAS_DIR/$ALIAS_NAME"
ln -sf "$STORE_ABS" "$ALIAS"

# --- run -------------------------------------------------------------------
if [ "$PRISTINE" -eq 1 ]; then
    exec sops exec-env --pristine "$ALIAS" "$COMMAND"
fi
exec sops exec-env "$ALIAS" "$COMMAND"
