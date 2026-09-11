# Module: host-network consumers

Some consumers cannot join the proxy's internal network the normal way.
A container run with `network_mode: host` (common for agents that report
host-level metrics — network throughput, disk I/O — that are only
accurate from the host's own network namespace, not a container's virtual
interface) shares the host's network namespace instead of getting its own.
It has no place in `networks:`, so it cannot resolve `socket-proxy` by
service name through Docker's embedded DNS, and Compose rejects a service
definition that combines `network_mode` with `networks`.

This module states the exception: how such a consumer reaches the proxy
without weakening R-5 (no published ports).

## The pattern

1. Give the internal network a fixed subnet (`ipam.config.subnet`) instead
   of letting Docker pick one.
2. Assign the proxy service a static address inside that subnet
   (`networks.<name>.ipv4_address`) — this is P-7.
3. Point the host-network consumer's Docker endpoint at
   `tcp://<static-ip>:2375` directly, instead of `tcp://socket-proxy:2375`.

## Why this doesn't violate R-5

`internal: true` on the network removes only the outbound
masquerade/default-route rule for containers attached to it — it does not
prevent the host kernel from routing to the network's subnet. Creating the
network still installs a host route to it via the bridge interface, exactly
as it would for a host-to-container-port reachability check on any other
bridge network. A host-network consumer shares the host's routing table, so
it can reach the static IP directly. No port is published on the proxy
service to make this work; the reachability comes from the host's own
routing, not from a `ports:` entry. `docker port socket-proxy` still
reports nothing (A-5 holds).

## Verification

- `docker inspect socket-proxy` shows no `HostPort` entries (A-5, unchanged).
- From the host-network consumer: `curl -o /dev/null -w '%{http_code}'
  http://<static-ip>:2375/_ping` returns `200`.
- The static IP is stable across `docker compose up -d socket-proxy`
  recreations (Docker preserves `ipv4_address` assignments across
  recreates as long as the compose file is unchanged).

## When not to reach for this

Only use a static IP for a consumer that genuinely requires
`network_mode: host` for its own purpose. Confirm that reason first (read
the consumer's own docs — don't assume). A consumer that merely defaults
to host networking, with no host-level-metrics requirement driving it,
should instead be moved onto the internal network like any other consumer
(R-5/P-5 as written) rather than carrying this exception forward.
