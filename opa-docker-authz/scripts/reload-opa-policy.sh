#!/usr/bin/env bash
# ─── Reload OPA policy without restarting Docker daemon ─────────
#
# Run this on the HOST (not inside the sandbox) after modifying the
# Rego policy file. It copies the policy to the plugin's directory
# and bounces the plugin so OPA re-compiles the new rules.
#
# Idempotent: safe to re-run. The plugin enable/disable is guarded
# by a state check — if already disabled, the disable step is skipped.
#
# Prerequisites:
#   - opa-docker-authz plugin installed and previously enabled
#   - Policy file exists at POLICY_SRC
#
# Usage:
#   sudo ./reload-opa-policy.sh             # from repo root
#   sudo ./reload-opa-policy.sh /path/to/agent.rego  # with explicit source
#
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration (override via environment variables) ─────────
CA_DIR="${CA_DIR:-/etc/docker}"
POLICY_SRC="${1:-./skeleton/agent.rego}"
POLICY_DST="${CA_DIR}/authz/agent.rego"
PLUGIN="opa-docker-authz"

# ─── Step 1: Validate source file ───────────────────────────────
if [ ! -f "$POLICY_SRC" ]; then
    echo "ERROR: policy source not found: $POLICY_SRC" >&2
    echo "  Pass the path as an argument, or run from the blueprint root." >&2
    exit 1
fi

echo "==> Step 1: Copy Rego policy"
install -D -m 644 "$POLICY_SRC" "$POLICY_DST"
echo "  Wrote ${POLICY_DST}"
echo ""

# ─── Step 2: Bounce the authz plugin ────────────────────────────
echo "==> Step 2: Bounce opa-docker-authz plugin"

# Check if plugin is currently enabled
if docker plugin ls --format '{{.Name}}|{{.Enabled}}' 2>/dev/null | grep -q "^${PLUGIN}|true$"; then
    echo "  Disabling plugin..."
    docker plugin disable "$PLUGIN"
    echo "  Re-enabling plugin..."
    docker plugin enable "$PLUGIN"
    echo "  Plugin re-enabled."
elif docker plugin ls --format '{{.Name}}' 2>/dev/null | grep -q "^${PLUGIN}$"; then
    echo "  Plugin exists but is disabled — enabling directly..."
    docker plugin enable "$PLUGIN"
else
    echo "ERROR: plugin ${PLUGIN} not installed." >&2
    echo "  Install it first:" >&2
    echo "    docker plugin install ghcr.io/open-policy-agent/opa-docker-authz:v0.10" >&2
    exit 1
fi
echo ""

# ─── Step 3: Verify ─────────────────────────────────────────────
echo "==> Step 3: Verify plugin status"
docker plugin ls --format '{{.Name}} enabled={{.Enabled}}' | grep "^${PLUGIN}" || true
echo ""

# ─── Hint: test from sandbox ────────────────────────────────────
echo "  Next, test from inside the sandbox container:"
echo "    docker ps"
echo "    docker compose -p <project> ps"
echo "    docker run --rm alpine echo hello  (should be denied)"
echo ""