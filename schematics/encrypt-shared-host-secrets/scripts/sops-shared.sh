#!/bin/sh
#
# sops-shared.sh - operate on a shared SOPS dotenv store.
#
# Usage:
#   sops-shared.sh keys          <store-file> [--age-key <path>]
#   sops-shared.sh set           <store-file> <NAME> [--value-file <path>] [--age-key <path>]
#   sops-shared.sh remove        <store-file> <NAME> [--age-key <path>]
#   sops-shared.sh extract       <store-file> <out-file> <KEY>[,<KEY>…] [--consumer-key <path>] [--age-key <path>]
#   sops-shared.sh add-recipient <store-file> <age1…> [--age-key <path>]
#
#   keys           print the store's key NAMES, one per line, never a value.
#   set            create or replace one value; it arrives on stdin (masked when
#                  stdin is a terminal) or from --value-file, is JSON-encoded,
#                  and is piped to `sops set --value-stdin`, so it never appears
#                  in argv, in shell history, or in a process listing.
#   remove         drop one key and the value with it; the remaining keys and the
#                  recipient list are preserved.
#   extract        write a projection: a new store holding only the named keys,
#                  encrypted to the store's recipients plus --consumer-key's
#                  public half when given. This is how a consumer that reads a
#                  subset of the store gets a key that opens only its own file.
#   add-recipient  re-encrypt the store to one more age recipient.
#
# --age-key defaults to $SOPS_AGE_KEY_FILE, else ${KEY_DIR:-$HOME/sops/age}/keys.txt.
# The master key is the default: it opens every store and projection, and it
# never leaves the host. Pass a consumer key to operate on a projection.
#
# Environment:
#   KEY_DIR      key directory. Default: $HOME/sops/age
#   SOPS_IMAGE   image used when the host has no sops binary.
#                Default: ghcr.io/getsops/sops:v3.11.0-alpine
#
# Run on the machine whose paths the Docker daemon sees: the container fallback
# bind-mounts the store's directory, the key file, and the output directory.
#
# POSIX sh. Writes only the store it is given (and, for `extract`, the output
# file). A hand-edited store is never produced: every mutation is a decrypt,
# transform, re-encrypt, and rename.

set -eu

usage() {
    sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[ "$#" -ge 2 ] || usage
CMD="$1"; STORE="$2"; shift 2

KEY_DIR="${KEY_DIR:-$HOME/sops/age}"
SOPS_IMAGE="${SOPS_IMAGE:-ghcr.io/getsops/sops:v3.11.0-alpine}"
AGE_KEY="${SOPS_AGE_KEY_FILE:-$KEY_DIR/keys.txt}"

VALUE_FILE=""
CONSUMER_KEY=""
NAME=""
OUT_FILE=""
KEYS=""

# Positional arguments first (one or two), then options: keeps the CLI readable
# and rejects a typo instead of silently reinterpreting it.
case "$CMD" in
    keys)          [ "$#" -ge 0 ] || usage ;;
    set)           [ "$#" -ge 1 ] || usage; NAME="$1"; shift ;;
    remove)        [ "$#" -ge 1 ] || usage; NAME="$1"; shift ;;
    extract)       [ "$#" -ge 2 ] || usage; OUT_FILE="$1"; KEYS="$2"; shift 2 ;;
    add-recipient) [ "$#" -ge 1 ] || usage; NEW_RECIPIENT="$1"; shift ;;
    *) usage ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --age-key)      [ "$#" -ge 2 ] || usage; AGE_KEY="$2"; shift 2 ;;
        --value-file)   [ "$#" -ge 2 ] || usage; VALUE_FILE="$2"; shift 2 ;;
        --consumer-key) [ "$#" -ge 2 ] || usage; CONSUMER_KEY="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *) echo "sops-shared: unexpected argument: $1" >&2; usage ;;
    esac
done

case "$CMD" in
    set)
        case "$NAME" in
            ''|[0-9]*|*[!A-Za-z0-9_]*) echo "sops-shared: not a variable name: $NAME" >&2; exit 2 ;;
        esac
        ;;
esac

[ -f "$STORE" ] || { echo "sops-shared: no such store: $STORE" >&2; exit 1; }
[ -f "$AGE_KEY" ] || { echo "sops-shared: no such age key: $AGE_KEY" >&2; exit 1; }

# --- sops invocation -------------------------------------------------------
# `keys` and `extract` produce output on stdout, which the container fallback
# can carry back through the terminal; `set`, `remove` and `add-recipient`
# rewrite a file the container fallback must reach through a bind mount.
HAVE_SOPS=0
command -v sops >/dev/null 2>&1 && HAVE_SOPS=1

sops_run() {
    # sops_run <input-file-or-'-' ... : runs sops with the age key exported.
    if [ "$HAVE_SOPS" -eq 1 ]; then
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops "$@"
        return
    fi
    echo "sops-shared: no sops binary on this host; the fallback needs to bind-mount" >&2
    echo "sops-shared: the store and key directories, so in-place commands run through" >&2
    echo "sops-shared: 'docker create'+'start', which is out of scope for this helper." >&2
    echo "sops-shared: install sops (its alpine image ships the binary: docker run --rm" >&2
    echo "sops-shared: --entrypoint sops ${SOPS_IMAGE} --version), or use --help for the" >&2
    echo "sops-shared: hand-run equivalents in the schematic's phases." >&2
    exit 1
}

decrypt_dotenv() {
    sops_run --decrypt --input-type dotenv --output-type dotenv "$STORE"
}

store_keys() {
    decrypt_dotenv | grep -oE '^[A-Za-z_][A-Za-z0-9_]*' | grep -v '^sops_' | sort -u
}

recipients_of() {
    # Every recipient currently named in the store, in file order, deduplicated.
    decrypt_dotenv >/dev/null 2>&1 || true   # ensure the file is readable first
    grep -o 'age1[a-z0-9]*' "$STORE" | awk '!seen[$0]++'
}

pubkey_of() {
    # The public half of an age private key file. Introduced in age 1.x:
    # `age-keygen -y` is the reliable path; the `public key:` comment line is a
    # convenience some versions write.
    if command -v age-keygen >/dev/null 2>&1; then
        age-keygen -y "$1" 2>/dev/null && return 0
    fi
    sed -n 's/^#[[:space:]]*public key:[[:space:]]*//p' "$1" | head -n 1
}

# --- commands --------------------------------------------------------------

case "$CMD" in

keys)
    store_keys
    ;;

set)
    TMPF="$(mktemp)"
    TMPJ="$(mktemp)"
    trap 'rm -f "$TMPF" "$TMPJ"' EXIT INT TERM
    chmod 600 "$TMPF" "$TMPJ"

    if [ -n "$VALUE_FILE" ]; then
        [ -f "$VALUE_FILE" ] || { echo "sops-shared: no such value file: $VALUE_FILE" >&2; exit 1; }
        cat "$VALUE_FILE" > "$TMPF"
    elif [ -t 0 ]; then
        printf 'value for %s: ' "$NAME" >&2
        if stty -echo 2>/dev/null; then
            trap 'stty echo 2>/dev/null; rm -f "$TMPF" "$TMPJ"' EXIT INT TERM
            IFS= read -r VAL || true
            stty echo 2>/dev/null
            trap 'rm -f "$TMPF" "$TMPJ"' EXIT INT TERM
        else
            IFS= read -r VAL || true
        fi
        printf '\n' >&2
        printf '%s' "$VAL" > "$TMPF"
    else
        cat > "$TMPF"
    fi

    [ -s "$TMPF" ] || { echo "sops-shared: refusing to store an empty value" >&2; exit 1; }

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; sys.stdout.write(json.dumps(open(sys.argv[1]).read()))' "$TMPF" > "$TMPJ"
    elif command -v jq >/dev/null 2>&1; then
        jq -Rs . < "$TMPF" > "$TMPJ"
    else
        echo "sops-shared: need python3 or jq to JSON-encode the value" >&2
        echo "sops-shared: (pass --value-file with an already JSON-encoded value instead)" >&2
        exit 1
    fi

    # Index format is ["KEY"] - the double quotes inside the brackets are
    # required, and the value arrives on stdin so it stays out of argv.
    # The type flags belong to `set`, so they follow the subcommand: sops
    # accepts them as global flags without error and then parses the value as
    # JSON, which fails with a message about the value, not about the flag.
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops set --input-type dotenv --output-type dotenv \
        --value-stdin "$STORE" "[\"$NAME\"]" < "$TMPJ"
    echo "sops-shared: set $NAME in $STORE" >&2
    ;;

remove)
    store_keys | grep -qx "$NAME" || { echo "sops-shared: $NAME is not in $STORE" >&2; exit 1; }
    TMPD="$(mktemp)"
    trap 'rm -f "$TMPD"' EXIT INT TERM
    chmod 600 "$TMPD"
    decrypt_dotenv | grep -v -E "^${NAME}=|^[[:space:]]+" > "$TMPD"
    RECIPS="$(recipients_of | paste -sd, -)"
    [ -n "$RECIPS" ] || { echo "sops-shared: no recipients found in $STORE; refusing to re-encrypt" >&2; exit 1; }
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops --input-type dotenv --output-type dotenv \
        --encrypt --age "$RECIPS" "$TMPD" > "$STORE.new"
    mv "$STORE.new" "$STORE"
    echo "sops-shared: removed $NAME from $STORE" >&2
    ;;

extract)
    TMPD="$(mktemp)"
    trap 'rm -f "$TMPD"' EXIT INT TERM
    chmod 600 "$TMPD"

    # Keep the named keys, in the store's own order, and nothing else.
    PREFIXES="$(printf '%s' "$KEYS" | tr ',' '\n' | sed 's/^/^/; s/$/=/' | paste -sd'|' -)"
    [ -n "$PREFIXES" ] || { echo "sops-shared: extract needs at least one key" >&2; exit 2; }
    decrypt_dotenv | grep -E "$PREFIXES" > "$TMPD"
    [ -s "$TMPD" ] || {
        echo "sops-shared: none of $KEYS is in $STORE; nothing to extract" >&2
        exit 1
    }

    RECIPS="$(recipients_of | paste -sd, -)"
    if [ -n "$CONSUMER_KEY" ]; then
        [ -f "$CONSUMER_KEY" ] || { echo "sops-shared: no such consumer key: $CONSUMER_KEY" >&2; exit 1; }
        CPUB="$(pubkey_of "$CONSUMER_KEY")"
        [ -n "$CPUB" ] || {
            echo "sops-shared: cannot derive the public half of $CONSUMER_KEY" >&2
            echo "sops-shared: install age for 'age-keygen -y', or keep the 'public key:' comment line in the key file" >&2
            exit 1
        }
        RECIPS="$RECIPS,$CPUB"
    fi

    OUT_DIR="$(cd "$(dirname "$OUT_FILE")" && pwd)"
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops --input-type dotenv --output-type dotenv \
        --encrypt --age "$RECIPS" "$TMPD" > "$OUT_DIR/$(basename "$OUT_FILE").new"
    mv "$OUT_DIR/$(basename "$OUT_FILE").new" "$OUT_FILE"
    echo "sops-shared: wrote $OUT_FILE with $(wc -l < "$TMPD") key(s) to: $RECIPS" >&2
    ;;

add-recipient)
    case "$NEW_RECIPIENT" in
        age1*) : ;;
        *) echo "sops-shared: not an age recipient: $NEW_RECIPIENT" >&2; exit 2 ;;
    esac
    TMPD="$(mktemp)"
    trap 'rm -f "$TMPD"' EXIT INT TERM
    chmod 600 "$TMPD"
    decrypt_dotenv > "$TMPD"
    RECIPS="$(recipients_of | paste -sd, -)"
    case ",$RECIPS," in
        *",$NEW_RECIPIENT,"*) echo "sops-shared: already a recipient of $STORE" >&2; exit 0 ;;
    esac
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops --input-type dotenv --output-type dotenv \
        --encrypt --age "$RECIPS,$NEW_RECIPIENT" "$TMPD" > "$STORE.new"
    mv "$STORE.new" "$STORE"
    echo "sops-shared: $STORE now has recipients: $RECIPS,$NEW_RECIPIENT" >&2
    ;;
esac
