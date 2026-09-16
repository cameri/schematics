# Module: exposure contracts

The per-service contract is the heart of this schematic: how one service
becomes one hostname on the tailnet. TSDProxy offers two mechanisms, and
this deployment uses exactly one per service (R-4). Both produce the same
observable result — `https://<name>.<TAILNET>` proxies to the service — and
differ only in where the declaration lives.

## Contract 1: docker labels

The declaration lives on the target service's compose entry (or
`docker run` invocation). TSDProxy's docker provider watches the Docker
socket (P-3) for containers carrying `tsdproxy.enable=true`.

```yaml
services:
  myapp:
    image: myapp:tag
    networks:
      - tsdproxy          # P-4 — the shared network (see target-reachability)
    labels:
      tsdproxy.enable: "true"
      tsdproxy.name: "myapp"
      # optional (uncommon): pick the port/protocol mapping explicitly
      # tsdproxy.port.1: "443/https:8080/http"
      # optional: quiet the access log for this container
      # tsdproxy.containeraccesslog: "false"
```

Minimum viable declaration: `tsdproxy.enable` + `tsdproxy.name`. Without an
explicit `tsdproxy.port.N` the proxy auto-detects the target port from the
container's exposed ports (this is the common case and why labels are the
upstream headline feature — one label pair exposes a service).

### Rules specific to labels

- The service MUST be attached to P-4's network (or reachable via P-5 —
  see target-reachability), because the docker provider locates targets by
  container IP on that network.
- Label changes require a proxy restart to take effect:
  `docker compose restart tsdproxy`. There is no hot reload for labels.
- Removing exposure = removing the labels (and optionally the network
  attachment) + restart. The tailnet hostname disappears with the proxy's
  next container scan.
- The proxy needs the docker socket (P-3) mounted read-write to enumerate
  and inspect containers.

## Contract 2: list-file entries (config entries)

The declaration lives in a YAML file under CONFIG_DIR (P-9), registered in
tsdproxy.yaml's `lists:` section (v2) / `files:` section (v1 — see
config-schema). Each entry key is the hostname; its value names the target.

```yaml
# <CONFIG_DIR>/services.yaml  (registered as a list in tsdproxy.yaml)
myapp:
  ports:
    443/https:
      targets:
        - http://myapp:8080     # service DNS name on the shared network
#  dashboard:                   # optional: label/icon for the proxy dashboard
#    label: My App
```

### Rules specific to list files

- The entry key is the hostname (`myapp` → `myapp.<TAILNET>`).
- The target URL is arbitrary: a service DNS name on the shared network
  (`http://myapp:8080`), any other reachable address, or even a `tcp://`
  target for non-HTTP proxying (see upstream docs).
- Changes to a list file hot-reload: TSDProxy watches the file and updates
  proxies without a restart. Only changes to tsdproxy.yaml itself (adding
  a file to `lists:`) need a proxy restart.
- Removing exposure = removing the entry; the hot reload drops the
  hostname.
- The docker socket is NOT required for list-file entries (the file
  provider does not inspect containers) — but the source deployment mounts
  it anyway because it also runs the docker provider. If a deployment is
  files-only, the socket mount can be dropped (see removal/scope notes in
  SCHEMATIC.md; the source's dual-provider setup is preserved there).

## Choosing between them

| Consideration | labels | files |
|---------------|--------|-------|
| Declaration location | on the service (compose) | central config file |
| Per-service change applies | proxy restart | hot reload |
| Needs docker socket | yes | no |
| Target selection | container IP on P-4 (autodetected port) | any URL you write |
| Non-HTTP (TCP) targets | upstream v2 port options | `tcp://` targets |
| Best for | services you own in compose, many services | mixed targets, non-compose services, ops-reviewed config |

The default is `files` (P-10) because that is what the source deployment
runs (its exposure is entirely config entries in category files). A
deployment that prefers upstream's zero-config path picks `labels`. Mixing
is possible but discouraged: R-4's uniqueness rule becomes harder to audit
when declarations live in two places — if mixing, keep the hostname
namespace disjoint and document which contract owns which names.

## Idempotency

- labels: re-applying the same label set is a no-op; a restart re-scans and
  converges. No state accumulates server-side beyond the tailnet node,
  which the proxy manages.
- files: re-writing the same entry is a no-op (hot reload converges);
  deleting an entry removes the node. TSDProxy reconciles the file contents
  with the tailnet on every reload, so drift between the file and the
  tailnet self-heals on the next change event.

## Removal Notes

Each contract's removal is stated above (drop labels + restart / drop entry
+ hot reload). Cross-cutting: the tailnet node for a removed hostname is
deleted by the proxy on the next scan/reload; if the proxy is stopped while
a hostname is being removed, the node lingers until the proxy next runs —
see SCHEMATIC.md's Removal section for the admin-console confirmation step.