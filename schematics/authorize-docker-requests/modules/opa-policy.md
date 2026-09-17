# Module: OPA Policy

The Rego authorization policy that decides which Docker API calls the sandbox
may perform. The policy file is `skeleton/agent.rego`; it is evaluated by the
authorization plugin on every daemon request.

## Purpose

Implements the authorization rules defined in R-1 through R-19. The policy
distinguishes sandbox clients (by TLS certificate CN or HTTP header) from local
host users, grants the sandbox read-only access by default, and then selectively
permits compose project operations, image builds, pulls, and a closed lifecycle
allowlist. Everything else is denied. Local host users (unix socket, no TLS)
pass through unrestricted.

Four of those rules are what the policy does *beyond* naming a project, and they
exist because "may create containers in its project" and "may create any
container, in its project" are different grants:

- **R-15** — every create path that carries the project label (or the
  testcontainers label) must additionally pass a host-access gate: no
  `Privileged`, no `CapAdd`, no `Devices`, no `SecurityOpt`, no `VolumesFrom`,
  no host or container-joined namespace (`PidMode`, `IpcMode`, `NetworkMode`,
  `CgroupnsMode`), no `UsernsMode`, and no mount whose source is neither a
  volume name nor a path inside `P-15` or inside a root named by `P-16`.
- **R-16** — a volume create may not carry `DriverOpts`, and its driver must be
  `local` (or unset). `DriverOpts: {type: none, o: bind, device: /}` makes a
  project-named volume the host filesystem.
- **R-17** — grants match a path by *equality* (`/build`, `/images/create`,
  `/containers/create`), never by substring, and no carve-out may be reachable
  from another endpoint — a create-shaped body on `/containers/<id>/attach` or
  `/exec` must not satisfy the create rule.
- **R-18** — network and volume deletes are scoped by the project as a whole
  path segment, the same way creation is scoped by name.
- **R-19** — path matching is version-independent. `path` is `PathPlain` with
  one optional `/v<major>[.<minor>]` prefix removed and no `..` segment; every
  rule matches that, so the same policy decides the same on a live daemon (which
  sends `/v1.56/containers/create`) and for a client that omits the version
  (which sends `/containers/create`).

## Inputs

The plugin enriches the request the daemon passes it (`AuthZPlugin.AuthZReq`)
before evaluation. Fields the policy uses:

- `input.User` — string. The TLS client certificate's subject common name;
  empty for unix-socket requests and for TCP clients that present no
  certificate. Value `P-4` for sandbox clients.
- `input.AuthMethod` — string. `TLS` when the client authenticated with a
  certificate.
- `input.Method` — string. HTTP method: `GET`, `HEAD`, `POST`, `DELETE`.
- `input.PathPlain` — string. The **raw request path**: API version prefix
  included, query string excluded (`u.Path`), e.g. `/v1.56/containers/json`.
  Nothing strips the version, so the policy derives `path` from it
  and matches that with `==` (R-17, R-19) — the raw field is read for nothing
  else.
- `input.PathArr` — array. `PathPlain` split into path elements, so its second
  element is the version. Not read by the policy: `path_segments` is the derived
  path split the same way, which is what matches a resource named in the path as
  a whole segment rather than as a substring.
- `input.Query` — object. The parsed query string as a map of arrays. A
  container create's name arrives here (Docker takes it from the `name` query
  parameter, not the body); no grant depends on it.
- `input.Headers` — object. Header names to header values, as plain strings
  (`map[string]string` in Docker's own message type, so a value is never an
  array). The header named by `P-9` with the value `true` is the secondary
  identity check.
- `input.Body` — object or `null`. Decoded JSON request body. `null` for
  requests that carry none, which is every `DELETE` and most `GET`s.
- `input.Body.Labels` — object. Container labels. Contains
  `com.docker.compose.project = P-3` for containers created by the project's
  compose file.
- `input.Body.Name` — string. Network or volume name. Compose names its
  networks and volumes `<project>_<suffix>`. A *container* name is not here:
  Docker takes it from the `name` query parameter, which is why the create
  grant does not read it at all.
- `input.Body.Driver`, `input.Body.DriverOpts` — a volume create's driver and
  driver options; R-16 refuses a non-`local` driver and any non-empty
  `DriverOpts`.
- `input.Body.HostConfig` — the create's host-side configuration, and the whole
  of the R-15 gate: `Privileged`, `CapAdd`, `Devices`, `SecurityOpt`,
  `VolumesFrom`, `PidMode`, `IpcMode`, `NetworkMode`, `CgroupnsMode`,
  `UsernsMode`, `Binds`, `Mounts`.
- `input.BindMounts` — array of objects with `Source`, `ReadOnly`, and
  `Resolved` (the source path with symlinks resolved). Derived from either
  `HostConfig.Binds` or `HostConfig.Mounts`. The policy checks every witness of
  a mount — `Resolved` where the plugin supplies it, then `Source`, then the raw
  arrays — rather than the first that answers, so an inconsistency between them
  refuses the create instead of passing it. It is not used to attribute a
  create to the project; the label does that.

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
| `ghcr.io/open-policy-agent/opa-docker-authz:v0.10` | **v1.3.0** | loads; every one of the 86 probe rows decides as specified |
| `openpolicyagent/opa-docker-authz-v2:0.9` | v0.60.0 | loads; identical decisions on all 86 probe rows |
| `openpolicyagent/opa-docker-authz-v2:0.8` | v0.30.0 | does **not** load — `import rego.v1` is rejected |

The embedded versions are read from each release's own `go.mod` at its tag
(`v0.10` → `github.com/open-policy-agent/opa v1.3.0`), and the probe table was
then run under those engines and under a newer one (v1.7.1) as a forward check.

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

(`P-11`'s `BUILDKIT_PREFIX` token is not read by any rule, but the leftover
check still greps for it, so a copy that carries the token is rejected rather
than silently deployed.)

## Limitations

These are properties of the authorization interface, not defects to be fixed
later; the deployment must be aware of them (SCHEMATIC.md states them as
limitations):

- **A `DELETE` or a lifecycle call on an existing *container* carries nothing
  that attributes it to a project.** The request body is `null` and the path
  holds only an id or name. `docker compose down` needs those calls, so they are
  allowed for any container the client can name. Network and volume deletes are
  scoped (R-18) because their path names the resource; container deletion and
  lifecycle calls are not.
- **The R-15 gate refuses in the safe direction.** A create that asks for a
  field the gate knows is refused even where the field is exotic rather than
  dangerous — a `DriverOpts`-bearing local volume (R-16), a compose
  `network_mode: service:<name>`, a mount that names a resource by id. Every one
  of those has a form that is allowed (no `DriverOpts`, an explicit network, a
  name); a deployment that needs the refused form must extend the policy
  deliberately, and the probe table must grow a row with it.
- **The table is not the daemon.** A probe row decides about the input it
  carries; if that input is not the plugin's, the table agrees with a fiction.
  The plugin always sends the API version prefix in `PathPlain`, so a row fed a
  version-less path exercises a request that never arrives — run rows with the
  plugin's own values (`main.go`'s `makeInput`), and treat a live test as what
  proves those values are the plugin's.
- **Host port publishing is not part of the gate.** A project container may
  publish a host port (`ports:`), which does not read the host filesystem but
  can occupy a free port and answer for it. Closing that is the daemon
  configuration's or the firewall's job; see SCHEMATIC.md's Limitations.
- **Identity is what the client presents, not what it is.** Any TLS client whose
  certificate CN is not exactly `P-4`, and any client reaching the unix socket,
  is treated as a host user and allowed everything. The CA must sign sandbox
  certificates only for `P-4`; a second certificate signed by the same CA with a
  different CN is a host-equivalent credential.
- **The accepted bind roots are a deployment decision, not a discovery.** `P-15`
  plus `P-16` is the entire set of host paths a create may bind, so a host whose
  stacks keep their data outside the project directory needs each extra root
  named in `P-16` before those containers can be created at all. Each root is a
  prefix grant: naming a directory accepts its subtree, naming a file accepts
  that file alone, and a `..` segment is refused under every root. An empty
  `P-16` is the default and accepts nothing beyond the project directory; an
  unsubstituted token yields no root, so the failure direction is a denied
  create.
- **The mount check is only as good as the plugin's filesystem view.** A
  managed-plugin install mounts only the policy directory into the plugin, so
  `Resolved` is empty for project paths and the check falls back to the raw
  source strings — which a symlink inside `P-15` pointing outside it satisfies.
  Sources with a `..` segment are refused outright, so the residual case is a
  symlink, not a traversal. A legacy install (or a rebuilt plugin `config.json`
  with the host filesystem mounted read-only) is what makes symlink resolution
  effective. The check applies to every container create (R-15); it is not
  consulted for attribution.

## Dependencies

- D-1, D-3, D-4 (from SCHEMATIC.md)
- Parameters P-3, P-4, P-9, P-12, P-15, P-16 (P-11 is not read by this policy)

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
