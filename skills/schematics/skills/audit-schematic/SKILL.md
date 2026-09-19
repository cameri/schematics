---
name: audit-schematic
description: Audits a schematic package (SCHEMATIC.md plus modules/, scripts/, skeleton/, templates/) against the format AND against its own claims — running every documented command and checking every stated behaviour, interface, path, and acceptance row, with findings by severity and the evidence quoted. Use when the user asks to audit, review, or check a schematic package, or to verify that a spec can be built from as written.
---

<objective>
Invokes the `schematics:schematic-auditor` subagent to audit a schematic package
at the given path: the format it declares, and the claims inside it that the
catalog validator cannot see — whether the documented commands run, whether
failures propagate, whether the documented interface is the implemented one, and
whether each acceptance row can actually fail.
</objective>

<quick_start>
`/schematics:audit-schematic <path-to-package-or-SCHEMATIC.md> [revision]`

The second argument names the revision to audit (a sha, a branch, or a pull
request head). Without it the auditor audits what is checked out and says so.
</quick_start>

<workflow>
1. Resolve the target from `$ARGUMENTS`. A directory that contains `SCHEMATIC.md`
   is the package; a path to `SCHEMATIC.md` means its directory. Resolve the
   revision too: `git -C <repo> rev-parse <ref-or-HEAD>`, and if the argument is
   a pull request, resolve its head with `gh pr view <n> --json headRefOid`.
   If no target was given, ask which package to audit — do not guess.
2. Invoke the `schematics:schematic-auditor` subagent via the `Agent` tool,
   passing the resolved package path and revision. The auditor runs the
   repository's own `scripts/validate-catalog.sh` first as its baseline and then
   audits what that validator cannot see; do not pre-run it and do not summarize
   it away.
3. Present the subagent's findings verbatim — the verdict line, every finding
   with its file:line and quoted evidence, the checked-and-clean section, and
   anything it marked `[UNVERIFIED]`. Do not paraphrase findings into a summary,
   and do not drop the unverified section: it is where a reader learns what the
   audit does not cover.
</workflow>

<delegation>
Artifacts inside the target that are not schematics stay with the plugin that
owns their standard: a `SKILL.md`, an extension module, or a subagent definition
is audited by `agent-resources`' own auditors (`skill-auditor`,
`extension-auditor`, `subagent-auditor`), and the schematic audit incorporates
their findings rather than duplicating them. That plugin's audit skills are the
model for this one: a thin dispatcher, a paired read-only auditor, severity-based
findings, and no scores.
</delegation>

<not_this>
This skill does not re-implement the catalog validator
(`scripts/validate-catalog.sh`: frontmatter, catalog agreement, referenced
paths, feature count, dependency pins, the plugin-version rule on a pull
request). It does not audit a plugin's own skill files as schematics, and it does
not edit the package it audits — findings only, unless the user asks for fixes
afterwards.
</not_this>

<success_criteria>
- The subagent was invoked with the resolved package path and revision
- The report's baseline shows the validator's own output, and no validator check
  was re-implemented in place of it
- The verdict uses this repository's vocabulary (`ready to merge` / `not ready to
  merge` with major/minor/nit counts)
- Findings are presented with their file:line locations, quoted claims, and
  evidence intact
- The checked-and-clean and unverified sections survive presentation to the user
</success_criteria>
