# Contributing to Agentic Schematics

Thanks for wanting to contribute a schematic. Read this before opening
anything.

## Rule zero: no PRs without an issue

**Every pull request must reference an open issue that was opened first,
by you, describing what you want to contribute.**

PRs opened by outside contributors without a prior issue are rejected
automatically, and the rejection will cite this rule. There are no
exceptions, including for small fixes.

Why this rule exists: a schematic is a build specification that others
implement independently. Before anyone spends effort on a PR, the idea
itself needs a public discussion. The issue is that discussion. It
establishes:

- what capability the schematic covers and why it is worth publishing
- whether something similar already exists (see the catalog first)
- the intended audience and runtime assumptions
- agreement on scope before a full spec is written

## How to contribute a schematic

1. **Open an issue first.** Title it `schematic: <capability name>`.
   Describe the capability, what problem it solves, and roughly what the
   implementation phases look like. Wait for feedback and reach rough
   agreement.

2. **Write the schematic.** After the issue converges, write
   `<name>/SCHEMATIC.md` following the format in
   [`skills/schematics/skills/create-schematic/SKILL.md`](skills/schematics/skills/create-schematic/SKILL.md).
   The `schematics` plugin's `create-schematic` skill walks any agent
   through the whole format, including the reverse-engineering workflow
   for distilling a spec from a working implementation.

3. **Register it in the catalog.** Add an entry for your package to
   `.agent-schematics/marketplace.json`, matching the existing entries.

4. **Open a PR that references the issue.** The PR body must link the
   issue (`Closes #N` or a plain reference). PRs without a referenced
   issue are rejected automatically per rule zero.

## What a schematic must satisfy

The ten binding principles in
[`README.md`](README.md#the-spec) are requirements, not suggestions.
The most commonly violated ones:

- **Self-contained:** the package is the complete world. No "see the
  original repo", no "ask the author", no facts that live only in your
  head.
- **Vendor-agnostic:** plain Markdown and portable shell. No agent tool
  names, no harness features, no skill formats.
- **Idempotent:** every phase is safe to re-run and verification gives
  the same verdict every time.
- **Parameterized:** every environment-specific value is a named
  parameter with a discovery method. Host-specific values appear only as
  parameterized defaults; secrets, tokens, and credentials never appear
  at all.
- **Self-describing files:** uncommon file types ship with their own
  `.schema` companion (see the spec section of the README).

## Other contributions

Fixes to the spec itself, the site, or the `create-schematic` skill
follow the same rule: issue first, then a PR referencing the issue.

## Licensing

By contributing, you agree that your contributions are licensed under
the [MIT license](LICENSE) that covers this repository.
