# Module: Router Service

The router process itself: the image it runs from, the map it loads, the port
it listens on, and how orchestration knows it is ready.

## Purpose

Owns everything between "an alias map and a key store exist on the host" and
"a healthy process answers OpenAI-shaped requests from the router network":
the image and its pin, the boot wrapper's place in the lifecycle, the config
mount, the listen port, the health endpoint, and the restart policy. It is
**not** responsible for what the aliases are (`model-aliases.md`), how
credentials reach the process (`provider-credentials.md`), who consumes the
endpoint (`client-wiring.md`), or exposing the router beyond its private
network (SCHEMATIC.md Phase 8).

## Inputs

- `P-1 ROUTER_SERVICE_NAME`, `P-2 ROUTER_PORT`, `P-3 ROUTER_IMAGE`.
- `P-4 CONFIG_PATH`: the alias → provider map, mounted read-only at
  `/opt/llm-router/config.yaml`.
- The decrypted environment, which compose produces by wrapping this
  container's boot in `sops exec-env` (`provider-credentials.md`) — the router
  never reads the ciphertext itself.
- `P-11 ROUTER_NETWORK`: the private network the service attaches to.

Error inputs it must tolerate: a config file with extra unknown keys (the
router ignores what it does not know), comments and blank lines, and a
provider outage at request time (an error per request, not a crash).

## Outputs

- An HTTP service on `http://<P-1>:<P-2>` inside `P-11`, with an
  OpenAI-compatible surface: `POST /v1/chat/completions`, `GET /v1/models`,
  plus the router's own health path (`P-2` is the port those are served on).
- Container state: `running` plus the health state orchestration gates on.
- A stable container name (`P-1`), so runbooks, verification, and probes can
  address it without discovering an id.
- No host ports, unless Phase 8 deliberately adds an exposure.

## Dependencies

- `D-1` (Docker + Compose v2), `D-5` only when clients are off-host.
- `P-1`, `P-2`, `P-3`, `P-4`, `P-11`.
- Consumes the decrypted environment produced by `provider-credentials.md`.

## Failure Behavior

| Condition | Behavior |
|---|---|
| `P-4` path does not exist on the host | Compose creates a **directory** at the mount point and the router boots with an empty model surface: it answers, but `/v1/models` is empty. Nothing crashes. This is the quietest failure in the whole schematic — it is caught by A-1, not by the healthcheck |
| Config is invalid YAML or a malformed `model_list` | The router exits non-zero; `restart: unless-stopped` re-runs it into the same error. The cause is in `docker compose logs <P-1>`, not in the health state |
| Upstream image tag removed or the build fails | `docker compose build` fails and nothing starts. Never resolve this by removing the pin (R-10) |
| Host port collision | Cannot happen by default: the service publishes nothing. A deliberate exposure adds one, and then the collision is a normal bind error at start |
| Health probe fails after `start_period` | The container is reported unhealthy but keeps running and keeps serving requests that succeed. Treat unhealthy as "re-check now", not "the router is down" — A-2 is the discriminator |
| Router process dies | `restart: unless-stopped` brings it back; the decrypted environment is re-created on every start, so no state is lost |

No silent fallback: if the router cannot start, clients get connection errors.
That is the intended behavior (see `client-wiring.md`) — nothing downstream may
invent a substitute inference path.

## Idempotency Notes

- `docker compose up -d` is the convergent operation: it creates, recreates, or
  leaves the container as needed, and re-running it never duplicates state.
- Rebuilding is required only when `P-3` (the image pin) or the bootstrap
  script changes. Config and credential changes are restarts
  (`provider-credentials.md` explains why a recreate, not a `docker restart`,
  is the reliable form).
- Completion detection: the container reports healthy **and** A-1 lists the
  expected alias set. Both are safe to re-run.

## Removal Notes

Adds: one image, one container, one network, one read-only config mount, and
the compose entry. Removes: stop and remove the service
(`docker compose down`), then the network. The image can stay (it is
re-buildable from the skeleton) or be dropped with `docker rmi`. Nothing on
the host's filesystem is owned by this module — the config file and the
encrypted store are files the operator created, and they stay.
