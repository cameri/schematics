# Module: composition convention

This package establishes the general rules for schematic-to-schematic
composition in the format. Future composition schematics follow it;
single-stack schematics are unaffected.

## 1. Dependencies gain a `schematic` kind

The dependency table's Kind column accepts `schematic` alongside
`system` and `service`. A schematic-kind dependency points at a sibling
package in the same catalog:

- The "What" cell links the sibling's SCHEMATIC.md at a SPECIFIC COMMIT
  in the remote repository, plus the SHA-256 of the file's contents at
  that commit. Never a floating ref (`main`, `HEAD`): the contract would
  drift under the composition. Verify mechanically:
  `curl <raw-url-at-commit> | sha256sum` and compare.
- The marketplace entry remains the name index; the pinned link is the
  version-of-record for the contract.
- Re-pin deliberately: when the composition re-verifies against a newer
  dependency, the pin (commit + hash) updates in the same change as the
  composition's own version bump.
- "Failure behavior" describes the composition degraded, not the
  dependency broken (it documents its own failures).

## 2. Contracts, not copies

A composition references the dependency's requirements by ID (e.g.
"serve-books-using-containers R-2") instead of restating them. If you find yourself
copying a requirement into the composition, stop: either the glue
really needs a new obligation (then write it as the composition's own
R, referencing the source) or it does not belong here.

## 3. Glue-only scope

A composition schematic contains no images, services, or networks of
its own. Its content is exactly:

- the shared contracts (volumes, networks, parameters),
- the isolation/anti-drift rules between the parts,
- the combined runbook and the end-to-end acceptance test.

If it needs a container, it is a regular schematic that depends on
others, not a composition schematic.

## 4. Parts must pass alone first

Composition phases begin at Phase 0: install the dependencies and pass
their acceptance tests IN ISOLATION. Debugging entangled half-broken
stacks is how integration turns into archaeology; the parts-standalone
rule keeps a decomposition path open forever ("down both, verify each
alone, reapply glue").

## 5. Anti-drift is a requirement class

Anything duplicated between stacks that must stay equal (shared paths,
uid, timezone) becomes an explicit composition requirement backed by a
single source (one env file) and an acceptance test that changes it in
one place and observes both stacks follow.

## Why the format needed this

Until now every schematic was standalone: composition happened only in
an operator's head. That did not scale to stacks that genuinely share a
dataset boundary (a fetching half and a serving half). The convention
makes the boundary itself the artifact - reviewable, testable, and
independent of who assembled it.
