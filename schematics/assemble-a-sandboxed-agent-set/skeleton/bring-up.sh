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
# Inputs (environment; see SCHEMATIC.md § Parameters for the discovery of each).
# The defaults named here are the parameter table's, and they are applied before
# any guard, so a deployment that leaves them alone is not refused for a variable
# the table says it may omit:
#   AGENT_SET_NETWORK        P-1   network every service joins (default agent-set)
#   AGENT_TREE_DIR           P-2   host directory bind-mounted as the agent tree
#   AGENT_IDS                P-3   space-separated agent ids
#   AGENT_BASE_REF           P-4   the base image reference
#   AGENT_HOST_IMAGE         P-5   the host image reference
#   HARNESS_IMAGE            P-6   the harness layer image reference
#   HARNESS_ID               P-7   the single CLI the layer installs
#   ROUTER_BASE_URL          P-8   the router ROOT the harness uses (no /v1: the
#                                  layer derives each arm's protocol path from it)
#                                  (default http://llm-router:4000)
#   ROUTER_CREDENTIAL_ENV    P-9   the name the CLI reads its router credential
#                                  from — derived from HARNESS_ID rather than
#                                  chosen: the pinned layer records the name at
#                                  /usr/local/share/agent-harness/credential-env,
#                                  which is ANTHROPIC_AUTH_TOKEN for the claude
#                                  arm (that CLI reads a fixed name) and this
#                                  variable (default ROUTER_API_KEY) for the codex
#                                  arm, whose provider block names it as env_key.
#                                  The same derived name is the one the host's
#                                  encrypted store must carry the credential
#                                  under.
#   ROUTER_ALIAS             P-10  the model alias the harness sends
#   ROUTER_ALIAS_SET         P-11  ids the router serves (space-separated)
#   ROUTER_FAST_ALIAS        P-12  the harness's secondary role (the arm that has
#                                  one requires it; the other ignores it)
#   HARNESS_CONTEXT_WINDOW   P-13  tokens, written into the harness config
#   HARNESS_MAX_OUTPUT_TOKENS P-14 tokens, written into the harness config (the
#                                  field only the claude arm's configuration has)
#   SECRETS_KEY_DIR          P-17  host directory holding the age keys
#                                  (default $HOME/sops/age)
#   SECRETS_STORE_DIR        P-18  host directory holding each service's store
#   ROUTER_SECRETS_SERVICE   P-19  store service for the router's provider keys
#                                  (default llm-router)
#   AGENT_HOST_SECRETS_SERVICE P-20 store service for the harness's credential
#                                  (default agent-host)
#
# Additional inputs:
#   PARTS_ROOT          directory holding each part's package checkout, laid out
#                       as <PARTS_ROOT>/<part-name>/ (needed by the three build
#                       steps; without it those steps skip, and the check and
#                       start steps still run)
#   COMPOSE_FILES       space-separated compose files in merge order, glue last
#   PART_SCRIPTS        space-separated name:path entries for the parts' own
#                       acceptance scripts — R-3's gate, run by step 9 before it
#                       starts anything (the same form scripts/verify-set.sh
#                       takes for its A-3)
#   BASE_DISTRO_DIGEST  the base part's own P-2, passed to the base build when
#                       BUILD_BASE=1: the manifest list digest of BASE_DISTRO_IMAGE.
#                       The base part has no default for it by design, so it is
#                       required by that build alone
#   ROUTER_HEALTH_URL   the router's own health endpoint (default: P-8 with
#                       /health/liveliness appended)
#   ROUTER_CREDENTIAL   the router credential, only for reading /v1/models. Prefer
#                       a file: ROUTER_CREDENTIAL_FILE. Neither is ever printed.
#   HARNESS_HOME        the harness's configuration root inside the image, passed
#                       to the layer build when set (the layer has the same
#                       default: the base account's home plus the CLI's name)
#   HARNESS_VERIFY_ENDPOINT=1  have the layer build check that P-8 answers, and
#                       fail the build when nothing does (the layer's P-11). It
#                       proves REACHABILITY: any HTTP answer passes it, and alias
#                       membership is not what it decides — step 7 is that gate
#   BASE_ACCOUNT_UID    the base image's account uid (part 1's P-4), for the tree
#                       ownership check
#   BASE_ACCOUNT_GID    likewise (P-5)
#   BUILD_BASE=1        build the base image from the base part's Containerfile
#                       when AGENT_BASE_REF is a local tag that does not exist
#   BUILDKIT=1          pass DOCKER_BUILDKIT=1 (the default on a current Engine);
#                       the base build needs it
#   AGENT_HOST_STATE    the host part's own parameter for the tree directory. Step
#                       9 derives it from AGENT_TREE_DIR when it is unset and
#                       refuses a value naming a different directory, so Compose
#                       mounts the tree whose ownership step 2 checked
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

# The parameter table's defaults, applied BEFORE the guards that read them. The
# values Compose also interpolates are exported, because this script hands its
# environment to `docker compose` at step 9 and an unexported shell variable would
# send the merge looking for a value that was never there.
export AGENT_SET_NETWORK="${AGENT_SET_NETWORK:-agent-set}"
export ROUTER_SECRETS_SERVICE="${ROUTER_SECRETS_SERVICE:-llm-router}"
export AGENT_HOST_SECRETS_SERVICE="${AGENT_HOST_SECRETS_SERVICE:-agent-host}"
ROUTER_BASE_URL="${ROUTER_BASE_URL:-http://llm-router:4000}"
ROUTER_CREDENTIAL_ENV="${ROUTER_CREDENTIAL_ENV:-ROUTER_API_KEY}"

# P-8 addresses the router by service name on P-1's network, and the router's own
# fragment publishes no host port (the router part's R-6), so a request issued
# from this shell's namespace resolves nothing and would refuse a deployment that
# is in fact up. Every probe of the router therefore runs inside a container
# attached to that network — the namespace the harness's own requests come from —
# using the host image, whose toolchain carries curl and jq (the base part's
# Containerfile installs both), so nothing outside the set has to have them.
probe() {  # probe SHELL-SNIPPET [ENV-NAME]: run it in a throwaway container on the set network
    env_arg=""
    [ -n "${2:-}" ] && env_arg="-e $2"
    # The unquoted $env_arg is intentional: it is empty or one flag, and it is
    # how an env NAME reaches the container without its VALUE appearing in any
    # command line.
    docker run --rm --network "$AGENT_SET_NETWORK" $env_arg --entrypoint sh "$AGENT_HOST_IMAGE" -c "$1"
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
# P-17's default is the parameter table's `~/sops/age`. A quoted assignment does
# not expand `~`, so HOME is expanded here instead — and a shell that has none
# gets this script's own exit 2 rather than the shell's unbound-variable error,
# which is neither the code nor the message the header promises.
if [ -z "${SECRETS_KEY_DIR:-}" ]; then
    [ -n "${HOME:-}" ] || { printf 'bring-up: SECRETS_KEY_DIR (P-17) is not set and HOME is empty, so its default ~/sops/age cannot be resolved\n' >&2; exit 2; }
    SECRETS_KEY_DIR="$HOME/sops/age"
    export SECRETS_KEY_DIR
fi
need SECRETS_KEY_DIR "${SECRETS_KEY_DIR:-}"
need SECRETS_STORE_DIR "${SECRETS_STORE_DIR:-}"
need ROUTER_SECRETS_SERVICE "${ROUTER_SECRETS_SERVICE:-}"
need AGENT_HOST_SECRETS_SERVICE "${AGENT_HOST_SECRETS_SERVICE:-}"
# One store service per consumer. Two equal names are not a shorter spelling of
# this step: the glue maps the router's secret source and the host's from these
# two names, so one name makes both containers decrypt the same file with the
# same dedicated key — the host would then hold the router's provider keys, and
# the store part's per-service key and isolation contract would be gone.
if [ "$ROUTER_SECRETS_SERVICE" = "$AGENT_HOST_SECRETS_SERVICE" ]; then
    refuse "ROUTER_SECRETS_SERVICE and AGENT_HOST_SECRETS_SERVICE are both '$ROUTER_SECRETS_SERVICE': one store and one dedicated key would serve both consumers, so the host container would decrypt the router's provider keys — give each consumer its own store service (P-19, P-20)"
else
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
fi

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
need AGENT_HOST_IMAGE "${AGENT_HOST_IMAGE:-}"
ROUTER_ROOT="${ROUTER_BASE_URL%/}"
HEALTH_URL="${ROUTER_HEALTH_URL:-$ROUTER_ROOT/health/liveliness}"
if [ "$DRY_RUN" = "1" ]; then
    act "curl -fsS $HEALTH_URL in a container on $AGENT_SET_NETWORK"
elif probe "curl -fsS -m 5 '$HEALTH_URL' >/dev/null"; then
    ok "the router answers $HEALTH_URL from a container on $AGENT_SET_NETWORK"
else
    refuse "the router does not answer $HEALTH_URL from a container on $AGENT_SET_NETWORK; deploy it first (its own package owns that), or set ROUTER_HEALTH_URL to the path this router really serves"
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
    act "GET $ROUTER_ROOT/v1/models in a container on $AGENT_SET_NETWORK and require every id in P-10, P-11 and P-12"
else
    # The credential reaches the probe container through its environment (the
    # name is on the command line, never the value), and it is not printed.
    export PROBE_CREDENTIAL="$CRED"
    if ! served="$(probe "curl -fsS -m 5 -H 'Authorization: Bearer \$PROBE_CREDENTIAL' '$ROUTER_ROOT/v1/models' | jq -r '.data[]?.id'" PROBE_CREDENTIAL)"; then
        refuse "the router's model list could not be read from $AGENT_SET_NETWORK — the probe container's own output is above; check that the router answers $ROUTER_ROOT/v1/models and that AGENT_HOST_IMAGE is the image this deployment runs"
    elif [ -z "$served" ]; then
        refuse "the answer from $ROUTER_ROOT/v1/models carries no model id; a router serving no model cannot serve the alias set this set names"
    else
        # Membership is compared id by id, not by searching the body for a quoted
        # string: an alias can appear in a metadata field (owned_by, a description)
        # while no served model has that id, and that answer must not open the gate.
        served_ids=" $(printf '%s' "$served" | tr '\n' ' ') "
        alias_missing=""
        for a in $ROUTER_ALIAS $ROUTER_ALIAS_SET ${ROUTER_FAST_ALIAS:-}; do
            case "$served_ids" in
                *" $a "*) ;;
                *) alias_missing="$alias_missing $a" ;;
            esac
        done
        [ -z "$alias_missing" ] \
            && ok "the router serves every alias the set names (P-10 $ROUTER_ALIAS, P-11, P-12 ${ROUTER_FAST_ALIAS:-none})" \
            || refuse "the router's /v1/models does not list:$alias_missing — fix the router's alias set before starting a set that names them"
    fi
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
        [ -f "$CTX/Containerfile" ] || refuse "no Containerfile at $CTX"
        # P-13 and P-14 are required by this package's parameter table, so they
        # are required of the build rather than invented here: an argument filled
        # in with a plausible number would write metadata unrelated to the alias
        # the set names, and nothing downstream would notice. P-14 and P-12 are
        # the claude arm's own fields — the layer requires both for that arm, and
        # the codex arm's configuration carries neither — so for an arm that does
        # not require them the value is forwarded only when it was supplied.
        need HARNESS_CONTEXT_WINDOW "${HARNESS_CONTEXT_WINDOW:-}"
        max_arg=""
        [ -n "${HARNESS_MAX_OUTPUT_TOKENS:-}" ] && max_arg="--build-arg HARNESS_MAX_OUTPUT_TOKENS=$HARNESS_MAX_OUTPUT_TOKENS"
        fast_arg=""
        [ -n "${ROUTER_FAST_ALIAS:-}" ] && fast_arg="--build-arg HARNESS_FAST_ALIAS=$ROUTER_FAST_ALIAS"
        # The credential variable's name is ARM-DEPENDENT, and the layer's own
        # record is the authority for it: the image writes the name the harness it
        # installed actually reads to /usr/local/share/agent-harness/credential-env.
        # One derived name is passed to the build, and it is the name the host's
        # encrypted store has to carry the credential under.
        case "$HARNESS_ID" in
            claude)
                # This arm reads ANTHROPIC_AUTH_TOKEN whatever P-9 says, and its
                # configuration carries a second role and a max-output field.
                CREDENTIAL_ENV=ANTHROPIC_AUTH_TOKEN
                need ROUTER_FAST_ALIAS "${ROUTER_FAST_ALIAS:-}"
                need HARNESS_MAX_OUTPUT_TOKENS "${HARNESS_MAX_OUTPUT_TOKENS:-}" ;;
            *)
                CREDENTIAL_ENV="$ROUTER_CREDENTIAL_ENV" ;;
        esac
        # HARNESS_HOME is passed only when set: the layer has the same default for
        # it (the base account's home plus the CLI's name), and an explicit EMPTY
        # value would override that default and be refused by the layer's own
        # required-argument check.
        home_arg=""
        [ -n "${HARNESS_HOME:-}" ] && home_arg="--build-arg HARNESS_HOME=$HARNESS_HOME"
        verify_arg=""
        [ "${HARNESS_VERIFY_ENDPOINT:-0}" = "1" ] && verify_arg="--build-arg HARNESS_VERIFY_ENDPOINT=1"
        [ "$REFUSED" -eq 0 ] && { act "building the harness layer FROM $AGENT_HOST_IMAGE ($HARNESS_ID, alias $ROUTER_ALIAS, credential variable $CREDENTIAL_ENV)"; \
            [ "$DRY_RUN" = "1" ] || env $BK docker build -f "$CTX/Containerfile" \
                --build-arg "AGENT_BASE_REF=$AGENT_HOST_IMAGE" \
                --build-arg "AGENT_HARNESS_ID=$HARNESS_ID" \
                --build-arg "ROUTER_BASE_URL=$ROUTER_BASE_URL" \
                --build-arg "ROUTER_CREDENTIAL_ENV=$CREDENTIAL_ENV" \
                --build-arg "HARNESS_MODEL_ALIAS=$ROUTER_ALIAS" \
                --build-arg "HARNESS_CONTEXT_WINDOW=$HARNESS_CONTEXT_WINDOW" \
                $home_arg $verify_arg $fast_arg $max_arg \
                -t "$HARNESS_IMAGE" "$CTX" >/dev/null || refuse "the harness layer build failed — read its output: a required argument or an unreachable endpoint fails here, which is the edge this step exists for"; }
    fi
fi

step "9/9 start the set"
if [ -z "${COMPOSE_FILES:-}" ]; then
    unset_ "COMPOSE_FILES is not set, so no step of this run starts anything; the set is started by whatever merges the parts' fragments (see skeleton/compose.yaml)"
else
    # Every value the merge reads is checked here, where the message can name it:
    # the parts' fragments and the glue each fail their own `${VAR:?}` guard when
    # one is missing, which says what Compose needed but not which parameter it is.
    need AGENT_HOST_IMAGE "${AGENT_HOST_IMAGE:-}"
    need AGENT_IDS "${AGENT_IDS:-}"
    need HARNESS_IMAGE "${HARNESS_IMAGE:-}"
    # AGENT_HOST_STATE is the host part's own name for the tree directory. Derived
    # from P-2 when unset — the parameter table's name for that path is
    # AGENT_TREE_DIR, and one tree must not have two spellings — and a value that
    # names some other directory is refused, because step 2 checked the owner of
    # AGENT_TREE_DIR and Compose would mount a path nothing validated.
    if [ -z "${AGENT_HOST_STATE:-}" ]; then
        AGENT_HOST_STATE="$AGENT_TREE_DIR"
    elif [ "$AGENT_HOST_STATE" != "$AGENT_TREE_DIR" ]; then
        refuse "AGENT_HOST_STATE is $AGENT_HOST_STATE while AGENT_TREE_DIR (P-2) is $AGENT_TREE_DIR: the host fragment mounts the tree from AGENT_HOST_STATE, and only AGENT_TREE_DIR's owner was checked — point P-2 at the tree this deployment mounts"
    fi
    export AGENT_HOST_STATE
    # R-3: every part has to pass its own acceptance rows before the chain is
    # assembled, and a part that fails them stops the assembly rather than being
    # worked around inside it. The gate runs HERE, before anything is started,
    # which is the whole point of the edge; the same name:path form and the same
    # verdict wording as scripts/verify-set.sh's A-3 are used, so one list serves
    # both. A run that names no part script skips the gate with its reason printed
    # — an unavailable row is never counted as a pass.
    if [ -z "${PART_SCRIPTS:-}" ]; then
        unset_ "PART_SCRIPTS is not set, so R-3's gate cannot run; set it to the parts' acceptance scripts (name:path, space-separated) and re-run to have every part pass before the set starts"
    else
        for entry in $PART_SCRIPTS; do
            name="${entry%%:*}"; script="${entry#*:}"
            if [ ! -f "$script" ]; then
                refuse "the $name part's own acceptance script is not at $script — run it from the part's own package checkout before assembling the chain"
            elif [ ! -x "$script" ]; then
                refuse "the $name part's own acceptance script $script is not executable"
            elif [ "$DRY_RUN" = "1" ]; then
                act "bash $script ($name)"
            elif bash "$script" >/dev/null 2>&1; then
                ok "$name: its own acceptance script exits 0"
            else
                refuse "the $name part fails its own acceptance script ($script); a part that fails its own rows must stop the assembly, not be worked around inside the chain (R-3)"
            fi
        done
    fi
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
