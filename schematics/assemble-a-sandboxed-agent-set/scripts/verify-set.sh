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
#   AGENT_IDS             space-separated agent ids                (no default)
#   AGENT_WORKSPACE_DIR   where the agent tree is mounted INSIDE a container
#                                                          (default: /workspace)
#   AGENT_HOST_IMAGE      the host image reference                 (no default)
#   HARNESS_IMAGE         the harness layer image reference        (no default)
#   HARNESS_ID            the single CLI the layer installs        (no default)
#   HARNESS_CONFIG_PATH   the CLI's configuration file inside the
#                         container, absolute path                 (no default)
#   ROUTER_BASE_URL       the router endpoint the harness uses     (no default)
#   ROUTER_CREDENTIAL_ENV name of the variable carrying the router
#                         credential                               (default: ROUTER_API_KEY)
#   ROUTER_ALIAS          the model alias the harness sends        (no default)
#   ROUTER_ALIAS_SET      space-separated ids the router serves    (no default)
#   DOCKER_PROXY_URL      the Docker-access endpoint consumers use (no default)
#   DOCKER_PROXY_ALLOWLIST  the proxy's allowed endpoint groups    (no default)
#   SECRETS_KEY_DIR       host directory holding the age key material
#   HOST_CONTAINER        the running host container's name        (no default)
#   ROUTER_CONTAINER      the running router container's name      (optional)
#   PROXY_CONTAINER       the running Docker-access proxy's name   (optional:
#                         without it A-5 cannot inspect the proxy, and cannot
#                         apply its one sanctioned socket mount)
#   PART_SCRIPTS          space-separated name:path entries for the parts'
#                         own acceptance scripts (optional; A-3)
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

require() {  # require NAME VALUE
    [ -n "${2:-}" ] || usage_error "$1 is not set"
}
for v in AGENT_SET_NETWORK AGENT_TREE_DIR AGENT_IDS AGENT_HOST_IMAGE HARNESS_IMAGE \
         HARNESS_ID HARNESS_CONFIG_PATH ROUTER_BASE_URL ROUTER_ALIAS ROUTER_ALIAS_SET \
         DOCKER_PROXY_URL DOCKER_PROXY_ALLOWLIST HOST_CONTAINER; do
    require "$v" "${!v:-}"
done
ROUTER_CREDENTIAL_ENV="${ROUTER_CREDENTIAL_ENV:-ROUTER_API_KEY}"
AGENT_WORKSPACE_DIR="${AGENT_WORKSPACE_DIR:-/workspace}"
# P-8 is the router root; the API path is appended here, exactly as the harness
# layer appends it per arm. A value that already ends in /v1 would double it.
ROUTER_ROOT="${ROUTER_BASE_URL%/}"
case "$ROUTER_ROOT" in
    */v1) printf 'note: ROUTER_BASE_URL ends in /v1, but P-8 is the router root; the models endpoint is read at %s/v1/models\n' "$ROUTER_ROOT" ;;
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
        blob_hash="$(git -C "$REPO_DIR" show "$commit:$path" 2>/dev/null | sha256sum | cut -d' ' -f1)"
        if [ -z "$blob_hash" ] || [ "$blob_hash" = "$(printf '' | sha256sum | cut -d' ' -f1)" ]; then
            pins_bad="$pins_bad
  $path: not present at commit ${commit%????????????????????????????????}"
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
                    if [ -n "$absent_svc" ]; then
                        fail "A-2 the merged configuration is missing service(s):$absent_svc — a fragment is absent from COMPOSE_FILES, and the set would come up without that service"
                    else
                        pass "A-2 the merged configuration defines every expected service ($EXPECTED_SERVICES); the glue contributed network membership and secret sources only"
                    fi
                else
                    pass "A-2 the merged configuration has $svc_all service(s), all from the parts' fragments"
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
    skip "A-3 no part acceptance scripts supplied (set PART_SCRIPTS='name:path …')"
else
    for entry in $PART_SCRIPTS; do
        name="${entry%%:*}"; script="${entry#*:}"
        if [ ! -f "$script" ]; then
            skip "A-3 $name: no script at $script"
        elif [ ! -x "$script" ]; then
            fail "A-3 $name: $script is not executable"
        else
            bash "$script" >/dev/null 2>&1
            rc=$?
            [ "$rc" -eq 0 ] \
                && pass "A-3 $name: its own acceptance script exits 0" \
                || fail "A-3 $name: $script exited $rc; a part that fails its own rows must stop the assembly"
        fi
    done
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
    if [ -z "$LAYER_CTX" ] || [ ! -f "$LAYER_CTX/Containerfile" ]; then
        skip "A-4 no harness layer build context (set LAYER_BUILD_CONTEXT to the directory holding its Containerfile)"
    else
        arm_args="--build-arg HARNESS_MODEL_ALIAS=$ROUTER_ALIAS --build-arg HARNESS_CONTEXT_WINDOW=${HARNESS_CONTEXT_WINDOW:-200000}"
        [ "$HARNESS_ID" = "claude" ] && arm_args="$arm_args --build-arg HARNESS_FAST_ALIAS=${ROUTER_FAST_ALIAS:-$ROUTER_ALIAS} --build-arg HARNESS_MAX_OUTPUT_TOKENS=${HARNESS_MAX_OUTPUT_TOKENS:-32000}"
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
if ! command -v docker >/dev/null 2>&1; then
    skip "A-5 docker is not available"
    skip "A-6 docker is not available"
else
    containers="$(docker ps --format '{{.Names}}' 2>&1)"
    if denied "$containers"; then
        skip "A-5 docker refused the request on this host: $(printf '%s' "$containers" | head -1)"
        skip "A-6 docker refused the request on this host"
    else
        # Every service of the set, the proxy included: it is the one container
        # whose socket mount is by design, so leaving it out of the set would hide
        # both the exception and any second socket mount.
        set_pattern="^(${HOST_CONTAINER}|${ROUTER_CONTAINER:-__none__}|${PROXY_CONTAINER:-__none__})$"
        set_containers="$(printf '%s' "$containers" | grep -E "$set_pattern" || true)"
        if [ -z "$set_containers" ]; then
            skip "A-5 no container of the set is running (expected $HOST_CONTAINER${ROUTER_CONTAINER:+, $ROUTER_CONTAINER}${PROXY_CONTAINER:+, $PROXY_CONTAINER})"
            skip "A-6 no container of the set is running"
        else
            bad_pub=""; bad_priv=""; bad_cap=""; bad_dev=""; bad_sock=""; ro_ok=1; rw_paths=""; sock_ok=0
            for c in $set_containers; do
                cfg="$(docker inspect "$c" 2>/dev/null)"
                [ -n "$cfg" ] || continue
                printf '%s' "$cfg" | grep -q '"PortBindings":{}\|"PortBindings": *null' \
                    || bad_pub="$bad_pub $c"
                printf '%s' "$cfg" | grep -q '"Privileged": *false' \
                    || bad_priv="$bad_priv $c"
                printf '%s' "$cfg" | grep -q '"CapAdd": *null\|"CapAdd": *\[\]' \
                    || bad_cap="$bad_cap $c"
                printf '%s' "$cfg" | grep -q '"Devices": *\[\]\|"Devices": *null' \
                    || bad_dev="$bad_dev $c"
                mounts="$(docker inspect "$c" --format '{{range .Mounts}}{{.Source}}|{{.Destination}}|{{.RW}}{{println}}{{end}}' 2>/dev/null)"
                sock_n=0
                while IFS='|' read -r src dst rw; do
                    [ -n "$src" ] || continue
                    case "$src" in
                        *docker.sock*)
                            sock_n=$((sock_n + 1))
                            # The proxy's own socket mount is the design: one
                            # mount, read-only (the Docker-access part's R-6).
                            # Anywhere else, or a writable one, is a failure.
                            if [ -n "$PROXY_CONTAINER" ] && [ "$c" = "$PROXY_CONTAINER" ] && [ "$rw" = "false" ] && [ "$sock_n" -le 1 ]; then
                                sock_ok=1
                            else
                                bad_sock="$bad_sock $c"
                            fi ;;
                    esac
                    if [ "$rw" = "true" ]; then
                        rw_paths="$rw_paths $src"
                        if [ -n "${AGENT_TREE_DIR:-}" ] && [ "$src" != "$AGENT_TREE_DIR" ]; then
                            ro_ok=0
                        fi
                    fi
                done <<EOF
$mounts
EOF
            done
            [ -z "$bad_pub" ] \
                && pass "A-5 no container of the set publishes a port" \
                || fail "A-5 published ports on:$bad_pub"
            if [ -z "$bad_priv$bad_cap$bad_dev$bad_sock" ]; then
                if [ "$sock_ok" = "1" ]; then
                    pass "A-5 no container of the set is privileged, holds an added capability or device, or mounts the Docker socket — with the proxy's own read-only socket mount as the one sanctioned exception"
                elif [ -n "$PROXY_CONTAINER" ]; then
                    pass "A-5 no container of the set is privileged, holds an added capability or device, or mounts the Docker socket"
                else
                    pass "A-5 no container of the set is privileged, holds an added capability or device, or mounts the Docker socket (PROXY_CONTAINER is unset, so the proxy was not inspected and its sanctioned mount was not seen)"
                fi
            else
                fail "A-5 forbidden properties — privileged:$bad_priv cap:$bad_cap device:$bad_dev socket:$bad_sock"
            fi
            [ "$ro_ok" = "1" ] \
                && pass "A-6 the only read-write host path in the set is $AGENT_TREE_DIR" \
                || fail "A-6 read-write host paths outside the agent tree:$rw_paths"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-7: nothing in the set runs as root
# ---------------------------------------------------------------------------
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
        proc_user="$(docker exec "$HOST_CONTAINER" id -u 2>&1)"
        if denied "$proc_user"; then
            skip "A-7 running-process uid: $(exec_reason)"
        elif [ "$proc_user" = "0" ]; then
            fail "A-7 the host container's process runs as uid 0"
        else
            pass "A-7 the host container's process runs as uid $proc_user"
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
        if printf '%s' "$env_json" | grep -q "AGENT_HARNESS=$HARNESS_ID"; then
            pass "A-8 AGENT_HARNESS is set to $HARNESS_ID in the image"
        else
            fail "A-8 AGENT_HARNESS=$HARNESS_ID is not in the image's environment: $env_json"
        fi
        if [ "$ep_json" = "null" ] && [ "$cmd_json" = "null" ]; then
            pass "A-8 the layer declares no ENTRYPOINT and no CMD (the base's run contract is inherited)"
        else
            fail "A-8 the layer declares entrypoint=$ep_json cmd=$cmd_json; it must declare neither"
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
            scan_log="$(docker logs "$cid" 2>&1 | grep -m1 '^SCAN|' | cut -d'|' -f2-)"
            docker rm -f "$cid" >/dev/null 2>&1
            scan_hits="$(printf '%s' "$scan_log" | tr -d ' \t')"
            if [ -z "$scan_log" ]; then
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
# A-9: an agent pane runs the harness CLI
# ---------------------------------------------------------------------------
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
                *"'"$HARNESS_ID"'"*) printf "%s|%s|%s\n" "$pid" "$cmd" "$(readlink "$p/cwd" 2>/dev/null)" ;;
            esac
        done' 2>&1)"
    if denied "$panes"; then
        skip "A-9 $(exec_reason)"
    elif [ -z "$panes" ]; then
        fail "A-9 no process in $HOST_CONTAINER runs $HARNESS_ID; the panes are not running the harness"
    else
        n="$(printf '%s\n' "$panes" | wc -l | tr -d ' ')"
        pass "A-9 $n process(es) in $HOST_CONTAINER run $HARNESS_ID (a pane's process tree contains the harness)"
        cwd_bad=0
        while IFS='|' read -r pid cmd cwd; do
            [ -z "$cwd" ] && continue
            case "$cwd" in
                "$AGENT_WORKSPACE_DIR"|"$AGENT_WORKSPACE_DIR"/*) ;;
                *) cwd_bad=$((cwd_bad + 1)) ;;
            esac
        done <<EOF
$panes
EOF
        [ "$cwd_bad" -eq 0 ] \
            && pass "A-9 every harness process runs inside the agent workspace ($AGENT_WORKSPACE_DIR)" \
            || fail "A-9 $cwd_bad harness process(es) run outside the agent workspace"
    fi
fi

# ---------------------------------------------------------------------------
# A-10: the pane's environment and configuration carry the wiring
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    skip "A-10 docker is not available"
else
    wire="$(docker exec -e CRED_NAME="$ROUTER_CREDENTIAL_ENV" -e CFG="$HARNESS_CONFIG_PATH" "$HOST_CONTAINER" sh -c '
        for p in /proc/[0-9]*; do
            cmd="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
            case "$cmd" in
                *"'"$HARNESS_ID"'"*)
                    tr "\0" "\n" < "$p/environ" 2>/dev/null | sed -n "s/^ROUTER_BASE_URL=/ROUTER_BASE_URL=/p;s/^${CRED_NAME}=/CREDENTIAL_PRESENT=/p" | sed "s/^CREDENTIAL_PRESENT=.*/CREDENTIAL_PRESENT=yes/"
                    break ;;
            esac
        done
        [ -f "$CFG" ] && printf "CONFIG_PRESENT=%s\n" "$CFG"' 2>&1)"
    if denied "$wire"; then
        skip "A-10 $(exec_reason)"
    elif [ -z "$wire" ]; then
        fail "A-10 could not read a harness process's environment in $HOST_CONTAINER"
    else
        printf '%s' "$wire" | grep -q "^ROUTER_BASE_URL=" \
            && pass "A-10 the harness process carries ROUTER_BASE_URL" \
            || fail "A-10 the harness process has no ROUTER_BASE_URL"
        printf '%s' "$wire" | grep -q "^CREDENTIAL_PRESENT=yes" \
            && pass "A-10 the harness process carries $ROUTER_CREDENTIAL_ENV (presence only; the value is never printed)" \
            || fail "A-10 the harness process has no $ROUTER_CREDENTIAL_ENV"
        cfg="$(docker exec "$HOST_CONTAINER" cat "$HARNESS_CONFIG_PATH" 2>/dev/null)"
        if [ -z "$cfg" ]; then
            skip "A-10 configuration check: $HARNESS_CONFIG_PATH is unreadable or absent"
        else
            forbidden="$(printf '%s' "$cfg" | grep -oE '(sk-[A-Za-z0-9_-]{8,}|ANTHROPIC_API_KEY|OPENAI_API_KEY|GEMINI_API_KEY)' | head -1)"
            if [ -n "$forbidden" ]; then
                fail "A-10 the harness configuration names a provider credential or key ($forbidden); it may name only aliases"
            else
                pass "A-10 the harness configuration names no provider credential or key"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# A-11: a request from the pane reaches the router by alias
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    skip "A-11 docker is not available"
else
    code="$(docker exec -e CRED_NAME="$ROUTER_CREDENTIAL_ENV" "$HOST_CONTAINER" sh -c '
        v="$(printenv "$CRED_NAME" 2>/dev/null)"
        [ -n "$v" ] || { echo "NO_CREDENTIAL"; exit 0; }
        curl -s -o /tmp/agent-set-models -w "%{http_code}" -H "Authorization: Bearer $v" "'"$ROUTER_BASE_URL"'/models"' 2>&1 | tail -1)"
    if denied "$code"; then
        skip "A-11 $(exec_reason)"
    elif [ "$code" = "NO_CREDENTIAL" ]; then
        skip "A-11 the host container carries no $ROUTER_CREDENTIAL_ENV in its environment; the store did not inject it"
    elif [ "$code" = "200" ]; then
        got="$(docker exec "$HOST_CONTAINER" cat /tmp/agent-set-models 2>/dev/null | grep -o "\"$ROUTER_ALIAS\"" | head -1)"
        [ -n "$got" ] \
            && pass "A-11 the pane's request to $ROUTER_BASE_URL/models returns 200 and the alias '$ROUTER_ALIAS' is in the answer" \
            || fail "A-11 the router answered 200 but does not list the alias '$ROUTER_ALIAS'"
        nocode="$(docker exec "$HOST_CONTAINER" sh -c 'curl -s -o /dev/null -w "%{http_code}" "'"$ROUTER_BASE_URL"'/models"' 2>/dev/null | tail -1)"
        case "$nocode" in
            401|403) pass "A-11 a request without the router credential is rejected ($nocode)" ;;
            "") skip "A-11 credential-refusal check: no answer from the router" ;;
            *) fail "A-11 a request without the router credential returned $nocode, not 401/403" ;;
        esac
    else
        fail "A-11 the pane's request to $ROUTER_BASE_URL/models returned '$code', not 200"
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
    out="$(docker exec "$HOST_CONTAINER" sh -c 'curl -sS -m 10 "'"$ROUTER_BASE_URL"'/models" 2>&1' 2>&1)"
    rc=$?
    docker start "$ROUTER_CONTAINER" >/dev/null 2>&1
    if [ "$stopped" -ne 0 ]; then
        skip "A-12 could not stop $ROUTER_CONTAINER on this host"
    elif [ "$rc" -eq 0 ]; then
        fail "A-12 the request succeeded while the router was stopped: another provider answered"
    else
        pass "A-12 with the router stopped the request fails visibly ($(printf '%s' "$out" | tail -1 | cut -c1-60)) and no other provider answers"
    fi
fi

# ---------------------------------------------------------------------------
# A-13: Docker access goes through the proxy, and the socket is not reachable
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    skip "A-13 docker is not available"
else
    ver="$(docker exec -e DOCKER_HOST="$DOCKER_PROXY_URL" "$HOST_CONTAINER" sh -c 'docker version --format "{{.Server.Version}}" 2>&1' 2>&1)"
    if denied "$ver" || absent "$ver"; then
        skip "A-13 $(exec_reason)"
    elif ! printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+'; then
        skip "A-13 the container's docker client reached no daemon through $DOCKER_PROXY_URL: $(printf '%s' "$ver" | tail -1 | cut -c1-80)"
    else
        pass "A-13 the host container reaches the Docker daemon through $DOCKER_PROXY_URL (server $ver)"
        sock="$(docker exec "$HOST_CONTAINER" sh -c 'ls -l /var/run/docker.sock 2>&1 || true' 2>/dev/null)"
        case "$sock" in
            *"No such file"*|"") pass "A-13 no Docker socket is present in the container's filesystem" ;;
            *) fail "A-13 a Docker socket is present in the container: $sock" ;;
        esac
        deny="$(docker exec -e DOCKER_HOST="$DOCKER_PROXY_URL" "$HOST_CONTAINER" sh -c 'docker run --rm --privileged '"${HARNESS_IMAGE}"' true 2>&1 | tail -1' 2>&1)"
        case "$deny" in
            *"failed to connect"*|*"Cannot connect"*|*"cannot connect"*|*"no such file"*)
                skip "A-13 deny check: the probe reached no daemon through the proxy, so this row cannot see what the proxy answered" ;;
            *denied*|*"not allowed"*|*"forbidden"*|*"not authorized"*|*"Error response from daemon"*)
                pass "A-13 the proxy refuses a verb outside the allowlist ($DOCKER_PROXY_ALLOWLIST)" ;;
            "") skip "A-13 deny check: no answer from the proxy" ;;
            *) fail "A-13 a privileged run was not refused by the proxy: $(printf '%s' "$deny" | cut -c1-80)" ;;
        esac
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
    PROBE_CID="$(docker create --label org.testcontainers=true --name "agent-set-verify-probe-$$" \
        -e SOPS_AGE_KEY_FILE="/run/secrets/age-keys-missing" "$HARNESS_IMAGE" 2>&1)"
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
        docker rm -f "$PROBE_CID" >/dev/null 2>&1; PROBE_CID=""
        logs="$(docker logs "$PROBE_CID" 2>/dev/null | tail -5)"
        if [ -z "$rc" ]; then
            fail "A-14 a container started without its key material kept running; the store's failure is not loud"
        elif [ "$rc" = "0" ]; then
            fail "A-14 a container started without its key material exited 0; the credential path failed silently"
        elif [ -n "$logs" ] && printf '%s' "$logs" | grep -qiE 'sops|age|decrypt|secret|key'; then
            pass "A-14 a container started without its key material exits $rc, and its own output names the credential path ($(printf '%s' "$logs" | tail -1 | cut -c1-60))"
        else
            skip "A-14 the probe exited $rc without naming the credential path, so this is not evidence about the store: $(printf '%s' "$logs" | tail -1 | cut -c1-60)"
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
    code="$(docker exec -e CRED_NAME="$ROUTER_CREDENTIAL_ENV" -e ALIAS="$ROUTER_ALIAS" "$HOST_CONTAINER" sh -c '
        v="$(printenv "$CRED_NAME" 2>/dev/null)"
        curl -s -o /tmp/agent-set-completion -w "%{http_code}" -X POST "'"$ROUTER_BASE_URL"'/chat/completions" \
            -H "Authorization: Bearer $v" -H "Content-Type: application/json" \
            -d "{\"model\":\"$ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: ok\"}],\"max_tokens\":8}"' 2>&1 | tail -1)"
    if denied "$code"; then
        skip "A-15 $(exec_reason)"
    elif [ "$code" = "200" ]; then
        pass "A-15 one real completion through the alias '$ROUTER_ALIAS' returns 200. Stated limit: this exercises the router's own path to its provider, not the harness CLI's interactive call"
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
        docker compose $args down >/dev/null 2>&1
    fi
    docker network rm "$AGENT_SET_NETWORK" >/dev/null 2>&1
    left="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^(${HOST_CONTAINER}|${ROUTER_CONTAINER:-__none__})$" || true)"
    [ -z "$left" ] \
        && pass "A-16 the set's containers are gone and the network is removed" \
        || fail "A-16 containers still running after teardown: $left"
    tree_ok=1
    [ -d "$AGENT_TREE_DIR" ] || tree_ok=0
    [ "$tree_ok" = "1" ] \
        && pass "A-16 the agent tree is still present and was not touched by the teardown" \
        || fail "A-16 the agent tree at $AGENT_TREE_DIR is gone; removal must not delete agent state"
    if [ -n "${PART_SCRIPTS:-}" ]; then
        for entry in $PART_SCRIPTS; do
            name="${entry%%:*}"; script="${entry#*:}"
            [ -x "$script" ] || continue
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
printf '\n%d check(s): %d failed, %d skipped\n' "$CHECKS" "$FAILURES" "$SKIPPED"
if [ "$SKIPPED" -gt 0 ]; then
    printf 'Skipped rows are not passes: each SKIP above names what the host could not provide.\n'
fi
[ "$FAILURES" -eq 0 ] || exit 1
exit 0
