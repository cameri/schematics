# Module: config schema (v1 vs v2)

TSDProxy's config syntax changed between the 1.x and 2.x lines, and the two
are NOT compatible. The source deployment that this schematic was
reverse-engineered from runs 1.4.7 (its config uses the v1 shapes below),
while the pinned image in this package (R-6, see SCHEMATIC.md) is 2.3.4.
This module is the map between them so a builder neither copies v1 syntax
into a v2 image nor misreads a legacy config.

## Recognizing the version

- `docker inspect <proxy-image>` → the image's version, or
  `docker compose exec tsdproxy /tsdproxyd` prints its version banner.
- Config tells you too: v1 uses lowercase keys (`files:`, `controlurl`,
  `authkeyfile`, `targethostname`) because its struct fields had no yaml
  tags; v2 uses camelCase tags (`lists:`, `controlUrl`, `authKeyFile`,
  `targetHostname`) and **rejects** the v1 names (case-sensitive, see
  upstream's headscale doc warning).

## v1 (1.x) — legacy

```yaml
defaultproxyprovider: default
docker:
    local:
        host: unix:///var/run/docker.sock
        targethostname: 172.31.0.1
files:
    applications:
        filename: /config/applications.yaml
        defaultProxyAccessLog: false
tailscale:
    providers:
        default:
            authKeyFile: "/secrets/ts-auth-key"
            controlurl: https://controlplane.tailscale.com
    datadir: /data/
http:
    hostname: 0.0.0.0
    port: 8080
log:
    level: info
    json: false
```

v1 list-file entry — the `url:` shorthand:

```yaml
photos:
  url: http://photos-app:8080
  dashboard:
    label: Photos
```

## v2 (2.x) — current, used by this package

```yaml
defaultProxyProvider: default
docker:
  local:
    host: unix:///var/run/docker.sock   # default
    targetHostname: 172.31.0.1          # default: docker bridge gateway
lists:
  applications:
    filename: /config/applications.yaml
    defaultProxyAccessLog: false
tailscale:
  providers:
    default:
      authKeyFile: /secrets/ts-auth-key
      controlUrl: https://controlplane.tailscale.com   # default
  dataDir: /data/
http:
  hostname: 0.0.0.0
  port: 8080
log:
  level: info
  json: false
```

v2 list-file entry — `ports:` with explicit targets:

```yaml
photos:
  ports:
    443/https:
      targets:
        - http://photos-app:8080
  dashboard:
    label: Photos
```

## Migration table (v1 → v2)

| v1 key | v2 key | Notes |
|--------|--------|-------|
| `files:` | `lists:` | section rename; entries also change (below) |
| `defaultproxyprovider` | `defaultProxyProvider` | |
| `docker.<name>.targethostname` | `docker.<name>.targetHostname` | same default `172.31.0.1` (docker bridge gateway) in both |
| `tailscale.providers.<n>.controlurl` | `tailscale.providers.<n>.controlUrl` | |
| `authkey`/`authkeyfile` | `authKey`/`authKeyFile` | v2 also adds OAuth `clientId`/`clientSecret` |
| `datadir` | `dataDir` | |
| entry `url:` (required URL) | entry `ports: <port>/<proto>: { targets: [<url>] }` | the url shorthand was dropped in v2; each port/proto pair gets its own targets list |
| entry `tlsvalidate` | port-level `tlsValidate` | now per port, not per entry |
| `defaultProxyAccessLog` | `defaultProxyAccessLog` | same name in the `lists:`/`files:` section |

Additional v2-only options this package does not depend on but a builder
may meet in existing configs: `apiKey`/`apiKeyFile`, `webhooks`, `admins`,
`proxyAccessLog` (global default), per-provider `tags`, and per-list
health-check knobs (`healthCheckEnabled/Interval/Failures/Cooldown`,
`autoRestart`).

## Idempotency Notes

The v2 config file is only read at proxy startup (a restart is required for
`tsdproxy.yaml` edits), while list files hot-reload. Re-writing the same
config and restarting is a no-op. There is no auto-migration: v1 config
files are not rewritten by a v2 binary — a v2 image pointed at a v1 config
fails validation (unknown/renamed fields), and a v1 image pointed at a v2
config fails the same way. Migration is a manual edit per the table above,
then compare `docker compose logs` for a clean start.

## Removal Notes

Nothing this module adds to the host beyond the config file itself; removal
is part of SCHEMATIC.md's Removal (the file lives in CONFIG_DIR, P-9).