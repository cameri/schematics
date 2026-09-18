# Module: Router Wiring

How the harness is told where inference comes from: the router's base URL, the
name of the credential variable, and model ids drawn from the router's alias set —
each expressed in the CLI's own configuration shape.

The wire contract belongs to `run-an-llm-router`'s `modules/client-wiring.md`
(D-2). This module is the client side of it: what the four facts are, and where
each CLI wants them written.

## The four facts

| Fact | Parameter | Value |
|---|---|---|
| Endpoint | `P-3 ROUTER_BASE_URL` | The router's OpenAI-compatible base URL, ending in `/v1` — built from that package's service name and port |
| Credential | `P-4 ROUTER_CREDENTIAL_ENV` | The **name** of the environment variable the deployment injects the credential into. The value never appears in a file (R-8) |
| Model | `P-5 HARNESS_MODEL_ALIAS` | An alias from the router's `P-10 ALIAS_SET`. A client may only send aliases that set contains |
| Metadata | `P-7`, `P-8` | The context window and the maximum output tokens of the model `P-5` resolves to. The router's registry does not report them, which is why the client declares them |

The credential is presented as `Authorization: Bearer <credential>`, so for both
CLIs a **bearer** variable is the one to name — not an API-key variable that sets
a different header.

## Claude Code

Configuration lives in `settings.json` under the directory named by
`CLAUDE_CONFIG_DIR`, which this layer sets to `P-9 HARNESS_HOME`.

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "@ROUTER_BASE_URL@",
    "ANTHROPIC_MODEL": "@HARNESS_MODEL_ALIAS@",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "@HARNESS_FAST_ALIAS@",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "@HARNESS_CONTEXT_WINDOW@",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "@HARNESS_MAX_OUTPUT_TOKENS@"
  }
}
```

| Setting | Effect |
|---|---|
| `ANTHROPIC_BASE_URL` | Routes requests through a proxy or gateway instead of the first-party endpoint |
| `ANTHROPIC_MODEL` | The model the session uses — an alias from the router's set |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | What the CLI's small/fast role resolves to — background work, session titles. Set it to a second alias (`P-6`); left unset, the CLI keeps its built-in name, which the router may not serve. The older `ANTHROPIC_SMALL_FAST_MODEL` name is deprecated; use the current one |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | The context window the CLI assumes for the active model. It exists precisely for a model reached through `ANTHROPIC_BASE_URL` whose window does not match the built-in size for its name — which is every alias |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | The maximum output tokens for most requests. Unset, the CLI assumes a default for model ids it does not recognize |

The `env` block takes **values**, so the credential variable must not appear in
this file. The deployment injects `ANTHROPIC_AUTH_TOKEN` into the process
environment; the CLI sends it as `Authorization: Bearer <value>`. Naming
`ANTHROPIC_API_KEY` instead would send `X-Api-Key`, which is not the header this
router reads — so this package does not use it.

## Codex CLI

Configuration lives in `config.toml` under the directory named by `CODEX_HOME`,
which this layer sets to `P-9 HARNESS_HOME`.

```toml
model = "@HARNESS_MODEL_ALIAS@"
model_provider = "router"
model_context_window = @HARNESS_CONTEXT_WINDOW@

[model_providers.router]
name = "router"
base_url = "@ROUTER_BASE_URL@"
env_key = "@ROUTER_CREDENTIAL_ENV@"
wire_api = "responses"
```

| Key | Effect |
|---|---|
| `model` | The model the session uses — an alias from the router's set |
| `model_provider` | Which provider block to use. Named for the router; the built-in `openai` provider is reserved and cannot be overridden, and pointing at it is not the same as pointing at the router |
| `model_context_window` | The context window available to the active model — a top-level key, next to `model`, not inside the provider block |
| `model_providers.router.name` | A display name |
| `model_providers.router.base_url` | The router's API base URL |
| `model_providers.router.env_key` | The **name** of the environment variable holding the credential. This is why the file can name a credential without carrying one: the value stays in the environment (R-8) |
| `model_providers.router.wire_api` | The protocol used to reach the provider. `responses` is the only supported value |

`wire_api = "responses"` is a **condition on the router**, not a preference: Codex
CLI speaks the Responses API. A router that serves chat completions alone is not a
compatible endpoint for this harness, and the failure appears at the first request
rather than at startup (D-2's failure behaviour). Do not paper over it with a
protocol-translating proxy in this layer — that is a second service, which R-2
forbids, and it hides which component is actually answering.

## The metadata the router does not report

A model's window and output limit are properties of the model, not of the router's
API, and the router's registry does not report them (D-2). They are therefore
declared here, per harness, in whatever field the CLI offers:

| Metadata | Claude Code | Codex CLI |
|---|---|---|
| Context window | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (`P-7`) | `model_context_window` (`P-7`) |
| Maximum output tokens | `CLAUDE_CODE_MAX_OUTPUT_TOKENS` (`P-8`) | **no key exists** |

For Codex CLI, `P-8` is unused and the acceptance row reports the gap rather than
a plausible-looking key. Writing a field the CLI ignores would produce a
configuration that reads as if the limit were set — worse than an absent one,
because the next reader believes it.

Both CLIs need `P-7` for the same reason: an unrecognized model id gets a wrong
assumed window, and the CLI then compacts the conversation at the wrong point.

## One provider, and what that costs

For every role the router serves, the configuration names an alias on that
router — and nothing else. No fallback provider, no second provider block, no
direct endpoint behind the router's back (R-7). The router package's client
wiring states the same rule from its side: when a client is moved onto the router,
the provider it replaced is removed in the same change, because a leftover
fallback reintroduces exactly the dependency the router exists to remove.

The consequence is intended and must be stated in a deployment's own notes: if
the router is down, every harness fails — loudly, at the client, naming the
endpoint. That is preferable to a silent fallback that bills a different provider
and reports a different model.

A role the deployment does not care about may be left at the CLI's default, and
`P-6` is empty by default. That is a real gap, not a neutral choice: an unset
small/fast role leaves the CLI pointing at a built-in model name the router
probably does not serve. Set `P-6` whenever the CLI has a second role.

## Because the configuration is written at build time

The alias, the URL and the token metadata are build inputs (`P-3`…`P-8`), so the
image carries a fixed configuration (a decision recorded in the spec). Two
operational consequences:

- Changing the router's alias set means rebuilding the layer with a corrected
  `P-5`/`P-6`. Nothing rewrites the file at boot, because the base's entrypoint
  offers no hook and adding one would mean replacing it (R-3).
- An alias that names nothing fails per request at the client, with the router's
  own error. Every other alias keeps serving, so a mistake is scoped to one
  deployment's build rather than to the router.

## Verifying the wiring by hand

Inside a container started from the built image, with the credential variable
present in its environment:

```
# the file the CLI actually reads
cat "${CLAUDE_CONFIG_DIR:-${CODEX_HOME}}/..."     # settings.json, or config.toml

# the endpoint answers, and names the alias it served
curl -sS -H "Authorization: Bearer ${ROUTER_API_KEY}" "${ROUTER_BASE_URL}/models"
```

The first commands are rows H-8, H-9 and H-11. The last one is a deployment
check, not a layer check: it needs a real credential and a running router, which is
why it is not a row in this package's table.
