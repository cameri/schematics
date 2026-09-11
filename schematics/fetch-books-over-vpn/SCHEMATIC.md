<!-- Recommended: use the schematics@cameri/schematics plugin to build this schematic -->
---
name: fetch-books-over-vpn
version: 0.2.1
status: published
description: Privately fetching books and audiobooks - gluetun as a structural VPN kill switch with Deluge sharing its network namespace, Chaptarr automating grabs, and a companion IP-sync service for indexers that allow exactly one seedbox IP. Every UI is tailnet-only; nothing public.
---

# Schematic: Fetch Books Over VPN (Gluetun, Deluge, Chaptarr, Mousehole)

## Applicable Context

**Must discover locally:**

- A VPN provider supported by gluetun (provider name, auth: wireguard
  key or OpenVPN creds) and whether it supports port forwarding
- A media root directory tree: `downloads/incomplete`,
  `downloads/complete`, plus the target library folders the arr stack
  will import into
- The tailnet's router IP for binding tailnet-only published ports
- Indexer(s): which ones, whether they gate IP changes (the seedbox-IP
  sync service exists only because one of ours does)

**May assume (with risk):**

- *arr-family automation for indexer search and import (Chaptarr for
  books and audiobooks; the design applies to any *arr)
- LinuxServer.io images for the client

**Must not change:**

- The ZFS/media dataset permissions (uid 1000)
- Any other stack's networks

## Scope

**In scope:**

- The VPN sidecar pattern: one gluetun, multiple clients sharing its
  network namespace
- The structural kill switch and how to prove it
- Chaptarr with root folders and its proxy wired to gluetun
- The IP-sync service for single-IP-gated indexers (optional per indexer)

**Out of scope / non-goals:**

- The serving side (see `serve-books-using-containers`); this stack only writes into
  download folders, it never serves media
- Usenet (SABnzbd lives on another host here; imports via a read-only
  sshfs mount are an integration option, not core)
- Prowlarr itself (external dependency; it syncs indexers into Chaptarr)

**Preservation List (reverse-engineered):**

- Deluge and Mousehole MUST share gluetun's network namespace
  (`network_mode: "service:gluetun"`), never a shared bridge network
- The port-forward hook MUST re-push the forwarded port on every gluetun
  port rotation (Deluge 2.x binds `listen_interfaces`, not
  `listen_ports`; `random_port` stays false)
- UI surfaces are tailnet-only, bound to the tailnet IP, never public
- Secrets via the encrypt-container-secrets pattern with per-service key names

## Requirements

- **R-1**: All torrent client traffic MUST traverse the VPN, and VPN
  loss MUST fail closed: with the tunnel down, the torrent client MUST
  be unreachable from outside and MUST NOT egress. Achieved
  structurally (shared netns + gluetun's firewall), never by per-app
  settings.
- **R-2**: Every UI and control plane (Deluge web, Chaptarr, Mousehole)
  MUST be reachable only on the tailnet: published, when at all, bound
  to the tailnet IP, or proxied through a tailnet-gated proxy. No port
  is publicly routable.
- **R-3**: Chaptarr's own outbound indexer/API traffic MUST ride the VPN
  via gluetun's HTTP proxy; only the torrent client's traffic is
  required to, but consistent egress is the default.
- **R-4**: If any indexer in use allows exactly one seedbox IP, an IP-sync
  service MUST keep that IP equal to gluetun's current exit IP, and MUST
  update on every gluetun IP change (rotation or reconnect).
- **R-5**: The forwarded VPN port MUST be applied to the torrent client
  within minutes of gluetun receiving it, and again on every rotation.
- **R-6**: Credentials (VPN, Deluge web password, IP-sync cookie/state)
  MUST use the `encrypt-container-secrets` pattern: committed encrypted `.env`,
  per-service age key, secrets injected at boot. Per-service secret
  NAMES are mandatory (shared compose secrets namespace).
- **R-7**: Download directories MUST separate incomplete and complete
  states, and the completed dir is the integration point with importers
  (same host path mounted into both stacks).
- **R-8**: Images MUST be digest-pinned.
- **R-9**: Containers that depend on gluetun MUST start only after it is
  healthy (condition-based), and MUST be recreated to rejoin the netns
  after a gluetun recreate - the runbook documents this sequencing.

## Design Principles Binding the Implementation

The ten binding principles apply as published in the repository README.
Implementation-specific binding choices:

- The kill switch is structural, not configured: sharing gluetun's netns
  means there is no interface for the torrent client to leak from. A
  kill-switch checkbox in Deluge's own settings is not a substitute and
  must not be relied on.
- One VPN sidecar serves all VPN-needing containers of the stack; each
  additional consumer is a `network_mode` line plus a port-forward line,
  not a second tunnel.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 | Docker Engine + Compose v2 | Runs the stack | `docker compose version` | Blocker |
| D-2 | A gluetun-supported VPN account | The tunnel and the kill switch | gluetun's provider wiki; credentials into `.env` | Kill switch closes; fetching stops loudly |
| D-3 | gluetun image | The sidecar | Digest-pinned | Everything torrent-side stops |
| D-4 | Deluge (linuxserver image) | The torrent client | Digest-pinned | Imports stall |
| D-5 | Chaptarr image | Books/audiobooks automation | Digest-pinned | No automated fetching |
| D-6 | Prowlarr (or equivalent indexer manager) | Indexer definitions into Chaptarr | May live on another host; out of scope | Chaptarr works only with manual grabs |
| D-7 | Mousehole image (optional) | Seedbox-IP sync for single-IP indexers | Digest-pinned; omit if no such indexer | The gated indexer fails announces |
| D-8 | Tailscale (or tsdproxy) on the host | Tailnet-only UI access (R-2) | Existing tailnet | UIs unreachable; fetching continues |

## Parameters

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 | VPN_SERVICE_PROVIDER | enum | (required) | gluetun's provider list | Which provider module runs |
| P-2 | VPN creds | secret | (required) | Provider account | Tunnel auth (goes in the encrypted .env) |
| P-3 | MEDIA_ROOT | path | `/media` | Host's media dataset | Where downloads and libraries live |
| P-4 | TAILNET_IP | string | (required) | `tailscale ip -4` on the host | Bind address for tailnet-only ports (R-2) |
| P-5 | DELUGE_PASS | secret | (required) | `openssl rand -hex 16` | Deluge web UI |
| P-6 | MOUSEHOLE_PASS | secret | (required if D-7) | `openssl rand -hex 16` | IP-sync UI |
| P-7 | TZ | string | (host tz) | `date +%Z` | Logs |
| P-8 | CHAPTARR_PORT / DELUGE_WEB_PORT / MOUSEHOLE_PORT | int | 8789 / 8112 / 5010 | Images' defaults | Tailnet-bound listeners |
| P-9 | APPS_ROOT | path | `${P-3}/apps` | State convention | Per-app config dirs |

## Modules

- **kill-switch-structural**: why shared netns beats every configured
  kill switch, and the test that proves failure-closed.
- **port-rotation**: the forwarded-port lifecycle and the Deluge 2.x
  interface-binding gotcha the hook must handle.
- **seedbox-ip-sync**: why one indexer needs its announced IP pinned to
  the VPN exit IP, and how the sync service closes that loop.

## Interfaces and Contracts

### gluetun sidecar contract

- Publishes on the tailnet IP only: Deluge web/daemon, Mousehole UI,
  HTTP proxy (8888) for arr-side outbound traffic.
- Writes `/tmp/gluetun/forwarded_port` when the provider forwards a
  port; consumers watch that file.
- Health: internal health server; dependents gate on it.

### Deluge contract (to importers)

- Completed downloads appear at `${P-3}/downloads/complete` (host path)
  - the same path any *arr stack mounts read-only to import.
- RPC: `http://gluetun:8112/json` from within gluetun's netns (or
  tailnet IP from a browser); cookie session via `auth.login`.

### Chaptarr contract (to importers)

- Root folders `${P-3}/books` and `${P-3}/audiobooks` - identical host
  paths the serving stack mounts; files import in place, never copied
  between stacks.
- Remote imports (optional): a read-only sshfs sidecar mounting a
  foreign completed-dir with a documented remote path mapping.

## Implementation Phases

### Phase 1: VPN sidecar

1. Deploy gluetun with the provider env (secrets via encrypt-container-secrets,
   per-service names), `NET_ADMIN`, `/dev/net/tun`, the health server,
   and HTTPPROXY on.
2. Verification: health check green; `docker exec gluetun curl -s
   ifconfig.me` shows the VPN exit IP, not the host's.

### Phase 2: Torrent client inside the netns

1. Deploy Deluge with `network_mode: "service:gluetun"`, config and
   download dirs per P-3/P-9.
2. Deploy the port-forward hook (same netns) watching
   `forwarded_port` and pushing `listen_interfaces` into Deluge.
3. Verification: a test torrent announces and completes; Deluge's
   reachable status reflects the forwarded port.

### Phase 3: Kill-switch proof

1. Stop gluetun (simulates a dead tunnel).
2. Verification (the acceptance test, not a checkbox): from outside the
   netns nothing on the tailnet can reach Deluge; inside, Deluge cannot
   fetch anything (no route except via the dead tunnel). Restart gluetun,
   force-recreate deluge and the hook (R-9), confirm recovery.

### Phase 4: Chaptarr and (optional) IP sync

1. Deploy Chaptarr: root folders, downloads mount, tailnet-only port or
   tsdproxy label; connect to gluetun's HTTP proxy for outbound
   (ProxyEverything).
2. If any indexer is single-IP: deploy Mousehole in gluetun's netns,
   paste the indexer's session once into its UI, verify it reports the
   exit IP.
3. Verification: search for a book, grab to Deluge, watch it land in
   the complete folder and import into the right root folder.

## Verification and Acceptance

- **A-1** (R-1): with gluetun stopped, an external TCP connect to the
  Deluge ports fails AND `docker exec gluetun wget -T 5 -qO-
  ifconfig.me` fails. Nothing announces.
- **A-2** (R-2): from a non-tailnet vantage, every UI URL times out;
  from a tailnet node, each works.
- **A-3** (R-3): from inside chaptarr, `curl --proxy
  http://gluetun:8888 ifconfig.me` returns the VPN exit IP.
- **A-4** (R-4): force a gluetun reconnect; within the sync period the
  IP-sync service updates and the gated indexer announces successfully.
- **A-5** (R-5): after a gluetun port rotation, the hook updates
  Deluge's `listen_interfaces` and the announce stays connectable.
- **A-6** (R-6): the stack's secrets are committed only as
  `.env.encrypted` with a per-service age key; `git ls-files` shows no
  plaintext `.env`.
- **A-7** (R-8): every `image:` carries `@sha256:`.
- **A-8** (R-9): a full `docker compose down && up` sequence recovers
  Deluge announces with no manual intervention beyond the documented
  recreate order.

## Failure Modes and Rollback

- **VPN dead**: fetching halts (by design); everything else on the host
  is unaffected. Fix credentials, restart gluetun, force-recreate the
  netns consumers.
- **Indexer announces fail after IP change**: the sync service lagged;
  check its log, re-run manually, confirm the IP matches.
- **Downloads stuck incomplete**: the forwarded port expired; run the
  hook manually once, verify announce.
- **Chaptarr cannot see remote imports**: sshfs sidecar down; check the
  mount and the remote path mapping before blaming the arr.
- **Rollback**: `docker compose down` per component; the media tree and
  per-app configs are state, not code - delete nothing.

## Removal

1. Stop and remove Mousehole (if present), Chaptarr, the port-forward
   hook, Deluge, gluetun - in that order.
2. Remove the tailnet DNS/proxy entries for the removed UIs.
3. Revoke the VPN session on the provider if the account is being freed.
4. Media and config trees remain on disk; delete only on explicit ask.

## Decisions and Open Questions

Decisions:

- 2026-09-10: Reverse-engineered from the phoenix media stack
  (Chaptarr/Deluge/Mousehole, migrated off Readarr 2026-09-07 and
  running daily). Structural kill switch, shared netns, tailnet-only
  bindings, per-service sops secrets: all production choices carried
  over as requirements.
- 2026-09-10: Usenet stays out of scope. Production integrates SABnzbd
  from another host via a read-only sshfs sidecar; that is one valid
  import path, recorded in the Interfaces section as optional, because
  baking a second server into the spec would couple two domains.

Open questions:

- **Q-1**: Whether the IP-sync service should be generalized to
  N-gated-indexers (production has exactly one) or kept as a
  Mousehole-specific recipe. Default: Mousehole-specific until a second
  gated indexer appears.
