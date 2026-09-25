# Module: exposure-and-clients

How phones and browsers reach the instance, what each exposure option requires,
what the first visitor is allowed to do, and the client facts that are easy to
discover late.

## Purpose

This module owns the seam between the running stack and the network: which of the
four exposure options is in use, what each requires from the host, and the rules
that keep the library private while it is reachable from a phone. It is NOT
responsible for installing a tunnel or proxy — a tailnet vehicle is a capability
of its own (`expose-container-services-privately` covers that) — and it does not
touch the files or the database.

## Inputs

- `EXPOSURE` — `private`, `localhost`, `tsdproxy`, or `cloudflare` — and
  `IMMICH_TRUSTED_PROXIES` when a proxy fronts the server.
- `HTTP_PORT`, the port the server listens on inside the container.
- An existing private network, tailnet, proxy, or tunnel, when the chosen option
  needs one.
- `IMMICH_ALLOW_SETUP`, and an administrator account created before exposure.

## Outputs

- The server reachable from exactly the vantage the option declares.
- One environment value the proxy path implies: `IMMICH_TRUSTED_PROXIES`, so the
  server attributes requests to clients rather than to the proxy.
- No other service reachable from anywhere: the database and the cache are on
  the Compose network only, and the machine-learning service listens on it.

## Dependencies

- D-8 (tailnet, proxy, or tunnel) — optional, and only for options B, C, and D.
- P-14, P-15, P-16.

## The four options

| Option | What it does | Requires | What it exposes |
|--------|--------------|----------|-----------------|
| `private` (default) | Attaches the server to an existing private network and publishes nothing | A network that already exists, or a decision to reach the instance over the LAN | Nothing beyond that network; clients on the LAN reach the host's address and the container port |
| `localhost` | Publishes the port on the loopback interface only | Nothing | Nothing off the host; useful for the first setup and for a host-local reverse proxy |
| `tsdproxy` | Attaches to the tailnet proxy's network with a hostname label | A running tailnet proxy | The tailnet, with automatic HTTPS, one hostname per service |
| `cloudflare` | Attaches to a tunnel's network with an ingress hostname | A tunnel and a Zero Trust policy | The public internet, gated by the policy at the edge |

The default is the first row. Choosing a public hostname is a deliberate upgrade
with its own requirements, not the starting point: the instance holds a family's
photographs, and the cost of being wrong is other people's pictures.

## Requirement under every option

- The database, the cache, and the machine-learning service MUST NOT be
  published, whatever the option. Only the server has a client-facing surface.
- HTTPS is required as soon as the instance leaves a trusted local network,
  because the mobile applications send credentials. The default security headers
  upgrade browser requests to HTTPS, so an HTTP-only deployment shows a broken
  page until the alternative header configuration is used; TLS is the better
  answer.
- The first administrator MUST exist before the instance is reachable by anyone
  else. Until an account exists, the sign-up endpoint is open to whoever finds
  the URL, and the instance has no notion of "the owner" to fall back on.
- `IMMICH_TRUSTED_PROXIES` MUST be set when a proxy is in front, or every request
  appears to come from the proxy's address, which defeats per-client rate
  limiting and fills the log with one address. `inferred:` the exact failure
  shape; the variable and its meaning are documented upstream.

## Failure Behavior

- **The instance is reachable from the LAN but not from a phone on mobile data.**
  Expected under `private` and `localhost`. If a hostname option was chosen, the
  tunnel or proxy attachment is the thing to check, not the stack: the server
  never changes.
- **The UI loads over plain HTTP but the page is blank or will not submit.** The
  security headers are upgrading requests to HTTPS. Terminate TLS at the proxy,
  or serve the alternative security-header configuration.
- **Everything works but rate limits trip early, or the log shows a single client
  address.** `IMMICH_TRUSTED_PROXIES` is unset or does not match the proxy's
  network.
- **A stranger asks for an account, or has one.** The sign-up endpoint was open
  when they arrived. Close it (`IMMICH_ALLOW_SETUP=false`) and review the user
  list; this is why the first-administrator rule is a requirement and not a step
  in a checklist.
- **The hostname still points at a previous deployment.** The tunnel or proxy
  serves the old target; the stack is fine. Check the ingress rule, then the
  stack.

## Idempotency Notes

- Changing `EXPOSURE` is a compose edit plus a recreate of the server service; it
  adds or removes a network attachment and, for `localhost`, a published port. No
  data changes.
- Re-running the exposure phase with the same option is a no-op.
- The environment values take effect on recreate, not on restart: the
  configuration is read when the container is created.

## Removal Notes

Removing the exposure attachment leaves the stack running and the data untouched:
drop the port publication, the network attachment, or the ingress hostname, in
the one place the chosen option put it. Nothing in this module writes to the
host except the compose file and the environment file.
