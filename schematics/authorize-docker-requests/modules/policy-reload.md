# Module: Policy Reload

Host-side procedure to apply a Rego policy change without restarting the Docker
daemon. The daemon restart is the expensive move (it stops containers); the
plugin is the cheap one.

## Purpose

Policy updates should not require a daemon restart. What a policy update *does*
cost depends on how the plugin was installed, and the difference matters
operationally:

| Path | How it reloads | What the window looks like |
|------|----------------|---------------------------|
| `-config-file` with a bundle service | The plugin long-polls its bundle endpoint; a new bundle applies without touching the plugin process | No window: the old policy is in force until the new bundle is fetched |
| Managed plugin, `-policy-file` | Disable and re-enable the plugin so it re-reads the file | **Denial window**: while the plugin is unavailable, the daemon's authorization middleware fails closed and every API call is denied, host users included |
| Legacy plugin container | Restart the container | Same denial window |

The plugin's own documentation recommends the bundle form for exactly this
reason (plus decision logging). The file form is simpler to deploy and is what
this package's default install uses.

**What a reload is not:** removing the plugin reference from the live daemon
configuration file (P-13) and
sending SIGHUP is not a reload, it is a return to an unrestricted daemon — every
request is allowed while the entry is absent. Use it only as the deliberate
rollback, never as a step in a policy update.

## Inputs

- Parameters P-6, P-7, P-13 from SCHEMATIC.md.
- The updated policy source (the implementer's working copy, e.g. in a git
  repository), with every placeholder substituted.
- The plugin installed and enabled (Phase 3).

## Outputs

- `P-7/agent.rego` — the deployed policy, copied from the substituted source.
- Plugin state: bounces through disable → enable on the file path; unchanged on
  the bundle path.

## Pre-flight checks (before touching the running plugin)

1. **No placeholders left**: `grep -nE 'SANDBOX_USERNAME|AUTH_HEADER_NAME|PROJECT_NAME|PROJECT_DIR_PATH|BUILDKIT_PREFIX|TESTCONTAINERS_LABEL' <source>` must print nothing. A leftover token would be deployed as a literal and silently turn the policy into "allow everything".
2. **It parses**: `opa check <source>` with an `opa` binary at or below the
   plugin's engine version (see `skeleton/agent.rego.schema`).
3. **It decides correctly**: the `opa eval` probes in
   `skeleton/agent.rego.schema` still produce the expected allow/deny results.
4. **A copy of the currently deployed policy is kept**, so the change can be
   reverted with the same procedure.

## Dependencies

- D-3 (the authorization plugin)
- Parameters P-6, P-7, P-13

## Failure Behavior

- **Policy syntax error**: the plugin does not serve a decision, so the daemon
  fails closed and all API calls are denied until a valid policy is deployed.
  This is an outage, not a security hole. Recovery: restore the previous file
  and re-apply the reload.
- **Plugin already disabled**: the disable step fails or is skipped; the script
  in `scripts/reload-opa-policy.sh` checks the state before acting.
- **Plugin not found**: it was never installed. Run Phase 3 first — and note
  that a plugin installed without `opa-args` answers "allow" to everything, so
  "install it and move on" is not a valid recovery.
- **Source file not found**: the copy fails. Pass an explicit path.
- **Bundle path unavailable**: with `-config-file`, the plugin keeps serving the
  last bundle it fetched; a decision-log or plugin-log line reports the fetch
  failure. The daemon is not disrupted, and the policy is stale rather than
  absent — state the staleness in the change record.

## Idempotency Notes

- Copying the policy file is idempotent (it always overwrites with the source).
- Disable-then-enable is idempotent only if the plugin is currently enabled.
- Substitution is idempotent, and the no-placeholder check makes a second run
  against an already-deployed file a no-op rather than a corruption.

## Removal Notes

- No removal step of its own — this is a maintenance procedure. When the whole
  capability is removed, follow SCHEMATIC.md's Removal section, which removes
  the plugin reference from the daemon configuration **before** uninstalling the
  plugin.
