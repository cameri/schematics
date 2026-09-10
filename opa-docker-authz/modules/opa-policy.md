# Module: OPA Policy

The Rego authorization policy that decides which Docker API calls the sandbox
may perform. Evaluated by the `opa-docker-authz` plugin on every daemon request.

## Purpose

Implements the authorization rules defined in R-1 through R-12. The policy
distinguishes sandbox clients (by TLS certificate CN or HTTP header) from
local host users, grants the sandbox read-only access by default, and then
selectively permits compose project operations, image builds, pulls, and a
closed lifecycle allowlist. Everything else is denied. Local host users (unix
socket, no TLS) pass through unrestricted.

## Inputs

- `input.User` — string. Set by the plugin from the TLS client certificate CN.
  Empty string for unix-socket (host) requests. Value `"sandbox-agent"` for
  sandbox clients.
- `input.Method` — string. HTTP method: `GET`, `HEAD`, `POST`, `DELETE`.
- `input.PathPlain` — string. Request path without API version prefix, e.g.
  `/containers/json`, `/images/create`, `/build`.
- `input.Headers` — object (string → string array). HTTP headers. The
  `X-Sandbox-Agent` header with value `"true"` is used as a secondary identity
  check.
- `input.Body.Labels` — object (string → string). Container labels, present
  only on container-create requests. Contains `com.docker.compose.project`
  for compose-created containers.
- `input.Body.HostConfig.Binds` — array of strings. Bind mount specifications,
  e.g. `["/src/path:/dst/path"]`.
- `input.Body.HostConfig.Mounts` — array of objects. JSON-style mount specs,
  each with `Source`, `Target`, `Type` keys.
- `input.Body.Name` — string. Container name, present on container-create
  requests. Used to detect BuildKit builder containers (prefix `/buildx_buildkit_`).

## Outputs

- `allow` — boolean. The `opa-docker-authz` plugin reads this as the
  authorization decision. Must evaluate to `true` for the request to proceed;
  any other value (or undefined) denies the request with a `403 Forbidden`
  response containing `"authorization denied by plugin opa-docker-authz"`.

Side effects: none. The Rego evaluation is pure and stateless.

## Dependencies

- D-1, D-3, D-4 (from SCHEMATIC.md)
- Parameters P-3, P-4, P-8, P-9, P-11, P-12

## Failure Behavior

- If the policy file is absent or malformed, the OPA plugin fails to start
  (plugin enable fails with a compile error). Docker continues running but
  without authorization — all requests pass through until the plugin is
  re-enabled with a valid policy.
- If the policy is missing a rule that should match (e.g. a new compose
  project), the default `allow := false` denies the request. This is a safe
  failure.

## Idempotency Notes

- The Rego policy is pure (no side effects) and stateless. Re-evaluating it a
  thousand times with the same input gives the same result.
- Policy file writes are idempotent: `install -m 644 agent.rego P-7/agent.rego`
  overwrites in place. The plugin must be bounced to pick up changes.

## Removal Notes

- Remove the file: `rm P-7/agent.rego`
- Disable the plugin: `docker plugin disable opa-docker-authz`
- Without the plugin, Docker runs without authorization — the sandbox gets
  full Docker access over TLS. To restore the unsecured state, remove the
  plugin and restart dockerd without the authorization-plugins config.