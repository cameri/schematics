# Module: Model Aliases

The alias → provider map: the only part of the router a client ever names.

## Purpose

Owns the model surface — which ids clients may send, which provider and
upstream model each one resolves to, and what happens when a client asks for
something that is not there. It is **not** responsible for the credentials
behind those providers (`provider-credentials.md`), for the HTTP transport
(`router-service.md`), or for what clients do with the responses
(`client-wiring.md`).

The alias is the schema of this capability, and it is where the router earns
its keep: a client names `alias-1` and keeps naming `alias-1` while the
provider, the upstream model id, or the whole provider family behind it
changes (R-8).

## Inputs

- `P-4 CONFIG_PATH`: one `model_list` entry per alias (format in
  `skeleton/config.example.yaml.schema`).
- `P-10 ALIAS_SET`: the aliases the operator has decided to serve.
- `P-8` / `P-9`: the credential *names* and upstream API bases those aliases
  bind to (values are never in this file).

Error inputs it must tolerate: a request for a model id that is not in the
map, a request carrying parameters the bound provider does not support, and a
provider that returns an error for a well-formed request.

## Outputs

- The exact list returned by `GET /v1/models`: the alias set, nothing more
  (`P-10`). A client discovering models through that endpoint must be able to
  treat every id it sees as usable.
- Per-alias routing: a request for an alias goes to exactly the provider and
  upstream model that alias binds to.
- Error responses that name the failure, passed back to the client
  unchanged in meaning — a request that cannot be served by its own alias
  MUST fail; it MUST NOT be answered by another provider (R-3).

## Dependencies

- `P-4`, `P-10`, `P-8`, `P-9`; `D-2` (the provider accounts' API bases).
- Consumed by `client-wiring.md`, which must be told the alias set.

## Failure Behavior

| Condition | Behavior |
|---|---|
| Alias requested that is not in the map | Client-visible error. Never a guess, never a passthrough of an arbitrary provider model id |
| Bound provider unreachable or erroring | The provider's error reaches the client as an error. **No cross-provider or cross-model fallback ever**: a router that quietly fails over to whatever is available would break R-3, and with it the reason this router exists (a client must know which provider served it) |
| Aliases removed while a client still sends them | The client gets an error for that alias only; other aliases keep serving. Remove an alias only after its consumers are updated, or the error is the signal to update them |
| `api_base` omitted where the router's built-in default differs from the account's provisioning | Requests silently go to a different API version and fail, or worse, succeed against a path the account is not provisioned on. Pin it (see the schema file); if it is pinned and wrong, the error names the path |
| Upstream model id renamed by the provider | That alias errors; other aliases are unaffected. Fix by editing the binding — the alias id does not change |
| Unsupported parameter in the request | Dropped (R-9), because `drop_params` is enabled in the config template. If that setting is removed, clients sending a superset of parameters start receiving 400s |

## Idempotency Notes

The map is declarative: re-applying the same file and recreating the container
converges to the same surface. There is no partial state — either the config
parses and the whole map is live, or the router fails to start and the previous
surface is gone. Adding an alias is additive; changing the provider behind an
existing alias is a one-line edit plus a recreate; both are safe to re-run.
Completion detection is A-1 (the set) plus A-4 (a real completion per alias).

## Removal Notes

Removing an alias is: delete its entry, recreate the container, and (only if
no other alias uses it) retire the credential from `P-8`. The credential may
be left in the store harmlessly, but leaving an unused provider key in a
collective store is unnecessary exposure — prefer rotation at the provider
(`provider-credentials.md`).
