# Module: trust chain

Four gates stand between the internet and the Docker daemon, in the order
a request meets them. Each gate lives where it can actually see the
signal it checks - a check placed at the wrong layer is decoration.

## Gate 1: Cloudflare edge

- The hostname is proxied and the origin is reachable only through the
  tunnel connector: the host opens no ports for this pipeline (R-1).
- Optional hardening: a WAF custom rule restricting `/webhook/*` to
  GitHub's webhook source ranges (from `https://api.github.com/meta`,
  key `hooks`; verified 2026-08-29: `192.30.252.0/22`,
  `185.199.108.0/22`, `140.82.112.0/20`, `143.55.64.0/20`,
  `2a0a:a440::/29`, `2606:50c0::/32`).
- Placement rule: the source-IP check MUST live in Cloudflare. Through
  the tunnel the origin sees Cloudflare as the client; GitHub's real IP
  arrives in `CF-Connecting-IP`, which an origin-side IP filter would
  miss.

## Gate 2: path token

- The webhook URL path carries a 32-byte random token (P-3,
  `openssl rand -hex 32`): `https://<host>/webhook/<token>`.
- Wrong path -> 404 from the receiver's http_server. The token is a
  capability: treat the full webhook URL as a secret, never log it.

## Gate 3: event filter and dedup

- Only `push` events for `refs/heads/<P-4>` proceed. Ping events,
  other events, and other refs are answered 200 with nothing enqueued.
- The `X-Github-Delivery` header dedups through an in-memory cache add:
  GitHub's retry-on-timeout becomes a no-op (R-4).

## Gate 4: scoped Docker API

- The worker reaches the daemon only through a deny-by-default socket
  proxy (R-5): `IMAGES=1`, `CONTAINERS=1`, `POST=1`, nothing else, socket
  mounted read-only, no published ports.
- Compromise of the receiver (the internet-facing component) yields
  control of neither the daemon nor the host: the receiver cannot even
  reach the proxy (different network position, and it never touches
  Docker), and the worker's reach is exactly the pull-only group list.

## What this chain does not defend against

- A leaked webhook URL plus a valid push payload shape can enqueue pulls
  of whatever the watched image/tag are - pulls only, and of the pinned
  image, so the blast radius is "cause an image re-pull".
- Compromise of the Cloudflare account defeats gates 1 and 2; gate 4
  still bounds the damage to image pulls.
