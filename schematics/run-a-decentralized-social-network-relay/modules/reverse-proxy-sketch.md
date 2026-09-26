# Module: reverse proxy sketch

Responsibility: terminate TLS and forward HTTP + WebSocket to the relay on
`http://127.0.0.1:${P-2}` without publishing the relay on `0.0.0.0`. Use when
**`P-12=proxy`**.

## Inputs

- Relay on loopback **`P-2`**, public hostname **`P-10`**, **`P-11`** `info.relay_url`.

## Outputs

- TLS-terminated `https://` / `wss://` on one hostname forwarding to the relay.

## Idempotency

Proxy config reloads are safe; changing **`P-10`** requires updating **`P-11`** and
recreating the relay container.

## Hard rules

1. **One public hostname** for NIP-11 and WebSocket — must match **`P-10`**
   (`info.relay_url` uses `wss://…`; HTTP NIP-11 uses the same host over HTTPS).
2. **Upstream** is the relay on the **host** loopback: `127.0.0.1:${P-2}`, not
   the Docker service name. If the proxy runs **on the host**, use that address.
   If the proxy runs **in another container**, `127.0.0.1` inside that container
   is not the host — use `host.docker.internal:${P-2}` (Linux: add
   `extra_hosts: ["host.docker.internal:host-gateway"]`) or `network_mode: host`.
3. **WebSocket upgrade** must pass through; Nostr clients use `wss://` on `/`.
4. **Probe path** for load balancers: `GET /readyz` on the upstream (see
   `modules/exposure-and-health.md`), timeout ≥ 5s.

Replace **`relay.example.com`** with the hostname from **`P-10`** (without
`wss://`).

## Option A: Caddy (automatic HTTPS)

Install Caddy on the host. Example `Caddyfile`:

```caddy
relay.example.com {
    reverse_proxy 127.0.0.1:${RELAY_PORT:-8008}
}
```

Caddy handles TLS (Let's Encrypt) and WebSocket upgrades by default. Match the
port to **`P-2`** / `RELAY_PORT` in `${DEPLOY_ROOT}/.env` (substitute the
numeric port in the Caddyfile — Caddy does not read compose `.env` automatically).

Verify:

```bash
curl -sS -H 'Accept: application/nostr+json' https://relay.example.com/
curl -sS https://relay.example.com/readyz
```

## Option B: nginx

Example server block (TLS certificate paths are distribution-specific):

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name relay.example.com;

    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${RELAY_PORT:-8008};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

Reload nginx after `nginx -t`. Long timeouts reduce idle WebSocket disconnects.

## Option C: Cloudflare Tunnel

When the relay must not receive a public IP on the host:

1. Run `cloudflared` on the host with a tunnel to `http://127.0.0.1:${P-2}`.
2. Map a public hostname in the Cloudflare dashboard to that tunnel.
3. Enable WebSocket support for the hostname (Cloudflare proxy orange-cloud).

**`P-10`** must use that hostname. Confirm NIP-11 and `wss://` from an
external network (acceptance **A-4**).

## Option D: tailnet only

For **`P-12=tailnet`**, prefer schematic
**expose-container-services-privately** instead of a public reverse proxy.
Clients use **`wss://<name>.<tailnet>`** for Nostr WebSocket and
**`https://<name>.<tailnet>`** for NIP-11 over HTTP; set **`P-10`** /
`info.relay_url` to the `wss://` form. Keep the relay on loopback upstream.

## Common failures

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| NIP-11 OK, WebSocket fails | Missing `Upgrade` headers | Use Option A or B headers |
| Wrong relay name in clients | `info.relay_url` ≠ public host | Edit **`P-11`** and recreate relay |
| 502 after deploy | Relay draining | Wait for drain; LB should use `/readyz` |
| TLS cert wrong host | DNS not pointing at proxy | Fix A/AAAA before ACME |

## Parameters used

`P-2`, `P-10`, `P-11`, `P-12`.
