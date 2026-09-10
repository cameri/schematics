---
name: <schematic-name>
version: 0.1.0
status: draft          # draft | stable | superseded
spec: 1                # schematic format version (this template's shape)
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
---

# Schematic: <Human-readable capability name>

One paragraph: what this capability is and what exists after the implementer
finishes. Written for a reader with zero context.

## Applicable Context

What the implementer must know about the target environment, in three lists:

**Must discover locally** (with the discovery command/method for each):
- ...

**May assume** (each with the risk if the assumption is wrong):
- ...

**Must not change** (host constraints the capability works within):
- ...

## Scope

**In scope:** ...
**Out of scope / non-goals:** ...
**Preservation List** *(reverse-engineered schematics only)*: behaviors that
must match the original exactly (data formats, wire messages, stored state),
separated from behaviors open to reinterpretation.

## Requirements

Numbered, testable, ordered by importance. Each maps to at least one
acceptance test.

- **R-1**: ...
- **R-2**: ...

Non-functional requirements (performance, security, resource limits) use the
same numbering.

## Design Principles Binding the Implementation

Keep this section verbatim unless a principle genuinely does not apply (state
why next to the struck principle). The implementer treats these as acceptance
criteria:

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
   table; concerns are separated per the Modules section.
7. **Dependencies called out** — implement the declared failure behavior for
   every Dependency.
8. **Applicable context respected** — discover what Must discover locally
   says; do not silently assume beyond May assume.
9. **Configuration flexibility** — behavior differences come from
   configuration, never source edits.
10. **Pluggable** — implement the attach/remove seams defined in Modules and
    Removal.

## Dependencies

| Id  | What | Why needed | Discovery | Failure behavior |
|-----|------|------------|-----------|------------------|
| D-1 |      |            |           |                  |

For composition schematics, the Kind column accepts `schematic`: a
dependency on a sibling package in this catalog, linked with a RELATIVE
path (`../<name>/SCHEMATIC.md`) and pinned by the marketplace entry. A
composition schematic contains no images or services of its own - only
the shared contracts (volumes, networks, parameters), the isolation
rules between the parts, and the end-to-end acceptance test. Parts must
pass their own acceptance tests in isolation before any glue phase.

## Parameters

Every environment-specific value. Referenced by name from prose and code.

| Id  | Name | Type | Default | Discovery | Effect |
|-----|------|------|---------|-----------|--------|
| P-1 |      |      |         |           |        |

## Modules

One subsection per module, each an inline summary pointing at its full doc in
`modules/<name>.md`. If the capability is small enough to be one module, keep
the single module doc and say so here.

- **<module-name>** (`modules/<name>.md`) — one-line responsibility summary.

## Interfaces and Contracts

The exact surfaces the capability exposes or consumes: endpoints, file
formats, message schemas, CLI flags. Fully specified here or in the owning
module doc — never "standard REST behavior" hand-waving.

## Implementation Phases

Ordered phases. Each: goal, steps (skip conditions for idempotency), and its
own verification. A phase is complete only when its verification passes.

### Phase 1: <name>
Goal: ...
Steps:
1. ...
Verify: ...

### Phase N: ...

## Verification and Acceptance

One test per requirement minimum. Ids `A-<n>`, each naming the requirement it
covers, the exact check (command or precise behavioral description), and the
expected result. Every A-<n> is runnable by the implementer after the
phases complete.

- **A-1** (covers R-1): ... expected: ...

## Failure Modes and Rollback

For each phase: what can fail, how it is detected, and how to undo the phase
safely. Partial-completion handling: how to detect a half-applied phase and
recover.

## Removal

How to detach/uninstall the capability and leave the host working: what was
added where, what is safe to delete, what must be restored, and how to
confirm clean removal. (Pluggability: a stated, safe procedure.)

## Decisions and Open Questions

Decisions:

Judgment calls made during authoring and updating, newest last. The next
updater reads this first.

- <date> — <decision and why>

Open questions:

Undecided points, each with the default the implementer may take if the
author has not answered by implementation time.

- **Q-1**: ... default: ...



