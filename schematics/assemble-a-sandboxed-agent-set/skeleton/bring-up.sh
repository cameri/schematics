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
#   ROUTER_BASE_URL          P-8   the router ROOT the harness uses (no /v1: the
#                                  layer derives each arm's protocol path from it)
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
#                       as <PARTS_ROOT>/<part-name>/ (needed by the three build
#                       steps; without it those steps skip, and the check and
#                       start steps still run)
#   COMPOSE_FILES       space-separated compose files in merge order, glue last
#   ROUTER_HEALTH_URL   the router's own health endpoint (default: P-8 with
#                       /health/liveliness appended)
#   ROUTER_CREDENTIAL   the router credential, only for reading /v1/models. Prefer
#                       a file: ROUTER_CREDENTIAL_FILE. Neither is ever printed.
#   HARNESS_HOME        the harness's configuration root inside the image, passed
#                       to the layer build when set (the layer has the same
#                       default: the base account's home plus the CLI's name)
#   HARNESS_VERIFY_ENDPOINT=1  have the layer build check that P-8 answers, and
#                       fail the build when nothing does (the layer's P-11)
#   BASE_ACCOUNT_UID    the base image's account uid (part 1's P-4), for the tree
#                       ownership check
#   BASE_ACCOUNT_GID    likewise (P-5)
#   BUILD_BASE=1        build the base image from the base part's Containerfile
#                       when AGENT_BASE_REF is a local tag that does not exist
#   BUILDKIT=1          pass DOCKER_BUILDKIT=1 (the default on a current Engine);
#                       the base build needs it
#
# Exit codes: 0 the set is up (or every step was already satisfied), 1 a step
# refused, 2 the invocation is wrong, 3 the run completed without starting the
# set (no COMPOSE_FILES, so no step that starts anything ran).

set -uo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

CHECKS=0
REFUSED=0
STARTED=0

say()   { printf '%s\n' "$1"; }
step()  { CHECKS=$((CHECKS + 1)); printf '\n== %s\n' "$1"; }
ok()    { printf '   ok       %s\n' "$1"; }
act()   { printf '   do       %s\n' "$1"; }
refuse(){ printf '   REFUSED  %s\n' "$1"; REFUSED=$((REFUSED + 1)); }
unset_(){ printf '   skip     %s\n' "$1"; }

need() {  # need NAME VALUE
    [ -n "${2:-}" ] || { printf 'bring-up: %s is not set\n' "$1" >&2; exit 2; }
}

# A step's label names the input it works on, and a label is printed BEFORE the
# step validates that input — so every expansion in a label uses the empty-default
# form. `${VAR}` there aborts the whole script with "unbound variable" under
# `set -u`, which is neither the exit 2 the header promises nor a step refusing.
if [ "$DRY_RUN" = "1" ]; then say "dry run: nothing will be created, built, or started"; fi

# ---------------------------------------------------------------------------
step "1/9 shared network (${AGENT_SET_NETWORK:-not set})"
need AGENT_SET_NETWORK "${AGENT_SET_NETWORK:-}"
if [ "$DRY_RUN" = "1" ]; then
    act "docker network create $AGENT_SET_NETWORK (if absent)"
elif docker network inspect "$AGENT_SET_NETWORK" >/dev/null 2>&1; then
    ok "network exists"
else
    act "creating network"
    # The daemon's own answer goes into the refusal: on a host whose daemon is
    # behind an authorization plugin, "could not create the network" is the
    # policy's refusal and the reason is the only thing that distinguishes it
    # from a name collision or a driver error.
    net_out="$(docker network create "$AGENT_SET_NETWORK" 2>&1)" \
        || refuse "could not create the network: $(printf '%s' "$net_out" | tail -1 | cut -c1-110)"
fi

# ---------------------------------------------------------------------------
step "2/9 agent tree (${AGENT_TREE_DIR:-not set})"
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
# ---------------------------------------------------------------------------
# The three build steps need a part to build FROM. Without PARTS_ROOT they skip —
# and only they skip: the router checks and the start step have their own inputs
# and still run, so a run without PARTS_ROOT is no longer a run in which every
# step printed SKIP and nothing happened.
BK=""
[ "${BUILDKIT:-1}" = "1" ] && BK="DOCKER_BUILDKIT=1"

step "4/9 base image (${AGENT_BASE_REF:-not set})"
if [ -z "${PARTS_ROOT:-}" ]; then
    unset_ "PARTS_ROOT is not set, so the base cannot be built here; consume a published base and set AGENT_BASE_REF to it"
else
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
fi

step "5/9 host image (${AGENT_HOST_IMAGE:-not set})"
if [ -z "${PARTS_ROOT:-}" ]; then
    unset_ "PARTS_ROOT is not set, so the host image cannot be built here; point AGENT_HOST_IMAGE at a published reference"
else
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
fi

step "6/9 router readiness"
need ROUTER_BASE_URL "${ROUTER_BASE_URL:-}"
ROUTER_ROOT="${ROUTER_BASE_URL%/}"
HEALTH_URL="${ROUTER_HEALTH_URL:-$ROUTER_ROOT/health/liveliness}"
if [ "$DRY_RUN" = "1" ]; then
    act "curl -fsS $HEALTH_URL"
elif curl -fsS -m 5 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "the router answers its health endpoint"
else
    refuse "the router does not answer $HEALTH_URL; deploy it first (its own package owns that)"
fi

step "7/9 alias check (${ROUTER_ALIAS:-not set})"
need ROUTER_ALIAS "${ROUTER_ALIAS:-}"
need ROUTER_ALIAS_SET "${ROUTER_ALIAS_SET:-}"
CRED=""
[ -n "${ROUTER_CREDENTIAL_FILE:-}" ] && CRED="$(cat "$ROUTER_CREDENTIAL_FILE")"
[ -n "$CRED" ] || CRED="${ROUTER_CREDENTIAL:-}"
# An alias set that was never read back is exactly the state this step exists to
# catch, so a run without a credential REFUSES rather than skipping: the layer
# build and the set's start both follow this gate, and a gate nobody can open is
# not a gate. Supply the credential (or its file) on a deployment that is meant
# to come up; a deployment that is not meant to come up should not run this.
if [ -z "$CRED" ]; then
    refuse "no router credential supplied: set ROUTER_CREDENTIAL_FILE (preferred) or ROUTER_CREDENTIAL so the alias set can be read back from the router"
elif [ "$DRY_RUN" = "1" ]; then
    act "GET $ROUTER_ROOT/v1/models and require every alias in P-10, P-11 and P-12"
else
    models="$(curl -fsS -m 5 -H "Authorization: Bearer $CRED" "$ROUTER_ROOT/v1/models" 2>/dev/null)"
    alias_missing=""
    for a in $ROUTER_ALIAS $ROUTER_ALIAS_SET ${ROUTER_FAST_ALIAS:-}; do
        case "$models" in
            *"\"$a\""*) ;;
            *) alias_missing="$alias_missing $a" ;;
        esac
    done
    [ -z "$alias_missing" ] \
        && ok "the router serves every alias the set names (P-10 $ROUTER_ALIAS, P-11, P-12 ${ROUTER_FAST_ALIAS:-none})" \
        || refuse "the router's /v1/models does not list:$alias_missing — fix the router's alias set before starting a set that names them"
fi

step "8/9 harness layer (${HARNESS_IMAGE:-not set})"
if [ -z "${PARTS_ROOT:-}" ]; then
    unset_ "PARTS_ROOT is not set, so the layer cannot be built here; point HARNESS_IMAGE at a published reference"
else
    need HARNESS_IMAGE "${HARNESS_IMAGE:-}"
    need HARNESS_ID "${HARNESS_ID:-}"
    if docker image inspect "$HARNESS_IMAGE" >/dev/null 2>&1 && [ "${NO_CACHE:-0}" != "1" ]; then
        ok "present locally"
    elif [ "$REFUSED" -ne 0 ]; then
        unset_ "skipped: an earlier step refused, and this build would wire a set against a router that is not known good"
    else
        CTX="$PARTS_ROOT/add-an-agent-harness/skeleton"
        [ -f "$CTX/Containerfile" ] || refuse "no layer Containerfile at $CTX"
        # HARNESS_HOME is passed only when set: the layer has the same default for
        # it (the base account's home plus the CLI's name), and an explicit EMPTY
        # value would override that default and be refused by the layer's own
        # required-argument check.
        home_arg=""
        [ -n "${HARNESS_HOME:-}" ] && home_arg="--build-arg HARNESS_HOME=$HARNESS_HOME"
        verify_arg=""
        [ "${HARNESS_VERIFY_ENDPOINT:-0}" = "1" ] && verify_arg="--build-arg HARNESS_VERIFY_ENDPOINT=1"
        [ "$REFUSED" -eq 0 ] && { act "building the harness layer FROM $AGENT_HOST_IMAGE ($HARNESS_ID, alias $ROUTER_ALIAS)"; \
            [ "$DRY_RUN" = "1" ] || env $BK docker build -f "$CTX/Containerfile" \
                --build-arg "AGENT_BASE_REF=$AGENT_HOST_IMAGE" \
                --build-arg "AGENT_HARNESS_ID=$HARNESS_ID" \
                --build-arg "ROUTER_BASE_URL=$ROUTER_BASE_URL" \
                --build-arg "ROUTER_CREDENTIAL_ENV=${ROUTER_CREDENTIAL_ENV:-ROUTER_API_KEY}" \
                --build-arg "HARNESS_MODEL_ALIAS=$ROUTER_ALIAS" \
                --build-arg "HARNESS_FAST_ALIAS=${ROUTER_FAST_ALIAS:-$ROUTER_ALIAS}" \
                --build-arg "HARNESS_CONTEXT_WINDOW=${HARNESS_CONTEXT_WINDOW:-200000}" \
                --build-arg "HARNESS_MAX_OUTPUT_TOKENS=${HARNESS_MAX_OUTPUT_TOKENS:-32000}" \
                $home_arg $verify_arg \
                -t "$HARNESS_IMAGE" "$CTX" >/dev/null || refuse "the harness layer build failed — read its output: a required argument or an unreachable endpoint fails here, which is the edge this step exists for"; }
    fi
fi

step "9/9 start the set"
if [ -z "${COMPOSE_FILES:-}" ]; then
    unset_ "COMPOSE_FILES is not set, so no step of this run starts anything; the set is started by whatever merges the parts' fragments (see skeleton/compose.yaml)"
else
    need AGENT_HOST_IMAGE "${AGENT_HOST_IMAGE:-}"
    args=""
    for f in $COMPOSE_FILES; do [ -f "$f" ] || refuse "compose file not found: $f"; args="$args -f $f"; done
    [ "$REFUSED" -eq 0 ] && { act "docker compose$args up -d"; \
        STARTED=1; \
        [ "$DRY_RUN" = "1" ] || docker compose $args up -d || { STARTED=0; refuse "compose could not start the set"; }; }
    [ "$DRY_RUN" = "1" ] || { [ "$REFUSED" -eq 0 ] && ok "the set is up"; }
fi

printf '\n%d step(s), %d refusal(s)\n' "$CHECKS" "$REFUSED"
if [ "$REFUSED" -eq 0 ]; then
    say "Next: run the end-to-end acceptance script (scripts/verify-set.sh) with the same deployment inputs."
    if [ "$DRY_RUN" != "1" ] && [ "$STARTED" != "1" ]; then
        say "Nothing was started: no step that starts the set ran (COMPOSE_FILES was not set)."
        exit 3
    fi
    exit 0
fi
say "Refused steps are ordering violations, not transient errors: fix the named input and re-run."
exit 1
