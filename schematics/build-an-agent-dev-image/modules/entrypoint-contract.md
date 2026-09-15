# Module: entrypoint-contract

## Purpose

This module owns the standard entrypoint: the runtime inputs it reads, the
checks it performs before starting anything, the exact way it hands control to
the harness, and the way it refuses.

It is explicitly NOT responsible for installing a harness (that is a layer's
job — see `publishing-and-pinning.md` for the layer form), for credentials, for
a multiplexer, or for anything the harness does after `exec`.

## Inputs

Three environment variables, and the container's arguments.

| Variable | Required | Default | Validated |
|----------|----------|---------|-----------|
| `AGENT_HARNESS` | yes | none | Non-empty, must not start with `-`; resolved with `command -v`, so it is either a bare name found in `PATH` or an absolute path to an executable. |
| `AGENT_WORKSPACE_DIR` | no | `P-6` (`/workspace`) | Absolute path. Created if absent (R-5). |
| `AGENT_ID` | no | the container's hostname | `[A-Za-z0-9][A-Za-z0-9._-]*`, at most 64 characters (R-3). |

Container arguments (`docker run <image> <args…>`) are forwarded to the harness
unchanged, in order, as the harness's own arguments. There is no
argument-parsing layer and no `AGENT_HARNESS_ARGS` variable: a consumer that
needs default arguments wraps the CLI in a small script and points
`AGENT_HARNESS` at it, which keeps quoting rules out of this contract.

Error inputs it must tolerate: any of the three variables set to an invalid
value (refuse, see below), an unset `AGENT_HARNESS` (refuse), a workspace path
whose parent is not writable (refuse), a workspace mounted read-only (refuse),
and a harness name that resolves to nothing (refuse).

## Outputs

On success the process becomes the harness:

- the working directory is `AGENT_WORKSPACE_DIR`;
- `AGENT_ID` and `AGENT_WORKSPACE_DIR` are exported with their resolved values,
  so the harness and everything it spawns see the same contract that was
  validated;
- `PID 1` is the harness itself — the entrypoint uses `exec`, never a fork, so
  no supervising shell sits between the container runtime and the harness;
- signals sent to the container (including the runtime's stop signal) are
  delivered to the harness directly;
- the container's exit status is the harness's exit status, unchanged.

On refusal: a single line on stderr, prefixed `agent-entrypoint: `, naming the
variable or path at fault, and exit status **78**. Nothing is started — no
harness, no shell, no background process — and the entrypoint never exits 0
without having exec'd a harness.

## Dependencies

- `P-6` `WORKSPACE_DIR` — the baked default for `AGENT_WORKSPACE_DIR`.
- `P-3` `AGENT_USER` / `P-4` `AGENT_UID` — the identity whose writability is
  checked; see `runtime-account.md` for what the caller must prepare.
- `R-2`…`R-6` in `SCHEMATIC.md` state the same contract normatively; this
  document adds the operational detail.

No external dependency: the entrypoint is a portable shell script with no
runtime beyond the image's own shell, and it must stay that way (it is the one
file every layer depends on).

## Failure Behavior

| Condition | stderr message contains | Exit |
|-----------|------------------------|------|
| `AGENT_HARNESS` unset or empty | `AGENT_HARNESS is not set` | 78 |
| `AGENT_HARNESS` starts with `-` | `must not start with '-'` | 78 |
| `AGENT_HARNESS` not found and not executable | `is not an executable path and was not found in PATH` | 78 |
| `AGENT_WORKSPACE_DIR` not absolute | `must be an absolute path` | 78 |
| Workspace cannot be created | `cannot create workspace` | 78 |
| Workspace exists but is not writable by the account | `is not writable by uid <uid>` | 78 |
| `AGENT_ID` has characters outside the allowed set | `AGENT_ID must match` | 78 |
| `AGENT_ID` longer than 64 characters | `must be at most 64 characters` | 78 |

There is no degraded mode: every refusal is a hard stop before any process
starts. A consumer that wants "start anyway" behavior wraps the entrypoint
itself and owns the consequences.

If `exec` fails after every check passed (the binary disappeared between the
lookup and the exec), the shell's own status is what the caller sees. The
entrypoint does not mask it.

## Idempotency Notes

The entrypoint has no persistent state and no ordering hazard: the only write
it can make is creating the workspace directory, which is idempotent
(`mkdir -p`). Running it twice in one container is not a supported operation —
it is PID 1 — but restarting a container runs the same checks again with the
same verdict.

Note one deliberate asymmetry: if the workspace directory exists but is
unwritable, the entrypoint refuses rather than repairing it. Repair would mean
`chown`, which requires root, and this image has no root path by design
(`runtime-account.md`).

## Removal Notes

What this module adds to the host: one file, `/usr/local/bin/agent-entrypoint`,
inside the image (not on the host). Nothing else — no config file, no state
directory, no registration.

A layer that replaces the entrypoint takes on the whole contract; a layer that
merely wants a different harness sets `AGENT_HARNESS` and inherits everything.
Removing the entrypoint without replacing it makes the image unusable for the
run contract; that is why `publishing-and-pinning.md` states the layer form as
"add a CLI, name it, change nothing else".
