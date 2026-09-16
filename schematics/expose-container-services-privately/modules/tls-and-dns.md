# Module: TLS and DNS

The observable promise of this schematic is `https://<name>.<TAILNET>`
working from any tailnet device. Two tailnet features make that true, and
this module says what each is, how to verify it, and what degrades when it
is off.

## The two features

1. **Tailnet name resolution (MagicDNS on managed Tailscale; equivalent on
   self-hosted control servers)**: every node registers a name; the
   control plane serves DNS to tailnet clients. `<name>` → the proxy's
   tailnet address. Without it, clients have no name to type — they would
   need raw tailnet IPs and hosts entries.
2. **Automatic HTTPS (managed Tailscale: "HTTPS Certificates" in admin
   console → DNS)**: lets a node obtain a valid Let's Encrypt certificate
   for its `<name>.<tailnet>` FQDN via the control plane's DNS challenge.
   TSDProxy requests these certificates itself for every hostname it
   proxies (upstream: "Automatic HTTPS"). Certificate Transparency means
   the FQDN appears in public cert logs — the tradeoff inherent to
   managed TLS, stated in the decisions section of SCHEMATIC.md.

## Parameter interplay

- P-2 `auto`: the proxy requests a certificate per hostname; R-2's
  assertion is `https://<name>.<TAILNET>` with a chain browsers trust.
- P-2 `off`: no TLS in front of services; R-2 degrades to
  `http://<name>` on the tailnet. The tailnet transport is still
  encrypted (WireGuard-based data plane — see the research note), so this
  is "no TLS on the proxy hop", not "no encryption on the wire".
- Self-hosted control servers: whether automatic HTTPS exists at all
  depends on the control server's TLS integration (they vary; Headscale's
  story is a moving target — check its docs for the pinned version).
  Managed Tailscale is the only target this package assumes for `auto`.

## Verifying (A-2)

```sh
curl -fsSI https://<name>.<TAILNET>          # exits 0, shows the service's headers
curl -fsSI https://<name>.<TAILNET>/ | grep -i '^HTTP/'   # 2xx/3xx from the service
echo | openssl s_client -connect <name>.<TAILNET>:443 2>/dev/null |
  openssl x509 -noout -ext subjectAltName     # lists <name>.<TAILNET>
```

## Failure behavior

- HTTPS feature disabled on the tailnet but P-2 `auto`: the proxy's cert
  requests fail (log lines about certificate/DNS challenge); services
  remain reachable over plain HTTP on the tailnet — set P-2 `off` to make
  expectations match reality.
- MagicDNS disabled: hostnames stop resolving on clients; the proxy itself
  still registers with the control plane. Either enable MagicDNS or
  document raw-IP access (out of scope for this package's contract).
- Certificate rate limits (Let's Encrypt): many rapid hostname add/re-add
  cycles can trip them; the proxy retries with backoff. Recreating a node
  from scratch re-issues its certs — avoid churning hostnames in tests.

## Idempotency Notes

Certificate issuance is convergent: re-running adds/restarts converges to
the same valid certs; verification commands are read-only and deterministic.

## Removal Notes

Nothing host-side to remove — certificates live in the proxy's P-8 state
and are deleted with the node when a hostname is removed (see
exposure-contracts).