---
name: webhook-rolling-deploy
version: 0.1.0
status: published
description: Self-updating Docker Compose deployments - a GitHub push webhook flows through a Cloudflare tunnel and a path-token receiver into an in-memory queue, and a worker pulls the new image through a scoped Docker API proxy. HTTP ack in milliseconds, pull in the background, no open ports, no full docker socket anywhere.
---

# Schematic: Webhook-Driven Rolling Image Deploy

## Applicable Context

**Must discover locally:**

- `docker compose version` (v2)
- `docker info` (daemon, socket path)
- Whether the host has IPv6 egress (`curl -6 -s https://cloudflare.com -o /dev/null -w '%{http_code}'`);
  the tunnel edge has AAAA records, so `--edge-ip-version 6` is safe either
  way when IPv6 exists
- The target image's registry and tag convention (`ghcr.io/<org>/<repo>`,
  a branch tag, or a digest)
- A Cloudflare account and zone: a Cloudflare Tunnel must be creatable
  (Zero Trust dashboard or API)

**May assume (with risk):**

- GitHub as the forge (the receiver filters on `X-Github-Event` and
  `refs/heads/<branch>`; adapting another forge is a receiver-config edit)
- The public hostname is proxied through Cloudflare

**Must not change:**

- The Docker daemon's socket permissions
- Other services running on the host

## Scope

**In scope:**

- The five-service pipeline: tunnel connector, webhook receiver, queue,
  pull worker, Docker API proxy
- The response contract with GitHub (fast ack, async pull, retries are
  no-ops)
- The trust chain: tunnel, path token, event filter, scoped Docker API

**Out of scope / non-goals:**

- Recreating containers after the pull (the pull makes the new image
  available; the deploy step is `docker compose up -d <service>` run by an
  operator or a separate deployment concern — see the scope rationale in
  Decisions)
- Building images (the webhook fires on push of already-built images)
- Multi-host fan-out

**Preservation List (reverse-engineered):**

- The queue decoupling: ack and pull MUST be separate processes (a broker
  that acks only when all child outputs finish will 408 GitHub; see the
  ack-vs-pull module)
- Delivery-ID dedup so GitHub retries never double-pull
- The scoped socket proxy: pull-only, never the raw socket

## Requirements

- **R-1**: The public endpoint MUST be reachable only through an
  outbound-only tunnel connector; no host ports are opened for this
  pipeline.
- **R-2**: The receiver MUST reject any request whose URL path does not
  carry a deployment-specific random token (404), and MUST process only
  push events for the watched ref.
- **R-3**: The HTTP response MUST return within seconds of a valid push
  (GitHub times out around 10s), regardless of pull duration.
- **R-4**: Duplicate delivery IDs MUST NOT trigger a second pull.
- **R-5**: Docker API access MUST go through a deny-by-default scoped
  proxy (pull images, list containers; no exec, no container lifecycle,
  no swarm) with the socket mounted read-only. The
  `docker-socket-proxy` schematic implements this; this schematic treats
  it as its dependency.
- **R-6**: Every image reference (proxy, receiver, worker, redis, target)
  MUST be pinned by digest; the pulled target is pinned by tag per the
  deployment's registry convention.
- **R-7**: Queue persistence MUST be off: a lost queue entry is harmless
  (the next push re-pulls), and durable state would turn a transient
  failure into a stale pull on restart.
- **R-8**: Pull failures MUST retry (bounded, with backoff) and re-queue
  on final failure rather than vanish.
- **R-9**: The real `.env` (tunnel token, webhook token) MUST never be
  committed; only `.env.example` ships in the package.

## Design Principles Binding the Implementation

The ten binding principles apply as published in the repository README.
Implementation-specific binding choices:

- Every timing number in the configs (5s ack budget, 10m pull timeout,
  1m retry spacing) is a recorded decision from production, not a guess;
  do not "tidy" them without reading the ack-vs-pull module.
- The pipeline is five dumb single-purpose containers, not one smart one:
  each failure mode is isolated and each container is replaceable.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | Docker Engine + Compose v2 | Runs the pipeline and the target | `docker compose version` | Blocker; the schematic has no non-compose variant |
| D-2 | Cloudflare Tunnel with a dedicated tunnel ID | Ingress without open ports (R-1) | Zero Trust dashboard; a dedicated tunnel, NOT a shared remotely-managed one (shared tunnels load-balance across replicas and would misroute half the webhooks) | Webhooks 5xx at the edge; check connector logs |
| D-3 | redpanda-connect image | The receiver and the pull worker (one image, two configs) | Pinned digest in compose | Pull failure blocks deploy |
| D-4 | redis image (in-memory mode) | The ack/pull decoupling queue | Pinned digest in compose | Receiver errors on enqueue; GitHub sees 500 and retries |
| D-5 | docker-socket-proxy (see the docker-socket-proxy schematic) | Scoped Docker API for the pull (R-5) | Its own deployment; this stack attaches to its network | Worker fails with 403; audit script diagnoses which group is missing |
| D-6 | GitHub webhook on the target repo | The trigger | Repo Settings > Webhooks; URL is `<public-host>/webhook/<WEBHOOK_TOKEN>` | Missed deploys; delivery list in GitHub shows response codes |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | TUNNEL_TOKEN | secret | (required) | Cloudflare Zero Trust > Tunnels > the dedicated tunnel | Authenticates the connector |
| P-2 | PUBLIC_HOSTNAME | string | (required) | The proxied DNS name pointed at the tunnel | GitHub webhook URL base |
| P-3 | WEBHOOK_TOKEN | secret | (required) | `openssl rand -hex 32` | Path token embedded in the webhook URL (R-2) |
| P-4 | WATCHED_BRANCH | string | `main` | The branch whose pushes mean "deploy" | Receiver filter (R-2) |
| P-5 | TARGET_IMAGE | string | (required) | The registry path of the image to pull | What the worker pulls |
| P-6 | TARGET_TAG | string | (required) | The registry's branch tag convention | Tag pulled on every push |
| P-7 | QUEUE_NAME | string | `pull-requests` | Design decision | Redis list key between receiver and worker |
| P-8 | SOCKET_PROXY_URL | string | `http://socket-proxy:2375` | The docker-socket-proxy deployment | Where the worker POSTs pulls |
| P-9 | TZ | string | (host timezone) | `date +%Z` | Log timestamps |

## Modules

- **ack-vs-pull**: why the redis queue exists - the timing proof of the
  408 failure with a direct pull, and the contract each side must keep.
- **trust-chain**: the four gates in order (edge, path token, event
  filter, API scope) and where each check must live.

## Interfaces and Contracts

### GitHub webhook (inbound contract)

- URL: `https://<P-2>/webhook/<P-3>`, POST only
- Valid push to watched ref: `200 {"status":"accepted",...}` in
  milliseconds, pull fires asynchronously
- Ping / unwatched ref / duplicate delivery: `200`, nothing enqueued
- Wrong token: `404`; blocked at edge: `403`

### Queue contract (receiver to worker)

- Redis list P-7; receiver RPUSHes, worker BLPOPs
- Message body is irrelevant (the image/tag are pinned by env); any
  string is a valid pull request

### Docker API contract (worker to proxy)

- `POST <P-8>/images/create?fromImage=<P-5>&tag=<P-6>`, empty body
- Timeout 10m, 3 retries at 1m spacing (capped 5m), nack re-queued

## Implementation Phases

### Phase 1: Deploy the scoped Docker API proxy

1. Follow the `docker-socket-proxy` schematic's phases 1-3 with the
   pull-only allowlist: `IMAGES=1`, `CONTAINERS=1`, `POST=1`.
2. Verification: its audit script shows exactly those groups ALLOWED.

### Phase 2: Create the dedicated tunnel

1. Create a Cloudflare Tunnel dedicated to this deployment; note P-1.
2. Add a public hostname `<P-2>` -> `http://connect:4195`.
3. If IPv6 egress exists, run the connector with `--edge-ip-version 6`
   (the edge has AAAA records; this keeps the tunnel off a broken v4 path).
4. Verification: the connector shows connected in the Zero Trust dashboard.

### Phase 3: Deploy the pipeline

1. Copy the skeleton: `compose.yml`, `config-webhook.yaml`,
   `config-pull.yaml`; create `.env` from `.env.example` filling
   P-1, P-3, P-4, P-5, P-6, P-9.
2. `docker compose up -d`.
3. Verification: all five containers running; `docker compose logs
   connect` shows the receiver listening on 4195; no container publishes
   a port.

### Phase 4: Register the webhook and prove end to end

1. Add the GitHub webhook: URL `https://<P-2>/webhook/<P-3>`,
   content type `application/json`, event: push.
2. Trigger a ping (GitHub sends one on save) and a real push.
3. Verification:
   - GitHub's delivery list shows 200 for both.
   - `docker compose logs puller` shows the
     `POST /images/create?fromImage=<P-5>&tag=<P-6>` request.
   - A second, duplicate delivery is a 200 with no second pull attempt
     (R-4) - verify via the receiver's `failed assignment` log lines and
     the worker's single POST.
   - `docker images <P-5>` shows the pulled tag.

## Verification and Acceptance

- **A-1** (R-1): `ss -tlnp` on the host shows no listener for this
  pipeline; the tunnel is the only path.
- **A-2** (R-2): `curl -s -o /dev/null -w '%{http_code}'
  https://<P-2>/webhook/wrong-token -X POST` returns 404.
- **A-3** (R-3): a valid push receives its 200 in under 2s (GitHub
  delivery detail shows the elapsed time).
- **A-4** (R-4): replaying the same delivery (GitHub "Redeliver") produces
  no second POST in the worker logs.
- **A-5** (R-5): the docker-socket-proxy audit shows only the pull-only
  groups allowed; `restart`/`exec` return 403.
- **A-6** (R-6): every image reference in the compose file carries
  `@sha256:` (the target image's tag is the registry's mutable branch tag
  by design).
- **A-7** (R-7): the redis container's command disables save and
  appendonly.
- **A-8** (R-8): with the socket proxy stopped, a push eventually
  re-queues and the pull succeeds once the proxy returns (worker nack
  path); no manual replay needed.
- **A-9** (R-9): `git ls-files` in the deployment shows `.env.example`
  but not `.env`.

## Failure Modes and Rollback

- **GitHub sees 408/timeouts**: the ack path is blocked - usually someone
  replaced the queue with a direct pull. Restore the queue wiring (read
  the ack-vs-pull module before touching timings).
- **Worker 403 from the proxy**: the allowlist lost a group; re-run the
  proxy's audit script, re-enable with justification.
- **Tunnel down**: webhooks fail at the edge; GitHub retries with
  backoff for up to a few hours. Fix the connector (`docker compose
  restart cloudflared`); missed pushes need a manual
  `docker compose pull <service>` or a re-push.
- **Registry auth failures on pull**: the proxy forwards daemon
  credentials; if the daemon cannot pull interactively, it cannot pull
  here either - fix `docker login` on the host.
- **Full rollback**: `docker compose down` on the pipeline; remove the
  GitHub webhook. The target service is untouched throughout - this
  pipeline pulls images, it never restarts anything.

## Removal

1. Delete the GitHub webhook.
2. `docker compose down` in the pipeline directory (in-memory queue: no
   state to preserve).
3. Remove the tunnel from Zero Trust if the hostname is retired.
4. The Docker API proxy goes only if no other consumer uses it; its own
   removal procedure applies then.

## Decisions and Open Questions

Decisions:

- 2026-09-10: Reverse-engineered from a production deployment
  (nostream-dev) that has run this exact pipeline since 2026-08-29. The
  redis queue is not a preference: the direct-pull variant was deployed
  first and failed with GitHub 408s within hours; the queue has not
  missed an ack since. Digest pinning and the internal IPv6 ULA subnet
  are carried over unchanged.
- 2026-09-10: The pull is deliberately NOT followed by a container
  recreate. Recreating the right service requires knowing which service
  maps to which image and preserving health-gated restart order - that is
  a separate deployment concern, and conflating it would push this
  pipeline from "pulls images" into "controls the daemon" (a much bigger
  security surface). An operator (or a later schematic) runs `docker
  compose up -d <service>` when appropriate.

Open questions:

- **Q-1**: Whether the worker should verify the pulled image's digest
  against a expected-digest file to detect registry tampering. Default:
  no - the registry trust model already covers it for public images;
  revisit for private registries with multiple writers.
