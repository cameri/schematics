# Module: Consumer Taxonomy

Every consumer of the shared store falls into one of four classes, and the class
decides the remedy. Nothing else in this package matters as much: the same value
served to a wrappable consumer and to the Compose parser cannot use the same
mechanism, and treating them alike is how a stack starts with an empty token and
reports it hours later.

## Purpose

Owns the classification of consumers and the remedy each class receives, plus
the decision procedure that assigns a class from evidence rather than
assumption. It does **not** own the store's format (`store-and-projections.md`),
the parse-time mechanics (`compose-interpolation.md`), or rotation
(`rotation.md`).

## Inputs

- The variable names that are moving into the store (from Phase 1's system
  check).
- The search roots that could name them: the stack directory, any repository
  holding the tooling that uses them, the operator's documented procedures.
- `scripts/find-consumers.sh <VAR> <search-root>` output: one line per
  reference, with the mechanism it detected.
- For each reference, one fact the search cannot establish: whether a command
  of yours can run before that consumer needs the value.

Error inputs tolerated: a reference the script cannot classify (it prints
`mechanism: unknown` with the line); a variable that appears in no file (a
consumer that reads it from the ambient environment only, which the inventory
must carry as a hand-written row).

## Outputs

- The inventory (`P-12 INVENTORY_FILE`), one row per consumer:
  location, mechanism, variable names read, class, remedy, and whether it holds
  the whole store or a projection.
- A stated remedy per non-wrappable consumer, chosen from the three below.

**The four classes:**

| Class | Test | Remedy |
|---|---|---|
| **Wrappable** | A command of yours can run immediately before the consumer needs the value, in the environment the consumer reads | `sops-env-exec --require … '<command>'`, or `D-5` for a container's own process |
| **Path-reading** | The consumer opens a file by path at start (an application config, `EnvironmentFile=`, a tool's config file) and you can change how it starts | Remedy (a): change the start command so a wrapper runs first, or remedy (b): materialize a plaintext runtime env-file for that consumer's lifetime |
| **Parse-time** | The value is resolved by the Compose CLI while parsing (`${VAR}` in a compose file) | Remedy (a), (b) or (c) per `compose-interpolation.md`; never a plaintext repository file for a secret |
| **Not a consumer** | The reference is a comment, an example, a build-time `ARG` for a version number, or a value that is not a secret | Leave it; record it so the next inventory run does not re-open the question |

**The decision procedure, in order:**

1. Does the *parse* of a compose file need the plaintext? The CLI resolves
   interpolation before any container exists, so the answer is decided by
   `docker compose config` showing the value, not by reading the compose file.
   If yes → parse-time.
2. Otherwise, can a command of yours run first in the same environment the
   consumer reads? A cron job, a unit's `ExecStart`, a script, a one-line
   documented invocation, a container entrypoint: yes → wrappable.
3. Otherwise the consumer reads a path at start. Can you change that path or
   the command that leads to it (point it at a materialized env-file, pass the
   value in its environment)? Yes → path-reading, remedy (a).
4. Otherwise → path-reading, remedy (b): materialize at `P-14`'s mode under
   `P-5 RUNTIME_DIR`, on tmpfs where the platform provides one, removed when
   the consumer exits.
5. If none of the above is possible without editing the consumer's source or
   giving up the value, the honest outcome is remedy (c): the consumer stops
   reading that value, and the inventory says so.

## Dependencies

- `D-6` (Compose v2) for step 1 of the procedure.
- `D-7` and `P-5` for remedy (b).
- `D-5` for the container case in remedy (a).
- `P-12`, `P-14` from the main tables.

## Failure Behavior

- **A consumer the search missed.** It keeps working from a stale plaintext
  copy or starts with a blank value; nothing errors. Detect with `A-2` (the
  inventory must account for every reference) and with the consumer's own logs
  after the plaintext file is narrowed. Remedy: add the row, then serve it.
- **A consumer classified wrappable that turns out not to be.** Its start runs
  a wrapper that does not receive the value where the consumer looks. Detect:
  the consumer's own error, at start, immediately after the change — this is
  the cheap direction and the reason to change one consumer at a time.
- **A parse-time value classified as something else.** The stack starts with a
  blank value and exits 0 (measured, see `compose-interpolation.md`). Detect
  `A-5`. Remedy: apply the fail-fast form, then the remedy.
- **A consumer that holds the whole store when it needed two keys.** No symptom
  at all until the key is compromised. Detect: the inventory's "whole store"
  column against the keys each consumer actually reads (`A-6` names the
  variables, so the comparison is mechanical). Remedy: regenerate as a
  projection.
- **A value in the store under a name no consumer reads.** Nothing errors: the
  variable is simply unset in the child. Detect: `A-6`. Remedy: rename the store
  key to what the consumer reads (`R-6`); never add a bridging mapping.

## Idempotency Notes

Re-running the inventory is safe and is the intended way to keep it true: the
script prints the same lines for unchanged files, and the phase's verify
compares sets rather than counts. Classification is a reading of the
environment, so a consumer that changes mechanism appears as a changed row, not
as a new consumer. A consumer already served by the remedy its row names is
skipped.

## Removal Notes

Nothing in this module adds state to the host: the inventory is a document. On
removal it stays — it is the record of what the store serves and the starting
point for a future deployment.
