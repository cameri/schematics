# Module: kill switch, structural

The kill switch is not a setting anyone toggles; it is a property of the
network topology. This module states the property, the mechanism, and the
test that distinguishes it from wishful thinking.

## The property

**VPN loss fails closed.** If the tunnel is down, the torrent client (and
any netns sharer) can neither reach the internet nor be reached from it.
No packet leaks on the host's interface. Fetching halts loudly; the
operator fixes the VPN.

## The mechanism

1. Deluge (and Mousehole) run with `network_mode: "service:gluetun"` -
   they share gluetun's network namespace. They have no `eth0` of their
   own.
2. Inside that namespace, gluetun runs a firewall (iptables) whose only
   egress rule routes through the VPN interface (tun/wg).
3. When the tunnel dies, the rule chain has no usable route. Even a
   client that ignores disconnects cannot send, because its socket
   belongs to a namespace whose firewall drops it.

Contrast with configured kill switches (a checkbox in the client's UI, a
bind-to-interface option): those depend on the application honoring them
and on a per-app rebind after every VPN change. The structural switch
depends on nothing but the namespace, which the application cannot escape.

## What it does NOT cover

- A process started in the gluetun container itself shares the same
  netns - that is the point - but anyone attaching a second VPN to the
  same netns or adding a route in the namespace can break the property.
  Keep the namespace single-purpose.
- DNS: gluetun forwards DNS for its netns. If a consumer hardcodes a
  public resolver on a host-network mount, it bypasses the tunnel's DNS
  (not its traffic). Do not do that.

## The proof test (A-1)

Not a status page, a measurement:

1. `docker stop gluetun` (or pull the VPN's network).
2. From OUTSIDE the namespace: TCP connect to the Deluge ports fails.
3. From INSIDE: any internet fetch fails.
4. Confirm nothing announced during the outage (tracker side, or Deluge
   logs show no successful announces).
5. Restart, force-recreate the netns consumers, verify recovery.

If a topology change ever makes step 2 or 3 succeed while gluetun is
down, the property is gone and the topology is wrong - do not "fix" it by
adding a Deluge kill-switch checkbox on top; find the added route or
interface.
