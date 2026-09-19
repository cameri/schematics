# Module: Extension Path

How another coding-agent CLI becomes a harness this layer can install. Module
files, the install arm, the configuration template, the acceptance rows — the
whole list, in the order that keeps the package consistent (R-11).

Adding a harness is not a code change to this package's structure; it is one more
value of a closed set, with everything that value implies written down.

## What a candidate harness must have

Before writing anything, check the CLI against these. A candidate that fails one
is a different design decision, not a checklist item.

| Needs | Why |
|---|---|
| An install path that resolves a version | The layer pins what it installs (R-5). A package registry that answers `npm view <package> version`, or an equivalent with a version query, is the shape this package already implements |
| A configuration file in a documented shape, with a config root the deployment can redirect | The layer writes the CLI's own file, and a deployment must be able to keep session state on a mount (`P-9`) |
| A way to set the endpoint, the credential *by name*, and the model id | That is the router's wire contract (R-6). A CLI that can only take a literal credential cannot satisfy R-8 |
| A CLI name resolvable from `PATH` | `AGENT_HARNESS` holds a name, and the base's entrypoint resolves it with `command -v` (R-3) |
| A non-interactive invocation that exits on its own | The acceptance rows need one command that returns: a version flag is enough, a headless mode is better (H-4) |

## The procedure

1. **Spec: the parameter.** Add the value to `P-1`'s enum in `SCHEMATIC.md`, and to
   the refusal message in `modules/harness-cli.md` so the message names the set
   the build actually accepts. Update R-2's wording only if the CLI brings a
   second process with it, which would be a different package.
2. **Skeleton: the install arm.** Add a `case` arm in `skeleton/Containerfile`
   giving the harness four things: the package name, the CLI name, the template
   file, and the file name it becomes in `P-9`. Nothing else in the build step
   varies per harness — the version resolution, the record files, the
   substitution, the placeholder check and the build-time `--version` are shared.
3. **Skeleton: the configuration template.** Add `skeleton/<cli>-config.<ext>`
   with `@PARAMETER@` placeholders for exactly the values that vary, and its
   `.schema` companion next to it. The companion names every key, the parameter it
   comes from, and what must not appear in the file. Then confirm the build's
   substitution covers every placeholder: the placeholder check fails the build on
   one left behind, and a `sed` expression that misses one is how that happens.
4. **Spec: the acceptance row.** Add the harness's configuration checks to the
   body half of `scripts/verify-harness-layer.sh` — the branch that parses the
   file and asserts its shape — and the row(s) to the Acceptance section. A
   harness whose file format the script cannot parse is a `SKIP` with that reason,
   never a `PASS` by omission.
5. **Module: the wiring.** Add the CLI's own file shape to
   `modules/router-wiring.md`: which key carries the endpoint, which carries the
   credential variable, which carries the model and each secondary role, and which
   metadata fields it has.
6. **Parameters: the metadata.** Update the metadata table in
   `modules/router-wiring.md`: a CLI with no context-window field, or no
   maximum-output field, gets that stated as a gap (`P-8`'s precedent) rather than
   a plausible key that the CLI would ignore.
7. **Catalogue: the description.** Only if the *package's* description changes —
   adding a value to the enum usually does not. If it does, the frontmatter
   `description` and the `.agent-schematics/marketplace.json` entry must say the
   same thing, and the validator enforces that.
8. **Run it.** `scripts/verify-harness-layer.sh` with `HARNESS=<new value>`:

   ```
   HARNESS=<new> BASE_IMAGE=<a locally present image> \
     BASE_PACKAGE_DIR=<the base package> sh scripts/verify-harness-layer.sh
   ```

   Both halves run for the new value; `EXPECTED_MIN_ROWS` must be raised if the
   new arm prints fewer rows than the floor in force, or the floor stops meaning
   anything.

## What the new value inherits, for free and by construction

Everything the other values get: the refusal for an unknown value, the
version-recorded install, the three record files, the placeholder check, the
build-time `--version`, the `AGENT_HARNESS` assignment, the config root, the
credential search and the entrypoint rows. If adding a value requires changing any
of those, the change does not belong in an arm — it belongs in the shared step,
where every value keeps it.

## The values this version deliberately does not carry

`omp`, OpenCode and Cursor CLI are named non-goals of this version. Each is
reachable by the procedure above; none is a stub branch here, because a branch
that installs nothing is worse than an absent value — it makes the enum look
wider than the package is, and the failure moves from the build (where an unknown
value is refused out loud) to the container, where the entrypoint refuses a
harness that does not exist and the operator has to work out why.

A candidate whose configuration the CLI owns and does not document — a CLI that
only offers an interactive login and stores an opaque blob — cannot satisfy R-6
or R-8. That is a defect in the candidate for this design, and the honest answer
is to say so in the deployment's notes, not to write a template that pretends the
file is understood.
