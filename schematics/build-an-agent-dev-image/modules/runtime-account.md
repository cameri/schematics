# Module: runtime-account

## Purpose

This module owns the account the agent runs as: its name, ids, home, which
paths it may write, and — the part that is easy to get wrong — the parity
between those ids and the ownership of whatever the caller mounts into the
container.

It is explicitly NOT responsible for authorizing what the account may do on the
host network or against a daemon; it defines what the account *is*, and the
line the image does not cross on its own.

## Inputs

- `P-3` `AGENT_USER` (default `user`) — the account name. It appears in three
  contract surfaces: `Config.User`, the home directory, and the workspace's
  owner. Consumers key on the *uid*, not the name; the name is for humans.
- `P-4` `AGENT_UID` (default `1000`) and `P-5` `AGENT_GID` (default `1000`).
- The caller's environment, at run time: the numeric owner of every directory
  mounted into the container.

Error inputs it must tolerate: a base image that already uses the requested
uid or gid (hard build failure, never a silent remap); a mounted directory
owned by another uid (not a build-time problem — see Failure Behavior).

## Outputs

Inside the image:

- an account `P-3` with uid `P-4`, gid `P-5`, home `/home/<P-3>`, shell
  `/bin/bash`, password locked — no password login, no interactive login path;
- home directory contents: the distribution's account skeleton
  (`.bashrc`, `.profile`, `.bash_logout`) plus an empty `.local/bin`;
- `P-6` (`/workspace` by default), existing, owned by `P-4`:`P-5`, mode 0755;
- `PATH` with `/home/<P-3>/.local/bin` first, so a CLI a consumer installs into
  the account's own directory is found by the entrypoint's `lookup` without
  editing `PATH`.

Absent, deliberately: `sudo`, any setuid helper added by this image, membership
in any group other than the account's own, and any credential file of any kind.

## Dependencies

- `P-3`, `P-4`, `P-5`, `P-6` in the main parameter table.
- `R-1` (the account exists and is never root) and `R-9` (nothing secret is in
  the image) in `SCHEMATIC.md`.
- `D-1` — the container runtime, which is what actually enforces the identity.

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| The base image already has uid `P-4` or gid `P-5` | The build fails with a message naming the ids. Do not pick different ids to make the build pass — pick ids that match the caller's bind mounts, or a different distribution base. |
| A mounted directory is owned by a uid other than `P-4` | The container starts, and then fails where the agent first writes: the entrypoint refuses when the workspace is not writable, and the harness fails on its own paths. Fix ownership — `chown -R` the mounted directory to `P-4` on the host, or re-derive `P-4` from the host's owner and rebuild. |
| A mounted file is mode 0600 and owned by another uid | Same shape: not a build problem, a parity problem. |
| A consumer tries to elevate inside the container | There is no path: no `sudo`, no setuid helper from this image, no privileged group. Elevation would require the caller to pass `--privileged`, `--user 0`, or a capability — a caller's decision, visible in the run command, not a property of the image. |

The account is never root, in any phase: at build time the image *creates* the
account as root (unavoidable — that is what image builds do), and every runtime
instruction after that point is `USER P-3`. A layer that needs root to install
its CLI switches to root inside its own build stage and switches back, which is
a build-time detail that leaves no runtime capability behind.

## Idempotency Notes

Account creation is a build step, so it re-runs from a clean base image every
time; there is no partial state to detect. The one re-run-sensitive operation
is `mkdir -p` of the workspace, which is safe, and the `chown` that follows it,
which is also safe.

The parity check at run time is read-only and gives the same verdict every
time: mount the same directory, get the same answer.

## Removal Notes

What this module adds to the host: nothing. The account lives inside the image,
never on the host, and no host user is created, modified, or added to a group.

When the image is removed, the account goes with it. On a host where a
workspace directory was `chown`ed to `P-4` for parity, the directory keeps that
ownership after the image is gone — record it, because a numeric uid with no
account behind it is the kind of residue that confuses the next operator.
Nothing else needs restoring.
