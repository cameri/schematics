# Module: exposure-and-health

Responsibility: who can reach the relay HTTP/WebSocket port and how probes behave.

## Default posture (R-5)

Skeleton publishes:

```yaml
ports:
  - 127.0.0.1:${RELAY_PORT:-8008}:${RELAY_PORT:-8008}
```

Only local processes and reverse proxies on the same host can connect. Public
Internet reachability requires **Phase 7** (`P-12`).

## Health endpoints

| Path | Type | Use |
|------|------|-----|
| `/healthz` | Liveness | Restart if process hung but listener up |
| `/readyz` | Readiness | Load balancer member up/down; checks Postgres + Redis |

Configure upstream probe timeout **above** dependency ping timeout (~3s default)
so slow-but-healthy backends do not flap.

On **SIGTERM**, relay may return `/readyz` **503** with `"status":"draining"`
while finishing WebSocket drain (`WS_DRAIN_TIMEOUT_MS`, default 30s). Compose
`stop_grace_period` must exceed drain (reference: 45s).

## Exposure patterns (`P-12`)

| Mode | Pattern |
|------|---------|
| `loopback` | Local clients, SSH tunnel, dev only |
| `proxy` | nginx/Caddy/HAProxy → `http://127.0.0.1:P-2`, TLS at edge, WebSocket upgrade |
| `tailnet` | `expose-container-services-privately` or Tailscale serve to loopback upstream |

Concrete proxy configs: `modules/reverse-proxy-sketch.md`. Multi-instance cutover:
`modules/load-balancer-cutover.md`.

NIP-11 and WebSocket must share the **same public hostname** clients use
(`P-10`).

## Admin and metrics

`/admin` and Prometheus endpoints are optional settings features — not part of
default acceptance. Keep admin off until `SECRET` and `ADMIN_PASSWORD` are set.
