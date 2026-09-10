# Module: Policy Reload

Host-side procedure to apply changes to the OPA Rego policy without restarting
the Docker daemon. The OPA plugin compiles the Rego file at enable time;
disabling and re-enabling the plugin triggers a recompile.

## Purpose

Policy updates should not require a Docker daemon restart. Restarting dockerd
drops all running containers and disrupts service. A plugin bounce reloads the
policy in under a second with zero container impact.

## Inputs

- Parameters P-6, P-7 from SCHEMA.md.
- The updated `agent.rego` policy file at `<POLICY_SRC>` (the implementer's
  working copy, e.g. in a git repository).
- The OPA plugin must be installed and enabled (from Phase 4).

## Outputs

- `P-7/agent.rego` — the policy file deployed, copied from the source.
- Plugin state: disabled then re-enabled.

Side effects: during the brief window between `docker plugin disable` and
`docker plugin enable`, all Docker API requests from the sandbox are unblocked
(the daemon receives no authorization response and falls through to allow).
For most setups this window is under one second.

## Dependencies

- D-3 (the `opa-docker-authz` plugin)
- Parameters P-6, P-7

## Failure Behavior

- **Policy syntax error**: The plugin enable fails with a compile error from
  the OPA engine. The error includes the line number and problem (e.g.
  `rego_parse_error`). The plugin remains in disabled state. Recovery: fix
  the policy file and retry enable.
- **Plugin already disabled**: `docker plugin disable` returns an error.
  Check status with `docker plugin ls`.
- **Plugin not found**: The plugin was never installed. Run Phase 4 first.
- **Source file not found**: Copy fails. Check that the working directory is
  the repository root (or provide an absolute path to the source).

## Idempotency Notes

- Copying the policy file is idempotent (overwrites without checking, which
  is fine — we always want the latest version).
- Disable-then-enable is idempotent only if the plugin is currently enabled.
  If it's already disabled, skip the disable step.
- The script in `scripts/reload-opa-policy.sh` uses `grep -q` to check the
  plugin state before disabling.

## Removal Notes

- No removal needed for this module — it's a maintenance procedure, not a
  component. If the entire capability is removed (per SCHEMA.md's Removal
  section), this procedure becomes moot.