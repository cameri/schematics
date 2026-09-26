# Module: server host prerequisites

Responsibility: prepare a Linux host before bootstrap — engine, disk, firewall,
and reboot behaviour. The relay stack assumes this module is satisfied or
deferred explicitly (for example a managed host that already runs Docker).

## Inputs

- Linux host, operator SSH access, chosen **`P-1`**, planned **`P-12`**.

## Outputs

- Docker Engine + Compose v2 enabled; firewall aligned with loopback relay posture.

## Idempotency

Re-running package installs or `ufw` rules is safe; verify `docker info` after changes.

## Target environment

| Assumption | Discovery | If wrong |
|------------|-----------|----------|
| Linux x86_64 or arm64 with Docker Engine | `uname -m`; `docker info` | Install engine or pick another host |
| Compose plugin v2 | `docker compose version` | Install compose plugin; v1 `docker-compose` is not the reference |
| Non-root operator with docker group **or** root for bootstrap | `groups`; `id` | Add user to `docker` or run compose as root |
| Static deploy path **`P-1`** on local disk | `df -h ${DEPLOY_ROOT}` | Move to larger volume before Postgres grows |

Upstream nostream deploy docs target **Docker on Linux**. Other OS may work for
experiments; production acceptance tests assume Linux loopback binding.

## Install Docker Engine and Compose

Use the official engine install guide for your distribution:

https://docs.docker.com/engine/install/

After install:

```bash
sudo systemctl enable --now docker
docker compose version
```

Verify the daemon survives reboot: reboot once in a maintenance window, then
`docker info` and `docker compose ps` in **`P-1`** after you deploy.

## Disk and memory planning

| Path | Grows with | Rough planning |
|------|------------|----------------|
| `${DEPLOY_ROOT}/.nostr/data` | Stored Nostr events | Start with tens of GB free; monitor weekly |
| `${DEPLOY_ROOT}/.nostr/db-logs` | Postgres logging | Rotate or truncate per your log policy |
| Redis named volume `cache` | Cache keys | Usually smaller than Postgres; rebuildable |

Discovery:

```bash
df -h "${DEPLOY_ROOT:-/opt/nostream}"
free -h
```

Tune **`P-7`** (`WORKER_COUNT`) and `DB_MAX_POOL_SIZE` in `.env` to RAM and CPU.
Under-provisioning shows up as connection pool timeouts under load (see failure
table in `SCHEMATIC.md`).

## Firewall posture (recommended)

Default compose binds the relay to **loopback only** (R-5). The host firewall
should reflect that:

| Traffic | Typical rule |
|---------|----------------|
| SSH (admin) | Allow from your admin IPs only if possible |
| Relay **`P-2`** | **Do not** expose publicly; no `0.0.0.0:${P-2}` unless you deliberately change compose |
| HTTPS **`443`** / **`80`** | Allow on the **reverse proxy** or tunnel endpoint only when **`P-12=proxy`** |
| Postgres / Redis | **No** host ports — containers talk on the internal compose network only |

Examples (adjust tool to distro):

```bash
# ufw on Ubuntu — proxy terminates TLS on 443
sudo ufw allow OpenSSH
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

With **`P-12=loopback`**, public `443` is optional until Phase 7.

## SSH and deploy root permissions

- Create **`P-1`** owned by the operator or root; bootstrap sets `.nostr` to
  uid **1000** when run as root (`skeleton/bootstrap.sh`).
- Keep **`.env`** mode **600** (R-4).
- Prefer SSH keys; disable password login if your policy allows.

## Optional: run compose on boot

Compose services use `restart: always` / `on-failure`. They start when the
Docker daemon starts after reboot **if** the project was brought up once with
`docker compose up -d` from **`P-1`**.

No separate systemd unit is required for the reference layout. If you wrap
compose in systemd, the unit must `WorkingDirectory=${DEPLOY_ROOT}` and invoke
`docker compose up -d` after `docker.service`.

## Parameters used

`P-1`, `P-2`, `P-4`, `P-7`, `P-12`.
