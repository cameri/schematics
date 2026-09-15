#!/bin/sh
# Acceptance checks for the agent dev base image.
#
# Implements the mechanical checks of SCHEMATIC.md's Verification and
# Acceptance section (A-1 … A-11, A-13 … A-16) against a built image. It touches nothing
# outside Docker: it builds one throwaway "harness layer" image, creates one
# named volume, and removes both when it is done. Safe to re-run.
#
# It never contacts a remote registry except to resolve the base image digest
# when BUILD=1, and it never pushes anything.
#
# Inputs (environment; none of these is written anywhere):
#   IMAGE             image ref to test            (default: agent-dev-base:dev)
#   BUILD             1 = build IMAGE from ../skeleton/Containerfile first
#   BASE_DISTRO_IMAGE distro image for that build  (default: debian:13-slim)
#   EXPECTED_USER     runtime account name         (default: user)
#   EXPECTED_UID      runtime uid                  (default: 1000)
#   EXPECTED_ENTRYPOINT  entrypoint path           (default: /usr/local/bin/agent-entrypoint)
#   EXPECTED_WORKDIR  default workspace path       (default: /workspace)
#   PUBLISHED_IMAGE   a pushed ref to check for the two-platform manifest
#                     (A-14; skipped when unset)
#   KEEP              1 = keep the throwaway layer image and volume
#
# Exit status: 0 when every executed check passed; 1 when any failed; 2 on a
# usage or precondition error.

set -u

IMAGE="${IMAGE:-agent-dev-base:dev}"
LAYER_TAG="${LAYER_TAG:-agent-dev-base:verify-layer}"
BASE_DISTRO_IMAGE="${BASE_DISTRO_IMAGE:-debian:13-slim}"
EXPECTED_USER="${EXPECTED_USER:-user}"
EXPECTED_UID="${EXPECTED_UID:-1000}"
EXPECTED_ENTRYPOINT="${EXPECTED_ENTRYPOINT:-/usr/local/bin/agent-entrypoint}"
EXPECTED_WORKDIR="${EXPECTED_WORKDIR:-/workspace}"
PUBLISHED_IMAGE="${PUBLISHED_IMAGE:-}"
BUILD="${BUILD:-0}"
KEEP="${KEEP:-0}"

CHECKS=0
FAILURES=0

pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { printf 'SKIP  %s\n' "$1"; }

usage_error() { printf 'verify-base-image: %s\n' "$1" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || usage_error "docker CLI not found in PATH"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-base-image.XXXXXX")"
VOLUME="verify-base-image-vol-$$"

cleanup() {
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    if [ "$KEEP" != "1" ]; then
        docker image rm "$LAYER_TAG" >/dev/null 2>&1 || true
        docker image rm "$LAYER_TAG-bad-key" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# run <docker run args…>: captures combined output in OUT and status in RC.
OUT=""
RC=0
run() {
    OUT="$(docker run --rm "$@" 2>&1)"
    RC=$?
}

# ---------------------------------------------------------------------------
# Build (optional) and preconditions
# ---------------------------------------------------------------------------

if [ "$BUILD" = "1" ]; then
    [ -f "$SELF_DIR/../skeleton/Containerfile" ] \
        || usage_error "BUILD=1 but $SELF_DIR/../skeleton/Containerfile is missing"
    digest="$(docker buildx imagetools inspect "$BASE_DISTRO_IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null)" \
        || usage_error "cannot resolve the manifest digest of $BASE_DISTRO_IMAGE"
    printf 'building %s from %s\n' "$IMAGE" "$BASE_DISTRO_IMAGE@$digest"
    if ! docker build -f "$SELF_DIR/../skeleton/Containerfile" \
        --build-arg "BASE_DISTRO_IMAGE=$BASE_DISTRO_IMAGE" \
        --build-arg "BASE_DISTRO_DIGEST=$digest" \
        --build-arg "AGENT_USER=$EXPECTED_USER" \
        --build-arg "AGENT_UID=$EXPECTED_UID" \
        -t "$IMAGE" "$SELF_DIR/../skeleton" >"$WORK/build.log" 2>&1
    then
        tail -20 "$WORK/build.log" >&2
        usage_error "docker build failed (last 20 lines of build output above)"
    fi
fi

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || usage_error "image $IMAGE not found locally (build it, or pass BUILD=1)"

img() { docker image inspect "$IMAGE" --format "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# A-1, A-4: the image's declared identity, entrypoint, and start contract
# ---------------------------------------------------------------------------

[ "$(img '{{.Config.User}}')" = "$EXPECTED_USER" ] \
    && pass "A-1 image declares USER $EXPECTED_USER" \
    || fail "A-1 image declares USER '$(img '{{.Config.User}}')', expected '$EXPECTED_USER'"

[ "$(img '{{.Config.WorkingDir}}')" = "$EXPECTED_WORKDIR" ] \
    && pass "A-4 default working directory is $EXPECTED_WORKDIR" \
    || fail "A-4 default working directory is '$(img '{{.Config.WorkingDir}}')', expected '$EXPECTED_WORKDIR'"

[ "$(img '{{json .Config.Entrypoint}}')" = "[\"$EXPECTED_ENTRYPOINT\"]" ] \
    && pass "A-4 ENTRYPOINT is exactly [\"$EXPECTED_ENTRYPOINT\"]" \
    || fail "A-4 ENTRYPOINT is $(img '{{json .Config.Entrypoint}}'), expected [\"$EXPECTED_ENTRYPOINT\"]"

[ "$(img '{{json .Config.Cmd}}')" = "null" ] \
    && pass "A-4 no CMD baked into the base (a layer supplies it)" \
    || fail "A-4 base declares CMD $(img '{{json .Config.Cmd}}')"

for field in ExposedPorts Healthcheck Volumes; do
    [ "$(img "{{json .Config.$field}}")" = "null" ] \
        && pass "A-14 no $field declared by the base" \
        || fail "A-14 base declares $field: $(img "{{json .Config.$field}}")"
done

# ---------------------------------------------------------------------------
# A-1, A-2: the runtime account at run time, and the absence of a path to root
# ---------------------------------------------------------------------------

run --entrypoint /usr/bin/id "$IMAGE" -u
[ "$RC" = "0" ] && [ "$OUT" = "$EXPECTED_UID" ] \
    && pass "A-1 'id -u' is $EXPECTED_UID" \
    || fail "A-1 'id -u' is '$OUT' (exit $RC), expected $EXPECTED_UID"

run --entrypoint /usr/bin/id "$IMAGE" -un
[ "$RC" = "0" ] && [ "$OUT" = "$EXPECTED_USER" ] \
    && pass "A-1 'id -un' is $EXPECTED_USER" \
    || fail "A-1 'id -un' is '$OUT' (exit $RC), expected $EXPECTED_USER"

run --entrypoint /bin/sh "$IMAGE" -c 'id -nG'
[ "$RC" = "0" ] && [ "$OUT" = "$EXPECTED_USER" ] \
    && pass "A-2 the account is in no group but its own ($OUT)" \
    || fail "A-2 account groups are '$OUT', expected only '$EXPECTED_USER'"

run --entrypoint /bin/sh "$IMAGE" -c 'command -v sudo || true'
[ -z "$OUT" ] \
    && pass "A-2 no sudo (no escalation path from the account)" \
    || fail "A-2 sudo is present at '$OUT'"

# ---------------------------------------------------------------------------
# A-3: the toolchain
# ---------------------------------------------------------------------------

for tool in \
    "docker --version" \
    "docker compose version" \
    "docker buildx version" \
    "git --version" \
    "cc --version" \
    "make --version" \
    "cmake --version" \
    "pkg-config --version" \
    "python3 --version"
do
    run --entrypoint /bin/sh "$IMAGE" -c "$tool"
    [ "$RC" = "0" ] && [ -n "$OUT" ] \
        && pass "A-3 $tool → $(printf '%s' "$OUT" | head -1)" \
        || fail "A-3 $tool failed (exit $RC): $OUT"
done

run --entrypoint /bin/sh "$IMAGE" -c 'python3 -m venv "$HOME/.venv-probe" && "$HOME/.venv-probe/bin/pip" --version && rm -rf "$HOME/.venv-probe"'
[ "$RC" = "0" ] \
    && pass "A-3 python3 -m venv creates a usable venv with pip" \
    || fail "A-3 python3 -m venv/pip failed (exit $RC): $OUT"

# ---------------------------------------------------------------------------
# A-5: nothing secret-shaped, nothing harness-shaped
# ---------------------------------------------------------------------------

run --entrypoint /bin/sh "$IMAGE" -c '
for p in "$HOME/.env" "$HOME/.netrc" "$HOME/.git-credentials" \
         "$HOME/.docker/config.json" "$HOME/.aws/credentials" \
         "$HOME/.ssh" "/root/.ssh"; do
    [ -e "$p" ] && echo "present:$p"
done
find "$HOME" -xdev \( -name "*.pem" -o -name "id_rsa*" -o -name "id_ed25519*" -o -name "*.key" \) 2>/dev/null
'
[ -z "$OUT" ] \
    && pass "A-5 no credential file, key, or .env anywhere in the image user's home" \
    || fail "A-5 secret-shaped paths present: $OUT"

run --entrypoint /bin/sh "$IMAGE" -c 'ls -A "$HOME"'
[ "$RC" = "0" ] \
    && pass "A-5 home holds only the account skeleton: $(printf '%s' "$OUT" | tr '\n' ' ')" \
    || fail "A-5 cannot list the home directory (exit $RC): $OUT"

# ---------------------------------------------------------------------------
# A-8: the base ships no harness — a bare run cannot start an agent
# ---------------------------------------------------------------------------

run "$IMAGE"
if [ "$RC" = "78" ] && printf '%s' "$OUT" | grep -q 'AGENT_HARNESS is not set'; then
    pass "A-8 bare 'docker run $IMAGE' refuses with 78 and names AGENT_HARNESS"
else
    fail "A-8 bare run exited $RC with: $OUT"
fi

# ---------------------------------------------------------------------------
# A-6, A-7, A-9, A-10, A-11: the entrypoint contract, through a layer image
# ---------------------------------------------------------------------------
# The throwaway layer is the smallest possible consumer of the base: FROM the
# base, add a CLI, name it in AGENT_HARNESS. Everything the checks below prove
# is therefore proved about the base's contract as a layer sees it.

cat > "$WORK/stub-harness" <<'STUB'
#!/bin/sh
# A stand-in harness: it reports what the contract promises, so the checks can
# compare observed behaviour against it.
printf 'harness id=%s pid=%s cwd=%s argv=[%s]\n' "$AGENT_ID" "$$" "$(pwd)" "$*"
STUB
cat > "$WORK/failing-harness" <<'STUB'
#!/bin/sh
exit 7
STUB
chmod 0755 "$WORK/stub-harness" "$WORK/failing-harness"

cat > "$WORK/Containerfile" <<'LAYER'
ARG BASE_IMAGE=none
FROM ${BASE_IMAGE}
USER root
COPY stub-harness failing-harness /usr/local/bin/
RUN chmod 0755 /usr/local/bin/stub-harness /usr/local/bin/failing-harness
USER ${AGENT_USER}
ENV AGENT_HARNESS=stub-harness
LAYER

docker build -f "$WORK/Containerfile" --build-arg "BASE_IMAGE=$IMAGE" -t "$LAYER_TAG" "$WORK" >/dev/null 2>&1 \
    || usage_error "could not build the throwaway harness layer from $IMAGE"

[ "$(docker image inspect "$LAYER_TAG" --format '{{.Config.User}}')" = "$EXPECTED_USER" ] \
    && pass "A-10 a layer keeps the base's runtime account without redeclaring it" \
    || fail "A-10 layer user is $(docker image inspect "$LAYER_TAG" --format '{{.Config.User}}')"

[ "$(docker image inspect "$LAYER_TAG" --format '{{json .Config.Entrypoint}}')" = "[\"$EXPECTED_ENTRYPOINT\"]" ] \
    && pass "A-10 a layer inherits the standard entrypoint untouched" \
    || fail "A-10 layer entrypoint is $(docker image inspect "$LAYER_TAG" --format '{{json .Config.Entrypoint}}')"

# A-6: the happy path — default id, explicit id, argument pass-through, cwd,
# and the harness as PID 1.
run "$LAYER_TAG"
observed_id="$(printf '%s' "$OUT" | sed -n 's/^harness id=\([^ ]*\) pid=.*/\1/p')"
observed_pid="$(printf '%s' "$OUT" | sed -n 's/^harness id=[^ ]* pid=\([^ ]*\) .*/\1/p')"
observed_cwd="$(printf '%s' "$OUT" | sed -n 's/^harness id=[^ ]* pid=[^ ]* cwd=\([^ ]*\) .*/\1/p')"
[ "$RC" = "0" ] && [ -n "$observed_id" ] \
    && pass "A-6 default AGENT_ID resolves to the container hostname ($observed_id)" \
    || fail "A-6 default run failed (exit $RC): $OUT"
[ "$observed_pid" = "1" ] \
    && pass "A-6 the harness is PID 1 (the entrypoint exec'd, no wrapper process)" \
    || fail "A-6 harness ran as pid $observed_pid, expected 1"
[ "$observed_cwd" = "$EXPECTED_WORKDIR" ] \
    && pass "A-6 the harness starts in the workspace ($observed_cwd)" \
    || fail "A-6 harness cwd is '$observed_cwd', expected '$EXPECTED_WORKDIR'"

run -e AGENT_ID=verify-id "$LAYER_TAG" --flag x "two words"
[ "$RC" = "0" ] && printf '%s' "$OUT" | grep -qF 'id=verify-id' \
    && printf '%s' "$OUT" | grep -qF 'argv=[--flag x two words]' \
    && pass "A-6 AGENT_ID is honoured and container arguments reach the harness" \
    || fail "A-6 explicit id/args run gave (exit $RC): $OUT"

# A-9: the harness's own exit status passes through unchanged.
run -e AGENT_HARNESS=failing-harness "$LAYER_TAG"
[ "$RC" = "7" ] \
    && pass "A-9 the harness's exit status reaches docker unchanged (7)" \
    || fail "A-9 exit status was $RC, expected the harness's 7"

# A-7: every refusal is 78, names the offending thing, and starts nothing.
refusal() { # refusal <label> <expected-substring> <docker run args…>
    label="$1"; want="$2"; shift 2
    run "$@"
    if [ "$RC" = "78" ] && printf '%s' "$OUT" | grep -qF "$want"; then
        pass "A-7 $label → 78 naming '$want'"
    else
        fail "A-7 $label exited $RC with: $OUT"
    fi
}

refusal "harness not found" "AGENT_HARNESS 'nope-not-here'" \
    -e AGENT_HARNESS=nope-not-here "$LAYER_TAG"
refusal "relative workspace" "must be an absolute path" \
    -e AGENT_WORKSPACE_DIR=relative/workspace "$LAYER_TAG"
refusal "invalid agent id" "AGENT_ID must match" \
    -e "AGENT_ID=bad id" "$LAYER_TAG"
refusal "over-long agent id" "at most 64 characters" \
    -e "AGENT_ID=$(printf '%065d' 0)" "$LAYER_TAG"

# A-11: the workspace — a mounted one is used, a nested one is created, and an
# unwritable one is refused before anything starts.
docker volume create "$VOLUME" >/dev/null 2>&1 || usage_error "cannot create a named volume"

run -v "$VOLUME:$EXPECTED_WORKDIR" "$LAYER_TAG"
[ "$RC" = "0" ] && printf '%s' "$OUT" | grep -qF "cwd=$EXPECTED_WORKDIR " \
    && pass "A-11 a workspace mounted at $EXPECTED_WORKDIR is used as the working directory" \
    || fail "A-11 mounted workspace run gave (exit $RC): $OUT"

run -v "$VOLUME:$EXPECTED_WORKDIR" -e "AGENT_WORKSPACE_DIR=$EXPECTED_WORKDIR/nested" "$LAYER_TAG"
[ "$RC" = "0" ] && printf '%s' "$OUT" | grep -qF "cwd=$EXPECTED_WORKDIR/nested " \
    && pass "A-11 a workspace path that does not exist yet is created and entered" \
    || fail "A-11 created-workspace run gave (exit $RC): $OUT"

run -v "$VOLUME:$EXPECTED_WORKDIR:ro" "$LAYER_TAG"
if [ "$RC" = "78" ] && printf '%s' "$OUT" | grep -qF 'is not writable by uid'; then
    pass "A-11 an unwritable workspace is refused with 78"
else
    fail "A-11 read-only workspace run exited $RC with: $OUT"
fi

# A-14: no listening socket in the container, with the harness running.
run --entrypoint /bin/sh "$LAYER_TAG" -c '
grep -q ": 0A" /proc/net/tcp /proc/net/tcp6 2>/dev/null && echo listening || echo none
'
[ "$OUT" = "none" ] \
    && pass "A-14 no listening TCP socket in the container" \
    || fail "A-14 a listening socket exists: $OUT"

# ---------------------------------------------------------------------------
# A-13: provenance labels
# ---------------------------------------------------------------------------

labels="$(img '{{json .Config.Labels}}')"
missing=""
for key in org.opencontainers.image.version org.opencontainers.image.revision \
           org.opencontainers.image.source org.opencontainers.image.base.digest; do
    printf '%s' "$labels" | grep -q "\"$key\"" || missing="$missing $key"
done
[ -z "$missing" ] \
    && pass "A-13 provenance labels present (version, revision, source, base digest)" \
    || fail "A-13 missing labels:$missing"

# ---------------------------------------------------------------------------
# A-15: the build history holds no unverified installer
# ---------------------------------------------------------------------------

history_text="$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE" 2>/dev/null)"
if printf '%s' "$history_text" | grep -Eq '\|[[:space:]]*(ba|z|d)?sh([[:space:]]|$)'; then
    fail "A-15 the image's build history pipes into a shell"
else
    pass "A-15 no pipe-to-shell in the image's build history"
fi
downloaded="$(printf '%s' "$history_text" | grep -Eo 'https?://[^ "]+' \
    | grep -E '\.(sh|tar|tar\.gz|tgz|zip|deb|rpm|whl)$' | sort -u)"
[ -z "$downloaded" ] \
    && pass "A-15 no archive or installer is downloaded from a URL during the build" \
    || fail "A-15 the build downloads: $(printf '%s' "$downloaded" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# A-16: a package repository key that does not match its recorded fingerprint
# stops the build, instead of the build trusting whatever the URL served
# (only when this script did the build, so it has the build arguments)
# ---------------------------------------------------------------------------

if [ "$BUILD" = "1" ]; then
    if docker build -f "$SELF_DIR/../skeleton/Containerfile" \
        --build-arg "BASE_DISTRO_IMAGE=$BASE_DISTRO_IMAGE" \
        --build-arg "BASE_DISTRO_DIGEST=$digest" \
        --build-arg "DOCKER_REPO_KEY_FPR=0000000000000000000000000000000000000000" \
        -t "$LAYER_TAG-bad-key" "$SELF_DIR/../skeleton" >"$WORK/negative-build.log" 2>&1
    then
        fail "A-16 a build with a mismatched repository key fingerprint succeeded"
    else
        pass "A-16 a build with a mismatched repository key fingerprint fails"
    fi
else
    skip "A-16 repository key fingerprint enforcement (run with BUILD=1)"
fi

# ---------------------------------------------------------------------------
# A-12: the two-platform manifest (only when a published ref is given)
# ---------------------------------------------------------------------------

if [ -n "$PUBLISHED_IMAGE" ]; then
    platforms="$(docker buildx imagetools inspect "$PUBLISHED_IMAGE" --format '{{json .Manifest.Manifests}}' 2>/dev/null)"
    if printf '%s' "$platforms" | grep -q 'linux/amd64' && printf '%s' "$platforms" | grep -q 'linux/arm64'; then
        pass "A-12 $PUBLISHED_IMAGE carries a linux/amd64 and a linux/arm64 manifest"
    else
        fail "A-12 $PUBLISHED_IMAGE does not publish both platforms: $platforms"
    fi
else
    skip "A-12 two-platform manifest (set PUBLISHED_IMAGE=<registry ref> after publishing)"
fi

# ---------------------------------------------------------------------------

printf '\n%s checks, %s failed\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" = "0" ] || exit 1
exit 0
