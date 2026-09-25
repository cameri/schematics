# Module: load balancer cutover (advanced)

Responsibility: zero-downtime **single-relay** upgrades when a reverse proxy or
HAProxy fronts multiple relay backends. This module does **not** ship a full
blue/green compose file — it documents the **readiness contract** nostream
exposes so fleet layouts can be built separately.

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

Each instance needs its own **`DEPLOY_ROOT`** or compose project name, Postgres
(if not shared), and Redis (if not shared). **Shared Postgres across blue/green
on one host** is an advanced operator choice — not part of the reference
four-service stack.

## Relation to upstream HAProxy compose

Nostream may publish a separate **`docker-compose.haproxy.yml`** for fleet
operators. Treat that file as an optional extension: the probes and drain
behaviour in this module still apply.

## Parameters used

`P-2`, `P-3`, `P-12`.
