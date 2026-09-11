---
name: create-schematic
description: Creates decentralized capability schematics — published, self-contained build specification packages (SCHEMATIC.md plus modules, scripts, skeleton, templates) that remove the author from the loop entirely: any builder — any LLM, any human team, any organization — can construct the capability independently, with zero coordination with the author; the spec is the only coordination mechanism. Also reverse-engineers schematics from existing implementations and updates schematics as living specs. Use when the user wants to publish a schematic for a feature or capability, capture how something is built so anyone can rebuild it independently, or update an existing schematic.
---

<essential_principles>

**A schematic is a contract, not a conversation.** A schematic is published,
not handed off: once written, it enables any builder — any LLM, any human team,
any organization — to construct the capability independently, with zero
coordination with the author. The spec is the only coordination mechanism. The
builder has none of this session's context — no memory of the interview, no
tools this session used, no access to this machine unless the schematic
explicitly packages what it needs. Every requirement, assumption, parameter,
and verification must live inside the schematic package itself.

**The ten binding principles.** Each is an acceptance criterion the finished
schematic must satisfy, not a style preference:

1. **Vendor-agnostic** — plain Markdown and portable shell only. No references to
   any specific agent's tools, skill formats, or harness features. The reader may
   be any LLM in any runtime.
2. **Portable** — no absolute paths, no machine-specific facts baked in. Anything
   environment-specific becomes a named parameter with a discovery method.
3. **Self-contained** — the package carries everything: the spec, module docs,
   reference scripts, starter files. The implementer needs nothing else.
4. **Predictable, intuitive, ergonomic** — the layout is always the same, sections
   appear in the same order, a reader can find any fact without hunting. Follow
   the template exactly.
5. **Idempotent and deterministic** — implementation steps are re-runnable without
   damage; verification steps produce the same result on every run; the spec never
   depends on "do it like last time".
6. **Parameterized and modular** — every environment-specific value is a parameter
   in one table; every separable concern is a module with an explicit contract;
   behavior differences between deployments are configuration, never code edits.
7. **Dependencies called out** — every external dependency (runtime, library,
   service, credential, network path) is declared with its purpose, a discovery
   method, and a fallback or failure behavior.
8. **Composable in kind** - a dependency may be another schematic (Kind
   `schematic` in the Dependencies table), pinned to a specific commit in
   the remote repository with the SHA-256 of the linked file's contents at
   that commit; never a floating ref. A composition schematic owns no
   images or services: only the shared contracts, the isolation rules
   between the parts, and the end-to-end acceptance test. Optional
   dependencies live in a separate Recommended table, pinned the same
   way, with the no-recommended-deps behavior stated per row.
9. **Applicable context stated** — what the implementer must know about the target
   environment, and explicitly what it must discover locally versus what it may
   assume.
10. **Pluggable** — the capability defines clean seams: where it attaches to its
    host, what interfaces it exposes, and how to remove or replace it without
    collateral damage.

**Copy the template, never invent structure.** `templates/SCHEMATIC.template.md`
is the canonical section order. Fill every section; delete a section only when it
genuinely does not apply (never leave stubs like "TBD" or "N/A" prose).

**Write for a stranger.** Address the reader as "the implementer". Assume zero
shared vocabulary beyond universal engineering knowledge. See
`references/llm-agnostic-authoring.md` before writing any schematic content.

</essential_principles>

<intake>
What would you like to do?

1. Author a new schematic (interview-driven, from an idea or requirement)
2. Reverse-engineer a schematic from an existing implementation (code, config, or running service)
3. Update an existing schematic (living spec)
4. Something else

**Wait for response before proceeding.**
</intake>

<intent_routing>
| Response | Workflow |
|----------|----------|
| 1, "create", "author", "new schematic", "schematic X" | `workflows/author-schematic.md` |
| 2, "reverse-engineer", "from this code/repo/service", "document how X works so it can be rebuilt" | `workflows/reverse-engineer-schematic.md` |
| 3, "update", "change", "revise schematic", "add requirement to schematic" | `workflows/update-schematic.md` |
| 4, other | Clarify intent, then select |

**After reading the workflow, follow it exactly.**
</intent_routing>

<reference_index>
All domain knowledge in `references/`:

**Principles:** schematic-principles.md — the ten principles, each with what it
demands of the artifact and how to verify it in the finished schematic.

**Authoring rules:** llm-agnostic-authoring.md — how to write content an
unknown-architecture LLM can execute: parameter tables, discovery methods,
universal verification, banned constructs.
</reference_index>

<workflows_index>
| Workflow | Purpose |
|----------|---------|
| author-schematic.md | Interview the user, design the package, emit a new schematic |
| reverse-engineer-schematic.md | Study an existing implementation and distill it into a schematic |
| update-schematic.md | Apply changes to an existing schematic as a living spec (version, changelog, supersede rules) |
</workflows_index>
