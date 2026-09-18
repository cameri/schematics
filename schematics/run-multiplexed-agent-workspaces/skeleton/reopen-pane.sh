#!/bin/sh
# reopen-pane.sh — the herdr `pane.exited` hook: put an agent's pane back.
#
# This is the fallback path, not the primary one. The pane's process is
# agent-loop.sh, which relaunches the agent inside the pane after a crash, so
# the pane normally never exits at all. This hook matters for the case the
# wrapper itself dies — SIGKILL of the pane process, or the plugin being
# reloaded — because that closes the pane, the tab, and (when it was the last
# pane) the workspace.
#
# herdr invokes it with HERDR_PLUGIN_EVENT_JSON holding the event, whose
# `data.workspace_id` says which workspace lost a pane. Rules:
#
#   * a workspace that is not in the roster is not ours: exit 0, silently.
#   * an agent whose stop marker is present stays down: exit 0. A deliberate
#     stop must not be undone by a fallback path.
#   * the workspace may already be gone: when the exited pane held the
#     workspace's last pane, herdr's auto-close cascade (pane, tab, workspace)
#     has run by the time this hook starts, so the workspace is recreated with
#     the same cwd and label before the pane is reopened.
#   * the roster is rewritten with the new workspace id whenever a workspace is
#     recreated, so agent-loop.sh resolves the same agent from it.
#   * a recreated workspace comes with a root shell pane; it is closed once the
#     agent pane is open, so the workspace has the same shape as one the boot
#     created.
#   * crash-loop bound: more than AGENT_REOPEN_LIMIT reopens inside
#     AGENT_REOPEN_WINDOW seconds sleep AGENT_REOPEN_BACKOFF seconds first, so
#     a pane that cannot stay alive cannot spin.
#
# Refusals exit 78 with one stderr line prefixed `reopen-pane: `.
set -u

REFUSED=78
refuse() { printf 'reopen-pane: %s\n' "$1" >&2; exit "$REFUSED"; }

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
PLUGIN_STATE="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/agent-respawn}"
STATE_ROOT="${AGENT_STATE_ROOT:-$PLUGIN_STATE}"
ROSTER="${AGENT_ROSTER_FILE:-${HERDR_PLUGIN_CONFIG_DIR:-.}/roster.tsv}"
PLUGIN_ID="${AGENT_PLUGIN_ID:-agent-respawn}"
PANE_ENTRYPOINT="${AGENT_PANE_ENTRYPOINT:-agent}"
REOPEN_LIMIT="${AGENT_REOPEN_LIMIT:-5}"
REOPEN_WINDOW="${AGENT_REOPEN_WINDOW:-60}"
REOPEN_BACKOFF="${AGENT_REOPEN_BACKOFF:-30}"

mkdir -p "$STATE_ROOT" 2>/dev/null || true
LOG="$STATE_ROOT/reopen.log"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null || true; }

EVENT="${HERDR_PLUGIN_EVENT_JSON:-}"
WS_ID=$(printf '%s' "$EVENT" | sed -n 's/.*"workspace_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$WS_ID" ] || exit 0
[ -f "$ROSTER" ] || exit 0

# The boot program closes and recreates workspaces on every start, and each of
# those closes fires this hook. Acting on them would recreate a workspace the
# boot is about to create itself, leaving the agent with two. The marker it
# writes for the duration of its reconciliation is what this checks.
if [ -f "$STATE_ROOT/reconciling" ]; then
    log "workspace $WS_ID lost its pane during boot reconciliation: leaving it to the boot program"
    exit 0
fi

LINE=$(awk -F'\t' -v id="$WS_ID" '$1 == id { print; exit }' "$ROSTER")
[ -n "$LINE" ] || exit 0
AGENT_ID=$(printf '%s' "$LINE" | cut -f2)
WORKSPACE_DIR=$(printf '%s' "$LINE" | cut -f3)
[ -n "$AGENT_ID" ] || exit 0

STATE_DIR="$STATE_ROOT/$AGENT_ID"
mkdir -p "$STATE_DIR" 2>/dev/null || true
if [ -f "$STATE_DIR/stop" ]; then
    log "workspace $WS_ID (agent $AGENT_ID) lost its pane, but its stop marker is present: leaving it down"
    exit 0
fi

NOW=$(date +%s)
REOPENS="$STATE_DIR/reopens"
printf '%s\n' "$NOW" >>"$REOPENS" 2>/dev/null || true
RECENT=$(awk -v now="$NOW" -v window="$REOPEN_WINDOW" 'now - $1 <= window' "$REOPENS" 2>/dev/null | wc -l | tr -d ' ')
tail -n 50 "$REOPENS" >"$REOPENS.tmp" 2>/dev/null && mv "$REOPENS.tmp" "$REOPENS" 2>/dev/null || true
if [ "$RECENT" -gt "$REOPEN_LIMIT" ]; then
    log "$RECENT reopens within ${REOPEN_WINDOW}s for agent $AGENT_ID: backing off ${REOPEN_BACKOFF}s"
    sleep "$REOPEN_BACKOFF"
fi

OPEN_OUT=$("$HERDR_BIN" plugin pane open --plugin "$PLUGIN_ID" --entrypoint "$PANE_ENTRYPOINT" --workspace "$WS_ID" 2>&1)
if [ $? -eq 0 ]; then
    log "reopened the agent pane in workspace $WS_ID (agent $AGENT_ID)"
    exit 0
fi

log "reopening in workspace $WS_ID failed: $OPEN_OUT"
case "$OPEN_OUT" in
    *workspace*not*found*|*unknown*workspace*|*no*such*workspace*) ;;
    *)
        log "not a missing workspace: leaving it to the operator"
        exit 0
        ;;
esac

[ -n "$WORKSPACE_DIR" ] || refuse "agent $AGENT_ID has no workspace directory in $ROSTER, so the workspace cannot be recreated"
mkdir -p "$WORKSPACE_DIR" 2>/dev/null || true
CREATED=$("$HERDR_BIN" workspace create --cwd "$WORKSPACE_DIR" --label "$AGENT_ID" --no-focus 2>&1)
if [ $? -ne 0 ]; then
    refuse "cannot recreate the workspace for agent $AGENT_ID: $CREATED"
fi
# The create response is parsed with jq, not with a pattern: its `root_pane`
# object holds nested objects of its own (`scroll`, for one), so a
# non-nesting pattern stops at the wrong brace and reads nothing. jq is
# guaranteed on this host — the boot program refuses without it — and the same
# parse is what the boot uses.
NEW_WS=$(printf '%s' "$CREATED" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
[ -n "$NEW_WS" ] || refuse "recreated the workspace for agent $AGENT_ID but could not read its id from: $CREATED"
# A created workspace comes with a root shell pane, which the boot closes as
# soon as the agent pane is up. A recreated one must end in the same shape, or
# the workspace drifts one pane wider on every recreate.
NEW_ROOT_PANE=$(printf '%s' "$CREATED" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
log "recreated workspace $NEW_WS for agent $AGENT_ID (was $WS_ID)"

TMP="$ROSTER.tmp.$$"
awk -F'\t' -v OFS='\t' -v old="$WS_ID" -v new="$NEW_WS" '{ if ($1 == old) $1 = new; print }' "$ROSTER" >"$TMP" && mv "$TMP" "$ROSTER" \
    || refuse "recreated workspace $NEW_WS but could not rewrite $ROSTER"

OPEN_OUT=$("$HERDR_BIN" plugin pane open --plugin "$PLUGIN_ID" --entrypoint "$PANE_ENTRYPOINT" --workspace "$NEW_WS" 2>&1)
[ $? -eq 0 ] || refuse "cannot reopen the agent pane in recreated workspace $NEW_WS: $OPEN_OUT"
if [ -n "$NEW_ROOT_PANE" ]; then
    "$HERDR_BIN" pane close "$NEW_ROOT_PANE" >/dev/null 2>&1 || true
fi
log "reopened the agent pane in recreated workspace $NEW_WS (agent $AGENT_ID)"
exit 0
