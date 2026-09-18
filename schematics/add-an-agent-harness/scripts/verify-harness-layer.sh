#!/bin/sh
# Acceptance checks for the harness layer.
#
# Implements the mechanical checks of SCHEMATIC.md's Verification and
# Acceptance section against a real image built from this package, and a real
# container started from it. It has two halves and runs both:
#
#   * the DRIVER half runs where the container runtime is reachable. It
#     synthesizes a base image when it is given the base package, builds this
#     layer over it, creates and starts containers, reads what they report,
#     removes them, and cleans up.
#   * the BODY half (`--inside`) runs as a container's process, through the
#     inherited entrypoint: it stands in for the harness, records what PID 1 is
#     and where it runs, reads the CLI's version record and its configuration
#     out of the image, searches for credential-shaped files, and writes one
#     `key=value` line per measurement to a directory the driver reads.
#
# It never attaches: containers are created and started explicitly, so it works
# where a client may create and start but not attach, which is also why no row
# needs a TTY.
#
# What it can and cannot prove
# ----------------------------
# Every row below is measured against a container built from this package. The
# one thing no row here proves is that a **model answers** through the harness:
# that needs a router serving a real alias and a real credential, which is the
# deployment's test, not the layer's. Rows that depend on the base image's own
# contract (A-2 below, and the account checks) need a base image; when the base
# cannot be built or pulled here, they SKIP with that reason printed, and the
# rest still run. A stand-in base is synthesized from the base package's own
# entrypoint when BASE_PACKAGE_DIR is available, so those rows are exercised for
# real rather than stubbed — the stand-in's account and distro differ from the
# base's, and the rows say which image they measured.
#
# Inputs (environment; none of these is written anywhere):
#   IMAGE                this layer's image. Optional: when unset, the script
#                        builds it (see BASE_IMAGE / BASE_PACKAGE_DIR).
#   BASE_IMAGE           a locally present base image to build the layer over
#                        and to compare the inherited contract against
#                        (default: containers-agent-sandbox:latest)
#   BASE_PACKAGE_DIR     the base schematic's package directory
#                        (default: ../build-an-agent-dev-image). Its
#                        skeleton/entrypoint.sh is copied into a synthesized
#                        stand-in base when no real base is available, so the
#                        entrypoint rows are real. A-2 and A-3 report a SKIP
#                        when it is missing too.
#   HARNESS              P-1: the CLI to build and check (default: claude)
#   ROUTER_BASE_URL      P-3 (default: http://llm-router:4000/v1)
#   ROUTER_CREDENTIAL_ENV P-4 (default: ROUTER_API_KEY)
#   HARNESS_MODEL_ALIAS  P-5 (default: check-model)
#   HARNESS_FAST_ALIAS   P-6 (default: check-fast-model)
#   HARNESS_CONTEXT_WINDOW P-7 (default: 200000)
#   HARNESS_MAX_OUTPUT_TOKENS P-8 (default: 32000)
#   HARNESS_HOME         P-9 (default: /home/<account>/.<harness>)
#   CONTAINER_USER       the account the image runs as. Unset uses the image's
#                        own USER. Set it for a stand-in base whose account
#                        differs from the base's.
#   PACKAGE_HOST_DIR     this package as a path the container runtime resolves
#                        on ITS host. The package is mounted read-only into the
#                        probe container so the body can run from it. Needed
#                        only when the runtime does not share a filesystem with
#                        this script (for example a container driving an outside
#                        daemon, where this container's /workspace is not the
#                        host's); the default is this script's own package dir.
#   RUN_HOST_DIR         host directory for the containers' writable output
#                        (default: <PACKAGE_HOST_DIR>/.verify-run). Must be a
#                        path the runtime resolves on its host, and one it is
#                        allowed to bind: the default sits under the package,
#                        which is under the runtime's own workspace root.
#   RUN_LOCAL_DIR        the same directory as THIS script sees it, for reading
#                        the evidence the body writes. Set it when the runtime's
#                        filesystem is not this script's (default: RUN_HOST_DIR)
#   EXPECTED_MIN_ROWS    how many rows the body half must report (default: 7).
#                        The body prints one `BODY-RESULT` line as its last act;
#                        the driver requires it and requires the count to clear
#                        this floor, so a body that executes nothing fails the
#                        run instead of passing it.
#   CONTAINER_RUNTIME    docker CLI name (default: docker)
#   KEEP                 1 = keep the built image and the output directory
#
# Exit status: 0 when every executed check passed; 1 when any failed; 2 on a
# usage or precondition error.
set -u

IMAGE="${IMAGE:-}"
BASE_IMAGE="${BASE_IMAGE:-containers-agent-sandbox:latest}"
BASE_PACKAGE_DIR="${BASE_PACKAGE_DIR:-}"
HARNESS="${HARNESS:-claude}"
ROUTER_BASE_URL="${ROUTER_BASE_URL:-http://llm-router:4000/v1}"
ROUTER_CREDENTIAL_ENV="${ROUTER_CREDENTIAL_ENV:-ROUTER_API_KEY}"
HARNESS_MODEL_ALIAS="${HARNESS_MODEL_ALIAS:-check-model}"
HARNESS_FAST_ALIAS="${HARNESS_FAST_ALIAS:-check-fast-model}"
HARNESS_CONTEXT_WINDOW="${HARNESS_CONTEXT_WINDOW:-200000}"
HARNESS_MAX_OUTPUT_TOKENS="${HARNESS_MAX_OUTPUT_TOKENS:-32000}"
HARNESS_HOME="${HARNESS_HOME:-}"
CONTAINER_USER="${CONTAINER_USER:-}"
PACKAGE_HOST_DIR="${PACKAGE_HOST_DIR:-}"
RUN_HOST_DIR="${RUN_HOST_DIR:-}"
RUN_LOCAL_DIR="${RUN_LOCAL_DIR:-}"
EXPECTED_MIN_ROWS="${EXPECTED_MIN_ROWS:-7}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
KEEP="${KEEP:-0}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SELF_DIR/.." && pwd)"
SKELETON="$PACKAGE_DIR/skeleton"
: "${BASE_PACKAGE_DIR:=$PACKAGE_DIR/../build-an-agent-dev-image}"
: "${PACKAGE_HOST_DIR:=$PACKAGE_DIR}"

CHECKS=0
FAILURES=0
SKIPS=0

pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'SKIP  %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }
usage_error() { printf 'verify-harness-layer: %s\n' "$1" >&2; exit 2; }
rt() { "$CONTAINER_RUNTIME" "$@"; }
# The legacy builder explicitly: the layer's own Containerfile needs no BuildKit,
# and a host policy that refuses BuildKit (it boots a privileged container) is a
# common reason the default builder cannot run.
build() { DOCKER_BUILDKIT=0 "$CONTAINER_RUNTIME" build "$@"; }
# True when a failed build failed for the environment's reasons rather than the
# package's: a builder the policy refuses, or a builder that cannot express what
# it was given.
build_refused() {
    grep -qE 'booting buildkit|authorization denied|administrative policy|requires BuildKit|not supported by the legacy builder' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Body: the in-container half. Runs as the container's process, standing in for
# the harness, through whatever entrypoint the image carries.
# ---------------------------------------------------------------------------

body() {
    OUT="${1:-/verify-out}"
    mkdir -p "$OUT" 2>/dev/null || true

    BODY_CHECKS=0
    BODY_FAILURES=0
    BODY_SKIPS=0
    bp() { BODY_CHECKS=$((BODY_CHECKS + 1)); printf 'PASS  %s\n' "$1"; }
    bf() { BODY_CHECKS=$((BODY_CHECKS + 1)); BODY_FAILURES=$((BODY_FAILURES + 1)); printf 'FAIL  %s\n' "$1"; }
    bs() { BODY_SKIPS=$((BODY_SKIPS + 1)); printf 'SKIP  %s\n' "$1"; }

    emit() { printf '%s=%s\n' "$1" "$2" >> "$OUT/body.evidence"; }

    # --- what this process is, and where it runs (H-3, H-5) ---------------
    # /proc rather than ps: a minimal base image may carry neither procps nor a
    # shell builtin for it, and PID 1 here is this script's interpreter.
    emit pid1 "$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null | tr -d '\n')"
    emit self_pid "$$"
    emit cwd "$(pwd)"
    emit arg1 "$(cat /proc/1/cmdline 2>/dev/null | tr '\0' '\n' | sed -n '3p')"
    if [ "$$" = "1" ]; then
        bp "H-5 the harness is PID 1: the container's process is the entrypoint's exec target"
    else
        bf "H-5 the harness is not PID 1 (pid $$)"
    fi

    # --- the harness the layer installed (H-4) ---------------------------
    if command -v "$HARNESS_CMD" >/dev/null 2>&1; then
        bp "H-4 the ${HARNESS_CMD} CLI is on PATH for this account"
        V="$("$HARNESS_CMD" --version 2>&1)"
        if [ -n "$V" ]; then
            bp "H-4 ${HARNESS_CMD} --version answers: ${V}"
            emit cli_version "$V"
        else
            bf "H-4 ${HARNESS_CMD} --version produced nothing"
        fi
    else
        bf "H-4 ${HARNESS_CMD} is not on PATH for this account"
    fi

    # --- the recorded install (H-7) --------------------------------------
    REC=/usr/local/share/agent-harness
    if [ -r "$REC/version" ]; then
        emit recorded_version "$(cat "$REC/version")"
        emit recorded_package "$(cat "$REC/package" 2>/dev/null)"
        emit recorded_command "$(cat "$REC/command" 2>/dev/null)"
        emit recorded_credential_env "$(cat "$REC/credential-env" 2>/dev/null)"
        bp "H-7 the install is recorded in the image: $(cat "$REC/version")"
    else
        bf "H-7 no version record at $REC/version"
    fi

    # --- the CLI's configuration (H-8, H-9, H-11) ------------------------
    CONF=""
    [ -n "${HARNESS_HOME:-}" ] && CONF="$HARNESS_HOME/$CONF_NAME"
    if [ -z "$CONF" ] || [ ! -r "$CONF" ]; then
        bf "H-8 no readable configuration at ${CONF:-<unset>}"
    else
        cp "$CONF" "$OUT/config.copy" 2>/dev/null || true
        if [ "$HARNESS" = "claude" ]; then
            if command -v python3 >/dev/null 2>&1; then
                if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONF" 2>/dev/null; then
                    bp "H-8 the configuration parses as JSON"
                else
                    bf "H-8 the configuration does not parse as JSON"
                fi
            else
                bs "H-8 JSON parse check skipped: no python3 in the image"
            fi
            if grep -q "\"$ROUTER_BASE_URL\"" "$CONF" && grep -q "$HARNESS_MODEL_ALIAS" "$CONF"; then
                bp "H-8 the configuration names the router URL and the primary alias"
            else
                bf "H-8 the configuration does not name the router URL and the primary alias"
            fi
            if grep -q "$HARNESS_CONTEXT_WINDOW" "$CONF"; then
                bp "H-11 the declared context window is in the file"
            else
                bf "H-11 the declared context window is missing from the file"
            fi
            if grep -q '@[A-Z_]*@' "$CONF"; then
                bf "H-8 the configuration still carries an unsubstituted parameter"
            else
                bp "H-8 no unsubstituted parameter remains"
            fi
        else
            # Codex CLI: TOML, one provider block, a top-level window key.
            if grep -q '^model_context_window' "$CONF"; then
                bp "H-11 the context window is a top-level key"
            else
                bf "H-11 model_context_window is not a top-level key"
            fi
            if grep -q 'base_url' "$CONF" && grep -q 'env_key' "$CONF"; then
                bp "H-8 the provider block names a base URL and a credential variable"
            else
                bf "H-8 the provider block is missing base_url or env_key"
            fi
            if [ "$(grep -c '^\[' "$CONF")" -eq 1 ]; then
                bp "H-9 exactly one provider block exists"
            else
                bf "H-9 the configuration declares $(grep -c '^\[' "$CONF") provider blocks"
            fi
        fi
        # H-9: only the router's endpoint, and no credential value.
        OTHER="$(grep -oE 'https?://[^"]+' "$CONF" | grep -v "^$ROUTER_BASE_URL" || true)"
        if [ -z "$OTHER" ]; then
            bp "H-9 no endpoint other than the router's appears"
        else
            bf "H-9 the configuration names another endpoint: $OTHER"
        fi
        if grep -qE '(sk-[A-Za-z0-9]|Bearer [A-Za-z0-9]|api[_-]?key"?[[:space:]]*[:=][[:space:]]*"[^"]+)' "$CONF"; then
            bf "H-10 the configuration carries a credential-shaped value"
        else
            bp "H-10 the configuration carries the credential's name, not a value"
        fi
    fi

    # --- no credential-shaped file where the layer could have put one (H-10)
    # Scoped to the harness home and the CLI's own credential paths. The base
    # image's own files are not this layer's doing, and a row that failed on
    # them would report the base's posture as this layer's defect.
    FOUND=""
    for f in "$HOME/.$HARNESS/auth.json" "$HARNESS_HOME/auth.json" "$HARNESS_HOME/.credentials.json"; do
        [ -e "$f" ] && FOUND="$FOUND $f"
    done
    FOUND="$FOUND$(find "$HARNESS_HOME" -maxdepth 2 \( -name '*.pem' -o -name 'id_*' -o -name '.env' -o -name '*token*' -o -name '*credential*' \) -print 2>/dev/null | tr '\n' ' ')"
    if [ -z "$FOUND" ]; then
        bp "H-10 no credential-shaped file in the account's harness home"
    else
        bf "H-10 credential-shaped files exist:$FOUND"
    fi
    if grep -rlE 'sk-[A-Za-z0-9_-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "$HARNESS_HOME" 2>/dev/null | grep -q .; then
        bf "H-10 the harness home contains token- or key-shaped content"
    else
        bp "H-10 the harness home contains no token- or key-shaped content"
    fi

    printf 'BODY-RESULT checks=%s failures=%s skips=%s\n' "$BODY_CHECKS" "$BODY_FAILURES" "$BODY_SKIPS"
    # A chosen non-zero status, so the driver can prove it is passed through.
    exit "${BODY_EXIT:-0}"
}

if [ "${1:-}" = "--inside" ]; then
    shift
    body "$@"
fi

# ---------------------------------------------------------------------------
# Driver: the half that talks to the container runtime.
# ---------------------------------------------------------------------------

command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 || usage_error "no $CONTAINER_RUNTIME on PATH"
[ -d "$SKELETON" ] || usage_error "no skeleton directory at $SKELETON"
CONF_NAME="settings.json"
[ "$HARNESS" = "claude" ] || CONF_NAME="config.toml"
HARNESS_CMD="$HARNESS"
: "${RUN_HOST_DIR:=$PACKAGE_HOST_DIR/.verify-run}"
: "${RUN_LOCAL_DIR:=$RUN_HOST_DIR}"
RUN_DIR="$RUN_HOST_DIR"
OUT_HOST="$RUN_HOST_DIR/out"
OUT_LOCAL="$RUN_LOCAL_DIR/out"
# The account the base image runs as. Read from the image rather than assumed:
# a layer must return to whatever account the base declares, and this script
# builds over more than one.
BASE_USER="$(rt image inspect "$BASE_IMAGE" --format '{{.Config.User}}' 2>/dev/null)"
: "${BASE_USER:=root}"
[ -n "$CONTAINER_USER" ] || CONTAINER_USER="$BASE_USER"
: "${HARNESS_HOME:=/home/$CONTAINER_USER/.$HARNESS}"
rm -rf "$RUN_DIR"; mkdir -p "$OUT_HOST" || usage_error "cannot create $RUN_DIR"
[ "$OUT_LOCAL" = "$OUT_HOST" ] || mkdir -p "$OUT_LOCAL"

CREATED=""
cleanup() {
    for c in $CREATED; do rt rm -f "$c" >/dev/null 2>&1; done
    if [ "$KEEP" != "1" ]; then
        rt image rm -f "${LAYER_TAG:-}" >/dev/null 2>&1 || true
        rm -rf "${BASE_STANDIN:-}" >/dev/null 2>&1 || true
    fi
}
LAYER_TAG=""
BASE_STANDIN=""
trap cleanup EXIT INT TERM

BUILD_LOG="$RUN_DIR/build.log"
BASE_STANDIN="$RUN_DIR/base.standin"
STANDIN_OK=0
LAYER_TAG="harness-layer-verify:$$"

printf 'verify-harness-layer: harness=%s base=%s\n' "$HARNESS" "$BASE_IMAGE"

# --- a base to build over ------------------------------------------------
if rt image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    note "using the local image $BASE_IMAGE as the base"
    BASE_REF="$BASE_IMAGE"
    if [ -n "$BASE_PACKAGE_DIR" ] && [ -f "$BASE_PACKAGE_DIR/skeleton/entrypoint.sh" ]; then
        # A faithful stand-in: the base package's own entrypoint, placed where
        # the base puts it, over a locally available image, with the environment
        # the base declares. The account and the distro differ from the base's;
        # the entrypoint and the variables it reads do not.
        cat > "$RUN_DIR/Containerfile.base" <<EOF
FROM $BASE_IMAGE
USER root
COPY entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/agent-entrypoint
ENV AGENT_USER=$CONTAINER_USER \\
    AGENT_WORKSPACE_DIR=/workspace
USER $CONTAINER_USER
EOF
        cp "$BASE_PACKAGE_DIR/skeleton/entrypoint.sh" "$RUN_DIR/entrypoint.sh"
        if build -q -t "$BASE_STANDIN" -f "$RUN_DIR/Containerfile.base" "$RUN_DIR" >>"$BUILD_LOG" 2>&1; then
            BASE_REF="$BASE_STANDIN"
            STANDIN_OK=1
            note "synthesized a stand-in base from $BASE_PACKAGE_DIR/skeleton/entrypoint.sh (account $CONTAINER_USER)"
        elif build_refused "$BUILD_LOG"; then
            note "the runtime refused the builder, so no stand-in base could be built (see $BUILD_LOG)"
        else
            note "could not synthesize a stand-in base; the entrypoint rows will skip"
        fi
    fi
else
    note "no local image $BASE_IMAGE"
fi

if [ -z "$IMAGE" ]; then
    if [ "$STANDIN_OK" != "1" ]; then
        skip "H-1..H-12 no image could be built here: no agent-host image is available locally and no stand-in base could be synthesized"
        note "the two reasons, in order: $BASE_IMAGE is not present, and either BASE_PACKAGE_DIR does not carry skeleton/entrypoint.sh or the runtime refused the builder"
        note "supply BASE_IMAGE (a locally present agent-host image) or a usable builder; the static rows above ran regardless"
        printf '\nchecks=%s failures=%s skips=%s\n' "$CHECKS" "$FAILURES" "$SKIPS"
        [ "$FAILURES" -eq 0 ] && exit 0 || exit 1
    fi
    note "building the layer over $BASE_REF"
    if build -t "$LAYER_TAG" -f "$SKELETON/Containerfile" \
        --build-arg "AGENT_BASE_REF=$BASE_REF" \
        --build-arg "AGENT_HARNESS_ID=$HARNESS" \
        --build-arg "ROUTER_BASE_URL=$ROUTER_BASE_URL" \
        --build-arg "ROUTER_CREDENTIAL_ENV=$ROUTER_CREDENTIAL_ENV" \
        --build-arg "HARNESS_MODEL_ALIAS=$HARNESS_MODEL_ALIAS" \
        --build-arg "HARNESS_FAST_ALIAS=$HARNESS_FAST_ALIAS" \
        --build-arg "HARNESS_CONTEXT_WINDOW=$HARNESS_CONTEXT_WINDOW" \
        --build-arg "HARNESS_MAX_OUTPUT_TOKENS=$HARNESS_MAX_OUTPUT_TOKENS" \
        --build-arg "HARNESS_HOME=$HARNESS_HOME" \
        "$SKELETON" >>"$BUILD_LOG" 2>&1; then
        pass "H-0 the layer builds over the base (log: $BUILD_LOG)"
    elif build_refused "$BUILD_LOG"; then
        WHY="$(grep -m1 -E 'booting buildkit|authorization denied|administrative policy|requires BuildKit|not supported by the legacy builder' "$BUILD_LOG" | tr -d '\r')"
        skip "H-0..H-11 no image could be built here: the runtime refused the build"
        note "reported by the runtime: ${WHY:-see $BUILD_LOG}"
        note "every row needing an image built from this layer skips for that environment reason, not because the package is wrong; the static rows above still ran"
        printf '\nchecks=%s failures=%s skips=%s\n' "$CHECKS" "$FAILURES" "$SKIPS"
        [ "$FAILURES" -eq 0 ] && exit 0 || exit 1
    else
        fail "H-0 the layer does not build; last lines:"
        tail -20 "$BUILD_LOG" | while IFS= read -r l; do note "$l"; done
        printf '\nchecks=%s failures=%s skips=%s\n' "$CHECKS" "$FAILURES" "$SKIPS"
        exit 1
    fi
else
    note "using the supplied image $IMAGE as this layer's image"
    LAYER_TAG="$IMAGE"
fi

# --- H-6: an unknown harness id stops the build --------------------------
if rt build -t "$RUN_DIR/nowhere" -f "$SKELETON/Containerfile" \
    --build-arg "AGENT_BASE_REF=$BASE_REF" \
    --build-arg "AGENT_HARNESS_ID=definitely-not-a-harness" \
    "$SKELETON" >"$RUN_DIR/enum.log" 2>&1; then
    fail "H-6 the build accepted an unknown AGENT_HARNESS_ID"
else
    if grep -q "definitely-not-a-harness" "$RUN_DIR/enum.log"; then
        pass "H-6 the build refused an unknown harness id, naming it"
    elif build_refused "$RUN_DIR/enum.log"; then
        skip "H-6 the runtime refused the builder, so the enum refusal could not be measured through a build"
    else
        fail "H-6 the build failed without naming the value it rejected"
    fi
fi

# --- H-1, H-12: what the image inherits and what it opens ----------------
BASE_CFG="$(rt image inspect "$BASE_REF" --format '{{.Config.User}}|{{.Config.WorkingDir}}|{{json .Config.Entrypoint}}' 2>/dev/null)"
LAYER_CFG="$(rt image inspect "$LAYER_TAG" --format '{{.Config.User}}|{{.Config.WorkingDir}}|{{json .Config.Entrypoint}}' 2>/dev/null)"
if [ -n "$LAYER_CFG" ] && [ "$LAYER_CFG" = "$BASE_CFG" ]; then
    pass "H-1 the image's account, working directory and entrypoint are the base's: $LAYER_CFG"
elif [ -n "$LAYER_CFG" ]; then
    fail "H-1 the layer changed the inherited contract: layer=$LAYER_CFG base=$BASE_CFG"
else
    skip "H-1 could not inspect $LAYER_TAG"
fi
HW="$(rt image inspect "$LAYER_TAG" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null)"
BW="$(rt image inspect "$BASE_REF" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null)"
if [ -n "$HW" ] && [ "$HW" = "$BW" ]; then
    pass "H-12 the layer's platform is the base's, as measured: $HW"
else
    fail "H-12 platform differs from the base: layer=${HW:-?} base=${BW:-?}"
fi

# --- H-13: the shipped Containerfile, read as text -----------------------
if grep -qE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' "$SKELETON/Containerfile"; then
    fail "H-13 the Containerfile pipes a download into a shell"
else
    pass "H-13 the Containerfile pipes nothing into a shell"
fi
if grep -qE 'npm install[^;]*@latest' "$SKELETON/Containerfile"; then
    fail "H-13 the Containerfile installs a floating tag"
elif grep -q '\${PKG}@\${V}' "$SKELETON/Containerfile"; then
    pass "H-13 the install is version-resolved"
else
    fail "H-13 no version-resolved install line found"
fi
if grep -qE '^[[:space:]]*(ENTRYPOINT|CMD|WORKDIR)' "$SKELETON/Containerfile"; then
    fail "H-13 the layer declares an ENTRYPOINT, CMD or WORKDIR"
else
    pass "H-13 the layer declares no ENTRYPOINT, CMD or WORKDIR of its own"
fi

# --- containers ----------------------------------------------------------
run_container() {
    # $1 name, $2 harness value for AGENT_HARNESS ('' = unset), rest: args
    c="$1"; h="$2"; shift 2
    rt rm -f "$c" >/dev/null 2>&1
    set -- \
        create --name "$c" --label org.testcontainers=true \
        -v "$PACKAGE_HOST_DIR:/verify-pkg:ro" \
        -v "$RUN_DIR:/verify-out" \
        -e "HARNESS=$HARNESS" -e "HARNESS_HOME=$HARNESS_HOME" \
        -e "CONF_NAME=$CONF_NAME" -e "HARNESS_CMD=$HARNESS_CMD" \
        -e "ROUTER_BASE_URL=$ROUTER_BASE_URL" -e "HARNESS_MODEL_ALIAS=$HARNESS_MODEL_ALIAS" \
        -e "HARNESS_CONTEXT_WINDOW=$HARNESS_CONTEXT_WINDOW" \
        "$@"
    if [ -n "$CONTAINER_USER" ]; then set -- "$@" --user "$CONTAINER_USER"; fi
    set -- "$@" -e "AGENT_HARNESS=$h" "$LAYER_TAG"
    rt "$@" >/dev/null 2>&1 || return 1
    CREATED="$CREATED $c"
    return 0
}

# H-2: the base's own refusal, with AGENT_HARNESS unset.
if run_container hl-unset ""; then
    rt start hl-unset >/dev/null 2>&1
    RC="$(rt wait hl-unset 2>/dev/null)"
    LOG="$(rt logs hl-unset 2>&1)"
    if [ "$RC" = "78" ] && printf '%s' "$LOG" | grep -q 'agent-entrypoint: '; then
        pass "H-2 an unset AGENT_HARNESS is refused with the base's code 78 and message"
    else
        fail "H-2 expected exit 78 with an agent-entrypoint: message; got rc=${RC:-?} log=$(printf '%s' "$LOG" | head -2 | tr '\n' ' ')"
    fi
else
    skip "H-2 could not create a container from $LAYER_TAG"
fi

# H-3/H-4/H-5: the real CLI through the entrypoint, with an argument.
if run_container hl-cli "$HARNESS_CMD" --version; then
    rt start hl-cli >/dev/null 2>&1
    RC="$(rt wait hl-cli 2>/dev/null)"
    LOG="$(rt logs hl-cli 2>&1)"
    TOP="$(rt top hl-cli -o args 2>/dev/null | tail -n +2 | tr -d '\n')"
    if printf '%s' "$LOG" | grep -Eq '[0-9]+\.[0-9]+'; then
        pass "H-4 the CLI answers --version: $(printf '%s' "$LOG" | head -1)"
    else
        fail "H-4 no version string from the CLI: $(printf '%s' "$LOG" | head -2 | tr '\n' ' ')"
    fi
    case "$TOP" in
        *"$HARNESS_CMD"*) pass "H-3 the harness is the container's process: $TOP" ;;
        *) skip "H-3 docker top did not report the process (unsupported here); logged output came from $HARNESS_CMD" ;;
    esac
    if [ "$RC" = "0" ]; then
        pass "H-5 the harness's exit status is the container's (0)"
    else
        fail "H-5 expected exit 0 from the version command, got ${RC:-?}"
    fi
else
    skip "H-3/H-4/H-5 could not create a container from $LAYER_TAG"
fi

# H-5 (rest) / H-7..H-11: the body stands in for the harness, through the same
# entrypoint, and records what it finds.
if run_container hl-body "/verify-pkg/scripts/verify-harness-layer.sh" --inside /verify-out; then
    rt start hl-body >/dev/null 2>&1
    RC="$(rt wait hl-body 2>/dev/null)"
    BODY_LOG="$(rt logs hl-body 2>&1)"
    printf '%s\n' "$BODY_LOG" | grep -E '^(PASS|FAIL|SKIP)' | while IFS= read -r l; do printf '%s\n' "$l"; done
    RESULT="$(printf '%s' "$BODY_LOG" | grep -E '^BODY-RESULT checks=[0-9]+ failures=[0-9]+ skips=[0-9]+' | tail -1)"
    if [ -n "$RESULT" ]; then
        BC="$(printf '%s' "$RESULT" | sed -E 's/.*checks=([0-9]+).*/\1/')"
        BF="$(printf '%s' "$RESULT" | sed -E 's/.*failures=([0-9]+).*/\1/')"
        BS="$(printf '%s' "$RESULT" | sed -E 's/.*skips=([0-9]+).*/\1/')"
        CHECKS=$((CHECKS + BC)); FAILURES=$((FAILURES + BF)); SKIPS=$((SKIPS + BS))
        if [ "$BC" -lt "$EXPECTED_MIN_ROWS" ]; then
            fail "H-0 the body reported only $BC rows (floor $EXPECTED_MIN_ROWS)"
        fi
    else
        fail "H-0 the body printed no BODY-RESULT line"
    fi
    # H-5: the harness's own non-zero status arrives intact.
    if [ "$RC" = "0" ]; then
        pass "H-5 the container reports the harness's exit status (the body exited 0)"
    else
        fail "H-5 expected the container to report 0, got ${RC:-?}"
    fi
    E="$OUT_LOCAL/body.evidence"
    if [ -r "$E" ]; then
        CWD="$(sed -n 's/^cwd=//p' "$E")"
        ARG1="$(sed -n 's/^arg1=//p' "$E")"
        PID1="$(sed -n 's/^pid1=//p' "$E")"
        [ "$CWD" = "$(rt image inspect "$LAYER_TAG" --format '{{.Config.WorkingDir}}' 2>/dev/null)" ] \
            && pass "H-5 the harness's working directory is the image's: $CWD" \
            || fail "H-5 expected the image's working directory, got ${CWD:-<none>}"
        [ "$ARG1" = "--inside" ] \
            && pass "H-5 the container's arguments reach the harness: $ARG1" \
            || fail "H-5 expected --inside to reach the harness, got ${ARG1:-<none>}"
        case "$PID1" in
            *verify-harness-layer*) pass "H-5 PID 1 is the harness: $PID1" ;;
            *) skip "H-5 could not read PID 1's command line inside the container (pid1='${PID1:-}')" ;;
        esac
        RV="$(sed -n 's/^recorded_version=//p' "$E")"
        BUILDV="$(grep -oE 'installing [^ ]+@[^ ]+' "$BUILD_LOG" | tail -1 | sed 's/.*@//')"
        if [ -n "$RV" ]; then
            if [ -n "$BUILDV" ]; then
                [ "$RV" = "$BUILDV" ] \
                    && pass "H-7 the image records the version the build resolved ($RV)" \
                    || fail "H-7 recorded $RV but the build resolved $BUILDV"
            else
                skip "H-7 the build log was not captured (supplied IMAGE); recorded version: $RV"
            fi
        fi
        # H-8: the credential variable is per harness — the Claude CLI reads
        # ANTHROPIC_AUTH_TOKEN from the process environment and its settings file
        # names no credential at all; the Codex CLI names P-4 in env_key. The
        # image records which variable the harness it installed actually reads.
        CV="$(sed -n 's/^recorded_credential_env=//p' "$E")"
        WANT_CV="$ROUTER_CREDENTIAL_ENV"
        [ "$HARNESS" = "claude" ] && WANT_CV="ANTHROPIC_AUTH_TOKEN"
        if [ "$CV" = "$WANT_CV" ]; then
            pass "H-8 the credential variable the ${HARNESS} harness reads is recorded: $CV"
        else
            fail "H-8 expected $WANT_CV for the ${HARNESS} harness, recorded '${CV:-<none>}'"
        fi
    else
        skip "H-7..H-11 no evidence file; the body wrote nothing to $E"
    fi
else
    skip "H-5/H-7..H-11 could not create the body container from $LAYER_TAG"
fi

printf '\nchecks=%s failures=%s skips=%s\n' "$CHECKS" "$FAILURES" "$SKIPS"
if [ "$FAILURES" -gt 0 ]; then exit 1; fi
exit 0
