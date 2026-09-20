#!/usr/bin/env bash
#
# Acceptance checks for a sandboxed agent set — the chain, not the parts.
#
# Implements the mechanical checks of SCHEMATIC.md's Verification and
# Acceptance section (A-1 … A-16). It touches nothing outside Docker and the
# package directory: it inspects containers and images, merges the compose
# fragments in config-only mode, and — only for the rows that need it — creates
# one short-lived container. Safe to re-run.
#
# The parts' own acceptance scripts prove the parts. This script proves the
# glue: the order, the isolation rules, the shared values, and the alias path
# from an agent pane to the router.
#
# Inputs (environment; none of these is written anywhere):
#   AGENT_SET_NETWORK     network every service of the set joins   (no default)
#   AGENT_TREE_DIR        host directory bind-mounted as the agent tree
#   AGENT_IDS             the agent ids the host runs (space- or
#                         comma-separated, as the parts take them)  (no default)
#   AGENT_WORKSPACE_DIR   the container path the agent tree is mounted at
#                         (optional: with it, every pane's own
#                         AGENT_WORKSPACE_DIR must lie under it; the row reads
#                         each pane's own value for the exact path, because the
#                         multiplexer gives each pane its own workspace)
#   AGENT_HOST_IMAGE      the host image reference                 (no default)
#   HARNESS_IMAGE         the harness layer image reference        (no default)
#   HARNESS_ID            the single CLI the layer installs        (no default)
#   HARNESS_CONFIG_PATH   the CLI's configuration file(s) inside the container,
#                         absolute paths, space-separated: the omp arm's endpoint
#                         and its roles live in two files and every named file is
#                         read, the other arms name one           (no default)
#   ROUTER_BASE_URL       the router ROOT, no /v1: the harness layer
#                         derives each arm's path from it (the root for
#                         claude, root plus /v1 for codex and omp), so the
#                         models endpoint is read at <root>/v1/models
#                                                                  (no default)
#   ROUTER_CREDENTIAL_ENV name of the variable carrying the router
#                         credential; the name actually checked is derived from
#                         HARNESS_ID (ANTHROPIC_AUTH_TOKEN for claude, this
#                         name for codex and omp)   (default: ROUTER_API_KEY)
#   ROUTER_ALIAS          the model alias the harness sends        (no default)
#   ROUTER_ALIAS_SET      space-separated ids the router serves    (no default)
#   DOCKER_PROXY_URL      the Docker-access endpoint consumers use, as a
#                         DOCKER_HOST value
#                                 (default: tcp://socket-proxy:2375; the Docker-
#                                 access part's http://socket-proxy:2375 is the
#                                 URL its own audit script uses, and the Docker
#                                 client refuses that scheme outright)
#   DOCKER_PROXY_ALLOWLIST  the proxy's allowed endpoint groups    (no default)
#   SECRETS_KEY_DIR       host directory holding the age key material
#   HOST_CONTAINER        the running host container's name        (no default)
#   ROUTER_CONTAINER      the running router container's name      (no default:
#                         the whole-set rows A-5, A-6, A-7 and A-13 cannot
#                         inspect every container of the set without it, and
#                         print SKIP rather than green over a subset)
#   PROXY_CONTAINER       the running Docker-access proxy's name   (same rule:
#                         without it A-5 cannot see the proxy's one sanctioned
#                         socket mount, nor A-13 the proxy's network contract)
#   PART_SCRIPTS          space-separated name:path entries for the parts'
#                         own acceptance scripts (optional; A-3). Both this
#                         list and COMPOSE_FILES are split on whitespace, so a
#                         path containing a space cannot be given here; a
#                         COMPOSE_FILES path that does not exist makes A-2
#                         SKIP, and a PART_SCRIPTS one makes A-3 FAIL — neither
#                         list is silently shortened
#   COMPOSE_FILES         space-separated paths of the parts' compose fragments
#                         and this package's glue, in merge order (A-2)
#   EXPECTED_SERVICES     service names the merged configuration must define
#                         (optional; without it, A-2 checks that the merge works,
#                         not that the set is complete)
#   PACKAGE_DIR           this package's directory (default: the script's parent)
#   REPO_DIR              the git checkout to check pins against (A-1; default:
#                         PACKAGE_DIR/../..)
#
# Opt-ins — a row that would disturb a running deployment runs only when its
# opt-in is set; otherwise it prints SKIP with that reason:
#   ALLOW_ROUTER_STOP=1     A-12 stops the router, tests, and starts it again
#   ALLOW_CONTAINER_PROBE=1 A-14 creates one container to prove the store fails
#                           loudly without its key
#   ALLOW_TEARDOWN=1        A-16 tears the set down before re-checking the parts
#   PROVIDER_CREDENTIAL=1   A-15 makes one real completion through the alias
#   ALLOW_BUILD_PROBE=1     A-4 attempts a build whose endpoint check must fail
#
# Rows that need something the host does not have print
# `SKIP  <row> <reason>` and are never counted as passes.

set -uo pipefail

PACKAGE_DIR="${PACKAGE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$PACKAGE_DIR/../.." 2>/dev/null && pwd)}"

CHECKS=0
FAILURES=0
SKIPPED=0

pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }
usage_error() { printf 'verify-set: %s\n' "$1" >&2; exit 2; }
# The verdict lives in one place: a row that has to stop the run (A-3's part
# gate) reports the same summary as the end of the script, never a second format.
verdict() {
    printf '\n%d check(s): %d failed, %d skipped\n' "$CHECKS" "$FAILURES" "$SKIPPED"
    if [ "$SKIPPED" -gt 0 ]; then
        printf 'Skipped rows are not passes: each SKIP above names what the host could not provide.\n'
    fi
    [ "$FAILURES" -eq 0 ] || exit 1
    exit 0
}

# A throwaway tag this script owns, removed at the end when it was created.
PROBE_TAG="agent-set-verify:probe-$$"
PROBE_CID=""
cleanup() {
    [ -n "$PROBE_CID" ] && docker rm -f "$PROBE_CID" >/dev/null 2>&1
    docker image rm "$PROBE_TAG" >/dev/null 2>&1 || true
    return 0
}
trap cleanup EXIT

# A request this host refused, or cannot satisfy because the object is absent or
# not running, is not a failing row: the row prints SKIP with that reason instead
# of a verdict it did not obtain.
exec_reason() {  # why an exec-based row cannot run here: not running, or the host refused the call
    state="$(docker inspect "$HOST_CONTAINER" --format '{{.State.Running}}' 2>&1)"
    if [ "$state" = "true" ]; then
        printf 'this host refused docker exec'
    else
        printf '%s is not running on this host (bring the set up, or point HOST_CONTAINER at it)' "$HOST_CONTAINER"
    fi
}

absent() {  # the object the row reads does not exist here (or docker could not name it): say so, do not call it a refusal
    case "$1" in
        *"No such image"*|*"No such container"*|*"No such object"*|*"not found"*) return 0 ;;
        *"Error response from daemon"*|*"multiple IDs found"*) return 0 ;;
        *"failed to connect"*|*"Cannot connect"*|*"cannot connect"*) return 0 ;;
        *) return 1 ;;
    esac
}

denied() {
    case "$1" in
        *"authorization denied"*|*"permission denied"*|*"cannot connect to the Docker daemon"*) return 0 ;;
        *"is not running"*|*"No such container"*|*"No such object"*|*"No such image"*) return 0 ;;
        *"Error response from daemon"*|*"multiple IDs found"*) return 0 ;;
        *"failed to connect"*|*"Cannot connect"*|*"cannot connect"*) return 0 ;;
        *) return 1 ;;
    esac
}

# A Docker socket, recognized by what it is rather than by its name alone: a
# bind mount whose host source is a Unix socket (`-S`, which is how a socket at
# the Docker-access part's configurable P-2 path is caught), or a mount whose
# source or destination names docker.sock. Every other mount in this set is a
# directory or a file.
is_socket_mount() {  # is_socket_mount SOURCE DESTINATION
    case "$1$2" in
        *docker.sock*) return 0 ;;
    esac
    [ -S "$1" ] && return 0
    return 1
}

# One value out of the arm's own configuration: Claude Code's settings.json (a
# JSON string under a key) or Codex's config.toml (`key = "value"`). The caller
# compares the value whole, so no substring of a value can satisfy it.
cfg_value() {  # cfg_value CONFIG KEY
    case "$HARNESS_ID" in
        claude) printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1 ;;
        omp)    printf '%s' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1 ;;
        *)      printf '%s' "$1" | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1 ;;
    esac
}

require() {  # require NAME VALUE
    [ -n "${2:-}" ] || usage_error "$1 is not set"
}
for v in AGENT_SET_NETWORK AGENT_TREE_DIR AGENT_IDS AGENT_HOST_IMAGE HARNESS_IMAGE \
         HARNESS_ID HARNESS_CONFIG_PATH ROUTER_BASE_URL ROUTER_ALIAS ROUTER_ALIAS_SET \
         DOCKER_PROXY_ALLOWLIST HOST_CONTAINER; do
    require "$v" "${!v:-}"
done
# P-15 has a default, so it is applied rather than required: a caller that omits
# it is a caller using the documented value, not one with a missing input.
DOCKER_PROXY_URL="${DOCKER_PROXY_URL:-tcp://socket-proxy:2375}"
# P-15 is the value a consumer exports as DOCKER_HOST, and the Docker client
# takes only a client scheme: `docker -H http://… version` fails before any
# connection with "invalid bind address format", while `tcp://…` initializes the
# client and then dials. The proxy part's own http:// URL is its audit script's.
case "$DOCKER_PROXY_URL" in
    tcp://*|unix://*|ssh://*|fd://*|npipe://*) ;;
    *) usage_error "DOCKER_PROXY_URL=$DOCKER_PROXY_URL carries no Docker client scheme, so no probe here can reach a daemon through it; P-15 is the value consumers set as DOCKER_HOST (tcp://socket-proxy:2375) — the Docker-access part's own http:// URL is its audit script's, and the client refuses that scheme before it dials anything" ;;
esac
ROUTER_CREDENTIAL_ENV="${ROUTER_CREDENTIAL_ENV:-ROUTER_API_KEY}"
AGENT_WORKSPACE_DIR="${AGENT_WORKSPACE_DIR:-}"
# The credential's NAME is arm-dependent, not chosen. The pinned harness layer
# records the name the CLI it installed reads at
# /usr/local/share/agent-harness/credential-env: ANTHROPIC_AUTH_TOKEN for the
# Claude arm, whose settings.json carries no credential because the process
# environment does, and ROUTER_CREDENTIAL_ENV for the Codex arm, whose
# config.toml names it as env_key — and for the omp arm, whose provider block
# names it the same way. One name is derived here and used by every
# row that reads it — A-10, A-11 and A-15 — so a deployment cannot pass by
# populating a variable no CLI reads.
case "$HARNESS_ID" in
    claude) CREDENTIAL_ENV="ANTHROPIC_AUTH_TOKEN" ;;
    *)      CREDENTIAL_ENV="$ROUTER_CREDENTIAL_ENV" ;;
esac
# The ids this host runs, in one spelling: the parts take AGENT_IDS
# comma-separated, the alias sets space-separated, and the rows read either.
AGENT_ID_LIST="$(printf '%s' "$AGENT_IDS" | tr ',' ' ')"
ALIAS_SET_LIST="$(printf '%s' "$ROUTER_ALIAS_SET" | tr ',' ' ')"
# P-8 is the router root; the API path is appended here, exactly as the harness
# layer appends it per arm. A value that already ends in /v1 would double it.
ROUTER_ROOT="${ROUTER_BASE_URL%/}"
case "$ROUTER_ROOT" in
    */v1) usage_error "ROUTER_BASE_URL=$ROUTER_BASE_URL ends in /v1, but P-8 is the router ROOT: every row here appends its own path, so the models endpoint would be read at $ROUTER_ROOT/v1/models — the /v1 doubled. The harness layer derives each arm's path from the root and refuses a /v1 suffix at build time for exactly this reason; pass the root" ;;
esac
MODELS_URL="$ROUTER_ROOT/v1/models"
PROXY_CONTAINER="${PROXY_CONTAINER:-}"

printf 'verifying the sandboxed agent set\n'
printf '  host container   %s\n' "$HOST_CONTAINER"
printf '  harness image    %s\n' "$HARNESS_IMAGE"
printf '  router endpoint  %s\n' "$ROUTER_BASE_URL"
printf '  alias            %s\n\n' "$ROUTER_ALIAS"

# ---------------------------------------------------------------------------
# A-1: every pinned dependency resolves, is reachable, and matches its hash
# ---------------------------------------------------------------------------
# The pins live in the package's own Dependencies table. Each is a blob URL at a
# commit plus the SHA-256 of that file at that commit. Reachability is checked
# against HEAD, which is the rule: a pin written at a branch tip passes on the
# branch and fails only after a squash merge.
SPEC="$PACKAGE_DIR/SCHEMATIC.md"
if [ ! -f "$SPEC" ]; then
    skip "A-1 SCHEMATIC.md not found at $SPEC"
elif [ ! -d "$REPO_DIR/.git" ]; then
    skip "A-1 $REPO_DIR is not a git checkout; cannot check pin reachability (use the package's repository)"
elif ! command -v git >/dev/null 2>&1; then
    skip "A-1 git is not installed; cannot check pin reachability"
else
    pins_checked=0
    pins_bad=""
    while IFS= read -r line; do
        commit="$(printf '%s' "$line" | sed -n 's|.*/blob/\([0-9a-f]\{40\}\)/schematics/.*|\1|p')"
        path="$(printf '%s' "$line" | sed -n 's|.*/blob/[0-9a-f]\{40\}/\(schematics/[^)]*SCHEMATIC.md\).*|\1|p')"
        hash="$(printf '%s' "$line" | sed -n 's|.*`sha256:\([0-9a-f]\{64\}\)`.*|\1|p')"
        version="$(printf '%s' "$line" | sed -n 's|.*\[\([^]]*\) v\([0-9][^]]*\)\](https.*|\2|p')"
        [ -n "$commit" ] && [ -n "$path" ] && [ -n "$hash" ] || continue
        pins_checked=$((pins_checked + 1))
        if ! git -C "$REPO_DIR" merge-base --is-ancestor "$commit" HEAD 2>/dev/null; then
            pins_bad="$pins_bad
  $path: commit ${commit%????????????????????????????????} is not reachable from HEAD"
            continue
        fi
        # Existence and emptiness are different answers: `git show` of a missing
        # path and of an empty file both hash to the same value, so testing the
        # hash first reported an empty pinned file as one that is not there.
        if ! git -C "$REPO_DIR" cat-file -e "$commit:$path" 2>/dev/null; then
            pins_bad="$pins_bad
  $path: not present at commit ${commit%????????????????????????????????}"
            continue
        fi
        blob_hash="$(git -C "$REPO_DIR" show "$commit:$path" | sha256sum | cut -d' ' -f1)"
        if [ "$blob_hash" = "$(printf '' | sha256sum | cut -d' ' -f1)" ]; then
            pins_bad="$pins_bad
  $path: present at commit ${commit%????????????????????????????????} but empty, so it cannot be the pinned file"
            continue
        fi
        if [ "$blob_hash" != "$hash" ]; then
            pins_bad="$pins_bad
  $path: sha256 is $blob_hash, the row says $hash"
            continue
        fi
        if [ -n "$version" ]; then
            blob_version="$(git -C "$REPO_DIR" show "$commit:$path" | sed -n 's/^version: //p')"
            [ "$blob_version" = "$version" ] \
                || pins_bad="$pins_bad
  $path: pinned as v$version, the file at that commit says v$blob_version"
        fi
    done < "$SPEC"
    if [ "$pins_checked" -eq 0 ]; then
        fail "A-1 no dependency pins found in $SPEC"
    elif [ -z "$pins_bad" ]; then
        pass "A-1 all $pins_checked pinned dependencies are reachable from HEAD and match their row's sha256 (and version)"
    else
        fail "A-1 pinned dependencies that do not resolve:$pins_bad"
    fi
fi

# ---------------------------------------------------------------------------
# A-2: the composition defines no service of its own
# ---------------------------------------------------------------------------
GLUE="$PACKAGE_DIR/skeleton/compose.yaml"
if [ ! -f "$GLUE" ]; then
    skip "A-2 no glue file at $GLUE"
else
    # The rule is about what the glue says about a service, not whether it names
    # one: network membership and a secret reference are shared contracts, while
    # image, command, entrypoint, environment, user and mounts belong to a part.
    bad_keys="$(awk '
        /^services:[[:space:]]*$/ { in_svc = 1; next }
        in_svc && /^[^[:space:]#]/ { in_svc = 0 }
        in_svc && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { svc = $1; next }
        in_svc && /^    [A-Za-z0-9._-]+:/ {
            key = $0; sub(/^    /, "", key); sub(/:.*/, "", key)
            if (key != "networks") printf "%s: %s\n", svc, key
        }
    ' "$GLUE")"
    if [ -n "$bad_keys" ]; then
        fail "A-2 the glue file sets service fields that belong to a part: $(printf '%s' "$bad_keys" | tr '\n' ' ')"
    else
        forbidden_keys="$(grep -nE '^[[:space:]]+(image|build|command|entrypoint|environment|user|ports|volumes|privileged|cap_add|cap_drop|devices|pid|network_mode):' "$GLUE" || true)"
        if [ -n "$forbidden_keys" ]; then
            fail "A-2 the glue file carries a service-defining field: $(printf '%s' "$forbidden_keys" | head -1)"
        else
            pass "A-2 the glue file declares no image, command, entrypoint, environment, user, or mount for any service; what it declares is network membership and secret sources"
        fi
    fi
    if [ -n "${COMPOSE_FILES:-}" ]; then
        missing=""
        for f in $COMPOSE_FILES; do [ -f "$f" ] || missing="$missing $f"; done
        if [ -n "$missing" ]; then
            skip "A-2 merged-config check: missing fragment(s):$missing"
        elif ! command -v docker >/dev/null 2>&1; then
            skip "A-2 merged-config check: docker is not available"
        else
            args=""
            for f in $COMPOSE_FILES; do args="$args -f $f"; done
            merged="$(docker compose $args config 2>&1)"
            mergerc=$?
            if [ "$mergerc" -ne 0 ]; then
                if denied "$merged"; then
                    skip "A-2 merged-config check: docker refused the request on this host"
                elif printf '%s' "$merged" | grep -q "is missing a value"; then
                    # The fragments interpolate the deployment's own values; a check
                    # run that does not carry them cannot render the file, and that is
                    # a gap in the check's inputs, not a defect in the composition.
                    skip "A-2 merged-config check: the parts' variables are not all supplied to this check ($(printf '%s' "$merged" | grep -o 'required variable [A-Z_]*' | head -1))"
                else
                    fail "A-2 docker compose config failed: $(printf '%s' "$merged" | tail -1)"
                fi
            else
                svc_all="$(printf '%s' "$merged" | sed -n '/^services:/,/^[a-z]/p' | grep -cE '^  [A-Za-z0-9._-]+:$' || true)"
                if [ "${svc_all:-0}" -eq 0 ]; then
                    fail "A-2 the merged configuration defines no service; at least one part's fragment must contribute one"
                elif [ -n "${EXPECTED_SERVICES:-}" ]; then
                    absent_svc=""
                    for s in $EXPECTED_SERVICES; do
                        printf '%s' "$merged" | grep -qE "^  $s:" || absent_svc="$absent_svc $s"
                    done
                    # The other direction, and the one R-2's "exactly" needs: a
                    # file in the merge that defines a service no part owns. The
                    # store part's `compose-secrets.yml` carries
                    # `services.myservice`, so a merge list that includes it
                    # produces a service this set does not have — and a
                    # presence-only check passes it, leaving `up` to fail on the
                    # pull of an image no part names.
                    extra_svc=""
                    for s in $(printf '%s' "$merged" | sed -n '/^services:/,/^[a-z]/p' | grep -oE '^  [A-Za-z0-9._-]+:' | tr -d ' :'); do
                        case " $EXPECTED_SERVICES " in
                            *" $s "*) ;;
                            *) extra_svc="$extra_svc $s" ;;
                        esac
                    done
                    if [ -n "$absent_svc" ]; then
                        fail "A-2 the merged configuration is missing service(s):$absent_svc — a fragment is absent from COMPOSE_FILES, and the set would come up without that service"
                    elif [ -n "$extra_svc" ]; then
                        fail "A-2 the merged configuration defines service(s) no expected part owns:$extra_svc — a file in COMPOSE_FILES defines a service this set does not have (the store part's compose-secrets.yml, whose services.myservice no part owns, is the usual cause); R-2's rule is that the merged services are exactly the parts' own, so drop that fragment from the merge list instead of starting a service nobody verified"
                    else
                        pass "A-2 the merged configuration defines exactly the expected services ($EXPECTED_SERVICES); the glue contributed network membership and secret sources only"
                    fi
                else
                    note "A-2 no EXPECTED_SERVICES supplied, so this row does not assert that nothing else is defined: the merged service list could not be compared with the parts' own"
                    pass "A-2 the merged configuration renders with $svc_all service(s) from the fragments in COMPOSE_FILES"
                fi
            fi
        fi
    else
        skip "A-2 merged-config check: COMPOSE_FILES is not set (name the parts' fragments in merge order)"
    fi
fi

# ---------------------------------------------------------------------------
# A-3: every part passed its own acceptance rows before the chain was assembled
# ---------------------------------------------------------------------------
if [ -z "${PART_SCRIPTS:-}" ]; then
    skip "A-3 no part acceptance scripts supplied (set PART_SCRIPTS='name:path …'): with no script named, neither this row nor the bring-up script's step-9 gate can run, so R-3 is unmet here rather than satisfied"
else
    part_failed=0
    for entry in $PART_SCRIPTS; do
        name="${entry%%:*}"; script="${entry#*:}"
        if [ ! -f "$script" ]; then
            # A name:path entry is the deployment's assertion that this part's
            # rows can be run, so a path that is not on disk is R-3's gate unmet
            # rather than a check the host could not perform — and bring-up.sh's
            # step 9 refuses on exactly this condition, so the two paths agree.
            fail "A-3 $name: no script at $script — R-3's gate has nothing to run for this part (the bring-up script's step 9 refuses on the same condition)"
            part_failed=1
        elif [ ! -x "$script" ]; then
            fail "A-3 $name: $script is not executable, so its part has not been verified"
            part_failed=1
        else
            bash "$script" >/dev/null 2>&1
            rc=$?
            if [ "$rc" -eq 0 ]; then
                pass "A-3 $name: its own acceptance script exits 0"
            else
                fail "A-3 $name: $script exited $rc; a part that fails its own rows must stop the assembly"
                part_failed=1
            fi
        fi
    done
    if [ "$part_failed" -eq 1 ]; then
        # R-3: the gate is a gate. Continuing would run the rows that observe an
        # assembled set over a part known to be broken, and a green row there
        # would be a claim about a chain nobody may bring up.
        note "R-3: a part that fails its own acceptance rows stops the assembly, so the rows that observe the assembled set are not run"
        verdict
    fi
fi

# ---------------------------------------------------------------------------
# A-4: the harness build refuses an endpoint nothing answers at
# ---------------------------------------------------------------------------
# The layer's P-11 check is what makes this row meaningful: with it set, a build
# that cannot reach the endpoint the arm is wired to stops with the guard's code
# 78 and a line naming the parameter. The row supplies EVERY argument the build
# requires for this arm: a build that failed on a missing argument would satisfy a
# looser version of this check while testing nothing, and that is exactly what an
# earlier version of this row did.
if [ "${ALLOW_BUILD_PROBE:-0}" != "1" ]; then
    skip "A-4 build probe not enabled (set ALLOW_BUILD_PROBE=1; it builds one throwaway image)"
else
    LAYER_CTX="${LAYER_BUILD_CONTEXT:-}"
    # The arguments this row supplies come from the RUN, never from a default
    # invented here: a probe that defaulted a value the deployment omits would
    # test a build no deployment makes, and would pass over exactly what this
    # row's failure column calls a failure — a build given less than it requires.
    # bring-up.sh requires the same ones for the same arms: P-13 always, and P-12
    # and P-14 for claude and omp, whose configuration carries the second role
    # and the max-output key.
    a4_missing=""
    [ -n "${HARNESS_CONTEXT_WINDOW:-}" ] || a4_missing="$a4_missing P-13(HARNESS_CONTEXT_WINDOW)"
    case "$HARNESS_ID" in
        claude|omp)
            [ -n "${ROUTER_FAST_ALIAS:-}" ] || a4_missing="$a4_missing P-12(ROUTER_FAST_ALIAS)"
            [ -n "${HARNESS_MAX_OUTPUT_TOKENS:-}" ] || a4_missing="$a4_missing P-14(HARNESS_MAX_OUTPUT_TOKENS)" ;;
    esac
    a4_missing_list="$(printf '%s' "$a4_missing" | sed 's/^ //;s/ /, /g')"
    if [ -z "$LAYER_CTX" ] || [ ! -f "$LAYER_CTX/Containerfile" ]; then
        skip "A-4 no harness layer build context (set LAYER_BUILD_CONTEXT to the directory holding its Containerfile)"
    elif [ -n "$a4_missing" ]; then
        skip "A-4 $a4_missing_list not set, so the probe cannot supply every argument $HARNESS_ID's build requires; the row is not asserted rather than asserted over a build assembled from values it invented"
    else
        arm_args="--build-arg HARNESS_MODEL_ALIAS=$ROUTER_ALIAS --build-arg HARNESS_CONTEXT_WINDOW=$HARNESS_CONTEXT_WINDOW"
        case "$HARNESS_ID" in
            claude|omp) arm_args="$arm_args --build-arg HARNESS_FAST_ALIAS=$ROUTER_FAST_ALIAS --build-arg HARNESS_MAX_OUTPUT_TOKENS=$HARNESS_MAX_OUTPUT_TOKENS" ;;
        esac
        [ -n "${HARNESS_HOME:-}" ] && arm_args="$arm_args --build-arg HARNESS_HOME=$HARNESS_HOME"
        # shellcheck disable=SC2086
        out="$(docker build -f "$LAYER_CTX/Containerfile" -t "$PROBE_TAG" \
            --build-arg AGENT_BASE_REF="$AGENT_HOST_IMAGE" \
            --build-arg AGENT_HARNESS_ID="$HARNESS_ID" \
            --build-arg ROUTER_BASE_URL="http://127.0.0.1:1" \
            --build-arg ROUTER_CREDENTIAL_ENV="$ROUTER_CREDENTIAL_ENV" \
            --build-arg HARNESS_VERIFY_ENDPOINT=1 \
            $arm_args \
            "$LAYER_CTX" 2>&1)"
        rc=$?
        if [ $rc -eq 0 ]; then
            fail "A-4 the harness layer built with its endpoint check pointed at an endpoint nothing answers at; the check is not enforced"
        elif denied "$out"; then
            skip "A-4 build probe: docker refused the build on this host"
        elif printf '%s' "$out" | grep -q "not reachable from the build" && printf '%s' "$out" | grep -q "non-zero code: 78"; then
            pass "A-4 a harness build whose endpoint check cannot reach the router fails with the guard's code 78, naming the parameter"
        elif printf '%s' "$out" | grep -qiE 'HARNESS_FAST_ALIAS|HARNESS_MAX_OUTPUT_TOKENS|HARNESS_HOME|ROUTER_CREDENTIAL_ENV|ROUTER_BASE_URL is required|is required and was not set'; then
            fail "A-4 the probe build failed on a missing argument rather than the endpoint check: $(printf '%s' "$out" | grep -m1 'add-an-agent-harness:' | cut -c1-120)"
        else
            skip "A-4 build probe failed for an unrelated reason: $(printf '%s' "$out" | tail -1 | cut -c1-120)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-5, A-6: isolation — nothing published, nothing privileged, no socket
# ---------------------------------------------------------------------------
# Both rows are claims about EVERY container of the set, so both need every
# member's name: with one missing, the inspect covers a subset, and a subset is
# not the row — a stopped proxy that publishes a port, or one with an extra
# read-write host path, would be invisible behind a green.
set_missing=""
[ -n "${ROUTER_CONTAINER:-}" ] || set_missing="$set_missing ROUTER_CONTAINER"
[ -n "${PROXY_CONTAINER:-}" ] || set_missing="$set_missing PROXY_CONTAINER"
set_missing_list="$(printf '%s' "$set_missing" | sed 's/^ //;s/ /, /g')"
if ! command -v docker >/dev/null 2>&1; then
    skip "A-5 docker is not available"
    skip "A-6 docker is not available"
elif [ -n "$set_missing" ]; then
    skip "A-5 $set_missing_list not set, so the row cannot inspect every container of the set; nothing is asserted about the containers it did not see"
    skip "A-6 $set_missing_list not set, so the row cannot inspect every container of the set"
else
    # -a: a stopped service of the set still carries its port bindings, its
    # privileges, its devices and its mounts, and the row is specified over the
    # set, not over what happens to be up.
    containers="$(docker ps -a --format '{{.Names}}' 2>&1)"
    if denied "$containers"; then
        skip "A-5 docker refused the request on this host: $(printf '%s' "$containers" | head -1)"
        skip "A-6 docker refused the request on this host"
    else
        set_absent=""
        for c in "$HOST_CONTAINER" "$ROUTER_CONTAINER" "$PROXY_CONTAINER"; do
            printf '%s\n' "$containers" | grep -qxF "$c" || set_absent="$set_absent $c"
        done
        if [ -n "$set_absent" ]; then
            skip "A-5 not every container of the set exists on this host, running or stopped — missing:$set_absent — so the row is not asserted"
            skip "A-6 not every container of the set exists on this host, running or stopped — missing:$set_absent — so the row is not asserted"
        else
            bad_pub=""; bad_priv=""; bad_cap=""; bad_dev=""; bad_sock=""; bad_rw=""
            rw_paths=""; unreadable=""; tree_rw=0; proxy_sock=0
            # Every service of the set, the proxy included: it is the one
            # container whose socket mount is by design, so leaving it out would
            # hide both the exception and any second socket mount.
            for c in "$HOST_CONTAINER" "$ROUTER_CONTAINER" "$PROXY_CONTAINER"; do
                rec="$(docker inspect "$c" --format '{{.Name}}|ports={{json .HostConfig.PortBindings}}|priv={{.HostConfig.Privileged}}|caps={{json .HostConfig.CapAdd}}|devs={{json .HostConfig.Devices}}{{println}}{{range .Mounts}}M|{{.Source}}|{{.Destination}}|{{.RW}}{{println}}{{end}}' 2>&1)"
                case "$rec" in
                    *"priv="*) ;;
                    # An unreadable container is not a clean one: the row reports
                    # the gap rather than a green over the containers it could read.
                    *) unreadable="$unreadable $c"
                       continue ;;
                esac
                printf '%s' "$rec" | grep -q 'ports={}\|ports=null' || bad_pub="$bad_pub $c"
                printf '%s' "$rec" | grep -q 'priv=false' || bad_priv="$bad_priv $c"
                printf '%s' "$rec" | grep -q 'caps=null\|caps=\[\]' || bad_cap="$bad_cap $c"
                printf '%s' "$rec" | grep -q 'devs=\[\]\|devs=null' || bad_dev="$bad_dev $c"
                while IFS='|' read -r tag src dst rw; do
                    [ "$tag" = "M" ] || continue
                    [ -n "$src" ] || continue
                    if is_socket_mount "$src" "$dst"; then
                        # The proxy's own socket mount is the design: one mount,
                        # read-only (the Docker-access part's R-6). Anywhere else,
                        # or a writable one, is a failure — and the proxy without
                        # the socket it exists to carry is not this set either.
                        if [ "$c" = "$PROXY_CONTAINER" ] && [ "$rw" = "false" ]; then
                            proxy_sock=$((proxy_sock + 1))
                        else
                            bad_sock="$bad_sock $c"
                        fi
                    fi
                    if [ "$rw" = "true" ]; then
                        rw_paths="$rw_paths $src"
                        [ "$src" = "$AGENT_TREE_DIR" ] || bad_rw="$bad_rw $src"
                        [ "$c" = "$HOST_CONTAINER" ] && [ "$src" = "$AGENT_TREE_DIR" ] && tree_rw=1
                    fi
                done <<EOF
$rec
EOF
            done
            if [ -n "$unreadable" ]; then
                skip "A-5 docker inspect could not read:$unreadable — an unreadable container is not a clean one, so this row is not asserted"
                skip "A-6 docker inspect could not read:$unreadable — an unreadable container is not a clean one, so this row is not asserted"
            else
                [ -z "$bad_pub" ] \
                    && pass "A-5 no container of the set publishes a port" \
                    || fail "A-5 published ports on:$bad_pub"
                if [ -n "$bad_priv$bad_cap$bad_dev$bad_sock" ]; then
                    fail "A-5 forbidden properties — privileged:$bad_priv cap:$bad_cap device:$bad_dev socket:$bad_sock"
                elif [ "$proxy_sock" -ne 1 ]; then
                    fail "A-5 the proxy ($PROXY_CONTAINER) does not hold exactly one read-only Docker socket mount ($proxy_sock seen); the socket must reach that container, and no other, under the mode the Docker-access part's R-6 requires"
                else
                    pass "A-5 no container of the set is privileged, holds an added capability or device, or mounts the Docker socket — with the proxy's own single read-only socket mount as the one sanctioned exception"
                fi
                # The tree mount itself, not merely the absence of others: a set
                # whose agent state has no host path behind it would pass a check
                # that only rejects extra read-write paths.
                [ -z "$bad_rw" ] \
                    && pass "A-6 no read-write host path in the set lies outside the agent tree ($AGENT_TREE_DIR)" \
                    || fail "A-6 read-write host paths outside the agent tree:$bad_rw"
                [ "$tree_rw" -eq 1 ] \
                    && pass "A-6 the agent tree $AGENT_TREE_DIR is mounted read-write into $HOST_CONTAINER" \
                    || fail "A-6 $AGENT_TREE_DIR is not mounted read-write into $HOST_CONTAINER (read-write host paths seen:$rw_paths); the agents' state would live in the container layer"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-7: no host root — the account contract, for every container of the set
# ---------------------------------------------------------------------------
# R-4's no-host-root binds the containers built from the base whose unprivileged
# account part 1's R-1 fixes: the harness image and the agent host. The row reads
# every container of the set's process uid all the same — a container it never
# looked at is not a clean one, and A-5 covers only its privileged/capability/
# device half — and reports the containers whose own images carry root by design
# (the Docker-access part's context says of its own container: "the proxy runs as
# root inside its container") instead of failing a correct deployment over them.
if ! command -v docker >/dev/null 2>&1; then
    skip "A-7 docker is not available"
else
    img_user="$(docker image inspect "$HARNESS_IMAGE" --format '{{.Config.User}}' 2>&1)"
    if absent "$img_user"; then
        skip "A-7 $HARNESS_IMAGE is not present on this host; build it (Phase 4) or point HARNESS_IMAGE at the deployed image"
    elif denied "$img_user"; then
        skip "A-7 docker refused the request on this host"
    elif [ -z "$img_user" ] || [ "$img_user" = "<no value>" ]; then
        skip "A-7 $HARNESS_IMAGE reports no runtime account"
    elif [ "$img_user" = "root" ] || [ "$img_user" = "0" ]; then
        fail "A-7 the harness image runs as root ($img_user)"
    else
        pass "A-7 the harness image's runtime account is '$img_user', not root"
    fi
    # The images are one claim; the uid a container's process actually has is
    # another, and only the running containers can answer it.
    if [ -n "$set_missing" ]; then
        skip "A-7 $set_missing_list not set, so the process accounts of the set's containers were not inspected"
    else
        root_bad=""; uid_unreadable=""; uid_host=""; uid_other=""
        for c in "$HOST_CONTAINER" "$ROUTER_CONTAINER" "$PROXY_CONTAINER"; do
            uid="$(docker exec "$c" id -u 2>&1)"
            if denied "$uid" || absent "$uid"; then
                uid_unreadable="$uid_unreadable $c"
            elif [ "$uid" = "0" ]; then
                if [ "$c" = "$HOST_CONTAINER" ]; then root_bad="$root_bad $c"; else uid_other="$uid_other $c=0"; fi
            else
                if [ "$c" = "$HOST_CONTAINER" ]; then uid_host="$uid"; else uid_other="$uid_other $c=$uid"; fi
            fi
        done
        if [ -n "$uid_host" ]; then
            pass "A-7 the host container's process runs as uid $uid_host, not 0"
        fi
        [ -z "$root_bad" ] \
            || fail "A-7 the host container's process runs as uid 0; a pane's account is the base's unprivileged one (part 1's R-1, R-4)"
        [ -z "$uid_unreadable" ] \
            || skip "A-7 the process uid could not be read in:$uid_unreadable — an unread container is not a clean one ($(exec_reason))"
        if [ -n "$uid_other" ]; then
            note "A-7 the set's other containers' process accounts read:${uid_other# }. R-4's no-host-root binds the containers built from the base whose unprivileged account part 1's R-1 fixes (the harness image and the agent host); the Docker-access part states of its own container that the proxy runs as root inside it, and the router image declares no account, so this row does not fail those. A-5 covers their privileged, capability and device half"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-8: one harness CLI, no credential in the image
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    skip "A-8 docker is not available"
else
    env_json="$(docker image inspect "$HARNESS_IMAGE" --format '{{json .Config.Env}}' 2>&1)"
    ep_json="$(docker image inspect "$HARNESS_IMAGE" --format '{{json .Config.Entrypoint}}' 2>&1)"
    cmd_json="$(docker image inspect "$HARNESS_IMAGE" --format '{{json .Config.Cmd}}' 2>&1)"
    if absent "$env_json"; then
        skip "A-8 $HARNESS_IMAGE is not present on this host; build it (Phase 4) or point HARNESS_IMAGE at the deployed image"
    elif denied "$env_json"; then
        skip "A-8 docker refused the request on this host"
    elif [ -z "$env_json" ] || [ "$env_json" = "<no value>" ]; then
        skip "A-8 $HARNESS_IMAGE reports no environment"
    else
        # The entry has to be the WHOLE entry: `grep "AGENT_HARNESS=claude"` also
        # matches AGENT_HARNESS=claude-old, so the match is anchored to the JSON
        # array's element boundary (the array is a flat list of strings, which is
        # what Config.Env is).
        if printf '%s' "$env_json" | grep -oE '"[^"]*"' | grep -qxF "\"AGENT_HARNESS=$HARNESS_ID\""; then
            pass "A-8 AGENT_HARNESS is set to $HARNESS_ID in the image (that exact environment entry, not a longer value starting with it)"
        else
            fail "A-8 AGENT_HARNESS=$HARNESS_ID is not an environment entry of the image: $env_json"
        fi
        # Inheritance, not absence: `docker image inspect` reports the base's
        # entrypoint on every image built FROM it, so comparing against `null`
        # fails every correct layer. What matters is that this image's run
        # contract is the BASE's, unchanged — the layer part's own rule (it
        # declares no ENTRYPOINT/CMD of its own, checked from its Containerfile).
        base_ep="$(docker image inspect "$AGENT_HOST_IMAGE" --format '{{json .Config.Entrypoint}}' 2>/dev/null)"
        base_cmd="$(docker image inspect "$AGENT_HOST_IMAGE" --format '{{json .Config.Cmd}}' 2>/dev/null)"
        if [ -z "$base_ep" ]; then
            skip "A-8 entrypoint check: $AGENT_HOST_IMAGE is not present on this host, so there is nothing to compare the harness image's run contract against"
        elif [ "$ep_json" = "$base_ep" ] && [ "$cmd_json" = "$base_cmd" ]; then
            pass "A-8 the harness image's entrypoint and cmd are the base image's, unchanged ($ep_json)"
        else
            fail "A-8 the harness image's run contract differs from the base's: entrypoint=$ep_json (base $base_ep) cmd=$cmd_json (base $base_cmd)"
        fi
        history="$(docker history --no-trunc --format '{{.CreatedBy}}' "$HARNESS_IMAGE" 2>&1)"
        if denied "$history"; then
            skip "A-8 credential scan: this host refused docker history"
        else
            hits="$(printf '%s' "$history" | grep -iE '(^|[^A-Z_])(ANTHROPIC|OPENAI|GEMINI|PROVIDER)_?(API_)?(KEY|TOKEN)=[^ ]|_SECRET=|_PASSWORD=[^ ]' | head -3)"
            if [ -n "$hits" ]; then
                fail "A-8 the image history carries a credential-shaped value: $(printf '%s' "$hits" | head -1 | cut -c1-80)"
            else
                pass "A-8 the image history carries no credential-shaped value. Stated limit: a credential assembled from parts at build time is not seen by a history scan — the filesystem scan below covers the file case"
            fi
        fi
        # The filesystem, not only the history. An earlier version of this row
        # scanned history alone, which cannot see a credential COPYed in as a file
        # — the shape the layer's R-8 actually forbids. The scan is run inside a
        # container made from the image (create/start/logs, because `docker exec`
        # is denied on hosts whose daemon is behind an authorization proxy).
        cid="$(docker create --label org.testcontainers=true --entrypoint sh "$HARNESS_IMAGE" -c '
            set -u
            H="${CLAUDE_CONFIG_DIR:-${CODEX_HOME:-}}"
            found=""
            for d in "$H" /home/* /root; do
                [ -n "$d" ] && [ -d "$d" ] || continue
                found="$found$(find "$d" -maxdepth 3 -type f \( -name auth.json -o -name credentials.json -o -name "*.credentials*" -o -name .env -o -name "*.pem" -o -name "id_rsa" -o -name id_ed25519 \) 2>/dev/null | head -5)
"
            done
            for f in "$HOME/.aws/credentials" "$HOME/.netrc" "$HOME/.npmrc" "$HOME/.git-credentials" "$HOME/.docker/config.json" "$HOME/.config/gh/hosts.yml"; do
                [ -f "$f" ] && found="$found$f
"
            done
            for d in "$H" "$HOME/.aws" "$HOME/.ssh"; do
                [ -d "$d" ] || continue
                found="$found$(grep -rlE "sk-[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|_TOKEN=[A-Za-z0-9_-]{16,}|_API_KEY=[A-Za-z0-9_-]{16,}" "$d" 2>/dev/null | head -5)
"
            done
            printf "SCAN|%s\n" "$(printf "%s" "$found" | tr "\n" " " | sed "s/  */ /g")"
        ' 2>&1)"
        if absent "$cid" || denied "$cid"; then
            skip "A-8 filesystem scan: docker refused to create a container from the image"
        else
            docker start "$cid" >/dev/null 2>&1
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "false" ] && break
                sleep 1
            done
            # The result line's PRESENCE and its CONTENT are two different
            # answers: a clean scan prints `SCAN|` with an empty payload, so
            # taking the payload alone made a clean image indistinguishable from
            # a container that printed nothing at all — and left the PASS branch
            # below unreachable for every clean image.
            scan_line="$(docker logs "$cid" 2>&1 | grep -m1 '^SCAN|' || true)"
            docker rm -f "$cid" >/dev/null 2>&1
            scan_log="${scan_line#SCAN|}"
            scan_hits="$(printf '%s' "$scan_log" | tr -d ' \t')"
            if [ -z "$scan_line" ]; then
                skip "A-8 filesystem scan produced no result line (the container reported nothing)"
            elif [ -z "$scan_hits" ]; then
                pass "A-8 the image's filesystem holds no credential-shaped file or value, scanned inside the image itself (the harness configuration directory and every account home). Stated limit: a value written in one layer and deleted in a later one is absent from this filesystem while remaining in the earlier layer's tar"
            else
                fail "A-8 the image's filesystem holds credential-shaped content: $scan_log"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-9: an agent pane runs the harness CLI, in its own workspace
# ---------------------------------------------------------------------------
# The multiplexer gives each pane its own workspace — AGENT_TREE/<id>/workspace
# (its R-3, and `agent-loop.sh` exports it as AGENT_WORKSPACE_DIR) — so there is
# no one path every pane shares: comparing all of them against a single default
# would fail a correct deployment and pass a pane that ran anywhere the operator
# happened to name. The row reads each pane's own variable and requires its
# working directory to be exactly that, and that path to be a rostered agent's
# workspace under the tree.
if ! command -v docker >/dev/null 2>&1; then
    skip "A-9 docker is not available"
else
    panes="$(docker exec "$HOST_CONTAINER" sh -c '
        for p in /proc/[0-9]*; do
            pid="${p#/proc/}"
            [ "$pid" = "1" ] && continue
            [ "$pid" = "$$" ] && continue
            cmd="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
            case "$cmd" in
                *"'"$HARNESS_ID"'"*)
                    ws="$(tr "\0" "\n" < "$p/environ" 2>/dev/null | sed -n "s/^AGENT_WORKSPACE_DIR=//p" | head -1)"
                    printf "%s|%s|%s|%s\n" "$pid" "$(readlink "$p/cwd" 2>/dev/null)" "$ws" "$cmd" ;;
            esac
        done' 2>&1)"
    if denied "$panes"; then
        skip "A-9 $(exec_reason)"
    elif [ -z "$panes" ]; then
        fail "A-9 no process in $HOST_CONTAINER runs $HARNESS_ID; the panes are not running the harness"
    else
        n="$(printf '%s\n' "$panes" | wc -l | tr -d ' ')"
        pass "A-9 $n process(es) in $HOST_CONTAINER run $HARNESS_ID (a pane's process tree contains the harness)"
        pane_bad=""
        while IFS='|' read -r pid cwd ws cmd; do
            [ -n "$pid" ] || continue
            if [ -z "$ws" ]; then
                pane_bad="$pane_bad ${pid}(no AGENT_WORKSPACE_DIR)"
                continue
            fi
            if [ -n "$AGENT_WORKSPACE_DIR" ]; then
                case "$ws" in
                    "$AGENT_WORKSPACE_DIR"|"$AGENT_WORKSPACE_DIR"/*) ;;
                    *) pane_bad="$pane_bad ${pid}($ws is outside $AGENT_WORKSPACE_DIR)"; continue ;;
                esac
            fi
            case "$ws" in
                */workspace) ;;
                *) pane_bad="$pane_bad ${pid}($ws is not a per-agent workspace)"; continue ;;
            esac
            ws_id="${ws%/workspace}"; ws_id="${ws_id##*/}"
            case " $AGENT_ID_LIST " in
                *" $ws_id "*) ;;
                *) pane_bad="$pane_bad ${pid}($ws_id is not one of the host's agents)"; continue ;;
            esac
            [ "$cwd" = "$ws" ] || pane_bad="$pane_bad ${pid}(cwd $cwd, workspace $ws)"
        done <<EOF
$panes
EOF
        [ -z "$pane_bad" ] \
            && pass "A-9 every harness process runs in its own agent workspace, the AGENT_WORKSPACE_DIR that pane was given (<tree>/<id>/workspace for a rostered id)" \
            || fail "A-9 harness process(es) not in their own agent workspace:$pane_bad"
    fi
fi

# ---------------------------------------------------------------------------
# A-10: the pane's environment and configuration carry the wiring
# ---------------------------------------------------------------------------
# The endpoint is not an environment variable of this composition: the harness
# layer writes it into the arm's own configuration file (ANTHROPIC_BASE_URL for
# Claude Code, base_url for Codex) and the host fragment adds no ROUTER_BASE_URL
# of its own, so requiring that variable of the process would fail a set that is
# wired exactly as specified. What the process must carry is the credential —
# and no second credential, because `sops exec-env` injects every entry of the
# encrypted store into it — while the endpoint and the aliases are read where
# the CLI reads them, from its configuration.
if ! command -v docker >/dev/null 2>&1; then
    skip "A-10 docker is not available"
else
    wire="$(docker exec -e CRED_NAME="$CREDENTIAL_ENV" -e CFG="$HARNESS_CONFIG_PATH" "$HOST_CONTAINER" sh -c '
        pane=""
        for p in /proc/[0-9]*; do
            cmd="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
            case "$cmd" in
                *"'"$HARNESS_ID"'"*) pane="$p"; break ;;
            esac
        done
        [ -n "$pane" ] || { printf "NO_PANE\n"; exit 0; }
        # Names only: which variables the pane carries, never what they hold.
        names="$(tr "\0" "\n" < "$pane/environ" 2>/dev/null | sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p")"
        printf "VARIABLES_READ=%s\n" "$(printf "%s\n" "$names" | grep -c .)"
        if printf "%s\n" "$names" | grep -qxF "$CRED_NAME"; then printf "CREDENTIAL_PRESENT=yes\n"; else printf "CREDENTIAL_PRESENT=no\n"; fi
        printf "%s\n" "$names" | grep -xE "([A-Za-z0-9]+_)*(API_)?(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|CREDENTIALS)" | grep -vxF "$CRED_NAME" | sed "s/^/OTHER_CREDENTIAL=/"
        env_ep="$(tr "\0" "\n" < "$pane/environ" 2>/dev/null | sed -n "s/^ROUTER_BASE_URL=//p" | head -1)"
        [ -n "$env_ep" ] && printf "ENDPOINT_ENV=%s\n" "$env_ep"
        [ -f "$CFG" ] && printf "CONFIG_PRESENT=%s\n" "$CFG"
        exit 0' 2>&1)"
    if denied "$wire"; then
        skip "A-10 $(exec_reason)"
    elif printf '%s' "$wire" | grep -q "^NO_PANE"; then
        fail "A-10 no process in $HOST_CONTAINER runs $HARNESS_ID, so there is no pane environment to read (A-9 selects the same processes)"
    else
        vars="$(printf '%s' "$wire" | sed -n 's/^VARIABLES_READ=//p' | head -1)"
        if [ -z "$vars" ] || [ "$vars" = "0" ]; then
            fail "A-10 the pane's environment could not be read in $HOST_CONTAINER (${vars:-no count} variables); an unreadable environment is not an unwired one"
        else
            printf '%s' "$wire" | grep -q "^CREDENTIAL_PRESENT=yes" \
                && pass "A-10 the pane's process carries $CREDENTIAL_ENV (presence only; the value is never read out here)" \
                || fail "A-10 the pane's process has no $CREDENTIAL_ENV (the name this arm's CLI reads)"
            other="$(printf '%s' "$wire" | sed -n 's/^OTHER_CREDENTIAL=//p' | tr '\n' ' ')"
            [ -z "$other" ] \
                && pass "A-10 the pane's process carries no other credential-shaped variable; $CREDENTIAL_ENV is the only one (a second entry in the encrypted store, or a provider key, would appear here)" \
                || fail "A-10 the pane's process carries credential-shaped variable(s) besides $CREDENTIAL_ENV:$other — a pane may hold no credential but the router's"
            if printf '%s' "$wire" | grep -q "^ENDPOINT_ENV="; then
                env_ep="$(printf '%s' "$wire" | sed -n 's/^ENDPOINT_ENV=//p' | head -1)"
                [ "$env_ep" = "$ROUTER_ROOT" ] \
                    && pass "A-10 the pane's process carries ROUTER_BASE_URL=$env_ep, the P-8 root" \
                    || fail "A-10 the pane's process carries ROUTER_BASE_URL=$env_ep, not P-8's root $ROUTER_ROOT"
            else
                note "A-10 the pane's process carries no ROUTER_BASE_URL; this composition's endpoint lives in the CLI's own configuration instead, read below"
            fi
        fi
        # P-7 may name more than one file: the omp arm's layout splits the roles
        # from the endpoint and the model metadata. EVERY named path is read, into
        # one blob, which is what the per-arm key readers below scan — and every
        # path has to be readable, because one that is not would make those readers
        # report the keys it holds as absent from a configuration whose other file
        # read fine. That is a finding about a deployment that does not exist: the
        # defect would be the unreadable path, named by P-21.
        cfg=""; cfg_unreadable=""
        for _p in $HARNESS_CONFIG_PATH; do
            _c="$(docker exec "$HOST_CONTAINER" cat "$_p" 2>/dev/null)"
            if [ -n "$_c" ]; then
                cfg="$cfg
$_c"
            else
                cfg_unreadable="$cfg_unreadable $_p"
            fi
        done
        if [ -n "$cfg_unreadable" ]; then
            skip "A-10 configuration check: not readable (or empty) inside $HOST_CONTAINER:$cfg_unreadable — P-21 names every file this arm's CLI reads, so the check is not asserted over the paths it could read"
        else
            forbidden="$(printf '%s' "$cfg" | grep -oE '(sk-[A-Za-z0-9_-]{8,}|ANTHROPIC_API_KEY|OPENAI_API_KEY|GEMINI_API_KEY)' | head -1)"
            if [ -n "$forbidden" ]; then
                fail "A-10 the harness configuration names a provider credential or key ($forbidden); it may name only aliases"
            else
                pass "A-10 the harness configuration names no provider credential or key"
            fi
            # P-8 against the arm's own keys, and P-10/P-11/P-12 for every model
            # it names. The keys differ per arm because the layer writes the
            # arm's own file: Claude Code's settings.json under `env`, Codex's
            # config.toml as TOML keys, the omp arm's YAML across the two files
            # P-7 names.
            # model_prefix is the spelling the arm's roles take inside its file:
            # the omp arm's role values read `router/<alias>`, so the compares
            # below carry the prefix and the alias-set check strips it.
            model_prefix=""
            case "$HARNESS_ID" in
                claude) ep_key="ANTHROPIC_BASE_URL"; model_key="ANTHROPIC_MODEL"; fast_key="ANTHROPIC_DEFAULT_HAIKU_MODEL"; cred_key=""; want_endpoint="$ROUTER_ROOT" ;;
                omp)    ep_key="baseUrl"; model_key="default"; fast_key="smol"; cred_key="apiKey"; want_endpoint="$ROUTER_ROOT/v1"; model_prefix="router/" ;;
                *)      ep_key="base_url"; model_key="model"; fast_key=""; cred_key="env_key"; want_endpoint="$ROUTER_ROOT/v1" ;;
            esac
            got_endpoint="$(cfg_value "$cfg" "$ep_key")"
            [ "$got_endpoint" = "$want_endpoint" ] \
                && pass "A-10 the harness configuration's $ep_key is $want_endpoint, the endpoint P-8 fixes for this arm" \
                || fail "A-10 the harness configuration's $ep_key is '${got_endpoint:-absent}', not the endpoint P-8 fixes for this arm ($want_endpoint): the pane is wired elsewhere"
            want_model="${model_prefix}$ROUTER_ALIAS"
            got_model="$(cfg_value "$cfg" "$model_key")"
            [ "$got_model" = "$want_model" ] \
                && pass "A-10 the harness configuration's $model_key is $want_model, P-10's alias" \
                || fail "A-10 the harness configuration's $model_key is '${got_model:-absent}', not P-10's alias $want_model"
            alias_bad=""
            for key in "$model_key" $fast_key; do
                val="$(cfg_value "$cfg" "$key")"
                [ -n "$val" ] || continue
                # The alias-set check sees the alias itself, not the file's
                # spelling of it: the omp arm writes `router/<alias>`.
                case "$val" in "$model_prefix"*) val="${val#"$model_prefix"}" ;; esac
                case " $ALIAS_SET_LIST " in
                    *" $val "*) ;;
                    *) alias_bad="$alias_bad $key=$val" ;;
                esac
            done
            [ -z "$alias_bad" ] \
                && pass "A-10 every model the harness configuration names is a member of P-11's alias set" \
                || fail "A-10 the harness configuration names model(s) outside ROUTER_ALIAS_SET:$alias_bad"
            if [ -n "$fast_key" ] && [ -n "${ROUTER_FAST_ALIAS:-}" ]; then
                got_fast="$(cfg_value "$cfg" "$fast_key")"
                [ "$got_fast" = "${model_prefix}$ROUTER_FAST_ALIAS" ] \
                    && pass "A-10 the harness configuration's $fast_key is ${model_prefix}$ROUTER_FAST_ALIAS, P-12's alias" \
                    || fail "A-10 the harness configuration's $fast_key is '${got_fast:-absent}', not P-12's alias ${model_prefix}$ROUTER_FAST_ALIAS (the spelling the file carries for this arm)"
            fi
            if [ -n "$cred_key" ]; then
                got_cred="$(cfg_value "$cfg" "$cred_key")"
                [ "$got_cred" = "$CREDENTIAL_ENV" ] \
                    && pass "A-10 the harness configuration reads its credential from $CREDENTIAL_ENV, the name the layer records for this arm" \
                    || fail "A-10 the harness configuration's $cred_key is '${got_cred:-absent}', not this arm's credential variable $CREDENTIAL_ENV"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-11: a request from the pane reaches the router by alias
# ---------------------------------------------------------------------------
# P-8 is the ROOT; the models endpoint is <root>/v1/models, which is the path
# the harness layer's own P-11 check reads at build time.
#
# The credential is read out of the PANE's own process environment: a fresh
# `docker exec` shell gets the container's configuration environment, not the
# boot process's, so an exec'd `printenv` finds nothing even in a set where the
# store injected the credential correctly. The value stays inside the container
# — it is used by the request and never printed. The request is issued from
# inside that container, which runs the panes: a portable check cannot drive an
# interactive CLI, so the pane ITSELF is what A-9 and A-10 prove.
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    skip "A-11 docker is not available"
else
    code="$(docker exec -e CRED_NAME="$CREDENTIAL_ENV" "$HOST_CONTAINER" sh -c '
        v=""
        for p in /proc/[0-9]*; do
            cmd="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
            case "$cmd" in
                *"'"$HARNESS_ID"'"*)
                    v="$(tr "\0" "\n" < "$p/environ" 2>/dev/null | sed -n "s/^${CRED_NAME}=//p" | head -1)"
                    [ -n "$v" ] && break ;;
            esac
        done
        [ -n "$v" ] || { echo "NO_CREDENTIAL"; exit 0; }
        curl -s -o /tmp/agent-set-models -w "%{http_code}" -H "Authorization: Bearer $v" "'"$MODELS_URL"'"' 2>&1 | tail -1)"
    if denied "$code"; then
        skip "A-11 $(exec_reason)"
    elif [ "$code" = "NO_CREDENTIAL" ]; then
        skip "A-11 the pane's process carries no $CREDENTIAL_ENV, so no authenticated request can be made; the store did not inject it (P-20's store, not the chain)"
    elif [ "$code" = "200" ]; then
        body="$(docker exec "$HOST_CONTAINER" cat /tmp/agent-set-models 2>/dev/null)"
        # The model list's ids, by field: a raw-body grep for the alias also
        # matches a provider name or any other metadata that happens to carry it.
        ids="$(printf '%s' "$body" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//')"
        if [ -z "$ids" ]; then
            skip "A-11 the model list's id values could not be read from the answer, so alias membership is not asserted: $(printf '%s' "$body" | tr -d '\n' | cut -c1-80)"
        elif printf '%s\n' "$ids" | grep -qxF "$ROUTER_ALIAS"; then
            pass "A-11 a request from inside $HOST_CONTAINER (the container the panes run in) to $MODELS_URL returns 200 and the model list's ids include '$ROUTER_ALIAS'"
        else
            fail "A-11 the router answered 200 but the model list's ids do not include '$ROUTER_ALIAS' (ids read: $(printf '%s' "$ids" | tr '\n' ' '))"
        fi
        nocode="$(docker exec "$HOST_CONTAINER" sh -c 'curl -s -o /dev/null -w "%{http_code}" "'"$MODELS_URL"'"' 2>/dev/null | tail -1)"
        case "$nocode" in
            401|403) pass "A-11 a request without the router credential is rejected ($nocode)" ;;
            "") skip "A-11 credential-refusal check: no answer from the router" ;;
            *) fail "A-11 a request without the router credential returned $nocode, not 401/403" ;;
        esac
    else
        fail "A-11 the request from $HOST_CONTAINER to $MODELS_URL returned '$code', not 200"
    fi
fi

# ---------------------------------------------------------------------------
# A-12: with the router unreachable the request fails visibly, with no fallback
# ---------------------------------------------------------------------------
if [ "${ALLOW_ROUTER_STOP:-0}" != "1" ]; then
    skip "A-12 not enabled (set ALLOW_ROUTER_STOP=1; it stops the router, tests, and starts it again)"
elif [ -z "${ROUTER_CONTAINER:-}" ]; then
    skip "A-12 ROUTER_CONTAINER is not set"
else
    docker stop "$ROUTER_CONTAINER" >/dev/null 2>&1
    stopped=$?
    # The real models path, not <root>/models: this router serves <root>/v1/…, so
    # the shorter path would test a route that does not exist and could report
    # the edge it exists for (and its opposite) for the wrong reason.
    out="$(docker exec "$HOST_CONTAINER" sh -c 'curl -sS -m 10 "'"$MODELS_URL"'" 2>&1' 2>&1)"
    rc=$?
    # Putting the set back is part of the row: a restart that fails leaves the
    # deployment worse than the row found it, and the previous version ignored
    # this result and could print PASS over a router it left stopped.
    start_out="$(docker start "$ROUTER_CONTAINER" 2>&1)"; start_rc=$?
    running="$(docker inspect "$ROUTER_CONTAINER" --format '{{.State.Running}}' 2>&1)"
    if [ "$stopped" -ne 0 ]; then
        skip "A-12 could not stop $ROUTER_CONTAINER on this host"
    elif [ "$start_rc" -ne 0 ] || [ "$running" != "true" ]; then
        fail "A-12 the router did not come back: docker start exited $start_rc and the container reports Running=$running ($(printf '%s' "$start_out" | tail -1 | cut -c1-70)) — start it again before leaving this host"
    elif [ "$rc" -eq 0 ]; then
        fail "A-12 the request succeeded while the router was stopped: another provider answered"
    else
        pass "A-12 with the router stopped the request to $MODELS_URL fails visibly ($(printf '%s' "$out" | tail -1 | cut -c1-60)) and no other provider answers"
    fi
fi

# ---------------------------------------------------------------------------
# A-13: Docker access goes through the proxy, and the socket is not reachable
# ---------------------------------------------------------------------------
# The row's own expectation includes the network contract — Docker works through
# the proxy AND the proxy is not exposed to the rest of the set — so it needs
# both container names: without the proxy's there is nothing to inspect, and
# without the router's the half that proves a service of the set cannot reach
# the proxy would be dropped behind a green. Either way the row prints SKIP
# instead of a partial pass.
a13_missing=""
[ -n "${PROXY_CONTAINER:-}" ] || a13_missing="$a13_missing PROXY_CONTAINER"
[ -n "${ROUTER_CONTAINER:-}" ] || a13_missing="$a13_missing ROUTER_CONTAINER"
a13_missing_list="$(printf '%s' "$a13_missing" | sed 's/^ //;s/ /, /g')"
if ! command -v docker >/dev/null 2>&1; then
    skip "A-13 docker is not available"
elif [ -n "$a13_missing" ]; then
    skip "A-13 $a13_missing_list not set, so the proxy's network contract cannot be inspected; the row is not asserted rather than reported green without it"
else
    ver="$(docker exec "$HOST_CONTAINER" sh -c 'docker version --format "{{.Server.Version}}" 2>&1' 2>&1)"
    # DOCKER_HOST is READ from the container, never injected: the wiring this row
    # exists for is whether the deployment's copy of the host fragment sets it
    # (the shipped copy ships it commented out), and an injected `-e` proves only
    # that the proxy answers — a host with no wiring at all would pass. A pane's
    # process is what the agents actually use, so it is read first; the
    # container's own configured environment is the fallback for a host whose
    # panes are not up yet.
    host_dh="$(docker exec "$HOST_CONTAINER" sh -c '
        v="${DOCKER_HOST:-}"
        if [ -z "$v" ]; then
            v="$(tr "\0" "\n" < /proc/1/environ 2>/dev/null | sed -n "s/^DOCKER_HOST=//p" | head -1)"
        fi
        printf "%s" "$v"' 2>&1)"
    if denied "$host_dh" || absent "$host_dh"; then
        skip "A-13 $(exec_reason)"
    elif [ -z "$host_dh" ]; then
        fail "A-13 $HOST_CONTAINER carries no DOCKER_HOST, so nothing in it can reach the Docker daemon: the deployment's copy of the host fragment left it unset (the shipped copy ships it commented out — see compose.yaml.schema, The host-fragment contract)"
    elif [ "$host_dh" != "$DOCKER_PROXY_URL" ]; then
        fail "A-13 $HOST_CONTAINER's DOCKER_HOST is '$host_dh' while P-15 (DOCKER_PROXY_URL) is '$DOCKER_PROXY_URL': the container and the parameter name different endpoints"
    elif ! printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+'; then
        skip "A-13 the container's docker client reached no daemon through its own DOCKER_HOST ($host_dh): $(printf '%s' "$ver" | tail -1 | cut -c1-80)"
    else
        # This is also the host container's half of the resolution contract: its
        # client resolves the proxy's name out of its own DOCKER_HOST.
        pass "A-13 the host container's own DOCKER_HOST ($host_dh) reaches the Docker daemon (server $ver)"
        sock="$(docker exec "$HOST_CONTAINER" sh -c 'ls -l /var/run/docker.sock 2>&1 || true' 2>/dev/null)"
        case "$sock" in
            *"No such file"*|"") pass "A-13 no Docker socket is present in the container's filesystem" ;;
            *) fail "A-13 a Docker socket is present in the container: $sock" ;;
        esac
        deny="$(docker exec "$HOST_CONTAINER" sh -c 'docker run --rm --privileged '"${HARNESS_IMAGE}"' true 2>&1 | tail -2' 2>&1)"
        case "$deny" in
            *"failed to connect"*|*"Cannot connect"*|*"cannot connect"*|*"no such file"*)
                skip "A-13 deny check: the probe reached no daemon through the proxy, so this row cannot see what the proxy answered" ;;
            # Only a refusal that names the proxy's own decision counts. Any other
            # daemon error (a missing image, a build failure, a timeout) is not
            # evidence that the allowlist refused anything, and treating it as one
            # would let a broken deployment satisfy this row.
            *denied*|*"not allowed"*|*"not permitted"*|*"forbidden"*|*Forbidden*|*"not authorized"*|*403*)
                pass "A-13 the proxy refuses a verb outside the allowlist ($DOCKER_PROXY_ALLOWLIST): $(printf '%s' "$deny" | tail -1 | cut -c1-70)" ;;
            "") skip "A-13 deny check: no answer from the proxy" ;;
            *) skip "A-13 deny check: the probe's answer is not a refusal this row can attribute to the proxy, so it is not evidence: $(printf '%s' "$deny" | tail -1 | cut -c1-90)" ;;
        esac
        # The proxy's own reach: it must sit on an internal network only, and the
        # set's other services must not be on it. A proxy attached to the set's
        # network puts an unauthenticated daemon port in front of every service —
        # which is what the Docker-access part's own isolation module forbids.
        if absent "$(docker inspect "$PROXY_CONTAINER" --format '{{.Id}}' 2>&1)"; then
            skip "A-13 proxy network check: no container named $PROXY_CONTAINER"
        else
            nets="$(docker inspect "$PROXY_CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}' 2>/dev/null | tr -d '\r')"
            external=""
            for n in $nets; do
                internal="$(docker network inspect "$n" --format '{{.Internal}}' 2>/dev/null)"
                [ "$internal" = "true" ] || external="$external $n"
            done
            if [ -z "$nets" ]; then
                fail "A-13 the proxy container is attached to no network"
            elif [ -n "$external" ]; then
                fail "A-13 the proxy is attached to a network that is not internal:$external — every service on it can reach the daemon port"
            else
                pass "A-13 the proxy is attached only to internal network(s): $(printf '%s' "$nets" | tr '\n' ' ')"
            fi
            # A refusal from `docker exec` is not a name that does not resolve:
            # the pass is only printed when the name was actually looked up and
            # came back empty.
            res="$(docker exec "$ROUTER_CONTAINER" sh -c 'getent hosts '"$PROXY_CONTAINER"' 2>&1' 2>&1)"; res_rc=$?
            if [ "$res_rc" -eq 0 ]; then
                fail "A-13 the router container resolves the proxy by name, so it shares the proxy's network: the set's services must not"
            elif printf '%s' "$res" | grep -qiE 'not found|not running|denied|permission|cannot connect'; then
                skip "A-13 router-resolution check: the router container's name lookup could not be read: $(printf '%s' "$res" | tail -1 | cut -c1-80)"
            else
                pass "A-13 the router container cannot resolve the proxy by name (it is not on the proxy's network)"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-14: the store fails loudly when its key is missing
# ---------------------------------------------------------------------------
if [ "${ALLOW_CONTAINER_PROBE:-0}" != "1" ]; then
    skip "A-14 not enabled (set ALLOW_CONTAINER_PROBE=1; it creates one short-lived container)"
elif ! command -v docker >/dev/null 2>&1; then
    skip "A-14 docker is not available"
else
    # The container runs the composition's own boot command — `sops exec-env
    # <file> <program>` — with a key file that does not exist, which is the
    # failure a deployment hits when the key material never arrived. Stated limit:
    # this exercises the wrapper and sops, not the deployment's encrypted file,
    # which needs the real key.
    # The key path the probe hands sops must not exist, and the row accepts only
    # a failure that names THAT path: the probe also points at an encrypted file
    # it cannot open, so a message about the file is indistinguishable from one
    # about the key — and accepting both would let this row pass without ever
    # touching the key path it is about.
    A14_KEY="/run/secrets/agent-set-verify-missing-key"
    PROBE_CID="$(docker create --label org.testcontainers=true --name "agent-set-verify-probe-$$" \
        --entrypoint sh \
        -e SOPS_AGE_KEY_FILE="$A14_KEY" \
        "$HARNESS_IMAGE" \
        -c 'exec sops exec-env /run/secrets/agent-set-verify-missing.env /usr/local/bin/agent-host-boot' 2>&1)"
    if denied "$PROBE_CID" || [ -z "$PROBE_CID" ]; then
        PROBE_CID=""
        skip "A-14 this host refused to create the probe container"
    else
        docker start "$PROBE_CID" >/dev/null 2>&1
        rc=""
        i=0
        while [ "$i" -lt 30 ]; do
            state="$(docker inspect "$PROBE_CID" --format '{{.State.Status}}|{{.State.ExitCode}}' 2>/dev/null)"
            case "$state" in
                exited*) rc="${state#*|}"; break ;;
            esac
            i=$((i + 1)); sleep 1
        done
        # The log has to be read while the container still exists: removing it
        # first left `docker logs` with nothing to read, so a genuine failure was
        # downgraded to a skip.
        logs="$(docker logs "$PROBE_CID" 2>/dev/null | tail -5)"
        docker rm -f "$PROBE_CID" >/dev/null 2>&1; PROBE_CID=""
        if [ -z "$rc" ]; then
            fail "A-14 a container started without its key material kept running; the store's failure is not loud"
        elif [ "$rc" = "0" ]; then
            fail "A-14 a container started without its key material exited 0; the credential path failed silently"
        elif [ -n "$logs" ] && printf '%s' "$logs" | grep -qF "$A14_KEY"; then
            pass "A-14 a container started without its key material exits $rc, and its own output names the key file it was given ($(printf '%s' "$logs" | tail -1 | cut -c1-60))"
        elif [ -n "$logs" ] && printf '%s' "$logs" | grep -qiE 'failed to load age identities|no identities|age: error'; then
            pass "A-14 a container started without its key material exits $rc, and its own output names the missing age identities ($(printf '%s' "$logs" | tail -1 | cut -c1-60))"
        else
            skip "A-14 the probe exited $rc without naming the key path it was given ($A14_KEY), so its failure cannot be attributed to the key: $(printf '%s' "$logs" | tail -1 | cut -c1-60)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-15: one real completion through the alias — skipped without a credential
# ---------------------------------------------------------------------------
if [ "${PROVIDER_CREDENTIAL:-0}" != "1" ]; then
    skip "A-15 no real provider credential is configured for this run (set PROVIDER_CREDENTIAL=1 to attempt one completion)"
elif ! command -v docker >/dev/null 2>&1; then
    skip "A-15 docker is not available"
else
    # The credential comes out of the PANE's process environment, not out of a
    # fresh exec shell's: `docker exec` starts with the container's configuration
    # environment, which never holds what `sops exec-env` injected into the boot
    # process, so the old form sent an empty bearer token and failed a set that
    # was correctly wired. The value stays inside the container.
    code="$(docker exec -e CRED_NAME="$CREDENTIAL_ENV" -e ALIAS="$ROUTER_ALIAS" "$HOST_CONTAINER" sh -c '
        v=""
        for p in /proc/[0-9]*; do
            cmd="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
            case "$cmd" in
                *"'"$HARNESS_ID"'"*)
                    v="$(tr "\0" "\n" < "$p/environ" 2>/dev/null | sed -n "s/^${CRED_NAME}=//p" | head -1)"
                    [ -n "$v" ] && break ;;
            esac
        done
        [ -n "$v" ] || { echo "NO_CREDENTIAL"; exit 0; }
        curl -s -o /tmp/agent-set-completion -w "%{http_code}" -X POST "'"$ROUTER_ROOT"'/v1/chat/completions" \
            -H "Authorization: Bearer $v" -H "Content-Type: application/json" \
            -d "{\"model\":\"$ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: ok\"}],\"max_tokens\":8}"' 2>&1 | tail -1)"
    if denied "$code"; then
        skip "A-15 $(exec_reason)"
    elif [ "$code" = "NO_CREDENTIAL" ]; then
        skip "A-15 the pane's process carries no $CREDENTIAL_ENV, so no authenticated completion can be made (the store did not inject it); the alias path is still proven by A-11"
    elif [ "$code" = "200" ]; then
        # 200 alone is not a completion: a proxy, a landing page or an error
        # handler answers 200 too. The body was written inside the container by
        # the probe above, so it is read back and required to carry the API's own
        # `choices`.
        body="$(docker exec "$HOST_CONTAINER" sh -c 'cat /tmp/agent-set-completion 2>/dev/null' 2>&1)"
        if printf '%s' "$body" | grep -q '"choices"'; then
            pass "A-15 one real completion through the alias '$ROUTER_ALIAS' returns 200 with a completion body, made with the credential the pane's own process carries. Stated limit: this exercises the router's own path to its provider, not the harness CLI's interactive call"
        else
            fail "A-15 the request through alias '$ROUTER_ALIAS' returned 200 but the body carries no \"choices\", so it is not a completion: $(printf '%s' "$body" | tr -d '\n' | cut -c1-90)"
        fi
    else
        fail "A-15 the completion through alias '$ROUTER_ALIAS' returned '$code', not 200"
    fi
fi

# ---------------------------------------------------------------------------
# A-16: removal detaches the composition and changes no part
# ---------------------------------------------------------------------------
if [ "${ALLOW_TEARDOWN:-0}" != "1" ]; then
    skip "A-16 not enabled (set ALLOW_TEARDOWN=1; it brings the set down before re-checking the parts)"
else
    if [ -n "${COMPOSE_FILES:-}" ] && command -v docker >/dev/null 2>&1; then
        args=""
        for f in $COMPOSE_FILES; do args="$args -f $f"; done
        down_out="$(docker compose $args down 2>&1)"; down_rc=$?
        # Teardown is what this row is about, so the composition's own command
        # failing is a FAIL rather than a note: every observation below would
        # otherwise be about a teardown that did not complete.
        if [ "$down_rc" -eq 0 ]; then
            pass "A-16 docker compose down exited 0"
        else
            fail "A-16 docker compose down exited $down_rc: $(printf '%s' "$down_out" | tail -1 | cut -c1-100)"
        fi
        # The network removal's own status is part of the row: a refusal here means
        # the network survived the teardown, which the previous version of this row
        # reported as removed because it never looked.
        # The absence has to be OBSERVED, not inferred from a failed command: a
        # refused or unreachable daemon answers the same way a removed network
        # does, and calling that "gone" is exactly the pass this row must not
        # invent. Only the daemon's own not-found answer counts.
        rm_out="$(docker network rm "$AGENT_SET_NETWORK" 2>&1)"; rm_rc=$?
        insp="$(docker network inspect "$AGENT_SET_NETWORK" 2>&1)"; insp_rc=$?
        if [ "$insp_rc" -eq 0 ]; then
            fail "A-16 the network $AGENT_SET_NETWORK still exists after teardown (docker network rm exited $rm_rc: $(printf '%s' "$rm_out" | tail -1 | cut -c1-80))"
        elif printf '%s' "$insp" | grep -qiE 'no such network|network .* not found|not found'; then
            pass "A-16 the network $AGENT_SET_NETWORK is gone (docker network rm exited $rm_rc)"
        else
            skip "A-16 the network's absence could not be observed: $(printf '%s' "$insp" | tail -1 | cut -c1-90) — a refused or unreachable daemon is not a removal"
        fi
        # -a, and the proxy included: a stopped leftover is still a container the
        # teardown failed to detach, and the proxy is a service of the set. An
        # unreadable list is a gap, never "no container remains".
        if [ -n "$set_missing" ]; then
            skip "A-16 container check: $set_missing_list not set, so the set's completeness after teardown cannot be asserted"
        else
            left_all="$(docker ps -a --format '{{.Names}}' 2>&1)"; left_rc=$?
            if [ "$left_rc" -ne 0 ]; then
                skip "A-16 the container list could not be read after teardown: $(printf '%s' "$left_all" | tail -1 | cut -c1-90)"
            else
                left="$(printf '%s\n' "$left_all" | grep -E "^(${HOST_CONTAINER}|${ROUTER_CONTAINER}|${PROXY_CONTAINER})$" || true)"
                [ -z "$left" ] \
                    && pass "A-16 no container of the set remains, running or stopped (host, router, proxy)" \
                    || fail "A-16 containers still present after teardown: $(printf '%s' "$left" | tr '\n' ' ')"
            fi
        fi
    else
        skip "A-16 no COMPOSE_FILES supplied, so this row cannot detach the composition; the tree and part checks below still run"
    fi
    tree_ok=1
    [ -d "$AGENT_TREE_DIR" ] || tree_ok=0
    [ "$tree_ok" = "1" ] \
        && pass "A-16 the agent tree is still present and was not touched by the teardown" \
        || fail "A-16 the agent tree at $AGENT_TREE_DIR is gone; removal must not delete agent state"
    if [ -n "${PART_SCRIPTS:-}" ]; then
        for entry in $PART_SCRIPTS; do
            name="${entry%%:*}"; script="${entry#*:}"
            if [ ! -x "$script" ]; then
                fail "A-16 $name: no executable acceptance script at $script, so the part cannot be re-checked after the teardown"
                continue
            fi
            if bash "$script" >/dev/null 2>&1; then
                pass "A-16 $name still passes its own acceptance script after the teardown"
            else
                fail "A-16 $name no longer passes after the teardown; removal changed a part"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
verdict
