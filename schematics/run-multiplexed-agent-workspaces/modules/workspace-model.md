# Module: workspace-model

## Purpose

Owns the mapping from agents to herdr workspaces: one agent is one workspace,
named by the agent id, and that name is how every other part of the host
(including the agent's own supervision wrapper) knows which agent it is looking
at. It owns the reconciliation the boot program performs and the roster file
that carries identity into the panes. It is explicitly NOT responsible for
starting or supervising the agent process inside the workspace (see
`supervision.md`) or for what the agent runs (the base's entrypoint contract).

## Inputs

- `AGENT_IDS` (`P-11`): the agents this host runs, comma-separated. Each id must
  match the base's charset for an agent id — `[A-Za-z0-9._-]`, first character
  alphanumeric, at most 64 characters — because the id becomes a workspace label,
  a directory name, a state directory name and a log name.
- `AGENT_TREE` (`P-12`): the container path of the mounted tree, under which each
  agent gets `<tree>/<id>/workspace` and `<tree>/<id>/home`.
- The herdr binary and a running session (`P-3`, `P-14`), and the linked plugin.
- The existing workspace set, read back from `herdr workspace list`.

## Outputs

- One herdr workspace per agent id, `label` equal to the id, `cwd` equal to that
  agent's workspace directory. Any workspace that already carried the label is
  closed first, so the set converges instead of accumulating.
- The **roster**: `<config root>/plugins/config/<plugin id>/roster.tsv`, rewritten
  at every boot, one tab-separated line per agent:

  ```
  # workspace_id<TAB>agent_id<TAB>workspace_dir<TAB>home_dir
  w1<TAB>alpha<TAB>/agents/alpha/workspace<TAB>/agents/alpha/home
  ```

  Written *before* the agent pane is opened, because the wrapper reads it the
  moment it starts. It is derived state: never edited by hand, always rewritten
  from `AGENT_IDS` and the workspaces the boot just created.
- The agent pane, opened with `herdr plugin pane open --plugin <plugin id>
  --entrypoint agent --workspace <workspace id>`, and then the workspace's shell
  pane closed (unless the pane open failed, in which case the shell pane is kept
  as a manual fallback).
- A reconciliation marker at `<state root>/reconciling`, held for the duration of
  the loop and removed before the host attaches. It exists because closing a
  workspace fires the plugin's `pane.exited` hook: without the marker that hook
  would reopen, or recreate, a workspace this loop is about to create, and the
  agent would end up with two.
- Focus on the first workspace of the list, so an attach lands somewhere
  meaningful.

## Dependencies

`D-1` (the base image, for the workspace directory contract), `D-3` (the plugin
manifest and the two scripts, which name the pane and the hook), and the
parameters `P-11` … `P-14`, plus `P-16` (the entrypoint the pane runs).

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| `AGENT_IDS` empty | refusal, exit 78, naming the variable |
| an id outside the charset, or over 64 characters | refusal, exit 78, naming the id and the rule |
| a workspace directory that cannot be created or is not writable by the account | refusal, exit 78, naming the directory — a host that cannot write an agent's workspace must not start an agent that will fail later |
| `herdr workspace create` fails | refusal, exit 78, with herdr's own output |
| the created workspace id cannot be parsed | refusal, exit 78, with the raw output — the roster cannot be written without it |
| `herdr plugin pane open` fails | the workspace keeps its shell pane and the boot logs why; the host is still up and other agents are unaffected |
| a workspace exists with the wanted label | closed first, silently: reconciliation, not an error |

## Idempotency Notes

Re-running is the normal case: every container start runs the boot again. The
roster is rewritten from scratch (a stale line is a wrong agent), each agent's
workspace is closed and recreated, and the workspace count after a second boot
equals the count after the first — no duplicates, one workspace per id. The
reconciliation marker is removed before the host attaches, and on any exit path.

## Removal Notes

Closing the workspaces (`herdr workspace close <id>` for each label in
`AGENT_IDS`) leaves the host with no agent workspaces; deleting the roster's
directory under the config root removes the last derived state this module
writes. The workspaces are herdr session state, not files: they do not need to
be removed from disk, and a workspace left behind is harmless — the next boot
closes it by label.
