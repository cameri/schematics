# Module: tailscale auth

The proxy joins the tailnet with a credential the operator provisions. In
the source deployment that credential is a reusable auth key stored in a
file mounted at `/secrets/ts-auth-key` and referenced by
`authKeyFile`/`authkeyfile` — the R-5 contract: the key never appears as a
literal in a committed config.

## The three auth methods (v2)

1. **Auth key** (`authKey` or `authKeyFile`): a secret token generated in
   the tailnet admin console (or the control server's CLI). Generated with
   "Reusable" enabled, it survives proxy restarts and is the 
   unattended-operations default. Tags can be attached to scope what the
   proxies may do. This is the method the source deployment uses, and this
   package's default.
2. **OAuth client** (`clientId`/`clientSecret`, v2): a control-plane
   client that minted auth keys with mandatory tags. This is a **managed
   Tailscale SaaS feature** — a self-hosted control server (Headscale)
   does not implement OAuth clients; use an auth key there.
3. **Manual** (neither set): the proxy waits for interactive
   authentication in its dashboard on first boot. Not suitable for
   unattended restart; kept for completeness.

## Providing the key as a file (R-5)

The compose skeleton mounts the host-side secret file into the container at
P-7 and the config references it by that in-container path:

```yaml
# compose (host side)
secrets:
  ts-auth-key:
    file: /path/on/host/to/the/key   # never commit this file

services:
  tsdproxy:
    secrets:
      - ts-auth-key        # mounted at /run/secrets/ts-auth-key
```

or a bind mount: `- ./secrets/ts-auth-key:/secrets/ts-auth-key:ro` with
`authKeyFile: /secrets/ts-auth-key`.

The discovery method for the key value itself is the operator's secret
store (password manager, SOPS/age, vault — outside this package; the
`encrypt-container-secrets` schematic in this catalog is a compatible
pattern for at-rest encryption). The schematic's contract is only: the key
reaches the container as a file, referenced by path, never inlined.

## Self-hosted control servers (Headscale and compatible)

Everything above assumes the managed control plane address
`https://controlplane.tailscale.com`. A self-hosted server speaks the same
protocol; only the address and the auth method differ:

```yaml
tailscale:
  providers:
    default:
      controlUrl: https://headscale.example.internal:8080
      authKeyFile: /secrets/ts-auth-key   # Headscale pre-auth key
```

- The auth key is created with the control server's CLI
  (`headscale preauthkeys create ...`), reusable recommended.
- OAuth is not available; anything the admin console of the managed
  product does (keys, ACLs, HTTPS toggle) has a Headscale equivalent whose
  exact surface changes over time — consult the deployment's own docs.

## Rotation without rebuilds

1. Generate a new key in the control plane.
2. Replace the host-side secret file (all mounts are file-backed, so a
   bind or secret update changes what the container sees on next start).
3. `docker compose restart tsdproxy`.
4. The proxy re-authenticates; the old key can be revoked once the new one
   is confirmed working (`tailscale status` on a joined machine shows the
   proxy node).

## Idempotency Notes

Replacing the key file and restarting converges to the new credential; the
proxy is stateless about auth (its tailnet state in P-8 is recreated from
the key if lost). Re-running with the same key is a no-op restart.

## Failure Behavior

- Key expired/revoked: proxy logs auth errors at boot and stays off the
  tailnet; already-registered hostnames keep resolving to the (now empty)
  proxy until it reconnects — the proxy's own node drops, taking all
  hostnames with it. Detect via `docker compose logs tsdproxy`; fix by
  rotating per above.
- Key file missing at start: the proxy fails to read it — log line names
  the path; mount check (`docker inspect tsdproxy` shows the secret mount)
  confirms the compose side.
- `controlUrl` unreachable (self-hosted): same symptom class; check
  network reachability to the control server before blaming the key.