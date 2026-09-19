#!/bin/sh
#
# find-consumers.sh - inventory every consumer of a variable, with its mechanism.
#
# Usage:
#   find-consumers.sh [--all] [--max-size <bytes>] [--exclude <dir>]… <VAR> [<search-root> ...]
#
# Prints one tab-separated row per reference:
#
#   <path>:<line>   <mechanism>   <text>
#
# The text has the value redacted (`NAME=[redacted]`), because the file being
# searched routinely holds the secret itself and an inventory that prints it
# would be a second copy of the secret — in a terminal, a log, or a report.
# Only the name and the shape of the line are useful for classification.
#
# Mechanisms:
#   compose-interpolation      `${VAR}` (or `$VAR`) in a YAML file: the Compose
#                              CLI resolves it at parse time, before any
#                              container exists.
#   container-env-file         `env_file:` in a YAML file: a container receives
#                              the whole file.
#   env-file-flag              a `--env-file <path>` argument: whatever runs that
#                              command reads the file's plaintext.
#   systemd-environmentfile    an `EnvironmentFile=` directive in a unit file.
#   shell-source               `. <path>` or `source <path>`: a shell reads the
#                              file into its own environment.
#   template-reference         `{{VAR}}`, `%VAR%` or `${VAR}` in a file that is
#                              not YAML: a template or config renderer, or a
#                              command line that expands it.
#   reference                  the name appears in something else. Read the line
#                              before classifying it: documentation, an example,
#                              and a real consumer all land here.
#
# Excluded by default, because they are code rather than consumers: `.git`,
# `node_modules`, `vendor`, `.venv`, `site-packages`; plus any file at or above
# `--max-size` (default 1048576 bytes). A host whose tooling keeps session
# transcripts or logs in its own directories adds them with `--exclude`, which
# repeats: those directories hold conversations about the variable, not
# consumers of it, and one of them will contain the value itself. `--all`
# searches everything.
#
# Exit status: 0 when at least one reference was found, 1 when none was, 2 on a
# usage error. The summary goes to stderr; only rows go to stdout.
#
# POSIX sh plus `find -print0`/`xargs -0` (GNU, busybox and BSD all provide
# them). Read-only: it starts nothing and writes nothing but its temp files.

set -eu

usage() {
    # Print the leading comment block verbatim (from `#` through the first
    # non-comment line): a hard-coded line range goes stale on the next edit.
    awk 'NR > 2 { if (sub(/^# ?/, "")) { print; next } exit }' "$0"
    exit 2
}

ALL=0
MAXSIZE=1048576
EXCLUDES=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --all)      ALL=1; shift ;;
        --max-size) [ "$#" -ge 2 ] || usage; MAXSIZE="$2"; shift 2 ;;
        --exclude)  [ "$#" -ge 2 ] || usage; EXCLUDES="$EXCLUDES $2"; shift 2 ;;
        -h|--help)  usage ;;
        --)         shift; break ;;
        -*)         echo "find-consumers: unknown option: $1" >&2; usage ;;
        *)          break ;;
    esac
done

[ "$#" -ge 1 ] || usage
VAR="$1"
shift

case "$VAR" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) echo "find-consumers: not a variable name: $VAR" >&2; exit 2 ;;
esac

if [ "$#" -eq 0 ]; then
    set -- .
fi

ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT INT TERM

for ROOT in "$@"; do
    if [ ! -e "$ROOT" ]; then
        echo "find-consumers: no such path: $ROOT" >&2
        continue
    fi
    if [ "$ALL" -eq 1 ]; then
        PRUNE=""
    else
        PRUNE='( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name site-packages'
        for X in $EXCLUDES; do
            PRUNE="$PRUNE -o -name $X"
        done
        PRUNE="$PRUNE ) -prune -o"
    fi
    # `--`-terminated file list piped to grep: no recursion, no argv limits, and
    # /dev/null keeps grep from ever reading stdin when the list is empty.
    # shellcheck disable=SC2086  # PRUNE is a deliberate fragment of the find expression
    find "$ROOT" $PRUNE -type f -size "-${MAXSIZE}c" -print0 2>/dev/null \
        | xargs -0 grep -nIH -F -- "$VAR" /dev/null 2>/dev/null >> "$ROWS" || true
done

redact() {
    # $1 is the line, $2 the variable name. Any value-looking tail after
    # NAME=/NAME:/NAME<space> is replaced: the value is never useful for
    # classification and must not be reproduced.
    printf '%s' "$1" | sed -E "s/(\"?$2\"?[[:space:]]*[=:][[:space:]]*)\"[^\"]*\"/\\1\"[redacted]\"/g; s/(\"?$2\"?[[:space:]]*[=:][[:space:]]*)[^[:space:]\"',]+/\\1[redacted]/g"
}

classify() {
    # $1 path, $2 text
    path="$1"; text="$2"
    case "$path" in
        *.yml|*.yaml|*.yml.j2|*.yaml.j2)
            case "$text" in
                *env_file*) printf 'container-env-file' ;;
                *'${'"$VAR"*|*'$'"$VAR"*) printf 'compose-interpolation' ;;
                *) printf 'reference' ;;
            esac
            ;;
        *.service|*.timer|*.socket|*.target|*.mount)
            case "$text" in
                *EnvironmentFile*) printf 'systemd-environmentfile' ;;
                *) printf 'reference' ;;
            esac
            ;;
        *)
            case "$text" in
                *--env-file*) printf 'env-file-flag' ;;
                *'{{'"$VAR"'}}'*|*'%'"$VAR"'%'*|*'${'"$VAR"*|*'$'"$VAR"*) printf 'template-reference' ;;
                *'source '*.env*|*'source "'*'.env"'*|*'. '*.env*|*'. "'*'.env"'*) printf 'shell-source' ;;
                *) printf 'reference' ;;
            esac
            ;;
    esac
}

COUNT=0
while IFS= read -r ROW; do
    [ -n "$ROW" ] || continue
    LOC="${ROW%%:*}"
    REST="${ROW#*:}"
    LINE="${REST%%:*}"
    TEXT="${REST#*:}"
    case "$LINE" in
        ''|*[!0-9]*) continue ;;
    esac
    printf '%s\t%s\t%s\n' "$LOC:$LINE" "$(classify "$LOC" "$TEXT")" "$(redact "$TEXT" "$VAR")"
    COUNT=$((COUNT + 1))
done < "$ROWS"

echo "find-consumers: $VAR -> $COUNT reference(s) under: $*" >&2
[ "$COUNT" -gt 0 ] || exit 1
exit 0
