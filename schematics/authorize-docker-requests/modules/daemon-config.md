# Module: Docker Daemon Configuration

Configures the host's Docker daemon (`dockerd`) to listen on a TLS-protected
TCP port and to enforce authorization via the OPA plugin.

## Purpose

Two configuration changes are needed, and they have different blast radii:
`daemon.json` (TLS paths + authorization plugin) and a systemd drop-in (the TCP
`-H` flag). They are separated because systemd already passes `-H fd://` to
dockerd, and adding `hosts` to daemon.json would conflict with that flag.

The third thing this module has to get right is **which file is live**. A
daemon.json that nothing reads is the most expensive mistake in this package: it
is written, it looks correct, and the daemon never changes behavior.

## Which File the Daemon Reads

| Daemon install | Live configuration file | Notes |
|----------------|------------------------|-------|
| Distribution package (`docker-ce`, `docker.io`) | `/etc/docker/daemon.json` | The documented default (`dockerd --config-file`) |
| Snap (`snap install docker`) | `/var/snap/docker/current/config/daemon.json` | The snap runs its own `dockerd` with its own `--config-file`. `/etc/docker/daemon.json` may exist and is **inert** — the daemon never reads it |

Discovery, in this order:

1. Resolve the unit that owns the daemon:
   `systemctl show docker --property=FragmentPath,Id,ExecStart`.
   A `FragmentPath` under `/etc/systemd/system/snap.docker.dockerd.service` (or
   an `Id` beginning with `snap.docker`) means the snap layout.
2. For the snap layout, read the configuration directory from the unit's
   environment or the snap data path (`/var/snap/docker/current/config/`), and
   confirm the file exists and parses: `python3 -m json.tool <file>`.
3. Do not trust the path by inspection alone. The check that the file is live is
   an **observable effect**: after writing a change and reloading (below), the
   daemon must behave differently — for the plugin entry, the plugin starts
   receiving authorization requests; for the TLS entries, the TCP listener
   appears. A change that produces no observable difference means the file is
   not the one being read; stop and re-discover rather than restarting the
   daemon again.
4. `dockerd --validate --config-file <file>` parses and validates the file
   statically (it does not apply anything). Run it before every reload.

## Inputs

- Parameters P-1, P-2, P-6, P-13 from SCHEMATIC.md.
- The certificate files created in Phase 2: `ca.pem`, `server-cert.pem`,
  `server-key.pem`.
- The existing live daemon configuration file (may be absent).

## Outputs

- The live daemon configuration file (P-13), updated with `tlsverify: true`,
  the TLS paths, and `authorization-plugins: [<plugin reference>]`.
- A systemd drop-in (path chosen from the daemon's unit, see below) that adds
  `-H tcp://0.0.0.0:P-2` to the daemon's existing command line.
- A backup of the pre-change configuration file, beside it, named so the
  rollback line in SCHEMATIC.md can find it.

## Reload vs Restart

The two changes are applied differently, and conflating them costs a container
outage:

- **`authorization-plugin` is in dockerd's SIGHUP-reloadable set** (with
  `debug`, `labels`, `live-restore`, `insecure-registries`, `registry-mirrors`,
  and a few others). Adding the plugin can be applied with
  `kill -HUP $(pidof dockerd)` — no restart, running containers unaffected.
- **`hosts` / `-H` is not reloadable.** Adding the TCP listener needs a daemon
  restart, which stops every running container unless `live-restore` is enabled.
  Discover whether it is: `docker info --format '{{json .LiveRestoreEnabled}}'`
  or the same key in the configuration file.

Order the work so the disruptive step happens once: write both changes, reload
the plugin registration with SIGHUP, verify it, and only then do the restart
that adds the listener.

## systemd Drop-in

For a distribution-package daemon the drop-in is
`/etc/systemd/system/docker.service.d/tcp-host.conf`. For a snap-managed daemon
the unit is the snap's (`snap.docker.dockerd.service`), and its command line
belongs to snapd — do not hand-write it. Derive it:

1. Read the live command line: `systemctl show <unit> --property=ExecStart`.
2. Write a drop-in that clears it and restates it with the added flag:
   `ExecStart=` (empty, to clear) followed by the exact original argv plus
   `-H tcp://0.0.0.0:P-2`.
3. `systemctl daemon-reload` then restart the daemon.
4. Mark this step as the one to re-check after a snap refresh: snapd may rewrite
   the unit. `systemctl show <unit> --property=ExecStart` after an upgrade tells
   you in one command.

## Dependencies

- D-1 (Docker Engine), D-5 (systemd), D-6 (python3 for JSON merge)

## Failure Behavior

- **Wrong configuration file**: the change has no effect and the verification
  step in Phase 4 fails. Recovery: re-run the discovery above; never "fix" it by
  restarting the daemon repeatedly.
- **daemon.json merge**: If python3 is unavailable, the implementer must
  manually merge the new keys using a text editor. Instructions: add
  `tlsverify: true`, `tlscacert`/`tlscert`/`tlskey`, and
  `authorization-plugins: [<plugin reference>]` with valid JSON syntax.
- **Invalid daemon.json**: the daemon fails to start or to reload. Validate
  before applying (`dockerd --validate --config-file <file>`); the backup beside
  the file is the rollback.
- **Plugin referenced but unavailable**: with the plugin entry written and the
  plugin not installed or not enabled, the daemon's authorization middleware
  fails closed — every API call is denied, including host-user calls on the unix
  socket. Recovery: remove the entry, SIGHUP, or install and enable the plugin.
  Whether a *restart* with an unavailable plugin is refused by the daemon is
  `inferred:` (the documented failure-closed statement covers request-time
  errors; the startup case was not observed in this pass) — do not plan a
  restart on an assumption.
- **Port conflict**: if P-2 is already in use, `ss -tlnp` shows the occupant.
  Choose a different port or stop the occupant.

## Idempotency Notes

- The daemon.json merge is idempotent: it deduplicates `authorization-plugins`
  and overwrites the `tls*` values with the new paths. Running it twice produces
  the same file.
- The systemd drop-in overwrites on every write (safe).
- `systemctl restart <unit>` is idempotent; `kill -HUP` is idempotent.

## Removal Notes

- Revert the systemd drop-in: remove the file, `systemctl daemon-reload`, then
  restart the daemon.
- Revert the live configuration file: restore the backup, SIGHUP (the plugin
  entry is reloadable — this needs no restart), then restart only if the TCP
  entries must go too.
- After removal, the daemon listens only on the unix socket again, and the
  sandbox's TLS client stops working.
