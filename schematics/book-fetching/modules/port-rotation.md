# Module: port rotation

Private trackers with port forwarding hand out a listening port that
changes whenever the VPN exit reconnects or rotates. A torrent client left
on a stale port becomes unconnectable - it still announces, but peers
cannot dial in, and downloads crawl to a stop. This module is the
lifecycle the hook implements.

## The lifecycle

1. gluetun's provider module obtains the forwarded port from the VPN's
   API (after connect, and after every rotation) and writes it to
   `/tmp/gluetun/forwarded_port`.
2. The hook container (inside gluetun's netns, so it reaches the client
   at localhost) watches that file.
3. On change, it authenticates to the client's web API and sets the
   listening interfaces to include the new port.
4. Announce continues; peers can connect again.

## Deluge 2.x gotcha (cost us a debugging session)

Deluge 2.x moved from `listen_ports` to `listen_interfaces`, which takes
a LIST OF `host:port` STRINGS (e.g. `0.0.0.0:51234,[::]:51234`), not an
integer. `core.set_config` with `listen_ports` silently does nothing in
2.x. Related constraint: `random_port` must be `false`, or Deluge
re-randomizes and the forwarded port is wasted.

## Seams the hook must survive (production scars)

- **Snap Docker cannot bind-mount single files**: it silently creates a
  DIRECTORY where the file should be. Mount the parent cache dir, read
  `cache/forwarded_port` inside the hook.
- **Netns rejoin after gluetun recreate**: containers that shared the
  old namespace hold a dead netns; they must be force-recreated after a
  gluetun recreate, not merely started. The runbook encodes the order:
  gluetun up healthy -> force-recreate hook and deluge.
- **Client auth after restart**: the hook must re-login (fresh cookie)
  before each set, not cache a session across a client restart.

## Acceptance in one line

Force a rotation (restart the tunnel), and within the poll interval the
client's listening port equals the newly forwarded one and an external
connect check succeeds (A-5).
