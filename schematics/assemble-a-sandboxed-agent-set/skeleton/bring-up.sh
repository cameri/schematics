#!/usr/bin/env bash
#
# Bring the sandboxed agent set up, in dependency order.
#
# This is the composition's ordering bootstrap: it walks the edges of SCHEMATIC.md
# § Implementation Phases 2–5 as guarded steps, and it REFUSES to take a step
# whose input does not exist yet. It creates nothing that a part owns — no
# service, no image of its own, no configuration — and it never prints or passes
# a secret value: it checks that the store's files are where they should be and
# lets the store's own boot wrapper do the decrypting.
#
# Run it with no arguments to walk every step; re-running is safe (each step
# detects completion and skips). `--dry-run` prints the plan and runs nothing.
#
# Inputs (environment; see SCHEMATIC.md § Parameters for the discovery of each):
#   AGENT_SET_NETWORK        P-1   network every service joins
#   AGENT_TREE_DIR           P-2   host directory bind-mounted as the agent tree
#   AGENT_IDS                P-3   space-separated agent ids
#   AGENT_BASE_REF           P-4   the base image reference
#   AGENT_HOST_IMAGE         P-5   the host image reference
#   HARNESS_IMAGE            P-6   the harness layer image reference
#   HARNESS_ID               P-7   the single CLI the layer installs
#   ROUTER_BASE_URL          P-8   the router endpoint the harness uses
#   ROUTER_CREDENTIAL_ENV    P-9   variable name carrying the router credential
#   ROUTER_ALIAS             P-10  the model alias the harness sends
#   ROUTER_ALIAS_SET         P-11  ids the router serves (space-separated)
#   ROUTER_FAST_ALIAS        P-12  the harness's secondary role (optional)
#   HARNESS_CONTEXT_WINDOW   P-13  tokens, written into the harness config
#   HARNESS_MAX_OUTPUT_TOKENS P-14 tokens, written into the harness config
#   SECRETS_KEY_DIR          P-17  host directory holding the age keys
#   SECRETS_STORE_DIR        P-18  host directory holding each service's store
#   ROUTER_SECRETS_SERVICE   P-19  store service for the router's provider keys
#   AGENT_HOST_SECRETS_SERVICE P-20 store service for the harness's credential
#
# Additional inputs:
#   PARTS_ROOT          directory holding each part's package checkout, laid out
#                       as <PARTS_ROOT>/<part-name>/ (required for the build and
#                       up steps; without it those steps print SKIP and why)
#   COMPOSE_FILES       space-separated compose files in merge order, glue last
#   ROUTER_HEALTH_URL   the router's own health endpoint (default: derived from
#                       ROUTER_BASE_URL by replacing a trailing /v1 with
#                       /health/liveliness)
#   ROUTER_CREDENTIAL   the router credential, only for reading /v1/models. Prefer
#                       a file: ROUTER_CREDENTIAL_FILE. Neither is ever printed.
#   BASE_ACCOUNT_UID    the base image's account uid (part 1's P-4), for the tree
#                       ownership check
#   BASE_ACCOUNT_GID    likewise (P-5)
#   BUILD_BASE=1        build the base image from the base part's Containerfile
#                       when AGENT_BASE_REF is a local tag that does not exist
#   BUILDKIT=1          pass DOCKER_BUILDKIT=1 (the default on a current Engine);
#                       the base build needs it
#
# Exit codes: 0 the set is up (or every step was already satisfied), 1 a step
# refused, 2 the invocation is wrong.

set -uo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

CHECKS=0
REFUSED=0

say()   { printf '%s\n' "$1"; }
step()  { CHECKS=$((CHECKS + 1)); printf '\n== %s\n' "$1"; }
ok()    { printf '   ok       %s\n' "$1"; }
act()   { printf '   do       %s\n' "$1"; }
refuse(){ printf '   REFUSED  %s\n' "$1"; REFUSED=$((REFUSED + 1)); }
unset_(){ printf '   skip     %s\n' "$1"; }

need() {  # need NAME VALUE
    [ -n "${2:-}" ] || { printf 'bring-up: %s is not set\n' "$1" >&2; exit 2; }
}

if [ "$DRY_RUN" = "1" ]; then say "dry run: nothing will be created, built, or started"; fi

# ---------------------------------------------------------------------------
step "1/9 shared network ($AGENT_SET_NETWORK)"
need AGENT_SET_NETWORK "${AGENT_SET_NETWORK:-}"
if [ "$DRY_RUN" = "1" ]; then
    act "docker network create $AGENT_SET_NETWORK (if absent)"
elif docker network inspect "$AGENT_SET_NETWORK" >/dev/null 2>&1; then
    ok "network exists"
else
    act "creating network"
    docker network create "$AGENT_SET_NETWORK" >/dev/null || refuse "could not create the network"
fi

# ---------------------------------------------------------------------------
step "2/9 agent tree ($AGENT_TREE_DIR)"
need AGENT_TREE_DIR "${AGENT_TREE_DIR:-}"
if [ ! -d "$AGENT_TREE_DIR" ]; then
    refuse "$AGENT_TREE_DIR does not exist; create it on the host (a bind mount source must exist)"
elif [ -n "${BASE_ACCOUNT_UID:-}" ] && [ -n "${BASE_ACCOUNT_GID:-}" ]; then
    owner="$(stat -c '%u:%g' "$AGENT_TREE_DIR" 2>/dev/null)"
    [ "$owner" = "$BASE_ACCOUNT_UID:$BASE_ACCOUNT_GID" ] \
        && ok "owned by the base image's account ($owner)" \
        || refuse "owned by $owner, but the base image's account is $BASE_ACCOUNT_UID:$BASE_ACCOUNT_GID — chown it, or rebuild the base with matching ids"
else
    unset_ "BASE_ACCOUNT_UID/BASE_ACCOUNT_GID unset; discover them from the base image and re-run to have the owner checked"
fi

# ---------------------------------------------------------------------------
step "3/9 credential store layout"
need SECRETS_KEY_DIR "${SECRETS_KEY_DIR:-}"
need SECRETS_STORE_DIR "${SECRETS_STORE_DIR:-}"
need ROUTER_SECRETS_SERVICE "${ROUTER_SECRETS_SERVICE:-}"
need AGENT_HOST_SECRETS_SERVICE "${AGENT_HOST_SECRETS_SERVICE:-}"
missing=""
for svc in "$ROUTER_SECRETS_SERVICE" "$AGENT_HOST_SECRETS_SERVICE"; do
    [ -f "$SECRETS_STORE_DIR/$svc/.env.encrypted" ] || missing="$missing $SECRETS_STORE_DIR/$svc/.env.encrypted"
    [ -f "$SECRETS_KEY_DIR/$svc-keys.txt" ] || missing="$missing $SECRETS_KEY_DIR/$svc-keys.txt"
done
if [ -z "$missing" ]; then
    ok "both encrypted stores and both dedicated keys are present"
else
    refuse "missing store material:$missing — the store part's own phases create it; this script only checks it exists"
fi

# ---------------------------------------------------------------------------
if [ -z "${PARTS_ROOT:-}" ]; then
    step "4/9 base image"
    unset_ "PARTS_ROOT is not set, so no part can be built here; consume a published base and set AGENT_BASE_REF to it"
    step "5/9 host image"; unset_ "PARTS_ROOT is not set"
    step "6/9 router readiness"; unset_ "PARTS_ROOT is not set (the router is deployed by its own package)"
    step "7/9 alias check"; unset_ "PARTS_ROOT is not set"
    step "8/9 harness layer"; unset_ "PARTS_ROOT is not set"
    step "9/9 start the set"; unset_ "PARTS_ROOT is not set"
else
    BK=""
    [ "${BUILDKIT:-1}" = "1" ] && BK="DOCKER_BUILDKIT=1"

    step "4/9 base image ($AGENT_BASE_REF)"
    need AGENT_BASE_REF "${AGENT_BASE_REF:-}"
    case "$AGENT_BASE_REF" in
        *"@sha256:"*)
            ok "a published reference: the base is pulled by digest, not built here" ;;
        *)
            if docker image inspect "$AGENT_BASE_REF" >/dev/null 2>&1; then
                ok "present locally"
            elif [ "${BUILD_BASE:-0}" != "1" ]; then
                refuse "the local base $AGENT_BASE_REF is absent and BUILD_BASE is not 1; build it from the base part's phases, or point AGENT_BASE_REF at a published reference"
            else
                CTX="$PARTS_ROOT/build-an-agent-dev-image/skeleton"
                [ -f "$CTX/Containerfile" ] || refuse "no base Containerfile at $CTX (is PARTS_ROOT the directory holding each part's package?)"
                need BASE_DISTRO_DIGEST "${BASE_DISTRO_DIGEST:-}"
                [ "$REFUSED" -eq 0 ] && { act "building the base image (needs BuildKit)"; \
                    [ "$DRY_RUN" = "1" ] || env $BK docker build -f "$CTX/Containerfile" \
                        --build-arg "BASE_DISTRO_DIGEST=$BASE_DISTRO_DIGEST" \
                        -t "$AGENT_BASE_REF" "$CTX" >/dev/null || refuse "the base image build failed"; }
            fi ;;
    esac

    step "5/9 host image ($AGENT_HOST_IMAGE)"
    need AGENT_HOST_IMAGE "${AGENT_HOST_IMAGE:-}"
    if docker image inspect "$AGENT_HOST_IMAGE" >/dev/null 2>&1 && [ "${NO_CACHE:-0}" != "1" ]; then
        ok "present locally"
    else
        CTX="$PARTS_ROOT/run-multiplexed-agent-workspaces/skeleton"
        [ -f "$CTX/Containerfile" ] || refuse "no host Containerfile at $CTX"
        [ "$REFUSED" -eq 0 ] && { act "building the host image FROM $AGENT_BASE_REF"; \
            [ "$DRY_RUN" = "1" ] || env $BK docker build -f "$CTX/Containerfile" \
                --build-arg "AGENT_BASE_REF=$AGENT_BASE_REF" \
                -t "$AGENT_HOST_IMAGE" "$CTX" >/dev/null || refuse "the host image build failed"; }
    fi

    step "6/9 router readiness"
    need ROUTER_BASE_URL "${ROUTER_BASE_URL:-}"
    HEALTH_URL="${ROUTER_HEALTH_URL:-${ROUTER_BASE_URL%/v1}/health/liveliness}"
    if [ "$DRY_RUN" = "1" ]; then
        act "curl -fsS $HEALTH_URL"
    elif curl -fsS -m 5 "$HEALTH_URL" >/dev/null 2>&1; then
        ok "the router answers its health endpoint"
    else
        refuse "the router does not answer $HEALTH_URL; deploy it first (its own package owns that), because the harness build validates the alias against it"
    fi

    step "7/9 alias check ($ROUTER_ALIAS)"
    need ROUTER_ALIAS "${ROUTER_ALIAS:-}"
    CRED=""
    [ -n "${ROUTER_CREDENTIAL_FILE:-}" ] && CRED="$(cat "$ROUTER_CREDENTIAL_FILE")"
    [ -n "$CRED" ] || CRED="${ROUTER_CREDENTIAL:-}"
    if [ -z "$CRED" ]; then
        unset_ "no router credential supplied (ROUTER_CREDENTIAL_FILE or ROUTER_CREDENTIAL); the alias cannot be read back here"
    elif [ "$DRY_RUN" = "1" ]; then
        act "GET ${ROUTER_BASE_URL}/models and require the alias $ROUTER_ALIAS"
    else
        models="$(curl -fsS -m 5 -H "Authorization: Bearer $CRED" "${ROUTER_BASE_URL}/models" 2>/dev/null)"
        case "$models" in
            *"\"$ROUTER_ALIAS\""*) ok "the router serves the alias" ;;
            *) refuse "the router's /models does not list '$ROUTER_ALIAS'; fix the router's alias set before building the layer that names it" ;;
        esac
    fi

    step "8/9 harness layer ($HARNESS_IMAGE)"
    need HARNESS_IMAGE "${HARNESS_IMAGE:-}"
    need HARNESS_ID "${HARNESS_ID:-}"
    if docker image inspect "$HARNESS_IMAGE" >/dev/null 2>&1 && [ "${NO_CACHE:-0}" != "1" ]; then
        ok "present locally"
    elif [ "$REFUSED" -ne 0 ]; then
        unset_ "skipped: an earlier step refused, and this build would validate against a router that is not known good"
    else
        CTX="$PARTS_ROOT/add-an-agent-harness/skeleton"
        [ -f "$CTX/Containerfile" ] || refuse "no layer Containerfile at $CTX"
        [ "$REFUSED" -eq 0 ] && { act "building the harness layer FROM $AGENT_HOST_IMAGE with the alias $ROUTER_ALIAS"; \
            [ "$DRY_RUN" = "1" ] || env $BK docker build -f "$CTX/Containerfile" \
                --build-arg "AGENT_BASE_REF=$AGENT_HOST_IMAGE" \
                --build-arg "AGENT_HARNESS_ID=$HARNESS_ID" \
                --build-arg "ROUTER_BASE_URL=$ROUTER_BASE_URL" \
                --build-arg "ROUTER_CREDENTIAL_ENV=${ROUTER_CREDENTIAL_ENV:-ROUTER_API_KEY}" \
                --build-arg "HARNESS_MODEL_ALIAS=$ROUTER_ALIAS" \
                --build-arg "HARNESS_FAST_ALIAS=${ROUTER_FAST_ALIAS:-$ROUTER_ALIAS}" \
                --build-arg "HARNESS_CONTEXT_WINDOW=${HARNESS_CONTEXT_WINDOW:-200000}" \
                --build-arg "HARNESS_MAX_OUTPUT_TOKENS=${HARNESS_MAX_OUTPUT_TOKENS:-32000}" \
                -t "$HARNESS_IMAGE" "$CTX" >/dev/null || refuse "the harness layer build failed — read its output: an alias that is not in the router's set fails here, which is the edge this step exists for"; }
    fi

    step "9/9 start the set"
    need COMPOSE_FILES "${COMPOSE_FILES:-}"
    need AGENT_HOST_IMAGE "${AGENT_HOST_IMAGE:-}"
    args=""
    for f in $COMPOSE_FILES; do [ -f "$f" ] || refuse "compose file not found: $f"; args="$args -f $f"; done
    [ "$REFUSED" -eq 0 ] && { act "docker compose$args up -d"; \
        [ "$DRY_RUN" = "1" ] || docker compose $args up -d || refuse "compose could not start the set"; }
    [ "$DRY_RUN" = "1" ] || { [ "$REFUSED" -eq 0 ] && ok "the set is up"; }
fi

printf '\n%d step(s), %d refusal(s)\n' "$CHECKS" "$REFUSED"
if [ "$REFUSED" -eq 0 ]; then
    say "Next: run the end-to-end acceptance script (scripts/verify-set.sh) with the same deployment inputs."
    exit 0
fi
say "Refused steps are ordering violations, not transient errors: fix the named input and re-run."
exit 1
