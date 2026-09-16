# Module: publishing-and-pinning

## Purpose

This module owns the artifact's identity after the build: how it is tagged,
how both architectures are published as one image, how a digest is recorded,
and how every consumer pins the base it was built against.

It is explicitly NOT responsible for what goes into the image
(`base-image.md`), for the account inside it (`runtime-account.md`), or for the
deployment that runs it.

## Inputs

- `P-7` `IMAGE_REGISTRY`, `P-8` `IMAGE_NAMESPACE`, `P-9` `IMAGE_NAME` — the
  published reference `P-7/P-8/P-9`.
- `P-10` `IMAGE_VERSION` (semantic version of the package) and `P-11`
  `GIT_COMMIT` (short commit of the source that produced the image).
- `P-12` `PLATFORMS` — the platforms published as one manifest.
- `P-13` `BUILDER_NAME` — the buildx builder used for a multi-platform build
  (a `docker-container`-driver builder, because the default Docker driver
  cannot produce a manifest for a platform it cannot run).
- Registry credentials, held by the caller. This package never stores, names,
  or transports a credential (R-9 applies to the build context too).

Error inputs it must tolerate: not being logged in to the registry (publish
fails, the local image stays usable), a builder that is not multi-platform
capable (publish fails with the builder's own message), and a push that is
interrupted (retry the same command — layers already present are reused).

## Outputs

- A published reference `P-7/P-8/P-9` carrying, at minimum:
  - tag `P-10-P-11` (the immutable, human-readable identity: version plus the
    commit that produced it);
  - a one-line manifest list covering every platform in `P-12`;
  - one digest per platform, and one digest for the list.
- A local image with the same configuration, for a single-platform build.
- The values a consumer needs to pin: the **manifest list digest** and, for the
  record, each platform digest printed by the inspection command below.

Nothing else is produced: no deployment, no service, no config file.

## Dependencies

- `D-1` — a Docker Engine with Buildx, which produces and pushes the manifest.
- `D-3` — a container registry the implementer is authorized to push to.
- `D-4` — the means to build and verify the second platform without emulation
  (see Failure Behavior).

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| Not authenticated to `P-7` | The push fails, the build is unaffected, and Phases 1–3 still verify. Publishing is required before any *layer* can pin the base — not before the base can be tested. |
| The builder cannot build a platform in `P-12` | The build fails for that platform. Do not "fix" it by dropping a platform from the list while the spec still claims two: either publish both or state the gap (Q-1 records the default). |
| No arm64 machine or CI runner is available | Publish amd64 and state the arm64 gap honestly; a QEMU-emulated build is not evidence (see below). |
| A consumer pins the per-platform digest instead of the manifest list digest | Their build succeeds only for that platform and fails for the other with a "no matching manifest" error. Re-pin with the list digest. |
| A published version is deleted while a layer pins it | Every rebuild of that layer, and every fresh pull of its image, fails on the base. Published versions are immutable in practice, not just in intention. |

**On emulation, stated once and binding:** the second platform's leg is verified
by building and running it on real hardware of that architecture, or by a CI
service whose builder pool runs that architecture natively. Emulated builds
(QEMU) are slow enough that nobody runs them routinely and quiet enough that
they hide architecture-specific breakage; an emulated build that passes is not
recorded as a verified platform. Record the verification basis next to the
digest (`native arm64 runner`, `emulated — not verified`, …).

## Idempotency Notes

- Re-running the publish with identical inputs re-pushes the same layers and
  the same digest; tags may be re-pointed, digests cannot. Publishing a rebuilt
  image under the same `P-10-P-11` tag replaces the tag but leaves any digest a
  consumer pinned untouched — which is the reason every consumer pins a digest
  and not the tag.
- The digest of a given build is stable; the digest of "rebuild the same
  commit tomorrow" is not, because the distribution repositories may have moved
  (see `base-image.md`).
- Completion is detected by the inspection command: it prints the list digest
  and one digest per platform. Record all of them.

Publish, then inspect:

```
docker buildx build \
  --builder "$BUILDER_NAME" \
  --platform "$PLATFORMS" \
  --build-arg BASE_DISTRO_DIGEST="$BASE_DISTRO_DIGEST" \
  --build-arg IMAGE_VERSION="$IMAGE_VERSION" \
  --build-arg GIT_COMMIT="$GIT_COMMIT" \
  --build-arg IMAGE_SOURCE="$IMAGE_SOURCE" \
  -f Containerfile \
  -t "$IMAGE_REGISTRY/$IMAGE_NAMESPACE/$IMAGE_NAME:$IMAGE_VERSION-$GIT_COMMIT" \
  --push .

docker buildx imagetools inspect "$IMAGE_REGISTRY/$IMAGE_NAMESPACE/$IMAGE_NAME:$IMAGE_VERSION-$GIT_COMMIT"
```

The inspection output's top-level `Digest:` is the **manifest list digest** —
the value a consumer pins. The per-platform entries underneath it are recorded
for the audit trail, not pinned by consumers.

## Removal Notes

What this module adds to the host: nothing. It adds a published artifact to a
registry, and the registry keeps it until the registry's own retention policy
or an operator deletes it.

Deleting a published version is a breaking change for every layer that pins it
by digest, because a digest cannot be re-pushed anywhere else: the same bytes
would have to be rebuilt. Before deleting, find the consumers (search the
catalogue for the digest) and re-pin them to a newer base. A tag can be
re-pointed freely; a digest that consumers reference should be treated as
append-only.
