# Module: Store and Projections

The shared store is one SOPS dotenv file, and the interesting design question is
not how it is encrypted but **who can decrypt it**. A per-service store gets its
blast radius from the key: one key, one service. A *shared* store cannot —
any key that opens the file opens every value in it — so the boundary has to be
drawn by the file instead, and a consumer that reads two of twelve values is
given a file that contains exactly those two.

## Purpose

Owns the store's format and key contract, the split between the narrow plaintext
file and the ciphertext store, the recipient model for the store and for
projections, the generation of projections, and the alias mechanics that let
`sops exec-env` read a `.encrypted` file. It does **not** own the classification
of consumers (`consumer-taxonomy.md`), the parse-time remedy
(`compose-interpolation.md`), or the rotation procedure (`rotation.md`).

## Inputs

- `P-1 SECRETS_DIR`, `P-2 STORE_FILE`, `P-3 PROJECTION_PATTERN`: where the
  ciphertext lives.
- `P-4 PLAIN_ENV_FILE`: the file being split; it is the source of the values
  that move.
- `P-7 KEY_DIR`, `P-8 MASTER_KEY_FILE`, `P-9 CONSUMER_KEY_PATTERN`: the keys.
- The inventory (`P-12`): which consumer reads which names, and which consumer
  is declared as holding the whole store.
- `scripts/sops-shared.sh`: `set`, `remove`, `keys`, `extract` (projection
  generation), `--add-recipient`.

Error inputs tolerated: a store that does not exist yet (Phase 3 creates it); a
narrow file that no longer exists (a deployment where every value moved may
delete it after `A-11` passes); a consumer key that exists already (reused, not
regenerated).

## Outputs

**The store**, SOPS dotenv, `P-2`:

```dotenv
API_TOKEN=ENC[AES256_GCM,data:…,iv:…,tag:…,type:str]
DB_PASSWORD=ENC[AES256_GCM,data:…,iv:…,tag:…,type:str]
sops_age__list_0__map_recipient=age1…        # master
sops_age__list_1__map_recipient=age1…        # a consumer declared as whole-store
sops_…                                       # format, version, MAC
```

- Values unquoted: a quoted value reaches the consumer with its quotes.
- The key name IS the variable name (`R-6`): injection is verbatim, so renaming
  a store key is the only way to change what a consumer sees, and a key nothing
  reads is a value nothing gets.
- The recipient list is the access list. Adding a consumer to the whole store is
  adding its public key; removing one is a re-encryption (`extract` of every
  key it should keep, or a re-encrypt with the remaining recipients).

**Projections**, SOPS dotenv, `P-3`, one per consumer that reads a subset:

- Generated from the store, never hand-maintained, so drift is impossible.
- Exactly two recipients: the master key and that consumer's key (`A-7`).
- Contains only the keys that consumer reads, plus the `sops_` metadata block.

**The narrow file**, `P-4 PLAIN_ENV_FILE`, unchanged in role: values the
consumer-side parser needs in plaintext, none of them a secret. Its key set and
the store's key set are disjoint (`R-11`, `A-11`).

**The aliases**, `${RUNTIME_DIR}/sops-alias/<name>.env`: paths ending in `.env`
whose content is the store's ciphertext. They exist because `exec-env` selects
its parser from the file name and ignores input-type flags (measured, see the
alias contract in `SCHEMATIC.md`). A symlink is sufficient: the content is
ciphertext, so an alias left behind leaks nothing, and the target is untouched
by reading it.

## Dependencies

- `D-1` (age) and `D-2` (sops) for every operation here.
- `D-4` (`python3` or `jq`) for `--value-stdin` encoding.
- `P-1`…`P-3`, `P-7`…`P-9`, `P-11`, `P-14`.
- `scripts/sops-shared.sh` is the only writer; a hand-edited store breaks the
  recipient block's MAC and is refused at read time, not write time.

## Failure Behavior

- **A key set on the wrong file.** A projection generated before its consumer
  key existed is encrypted to the master alone: the operator's own read
  succeeds and the consumer's fails. Detect: `A-7`'s recipient count is exactly
  two. Remedy: regenerate.
- **Type flags placed before the subcommand.** `sops --input-type dotenv set …`
  is accepted and the value is parsed as JSON instead, so a plain string fails
  with `Error unmarshalling input json: invalid character …` and the store is
  left unchanged. Detect: `keys`/the read-back after a `set`. Remedy: put the
  flags after `set` (`scripts/sops-shared.sh` does).
- **A store edited by hand.** The `sops_` metadata block's MAC no longer
  matches, and decryption fails for every consumer at once. Detect: any
  decryption exits non-zero with a MAC message. Remedy: restore from version
  control — the ciphertext is committed, so this is a checkout, not a
  re-encryption.
- **A value that exists in both files.** The narrow file still carries it in
  plaintext and the store carries it too; consumers reading the narrow file
  never see a rotation. Detect: `A-11`. Remedy: delete the narrow-file line.
- **The master key lost.** Every store and projection is unreadable at once.
  Keep a copy outside the repository; there is no recovery from ciphertext
  alone.
- **A store key renamed while a consumer still reads the old name.** The
  variable is unset in the child with no error (measured). Detect: `A-6`.
  Remedy: rename back or update the consumer's expectations — never add a
  bridging layer, which is a second source of truth (`R-6`).
- **A projection that is stale after a rotation.** Its consumer keeps seeing
  the old value. Detect: read the value back through the consumer's own path
  (`A-8`). Remedy: regenerate every projection carrying that key
  (`rotation.md`).

## Idempotency Notes

`set` on an existing key replaces the value and leaves every other line and the
recipient list intact; `extract` overwrites the projection from the current
store, so re-running it is the way to converge after any change. Recreating a
key is skipped when the key file exists — regenerating a key would invalidate
every file encrypted to it, so the scripts refuse rather than replace.
`--add-recipient` on a key already present is a no-op. Reading an alias never
modifies the ciphertext (measured: the `ENC[` count is unchanged after an
`exec-env` run through a symlink).

## Removal Notes

The store and the projections are the artifacts worth keeping: they cannot be
reconstructed if the keys are ever put back into use, and they are what makes a
half-finished removal recoverable. Removal therefore restores each consumer's
previous mechanism and leaves `P-1 SECRETS_DIR` in place; deleting it is a
separate, deliberate act.
