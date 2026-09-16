#!/bin/sh
# Standard entrypoint for the agent dev base image and every image layered on
# it. See modules/entrypoint-contract.md for the full contract.
#
# Runtime inputs:
#   AGENT_HARNESS        required. Name of the harness CLI (resolved from PATH)
#                        or an absolute path to it. This image ships none, so a
#                        layer image sets it (ENV AGENT_HARNESS=<cli>).
#   AGENT_WORKSPACE_DIR  optional. Absolute path of the one workspace the agent
#                        gets; default /workspace.
#   AGENT_ID             optional. The agent's id; default the container's
#                        hostname.
#
# Arguments passed to the container are forwarded to the harness unchanged.
#
# Refusals: exit 78, one line on stderr naming the variable or path at fault.
# Nothing is started before every check has passed, and the harness is exec'd
# (never forked), so the container's PID 1 is the harness itself.
set -eu

PROG=agent-entrypoint

refuse() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit 78
}

HARNESS="${AGENT_HARNESS:-}"
WORKSPACE_DIR="${AGENT_WORKSPACE_DIR:-/workspace}"
AGENT_ID="${AGENT_ID:-$(hostname)}"

# The harness name is looked up with `command -v`, so a leading dash would be
# read as an option; refuse it rather than let the lookup fail confusingly.
case "$HARNESS" in
    '') refuse "AGENT_HARNESS is not set: this image ships no harness CLI. A layer image sets it (ENV AGENT_HARNESS=<cli>), or pass -e AGENT_HARNESS=<cli>." ;;
    -*) refuse "AGENT_HARNESS must not start with '-', got '$HARNESS'" ;;
esac

# The workspace is the process's working directory, so a relative path would
# mean something different after exec; require an absolute one.
case "$WORKSPACE_DIR" in
    /*) ;;
    *) refuse "AGENT_WORKSPACE_DIR must be an absolute path, got '$WORKSPACE_DIR'" ;;
esac

# The agent id becomes a name in other components (workspace labels, state
# directories), so it is restricted to a portable charset up front.
case "$AGENT_ID" in
    ''|*[!A-Za-z0-9._-]*) refuse "AGENT_ID must match [A-Za-z0-9][A-Za-z0-9._-]* and be at most 64 characters, got '$AGENT_ID'" ;;
esac
case "$AGENT_ID" in
    [A-Za-z0-9]*) ;;
    *) refuse "AGENT_ID must start with a letter or digit, got '$AGENT_ID'" ;;
esac
if [ "${#AGENT_ID}" -gt 64 ]; then
    refuse "AGENT_ID must be at most 64 characters, got ${#AGENT_ID}"
fi

# Workspace: created if absent, then required to be a directory this user can
# write. An unwritable workspace is refused here, loudly, instead of surfacing
# later as a random command failing inside the harness.
if [ ! -d "$WORKSPACE_DIR" ]; then
    mkdir -p "$WORKSPACE_DIR" 2>/dev/null \
      || refuse "cannot create workspace '$WORKSPACE_DIR' as uid $(id -u): its parent is not writable"
fi
[ -d "$WORKSPACE_DIR" ] || refuse "workspace '$WORKSPACE_DIR' is not a directory"
[ -w "$WORKSPACE_DIR" ] || refuse "workspace '$WORKSPACE_DIR' is not writable by uid $(id -u)"

HARNESS_PATH="$(command -v "$HARNESS" || true)"
[ -n "$HARNESS_PATH" ] \
  || refuse "AGENT_HARNESS '$HARNESS' is not an executable path and was not found in PATH ($PATH)"

cd "$WORKSPACE_DIR" || refuse "cannot enter workspace '$WORKSPACE_DIR'"

# Export the resolved values so the harness and anything it spawns see the same
# contract this entrypoint validated.
export AGENT_ID AGENT_WORKSPACE_DIR="$WORKSPACE_DIR"

exec "$HARNESS_PATH" "$@"
