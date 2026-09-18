#!/bin/sh
# Acceptance checks for the multiplexed agent host.
#
# Implements the mechanical checks of SCHEMATIC.md's Verification and
# Acceptance section against a real herdr, inside a real container. It has two
# halves and runs both:
#
#   * the DRIVER half runs on the deployment host. It inspects the image,
#     creates and starts one container, reads what that container reports,
#     removes it, starts a second container on the same bind-mounted tree to
#     prove persistence, and cleans everything up.
#   * the BODY half (`--inside`) runs as that container's process. It prepares a
#     throwaway agent tree, a stub harness, and a throwaway SSH keypair; runs the
#     boot program; and drives one real herdr through the whole lifecycle —
#     workspaces by agent id, a crash that comes back, a clean exit that does
#     not, the crash-loop bound, the stop marker, the restored session after a
#     recreate, and the SSH parity triad that remote attach needs.
#
# The stub harness stands in for a real one: it writes its identity, appends to
# a session file in its home, and then crashes, exits cleanly, or kills itself
# in a loop, depending on a mode file. Nothing about the host's behaviour
# depends on which harness runs, which is the point — this package is
# harness-free by construction.
#
# Inputs (environment; none of these is written anywhere):
#   IMAGE              image ref to test           (no default; required)
#   BASE_IMAGE         the base ref the image was built from, for the
#                      entrypoint-refusal check (A-12). Optional.
#   EXPECTED_USER      runtime account name        (default: user)
#   EXPECTED_ENTRYPOINT  the base image's entrypoint
#                      (default: /usr/local/bin/agent-entrypoint)
#   EXPECTED_WORKDIR   the base image's working directory (default: /workspace)
#   EXPECTED_HERDR_VERSION  herdr version the image should carry (default: 0.9.0)
#   PUBLISHED_IMAGE    a pushed reference of this same image, for the
#                      two-platform manifest check (A-16; skipped when unset)
#   AGENT_IDS          agents the probe host runs  (default: alpha,beta)
#   HERDR_SESSION      herdr session name          (default: agents)
#   TREE_HOST_DIR      host directory mounted as the agent tree
#                      (default: ./agent-host-verify)
#   TREE_LOCAL_DIR     the same directory as THIS script sees it, for the checks
#                      that read the tree directly. Set it when the container
#                      runtime's filesystem is not this script's (default:
#                      TREE_HOST_DIR)
#   PACKAGE_HOST_DIR   the same package, expressed as a path the container
#                      runtime resolves on ITS host. Needed only when this
#                      script runs somewhere the runtime does not share a
#                      filesystem with, e.g. inside a container driving an
#                      outside daemon (default: this script's own package dir)
#   USE_PACKAGE_FILES  1 = run the boot program, plugin and config template from
#                      this package (the verification mode: it tests the shipped
#                      files) ; 0 = use the copies inside IMAGE (default: 1)
#   CONTAINER_RUNTIME  docker CLI name             (default: docker)
#   CONTAINER_USER     run the probe containers as this account. Unset uses the
#                      image's own USER, which is what a layer built from the
#                      base carries; set it when the deployment names the
#                      account at run time instead (as the compose fragment does)
#   KEEP               1 = keep the agent tree and the containers
#   STUB_ENTRYPOINT    1 = stand in an entrypoint for the base's, inside the
#                      agent tree, and point AGENT_ENTRYPOINT at it. This exists
#                      for the case where the base image cannot be built or
#                      pulled on the verifying machine: the host's own logic —
#                      workspaces, supervision, attach, persistence — is then
#                      still exercised end to end, while everything that depends
#                      on the base's own contract is a SKIP with that reason.
#                      Leave it off when verifying a real layer over the base.
#   AGENT_ENTRYPOINT   passthrough for the account the panes run (see above)
#
# Containers are created and started explicitly, never through `docker run`:
# attaching is not required to run them, so this works on hosts (and from
# containers) where a client may create and start but not attach.
#
# Exit status: 0 when every executed check passed; 1 when any failed; 2 on a
# usage or precondition error.
set -u

IMAGE="${IMAGE:-}"
BASE_IMAGE="${BASE_IMAGE:-}"
EXPECTED_USER="${EXPECTED_USER:-user}"
EXPECTED_ENTRYPOINT="${EXPECTED_ENTRYPOINT:-/usr/local/bin/agent-entrypoint}"
EXPECTED_WORKDIR="${EXPECTED_WORKDIR:-/workspace}"
EXPECTED_HERDR_VERSION="${EXPECTED_HERDR_VERSION:-0.9.0}"
PUBLISHED_IMAGE="${PUBLISHED_IMAGE:-}"
AGENT_IDS="${AGENT_IDS:-alpha,beta}"
HERDR_SESSION="${HERDR_SESSION:-agents}"
TREE_HOST_DIR="${TREE_HOST_DIR:-}"
USE_PACKAGE_FILES="${USE_PACKAGE_FILES:-1}"
PACKAGE_HOST_DIR="${PACKAGE_HOST_DIR:-}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
CONTAINER_USER="${CONTAINER_USER:-}"
KEEP="${KEEP:-0}"
STUB_ENTRYPOINT="${STUB_ENTRYPOINT:-0}"
AGENT_ENTRYPOINT="${AGENT_ENTRYPOINT:-}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SELF_DIR/.." && pwd)"

CHECKS=0
FAILURES=0
SKIPS=0

pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'SKIP  %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }
usage_error() { printf 'verify-agent-host: %s\n' "$1" >&2; exit 2; }

rt() { "$CONTAINER_RUNTIME" "$@"; }

# ---------------------------------------------------------------------------
# Body: the in-container half
# ---------------------------------------------------------------------------

body() {
    TREE="${AGENT_TREE:-/agents}"
    PROBE="$TREE/.probe"
    XDG="${XDG_CONFIG_HOME:-$TREE/.config}"
    SSHD_DIR="${AGENT_SSHD_DIR:-$TREE/sshd}"
    STATE_ROOT="${AGENT_STATE_ROOT:-$TREE/.state}"
    PORT="${AGENT_SSH_PORT:-2222}"
    HOST_USER="$(id -un)"
    export AGENT_TREE="$TREE" AGENT_IDS="$AGENT_IDS" HERDR_SESSION="$HERDR_SESSION"
    export XDG_CONFIG_HOME="$XDG" AGENT_SSHD_DIR="$SSHD_DIR" AGENT_STATE_ROOT="$STATE_ROOT"
    export AGENT_SSH_PORT="$PORT" AGENT_SSH_LISTEN="${AGENT_SSH_LISTEN:-127.0.0.1}"
    export AGENT_SSH_AUTHORIZED_KEYS="$PROBE/authorized_keys"
    export AGENT_BOOT_FOREGROUND=0 PROBE_DIR="$PROBE"
    export AGENT_HARNESS="$PROBE/harness.sh"
    if [ "$USE_PACKAGE_FILES" = "1" ]; then
        export AGENT_PLUGIN_ROOT="${AGENT_PLUGIN_ROOT:-/verify-pkg/skeleton}"
        export AGENT_HERDR_CONFIG_TEMPLATE="${AGENT_HERDR_CONFIG_TEMPLATE:-/verify-pkg/skeleton/herdr-config.toml}"
        BOOT="${BOOT_PROGRAM:-/verify-pkg/skeleton/agent-host-boot.sh}"
    else
        BOOT="${BOOT_PROGRAM:-/usr/local/bin/agent-host-boot}"
    fi
    [ -f "$BOOT" ] || usage_error "the boot program $BOOT is not in this container"

    mkdir -p "$PROBE" "$TREE" "$SSHD_DIR" "$STATE_ROOT" || usage_error "cannot create the agent tree under $TREE"
    printf 'crash\n' >"$PROBE/mode"
    : >"$PROBE/starts.log"

    if [ "$STUB_ENTRYPOINT" = "1" ]; then
        cat >"$PROBE/entrypoint.sh" <<'ENTRY'
#!/bin/sh
# Stand-in for the base image's entrypoint, for machines where the base image
# cannot be built. It implements only the part this host depends on: refuse with
# 78 naming AGENT_HARNESS when it is unset, otherwise run the harness in the
# agent's workspace, replacing this process.
set -u
if [ -z "${AGENT_HARNESS:-}" ]; then
    printf 'agent-entrypoint: AGENT_HARNESS is not set\n' >&2
    exit 78
fi
if [ -n "${AGENT_WORKSPACE_DIR:-}" ]; then
    [ -d "$AGENT_WORKSPACE_DIR" ] || { printf 'agent-entrypoint: workspace %s is not a directory\n' "$AGENT_WORKSPACE_DIR" >&2; exit 78; }
    cd "$AGENT_WORKSPACE_DIR" || exit 78
fi
exec "$AGENT_HARNESS"
ENTRY
        chmod 0755 "$PROBE/entrypoint.sh"
        export AGENT_ENTRYPOINT="$PROBE/entrypoint.sh"
        printf '      note: STUB_ENTRYPOINT=1 — the base image is not present, so a stand-in entrypoint is used; checks that depend on the base contract report SKIP\n'
    fi

    cat >"$AGENT_HARNESS" <<'STUB'
#!/bin/sh
# Stub harness: stands in for a coding-agent CLI. Records its start, appends to
# a session file in its home (the state a real harness resumes from), reads its
# mode, then behaves accordingly.
set -u
PROBE="${PROBE_DIR:-/agents/.probe}"
printf '%s agent=%s pid=%s uid=%s cwd=%s home=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$AGENT_ID" "$$" "$(id -u)" "$PWD" "$HOME" >>"$PROBE/starts.log"
printf '%s\n' "$$" >"$PROBE/agent-$AGENT_ID.pid"
[ -d "$HOME" ] && printf 'start %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$HOME/.probe-session"
case "$(cat "$PROBE/mode" 2>/dev/null || echo crash)" in
    clean) exit 0 ;;
    exit7) exit 7 ;;
    crashloop) kill -9 $$ ;;
    *) exec sleep 900 ;;
esac
STUB
    chmod 0755 "$AGENT_HARNESS"

    rm -f "$PROBE/client" "$PROBE/client.pub"
    ssh-keygen -q -t ed25519 -f "$PROBE/client" -N "" || usage_error "ssh-keygen is unavailable in this container"
    cp "$PROBE/client.pub" "$AGENT_SSH_AUTHORIZED_KEYS"

    boot() { sh "$BOOT" >"$1" 2>&1; printf '%s\n' "$?"; }

    ws_id_of() { herdr workspace list 2>/dev/null | jq -r --arg l "$1" '.result.workspaces[]? | select(.label == $l) | .workspace_id' 2>/dev/null; }
    panes_of() { herdr pane list --workspace "$1" 2>/dev/null | jq -r '.result.panes[]?.label // "shell"' 2>/dev/null; }
    agent_pane_of() { herdr pane list --workspace "$1" 2>/dev/null | jq -r '[.result.panes[]? | select(.label == "agent")] | length' 2>/dev/null; }
    starts_of() { grep -c "agent=$1 " "$PROBE/starts.log" 2>/dev/null || echo 0; }
    kill_agent() {
        [ -f "$PROBE/agent-$1.pid" ] || return 1
        kill -9 "$(cat "$PROBE/agent-$1.pid")" 2>/dev/null || return 1
        return 0
    }
    wait_stub_alive() { i=0; while [ "$i" -lt "${1:-20}" ]; do stub_alive "$first_id" && return 0; i=$((i + 1)); sleep 1; done; return 1; }
    wait_stub_dead() { i=0; while [ "$i" -lt "${1:-20}" ]; do stub_alive "$first_id" || return 0; i=$((i + 1)); sleep 1; done; return 1; }
    wait_starts_gt() { i=0; while [ "$i" -lt "${2:-20}" ]; do [ "$(starts_of "$first_id")" -gt "$1" ] && return 0; i=$((i + 1)); sleep 1; done; return 1; }
    wait_log_match() { i=0; while [ "$i" -lt "${2:-30}" ]; do grep -q "$1" "$STATE_ROOT/$first_id/loop.log" 2>/dev/null && return 0; i=$((i + 1)); sleep 1; done; return 1; }
    session_running() { herdr session list --json 2>/dev/null | jq -r --arg s "$HERDR_SESSION" '.sessions[]? | select(.name == $s) | .running' 2>/dev/null | grep -q true; }
    stub_alive() { [ -f "$PROBE/agent-$1.pid" ] && kill -0 "$(cat "$PROBE/agent-$1.pid")" 2>/dev/null; }
    session_lines() { [ -f "$TREE/$1/home/.probe-session" ] && wc -l <"$TREE/$1/home/.probe-session" | tr -d ' ' || echo 0; }
    first_id="${AGENT_IDS%%,*}"
    second_id=""
    case "$AGENT_IDS" in *,*) second_id="$(printf '%s' "$AGENT_IDS" | cut -d, -f2)" ;; esac

    # --- boot, and the workspace model (R-2, R-12) ---------------------------
    RC=$(boot "$PROBE/boot1.log")
    if [ "$RC" != "0" ]; then
        fail "A-2: the boot program exits 0 (it exited $RC; see the log below)"
        sed 's/^/      | /' "$PROBE/boot1.log"
        return 1
    fi
    if session_running; then
        pass "A-2: the herdr session $HERDR_SESSION is running after boot"
    else
        fail "A-2: the herdr session $HERDR_SESSION is not running after boot"
    fi
    WS_COUNT_AFTER_BOOT1=$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces | length' 2>/dev/null)
    LABELS=$(herdr workspace list 2>/dev/null | jq -r '[.result.workspaces[]?.label] | sort | join(",")' 2>/dev/null)
    EXPECTED_LABELS=$(printf '%s' "$AGENT_IDS" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
    if [ "$LABELS" = "$EXPECTED_LABELS" ]; then
        pass "A-2: exactly one workspace per configured agent id, labelled with the id ($LABELS)"
    else
        fail "A-2: workspace labels are '$LABELS', expected '$EXPECTED_LABELS'"
    fi

    # --- the agent process (R-3, R-11) ---------------------------------------
    wait_stub_alive 20 \
        && pass "A-3: agent $first_id runs (its pane's wrapper started it)" \
        || fail "A-3: agent $first_id never started; starts.log has $(starts_of "$first_id") entries"
    LINE=$(grep "agent=$first_id " "$PROBE/starts.log" 2>/dev/null | tail -1)
    note "$LINE"
    HOME_SEEN=$(printf '%s' "$LINE" | sed -n 's/.*home=\(.*\)$/\1/p')
    CWD_SEEN=$(printf '%s' "$LINE" | sed -n 's/.*cwd=\([^ ]*\) home.*/\1/p')
    [ "$HOME_SEEN" = "$TREE/$first_id/home" ] \
        && pass "A-3: the agent runs with HOME set to its own home ($HOME_SEEN)" \
        || fail "A-3: the agent's HOME is '$HOME_SEEN', expected '$TREE/$first_id/home'"
    [ "$CWD_SEEN" = "$TREE/$first_id/workspace" ] \
        && pass "A-3: the agent runs in its own workspace directory ($CWD_SEEN)" \
        || fail "A-3: the agent's working directory is '$CWD_SEEN', expected '$TREE/$first_id/workspace'"
    UID_SEEN=$(printf '%s' "$LINE" | sed -n 's/.*uid=\([0-9]*\).*/\1/p')
    if [ -n "$UID_SEEN" ] && [ "$UID_SEEN" != "0" ]; then
        pass "A-11: every agent process runs as a non-root account (uid $UID_SEEN)"
    else
        fail "A-11: the agent runs with uid '${UID_SEEN:-unknown}'; the base's account is never root"
    fi

    # --- the pinned multiplexer (R-13) ---------------------------------------
    VERSION_SEEN=$(herdr --version 2>/dev/null | awk '{print $NF}')
    [ "$VERSION_SEEN" = "$EXPECTED_HERDR_VERSION" ] \
        && pass "A-14: herdr runs at the pinned version ($VERSION_SEEN)" \
        || fail "A-14: herdr reports '$VERSION_SEEN', expected '$EXPECTED_HERDR_VERSION'"
    if grep -q 'version_check = false' "$XDG/herdr/config.toml" 2>/dev/null && grep -q '^onboarding = false' "$XDG/herdr/config.toml" 2>/dev/null; then
        pass "A-14: the installed config disables onboarding and both background checks"
    else
        fail "A-14: $XDG/herdr/config.toml does not carry onboarding = false and version_check = false"
    fi

    # --- crash: relaunched in the same pane (R-4, R-14) ----------------------
    WS1=$(ws_id_of "$first_id")
    PANE_BEFORE=$(herdr pane list --workspace "$WS1" 2>/dev/null | jq -r '[.result.panes[]? | select(.label == "agent")] | .[0].pane_id' 2>/dev/null)
    BEFORE=$(starts_of "$first_id")
    kill_agent "$first_id" || fail "A-4: the probe could not signal its own stub agent"
    if wait_starts_gt "$BEFORE" 20; then
        PANE_AFTER=$(herdr pane list --workspace "$WS1" 2>/dev/null | jq -r '[.result.panes[]? | select(.label == "agent")] | .[0].pane_id' 2>/dev/null)
        if [ -n "$PANE_AFTER" ] && [ "$PANE_AFTER" = "$PANE_BEFORE" ]; then
            pass "A-4: a killed agent is relaunched inside the same pane ($PANE_AFTER) — the workspace never tears down"
        else
            fail "A-4: the agent came back, but in pane '${PANE_AFTER:-none}' rather than '$PANE_BEFORE'"
        fi
        grep -q 'death by signal, relaunching' "$STATE_ROOT/$first_id/loop.log" 2>/dev/null \
            && pass "A-4: the supervision log records the crash and the relaunch" \
            || fail "A-4: the supervision log does not record a crash relaunch"
    else
        fail "A-4: a killed agent did not come back within 20s (starts: $BEFORE -> $(starts_of "$first_id"))"
    fi

    # --- clean exit: stays closed (R-4) --------------------------------------
    printf 'clean\n' >"$PROBE/mode"
    BEFORE=$(starts_of "$first_id")
    kill_agent "$first_id"
    wait_stub_dead 20
    sleep 3
    if [ -f "$STATE_ROOT/$first_id/stop" ]; then
        pass "A-5: a clean exit writes the agent's stop marker"
    else
        fail "A-5: a clean exit did not write $STATE_ROOT/$first_id/stop"
    fi
    if [ "$(starts_of "$first_id")" -gt "$BEFORE" ] && ! stub_alive "$first_id"; then
        pass "A-5: the agent stayed down after its clean exit (one relaunch to observe the exit, no loop)"
    elif [ "$(starts_of "$first_id")" = "$BEFORE" ]; then
        fail "A-5: the agent never restarted to observe the clean-exit path"
    else
        fail "A-5: the agent kept running after a clean exit"
    fi
    grep -q 'a clean exit' "$STATE_ROOT/$first_id/loop.log" 2>/dev/null \
        && pass "A-5: the supervision log names the clean exit and the marker path" \
        || fail "A-5: the supervision log does not name the clean exit"

    # --- the stop marker holds through a boot (R-5, R-6) ---------------------
    printf 'crash\n' >"$PROBE/mode"
    if [ -n "$second_id" ]; then
        mkdir -p "$STATE_ROOT/$second_id"
        : >"$STATE_ROOT/$second_id/stop"
    fi
    rm -f "$STATE_ROOT/$first_id/stop"
    WS_BEFORE="${WS_COUNT_AFTER_BOOT1:-0}"
    SESSION_BEFORE=$(session_lines "$first_id")
    RC=$(boot "$PROBE/boot2.log")
    [ "$RC" = "0" ] && pass "A-15: a second boot on a live host exits 0 (idempotent re-run)" \
        || fail "A-15: the second boot exited $RC"
    WS_AFTER=$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces | length')
    [ "$WS_BEFORE" = "$WS_AFTER" ] \
        && pass "A-15: the second boot leaves the same number of workspaces as the first ($WS_AFTER), not one more per agent" \
        || fail "A-15: workspaces went from $WS_BEFORE after the first boot to $WS_AFTER after the second"
    LABELS=$(herdr workspace list 2>/dev/null | jq -r '[.result.workspaces[]?.label] | sort | join(",")')
    [ "$LABELS" = "$EXPECTED_LABELS" ] \
        && pass "A-15: exactly one workspace per agent id after the second boot ($LABELS)" \
        || fail "A-15: workspace labels are '$LABELS' after the second boot, expected '$EXPECTED_LABELS'"
    if [ -n "$second_id" ]; then
        WS2=$(ws_id_of "$second_id")
        if [ -n "$WS2" ] && [ "$(agent_pane_of "$WS2")" = "0" ]; then
            pass "A-6: a stopped agent ($second_id) keeps its workspace but gets no agent pane"
        else
            fail "A-6: a stopped agent ($second_id) has $(agent_pane_of "$WS2") agent pane(s); the marker must win over the boot"
        fi
        grep -q "agent $second_id is stopped" "$PROBE/boot2.log" 2>/dev/null \
            && pass "A-6: the boot names the stopped agent and what it did instead" \
            || fail "A-6: the boot log does not name the stopped agent $second_id"
    else
        skip "A-6: needs two agent ids (AGENT_IDS has one)"
    fi
    if wait_stub_alive 20; then
        pass "A-6: a live agent is running again after the second boot"
    else
        fail "A-6: agent $first_id is not running after the second boot"
    fi
    SESSION_AFTER=$(session_lines "$first_id")
    if [ "${SESSION_AFTER:-0}" -gt "${SESSION_BEFORE:-0}" ]; then
        pass "A-10: the agent's home survived the reconcile and its session continued there ($SESSION_BEFORE -> $SESSION_AFTER)"
    else
        fail "A-10: the agent's session file did not grow across the second boot ($SESSION_BEFORE -> $SESSION_AFTER)"
    fi

    # --- the crash-loop bound (R-5) -------------------------------------------
    rm -f "$STATE_ROOT/$first_id/launches"
    printf 'crashloop\n' >"$PROBE/mode"
    kill_agent "$first_id"
    if wait_log_match 'backing off' 30; then
        pass "A-7: a crashing agent hits the crash-loop bound and backs off instead of spinning"
    else
        fail "A-7: no backoff appeared after repeated crashes; see $STATE_ROOT/$first_id/loop.log"
    fi
    printf 'crash\n' >"$PROBE/mode"
    rm -f "$STATE_ROOT/$first_id/launches"

    # --- the plugin fallback: the wrapper itself dies (R-14) -----------------
    WS1=$(ws_id_of "$first_id")
    PANE_BEFORE=$(herdr pane list --workspace "$WS1" 2>/dev/null | jq -r '[.result.panes[]? | select(.label == "agent")] | .[0].pane_id' 2>/dev/null)
    STARTS_BEFORE=$(starts_of "$first_id")
    WRAPPERS=$(pgrep -f 'agent-loop.sh' 2>/dev/null | tr '\n' ' ')
    if [ -n "$WRAPPERS" ]; then
        # The pane's process is the wrapper. Killing it is the one failure the
        # wrapper cannot survive, and the pane.exited hook is what must answer.
        for p in $WRAPPERS; do kill -9 "$p" 2>/dev/null || true; done
        i=0
        while [ "$i" -lt 30 ]; do
            WS_NOW=$(ws_id_of "$first_id")
            PANE_NOW=$(herdr pane list --workspace "$WS_NOW" 2>/dev/null | jq -r '[.result.panes[]? | select(.label == "agent")] | .[0].pane_id' 2>/dev/null)
            [ -n "$PANE_NOW" ] && [ "$PANE_NOW" != "$PANE_BEFORE" ] && break
            i=$((i + 1))
            sleep 1
        done
        if [ -n "${PANE_NOW:-}" ] && [ "$PANE_NOW" != "$PANE_BEFORE" ] && [ "$(starts_of "$first_id")" -gt "$STARTS_BEFORE" ]; then
            pass "A-8: when the pane's own process is killed, the pane.exited hook puts an agent pane back ($PANE_BEFORE -> $PANE_NOW)"
        else
            fail "A-8: killing the wrapper left no agent pane (was $PANE_BEFORE, now '${PANE_NOW:-none}')"
        fi
    else
        fail "A-8: no agent-loop.sh process found to kill; the pane is not running the wrapper"
    fi

    # --- the SSH parity triad (R-8) -------------------------------------------
    SSHD_PID=$(cat "$SSHD_DIR/sshd.pid" 2>/dev/null || echo "")
    if [ -n "$SSHD_PID" ] && kill -0 "$SSHD_PID" 2>/dev/null; then
        pass "A-9: the SSH daemon is running (pid $SSHD_PID)"
    else
        fail "A-9: no SSH daemon is running from $SSHD_DIR"
    fi
    grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHD_DIR/sshd_config" 2>/dev/null \
        && pass "A-9: key-only authentication is configured (PasswordAuthentication no)" \
        || fail "A-9: $SSHD_DIR/sshd_config does not disable password authentication"
    SRV_PID=$(pgrep -f 'herdr server' 2>/dev/null | head -1)
    if [ -n "$SRV_PID" ]; then
        SID=$(ps -o sid= -p "$SRV_PID" 2>/dev/null | tr -d ' ')
        [ "$SID" = "$SRV_PID" ] \
            && pass "A-9: the herdr server is its own session leader (pid $SRV_PID == sid), which herdr --remote requires" \
            || fail "A-9: the herdr server runs in session $SID, not its own; remote attach would demand a restart"
        if tr '\0' '\n' <"/proc/$SRV_PID/environ" 2>/dev/null | grep -qx "XDG_CONFIG_HOME=$XDG" \
            && tr '\0' '\n' <"/proc/$SRV_PID/environ" 2>/dev/null | grep -qx "HERDR_SESSION=$HERDR_SESSION"; then
            pass "A-9: the server's environment carries the config root and session the SSH sessions are told to use"
        else
            fail "A-9: the server's environment does not match $XDG / $HERDR_SESSION"
        fi
    else
        fail "A-9: no herdr server process found to check the session-leader requirement"
    fi
    SSH_OUT=$(ssh -p "$PORT" -i "$PROBE/client" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes "$HOST_USER@127.0.0.1" \
        'echo "XDG=$XDG_CONFIG_HOME SESSION=$HERDR_SESSION"; herdr session list --json; herdr workspace list | jq -r "[.result.workspaces[]?.label] | sort | join(\",\")"' 2>&1)
    note "$(printf '%s' "$SSH_OUT" | tr '\n' ' ')"
    case "$SSH_OUT" in
        *"XDG=$XDG SESSION=$HERDR_SESSION"*) pass "A-9: an SSH session carries the server's config root and session (SetEnv parity)" ;;
        *) fail "A-9: an SSH session did not carry the server's environment; remote herdr commands would resolve a different session" ;;
    esac
    case "$SSH_OUT" in
        *'"running":true'*) pass "A-9: the real session is listed as running from inside an SSH session" ;;
        *) fail "A-9: the session is not reported running over SSH" ;;
    esac
    case "$SSH_OUT" in
        *"$EXPECTED_LABELS"*) pass "A-9: the agent workspaces are visible over SSH ($EXPECTED_LABELS)" ;;
        *) fail "A-9: the agent workspaces are not visible over SSH" ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# Driver: the host-side half
# ---------------------------------------------------------------------------

driver() {
    [ -n "$IMAGE" ] || usage_error "set IMAGE to the image under test"
    command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 || usage_error "$CONTAINER_RUNTIME is not on PATH"
    rt image inspect "$IMAGE" >/dev/null 2>&1 || usage_error "image $IMAGE is not present on this host"
    [ -f "$PACKAGE_DIR/scripts/verify-agent-host.sh" ] || usage_error "this script is not inside the package it verifies"

    PACKAGE_HOST_DIR="${PACKAGE_HOST_DIR:-$PACKAGE_DIR}"
    TREE_HOST_DIR="${TREE_HOST_DIR:-$PWD/agent-host-verify}"
    # USER_ARGS is empty unless the deployment names the account at run time;
    # PKG_ARGS is the read-only mount this script's own package is verified from.
    USER_ARGS=""
    [ -n "$CONTAINER_USER" ] && USER_ARGS="-u $CONTAINER_USER"
    if [ "$USE_PACKAGE_FILES" = "1" ]; then
        PKG_ARGS="-v $PACKAGE_HOST_DIR:/verify-pkg:ro"
    else
        PKG_ARGS=""
    fi
    TREE_LOCAL_DIR="${TREE_LOCAL_DIR:-$TREE_HOST_DIR}"
    mkdir -p "$TREE_LOCAL_DIR" || usage_error "cannot create the agent tree at $TREE_LOCAL_DIR; when the runtime sees it at a different path, set TREE_HOST_DIR to that path and TREE_LOCAL_DIR to this one"
    TREE_LOCAL_DIR="$(cd "$TREE_LOCAL_DIR" && pwd)"

    # The host's own knobs, passed through when this script's environment names
    # them, so a deployment's values can be verified rather than assumed.
    EXTRA_ARGS=""
    for name in AGENT_SSH_ENABLE AGENT_SSH_PORT AGENT_SSH_LISTEN AGENT_CRASH_LIMIT AGENT_CRASH_WINDOW AGENT_CRASH_BACKOFF AGENT_REOPEN_LIMIT AGENT_REOPEN_WINDOW AGENT_REOPEN_BACKOFF; do
        eval "value=\${$name:-}"
        [ -n "$value" ] && EXTRA_ARGS="$EXTRA_ARGS -e $name=$value"
    done
    NAME="agent-host-verify-$$"
    NAME2="$NAME-recreate"
    CREATED=""

    cleanup() {
        for c in $CREATED; do rt rm -f "$c" >/dev/null 2>&1 || true; done
        if [ "$KEEP" != "1" ]; then rm -rf "$TREE_LOCAL_DIR"; fi
    }
    trap cleanup EXIT INT TERM

    # start <name> <image> <mount tree?> <entrypoint> <args...>
    start_container() {
        cname="$1"
        shift
        rt create --label org.testcontainers=true --name "$cname" "$@" >/dev/null 2>&1 \
            || { printf ''; return 1; }
        CREATED="$CREATED $cname"
        rt start "$cname" >/dev/null 2>&1 || return 1
        i=0
        while [ "$i" -lt 180 ]; do
            st=$(rt inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo missing)
            [ "$st" = "exited" ] && return 0
            [ "$st" = "missing" ] && return 1
            i=$((i + 1))
            sleep 1
        done
        return 1
    }
    logs_of() { rt logs "$1" 2>&1; }

    printf '== image ==\n'
    INSPECT=$(rt image inspect "$IMAGE" --format '{{.Config.User}}|{{.Config.WorkingDir}}|{{json .Config.Entrypoint}}|{{json .Config.ExposedPorts}}' 2>/dev/null)
    USER_SEEN=$(printf '%s' "$INSPECT" | cut -d'|' -f1)
    WORKDIR_SEEN=$(printf '%s' "$INSPECT" | cut -d'|' -f2)
    ENTRY_SEEN=$(printf '%s' "$INSPECT" | cut -d'|' -f3)
    PORTS_SEEN=$(printf '%s' "$INSPECT" | cut -d'|' -f4)
    [ "$PORTS_SEEN" = "null" ] \
        && pass "A-13: the image declares no port" \
        || fail "A-13: the image declares ExposedPorts $PORTS_SEEN; inbound exposure is the deployment's decision"

    # Is this image a layer over the base? A-1 and A-12 ask about properties
    # inherited from the base, so they can only be answered against an image
    # built from it. The probe below decides, and the two checks report a skip
    # with that reason rather than a pass or a failure they cannot support.
    ENTRY_PROBE="test -x $EXPECTED_ENTRYPOINT && echo present || echo absent"
    start_container "$NAME-base" $USER_ARGS --entrypoint /bin/sh "$IMAGE" -c "$ENTRY_PROBE" >/dev/null 2>&1
    BASE_HAS_ENTRYPOINT=$(logs_of "$NAME-base" 2>/dev/null | tr -d '\r')
    case "$BASE_HAS_ENTRYPOINT" in
        *present*)
            [ "$USER_SEEN" = "$EXPECTED_USER" ] \
                && pass "A-1: the image's account is the base's ($USER_SEEN)" \
                || fail "A-1: the image's account is '$USER_SEEN', expected '$EXPECTED_USER'"
            [ "$WORKDIR_SEEN" = "$EXPECTED_WORKDIR" ] \
                && pass "A-1: the image's working directory is the base's ($WORKDIR_SEEN)" \
                || fail "A-1: the image's working directory is '$WORKDIR_SEEN', expected '$EXPECTED_WORKDIR' (the layer must not change it)"
            case "$ENTRY_SEEN" in
                *"$EXPECTED_ENTRYPOINT"*) pass "A-12: the image's entrypoint is the base's ($ENTRY_SEEN), unchanged by the layer" ;;
                *) fail "A-12: the image's entrypoint is '$ENTRY_SEEN', expected to contain '$EXPECTED_ENTRYPOINT'" ;;
            esac
            start_container "$NAME-default" $USER_ARGS "$IMAGE" >/dev/null 2>&1 || true
            DEFAULT_OUT=$(logs_of "$NAME-default" 2>/dev/null)
            printf '%s\n' "$DEFAULT_OUT" | sed 's/^/      | /'
            case "$DEFAULT_OUT" in
                *AGENT_HARNESS*) pass "A-12: started without the host override, the image behaves as the base and refuses, naming AGENT_HARNESS" ;;
                *) fail "A-12: the image did not refuse as the base does when started without AGENT_HARNESS" ;;
            esac
            ;;
        *)
            skip "A-1: $EXPECTED_ENTRYPOINT is not in $IMAGE, so this is not a layer over the base the package pins — the account and working directory cannot be checked here"
            skip "A-12: $EXPECTED_ENTRYPOINT is not in $IMAGE, so the base's refusal cannot be exercised here"
            ;;
    esac

    printf '\n== the host: boot, lifecycle, attach ==\n'
    if start_container "$NAME" \
        -v "$TREE_HOST_DIR:/agents" $PKG_ARGS $USER_ARGS $EXTRA_ARGS \
        -e "AGENT_IDS=$AGENT_IDS" -e "HERDR_SESSION=$HERDR_SESSION" \
        -e "AGENT_TREE=/agents" -e "XDG_CONFIG_HOME=/agents/.config" \
        -e "AGENT_SSHD_DIR=/agents/sshd" -e "AGENT_STATE_ROOT=/agents/.state" \
        -e "USE_PACKAGE_FILES=$USE_PACKAGE_FILES" -e "EXPECTED_HERDR_VERSION=$EXPECTED_HERDR_VERSION" \
        -e "STUB_ENTRYPOINT=$STUB_ENTRYPOINT" -e "AGENT_ENTRYPOINT=$AGENT_ENTRYPOINT" \
        --entrypoint /bin/sh "$IMAGE" \
        -c "USE_PACKAGE_FILES=$USE_PACKAGE_FILES sh /verify-pkg/scripts/verify-agent-host.sh --inside"; then
        BODY_OUT=$(logs_of "$NAME")
    else
        BODY_OUT=$(logs_of "$NAME" 2>/dev/null)
        fail "A-2: the probe container did not exit within 180s"
        note "$BODY_OUT"
        BODY_OUT=""
    fi
    printf '%s\n' "$BODY_OUT" | sed 's/^/      /' || true
    CHECKS=$((CHECKS + $(printf '%s\n' "$BODY_OUT" | grep -cE '^(PASS|FAIL) ')))
    FAILURES=$((FAILURES + $(printf '%s\n' "$BODY_OUT" | grep -cE '^FAIL ')))
    SKIPS=$((SKIPS + $(printf '%s\n' "$BODY_OUT" | grep -cE '^SKIP ')))

    MOUNTS=$(rt inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$NAME" 2>/dev/null)
    case "$MOUNTS" in
        *docker.sock*) fail "A-13: the container mounts a Docker socket; agent Docker access must go through the pinned proxy endpoint" ;;
        *"/agents"*) pass "A-13: the agent tree is a bind mount, so state lives on the host" ;;
        *) fail "A-13: the agent tree is not bind-mounted" ;;
    esac
    PUBLISHED=$(rt inspect -f '{{json .NetworkSettings.Ports}}' "$NAME" 2>/dev/null)
    case "$PUBLISHED" in
        ""|"null"|"{}") pass "A-9: the probe publishes no port — inbound is closed unless the deployment opens it" ;;
        *) fail "A-9: the container publishes ports ($PUBLISHED) without the deployment asking for it" ;;
    esac

    printf '\n== persistence across a recreate ==\n'
    SESSION_FILE="$TREE_LOCAL_DIR/$FIRST_ID/home/.probe-session"
    SESSION_BEFORE=0
    [ -f "$SESSION_FILE" ] && SESSION_BEFORE=$(wc -l <"$SESSION_FILE" | tr -d ' ')
    rt rm -f "$NAME" >/dev/null 2>&1 || true
    # The recreate container runs the boot alone, with the same environment the
    # first one booted with: the same plugin root and config template in
    # package-file mode, the same stand-in entrypoint when one was used, and the
    # same stub harness and SSH key the probe wrote into the tree.
    RECREATE_ENV="AGENT_HARNESS=/agents/.probe/harness.sh AGENT_SSH_AUTHORIZED_KEYS=/agents/.probe/authorized_keys"
    if [ "$STUB_ENTRYPOINT" = "1" ]; then
        RECREATE_ENV="$RECREATE_ENV AGENT_ENTRYPOINT=/agents/.probe/entrypoint.sh"
    fi
    if [ "$USE_PACKAGE_FILES" = "1" ]; then
        RECREATE_CMD="export AGENT_PLUGIN_ROOT=/verify-pkg/skeleton AGENT_HERDR_CONFIG_TEMPLATE=/verify-pkg/skeleton/herdr-config.toml $RECREATE_ENV; sh /verify-pkg/skeleton/agent-host-boot.sh"
    else
        RECREATE_CMD="export $RECREATE_ENV; sh /usr/local/bin/agent-host-boot"
    fi
    if start_container "$NAME2" \
        -v "$TREE_HOST_DIR:/agents" $PKG_ARGS $USER_ARGS $EXTRA_ARGS \
        -e "AGENT_IDS=$AGENT_IDS" -e "HERDR_SESSION=$HERDR_SESSION" \
        -e "AGENT_TREE=/agents" -e "XDG_CONFIG_HOME=/agents/.config" \
        -e "AGENT_SSHD_DIR=/agents/sshd" -e "AGENT_STATE_ROOT=/agents/.state" \
        -e "USE_PACKAGE_FILES=$USE_PACKAGE_FILES" -e "AGENT_BOOT_FOREGROUND=0" \
        -e "STUB_ENTRYPOINT=$STUB_ENTRYPOINT" -e "AGENT_ENTRYPOINT=$AGENT_ENTRYPOINT" \
        --entrypoint /bin/sh "$IMAGE" -c "$RECREATE_CMD"; then
        RECREATE_OUT=$(logs_of "$NAME2")
    else
        RECREATE_OUT=$(logs_of "$NAME2" 2>/dev/null)
        fail "A-10: the recreate run did not finish"
    fi
    printf '%s\n' "$RECREATE_OUT" | sed 's/^/      | /'
    SESSION_AFTER=0
    [ -f "$SESSION_FILE" ] && SESSION_AFTER=$(wc -l <"$SESSION_FILE" | tr -d ' ')
    if [ "$SESSION_AFTER" -gt "$SESSION_BEFORE" ]; then
        pass "A-10: after removing and recreating the container, the agent's session state was still there and resumed ($SESSION_BEFORE -> $SESSION_AFTER starts)"
    else
        fail "A-10: the agent's session file did not grow after the recreate ($SESSION_BEFORE -> $SESSION_AFTER)"
    fi
    case "$RECREATE_OUT" in
        *"agent $FIRST_ID runs in workspace"*) pass "A-10: the recreated host re-established the agent's workspace and pane" ;;
        *) fail "A-10: the recreated host did not re-establish agent $FIRST_ID" ;;
    esac
    for f in "$TREE_LOCAL_DIR/$FIRST_ID/workspace" "$TREE_LOCAL_DIR/$FIRST_ID/home" "$TREE_LOCAL_DIR/.state" "$TREE_LOCAL_DIR/sshd/ssh_host_ed25519_key"; do
        [ -e "$f" ] && pass "A-10: $(basename "$(dirname "$f")")/$(basename "$f") exists in the mounted tree (state is not inside the container)" || fail "A-10: $f is missing"
    done

    printf '\n== the published manifest ==\n'
    if [ -z "${PUBLISHED_IMAGE:-}" ]; then
        skip "A-16: PUBLISHED_IMAGE is unset; the two-platform manifest check names a published reference"
    elif ! rt buildx imagetools inspect "$PUBLISHED_IMAGE" >/dev/null 2>&1; then
        skip "A-16: this client cannot resolve $PUBLISHED_IMAGE (buildx imagetools unavailable or the reference is not pushed yet)"
    else
        INSPECT_OUT=$(rt buildx imagetools inspect "$PUBLISHED_IMAGE" 2>/dev/null)
        AMD=$(printf '%s' "$INSPECT_OUT" | grep -c 'linux/amd64')
        ARM=$(printf '%s' "$INSPECT_OUT" | grep -c 'linux/arm64')
        DIGEST=$(rt buildx imagetools inspect "$PUBLISHED_IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null)
        if [ "${AMD:-0}" -ge 1 ] && [ "${ARM:-0}" -ge 1 ] && [ -n "$DIGEST" ]; then
            pass "A-16: the published reference lists both platforms and a manifest digest ($DIGEST)"
        else
            fail "A-16: $PUBLISHED_IMAGE does not resolve to a two-platform manifest (digest '${DIGEST:-none}')"
        fi
    fi
}

# ---------------------------------------------------------------------------

if [ "${1:-}" = "--inside" ]; then
    body
    printf '\n%s checks, %s failed, %s skipped (in-container)\n' "$CHECKS" "$FAILURES" "$SKIPS"
    [ "$FAILURES" -eq 0 ] || exit 1
    exit 0
fi

FIRST_ID="${AGENT_IDS%%,*}"
driver
printf '\n%s checks, %s failed, %s skipped\n' "$CHECKS" "$FAILURES" "$SKIPS"
[ "$FAILURES" -eq 0 ] || exit 1
exit 0
