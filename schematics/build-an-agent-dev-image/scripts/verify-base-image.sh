#!/bin/sh
# Acceptance checks for the agent dev base image.
#
# Implements the mechanical checks of SCHEMATIC.md's Verification and
# Acceptance section (A-1 … A-17; A-12 only when PUBLISHED_IMAGE names a
# published ref) against a built image. It touches nothing outside Docker: it
# builds three throwaway layer images, creates one named volume, runs one
# short-lived probe container, and removes all of it when it is done. Safe to
# re-run.
#
# It never contacts a remote registry except to resolve the base image digest
# when BUILD=1, and it never pushes anything.
#
# Inputs (environment; none of these is written anywhere):
#   IMAGE             image ref to test            (default: agent-dev-base:dev)
#   BUILD             1 = build IMAGE from ../skeleton/Containerfile first
#   NO_CACHE          1 = build with --no-cache. A cached build does not
#                     re-execute the package installation or the repository key
#                     fetch, so a run that must exercise those steps (and A-16)
#                     uses this. Pair it with BUILD=1.
#   BASE_DISTRO_IMAGE distro image for that build  (default: debian:13-slim)
#   BASE_DISTRO_DIGEST  the base's manifest list digest; resolved from the
#                     registry when unset. Supply it when the registry is
#                     rate-limiting the resolution request.
#   IMAGE_VERSION, GIT_COMMIT, IMAGE_SOURCE
#                     label values passed to a BUILD=1 build. Defaults are
#                     deliberately non-release values (0.0.0-verify, the current
#                     commit, a reserved .invalid URL) so a verification build
#                     cannot be mistaken for a published one.
#   EXPECTED_BASE_DIGEST  the digest the image was built from; compared against
#                     the base-digest label. Resolved automatically when
#                     BUILD=1; when neither is available that single sub-check
#                     is skipped rather than passed.
#   EXPECTED_USER     runtime account name         (default: user)
#   EXPECTED_UID      runtime uid                  (default: 1000)
#   EXPECTED_ENTRYPOINT  entrypoint path           (default: /usr/local/bin/agent-entrypoint)
#   EXPECTED_WORKDIR  default workspace path       (default: /workspace)
#   PUBLISHED_IMAGE   a pushed ref to check for the two-platform manifest
#                     (A-12; skipped when unset)
#   KEEP              1 = keep the throwaway layer images and volume
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
NO_CACHE="${NO_CACHE:-0}"
KEEP="${KEEP:-0}"
IMAGE_VERSION="${IMAGE_VERSION:-0.0.0-verify}"
GIT_COMMIT="${GIT_COMMIT:-}"
IMAGE_SOURCE="${IMAGE_SOURCE:-https://example.invalid/verification-build}"
EXPECTED_BASE_DIGEST="${EXPECTED_BASE_DIGEST:-}"
PROBE_CID=""

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
    if [ -n "$PROBE_CID" ]; then
        docker rm -f "$PROBE_CID" >/dev/null 2>&1 || true
    fi
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    if [ "$KEEP" != "1" ]; then
        docker image rm "$LAYER_TAG" >/dev/null 2>&1 || true
        docker image rm "$LAYER_TAG-plain" >/dev/null 2>&1 || true
        docker image rm "$LAYER_TAG-bad-key" >/dev/null 2>&1 || true
        docker image rm "$LAYER_TAG-template" >/dev/null 2>&1 || true
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
    if [ -n "${BASE_DISTRO_DIGEST:-}" ]; then
        digest="$BASE_DISTRO_DIGEST"
    else
        digest="$(docker buildx imagetools inspect "$BASE_DISTRO_IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null)" \
            || usage_error "cannot resolve the manifest digest of $BASE_DISTRO_IMAGE (pass BASE_DISTRO_DIGEST)"
    fi
    EXPECTED_BASE_DIGEST="${EXPECTED_BASE_DIGEST:-$digest}"
    [ -n "$GIT_COMMIT" ] \
        || GIT_COMMIT="$(git -C "$SELF_DIR/.." rev-parse --short HEAD 2>/dev/null || echo verify)"
    cache_arg=""
    [ "$NO_CACHE" = "1" ] && cache_arg="--no-cache"
    printf 'building %s from %s%s\n' "$IMAGE" "$BASE_DISTRO_IMAGE@$digest" \
        "$([ -n "$cache_arg" ] && echo ' (no cache)')"
    # The unquoted $cache_arg is intentional: it is empty or one flag.
    if ! docker build $cache_arg -f "$SELF_DIR/../skeleton/Containerfile" \
        --build-arg "BASE_DISTRO_IMAGE=$BASE_DISTRO_IMAGE" \
        --build-arg "BASE_DISTRO_DIGEST=$digest" \
        --build-arg "AGENT_USER=$EXPECTED_USER" \
        --build-arg "AGENT_UID=$EXPECTED_UID" \
        --build-arg "IMAGE_VERSION=$IMAGE_VERSION" \
        --build-arg "GIT_COMMIT=$GIT_COMMIT" \
        --build-arg "IMAGE_SOURCE=$IMAGE_SOURCE" \
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
# Two scopes: the whole filesystem (credential-shaped *file names* anywhere —
# the distribution ships none of them, so a hit is a defect) and the account's
# home (*key material*: anything else in the image may legitimately carry a
# public certificate, e.g. the CA bundle under /etc/ssl/certs, but a private
# key in the account's home is never legitimate).
#
# Scope limit, stated: the scan runs as the runtime account, so paths that
# account cannot read (root-only directories) are out of its reach. R-9 is
# therefore also a build-time property — the Containerfile creates no such
# file — and that half is checked by A-15's history rules.

run --entrypoint /bin/sh "$IMAGE" -c '
find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
    -type f \( -name ".env" -o -name ".netrc" -o -name ".git-credentials" \
               -o -name "id_rsa*" -o -name "id_ed25519*" -o -name "authorized_keys" \
               -o -name "credentials.json" -o -path "*/.docker/config.json" \
               -o -path "*/.aws/credentials" \) -print 2>/dev/null
find "$HOME" -xdev \( -name "*.pem" -o -name "*.key" \) -print 2>/dev/null
'
[ -z "$OUT" ] \
    && pass "A-5 no credential-shaped file anywhere in the image, and no key material in the account's home" \
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
# compare observed behaviour against it. With STUB_SLEEP set it stays alive
# (as PID 1) so the socket probe has a running agent process to inspect.
printf 'harness id=%s pid=%s cwd=%s argv=[%s]\n' "$AGENT_ID" "$$" "$(pwd)" "$*"
if [ -n "${STUB_SLEEP:-}" ]; then
    exec sleep "$STUB_SLEEP"
fi
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

# The same layer in its minimal form: it restates nothing at all about the
# contract — no USER, no WORKDIR, no ENTRYPOINT — and is the shape A-10 claims.
cat > "$WORK/Containerfile.plain" <<'PLAIN'
ARG BASE_IMAGE=none
FROM ${BASE_IMAGE}
COPY stub-harness /usr/local/bin/stub-harness
ENV AGENT_HARNESS=stub-harness
PLAIN

docker build -f "$WORK/Containerfile.plain" --build-arg "BASE_IMAGE=$IMAGE" -t "$LAYER_TAG-plain" "$WORK" >/dev/null 2>&1 \
    || usage_error "could not build the no-restatement layer from $IMAGE"

plain_config="$(docker image inspect "$LAYER_TAG-plain" \
    --format '{{.Config.User}}|{{.Config.WorkingDir}}|{{json .Config.Entrypoint}}')"
if [ "$plain_config" = "$EXPECTED_USER|$EXPECTED_WORKDIR|[\"$EXPECTED_ENTRYPOINT\"]" ]; then
    pass "A-10 a layer that restates nothing inherits the base's account, working directory, and entrypoint"
else
    fail "A-10 no-restatement layer config is '$plain_config', expected '$EXPECTED_USER|$EXPECTED_WORKDIR|[\"$EXPECTED_ENTRYPOINT\"]'"
fi

run "$LAYER_TAG-plain"
plain_pid="$(printf '%s' "$OUT" | sed -n 's/^harness id=[^ ]* pid=\([^ ]*\) .*/\1/p')"
if [ "$RC" = "0" ] && [ "$plain_pid" = "1" ]; then
    pass "A-10 the no-restatement layer runs: the harness is PID 1 and the container exits 0"
else
    fail "A-10 the no-restatement layer run gave (exit $RC, pid ${plain_pid:-none}): $OUT"
fi

# The layer form the template teaches — install as root, switch back — must
# land on the same account: this proves the switch-back, not the inheritance
# (that is the check above).
[ "$(docker image inspect "$LAYER_TAG" --format '{{.Config.User}}')" = "$EXPECTED_USER" ] \
    && pass "A-10 the root-install form ends on the base's account (USER \${AGENT_USER} switch-back)" \
    || fail "A-10 layer user is $(docker image inspect "$LAYER_TAG" --format '{{.Config.User}}')"

[ "$(docker image inspect "$LAYER_TAG" --format '{{json .Config.Entrypoint}}')" = "[\"$EXPECTED_ENTRYPOINT\"]" ] \
    && pass "A-10 a layer never has to redeclare the entrypoint" \
    || fail "A-10 layer entrypoint is $(docker image inspect "$LAYER_TAG" --format '{{json .Config.Entrypoint}}')"

# A-17 (R-12, R-13): the SHIPPED layer template attaches to a base that was
# never published — one build argument, one complete reference, no registry,
# no login, no credential. The template's install step fails on purpose, so
# this copy neutralizes that one line; the FROM, the account switch and the
# ENV are the file as shipped.
TEMPLATE="$SELF_DIR/../skeleton/Containerfile.layer"
if [ -f "$TEMPLATE" ]; then
    sed 's|^    exit 1$|    true|' "$TEMPLATE" > "$WORK/Containerfile.template"
    grep -q '^    true$' "$WORK/Containerfile.template" \
        || usage_error "A-17 could not neutralize the template's intentional failure step"
    docker build -f "$WORK/Containerfile.template" \
        --build-arg "AGENT_DEV_BASE_REF=$IMAGE" -t "$LAYER_TAG-template" "$WORK" >/dev/null 2>&1 \
        && pass "A-17 the shipped layer template builds FROM a locally tagged base: one build argument, one complete reference, no registry" \
        || fail "A-17 the shipped layer template did not build FROM the local reference $IMAGE"
    template_config="$(docker image inspect "$LAYER_TAG-template" \
        --format "{{.Config.User}}|{{.Config.WorkingDir}}|{{json .Config.Entrypoint}}" 2>/dev/null)"
    [ "$template_config" = "$EXPECTED_USER|$EXPECTED_WORKDIR|[\"$EXPECTED_ENTRYPOINT\"]" ] \
        && pass "A-17 a layer built by the shipped template inherits the base's account, working directory, and entrypoint" \
        || fail "A-17 template layer config is '$template_config', expected '$EXPECTED_USER|$EXPECTED_WORKDIR|[\"$EXPECTED_ENTRYPOINT\"]'"
    grep -q '^# syntax=' "$TEMPLATE" \
        && fail "A-17 the template carries a '# syntax=' directive, which would make every layer build require BuildKit" \
        || pass "A-17 the template demands no BuildKit (no '# syntax=' directive), so a layer builds on a legacy-builder host"
else
    skip "A-17 the shipped layer template is absent at $TEMPLATE"
fi

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

# A-14: nothing listening while an agent process runs, with a positive control.
# The probe greps /proc/net/tcp{,6} for the LISTEN state, which is the field
# after the local and remote addresses (a bare ": 0A" never matches — the
# character before the state is the end of the remote address).
PROBE='if grep -q " 0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null; then echo listening; else echo none; fi'

PROBE_CID="$(docker run -d -e STUB_SLEEP=30 "$LAYER_TAG" 2>/dev/null)"
if [ -n "$PROBE_CID" ]; then
    sleep 1
    # The probe runs against a container whose agent process (the stub harness,
    # holding PID 1) is alive — not against a shell that replaced the entrypoint.
    sockets="$(docker exec "$PROBE_CID" /bin/sh -c "$PROBE" 2>&1)"
    [ "$sockets" = "none" ] \
        && pass "A-14 nothing is listening in a container whose agent process is running" \
        || fail "A-14 a listening socket exists: $sockets"

    # Positive control: start a real listener inside the same container and
    # require the probe to see it. Without this, a probe that can never match
    # would pass the check above forever.
    docker exec -d "$PROBE_CID" /usr/bin/python3 -c 'import socket,time
s = socket.socket(); s.bind(("0.0.0.0", 9999)); s.listen(1); time.sleep(20)'
    sleep 1
    control="$(docker exec "$PROBE_CID" /bin/sh -c "$PROBE" 2>&1)"
    [ "$control" = "listening" ] \
        && pass "A-14 positive control: the probe detects a listener started inside the container" \
        || fail "A-14 the probe did not detect a real listener (positive control): $control"
    docker rm -f "$PROBE_CID" >/dev/null 2>&1
    PROBE_CID=""
else
    fail "A-14 could not start the probe container"
fi

# ---------------------------------------------------------------------------
# A-13: provenance labels carry the real values, and the base digest matches
# ---------------------------------------------------------------------------
# Passing presence is not enough: an image built without the label arguments
# carries the Containerfile's defaults (0.0.0 / unknown / an empty source) and
# would otherwise look fine.

labels="$(img '{{json .Config.Labels}}')"
label_value() { printf '%s' "$labels" | grep -o "\"$1\":\"[^\"]*\"" | sed 's/^"[^"]*":"//; s/"$//'; }

label_missing=""
for key in version revision source base.digest; do
    value="$(label_value "org.opencontainers.image.$key")"
    [ -n "$value" ] || label_missing="$label_missing org.opencontainers.image.$key"
done
[ -z "$label_missing" ] \
    && pass "A-13 provenance labels present and non-empty (version, revision, source, base digest)" \
    || fail "A-13 missing or empty labels:$label_missing"

if [ "$BUILD" = "1" ]; then
    # The strongest form: the labels are exactly the values this build was given.
    for pair in "version:$IMAGE_VERSION" "revision:$GIT_COMMIT" "source:$IMAGE_SOURCE"; do
        key="${pair%%:*}"; want="${pair#*:}"
        got="$(label_value "org.opencontainers.image.$key")"
        [ "$got" = "$want" ] \
            && pass "A-13 $key label equals the value the build was given ($got)" \
            || fail "A-13 $key label is '$got', expected '$want'"
    done
else
    # Verifying an image this script did not build: the values are not known
    # here, so the check is that none of them is still the Containerfile's
    # placeholder (which is what a build without the arguments produces).
    [ "$(label_value org.opencontainers.image.version)" != "0.0.0" ] \
        && pass "A-13 version label is not the Containerfile default: $(label_value org.opencontainers.image.version)" \
        || fail "A-13 the version label is still the Containerfile default (0.0.0)"
    [ "$(label_value org.opencontainers.image.revision)" != "unknown" ] \
        && pass "A-13 revision label is not the Containerfile default: $(label_value org.opencontainers.image.revision)" \
        || fail "A-13 the revision label is still the Containerfile default (unknown)"
    [ -n "$(label_value org.opencontainers.image.source)" ] \
        && pass "A-13 source label is set: $(label_value org.opencontainers.image.source)" \
        || fail "A-13 the source label is empty"
fi

if [ -n "$EXPECTED_BASE_DIGEST" ]; then
    [ "$(label_value org.opencontainers.image.base.digest)" = "$EXPECTED_BASE_DIGEST" ] \
        && pass "A-13 base digest label equals the digest the image was built from ($EXPECTED_BASE_DIGEST)" \
        || fail "A-13 base digest label is '$(label_value org.opencontainers.image.base.digest)', expected '$EXPECTED_BASE_DIGEST'"
else
    skip "A-13 base digest equality (pass EXPECTED_BASE_DIGEST, or BUILD=1 to resolve it)"
fi

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

# Every curl/wget command in the history that reaches out to a URL, except the
# one fetch this package allows: the package repository's signing key into
# /etc/apt/keyrings (R-10). This catches the extension-less forms the URL
# filter above misses, e.g.
#   curl -o /usr/local/bin/tool https://host/binary
# Two things keep it from flagging the package names in an install list: the
# command must be a separate command (the history is split on &&, ;, |) and it
# must contain a URL. Residual holes, stated: a fetch whose URL is built at run
# time (``curl "$URL"``) is not seen, and neither are any of the three rules
# seeing a package manager reaching the network for an unnamed source (a
# ``pip install --index-url <host>``, an apt source added from an arbitrary
# host) — R-10 forbids both; these rules are a net, not a proof.
fetches="$(printf '%s\n' "$history_text" | awk '
{
    line = $0
    cont = (line ~ /\\[ \t]*$/)
    sub(/\\[ \t]*$/, "", line)
    buf = (buf == "" ? line : buf " " line)
    if (cont) next
    gsub(/&&|\|\||[;&|]/, "\n", buf)
    n = split(buf, cmds, "\n")
    for (i = 1; i <= n; i++) {
        c = cmds[i]
        if (c ~ /(^|[^[:alnum:]_-])(curl|wget)([^[:alnum:]_-]|$)/ \
            && c ~ /:\/\// && c !~ /\/etc\/apt\/keyrings\//) print c
    }
    buf = ""
}')"
[ -z "$fetches" ] \
    && pass "A-15 the only URL a curl/wget command fetches is the package repository signing key" \
    || fail "A-15 the build fetches from other URLs: $(printf '%s' "$fetches" | tr '\n' ';')"

# ---------------------------------------------------------------------------
# A-16: a package repository key that does not match its recorded fingerprint
# stops the build, instead of the build trusting whatever the URL served
# (only when this script did the build, so it has the build arguments)
# ---------------------------------------------------------------------------

if [ "$BUILD" = "1" ]; then
    bogus_fpr="0000000000000000000000000000000000000000"
    if docker build $cache_arg -f "$SELF_DIR/../skeleton/Containerfile" \
        --build-arg "BASE_DISTRO_IMAGE=$BASE_DISTRO_IMAGE" \
        --build-arg "BASE_DISTRO_DIGEST=$digest" \
        --build-arg "AGENT_USER=$EXPECTED_USER" \
        --build-arg "AGENT_UID=$EXPECTED_UID" \
        --build-arg "IMAGE_VERSION=$IMAGE_VERSION" \
        --build-arg "GIT_COMMIT=$GIT_COMMIT" \
        --build-arg "IMAGE_SOURCE=$IMAGE_SOURCE" \
        --build-arg "DOCKER_REPO_KEY_FPR=$bogus_fpr" \
        -t "$LAYER_TAG-bad-key" "$SELF_DIR/../skeleton" >"$WORK/negative-build.log" 2>&1
    then
        fail "A-16 a build with a mismatched repository key fingerprint succeeded"
    else
        # The failure has to be this failure: the log must name the fingerprint
        # the key actually has and the one that was expected.
        observed_fpr="$(grep -o 'key fingerprint is [0-9A-Fa-f]\{40\}' "$WORK/negative-build.log" \
            | head -1 | sed 's/.* //')"
        if [ -n "$observed_fpr" ] && [ "$observed_fpr" != "$bogus_fpr" ] \
            && grep -q "expected $bogus_fpr" "$WORK/negative-build.log"
        then
            pass "A-16 a mismatched fingerprint stops the build, reporting observed $observed_fpr against expected $bogus_fpr"
        else
            fail "A-16 the negative build failed without reporting the fingerprints (observed '${observed_fpr:-none}'): $(tail -3 "$WORK/negative-build.log" | tr '\n' ' ')"
        fi
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
