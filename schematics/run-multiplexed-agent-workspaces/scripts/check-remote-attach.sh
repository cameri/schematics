#!/bin/sh
# check-remote-attach.sh — the operator's diagnostic for `herdr --remote`.
#
# Run this INSIDE the agent host container (or on any host that runs a herdr
# server) before blaming a client. It checks the four things remote attach
# needs, in the order they fail, and prints OK / FAIL / SKIP per check:
#
#   1. an sshd is running from AGENT_SSHD_DIR;
#   2. its port accepts a connection;
#   3. key-only authentication is configured;
#   4. the config root and session the SSH sessions are told to use are the same
#      ones the running server was started with — the parity that decides
#      whether a remote `herdr session list` sees the real session;
#   5. the server process is its own session leader, which is the property
#      `herdr --remote` reads before attaching. Without it herdr offers to
#      restart the server, and that restart can fail and fall back to a new
#      empty session;
#   6. the session is reported running.
#
# Exit status: 0 when every check that ran came back OK; 1 when any failed.
#
# Inputs (environment): AGENT_SSHD_DIR (default <AGENT_TREE>/.sshd, the boot
# program's own default; AGENT_TREE defaults to /agents), AGENT_SSH_PORT
# (default 2222), HERDR_BIN_PATH (default herdr).
#
# The address it probes is read from the installed sshd_config's ListenAddress,
# not assumed to be the loopback: AGENT_SSH_LISTEN is a supported parameter, and
# a deployment that points the daemon at a routed or tunnel address is healthy
# while a probe of 127.0.0.1 is refused. The address actually probed is printed
# with the result, so a FAIL can be read without guessing which address was
# tried.
set -u

SSHD_DIR="${AGENT_SSHD_DIR:-${AGENT_TREE:-/agents}/.sshd}"
PORT="${AGENT_SSH_PORT:-2222}"
HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
FAIL=0

ok() { printf 'OK:   %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
skip() { printf 'SKIP: %s\n' "$1"; }

printf '== sshd from %s ==\n' "$SSHD_DIR"
if [ -f "$SSHD_DIR/sshd.pid" ] && kill -0 "$(cat "$SSHD_DIR/sshd.pid" 2>/dev/null)" 2>/dev/null; then
    ok "sshd running (pid $(cat "$SSHD_DIR/sshd.pid"))"
elif pgrep -f "sshd.*$SSHD_DIR" >/dev/null 2>&1; then
    ok "sshd running (pid $(pgrep -f "sshd.*$SSHD_DIR" | head -1), no pid file)"
else
    fail "no sshd running from $SSHD_DIR; the boot program starts one when AGENT_SSH_ENABLE=1"
fi

printf '\n== port %s ==\n' "$PORT"
# Which address to probe: the one the installed sshd_config binds. A wildcard
# bind is probed on the loopback address (that is what a wildcard includes); a
# specific address is probed as itself, because that is the only address such a
# daemon answers on.
LISTEN_SEEN=$(sed -n 's/^[[:space:]]*ListenAddress[[:space:]]\+\([^[:space:]]*\).*/\1/p' "$SSHD_DIR/sshd_config" 2>/dev/null | head -1)
case "$LISTEN_SEEN" in
    "") PROBE_ADDR=127.0.0.1 ;;
    0.0.0.0) PROBE_ADDR=127.0.0.1 ;;
    '::'|'[::]'|'::0') PROBE_ADDR='::1' ;;
    *) PROBE_ADDR="$LISTEN_SEEN" ;;
esac
printf '     probing %s (from %s)\n' "$PROBE_ADDR" "${LISTEN_SEEN:-the default bind, no ListenAddress line}"
# A TCP connect, however this host can do one. /dev/tcp is a bash feature, so a
# check written for POSIX sh cannot rely on it; nc is not always installed; and
# a listening check that silently passes because it could not test anything is
# worse than no check at all. Hence three outcomes, not two.
port_probe() {
    if command -v nc >/dev/null 2>&1; then
        nc -z "$PROBE_ADDR" "$PORT" >/dev/null 2>&1 && return 0
        return 1
    fi
    if command -v bash >/dev/null 2>&1; then
        command bash -c "exec 3<>/dev/tcp/$PROBE_ADDR/$PORT" >/dev/null 2>&1 && return 0
        return 1
    fi
    return 2
}
ATTEMPT=0
while [ "$ATTEMPT" -lt 5 ]; do
    port_probe
    RC=$?
    [ "$RC" -eq 0 ] && break
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
done
case "${RC:-1}" in
    0) ok "port $PORT accepts connections on the address the daemon binds ($PROBE_ADDR)" ;;
    1) fail "port $PORT does not accept a connection on $PROBE_ADDR, the address the installed sshd_config binds (a pid file present does not mean it bound)" ;;
    *) skip "cannot test port $PORT: neither nc nor bash is available on this host to open a TCP connection" ;;
esac

printf '\n== key-only authentication ==\n'
if [ -f "$SSHD_DIR/sshd_config" ] && grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHD_DIR/sshd_config"; then
    ok "PasswordAuthentication no in $SSHD_DIR/sshd_config"
else
    fail "sshd_config does not disable password authentication"
fi
AUTH_KEYS=$(sed -n 's/^[[:space:]]*AuthorizedKeysFile[[:space:]]\+//p' "$SSHD_DIR/sshd_config" 2>/dev/null | head -1)
if [ -n "$AUTH_KEYS" ]; then
    if [ -s "$AUTH_KEYS" ]; then
        ok "$AUTH_KEYS holds $(grep -c . "$AUTH_KEYS") key(s)"
    else
        fail "$AUTH_KEYS is empty or missing; key-only auth rejects every connection"
    fi
else
    skip "no AuthorizedKeysFile line in $SSHD_DIR/sshd_config to check"
fi

printf '\n== SetEnv parity with the running server ==\n'
SERVER_PIDS=$(pgrep -f "$HERDR_BIN server" 2>/dev/null || true)
if [ -z "$SERVER_PIDS" ]; then
    skip "no running herdr server to compare against; start the host first"
elif [ "$(printf '%s\n' "$SERVER_PIDS" | wc -l | tr -d ' ')" -gt 1 ]; then
    fail "more than one herdr server is running ($(printf '%s' "$SERVER_PIDS" | tr '\n' ' ')); the attach target is ambiguous"
else
    SERVER_PID="$SERVER_PIDS"
    SERVER_XDG=$(tr '\0' '\n' <"/proc/$SERVER_PID/environ" 2>/dev/null | sed -n 's/^XDG_CONFIG_HOME=//p')
    SERVER_SESSION=$(tr '\0' '\n' <"/proc/$SERVER_PID/environ" 2>/dev/null | sed -n 's/^HERDR_SESSION=//p')
    SSH_XDG=$(sed -n 's/^[[:space:]]*SetEnv[[:space:]]\+.*XDG_CONFIG_HOME=\([^ ]*\).*/\1/p' "$SSHD_DIR/sshd_config" 2>/dev/null | head -1)
    SSH_SESSION=$(sed -n 's/^[[:space:]]*SetEnv[[:space:]]\+.*HERDR_SESSION=\([^ ]*\).*/\1/p' "$SSHD_DIR/sshd_config" 2>/dev/null | head -1)
    if [ -z "$SSH_XDG" ] && [ -z "$SSH_SESSION" ]; then
        if [ -z "$SERVER_XDG" ] && [ -z "$SERVER_SESSION" ]; then
            ok "no SetEnv and no server override: both sides resolve the default config root and session"
        else
            fail "the server runs with XDG_CONFIG_HOME='$SERVER_XDG' HERDR_SESSION='$SERVER_SESSION' but sshd_config injects neither; remote herdr commands resolve a different session"
        fi
    else
        [ -z "$SERVER_XDG" ] || [ "$SSH_XDG" = "$SERVER_XDG" ] \
            && ok "SetEnv XDG_CONFIG_HOME=$SSH_XDG matches the running server" \
            || fail "SetEnv XDG_CONFIG_HOME=$SSH_XDG, but the server runs with '$SERVER_XDG'"
        [ -z "$SERVER_SESSION" ] || [ "$SSH_SESSION" = "$SERVER_SESSION" ] \
            && ok "SetEnv HERDR_SESSION=$SSH_SESSION matches the running server" \
            || fail "SetEnv HERDR_SESSION=$SSH_SESSION, but the server runs with '$SERVER_SESSION'"
    fi

    printf '\n== detached daemon (session leader) ==\n'
    SID=$(ps -o sid= -p "$SERVER_PID" 2>/dev/null | tr -d ' ')
    if [ "$SID" = "$SERVER_PID" ]; then
        ok "the herdr server (pid $SERVER_PID) is its own session leader, so herdr --remote attaches without a restart prompt"
    else
        fail "the herdr server runs in session $SID, not its own; relaunch it detached (setsid herdr server &) or remote attach will offer a restart and may fall back to a fresh session"
    fi

    printf '\n== session state ==\n'
    LIST=$(env ${SERVER_XDG:+XDG_CONFIG_HOME="$SERVER_XDG"} ${SERVER_SESSION:+HERDR_SESSION="$SERVER_SESSION"} "$HERDR_BIN" session list --json 2>/dev/null || true)
    if [ -z "$LIST" ]; then
        fail "herdr session list returned nothing under the server's own config root and session"
    elif [ -n "$SERVER_SESSION" ]; then
        case "$LIST" in
            *"\"name\":\"$SERVER_SESSION\""*'"running":true'*) ok "session '$SERVER_SESSION' is running" ;;
            *) fail "session '$SERVER_SESSION' is not reported running (an empty session list usually means the parity check above failed first)" ;;
        esac
    else
        case "$LIST" in
            *'"running":true'*) ok "at least one session is running" ;;
            *) fail "no running session found" ;;
        esac
    fi
fi

printf '\n'
if [ "$FAIL" -ne 0 ]; then
    printf 'RESULT: FAIL (fix the FAIL lines, then re-run)\n'
    exit 1
fi
printf 'RESULT: all OK\n'
exit 0
