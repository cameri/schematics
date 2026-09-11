# Module: exposure options

The decision table lives in `serve-books-using-containers`'s module of
the same name (local / tailnet / tsdproxy / cloudflare, with the
shared-vs-dedicated tunnel rule). This package reuses it wholesale and
records only what differs here:

- **Default differs**: production for this stack runs a gated public
  hostname (Cloudflare with edge auth), while the book stack defaults to
  tailnet. P-2 exists either way; the default is the operator's call.
- **The shared-tunnel rule is identical**: a read-only, stateless
  serving service is fine on a shared remotely-managed tunnel; anything
  with an inbound contract (webhooks, sync push) must move to a
  dedicated tunnel.
- **The negative control is identical**: for local/tailnet/tsdproxy, a
  public probe must time out entirely; for cloudflare, an
  unauthenticated fetch must hit the Zero Trust login, never the server.
