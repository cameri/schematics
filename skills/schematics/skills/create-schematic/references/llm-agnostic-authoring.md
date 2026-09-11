# LLM-Agnostic Authoring Rules

How to write schematic content an unknown-architecture LLM can execute. These
rules apply to every file in the package.

## Address the implementer

Second person or imperative, aimed at a competent engineer with shell access
and no other context: "Create the file...", "Verify that...". Never "I would...",
never "we discussed", never "the assistant".

## Ban conversation references

No content may depend on the authoring session: no "as you suggested", no
unresolved pronouns about prior discussion, no "same as usual". If a fact
matters, it is written in the package.

## Ban vendor constructs

- No agent tool names or tool-calling syntax.
- No skill/plugin/harness frontmatter or directory conventions from any agent.
- No "use your built-in X" — either the step is expressible in plain terms
  (read a file, run a command, make an HTTP request) or it is not a step.
- Markdown formatting only: headings, lists, fenced code blocks with language
  tags. No vendor-specific directives inside code fences.

## Parameters over literals

Every value that could differ between deployments is a parameter:

```markdown
| Id   | Name          | Type   | Default | Discovery                          | Effect                        |
|------|---------------|--------|---------|------------------------------------|-------------------------------|
| P-1  | LISTEN_PORT   | int    | 8080    | `ss -tlnp` — first free port ≥8080 | Port the service binds        |
```

In prose and code, refer to parameters by name (`LISTEN_PORT`), with example
values only where a concrete value aids comprehension — and mark it as an
example default from the table.

## Discovery over assumption

When the schematic needs a host fact (installed runtime, free port, existing
user, config location), give the discovery method, not just the expected
answer:

```markdown
Determine the Python version with `python3 --version`. Require ≥3.11; if
older, install per your platform's package manager before Phase 1.
```

## Verification in universal terms

Express checks as shell commands where possible; otherwise as behavioral
checks precise enough that two different implementers would reach the same
verdict:

```markdown
A-3: After Phase 2, `curl -fsS "http://127.0.0.1:${LISTEN_PORT}/healthz"`
exits 0 and the body parses as JSON containing `"status":"ok"`.
```

Never "it should work", never screenshots or GUI-only checks without a
programmatic alternative.

## Idempotent step phrasing

Write phases so re-running is safe, and say how completion is detected:

```markdown
Phase 2: Create the config file.
Skip if `${CONFIG_PATH}` already exists and contains a `[service]` section.
Otherwise create it from skeleton/config.example, then fill P-1 and P-3.
Verify: `grep -q '^\[service\]' "${CONFIG_PATH}"` exits 0.
```

## Module contracts

Every module doc states, in this order: purpose (one paragraph), inputs,
outputs, dependencies (ids from the main tables), failure behavior (what it
does when inputs are bad or a dependency is down), and idempotency notes.
Anything a module needs from a sibling module appears in both contracts — no
implicit coupling.

## Honest uncertainty

If the schematic is a reconstruction (reverse-engineered), inferred content
carries an `inferred:` note and unconfirmed inference lands in Open Questions
— the implementer must never mistake reconstruction for record. If something
is genuinely undecidable from the package, it is an Open Question with a
default the implementer may take unless the author answers it.
