# Module: Policy Reload

Host-side procedure to apply a Rego policy change. On this package's default
install there is nothing to reload: **the plugin re-reads the policy file on
every request**, so the change is live on the next API call.

## Purpose

A policy update must not cost a daemon restart, and on the file path it does not
even cost a plugin bounce. `main.go` (`evaluatePolicyFile`) reads the policy
file, compiles it, and evaluates it *inside the handling of a single request*:

```go
bs, err := os.ReadFile(p.policyFile)
...
eval := rego.New(rego.Query(p.allowPath), rego.Input(input),
                 rego.Module(p.policyFile, string(bs)))
```

and it logs a sha256 of the bytes it read as the decision log's `config_hash`.
So the deployed file *is* the live policy, per request. Two properties of that
code decide the whole procedure:

| Deployment path | How a change takes effect | What the window looks like |
|---|---|---|
| `-policy-file` (**this package's install**) | The file is read per request: replace it and the next API call uses the new policy | No window, **provided the file is replaced atomically** — see below |
| `-config-file` with a bundle service | The plugin long-polls its bundle endpoint; a new bundle applies without touching the plugin process | No window: the old policy is in force until the new bundle is fetched |
| `docker plugin disable` → `enable` | Not a reload path at all: it stops the plugin the daemon is using | **Fatal** — see the next section |

**What a policy change is not:**

- **It is not a plugin bounce.** Disabling, removing, or upgrading a plugin that
  the running daemon references makes dockerd treat its own configuration as
  invalid and **exit**: `level=fatal msg="Error validating authorization
  plugin" error="plugin \"<P-14>\" not found"` (measured on Docker 29.6.1, snap
  install; Q-4 in SCHEMATIC.md's decisions). Before this was measured, the
  script this package shipped did exactly that.
- **It is not removing the plugin reference.** Deleting `P-14` from
  `authorization-plugins` and sending SIGHUP leaves an unrestricted daemon:
  every request is allowed while the entry is absent. That is the deliberate
  rollback of the whole capability, never a step in a policy update.

## Inputs

- Parameters P-6, P-7, P-13 from SCHEMATIC.md.
- The updated policy source (the implementer's working copy, e.g. in a git
  repository), with every placeholder substituted.
- The plugin installed and enabled (Phase 3). Its `-policy-file` argument and
  mount are read to find P-7 — `docker plugin inspect <P-14>` names both, so the
  path is derivable rather than guessed, and
  `scripts/reload-opa-policy.sh --discover` prints it read-only.

## Outputs

- `P-7/agent.rego` — the deployed policy, installed by atomic rename.
- `P-7/agent.rego.previous` — the policy it replaced, for rollback.
- Plugin state: **unchanged**. Nothing in this procedure disables, restarts, or
  reinstalls the plugin, and no daemon restart is involved.

## Pre-flight checks (before touching the deployed file)

1. **No placeholders left**: `grep -nE 'SANDBOX_USERNAME|AUTH_HEADER_NAME|PROJECT_NAME|PROJECT_DIR_PATH|BUILDKIT_PREFIX|TESTCONTAINERS_LABEL' <source>` must print nothing. A leftover token would be deployed as a literal and silently turn the policy into "allow everything". (`BUILDKIT_PREFIX` is retired — R-17 removed the BuildKit carve-out — and is kept in this pattern on purpose: the check is a superset of the template's tokens, so a source copied from an older template is still caught.)
2. **It parses**, under an engine **no newer than the plugin's** (P-10):
   `opa check <source>`, or the engine's own image when no binary is installed —
   `docker run --rm -v "$(pwd):/w:ro" -w /w openpolicyagent/opa:1.3.0 check <source>`.
   A newer engine accepts syntax the plugin's engine rejects.
3. **It decides correctly**: the `opa eval` probes in
   `skeleton/agent.rego.schema` still produce the expected allow/deny results —
   **with the plugin's real input shape**, which is the part this package got
   wrong once: `PathPlain` carries the API version prefix (`"PathPlain": u.Path`
   in `main.go`), so a probe table written with a version-less `PathPlain`
   proves nothing about a live daemon (issue #35). Every path in the table is
   `/v1.<n>/…`, and the runner records the version it used.
4. **A copy of the currently deployed policy is kept** before the replacement,
   so the change can be reverted with the same procedure.

## Dependencies

- D-3 (the authorization plugin)
- Parameters P-6, P-7, P-13

## Failure Behavior

- **Policy syntax error**: the plugin cannot compile it, so it returns an error
  and the daemon fails closed — an outage, not a security hole. Recovery:
  `--rollback` (restores `agent.rego.previous`) or re-deploy a valid file.
- **The policy file is missing when a request arrives**: the plugin **fails
  open** (`OPA policy file %s does not exist, failing open and allowing
  request`). This is the one open direction in this procedure, and it is why
  the deployed file is replaced by `install` to a temporary name followed by
  `mv -f` — one atomic rename — and never by copying or truncating the live
  path.
- **A partially written policy file**: it does not compile, so the request is
  denied and logged; the atomic rename makes this unreachable in the normal
  flow.
- **The plugin is missing, disabled, or was removed from the daemon's
  configuration**: dockerd will not complete a start or a reload — it exits
  with `Error validating authorization plugin`. If that state exists while the
  daemon is configured to reference the plugin, the daemon crash-loops, and
  `docker plugin enable` cannot help because it needs a running daemon:
  recovery is to remove the reference from the live daemon configuration file
  (P-13), start the daemon (unrestricted for the moment), `docker plugin
  enable <P-14>`, then put the reference back and apply it with SIGHUP. This is
  why nothing in this procedure touches plugin state.
- **Source file not found**: nothing is replaced. Pass an explicit path.
- **Bundle path unavailable**: with `-config-file`, the plugin keeps serving the
  last bundle it fetched; a decision-log or plugin-log line reports the fetch
  failure. The daemon is not disrupted, and the policy is stale rather than
  absent — state the staleness in the change record.

## Verification (not just "the file looks right")

0. `scripts/reload-opa-policy.sh --discover` prints the host path the plugin
   actually reads, derived from its `-policy-file` argument and the mount that
   carries it. Compare that with P-7 before deploying: a policy written to a
   directory the plugin does not mount is installed perfectly and read by
   nobody.
1. `sha256sum P-7/agent.rego`, then read the plugin's decision log for the next
   request and compare with its `config_hash` — the plugin logs the hash of the
   bytes it actually evaluated, so this is the difference between "the file on
   disk changed" and "the live policy changed".
2. A decision that the change was about: one that must be allowed and one that
   must be denied, over the TLS listener (Phase 8's tests).

## Idempotency Notes

- Installing the file is idempotent: the same source always produces the same
  deployed bytes, and `agent.rego.previous` is a copy of what was replaced.
- Substitution is idempotent, and the no-placeholder check makes a second run
  against an already-deployed file a no-op rather than a corruption.
- Re-running the procedure never leaves the plugin in a different state from
  the one it started in.

## Removal Notes

- No removal step of its own — this is a maintenance procedure. When the whole
  capability is removed, follow SCHEMATIC.md's Removal section, which removes
  the plugin reference from the daemon configuration **before** uninstalling the
  plugin.
