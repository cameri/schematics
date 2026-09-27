#!/bin/sh
#
# find-consumers.sh - inventory every consumer of a variable, with its mechanism.
#
# Usage:
#   find-consumers.sh [--all] [--max-size <bytes>] [--exclude <dir>]… \
#                     [--value-stdin] <VAR> [<search-root> ...]
#
# Prints one tab-separated row per reference:
#
#   <path>:<line>   <mechanism>   <text>
#
# The text has every occurrence of the value redacted (`NAME=[redacted]`),
# because the file being searched routinely holds the secret itself and an
# inventory that prints it would be a second copy of the secret — in a terminal,
# a log, or a report. Only the name and the shape of the line are useful for
# classification.
#
# Redaction covers the shapes a value is written in, and the second one needs
# the value itself, not only the name:
#
#   NAME=<value>        bare, quoted with `"…"` or `'…'`, or spaced around the
#                       separator: all become `NAME=[redacted]`
#   the value inlined   the value's own bytes anywhere on the line, with no name
#                       in front of it — an auth header, a JSON body, a
#                       trailing comment
#
# The inlined shape carries no syntax to match on, so only its bytes catch it:
# supply the value with `--value-stdin` (one value per line, read from stdin so
# it never reaches argv or the shell history — the route `sops set
# --value-stdin` already uses), or have it set in this script's own environment
# as `$VAR`, or both. With neither, redaction is name-keyed only and an inlined
# occurrence prints in the clear. A supplied value may carry one layer of
# surrounding quotes: they are stripped, so the bare bytes match everywhere. An
# empty or whitespace-only value is ignored.
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
# searches everything except the one scratch directory this run created.
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
VALUES_IN=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --all)          ALL=1; shift ;;
        --max-size)     [ "$#" -ge 2 ] || usage; MAXSIZE="$2"; shift 2 ;;
        --exclude)      [ "$#" -ge 2 ] || usage; EXCLUDES="$EXCLUDES $2"; shift 2 ;;
        --value-stdin)  VALUES_IN=1; shift ;;
        -h|--help)      usage ;;
        --)             shift; break ;;
        -*)             echo "find-consumers: unknown option: $1" >&2; usage ;;
        *)              break ;;
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

# Scratch lives in a private directory of its own, and the scan skips that one
# directory by its exact name: the sed program it holds carries the variable's
# own name, so a scratch file the search could reach would come back as a row
# about itself. Matching the name `mktemp -d` returned — not the prefix the
# template shares with it — is what keeps the skip from hiding a real directory
# that happens to be called `find-consumers.<something>`: an inventory that
# silently drops a consumer is worse than one that reports the tool's own file.
# `mktemp -d` creates the directory 0700, and the umask below keeps the files
# inside it 0600, which matters — the redaction program holds every value the
# caller supplied.
umask 077
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/find-consumers.XXXXXXXX")"
TMPSKIP="$(basename "$TMPD")"
ROWS="$TMPD/rows"
SEDSCRIPT="$TMPD/sed"
trap 'rm -f "$ROWS" "$SEDSCRIPT"; rmdir "$TMPD" 2>/dev/null || true' EXIT INT TERM HUP PIPE QUIT

escape_literal() {
    # $1 is a value; every ERE metacharacter and the delimiter is escaped so the
    # expression matches exactly its own bytes and nothing else.
    printf '%s' "$1" | sed -e 's/[][\\/.^$*+?(){}|]/\\&/g'
}

strip_quotes() {
    # $1 is a value read out of a dotenv file, which may still carry the quotes
    # it was written with; the bytes inside them are what must match.
    sv="$1"
    case "$sv" in
        \"*\") sv="${sv#\"}"; sv="${sv%\"}" ;;
        \'*\') sv="${sv#\'}"; sv="${sv%\'}" ;;
    esac
    printf '%s' "$sv"
}

add_value() {
    # $1 is a candidate value. Anything without a non-blank character is
    # dropped: an empty pattern matches everywhere and would redact every line
    # whole, which destroys the output instead of protecting it.
    sv="$(strip_quotes "$1")"
    case "$sv" in
        *[![:space:]]*) ;;
        *) return 0 ;;
    esac
    printf 's/%s/[redacted]/g\n' "$(escape_literal "$sv")" >> "$SEDSCRIPT"
}

# The name-keyed shape first: `NAME` or `"NAME"`, optional space, `=` or `:`,
# then a value that is double-quoted, single-quoted, or bare. The quoted forms
# come first so a value containing a space is taken whole, and each is replaced
# together with its quotes — which is the `NAME=[redacted]` the header promises.
# A bare value stops at whitespace, so a trailing comment still classifies.
SQ="'[^']*'"
printf 's/("?%s"?[[:space:]]*[=:][[:space:]]*)("[^"]*"|%s|[^[:space:]]+)/\\1[redacted]/g\n' \
    "$VAR" "$SQ" >> "$SEDSCRIPT"

# The inlined shape: the value's own bytes, wherever a line that matched the
# name happens to carry them.
if [ "$VALUES_IN" -eq 1 ]; then
    # tr: a dotenv file written on another platform may carry carriage returns.
    tr -d '\r' | while IFS= read -r VLINE || [ -n "$VLINE" ]; do
        add_value "$VLINE"
    done
fi

# The caller usually holds the value already, so `$VAR` in this script's own
# environment is redacted as a literal too. Building the reference into the
# `eval` is the portable form of an indirect expansion, and it is safe because
# VAR was validated as a bare name above. Over-redaction is the safe direction:
# a missed occurrence is a secret in a transcript.
ENVVAL=""
eval "ENVVAL=\${$VAR-}"
add_value "$ENVVAL"

for ROOT in "$@"; do
    if [ ! -e "$ROOT" ]; then
        echo "find-consumers: no such path: $ROOT" >&2
        continue
    fi
    if [ "$ALL" -eq 1 ]; then
        PRUNE="( -name $TMPSKIP ) -prune -o"
    else
        PRUNE='( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name site-packages'
        for X in $EXCLUDES; do
            PRUNE="$PRUNE -o -name $X"
        done
        PRUNE="$PRUNE -o -name $TMPSKIP ) -prune -o"
    fi
    # `--`-terminated file list piped to grep: no recursion, no argv limits, and
    # /dev/null keeps grep from ever reading stdin when the list is empty.
    # shellcheck disable=SC2086  # PRUNE is a deliberate fragment of the find expression
    find "$ROOT" $PRUNE -type f -size "-${MAXSIZE}c" -print0 2>/dev/null \
        | xargs -0 grep -nIH -F -- "$VAR" /dev/null 2>/dev/null >> "$ROWS" || true
done

redact() {
    # $1 is the line. Every expression was built into $SEDSCRIPT before the
    # scan began: the name-keyed shapes, then one literal expression per known
    # value. A value is never useful for classification and must not be
    # reproduced.
    printf '%s' "$1" | sed -E -f "$SEDSCRIPT"
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
    printf '%s\t%s\t%s\n' "$LOC:$LINE" "$(classify "$LOC" "$TEXT")" "$(redact "$TEXT")"
    COUNT=$((COUNT + 1))
done < "$ROWS"

echo "find-consumers: $VAR -> $COUNT reference(s) under: $*" >&2
[ "$COUNT" -gt 0 ] || exit 1
exit 0
