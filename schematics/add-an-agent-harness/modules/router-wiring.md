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
| Endpoint | `P-3 ROUTER_BASE_URL` | The router's **root**, with no path suffix — built from that package's service name and port. Each CLI appends its own protocol path to it, so the value written into a configuration is derived per arm, below |
| Credential | `P-4 ROUTER_CREDENTIAL_ENV` | The **name** of the environment variable the deployment injects the credential into. The value never appears in a file (R-8) |
| Model | `P-5 HARNESS_MODEL_ALIAS` | An alias from the router's `P-10 ALIAS_SET`. A client may only send aliases that set contains |
| Metadata | `P-7`, `P-8` | The context window and the maximum output tokens of the model `P-5` resolves to. The router's registry does not report them, which is why the client declares them |

The credential is presented as `Authorization: Bearer <credential>`, so for all
three CLIs a **bearer** variable is the one to name — not an API-key variable that
sets a different header.

## Claude Code

Configuration lives in `settings.json` under the directory named by
`CLAUDE_CONFIG_DIR`, which this layer sets to `P-9 HARNESS_HOME`.

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "@HARNESS_ENDPOINT@",
    "ANTHROPIC_MODEL": "@HARNESS_MODEL_ALIAS@",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "@HARNESS_FAST_ALIAS@",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "@HARNESS_CONTEXT_WINDOW@",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "@HARNESS_MAX_OUTPUT_TOKENS@"
  }
}
```

| Setting | Effect |
|---|---|
| `ANTHROPIC_BASE_URL` | Routes requests through a proxy or gateway instead of the first-party endpoint. The build writes the router **root** here: Claude Code appends `/v1/messages` itself, so a value ending in `/v1` would request `/v1/v1/messages` and never reach the router |
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
base_url = "@HARNESS_ENDPOINT@"
env_key = "@ROUTER_CREDENTIAL_ENV@"
wire_api = "responses"
```

| Key | Effect |
|---|---|
| `model` | The model the session uses — an alias from the router's set |
| `model_provider` | Which provider block to use. Named for the router; the built-in `openai` provider is reserved and cannot be overridden, and pointing at it is not the same as pointing at the router |
| `model_context_window` | The context window available to the active model — a top-level key, next to `model`, not inside the provider block |
| `model_providers.router.name` | A display name |
| `model_providers.router.base_url` | The router's API base URL **with `/v1`**, because Codex CLI appends `/responses` |
| `model_providers.router.env_key` | The **name** of the environment variable holding the credential. This is why the file can name a credential without carrying one: the value stays in the environment (R-8) |
| `model_providers.router.wire_api` | The protocol used to reach the provider. `responses` is the only supported value |

`wire_api = "responses"` is a **condition on the router**, not a preference: Codex
CLI speaks the Responses API. A router that serves chat completions alone is not a
compatible endpoint for this harness, and the failure appears at the first request
rather than at startup (D-2's failure behaviour). Do not paper over it with a
protocol-translating proxy in this layer — that is a second service, which R-2
forbids, and it hides which component is actually answering.

## omp

omp reads **two** files, both under the directory named by `PI_CODING_AGENT_DIR`,
which this layer sets to `P-9 HARNESS_HOME`: its settings file (`config.yml`) and
its model catalogue (`models.yml`). The layer writes both (R-6) — the settings file
carries the model roles, the catalogue carries the provider, and the model metadata
exists in no other file.

```yaml
# config.yml — the roles the session uses
modelRoles:
  default: "router/@HARNESS_MODEL_ALIAS@"
  smol: "router/@HARNESS_FAST_ALIAS@"
```

```yaml
# models.yml — the provider, and the models it may be asked for
providers:
  router:
    baseUrl: "@HARNESS_ENDPOINT@"
    api: openai-completions
    apiKey: "@ROUTER_CREDENTIAL_ENV@"
    authHeader: true
    models:
      - id: "@HARNESS_MODEL_ALIAS@"
        name: "@HARNESS_MODEL_ALIAS@"
        contextWindow: @HARNESS_CONTEXT_WINDOW@
        maxTokens: @HARNESS_MAX_OUTPUT_TOKENS@
      - id: "@HARNESS_FAST_ALIAS@"
        name: "@HARNESS_FAST_ALIAS@"
```

| Key | Effect |
|---|---|
| `modelRoles.default` | The model the session uses for its primary role — the provider id, then the alias from the router's set |
| `modelRoles.smol` | The small/fast role: background work, titles, summaries. Its value is `P-6`; an unset role leaves the CLI on a built-in name the router probably does not serve, which is why `P-6` is required at build for this arm |
| `providers.router.baseUrl` | The router's API base URL **with `/v1`**, because omp's OpenAI-compatible client appends `/chat/completions`. The template's placeholder is `@HARNESS_ENDPOINT@`, which the build resolves per arm |
| `providers.router.api` | Which wire protocol the client speaks. `openai-completions` is this package's choice for the arm, and it is a compatibility requirement on the router: every router that serves anything serves `/v1/chat/completions` |
| `providers.router.apiKey` | The **name** of the environment variable the credential arrives in. omp reads that variable when it is set and treats the value as a literal otherwise, so the name alone is the file's content and the credential stays in the environment (R-8) |
| `providers.router.authHeader` | Sends `Authorization: Bearer <resolved credential>`. The router reads a bearer credential, and a custom provider does not add that header on its own |
| `providers.router.models[].id` | The model ids the provider may be asked for — `P-5` and `P-6` |
| `providers.router.models[].contextWindow`, `maxTokens` | `P-7` and `P-8` for the model `P-5` resolves to. This is the only place in the CLI's configuration where either number can be declared |
| `providers.router.models[].name` | A display name for the model picker |

The fast model's entry carries **no** `contextWindow` and no `maxTokens`: `P-7` and
`P-8` describe the model `P-5` resolves to, and the layer has no second pair of
numbers for `P-6`'s model. Copying the primary's numbers there would be a
plausible-looking declaration for a different model — the thing `P-8`'s precedent
forbids. A deployment that knows the fast model's numbers adds them to that entry
in its own copy of the catalogue.

The catalogue also carries a per-provider `discovery` block for providers whose
model list is fetched at run time. This layer sets none: the model set a router
deployment may use is exactly the alias set it declared at build time, and a
discovery block would let the CLI reach for ids the router does not serve (R-7).

## One parameter, two paths: the per-arm endpoint

`P-3` is the router's root. The two CLIs append different paths to it, so the
layer derives the value each configuration gets — one parameter cannot be both:

| Arm | Appends | Written into the configuration | Example, for `P-3 = http://llm-router:4000` |
|---|---|---|---|
| `claude` | `/v1/messages` | the root alone (`ANTHROPIC_BASE_URL`) | `http://llm-router:4000` |
| `codex` | `/responses` | the root plus `/v1` (`base_url`) | `http://llm-router:4000/v1` |
| `omp` | `/chat/completions` | the root plus `/v1` (`providers.router.baseUrl`) | `http://llm-router:4000/v1` |

Claude Code's own documentation sets `ANTHROPIC_BASE_URL` to the gateway root and
verifies with a request to `/v1/messages`; Codex CLI's provider block takes the
OpenAI-style base ending in `/v1`. Writing `P-3` verbatim into both files is the
defect this table exists to prevent: the Claude arm would request
`/v1/v1/messages`, which is a 404 at the first turn — not a startup error, and not
something the acceptance rows could see without comparing the file's value to the
derived one (they do: H-8).

The derivation is the build's, and it is recorded: the image writes the URL it
used to `/usr/local/share/agent-harness/endpoint`, and the body half of the
acceptance script compares the configuration's value against it. A build given a
`P-3` that already ends in `/v1` is refused rather than doubled.

## The metadata the router does not report

A model's window and output limit are properties of the model, not of the router's
API, and the router's registry does not report them (D-2). They are therefore
declared here, per harness, in whatever field the CLI offers:

| Metadata | Claude Code | Codex CLI | omp |
|---|---|---|---|
| Context window | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (`P-7`) | `model_context_window` (`P-7`) | `providers.router.models[].contextWindow` in `models.yml` (`P-7`) |
| Maximum output tokens | `CLAUDE_CODE_MAX_OUTPUT_TOKENS` (`P-8`) | **no key exists** | `providers.router.models[].maxTokens` in `models.yml` (`P-8`) |

For Codex CLI, `P-8` is unused and the acceptance row reports the gap rather than
a plausible-looking key. Writing a field the CLI ignores would produce a
configuration that reads as if the limit were set — worse than an absent one,
because the next reader believes it.

omp declares both numbers, but only for the model `P-5` resolves to: the file's
model list gains an entry per id the provider may serve, and only the primary
alias has numbers the layer was given.

Both CLIs need `P-7` for the same reason: an unrecognized model id gets a wrong
assumed window, and the CLI then compacts the conversation at the wrong point.
omp has the same reason, and one more place the rule of this section has to be
applied: its settings file carries a `retry.fallbackChains` map, in which a role
may name `provider/id` selectors and wildcards such as `provider/*`. The arm
writes no `fallbackChains` key at all, which is the empty map: a chain is exactly
the fallback provider R-7 forbids, and one written here would move a request off
the router the moment the router failed.

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

A role the deployment does not care about is still a route, and `P-6` is required
at build for that reason. An unset small/fast role leaves the CLI pointing at a
built-in model name the router probably does not serve, and nothing in the layer
would say so: the request would simply never reach the router. Where a harness has
no second role — the `codex` arm — the parameter is unused and no key is written;
where it has one under a different name, the arm writes that name (omp's is
`smol`).

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
# the file(s) the CLI actually reads
cat "${CLAUDE_CONFIG_DIR:-${CODEX_HOME:-${PI_CODING_AGENT_DIR}}}/settings.json"   # or config.toml
cat "${PI_CODING_AGENT_DIR}/config.yml" "${PI_CODING_AGENT_DIR}/models.yml"       # the omp arm

# the endpoint answers, and names the alias it served
curl -sS -H "Authorization: Bearer ${ROUTER_API_KEY}" "${ROUTER_BASE_URL}/v1/models"
```

The first commands are rows H-8, H-9 and H-11. The last one is a deployment
check, not a layer check: it needs a real credential and a running router, which is
why it is not a row in this package's table.
