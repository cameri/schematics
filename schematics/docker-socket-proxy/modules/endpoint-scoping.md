# Module: endpoint scoping

The proxy's configuration is a set of environment variables, each enabling
one Docker API endpoint group. Everything not enabled is denied with 403.
This module is the map from "what my consumer does" to "which group to
enable", plus the verb gating that container-control requires.

## Group table

| Env var | Docker API surface | Typical consumer need |
|---------|--------------------|-----------------------|
| `CONTAINERS` | `GET /containers/json`, container inspect | status dashboards, "is it running" checks |
| `IMAGES` | `GET /images/...`, `POST /images/create` | image pulls (watchtower-style), existence checks |
| `POST` | the POST verb itself (needed by `POST /images/create`) | any POST-type operation |
| `NETWORKS` | network inspect/create | tools that manage networks |
| `VOLUMES` | volume inspect/create | backup tools |
| `EXEC` | `POST /exec` | remote command execution (avoid) |
| `BUILD` | `POST /build` | CI builders |
| `SWARM`, `NODES`, `TASKS`, `SECRETS`, `CONFIG`, `PLUGINS`, `SESSION`, `SYSTEM`, `EVENTS`, `AUTH` | swarm/admin surfaces | cluster tooling (avoid) |

## Verb gating

Enabling a group enables its reads and, with `POST=1`, its writes under that
group. Container lifecycle is gated separately and stays off unless enabled
explicitly:

- `ALLOW_START=0`, `ALLOW_STOP=0`, `ALLOW_RESTART=0` (defaults)

The pull-only pipeline in the reference deployment therefore runs with
exactly: `IMAGES=1`, `CONTAINERS=1`, `POST=1` - it can pull images and list
containers, and cannot start, stop, restart, or exec anything.

## Deriving the minimal set

1. Grep each consumer's config and code for Docker API paths
   (`/containers`, `/images`, `/exec`, ...).
2. For each hit, note the verb and the path.
3. Map to the group table; enable the group only if the operation is
   required for the consumer's documented purpose.
4. Write a one-line justification next to each enabled group in the compose
   file. An allowlist entry whose justification starts with "might need" is
   a denial waiting to happen - delete it instead.

## Worked example

A pull worker that runs `POST /images/create?fromImage=X&tag=Y` and reads
`GET /containers/json` to report the running version:

```
IMAGES: 1      # POST /images/create (the pull), GET /images/... (existence)
CONTAINERS: 1  # GET /containers/json (running-version status)
POST: 1        # the POST verb itself; start/stop/restart stay off
```

Everything else remains unset (denied): EXEC, NETWORKS, VOLUMES, SWARM,
BUILD, SECRETS, CONFIG, NODES, TASKS, PLUGINS, SYSTEM, EVENTS, AUTH, SESSION.
