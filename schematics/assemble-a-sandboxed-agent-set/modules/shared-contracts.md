# Module: Shared Contracts

The values two or more parts must agree on for the set to work, each mapped to the
part-owned parameter that decides it. This is the module the composition exists to
carry: a part can pass its own acceptance rows and still be assembled wrongly,
because the failure is in a value that crosses a boundary — a path, a name, an
endpoint, a credential variable — and no single part owns both ends of it.

It is NOT the isolation module: what each container may reach, mount and hold, and
the one table of forbidden properties, belong to `modules/isolation-rules.md`. This
module is about agreement, not reachability.

## Purpose

Own the cross-part value table, and nothing else. A deployment that changes a value
here must change it at both ends; a deployment that changes one end alone has a
defect this module's "if they disagree" column names, and the check column is how it
is found before a container starts.

## Inputs

- This package's Parameters table, and the parts' parameter tables **read at the
  pinned commits** (D-1 … D-6) — the pins are what make a part's parameter name
  citable rather than remembered.
- The deployment's own values for `P-1` … `P-21`.
- The merged configuration of the parts' fragments in the order the spine gives.

## Outputs

- One table of cross-part contracts: the value, where it is fixed here, the parts
  that must agree, the observable symptom when they disagree, and a command that
  finds the disagreement.
- The compose merge order and what it guarantees, which is itself a contract
  between this package's glue and every part's fragment.
- Nothing else: no file, no service, no image. The checks are the acceptance rows'
  reading of the set; do not fork a second copy into a part.

## Dependencies

- **D-1** `build-an-agent-dev-image` — the account uid/gid and the workspace path
  the tree and the layout are built around.
- **D-2** `run-multiplexed-agent-workspaces` — the agent tree layout, the
  per-agent home, `AGENT_HARNESS`, and the host image the layer builds on.
- **D-3** `add-an-agent-harness` — the config root (`P-9`), the router endpoint's
  form (`P-3`), the credential variable the CLI reads, and `AGENT_HARNESS`.
- **D-4** `run-an-llm-router` — the endpoint, the credential variable its gate
  reads, and the alias set.
- **D-5** `encrypt-container-secrets` — the secret names, the mount targets, and
  the key-file naming.
- **D-6** `restrict-docker-api-access` — the proxy endpoint, its allowlist, and
  **which network it is on**.

## The contract table

Every row is a value, not a hope: the parts' own files decide each one, and this
package's parameters are the only place a deployment sets it.

| Contract | Fixed here | Parts that must agree | If they disagree | How to check |
|---|---|---|---|---|
| **The set network.** One bridge network every service of the set joins, addressed by service name | `P-1 AGENT_SET_NETWORK`, declared in the glue and named in each service's `networks:` | Every part's service definition (none of them declares a `networks:` of its own — the parts are deltas) | A service on another network resolves nothing by name: the harness's `ROUTER_BASE_URL` and the host's `DOCKER_PROXY_URL` fail with name-resolution errors at the first call | `docker compose … config --services` plus `docker inspect <c> --format '{{json .NetworkSettings.Networks}}'` for each container |
| **The Docker-access network, which is NOT the set network.** The proxy keeps its own internal network; the host container joins that network as its consumer | The glue's `networks:` line for `agent-host`; the proxy's own fragment declares the internal network (`internal: true`) | D-6's own network contract (`P-5 NETWORK_NAME`, "the internal network consumers join") and its rule that nothing else is attached to it | If the proxy is attached to the set network instead, its unauthenticated port 2375 is reachable by every member of the set, and the part's network isolation — the thing that stops `HTTP on 2375` from being an open daemon — is gone. The allowlist still bounds *verbs*, not *who may ask* | `docker inspect socket-proxy --format '{{json .NetworkSettings.Networks}}'` shows one network, the internal one; `docker exec <host> getent hosts socket-proxy` resolves; the router container does not resolve it |
| **The agent tree path and its owner** | `P-2 AGENT_TREE_DIR` (host path), mounted at the workspace path the base declares | D-1's account uid/gid, D-2's tree layout and per-agent home | A tree owned by another uid makes every pane unwritable: the harness starts and cannot write session state. Wrong path and the panes start in an empty workspace | `stat -c '%u:%g' "$AGENT_TREE_DIR"` against the base image's account; `docker inspect <host> --format '{{range .Mounts}}…'` |
| **The image chain, and the form of each reference** | `P-4 AGENT_BASE_REF` → `P-5 AGENT_HOST_IMAGE` → `P-6 HARNESS_IMAGE`, each ONE complete reference (`name:tag` locally, `name@sha256:<digest>` published) | D-2's own image parameter, D-3's `P-2` (the base it builds on), and every fragment that names an image | Appending a tag to a digest reference, or naming the host image where the layer's is required, either fails to resolve or runs the harness-free host: the container starts and has no CLI. This is why the glue's `services:` entries carry no `image` at all | `docker image inspect <ref>` resolves; `docker compose … config` shows each service's `image` coming from the part that owns it |
| **The router endpoint: the ROOT, and the path each arm appends** | `P-8 ROUTER_BASE_URL` is the root, no `/v1`; the harness layer's `P-3` takes the same value and derives the arm's URL (`/v1/messages` appended by Claude Code, `/v1/responses` by Codex CLI, whose base therefore ends in `/v1`) | D-4's `P-13` (the URL it publishes) and D-3's `P-3` + its `modules/router-wiring.md` table | Pass the `/v1` base through and the Claude arm requests `/v1/v1/messages`: a 404 at the first turn, with a configuration that looks right. The layer refuses a `/v1` suffix at build time for exactly this reason | `docker image inspect <harness image> --format '{{json .Config.Env}}'` and the recorded endpoint at `/usr/local/share/agent-harness/endpoint`; the layer's `H-8` compares the file's value against the derived one |
| **The model aliases** | `P-10 ROUTER_ALIAS` (primary), `P-11 ROUTER_ALIAS_SET` (what the deployment decided the router serves), `P-12 ROUTER_FAST_ALIAS` (secondary) | D-4's `P-10 ALIAS_SET` (the only ids a client may send) and D-3's `P-5`/`P-6` (what its configuration names) | An alias the router does not serve is accepted by every build and fails per request; nothing else in the set notices | `GET <root>/v1/models` with the router credential, then compare the answer with `P-11`; `bring-up.sh`'s step 7 does exactly this and refuses before the layer is built |
| **The credential variable's name** | `P-9 ROUTER_CREDENTIAL_ENV` — the name the *harness* reads | D-3's `P-4` and its per-arm record (`ANTHROPIC_AUTH_TOKEN` for the Claude arm, the layer's `P-4` for the Codex arm), D-4's own credential variable (inside ITS store — a different variable in a different container), and D-5's key set (the store must carry the entry under the harness's name) | The harness starts with the variable unset and fails its first request 401; no build sees it | `docker exec <host> printenv <name>`; the image's record at `/usr/local/share/agent-harness/credential-env` is the authority for which name this image's CLI reads |
| **The secret names and their mount targets** | `P-17 SECRETS_KEY_DIR`, `P-18 SECRETS_STORE_DIR`, `P-19 ROUTER_SECRETS_SERVICE`, `P-20 AGENT_HOST_SECRETS_SERVICE` | D-5's name-prefix rule, its mount-name and target-path parameters, and each consumer's `secrets:` list | Compose fails the merge on a secret nobody declares ("secret … not found"), and a wrong target decrypts the wrong file into a process — a secrecy finding, not a startup error | `docker compose … config` lists every `secrets:` key; `docker inspect <c> --format '{{range .Mounts}}…'` shows the targets |
| **The key-file mode against the runtime uid** | `P-17 SECRETS_KEY_DIR` holds `<service>-keys.txt` per store service | D-5's key-file mode parameter, read against D-1's account uid/gid | A mode the container's uid cannot read stops the decryptor and the container exits before its application starts; a mode anyone can read hands the key to another user | `stat -c '%a %u:%g' "$SECRETS_KEY_DIR/<service>-keys.txt"` against the store part's parameter for the relationship the tree's owner reports |
| **The Docker proxy endpoint and its allowlist** | `P-15 DOCKER_PROXY_URL`, `P-16 DOCKER_PROXY_ALLOWLIST` | D-6's `P-5`/`P-6` (its network and port) and its endpoint-scoping rule | The host's Docker tooling fails to reach the daemon; a group the deployment did not enable is refused, which is the proxy working as designed rather than a defect | `docker exec <host> docker version` through `P-15`; `docker exec <host> docker run --privileged …` must be refused |
| **The harness config root** | `P-21 HARNESS_CONFIG_PATH` — the path a deployment reads configuration from inside the container | D-3's `P-9` (the same value, written into the image as `CLAUDE_CONFIG_DIR`/`CODEX_HOME`) | A deployment that reads or mounts a different directory sees an empty configuration while the CLI reads the real one | `docker image inspect <harness image> --format '{{json .Config.Env}}'` against `P-21` |

## The compose merge order, and what it guarantees

The fragments are merged in one order, and the order is itself a contract:

```sh
docker compose \
  -f <part: run-an-llm-router>/skeleton/compose.yml \
  -f <part: encrypt-container-secrets>/skeleton/compose-secrets.yml \
  -f <part: restrict-docker-api-access>/skeleton/compose-socket-proxy.yml \
  -f <part: run-multiplexed-agent-workspaces>/skeleton/compose.service.yaml \
  -f <part: add-an-agent-harness>/skeleton/compose.service.yaml \
  -f <this package>/skeleton/compose.yaml \
  config
```

Compose's rule, measured with `docker compose config` on two fragments that both set
`image`, `environment` and `networks`: **the last file wins a single-value field,
and list-valued fields such as `networks:` are unioned.** Two consequences this
package depends on:

- The glue comes **last**, so nothing a part declares can be overridden by it, and
  it declares no single-value field of its own (`R-2`).
- The host part and the harness layer **both** define `agent-host`. The layer's
  fragment must come after the host's: its image and its decrypt-at-boot entrypoint
  are the ones that must win, while the host's keep everything the layer does not
  set. Reversing the two silently runs the harness-free host — the failure the
  ordering edge in `modules/deployment-order.md` exists to prevent.

## What this package does not own

Stated so a reader does not look for it here:

- Every service body: `image`, `command`, `entrypoint`, `environment`, `user` and
  mounts belong to the fragment that defines the service (`D-2` … `D-6`). The glue
  adds network membership and secret sources, and nothing else (`R-2`, row `A-2`).
- Each part's internal file formats: the store's dotenv layout, the router's
  configuration, the harness's `settings.json`/`config.toml`.
- The parts' own acceptance rows, which `A-3` runs rather than reimplements.

## Failure Behavior

| Condition | What the deployment sees | What to do |
|---|---|---|
| A contract value differs between the two ends | The symptom in that row's column: a name that does not resolve, a 401, a CLI that writes somewhere nobody reads | Fix the value here, then re-run the acceptance script; every row names the two ends it compares |
| A fragment is missing from the merge list | Compose fails on a service with no image, or the expected-service check names it | Add the fragment in the position the order gives it |
| The glue grows a service-defining field | `A-2` fails, naming the field | Move it back to the part that owns the service |
| Two parts declare the same secret name differently | Compose refuses the merge | The secret names are contracts; change the fragment, not the glue |
| A part is pinned at a commit whose parameters changed | The pins in `SCHEMATIC.md` no longer describe the parts | Re-read the part at the pinned commit; a pin bump is a change to this table, not a formality |

## Idempotency Notes

- The table is read, never written: applying it twice changes nothing.
- Merging is idempotent — the same fragments in the same order render the same
  configuration, which is what makes `A-2` a repeatable check rather than a
  snapshot.
- Every check column is a read (`inspect`, `config`, `stat`, `GET`). Nothing here
  starts, stops, or writes to a service.
