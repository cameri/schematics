# Module: Sandbox Provisioning

Prepares the host-side directory that will be bind-mounted into the sandbox
container as its Docker configuration home (`/home/<agent-user>/.docker` or
equivalent). Contains client TLS certificates, a Docker config file with the
auth header, and an environment file sourced by the container entrypoint.

## Purpose

Every file the sandbox container needs to authenticate to the Docker daemon
over TLS lives in this directory. The container entrypoint sources the env
file, and the Docker client reads the certs and config.json from
`DOCKER_CERT_PATH`. This separation means the container image never embeds
sensitive material — it's injected at runtime through the bind mount.

## Inputs

- Parameters P-1, P-2, P-8, P-9 from SCHEMATIC.md.
- Certificate files from Phase 2: `ca.pem`, `sandbox-cert.pem`,
  `sandbox-key.pem`.

## Outputs

Files written to P-8:

| File         | Source               | Permissions | Purpose                                  |
|--------------|----------------------|-------------|------------------------------------------|
| `ca.pem`     | copy of P-6/ca.pem   | 644         | Trust anchor for TLS verification        |
| `cert.pem`   | copy of P-6/sandbox-cert.pem | 644  | Client TLS certificate (CN=P-4)          |
| `key.pem`    | copy of P-6/sandbox-key.pem  | 600  | Client TLS private key                   |
| `config.json`| generated            | 600         | Defence-in-depth auth header, see below  |
| `env`        | generated            | 644         | Shell environment source, see below      |

### config.json format

```json
{
  "HttpHeaders": {
    "P-9": "true"
  }
}
```

### env file format

```bash
export DOCKER_HOST=tcp://P-1:P-2
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH=/home/<agent-user>/.docker
```

## Dependencies

- Parameters P-1, P-2, P-8, P-9

## Failure Behavior

- **Missing P-8 directory**: `mkdir -p P-8` creates it. If the path is wrong,
  the sandbox container's bind mount will point to a non-existent or empty
  directory; the container entrypoint's `source ~/.docker/env` fails silently
  (with `|| true`), and Docker commands inside fall back to unix socket (if
  available) or fail with "cannot connect to Docker daemon".
- **Wrong permissions on key.pem**: Docker client refuses to use it (requires
  600 or less permissive). Check with `stat -c '%a' P-8/key.pem`.
- **Wrong DOCKER_HOST in env**: The sandbox connects to the wrong address or
  port. Double-check P-1 and P-2.
- **Ca.pem missing or wrong**: TLS handshake fails with "certificate signed by
  unknown authority".

## Idempotency Notes

- All file writes are destructive overwrites. Running twice is safe — it just
  copies the same certs again.
- The env file is not deduplicated; sourcing it multiple times is safe
  (idempotent export).

## Removal Notes

Delete the entire directory: `rm -f P-8/ca.pem P-8/cert.pem P-8/key.pem
P-8/config.json P-8/env`. Without these files, the sandbox cannot connect to
Docker over TCP.