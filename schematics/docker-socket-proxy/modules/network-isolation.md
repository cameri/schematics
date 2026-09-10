# Module: network isolation

The proxy speaks plain HTTP on port 2375 with no authentication. That is
safe only under a strict network posture, which this module states as
invariants. Breaking any one of them turns the proxy into a root-equivalent
daemon endpoint.

## Invariants

1. **No published ports.** The proxy service never appears in a `ports:`
   block. Verify with `docker port socket-proxy` (empty) and by the absence
   of `HostPort` entries in `docker inspect`.
2. **Internal-only attachment.** The proxy attaches only to the compose
   project's internal network (P-5). Consumers reach it by service name.
3. **Single client intent.** If only one container should call the API, do
   not rely on discipline: an internal bridge network already blocks
   everything off-host, but any container ON the network can call the
   proxy. Keep the network's membership minimal; never attach general
   application containers to it "temporarily".
4. **Read-only socket.** The daemon socket is mounted `:ro` into the proxy.
   The proxy only forwards; a compromised proxy still cannot chmod or
   replace the socket.

## Why HTTP-without-auth is acceptable here

The Docker daemon's socket is equally unauthenticated - the proxy does not
weaken the daemon, it narrows what a caller can reach. The threat being
addressed is accidental or partial trust (a tool that needs one read
getting the full daemon), not a malicious actor already inside the
compose network. If untrusted containers must share the network, add
authentication as a separate layer (mTLS terminator in front of the
proxy, or an allowlist keyed on source IP in HAProxy) rather than
widening this module's guarantees.

## Failure posture

- Proxy down: consumers fail with connection refused (loud, immediate).
- Proxy misconfigured wider than intended: caught by the audit script
  (R-8), not by luck.
- Host firewall changes do not matter: no host port is ever open.
