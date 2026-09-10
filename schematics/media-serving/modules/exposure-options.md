# Module: exposure options

Three vehicles can put the server on a hostname or a tailnet. The
parameter P-2 picks one; this module is the decision table and the one
hard rule that separates the options.

| Option | What it exposes | Operator burden | Public? | Hard rule |
|--------|-----------------|-----------------|---------|-----------|
| A: tailscale (default) | The tailnet only, via the host's tailscale | None if a tailnet exists | No | Bind/publish to the tailnet IP or don't publish at all |
| B: tsdproxy | A DNS name, but reachable only by tailnet identities | A tsdproxy deployment + one mapping | Not to the public; identity-gated | Origin connection stays host-local |
| C: cloudflare tunnel | A real public hostname | A tunnel + Zero Trust app policy | Yes, but gated | Edge auth MUST gate the hostname (R-4); ABS login is the second factor |

## When shared tunnels are acceptable

A remotely-managed (shared) Cloudflare tunnel load-balances across
connectors and replicas. That is harmless for a read-only, stateless
service: any replica can serve any request. It is FATAL for anything
with a stateful inbound contract (webhooks: a request can land on the
connector while its queue is on another). Hence:

- media-serving (this schematic): shared tunnel is acceptable in
  production and is what production actually runs.
- webhook-style inbound endpoints: dedicated tunnel, no exceptions.

If a future consumer of this stack adds an inbound contract (e.g. a
sync push from a phone app through the tunnel), that hostname must move
to a dedicated tunnel; the exposure-options decision for THAT consumer
must be revisited.

## Choosing in one question

"Who should reach this?" - only you, on your devices: A. You plus
family/users with identities: B. Anyone with a link plus a login wall:
C (with the R-4 policy). The cost of choosing wrong is low for A/B and
higher for C; when unsure, pick A and upgrade later - the compose delta
is one line.
