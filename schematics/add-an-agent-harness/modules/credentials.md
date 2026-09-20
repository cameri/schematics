# Module: Credentials

Where a harness keeps its credential home, how the router's credential reaches
the CLI's process, why the image contains neither, and what an operator does
when a harness insists on a login it can persist.

## Purpose

Owns the credential half of R-6 and all of R-8: the directory a CLI treats as
its credential home, the injection path that puts the credential in the
process environment, the image's emptiness, and the maintenance procedure for
a persisted login.

It is explicitly not responsible for the rest of the router wiring — the
endpoint, the aliases, the model metadata (`modules/router-wiring.md`) — or
for the secret machinery itself: the encrypted store, the keys and the boot
decryption belong to `encrypt-container-secrets` (D-3).

## Inputs

| Input | What | Where it comes from |
|---|---|---|
| `P-4 ROUTER_CREDENTIAL_ENV` | The *name* of the credential variable. The value is never a build input and never appears in this package's files | The deployment, injected at boot |
| `P-9 HARNESS_HOME` | The config root the layer points the CLI's own relocation variable at | Build arg |
| The CLI's relocation variable | `CLAUDE_CONFIG_DIR` (Claude Code), `CODEX_HOME` (Codex CLI), `PI_CODING_AGENT_DIR` (omp) | The CLIs |
| The D-3 store and the service's dedicated key file | Mounted read-only; decrypted in memory at boot | The deployment's `encrypt-container-secrets` wiring |

Error inputs it must tolerate: the credential variable absent at boot, a store
key named something other than `P-4`, and a CLI that ignores its relocation
variable.

## Outputs

- A process environment that carries the credential under `P-4`'s name, and no
  filesystem — image or runtime — that carries its value.
- A `P-9` holding the CLI's configuration, which references the credential by
  name at most, and — only via the maintenance path below — a login file on a
  mounted volume.
- An image with no credential and no credential-shaped file in it (R-8),
  verified by row H-10 rather than asserted.

## The harness home is the credential home

Each CLI keeps everything it persists in one directory: its configuration, its
session state, and — when a login flow runs — its stored credential file
(`auth.json` for the two npm-distributed CLIs this package names, and `agent.db`
for omp). The directory is the CLI's own config root, relocatable by a variable
the CLI defines:

| CLI | Config root variable | Built-in default |
|---|---|---|
| Claude Code | `CLAUDE_CONFIG_DIR` | `~/.claude` |
| Codex CLI | `CODEX_HOME` | `~/.codex` |
| omp | `PI_CODING_AGENT_DIR` | `~/.omp/agent` — or `~/.omp/profiles/<profile>/agent` under a named profile, which takes precedence over the variable |

omp's relocation is the reason the third row carries a caveat: its own variable
names the *agent directory*, and a named profile derives that directory instead of
honouring it. The layer sets the variable and no profile, so the root is the one
this layer pinned; a deployment that selects a profile for the pane moves the root
to the profile's directory and must mount that path instead (Q-1).

The layer sets whichever variable the selected CLI defines to `P-9
HARNESS_HOME`, so every file the CLI writes lands in one known place. One
directory, three jobs:

- A deployment that wants session state across recreates mounts exactly it
  (Q-1) — which is also the only place a credential file can accumulate.
- H-10's search is bounded: the harness home and the account's home, not the
  filesystem. The account's home is in the search for the case where a CLI
  ignores its relocation variable and falls back to its built-in default.
- The image writes the default configuration into `P-9` at build time, and a
  bind mount takes precedence at run time. A deployment that mounts the home
  from the host must hand it to the base's uid, or the CLI cannot write
  session state — and a login could not write its file either.
- **The root is per image, and every agent a deployment runs from that image
  shares it.** The layer pins `CLAUDE_CONFIG_DIR`/`CODEX_HOME` at build time, and
  the deployment cannot vary it per pane: the multiplexer runs each agent with its
  own home, but `herdr` does not pass a workspace's `--env` values into a plugin
  pane, which is that package's own measured constraint. So a pane's session state
  and configuration live where every other pane's do — one path, the one Q-1's
  optional volume mounts. Per-agent isolation of session state is outside this
  layer's reach; SCHEMATIC.md records the alternative and why it is not taken.

## How the credential reaches the process

The deployment injects the credential as the environment variable named by
`P-4`. The value travels by `encrypt-container-secrets` (D-3): at boot, a
wrapper decrypts the deployment's encrypted dotenv file **in memory** and
execs the base's entrypoint with the entries in the environment. Nothing
decrypted is ever written to a container filesystem — no temp file, no
plaintext copy — and the master key never enters the container: what is
mounted is the ciphertext and the service's dedicated key file.

One property of that mechanism is load-bearing: **the store's key name is the
variable name.** Entries reach the process verbatim, with no mapping layer, so
the key in the encrypted file is named exactly what `P-4` names.

Each CLI consumes the variable in its own way:

| CLI | Where the credential lives | Where the value is read | Header sent |
|---|---|---|---|
| Claude Code | The process environment. `settings.json` carries no credential: its `env` block takes values, so a value written there would be a credential in the image (R-8) | `ANTHROPIC_AUTH_TOKEN`, read from the environment; the CLI prefixes `Bearer ` | `Authorization: Bearer <credential>` |
| Codex CLI | The *name* is configuration: `model_providers.<id>.env_key` in `config.toml` is set to `P-4` | The named variable, read from the environment at request time | `Authorization: Bearer <credential>` |
| omp | The *name* is configuration: `providers.router.apiKey` in `models.yml` is set to `P-4`, with `authHeader: true` so the resolved value becomes a bearer header | The named variable when it is set; a literal value in that field otherwise, which is why the name is the only thing this layer writes there | `Authorization: Bearer <credential>` |

Who picks the name differs, and the difference matters when wiring:

- **Claude Code dictates it.** The variable whose value it sends as the bearer
  header is `ANTHROPIC_AUTH_TOKEN`, so `P-4` takes that name.
  `ANTHROPIC_API_KEY` is not the variable for this router: it sets a different
  header (`X-Api-Key`), and the router reads a bearer credential
  (`run-an-llm-router`'s `modules/client-wiring.md`). The wrong variable
  produces a configuration that looks wired and authenticates against nothing.
- **Codex CLI defers it.** `env_key` reads whatever variable `P-4` names, at
  request time. Naming the variable is configuration; holding the value is not
  possible in the file (R-8) — the value stays in the environment, which the
  deployment owns.
- **omp defers it, with a fallback to remember.** Its `apiKey` field reads the
  variable `P-4` names when that variable is set, and treats the field's text as a
  literal credential when it is not. So the file is safe exactly as long as the
  field holds the *name*: writing a value there would put a credential in an image
  layer, and the CLI would then send the literal whether or not the deployment's
  store decrypted anything — a failure H-10 catches at build time, which is what
  the row is for.

## Why the image holds none

R-8 states the rule; the reasons behind it are mechanical:

- A credential in an image layer is a credential in every container started
  from that image, on every host the image reaches, for as long as the image
  exists. Restarting, recreating and rotating do not revoke it.
- The image must be reproducible from its parameters alone — that is what
  makes the acceptance rows re-runnable and the build idempotent (principle
  4). A build that needs a credential is a build that cannot be repeated
  elsewhere.
- Nothing in the layer needs one: the CLI's version command exits 0 with no
  credential (H-4), and a missing variable fails at the first request with the
  CLI's own error naming the variable (D-3's failure behaviour).

Row H-10 is the mechanical check: search the harness home and the account's
home for credential-shaped files — the CLIs' stored credentials, keys, tokens,
dotenv files — and expect none. The configuration is inside the search, under
the distinction that decides the row: the credential **name** may appear
(`P-4`, as Codex CLI's `env_key`; Claude Code's file names no credential at
all), a credential **value** may not.

## When a harness insists on a login

The env-var path is the only credential path this layer provides — no login
flow runs in the image, because a CLI that persists a login writes a
credential-shaped file and the image must contain none (R-8, the decision
log). A CLI that accepts the variable never asks. One that nonetheless insists
on an interactive login is handled outside the image:

1. Start a one-off container from the built image with `P-9` bind-mounted and
   a TTY, and run the CLI's login there. The credential the flow writes —
   `auth.json` for the two npm-distributed CLIs this package names, `agent.db` for
   omp — lands under `P-9`, on the mount, not in a container layer.
2. Leave it on the mount. That is session-state territory (Q-1): the file
   survives recreates, belongs to the deployment, and is absent from every
   image this layer produces.
3. If the credential must be held centrally rather than as a host-side file,
   re-encrypt it into the deployment's D-3 store by that package's own
   procedure. Note the boundary: D-3 delivers entries as environment
   variables, so a *file*-shaped credential would need deployment-side boot
   wiring to place it — a hook the base's entrypoint does not offer (R-3).
   The mounted `P-9` is the only end-to-end path this package provides for a
   persisted login. *(inferred: the boundary reasoning, not an observed
   failure.)*
4. Never bake the file into an image layer or a build context. H-10 fails on
   it, and every container from the image carries it.
5. Rebuild sanity: a rebuild from the same parameters, on a machine that has
   never seen the credential, must produce an image that passes H-10. If it
   does not, the login file leaked into the build inputs, and the fix is to
   remove it — not to exclude the file from the search.

omp has a second credential path that is easy to introduce by accident: it applies
a `.env` file found in its own root, so a deployment that drops the credential
there has created a plaintext credential on the mount without a login flow
anywhere. The layer writes no `.env`, H-10's search includes one — in the image,
where none may exist — and a deployment that wants the variable path keeps the
value in the D-3 store, injected at boot, not in a file beside the configuration.

The last point is the rule the procedure exists to protect: **the image is a
function of the parameters, and none of the parameters is a credential.**

## Rotation

Changing the credential changes the deployment's secret only:

| Change | What moves | What does not |
|---|---|---|
| Credential **value** | The D-3 store is edited and the container restarted; the wrapper re-decrypts at boot (D-3's rotation procedure) | The image, the configuration, `P-9` — nothing rebuilds |
| Credential **variable name** (`P-4`) | A build arg: the layer is rebuilt, and the name is re-checked by H-8 — in the file for Codex CLI, in the injected environment for Claude Code | The credential value, the store, `P-9` |

That asymmetry is R-8 working: because the image never held the value,
rotating it cannot require a build. Where the maintenance path above left a
login file on the mount, rotation re-runs that path — a fresh login replaces
the file on the mount; the image is still not touched.

## Failure Behavior

| Condition | Behavior |
|---|---|
| Credential variable absent at boot | The container starts — the entrypoint does not check credentials — and the CLI fails its first request, naming the variable (D-3's failure behaviour) |
| Store key named something other than `P-4` | The value arrives under the wrong name; the CLI reports the variable missing while the store holds it. Fix the store key's name (the verbatim rule), never by adding a mapping |
| Credential value written into the CLI's configuration | H-10 fails at build time — measured, not silent |
| Login file baked into an image layer | H-10 fails; every container from the image carries the credential until the image is rebuilt without it |

## Idempotency Notes

Every boot re-decrypts from the mounted ciphertext, so a restart always
converges to the store's current contents; the image never participates in a
value change. The maintenance login is a one-time operation on a mount and can
be re-run — for rotation, or after a bad login — with no image rebuild and no
ordering hazard. A rebuild from unchanged parameters reproduces a
credential-free image, and H-10 re-proves it each time.

## Removal Notes

The layer adds no credential state anywhere: no store, no key file, no secret
mount, no credential in any image. Removing the layer leaves the deployment's
D-3 store and the mounted `P-9` exactly as they were (the spec's Removal step
3). The only credential artifact this module's procedure can have created is a
login file on the mount, which belongs to the deployment, not to this package.
