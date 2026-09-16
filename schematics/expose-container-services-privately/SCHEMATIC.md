<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: expose-container-services-privately
version: 0.1.0
status: published
spec: 1
description: Privately exposing local container services on a tailnet - one TSDProxy container joins a Tailscale-compatible network and reverse-proxies selected services to per-service hostnames with automatic HTTPS. The exposure contract is per service (docker labels or list-file entries); services themselves carry no tunnel client, and nothing needs a public port.
created: 2026-09-14
updated: 2026-09-14
---

# Schematic: Expose Container Services Privately (TSDProxy + Tailscale)

Reverse-engineered from a production deployment (this document's source
instance runs 20+ proxies). The result: selected Docker Compose services
become reachable on a private tailnet as `https://<name>.<tailnet>` with
automatic TLS, while the services themselves stay untouched — no tunnel
client, no sidecar, no published host port, no public exposure.

```
                          tailnet (private, encrypted mesh)
     https://app1.<tailnet> ─┐
     https://app2.<tailnet> ─┼──►  TSDProxy container ──► docker network ──► app1, app2
     https://app3.<tailnet> ─┘        (only tailnet member)
```

## Applicable Context

**Must discover locally:**

- `docker compose version` — compose v2 is required for the config format
  used here
- The tailnet's DNS name (`<tailnet>`): from the tailnet admin console, or
  on a joined machine `tailscale status` (the `-tailnet.ts.net`-style
  suffix). Managed Tailscale assigns it; a self-hosted control server
  (Headscale) has its own equivalent
- The Tailscale auth key for the proxy (see the tailscale-auth module):
  generated in the admin console or control server; reusable keys are
  recommended for unattended restarts
- Whether HTTPS certificates are enabled on the tailnet (managed Tailscale:
  admin console → DNS → HTTPS Certificates; see the TLS module). Without it,
  services are reachable over plain HTTP on the tailnet only
- The service DNS names of the containers to expose, and the port each
  listens on (their compose files / container inspect)

**May assume (with risk):**

- A Linux Docker host with the Docker daemon socket at
  `/var/run/docker.sock` (parameter P-3 if different)
- A private docker network exists or can be created that the proxy and the
  exposed services share (P-4). If services are on *different* networks,
  the proxy must join each of them, or reach them by an address it can
  resolve (see the target-reachability module)
- The proxy container runs with root-equivalent privileges (Tailscale's
  userspace networking needs no kernel module, but the container must be
  able to open its data files and the docker socket)

**Must not change:**

- The exposed services' own configurations, ports, or networks beyond the
  single attachment/shared network the exposure contract requires
- The Docker daemon or its socket permissions

## Scope

**In scope:**

- Deploying one TSDProxy container as the sole tailnet member for a set of
  local container services
- The per-service exposure contract in both supported forms: docker labels
  and list-file entries, and the rules for choosing between them
- Automatic HTTPS per exposed hostname, and the tailnet features that
  provide it (MagicDNS / equivalent name resolution, tailnet TLS)
- Adding, removing, and renaming exposed services at runtime
- The tailscale auth contract: key file, OAuth, and self-hosted control
  servers (Headscale)

**Out of scope / non-goals:**

- Public exposure of any service (Tailscale Funnel / `tailscale serve` to
  the open internet) — this schematic's purpose is the opposite
- Per-service tailscale containers or sidecars (the whole point is zero
  sidecars)
- Client-side configuration of tailnet users' devices
- A self-hosted alternative stack (WireGuard + reverse proxy): feasibility
  and comparison are captured in `assets/wireguard-alternative.md`, a
  research note, not an implementation path in this package
- Docker daemon hardening (see `restrict-docker-api-access` in the catalog)

**Preservation List (reverse-engineered):**

- Must match the source deployment: one proxy container, one tailnet
  identity for the whole set of services; each service exposed as its own
  hostname on that tailnet; automatic TLS on every exposed hostname; the
  docker socket mounted read-write into the proxy (the docker provider
  needs to list containers); the auth key delivered to the proxy as a file
  (`/secrets/ts-auth-key` in the source), never as a compose literal.
- Open to reinterpretation: the config file's organization (the source
  splits entries into category files — applications, admin-tools,
  infrastructure — but a single file works), the dashboard icon set, the
  access-log default.

## Requirements

- **R-1**: Exactly one proxy container serves the whole set of exposed
  services; the proxy is the only tailnet member for those services, and
  no exposed service runs a tunnel client or sidecar.
- **R-2**: Every exposed service is reachable from any tailnet member at
  `https://<name>.<tailnet>` with a valid TLS certificate (or, if the
  tailnet's HTTPS feature is off, at `http://<name>` per P-2). The
  hostname `<name>` is derived from the per-service contract, not the
  container name.
- **R-3**: No exposed service is reachable from the public internet; no
  host port is published for any exposed service, and the proxy itself
  publishes only its management dashboard port (P-6) when the operator
  opts in.
- **R-4**: The exposure contract is declared per service in exactly one
  place — either the service's docker labels or an entry in a configured
  list file — never both for the same hostname. Adding a service is that
  one declaration plus a proxy reload/restart; removing it removes the
  hostname from the tailnet.
- **R-5**: The Tailscale credential used by the proxy is provided as a
  file mounted into the container (P-7), never as a literal in a committed
  config. Rotating the credential must not require a container rebuild.
- **R-6**: The proxy image is pinned by digest, not by mutable tag.
- **R-7**: The proxy can reach each target service over a shared docker
  network by service name, or by a configured fallback address (P-5); the
  reachability choice per service is documented, not guessed (see the
  target-reachability module).
- **R-8**: Every phase below is re-runnable: re-running a phase on an
  already-configured host is a no-op or a safe converge, and every
  verification yields the same verdict.
- **R-9**: Config schema matches the pinned proxy version: TSDProxy v2.x
  config keys are camelCase and the file-provider section is `lists:`
  (the v1 `files:`/`url:` shorthand is legacy — see the config-schema
  module before mixing versions).

## Design Principles Binding the Implementation

The ten binding principles apply as published in the repository README.
Implementation-specific binding choices:

- The exposure contract is configuration, never a proxy code edit: adding
  or removing a service changes a label set or a YAML entry, nothing else.
- The proxy is infrastructure, not application: it keeps no meaningful
  state (Tailscale state under P-8 is recreated from the auth key), and a
  restart is always safe.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | Docker Engine with Unix socket | The proxy's docker provider lists/enumerates target containers; compose runs the proxy itself | `docker info` | Proxy starts but can't see containers; docker-provider exposure fails with "no targets" |
| D-2 | Docker Compose v2 | Runs the proxy service and wires the shared network | `docker compose version` | Use `docker run` equivalents; network wiring is manual |
| D-3 | TSDProxy image (digest-pinned) | The proxy itself | Digest in the compose skeleton | Pull failure blocks deploy; any registry mirror may substitute |
| D-4 | A Tailscale-compatible tailnet (managed Tailscale, or a self-hosted control server) | The private network that carries the traffic | Tailnet admin console / `tailscale status` on a joined machine | Proxy logs auth failures; no hostnames resolve |
| D-5 | Tailscale auth key (or OAuth client credentials) for the proxy | The proxy's tailnet identity | Generated in the control plane's admin UI/CLI | Without it the proxy waits in "auth required"; existing proxies keep working |
| D-6 | Tailnet HTTPS feature (managed Tailscale: enabled in admin console) | Automatic TLS per hostname | Admin console → DNS → HTTPS Certificates | Hostnames serve plain HTTP on the tailnet (R-2 degrades per P-2) |
| D-7 | MagicDNS or equivalent name resolution on the tailnet | `https://<name>.<tailnet>` must resolve on client devices | `tailscale status` shows hostnames | Clients must use tailnet IPs or hosts entries; R-2 fails on name resolution, not on the proxy |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | TAILNET | string | (required) | `tailscale status` on a joined machine (the `-tailnet.ts.net` suffix) or the admin console | DNS suffix all exposed hostnames get |
| P-2 | HTTPS | enum | `auto` | Managed tailnet: admin console → DNS → HTTPS Certificates; self-hosted control server: its TLS docs | `auto` = TLS on every hostname; `off` = plain HTTP on the tailnet |
| P-3 | DOCKER_SOCKET | path | `/var/run/docker.sock` | `docker info -f '{{.DockerRootDir}}'` and host inspection | Socket mounted into the proxy; needed by the docker provider |
| P-4 | PROXY_NETWORK | string | `tsdproxy` | Compose project conventions | Shared docker network the proxy and exposed services attach to |
| P-5 | TARGET_HOSTNAME | string | (docker bridge gateway) | `docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'` | Fallback target address for services not reachable by service name (host-network or other-network targets) |
| P-6 | DASHBOARD_PORT | int | `8080` | First free port ≥8080 (`ss -tlnp`) | Management dashboard/API listener; publish to the host only if LAN management is wanted (R-3) |
| P-7 | AUTH_KEY_FILE | path | `/secrets/ts-auth-key` | Where the deployment mounts the tailscale auth key | The proxy's credential file; must exist before first start |
| P-8 | DATA_DIR | path | `/data` | Deployment's state mount | Tailscale node state; recreated from the auth key if lost |
| P-9 | CONFIG_DIR | path | `/config` | Deployment's config mount | tsdproxy.yaml and any list files |
| P-10 | EXPOSURE_MODE | enum | `files` | Operator choice (see exposure-contracts module) | Which per-service contract this deployment uses: `files` (config entries — what the source deployment runs) or `labels` (docker labels — upstream's headline feature) |
| P-11 | LIST_FILES | map | (empty) | Only when P-10 = `files`: one entry per list file (name → path inside CONFIG_DIR) | Files the file-provider reads; each entry becomes hostnames |
| P-12 | ACCESS_LOG | bool | `false` | Operator preference | Log proxied requests; off reduces log volume |

## Modules

- **exposure-contracts** (`modules/exposure-contracts.md`) — the two
  per-service contracts (docker labels, list-file entries), their exact
  syntax, idempotent add/remove, and the rules for choosing and mixing
  them.
- **config-schema** (`modules/config-schema.md`) — the tsdproxy.yaml shape
  per proxy version (v1 `files:`/`url:` vs v2 `lists:`/`ports:`/`targets:`,
  camelCase), how to recognize which your pinned image speaks, and how to
  migrate.
- **tailscale-auth** (`modules/tailscale-auth.md`) — auth key files,
  OAuth client credentials, self-hosted control servers (Headscale), and
  rotation without rebuilds.
- **target-reachability** (`modules/target-reachability.md`) — how the
  proxy reaches each target: shared-network service names, the fallback
  target address, and per-service reachability decisions.
- **tls-and-dns** (`modules/tls-and-dns.md`) — what "automatic HTTPS" is
  made of (tailnet TLS + MagicDNS), how to verify it, and what changes if
  the tailnet's HTTPS feature is off.

## Interfaces and Contracts

### Exposed hostname (the product of this schematic)

- URL: `https://<name>.<TAILNET>` for every exposed service (P-2 `auto`),
  or `http://<name>` on the tailnet (P-2 `off`)
- `<name>` comes from the per-service contract: `tsdproxy.name` label or
  the list-file entry key
- The tailnet's name resolution (MagicDNS or equivalent) must resolve
  `<name>` to the proxy's tailnet address — the proxy registers the name
  with the control server at startup (R-2)

### Proxy management surface

- Dashboard/API: `http://<proxy-host>:<P-6>`; bind hostname
  `0.0.0.0`, port from P-6. Publishing to the host is opt-in (R-3);
  the dashboard can alternatively be reached from another container on
  the shared network.

### Per-service contract (chosen by P-10)

- **labels**: on the target service —
  `tsdproxy.enable: "true"`, `tsdproxy.name: <name>`, optionally
  `tsdproxy.port.<i>: "<proxyport>/<protocol>:<containerport>/<protocol>"`
  and `tsdproxy.containeraccesslog: "false"`; the service must be attached
  to P-4's network for the docker provider to reach it.
- **files**: an entry keyed by `<name>` in one of P-11's list files, with
  `ports: 443/https: targets: [http://<service>:<port>]` (v2 syntax; the
  v1 `url:` shorthand maps to the same thing — see the config-schema
  module).

## Implementation Phases

### Phase 1: Discover tailnet facts

1. Join a device to the tailnet (or confirm one is joined); record
   `TAILNET` (P-1) from `tailscale status`.
2. Confirm HTTPS is enabled (P-2 `auto`) in the tailnet admin console.
3. Generate a reusable tailscale auth key for the proxy (D-5); store it
   where the deployment keeps secrets (the key file, P-7, is mounted into
   the container — see the tailscale-auth module).
4. Verification: `tailscale status` shows the joined device and the tailnet
   name; the auth key exists and is reusable.

### Phase 2: Deploy the proxy

1. Create P-9's config dir; copy `skeleton/tsdproxy.example.yaml` to
   `<P-9>/tsdproxy.yaml` and fill in P-1..P-12 (config-schema module first —
   the example is v2 syntax; if your pinned image is v1, use the v1 block
   from the config-schema module instead).
2. Create P-4's docker network if it does not exist:
   `docker network create <P-4>`.
3. Add the proxy service from `skeleton/compose-tsdproxy.yml` to the
   compose project (P-3 socket, P-8 data, P-9 config mounts; P-7 key file;
   P-4 network; digest-pinned image per R-6).
4. Start it: `docker compose up -d tsdproxy`.
5. Verification: `docker compose ps tsdproxy` is running/healthy; the
   proxy appears in the tailnet admin console as a connected node;
   `docker compose logs tsdproxy` shows no auth errors.

### Phase 3: Expose the first service

1. Pick the exposure contract (P-10) and apply it to the first target
   service: add the label set (labels) or add a list-file entry and
   register the file under `lists:` in tsdproxy.yaml (files). Ensure the
   service is attached to P-4's network (or documented as reachable via
   P-5 — target-reachability module).
2. Reload the proxy: list-file changes hot-reload; label changes require
   `docker compose restart tsdproxy` (labels mode).
3. Verification: from a tailnet-connected device,
   `curl -fsSI https://<name>.<TAILNET>` returns the target's response;
   `tailscale status` shows the new hostname.

### Phase 4: Expose the remaining services

1. Repeat Phase 3 for each remaining service, one declaration per service
   (R-4).
2. Verification: every intended hostname from the previous step resolves
   and serves; the count in the tailnet admin console matches the number
   of declared services plus the proxy itself.

### Phase 5 (optional): enable the dashboard on the LAN

1. Publish P-6 if LAN management is wanted (R-3 opt-in); otherwise leave
   it in-network.
2. Verification: `curl -fsS http://127.0.0.1:<P-6>` on the host (if
   published) returns the dashboard; from the public internet the port is
   unreachable (R-3).

## Verification and Acceptance

- **A-1** (R-1): `docker ps` on the host shows exactly one container
  running a tailscale/tsdproxy tunnel for the exposed set; none of the
  target services runs a tailscale process (`docker exec <svc> pgrep
  tailscale` exits nonzero — services may lack pgrep; then confirm their
  images/config carry no tunnel client).
- **A-2** (R-2): from a tailnet device, `curl -fsSI
  https://<name>.<TAILNET>` exits 0 and shows the target service's own
  headers/body; with P-2 `off`, `curl -fsSI http://<name>` does.
- **A-3** (R-3): `docker port <svc>` is empty for every exposed service;
  the proxy's only published port is P-6 (if opted in); a probe from
  outside the tailnet cannot reach any exposed hostname (unroutable —
  there is no public address to probe; confirm the tailnet ACLs don't
  allow public sharing).
- **A-4** (R-4): each hostname appears exactly once across labels and list
  files (`grep -r "tsdproxy.name" <compose>` vs list-file keys); removing
  one declaration and restarting/reloading drops the hostname from
  `tailscale status`.
- **A-5** (R-5): `grep -r <auth-key-prefix> <config-dir> <compose>` finds
  nothing (the key lives only in P-7's file); rotating the key file and
  restarting the proxy re-authenticates without a rebuild.
- **A-6** (R-6): the compose file's image reference for the proxy contains
  `@sha256:`.
- **A-7** (R-7): for each service, the reachability path is documented and
  verified: same-network service name resolves from the proxy
  (`docker exec tsdproxy getent hosts <service>` where the image has
  getent, else a curl probe), or P-5 fallback documented and reachable.
- **A-8** (R-8): re-run Phase 3's verification twice — identical results;
  re-running Phase 2 leaves one healthy proxy, not two.
- **A-9** (R-9): the proxy's image version and config syntax agree:
  `docker inspect` the image's version, and confirm tsdproxy.yaml uses
  that version's section names (config-schema module's table).

## Failure Modes and Rollback

- **Proxy up, hostnames not resolving**: auth key expired or tailnet
  ACL/MagicDNS issue. Check `docker compose logs tsdproxy` for
  auth/registration errors; regenerate a key, replace P-7's file, restart
  (tailscale-auth module). Rollback: keep the old key file.
- **Wrong config version (v1 vs v2)**: proxy logs config parse errors.
  Apply the config-schema module's table; restart. Rollback: restore the
  previous tsdproxy.yaml.
- **Service not reachable (502/connection refused)**: reachability issue —
  target not on P-4's network, or P-5 fallback wrong. Fix the attachment
  or P-5; restart proxy. Rollback: restore the previous attachment.
- **One service's hostname wrong**: name collision or stale registration.
  Fix the declaration (R-4 uniqueness), restart; stale names disappear
  from the tailnet on restart.
- **Partial Phase 4**: some hostnames up, some not — the missing ones
  have a contract problem (label typo, missing network, unreachable port).
  Fix each declaration individually; the running proxies are unaffected.
- **Full rollback**: stop the proxy (`docker compose down tsdproxy`),
  remove P-4's network if nothing else uses it, remove the added labels
  or list entries. The exposed services were never modified beyond the
  attachment, so they keep working as before.

## Removal

1. Remove the per-service declarations (labels from each service, list
   entries from P-11 files) — or keep them and just stop the proxy if
   removal may be temporary.
2. `docker compose down tsdproxy` (or `docker compose rm -sf tsdproxy`).
3. In the tailnet admin console, confirm the proxy node and all service
   hostnames are gone (or expire per key policy).
4. Delete P-4's network if nothing else uses it; delete the P-8/P-9
   mounts and P-7's key file only on explicit ask (the state is
   recreated from the key; the config documents what was exposed).
5. The host and all target services are otherwise unchanged.

## Decisions and Open Questions

Decisions:

- 2026-09-14: Reverse-engineered from the source deployment (one tsdproxy
  container, ~20 hostnames, `files:`-provider config split into category
  files, auth key at `/secrets/ts-auth-key`, docker socket mounted). The
  schematic targets TSDProxy v2.x syntax (current stable, immutable tags)
  and documents v1 in the config-schema module because the source
  instance predates v2 and a fresh builder should not copy v1 config
  verbatim.
- 2026-09-14: Both exposure contracts are first-class (labels default,
  files alternative) because the upstream project's headline feature is
  labels while the source deployment actually uses files; the choice is a
  parameter (P-10), not a fork.
- 2026-09-14: The WireGuard self-hosted alternative is captured as a
  research note (`assets/wireguard-alternative.md`), not an
  implementation path: the comparison shows it is feasible with
  materially higher operational cost, and this package deliberately does
  not dual-ship two stacks.

Open questions:

- **Q-1**: Whether to add an optional module for public exposure
  (Tailscale Funnel) as a deliberate opt-in. Default: no — this
  schematic's contract is private exposure; funnel belongs to a separate
  package if ever wanted.
- **Q-2**: Dashboard access control (the v2 proxy supports an API key and
  role-based access). Default: leave it unauthenticated on the internal
  network only; if the dashboard is published beyond a trusted LAN, enable
  the API key per upstream docs.
