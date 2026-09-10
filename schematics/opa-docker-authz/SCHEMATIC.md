---
name: opa-docker-authz
version: 0.2.0
status: draft
spec: 1
description: Grants a sandbox container restricted Docker daemon access over TLS, policed by Open Policy Agent — certificate infrastructure, Rego policy, systemd TCP listener, and sandbox client provisioning.
created: 2026-09-09
updated: 2026-09-09
---

# Schematic: OPA Authorization for Docker Sandbox Access

> **Reverse-engineered.** This schematic was reconstructed from a running
> implementation at `/workspace/containers/claude/`. Components where the
> reconstruction inferred behaviour from code rather than observing it at
> runtime carry `inferred:` markers in their sections. Two
> reverse-engineering-specific notes:
> 1. The OPA plugin's exact Rego function support (particularly `sprintf`
>    syntax) is inferred from plugin documentation, not observed at runtime.
> 2. The `resource_belongs_to_project` bind-mount heuristic was observed in
>    the policy but the multiplix approaches to address containers (by label,
>    by name, by bind path) were present simultaneously — their relative
>    priority and interaction are inferred.

Grants a sandbox container (isolated agent, CI runner, or untrusted workload)
restricted TCP access to the host Docker daemon, policed by Open Policy Agent.
After implementing this schematic, the host's Docker daemon listens on a TLS
port, an OPA plugin authorizes every API call against a Rego policy, and the
sandbox container carries a client TLS certificate and environment variables that
let it run Docker commands — but only operations the policy permits.

The policy enforces: read-only for most resources, full compose lifecycle for a
single named project, image builds and pulls, and container lifecycle actions
(start/stop/restart/kill) against an allowlist. Exec and attach are denied.
The host's local unix socket remains unrestricted for host users.

## Applicable Context

**Must discover locally:**
- The host's routable IP address (used as the TLS SAN and the DOCKER_HOST value).
  Discovery: `tailscale ip -4` (if Tailscale is installed) else `ip -4 addr show
  scope global | grep -oP 'inet \K[\d.]+' | head -1`.
- Whether the host is running a systemd-based Linux distribution (for the
  systemd drop-in). Discovery: `systemctl --version` succeeds.
- The installed Docker daemon version (to verify plugin compatibility).
  Discovery: `dockerd --version`.
- The host filesystem paths for Docker config (`/etc/docker`) and systemd
  drop-ins (`/etc/systemd/system/docker.service.d`). Discovery: check for
  `/etc/docker/daemon.json` and `systemctl show docker --property=FragmentPath`.

**May assume:**
- Linux x86_64 host (assumption shared by almost every Docker deployment).
  Risk if wrong: OpenSSL and OPA plugin may not be available for the
  architecture.
- Docker is installed and managed by systemd (`docker.service`). Risk if wrong:
  the systemd drop-in step must be adapted to the init system.
- The sandbox container is rootless (non-root user inside). Risk if wrong: file
  permissions on certs may be too restrictive.
- `docker plugin` (managed plugin system) is available. Risk if wrong: must use
  the legacy plugin path with `--plugin` flags on dockerd.

**Must not change:**
- Existing Docker daemon `hosts` configuration — it conflicts with the systemd
  `-H` flag. Use a systemd drop-in instead.
- The host's unix socket authorization behaviour: it remains unrestricted.
- Any existing `authorization-plugins` in daemon.json — they are merged, not
  replaced.

## Scope

**In scope:**
- TLS certificate authority creation and certificate signing (CA, server cert
  with SANs, client cert with CN identity).
- Docker daemon configuration: TLS verification enabled, OPA authz plugin
  registered.
- Systemd drop-in to add TCP listener on a TLS port alongside the existing
  `-H fd://`.
- OPA Rego policy that enforces sandbox restrictions (read-only, project-scoped
  compose, build/pull, lifecycle allowlist).
- OPA plugin installation (the `opa-docker-authz` managed plugin).
- Sandbox provisioning: client certs and shell environment file written to a
  host directory later bind-mounted into the container.
- Policy reload procedure (bounce the plugin, not the daemon).
- Verification commands for TLS connectivity and OPA enforcement.

**Out of scope / non-goals:**
- The sandbox container itself (Containerfile, entrypoint, bind mounts — the
  host-side config is in scope, the container image is not).
- Multi-project support (the policy hard-codes a single project name).
- High availability or multi-host orchestration.
- Metrics or audit logging beyond what the OPA plugin emits.
- Automatic certificate rotation.

**Preservation List** *(reverse-engineered)*:

*Must match original behaviour exactly:*
- The `is_sandbox` identity detection: CN=sandbox-agent OR `X-Sandbox-Agent: true`
  HTTP header. Both must work because the Docker client drops HTTP headers in
  some configurations.
- The `resource_belongs_to_project` bind mount path check: the directory suffix
  defines the allowed project, and both `Binds`-array and `Mounts`-array formats
  must be checked.
- The lifecycle action allowlist: exactly `{start, stop, restart, kill, pause,
  unpause, wait, update}`. Exec and attach are structurally excluded.
- The BuildKit container name prefix pattern: `/buildx_buildkit_`.
- The `com.docker.compose.project` label check must match the exact project name.

*Open to reinterpretation:*
- The certificate validity duration (default 3650 days in setup script, but
  shorter is safer).
- The specific OPA plugin image tag (`v0.10` vs latest stable).
- The optional `X-Sandbox-Agent` HTTP header name.
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
- **R-5**: The OPA policy MUST restrict sandbox container lifecycle operations
  to a single named Docker Compose project.
- **R-6**: The OPA policy MUST deny sandbox `exec` and `attach` operations
  (no shell access to any container).
- **R-7**: The OPA policy MUST allow image builds and pulls from the sandbox.
- **R-8**: The OPA policy MUST allow a closed set of container lifecycle actions:
  start, stop, restart, kill, pause, unpause, wait, update.
- **R-9**: The sandbox container MUST NOT require Docker configuration changes
  when the OPA policy is updated — policy reload is a host-side operation.
- **R-10**: The host's unix socket (`/var/run/docker.sock`) MUST remain
  unrestricted for local host users.
- **R-11**: The OPA policy MUST allow testcontainers-go containers (labelled
  `org.testcontainers: true`) to be created from the sandbox.
- **R-12**: The OPA policy MUST allow network and volume operations scoped to
  the authorized project.

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
| D-1  | Docker Engine (dockerd)  | The daemon being secured                 | `dockerd --version` exits 0                                 | Hard fail before Phase 1                                  |
| D-2  | OpenSSL                  | Certificate generation                   | `openssl version` exits 0                                   | Hard fail before Phase 2                                  |
| D-3  | OPA Docker Authz plugin  | Managed Docker plugin for Rego authz     | `docker plugin ls` for `opa-docker-authz`                   | Hard fail in Phase 4 if install fails                     |
| D-4  | Rego policy engine       | Built into the OPA plugin                | Part of D-3 — no separate check                             | Not applicable                                            |
| D-5  | systemd                  | Drop-in for TCP listener                 | `systemctl --version` exits 0                               | Phase 5 must adapt to alternative init system             |
| D-6  | python3                  | Merging daemon.json (json handling)      | `python3 --version` exits 0                                 | Phase 3 falls back to manual daemon.json edit (instructions given) |
| D-7  | TCP reachability         | Sandbox must reach DOCKER_HOST:2376      | `ss -tlnp \| grep 2376` from host; `curl` from sandbox      | Hard fail in Phase 9 verification                        |
| D-8  | Root or sudo             | Most steps require root                  | `whoami` shows root, or `sudo -n true` exits 0              | Hard fail — most phases fail without root                 |

## Parameters

| Id   | Name                    | Type   | Default                          | Discovery                                                                 | Effect                                                              |
|------|-------------------------|--------|----------------------------------|---------------------------------------------------------------------------|---------------------------------------------------------------------|
| P-1  | DOCKER_HOST_IP          | string | (discovered)                     | `tailscale ip -4` if available else `ip -4 addr show scope global \| grep -oP 'inet \K[\d.]+' \| head -1` | IP address the sandbox uses to reach Docker daemon                  |
| P-2  | DOCKER_DAEMON_PORT      | int    | 2376                             | Port must be free: `ss -tlnp '(sport = :2376)'`                           | TCP port for TLS Docker listener                                    |
| P-3  | PROJECT_NAME            | string | backend-services                 | The Docker Compose project name the sandbox is allowed to manage          | Scopes all container/network/volume operations                      |
| P-4  | SANDBOX_USERNAME        | string | sandbox-agent                    | The CN in the client TLS cert — identifies sandbox in OPA policy          | OPA identity detection via `input.User`                             |
| P-5  | CA_VALIDITY_DAYS        | int    | 3650                             | N/A — a policy decision                                                   | Lifetime of the self-signed CA and all signed certs                 |
| P-6  | CA_DIR                  | path   | /etc/docker                      | Default Docker cert directory; check `docker info \| grep "Docker Root Dir"` for alternative | Filesystem path for CA key, CA cert, server cert, client cert       |
| P-7  | POLICY_DIR              | path   | /etc/docker/authz                | Convention: subdirectory of CA_DIR                                       | Where agent.rego is deployed                                        |
| P-8  | SANDBOX_CONFIG_DIR      | path   | /home/<user>/workspace/...       | Where the sandbox container config lives (bind mount source on host)      | Client certs, config.json, and env file written here                |
| P-9  | AUTH_HEADER             | string | X-Sandbox-Agent: true            | N/A — a policy decision                                                   | HTTP header used as defence-in-depth for sandbox identity detection  |
| P-10 | OPA_PLUGIN_TAG          | string | ghcr.io/open-policy-agent/opa-docker-authz:v0.10 | `docker search opa-docker-authz` for latest                               | Which OPA plugin image to install                                   |
| P-11 | BUILDKIT_PREFIX         | string | /buildx_buildkit_                | N/A — a known BuildKit container naming pattern                           | OPA uses this to identify BuildKit containers                       |
| P-12 | TESTCONTAINERS_LABEL    | string | org.testcontainers: true         | N/A — a known testcontainers-go label convention                          | OPA uses this to identify testcontainers containers                 |

## Modules

- **OPA Policy** (`modules/opa-policy.md`) — the Rego authorization policy file
  that defines sandbox vs host identity, read-only grants, project-scoped
  container operations, lifecycle allowlists, and BuildKit/testcontainers
  carve-outs.
- **Docker Daemon Config** (`modules/daemon-config.md`) — daemon.json TLS and
  OPA plugin configuration, plus systemd drop-in for the TCP listener.
- **Sandbox Provisioning** (`modules/sandbox-provisioning.md`) — client
  certificate deployment, Docker environment file, and config.json for the
  sandbox container's bind-mounted `.docker` directory.
- **Policy Reload** (`modules/policy-reload.md`) — host-side procedure to apply
  a Rego policy change by bouncing the OPA plugin (no daemon restart).

## Interfaces and Contracts

### Docker API (external interface)

The capability attaches to Docker's existing authorization plugin interface.
Docker calls the OPA plugin synchronously for every API request, passing the
full request context as JSON. The plugin evaluates `input` against the Rego
policy and returns `allow: true/false`.

See [Docker authorization plugin spec](https://docs.docker.com/engine/extend/plugins_authorization/)
for the exact `AuthZPlugin.Request` and `AuthZPlugin.Response` message schema.

### Rego input schema (contract consumed by the policy)

The `opa-docker-authz` plugin passes the Docker API request as this JSON
structure to the Rego evaluation:

```json
{
  "User": "sandbox-agent",
  "Method": "GET",
  "Path": "/v1.47/containers/json",
  "PathPlain": "/containers/json?all=true",
  "Headers": {
    "X-Sandbox-Agent": ["true"]
  },
  "Body": {
    "Labels": { "com.docker.compose.project": "backend-services" },
    "HostConfig": {
      "Binds": ["/src:/dst"],
      "Mounts": []
    },
    "Name": "/buildx_buildkit_default"
  }
}
```

Fields used by the policy:
- `input.User` — set to the TLS client certificate CN
- `input.Headers` — HTTP headers (defence-in-depth header)
- `input.Method` — HTTP method (GET, HEAD, POST, DELETE)
- `input.PathPlain` — request path without API version prefix
- `input.Body.Labels` — container labels (compose project, testcontainers)
- `input.Body.HostConfig.Binds` — bind mount sources
- `input.Body.HostConfig.Mounts` — JSON-style mount sources
- `input.Body.Name` — container name (for BuildKit pattern)

### OPA plugin interface (consumed by the daemon)

The plugin registers under the name `opa-docker-authz` and is listed in
daemon.json under `authorization-plugins`. After install and enable, Docker
discovers it automatically — no other registration needed.

### Environment interface (consumed by the sandbox)

Three environment variables exported in the sandbox:

```
DOCKER_HOST=tcp://<P-1>:<P-2>
DOCKER_TLS_VERIFY=1
DOCKER_CERT_PATH=/home/agent/.docker
```

The client must have access to `ca.pem`, `cert.pem`, `key.pem` at that cert
path, plus a `config.json` with the auth header for defence-in-depth.

## Implementation Phases

Run all phases from the **host** (not inside the sandbox container). Most steps
require root — the setup script in scripts/ bundles them, but the phases below
can be executed independently.

### Phase 1: System checks
Goal: Verify all dependencies are present before making changes.

Steps:
1. Verify Docker is running: `dockerd --version` exits 0.
2. Verify systemd: `systemctl --version` succeeds.
3. Verify OpenSSL: `openssl version` succeeds.
4. Verify python3: `python3 --version` succeeds.
5. Discover DOCKER_HOST_IP from tailscale or LAN IP.
6. Verify port P-2 is free: `ss -tlnp '(sport = :2376)' | grep -q LISTEN` should
   fail (no listener yet). Skip if re-running after a failed later phase.

Verify:
```
dockerd --version && openssl version && python3 --version && systemctl --version
```
All four commands exit 0.

### Phase 2: Create certificate authority and certificates
Goal: Generate a self-signed CA, a server certificate (with SANs for the Docker
host IP), and a client certificate (with CN = P-4).

Steps:
1. Create CA_DIR if missing: `mkdir -p P-6 && chmod 700 P-6`.
2. Generate CA key and self-signed cert (if not existing):
   `openssl genrsa -out P-6/ca-key.pem 4096`
   `openssl req -x509 -new -nodes -key P-6/ca-key.pem -sha256 -days P-5 -out P-6/ca.pem -subj "/CN=Docker CA"`
3. Generate server key and CSR with SANs for 127.0.0.1, localhost, and P-1.
   Sign with the CA. See `skeleton/openssl-server.conf`.
4. Generate client key and CSR with subject `/CN=P-4` and
   `extendedKeyUsage = clientAuth`. Sign with the CA.
5. Set permissions: server-key.pem 600, client-key.pem 600, certs 644.

Verify:
```
openssl x509 -in P-6/ca.pem -noout -subject | grep -q "CN=Docker CA"
openssl x509 -in P-6/server-cert.pem -noout -ext subjectAltName | grep -q "IP"
echo | openssl s_client -connect 127.0.0.1:P-2 -CAfile P-6/ca.pem 2>&1 | grep -q "CONNECTED"
```
(TLS test will fail until Phase 5 — start with the first two checks.)

### Phase 3: Write daemon.json
Goal: Configure Docker daemon to enforce TLS verification and enable the OPA
authorization plugin.

Steps:
1. Read existing daemon.json (if any) from P-6/daemon.json.
2. Merge or create: set `tlsverify: true`, `tlscacert: P-6/ca.pem`,
   `tlscert: P-6/server-cert.pem`, `tlskey: P-6/server-key.pem`.
3. Append `"opa-docker-authz"` to `authorization-plugins` list (deduplicate).
4. Remove any existing `hosts` key — conflicts with systemd `-H` flag.
5. Write daemon.json with strict JSON (2-space indent).
6. Set permissions: chmod 644.

Verify:
```
python3 -c "import json; cfg = json.load(open('P-6/daemon.json')); assert cfg.get('tlsverify'), 'tlsverify missing'; assert 'opa-docker-authz' in cfg.get('authorization-plugins', []), 'plugin missing'"
```

### Phase 4: Install OPA plugin
Goal: Install the opa-docker-authz managed Docker plugin.

Steps:
1. Check if plugin exists: `docker plugin ls | grep opa-docker-authz`.
2. If absent, install: `docker plugin install P-10`.
3. If present but disabled, enable: `docker plugin enable opa-docker-authz`.

Verify:
```
docker plugin ls --format '{{.Name}} enabled={{.Enabled}}' | grep opa-docker-authz | grep -q true
```

### Phase 5: Configure systemd drop-in for TCP listener
Goal: Add a TLS TCP listener alongside the existing systemd fd socket.

Steps:
1. Create drop-in directory: `mkdir -p /etc/systemd/system/docker.service.d`.
2. Write `tcp-host.conf` replacing ExecStart with:
   `ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:P-2 --containerd=/run/containerd/containerd.sock`
3. Run `systemctl daemon-reload`.
4. Restart Docker: `systemctl restart docker`.
5. Wait for daemon to be ready: `docker info` succeeds.

Verify:
```
systemctl show docker --property=ExecStart | grep -q "tcp://0.0.0.0:P-2"
docker info >/dev/null 2>&1
```

### Phase 6: Deploy the OPA Rego policy
Goal: Copy the Rego policy file to the directory the OPA plugin reads on
startup.

Steps:
1. Copy `modules/opa-policy.md` (the Rego file at `skeleton/agent.rego`) to
   `P-7/agent.rego`.
   `install -D -m 644 skeleton/agent.rego P-7/agent.rego`
2. Bounce the plugin to compile the new policy:
   `docker plugin disable opa-docker-authz && docker plugin enable opa-docker-authz`

Verify:
```
docker plugin ls --format '{{.Name}} enabled={{.Enabled}}' | grep opa-docker-authz | grep -q true
```

### Phase 7: Provision sandbox configuration
Goal: Write client certificates, Docker config, and env file to the host
directory that will be bind-mounted into the sandbox container.

Steps:
1. Ensure SANDBOX_CONFIG_DIR exists.
2. Copy CA cert, client cert, client key: `cp P-6/ca.pem P-8/ca.pem`,
   `cp P-6/sandbox-cert.pem P-8/cert.pem`, `cp P-6/sandbox-key.pem P-8/key.pem`.
3. Write P-8/config.json with the auth header:
   ```json
   {"HttpHeaders": {"P-9": "true"}}
   ```
4. Write P-8/env with:
   ```
   export DOCKER_HOST=tcp://P-1:P-2
   export DOCKER_TLS_VERIFY=1
   export DOCKER_CERT_PATH=/home/agent/.docker
   ```
5. Set permissions: ca.pem/cert.pem 644, key.pem 600, config.json 600, env 644.

Verify:
```
ls -la P-8/ca.pem P-8/cert.pem P-8/key.pem P-8/config.json P-8/env
python3 -c "import json; cfg=json.load(open('P-8/config.json')); print('OK')"
```

### Phase 8: Verify TLS and OPA enforcement
Goal: Confirm the running setup works end-to-end.

Steps:
1. Test TLS connectivity with sandbox client cert:
   `docker --tlsverify -H tcp://P-1:P-2 --tlscacert P-8/ca.pem --tlscert P-8/cert.pem --tlskey P-8/key.pem ps`
2. Test OPA denies unauthorized container creation:
   `docker --tlsverify -H tcp://P-1:P-2 ... run --rm alpine echo hello`
   Should fail with "authorization denied by plugin opa-docker-authz".
3. Test OPA allows authorised compose operations (if the compose project exists):
   `docker --tlsverify ... compose -p P-3 ps`

Verify:
- Step 1 exits 0 and lists containers.
- Step 2 exits non-zero with "authorization denied" in stderr.
- (Step 3 is conditional on the compose project existing.)

### Phase 9: Sandbox container restart
Goal: Signal the sandbox container to reload its Docker configuration.

Steps:
1. Restart the sandbox container so it sources the new env file:
   `docker compose -f <sandbox-compose.yml> up -d <sandbox-service>`
2. Verify from inside the sandbox (or via exec):
   `docker ps` lists containers.
3. Verify OPA still blocks unauthorized operations:
   `docker run --rm alpine echo hello` is denied.

## Verification and Acceptance

- **A-1** (covers R-1, R-2): `echo | openssl s_client -connect 127.0.0.1:P-2 -CAfile P-6/ca.pem 2>&1 | grep -q "CONNECTED"` — TLS handshake succeeds. Without a valid client cert, the daemon drops the connection.
- **A-2** (covers R-3, R-4): `docker --tlsverify -H tcp://P-1:P-2 ... ps` exits 0 — sandbox client can list all resources.
- **A-3** (covers R-5, R-6): `docker --tlsverify ... run --rm alpine echo hello` exits non-zero with "authorization denied" — arbitrary run is blocked.
- **A-4** (covers R-10): `docker ps` (on unix socket, no TLS) exits 0 — host user is unaffected.
- **A-5** (covers R-7): `docker --tlsverify ... build -t test .` (from a directory with a Dockerfile) exits 0 — builds allowed.
- **A-6** (covers R-8): `docker --tlsverify ... stop <container>` exits 0 — lifecycle actions allowed.
- **A-7** (covers R-8): `docker --tlsverify ... exec <container> ls` exits non-zero with "authorization denied" — exec is blocked.
- **A-8** (covers R-9): Modify agent.rego, run reload-opa-policy.sh, then `docker --tlsverify ... ps` still works — policy reloads without daemon restart.

## Failure Modes and Rollback

**Phase 2 (certificate generation):** If OpenSSL fails, check that the openssl
command and options are compatible with the installed version. The CA directory
can be cleaned up with `rm -rf P-6/*.pem P-6/*.srl` and re-run.

**Phase 3 (daemon.json):** If the JSON is invalid, Docker fails to start.
Rollback: restore from backup (`cp /etc/docker/daemon.json.bak` if you made
one; otherwise revert to the previous version manually) and
`systemctl restart docker`. The script backs up the previous daemon.json
automatically.

**Phase 5 (systemd drop-in):** If Docker fails to start after the drop-in,
check conflicting `hosts` in daemon.json. Rollback:
`rm /etc/systemd/system/docker.service.d/tcp-host.conf && systemctl daemon-reload && systemctl restart docker`.

**Phase 6 (policy deploy):** If the plugin fails to enable, check the policy
file syntax. The `opa` CLI can validate: `opa check P-7/agent.rego`. Rollback:
disable plugin (`docker plugin disable opa-docker-authz`), fix policy, re-enable.

**Phase 7 (sandbox provisioning):** Non-critical — fix permissions and copy
manually. The sandbox will fail to connect to Docker until the files are correct.

**Phase 8 (verification):** If the OPA denial test passes but the compose
authorization fails, the most likely cause is an incorrect PROJECT_NAME or a
missing bind-mount path check in the policy. Adjust P-3 or update
`resource_belongs_to_project` in the policy.

## Removal

Clean teardown reverses each phase in the opposite order:

1. Remove systemd drop-in:
   ```bash
   rm /etc/systemd/system/docker.service.d/tcp-host.conf
   systemctl daemon-reload
   systemctl restart docker
   ```
2. Disable OPA plugin:
   ```bash
   docker plugin disable opa-docker-authz
   docker plugin rm opa-docker-authz
   ```
3. Restore daemon.json to pre-schematic state:
   ```bash
   # Remove tlsverify, tlscacert, tlscert, tlskey, authorization-plugins
   # or restore from backup
   systemctl restart docker
   ```
4. Remove CA and certs:
   ```bash
   rm -f P-6/ca*.pem P-6/server*.pem P-6/sandbox*.pem
   rm -rf P-7/
   ```
5. Remove sandbox config:
   ```bash
   rm -f P-8/ca.pem P-8/cert.pem P-8/key.pem P-8/config.json P-8/env
   ```

After removal, confirm:
```bash
docker ps    # on unix socket — should work
docker --tlsverify -H tcp://P-1:P-2 ... ps  # should fail (no listener)
```

## Decisions and Open Questions

Decisions:

- 2026-09-09 — Schematic reverse-engineered from the `containers/claude/`
  repository at `/workspace/containers/`. The setup includes: a self-hosted
  Docker TLS certificate infrastructure, the OPA authorization plugin, a Rego
  policy file, sandbox container provisioning files, and a policy reload
  script. The original host is running Ubuntu with systemd and the sandbox
  container uses `agent` as the non-root user.

Open questions:

- **Q-1**: The OPA policy uses `sprintf` for string concatenation (`lifecycle_action`
  path check) — some OPA versions may require `sprintf("%s", [action])` instead
  of `sprintf("/%s", [action])`. The syntax works in OPA v0.60+ (which the
  v0.10 plugin bundles). Default: keep as written, test with `opa check`.
- **Q-2**: The `resource_belongs_to_project` bind-mount path check hard-codes a
  project directory path. In the original setup this path is
  `/home/cameri/workspace/projects/onlygpus/backend-services`. Should this be
  parameterized? Default: yes, parameterize P-3 and check the label first
  (which is project-based); the bind mount check is a secondary heuristic.
- **Q-3**: The `opa-docker-authz` managed plugin is at
  `ghcr.io/open-policy-agent/opa-docker-authz:v0.10` which bundles OPA v0.60+.
  If using a different tag, the `import future.keywords.in` syntax may not be
  supported. Default: specify `v0.10` or later.



