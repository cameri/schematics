# Module: Docker Daemon Configuration

Configures the host's Docker daemon (`dockerd`) to listen on a TLS-protected
TCP port and to enforce authorization via the OPA plugin.

## Purpose

Two configuration changes are needed: `daemon.json` (TLS paths + authz plugin)
and a systemd drop-in (TCP host flag). They are separated because systemd
already passes `-H fd://` to dockerd, and adding `hosts` to daemon.json would
conflict with that flag.

## Inputs

- Parameters P-1, P-2, P-6, P-10 from SCHEMATIC.md.
- The certificate files created in Phase 2: `ca.pem`, `server-cert.pem`,
  `server-key.pem`.
- The existing `daemon.json` at P-6/daemon.json (may be absent).

## Outputs

- `P-6/daemon.json` — the Docker daemon configuration file, updated with
  `tlsverify: true`, TLS paths, and `authorization-plugins: ["opa-docker-authz"]`.
- `/etc/systemd/system/docker.service.d/tcp-host.conf` — a systemd drop-in
  that replaces the dockerd ExecStart to add `-H tcp://0.0.0.0:P-2`.

## Dependencies

- D-1 (Docker Engine), D-5 (systemd), D-6 (python3 for JSON merge)

## Failure Behavior

- **daemon.json merge**: If python3 is unavailable, the implementer must
  manually merge the new keys into daemon.json using a text editor.
  Instructions: add `tlsverify: true`, `tlscacert/...`, and
  `authorization-plugins: ["opa-docker-authz"]` with valid JSON syntax.
- **Invalid daemon.json**: Docker fails to start. Check logs with
  `journalctl -u docker -n 50 --no-pager`. Rollback is described in
  SCHEMATIC.md.
- **systemd drop-in conflict**: If the drop-in uses a different ExecStart
  format than the host's Docker version requires, check `systemctl show
  docker --property=ExecStart` for the current argument pattern and adapt.
- **Port conflict**: If P-2 is already in use, `ss -tlnp` shows the occupant.
  Choose a different port or stop the occupant.

## Idempotency Notes

- daemon.json merge is idempotent: the python3 merge script deduplicates
  `authorization-plugins` and overwrites `tls*` values with the new paths.
  Running it twice produces the same file.
- The systemd drop-in overwrites on every write (safe).
- Restarting Docker (`systemctl restart docker`) is idempotent.

## Removal Notes

- Revert the systemd drop-in: `rm /etc/systemd/system/docker.service.d/tcp-host.conf`
  then `systemctl daemon-reload && systemctl restart docker`.
- Revert daemon.json: remove the `tls*` keys and `authorization-plugins`,
  then `systemctl restart docker`.
- After removal, Docker listens only on the unix socket and localhost.