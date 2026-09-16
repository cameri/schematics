# Module: target reachability

The proxy must reach each target service. This module is the map from
"what the target is" to "how the proxy reaches it" — the R-7 contract that
every reachability choice is documented, not guessed.

## The shared-network model (the source deployment's pattern)

In the reference deployment every exposed service attaches to the same
docker network as the proxy (P-4, named `tsdproxy` there; created once in
the root compose file). On that network:

- Docker's embedded DNS resolves service names to container IPs, so a
  list-file entry can name the target directly:
  `url: http://photos-app:8080` (v1) /
  `ports: 443/https: {targets: [http://photos-app:8080]}` (v2).
- The docker provider (labels contract) locates containers by inspecting
  the socket: for each labeled container it tries connections to the
  container's IPs on the shared network until one answers
  (`tryInternalPort`), then the bridge gateway + published port, then the
  image's declared EXPOSE port — in that order (upstream source,
  v1.4.7; v2 keeps the same intent).

Rule: a target reachable by service name on P-4 needs nothing more. This
is the default and the common case.

## When the target is NOT on the shared network

Three situations, three answers:

1. **Target on a different compose network**: either join P-4 to that
   service too (add the network to its compose entry — the least surprise,
   keeps service-name resolution), or fall back to P-5 (below). Joining is
   preferred: it preserves DNS names and avoids address guessing.
2. **Target in `network_mode: host`**: it has no container IP on any
   docker network. Reach it via P-5: the docker bridge gateway
   (discovered with
   `docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'`)
   plus the published port. The source deployment's
   `targetHostname: 172.31.0.1` is TSDProxy's own product default for
   that field — the deployment kept it because its bridge gateway
   happens to match; your value is discovered, not assumed. This only
   works if
   the service publishes a host port — a host-network service with a
   private listener is unreachable from another container unless the
   listener binds 0.0.0.0 and the port is published.
3. **Target on a remote machine (non-docker, other host)**: the list-file
   entry takes any resolvable URL — an internal DNS name, a static LAN IP,
   or an address routed through the tailnet from the proxy's own vantage.
   Document it in the entry; the proxy is a plain HTTP/TCP client to it.

## Verifying reachability (A-7)

From inside the proxy container (or any container on P-4):

```sh
docker compose exec tsdproxy sh -lc 'getent hosts <service>' 2>/dev/null ||
  docker compose exec <p4-container> getent hosts <service>
```

or a direct probe when names resolve but connections fail:

```sh
docker compose exec tsdproxy sh -lc 'curl -fsS -o /dev/null http://<service>:<port>'
```

Every target's chosen path (service name, P-5 gateway, external URL) is
recorded next to the exposure declaration — see A-7's documentation step.

## Idempotency Notes

Re-running the reachability checks is read-only and deterministic; the
checks either pass or name the failing hop (DNS vs connect). There is no
state to converge.

## Removal Notes

Removing an exposure declaration removes the proxy's need for the target;
the service's network attachment (P-4) may be dropped once no other
declaration uses it. The proxy itself never required the socket for
list-file targets (the source deployment mounts it for its docker
provider; a files-only deployment can drop the mount).