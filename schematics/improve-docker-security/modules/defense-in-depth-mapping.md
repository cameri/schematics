# Module: defense-in-depth mapping

Three siblings, one daemon, three different questions. This module is
the map that keeps the layers from being confused - or worse, assumed
redundant.

## The three questions

| Question | Layer | Mechanism |
|----------|-------|-----------|
| What may a container *ask* the daemon? | restrict-docker-api-access | Endpoint-group allowlist on an internal-network proxy |
| What may a *network client* make the daemon *do*? | authorize-docker-requests | OPA policy on the daemon's TLS listener |
| Where may credentials *rest*? | encrypt-container-secrets | SOPS + age, per-service keys, memory-only plaintext |

## Why two request layers (proxy AND policy) are not redundant

- The proxy sees only unix-socket-path requests from containers, and its
  granularity is the endpoint GROUP (containers, images, exec...).
- OPA sees only network-path requests, and its granularity is the
  operation's CONTENT (which container, which action, from which
  authenticated client).
- A container cannot reach the TLS listener without also passing the
  proxy's group check only if it goes through the proxy; a network
  client cannot reach the socket at all. The layers overlap only in the
  deployed topology you choose - document any overlap explicitly (R-6).
- Compromise stories: a malicious container with proxy access is bounded
  by the allowlist (no exec, no lifecycle). A stolen client cert is
  bounded by OPA policy. A leaked `.env` file is bounded by the
  per-service age key. Each story stops at a different layer.

## Ordering rationale (why secrets come second, policy last)

1. Access restriction first: it changes how consumers reach the daemon,
   and everything after builds on that topology.
2. Secrets second: converting a service is per-service and reversible;
   doing it before the policy layer means the eventual OPA sidecar and
   daemon config can also ride the encrypted-secrets pattern.
3. Policy last: it is the only step that can lock out operators (fail
   closed), so it goes in with everything else already verified, and its
   rollback line is tested the same day it is applied (A-5).

## The bypass to check for (R-6 in practice)

Any consumer that reaches the daemon NOT through the proxy and NOT
through the TLS listener - e.g. a leftover socket mount, or a container
on the host network with `/var/run/docker.sock` bind-mounted via a
different path - is a hole in all three layers at once. The
cross-verification phase greps for socket mounts after the proxy phase
for exactly this reason; re-run it last.
