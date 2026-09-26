# Module: load balancer cutover (advanced)

Responsibility: zero-downtime **single-relay** upgrades when a reverse proxy or
HAProxy fronts multiple relay backends. This module does **not** ship a full
blue/green compose file — it documents the **readiness contract** nostream
exposes so fleet layouts can be built separately.

## Inputs

- Two or more relay instances, load balancer using **`/readyz`**, **`P-2`**, **`P-3`**.

## Outputs

- Traffic shifted to healthy backend; draining backend returns 503 on **`/readyz`**.

## Idempotency

Cutover steps may be repeated per release; each instance keeps its own **`P-1`**.

## Failure behaviour

Routing traffic before green `/readyz` is 200 causes client errors. Probing
`/healthz` during drain sends traffic to a relay that rejects new WebSockets.

## Removal notes

Drain backends with `docker compose stop` before removing LB pool members; use
**`COMPOSE_PROJECT_NAME`** (**`P-20`**) when running `relay-verify.sh` against a
non-default project.

## When this applies

- Two or more relay instances behind HAProxy, nginx upstream groups, or cloud LB.
- Rolling image upgrades: new instance must pass **`/readyz`** before taking traffic.
- Graceful shutdown: old instance drains WebSockets while **`/readyz`** returns **503**.

Default single-host compose (**`P-12=loopback`**) does not need this module.

## Readiness contract (R-7, R-9)

| Endpoint | Healthy member | Draining / deps down |
|----------|----------------|----------------------|
| `/healthz` | 200 if process up | May still 200 while draining |
| `/readyz` | 200, dependencies OK | 503 when Postgres/Redis fail or relay draining |

Configure the load balancer **check** against **`/readyz`**, not `/healthz`.

Probe timeout should exceed the relay dependency ping timeout (~3s). Example
HAProxy: `timeout check 5s`.

On **SIGTERM**, the relay sets readiness to draining while the HTTP listener
stays up, rejects new WebSockets, and waits up to **`WS_DRAIN_TIMEOUT_MS`**
(default 30s). Compose **`stop_grace_period`** must exceed that (reference 45s).

## Cutover pattern

```
                    ┌──► relay-blue  (127.0.0.1:8008)  ── readyz OK ──► IN SERVICE
  clients ──► LB ───┤
                    └──► relay-green (127.0.0.1:8009)  ── readyz OK ──► STANDBY
```

Typical rolling upgrade:

1. Deploy green with new **`P-3`** on a **different loopback port** (operator
   parameter — not in the default skeleton).
2. Wait until green **`/readyz`** is 200.
3. Move LB backend weight to green.
4. Send SIGTERM to blue; wait until blue **`/readyz`** is 503 and connections drain.
5. Decommission blue or repoint it for the next release.

Each instance needs its own **`DEPLOY_ROOT`** and a distinct Compose project name
(for example `docker compose -p nostream-green up -d`). The skeleton omits
fixed `container_name` values so two stacks can coexist on one host. Postgres
(if not shared), and Redis (if not shared) stay per instance. **Shared Postgres
across blue/green on one host** is an advanced operator choice — not part of the
reference four-service stack.

## Relation to upstream fleet layouts

Upstream nostream documents HAProxy blue/green cutover and probe timeouts in
**[`deploy/README.md` — Health checks](https://github.com/cameri/nostream/blob/main/deploy/README.md#health-checks)**.
The repository also ships **`docker-compose.nginx.yml`** at the repo root as an
optional nginx front-end example. This module states the **`/readyz`** contract
those layouts rely on; it does not duplicate their compose files.

## Parameters used

`P-2`, `P-3`, `P-12`.
