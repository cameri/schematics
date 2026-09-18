# Module: host-image

## Purpose

Builds the agent host image: the dev base image plus the multiplexer, the attach
transport, the supervision scripts and the boot program. It owns the build, the
pinned inputs, and the publishing identity of the layer. It is explicitly NOT
responsible for the runtime account, the entrypoint, the working directory or the
`AGENT_*` contract — all four are inherited from the base image and only
referenced here. It is also not responsible for what runs inside an agent: that
is the base's entrypoint plus whichever harness a harness layer installs.

## Inputs

- The base reference and its **manifest list** digest (`P-1`, `P-2`), from the
  base's publish step (`docker buildx imagetools inspect <ref> --format
  '{{.Manifest.Digest}}'`).
- The herdr version and the two release-asset SHA-256 digests (`P-3`, `P-4`,
  `P-5`), read from the release's asset list at authoring time.
- The container runtime with BuildKit (`D-5`), and a registry to publish to
  (`P-9`, `P-10`).
- The files in this package's `skeleton/`: `herdr-config.toml`,
  `herdr-plugin.toml`, `agent-loop.sh`, `reopen-pane.sh`, `agent-host-boot.sh`.

## Outputs

- One image, built `FROM ${AGENT_BASE_IMAGE}@${AGENT_BASE_DIGEST}`, carrying:
  - `openssh-server`, `openssh-client`, `jq`, `util-linux` (for `setsid`), and
    `curl` when the base has none, installed in a `USER root` section that ends
    by switching back to the inherited account;
  - `/usr/local/bin/herdr`, at the pinned version, verified against the
    publisher's per-asset SHA-256 during the build;
  - `/usr/local/share/agent-host/herdr-config.toml`,
    `/usr/local/share/agent-host/plugin/{herdr-plugin.toml,agent-loop.sh,reopen-pane.sh}`,
    `/usr/local/bin/agent-host-boot`, all root-owned and world-readable;
  - provenance labels naming the base reference, the base digest, the package
    version, the source revision and the herdr version.
- Nothing else: no `EXPOSE`, no `VOLUME`, no `HEALTHCHECK`, no `ENTRYPOINT`
  change, no `USER` change, no socket mount.
- A published reference `<P-9>/<P-10>/<P-6>:<P-7>-<P-8>`, whose digest a
  deployment pins.

## Dependencies

`D-1` (the base schematic — this layer is built from its artifact and inherits
its contract), `D-5` (Docker Engine and Compose), `D-6` (the herdr release
archive, at build time), `D-7` (the distribution's package repositories, at
build time), and the parameter ids `P-1` … `P-10`.

## Failure Behavior

| Condition | Result |
|-----------|--------|
| `AGENT_BASE_DIGEST` unset or malformed | the build fails at `FROM`, before any instruction runs |
| the herdr asset's SHA-256 does not match | the build fails at the checksum line, printing expected and observed digests, and no image is produced |
| `TARGETARCH` is neither `amd64` nor `arm64` | the build stops with `unsupported TARGETARCH`, rather than producing an image whose herdr cannot run |
| `setsid`, `sshd` or `jq` missing after the package install | the build fails on the `command -v` checks, not at run time |
| the base image already carries the files this layer installs | `COPY` overwrites them; the base's contract owns the paths it declares, and none of those overlap |

## Idempotency Notes

Every build input is pinned, so rebuilding produces the same image unless an
input was deliberately changed. The package install and the herdr download are
single `RUN` layers with no cache to invalidate wrongly; `--no-cache` is only
needed when the distribution's repositories have moved under an existing tag,
and the base's digest pin is what makes that a deliberate act rather than an
accident.

## Removal Notes

Removing the image removes the layer: `docker image rm` locally, and the
published tag from the registry. Nothing on a host depends on the image being
present once its containers are gone — the agent tree, the SSH host key and the
per-agent state all live in bind mounts, and are described in
`persistence-and-mounts.md`.
