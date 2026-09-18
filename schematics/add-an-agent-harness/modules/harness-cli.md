# Module: Harness CLI

What this layer installs, how the version is fixed, how the harness becomes the
container's process, and what the install step is forbidden to do.

## What the layer adds

One coding-agent CLI, its configuration, and the one environment variable that
makes the inherited entrypoint run it. Nothing else: no service, no daemon, no
listener, no second CLI, no package the chosen CLI does not need (R-2).

The layer does not supervise the harness, route its traffic, or hold its
credential. Those are the multiplexer's, the router's and the deployment's jobs
respectively.

## The harness is a closed parameter

`P-1 AGENT_HARNESS_ID` accepts a closed set of values. Each value is a real
implementation: a package to install, a configuration template, and a name the
entrypoint can resolve. Adding a value is a defined procedure
(`modules/extension-path.md`), not a stub branch.

The install step dispatches on the value and refuses anything else:

```
RUN case "${AGENT_HARNESS_ID}" in
      claude|codex) ;;
      *) echo "add-an-agent-harness: AGENT_HARNESS_ID '${AGENT_HARNESS_ID}' is not one of: claude codex" >&2
         exit 78 ;;
    esac
```

Three properties matter here:

- The refusal happens **at build time**, so no image exists to start without a
  harness. A layer that accepted an unknown value and failed at run time would
  produce a container that reaches the entrypoint with nothing to run.
- The message is **one line on stderr naming the value** — the reader learns what
  was rejected, not that something was.
- The exit code is the same first line of defence the base uses (`78`, the
  base's own refusal code). The prefix is this package's, so the origin of the
  refusal is unambiguous.

The default value is deliberately not set to a specific CLI: a build that names
no harness is a configuration mistake, and the case arm reports it the same way
it reports a typo.

## The version is resolved, not copied

`P-10 HARNESS_PACKAGE_VERSION` is empty by default. The build then asks the
registry what the current version is and installs exactly that:

```
npm view <package> version      # the resolved version, printed by the build
npm install --global <package>@<resolved>
```

The resolved value is then written inside the image:

```
/usr/local/share/agent-harness/version
```

so the acceptance table can read what was installed without starting the CLI, and
so an image can be inspected long after its build log is gone (R-5, row H-7).

Why this shape rather than a version in the spec:

- A version written into a document is stale the day after it is written, and
  every harness release would edit this package.
- `latest` is not a version. It resolves differently on two machines built an hour
  apart, which is the opposite of what an image is for.
- A deployment that must reproduce an older image sets `P-10` to the version that
  image recorded.

## The harness becomes the process

The base image's entrypoint resolves `AGENT_HARNESS` and `exec`s it, so the
container's process is the harness itself. The layer's whole contribution to that
chain is one line:

```
ENV AGENT_HARNESS=${AGENT_HARNESS_ID}
```

Three consequences follow, and all three are acceptance rows rather than claims:

- **PID 1 is the harness.** No shell, no wrapper, no supervisor between the
  entrypoint and the CLI, so the CLI receives the container's arguments and its
  exit status is the container's (H-3, H-5).
- **The working directory is the base's workspace.** The layer declares no
  `WORKDIR`; the harness starts where the base put it (H-1, H-5).
- **The runtime account is the base's.** The install runs as root inside a build
  layer and the image returns to the base's account before it ends; the layer adds
  no user, no group and no sudo (R-1).

The layer declares no `ENTRYPOINT` and no `CMD` (R-3). This is not a style
preference: an `ENTRYPOINT` would replace the base's, and the base's is what reads
`AGENT_HARNESS`, validates `AGENT_ID`, prepares the workspace and reports refusals
with its own code. A harness layer that took the entrypoint over would have to
reimplement all of it, and the copy would drift.

`AGENT_HARNESS` is set to the CLI's own name (`claude`, `codex`) rather than an
absolute path, so the value is portable across a base image that relocates its
binaries. Nothing in this layer needs to know where the package manager puts them.

## The runtime

Both CLIs are distributed through a Node.js package registry, so the install step
needs `node` and `npm`. The base image may already carry them; where it does not,
the step installs the distribution's `nodejs` and `npm` packages (D-6) before it
resolves the CLI version.

If the distribution cannot supply them, that is a decision about the **base
image**, not about the harness: the fix is a base that carries the runtime (D-6's
failure behaviour). Installing a runtime from a vendor's install script instead
would break R-9 — a piped install script is architecture-specific, unverified and
unpinnable.

## What the install step must not do

| Forbidden | Why |
|---|---|
| `curl … \| sh`, or any downloaded installer script | Unpinned, unverifiable, and architecture-specific; the registry path is version-resolved instead (R-5, row H-13) |
| A floating tag (`latest`, a major-version range) | The image would differ between two builds from the same source |
| Writing a credential, a token, or a login file | The image must contain none, and a credential in a layer is a credential in every container started from it (R-8, row H-10) |
| Declaring `ENTRYPOINT`, `CMD` or `WORKDIR` | They are the base's, and the layer's whole job is to sit under them (R-1, R-3) |
| Adding a second CLI "so the image is flexible" | R-2. A layer with two harnesses has two configurations, two version resolutions and two upgrade paths, and the multiplexer can still only set `AGENT_HARNESS` to one value |
| Leaving the package manager's cache in the image | Build weight with no runtime value; the install step clears it in the same layer that created it |
| Adding a healthcheck that reports on the CLI | The base declares none and the multiplexer supervises the pane; a CLI that answers `--version` says nothing about the agent (Open question Q-2) |

## Verifying the install by hand

Inside a container started from the built image:

```
command -v "${AGENT_HARNESS}"          # the entrypoint's own resolution rule
"${AGENT_HARNESS}" --version           # the CLI runs as the base's account, with no credential
cat /usr/local/share/agent-harness/version
```

The first two are rows H-3 and H-4. The third is H-7. None of them needs a
credential or a router, which is the point: whether the *model* answers is the
deployment's test, not the layer's.
