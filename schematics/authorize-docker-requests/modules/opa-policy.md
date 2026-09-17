# Module: OPA Policy

The Rego authorization policy that decides which Docker API calls the sandbox
may perform. The policy file is `skeleton/agent.rego`; it is evaluated by the
authorization plugin on every daemon request.

## Purpose

Implements the authorization rules defined in R-1 through R-14. The policy
distinguishes sandbox clients (by TLS certificate CN or HTTP header) from local
host users, grants the sandbox read-only access by default, and then selectively
permits compose project operations, image builds, pulls, and a closed lifecycle
allowlist. Everything else is denied. Local host users (unix socket, no TLS)
pass through unrestricted.

## Inputs

The plugin enriches the request the daemon passes it (`AuthZPlugin.AuthZReq`)
before evaluation. Fields the policy uses:

- `input.User` — string. The TLS client certificate's subject common name;
  empty for unix-socket requests and for TCP clients that present no
  certificate. Value `P-4` for sandbox clients.
- `input.AuthMethod` — string. `TLS` when the client authenticated with a
  certificate.
- `input.Method` — string. HTTP method: `GET`, `HEAD`, `POST`, `DELETE`.
- `input.PathPlain` — string. Request path without the query string, e.g.
  `/containers/json`, `/images/create`, `/build`.
- `input.PathArr` — array. `PathPlain` split into path elements. Used to match a
  resource named in the path as a whole segment rather than as a substring.
- `input.Headers` — object. Header names to header values, as plain strings.
  The header named by `P-9` with the value `true` is the secondary identity
  check.
- `input.Body` — object or `null`. Decoded JSON request body. `null` for
  requests that carry none, which is every `DELETE` and most `GET`s.
- `input.Body.Labels` — object. Container labels. Contains
  `com.docker.compose.project = P-3` for containers created by the project's
  compose file.
- `input.Body.Name` — string. Container, network, or volume name. Compose names
  its networks and volumes `<project>_<suffix>`.
- `input.BindMounts` — array of objects with `Source`, `ReadOnly`, and
  `Resolved` (the source path with symlinks resolved). Derived from either
  `HostConfig.Binds` or `HostConfig.Mounts`, and consulted for path-named
  network and volume operations; container creation is attributed by the compose
  label instead.

## Outputs

- `allow` in package `docker.authz` — boolean. The plugin queries
  `data.docker.authz.allow` for the authorization decision. `true` allows the
  request; `false` or an undefined result denies it, and the client sees
  `authorization denied by plugin <name>`.

Side effects: none. The Rego evaluation is pure and stateless.

## Language and Engine

The policy ships in **Rego v1** syntax (`import rego.v1`, `if` rule heads,
`some x in`). It is evaluated by the OPA engine compiled into the plugin image,
so the plugin release decides the language version:

| Plugin image | Embedded OPA | Result |
|--------------|--------------|--------|
| `ghcr.io/open-policy-agent/opa-docker-authz:v0.10` | v1.7.1 | loads; decisions verified |
| `openpolicyagent/opa-docker-authz-v2:0.9` | v0.60.0 | loads; identical decisions verified |
| `openpolicyagent/opa-docker-authz-v2:0.8` | v0.30.0 | does **not** load — `import rego.v1` is rejected |

A change to the policy is validated with the engine that will run it
(`opa check`, then `opa eval` probes as listed in
`skeleton/agent.rego.schema`). Validating with a newer `opa` binary than the
plugin's engine proves nothing about the plugin.

## Placeholders

`agent.rego` is a template: seven tokens must be substituted from the Parameters
table before deployment, and the deployed file must be checked for leftovers.
A leftover is a silent full-access bug, not a cosmetic one: `is_sandbox` then
never matches a real client, so the sandbox is classified as a host user and
every request is allowed. See Phase 6 and its acceptance test.

## Limitations

These are properties of the authorization interface, not defects to be fixed
later; the deployment must be aware of them (SCHEMATIC.md states them as
limitations):

- **A `DELETE`, or a lifecycle call on an existing object, carries nothing that
  attributes it to a project.** The request body is `null` and the path holds
  only an id or name. `docker compose down` needs these calls, so they are
  allowed for any container, network, or volume the client can name. Project
  scoping applies to *creation* (labels, body name) and to path-named
  operations.
- **Identity is what the client presents, not what it is.** Any TLS client whose
  certificate CN is not exactly `P-4`, and any client reaching the unix socket,
  is treated as a host user and allowed everything. The CA must sign sandbox
  certificates only for `P-4`; a second certificate signed by the same CA with a
  different CN is a host-equivalent credential.
- **The bind-mount check is only as good as the plugin's filesystem view.** A
  managed-plugin install mounts only the policy directory into the plugin, so
  `Resolved` is empty for project paths and the check falls back to the raw
  source strings. A legacy install (or a rebuilt plugin `config.json` with the
  host filesystem mounted read-only) is what makes symlink resolution
  effective. The check is consulted for path-named network and volume
  operations, not for container creation.

## Dependencies

- D-1, D-3, D-4 (from SCHEMATIC.md)
- Parameters P-3, P-4, P-9, P-11, P-12

## Failure Behavior

Failure behavior has two independent halves, and they point in opposite
directions. Both were read from the plugin's and Docker's own documentation:

- **The daemon fails closed.** When the plugin is unreachable or returns an
  error, the Engine's authorization middleware denies the request and surfaces
  the error to the client. A dead plugin is an outage for every client,
  including host users, not an open door.
- **The plugin fails open if it was given no policy.** A plugin installed
  without a `-policy-file` or `-config-file` argument answers *every* request
  with "allow". This is why the install step must pass `opa-args` and why the
  deployment verifies it (Phase 3 and its acceptance test).
- **A malformed policy is a third case**: the plugin cannot compile it, so it
  does not serve a decision and the daemon's fail-closed behavior applies.
  Installing a policy therefore cannot silently open the daemon, but deploying
  one with unresolved placeholders can (see Placeholders above).
- **If the policy is missing a rule that should match** (e.g. a new compose
  project), `default allow_sandbox := false` denies the request. That is the
  intended direction.

## Idempotency Notes

- The Rego policy is pure (no side effects) and stateless. Re-evaluating it a
  thousand times with the same input gives the same result.
- Substitution is idempotent as long as the tokens are gone afterwards; the
  leftover check makes a second run report "nothing to do" rather than corrupt
  an already-substituted file.
- Policy file writes are idempotent: `install -m 644 agent.rego <POLICY_DIR>/agent.rego`
  overwrites in place.

## Removal Notes

- Remove the file: `rm <POLICY_DIR>/agent.rego`
- Remove the plugin from `authorization-plugins` **first**, then uninstall it:
  removing the plugin while the daemon still references it leaves the daemon
  failing closed, which is an outage rather than a rollback.
- With the policy gone and the plugin no longer referenced, the daemon accepts
  every authenticated client again: the sandbox's TLS client keeps working, and
  is no longer restricted. Removing this capability is a deliberate return to
  "anyone who can reach the daemon can do anything".
