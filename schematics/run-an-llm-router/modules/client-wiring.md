# Module: Client Wiring

The half of this capability that lives outside the router: what a client must
be told, how it reaches the router, and how the operator proves the client is
actually using it.

## Purpose

Owns the contract between the router and anything that consumes inference —
the base URL, the credential, the alias ids, and the reachability path when the
client is not a container on the router's network. It is **not** responsible
for running the router (`router-service.md`) or for what the router serves
(`model-aliases.md`).

## Inputs

- `P-13 ROUTER_BASE_URL`: what the client sets as its OpenAI-compatible base
  URL. Inside the router network it is
  `http://<P-1 ROUTER_SERVICE_NAME>:<P-2 ROUTER_PORT>/v1`.
- `P-7`: the router credential the client presents (the *value* is in the
  store; the client receives it through whatever secret mechanism it already
  uses).
- `P-10 ALIAS_SET`: the alias ids the client may send.
- `P-12 EXPOSURE_HOSTNAME`: present only when clients are off-host (Phase 8).

Error inputs it must tolerate: the router being unreachable, a rejected
credential, and an alias the client sends that the map does not contain.

## Outputs

- A client configuration that resolves every model role the client needs to an
  alias on this router — and to nothing else (R-11).
- Client-side model metadata where the router's registry lacks it: token
  limits and context window are often a client concern, not a router one.
  Where the router cannot report them, declare them next to the alias in the
  client's own model list.
- A verification trail: A-10 (a real completion through the client) and A-11
  (the client fails loudly when the router is down).

## The Wire Contract

Plain OpenAI-compatible HTTP. A client needs exactly three facts:

| Fact | Value |
|---|---|
| Base URL | `P-13` (the router's `/v1`) |
| Credential | the router's own credential (`P-7`'s value), presented as `Authorization: Bearer <credential>` on every request |
| Model id | an alias from `P-10`, sent as the `model` field |

Because the surface is the standard one, any client that already speaks an
OpenAI-compatible API works without a router-specific integration — and the
client keeps the same base URL, credential, and alias ids when a provider
changes behind an alias (R-8).

## Reachability

| Client location | Path | Notes |
|---|---|---|
| Same Docker host | Join `P-11 ROUTER_NETWORK`; use the in-network base URL | Default. No port published on the host, nothing to firewall |
| Another host on a private network | A private path the operator already runs (tailnet, VPN, or a reverse proxy on that network) fronting the router | `P-12` names the hostname; the router itself stays unpublished (R-6) |
| Public internet | Not supported by this schematic | Exposing a BYOK gateway publicly publishes a metered surface and a credential-guessing target. If it is ever needed, that is a deliberate, separate design with its own rate limits and key issuing |

When a reverse proxy is used, the proxy's route points at the router's service
name and port on `P-11` — the same in-network URL, sourced from a second
network the proxy also joins.

## Failure Behavior

| Condition | Behavior |
|---|---|
| Router unreachable (DNS, network, exposure misconfigured) | Every request fails at the client. It MUST surface as failure, not as a silent switch to another provider (R-11) — that switch is exactly what this capability exists to remove |
| Wrong credential | 401 on every request; the router's own log names the rejected credential |
| Alias not in the map | Per-request error for that alias; other aliases keep serving |
| Client sends a parameter the bound provider ignores | Dropped by the router (R-9); the client keeps working unchanged |
| Client host cannot resolve `P-12` | The private path (proxy/tailnet/VPN) is not in place for that host — a path problem, not a router problem. Confirm with A-9 before touching the router |

## Idempotency Notes

Client wiring is configuration only: re-applying it converges. Two orderings
matter:

1. Wire a client **after** A-1 passes — otherwise the client's error state and
   the router's startup problem are indistinguishable.
2. When replacing an existing provider with this router, remove the old
   provider from the client **in the same change** (R-11). Leaving it as a
   fallback reintroduces the dependency this capability removes, and the
   fallback only shows itself when the router is down.

Completion detection is A-10 (a real completion) plus A-11 (the loud failure).

## Removal Notes

Adds: a provider entry (base URL, credential, alias list) in each client's
configuration. Removing the router means pointing each client back at whatever
it used before — or at nothing, if the router *replaced* a metered provider and
there is nothing to go back to. Client-side model metadata (token limits) is
the operator's to keep; it is not router state.
