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
#                        builds it (see BASE_IMAGE / BASE_PACKAGE_DIR). When it
#                        IS set, BASE_IMAGE must be set too: the rows that
#                        compare the inherited contract, and the enum probe, need
#                        an image to compare against.
#                        The two modes are NOT equal in coverage. With IMAGE
#                        supplied the script verifies that image and never
#                        builds, so H-16 (the build refuses an unreachable
#                        endpoint) and the build half of H-7 do not run — H-7
#                        skips with that reason. IMAGE is the mode for checking
#                        a published layer; leaving it unset is the mode that
#                        gives the full row set, and the only one that proves
#                        this layer builds. Neither mode proves `sops`: the
#                        binary is proved by the build's own `sops --version`
#                        line in skeleton/Containerfile, which no row reads.
#   BASE_IMAGE           a locally present image to build the layer over and to
#                        compare the inherited contract against. No default: an
#                        agent-host image is the deployment's own, and naming one
#                        here would name the author's. When it is set, the
#                        script also synthesizes a stand-in base from the base
#                        package's own entrypoint (see BASE_PACKAGE_DIR) so the
#                        entrypoint rows are exercised for real. When it is not,
#                        every row that needs a built image skips with that
#                        reason printed.
#   BASE_PACKAGE_DIR     the base schematic's package directory
#                        (default: ../build-an-agent-dev-image). Its
#                        skeleton/entrypoint.sh is what the stand-in base above
#                        is built from.
#   HARNESS              P-1: the CLI to build and check (default: claude)
#   ROUTER_BASE_URL      P-3 (default: http://llm-router:4000) — the router
#                        ROOT. The script derives this arm's endpoint from it
#                        (the root for claude, the root plus /v1 for codex and
#                        for omp, whose OpenAI-compatible client appends
#                        /chat/completions to a base that ends in /v1).
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
# The driver derives one more value for the body: the endpoint this arm's CLI is
# expected to call (the router root for claude, the root plus /v1 for codex and for
# omp), and passes it as CHECK_ENDPOINT, together with the name of the arm's second
# configuration file where it has one (CHECK_MODELS). The body compares the
# configuration's own value against it — a comparison, not a substring search,
# because a doubled /v1 path passes a substring search and fails the request.
#
# Exit status: 0 when every executed check passed; 1 when any failed; 2 on a
# usage or precondition error.
set -u

IMAGE="${IMAGE:-}"
BASE_IMAGE="${BASE_IMAGE:-}"
BASE_PACKAGE_DIR="${BASE_PACKAGE_DIR:-}"
HARNESS="${HARNESS:-claude}"
ROUTER_BASE_URL="${ROUTER_BASE_URL:-http://llm-router:4000}"
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
    if command -v "$CHECK_CMD" >/dev/null 2>&1; then
        bp "H-4 the ${CHECK_CMD} CLI is on PATH for this account"
        V="$("$CHECK_CMD" --version 2>&1)"
        if [ -n "$V" ]; then
            bp "H-4 ${CHECK_CMD} --version answers: ${V}"
            emit cli_version "$V"
        else
            bf "H-4 ${CHECK_CMD} --version produced nothing"
        fi
    else
        bf "H-4 ${CHECK_CMD} is not on PATH for this account"
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
    [ -n "${HARNESS_HOME:-}" ] && CONF="$HARNESS_HOME/$CHECK_CONF"
    if [ -z "$CONF" ] || [ ! -r "$CONF" ]; then
        bf "H-8 no readable configuration at ${CONF:-<unset>}"
    else
        cp "$CONF" "$OUT/config.copy" 2>/dev/null || true
        if [ "$CHECK_HARNESS" = "claude" ]; then
            if command -v python3 >/dev/null 2>&1; then
                if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONF" 2>/dev/null; then
                    bp "H-8 the configuration parses as JSON"
                else
                    bf "H-8 the configuration does not parse as JSON"
                fi
            else
                bs "H-8 JSON parse check skipped: no python3 in the image"
            fi
            URL="$(sed -n 's/.*"ANTHROPIC_BASE_URL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF" | head -1)"
            MODEL="$(sed -n 's/.*"ANTHROPIC_MODEL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF" | head -1)"
            emit config_url "$URL"
            emit config_model "$MODEL"
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
        elif [ "$CHECK_HARNESS" = "omp" ]; then
            # omp: two YAML files. The settings file carries the roles, the model
            # catalogue carries the provider and the per-model metadata.
            MODELS="${HARNESS_HOME:-}/$CHECK_MODELS"
            if [ ! -r "$MODELS" ]; then
                bf "H-8 no readable model catalogue at ${MODELS:-<unset>}"
            else
                cp "$MODELS" "$OUT/models.copy" 2>/dev/null || true
                if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
                    if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1])); yaml.safe_load(open(sys.argv[2]))' "$CONF" "$MODELS" 2>/dev/null; then
                        bp "H-8 both configuration files parse as YAML"
                    else
                        bf "H-8 the configuration does not parse as YAML"
                    fi
                else
                    bs "H-8 YAML parse check skipped: no python3 with the yaml module in the image"
                fi
                # The roles name the provider this layer writes, and the alias.
                ROLE_DEFAULT="$(sed -n 's/^[[:space:]]*default:[[:space:]]*"\{0,1\}router\/\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$CONF" | head -1)"
                ROLE_SMOL="$(sed -n 's/^[[:space:]]*smol:[[:space:]]*"\{0,1\}router\/\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$CONF" | head -1)"
                URL="$(sed -n 's/^[[:space:]]*baseUrl:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$MODELS" | head -1)"
                MODEL="$ROLE_DEFAULT"
                ENVKEY="$(sed -n 's/^[[:space:]]*apiKey:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$MODELS" | head -1)"
                emit config_url "$URL"
                emit config_model "$MODEL"
                emit config_env_key "$ENVKEY"
                if [ "$ROLE_SMOL" = "$HARNESS_FAST_ALIAS" ]; then
                    bp "H-8 the fast role names the second alias: $ROLE_SMOL"
                else
                    bf "H-8 the fast role names '${ROLE_SMOL:-<none>}' but P-6 is $HARNESS_FAST_ALIAS"
                fi
                # H-11: the metadata the router does not report, in the only place
                # this CLI accepts it — the model entry. The primary alias carries
                # the numbers, and the fast alias carries none: P-7/P-8 describe
                # the model P-5 resolves to, and a copy of them here would be a
                # declaration about a different model.
                PRIMARY="$(sed -n "/^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"\{0,1\}${HARNESS_MODEL_ALIAS}\"\{0,1\}[[:space:]]*\$/,/^[[:space:]]*-[[:space:]]*id:/p" "$MODELS")"
                FAST="$(sed -n "/^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"\{0,1\}${HARNESS_FAST_ALIAS}\"\{0,1\}[[:space:]]*\$/,/^[[:space:]]*-[[:space:]]*id:/p" "$MODELS")"
                if printf '%s' "$PRIMARY" | grep -qE "^[[:space:]]*contextWindow:[[:space:]]*${HARNESS_CONTEXT_WINDOW}[[:space:]]*$"; then
                    bp "H-11 the primary alias's model entry declares P-7: $HARNESS_CONTEXT_WINDOW"
                else
                    bf "H-11 the primary alias's model entry does not declare P-7 ($HARNESS_CONTEXT_WINDOW)"
                fi
                if [ -n "${HARNESS_MAX_OUTPUT_TOKENS:-}" ] && printf '%s' "$PRIMARY" | grep -qE "^[[:space:]]*maxTokens:[[:space:]]*${HARNESS_MAX_OUTPUT_TOKENS}[[:space:]]*$"; then
                    bp "H-11 the primary alias's model entry declares P-8: $HARNESS_MAX_OUTPUT_TOKENS"
                else
                    bf "H-11 the primary alias's model entry does not declare P-8 (${HARNESS_MAX_OUTPUT_TOKENS:-<unset>})"
                fi
                if printf '%s' "$FAST" | grep -qE '^[[:space:]]*(contextWindow|maxTokens):'; then
                    bf "H-11 the fast alias's model entry carries token metadata the layer was not given"
                else
                    bp "H-11 the fast alias's model entry declares no token metadata, as the module states"
                fi
                if [ "$(grep -c '^[[:space:]]*baseUrl:' "$MODELS")" -eq 1 ]; then
                    bp "H-9 exactly one provider endpoint exists"
                else
                    bf "H-9 the catalogue declares $(grep -c '^[[:space:]]*baseUrl:' "$MODELS") provider endpoints"
                fi
                # H-9, settings side: a fallback chain is a second provider.
                if grep -qE '^[[:space:]]*fallbackChains:' "$CONF"; then
                    bf "H-9 the settings file declares a fallback chain, which R-7 forbids"
                else
                    bp "H-9 the settings file declares no fallback chain"
                fi
            fi
            if grep -q '@[A-Z_]*@' "$CONF" || grep -q '@[A-Z_]*@' "$MODELS"; then
                bf "H-8 a configuration file still carries an unsubstituted parameter"
            else
                bp "H-8 no unsubstituted parameter remains in either file"
            fi
            # The CLI's own reading of the settings file this layer wrote: this row
            # is the harness resolving the roles, not the script parsing them. The
            # value it prints is what the row reports, so a deployment that selects
            # a named profile — which moves the root the CLI reads — fails here with
            # the roles it actually resolved.
            ROLES="$("$CHECK_CMD" config get modelRoles 2>/dev/null)"
            if [ -z "$ROLES" ]; then
                bs "H-8 the CLI's own config read produced nothing (${CHECK_CMD} config get modelRoles)"
            elif printf '%s' "$ROLES" | grep -q "\"default\":\"router/${HARNESS_MODEL_ALIAS}\"" \
              && printf '%s' "$ROLES" | grep -q "\"smol\":\"router/${HARNESS_FAST_ALIAS}\""; then
                bp "H-8 the CLI itself resolves both roles from the file this layer wrote: $ROLES"
            else
                bf "H-8 the CLI resolves '${ROLES}' while the layer wrote router/${HARNESS_MODEL_ALIAS} and router/${HARNESS_FAST_ALIAS}"
            fi
        elif [ "$CHECK_HARNESS" = "codex" ]; then
            # Codex CLI: TOML, one provider block, a top-level window key.
            if grep -q '^model_context_window' "$CONF"; then
                bp "H-11 the context window is a top-level key"
            else
                bf "H-11 model_context_window is not a top-level key"
            fi
            URL="$(sed -n 's/^base_url[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$CONF" | head -1)"
            MODEL="$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$CONF" | head -1)"
            ENVKEY="$(sed -n 's/^env_key[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$CONF" | head -1)"
            emit config_url "$URL"
            emit config_model "$MODEL"
            emit config_env_key "$ENVKEY"
            if [ "$(grep -c '^\[' "$CONF")" -eq 1 ]; then
                bp "H-9 exactly one provider block exists"
            else
                bf "H-9 the configuration declares $(grep -c '^\[' "$CONF") provider blocks"
            fi
        fi
        # H-8: the values the file carries, compared — the per-arm endpoint, the
        # primary alias, and (for the arm whose configuration names one) the
        # credential variable against the name the image recorded.
        if [ -n "${CHECK_ENDPOINT:-}" ]; then
            if [ "$URL" = "$CHECK_ENDPOINT" ]; then
                bp "H-8 the configuration's endpoint is the derived one for this arm: $URL"
            else
                bf "H-8 the configuration's endpoint is '${URL:-<none>}' but this arm's endpoint is $CHECK_ENDPOINT"
            fi
        else
            bs "H-8 endpoint comparison skipped: the driver supplied no CHECK_ENDPOINT"
        fi
        if [ "$MODEL" = "$HARNESS_MODEL_ALIAS" ]; then
            bp "H-8 the configuration's model is the primary alias: $MODEL"
        else
            bf "H-8 the configuration's model is '${MODEL:-<none>}' but P-5 is $HARNESS_MODEL_ALIAS"
        fi
        REC_ENDPOINT="$(cat "$REC/endpoint" 2>/dev/null)"
        if [ -z "$REC_ENDPOINT" ]; then
            bs "H-7 no endpoint record in the image at $REC/endpoint"
        elif [ -z "${CHECK_ENDPOINT:-}" ]; then
            bs "H-7 endpoint record is '$REC_ENDPOINT' but the driver supplied no CHECK_ENDPOINT to compare it with"
        elif [ "$REC_ENDPOINT" = "$CHECK_ENDPOINT" ]; then
            bp "H-7 the image records the endpoint it wired: $REC_ENDPOINT"
        else
            bf "H-7 the image records endpoint '$REC_ENDPOINT', this arm's is '$CHECK_ENDPOINT'"
        fi
        if [ "$CHECK_HARNESS" != "claude" ]; then
            REC_CRED="$(cat "$REC/credential-env" 2>/dev/null)"
            if [ -n "$ENVKEY" ] && [ "$ENVKEY" = "$REC_CRED" ]; then
                bp "H-8 the provider block's env_key is the variable the image recorded: $ENVKEY"
            else
                bf "H-8 the provider block's env_key is '${ENVKEY:-<absent>}' but the image recorded '${REC_CRED:-<none>}'"
            fi
        fi

        # H-15: no listener. The row the spec claimed and no half of the script
        # measured. State 0A is LISTEN in /proc/net/tcp.
        if command -v awk >/dev/null 2>&1; then
            LISTENERS="$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk 'NR>1 && $4=="0A" {n++} END {print n+0}')"
            if [ "${LISTENERS:-0}" -eq 0 ]; then
                bp "H-15 the process holds no listening socket (/proc/net/tcp, /proc/net/tcp6)"
            else
                bf "H-15 ${LISTENERS} listening socket(s) are open inside the container"
            fi
        else
            bs "H-15 listener check skipped: no awk in the image"
        fi

        # H-9: only the router's endpoint, and no credential value. The arms that
        # read two files are checked in both: the endpoint and the credential's
        # name live in the arm's own file, and a rule that only reads the settings
        # file would pass an arm whose catalogue named another provider.
        for f in "$CONF" ${MODELS:-}; do
            OTHER="$(grep -oE 'https?://[^"]+' "$f" | grep -vxF "${CHECK_ENDPOINT:-$ROUTER_BASE_URL}" || true)"
            if [ -z "$OTHER" ]; then
                bp "H-9 no endpoint other than the router's appears in $(basename "$f")"
            else
                bf "H-9 $(basename "$f") names another endpoint: $OTHER"
            fi
            # H-10: a credential field names a variable; a credential *value*
            # may not appear in a file (R-8). The rule is shape, not spelling: a
            # legal variable name is [A-Za-z_][A-Za-z0-9_]*, which is what keeps
            # a camel-cased or digit-bearing name quiet — omp's own field is
            # `apiKey`, and P-4 is free-form, so `RouterApiKey` and `ROUTER_CRED_2`
            # are valid input a build must accept — while `sk-…`, `Bearer …`, and
            # any value carrying a character a variable name cannot (`topsecret!`,
            # `a/b`) are not. A literal that is itself identifier-shaped passes
            # here and is caught by H-8, which compares the field against the
            # variable the image records; this row cannot make that comparison,
            # because it must also hold for the arm whose settings file names no
            # credential at all. An empty value is not a value and is left to H-8.
            NAMED="$(grep -oE '(api[_-]?[Kk]ey|env_key)"?[[:space:]]*[:=][[:space:]]*"[^"]*"' "$f" \
                     | sed -n 's/.*"\([^"]*\)"$/\1/p' \
                     | grep -vE '^([A-Za-z_][A-Za-z0-9_]*)?$' || true)"
            if [ -n "$NAMED" ]; then
                bf "H-10 $(basename "$f") names a value where a credential variable belongs: $NAMED"
            elif grep -qE '(sk-[A-Za-z0-9]|Bearer [A-Za-z0-9])' "$f"; then
                bf "H-10 $(basename "$f") carries a credential-shaped value"
            else
                bp "H-10 $(basename "$f") carries the credential's name, not a value"
            fi
        done
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
[ -n "$IMAGE" ] && [ -z "$BASE_IMAGE" ] && usage_error "BASE_IMAGE is required when IMAGE is supplied: the inherited-contract rows and the enum probe compare against the base image, and H-6 builds over it"
CHECK_CONF="settings.json"
[ "$HARNESS" = "claude" ] || CHECK_CONF="config.toml"
[ "$HARNESS" = "omp" ] && CHECK_CONF="config.yml"
# The omp arm's second file: the roles live in the settings file and the provider
# and its model metadata live in the catalogue. The other arms read one file.
CHECK_MODELS=""
[ "$HARNESS" = "omp" ] && CHECK_MODELS="models.yml"
CHECK_CMD="$HARNESS"
: "${RUN_HOST_DIR:=$PACKAGE_HOST_DIR/.verify-run}"
: "${RUN_LOCAL_DIR:=$RUN_HOST_DIR}"
RUN_DIR="$RUN_LOCAL_DIR"      # where this script reads and writes
RUN_HOST="$RUN_HOST_DIR"      # what containers bind: the runtime resolves this
OUT_HOST="$RUN_HOST/out"
OUT_LOCAL="$RUN_DIR/out"
# The account the base image runs as. Read from the image rather than assumed:
# a layer must return to whatever account the base declares, and this script
# builds over more than one.
BASE_USER="$(rt image inspect "$BASE_IMAGE" --format '{{.Config.User}}' 2>/dev/null)"
: "${BASE_USER:=root}"
[ -n "$CONTAINER_USER" ] || CONTAINER_USER="$BASE_USER"
: "${HARNESS_HOME:=/home/$CONTAINER_USER/.$HARNESS}"
rm -rf "$OUT_LOCAL" 2>/dev/null || true
mkdir -p "$OUT_LOCAL" || usage_error "cannot create $OUT_LOCAL"
[ "$OUT_LOCAL" = "$OUT_HOST" ] || mkdir -p "$OUT_HOST" 2>/dev/null || true

CREATED=""
cleanup() {
    for c in $CREATED; do rt rm -f "$c" >/dev/null 2>&1; done
    if [ "$KEEP" != "1" ]; then
        rt image rm -f "${LAYER_TAG:-}" >/dev/null 2>&1 || true
        rt image rm -f "${BASE_STANDIN:-}" >/dev/null 2>&1 || true
    fi
}
LAYER_TAG=""
BASE_STANDIN=""
trap cleanup EXIT INT TERM

# Truncated, not appended: a log left by an earlier run (another arm, another
# base) otherwise answers H-7's comparison with the wrong build's version.
BUILD_LOG="$RUN_DIR/build.log"
STANDIN_LOG="$RUN_DIR/standin.log"
: > "$BUILD_LOG"
: > "$STANDIN_LOG"
BASE_STANDIN="harness-layer-verify-base:$$"
STANDIN_OK=0
LAYER_TAG="harness-layer-verify:$$"

# The endpoint this arm's CLI must be wired to: the layer's own rule, restated
# here so the body can compare against it instead of trusting a substring.
CHECK_ENDPOINT="${ROUTER_BASE_URL%/}"
case "$CHECK_ENDPOINT" in
    */v1) CHECK_ENDPOINT="${CHECK_ENDPOINT%/v1}" ;;
esac
case "$HARNESS" in
    codex|omp) CHECK_ENDPOINT="$CHECK_ENDPOINT/v1" ;;
esac
export CHECK_ENDPOINT

printf 'verify-harness-layer: harness=%s base=%s\n' "$HARNESS" "$BASE_IMAGE"
printf 'verify-harness-layer: endpoint for the %s arm: %s\n' "$HARNESS" "$CHECK_ENDPOINT"

# --- H-13: the shipped Containerfile, read as text. These rows need no image,
# --- so they run first and always, including on a host with no usable builder.
static_rows() {
    if grep -qE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' "$SKELETON/Containerfile"; then
        fail "H-13 the Containerfile pipes a download into a shell"
    else
        pass "H-13 the Containerfile pipes nothing into a shell"
    fi
    if grep -qE 'npm install[^;]*@latest' "$SKELETON/Containerfile"; then
        fail "H-13 the Containerfile installs a floating tag"
    elif grep -q '\${PKG}@\${V}' "$SKELETON/Containerfile" || grep -q 'releases/download/\${V}' "$SKELETON/Containerfile"; then
        pass "H-13 the install is version-resolved"
    else
        fail "H-13 no version-resolved install line found"
    fi
    # A release arm must verify what it downloaded. The row reads the file, so it
    # holds for any arm that installs from a release host rather than only for the
    # one that exists today.
    if grep -q 'releases/download/\${V}' "$SKELETON/Containerfile" && ! grep -q 'SHA256SUMS' "$SKELETON/Containerfile"; then
        fail "H-13 a release arm installs an artifact without its release's checksum"
    else
        pass "H-13 a release arm compares the artifact against the release's checksum"
    fi
    if grep -qE '^[[:space:]]*(ENTRYPOINT|CMD|WORKDIR)' "$SKELETON/Containerfile"; then
        fail "H-13 the layer declares an ENTRYPOINT, CMD or WORKDIR"
    else
        pass "H-13 the layer declares no ENTRYPOINT, CMD or WORKDIR of its own"
    fi
    if grep -qE 'supervisord|s6-svscan|runsvdir|nginx|httpd|[[:space:]]listen[[:space:]]' "$SKELETON/Containerfile"; then
        fail "H-12 the Containerfile starts a service or a listener"
    else
        pass "H-12 the Containerfile starts no service and opens no listener"
    fi
}
static_rows

# --- a base to build over ------------------------------------------------
BASE_PRESENT="not set"
if [ -z "$BASE_IMAGE" ]; then
    note "BASE_IMAGE is unset: there is no image to build this layer over"
elif rt image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    note "using the local image $BASE_IMAGE as the base"
    BASE_PRESENT="present"
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
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
USER $CONTAINER_USER
EOF
        cp "$BASE_PACKAGE_DIR/skeleton/entrypoint.sh" "$RUN_DIR/entrypoint.sh"
        if build -q -t "$BASE_STANDIN" -f "$RUN_DIR/Containerfile.base" "$RUN_DIR" >"$STANDIN_LOG" 2>&1; then
            BASE_REF="$BASE_STANDIN"
            STANDIN_OK=1
            note "synthesized a stand-in base from $BASE_PACKAGE_DIR/skeleton/entrypoint.sh (account $CONTAINER_USER)"
        elif build_refused "$STANDIN_LOG"; then
            note "the runtime refused the builder, so no stand-in base could be built"
        else
            note "the stand-in base did not build; its own last line:"
            note "  $(grep -vE '^(Step |---> |Removing |DEPRECATED|BuildKit| *$)' "$STANDIN_LOG" 2>/dev/null | tail -1)"
        fi
    fi
else
    BASE_PRESENT="absent locally"
    note "no local image $BASE_IMAGE"
fi

if [ -z "$IMAGE" ]; then
    if [ "$STANDIN_OK" != "1" ]; then
        # Three states reach here and the line must name the one that holds:
        # BASE_IMAGE unset or absent locally (no base at all), BASE_IMAGE present
        # but the base package's entrypoint not available (no stand-in to make),
        # and a stand-in that failed or whose builder was refused. The notes
        # printed above already say which stand-in outcome happened and where the
        # entrypoint would have come from, so this line reuses their terms and
        # the two agree. The run skips rather than building over the raw base
        # because the boot-path rows need the base's own entrypoint: over a base
        # without it they would fail about a missing prerequisite — the
        # environment — instead of the property under test.
        if [ "$BASE_PRESENT" = "present" ]; then
            skip "H-0..H-12 no image could be built here: $BASE_IMAGE is present locally, but no stand-in base could be synthesized${BASE_PACKAGE_DIR:+ from $BASE_PACKAGE_DIR/skeleton/entrypoint.sh}, and the rows that need the base's own entrypoint cannot run over the raw base"
        else
            skip "H-0..H-12 no image could be built here: BASE_IMAGE is ${BASE_PRESENT:-not inspected} (${BASE_IMAGE:-unset}) and no stand-in base could be synthesized, so there is no base to build this layer over"
        fi
        note "what happened: BASE_IMAGE was ${BASE_PRESENT:-not inspected}; the stand-in base is built from ${BASE_PACKAGE_DIR:-<unset BASE_PACKAGE_DIR>}/skeleton/entrypoint.sh, and when a stand-in build ran, its own last line is printed above"
        note "supply a locally present BASE_IMAGE, a builder that can run, and the base package; the static rows above ran regardless"
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
        skip "H-0..H-12 no image could be built here: the runtime refused the build"
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
if [ -z "${BASE_REF:-}" ]; then
    skip "H-6 no base reference resolved here (\$BASE_IMAGE ${BASE_PRESENT:-unset}), so the enum refusal cannot be measured through a build"
elif build -t "harness-layer-verify-enum:$$" -f "$SKELETON/Containerfile" \
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

# --- H-16: the opt-in endpoint check refuses an unreachable router --------
if [ -z "${BASE_REF:-}" ]; then
    skip "H-16 no base reference resolved here, so the endpoint check cannot be measured through a build"
elif build -t "harness-layer-verify-endpoint:$$" -f "$SKELETON/Containerfile" \
    --build-arg "AGENT_BASE_REF=$BASE_REF" \
    --build-arg "AGENT_HARNESS_ID=$HARNESS" \
    --build-arg "ROUTER_BASE_URL=http://127.0.0.1:1" \
    --build-arg "HARNESS_VERIFY_ENDPOINT=1" \
    --build-arg "HARNESS_MODEL_ALIAS=$HARNESS_MODEL_ALIAS" \
    --build-arg "HARNESS_FAST_ALIAS=$HARNESS_FAST_ALIAS" \
    --build-arg "HARNESS_CONTEXT_WINDOW=$HARNESS_CONTEXT_WINDOW" \
    --build-arg "HARNESS_MAX_OUTPUT_TOKENS=$HARNESS_MAX_OUTPUT_TOKENS" \
    "$SKELETON" >"$RUN_DIR/endpoint.log" 2>&1; then
    fail "H-16 the build succeeded with HARNESS_VERIFY_ENDPOINT=1 pointing at an endpoint that answers nothing"
else
    # Both halves: our own line, and the guard's exit code. The phrase alone is
    # also in the echoed RUN command, so a build that failed for another reason
    # would otherwise satisfy this row.
    if grep -q "not reachable from the build" "$RUN_DIR/endpoint.log" && grep -q "non-zero code: 78" "$RUN_DIR/endpoint.log"; then
        pass "H-16 a build whose endpoint check cannot reach the router fails with the guard's code 78, and its own line names the endpoint: $(grep 'not reachable from the build' "$RUN_DIR/endpoint.log" | tail -1 | cut -c1-140)"
    elif build_refused "$RUN_DIR/endpoint.log"; then
        skip "H-16 the runtime refused the builder, so the endpoint check could not be measured through a build"
    else
        fail "H-16 the build failed without naming the endpoint check: $(tail -1 "$RUN_DIR/endpoint.log" | cut -c1-120)"
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

# --- H-14: the one variable the inherited entrypoint reads, and the config root
ENVJSON="$(rt image inspect "$LAYER_TAG" --format '{{json .Config.Env}}' 2>/dev/null)"
if [ -z "$ENVJSON" ]; then
    skip "H-14 could not read $LAYER_TAG's Config.Env"
else
    if printf '%s' "$ENVJSON" | grep -q "\"AGENT_HARNESS=$HARNESS\""; then
        pass "H-14 the image's Config.Env sets AGENT_HARNESS=$HARNESS, which is what the inherited entrypoint execs"
    else
        fail "H-14 the image's Config.Env does not set AGENT_HARNESS to $HARNESS: $ENVJSON"
    fi
    ROOTVAR="CLAUDE_CONFIG_DIR"
    [ "$HARNESS" = "codex" ] && ROOTVAR="CODEX_HOME"
    [ "$HARNESS" = "omp" ] && ROOTVAR="PI_CODING_AGENT_DIR"
    if printf '%s' "$ENVJSON" | grep -q "\"$ROOTVAR=$HARNESS_HOME\""; then
        pass "H-14 the image's $ROOTVAR is P-9: $HARNESS_HOME"
    else
        fail "H-14 the image's $ROOTVAR is not P-9 ($HARNESS_HOME): $ENVJSON"
    fi
fi

# --- containers ----------------------------------------------------------
run_container() {
    # $1 name, $2 harness value for AGENT_HARNESS ('' = unset), rest: the
    # container's command, passed to the harness by the inherited entrypoint.
    c="$1"; h="$2"; shift 2
    rt rm -f "$c" >/dev/null 2>&1
    set -- create --name "$c" --label org.testcontainers=true \
        --user "$CONTAINER_USER" \
        -v "$PACKAGE_HOST_DIR:/verify-pkg:ro" \
        -v "$RUN_HOST/out:/verify-out" \
        -e "CHECK_HARNESS=$HARNESS" -e "HARNESS_HOME=$HARNESS_HOME" \
        -e "CHECK_CONF=$CHECK_CONF" -e "CHECK_MODELS=$CHECK_MODELS" -e "CHECK_CMD=$CHECK_CMD" \
        -e "ROUTER_BASE_URL=$ROUTER_BASE_URL" -e "HARNESS_MODEL_ALIAS=$HARNESS_MODEL_ALIAS" \
        -e "HARNESS_CONTEXT_WINDOW=$HARNESS_CONTEXT_WINDOW" \
        -e "HARNESS_FAST_ALIAS=$HARNESS_FAST_ALIAS" \
        -e "HARNESS_MAX_OUTPUT_TOKENS=$HARNESS_MAX_OUTPUT_TOKENS" \
        -e "AGENT_HARNESS=$h" \
        -e "CHECK_ENDPOINT=${CHECK_ENDPOINT:-}" \
        -e "BODY_EXIT=${RUN_BODY_EXIT:-}" \
        "$LAYER_TAG" "$@"
    if ! rt "$@" >"$RUN_DIR/create-$c.log" 2>&1; then
        note "docker create for $c failed: $(tail -1 "$RUN_DIR/create-$c.log")"
        return 1
    fi
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
if run_container hl-cli "$CHECK_CMD" --version; then
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
        *"$CHECK_CMD"*) pass "H-3 the harness is the container's process: $TOP" ;;
        *) skip "H-3 docker top did not report the process (unsupported here); logged output came from $CHECK_CMD" ;;
    esac
    if [ "$RC" = "0" ]; then
        pass "H-5 the harness's exit status is the container's (0)"
    else
        fail "H-5 expected exit 0 from the version command, got ${RC:-?}"
    fi
    # H-15: what the container publishes. R-10's other half, read from the
    # container rather than from the Containerfile as text.
    PB="$(rt inspect hl-cli --format '{{json .HostConfig.PortBindings}}' 2>/dev/null)"
    NP="$(rt inspect hl-cli --format '{{json .NetworkSettings.Ports}}' 2>/dev/null)"
    case "$PB$NP" in
        "" ) skip "H-15 could not inspect hl-cli's port bindings" ;;
        *[0-9]* ) fail "H-15 the container publishes a port: bindings=$PB ports=$NP" ;;
        *) pass "H-15 the container publishes no port (bindings=$PB ports=$NP)" ;;
    esac
else
    skip "H-3/H-4/H-5 could not create a container from $LAYER_TAG"
fi

# H-5 (rest) / H-7..H-11: the body stands in for the harness, through the same
# entrypoint, and records what it finds.
RUN_BODY_EXIT=7
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
    # H-5: the harness's own non-zero status arrives intact — measured, by
    # asking the body for a specific status instead of asserting 0.
    if [ "$RC" = "$RUN_BODY_EXIT" ]; then
        pass "H-5 the container reports the harness's own exit status: the body exited ${RUN_BODY_EXIT}, the container reports ${RC}"
    else
        fail "H-5 the body was asked to exit ${RUN_BODY_EXIT}; the container reported ${RC:-?}"
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
        BUILDV="$(grep -E '^add-an-agent-harness: installing .*@v?[0-9]' "$BUILD_LOG" | tail -1 | sed 's/.*@//;s/ as.*//')"
        if [ -n "$RV" ]; then
            if [ -n "$BUILDV" ]; then
                [ "$RV" = "$BUILDV" ] \
                    && pass "H-7 the image records the version the build resolved ($RV)" \
                    || fail "H-7 recorded $RV but the build resolved $BUILDV"
            else
                skip "H-7 the build log was not captured (supplied IMAGE); recorded version: $RV"
            fi
        fi
        # A base image that already carries this CLI on PATH shadows the one the
        # layer installed, which is worth saying out loud rather than failing:
        # the record is the layer's install, the answer below may be another's.
        CLI_V="$(sed -n 's/^cli_version=//p' "$E" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [ -n "$CLI_V" ] && [ -n "$RV" ] && [ "$CLI_V" != "$RV" ]; then
            note "the CLI on PATH reports '$CLI_V' while the layer installed $RV: the base image already carried a copy"
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
