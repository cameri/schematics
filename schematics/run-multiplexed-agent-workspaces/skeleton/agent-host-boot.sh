#!/bin/sh
# agent-host-boot.sh — the container's process on an agent host.
#
# It brings the host up in a fixed order and then becomes the herdr client for
# the host's session:
#
#   1. checks the environment contract and the agent tree;
#   2. installs the herdr configuration if the config root has none;
#   3. starts the SSH daemon that remote attach arrives through;
#   4. starts the herdr server as its own session leader — the detached-daemon
#      requirement `herdr --remote` checks before it will attach;
#   5. links the agent plugin;
#   6. reconciles the workspace set with AGENT_IDS: one workspace per agent,
#      labelled with the agent id, with the agent pane open in it;
#   7. execs the herdr client, so the container's process is the host's session.
#
# Every step is idempotent: re-running on a host that is already up closes and
# recreates each agent's workspace (which is how the desired state is enforced)
# and leaves the server, the daemon and the roster consistent.
#
# This program is the container's process only because the deployment starts it
# (see compose.service.yaml). The image's own ENTRYPOINT is unchanged, so the
# image still runs exactly one agent in one workspace when it is started without
# this override — see SCHEMATIC.md, Decisions and Open Questions.
#
# Refusals exit 78 with one stderr line prefixed `agent-host-boot: `, naming the
# value at fault.
set -u

REFUSED=78
refuse() { printf 'agent-host-boot: %s\n' "$1" >&2; exit "$REFUSED"; }

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
HERDR_SESSION="${HERDR_SESSION:-agents}"
AGENT_IDS="${AGENT_IDS:-}"
AGENT_TREE="${AGENT_TREE:-/agents}"
STATE_ROOT="${AGENT_STATE_ROOT:-$AGENT_TREE/.state}"
AGENT_ENTRYPOINT="${AGENT_ENTRYPOINT:-/usr/local/bin/agent-entrypoint}"
PLUGIN_ROOT="${AGENT_PLUGIN_ROOT:-/usr/local/share/agent-host/plugin}"
PLUGIN_ID="${AGENT_PLUGIN_ID:-agent-respawn}"
PANE_ENTRYPOINT="${AGENT_PANE_ENTRYPOINT:-agent}"
CONFIG_TEMPLATE="${AGENT_HERDR_CONFIG_TEMPLATE:-/usr/local/share/agent-host/herdr-config.toml}"
SSH_ENABLE="${AGENT_SSH_ENABLE:-1}"
SSH_PORT="${AGENT_SSH_PORT:-2222}"
SSH_LISTEN="${AGENT_SSH_LISTEN:-127.0.0.1}"
SSHD_DIR="${AGENT_SSHD_DIR:-$HOME/.sshd}"
AUTHORIZED_KEYS="${AGENT_SSH_AUTHORIZED_KEYS:-$SSHD_DIR/authorized_keys}"
FOREGROUND="${AGENT_BOOT_FOREGROUND:-1}"

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export HERDR_SESSION

CONFIG_DIR="$XDG_CONFIG_HOME/herdr"
PLUGIN_CONFIG_DIR="$CONFIG_DIR/plugins/config/$PLUGIN_ID"
ROSTER="$PLUGIN_CONFIG_DIR/roster.tsv"

# --- 1. environment contract -------------------------------------------------

[ -n "$AGENT_IDS" ] || refuse "AGENT_IDS is empty; name the agents this host runs, comma-separated"
command -v "$HERDR_BIN" >/dev/null 2>&1 || refuse "herdr is not on PATH as '$HERDR_BIN'"
command -v jq >/dev/null 2>&1 || refuse "jq is not on PATH; this host parses herdr's JSON output with it"
command -v setsid >/dev/null 2>&1 || refuse "setsid is not on PATH; the herdr server must be started as its own session leader or remote attach will not find it"
[ -x "$AGENT_ENTRYPOINT" ] || refuse "the agent entrypoint $AGENT_ENTRYPOINT is not an executable file"
[ -d "$PLUGIN_ROOT" ] || refuse "the plugin root $PLUGIN_ROOT is not a directory"

mkdir -p "$AGENT_TREE" || refuse "cannot create the agent tree $AGENT_TREE"
[ -w "$AGENT_TREE" ] || refuse "the agent tree $AGENT_TREE is not writable by $(id -un); a bind mount owned by another uid needs the same uid as this account"

OLD_IFS="$IFS"
IFS=','
for ID in $AGENT_IDS; do
    IFS="$OLD_IFS"
    case "$ID" in
        '') refuse "AGENT_IDS contains an empty entry; every comma-separated entry must be an agent id" ;;
        *[!A-Za-z0-9._-]*) refuse "agent id '$ID' contains a character outside [A-Za-z0-9._-]; it becomes a workspace label, a directory name and a log name" ;;
        [!A-Za-z0-9]*) refuse "agent id '$ID' must start with a letter or digit" ;;
    esac
    LENGTH=$(printf '%s' "$ID" | wc -c | tr -d ' ')
    [ "$LENGTH" -le 64 ] || refuse "agent id '$ID' is $LENGTH characters long; the limit is 64"
    WORKSPACE_DIR="$AGENT_TREE/$ID/workspace"
    AGENT_HOME="$AGENT_TREE/$ID/home"
    mkdir -p "$WORKSPACE_DIR" "$AGENT_HOME" || refuse "cannot create $WORKSPACE_DIR and $AGENT_HOME"
    [ -w "$WORKSPACE_DIR" ] || refuse "the workspace directory $WORKSPACE_DIR is not writable by $(id -un)"
    IFS=','
done
IFS="$OLD_IFS"

# --- 2. herdr configuration --------------------------------------------------

mkdir -p "$CONFIG_DIR" "$PLUGIN_CONFIG_DIR" "$STATE_ROOT" || refuse "cannot create the herdr config root $CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    [ -f "$CONFIG_TEMPLATE" ] || refuse "no config.toml in $CONFIG_DIR and no template at $CONFIG_TEMPLATE"
    cp "$CONFIG_TEMPLATE" "$CONFIG_DIR/config.toml" || refuse "cannot install $CONFIG_TEMPLATE to $CONFIG_DIR/config.toml"
    printf 'agent-host-boot: installed %s\n' "$CONFIG_DIR/config.toml"
fi
printf '# workspace_id\tagent_id\tworkspace_dir\thome_dir\n' >"$ROSTER" \
    || refuse "cannot write the roster $ROSTER"

# --- 3. SSH daemon -----------------------------------------------------------

SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
if [ "$SSH_ENABLE" = "1" ]; then
    [ -x "$SSHD_BIN" ] || refuse "AGENT_SSH_ENABLE=1 but sshd is not installed on this host"
    mkdir -p "$SSHD_DIR" || refuse "cannot create $SSHD_DIR"
    chmod 700 "$SSHD_DIR" 2>/dev/null || true
    HOST_KEY="$SSHD_DIR/ssh_host_ed25519_key"
    if [ ! -f "$HOST_KEY" ]; then
        ssh-keygen -q -t ed25519 -f "$HOST_KEY" -N "" || refuse "cannot generate the SSH host key $HOST_KEY"
    fi
    chmod 600 "$HOST_KEY" 2>/dev/null || true
    cat >"$SSHD_DIR/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress $SSH_LISTEN
HostKey $HOST_KEY
AuthorizedKeysFile $AUTHORIZED_KEYS
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
UsePAM no
PidFile $SSHD_DIR/sshd.pid
LogLevel VERBOSE
SetEnv XDG_CONFIG_HOME=$XDG_CONFIG_HOME HERDR_SESSION=$HERDR_SESSION
EOF
    chmod 600 "$SSHD_DIR/sshd_config"
    "$SSHD_BIN" -t -f "$SSHD_DIR/sshd_config" || refuse "sshd rejects the generated configuration at $SSHD_DIR/sshd_config"
    if [ -f "$SSHD_DIR/sshd.pid" ] && kill -0 "$(cat "$SSHD_DIR/sshd.pid" 2>/dev/null)" 2>/dev/null; then
        kill -HUP "$(cat "$SSHD_DIR/sshd.pid")" 2>/dev/null || true
    else
        "$SSHD_BIN" -f "$SSHD_DIR/sshd_config" || refuse "sshd failed to start with $SSHD_DIR/sshd_config"
    fi
    if [ ! -s "$AUTHORIZED_KEYS" ]; then
        printf 'agent-host-boot: %s is empty; add the attaching client public key or key-only auth rejects every connection\n' "$AUTHORIZED_KEYS"
    fi
    printf 'agent-host-boot: sshd on %s:%s, config root %s, session %s\n' "$SSH_LISTEN" "$SSH_PORT" "$XDG_CONFIG_HOME" "$HERDR_SESSION"
fi

# --- 4. herdr server, as its own session leader ------------------------------

session_running() {
    "$HERDR_BIN" session list --json 2>/dev/null \
        | jq -r --arg s "$HERDR_SESSION" '.sessions[]? | select(.name == $s) | .running' 2>/dev/null \
        | grep -q true
}

if session_running; then
    printf 'agent-host-boot: herdr session %s is already running\n' "$HERDR_SESSION"
else
    setsid "$HERDR_BIN" server >"$STATE_ROOT/herdr-server.log" 2>&1 &
    TRIES=0
    until session_running; do
        TRIES=$((TRIES + 1))
        [ "$TRIES" -lt 60 ] || refuse "herdr session $HERDR_SESSION did not come up within 15s; see $STATE_ROOT/herdr-server.log"
        sleep 0.25
    done
    printf 'agent-host-boot: started herdr session %s\n' "$HERDR_SESSION"
fi

SRV_PID=$(pgrep -f "$HERDR_BIN server" | head -1)
if [ -n "$SRV_PID" ]; then
    SID=$(ps -o sid= -p "$SRV_PID" 2>/dev/null | tr -d ' ')
    if [ "$SID" != "$SRV_PID" ]; then
        printf 'agent-host-boot: the herdr server (pid %s) runs in session %s, not its own; remote attach will demand a restart and may fall back to a fresh session\n' "$SRV_PID" "$SID" >&2
    fi
fi

# --- 5. the plugin -----------------------------------------------------------

if ! "$HERDR_BIN" plugin list 2>/dev/null | grep -q "$PLUGIN_ID"; then
    "$HERDR_BIN" plugin link "$PLUGIN_ROOT" >/dev/null 2>&1 \
        || refuse "cannot link the plugin at $PLUGIN_ROOT into herdr"
    printf 'agent-host-boot: linked the plugin %s from %s\n' "$PLUGIN_ID" "$PLUGIN_ROOT"
fi

# --- 6. one workspace per agent ---------------------------------------------

# Closing a workspace kills its pane, which fires the plugin's pane.exited hook.
# During reconciliation that hook must not fight this loop: it would reopen (or
# recreate) a workspace the loop is about to create itself, and the same agent
# would end up with two. The marker below is what tells the hook to stand down.
RECONCILING="$STATE_ROOT/reconciling"
: >"$RECONCILING" || refuse "cannot write the reconciliation marker $RECONCILING"
trap 'rm -f "$RECONCILING"' EXIT INT TERM

IFS=','
for ID in $AGENT_IDS; do
    IFS="$OLD_IFS"
    WORKSPACE_DIR="$AGENT_TREE/$ID/workspace"
    AGENT_HOME="$AGENT_TREE/$ID/home"

    for OLD in $("$HERDR_BIN" workspace list 2>/dev/null | jq -r --arg l "$ID" '.result.workspaces[]? | select(.label == $l) | .workspace_id'); do
        "$HERDR_BIN" workspace close "$OLD" >/dev/null 2>&1 || true
    done

    CREATED=$("$HERDR_BIN" workspace create --cwd "$WORKSPACE_DIR" --label "$ID" --no-focus 2>&1) \
        || refuse "cannot create the workspace for agent $ID: $CREATED"
    WS_ID=$(printf '%s' "$CREATED" | jq -r '.result.workspace.workspace_id' 2>/dev/null)
    ROOT_PANE=$(printf '%s' "$CREATED" | jq -r '.result.root_pane.pane_id' 2>/dev/null)
    [ -n "$WS_ID" ] && [ "$WS_ID" != "null" ] || refuse "created the workspace for agent $ID but found no workspace id in: $CREATED"

    printf '%s\t%s\t%s\t%s\n' "$WS_ID" "$ID" "$WORKSPACE_DIR" "$AGENT_HOME" >>"$ROSTER" \
        || refuse "cannot append agent $ID to the roster $ROSTER"

    if [ -f "$STATE_ROOT/$ID/stop" ]; then
        printf 'agent-host-boot: agent %s is stopped (its stop marker is present); workspace %s keeps its shell pane and no agent pane is opened\n' "$ID" "$WS_ID"
    elif "$HERDR_BIN" plugin pane open --plugin "$PLUGIN_ID" --entrypoint "$PANE_ENTRYPOINT" --workspace "$WS_ID" >/dev/null 2>&1; then
        [ -n "$ROOT_PANE" ] && [ "$ROOT_PANE" != "null" ] && "$HERDR_BIN" pane close "$ROOT_PANE" >/dev/null 2>&1 || true
        printf 'agent-host-boot: agent %s runs in workspace %s\n' "$ID" "$WS_ID"
    else
        printf 'agent-host-boot: could not open the agent pane for %s; workspace %s keeps its shell pane\n' "$ID" "$WS_ID" >&2
    fi
    IFS=','
done
IFS="$OLD_IFS"

FIRST=$("$HERDR_BIN" workspace list 2>/dev/null | jq -r '.result.workspaces[0].workspace_id // empty')
[ -n "$FIRST" ] && "$HERDR_BIN" workspace focus "$FIRST" >/dev/null 2>&1 || true

# Reconciliation is over: the hook may act on pane exits again. Removed here and
# not only by the trap, because the foreground path below replaces this process.
rm -f "$RECONCILING"

# --- 7. the session ----------------------------------------------------------

if [ "$FOREGROUND" != "1" ]; then
    printf 'agent-host-boot: AGENT_BOOT_FOREGROUND=%s, so the host is up and this program exits\n' "$FOREGROUND"
    exit 0
fi
printf 'agent-host-boot: attaching to herdr session %s\n' "$HERDR_SESSION"
exec "$HERDR_BIN" --session "$HERDR_SESSION"
