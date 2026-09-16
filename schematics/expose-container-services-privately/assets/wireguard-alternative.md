# Research Note: Self-Hosted WireGuard + Reverse Proxy as an Alternative to Managed Tailscale + TSDProxy

**Question answered:** can the *same private exposure* (local services
reachable by name from only your devices, no public ports) be built
self-hosted with WireGuard + a reverse proxy (Caddy, Traefik, HAProxy,
NGINX)?

**Short answer: yes, with two different shapes and one honest caveat.**
The reverse-proxy half of the stack is transport-agnostic — any of those
proxies routes by hostname over any private tunnel. What managed Tailscale
actually buys you is a set of control-plane features (identity, NAT
traversal, DNS, TLS automation) that a bare WireGuard tunnel does not
include and you must rebuild. The caveat: "self-hosted" splits into
*keep the Tailscale client, self-host the control server* (Headscale) and
*no Tailscale at all, plain WireGuard everywhere* — different cost curves,
same privacy goal.

---

## 1. What each layer is made of

| Layer | Managed Tailscale + TSDProxy (this package) | Self-hosted shape A: Headscale + TSDProxy | Self-hosted shape B: plain WireGuard + reverse proxy |
|---|---|---|---|
| Data transport | WireGuard, via the Tailscale client (tsnet) | Same — the client is the client | WireGuard directly (kernel module or userspace) |
| NAT traversal | magicsock: NAT hole-punching with DERP encrypted relays as fallback | Same magicsock/DERP (DERP or your own relay) | None built in — peers need a reachable endpoint (public IP, port-forward, or a VPS relay) |
| Coordination server | Tailscale SaaS (controlplane.tailscale.com) | Headscale (self-hosted) | None — static config files per peer |
| Identity/auth | Tailscale account, SSO, auth keys, ACLs | Headscale user + pre-auth keys | Curve25519 key pairs + optional pre-shared keys |
| DNS | MagicDNS: every node gets `<name>.<tailnet>` | Headscale's DNS integration | You provision it: hosts files, split-horizon DNS, or a DNS-over-tunnel service |
| TLS certs | Automatic HTTPS: control plane does a DNS-01 challenge for `<name>.<tailnet>` with Let's Encrypt | Varies by control-server version; cert automation often still your job | Your job: internal CA (Caddy internal CA, step-ca), mTLS, or public LE only for publicly resolvable names |
| Reverse proxy | TSDProxy (Tailscale-aware, creates a node per hostname) | TSDProxy against the Headscale control URL (tsdproxy supports `controlUrl` override) | Any of Caddy/Traefik/HAProxy/NGINX on the host doing vhost routing |
| Reverse tunnel (clients behind NAT reaching the server) | Built in: DERP relays + hole punching, server is just another node | Same | Requires at least one publicly reachable WG endpoint (VPS or port-forward); without it, clients on strict NAT cannot reach the host |

---

## 2. Shape B in practice: plain WireGuard + reverse proxy

Feasible and production-real for a fixed device fleet. The build:

1. **Tunnel**: install WireGuard on the host (the proxy/tunnel machine).
   Give each client a peer config: host's public key, client's own key
   pair, a private subnet (e.g. `10.99.0.0/24`, clients `.1`+). The host
   needs a reachable endpoint: a public IP, a port-forward on the router,
   or a cheap VPS as a relay (WG peers can route *through* a relay hub).
   Clients behind strict NAT add `PersistentKeepalive = 25` so the tunnel
   stays up.
2. **Proxy**: run Caddy, Traefik, HAProxy, or NGINX on the host, bound to
   the WG interface (or all interfaces with a firewall rule allowing only
   the WG subnet). Each vhost = one service. This is exactly what TSDProxy
   does — the proxy layer is not the differentiator.
3. **DNS**: this is the biggest unmanaged gap. MagicDNS is the feature
   that turns `http://app1` into a name every device can type. On bare WG
   you either edit `/etc/hosts` on every client, run a split-horizon DNS
   server (dnsmasq/CoreDNS) on the tunnel, or use short WG IPs. Any of
   these is fine; all are manual.
4. **TLS**: three honest options:
   - **Public LE certs** only if the hostname is publicly resolvable
     (DNS-01 challenge) — contradicts "private" if you care about name
     leakage, and needs a domain you control.
   - **Internal CA** (Caddy's internal CA, step-ca, mkcert): trusted
     certs, no public ledger, but you must install the CA on every
     client. This is the private equivalent of automatic HTTPS.
   - **mTLS** (mutual TLS): the proxy requires a client certificate from
     the same CA — strongest posture (only devices holding a client cert
     can even open the service). Good fit when clients are managed devices.
5. **Auth**: WG's credential model is static key pairs — no user directory,
   no ACLs, no revocation beyond "delete the peer config". Fine for a
     small trusted fleet, painful at scale.

Yes on the feasibility question; the effort is concentrated in DNS, TLS
distribution, and NAT reachability — exactly the three things the managed
control plane automates.

---

## 3. Shape A: Headscale — self-hosted control plane, same client

The middle path that often gets missed. TSDProxy's `controlUrl` setting
points at any Tailscale-compatible control server, including Headscale.
You keep:

- the Tailscale client's entire data plane — magicsock hole-punching and
  DERP fallback, so clients behind NAT still reach the host without VPS
  relays;
- tsdproxy's per-hostname node creation and automatic-HTTPS intent;
- identity/auth under your control (Headscale users, pre-auth keys).

You give up: the SaaS convenience surface (admin console, SSO, managed
MagicDNS/HTTPS plumbing — Headscale integrates DNS but TLS-cert automation
quality varies by version). OAuth is documented as SaaS-only in tsdproxy
(`clientId`/`clientSecret` is a managed-Tailscale feature — with Headscale
you use auth keys). This shape is the closest self-hosted analogue of the
managed stack and the least reinvention.

---

## 4. Decision matrix

| You care about | Managed Tailscale + TSDProxy | Headscale + TSDProxy | WireGuard + reverse proxy |
|---|---|---|---|
| Zero ops for NAT, DNS, TLS | best | good (some self-host ops) | DIY |
| No third-party control plane | ✗ (SaaS) | ✓ | ✓ |
| No third-party *data* relay (DERP) | ✗ (DERP relays) | partial (run your own or DERP) | ✓ (if endpoints reachable) |
| Scale to many devices/users | best (SSO, ACLs) | good | worst (static configs) |
| Full control of identity/auth | ✗ | ✓ | ✓ |
| Fixed small fleet, LAN-mostly, managed clients | fine | fine | best value |
| Public-name privacy (no LE/CT leakage of hostnames) | ✗ (CT logs `*.ts.net` names) | depends on TLS path | ✓ with internal CA/mTLS |
| Compatibility with tsdproxy / schemaformat.ai catalog | ✓ native | ✓ via `controlUrl` | n/a — swap proxy layer for a general proxy |

---

## 5. Verdict for this schematic

- **Is it feasible self-hosted? Yes.** Both shapes satisfy the same private
  exposure contract: private names, no public ports, reverse proxy in
  front of local services.
- **The honest recommendation**: for anyone already inside the Tailscale
  ecosystem (this schematic's audience), managed Tailscale + TSDProxy
  remains lowest-ops: the features that are painful to self-host (NAT
  traversal, MagicDNS, automatic HTTPS) are exactly what the managed
  control plane provides, and the cost is control-plane and relay
  dependence. Choose **Headscale + TSDProxy** when the control plane must
  be self-hosted (compliance, isolation, no-SaaS) while keeping the data
  plane's traversal magic. Choose **plain WireGuard + reverse proxy**
  when the fleet is small and fixed, endpoints are reachable (or a small
  relay VPS is acceptable), and you will invest in CA/DNS tooling — the
  only shape with zero third-party dependency anywhere in the path.

- **Not rebuilt here**: this package deliberately implements only the
  managed path (Decision in SCHEMATIC.md). A Headscale variant is a
  small delta (`controlUrl` + auth key per the tailscale-auth module);
  a plain-WireGuard variant is a separate package, not a parameter.

---

### Sources

- WireGuard protocol & primitives (connectionless protocol, key
  handshakes, keepalives, no traversal built in): wireguard.com/protocol
- Tailscale DERP servers (relay purpose, NAT-traversal fallback,
  encrypted forwarding): tailscale.com/kb/1232/derp-servers
- Tailscale HTTPS certificates (Let's Encrypt DNS-01 via tailnet name,
  CT ledger exposure of `<name>.<tailnet>`): tailscale.com/kb/1153/enabling-https
- TSDProxy: docker/lists providers, label contract, health checks:
  almeidapaulopt.github.io/tsdproxy (providers/docker, providers/lists)
- TSDProxy Headscale control-server support and OAuth-is-SaaS note:
  tsdproxy docs advanced/headscale
- Headscale (self-hosted Tailscale-compatible control server): headscale.net
- Caddy automatic HTTPS and internal CA: caddyserver.com/docs/automatic-https

*Research note authored 2026-09-14 alongside the schematic this package
ships. Facts about third-party products (DERP topology, Headscale's TLS
capabilities, WG NAT behavior) are stated at the pinned-version level;
re-verify against the products' docs when the pinned versions move.*