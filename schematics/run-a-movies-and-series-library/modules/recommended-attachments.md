# Module: recommended attachments

Where the recommended (optional) dependencies attach, and what
declining them means. Declining any of them keeps R-6 intact: every
required phase and acceptance test still passes.

## RD-1: improve-docker-security

- **Attaches at Phase 3, after the loop works.** Its three layers wrap
  the host this stack runs on; deploying it before the loop is proven
  entangles two debug surfaces.
- **What it changes here**: consumers that mounted `docker.sock` move
  to the scoped proxy; the stack's many API keys move into encrypted
  secrets (making R-3's rule mechanical instead of aspirational); any
  network-facing control of the daemon becomes OPA-policed.
- **What declining means**: the stack runs fine; socket mounts and
  plaintext keys remain an accepted risk, reviewed whenever reviewed.
- **The one integration risk**: the scoped proxy allowlist must cover
  every Docker-API call the loop's members make. If A-2 breaks after
  attaching RD-1, re-run the scoping derivation - do not widen OPA to
  compensate for an allowlist gap.

## RD-2: update-images-on-push

- **Attaches at Phase 3**, for images this stack runs that come from a
  registry you push to. Images you consume but do not build stay on
  manual/deliberate upgrades.
- **What it changes here**: pushes that rebuild your images also update
  the running deployments' images - pulls only; nothing in this stack's
  containers is recreated by the pipeline (its explicit boundary).
- **What declining means**: upgrades happen when an operator runs them.
