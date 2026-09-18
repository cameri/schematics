#!/bin/sh
# agent-loop.sh — one agent's process, running as its herdr plugin pane's
# process.
#
# The agent itself is the base image's entrypoint, started as this script's
# child with the agent's identity in the environment it defines. The wrapper
# exists for one reason: the pane's process must outlive the agent, so that an
# agent that dies does not take its pane, tab and workspace with it.
#
# Restart policy — crash only:
#   * the agent exits with a status >= 128 (death by signal, e.g. SIGKILL or
#     SIGSEGV) — a crash. The wrapper relaunches it in the same pane, so the
#     pane, tab and workspace never tear down.
#   * the agent exits with a status < 128 — a clean exit, deliberate: the
#     wrapper writes the agent's stop marker, logs the path, and exits 0. The
#     pane closes and nothing reopens the agent. This is the difference between
#     a killed agent and an exited one.
#   * an interactive interrupt (Ctrl-C, status 130) is a signal death and
#     therefore a crash: an accidental interrupt must not close the workspace.
#   * the stop marker is the maintenance escape hatch: with it present the
#     wrapper does not start the agent at all, and exits 0 so the pane closes.
#   * crash-loop bound: AGENT_CRASH_LIMIT launches inside AGENT_CRASH_WINDOW
#     seconds make the wrapper sleep AGENT_CRASH_BACKOFF seconds before the
#     next launch, so a permanently broken agent cannot spin.
#
# Identity comes from the workspace, not from the environment: herdr injects
# HERDR_WORKSPACE_ID into every pane, and this script looks that workspace up
# in the roster the boot program wrote. Nothing here has to be passed per pane.
#
# State lives under AGENT_STATE_ROOT/<agent id>/: loop.log, launches, and the
# `stop` marker. Re-runnable: every path is derived from the workspace id.
#
# Refusals exit 78 with one stderr line prefixed `agent-loop: `, naming the
# value at fault.
set -u

REFUSED=78
refuse() { printf 'agent-loop: %s\n' "$1" >&2; exit "$REFUSED"; }

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
PLUGIN_STATE="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/agent-respawn}"
STATE_ROOT="${AGENT_STATE_ROOT:-$PLUGIN_STATE}"
ROSTER="${AGENT_ROSTER_FILE:-${HERDR_PLUGIN_CONFIG_DIR:-.}/roster.tsv}"
ENTRYPOINT="${AGENT_ENTRYPOINT:-/usr/local/bin/agent-entrypoint}"
CRASH_LIMIT="${AGENT_CRASH_LIMIT:-3}"
CRASH_WINDOW="${AGENT_CRASH_WINDOW:-5}"
CRASH_BACKOFF="${AGENT_CRASH_BACKOFF:-30}"
SIGNAL_FLOOR=128

# A pause of zero is not a bound: it would let a permanently broken agent spin
# exactly as if there were no refusal at all, which is the failure R-5 exists to
# prevent. Refuse it here, where the value is named, rather than discovering it
# as load on the host.
case "$CRASH_BACKOFF" in
    ''|*[!0-9]*) refuse "AGENT_CRASH_BACKOFF is '$CRASH_BACKOFF'; the crash-loop pause must be a whole number of seconds" ;;
esac
[ "$CRASH_BACKOFF" -ge 1 ] || refuse "AGENT_CRASH_BACKOFF is $CRASH_BACKOFF; the crash-loop pause must be at least 1 second, or a permanently broken agent spins"

WS_ID="${HERDR_WORKSPACE_ID:-}"
[ -n "$WS_ID" ] || refuse "HERDR_WORKSPACE_ID is unset; this program is the process of a herdr plugin pane, and the workspace is how it knows which agent it runs"

[ -f "$ROSTER" ] || refuse "roster $ROSTER is missing; the boot program writes it before it opens any pane"
LINE=$(awk -F'\t' -v id="$WS_ID" '$1 == id { print; exit }' "$ROSTER")
[ -n "$LINE" ] || refuse "workspace $WS_ID has no roster entry in $ROSTER; no agent is configured for it"
AGENT_ID=$(printf '%s' "$LINE" | cut -f2)
WORKSPACE_DIR=$(printf '%s' "$LINE" | cut -f3)
AGENT_HOME=$(printf '%s' "$LINE" | cut -f4)
[ -n "$AGENT_ID" ] || refuse "the roster entry for workspace $WS_ID has no agent id in column 2"
[ -n "$WORKSPACE_DIR" ] || refuse "the roster entry for agent $AGENT_ID has no workspace directory in column 3"
# The home goes to the agent as HOME, so an empty column 4 is passed on as an
# empty HOME and every harness writes its session somewhere unintended. The
# roster's own contract says a column is never empty; this is where that is
# enforced, naming the row.
[ -n "$AGENT_HOME" ] || refuse "the roster entry for agent $AGENT_ID has no home directory in column 4"
[ -x "$ENTRYPOINT" ] || refuse "entrypoint $ENTRYPOINT is not an executable file"

STATE_DIR="$STATE_ROOT/$AGENT_ID"
mkdir -p "$STATE_DIR" || refuse "cannot create the state directory $STATE_DIR"
STOP="$STATE_DIR/stop"
LAUNCHES="$STATE_DIR/launches"
LOG="$STATE_DIR/loop.log"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }

log "pane process started: agent $AGENT_ID, workspace $WS_ID, entrypoint $ENTRYPOINT, herdr $HERDR_BIN"

# The marker is the maintenance escape hatch, so it is re-read before every
# launch rather than once before the loop: an operator who writes it while a
# crash-looping wrapper sleeps out its backoff must be obeyed at the end of that
# sleep, not only on the next container start — that is precisely the moment the
# escape hatch is reached for. The first iteration covers the pre-loop case.
while :; do
    if [ -f "$STOP" ]; then
        log "stop marker $STOP is present: not starting agent $AGENT_ID (remove it to allow a start)"
        exit 0
    fi
    log "starting agent $AGENT_ID: workspace $WORKSPACE_DIR, home $AGENT_HOME"
    START=$(date +%s)
    AGENT_ID="$AGENT_ID" \
    AGENT_WORKSPACE_DIR="$WORKSPACE_DIR" \
    HOME="$AGENT_HOME" \
    HERDR_WORKSPACE_ID="$WS_ID" \
        "$ENTRYPOINT"
    CODE=$?
    NOW=$(date +%s)
    DURATION=$((NOW - START))
    log "agent $AGENT_ID exited with status $CODE after ${DURATION}s"

    if [ "$CODE" -lt "$SIGNAL_FLOOR" ]; then
        log "status $CODE is below $SIGNAL_FLOOR: a clean exit, so agent $AGENT_ID stays down. Remove $STOP to allow it to start again"
        : >"$STOP"
        exit 0
    fi

    log "status $CODE is at or above $SIGNAL_FLOOR: death by signal, relaunching agent $AGENT_ID in this pane"
    printf '%s\n' "$NOW" >>"$LAUNCHES"
    RECENT=$(awk -v now="$NOW" -v window="$CRASH_WINDOW" 'now - $1 <= window' "$LAUNCHES" | wc -l | tr -d ' ')
    tail -n 50 "$LAUNCHES" >"$LAUNCHES.tmp" && mv "$LAUNCHES.tmp" "$LAUNCHES"
    if [ "$RECENT" -ge "$CRASH_LIMIT" ]; then
        log "$RECENT launches within ${CRASH_WINDOW}s are crashes: backing off ${CRASH_BACKOFF}s before the next attempt"
        sleep "$CRASH_BACKOFF"
    fi
done
