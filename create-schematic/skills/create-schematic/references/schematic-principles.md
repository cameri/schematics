# Schematic Principles

The ten binding principles from SKILL.md, each with what it demands of the
artifact and how to verify it. Walk this checklist during the mandatory
self-audit. A schematic that fails any check is not done.

## 1. Vendor-agnostic

**Demands:** The package contains only plain Markdown, portable shell, and
portable data formats (JSON, YAML, TOML). No references to any specific agent
harness: no tool names, no skill/plugin frontmatter, no session or channel
concepts, no "the assistant should...". Instructions are addressed to "the
implementer" — whatever LLM reads it.

**Verify:** Search the package for known agent-tool vocabulary and harness
terms; search for instructions phrased as actions only a specific agent could
take. Everything must be executable by a plain LLM with a shell and a text
editor.

## 2. Portable

**Demands:** No absolute paths, no hostnames, no usernames, no OS assumptions
unless the requirement states them. Every environment-specific value is a
parameter. Where the OS genuinely matters (a shell quirk, a path convention),
the schematic states the assumption and the alternative.

**Verify:** Search for absolute paths and machine-specific literals — each hit
must be inside the Parameters table as a documented example default, nowhere
else.

## 3. Self-contained

**Demands:** The package is the complete world. The implementer needs: the
spec (SCHEMATIC.md), per-component contracts (modules/), anything runnable
(scripts/), anything copied (skeleton/), anything produced (templates/). No
"see the original repo", no "ask the author".

**Verify:** Read the package as a stranger. Every external reference resolves
either inside the package or to a declared, publicly reachable dependency.

## 4. Predictable, intuitive, ergonomic

**Demands:** Identical layout for every schematic; template section order; a
reader can locate any fact by section, not by search. Frontmatter fields,
naming conventions (`R-<n>` requirements, `A-<n>` acceptance tests, `P-<n>`
parameters, `D-<n>` dependencies), and the module doc shape never vary.

**Verify:** Diff the section skeleton against `templates/SCHEMATIC.template.md`;
identifier prefixes used consistently everywhere.

## 5. Idempotent and deterministic

**Demands:** Implementation phases are re-runnable: safe to re-execute on an
already-partly-built host, each phase detects its own completion state where
feasible. Verification steps yield the same verdict every run. No "redo the
previous phase's edits" instructions; no steps that append or mutate
unconditionally.

**Verify:** For each phase, answer: if I ran this twice, what breaks? For each
verification, answer: could this pass and fail on the same state? Fix both.

## 6. Parameterized and modular

**Demands:** One Parameters table (in SCHEMATIC.md) lists every tunable: id,
name, type, default, discovery method (how the implementer finds the right
value on its host), effect. Modules split at real seams — each has inputs,
outputs, failure behavior, and no hidden coupling; anything a module needs
from another module appears in its contract.

**Verify:** Every literal that would differ between two deployments exists as
a `P-<n>`; every cross-module need is declared in both modules' contracts.

## 7. Dependencies called out

**Demands:** Dependencies table (`D-<n>`) covers runtime, libraries, services,
credentials, and network paths. Each entry: what it is, why needed, discovery
method (command to check presence/reachability), and failure behavior (what
the capability does when it's missing — hard fail with a clear message, or
degrade how).

**Verify:** For each `D-<n>`: run its discovery command mentally against a
bare host; the failure behavior is stated and sane.

## 8. Applicable context stated

**Demands:** The Applicable Context section separates three kinds of
knowledge: what the implementer MUST discover locally (with the discovery
method), what it MAY assume (with the risk if the assumption is wrong), and
what it MUST NOT change (host constraints). No silent assumptions anywhere in
the package.

**Verify:** For each non-universal claim in the package, it appears in one of
the three context lists.

## 9. Configuration flexibility

**Demands:** Behavior that varies between deployments is configuration, never
a code edit. The schematic names every knob, its type, default, and effect —
and the implementation phases wire them through the parameter mechanism, not
by editing source.

**Verify:** Imagine two deployments that must behave differently per the
requirements; both are achievable by parameters alone.

## 10. Pluggable

**Demands:** Clean seams: where the capability attaches to its host (entry
points, hooks, interfaces it implements or exposes), what a replacement or
removal entails, and what collateral the host suffers. Removal/uninstall is a
stated, safe procedure.

**Verify:** The package answers: how do I detach this and leave the host
working? With a procedure, not a shrug.
