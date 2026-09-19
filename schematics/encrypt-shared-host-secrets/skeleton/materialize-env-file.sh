#!/bin/sh
#
# materialize-env-file.sh - write a decrypted env-file for a consumer that can
# only read a path, and remove it when that consumer exits.
#
# Usage:
#   materialize-env-file.sh [--from <store-file>] [--mode <octal>] [--keep] \
#                           <target-path> -- '<command string>'
#
#   --from   the encrypted store (default: $STORE_FILE).
#   --mode   permissions on the plaintext file (default: ${RUNTIME_FILE_MODE:-0600}).
#   --keep   leave the file in place after the command exits. Use it only when
#            the consumer is not this process's child (a unit started by the
#            service manager); the file then persists until something removes
#            it, which the consumer's inventory row must say.
#
# The file is written to a temporary name in the target's directory, made
# non-empty and mode-correct, then renamed into place: a consumer never opens a
# half-written or empty file. On every exit path but `--keep`, it is removed —
# including when the command fails or the wrapper is signalled.
#
# Target paths belong under ${RUNTIME_DIR:-/run}, which `D-7` says is tmpfs
# where the platform provides one: the plaintext then lives in memory-backed
# storage and disappears with the boot. Never materialize inside a repository.
#
# Requires a sops binary on this host (it writes to this host's filesystem).
#
# POSIX sh.

set -eu

STORE="${STORE_FILE:-}"
MODE="${RUNTIME_FILE_MODE:-0600}"
KEEP=0
TARGET=""

usage() {
    # Print the leading comment block verbatim (from `#` through the first
    # non-comment line): a hard-coded line range goes stale on the next edit.
    awk 'NR > 2 { if (sub(/^# ?/, "")) { print; next } exit }' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --from) [ "$#" -ge 2 ] || usage; STORE="$2"; shift 2 ;;
        --mode) [ "$#" -ge 2 ] || usage; MODE="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage ;;
        --) shift; break ;;
        -*) echo "materialize-env-file: unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

[ "$#" -ge 1 ] || usage
TARGET="$1"; shift

COMMAND=""
if [ "$#" -gt 0 ]; then
    [ "$1" = "--" ] || { echo "materialize-env-file: expected -- before the command" >&2; usage; }
    shift
    case "$#" in
        0) [ "$KEEP" -eq 1 ] || { echo "materialize-env-file: no command given (or use --keep)" >&2; usage; } ;;
        1) COMMAND="$1" ;;
        *)
            echo "materialize-env-file: the command must be ONE argument; got $#" >&2
            echo "materialize-env-file: quote it, or use --keep and start the consumer yourself" >&2
            exit 2
            ;;
    esac
fi

[ -n "$STORE" ] || { echo "materialize-env-file: no store given (--from or \$STORE_FILE)" >&2; exit 2; }
[ -f "$STORE" ] || { echo "materialize-env-file: no such store: $STORE" >&2; exit 1; }
[ -n "$TARGET" ] || usage
case "$TARGET" in
    */../*|*/..) echo "materialize-env-file: refusing a target with ..: $TARGET" >&2; exit 2 ;;
esac

command -v sops >/dev/null 2>&1 || {
    echo "materialize-env-file: no sops binary on this host; it writes this host's files." >&2
    echo "materialize-env-file: install sops (its alpine image ships the binary)." >&2
    exit 1
}

TARGET_DIR="$(dirname "$TARGET")"
mkdir -p "$TARGET_DIR"
chmod 700 "$TARGET_DIR"

TMPF="$TARGET.tmp.$$"
# The file that must be gone on exit is the *target*: the temp name only exists
# between decryption and the rename. `--keep` is the one case that leaves it.
cleanup() { rm -f "$TMPF"; [ "$KEEP" -eq 1 ] || rm -f "$TARGET"; }
trap 'cleanup' EXIT INT TERM HUP

# Decrypt straight into the destination directory, then tighten the mode before
# anything can open it.
( umask 077; sops --decrypt --input-type dotenv --output-type dotenv "$STORE" > "$TMPF" )
[ -s "$TMPF" ] || {
    echo "materialize-env-file: decryption of $STORE produced an empty file; refusing to" >&2
    echo "materialize-env-file: place it, because an empty env-file starts a consumer blank" >&2
    exit 1
}
chmod "$MODE" "$TMPF"
mv "$TMPF" "$TARGET"

if [ "$KEEP" -eq 1 ]; then
    trap - EXIT INT TERM HUP
    echo "materialize-env-file: $TARGET ($MODE) left in place" >&2
fi

if [ -n "$COMMAND" ]; then
    sh -c "$COMMAND"
fi
