<div align="center">

# ⚡ Agentic Schematics

### Publish a schematic. Anyone builds it. No coordination.

**[schemaformat.ai](https://schemaformat.ai)** · [The Spec](#the-spec) · [The Catalog](#the-catalog) · [Author a Schematic](#author-a-schematic)

</div>

---

<p align="center">
  <em>"Publish the spec, and the network builds itself."</em><br>
  Inspired by the shared schematics of Daniel Suarez's <em>Daemon</em> — where the
  Darknet spread through build specifications that independent teams executed
  without permission, coordination, or contact with the author.
</p>

An **agentic schematic** is a self-contained build specification package —
every requirement, parameter, dependency, implementation phase, and acceptance
test for one capability, in plain Markdown and portable shell. The author
publishes once; any builder — any LLM, any human team, any organization —
constructs the capability independently, in any runtime, without ever
consulting them.

**The spec is the only coordination mechanism.**

| · | |
|---|---|
| **10** | binding principles |
| **1** | file to copy (`SCHEMATIC.md`) |
| **0** | coordination, context, or conversation required |

## Why schematics?

Traditional spec handoffs fail in one of two directions:

- **A conversation.** "Let me walk you through the setup" — the knowledge lives
  in people and calls. It doesn't transfer, doesn't scale, doesn't survive.
- **A document that isn't self-contained.** "See the original repo", "ask the
  author about the TLS setup", "this assumes the staging server" — every hidden
  dependency is a coordination round-trip with the author.

A schematic refuses both. It is a **contract, not a conversation**:

- **Self-contained** — every requirement, assumption, parameter, and
  verification lives inside the package. If a fact matters, it's in the
  package — or it doesn't exist.
- **Vendor-agnostic** — plain Markdown and portable shell. No references to
  any specific agent's tools, skill formats, or harness features. The reader
  may be any LLM in any runtime — or a human team on another continent.
- **Idempotent** — every implementation phase re-runs without damage;
  verification produces the same verdict every time.
- **Parameterized** — no absolute paths, no machine-specific facts. Every
  environment-specific value is a named parameter with a discovery method.

The schematic removes the author from the loop entirely. That is the point.

## The spec

Every schematic follows the same layout, `SCHEMATIC.md` at the root of a
package directory:

```
<schematic-name>/
├── SCHEMATIC.md          # the spec: requirements → acceptance (always)
├── SCHEMATIC.md.schema   # format companion, for LLMs new to the format
├── modules/              # one contract doc per separable component
├── scripts/              # reference implementations (setup, verification)
├── skeleton/             # starter files to copy verbatim, then fill
└── templates/            # output structures the capability produces
```

Inside `SCHEMATIC.md`, sections appear in a fixed order:

```
---
name: my-schematic
version: 0.1.0
status: draft
description: One-line summary copied to the marketplace
---

# Schematic: <Capability>

## Applicable Context     → must discover locally / may assume / must not change
## Requirements           → R-1, R-2, … every one testable
## Dependencies           → D-1, D-2, … every one with failure behavior
## Parameters             → P-1, P-2, … every one with a discovery method
## Modules                → one explicit contract per module
## Implementation         → ordered, idempotent phases, each verified
## Acceptance             → A-1, A-2, … one per requirement
## Removal                → stated, safe uninstall procedure
```

Uncommon file formats ship with a `.schema` companion that documents the
format — an `agent.rego` ships with an `agent.rego.schema`, so an implementer
with zero prior knowledge of Rego can still work with the file. The
convention: every `<name>.<ext>` gets a `<name>.<ext>.schema` alongside it.

The **ten binding principles** — each an acceptance criterion, not a style
preference:

1. **Vendor-agnostic** — no agent-specific tools or formats
2. **Portable** — no absolute paths or machine-specific literals
3. **Self-contained** — the package is the complete world
4. **Predictable, intuitive, ergonomic** — identical layout, same section order
5. **Idempotent and deterministic** — re-runnable without damage
6. **Parameterized and modular** — every tunable in one table, every concern a module
7. **Dependencies called out** — with discovery and failure behavior
8. **Applicable context stated** — discover vs assume vs don't-change
9. **Configuration flexibility** — behavior is config, never code edits
10. **Pluggable** — clean seams and a stated removal procedure

Full details: [`schematics/skills/create-schematic/references/schematic-principles.md`](schematics/skills/create-schematic/references/schematic-principles.md).

## The catalog

The `.agent-schematics/marketplace.json` file lists every package in this
repository and doubles as a Claude Code / omp plugin marketplace. The website
at [schemaformat.ai](https://schemaformat.ai) renders it live with one-click
copy-as-Markdown for each entry.

This repository holds **plugins**. Every plugin carries a schematic — the
build specification for the capability it provides:

### Plugins in this repo

| Plugin | Kind | What it provides |
|--------|------|------------------|
| [`schematics`](schematics/README.md) | authoring | The `create-schematic` skill: author, reverse-engineer, and maintain schematics |
| [`opa-docker-authz`](opa-docker-authz/SCHEMATIC.md) | infrastructure | The capability itself — plus the schematic (`opa-docker-authz/SCHEMATIC.md`) that documents how to rebuild it anywhere |
| [`sops-env-secrets`](sops-env-secrets/SCHEMATIC.md) | infrastructure | A spec-only schematic: SOPS + age encrypted secrets injected into a container's process environment at boot, with per-service keys and rotation without rebuilds |

### Install

```
/plugin marketplace add cameri/schematics
/plugin install schematics@cameri-schematics
```

### Use a schematic directly

A schematic doesn't need to be installed — it's a spec, not a program. Hand
`SCHEMATIC.md` (plus referenced files) to any agent session, or copy it from
the website with one click. The agent implements the phases and verifies
against the acceptance tests. No interview, no plugin required.

## Author a schematic

The **`schematics`** plugin authors new schematics (interview-driven),
reverse-engineers them from existing implementations, and maintains them as
living specs. Install it, then ask any agent to "create a schematic" or
"schematize this repo":

```
/plugin marketplace add cameri/schematics
/plugin install schematics@cameri-schematics
```

Or read the skill directly:
[`schematics/skills/create-schematic/SKILL.md`](schematics/skills/create-schematic/SKILL.md).

To publish a schematic here: create `<name>/SCHEMATIC.md`, add an entry to
`.agent-schematics/marketplace.json`, and open a PR.

## Contributing

Schematics are contributions. A schematic is a capability others can build
independently — if you've built something an agent or a team should be able to
reproduce from a spec, distill it and open a PR. The
`schematics` plugin's reverse-engineering workflow does the distilling.

## License

[MIT](LICENSE) © 2026 cameri

---

<p align="center">
  <sub>made for builders who never met the author</sub>
</p>
