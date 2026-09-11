# Module: composition convention

This package follows (and extends) the rules for schematic-to-schematic
composition. Version 2 of the convention adds cryptographic pinning of
dependency contracts.

## 1. Dependencies gain a `schematic` kind

The dependency table's Kind column accepts `schematic` alongside
`system` and `service`.

## 2. Schematic dependencies are pinned: commit + content SHA-256

A schematic-kind dependency MUST be referenced by an absolute URL to the
dependency's SCHEMATIC.md at a SPECIFIC COMMIT in the remote repository,
plus the SHA-256 of the file's contents at that commit:

```
https://github.com/<org>/<repo>/blob/<commit>/schematics/<name>/SCHEMATIC.md
sha256:<hex of the file's contents at that commit>
```

Rules:

- **Never a floating ref.** `main`, `HEAD`, or a branch name in the URL
  is a violation: the contract would drift under the composition.
- **The hash is of the file contents at that commit** (the raw file, as
  `curl https://raw.githubusercontent.com/<org>/<repo>/<commit>/<path> |
  sha256sum` prints). Verification is mechanical: fetch the raw file at
  the pinned commit, hash it, compare.
- **The marketplace entry is the name index; the pinned link is the
  contract.** A composition's `composes` field lists sibling names for
  display; the SCHEMATIC.md dependency table carries the pins.
- **Re-pin deliberately.** When a dependency evolves and the composition
  re-verifies against it, the composition's own version bumps and the
  pin (commit + hash) is updated in the same change. A pin is never
  silently moved.

Why both: the commit says "this version"; the hash says "and here is
proof of what it says". A link without the hash trusts GitHub; the hash
makes the trust a one-line check (A-7 in this package).

## 3. Contracts, not copies

Reference dependency requirements by ID (e.g. "D-2's R-1"); never
restate them. If the glue needs a new obligation, write it as the
composition's own requirement, referencing the source.

## 4. Glue-only scope

A composition schematic contains no images, services, or networks of its
own - only shared contracts, isolation/anti-drift rules, the combined
runbook, and the end-to-end acceptance test.

## 5. Parts must pass alone first

Phase 0 installs the dependencies and passes their acceptance tests IN
ISOLATION. The parts-standalone rule keeps a decomposition path open
forever.

## 6. Anti-drift is a requirement class

Anything duplicated between the parts that must stay equal becomes an
explicit composition requirement backed by a single source and an
acceptance test.

## 7. Recommended (optional) dependencies

A composition MAY list dependencies the operator can decline without
losing the composition's core job. Rules:

- They live in a separate **Recommended** table under the Dependencies
  section, never mixed into the required table. An implementer reading
  only the required table must be able to complete every required phase.
- Same pinning rule as required schematic dependencies: absolute URL at
  a SPECIFIC COMMIT plus the file's content SHA-256. "Optional" relaxes
  whether you deploy it, never how precisely you reference it.
- Each recommended row states what the composition does without it (the
  degraded-but-working behavior) and what it adds.
- The composite's phases mark where a recommended dependency attaches
  (e.g. "Phase N (recommended): ..."), and the acceptance set must be
  satisfiable with every recommended dependency declined.
