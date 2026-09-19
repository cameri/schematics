# schematics

Creates **capability schematics** — published, self-contained, vendor-agnostic
build specifications that remove the author from the loop entirely. Once
published, any builder — any LLM with any architecture, any human team, any
organization — can construct the capability independently, with zero
coordination with the author. The spec is the only coordination mechanism. A
schematic carries everything the builder needs: the spec (`SCHEMATIC.md`),
per-component contracts (`modules/`), runnable reference implementations
(`scripts/`), starter files (`skeleton/`), and output shapes (`templates/`).
No access to the author, the authoring conversation, or any central registry
is required.

Schematics are **living specs**: versioned, changelogged, with requirements
and parameters superseded (never deleted) so implementations built against
older revisions stay traceable.

## Skills

| Skill | Description |
|---|---|
| `schematics:create-schematic` | Author a new schematic (interview-driven), reverse-engineer one from an existing implementation, or update an existing schematic as a living spec |
| `schematics:build-schematic` | Build a schematic package from any public GitHub repo: resolve it through that repo's `.agent-schematics/marketplace.json` catalog or conventional paths, download the spec plus its modules, scripts, and skeleton, validate the spec, and report what was found |
| `schematics:audit-schematic` | Audit a package against the format and against its own claims — documented commands actually run, failures propagate, documented interfaces are the implemented ones, acceptance rows can fail — with findings by severity and quoted evidence |

`audit-schematic` dispatches to the `schematics:schematic-auditor` agent that
ships with this plugin, a read-only auditor that runs the package's commands
against a throwaway copy. Where the audit target contains an artifact that is not
a schematic — a `SKILL.md`, an extension module, a subagent definition — it
defers to `agent-resources`' own auditors rather than duplicating their
standards.

## Schematic package layout

```
<schematics-root>/<schematic-name>/
├── SCHEMATIC.md          # root living spec (always present)
├── modules/<name>.md     # one per separable component with a contract
├── scripts/              # portable reference implementations
├── skeleton/             # starter files to copy verbatim and fill
└── templates/            # output structures the capability produces
```

Default `<schematics-root>` is `docs/schematics/` under the workspace/repo
root where that convention exists; otherwise `./schematics/`. Always
confirmable per invocation.

## The ten binding principles

Every schematic is audited against: vendor-agnostic, portable, self-contained,
predictable/intuitive/ergonomic, idempotent and deterministic, parameterized
and modular, dependencies called out, applicable context stated,
configuration flexibility, and pluggable. See
`skills/create-schematic/references/schematic-principles.md`.

## Install

```
/plugin marketplace add cameri/schematics
/plugin install schematics@cameri-schematics
```
