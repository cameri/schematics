#!/bin/sh
#
# sops-shared.sh - operate on a shared SOPS dotenv store.
#
# Usage:
#   sops-shared.sh keys          <store-file> [--age-key <path>]
#   sops-shared.sh set           <store-file> <NAME> [--value-file <path> | --value-json <path>] [--age-key <path>]
#   sops-shared.sh remove        <store-file> <NAME> [--age-key <path>]
#   sops-shared.sh extract       <store-file> <out-file> <KEY>[,<KEY>…] [--consumer-key <path>] [--age-key <path>]
#   sops-shared.sh add-recipient <store-file> <age1…> [--age-key <path>]
#
#   keys           print the store's key NAMES, one per line, never a value.
#   set            create or replace one value; it arrives on stdin (masked when
#                  stdin is a terminal) or from --value-file, is JSON-encoded,
#                  and is piped to `sops set --value-stdin`, so it never appears
#                  in argv, in shell history, or in a process listing. A value
#                  with a leading or trailing newline is refused: `echo value |
#                  ...` adds one, it is almost never intended, and it reaches the
#                  consumer as part of the secret. --value-json takes a value
#                  that is ALREADY JSON-encoded and skips the encoder, which is
#                  the path for a host with neither python3 nor jq.
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
# Requires a `sops` binary on this host. Without one every command here refuses
# with an explanation rather than half-working: an in-place mutation through a
# bind mount is not something this helper attempts. `encrypt-container-secrets`'
# own `sops-set-env.sh` does implement a container fallback for value-setting.
#
# POSIX sh. Writes only the store it is given (and, for `extract`, the output
# file). A hand-edited store is never produced: every mutation is a decrypt,
# transform, re-encrypt, and rename. Every read decrypts to a 0600 temporary
# file first, so a store that cannot be decrypted is an error and never looks
# like an empty store.

set -eu

usage() {
    # Print the leading comment block verbatim (from `#` through the first
    # non-comment line): a hard-coded line range goes stale on the next edit.
    awk 'NR > 2 { if (sub(/^# ?/, "")) { print; next } exit }' "$0"
    exit 2
}

[ "$#" -ge 2 ] || usage
CMD="$1"; STORE="$2"; shift 2

KEY_DIR="${KEY_DIR:-$HOME/sops/age}"
SOPS_IMAGE="${SOPS_IMAGE:-ghcr.io/getsops/sops:v3.11.0-alpine}"
AGE_KEY="${SOPS_AGE_KEY_FILE:-$KEY_DIR/keys.txt}"

VALUE_FILE=""
VALUE_JSON=""
CONSUMER_KEY=""
NAME=""
OUT_FILE=""
KEYS=""
NEW_RECIPIENT=""

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
        --value-json)   [ "$#" -ge 2 ] || usage; VALUE_JSON="$2"; shift 2 ;;
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
TMP_CLEANUP=""

sops_run() {
    # sops_run <input-file-or-'-' ... : runs sops with the age key exported.
    if [ "$HAVE_SOPS" -eq 1 ]; then
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops "$@"
        return
    fi
    echo "sops-shared: no sops binary on this host; this helper refuses rather than" >&2
    echo "sops-shared: half-working. Install it (the alpine image ships the binary:" >&2
    echo "sops-shared: docker create --entrypoint sops ${SOPS_IMAGE} --version), or run" >&2
    echo "sops-shared: the operation where the binary exists. For value-setting only," >&2
    echo "sops-shared: the sibling package's sops-set-env.sh has a container fallback." >&2
    exit 1
}

decrypt_dotenv() {
    sops_run --decrypt --input-type dotenv --output-type dotenv "$STORE"
}

# Decrypt to a 0600 temporary file and fail loudly. Piping the decryption into
# grep would make the pipeline's status grep's, so an unreadable store (wrong
# key, corrupt file, no sops binary) would look like an empty one — and an empty
# store that is then re-encrypted destroys every value in it. Sets DECRYPTED.
decrypt_to_tmp() {
    DECRYPTED="$(mktemp)"
    chmod 600 "$DECRYPTED"
    if ! decrypt_dotenv > "$DECRYPTED"; then
        echo "sops-shared: cannot decrypt $STORE with $AGE_KEY; no change made" >&2
        rm -f "$DECRYPTED"
        exit 1
    fi
    case "$TMP_CLEANUP" in
        "") TMP_CLEANUP="$DECRYPTED"; trap 'rm -f $TMP_CLEANUP' EXIT INT TERM ;;
        *)  TMP_CLEANUP="$TMP_CLEANUP $DECRYPTED" ;;
    esac
}

store_keys() {
    decrypt_to_tmp
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$DECRYPTED" | grep -v '^sops_' | sort -u || true
}

recipients_of() {
    # The recipient list is plaintext inside the ciphertext file: no key needed.
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
    [ -z "$VALUE_FILE" ] || [ -z "$VALUE_JSON" ] || {
        echo "sops-shared: --value-file and --value-json are mutually exclusive" >&2
        exit 2
    }
    TMPF="$(mktemp)"
    TMPJ="$(mktemp)"
    TMP_CLEANUP="$TMP_CLEANUP $TMPF $TMPJ"
    trap 'rm -f $TMP_CLEANUP' EXIT INT TERM
    chmod 600 "$TMPF" "$TMPJ"

    if [ -n "$VALUE_JSON" ]; then
        # Already JSON-encoded: this is the path for a host with neither python3
        # nor jq. The value never reaches argv.
        [ -f "$VALUE_JSON" ] || { echo "sops-shared: no such JSON file: $VALUE_JSON" >&2; exit 1; }
        [ -s "$VALUE_JSON" ] || { echo "sops-shared: $VALUE_JSON is empty" >&2; exit 1; }
        cp "$VALUE_JSON" "$TMPJ"
        chmod 600 "$TMPJ"
    elif [ -n "$VALUE_FILE" ]; then
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

    if [ -z "$VALUE_JSON" ]; then
        [ -s "$TMPF" ] || { echo "sops-shared: refusing to store an empty value" >&2; exit 1; }
        # A leading or trailing newline is almost always `echo` rather than the
        # operator's intent, and it reaches the consumer as part of the secret.
        # `wc -l` counts newline bytes, so one byte of the file tells the story.
        if [ "$(tail -c 1 "$TMPF" | wc -l)" -eq 1 ]; then
            echo "sops-shared: the value ends with a newline; refusing" >&2
            echo "sops-shared: pipe it without one (printf 'value'), or pass an encoded value with --value-json" >&2
            exit 1
        fi
        if [ "$(head -c 1 "$TMPF" | wc -l)" -eq 1 ]; then
            echo "sops-shared: the value starts with a newline; refusing" >&2
            exit 1
        fi

        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import json,sys; sys.stdout.write(json.dumps(open(sys.argv[1]).read()))' "$TMPF" > "$TMPJ"
        elif command -v jq >/dev/null 2>&1; then
            jq -Rs . < "$TMPF" > "$TMPJ"
        else
            echo "sops-shared: need python3 or jq to JSON-encode the value" >&2
            echo "sops-shared: encode it yourself and pass it with --value-json <path>" >&2
            exit 1
        fi
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
    decrypt_to_tmp
    grep -qx "$NAME" "$DECRYPTED" 2>/dev/null || grep -qE "^${NAME}=" "$DECRYPTED" || {
        echo "sops-shared: $NAME is not in $STORE" >&2
        exit 1
    }
    TMPD="$(mktemp)"
    TMP_CLEANUP="$TMP_CLEANUP $TMPD"
    trap 'rm -f $TMP_CLEANUP' EXIT INT TERM
    chmod 600 "$TMPD"
    grep -v -E "^${NAME}=|^[[:space:]]+" "$DECRYPTED" > "$TMPD"
    RECIPS="$(recipients_of | paste -sd, -)"
    [ -n "$RECIPS" ] || { echo "sops-shared: no recipients found in $STORE; refusing to re-encrypt" >&2; exit 1; }
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops --input-type dotenv --output-type dotenv \
        --encrypt --age "$RECIPS" "$TMPD" > "$STORE.new"
    mv "$STORE.new" "$STORE"
    echo "sops-shared: removed $NAME from $STORE" >&2
    ;;

extract)
    TMPD="$(mktemp)"
    TMP_CLEANUP="$TMP_CLEANUP $TMPD"
    trap 'rm -f $TMP_CLEANUP' EXIT INT TERM
    chmod 600 "$TMPD"
    decrypt_to_tmp

    # Keep the named keys, in the store's own order, and nothing else.
    PREFIXES="$(printf '%s' "$KEYS" | tr ',' '\n' | sed 's/^/^/; s/$/=/' | paste -sd'|' -)"
    [ -n "$PREFIXES" ] || { echo "sops-shared: extract needs at least one key" >&2; exit 2; }
    grep -E "$PREFIXES" "$DECRYPTED" > "$TMPD"
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
    TMP_CLEANUP="$TMP_CLEANUP $TMPD"
    trap 'rm -f $TMP_CLEANUP' EXIT INT TERM
    chmod 600 "$TMPD"
    decrypt_to_tmp
    cp "$DECRYPTED" "$TMPD"
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
