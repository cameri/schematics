# Module: Provider Credentials

Where every credential lives, how it reaches the router process, and what a
compromise of this container exposes.

## Purpose

Owns the two credentials the router needs — one per upstream provider, plus the
router's own client-facing credential — from "encrypted at rest" to "present in
the router process environment at boot, and nowhere else". It is **not**
responsible for which aliases use which key (`model-aliases.md`) or for how a
client presents its credential (`client-wiring.md`).

## Inputs

- `P-5 ROUTER_ENV_FILE`: the encrypted store (dotenv format; a **file**-backed
  compose secret). Its format and tooling are not re-specified here — this
  module delegates to `D-3`, which owns the encryption, the key hierarchy, and
  the store-editing scripts.
- `P-6 ROUTER_AGE_KEY_FILE`: this router's **dedicated** age key. The
  host-wide master key is deliberately not mounted (R-4).
- `P-7 ROUTER_MASTER_KEY_ENV`: the name, **inside the store**, of the
  credential clients will present. It is the router's own credential, not a
  provider's.
- `P-8 PROVIDER_KEYS`: the names, inside the store, of each provider
  credential. Values are never written into the config file.

## Outputs

- A process environment at boot containing the provider keys and the router's
  own credential, decrypted in memory by `sops exec-env` (the compose
  entrypoint does this; the router binary never sees the ciphertext).
- Two read-only mounts inside the container: the ciphertext store, and the
  dedicated key file.
- **No plaintext artifact**: no decrypted file, no sidecar, no temp file, no
  host path holding a decrypted copy (R-4).

## Dependencies

- `D-3` (the encryption schematic, pinned in SCHEMATIC.md) — this module is a
  consumer of its contract, not a replacement for it.
- `P-5`, `P-6`, `P-7`, `P-8`.

## Failure Behavior

| Condition | Behavior |
|---|---|
| Store missing, or built with the wrong recipients | `sops exec-env` fails and the container exits before the router starts. Clients see connection errors. This is the correct failure: never a start with zero keys |
| `P-7` name absent from the store | The bootstrap script aborts with a message naming the missing variable; the container exits non-zero, never listening with an empty master key (R-2) |
| A provider key missing or wrong | The router starts normally (the config only names environment variables at parse time) and that alias fails at request time with the provider's own 401 `inferred:` the reference implementation validates nothing at boot, so a bad key is only visible per-alias — A-4 is what catches it |
| Age key unreadable (mode/ownership) | Decryption fails at boot with a permission error, not a parse error. The key file must be readable by the container's user |
| The store is edited but the container is only `docker restart`ed | The container keeps serving with the **old** values: a `sops set` rewrites the file to a new inode, and the mounted secret still points at the old one. Always recreate (`up -d --force-recreate`), never plain `restart` |
| Credential value changed at the provider but not in the store | Same shape as a missing key: that alias fails at request time, others are unaffected |

## Idempotency Notes

- Setting a value is idempotent (overwrites the same store key). Decryption is
  re-done on every container start, so a restart always converges to the
  store's *current* contents — provided the recreate caveat above is honored.
- Rotation is therefore: set the value in the store, **recreate** the
  container, verify with A-4 for one alias of that provider. No image rebuild
  is involved (R-5).
- Completion detection: a real completion through an alias bound to the rotated
  key. `GET /v1/models` proves nothing about credentials.

## Removal Notes

Adds: two secret mounts, one environment variable, and one store entry per
provider. Removing the router means: delete the compose entry (mounts go with
it), then **rotate every provider credential that was in the store** at the
provider. A credential that has been decrypted into a container is treated as
exposed on removal. If no other service uses this router's dedicated age key,
remove that recipient from the store's recipient list as well — the key belongs
to this deployment, not to the host.
