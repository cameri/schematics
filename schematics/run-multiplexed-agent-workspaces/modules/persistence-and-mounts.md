# Module: persistence-and-mounts

## Purpose

Owns where state lives, what a restart does to it, and what stopping a host
costs. The rule is one sentence: memory is the container's, state is the host's.
This module is explicitly NOT responsible for what an agent writes into its own
home or workspace — it guarantees the mount, not the contents.

## Inputs

- `AGENT_TREE` (`P-12`) and `AGENT_STATE_ROOT` (`P-13`), both under the mounted
  tree.
- The host directory a deployment mounts at `AGENT_TREE` (`P-30`), and the
  owner ids on that directory, which must match the base's runtime account for
  the bind mount to be writable (the base's account contract; this package
  restates neither the name nor the ids).
- The mounted SSH directory (`P-21`), when the host identity must survive a
  recreate.

## Outputs

- The layout, one pair per agent, plus the host's own directories:

  ```
  <AGENT_TREE>/
    <agent id>/workspace/     the agent's working directory — what it edits
    <agent id>/home/          the agent's HOME — where its session state lives
    .state/                   supervision state per agent, plus herdr's own server log
    .sshd/                    host key, sshd_config, authorized_keys, pid file
    .config/                  the herdr config root, when the deployment mounts it here
  ```

- A restart (container stop, then start) that resumes each agent from its home:
  the files the harness left there are the session it continues. herdr restores
  its workspace and pane shape from its own state under the config root, and the
  boot's reconciliation then re-establishes the current set on top of it.
- A stop that frees memory and touches no state: stopping the container ends the
  processes (agents, server, daemon) and leaves every file in the tree exactly
  where it was. This is what makes a stopped host cheap and a restarted host
  indistinguishable from the one that was running.
- A stable SSH host identity across recreates, because the host key is a file in
  the mounted tree rather than a fresh key per container: `AGENT_SSHD_DIR`
  (`P-21`) defaults to `<AGENT_TREE>/.sshd`, so the identity is a consequence of
  the mount rather than of a second mount the deployment has to remember.

## Dependencies

`D-1` (the base's account owns the mounted tree; the base's workspace contract
is what the per-agent workspace directories satisfy), and the parameters `P-12`,
`P-13`, `P-21`, `P-30`.

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| the tree directory does not exist on the host | the runtime creates it, empty, and the boot populates it: a first boot and a lost mount look identical, so the deployment should create it deliberately and check the mount |
| the tree is not writable by the account | refusal, exit 78, naming the directory — an unwritable tree otherwise produces an agent that fails on its first write instead of a host that refuses to start |
| a per-agent directory is missing | created by the boot; its absence is the normal state of a new agent |
| the home contains no session state | the harness starts a fresh session, which is the correct behaviour for a first run and the same code path as a resumed one |
| a bound directory is mounted read-only | the base's entrypoint refuses with its own code and message, naming the workspace; the host logs the pane's exit |
| the mounted tree is on a network filesystem | locks and atomic renames may misbehave; the tree is documented as a local directory, and nothing in this package depends on cross-device semantics beyond `mv` within one directory |

## Idempotency Notes

Mounts are declarative: re-creating a container with the same bind mounts yields
the same files. The boot creates missing directories and never removes state. The
one thing a replace does destroy is anything written inside the container's own
filesystem — which is why every path the host writes lives under the tree. Stop
markers live in `.state/` inside the tree, so a deliberate stop survives a
restart; that is intended, and removing the marker is what undoes it.

## Removal Notes

Removing a deployment's volumes from the compose file leaves the directories on
the host where they are; deleting them is the only operation in this package that
destroys agent state, and it should be a deliberate one. To retire a single
agent: drop it from `AGENT_IDS`, reboot, then remove `<AGENT_TREE>/<agent id>/`
and `<AGENT_TREE>/.state/<agent id>/` when its workspace and session are no longer
wanted. To retire the host: remove the container (state stays), then the
published port, then the directory.
