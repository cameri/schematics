# Module: end-to-end-acceptance

## Purpose

This module owns the one test that fails when the chain is broken and passes
when it works: `scripts/verify-set.sh`. It exists because every other check in
this package's neighbourhood is a check of a part. A deployment whose parts each
pass their own acceptance rows can still be assembled wrongly — an alias the
router does not serve, a credential that arrives in the wrong container, a
service on the wrong network, a socket where the rules say there is none — and
none of those failures belongs to any part. This module's rows are the ones that
observe the whole chain: an agent pane runs the harness, and a request from that
pane reaches the router by alias.

It also owns the honesty rule that makes the result usable: a row the host
cannot run prints `SKIP` with its reason and is never counted as a pass
(`R-11`). A chain test that claims a green it did not obtain is worse than one
that reports a gap.

## Inputs

- The Parameters table's deployment values, passed as environment variables:
  `AGENT_SET_NETWORK`, `AGENT_TREE_DIR`, `AGENT_IDS`,
  `AGENT_HOST_IMAGE`, `HARNESS_IMAGE`, `HARNESS_ID`, `HARNESS_CONFIG_PATH`,
  `ROUTER_BASE_URL`, `ROUTER_CREDENTIAL_ENV`, `ROUTER_ALIAS`,
  `ROUTER_ALIAS_SET`, `DOCKER_PROXY_URL`, `DOCKER_PROXY_ALLOWLIST`,
  `HOST_CONTAINER`, optionally `ROUTER_CONTAINER` and `PROXY_CONTAINER` (without
  the proxy's name the proxy is not inspected, so `A-5` SKIPs rather than passing
  over a subset of the set and `A-13` SKIPs rather than passing on half its
  contract), optionally `AGENT_WORKSPACE_DIR` — only the root a pane's workspace
  is checked against, since each pane's own value is read from that pane's
  process environment and no default is assumed for it — and the
  arm-specific build arguments `A-4` supplies to the layer
  (`ROUTER_FAST_ALIAS`, `HARNESS_HOME`, `HARNESS_CONTEXT_WINDOW`,
  `HARNESS_MAX_OUTPUT_TOKENS`, with defaults where the layer has one).
- The package's own `SCHEMATIC.md`, which the pin row reads (`A-1`), and the git
  checkout it lives in, for reachability.
- The parts' compose fragments, in merge order (`COMPOSE_FILES`), the service
  names the merge must produce (`EXPECTED_SERVICES`, optional — without it `A-2`
  checks that the merge works, not that the set is complete, so a fragment left
  out of the list goes unnoticed), and the parts' own acceptance scripts
  (`PART_SCRIPTS`, as `name:path` entries), for `A-2` and `A-3`.
- Four opt-ins, each a row that would disturb a running deployment and therefore
  runs only when asked: `ALLOW_BUILD_PROBE=1` (`A-4`), `ALLOW_ROUTER_STOP=1`
  (`A-12`), `ALLOW_CONTAINER_PROBE=1` (`A-14`), `ALLOW_TEARDOWN=1` (`A-16`), and
  `PROVIDER_CREDENTIAL=1` (`A-15`).
- The runtime: `docker` for the inspect-based rows. No part's image is required
  for a row that only reads configuration.

## Outputs

- One line per row on standard output: `PASS <row> <what>`, `FAIL <row> <what>`,
  or `SKIP <row> <reason>`, followed by a summary line
  `<n> check(s): <f> failed, <s> skipped`.
- An exit status: `0` when no row failed, `1` when a row failed, `2` when a
  required input is unset.
- A temporary file inside the host container
  (`/tmp/agent-set-models`) written by `A-11` and read back in the same row. The
  script creates one container in `A-14` and removes it, and removes one
  throwaway image tag if `A-4` built it.

## Dependencies

- `D-1` … `D-6` — the pinned parts. `A-1` verifies their pins; `A-3` runs their
  own acceptance scripts; the rest of the rows observe the parts in a running
  chain.
- `D-7` — the runtime, for every row that inspects a container or an image.
- `D-9` — a real provider credential, needed only by `A-15`.

## Failure Behavior

| Row | What it observes | What makes it FAIL | When it SKIPs, and why that is honest |
|-----|------------------|--------------------|---------------------------------------|
| `A-1` | every pin in the Dependencies table: commit reachable from `HEAD`, file present at that commit, `sha256` equal to the row, version equal to the row | any pin unreachable, missing, or mismatched — the failure names the row | the package is not inside a git checkout: the row checks a repository, and a copy of the package cannot answer it |
| `A-2` | the glue file's `services:` entries carry only `networks:`, the merged configuration renders, it defines every service in `EXPECTED_SERVICES`, and it defines no service outside that list | the glue declares an `image`, `command`, `entrypoint`, `environment`, `user`, or mount for a service; the merge fails on the files themselves; an expected service is absent; or a service outside `EXPECTED_SERVICES` is present — the store part's `compose-secrets.yml`, whose `services.myservice` no part owns, is the case this catches | `COMPOSE_FILES` is unset, a fragment is missing from disk, the parts' own variables are not supplied to the check, or `EXPECTED_SERVICES` is unset — an incomplete environment cannot render the parts' files, and that is a gap in the check's inputs. **Second input limit:** without `EXPECTED_SERVICES` the "and nothing else is defined" half cannot run, so the row reports the merged service count and does not claim completeness. **Stated limit:** two fragments that contribute the same service (the host part's and the harness layer's both define `agent-host`) are distinguished only by their fields, which this row does not compare — omitting one of them is caught by field loss, not by name |
| `A-3` | each part's acceptance script is present and exits 0 | a script exits non-zero — a part that fails its own rows must stop the assembly — or a script named in `PART_SCRIPTS` is not on disk, which is R-3's gate unmet rather than a check that could not run (`bring-up.sh`'s step 9 refuses on the same condition) | `PART_SCRIPTS` is unset: with no script named, neither this row nor the assembly's own gate can verify a part, and both print that gap instead of a pass |
| `A-4` | a harness build whose endpoint check is pointed at an address nothing answers at fails with the guard's code `78` and a line naming the parameter, with every argument this arm requires supplied | the build succeeds, or it fails on a missing argument — which is not the edge this row exists for, and is reported as a failure rather than a pass | the probe is not enabled, the build context is not supplied, or docker refuses the build on this host |
| `A-5` | no container of the set — read from `docker ps -a`, so a stopped one is inspected too — publishes a port, is privileged, holds an added capability or device, or mounts the Docker socket; the proxy included, whose one read-only socket mount is the sanctioned exception | any of those appears in `docker inspect`, a second socket mount exists, or the proxy's socket mount is writable | no container of the set is running, or a container cannot be named or its inspect read (denied, empty, no `priv=` field): the row SKIPs naming it rather than reporting the set clean from a subset |
| `A-6` | the only read-write host path in the set is `AGENT_TREE_DIR` | a second read-write host path appears | as `A-5` |
| `A-7` | the host container's process uid is not 0, and every other container of the set has its `id -u` read and reported | the host container's process runs as uid 0 | a uid cannot be read in a container (denied, absent): the row SKIPs naming it, because an unread container is not a clean one. A uid of 0 inside another container is reported in a note rather than failed — R-4 forbids **host** root, and those containers hold no host namespace and no bind of `/` — naming the two parts that ship that way (the proxy, which states it in its own `SCHEMATIC.md` and is the one container that does hold the socket, read-only and sanctioned by `A-5`; and the router, whose `Containerfile` declares no `USER`) |
| `A-8` | `AGENT_HARNESS` is set to `HARNESS_ID`, the image's entrypoint and `CMD` are the base image's unchanged (compared against `AGENT_HOST_IMAGE`, because an image built `FROM` another always reports it), the image history names no credential, and a scan inside a container made from the image finds no credential-shaped file or value | `AGENT_HARNESS` is missing or different, the run contract differs from the base's, a credential-shaped value is in the history, or the scan finds one | the image is not present locally, or the host refuses to create the scanning container: the row reads an artifact that does not exist yet |
| `A-9` | a process inside the host container runs the harness CLI, and each such process's own `AGENT_WORKSPACE_DIR` — read from that process's environment, one per pane — ends in `workspace` with a rostered agent's directory name, with the pane's working directory equal to it and inside `AGENT_WORKSPACE_DIR` when that root is supplied | no such process exists, or one carries no per-pane workspace, sits outside the supplied root, is not a rostered agent's, or has a working directory other than its workspace | the host refuses `docker exec` into the container |
| `A-10` | the pane's process carries the credential under `ROUTER_CREDENTIAL_ENV`'s derived name and no other credential-shaped variable (**names only, never values**), and the arm's own configuration — `ANTHROPIC_BASE_URL`/`ANTHROPIC_MODEL`/`ANTHROPIC_DEFAULT_HAIKU_MODEL` for Claude Code, `base_url`/`model`/`env_key` for Codex — names `P-8`'s endpoint for that arm, `P-10`'s alias, `P-12`'s fast alias, only members of `ROUTER_ALIAS_SET`, and no provider credential or key; a `ROUTER_BASE_URL` present in the environment is compared with `P-8`'s root | the credential is absent, a second credential-shaped variable is present, or any configured value differs from the parameter it must equal | the config file is unreadable or absent, no pane process exists to read, or the host refuses `docker exec`; a missing `ROUTER_BASE_URL` in the environment is a note, not a skip — this composition's endpoint lives in the CLI's configuration |
| `A-11` | a request from inside the host container (the container the panes run in, not the pane's own shell) to `<ROUTER_BASE_URL>/v1/models` (P-8 is the root), made with the credential the pane's own process holds, returns 200 and the model list's `id` values include `ROUTER_ALIAS`; the same request without the credential is refused | the request fails or returns another status, the alias is absent from the ids (another field's metadata does not count), or the credential-free request is not refused | the container carries no credential (the store did not inject it), which is a finding about `P-20`'s store, not about the chain; or the id values cannot be read from the answer, in which case membership is not asserted |
| `A-12` | with the router stopped, a request from inside the host container (as `A-11` issues it) fails visibly and nothing else answers | the request succeeds while the router is down | not enabled, or `ROUTER_CONTAINER` is unset: stopping a service is a deliberate act, not a side effect of a check |
| `A-13` | the host container's own environment carries `DOCKER_HOST` (read from a pane process, falling back to the container's configured environment — never injected by the check), and it reaches the daemon through that value, its filesystem has no Docker socket, the proxy refuses a verb outside the allowlist in terms that name its own decision, every network the proxy is on is internal, and the router cannot resolve the proxy by name | the container carries no `DOCKER_HOST`, the daemon is unreachable through it, a socket is present, a privileged run is not refused, the proxy sits on a non-internal network, or a service of the set shares the proxy's network | the host refuses `docker exec`, the proxy does not answer, or the probe's answer is a daemon error that cannot be attributed to the proxy — which is not evidence of a refusal; and without either `PROXY_CONTAINER` or `ROUTER_CONTAINER` the whole row SKIPs, because the proxy's network contract is the point of that half and a green row over an unchecked contract is the failure this row prevents |
| `A-14` | a container started on the composition's own boot command (`sops exec-env <file> <program>`) without its key material exits non-zero and its own output names the key path the probe supplied; the log is read while the container still exists | the container keeps running, or exits 0 | the probe is not enabled, the host refuses to create the container, or the failure does not name the key path the probe supplied — a message about the encrypted store file it also cannot open is not evidence about the key, and an unrelated failure is not evidence about the store. Stated limit: the probe exercises the wrapper and its decryptor, not the deployment's encrypted file, which needs the real key |
| `A-15` | one real completion through the alias returns 200 with a completion body (the `choices` the API carries), requested with the credential the pane's own process holds — issued from the host container, the way any router client issues one | the completion returns another status, or returns 200 without a completion body | no real provider credential is configured. Never asserted: the row states the gap instead of inventing a result |
| `A-16` | after teardown the set's containers are gone (running or stopped, the proxy included), the network's removal is verified, every part still passes its own script, and the agent tree is intact | `docker compose down` exits non-zero, a container survives, the network still exists after `docker network rm`, a part named in `PART_SCRIPTS` no longer passes its own script (or is no longer on disk), or the tree is gone | teardown is not enabled, or `COMPOSE_FILES` is unset so the composition cannot be detached: bringing the set down is a deliberate act |

## Idempotency Notes

- Every row is a read, except the four opt-in rows, and each of those removes
  what it created: `A-4` builds one throwaway tag the trap deletes, `A-14`
  removes its probe container, `A-12` starts the router again after stopping it
  and fails if it did not come back, and `A-16` is a teardown by definition.
- Re-running the script gives the same verdict for the same deployment state. A
  row cannot pass because a previous run left something behind: no row reads a
  file another row wrote, except `A-11`'s two steps inside one row.
- The rows are ordered so that a failure early (a pin that does not resolve) does
  not stop the later observations: the script reports every row it can reach, so
  one run gives the whole picture rather than the first problem.
- Skipped rows are counted separately and named. A run with skips exits 0 when
  nothing failed, and prints that skipped rows are not passes, so a reader
  cannot mistake a partial run for a complete one.

## What this module deliberately does not prove

- **That a part is correctly implemented.** That is the part's own acceptance
  script, run by `A-3`. These rows observe the parts from outside.
- **The harness CLI's interactive behaviour.** A portable check cannot drive an
  interactive agent session; `A-15` therefore proves the router's path to its
  provider using the credential a pane's own process holds, and says so in its
  own output.
- **A platform the host cannot run.** Nothing here emulates a second
  architecture: a deployment that needs it runs the parts' own rows on native
  hardware, and reports what it could not run.
- **That a skipped row would pass.** The script never infers a result from the
  absence of a failure.
