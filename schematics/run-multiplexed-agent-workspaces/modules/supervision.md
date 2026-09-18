# Module: supervision

## Purpose

Owns what happens when an agent process stops: whether it comes back, what the
operator sees, and how an operator deliberately keeps it down. The policy is
crash-only — a signal death relaunches, a clean exit does not — and it is
implemented by a wrapper that runs as the pane's process, with a `pane.exited`
hook as the fallback for the wrapper itself dying. This module is explicitly NOT
responsible for the workspace (see `workspace-model.md`) or for the agent's own
semantics: it observes exit statuses, nothing else.

## Inputs

- `HERDR_WORKSPACE_ID`, injected by herdr into every pane, and the roster, from
  which the wrapper resolves the agent id, its workspace directory and its home.
- `AGENT_STATE_ROOT` (`P-13`) and the per-agent state directory under it.
- `AGENT_ENTRYPOINT` (`P-16`) and the environment the pane inherits — in
  particular `AGENT_HARNESS` (`P-17`), which the base's entrypoint resolves.
- The crash bound (`P-23`, `P-24`, `P-25`) and the reopen bound (`P-26`, `P-27`,
  `P-28`).
- `HERDR_PLUGIN_EVENT_JSON`, which herdr passes to the hook, containing
  `data.workspace_id` for the pane that exited.

## Outputs

- For each agent, a state directory `<state root>/<agent id>/` holding:
  - `loop.log` — one line per start, exit, relaunch and backoff, with the exit
    status and the duration. This is the operator's account of what happened;
  - `stop` — present means keep this agent down. Written by the wrapper when the
    agent exits cleanly, and by an operator for maintenance;
  - `launches` — recent launch timestamps, trimmed to 50, for the crash bound;
  - `reopens` — recent reopen timestamps, for the hook's bound.
- Log lines for the two decisions an operator has to be able to tell apart: one
  saying the status was a death by signal and the agent is being relaunched, and
  one saying the status was a clean exit and the agent stays down, naming the
  stop marker to remove to allow a start again.
- A reopened pane when the wrapper itself dies, in the same workspace, or in a
  recreated workspace with the same cwd and label when herdr's auto-close
  cascade (pane, tab, workspace) already removed it. A recreated workspace id is
  written back into the roster so the wrapper resolves the same agent.

## Dependencies

`D-3` (the plugin: the pane runs the wrapper, the hook runs on `pane.exited`),
`D-1` (the entrypoint the wrapper execs, and the account it runs as), and the
parameters `P-13`, `P-16` … `P-17`, `P-23` … `P-28`.

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| `HERDR_WORKSPACE_ID` unset | refusal, exit 78: this program is a pane's process, and without the workspace it cannot know which agent it runs |
| the roster is missing, or has no line for this workspace | refusal, exit 78, naming the roster and the workspace id |
| the entrypoint is not executable | refusal, exit 78, naming the path |
| the agent exits with a status below 128 | stop marker written, one log line naming the marker path, the wrapper exits 0 and the pane closes |
| the agent dies from a signal (status ≥ 128, including an interrupt's 130) | relaunched in the same pane; the pane, tab and workspace never tear down |
| three launches inside 5 seconds (the configured bound) | a 30-second backoff, logged, then the next attempt — a permanently broken agent cannot spin |
| more than 5 reopens inside 60 seconds | the hook backs off before reopening |
| the wrapper itself is killed | the pane exits, the hook reopens it; the pane's death also runs herdr's auto-close cascade, so the hook may have to recreate the workspace first |
| the stop marker is present | the agent is not started at all, and the pane closes. The marker is read before **every** launch, not once at start-up, so writing it while a crash-looping agent sleeps out its backoff stops that agent at the end of the sleep |
| the hook fires while the boot is reconciling | it stands down: the boot owns the workspace set at that moment |

## Idempotency Notes

Every path is derived from the workspace id, so a relaunch re-reads the roster
and starts the agent again; nothing accumulates except the log, the trimmed
timestamps, and the explicit stop marker. Deleting one agent's state directory
resets that agent — the next launch recreates it — and is the documented way to
clear a crash-loop backoff that an operator does not want to wait out. The boot's
reconciliation closes and recreates workspaces, which the wrapper treats as a
fresh start: no state is carried across it except what lives in the agent's home.

## Removal Notes

Removing the plugin (`herdr plugin unlink <plugin id>`) removes the pane type and
the hook: no pane is reopened and no agent is relaunched. The per-agent state
directories live in the mounted tree (`P-12`, `P-13`) and are safe to delete —
they hold logs, timestamps and stop markers, never agent data. Removing an agent
from `AGENT_IDS` and rebooting closes its workspace and stops its supervision,
and leaves its home and workspace directories on the host untouched.
