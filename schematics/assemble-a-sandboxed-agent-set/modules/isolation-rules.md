# Module: isolation-rules

## Purpose

Owns the set-wide view of what each container may reach, mount and hold, and the one table of things no container in the set
may ever have. Read it before adding a service to the merged compose file, and when `scripts/verify-set.sh` reports on
`A-5`, `A-6`, `A-7` or `A-13`. It is NOT responsible for any part's contract: each statement names the requirement that
already decides it, and this module adds only the per-container view and one detection expression per rule.

## Inputs

- The set as deployed: the merged configuration of the parts' fragments in the merge order the spine's Interfaces section
  gives, and the containers it starts.
- `P-1` `AGENT_SET_NETWORK`, `P-2` `AGENT_TREE_DIR`, `P-15` `DOCKER_PROXY_URL`, `P-16` `DOCKER_PROXY_ALLOWLIST`, `P-17`
  `SECRETS_KEY_DIR`, `P-18` `SECRETS_STORE_DIR`, `P-19` `ROUTER_SECRETS_SERVICE`, `P-20` `AGENT_HOST_SECRETS_SERVICE`.
- The store part's parameter values as this deployment set them: its `P-2` (master key file), `P-3` (dedicated key name),
  `P-8` (key-file mode), `P-10` (key path inside a container).

## Outputs

- The five statements of what may be reached, mounted and held: the agent pane's process, the host container, the router
  container, the Docker-access proxy container, and the store's key material.
- One forbidden table, each row carrying the requirement that forbids the thing plus a detection expression the implementer
  can run unchanged.
- Nothing else: no file, no service, no image. The checks are the reading of `scripts/verify-set.sh`'s rows; do not fork a
  second copy into a part.

## Dependencies

- `D-1` — the base image's unprivileged account and `AGENT_*` contract (its `R-1`, `R-3`, `R-9`, `R-15`): the "not root" rule
  below.
- `D-2` — the host part: its `R-9` (loopback, no socket) and `R-13` (no secret in the image).
- `D-3` — the harness layer: its `R-8` (no credential in the image) and `R-10` (no listener, no daemon).
- `D-4` — the router: its `R-2`, `R-4`, `R-6` fix the router container's reachability and its credential handling.
- `D-5` — the store: its key hierarchy and its `R-3` master-key rule, which the spine's `R-8` adopts for the whole set.
- `D-6` — the Docker-access part: its `R-1`, `R-2`, `R-5`, `R-6`, `R-7` are the Docker half of the forbidden table.

## What each container may see, mount and hold

### The agent pane's process

- **Reaches:** the router at `ROUTER_BASE_URL` (`P-8`) by service name on `AGENT_SET_NETWORK` (`P-1`), with the credential
  named by `ROUTER_CREDENTIAL_ENV` (`P-9`) in its process environment at run time (spine's `R-7`, part 3's `R-8`); Docker,
  when enabled, only via `DOCKER_HOST="$DOCKER_PROXY_URL"` (`P-15`).
- **Mounts:** nothing of its own — it inherits the host container's mounts. Its working directory and `HOME` are its own
  directories under the tree, and its identity comes from the workspace, never its environment (part 2's `R-3`).
- **Cannot:** open a listener or run a daemon (part 3's `R-10`); hold a provider credential, or any credential but the router
  credential (part 3's `R-8`); reach a Docker socket (part 2's `R-9`); run as root — the pane runs as the base's account (part
  2's `R-3`, part 1's `R-1`).

### The host container

- **Reaches:** the proxy's HTTP endpoint on the proxy's own network, the router by service name on `AGENT_SET_NETWORK`, and
  its own bind mount. Nothing on the host outside that mount, and nothing inbound (part 2's `R-9`).
- **Mounts:** exactly one read-write host path, `AGENT_TREE_DIR` (`P-2`), at part 2's `P-12`, holding every agent's workspace
  and home, the supervision state and the SSH material (part 2's `R-7`). Everything else is read-only or one credential file
  (spine's `R-6`): its dedicated store key at the store part's `P-10`, with the mode that part's `P-8` requires.
- **Cannot:** run as root (part 1's `R-1`); mount a Docker socket (part 2's `R-9`, `R-13`); publish a port — its `R-9` keeps
  inbound closed and its `P-20` defaults to loopback; hold the master key (spine's `R-8`).

### The router container

- **Reaches:** outbound to the provider endpoints the operator configured explicitly (its `R-2`); inbound only from the set's
  containers, by service name on `AGENT_SET_NETWORK`.
- **Mounts:** its own encrypted store file and its own dedicated key — only that key may be mounted into it (its `R-4`).
  Nothing of the agent tree, and no second service's key.
- **Cannot:** keep provider credentials on its filesystem — they are decrypted in memory at boot (its `R-4`); expose a host
  port by default (its `R-6`), and never inside this set's default (spine's `R-4`); be reached by a client off the set's
  network.

### The Docker-access proxy container

- **Reaches:** the daemon, through the socket mounted read-only into this container and no other (Docker-access part's `R-1`,
  `R-6`; the spine's `D-6` row). Consumers reach it only on its internal network, at that part's `P-6`, never published (its
  `R-5`).
- **Mounts:** the socket read-only at that part's `P-2`, and its own configuration.
- **Cannot:** mount the socket writable (its `R-6`); publish its endpoint (its `R-5`); serve an endpoint group not enabled
  with a documented reason (its `R-2`, `R-3`); enable container-control verbs without a written justification (its `R-7`).
  `DOCKER_PROXY_ALLOWLIST` (`P-16`) is the whole of what it may serve.

### The store's key material

- **Where it lives:** one host directory, `SECRETS_KEY_DIR` (`P-17`), holding the master key (the store part's `P-2`) and one
  dedicated key per service, named after the service (its `P-3`). A host path, not a container.
- **What reaches a container:** only its own dedicated key file, mounted at that part's `P-10` with the mode its `P-8`
  requires, decrypted in memory at boot and exported into the process environment; no plaintext lands on the container
  filesystem, and there is no shared secrets volume and no sidecar (its `R-4`).
- **Cannot reach any container:** the master key (the store part's `R-3`; the spine's `R-8` adopts it for the set). Secret
  values never enter the deployment's environment file either — that file holds parameter values only (spine's Phase 2, step
  4).

## Forbidden to every container in the set

Every expression below is a read; `$C` is one container of the set. Run each row against every container it applies to,
including ones a later phase adds.

| Rule | Why it holds | Detection |
|------|--------------|-----------|
| No published port | Part 2's `R-9` (inbound closed by default); the spine's `R-4`; the Docker-access part's `R-5` for the proxy | `docker ps --format '{{.Names}}\t{{.Ports}}'` shows no `->`; `docker inspect "$C" --format '{{json .HostConfig.PortBindings}}'` prints `{}` |
| No `--privileged` | The spine's `R-4`; part 2's `R-9` (no privileged agent-host process) | `docker inspect "$C" --format '{{.HostConfig.Privileged}}'` prints `false` |
| No added capability | The spine's `R-4`; part 1's `R-15` (none is required for the base's contract) | `docker inspect "$C" --format '{{json .HostConfig.CapAdd}}'` prints `null` |
| No device | The spine's `R-4`; part 1's `R-15` | `docker inspect "$C" --format '{{json .HostConfig.Devices}}'` prints `[]` or `null` |
| No host root: not uid 0, no host namespace, no bind of `/` | The spine's `R-4`; part 1's `R-1` (a fixed, unprivileged account) | `docker exec "$C" id -u` prints `1000`, not `0`; `docker inspect "$C" --format '{{.Config.User}} {{.HostConfig.PidMode}} {{.HostConfig.NetworkMode}} {{.HostConfig.IpcMode}}'` names no `host`; `docker inspect "$C" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' \| grep -xF /` prints nothing |
| No Docker socket | Part 2's `R-9`, `R-13`; the spine's `R-4`; the Docker-access part's `R-1`, `R-6` (the socket reaches exactly one container, read-only) and `R-2`, `R-7` (that container is a deny-by-default proxy) | `docker inspect "$C" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' \| grep -F docker.sock` prints nothing; `docker exec "$C" test -S /var/run/docker.sock` exits non-zero |
| No provider credential in an image | Part 3's `R-8`; part 1's `R-9`; the router part's `R-4` | `docker image inspect "$REF" --format '{{json .Config.Env}}' \| grep -E '(_KEY\|_TOKEN\|_SECRET\|PASSWORD)='` prints nothing, and the store part's `A-3` digest scan run against the image's filesystem prints `0` |
| No master key in any container | The store part's `R-3`; the spine's `R-8` | The store part's `A-3`: `docker exec "$C" sha256sum "$SECRET_TARGET_PATH"` equals the dedicated key's hash and differs from `$MASTER_KEY_FILE`'s, and the size-filtered `find … -exec sha256sum` prints `0` |

A single tripwire over the whole set:

```sh
for C in "$HOST_CONTAINER" "$ROUTER_CONTAINER" "$PROXY_CONTAINER"; do
  docker inspect "$C" --format '{{.Name}} ports={{json .HostConfig.PortBindings}} priv={{.HostConfig.Privileged}} caps={{json .HostConfig.CapAdd}} devices={{json .HostConfig.Devices}} user={{.Config.User}}'
done
```

## Inherited, not restated

- **Part 2's loopback default for its SSH listen parameter (`P-20`).** Not written down here: the host's exposure is one
  decision inside part 2, and a second copy would drift the moment that part moves it.
- **Part 1's run-contract variable names (`R-3`).** The container statements say "the base's account" and "the process
  environment"; copying the variable list would be a second declaration of a contract whose only home is the base image.
- **The store's master-key rule (its `R-3`).** Named and detected here, never re-described: restating its encryption or
  rotation procedure would duplicate the part that owns it, and the duplicate is the copy that goes stale.

## Failure Behavior

A violation is visible from outside the container, without entering it, which is what makes this a gate rather than a
diagnosis. The action is the same in every case: stop that container, never "harden" it in place.

| What you see | What it means | Immediate action |
|--------------|---------------|------------------|
| `docker ps` shows a `->` for a container of the set | a port was published; this is not the set the document describes (spine's `R-4`) | `docker stop "$C"`; find where the port entered the merged configuration and correct that file |
| `docker exec "$C" id -u` prints `0` | the run arguments or the image are wrong (part 1's `R-1`) | `docker stop "$C"`; fix the part or the merged compose and recreate — do not `usermod` inside a running container |
| A socket path or a socket bind appears | the socket reached a container that must not have one (part 2's `R-9`; Docker-access `R-1`) | Stop the container that has it and remove it; never retry with the mount made read-only — only the proxy holds the socket |
| The master key's digest is found inside a container (the store part's `A-3` prints `1`) | the master key is exposed | Stop the container, treat the master key as compromised, rotate per the store part's own procedure; do not delete the copy and continue |
| `Privileged` is `true`, or `CapAdd`/`Devices` is non-empty | the container was created outside the merged configuration | Stop it; its run arguments did not come from the parts' fragments |
| A credential-shaped value appears in an image's `Config.Env` | a credential was baked into an image (part 3's `R-8`) | Stop every container running that image and rebuild without it; removing the value at run time leaves it in the layers |

After any stop, recreate the set from the merged compose and re-run the checks: a clean verdict is what says the phase's
gate (`A-5`, `A-6`, `A-7`, `A-13`) passes, not the fact that the offending container is gone.

## Idempotency Notes

- Every check here is a read: `docker ps`, `docker inspect`, a `docker exec` query or `test`, and the store part's `A-3`.
  Re-running them gives the same verdict, and a failed check changes no state.
- Address containers by the names the merged configuration gives them and re-read them after every recreate: ids change on
  `docker compose up`, so an inspect result captured before a recreate says nothing about the container running now.
- The forbidden table is a gate, not a repair list. Applying it repeatedly converges — a clean set stays clean — and a
  violation is always resolved by stopping and re-creating from the merged configuration, which is itself idempotent.
