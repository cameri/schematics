# Module: seedbox IP sync

Some private indexers allow exactly one IP per account and match it
against the IP your client announces from. Run a torrent client on a
dynamic VPN exit and the account locks out the moment the exit IP
rotates. This module is the closed loop that keeps the two equal.

## The loop

1. The VPN exit IP is whatever gluetun currently egresses from.
2. The torrent client (sharing gluetun's netns) announces from that same
   IP - automatically, no config.
3. The sync service (Mousehole, also in gluetun's netns) periodically
   tells the indexer "my seedbox IP is <exit IP>", authenticating with
   the operator's session.
4. Indexer's notion of the seedbox IP == announce IP. Always.

Property: because all three parties (client announce, sync egress, the
IP the sync reports) live in the same netns, they cannot disagree. The
loop's only failure mode is the sync lagging a rotation by its poll
interval.

## Operational notes

- The sync service's session cookie is the operator's account - handle
  like a password: never log it, never echo it, store it in the service's
  state dir on the media root, not in the repo.
- Expose its UI tailnet-only (R-2); the operator pastes the session once.
- After a forced VPN reconnect, check the sync service's last-updated
  timestamp before blaming the indexer for a failed announce (A-4).

## Why not static

A static VPN exit IP would remove the need for this service entirely -
if your provider sells one, prefer it and drop D-7. The sync loop is the
answer for the common case: rotating exit IPs on a consumer VPN plan.
