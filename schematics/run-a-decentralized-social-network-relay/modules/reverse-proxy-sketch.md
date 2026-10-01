# Module: reverse proxy sketch

Responsibility: terminate TLS and forward HTTP + WebSocket to the relay on
the host without publishing the relay on `0.0.0.0`. Use when **`P-12=proxy`**.

## Inputs

- Relay on host loopback **`P-2`**, public hostname **`P-10`**, **`P-11`** `info.relay_url`.

## Outputs

- TLS-terminated `https://` / `wss://` on one hostname forwarding to the relay.

## Idempotency

Proxy config reloads are safe; changing **`P-10`** requires updating **`P-11`** and
recreating the relay container.

## Failure behaviour

Misconfigured TLS or missing WebSocket headers surface as client disconnects or
502 from the proxy; the relay may still pass **`/readyz`** on loopback — test both
proxy URL and `http://127.0.0.1:P-2` when debugging.

## Removal notes

Remove proxy vhost/tunnel routes before `docker compose down`; clients must not
resolve **`P-10`** to this host after removal (see schematic Removal).

## Hard rules

1. **One public hostname** for NIP-11 and WebSocket — must match **`P-10`**
   (`info.relay_url` uses `wss://…`; HTTP NIP-11 uses the same host over HTTPS).
2. **Host proxy (recommended):** upstream is `127.0.0.1:<port>` where `<port>` is
   **`P-2`** / `RELAY_PORT` from `${DEPLOY_ROOT}/.env`. Examples below use **8008**
   — substitute your port if not default.
3. **Container proxy:** the reference skeleton publishes the relay on **host
   loopback only** (`127.0.0.1:P-2`). A proxy on a Docker bridge network **cannot**
   reach that bind via `host.docker.internal` or the bridge gateway (connection
   refused). Use a **host-installed** proxy (Options A–C), tailnet exposure
   (Option D), or run the proxy in the **same compose project** with upstream
   `http://nostream:<port>` by service name (custom compose, deviates from default
   R-5 layout).
4. **WebSocket upgrade** must pass through; Nostr clients use `wss://` on `/`.
5. **Probe path** for load balancers: `GET /readyz` on the upstream (see
   `modules/exposure-and-health.md`), timeout ≥ 5s.

Replace **`relay.example.com`** with the hostname from **`P-10`** (without
`wss://`).

## Option A: Caddy (automatic HTTPS)

Install Caddy **on the host**. Example `Caddyfile` (replace **8008** if **`P-2`**
is not 8008):

```caddy
relay.example.com {
    reverse_proxy 127.0.0.1:8008
}
```

Caddy handles TLS (Let's Encrypt) and WebSocket upgrades by default.

Verify:

```bash
curl -sS -H 'Accept: application/nostr+json' https://relay.example.com/
curl -sS https://relay.example.com/readyz
```

## Option B: nginx

Install nginx **on the host**. Example server block (replace **8008** if needed;
TLS paths are distribution-specific):

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
        proxy_pass http://127.0.0.1:8008;
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

Reload nginx after `nginx -t`.

## Option C: Cloudflare Tunnel

When the relay must not receive a public IP on the host:

1. Run `cloudflared` **on the host** with a tunnel to `http://127.0.0.1:8008`
   (or your **`P-2`**).
2. Map a public hostname in the Cloudflare dashboard to that tunnel.
3. Enable WebSocket support for the hostname (Cloudflare proxy orange-cloud).

**`P-10`** must use that hostname. Confirm NIP-11 and `wss://` from an
external network (acceptance **A-12**).

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
| Proxy in Docker cannot connect | Loopback-only publish (R-5) | Host proxy or same-compose upstream |

## Parameters used

`P-2`, `P-10`, `P-11`, `P-12`.
