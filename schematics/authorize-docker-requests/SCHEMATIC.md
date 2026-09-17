<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: authorize-docker-requests
version: 0.6.0
status: draft
spec: 1
description: Grants a sandbox container restricted Docker daemon access over TLS, policed by Open Policy Agent — certificate infrastructure, Rego policy, systemd TCP listener, and sandbox client provisioning.
created: 2026-09-09
updated: 2026-09-17
---

# Schematic: OPA Authorization for Docker Sandbox Access

> **Reverse-engineered, then verified.** This schematic was reconstructed from a
> running implementation on 2026-09-09, and nothing in it had been built since.
> On 2026-09-16 every claim was re-checked against the plugin's, Docker's, and
> Open Policy Agent's own documentation, and the policy was loaded and its
> decisions probed under the OPA engines the two installable plugin releases
> embed. Claims that are still inferences carry `inferred:` markers; the absence
> of a marker means the claim is either observed or documented at the cited
> source. Three reverse-engineering notes survive that pass, corrected:
> 1. The plugin's Rego function support is no longer inferred from documentation
>    prose: the policy is validated by running it under the plugin's engine
>    versions (see `skeleton/agent.rego.schema`).
> 2. The bind-mount heuristic is corrected. The plugin supplies a `BindMounts`
>    array with resolved source paths, and a managed-plugin install cannot
>    resolve host paths the plugin cannot read — both facts change which check
>    is effective in which deployment shape.
> 3. Failure behavior is documented, not assumed, and it points in two
>    directions: the **daemon** fails closed when the plugin is unavailable,
>    while the **plugin** fails open if it was installed without a policy
>    argument. Both are stated where they apply.
>
> **2026-09-17 — the create path was hardened.** A review pass found that
> "the sandbox may create containers in its project" had been read as "the
> sandbox may create *any* container in its project": a project-labelled
> create could ask for `Privileged`, `CapAdd`, host namespaces, host devices,
> a bind of `/`, or a volume whose driver options are a bind of `/`, and the
> policy allowed it. Requirements R-15 to R-18 close that, asserted by a probe
> table in which 30 of its 71 rows decided wrongly before the change and every
> row decides as specified after it, on the three OPA engines the package names
> (see `skeleton/agent.rego.schema`).
Grants a sandbox container (isolated agent, CI runner, or untrusted workload)
restricted TCP access to the host Docker daemon, policed by Open Policy Agent.
After implementing this schematic, the host's Docker daemon listens on a TLS
port, an OPA plugin authorizes every API call against a Rego policy, and the
sandbox container carries a client TLS certificate and environment variables that
let it run Docker commands — but only operations the policy permits.

The policy enforces: read-only for most resources, compose project operations
for a single named project (container, network, and volume *creation*, and
network and volume *deletion*), image builds and pulls, and container lifecycle
actions (start/stop/restart/kill) against an allowlist. Every container create
that carries the project's own label still has to pass a host-access gate
(R-15): a privileged container, added capabilities, host devices, a host or
joined namespace, an added security profile, `VolumesFrom`, or a mount source
outside the project directory is refused. Exec and attach are denied. The
host's local unix socket remains unrestricted for host users — and that is also
this capability's boundary: any client that can reach the socket, including a
container that has it mounted, is a host user and is not policed at all (see
Limitations).

## Applicable Context

**Must discover locally:**
- The host's routable IP address (used as the TLS SAN and the DOCKER_HOST value).
  Discovery: `tailscale ip -4` (if Tailscale is installed) else `ip -4 addr show
  scope global | grep -oP 'inet \K[\d.]+' | head -1`.
- Whether the host is running a systemd-based Linux distribution (for the
  systemd drop-in). Discovery: `systemctl --version` succeeds.
- The installed Docker daemon version (to verify plugin compatibility).
  Discovery: `docker version --format '{{.Server.Version}}'` — this reports the
  daemon's version regardless of how the daemon was installed, where
  `dockerd --version` does not when only the snap package provides the daemon.
- **The live daemon configuration file.** This is not always
  `/etc/docker/daemon.json`: a snap-installed daemon reads
  `/var/snap/docker/current/config/daemon.json` and never reads the file under
  `/etc/docker`, so a correct-looking `/etc/docker/daemon.json` there is inert.
  Discovery: `systemctl show docker --property=FragmentPath,ExecStart` — a unit
  belonging to the snap package means the snap's configuration file; confirm by
  reading the file the unit's command line names. See the daemon-config module
  for the full procedure and the observable-effect check that proves the file is
  the live one.
- The daemon's systemd unit name and whether it already passes `-H` flags.
  Discovery: `systemctl show <unit> --property=ExecStart`.
- Whether the daemon has live-restore enabled, which decides what a daemon
  restart costs the running containers. Discovery:
  `docker info --format '{{json .LiveRestoreEnabled}}'`.
- Whether port P-2 is already bound. Discovery: `ss -tlnp | grep :P-2`.
- Whether any container that this capability is meant to police still mounts the
  Docker socket, which would make the policy ineffective for it. Discovery:
  `docker inspect <container> --format '{{range .Mounts}}{{.Source}} {{.Destination}}{{println}}{{end}}'`.
- The host filesystem paths for the certificate directory and systemd drop-ins
  (`/etc/systemd/system/docker.service.d`). Discovery:
  `systemctl show docker --property=FragmentPath`, and the directory's existence.

**May assume:**
- Linux x86_64 host (assumption shared by almost every Docker deployment).
  Risk if wrong: OpenSSL and the OPA plugin image may not be available for the
  architecture.
- Docker is installed and managed by systemd, under either the snap unit or a
  distribution unit. Risk if wrong: the systemd drop-in step must be adapted to
  the init system.
- The sandbox container is rootless (non-root user inside). Risk if wrong: file
  permissions on certs may be too restrictive.
- `docker plugin` (the managed plugin system) is available and the daemon can
  pull the plugin image from its registry. Risk if wrong: the legacy plugin path
  with `--plugin` flags on dockerd must be used, which has a different install
  and reload procedure (see the policy-reload module).
- The sandbox can reach the daemon's TCP address (`P-1:P-2`) over the network —
  same host, same bridge, or a routable path. Risk if wrong: the client must be
  given an address that is reachable from inside its network namespace.

**Must not change:**
- Existing Docker daemon `hosts` configuration — it conflicts with the systemd
  `-H` flag. Use a systemd drop-in instead.
- The host's unix socket authorization behaviour: it remains unrestricted.
- Any existing `authorization-plugins` in the live daemon configuration file —
  they are merged, not replaced.
- After the sandbox's socket mount is removed (Phase 9, R-14), it must not be
  re-added as a convenience: doing so silently voids the policy for that
  container, and nothing in the capability will report it.

## Scope

**In scope:**
- TLS certificate authority creation and certificate signing (CA, server cert
  with SANs, client cert with CN identity).
- Docker daemon configuration: TLS verification enabled, OPA authz plugin
  registered.
- Systemd drop-in to add TCP listener on a TLS port alongside the existing
  `-H fd://`.
- OPA Rego policy that enforces sandbox restrictions (read-only, project-scoped
  create, build/pull, lifecycle allowlist).
- Install of the OPA Docker authorization plugin (`opa-docker-authz`) as a
  managed plugin, with its policy argument.
- Sandbox provisioning: client certs and shell environment file written to a
  host directory later bind-mounted into the container.
- The integration step that makes the policy effective for the sandbox: removing
  its Docker socket mount (R-14).
- Policy reload procedure (replace the policy file; nothing is bounced — see
the policy-reload module).
- Verification commands for TLS connectivity and OPA enforcement.

**Out of scope / non-goals:**
- The sandbox container itself (Containerfile, entrypoint, bind mounts — the
  host-side config is in scope, the container image is not).
- Multi-project support (the policy hard-codes a single project name).
- High availability or multi-host orchestration.
- Metrics or audit logging beyond what the OPA plugin emits.
- Automatic certificate rotation.
- The sibling `restrict-docker-api-access` proxy path: a consumer that needs only
  a slice of the API should use that schematic, and traffic through it arrives at
  the daemon on the unix socket, where this policy cannot see it.

### Limitations

These are boundaries of the mechanism, not defects to be fixed later. A
deployment that does not accept them is deploying something else.

- **Container operations on existing objects cannot be attributed to a
  project.** A `DELETE`, or a lifecycle call on an existing container, carries
  no request body and names its target only by id or name, so the policy allows
  them for any container id the client can name. `docker compose down` needs
  those calls. Scoping applies to *creation* (labels and body name), to
  path-named operations, and — since 2026-09-17 — to network and volume
  deletion, whose path does name the resource (R-18). It does not apply to
  container deletion or lifecycle calls.
- **A network or volume delete must name the resource.** R-18 matches the
  project as a whole path segment, so `docker volume rm <P-3>_data` and
  `docker network rm <P-3>_default` are allowed while `docker volume rm
  <volume-id>` — the same volume, named by its opaque id — is refused. The
  refusal is the safe direction: compose deletes by name.
- **Identity is what the client presents.** Any TLS client whose certificate CN
  is not exactly `P-4`, and any client on the unix socket, is a host user and is
  allowed everything. A second certificate signed by the same CA with another CN
  is a host-equivalent credential. The `P-9` header is a *self-declared*
  secondary signal: because an unidentified client is already unrestricted,
  sending the header can only narrow a client's privileges, never grant any — it
  is a testing and defence-in-depth aid, not a second factor.
- **The policy cannot see socket traffic.** A container with
  `/var/run/docker.sock` mounted acts as a host user; a `:ro` mount is no
  protection, because the read-only attribute applies to the socket file and not
  to the API calls over it.
- **Host-access refusal is a deny list, and it is not exhaustive.** R-15
  refuses the host-reaching fields the policy knows: `Privileged`, `CapAdd`,
  `Devices`, `SecurityOpt`, `VolumesFrom`, `PidMode`/`IpcMode`/`NetworkMode`/
  `CgroupnsMode` naming the host or another container, `UsernsMode`, and mount
  sources outside `P-15`. **Published host ports are not covered**: a project
  container may map a host port (compose `ports:`) or ask for
  `PublishAllPorts`. Binding a port is not root — it cannot read the host
  filesystem — but a container can occupy a port a host service is not yet
  using and answer for it. A deployment that needs that closed must close it
  in the daemon's own configuration or in the firewall, not here.
- **The mount check is only as good as the path it is given.** R-15 accepts a
  mount source that is not an absolute path (a volume name) or that is a path
  inside `P-15` with no `..` segment. That is a *string* test on the source
  the request carries, so a symlink *inside* `P-15` that points outside it is
  caught only by the plugin's `Resolved` field: a managed-plugin install
  mounts only the policy directory into the plugin, cannot read host paths,
  and leaves `Resolved` empty (the policy then falls back to the raw source
  string, which the symlink satisfies). Everything the plugin *can* resolve is
  checked — `Resolved` where the plugin supplies it, `Source` and the raw
  `HostConfig.Binds`/`HostConfig.Mounts` arrays otherwise, all of them rather
  than the first that answers — and the raw source is refused outright when it
  contains a `..` segment. Closing the remainder means a plugin installation
  that can read the host paths it checks.
- **The bind allow-list is exactly as wide as `P-15` plus `P-16`.** A bind
  source is the one input to this decision where the operator's real layout, not
  the API's shape, decides what is legitimate: a host whose stacks keep
  downloads, libraries or documents outside the project directory cannot create
  those containers at all until each such root is named in `P-16`. Two
  consequences follow. A root is a *prefix* grant — naming `/srv/media` accepts
  its whole subtree, so name the narrowest root that covers the deployment, and
  name a single file exactly rather than its directory when only that file is
  intended (a directory holding private keys stays out while one named file
  inside it can be named). And traversal is refused under every root, because
  `path..` is what a prefix grant otherwise reaches: `<P-16>/../../etc` starts
  with the root and is still refused. An unsubstituted `EXTRA_BIND_ROOTS` token
  on its own yields no root at all, so its failure direction is a denied create
  rather than a widened boundary — the identity token is the one whose leftover
  opens everything (R-13).
- **A policy that grants neither `exec` nor `attach` changes what a client
  command can do, and the failure reads as a broken tool rather than as a
  decision.** Measured against a hardened daemon as the sandbox client:
  `docker run` cannot complete — its create is granted and the attach that
  follows is refused — so the working forms are `docker create` + `docker start`,
  or `docker compose up -d`. A build must set `DOCKER_BUILDKIT=0`: BuildKit's
  first request is `POST /grpc`, which is denied and stays denied (the classic
  builder needs no grant the policy should not give), and its second is a builder
  container that the project-name rules refuse. And anything that administers or
  inspects a container through `docker exec` — cross-container tooling,
  in-container diagnostics — stops working. Every one of those denials carries
  the plugin's message (`authorization denied by plugin <P-14>`), so the state is
  legible once it is clear that it is the policy answering, not a fault.
- **A malformed or placeholder-bearing policy is not a security hole but an
  outage or an open door, depending on how it fails**: unresolved placeholders
  make every request allowed (R-13), while a policy that does not compile leaves
  the daemon failing closed.
- **A probe table can only be as real as its inputs.** The policy is proven by
  running engines and probes as described in `skeleton/agent.rego.schema` — 86
  rows, decision-checked on three OPA engines (OPA v0.60.0 and v1.3.0, the two
  the installable plugin releases embed, plus v1.7.1) — but a row decides only
  about the input it carries. A row fed a version-less `PathPlain` proves
  nothing: the plugin always sends the version, so the table agrees with itself
  while the rules it covers decide nothing. Only a **live** run (A-11, A-16)
  can find a mismatch between the table's model of the input and the plugin's.
- **A project name that is also an API path segment widens the segment match.**
  `P-3` is matched as a whole path segment (R-12, R-18). A deployment whose
  project is called `containers` — the host this package was verified against —
  therefore also satisfies the match on any path that contains the API's own
  `containers` segment, so a foreign network or volume literally named
  `containers` could be deleted. Container paths are unaffected in practice
  (container delete and lifecycle calls are unscoped anyway). Pick a project
  name that is not an API segment if that matters.

**Preservation List** *(reverse-engineered; corrected 2026-09-16)*:

*Must match original behaviour exactly:*
- The `is_sandbox` identity detection: certificate CN `P-4` **or** the `P-9`
  HTTP header carrying the value `true`. The CN is the primary identity; the
  header is a secondary signal. `inferred:` the original implementation's
  rationale for keeping both ("the Docker client drops HTTP headers in some
  configurations") was not reproduced — the header survives a client that does
  not send it by leaving the CN path intact.
- The project attribution checks, in the corrected forms the policy implements:
  container creation is attributed by the `com.docker.compose.project` label
  (the original did the same — a label-less create carrying the project path in
  `BindMounts`, `HostConfig.Binds`, or `HostConfig.Mounts` was denied then, by
  probe, and is denied now); network and volume creation is attributed by the
  request body's name (`P-3` or `P-3_<suffix>`); and path-named network/volume
  operations are attributed by the project name as a whole path segment or by
  the project directory appearing in a bind mount. The original checked only the
  label and the mount paths, and matched the path by substring, which denied
  `docker compose up` on a project whose network or volume did not exist yet.
- The lifecycle action allowlist: exactly `{start, stop, restart, kill, pause,
  unpause, wait, update}`.
- Exec and attach are refused. **Corrected 2026-09-17**: this entry used to say
  they were "structurally excluded", which was an assumption, not a
  measurement, and it was wrong in one direction — the daemon forwards a JSON
  body to the plugin for every endpoint that has one, and the create rule then
  matched the path by *prefix*, so a `POST` to `/containers/<id>/attach` or
  `/exec` carrying a create-shaped body was treated as a create (probe rows
  R15.04, R15.05: allowed before, denied now). The refusal is structural now
  because the create grant matches `/containers/create` exactly and no
  carve-out can be reached from another endpoint (R-17).
- ~~The BuildKit container name prefix pattern: `/buildx_buildkit_`.~~
  **Superseded 2026-09-17** (R-17): the sandbox can no longer create a BuildKit
  container at all, so the pattern — and the `BUILDKIT_PREFIX` parameter — has
  nothing to match. The token is still listed in the Parameters table and still
  grepped for by the leftover-token check, so deploying a copy of the old
  template is caught rather than silently missing a substitution.
- The `com.docker.compose.project` label check must match the exact project name.

*Open to reinterpretation:*
- The certificate validity duration (default 3650 days, but shorter is safer).
- The specific OPA plugin image tag — **decided 2026-09-16**: `v0.10` or `v0.9`,
  both of which run the policy this package ships; `v0.8` (OPA v0.30) does not
  (P-10 keeps the tag as a parameter, with the engine constraint stated).
- The optional `P-9` HTTP header name.
- The systemd drop-in file name and the exact `ExecStart=...` argument format.

## Requirements

- **R-1**: The host Docker daemon MUST accept TLS-authenticated TCP connections
  on a configurable port (default 2376).
- **R-2**: The daemon MUST reject TCP connections without a valid client
  certificate signed by the configured CA.
- **R-3**: Every Docker API call from a sandbox-authenticated client MUST be
  authorized by the OPA Rego policy before it reaches the daemon.
- **R-4**: The OPA policy MUST grant sandbox clients read access to all Docker
  resources (GET, HEAD).
- **R-5**: The OPA policy MUST restrict the sandbox's *creation* of Docker
  resources to a single named Docker Compose project: a container create request
  is allowed when it carries the project's `com.docker.compose.project` label,
  and is denied otherwise. A create request that only mounts a path under the
  project's directory is **not** sufficient — attribution at the create call is
  by label (verified against the original policy: a label-less create with the
  project path in `BindMounts`, `HostConfig.Binds`, or `HostConfig.Mounts` was
  denied there too, and stays denied). The project-directory path check applies
  to network and volume operations (R-12).
  **Revision 2026-09-16** (the original text read "MUST restrict sandbox
  container lifecycle operations to a single named Docker Compose project"):
  the authorization request for an operation on an existing container carries a
  request body of `null` and names its target only by id, so no policy at this
  interface can attribute it to a project. Lifecycle *actions* are therefore
  constrained by the allowlist in R-8 and may name any container id; project
  scoping applies to creation. See Limitations.
- **R-6**: The OPA policy MUST deny sandbox `exec` and `attach` operations
  (no shell access to any container).
- **R-7**: The OPA policy MUST allow image builds and pulls from the sandbox.
  **Revision 2026-09-17**: "a build" also covers `POST /session`, the
  endpoint the Docker CLI's BuildKit session uses — the daemon's built-in
  builder asks the client for build inputs over it, so a build against a
  BuildKit-enabled daemon (the default) fails without it. The policy grants
  `/session` for the same reason it grants `/build`: the sandbox runs the build
  and the session serves data the sandbox already holds.
  `inferred:` on a host without BuildKit, `POST /session` may not be issued at
  all; the grant was **not** measured against a live BuildKit daemon here (no
  such host was available to this pass), it is the documented client/daemon
  protocol. The probe row asserts the policy's decision, not the daemon's
  behaviour.
- **R-8**: The OPA policy MUST allow a closed set of container lifecycle actions:
  start, stop, restart, kill, pause, unpause, wait, update.
- **R-9**: The sandbox container MUST NOT require Docker configuration changes
  when the OPA policy is updated — policy reload is a host-side operation.
  "Reload" is precisely stated: the plugin re-reads the policy **file on every
  request** (`os.ReadFile(p.policyFile)` inside `evaluatePolicyFile`), so a
  policy change is a file replacement and nothing else — no plugin bounce
  (disabling a plugin the daemon references makes dockerd **exit**; measured,
  Q-4), no daemon restart, and no sandbox change. The replacement must be
  atomic, because a *missing* policy file is the plugin's one fail-open path.
  See the policy-reload module.
- **R-10**: The host's unix socket (`/var/run/docker.sock`) MUST remain
  unrestricted for local host users.
- **R-11**: The OPA policy MUST allow testcontainers-go containers — those
  carrying the P-12 label key set to its value (`org.testcontainers: true`,
  the common form) — to be created from the sandbox.
- **R-12**: The OPA policy MUST allow network and volume operations scoped to
  the authorized project: creating a network or volume whose name is the project
  name or begins with `<project>_`, and connecting or disconnecting a container
  on a path-named network of the project. A network or volume named otherwise
  MUST be denied.
  **Revision 2026-09-16** (the original text read "…allow network and volume
  operations scoped to the authorized project", without saying how a create
  request is attributed): the request body's `Name` is what identifies a network
  or volume create, and the original policy did not read it — it matched the
  project only against path segments, so `docker compose up` on a project whose
  network and volume did not exist yet was denied. The policy this package ships
  evaluates the body name; the deny-probe table in
  `skeleton/agent.rego.schema` covers both directions.
  **Revision 2026-09-17**: path-named operations are matched as a whole path
  segment (the plugin's `PathArr`) rather than anywhere in the path string, so
  a query string or a longer name cannot satisfy it.
- **R-13**: The policy deployed to the host MUST be the *substituted* policy:
  every placeholder token from the Parameters table replaced, and the deployed
  file checked for leftover tokens. A deployed file that still contains tokens
  MUST be treated as a failed deployment, not a cosmetic defect: the sandbox is
  then classified as a host user and every request is allowed.
- **R-14**: A deployment of this capability MUST remove the sandbox container's
  Docker socket mount. A container holding `/var/run/docker.sock` — read-only or
  not — authenticates as a host user, so the policy never sees its requests and
  is decorative for that container. The removal MUST be verified by inspecting
  the container's mounts.
- **R-15**: The OPA policy MUST refuse a container-create request that would
  give the container access to the host, **including a request that carries the
  project's own label or a testcontainers label**. Refused: a privileged
  container; added capabilities (`CapAdd`); host devices (`Devices`); a relaxed
  security profile (`SecurityOpt`); another container's volumes (`VolumesFrom`);
  a host or container-joined namespace (`PidMode`, `IpcMode`, `NetworkMode`,
  `CgroupnsMode` naming `host` or `container:<id>`); an explicit `UsernsMode`;
  and any mount whose source is neither a volume name nor a path inside `P-15`
  or inside one of the roots `P-16` names.
  The same gate MUST apply to every create-equivalent path the policy grants —
  the compose-label create, the testcontainers create, and volume creation
  (R-16) — so no grant can be used to reach the host. Host port publishing is
  deliberately outside this requirement; see Limitations.
  **Safer direction**: a create that a deployment would have accepted is
  refused when it asks for one of these fields, even where the field is exotic
  rather than dangerous (a `DriverOpts`-bearing local volume, a `service:`
  network mode, a bind by an id-named resource).
- **R-16**: The OPA policy MUST refuse a volume-create request that turns the
  volume into a host mount. A project-named volume with the `local` driver (or
  no driver) and no `DriverOpts` MUST be allowed; a `DriverOpts` object with any
  entry, or a driver other than `local`, MUST be denied — `DriverOpts: {type:
  none, o: bind, device: /}` is the host's root filesystem wearing a project
  name, and R-15 cannot see it at container-create time.
- **R-17**: The policy MUST grant by exact path, never by path prefix or
  substring, and MUST NOT contain a carve-out that makes a create grant
  reachable from another endpoint. Concretely: `POST /build` (not
  `/build/prune`), `POST /images/create`, and `POST /containers/create` are the
  granted paths; `/containers/<id>/exec` and `/containers/<id>/attach` MUST be
  denied whatever body they carry (R-6); and the BuildKit name-prefix carve-out
  is removed (it was reachable from the attach and exec endpoints, and its
  grant is no longer needed — see Decisions). A BuildKit *build* is unaffected:
  it runs through `POST /build` (R-7).
  **Revision 2026-09-17** (this requirement is new; it supersedes P-11).
- **R-18**: The OPA policy MUST scope network and volume *deletion* the way
  creation is scoped: a delete whose path names the project (`P-3`, or
  `P-3_<suffix>` as a whole path segment) MUST be allowed, and a delete of any
  other network or volume — a foreign name, or an opaque id — MUST be denied.
  Container deletion stays unscoped (R-5's revision; see Limitations).
- **R-19**: The OPA policy MUST match request paths independently of the API
  version prefix, and MUST NOT depend on a field value the plugin does not
  send. `PathPlain` is the raw request path **including** `/v<major>.<minor>`
  (`"PathPlain": u.Path` in the plugin's `main.go`; nothing strips it), so the
  policy MUST either derive a version-free path from it or match in a way that
  tolerates the prefix. The derivation MUST leave a request without a prefix
  unchanged (a client may omit the version), strip at most one prefix, leave
  `/_ping` and any other unversioned path alone, and yield no match for a path
  carrying a `..` segment — the daemon cleans the path before routing while the
  plugin authorizes the raw one. The documented input shape, and every probe
  row, MUST use the values the plugin actually sends; a version-less probe
  input proves nothing about a live daemon.

## Design Principles Binding the Implementation

1. **Vendor-agnostic** — implement with plain, portable components; no
   dependency on any specific agent or harness.
2. **Portable** — no absolute paths or machine-specific values in the
   implementation; use the Parameters below.
3. **Self-contained** — the implementation needs nothing outside this package
   and the declared Dependencies.
4. **Predictable, intuitive, ergonomic** — the installed capability behaves
   exactly as this document describes; no surprise behaviours.
5. **Idempotent and deterministic** — every phase is safe to re-run; checks
   give the same verdict every time.
6. **Parameterized and modular** — all tunables flow from the Parameters
   table; concerns are separated per the Modules section.
7. **Dependencies called out** — implement the declared failure behaviour for
   every Dependency.
8. **Applicable context respected** — discover what Must discover locally
   says; do not silently assume beyond May assume.
9. **Configuration flexibility** — behaviour differences come from
   configuration, never source edits.
10. **Pluggable** — implement the attach/remove seams defined in Modules and
    Removal.

## Dependencies

| Id   | What                     | Why needed                              | Discovery                                                   | Failure behaviour                                        |
|------|--------------------------|-----------------------------------------|-------------------------------------------------------------|-----------------------------------------------------------|
| D-1  | Docker Engine (dockerd)  | The daemon being secured                 | `docker version --format '{{.Server.Version}}'` succeeds      | Hard fail before Phase 1                                  |
| D-2  | OpenSSL                  | Certificate generation                   | `openssl version` exits 0 (any 1.1.1+ or 3.x)                 | Hard fail before Phase 2                                  |
| D-3  | OPA Docker authorization plugin (`opa-docker-authz`) | Managed Docker plugin that evaluates the Rego policy | `docker plugin ls` shows it enabled, and the daemon can pull its image | Hard fail in Phase 3 if install fails; **note** a plugin installed without its policy argument answers "allow" to every request — the install step and its acceptance test cover that |
| D-4  | Rego policy engine       | Built into the plugin image              | Part of D-3 — the engine version follows the image tag (see P-10) | A policy using syntax the engine rejects does not compile, and the daemon then fails closed |
| D-5  | systemd                  | Drop-in for TCP listener                 | `systemctl --version` exits 0                               | Phase 5 must adapt to alternative init system             |
| D-6  | python3                  | Merging the live daemon configuration file (JSON handling) | `python3 --version` exits 0               | Phase 4 falls back to manual file edit (instructions given) |
| D-7  | TCP reachability         | Sandbox must reach DOCKER_HOST:2376      | `ss -tlnp \| grep 2376` from host; `curl` from sandbox      | Hard fail in Phase 8 verification                        |
| D-8  | Root or sudo             | Most steps require root                  | `whoami` shows root, or `sudo -n true` exits 0              | Hard fail — most phases fail without root; an unprivileged user cannot complete them |
| D-9  | The sandbox container's definition (compose file or run command) | The socket mount must be removed for the policy to apply to it | `docker inspect <container> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'` | The policy is bypassed for that container (R-14); the deployment is incomplete, not failing |

## Parameters

| Id   | Name                    | Type   | Default                          | Discovery                                                                 | Effect                                                              |
|------|-------------------------|--------|----------------------------------|---------------------------------------------------------------------------|---------------------------------------------------------------------|
| P-1  | DOCKER_HOST_IP          | string | (discovered)                     | `tailscale ip -4` if available else `ip -4 addr show scope global \| grep -oP 'inet \K[\d.]+' \| head -1` | IP address the sandbox uses to reach Docker daemon                  |
| P-2  | DOCKER_DAEMON_PORT      | int    | 2376                             | Port must be free: `ss -tlnp '(sport = :2376)'`                           | TCP port for TLS Docker listener                                    |
| P-3  | PROJECT_NAME            | string | backend-services                 | The compose project the sandbox may manage — from a running container of that project: `docker inspect <c> --format '{{index .Config.Labels "com.docker.compose.project"}}'` | Scopes container, network, and volume *creation*; also the whole-segment match for path-named network/volume calls |
| P-4  | SANDBOX_USERNAME        | string | sandbox-agent                    | The CN in the client TLS cert — identifies sandbox in OPA policy          | OPA identity detection via `input.User`                             |
| P-5  | CA_VALIDITY_DAYS        | int    | 3650                             | N/A — a policy decision                                                   | Lifetime of the self-signed CA and all signed certs                 |
| P-6  | CA_DIR                  | path   | /etc/docker                      | Where `ca.key`, `ca.pem`, and the signed certs are kept; check the daemon's existing `tlscacert`/`tlscert`/`tlskey` values in the live configuration file (P-13) if TLS is already configured | Filesystem path holding the CA and certificates. The daemon reads its `tls*` paths from here, and this directory is mounted into the plugin container at `/opa` — which is why P-7 must live under it |
| P-7  | POLICY_DIR              | path   | /etc/docker/authz                | Must be a subdirectory of P-6                                             | Where the deployed `agent.rego` lives; the plugin's only view of the host filesystem |
| P-8  | SANDBOX_CONFIG_DIR      | path   | (discovered)                     | The host directory that is bind-mounted into the sandbox as its Docker config home; discovery: the mount source in the sandbox's compose definition | Client certs, config.json, and env file written here                |
| P-9  | AUTH_HEADER             | string | X-Sandbox-Agent                  | N/A — a policy decision                                                   | HTTP header *name* used as a secondary identity signal; the policy requires its value to be exactly `true` |
| P-10 | OPA_PLUGIN_IMAGE        | string | ghcr.io/open-policy-agent/opa-docker-authz:v0.10 | The image tag must carry an OPA engine that runs Rego v1: `v0.10` embeds **OPA v1.3.0** and `openpolicyagent/opa-docker-authz-v2:0.9` embeds **OPA v0.60.0** (measured from each release's own `go.mod`, and this package's policy was evaluated under both); `v0.8` (OPA v0.30) rejects `import rego.v1` | Which plugin image is installed; it decides the policy language version (see `skeleton/agent.rego.schema`) |
| P-11 | ~~BUILDKIT_PREFIX~~ | string | ~~/buildx_buildkit_~~ | **Superseded 2026-09-17 by R-17** — the BuildKit carve-out is removed, so nothing reads this token | Nothing. The row is kept because the leftover-token check still greps for it, so deploying a copy of the pre-R-17 template is caught |
| P-12 | TESTCONTAINERS_LABEL    | string | org.testcontainers               | N/A — a known testcontainers-go label key, whose value is `true`           | OPA uses this to identify testcontainers containers                 |
| P-13 | DAEMON_CONFIG_FILE      | path   | /etc/docker/daemon.json          | The daemon's own command line: `ps -o args= -C dockerd` carries `--config-file`, which is the one answer that cannot be wrong (`systemctl show <unit> --property=ExecStart` carries the same argument). A snap-installed daemon names `/var/snap/docker/<revision>/config/daemon.json` — a revision directory that a snap refresh replaces — with `/var/snap/docker/current/config/daemon.json` as its stable alias | The file the daemon actually reads. Writing a different file has no effect and produces no error (see the daemon-config module) |
| P-14 | OPA_PLUGIN_NAME         | string | opa-docker-authz                 | The name shown by `docker plugin ls` after install (the `--alias` value)   | The `authorization-plugins` entry, the reload script's target, and the name in denial messages |
| P-15 | PROJECT_DIR             | path   | (discovered)                     | The host directory of the compose project — `docker inspect <c> --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'` for a container of that project | The policy's host-path boundary (R-15): a mount source must be under this directory (or be a volume name) for a create to be allowed. Attribution is unchanged — by label for container creates, by name or path segment for network and volume calls — and the directory is no longer consulted for attribution at all |
| P-16 | EXTRA_BIND_ROOTS        | list   | (empty)                          | The bind sources already in use on this host: `docker ps -q \| xargs docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' \| sort -u`, then keep the roots this deployment accepts — discovery is a decision, not a lookup | Further roots whose bind sources are accepted (R-15), as comma-separated absolute directories. Each root is a prefix grant and is as narrow as it is written: a directory accepts its whole subtree, and a single file may be named exactly, without granting the directory holding it. Empty — the default — accepts nothing beyond P-15. A `..` segment is refused under every root |

## Modules

- **OPA Policy** (`modules/opa-policy.md`) — the Rego authorization policy file
  that defines sandbox vs host identity, read-only grants, project-scoped
  creation and deletion, the host-access gate on every create (R-15, R-16), the
  exact-path rule (R-17), lifecycle allowlists, and the testcontainers
  carve-out, with its engine-version constraints and its limitations.
- **Docker Daemon Config** (`modules/daemon-config.md`) — the live daemon
  configuration file's TLS and plugin entries (including how to find which file
  the daemon actually reads), plus the systemd drop-in for the TCP listener and
  the reload/restart split.
- **Sandbox Provisioning** (`modules/sandbox-provisioning.md`) — client
  certificate deployment, Docker environment file, and config.json for the
  sandbox container's bind-mounted config directory, plus the socket-mount
  precondition.
- **Policy Reload** (`modules/policy-reload.md`) — host-side procedure to apply
  a Rego policy change: an atomic file replacement (the plugin re-reads the
  policy per request), with the pre-flight checks that keep a bad policy from
  being deployed, and why a plugin bounce is fatal rather than cheap.

## Interfaces and Contracts

### Docker API (external interface)

The capability attaches to Docker's existing authorization plugin interface.
Docker calls the plugin synchronously for every API request, passing the request
context as JSON, and the plugin answers with an authorization decision. Three
properties of that interface shape everything else here:

- The daemon **fails closed**: if the plugin is unreachable or returns an error,
  the request is denied with
  `authorization denied by plugin <name>: <message>` — for every client,
  including host users on the unix socket.
- The plugin **fails open when it has no policy**: a plugin installed without a
  policy or config argument allows every request. The install must pass the
  argument, and the deployment must verify it.
- Authorization happens **only on API requests**. Nothing in this interface sees
  a client that never reaches the daemon — see the contract boundary below.

See [Docker's authorization plugin documentation](https://docs.docker.com/engine/extend/plugins_authorization/)
for the `AuthZPlugin.AuthZReq` / `AuthZPlugin.AuthZRes` message schema.

### Rego input schema (contract consumed by the policy)

The plugin passes the Docker API request to the Rego evaluation in this shape.
The values are the plugin's own, quoted from `main.go`'s `makeInput` — and
the two path fields are easy to misread: `PathPlain` keeps the API version
prefix, and `PathArr` is split from that same versioned path:

```go
input := map[string]interface{}{
        "Headers":    r.RequestHeaders,
        "Path":       r.RequestURI,               // raw URI: version prefix + query
        "PathPlain":  u.Path,                     // raw path: version prefix, no query
        "PathArr":    strings.Split(u.Path, "/"),
        "Query":      u.Query(),
        ...
}
```

```json
{
  "User": "sandbox-agent",
  "AuthMethod": "TLS",
  "Method": "POST",
  "Path": "/v1.47/containers/create?name=backend-services-web-1",
  "PathPlain": "/v1.47/containers/create",
  "PathArr": ["", "v1.47", "containers", "create"],
  "Query": { "name": ["backend-services-web-1"] },
  "Headers": { "X-Sandbox-Agent": "true" },
  "Body": {
    "Labels": { "com.docker.compose.project": "backend-services" },
    "HostConfig": {
      "Binds": ["/srv/compose/backend-services/src:/app/src"],
      "Mounts": [{ "Type": "volume", "Source": "backend-services_data", "Target": "/data" }]
    }
  },
  "BindMounts": [
    { "Source": "/srv/compose/backend-services/src", "Resolved": "/srv/compose/backend-services/src", "ReadOnly": false }
  ]
}
```

**`PathPlain` carries the API version prefix.** The example above shows it
(`/v1.47/containers/create`), and a real plugin sends exactly that: nothing in
`main.go` strips the prefix, and `-skip-ping` only bypasses `HEAD /_ping`. A
policy that matches the raw field by equality therefore decides nothing on a
live daemon, and it fails **closed**: the grants disappear while every denial
holds, so the sandbox cannot create, build, pull or delete anything for its own
project — a broken policy that looks like a working one.

The policy derives the version-free path once (R-19) and every rule matches
that:

```rego
path := p if {
        p := regex.replace(object.get(input, "PathPlain", ""), "^/v[0-9]+(\\.[0-9]+)?", "")
        not traversal(p)
}

path_segments := split(path, "/")
```

The strip is anchored and single, so: `/v1.56/containers/create` →
`/containers/create`; `/containers/create` (a client that sends no version) →
unchanged; `/v1/containers/create` → `/containers/create`; `/_ping` →
unchanged; `/v1.56/v1.56/containers/create` → `/v1.56/containers/create`, which
is no grant. A path with a `..` segment yields no `path` at all, so no rule can
match it.

A create request carries no container name in its body: Docker takes it from the
`name` query parameter (which lands in `input.Query`), the name of a network or
volume create from `Body.Name`. The example above is the compose-labelled
create, the one case where a container create is granted.

Fields used by the policy:
- `input.User` — the TLS client certificate's subject common name; empty for
  unix-socket clients and for TCP clients with no certificate
- `input.Method` — HTTP method (`GET`, `HEAD`, `POST`, `DELETE`)
- `input.PathPlain` — the raw request path: **with** the API version prefix,
  without the query string (`u.Path`). Read only to derive `path`; no rule
  matches the raw field (R-19)
- `input.PathArr` — that path split on `/` (`["", "v1.47", "containers",
  "create"]`). Not read by the policy: the derived `path_segments` is used for
  whole-segment matching, so the version element cannot reach a match
- `input.Query` — the parsed query string, as a map of arrays (`{"name":
  ["backend-services-web-1"]}`). Where a container create's name arrives; no
  grant depends on it
- `input.Headers` — request headers; the `P-9` header is the secondary identity
  signal, and header values are strings (`map[string]string`), never arrays
- `input.Body` — the decoded request body, or `null` for requests without one
  (every `DELETE`, and most `GET`s)
- `input.Body.Labels` — container labels (compose project; testcontainers)
- `input.Body.Name` — network or volume name (`P-3` and `P-3_<suffix>` are the
  project's own names)
- `input.Body.Driver` / `input.Body.DriverOpts` — a volume create's driver and
  its options; a non-empty `DriverOpts`, or a driver other than `local`, makes
  the volume a host mount and is refused (R-16)
- `input.Body.HostConfig` — the create's host-side configuration, and the whole
  of the R-15 gate: `Privileged`, `CapAdd`, `Devices`, `SecurityOpt`,
  `VolumesFrom`, `PidMode`, `IpcMode`, `NetworkMode`, `CgroupnsMode`,
  `UsernsMode`, `Binds`, `Mounts`
- `input.BindMounts` — one entry per bind mount of a create request, with
  `Source`, `ReadOnly`, and `Resolved` (a plugin addition; `Resolved` is empty
  when the plugin cannot read the host path — see the policy module). Every
  witness of a mount is checked, not the first that answers: `Resolved` where
  the plugin supplies it, `Source`, and the raw `HostConfig.Binds` /
  `HostConfig.Mounts` arrays.

### OPA plugin interface (consumed by the daemon)

The plugin is installed as a managed plugin and enabled; it is then referenced
by name (`P-14`) in the live daemon configuration file's `authorization-plugins`
array. Install and reference:

```
docker plugin install --grant-all-permissions --alias <P-14> <P-10> \
  opa-args="-policy-file /opa/authz/agent.rego"
```

The host's `P-6` directory is mounted into the plugin container at `/opa`, so the
policy path inside the plugin is `/opa/` plus the policy's path relative to
`P-6` — with the defaults, `/etc/docker/authz/agent.rego` is
`/opa/authz/agent.rego`. Both halves of the install are load-bearing: the plugin
must exist *and* be given the policy, or it answers "allow" to everything.

### Contract boundary with the sibling mechanisms

Two sibling capabilities exist in this catalogue, and neither substitutes for
this one at the API level:

- **`restrict-docker-api-access`** filters API traffic through its own policy
  layer. It reaches the daemon over the unix socket, so this policy sees a host
  user and imposes nothing on it: the two compose, they do not replace each
  other. A consumer that needs only a slice of the API is better served by that
  schematic's proxy path than by a certificate here.
- **The socket mount** is the boundary of this capability's authority (R-14):
  a container holding `/var/run/docker.sock` is a host user no matter what
  certificates it carries.

### Environment interface (consumed by the sandbox)

Three environment variables exported in the sandbox:

```
DOCKER_HOST=tcp://<P-1>:<P-2>
DOCKER_TLS_VERIFY=1
DOCKER_CERT_PATH=<container path where P-8 is mounted>
```

The client must have `ca.pem`, `cert.pem`, and `key.pem` at that cert path, plus
a `config.json` carrying the `P-9` header. The host-side files, their
permissions, and the exact `config.json` shape are in
`modules/sandbox-provisioning.md`.

## Implementation Phases

Run all phases from the **host** (not inside the sandbox container). **Every
phase that changes daemon or certificate state requires root** — an unprivileged
user cannot complete them (D-8), and the phases below say which steps are
root-only and which are not.

Phase order is load-bearing in one place: **the plugin must exist and be enabled
before the daemon configuration references it** (Phase 3 before Phase 4), and
before any SIGHUP applies that reference. A reference to a plugin that is absent
or disabled makes the daemon fail closed — an outage for every client, host
users included.

### Phase 1: System checks and discovery
Goal: Verify all dependencies are present and discover the host-specific values
that the later phases substitute. Nothing is changed in this phase.

Steps:
1. Verify Docker is running: `docker version --format '{{.Server.Version}}'`
   succeeds. (`dockerd --version` is not equivalent: with a snap-installed
   daemon there is no `dockerd` on `PATH`.)
2. Verify systemd: `systemctl --version` succeeds.
3. Verify OpenSSL: `openssl version` succeeds.
4. Verify python3: `python3 --version` succeeds.
5. Verify root access: `whoami` shows `root`, or `sudo -n true` exits 0. Without
   it, stop here.
6. Discover the **live daemon configuration file (P-13)** from the daemon's own
   command line: `ps -o args= -C dockerd` carries `--config-file=<file>`, and
   that is the file the daemon reads, whatever the install. A snap-installed
   daemon names a **revision-numbered** directory there
   (`/var/snap/docker/<revision>/config/daemon.json`, replaced on snap refresh),
   whose stable alias is `/var/snap/docker/current/config/daemon.json`; a
   distribution unit means `/etc/docker/daemon.json`. Confirm the recorded file
   exists and parses.
7. Discover the certificate directory (P-6), the sandbox config directory (P-8),
   the project name (P-3), the project directory (P-15), and the extra bind roots
   (P-16), using the discovery commands in the Parameters table. P-16 is a
   decision rather than a lookup: list the bind sources the host's existing
   containers already use, then record the roots this deployment accepts.
8. Discover DOCKER_HOST_IP (P-1) from Tailscale or the LAN address.
9. Verify port P-2 is free: `ss -tlnp '(sport = :P-2)'` — no listener yet. Skip
   if re-running after a failed later phase.

Verify:
```
docker version --format '{{.Server.Version}}' && openssl version && python3 --version && systemctl --version
```
All four commands exit 0, and P-13, P-6, P-8, P-3, P-15, P-16, P-1 are recorded —
these values are substituted into the policy and the client configuration later,
so a value that is guessed here becomes a defect there.

### Phase 2: Create certificate authority and certificates
Goal: Generate a self-signed CA, a server certificate (with SANs for the Docker
host IP), and a client certificate (with CN = P-4).

Root required: yes (writing to P-6).

Steps:
1. Create the certificate directory if missing: `mkdir -p P-6 && chmod 700 P-6`.
2. Generate the CA key and a self-signed certificate (skip if they exist):
   `openssl genrsa -out P-6/ca-key.pem 4096`
   `openssl req -x509 -new -nodes -key P-6/ca-key.pem -sha256 -days P-5 -out P-6/ca.pem -subj "/CN=Docker CA"`
3. Generate the server key and CSR with SANs for `127.0.0.1`, `localhost`, and
   P-1, using `skeleton/openssl-server.conf` (replace its `DOCKER_HOST_IP`
   placeholder first), then sign it with the CA and the same extension section:
   ```
   openssl genrsa -out P-6/server-key.pem 4096
   openssl req -new -key P-6/server-key.pem -out P-6/server.csr -subj "/CN=<P-1>" -config skeleton/openssl-server.conf
   openssl x509 -req -in P-6/server.csr -CA P-6/ca.pem -CAkey P-6/ca-key.pem -CAcreateserial \
     -out P-6/server-cert.pem -days P-5 -sha256 -extfile skeleton/openssl-server.conf -extensions req_ext
   ```
   The `-extfile`/`-extensions` pair is what actually writes the SANs and the
   `serverAuth` extended key usage: extensions listed in the CSR config are not
   carried into the signed certificate on their own.
4. Generate the client key and CSR with subject `/CN=P-4`, then sign it with the
   `clientAuth` extended key usage the daemon requires. `openssl x509 -req` has
   no `-addext` option (verified on OpenSSL 3.0.13), so the extension goes in a
   one-line file passed with `-extfile`:
   ```
   openssl genrsa -out P-6/sandbox-key.pem 4096
   openssl req -new -key P-6/sandbox-key.pem -out P-6/sandbox.csr -subj "/CN=P-4"
   printf 'extendedKeyUsage = clientAuth\n' > /tmp/openssl-client-ext.cnf
   openssl x509 -req -in P-6/sandbox.csr -CA P-6/ca.pem -CAkey P-6/ca-key.pem -CAcreateserial \
     -out P-6/sandbox-cert.pem -days P-5 -sha256 -extfile /tmp/openssl-client-ext.cnf
   ```
   (The extension is not carried from the CSR: it must be passed at signing
   time, exactly as the server certificate's SANs and EKU are.)
5. Set permissions: `chmod 600 P-6/ca-key.pem P-6/server-key.pem
   P-6/sandbox-key.pem`, `chmod 644 P-6/*.pem` for the certificates.

Verify:
```
openssl x509 -in P-6/ca.pem -noout -subject | grep -qE "CN ?= ?Docker CA"
openssl x509 -in P-6/server-cert.pem -noout -ext subjectAltName | grep -q "IP"
openssl x509 -in P-6/server-cert.pem -noout -ext extendedKeyUsage | grep -q "TLS Web Server Authentication"
openssl x509 -in P-6/sandbox-cert.pem -noout -ext extendedKeyUsage | grep -q "TLS Web Client Authentication"
openssl x509 -in P-6/sandbox-cert.pem -noout -subject | grep -qE "CN ?= ?P-4"
```
The `CN ?= ?` form matters: OpenSSL 3 prints `subject=CN = Docker CA` with spaces
around the `=`, so a `CN=Docker CA` grep matches nothing and the check fails on a
certificate that is correct. (The TLS connection test belongs to Phase 8, once a
listener exists.)

### Phase 3: Install the OPA authorization plugin
Goal: Install and enable the managed plugin **with its policy argument**, before
anything references it.

Root required: yes (`docker plugin install` needs the daemon socket and root).

Steps:
1. Check whether the plugin is already installed:
   `docker plugin ls --format '{{.Name}} {{.Enabled}}'`.
2. If it is absent, install it **with `opa-args`** — the plugin's only two
   arguments are a policy file or a config file, and a plugin installed without
   one answers "allow" to every request:
   ```
   docker plugin install --grant-all-permissions --alias P-14 P-10 \
     opa-args="-policy-file /opa/authz/agent.rego"
   ```
   `--grant-all-permissions` is required for a non-interactive install; without
   it the CLI asks for confirmation and the install stalls.
   The `/opa/authz/agent.rego` path is inside the plugin container: the host's P-6
   directory is mounted at `/opa`, so it is `P-7` relative to `P-6`. If P-7 is
   changed, this argument changes with it — and so does the deploy path in
   Phase 6.
3. If it is installed but disabled, enable it: `docker plugin enable P-14`.
4. If it is installed with the wrong or missing arguments, remove and reinstall
   it with the correct ones: `docker plugin disable P-14`,
   `docker plugin rm P-14`, then step 2.

Verify:
```
docker plugin ls --format '{{.Name}} enabled={{.Enabled}}' | grep -q "^P-14 enabled=true$"
docker plugin inspect P-14 | grep -q 'policy-file'
```
The second command is the one that matters: it shows the plugin was given a
policy. A plugin installed without that argument passes the first check and
allows everything.

### Phase 4: Configure the live daemon configuration file
Goal: Point the daemon at the certificate material, and register the plugin the
previous phase installed.

Root required: yes.

Steps:
1. Read the **live** configuration file at P-13 (discovered in Phase 1 — not
   necessarily `/etc/docker/daemon.json`). Back it up beside itself:
   `cp -p P-13 P-13.bak`.
2. Merge or create, preserving every existing key: set `tlsverify: true`,
   `tlscacert: P-6/ca.pem`, `tlscert: P-6/server-cert.pem`,
   `tlskey: P-6/server-key.pem`.
3. Append `"P-14"` to the `authorization-plugins` array (deduplicate; never
   replace an existing entry).
4. Remove any `hosts` key — it conflicts with the systemd `-H` flag added in
   Phase 5.
5. Write the file with strict JSON (2-space indent), and set `chmod 644`.
6. Validate before applying: `python3 -m json.tool P-13 > /dev/null`. Where a
   `dockerd` binary is on `PATH`, `dockerd --validate --config-file P-13` is the
   stronger check (it validates key names as well as JSON).
7. Apply the plugin entry **without a restart** — `authorization-plugin` is in
   dockerd's SIGHUP-reloadable set:
   `kill -HUP $(pidof dockerd)`
   The TLS and `hosts` keys are not reloadable; they take effect at the restart
   in Phase 5.

Verify:
```
python3 -c "import json; c=json.load(open('P-13')); assert c.get('tlsverify'), 'tlsverify missing'; assert 'P-14' in c.get('authorization-plugins', []), 'plugin missing'; assert 'hosts' not in c, 'hosts key must be removed'"
docker ps > /dev/null && echo "daemon answering after SIGHUP"
```
The `docker ps` check proves the daemon reloaded the configuration and that the
plugin is reachable and allowing host users; it does not by itself prove the
entry is in the plugin chain — the discriminating check is the sandbox client's
denial in Phase 8. If `docker ps` fails here, the plugin is not answering and the
daemon is failing closed: check `docker plugin ls` and the daemon's log
(`journalctl -u <unit> -n 50`) before going further.

### Phase 5: Configure the systemd drop-in for the TCP listener
Goal: Add a TLS TCP listener alongside the existing systemd file-descriptor
socket. **This is the disruptive phase**: it restarts the daemon.

Root required: yes.

Steps:
1. Read the daemon's live unit and command line:
   `systemctl show docker --property=Id,FragmentPath,ExecStart`. Everything below
   uses that unit name — a snap-installed daemon's unit is
   `snap.docker.dockerd.service`, not `docker.service`.
2. Create the drop-in directory for that unit, then write a drop-in that adds the
   listener to the **existing** command line (clear it, then restate it):
   ```
   [Service]
   ExecStart=
   ExecStart=<the exact argv from step 1> -H tcp://0.0.0.0:P-2
   ```
   Do not hand-write the daemon's argv from memory: for a snap unit the flags
   (`--config-file`, `--containerd`, and so on) belong to snapd and differ from a
   distribution unit's.
3. `systemctl daemon-reload`, then restart: `systemctl restart <unit>`.
4. Wait for the daemon: `docker info` succeeds.

Disruption: the restart stops every running container unless the daemon has
live-restore enabled. Check it (Phase 1, step 6) and say so in the change record
before restarting; if containers must not stop, schedule the restart.

Verify:
```
systemctl show <unit> --property=ExecStart | grep -q "tcp://0.0.0.0:P-2"
docker info >/dev/null 2>&1
ss -tlnp | grep -q ":P-2"
```
Re-check the drop-in after a snap refresh: snapd may rewrite the unit, and
`systemctl show <unit> --property=ExecStart` shows that in one command. The
`authorization-plugins` entry written in Phase 4 lives in the configuration file
and survives the restart as long as the file is the one the daemon reads — which
is why Phase 4 verified it with a live request rather than by reading it back.

### Phase 6: Deploy the OPA Rego policy
Goal: Substitute the placeholders in the policy template, check the result, and
deploy it where the plugin reads it. **A deployed file that still contains a
placeholder is not a partial deployment — it is a full-access policy**, because
the sandbox then stops being recognised as a sandbox client at all.

Root required: yes (writing under P-7).

Steps:
1. Substitute the seven tokens from `skeleton/agent.rego` with the Phase 1
   values. Any mechanism is fine (editor, `sed`, a deployment script); the check
   in step 2 is what makes it safe:
   ```
   sed -e 's#SANDBOX_USERNAME#P-4 value#g' \
       -e 's#AUTH_HEADER_NAME#P-9 value#g' \
       -e 's#PROJECT_NAME#P-3 value#g' \
       -e 's#PROJECT_DIR_PATH#P-15 value#g' \
       -e 's#TESTCONTAINERS_LABEL_KEY#P-12 key#g' \
       -e 's#TESTCONTAINERS_LABEL_VALUE#P-12 value#g' \
       -e 's#EXTRA_BIND_ROOTS#P-16 value#g' \
       skeleton/agent.rego > /tmp/agent.rego
   ```
   `P-16` goes in as one value whether it names one root or several
   (`/srv/media,/srv/downloads`) and is empty for a deployment whose project
   directory is the only accepted boundary. Empty is not the same as
   unsubstituted: an empty value yields no extra root, while an unsubstituted
   token yields a root that matches nothing — both are denied, and step 2 is
   what makes the difference visible.
   `#` is the delimiter, not `/`: several of these values are paths (`P-15` is
   `/srv/compose/backend-services` with the defaults, and `P-16` is a list of
   them), and a `/` delimiter ends the `s` command at the first slash in the
   value. If a value itself contains `#`, pick another character that appears in
   none of them. The
   `g` flag matters for the same reason it always does — a token appears more
   than once in the file — and the leftover check in step 2 is the guarantee, not
   the substitution command.
   (`BUILDKIT_PREFIX` is **not** in this list since 2026-09-17: R-17 removed the
   BuildKit carve-out, and the token is gone from the template. The leftover
   check below still greps for it, so substituting a copy of the old template
   with this command fails the check rather than deploying a stale policy.)
2. Check the substituted file for leftover tokens **in code lines** (comments
   name the tokens on purpose):
   ```
   awk '!/^[[:space:]]*#/ && /SANDBOX_USERNAME|AUTH_HEADER_NAME|PROJECT_NAME|PROJECT_DIR_PATH|EXTRA_BIND_ROOTS|BUILDKIT_PREFIX|TESTCONTAINERS_LABEL/ {print FILENAME":"FNR": "$0}' /tmp/agent.rego
   ```
   Output must be empty. If it is not, stop and fix the substitution.
3. Validate the policy against an engine **no newer than the plugin's** (P-10):
   `opa check /tmp/agent.rego`, or the engine's own image when no binary is
   installed —
   `docker run --rm -v "$(pwd):/w:ro" -w /w openpolicyagent/opa:1.3.0 check agent.rego`
   (1.3.0 is what `v0.10` embeds; never check with a newer engine than the
   plugin's). The deploy script does this step itself.
4. Deploy it where the plugin's `-policy-file` argument points:
   `scripts/reload-opa-policy.sh /tmp/agent.rego`
   That path is P-7, and it does not have to be guessed — the installed plugin
   reports it, since `docker plugin inspect` shows both the policy argument and
   the mount carrying it (`-policy-file /opa/authz/agent.rego` with
   `/etc/docker -> /opa` means `/etc/docker/authz/agent.rego`). The script finds
   it the same way when `POLICY_DST`/`POLICY_DIR` are unset, and
   `scripts/reload-opa-policy.sh --discover` prints it without changing
   anything.
   There is nothing to bounce: the plugin re-reads the policy **file on every
   request**, so the change is live on the next API call. The script runs the
   same leftover check, parses the policy under the plugin's engine, keeps the
   previous policy at `P-7/agent.rego.previous` for rollback, and installs the
   new file by writing a temporary file and renaming it over the target. Both
   halves are load-bearing:
   - **Never `docker plugin disable` / `rm` / `upgrade` a plugin the running
     daemon references**: dockerd exits with `Error validating authorization
     plugin ... not found` (measured; Q-4). Nothing in a policy update needs it.
   - **Never copy or truncate the live file**: while it is absent the plugin
     **fails open** (`OPA policy file ... does not exist, failing open and
     allowing request`). The rename is what makes the replacement atomic.

Verify:
```
awk '!/^[[:space:]]*#/ && /SANDBOX_USERNAME|AUTH_HEADER_NAME|PROJECT_NAME|PROJECT_DIR_PATH|EXTRA_BIND_ROOTS|BUILDKIT_PREFIX|TESTCONTAINERS_LABEL/ {print}' P-7/agent.rego   # no output
docker plugin ls --format '{{.Name}} enabled={{.Enabled}}' | grep -q "^P-14 enabled=true$"
```
and then the denial test in Phase 8 — a plugin that is enabled but running a
stale policy passes both checks above.

### Phase 7: Provision the sandbox configuration
Goal: Write the client certificates, Docker config, and environment file to the
host directory (P-8) that is bind-mounted into the sandbox container.

Root required: only if P-8 is root-owned; the files must end up readable by the
sandbox's user.

Steps:
1. Ensure P-8 exists and is the directory the sandbox actually mounts.
2. Copy the CA certificate, the client certificate, and the client key:
   `cp P-6/ca.pem P-8/ca.pem`, `cp P-6/sandbox-cert.pem P-8/cert.pem`,
   `cp P-6/sandbox-key.pem P-8/key.pem`.
3. Write `P-8/config.json` with the P-9 header — the value is the string `true`:
   ```json
   {"HttpHeaders": {"P-9": "true"}}
   ```
4. Write `P-8/env`:
   ```
   export DOCKER_HOST=tcp://P-1:P-2
   export DOCKER_TLS_VERIFY=1
   export DOCKER_CERT_PATH=<the path P-8 is mounted at inside the container>
   ```
5. Set permissions: `ca.pem`, `cert.pem`, `env` → 644; `key.pem`,
   `config.json` → 600.

Verify:
```
stat -c '%a %n' P-8/ca.pem P-8/cert.pem P-8/key.pem P-8/config.json P-8/env
python3 -c "import json; json.load(open('P-8/config.json')); print('OK')"
```
and confirm the sandbox container actually mounts P-8 (Phase 9, step 1).

### Phase 8: Verify TLS and OPA enforcement
Goal: Confirm the running setup works end-to-end. Every command below uses the
sandbox's own credentials, so a pass here is evidence about the deployed policy,
not about the files on disk.

Steps:
1. TLS connectivity with the sandbox client certificate:
   `docker --tlsverify -H tcp://P-1:P-2 --tlscacert P-8/ca.pem --tlscert P-8/cert.pem --tlskey P-8/key.pem ps`
2. A read that the policy allows (step 1 covers it), then an operation it denies:
   `... run --rm alpine echo hello` must fail with
   `authorization denied by plugin <P-14>`.
3. An operation it allows for the project, if the project exists:
   `... compose -p P-3 ps`.
4. The host path, unchanged: `docker ps` on the unix socket.

Verify: step 1 exits 0 and lists containers; step 2 exits non-zero with
`authorization denied` in stderr; step 4 still works. If step 2 **succeeds**,
stop: the policy is not in force (leftover placeholder, a plugin installed
without `opa-args`, or a stale policy the plugin never recompiled).

### Phase 9: Remove the socket mount and restart the sandbox
Goal: Make the policy apply to the sandbox container at all, then hand it the new
configuration. A container that keeps its socket mount is a host user (R-14), and
everything deployed above is decoration for it.

Root required: yes for the restart (or the container owner's access).

Steps:
1. Inspect the sandbox container's mounts and remove any Docker socket mount
   from its compose file (or run command):
   `docker inspect <sandbox container> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{.Mode}}{{println}}{{end}}'`
   A `:ro` socket mount is still a full control channel — remove it, do not
   downgrade it.
2. Recreate the container so the mount actually disappears and the new env file
   is sourced: `docker compose -f <sandbox-compose.yml> up -d --force-recreate <service>`
   (a plain `restart` does not change mounts).
3. Verify from inside the container: `docker ps` lists containers (the client is
   talking TLS to P-1:P-2), and `docker run --rm alpine echo hello` is denied.

Verify: the mount inspection shows no `docker.sock` line, and both commands
behave as above.

## Verification and Acceptance

Each test names the requirements it covers. `...` stands for
`--tlsverify -H tcp://P-1:P-2 --tlscacert P-8/ca.pem --tlscert P-8/cert.pem --tlskey P-8/key.pem`.

- **A-1** (covers R-1): the TLS listener accepts a client with a valid
  certificate — `docker ... ps` exits 0 and lists containers.
- **A-2** (covers R-2): the listener refuses a client **without** a certificate —
  `docker -H tcp://P-1:P-2 ps` (no `--tlsverify`, no client cert) fails, and
  `echo | openssl s_client -connect 127.0.0.1:P-2 -CAfile P-6/ca.pem 2>&1`
  reports a TLS failure or a closed connection rather than an API answer. The
  daemon drops unauthenticated TCP clients; the unix socket is untouched.
- **A-3** (covers R-3, R-4): the sandbox client can read — `docker ... ps` exits
  0 (A-1 doubles as this).
- **A-4** (covers R-3, R-6): an operation the policy does not allow is denied by
  the plugin — `docker ... run --rm alpine echo hello` exits non-zero with
  `authorization denied by plugin <P-14>` in stderr. A success here means the
  policy is not in force.
- **A-5** (covers R-10): the host user is unaffected — `docker ps` on the unix
  socket exits 0.
- **A-6** (covers R-7): a build is allowed — `docker ... build -t test .` from a
  directory with a Dockerfile exits 0.
- **A-7** (covers R-8): a lifecycle action from the allowlist is allowed —
  `docker ... stop <container of the project>` exits 0, and
  `docker ... exec <container> ls` is denied (R-6).
- **A-8** (covers R-9, R-19): a policy update is a file deployment — not a
  plugin bounce, not a daemon restart. Change the policy, run
  `scripts/reload-opa-policy.sh`, then re-run A-3 and A-4: the read still
  works, the denial still denies, the daemon's start time is unchanged
  (`systemctl show <unit> --property=ExecMainStartTimestamp`), and
  `docker plugin ls` shows the plugin's enabled state unchanged. Confirm which
  policy is live from the plugin's own decision log: it logs `config_hash`, the
  sha256 of the bytes it read, which must equal `sha256sum P-7/agent.rego` after
  the next API call. Reversing the change is `scripts/reload-opa-policy.sh
  --rollback`, and it must restore the previous decisions without touching the
  plugin or the daemon either.
- **A-9** (covers R-13): the deployed policy has no leftover placeholders — the
  `awk` check from Phase 6, step 2, over `P-7/agent.rego`, prints nothing.
  Run it *before* deploying: a file that fails this check turns A-4 into a
  false pass.
- **A-10** (covers R-3): the plugin was installed with its policy argument —
  `docker plugin inspect <P-14>` contains `policy-file` (or `config-file`), and
  `docker plugin ls` shows it enabled.
- **A-11** (covers R-12, R-18): project-scoped creation and deletion work end to
  end — from the sandbox, `docker ... compose -p P-3 up -d` on a project whose
  network and volume do not exist yet exits 0, while `docker ... volume create
  other_data` is denied, `docker ... volume rm <a volume id>` is denied, and
  `docker ... compose -p P-3 down` exits 0 (it deletes by name, which is what
  R-18 matches). Both directions matter: the original policy denied the first.
- **A-12** (covers R-14): the sandbox container does not mount the Docker socket
  — `docker inspect <sandbox> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{println}}{{end}}'`
  has no `docker.sock` line, and inside the container `docker run --rm alpine
  echo hello` is denied (if the socket were mounted, it would succeed).
- **A-13** (covers R-1, R-3): the plugin entry applies without a restart —
  after writing `authorization-plugins` and `kill -HUP $(pidof dockerd)`, the
  daemon's start timestamp is unchanged and A-4's denial still holds.
- **A-14** (covers R-2, R-5): the certificate identities are what the policy
  expects — `openssl x509 -in P-8/cert.pem -noout -subject` shows `CN=P-4`, its
  `extendedKeyUsage` is client authentication, and the server certificate's SANs
  cover P-1.
- **A-15** (covers R-5, R-6, R-7, R-8, R-11, R-12, R-17, R-19): the policy's
  decision table — the probes in `skeleton/agent.rego.schema`, run with the
  plugin image's own engine (P-10) against the deployed file, produce the
  expected allow/deny for **every** row, including the exact-path rows (a
  smuggled body on `/containers/<id>/attach` and `/exec` must be denied), the
  `POST /session` grant, the testcontainers label, and both directions of the
  project-scoped create checks.
  **The rows must be fed the plugin's real input shape** (`Path`, `PathPlain`
  and `PathArr` carrying the version prefix, `Query` parsed) — a table cannot
  catch a disagreement between its own model of the input and the plugin's
  (`main.go`'s `makeInput`) unless it uses the plugin's values. Run the table
  **twice** where the shape is in question: once with a version prefix and once
  without, and require identical decisions.
  **This test alone is not enough**: with a wrong input shape the whole table
  passes while every create on a live host is denied. The live tests (A-11,
  A-16) are the ones that catch that class; run at least one of them against a
  real daemon before trusting a policy change.
- **A-16** (covers R-15, R-16): the host-access gate holds for a project-labelled
  client — from the sandbox, each of these is denied by the plugin, and the
  denial is not a mistake of syntax but the R-15/R-16 decision:
  ```
  docker ... run --rm --privileged alpine echo hello          # Privileged
  docker ... run --rm --cap-add SYS_ADMIN alpine echo hello   # CapAdd
  docker ... run --rm --pid host alpine echo hello            # host namespace
  docker ... run --rm -v /:/host alpine echo hello            # bind outside P-15
  docker ... run --rm -v /var/run/docker.sock:/s alpine echo hello
  docker ... volume create P-3_evil --opt type=none --opt o=bind --opt device=/
  ```
  and the same host with a user who is not the sandbox still succeeds:
  `docker run --rm --privileged alpine echo hello` on the unix socket exits 0
  (R-10 — the gate applies to the sandbox identity only). The sandbox's own
  legitimate work stays allowed: `docker ... compose -p P-3 up -d` (A-11) and a
  build (A-6) must still exit 0.

## Failure Modes and Rollback

**A second daemon on the same host:** starting a throwaway `dind` container with
`--privileged --network host` takes `docker0` down, and the network of every
container already running with it — a working stack losing its network to a
debugging container. Nothing in this package's policy causes it and nothing in
this package prevents it, so run such a trial on another host, or without
`--network host` and without `--privileged`.

**Phase 1 (discovery):** The two traps this phase exists to catch are a
configuration file the daemon does not read, and a guessed project name or path.
Both surface later as "the policy does nothing" or "the project is denied", so
they are cheaper to catch here. Nothing is changed yet: re-run the discovery.

**Phase 2 (certificate generation):** If OpenSSL fails, check that the command
and its options are supported by the installed version (`-addext` needs 1.1.1 or
newer). The certificate directory can be cleaned and re-run with
`rm -f P-6/*.pem P-6/*.srl`; nothing else has consumed the certificates yet.

**Phase 3 (plugin install):** If the install fails, the daemon could not pull the
image (network, registry authentication, or an architecture mismatch). The plugin
is not yet referenced by the daemon, so a failed install changes nothing — fix
the pull and retry. Do **not** proceed to Phase 4 with the plugin installed but
unconfigured: a plugin without `opa-args` allows every request.

**Phase 4 (daemon configuration):** If the JSON is invalid, the SIGHUP fails and
the daemon keeps running with its previous configuration; a restart would fail to
start. Rollback: `cp -p P-13.bak P-13` and `kill -HUP $(pidof dockerd)`, then a
restart if the TLS keys were already applied. If `docker ps` fails *after* the
SIGHUP, the plugin is not answering and the daemon is failing closed — check
`docker plugin ls`, then disable and fix the plugin; removing the entry and
SIGHUPping restores service.

**Phase 5 (systemd drop-in):** If the daemon fails to start after the drop-in,
read `journalctl -u <unit> -n 50`. The two likely causes are a conflicting
`hosts` key in the configuration file and an argv that does not match the unit's
own (snap units own their flags). Rollback: remove the drop-in,
`systemctl daemon-reload`, `systemctl restart <unit>`. Containers that were
stopped by the restart are started again by their restart policies.

**Phase 6 (policy deploy):** If the plugin fails to enable, the policy did not
compile. Rollback: the previous policy is kept as `P-7/agent.rego.previous` by
the reload script — restore it and re-run the script. A missing `opa` binary is
not a blocker: deploy and use the Phase 8 denial test instead.

**Phase 7 (sandbox provisioning):** Non-critical — fix permissions and copy
manually. The sandbox cannot connect to Docker until the files are correct, and
its failure mode is a connection error, not an open door.

**Phase 8 (verification):** If the denial test passes but project operations are
denied, the likely causes are an incorrect P-3 (the exact compose project name),
an incorrect P-15 (so R-15's mount check refuses a bind that is legitimate —
the project's own files then look like they are outside the project), or an
unsubstituted token. Check A-9 first: a leftover token makes *everything*
allowed, so a correct-looking denial test rules it out.

**Phase 9 (sandbox recreate):** If the sandbox cannot reach the daemon after the
recreate, check `DOCKER_HOST`/`DOCKER_CERT_PATH` inside the container and that
P-8 is mounted where the env file says it is. If the container still lists a
`docker.sock` mount, the policy is bypassed for it (A-12).

## Removal

Clean teardown reverses each phase in the opposite order. The order of steps 1
and 2 matters: **remove the daemon's reference to the plugin before removing the
plugin**, or the daemon fails closed for every client.

1. Remove the systemd drop-in and restart (this also drops the TCP listener):
   ```bash
   rm /etc/systemd/system/<unit>.d/tcp-host.conf
   systemctl daemon-reload
   systemctl restart <unit>
   ```
2. Remove the plugin reference from the live configuration file (P-13) and apply
   it without a restart:
   ```bash
   # remove "P-14" from authorization-plugins; keep any other entries
   kill -HUP $(pidof dockerd)
   ```
   Then uninstall the plugin:
   ```bash
   docker plugin disable P-14
   docker plugin rm P-14
   ```
3. Restore the daemon configuration to its pre-schematic state (remove
   `tlsverify`, `tlscacert`, `tlscert`, `tlskey`, and the plugin entry, or copy
   the backup over it) and restart:
   ```bash
   cp -p P-13.bak P-13
   systemctl restart <unit>
   ```
4. Remove the certificates and the policy:
   ```bash
   rm -f P-6/ca*.pem P-6/server*.pem P-6/sandbox*.pem P-6/*.csr P-6/*.srl
   rm -rf P-7/
   ```
5. Remove the sandbox configuration and restore the sandbox's Docker access path:
   ```bash
   rm -f P-8/ca.pem P-8/cert.pem P-8/key.pem P-8/config.json P-8/env
   ```
   If the sandbox needs Docker access again, this is where its socket mount (or
   the `restrict-docker-api-access` proxy) comes back — a deliberate decision, not
   a leftover.

After removal, confirm:
```bash
docker ps                                     # unix socket — works
docker -H tcp://P-1:P-2 ps                    # no listener — fails
```

## Decisions and Open Questions

Decisions:

- 2026-09-09 — Schematic reverse-engineered from a running implementation on a
  private host (the implementation itself is not part of this catalogue, and the
  host is not named here: the package must be self-contained and portable). The
  setup included: a self-hosted Docker TLS certificate infrastructure, the OPA
  authorization plugin, a Rego policy file, sandbox container provisioning
  files, and a policy reload script. The original host runs Ubuntu with systemd,
  and the sandbox container uses a non-root user.
- 2026-09-16 — Verified and corrected against the plugin's, Docker's, and
  Open Policy Agent's own documentation, and against the OPA engines the two
  installable plugin releases embed. What changed:
  - **The plugin named by the package did not exist.** D-3/P-10 named
    `ghcr.io/open-policy-agent/authorize-docker-requests`, which is not a
    repository; the real managed plugin is `opa-docker-authz`, published as
    `ghcr.io/open-policy-agent/opa-docker-authz:v0.10` and
    `openpolicyagent/opa-docker-authz-v2` on Docker Hub up to `0.9`.
  - **The policy did not load on any plugin the package could install.** The
    shipped Rego used v0 syntax with `import future.keywords.in`, which the
    engine in v0.8 (OPA v0.30) rejects and the engine in v0.9 (OPA v0.60)
    also rejects. The policy now ships in Rego v1 and was verified to load and
    decide identically under OPA v0.60.0 and v1.7.1. (The 2026-09-17 pass added
    v1.3.0 — the engine `v0.10` actually embeds, see the correction below.)
  - **Project-scoped network and volume creation was denied.** The original
    policy matched the project only against path segments, so
    `docker compose up` on a project whose network and volume did not exist yet
    was refused. R-12 now states the body-name rule the corrected policy
    implements (verified by probe: project name allowed, foreign name denied).
  - **R-5 was narrowed.** Lifecycle calls on existing containers cannot be
    attributed to a project at this interface (the request body is `null`), so
    the requirement now covers creation and the limitation is stated explicitly
    rather than promised and unmet.
  - **The daemon configuration path was wrong for snap-installed daemons.**
    The package wrote `P-6/daemon.json`; a snap daemon reads
    `/var/snap/docker/current/config/daemon.json` and ignores `/etc/docker`. The
    new P-13 parameter carries the live path, and the daemon-config module
    requires an observable-effect check rather than a path assumption.
  - **Reload semantics were wrong in one direction.** The package said a policy
    reload was unblocked; in fact a plugin bounce is a *denial* window (the
    daemon fails closed while the plugin is down), and a plugin installed
    without `opa-args` fails *open*. **Corrected 2026-09-17**: the bounce is
    worse than a denial window — with the plugin referenced by a running daemon
    it is fatal to the daemon, and it was never needed in the first place
    (Q-4, below). Both are now stated where they apply, and
    the install step passes the policy argument explicitly.
  - **Two failure-behavior claims were corrected**: the daemon fails closed on a
    plugin error (documented), and the plugin allows everything when it has no
    policy (documented) — the original text implied only the first.
  - **The systemd drop-in is derived, not hand-written**, and the plugin entry
    is applied by SIGHUP (it is in dockerd's reloadable set) so the single
    disruptive restart is the one that adds the listener.
  - **Certificate extensions corrected**: `serverAuth` on the server
    certificate, `clientAuth` on the client certificate, both stated in the
    skeleton and the acceptance tests. The extension must be passed at signing
    time: `openssl x509 -req` has no `-addext` option (run against OpenSSL
    3.0.13), so the client's `clientAuth` extension is written to a one-line
    file and passed with `-extfile`. The Phase 2 verification greps were also
    corrected to tolerate OpenSSL 3's `CN = value` spacing, which made a correct
    certificate fail its own check. Both corrections were made by running the
    phase's commands, not by reading them.
- 2026-09-16 — New requirements R-13 (the deployed policy must be substituted;
  a leftover placeholder is a failed deployment) and R-14 (the sandbox's socket
  mount must be removed, verified), and new parameters P-13 (live daemon
  configuration file), P-14 (installed plugin name), P-15 (project directory).
- 2026-09-16 — Known surface for the deployment decision: the host examined
  during this pass runs a snap-installed Docker, so P-13 is the snap path and
  every daemon-level step is root-only. The restart in Phase 5 is the disruptive
  step, and live-restore decides whether it stops the running containers.
- 2026-09-17 — **The create path was hardened, and the engine claim corrected.**
  Every change below is backed by the deny-probe table in
  `skeleton/agent.rego.schema`, run under the published `openpolicyagent/opa`
  images for 0.60.0, **1.3.0** and 1.7.1 (the plugin's engine is an OPA release;
  1.3.0 is what `v0.10` embeds):
  - **A project-labelled create could ask for anything.** A request carrying the
    project's own `com.docker.compose.project` label was allowed to request
    `Privileged`, `CapAdd`, host devices, host namespaces, `SecurityOpt`, or a
    bind of `/` — the label was treated as sufficient. It is now a gate, not a
    grant (R-15), and the same gate covers the testcontainers create and volume
    creation (R-16).
  - **A create-shaped body on `/containers/<id>/attach` or `/exec` satisfied the
    create rule.** The grant matched the path with `contains(...)`, so a rule
    meant for `POST /containers/create` also matched those endpoints — and
    Docker forwards the JSON body to the plugin for an endpoint whose handler
    ignores it, so the smuggled body decided the request. Whether the daemon
    *forwards* such a body is version-dependent, which is the point: the policy
    must not depend on it. Grants now match by equality (R-17), and the
    BuildKit name-prefix carve-out — the grant that was reachable that way — is
    removed. Cost, accepted: `docker buildx create --driver docker-container`
    from the sandbox no longer works; builds run through `POST /build` and are
    unaffected.
  - **A project-named volume could be the host's root filesystem.**
    `DriverOpts: {type: none, o: bind, device: /}` on a `<P-3>_`-named volume
    was allowed, and a container mounting that volume reached the host while
    R-15 — which reads `HostConfig`, not the volume's definition — saw nothing.
    R-16 refuses any non-empty `DriverOpts` and any driver other than `local`.
  - **Network and volume deletes were unscoped**: any network or volume the
    client could name could be deleted, including the host's. R-18 scopes them
    to the project as a whole path segment. Container deletes stay unscoped —
    their request carries nothing to attribute (Limitations).
  - **`POST /session` is now granted** (R-7 revision): the Docker CLI's BuildKit
    session endpoint, without which a build against a BuildKit-enabled daemon
    fails. **Not measured against a live BuildKit host** — none was available to
    this pass — so the source is the client/daemon protocol and the probe row
    asserts the policy's decision only. A deployment whose daemon is
    BuildKit-disabled can drop the grant without losing anything.
  - **The engine version in P-10 was wrong**: `v0.10` embeds OPA **v1.3.0**, not
    v1.7.1. The error was reading the newest OPA release instead of the plugin's
    own `go.mod` at its tag. Fixed in P-10, the policy header,
    `agent.rego.schema`, and the policy module; the probe table now includes
    v1.3.0 alongside v0.60.0 and v1.7.1.
  - **The deny list was extended past the review's list**, each addition with a
    probe row: `CgroupnsMode: host`, a namespace joined by `container:<id>` (a
    host-networked container's namespace is the host's, one hop away),
    `VolumesFrom`, a mount source carrying a `..` segment, and a `Mounts` entry
    with no `Type`. Consequence accepted and stated: a compose
    `network_mode: service:<name>` is refused.
  - **A Rego evaluation trap the probe table caught**: `not is_string(field)`
    over a *missing* field fails the rule instead of succeeding, so the first
    draft of R-16 refused a volume create that carried no `Driver` at all
    (row R16.03). Presence tests use `object.get(object, key, default)`.
  - **Residuals are stated, not hidden**: published host ports are outside the
    gate; a symlink inside `P-15` survives where the plugin cannot resolve
    paths; container deletion and lifecycle calls stay unscoped. Each is in
    Limitations, with what closing it would take.
  - **Follow-up out of this package's scope**: `improve-docker-security`'s R-2
    says the OPA policy narrows what the daemon *executes*; nothing in this
    package enforces that, and it belongs in an issue against that schematic
    rather than in an edit here.
  - **Version 0.4.0 (minor)**: R-15 to R-18 are new requirements, so the level
    is "new capability" per the update workflow. A review comment noted that a
    *narrowed* contract can read as a major bump; recorded rather than silently
    disagreed with — what narrowed is the policy's grants, which the
    requirements never intended to make, while the requirement set grew. A
    future change that *removes* a requirement is the major bump.
  - **The in-place `Revision 2026-09-16` notes on R-5 and R-12 were left in
    place**, with a dated revision note added under each rather than the
    requirement being rewritten. The review raised whether those revisions
    should have been a major bump; the decision is that the form stays, because
    a reader needs the current text and its history in one place.
  - **Merge order**: `#18` (one canonical container-format companion) was
    already merged into `main`, and this branch was rebased onto it, so the
    deletion of the per-package `SCHEMATIC.md.schema` is in the base rather
    than a conflict here.

- **Path matching derives the version-free path inside the policy** (R-19):
  `path` is `PathPlain` with one optional `/v<major>[.<minor>]` prefix removed
  and with no `..` segment, and `path_segments` is `split(path, "/")`. Deriving
  was chosen over rebuilding the path from `PathArr` because rebuilding
  mishandles a path that carries no version (`/_ping` would lose a real segment)
  and needs the same guard anyway, while one anchored regex leaves an
  unversioned path untouched — a client that omits the version keeps working.
  The `..` guard exists because the daemon cleans the path before routing while
  the plugin authorizes the raw one, so no rule may be reachable through a
  traversal. The property is asserted by running the probe table with a version
  prefix, without one, and with a major-only prefix: all three give identical
  decisions.
- **A policy reload replaces the file and never touches the plugin (Q-4).**
  Disabling, removing or upgrading a plugin that a running daemon references is
  fatal: `level=fatal msg="Error validating authorization plugin" error="plugin
  \"<P-14>\" not found"`, and dockerd exits (measured on Docker 29.6.1, snap
  install). `docker plugin enable` cannot recover that state, because it needs a
  running daemon — remove the reference from the live configuration file (P-13)
  first. No bounce is needed in any case: `evaluatePolicyFile` reads the policy
  **file on every request**, so the deployed file *is* the live policy. Replace
  it by installing to a temporary name and renaming over the target, because a
  *missing* policy file is the plugin's one fail-open path (`OPA policy file %s
  does not exist, failing open and allowing request`), which copying or
  truncating the live path can produce.
  `scripts/reload-opa-policy.sh` does this and verifies the result through the
  decision log's `config_hash`.
- **A snap-installed daemon does bind-mount the policy directory (Q-5).** The
  host directory (P-6) appears inside the managed plugin at `/opa`, so the
  policy is a host file the plugin reads. The plugin's own record names both
  halves — `docker plugin inspect <P-14>` shows the `-policy-file` argument and
  the mount that carries it — which is how the deploy script derives the host
  path (P-7) instead of assuming it.
- **The registered plugin name is the install name, tag included** (P-14).
  Installed without `--alias` it registers as `opa-docker-authz:latest`, which
  is the name the daemon's `authorization-plugins` entry must carry and the name
  that appears in denial messages.
- **The probe table's evidence is decision-level.** A live end-to-end pass
  (A-11, A-16) against a real daemon is what proves the table's model of the
  input matches the plugin's.

Open questions:

- **Q-1** *(answered 2026-09-16; re-verified 2026-09-17)*:
  `sprintf("/%s", [action])` is valid — the format string and its argument list
  were verified by evaluation under OPA v0.60.0, v1.3.0, and v1.7.1, not
  assumed. The original default ("keep as written, test with `opa check`")
  stands, with the engines named.
- **Q-2** *(answered 2026-09-16; revised 2026-09-17)*: the bind-mount check is
  not an attribution heuristic. Attribution is the label (creates) and the
  name or path segment (network and volume calls); the mount check is R-15's
  host-path boundary, and since 2026-09-17 it gates every container create
  rather than decorating the path-named operations. Its path is parameterized
  (P-15), and it is effective only where the plugin can resolve host paths (see
  the policy module's limitation on `Resolved`).
- **Q-3** *(answered 2026-09-16; engine corrected 2026-09-17)*: the plugin
  repository in the original text does not exist; P-10 now names the real
  images. The version constraint is inverting as stated there — `v0.10` (OPA
  **v1.3.0**) and `v0.9` (OPA v0.60.0) both run this policy, and the language to
  avoid is the classic v0 form the original file used, which the older engines
  reject. The 2026-09-16 pass wrote "v1.7.1" for `v0.10`; that was wrong — the
  version comes from the plugin release's own `go.mod` at its tag, not from the
  newest OPA release at the time of writing, which is the mistake to avoid here.
- **Q-4** *(new)*: whether the daemon **refuses to start** when
  `authorization-plugins` names a plugin that is absent or disabled. The
  request-time behavior is documented (fail closed); the startup behavior is
  `inferred:` and untested here. Decide by testing on a maintenance window with
  a restart, not by assumption — until then, Phase 3's ordering (install first,
  reference second) is the safe procedure.
- **Q-5** *(answered 2026-09-17)*: **yes** — a snap-installed daemon does
  bind-mount host `P-6` into the managed plugin at `/opa`, verified by the
  operator on the snap host this package was tested against (the daemon's
  `/etc/docker` is a snap layout pointing at `$SNAP_DATA/etc/docker`, and the
  plugin's mount source resolves there). The install argument and the policy
  path (`/opa/authz/agent.rego`) are therefore correct as documented, and no
  second location for the policy file is needed.



