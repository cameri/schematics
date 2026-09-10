# Workflow: Update an Existing Schematic

<required_reading>
**Read these files NOW:**
1. `references/schematic-principles.md`
2. The schematic being updated (`SCHEMATIC.md` at minimum, plus affected modules)
</required_reading>

<process>

## Step 1: Locate and load

Find the schematic package (ask the user if the name is ambiguous; search
`docs/schematics/` or the stated root for `SCHEMATIC.md` files). Read the
frontmatter: `version`, `status`, `updated`. Read the whole `SCHEMATIC.md` plus
every module the change will touch. A schematic with `status: superseded` is
never edited — tell the user and stop.

## Step 2: Classify the change

- **New requirement or capability** → add requirement(s), acceptance test(s),
  affected module updates, implementation phase if needed. Minor version bump.
- **Changed contract or breaking reinterpretation** (interface, wire format,
  stored state, parameter semantics) → edit in place, mark the old form
  superseded (see Step 3), bump major version.
- **Clarification or correction that does not change behavior** (better
  discovery method, fixed example, clearer wording) → edit, patch version bump.
- **Implementation drift** (the implementer built it differently and the user
  ratified the difference) → update the schematic to match ratified reality;
  record the decision in the Decisions Log.

## Step 3: Apply the edit under living-spec rules

- Never delete a requirement, acceptance test, or parameter. Replace it with
  its successor and mark the old entry `superseded: by R-<n>` (kept for
  traceability with implementations built against the older revision).
- Every change adds an entry to the Changelog section: version, date, one-line
  summary, sections touched.
- Every judgment call made during the update (ambiguity resolved, tradeoff
  chosen) gets a Decisions Log entry — the next updater reads that log first.
- Parameter changes update the Parameters table AND every usage of the
  parameter elsewhere in the package — grep the whole package for the old name
  before finishing.
- If the change invalidates already-completed implementation phases, add a
  note to the affected phase stating what must be redone and how to detect
  whether it was done the old way (a check command where possible).

## Step 4: Re-audit and commit

Re-run the author workflow's self-audit (Step 4 there) on every touched file.
Commit with message `schematic: <name> v<new-version> — <one-line summary>` and
summarize the delta for the user.

</process>

<success_criteria>
This workflow is complete when:

- [ ] Change classified; version bumped per severity
- [ ] No requirement/test/parameter deleted — superseded entries retained
- [ ] Changelog and Decisions Log updated
- [ ] All usages of renamed/changed parameters updated across the whole package
- [ ] Re-audit passes; committed; delta summarized to the user
</success_criteria>
