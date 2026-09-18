#!/usr/bin/env bash
# ─── Deploy a Rego policy change without restarting dockerd ──────
#
# The plugin re-reads the policy FILE ON EVERY REQUEST, so a policy change
# takes effect on the next API call and there is nothing to bounce. main.go
# (evaluatePolicyFile) does `os.ReadFile(p.policyFile)` inside the evaluation
# of every request, then logs a sha256 of the bytes it read as the decision
# log's `config_hash`. Two consequences decide this whole procedure:
#
#   1. `docker plugin disable` / `enable` / `rm` / `upgrade` is NOT part of a
#      policy change, and is FATAL while the daemon references the plugin: a
#      missing or disabled plugin makes dockerd exit —
#        level=fatal msg="Error validating authorization plugin"
#          error="plugin \"opa-docker-authz\" not found"
#      (measured on Docker 29.6.1, snap install). Whether that costs only the
#      API or every container depends on the unit's restart policy and
#      live-restore — do not find out on purpose.
#   2. The policy file must never be *absent* on a request: a missing file is
#      the plugin's one fail-OPEN path, and it says so in its log —
#        OPA policy file %s does not exist, failing open and allowing request
#      So the file is replaced by writing a temporary file and renaming it over
#      the target (one atomic rename on the same filesystem), never by copying
#      or truncating the live path.
#
# Usage:
#   sudo ./reload-opa-policy.sh [substituted-agent.rego]     # default ./agent.rego
#   sudo ./reload-opa-policy.sh --rollback                   # restore <policy>.previous
#   ./reload-opa-policy.sh --discover                        # print the policy path
#
# The policy path is read from the plugin itself, so it does not have to be
# guessed: `docker plugin inspect` shows both the argument the plugin runs with
# (`-policy-file /opa/authz/agent.rego`) and the mount that carries it
# (`/etc/docker -> /opa`), and together they are the host path to write (this is
# P-7). `--discover` reports it and exits.
#
# Environment overrides:
#   POLICY_DST   host path of the policy file to replace (wins over POLICY_DIR)
#   POLICY_DIR   host directory the plugin reads the policy from
#   PLUGIN       installed plugin name              (default opa-docker-authz)
#   OPA_BIN      opa binary for `opa check`         (optional; used if set)
#   OPA_IMAGE    image for `opa check` instead      (default openpolicyagent/opa:1.3.0)
#   SKIP_CHECK   set to 1 to skip `opa check`       (not recommended)
#
# Prerequisites: the authorization plugin installed WITH its policy argument,
# and the policy source fully substituted (no PLACEHOLDER tokens left).
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PLUGIN="${PLUGIN:-opa-docker-authz}"
OPA_BIN="${OPA_BIN:-}"
OPA_IMAGE="${OPA_IMAGE:-openpolicyagent/opa:1.3.0}"
SKIP_CHECK="${SKIP_CHECK:-0}"
POLICY_DIR="${POLICY_DIR:-}"
POLICY_DST="${POLICY_DST:-}"

PLACEHOLDERS='SANDBOX_USERNAME|AUTH_HEADER_NAME|PROJECT_NAME|PROJECT_DIR_PATH|EXTRA_BIND_ROOTS|BUILDKIT_PREFIX|TESTCONTAINERS_LABEL'

# ─── Where the plugin reads its policy ──────────────────────────
# Echoes the host path of the file the plugin's -policy-file argument names,
# by mapping that in-plugin path back through the plugin's own bind mount.
discover_policy_file() {
    local inpath src dest rest
    inpath="$(docker plugin inspect "$PLUGIN" \
        --format '{{range .Settings.Args}}{{println .}}{{end}}' 2>/dev/null \
        | awk '/^-policy-file$/{getline; print; exit}')" || true
    if [ -z "$inpath" ]; then
        inpath="$(docker plugin inspect "$PLUGIN" \
            --format '{{range .Settings.Args}}{{println .}}{{end}}' 2>/dev/null \
            | sed -n 's/^-policy-file=//p' | head -1)"
    fi
    [ -n "$inpath" ] || return 1
    while IFS='|' read -r src dest; do
        [ -n "$src" ] && [ -n "$dest" ] || continue
        case "$inpath" in
            "$dest"/*) rest="${inpath#"$dest"}"; printf '%s%s\n' "${src%/}" "$rest"; return 0 ;;
            "$dest")   printf '%s\n' "$src"; return 0 ;;
        esac
    done < <(docker plugin inspect "$PLUGIN" \
        --format '{{range .Settings.Mounts}}{{.Source}}|{{.Destination}}{{println}}{{end}}' 2>/dev/null)
    return 1
}

if [ "${1:-}" = "--discover" ]; then
    if found="$(discover_policy_file)"; then
        echo "$found"
        exit 0
    fi
    echo "ERROR: no policy path could be read from plugin ${PLUGIN}." >&2
    echo "  Is it installed (docker plugin ls) and does it run with -policy-file?" >&2
    exit 1
fi

if [ -n "$POLICY_DST" ]; then
    POLICY_DIR="${POLICY_DIR:-$(dirname "$POLICY_DST")}"
elif [ -n "$POLICY_DIR" ]; then
    POLICY_DST="${POLICY_DIR}/agent.rego"
elif POLICY_DST="$(discover_policy_file)"; then
    POLICY_DIR="$(dirname "$POLICY_DST")"
    echo "==> policy path discovered from plugin ${PLUGIN}: ${POLICY_DST}"
else
    POLICY_DIR="/etc/docker/authz"
    POLICY_DST="${POLICY_DIR}/agent.rego"
    echo "==> WARNING: no policy path could be read from plugin ${PLUGIN};"
    echo "    falling back to ${POLICY_DST} (override with POLICY_DST=<host file>)."
fi
POLICY_DIR="${POLICY_DIR%/}"
POLICY_PREV="${POLICY_DST}.previous"

# ─── Rollback path ──────────────────────────────────────────────
ROLLBACK=0
if [ "${1:-}" = "--rollback" ]; then
    ROLLBACK=1
    POLICY_SRC="$POLICY_PREV"
else
    POLICY_SRC="${1:-./agent.rego}"
fi

if [ ! -f "$POLICY_SRC" ]; then
    echo "ERROR: policy source not found: $POLICY_SRC" >&2
    echo "  Pass the substituted policy as an argument (--rollback uses" >&2
    echo "  ${POLICY_PREV})." >&2
    exit 1
fi

# ─── Step 1: validate the source policy ─────────────────────────
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

if [ "$SKIP_CHECK" != "1" ]; then
    # Check with the engine the plugin embeds (P-10), never a newer one.
    if [ -n "$OPA_BIN" ]; then
        "$OPA_BIN" check "$POLICY_SRC"
        echo "  passed opa check: ${OPA_BIN}"
    else
        src_dir="$(cd "$(dirname "$POLICY_SRC")" && pwd)"
        base="$(basename "$POLICY_SRC")"
        docker run --rm -v "${src_dir}:/w:ro" -w /w "$OPA_IMAGE" check "$base"
        echo "  passed opa check under ${OPA_IMAGE} (the engine v0.10 embeds)"
    fi
else
    echo "  WARNING: opa check skipped (SKIP_CHECK=1)"
fi

# ─── Step 2: keep the current policy, then replace it atomically ─
if [ "$ROLLBACK" = "1" ]; then
    echo "==> Step 2: rolling back to ${POLICY_PREV}"
    [ -f "$POLICY_PREV" ] || { echo "ERROR: ${POLICY_PREV} not found" >&2; exit 1; }
else
    if [ -f "$POLICY_DST" ]; then
        cp -p "$POLICY_DST" "$POLICY_PREV"
        echo "==> Step 2: previous policy kept at ${POLICY_PREV}"
        echo "    roll back with: $0 --rollback"
    else
        echo "==> Step 2: no policy deployed yet; nothing to keep"
    fi
fi

# temp file + rename: the plugin must never see a missing or partial policy.
tmp="${POLICY_DST}.tmp.$$"
trap 'rm -f "$tmp"' EXIT
install -D -m 644 "$POLICY_SRC" "$tmp"
mv -f "$tmp" "$POLICY_DST"
trap - EXIT
echo "    deployed atomically: ${POLICY_DST}"
echo ""

# ─── Step 3: verify a decision, not just the file ───────────────
new_hash="$(sha256sum "$POLICY_DST" | cut -d' ' -f1)"
echo "==> Step 3: verify"
echo "    policy sha256: ${new_hash}"
echo "    The plugin logs a sha256 of the bytes it read as the decision log's"
echo "    \`config_hash\` on every request, so this proves which policy is live:"
echo "      journalctl -u docker -n 200 | grep -o '\"config_hash\":\"[0-9a-f]*\"' | tail -1"
echo "    (a snap install logs where the unit logs; use 'docker info' to confirm"
echo "    the daemon, then that unit's journal). It must print the hash above"
echo "    after the next API call — no plugin bounce, no daemon restart."
echo ""
echo "    Then check the decisions the change was about, over the TLS listener:"
echo "      docker --tlsverify -H tcp://<P-1>:<P-2> ... ps                      # allowed"
echo "      docker --tlsverify -H tcp://<P-1>:<P-2> ... run --rm alpine true   # denied"
echo ""
echo "    If a request that should have been denied succeeds, the policy is not"
echo "    in force: check for leftover placeholders, and that the plugin was"
echo "    installed with its opa-args (a plugin without a policy allows all)."
echo ""
echo "==> Plugin state (for the record — this script never changes it)"
docker plugin ls --format '{{.Name}} enabled={{.Enabled}}' 2>/dev/null | grep "^${PLUGIN}" \
    || echo "    WARNING: plugin ${PLUGIN} not listed; it must exist and be enabled."
