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

### When the consumer is a prebuilt image (no local source to grep)

Step 1 assumes you can grep the consumer's own code. Most consumers are
someone else's prebuilt image - there is nothing local to grep. Use one of
these instead, in order of preference:

1. **Read the consumer's own docs/source upstream.** Its README or its
   Docker-client code (search for how it opens the Docker connection) will
   say what it lists, watches, or writes. This is usually enough on its
   own to fill in the group table without ever touching the deployment.
2. **Deploy deny-by-default first, watch what fails.** Start the proxy with
   every group unset, point the consumer at it, and read its logs/errors.
   A consumer that needs `CONTAINERS` will fail listing or inspecting
   containers; one that needs `EVENTS` will fail (or silently never fire)
   on its event-watch call. Enable one group at a time, redeploy, and
   confirm the specific failure clears before moving to the next -
   this doubles as A-2's audit-script cross-check, live.

Either path still ends at step 4: every enabled group gets a written
justification. "The upstream docs say it calls `GET /containers/json`" and
"enabling `CONTAINERS` cleared the `dial unix docker.sock: no such file`
error in its logs" are both acceptable justifications - an unexplained
`ALLOWED` in the audit output is still a bug (R-3).

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
