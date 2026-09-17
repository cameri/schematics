#!/usr/bin/env bash
# ─── Reload the OPA policy without restarting the Docker daemon ──
#
# Run this on the HOST (not inside the sandbox) after changing the Rego
# policy. It validates the substituted policy, installs it where the plugin
# reads it, and bounces the plugin so it is compiled again.
#
# Idempotent: safe to re-run. The bounce is guarded by a state check.
#
# What the bounce costs: while the plugin is disabled the daemon's
# authorization middleware fails closed, so EVERY API call is denied
# (host users included) until it is enabled again. That window is short, but
# it is a denial window, not an open one. If a plugin-free policy change is
# required, install the plugin with `-config-file` and a bundle service
# instead — see modules/policy-reload.md.
#
# Prerequisites:
#   - the authorization plugin installed (with opa-args) and enabled
#   - the policy source fully substituted: no PLACEHOLDER tokens left
#
# Usage:
#   sudo ./reload-opa-policy.sh                    # uses ./skeleton/agent.rego
#   sudo ./reload-opa-policy.sh /path/to/agent.rego
#
# Environment overrides:
#   POLICY_DIR   where the plugin reads the policy  (default /etc/docker/authz)
#   PLUGIN       installed plugin name              (default opa-docker-authz)
#   OPA_BIN      path to an opa binary for `opa check` (optional)
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

POLICY_DIR="${POLICY_DIR:-/etc/docker/authz}"
POLICY_SRC="${1:-./skeleton/agent.rego}"
POLICY_DST="${POLICY_DIR}/agent.rego"
PLUGIN="${PLUGIN:-opa-docker-authz}"
OPA_BIN="${OPA_BIN:-}"

PLACEHOLDERS='SANDBOX_USERNAME|AUTH_HEADER_NAME|PROJECT_NAME|PROJECT_DIR_PATH|BUILDKIT_PREFIX|TESTCONTAINERS_LABEL'

# ─── Step 1: validate the source policy ─────────────────────────
if [ ! -f "$POLICY_SRC" ]; then
    echo "ERROR: policy source not found: $POLICY_SRC" >&2
    echo "  Pass the path as an argument, or run from the schematic root." >&2
    exit 1
fi

leftover="$(awk -v pat="$PLACEHOLDERS" \
    '!/^[[:space:]]*#/ && $0 ~ pat { printf "%s:%d: %s\n", FILENAME, FNR, $0 }' \
    "$POLICY_SRC")"
if [ -n "$leftover" ]; then
    echo "ERROR: policy still contains placeholder tokens:" >&2
    echo "$leftover" >&2
    echo "  Substitute them from the Parameters table first (see" >&2
    echo "  skeleton/agent.rego.schema). Deploying a placeholder turns the" >&2
    echo "  policy into 'allow everything': the sandbox stops being" >&2
    echo "  recognised as a sandbox client at all." >&2
    exit 1
fi
echo "==> Step 1: policy has no placeholder tokens"

if [ -n "$OPA_BIN" ]; then
    "$OPA_BIN" check "$POLICY_SRC"
    echo "  passed opa check: $OPA_BIN"
fi

# What is being replaced, kept for rollback.
if [ -f "$POLICY_DST" ]; then
    backup="${POLICY_DST}.previous"
    cp -p "$POLICY_DST" "$backup"
    echo "  previous policy kept at ${backup}"
fi

install -D -m 644 "$POLICY_SRC" "$POLICY_DST"
echo "  wrote ${POLICY_DST}"
echo ""

# ─── Step 2: bounce the plugin so the policy is compiled ────────
echo "==> Step 2: bounce ${PLUGIN}"

if docker plugin ls --format '{{.Name}}|{{.Enabled}}' 2>/dev/null | grep -q "^${PLUGIN}|true$"; then
    echo "  disabling (API calls are denied while it is down)..."
    docker plugin disable "$PLUGIN"
    echo "  re-enabling (authorization resumes)..."
    docker plugin enable "$PLUGIN"
    echo "  plugin re-enabled."
elif docker plugin ls --format '{{.Name}}' 2>/dev/null | grep -q "^${PLUGIN}$"; then
    echo "  plugin exists but is disabled — enabling directly..."
    docker plugin enable "$PLUGIN"
else
    echo "ERROR: plugin ${PLUGIN} is not installed." >&2
    echo "  Install it WITH its policy argument, or every request is allowed:" >&2
    echo "    docker plugin install --grant-all-permissions --alias ${PLUGIN} \\" >&2
    echo "      ghcr.io/open-policy-agent/opa-docker-authz:v0.10 \\" >&2
    echo "      opa-args=\"-policy-file /opa/authz/agent.rego\"" >&2
    echo "  (the host path /etc/docker is mounted at /opa inside the plugin)" >&2
    exit 1
fi
echo ""

# ─── Step 3: verify ─────────────────────────────────────────────
echo "==> Step 3: plugin status"
docker plugin ls --format '{{.Name}} enabled={{.Enabled}}' | grep "^${PLUGIN}" || true
echo ""
echo "  Now verify a decision, not just the plugin state:"
echo "    docker --tlsverify -H tcp://<P-1>:<P-2> ... ps        # allowed"
echo "    docker --tlsverify -H tcp://<P-1>:<P-2> ... run --rm alpine echo hi   # denied"
echo "  If the second command succeeds, the policy is not in force — check for"
echo "  leftover placeholders and that the plugin was installed with opa-args."
echo ""
