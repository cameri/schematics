---
name: docker-socket-proxy
version: 0.1.0
status: published
description: Exposes a deny-by-default Docker API to containers over an internal network - an endpoint allowlist proxy in front of docker.sock so tooling can pull images or read status without ever mounting the socket or gaining control of the daemon.
---

# Schematic: Docker Socket Proxy

## Applicable Context

**Must discover locally:**

- `docker compose version` (compose v2 required for `docker compose config`)
- `docker info` (daemon reachable; confirm socket path)
- The consumer containers that need Docker API access, and which API
  operations each actually performs (grep their configs for
  `/containers/`, `/images/`, `/exec`, etc.)

**May assume (with risk):**

- A Docker daemon with a Unix socket at `/var/run/docker.sock` (override
  P-2 if different)
- Linux host; the proxy runs as root inside its container

**Must not change:**

- The Docker daemon and its socket ownership/permissions
- Existing consumer containers (they are re-pointed, not modified)

## Scope

**In scope:**

- Deploying a deny-by-default Docker API proxy as a compose service
- Choosing and documenting an endpoint allowlist per deployment
- Re-pointing consumers from socket mounts to the proxy endpoint
- An audit script that proves the allowlist is what you think it is

**Out of scope / non-goals:**

- Authentication on the proxy endpoint (network isolation is the access
  control; add mTLS or an auth sidecar as a separate concern)
- Fine-grained per-consumer policies (the proxy scopes by endpoint, not by
  client; per-client policy is a follow-up deployment concern)
- Docker daemon hardening generally (user namespaces, rootless mode)

**Preservation List (reverse-engineered):**

- The deny-by-default posture: every endpoint group not explicitly enabled
  stays disabled
- The read-only socket mount
- No published ports on the proxy

## Requirements

- **R-1**: The Docker socket MUST NOT be mounted into any consumer
  container. Consumers reach the daemon only through the proxy's HTTP
  endpoint.
- **R-2**: The proxy MUST deny every API endpoint group that is not
  explicitly enabled in its configuration (deny by default, not allow by
  default).
- **R-3**: Every enabled endpoint group MUST have a documented reason in
  the deployment config; an allowlist entry without a reason is a bug.
- **R-4**: The proxy image MUST be pinned by digest, not by mutable tag.
- **R-5**: The proxy MUST NOT publish ports to the host. Only containers
  on the same compose network reach it.
- **R-6**: The docker.sock mount into the proxy MUST be read-only
  (`:ro`).
- **R-7**: Container control verbs (start/stop/restart/exec) MUST stay
  disabled unless a requirement explicitly demands them; enabling them
  requires a written justification alongside the allowlist.
- **R-8**: An audit procedure MUST exist that enumerates every endpoint
  group and reports allowed vs denied, so the effective policy is
  verifiable, not assumed.

## Design Principles Binding the Implementation

The ten binding principles apply as published in the repository README.
Implementation-specific binding choices:

- The allowlist is configuration, not code: changing scope is an env edit
  plus a recreate, never an image rebuild.
- The proxy is infrastructure, not application: it has no volumes, no
  state, and a restart is always safe.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | Docker Engine with unix socket | The proxy forwards to it | `docker info` | Proxy starts but every request fails with 5xx; audit script reports the daemon unreachable |
| D-2 | Docker Compose v2 | Service definition and network isolation | `docker compose version` | Use `docker run` equivalents; compose syntax is not portable to v1 |
| D-3 | tecnativa/docker-socket-proxy image | The proxy itself (HAProxy in front of the socket) | Pinned digest in the compose file | Pull failure blocks deploy; any registry mirror may substitute |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | PROXY_IMAGE | string | `tecnativa/docker-socket-proxy` | The deployment's registry layout | Image to run; pin the tag to a digest |
| P-2 | DOCKER_SOCKET_PATH | path | `/var/run/docker.sock` | `docker info -f '{{.DockerRootDir}}'` and host inspection | Socket mounted read-only into the proxy |
| P-3 | COMPOSE_PROJECT_DIR | path | (the directory holding the compose file) | Where the consumer stack lives | Network attachment point for consumers |
| P-4 | ALLOWED_GROUPS | env map | (empty) | Grep consumer configs for the API paths they call; each gets a justification | Endpoint groups enabled, e.g. `IMAGES=1`, `CONTAINERS=1` |
| P-5 | NETWORK_NAME | string | `docker-proxy` | Compose project conventions | Name of the internal network consumers join |
| P-6 | PROXY_PORT | port | `2375` | The proxy image's default | In-network HTTP endpoint; never published |

## Modules

- **endpoint-scoping**: how the proxy's env vars map to Docker API endpoint
  groups, and how to derive the minimal set from consumer behavior.
- **network-isolation**: how the proxy is fenced so "HTTP on 2375" is not an
  accident waiting for a port publish.

## Interfaces and Contracts

### Docker API endpoint (consumed by client containers)

- URL: `http://socket-proxy:2375` (service name P-5-resolved)
- Behavior: HAProxy ACLs permit only the enabled groups' paths and verbs;
  everything else returns 403
- Contract: enabled groups behave exactly as the Docker API documents;
  disabled groups are unreachable, not partially functional

### Container contract

- Name: `socket-proxy` (or project-prefixed variant)
- Restart: `unless-stopped`
- Mounts: exactly one - the docker socket, read-only
- Ports: none published

## Implementation Phases

### Phase 1: Discover the minimal allowlist

1. List every consumer that will use the proxy.
2. For each, grep its configuration (compose env, config files, code) for
   Docker API usage: `grep -rE "(/containers|/images|/exec|/networks|/volumes|/swarm|/events)" <consumer-config>`.
3. Map each usage to its endpoint group (see the endpoint-scoping module).
4. Write the resulting groups into the deployment config with a
   one-line justification per group (R-3).
5. Verification: the allowlist table exists in the compose file (or its
   `.env`), every entry has a justification.

### Phase 2: Deploy the proxy

1. Add the `socket-proxy` service from `skeleton/compose-socket-proxy.yml`
   to the compose project, with P-4's groups as its environment.
2. Create the internal network (P-5); attach the proxy and the consumers
   to it; publish no ports (R-5).
3. `docker compose up -d socket-proxy`.
4. Verification: `docker compose ps socket-proxy` is healthy; the socket
   is mounted `:ro` in `docker inspect` (R-6); `docker port socket-proxy`
   is empty (R-5).

### Phase 3: Prove the policy

1. Run `scripts/audit-access.sh http://socket-proxy:2375` from a consumer
   container.
2. Compare the audit output against the intended allowlist (P-4). Every
   intended-allowed group returns 200/2xx; every other group returns 403.
3. Verification: audit output matches the allowlist exactly (R-2, R-8).

### Phase 4: Re-point consumers and remove socket mounts

1. Change each consumer's Docker endpoint from the socket (or
   `unix:///var/run/docker.sock`) to `http://socket-proxy:2375`.
2. Remove every `docker.sock` mount from consumer services (R-1).
3. `docker compose up -d <consumers>`.
4. Verification: `docker inspect <consumer>` shows no socket mount;
   each consumer performs its task successfully through the proxy.

## Verification and Acceptance

- **A-1** (R-1): `docker inspect` on every consumer shows no
  `/var/run/docker.sock` mount.
- **A-2** (R-2, R-8): the audit script's allowed/denied matrix matches the
  documented allowlist, including 403 on every disabled group.
- **A-3** (R-3): every enabled group in the compose config has a written
  justification next to it.
- **A-4** (R-4): the image reference in the compose file contains an
  `@sha256:` digest.
- **A-5** (R-5): no published ports on the proxy; from outside the compose
  network, the endpoint is unreachable.
- **A-6** (R-6): `docker inspect socket-proxy` shows the socket mount with
  `RW: false`.
- **A-7** (R-7): `POST /containers/<id>/restart` returns 403 unless a
  written justification for container-control verbs exists.

## Failure Modes and Rollback

- **Proxy container down**: consumers fail with connection refused. Detect
  with the proxy's healthcheck / consumer error logs. Recovery:
  `docker compose up -d socket-proxy`. Rollback is the same command.
- **Wrong allowlist (consumer gets 403)**: the group was not enabled.
  Enable it with justification, `docker compose up -d socket-proxy`
  (env change requires a recreate).
- **Daemon moved off the default socket path**: set P-2 and recreate.
- **Full rollback**: remove the proxy service, restore the consumers'
  socket mounts and endpoints. The original working state is exactly the
  pre-change compose file; keep it in version control.

## Removal

1. Re-point consumers back to their previous Docker access (socket mount
   or other endpoint) and recreate them.
2. `docker compose down socket-proxy` (or remove the service block and
   `docker compose up -d`).
3. Remove the internal network if nothing else uses it.
4. The host is unchanged: the daemon and its socket were never modified.

## Decisions and Open Questions

Decisions:

- 2026-09-10: Reverse-engineered from two production deployments (a
  webhook-driven pull pipeline and a coding-agent sandbox) that both run
  tecnativa/docker-socket-proxy with deny-by-default allowlists. The
  schema generalizes the pattern; per-deployment allowlists are
  parameters, not part of the schematic.

Open questions:

- **Q-1**: Whether per-consumer ACLs (client certificate or source-IP
  based) are worth a module. Default: no - network isolation plus the
  deny-by-default group list has been sufficient in both source
  deployments; revisit if a deployment needs mutually untrusting
  consumers on one network.
