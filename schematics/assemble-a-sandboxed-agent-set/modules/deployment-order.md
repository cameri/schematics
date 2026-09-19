# Module: deployment-order

## Purpose

This module owns the order: every build and start edge between the parts and
their neighbours, the reason it exists, the failure it prevents, the observable
state that says it is satisfied, and what a re-run does when it is. It is the
document `R-1` is written for, and it orders the work of Phases 2–5. It is
explicitly NOT responsible for what a part contains, for what each container may
see and mount (`modules/isolation-rules.md`), or for the values two parts must
agree on (`modules/shared-contracts.md`); those modules name the parts, this one
sequences them. It owns no image, service or file of its own (`R-2`): every step
below is a step inside a part's own phases, entered through the parameter this
package hands that part.

## Inputs

- The parameter values Phase 1 resolves: `P-1 AGENT_SET_NETWORK`, `P-2 AGENT_TREE_DIR`,
  `P-4 AGENT_BASE_REF`, `P-5 AGENT_HOST_IMAGE`, `P-6 HARNESS_IMAGE`, `P-7 HARNESS_ID`,
  `P-8 ROUTER_BASE_URL`, `P-10 ROUTER_ALIAS`, `P-11 ROUTER_ALIAS_SET`,
  `P-15 DOCKER_PROXY_URL`, `P-16 DOCKER_PROXY_ALLOWLIST`, `P-17 SECRETS_KEY_DIR`, `P-18 SECRETS_STORE_DIR`, `P-19 ROUTER_SECRETS_SERVICE`, `P-20 AGENT_HOST_SECRETS_SERVICE`.
- The pins `D-1`–`D-6`, the parts whose own phases do the work below, and the host
  facts `D-7`, `D-8` the builds need. `D-9` gates no edge; `D-10` is recommended.
- Each part's own acceptance script, present and executable (`A-3`): the terminus of
  every edge whose consumer is a build or the assembled chain.
- The operator's Phase 1 decisions: the harness arm, the alias set read back from the
  router, and the allowlist the agents actually need.

## Outputs

- The edge table below, one row per edge, each with the observable that marks it
  satisfied. The phases' verify steps run exactly these checks; `scripts/verify-set.sh`
  runs the subset needing the running set (`A-9`–`A-15`).
- The order Phases 2–5 perform the work in, and each phase's skip condition reused as
  the re-run detection at the end of this file.
- No artifact: no file, image, network or container; the network is Phase 2's own step,
  the images and services belong to the parts.

## Dependencies

`D-1` (the base — its phases own the base build and its architecture guard), `D-2` (the
agent host — the host image build and the host's run contract), `D-3` (the harness layer
— the layer build, including the alias check inside it), `D-4` (the router — its
configuration and alias set), `D-5` (the store — key creation and encryption), `D-6`
(the Docker-access proxy — the proxy and its audit), `D-7`, `D-8`, `D-9`. Requirements:
`R-1`, `R-2`, `R-3`, `R-14`; acceptance rows `A-3`, `A-4`, `A-8`, `A-13`, `A-14`; Phases 1–6.

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| A build step's input does not yet exist | The phase refuses to proceed (`R-1`); the edge table names what that refusal looks like. No input is improvised |
| A part fails its own acceptance rows in isolation | The assembly stops; the part is never worked around inside the chain (`R-3`), and `A-3` names it |
| The alias set read back from the router differs from the decided list | Stop at Phase 3 and fix the router first: a set started against a different set of aliases fails per request, with every container already up |
| The store file or the service key file is missing | The container exits before its application starts (the store part's `R-9`). Restore both; never export the values into the deployment's environment |
| The proxy is not running when the host container starts | The host has no Docker path and `A-13` fails from inside it. Start the proxy, then the host |
| The host runs but a pane starts no harness | The layer was not attached, or `AGENT_HARNESS` is unset (part 2's `P-17`): rebuild the layer, or start the host from `P-6 HARNESS_IMAGE`, never from `P-5 AGENT_HOST_IMAGE` |
| A part is upgraded and a chain row fails | A pin move, not an edit (Phase 6's skip condition): re-pin, rebuild from that part upward, re-run the script |

## The Edges

Every edge the set depends on, once each. `R-1` names the first four; the rest
are what Phases 2–5 and `R-3` add to them.

| Edge (from → to) | Why the edge exists | The failure it prevents | How you know it is satisfied |
|---|---|---|---|
| the base reference (`P-4 AGENT_BASE_REF`) exists → the host image build (Phase 4 step 2; part 2's phases) | The host image is built `FROM` that exact reference and inherits its account, entrypoint, working directory and `AGENT_*` contract | A build that stops at `FROM`, or a base carrying a contract the other parts were not written against | `docker image inspect "$AGENT_BASE_REF"` exits 0; for a published base, `docker buildx imagetools inspect "$AGENT_BASE_REF" --format '{{.Manifest.Digest}}'` prints the digest the reference carries |
| the host image (`P-5 AGENT_HOST_IMAGE`) exists → the harness layer build (Phase 4 step 3; the layer part's phases) | The layer is built `FROM` the host image and adds exactly one CLI to it | A layer built on an absent or wrong base, producing a `HARNESS_IMAGE` the host cannot run | `docker image inspect "$AGENT_HOST_IMAGE" --format '{{.Id}}'` exits 0, and part 2's own acceptance script reports the inherited account, working directory and entrypoint |
| the router is running and serving `P-11 ROUTER_ALIAS_SET` → building and starting the set (this composition's gate: Phase 3 step 3, the bring-up script's step 7; optionally part 3's build-time reachability check, its `P-11`) | The composition reads the router's own model list back and refuses to start a set whose aliases are not in it, so an alias mismatch stops the deployment at the gate rather than at the first request | A running set whose configured alias no provider on this router serves — found only after an agent pane fails its first model call | `curl -fsS "$ROUTER_BASE_URL/health/liveliness"` answers, then `curl -fsS -H "Authorization: Bearer $ROUTER_API_KEY" "$ROUTER_BASE_URL/models" \| jq -e --arg a "$ROUTER_ALIAS" '.. \| objects \| select(.id?) \| .id \| select(. == $a)'` succeeds (the header carries the variable `P-9` names; its default is `ROUTER_API_KEY`). `A-4` asserts the edge by building with the router stopped |
| the store's key material exists → any container that decrypts at boot (the router and the host; Phase 3 step 1 and Phase 5 step 2 — the store part's phases own key creation and encryption) | Both containers read their values from the store at boot; the material is what makes that read succeed instead of yielding an empty environment | A container that starts with an empty environment and fails later, where the cause is no longer visible | The store files exist where `P-17 SECRETS_KEY_DIR` and `P-18 SECRETS_SERVICE_NAME` put them, in the mode the store part's parameter requires and readable by the deploying user; `A-14` is the observable — with store and key the container reaches its application, without them it exits non-zero |
| the Docker-access proxy is running → the host container starts (Phase 5 steps 1–2; the Docker-access part's phases) | `P-15 DOCKER_PROXY_URL` is the only Docker path the agents have, and the host container is its first consumer | An agent with no Docker at all, or the reflexive "fix" of mounting the socket, which `R-4` refuses | `docker inspect --format '{{.State.Running}}'` on the proxy container reports `true` before the host starts, and the part's own audit matches `P-16 DOCKER_PROXY_ALLOWLIST`; once the host is up, `DOCKER_HOST="$DOCKER_PROXY_URL" docker version` answers from inside it (`A-13`) |
| the shared network (`P-1 AGENT_SET_NETWORK`) exists → any service joins it (Phase 2 step 1; every service started in Phases 3 and 5) | It is the only path between the set's services that is not a bind mount, and all in-network addressing is by service name | A service that cannot be attached, or one on a default bridge where the names in `P-8` and `P-15` resolve to nothing | `docker network inspect "$AGENT_SET_NETWORK" >/dev/null` exits 0 before the first service starts, and the merged compose configuration attaches every service to that one name and no other |
| each part's own acceptance rows pass → the chain is assembled (`R-3`; Phase 5 step 4 and Phase 6 step 2) | A part verified alone can be attributed; a part first exercised inside the chain cannot | A chain failure whose cause is a part nothing ever tested in isolation — the expensive kind, because the glue is the obvious suspect | Each part's own acceptance script exits 0 where this host can run it and prints `SKIP <reason>` where it cannot (`A-3`); a failure stops the assembly rather than being worked around |

`D-9` is deliberately absent: a missing provider credential gates no build and no start, and changes only whether `A-15` completes or skips.

## The Order the Work Happens In

Phase 1 resolves the parameters; everything else is this list. Each step names
the phase it belongs to and the part whose own phases perform it.

1. **Phase 2** — create the network `P-1`; create `P-2 AGENT_TREE_DIR` owned as the
   base image's account ids require (part 1's `P-4`/`P-5`; the host part's phase
   re-derives them); place the store's files where `P-17`–`P-20` say (one directory per store service under `P-18`, one `<service>-keys.txt` under `P-17`).
2. **Phase 3 step 1** — deploy the store's material for the router service: the
   store part's phases own key creation and encryption.
3. **Phase 3 step 2** — deploy the router (`D-4`): the router part's phases own its
   configuration, including the alias set `P-11`.
4. **Phase 3 step 3** — wait for the router's health gate, read the alias set back
   and compare it with the decided list. Nothing is built yet, which is the point.
5. **Phase 4 step 1** — obtain the base: consume a published one, or build it from
   `D-1`; the base part's phases own that build and its architecture guard.
6. **Phase 4 step 2** — build the host image from `D-2` with `AGENT_BASE_REF` set to
   the complete reference; the host part's phases own the build.
7. **Phase 4 step 3** — build the harness layer from `D-3` with the router up; the
   layer part's phases own the build, including the alias check inside it.
8. **Phase 4 step 4** — confirm the layer's configuration (`AGENT_HARNESS` set, no
   `ENTRYPOINT`, no `CMD`, no credential-shaped file — `A-8`).
9. **Phase 5 step 1** — deploy the Docker-access proxy (`D-6`) with `P-16`, on its
   own network; the Docker-access part's phases own it.
10. **Phase 5 step 2** — start the host container from `P-6 HARNESS_IMAGE`, joined to
    `P-1` and to the proxy's network, tree bind-mounted, credential from the store.
11. **Phase 5 step 3** — confirm the run contract: boot program starts, herdr session
    alive, one workspace per `P-3 AGENT_IDS` entry (part 2's phases own it).
12. **Phase 5 step 4, then Phase 6** — run the parts' acceptance scripts this host can
    run (`A-3`), then `scripts/verify-set.sh`, which proves the chain, not the parts.

## When the Order Is Violated

Both image builds check their input before producing anything, and the third
build-time edge is checked inside the same build as the second. The failures are
cheap: no image is produced and no container is started.

| Out-of-order attempt | Observable failure | Why it is cheap |
|---|---|---|
| Build the host image with `AGENT_BASE_REF` unset, or naming a reference the daemon cannot resolve | The build fails at `FROM`, before any instruction in the host part's build runs | One failed `docker build`: no layer worth keeping, no image, and nothing downstream can have consumed a wrong base |
| Build the harness layer with `AGENT_HOST_IMAGE` naming an image the daemon does not have | The build fails at `FROM`; no layer of the harness build executes | Same shape: one failed build, no image, no container — and the host image is unchanged |
| Start the set with the router stopped, or with an alias it does not serve | This composition's own gate refuses before anything starts (the bring-up script's step 7, `A-11`), and an alias the layer cannot reach at build time fails that build only when the deployment asked for the check (`A-4`, part 3's `P-11`) | Found at run time instead, the mistake surfaces as an agent pane whose model calls fail with everything else already deployed. A credential cannot be a build argument, so the build cannot decide alias membership — the gate is the composition's |

The run-time edges are loud rather than silent: a store without its key exits
before its application starts (the store part's `R-9`), a host started before the
proxy has no Docker path (`A-13`), a service started before the network cannot
attach. The order exists so no build is paid for twice.

## Idempotency Notes

Every edge above is detected by a read, never assumed: an image-exists check, a
health gate, or `docker network inspect`. That is what makes re-running a phase
safe (`R-14`), and a re-run starts at the first edge whose check fails, not at
Phase 1.

- **The base reference.** `docker image inspect "$AGENT_BASE_REF"` exits 0, or the
  published reference still resolves to the digest `P-4` carries.
- **The host image and the harness image.** Phase 4's skip condition: each exists
  at the intended reference with its build inputs unchanged. Compare provenance
  against the pins (`docker image inspect "$AGENT_HOST_IMAGE" --format '{{index
  .Config.Labels "org.opencontainers.image.revision"}}'`), as Phase 6 does.
- **The router.** Phase 3's skip condition: it already runs and `GET /v1/models`
  returns the decided set; a gate that still answers is not re-proved by a restart.
- **The store's key material.** A no-op while the store files sit there in the
  expected mode and `A-14`'s pair holds; the store part recreates them if not.
- **The Docker-access proxy.** `docker inspect --format '{{.State.Running}}'` on it
  reports `true` and the part's own audit matches `P-16`; an allowlist change
  restarts the proxy, never the set.
- **The shared network.** Create it only when absent — `docker network inspect
  "$AGENT_SET_NETWORK" >/dev/null 2>&1 || docker network create
  "$AGENT_SET_NETWORK"` — and let it be the last thing removed (`R-13`).
- **The acceptance rows.** Re-running the parts' scripts and `scripts/verify-set.sh`
  gives the same verdict (`R-14`); a skipped row keeps its reason, never a pass.
