# Module: Sandbox Provisioning

Prepares the host-side directory that is bind-mounted into the sandbox container
as its Docker client configuration home (`~/.docker` inside the container, or
wherever `DOCKER_CONFIG` points). Contains the client TLS certificates, a Docker
`config.json` carrying the secondary identity header, and an environment file
the container sources.

## Purpose

Every file the sandbox container needs to authenticate to the daemon over TLS
lives in this directory. The container entrypoint (or its compose service
definition) sources the env file, and the Docker client reads the certificates
and `config.json` from `DOCKER_CERT_PATH`/`DOCKER_CONFIG`. The container image
never embeds credential material; it arrives through the bind mount at run time.

## Precondition: the socket mount must be gone

This capability is bypassed — silently and completely — if the sandbox container
also mounts the Docker socket. A container holding `/var/run/docker.sock`
authenticates as nothing (`input.User` is empty on the unix socket), so the
policy classifies it as a host user and allows every request. The TLS
configuration and the policy are then decoration: the client's `DOCKER_HOST`
setting is a preference, and anything that opens the socket directly wins.

A read-only socket mount (`:ro`) does **not** make this safe. The read-only
attribute applies to the socket *file*; the API calls that travel over it are
unaffected, and creating a container requires no write to the socket. Treat
`-v /var/run/docker.sock:/var/run/docker.sock:ro` as equivalent to a writable
mount of the daemon.

So: removing the socket mount is part of deploying this capability, and it is
what the sibling `restrict-docker-api-access` schematic exists to provide for
consumers that only need a slice of the API. Verify the removal before claiming
the deployment works:

```
docker inspect <sandbox container> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{.Mode}}{{println}}{{end}}'
```

No line may mention `docker.sock`.

## Inputs

- Parameters P-1, P-2, P-4, P-8, P-9 from SCHEMATIC.md.
- Certificate files from Phase 2: `ca.pem`, `sandbox-cert.pem`,
  `sandbox-key.pem`.
- The sandbox container's cert path inside the container: the directory that
  `DOCKER_CERT_PATH` will name. It must be the mount point of P-8.

## Outputs

Files written to P-8:

| File | Source | Permissions | Purpose |
|------|--------|-------------|---------|
| `ca.pem` | copy of the CA certificate | 644 | Trust anchor for TLS verification |
| `cert.pem` | copy of the client certificate (CN = P-4) | 644 | Client TLS certificate |
| `key.pem` | copy of the client key | 600 | Client TLS private key |
| `config.json` | generated | 600 | Secondary identity header |
| `env` | generated | 644 | Shell environment to source |

### config.json format

```json
{
  "HttpHeaders": {
    "<P-9 header name>": "true"
  }
}
```

The client must read this file as its Docker configuration (`~/.docker/config.json`
for a default client, or the directory named by `DOCKER_CONFIG`). A `config.json`
that the client never reads is a policy that never sees the header; the
certificate identity still applies, so the failure is a missing second factor
rather than an open door.

### env file format

```bash
export DOCKER_HOST=tcp://<P-1>:<P-2>
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH=<the container path where P-8 is mounted>
```

## Dependencies

- Parameters P-1, P-2, P-4, P-8, P-9

## Failure Behavior

- **Missing P-8 directory**: `mkdir -p P-8` creates it. If the path is wrong the
  bind mount is empty, the entrypoint's `source` of the env file fails, and the
  Docker client inside falls back to the unix socket — which is exactly the
  bypass this module warns about. Verify with the mount inspection above.
- **Wrong permissions on key.pem**: the Docker client refuses to use it (0600 or
  tighter). Check with `stat -c '%a' P-8/key.pem`.
- **Wrong DOCKER_HOST**: the client connects to the wrong address or port, or
  falls back to a default. Re-check P-1 and P-2 against `ss -tlnp`.
- **CA file missing or wrong**: TLS fails with "certificate signed by unknown
  authority".
- **Header not sent**: the certificate identity still applies (the client is the
  sandbox by CN); the header is a second signal, not the first one.

## Idempotency Notes

- All file writes are destructive overwrites; running twice is safe.
- The env file is not deduplicated; sourcing it more than once is safe.

## Removal Notes

Remove the directory contents: `rm -f P-8/ca.pem P-8/cert.pem P-8/key.pem
P-8/config.json P-8/env`. Without these files the sandbox cannot connect to the
daemon over TCP — and if the socket mount was removed as required above, it has
no Docker access at all, which is the intended fail-closed direction.
