# Workflow: Reverse-Engineer a Schematic

<required_reading>
**Read these files NOW before writing anything:**
1. `references/schematic-principles.md`
2. `references/llm-agnostic-authoring.md`
3. `templates/SCHEMATIC.template.md`
4. `templates/module.template.md`
</required_reading>

<process>

## Step 1: Identify the subject and access path

Establish what is being captured (a codebase, a config stack, a running service,
a workflow) and what evidence is reachable: source files, config files, API
responses, logs, running processes. Confirm scope with the user: whole system or
one capability within it.

## Step 2: Study the implementation

Read the evidence until you can answer, from the artifact itself:

- What observable behavior does it produce? (This becomes the Requirements —
  derived from what the code/config *does*, not what its names suggest.)
- What are the seams: inputs, outputs, interfaces, stored state?
- What external things does it depend on, and how are credentials/endpoints
  discovered at runtime?
- What is hard-coded that should have been a parameter? Record each as a
  parameter with its observed default.
- What behavior is idempotent versus order-sensitive? Record re-run safety
  honestly, including where it is NOT safe.

For running services, prefer observed runtime behavior (endpoints, state,
logs) over reading source, and cross-check the two where both exist.

## Step 3: Interview for intent only

Ask the user only what the evidence cannot show: why decisions were made, which
behaviors are intentional versus accidental, what may be dropped in a rebuild,
what the rebuild must preserve exactly. Do not re-ask what Step 2 answered.

## Step 4: Emit the schematic

Fill `templates/SCHEMATIC.template.md` as in the author workflow, with these
reverse-engineering specifics:

- Requirements are derived from observed behavior; cite the evidence source
  (file, endpoint, log line) for each non-obvious requirement.
- Anything you inferred rather than observed is marked explicitly in the
  schematic (an `inferred:` note) — the implementer must know which parts are
  reconstruction, not record.
- Include a **Preservation List** in Scope: behaviors that MUST match the
  original byte-for-byte or protocol-exactly (data formats, wire messages,
  stored state), separated from behaviors open to reinterpretation.
- Reference scripts go in `scripts/` only when they are portable (no embedded
  hostnames, keys, or absolute paths); sanitize everything you copy.

## Step 5: Self-audit, write, commit, hand off

Run the same mandatory audit as the author workflow (Step 4 there), with two
extra checks:

- [ ] No secrets, tokens, internal hostnames, or real user data copied from the
      implementation into the package — parameters only.
- [ ] Every `inferred:` claim is either confirmed by the user in Step 3 or
      flagged as unverified in Open Questions.

Write to the confirmed destination (default `docs/schematics/<name>/` where the
convention exists), commit if version-controlled, and deliver the handoff note.

</process>

<success_criteria>
This workflow is complete when:

- [ ] Requirements, dependencies, and parameters are derived from observed evidence, each traceable to its source
- [ ] Inferred content is explicitly marked and either confirmed or flagged unverified
- [ ] The Preservation List separates must-match behaviors from open ones
- [ ] No secrets or host-specific values leaked into the package
- [ ] The Step 5 audit passes; package written, committed (if applicable), handed off
</success_criteria>
