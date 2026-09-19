---
name: encrypt-shared-host-secrets
version: 0.1.0
status: draft
spec: 1
description: Encrypt one shared host secret store with SOPS + age and serve it to many unlike consumers — classify which can decrypt, wrap those that can, bound the plaintext for the one that cannot (the compose parser resolves interpolation before any container exists), ship per-consumer projections so a key unlocks only what its consumer reads, and rotate across every consumer without a rebuild.
created: 2026-09-19
updated: 2026-09-19
---

# Schematic: One Shared Secret Store, Served to Many Consumers

A host keeps one file of shared secrets — a DNS-provider API token, a database
password — read by several unlike things at once: a script an operator runs by
hand, a tool that reads a path at startup, a container, and the Compose CLI
itself, which resolves `${VAR}` while parsing. After implementing this
schematic, every one of those consumers holds the value it needs, the value
exists on disk only as SOPS ciphertext, and the one consumer that structurally
cannot decrypt has a bounded, stated, observable alternative instead of a
plaintext file nobody measures.

The hard part is not encryption. It is that **the consumers are not
interchangeable**: some can run a decrypting command before they need the value
and some cannot, and one of them — the Compose CLI's own interpolation — cannot
be made to, because it reads plaintext before any container exists. A spec that
treats the shared file as one more service env file produces a stack that starts
with a blank token and says nothing.

**Terms used throughout:**

- **Store**: the encrypted dotenv file holding the shared secrets
  (`sops` ciphertext, one `KEY=value` per line at rest).
- **Consumer**: any program that needs a value from the store — a script, a
  unit, a container, or the Compose CLI's interpolation step.
- **Projection**: a derived encrypted file holding only the keys one consumer
  reads, so that consumer's key decrypts nothing else.
- **Alias**: a path whose *name* ends in `.env` and whose content is the
  store's ciphertext; `sops exec-env` selects its parser from the file name, so
  an alias is how a `.encrypted` store is read without decrypting to disk
  (measured, see Interfaces).
- **Narrow file**: the plaintext env file that remains, holding only values
  that are safe in plaintext and must be interpolated at parse time.
- **Wrapper**: the host command that decrypts the store into a child process's
  environment and execs it.

## Applicable Context

**Must discover locally** (with the discovery command/method for each):

- **Every consumer of the store**, before anything is changed: run
  `scripts/find-consumers.sh <VAR> <search-root>` for each variable that will
  move into the store. It prints one line per reference with the mechanism it
  uses; the inventory you write from it is a required artifact (`P-12`).
- **Whether the platform offers a tmpfs** for a materialized plaintext file:
  `findmnt -no FSTYPE --target "${RUNTIME_DIR}"` prints `tmpfs`, and
  `test -w "${RUNTIME_DIR}"` succeeds. Without both, `R-4`'s remedy (b) costs
  more than the spec assumes: plaintext lands on a persistent filesystem and
  `R-9`'s lifetime guarantee is the only thing bounding it.
- **The Compose project directory and whether `.env` is read there**: the CLI
  reads `.env` from the directory the compose file's project root resolves to.
  Confirm which file the CLI actually loads with
  `docker compose config | grep -c "${VAR}"` before and after placing a value.
- **Which variables are compile-time or parse-time only**: `docker compose
  config` shows every interpolated value resolved. A variable that appears
  there is a parse-time consumer (`modules/compose-interpolation.md`).
- **The account the consumers run as**, and therefore the mode the materialized
  file needs: `id -u` for host consumers, the container image's
  `Config.User` for container consumers.
- **Whether `sops` exists on the host**: `command -v sops`. If it does not, the
  store-editing and read operations here cannot run: this package's scripts
  refuse with that explanation rather than degrading. Two ways out: run them
  where the binary exists (its alpine image ships it — `docker create …
  --entrypoint sops "${SOPS_IMAGE}" --version` proves it works), or use
  `encrypt-container-secrets`' `sops-set-env.sh` for value-setting,
  which implements a container fallback through a bind mount. The wrapper
  (`skeleton/host-wrapper.sh`) has no fallback by construction: it must inject
  values into a host process's environment, which a container cannot do for it.
- **The key hierarchy already in use**, if any: `ls "${KEY_DIR}"`. A host that
  already runs per-service encrypted stores has the master key and the
  per-consumer keys this spec reuses; one that does not creates them in
  Phase 4.

**May assume** (each with the risk if the assumption is wrong):

- **Docker Compose v2** for the interpolation behaviours this spec relies on
  (the `.env` lookup, `${VAR:?}`, `--env-file`). Risk if wrong: Compose v1
  resolves `.env` differently and `--env-file` does not exist; the parse-time
  remedy then reduces to `R-4`'s (c) and the fail-fast form must be a
  pre-flight check alone.
- **`sops` with age** for the store format. Risk if wrong: a SOPS build without
  age cannot read the recipient block; the store's `sops_age__list_*` entries
  are the check.
- **The consumer set is finite and enumerable by text search.** Risk if wrong
  is the expensive direction: an undiscovered consumer does not fail — it
  either starts with a blank value or keeps reading a stale plaintext copy, and
  the inventory's "unclassified references: 0" check (`A-2`) is the only thing
  that catches it. A consumer that resolves the value at runtime from a remote
  store, a database, or an inherited parent process is outside a text search
  and must be named by hand.
- **A consumer can be restarted** to pick up a rotated value, or re-invoked
  where it is a one-shot command. Risk if wrong: a long-lived process that
  cannot be restarted holds the old value until it is; the inventory records
  it as such (`R-8`).

**Must not change:**

- **The values that must be interpolated at parse time** (`TZ`, retention
  periods, project names). They stay in the narrow file: the Compose CLI has no
  other way to receive them, and moving them into the store breaks the stack
  that reads them.
- **Existing per-service encrypted files and their keys.** This spec adds a
  shared store beside them; it does not re-encrypt service stores, and a service
  that already decrypts its own env keeps doing so.
- **The master key.** Never regenerate or rotate it as part of this
  schematic: every store already encrypted to it becomes unreadable.
- **The Compose CLI's interpolation semantics.** The spec works with the
  parser, not around it: no wrapper shim that lies about the resolved config,
  no plugin, no edited CLI.

## Scope

**In scope:**

- The consumer taxonomy: which consumers can decrypt, which cannot, and the
  remedy for each class, decided from the collected inventory.
- The shared store: its format, key-naming contract, recipient set, and the
  split between a narrow plaintext file and the ciphertext store.
- Per-consumer projections, so a consumer given a key decrypts only what it
  reads.
- The host wrapper that decrypts into a command's environment, and the
  bounded plaintext alternative for consumers that cannot be wrapped.
- The parse-time problem: the fail-fast form for interpolated secrets, the
  materialized env-file for the Compose CLI, and the guard that proves no
  secret resolved to an empty string.
- Rotation across every consumer named in the inventory, without rebuilding an
  image.
- Removal that restores the previous mechanism for every consumer.

**Out of scope / non-goals:**

- **Decrypting inside a container.** That is
  `encrypt-container-secrets`' contract, declared here as a pinned dependency
  (`D-5`) and reused rather than restated.
- Cloud KMS, Vault, or any external secret manager; SOPS with age only.
- Multi-host distribution, secret synchronization, or a store that several
  machines share.
- Automatic key rotation, key expiry policy, or certificate-style lifetimes.
- Migrating a consumer to read configuration files instead of environment
  variables, and any change to a consumer's own source code.
- Secrets that are not text: binary stores (keys, keystores, certificates)
  follow the same tools with `--input-type binary` and are not covered here.

## Requirements

- **R-1**: Shared secret values MUST exist in any version-controlled, backed-up,
  or replicated location only as SOPS ciphertext. No plaintext value may appear
  in a repository, in process argv, in shell history, in a world-readable file,
  or in a container image layer.
- **R-2**: Every consumer MUST be inventoried and classified before it is
  changed: its location, the mechanism by which it reads the value, whether it
  can run a command before it needs the value, the variable names it reads, and
  the remedy applied to it. The inventory is a committed artifact (`P-12`), and
  an unclassified reference is an implementation defect, not an omission.
- **R-3**: A consumer that can run a command before it needs the value MUST
  receive it by in-memory decryption at start (the wrapper), or — inside a
  container — by the declared dependency's boot path. It MUST NOT be given a
  plaintext file.
- **R-4**: A consumer that cannot decrypt MUST be served by exactly one stated
  remedy: **(a)** change how it starts so a command of yours runs first
  (preferred); **(b)** materialize a plaintext runtime env-file at `P-14`'s
  mode, under `P-5`'s directory, on a tmpfs where the platform provides one,
  outside every repository, for the consumer's lifetime only; **(c)** remove the
  need for the value by narrowing or relocating what that consumer reads. The
  chosen remedy MUST be recorded per consumer in the inventory.
- **R-5**: No consumer may start with a silently empty secret. An interpolated
  secret MUST be removed, or written in the fail-fast form so that a missing
  value aborts the parse; the wrapper MUST verify the names it was told the
  consumer reads are present in the store before it execs anything; and a
  materialized file MUST NOT be produced empty.
- **R-6**: The store key name IS the variable name. Injection is verbatim: no
  mapping layer, no rename, no alias between the store and the consumer.
- **R-7**: A key MUST decrypt only the file its consumer is given. A consumer
  that reads a subset of the store's keys MUST receive a projection containing
  exactly those keys; a consumer given the whole store MUST be declared as such
  in the inventory, because a shared store's boundary is the file, not the key.
- **R-8**: Rotating a shared value MUST NOT require rebuilding any image:
  setting the value, regenerating every projection that carries it, and
  restarting or re-invoking each consumer recorded in the inventory is the whole
  procedure.
- **R-9**: The plaintext's lifetime MUST be bounded and observable: a
  materialized file is removed when its consumer exits, including on failure,
  and no plaintext remains at any materialized path once the consumer has
  started.
- **R-10**: Removal MUST restore each consumer's previous mechanism and leave
  the ciphertext store in place; the revert is provable per consumer.
- **R-11**: A narrow plaintext file and the store MUST NOT share a key. No
  value is served from both, and a key that appears in both is a leak of that
  value into plaintext.

**Evidence** (how each requirement is satisfied, and what was measured to write
it; `*(observed)*` marks behaviour reproduced while authoring, with the input
that produced it):

| Req | Evidence |
|-----|----------|
| R-1 | Operator tooling reads the value into a 0600 temp file and pipes it to `sops set --value-stdin`, so it never reaches argv or history; the repository holds only `ENC[AES256_GCM,…]` values (see `scripts/sops-shared.sh`) |
| R-2 | The classification is mechanized: `scripts/find-consumers.sh` prints every reference to a variable with its mechanism, and `A-2` fails while any reference is absent from the inventory |
| R-3 | `sops exec-env` holds the process and execs the child with the decrypted values in its environment; nothing is written to disk *(observed: `sops exec-env <alias>.env '<command>'` injected `TOKEN=abc123`, exit 0)* |
| R-4 | The reference deployment's operator commands run inside a throwaway container that receives the variable through its own environment — wrap the invocation, not the file |
| R-5 | Compose substitutes an empty string for an unset variable and still exits 0 *(observed: `` PLAIN: "" `` in `docker compose config` output, one warning on stderr, rc 0)*; `${VAR:?message}` aborts the parse *(observed: rc 1, `required variable X is missing a value: …`)*; `sops exec-env` over an unreadable store exits non-zero and never runs the command *(observed: rc 1, `invalid dotenv input line: garbage`)*; a store key that is absent leaves the variable simply unset in the child *(observed: `${ABSENT:-unset}` printed `unset`)*, which is why the wrapper's name check exists |
| R-6 | `sops exec-env` injects each store key verbatim, so a reference to a value under a name the consumer does not read finds nothing; the wrapper checks store key names against the names the inventory records |
| R-7 | A projection is generated from the store by `scripts/sops-shared.sh extract` and encrypted to the master key plus that consumer's key only; `A-7` proves a canary key outside the projection cannot be decrypted with that consumer's key |
| R-8 | Rotation is the store update plus the projection regeneration plus the consumer restarts recorded in the inventory; no image is rebuilt and no ciphertext is re-templated |
| R-9 | The materializing wrapper removes its file on every exit path (`trap … EXIT`), and `A-9` looks for plaintext after the consumer has started rather than assuming the trap ran |
| R-10 | The narrow file was never deleted, only narrowed; restoring the previous mechanism is putting the interpolated key back and dropping the wrapper invocation |
| R-11 | `A-11` diffs the key sets of the narrow file and the store; the empty intersection is the requirement |

## Design Principles Binding the Implementation

1. **Vendor-agnostic** — implement with plain, portable components; no
   dependency on any specific agent or harness.
2. **Portable** — no absolute paths or machine-specific values in the
   implementation; use the Parameters below.
3. **Self-contained** — the implementation needs nothing outside this package
   and the declared Dependencies.
4. **Predictable, intuitive, ergonomic** — the installed capability behaves
   exactly as this document describes; no surprise behaviors.
5. **Idempotent and deterministic** — every phase is safe to re-run; checks
   give the same verdict every time.
6. **Parameterized and modular** — all tunables flow from the Parameters
   table; concerns are separated per the Modules section; behavior
   differences between deployments are configuration, never code edits.
7. **Dependencies called out** — implement the declared failure behavior for
   every Dependency.
8. **Composable in kind** — a dependency may be another schematic in the
   catalog, pinned to a commit and a content hash; a composition schematic
   owns no services, only the shared contracts and the end-to-end
   acceptance test.
9. **Applicable context stated** — discover what Must discover locally
   says; do not silently assume beyond May assume.
10. **Pluggable** — implement the attach/remove seams defined in Modules and
    Removal.

Binding notes where a principle applies non-obviously:

- **8** — this package is a spec-only schematic, not a composition: it owns the
  shared store, the wrapper and the guards. The container half of every remedy
  is delegated to `encrypt-container-secrets` (`D-5`), pinned, never restated.
- **6** — the consumer inventory (`P-12`) carries per-consumer facts (which
  variables, which remedy, whether it holds the whole store). Those belong in
  one file per deployment, not in this spec's parameter table, because they are
  discovered, not chosen.
- **4** — the failure this principle protects against has a specific shape
  here: a stack that starts cleanly with an empty token, reported by the
  consumer long after the start (see `modules/compose-interpolation.md`).

## Dependencies

| Id  | Kind | What | Why needed | Discovery | Failure behavior |
|-----|------|------|------------|-----------|------------------|
| D-1 | system | age encryption (keygen, recipients) | Generate the master and per-consumer keys, encrypt to them | Provided by `sops` (age built in) or the `age` package | Hard fail before Phase 3: without a recipient nothing encrypts |
| D-2 | system | SOPS binary on the host (`P-10 SOPS_IMAGE` supplies one when the host has none) | Encrypt, decrypt, extract projections, and inject the environment | `command -v sops`, else `docker create … --entrypoint sops "${SOPS_IMAGE}" --version` | Hard fail before Phase 3: `scripts/sops-shared.sh` and `skeleton/host-wrapper.sh` refuse with an explanation rather than degrading, because a container cannot inject values into a host process's environment. Remedies: a host that has the binary, or the sibling package's `sops-set-env.sh`, which implements a container fallback for value-setting |
| D-3 | system | POSIX shell where the wrapper runs | The wrapper execs the consumer through a shell, and sops spawns the child with `/bin/sh -c` | `sh -c 'echo ok'` exits 0 | Hard fail before Phase 5: no wrapper means every wrappable consumer keeps its plaintext path |
| D-4 | system | `python3` or `jq` | JSON-encode a value before `sops set --value-stdin` | `command -v python3 \|\| command -v jq` | Degrade: the operator passes `--value-file` with a pre-encoded value, or installs one of them |
| D-5 | schematic | [encrypt-container-secrets v0.2.2](https://github.com/cameri/schematics/blob/4ab37413e2d47c895074ea290867ec0f234f624f/schematics/encrypt-container-secrets/SCHEMATIC.md) `sha256:7b40f292571587b0c6a57460ab5611b2bb4104b1ea0cc6e6848dddea78a45d6a` | The container half of the taxonomy: a value that must reach a container process is injected by that package's boot wrapper, with its per-service key and its no-plaintext-on-disk guarantee. Declared instead of restated so the two specs cannot drift | Its own acceptance green; `docker compose config` of the consuming service shows its secrets wiring | A container consumer cannot be served by this package's host wrapper: Phase 5 stops for that consumer and it keeps its plaintext path until the dependency is deployed. Starting it with the store mounted instead is refused by `R-3` |
| D-6 | service | Docker Engine and Compose v2 | The parse-time consumer exists only here: interpolation, `--env-file`, and the resolved config that `A-5` inspects | `docker compose version` exits 0 | Without it there is no parse-time consumer on this host: phases 1-5 and 7-8 still apply, Phase 6 reduces to the narrow file's own checks |
| D-7 | system | A directory that is writable by the operator and backed by tmpfs (where the platform provides one) | Holds the ciphertext aliases and any materialized plaintext env-file | `findmnt -no FSTYPE --target "${RUNTIME_DIR}"` prints `tmpfs`; `test -w "${RUNTIME_DIR}"` | Degrade to a 0700 directory on a persistent filesystem: `R-9` then carries the whole lifetime guarantee and the inventory must say so per consumer |

## Parameters

| Id   | Name | Type | Default | Discovery | Effect |
|------|------|------|---------|-----------|--------|
| P-1  | `SECRETS_DIR` | path | `<stack-dir>/.secrets` | `test -d`; create in Phase 3 | Directory holding the store and every projection; tracked, ciphertext only |
| P-2  | `STORE_FILE` | path | `${SECRETS_DIR}/shared.env.encrypted` | `test -f`; create in Phase 3 | The SOPS dotenv store of shared secrets |
| P-3  | `PROJECTION_PATTERN` | path pattern | `${SECRETS_DIR}/<consumer>.env.encrypted` | Generated per consumer in Phase 4 | Derived store holding only the keys one consumer reads |
| P-4  | `PLAIN_ENV_FILE` | path | `<stack-dir>/.env` | `test -f`; it is the file the Compose CLI reads today | The narrow plaintext file: values that must be interpolated at parse time, none of them a secret |
| P-5  | `RUNTIME_DIR` | path | `/run` | `findmnt -no FSTYPE --target <dir>` is `tmpfs` from `D-7`; `test -w` | Parent of the alias directory and of any materialized plaintext; never inside a repository |
| P-6  | `WRAPPER_PATH` | path | `/usr/local/bin/sops-env-exec` | `test -x`; install in Phase 5 | Installed name of `skeleton/host-wrapper.sh`, so units and scripts can name a stable path |
| P-7  | `KEY_DIR` | path | `~/sops/age` | `ls`; create in Phase 4 if absent | Host directory holding the master key and every consumer key |
| P-8  | `MASTER_KEY_FILE` | path | `${KEY_DIR}/keys.txt` | `test -f`; create with `age-keygen` if absent | Break-glass key: decrypts every store and projection; never leaves the host |
| P-9  | `CONSUMER_KEY_PATTERN` | path pattern | `${KEY_DIR}/<consumer>-keys.txt` | `test -f` per consumer; create in Phase 4 | A consumer's own key, used as the second recipient of its projection |
| P-10 | `SOPS_IMAGE` | string | `ghcr.io/getsops/sops:v3.11.0-alpine` | `docker create … --entrypoint sops "${SOPS_IMAGE}" --version` | Supplies the pinned sops binary when the host has none |
| P-11 | `AGE_KEY_ENV` | string | `SOPS_AGE_KEY_FILE` | N/A: a sops convention | Names the variable sops reads the key path from |
| P-12 | `INVENTORY_FILE` | path | `<stack-dir>/SECRETS-CONSUMERS.md` | `test -f`; written in Phase 2 | The committed classification of every consumer: mechanism, names, remedy |
| P-13 | `COMPOSE_DIR` | path | `<stack-dir>` | The directory whose `.env` the CLI loads; confirmed with `docker compose config` | Where the parse-time consumer is served from: the narrow file, or a materialized env-file passed with `--env-file` |
| P-14 | `RUNTIME_FILE_MODE` | octal | `0600` | Compare the consumer's uid to the file owner's when a materialized file must be read by a container or another account | Permissions of any materialized plaintext file and of the alias directory |

## Modules

- **Consumer taxonomy** (`modules/consumer-taxonomy.md`) — the four classes a
  consumer can fall into, the decision procedure that assigns one, and the
  remedy each class gets.
- **Store and projections** (`modules/store-and-projections.md`) — the store's
  format and key contract, the split between the narrow file and the store, the
  recipient model, projection generation, and the alias mechanics that make a
  `.encrypted` store readable by `exec-env`.
- **Compose interpolation** (`modules/compose-interpolation.md`) — why the
  Compose CLI is a plaintext consumer by construction, the three remedies with
  their costs, and the measured behaviours that decide between them.
- **Rotation** (`modules/rotation.md`) — changing a shared value end to end:
  projections, the restart matrix, and the consumer that is hardest to move.

## Interfaces and Contracts

### The store (SOPS dotenv)

Format: SOPS dotenv, one `KEY=value` per line plus the `sops_` metadata block.
Contract points:

- The file name ends in `.encrypted`, so every sops call passes explicit
  `--input-type dotenv --output-type dotenv` (`sops exec-env` is the one
  exception and cannot be given those flags — see the alias contract below).
- Values are stored unquoted; a quoted value arrives at the consumer with its
  quotes.
- **The key name is the variable name** (`R-6`). A value migrated out of an
  interpolated `environment:` entry keeps working only if the store key is
  renamed to what the consumer reads.
- The recipient block names the master key plus every consumer declared as
  holding the whole store; projections name the master plus one consumer key.

### The alias contract (`exec-env` and the file name)

`sops exec-env` reads its input type from the **file name**, not from the
content, and it accepts no `--input-type` of its own; the global flag is not
honoured for the subcommand. Measured with sops v3.11.0:

| Path given to `exec-env` | Content | Result |
|---|---|---|
| `store.encrypted` | SOPS dotenv | exit 1, `Error unmarshalling input json` — the extension selected the JSON parser |
| `--input-type dotenv` before the subcommand, `store.encrypted` | SOPS dotenv | same failure: the flag does not reach `exec-env` |
| `store.env` (symlink, hardlink or copy of the same bytes) | SOPS dotenv | exit 0, values injected, ciphertext untouched |
| `store.env`, `--pristine` before the file | SOPS dotenv | exit 0, inherited environment dropped |
| `store.env` with the command split into several arguments | SOPS dotenv | exit 1, `error: missing file to decrypt` |
| `store.env` with `--` between file and command | SOPS dotenv | exit 1, `error: missing file to decrypt` |
| `--pristine` **after** the file | SOPS dotenv | exit 2, `Error reading file: open <the command>` — flags belong before the two positionals |

Consequences the implementation MUST honour:

- A store at rest is never handed to `exec-env` directly. The wrapper creates
  an alias whose name ends in `.env` in `${RUNTIME_DIR}/sops-alias/` and passes
  **that** path. An alias may be a symlink: the content is ciphertext, so its
  presence leaks nothing.
- The command is **one argument**: `sops exec-env <alias> '<command string>'`.
  Splitting it into argv words fails with a message that names neither the
  cause nor the argument.
- Flags precede the two positionals.

### `sops` flag placement (store-editing operations)

The type flags belong to the subcommand, not the program: `sops set --input-type
dotenv --output-type dotenv --value-stdin <store> '["KEY"]'`. Writing them
before `set` is accepted without an error and the value is then parsed as JSON
instead, so a plain string fails with `Error unmarshalling input json: invalid
character …` — a message about the value that says nothing about the flag
(measured, sops v3.11.0). `--decrypt` and `--encrypt` are program-level flags
and take them before their argument.

### The wrapper (host consumer interface)

```
sops-env-exec [--store <file>] [--age-key <file>] [--require <NAME[,NAME…]>] [--pristine] [--alias-dir <dir>] <command string>
```

- `<command string>` is one argument, run through `/bin/sh -c`.
- `--require` names the variables the consumer reads, from the inventory. The
  wrapper reads **key names only** from the store
  (`sops --decrypt --input-type dotenv --output-type dotenv <store> | grep -oE '^[A-Za-z_][A-Za-z0-9_]*'`),
  compares them against the list, and exits non-zero listing the missing names
  **before** exec'ing anything (R-5). Names are compared, never values.
- Default key: `P-8 MASTER_KEY_FILE`. `--age-key` points at a projection's
  consumer key instead.
- `--alias-dir` overrides where the `.env`-named symlink is created; the
  default is `${RUNTIME_DIR}/sops-alias`, created 0700. The wrapper needs no
  other state: it writes that one symlink and nothing else.
- Exit status is the child's own, so a wrapped script's failure is not masked.
- Missing or unreadable store: exit non-zero, nothing runs.

### Materialized runtime env-file (consumers that read a path)

```
materialize-env-file.sh [--from <store>] [--mode <octal>] <target-path> -- <command string>
```

Writes the decrypted dotenv to `<target-path>` under `P-5 RUNTIME_DIR` with
`P-14`'s mode, runs the command, and removes the file on every exit path
(`trap … EXIT INT TERM`). The file is never created empty: a decryption that
yields nothing exits non-zero before the command starts.

### Compose (the parse-time consumer)

```yaml
services:
  <service>:
    environment:
      TZ: ${TZ}                       # narrow file: safe in plaintext
      API_TOKEN: ${API_TOKEN:?API_TOKEN must be set}   # fail-fast, never blank
```

- A secret that must be interpolated is written in the fail-fast form, so a
  Compose run without the materialized value aborts instead of starting a
  stack with an empty token.
- The value is provided for the invocation that needs it:
  `sops-env-exec --require API_TOKEN 'docker compose up -d'` (the wrapper holds
  the value in the CLI's environment for that run only), or
  `docker compose --env-file "${RUNTIME_DIR}/sops-env/<name>" up -d` for a
  materialized file. A later Compose invocation **without** either sees the
  fail-fast form and stops: that is the intended behavior, not a regression.
- The pre-flight guard proves it:
  `docker compose config >/dev/null && … ` plus the named-variable check in
  `skeleton/preflight-compose-secrets.sh`, which fails when a named variable
  resolves to an empty string.

### Worked example: one shared API token, four consumers

The shape this spec exists for, with the roles named rather than the values: a
DNS-provider API token lives in the same file as `TZ`-style parse-time values,
and four unlike consumers need it.

| Consumer | Mechanism today | Class | Remedy |
|---|---|---|---|
| Operator commands, documented as one-line invocations (`… sh -c 'curl -H "Authorization: Bearer ${TOKEN}" …'`) | The operator's session environment holds the plaintext | Wrappable | Run the whole invocation under the wrapper; the token lives in that command's environment only |
| The Compose CLI's interpolation, in the same stack | Plaintext `.env` at parse time | Cannot decrypt | **Remove the need**: the token is not interpolated at all (no container in that stack needs it in its environment), so it leaves the narrow file. If one ever did, that container takes it through `D-5` |
| A container that needs the token in its own environment | Would be an interpolated `environment:` entry | Cannot decrypt (but does not have to) | `D-5`: the container decrypts its own store at boot |
| Tooling that reads the file by path at startup | Reads `P-4 PLAIN_ENV_FILE` | Cannot decrypt without changing how it starts | Change how it starts: point it at a materialized env-file (`materialize-env-file.sh`), or give it the value through its own process environment |
| A CLI the operator installs that takes the token from its own environment and can write it to a `0600` env file of its own | The operator exports the token first, or the CLI writes its own plaintext copy | Wrappable | Run the CLI through the wrapper, and treat the env file *it* writes as a materialized plaintext with a consumer named in the inventory — the second copy is the one that gets forgotten |
| Anything that reads only the non-secret parse-time values | Plaintext `.env` | Not a secret consumer | Stays on the narrow file; `A-11` proves the two files share no key |

What the example fixes, concretely: after the change the token is not in the
narrow file, not in any session's environment unless that command asked for it,
and a Compose run that would have started with a blank token stops instead.

## Implementation Phases

Phases are idempotent: every step states its skip condition. Run them from the
host, in the stack directory whose secrets are being served.

### Phase 1: System checks

Goal: verify dependencies before changing anything.

Steps:
1. `command -v docker && docker compose version` (D-6).
2. `command -v sops` or confirm the container path works:
   `docker create --label org.testcontainers=true --entrypoint sops "${SOPS_IMAGE}" --version`
   then `docker start` and read the logs (D-2).
3. `command -v python3 || command -v jq` (D-4; else use `--value-file`).
4. `findmnt -no FSTYPE --target "${RUNTIME_DIR}"` and `test -w "${RUNTIME_DIR}"` (D-7).
5. List the variables that are candidates to move: every key of
   `P-4 PLAIN_ENV_FILE` whose value is a credential, a token, or a password.

Verify: steps 1-4 exit 0, or the degradation each failure implies is written
into the inventory.

### Phase 2: Inventory and classify every consumer

Goal: `P-12 INVENTORY_FILE` exists, and every reference the search finds is in
it with a class and a remedy.

Steps:
1. For each candidate variable: `scripts/find-consumers.sh <VAR> <search-root>`
   (the stack directory, plus any repository or tooling directory that names
   it), adding `--exclude <dir>` for every directory the host's tooling keeps
   session transcripts or logs in — they discuss the variable, they do not
   consume it, and one of them will hold the value. Skip if the inventory
   already carries a row for that variable and its reference count.
2. Assign each reference a class from `modules/consumer-taxonomy.md`
   (wrappable, path-reading, parse-time, or non-consumer) and the remedy
   (a), (b) or (c) for anything that cannot decrypt.
3. Record per consumer: location, mechanism, variable names it reads, class,
   remedy, and whether it holds the whole store or a projection (`R-7`).
4. Any reference you cannot classify is left in the inventory as
   `class: unknown` with the reason — never dropped, since dropping it is how
   a consumer ends up unserved.

Verify:
```bash
grep -c '^| ' "${INVENTORY_FILE}"                       # >= 1
scripts/find-consumers.sh <VAR> <root> | wc -l          # equals the inventory's reference count for <VAR>
```

### Phase 3: Split the file

Goal: the store holds every shared secret; the narrow file holds only values
that must be interpolated and are not secrets.

Steps:
1. Skip if `P-2 STORE_FILE` exists; otherwise create the first version,
   encrypted to the master key (and to any consumer declared as holding the
   whole store):
   `sops --input-type dotenv --output-type dotenv --encrypt --age "<MASTER_PUB>" /dev/stdin > "${STORE_FILE}"`
2. For each secret key: set its value in the store
   (`scripts/sops-shared.sh set "${STORE_FILE}" NAME`, value on stdin), then
   delete the line from `P-4 PLAIN_ENV_FILE`.
3. Keep every value the Compose CLI interpolates that is *not* a secret in the
   narrow file, and leave its `${VAR}` usage alone.
4. Do not commit plaintext intermediates: the scripts write a 0600 temp file
   and remove it on exit.

Verify:
```bash
grep -c '^NAME=' "${STORE_FILE}"                 # >= 1, and the value is ENC[…]
grep -c '^NAME=' "${PLAIN_ENV_FILE}"             # 0
comm -12 "$(keys_of "${PLAIN_ENV_FILE}")" "$(keys_of "${STORE_FILE}")"   # prints nothing (R-11)
```
`keys_of` is `grep -oE '^[A-Za-z_][A-Za-z0-9_]*' <file> | grep -v '^sops_' | sort -u`
for the plaintext file and the same over `sops --decrypt …` for the store.

### Phase 4: Recipients and projections

Goal: every consumer's key decrypts exactly the file that consumer is given.

Steps:
1. Skip if `P-8 MASTER_KEY_FILE` exists; otherwise create the key directory
   (0700) and the master key with `age-keygen`, and record its public half.
2. For each consumer whose inventory row says `projection`: skip if
   `P-9 CONSUMER_KEY_PATTERN` exists; otherwise create it the same way.
3. Generate each projection from the store:
   `scripts/sops-shared.sh extract "${STORE_FILE}" "${PROJECTION_PATTERN}" "<KEY>[,<KEY>…]" --consumer-key "<consumer key>"`.
   The script decrypts with the master key, keeps only the named keys,
   re-encrypts to the master plus that consumer's key, and prints both public
   keys it used. Re-run it after every rotation of a key it carries.
4. For a consumer declared as holding the whole store, add its public key to
   the store's recipient list
   (`scripts/sops-shared.sh --add-recipient "${STORE_FILE}" "<CONSUMER_PUB>"`)
   and record that in the inventory.

Verify:
```bash
sops --decrypt --input-type dotenv --output-type dotenv "${STORE_FILE}" >/dev/null && echo store-ok
grep -o 'age1[a-z0-9]*' "${PROJECTION_FILE}" | sort -u     # exactly two: master and that consumer
```

### Phase 5: Serve the wrappable consumers

Goal: every class-`wrappable` consumer gets its values by in-memory decryption.

Steps:
1. Install the wrapper at `P-6 WRAPPER_PATH` (mode 0755) and confirm
   `D-3`: `sh -c 'echo ok'`.
2. For each wrappable consumer, replace its invocation with
   `"${WRAPPER_PATH}" --require <names from the inventory> '<original command>'`:
   cron entries, unit files, scripts, and documented commands alike. Skip any
   consumer already wrapped.
3. For a consumer that is a container, apply `D-5` instead: the container's own
   store and boot wrapper. If its values come from the shared store, generate
   its projection and mount that.
4. Do not leave a consumer with both paths: the wrapped invocation and a
   plaintext path to the same value is two sources of truth.

Verify:
```bash
"${WRAPPER_PATH}" --require <NAME> 'printf "%s\n" "${NAME:+present}"'   # prints: present
"${WRAPPER_PATH}" --require NOT_IN_STORE 'echo ran'                     # non-zero, no "ran"
```

### Phase 6: Serve the parse-time consumer

Goal: no interpolation of a secret can produce a blank value.

Steps:
1. Skip if no variable that moved is interpolated: the inventory shows no
   parse-time consumer for it. Otherwise apply the remedy from its inventory
   row: (a) a wrapped Compose invocation, (b) a materialized env-file passed
   with `--env-file`, or (c) removal of the interpolation.
2. Rewrite every interpolated secret in the compose files as `${VAR:?message}`,
   including the values served by a wrapped invocation: the fail-fast form is
   what makes the wrapper's absence loud.
3. If a materialized env-file is the remedy, generate it for the invocation:
   `materialize-env-file.sh --from "${STORE_FILE}" "${RUNTIME_DIR}/sops-env/<stack>.env" -- 'docker compose up -d'`.
4. Leave the narrow file's non-secret values exactly as they were.

Verify:
```bash
skeleton/preflight-compose-secrets.sh --var TZ --var API_TOKEN -- docker compose config   # exit 0
# and, with the materialized value absent, the same command exits non-zero and names API_TOKEN
```

### Phase 7: Rotate one value end to end

Goal: prove the procedure in `modules/rotation.md` against a real consumer set.

Steps:
1. Pick a value with at least one wrappable and one non-wrappable consumer.
2. Set the new value (`scripts/sops-shared.sh set …`).
3. Regenerate every projection that carries it (Phase 4 step 3).
4. Restart or re-invoke each consumer its inventory row names, and read the new
   value back through the consumer's own path — not from the store.
5. Confirm no image was rebuilt: `docker image inspect <image> --format '{{.Created}}'`
   is unchanged for every container consumer.

Verify: every consumer shows the new value; no consumer required a rebuild.

### Phase 8: Removal

Goal: the host is back to its previous mechanism, with the ciphertext intact.

Steps: see Removal.

## Verification and Acceptance

Every check below runs from the host after the phases complete. `A-5`, `A-6`
and `A-11` are runnable against a throwaway store with a canary value and no
real consumer, which is how they are meant to be exercised before the first
real migration.

- **A-1** (covers R-1): no plaintext value reached a versioned or backed-up
  location. Put a canary in the store, then:
  ```bash
  git grep -n -F "<canary>" -- .        # no output
  git log -p --all | grep -c -F "<canary>"   # 0
  ```
  Expected: no output and `0`. Also `find "${RUNTIME_DIR}" -maxdepth 2 -perm -o+r -type f` prints nothing.
- **A-2** (covers R-2): the inventory classifies every reference. For each
  variable: the set of `path:line` from `scripts/find-consumers.sh <VAR> <root>`
  equals the set of `path:line` in the inventory's rows for that variable;
  `class: unknown` rows are counted and reported, and any reference missing
  from the inventory fails this check.
- **A-3** (covers R-3): a wrapped consumer gets the value, and only the value.
  Expected: the required name prints non-empty; with `--pristine`, the child's
  environment contains only the store's key names
  (`env | cut -d= -f1 | sort` equals the store's key names).
- **A-4** (covers R-4, remedy (b)): a materialized file is a bounded plaintext.
  Expected: while the consumer runs, the file exists with `P-14`'s mode
  (`stat -c %a`), its directory is tmpfs where `D-7` found one
  (`findmnt -no FSTYPE --target`), and it is outside every repository
  (`git -C <repo> check-ignore` or a path comparison). After the consumer
  exits — including when it exits non-zero — the file is gone.
- **A-5** (covers R-5): no secret resolves to an empty string.
  ```bash
  docker compose config >/dev/null; echo "rc=$?"          # with the value absent: rc != 0
  docker compose config 2>&1 | grep -c 'required variable' # >= 1, naming the missing variable
  "${WRAPPER_PATH}" --require NAME 'echo ran'             # with NAME absent from the store: non-zero, no "ran"
  ```
  Also refuse a value that is still ciphertext, which is what an `env_file:`
  or `--env-file` naming a store produces (the CLI inlines the file's contents
  into the service environment, so the variable is non-empty and wrong):
  ```bash
  skeleton/preflight-compose-secrets.sh --var API_TOKEN -- docker compose config
  # non-zero, naming the variable and reporting that it resolves to CIPHERTEXT
  ```
  Expected: the fail-fast form aborts the parse; the wrapper refuses before
  exec'ing; a ciphertext value is refused rather than passed. Measured baseline:
  an unset variable **without** the fail-fast form exits 0 with `PLAIN: ""` in
  the resolved config, which is the state this test exists to end.
- **A-6** (covers R-6): the store key is the variable name the consumer reads.
  For every consumer: `comm -23 <(inventory names for that consumer) <(store key names)`
  prints nothing. A non-empty result names a variable the consumer reads and
  the store does not define — the silent-blank case again, caught before start.
- **A-7** (covers R-7): a projection's key decrypts its own keys and nothing
  else. With a canary key in the store that the consumer does not read:
  ```bash
  sops --decrypt --input-type dotenv --output-type dotenv "${PROJECTION_FILE}" \
    | grep -c '<canary-key>'      # 0
  SOPS_AGE_KEY_FILE="<consumer-key>" sops --decrypt --input-type dotenv --output-type dotenv "${STORE_FILE}" \
    >/dev/null                    # non-zero: the consumer key is not a recipient of the store
  ```
  Expected: `0`, and a non-zero exit whose message names the missing key.
- **A-8** (covers R-8): rotation needs no rebuild. After Phase 7: every
  consumer's own path shows the new value, and
  `docker image inspect <image> --format '{{.Created}}'` is unchanged for every
  container consumer.
- **A-9** (covers R-9): no plaintext survives a consumer's start.
  ```bash
  find "${RUNTIME_DIR}" -name '*.env' -type f -newer "${STORE_FILE}"   # no plaintext env file
  docker diff <service> | grep -iE '\.env$'                            # empty for container consumers
  ```
  Expected: no output. Run it after the consumer has started, not only after
  it exited: a file left behind while a process runs is the failure this
  catches.
- **A-10** (covers R-10): removal restores the previous mechanism. After the
  Removal procedure: every consumer starts, `git status --porcelain` shows the
  store's ciphertext still tracked and untouched, and
  `grep -c 'sops-env-exec' <cron, units, scripts>` is 0.
- **A-11** (covers R-11): the narrow file and the store share no key.
  ```bash
  comm -12 <(keys_of "${PLAIN_ENV_FILE}") <(keys_of_store "${STORE_FILE}")   # prints nothing
  ```
  Expected: no output. A shared key means the value is still in plaintext.

**Verification provenance.** The behaviours this spec depends on were
measured, not assumed, against `sops` v3.11.0 and Docker Compose v2: the
interpolation table in `modules/compose-interpolation.md`, the alias table in
Interfaces and Contracts, the `sops set` flag placement above, and the
`--pristine`/single-argument rules. The package's own tools were then exercised
end to end on a throwaway store with canary values and throwaway age keys: store
creation from stdin, `keys`/`set`/`remove`, a two-recipient projection whose
consumer key decrypts the projection and is refused by the store, an added
recipient that can decrypt the store, the wrapper with present and absent
required names, the wrapper's refusal of a multi-word command, `--pristine`
dropping the inherited environment, the alias naming rule, the materializer's
mode, its removal on success and on a failing command, `--keep`, and the
pre-flight guard against a value that resolves empty or to ciphertext (the
ciphertext case measured through an `env_file:` naming an encrypted file). `A-1` through `A-11` are
the implementer's checks, not a record of that run.

## Failure Modes and Rollback

**Phase 2 (inventory).** The expensive failure is an incomplete inventory: a
consumer nobody found keeps reading a stale plaintext copy, or starts with a
blank value. Detect: `A-2`, and the consumer's own logs after the plaintext file
is narrowed. Rollback: restore the value to the narrow file for that consumer
only, and record it in the inventory as `class: unknown` with the evidence.

**Phase 3 (split).** A botched edit can drop a value from the narrow file while
never reaching the store, so nothing reads it. Detect: the phase's verify
(`grep -c '^NAME='` in both places) and `A-11`. Rollback: the previous
`P-4 PLAIN_ENV_FILE` is in version control; restore it and redo the key one at a
time. Never edit the store in place without a copy: `cp "${STORE_FILE}"
"${STORE_FILE}.bak"` before a re-encryption, verify the recipient list and key
count afterwards, then delete the backup.

**Phase 4 (keys and projections).** A projection generated before its consumer
key exists is encrypted to the master alone and appears to work for the
operator while failing for the consumer. Detect: `A-7`'s recipient count (a
projection has exactly two recipients). Rollback: regenerate the projection.
A lost master key makes every store and projection unreadable: keep a copy of
`P-8 MASTER_KEY_FILE` outside the repository and treat its loss as
non-recoverable.

**Phase 5 (wrappers).** A wrapper that receives its command split into argv
words exits with `error: missing file to decrypt`, and a wrapper pointed at the
`.encrypted` store instead of an alias exits with `Error unmarshalling input
json`; both name neither cause nor argument. Detect: the phase's verify. Fix the
invocation; no other phase is affected. A wrapped cron entry that loses its
environment fails the same way a plain one does — the fix is
`--require` plus the consumer's own error, not blank values.

**Phase 6 (parse-time).** A Compose run executed outside the wrapper (a host
reboot brings the stack up through a unit, a colleague runs `docker compose up`
by hand) meets the fail-fast form and stops. That is the designed behavior;
detect it in the unit's logs and wrap that invocation too. The opposite failure
is worse and quiet: dropping the `:?` form leaves a stack that starts with an
empty token.

**Phase 7 (rotation).** A projection that is not regenerated keeps serving the
old value to its consumer while the store holds the new one. Detect: read the
value back through the consumer's own path (`A-8`), never from the store.
Rollback: regenerate every projection that carries the key.

**Phase 8 (removal).** A consumer left wrapped after its plaintext path is
restored (or the reverse) gives two sources of truth for one value. Detect:
`A-10`'s grep for the wrapper name. Rollback: pick one path per consumer.

## Removal

Reverse the wiring; the ciphertext stays:

1. For every consumer the inventory lists as wrapped: restore the original
   invocation (unit, cron entry, script, documented command).
2. For every materialized env-file: remove `--env-file`/the materializing
   wrapper from the invocation, and delete any file left under
   `${RUNTIME_DIR}/sops-env/`.
3. Restore into `P-4 PLAIN_ENV_FILE` the values this deployment moved, except
   those the operator chooses to keep out of plaintext (a consumer that still
   needs them keeps its remedy).
4. Remove `${RUNTIME_DIR}/sops-alias/*` and uninstall `P-6 WRAPPER_PATH` if
   nothing else uses it.
5. Containers: reverse `D-5` per its own Removal section.
6. `docker compose up -d` (or restart the units), and re-run `A-5` with the
   fail-fast form removed.

Confirm after removal:
```bash
grep -rc 'sops-env-exec' <units, crontab, scripts>   # 0
git status --porcelain "${SECRETS_DIR}"             # ciphertext still tracked, unmodified
docker compose up -d && docker compose ps           # every service running
```

Keeping `${SECRETS_DIR}` is intentional: the ciphertext is the only artifact
that cannot be reconstructed if the keys are ever put back into use, and it is
what makes a half-finished removal recoverable.

## Decisions and Open Questions

Decisions:

- 2026-09-19 — **A separate schematic, not an extension of
  `encrypt-container-secrets`.** That package's contract is one service, one
  store, one key, in the container; it states as a non-goal that it does not
  migrate a cleartext `.env` other tooling reads, and its blast-radius rule is
  a key per service. The capability here is the opposite shape: one file, many
  consumers, and a consumer (the Compose parser) that cannot decrypt at all.
  Extending would mean superseding two of its requirements and rewriting its
  scope; declaring it as a pinned dependency (`D-5`) keeps both contracts
  single-purpose and reuses the container half unchanged. The reasoning is
  restated in the pull request, per the repository's rule that a spec states
  what is true now and the PR carries the argument.
- 2026-09-19 — **The store is read through a `.env`-named alias, never by
  renaming the ciphertext.** `sops exec-env` selects its parser from the file
  name and honours no input-type flag (measured, see Interfaces). Naming the
  ciphertext itself `.env` would put a file that looks sourceable in front of
  every tool that globs `.env`; a symlink in a runtime directory keeps the
  tracked name honest.
- 2026-09-19 — **The wrapper verifies names, not values.** A store key absent
  from the file leaves the variable unset in the child with no error
  (measured). Comparing the store's key names against the names the inventory
  records is what converts that silent state into a refusal, and it prints
  nothing secret.
- 2026-09-19 — **Interpolated secrets get the fail-fast form rather than a
  wrapper-only rule.** A wrapped Compose invocation makes the value present for
  that run, but any other invocation of the same stack — a unit at boot, a
  colleague, a CI job — would otherwise start with a blank value and exit 0
  (measured: empty string in the resolved config, rc 0). `${VAR:?}` makes the
  absence loud wherever it happens.
- 2026-09-19 — **Host consumers use the master key by default.** The master key
  is host-only and already decrypts every store, so a host wrapper needs no new
  key. Consumer keys exist for projections, which is where a key's blast radius
  actually matters: a container that reads two of twelve values must not hold a
  key that opens the other ten.

Open questions:

- **Q-1**: Whether to commit a recipients file (the list of public keys per
  store and projection) so a re-encryption after a key change is scriptable
  without decrypting the store first. Default: no — the recipients are
  recoverable from each file with `grep -o 'age1[a-z0-9]*'`, and a committed
  recipients file is one more artifact to keep in sync.
- **Q-2**: How to serve a consumer that reads a value at a moment this spec
  cannot wrap — an interactive session that exports the value into a shell for
  hours. Default: document the wrapper for the specific command that needs the
  value, and treat a long-lived exported plaintext as an accepted, inventoried
  exception (`R-4` remedy (b), with its lifetime bounded by the session).
- **Q-3**: Whether the narrow file should be *generated* from a template to
  keep its keys provably disjoint from the store. Default: no generation step
  — `A-11`'s intersection check is enough, and generating a file whose values
  are not secrets adds a build artifact for no security gain.
- **Q-4**: Behaviour when `P-5 RUNTIME_DIR` is not tmpfs (a host without one).
  Default: place the alias directory there anyway (it holds ciphertext), put
  materialized plaintext in a 0700 directory, and record the reduction of
  `R-9` per consumer in the inventory.
