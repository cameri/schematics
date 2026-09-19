#!/bin/sh
# Router acceptance checks.
#
# Implements the mechanical checks of SCHEMATIC.md's Verification and
# Acceptance section against a RUNNING router. Read-only on the host: it
# changes no file, no container, and no configuration. Safe to re-run.
#
# It does spend a few tokens: the completion checks send real requests to real
# providers (set SKIP_COMPLETIONS=1 for a credential-free structural pass).
#
# Inputs (environment; none of these is written anywhere):
#   ROUTER_BASE_URL      base URL of the router, including /v1
#                        (default: http://llm-router:4000/v1)
#   ROUTER_API_KEY       the router credential. Prefer the file form below so
#                        the value never appears in argv or shell history.
#   ROUTER_API_KEY_FILE  file containing the credential (takes precedence)
#   EXPECTED_ALIASES     comma-separated alias ids the map must serve; when
#                        unset, the check reports the set it found instead of
#                        comparing it
#   ALIASES              comma-separated subset to send completions through
#                        (default: every served alias). After rotating one
#                        provider's key, testing that provider's aliases is
#                        enough
#   HEALTH_PATH          health endpoint path (default: /health/liveliness)
#   ROUTER_CONTAINER     container name; when set, adds the at-rest check that
#                        the mounted key store carries no plaintext (A-6)
#   STORE_PATH           path, inside that container, of the mounted key store
#                        (default: /run/secrets/router-secrets.env)
#   SKIP_COMPLETIONS     set to 1 to skip every token-spending check
#   TIMEOUT              per-request timeout in seconds (default: 30)
#
# Exit status: 0 when every executed check passed; 1 when any failed; 2 on a
# usage/precondition error (no credential, no python3).
set -eu

ROUTER_BASE_URL="${ROUTER_BASE_URL:-http://llm-router:4000/v1}"
HEALTH_PATH="${HEALTH_PATH:-/health/liveliness}"
ROUTER_CONTAINER="${ROUTER_CONTAINER:-}"
STORE_PATH="${STORE_PATH:-/run/secrets/router-secrets.env}"
EXPECTED_ALIASES="${EXPECTED_ALIASES:-}"
ALIASES="${ALIASES:-}"
SKIP_COMPLETIONS="${SKIP_COMPLETIONS:-0}"
TIMEOUT="${TIMEOUT:-30}"

if [ -n "${ROUTER_API_KEY_FILE:-}" ]; then
  ROUTER_API_KEY="$(cat "$ROUTER_API_KEY_FILE")"
elif [ -z "${ROUTER_API_KEY:-}" ]; then
  echo "usage: ROUTER_API_KEY=... (or ROUTER_API_KEY_FILE=...) $0" >&2
  echo "       ROUTER_BASE_URL defaults to $ROUTER_BASE_URL" >&2
  exit 2
fi

# Strip only trailing newline/CR: a credential is otherwise taken literally.
ROUTER_API_KEY="$(printf '%s' "$ROUTER_API_KEY" | tr -d '\r' | sed -e '$a\' -e '')"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required (the router image guarantees it)" >&2
  exit 2
fi

export ROUTER_BASE_URL HEALTH_PATH ROUTER_CONTAINER STORE_PATH EXPECTED_ALIASES \
       ALIASES SKIP_COMPLETIONS TIMEOUT ROUTER_API_KEY

python3 - <<'PY'
import json, os, shlex, subprocess, sys, urllib.error, urllib.request

BASE = os.environ["ROUTER_BASE_URL"].rstrip("/")
ORIGIN = BASE[:-3] if BASE.endswith("/v1") else BASE
KEY = os.environ["ROUTER_API_KEY"]
HEALTH = "/" + os.environ["HEALTH_PATH"].lstrip("/")
TIMEOUT = float(os.environ["TIMEOUT"])
EXPECTED = [a.strip() for a in os.environ["EXPECTED_ALIASES"].split(",") if a.strip()]
SUBSET = [a.strip() for a in os.environ["ALIASES"].split(",") if a.strip()]
CONTAINER = os.environ["ROUTER_CONTAINER"]
STORE_PATH = os.environ["STORE_PATH"]
SKIP_COMPLETIONS = os.environ["SKIP_COMPLETIONS"] == "1"

results = []
def check(name, ok, detail="", skip=False):
    results.append((name, "SKIP" if skip else ("PASS" if ok else "FAIL"), detail))
    print(f"{'SKIP' if skip else ('PASS' if ok else 'FAIL')}  {name}" + (f" — {detail}" if detail else ""))

def request(path, method="GET", body=None, key=KEY, base=None):
    """Returns (status, parsed-or-text). Never raises on an HTTP error status."""
    url = (base or BASE) + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if key is not None:
        req.add_header("Authorization", "Bearer " + key)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:                      # connection refused, DNS, timeout
        return 0, str(e)

COMPLETION = {
    "messages": [{"role": "user", "content": "Reply with exactly the word PONG."}],
    # Generous on purpose: a reasoning model can spend a small budget without
    # emitting any visible text, which would fail this check for a reason that
    # has nothing to do with the router.
    "max_tokens": 256,
}

def answer_text(payload):
    """First non-empty assistant text in a completion response.

    Tolerates the shapes providers actually return: a null `content` with the
    text in `reasoning_content`, an empty `content` on a truncated response,
    and providers that return content as a list of parts.
    """
    if not isinstance(payload, dict):
        return ""
    choices = payload.get("choices") or []
    if not choices:
        return ""
    message = (choices[0] or {}).get("message") or {}
    for field in ("content", "reasoning_content"):
        value = message.get(field)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, list):
            joined = "".join(p.get("text", "") for p in value if isinstance(p, dict))
            if joined.strip():
                return joined.strip()
    return ""

# --- A-2: the router is alive ------------------------------------------------
status, _ = request(HEALTH, base=ORIGIN, key=None)
check("A-2 health endpoint answers", status == 200, f"HTTP {status} {ORIGIN}{HEALTH}")

# --- A-3: authentication is enforced (R-2) -----------------------------------
status_no_key, _ = request("/models", key=None)
check("A-3 request without a credential is rejected", status_no_key in (401, 403), f"HTTP {status_no_key}")
status_bad_key, _ = request("/models", key="router-verify-wrong-credential")
check("A-3 request with a wrong credential is rejected", status_bad_key in (401, 403), f"HTTP {status_bad_key}")

# --- A-1: the model surface is exactly the configured alias set (R-1) --------
status, payload = request("/models")
served = sorted(m.get("id") for m in payload.get("data", [])) if isinstance(payload, dict) else []
if status != 200:
    check("A-1 model list is served", False, f"HTTP {status} {payload!r}"[:200])
elif EXPECTED:
    check("A-1 model list equals the configured alias set",
          served == sorted(EXPECTED),
          f"served={served} expected={sorted(EXPECTED)}")
else:
    check("A-1 model list is served (set not compared: EXPECTED_ALIASES unset)",
          bool(served), f"served={served}")

# --- R-3: an unconfigured model id is an error, not a passthrough ------------
status, payload = request("/chat/completions", method="POST",
                          body=dict(COMPLETION, model="router-verify-nonexistent-model"))
detail = payload if isinstance(payload, str) else json.dumps(payload.get("error", payload))[:160]
check("R-3 unconfigured model id is refused", 400 <= status < 500, f"HTTP {status} {detail}")

# --- R-9: unsupported parameters are dropped, not rejected ------------------
if SKIP_COMPLETIONS or not served:
    check("R-9 unsupported parameter is dropped (needs a completion)", False, "skipped", skip=True)
else:
    status, payload = request("/chat/completions", method="POST",
                              body=dict(COMPLETION, model=served[0], store=False))
    check("R-9 unsupported parameter is dropped, not rejected", status == 200,
          f"HTTP {status} model={served[0]} store=false")

# --- A-4: a real completion per alias (proves binding + base + credential) ---
if SKIP_COMPLETIONS:
    check("A-4 completion per alias", False, "skipped by SKIP_COMPLETIONS=1", skip=True)
elif not served:
    check("A-4 completion per alias", False, "no aliases to test")
else:
    targets = SUBSET or (sorted(EXPECTED) if EXPECTED else served)
    for alias in targets:
        status, payload = request("/chat/completions", method="POST", body=dict(COMPLETION, model=alias))
        text = answer_text(payload)
        reported = payload.get("model") if isinstance(payload, dict) else payload
        check(f"A-4 completion through {alias}", status == 200 and bool(text),
              f"HTTP {status} answered {text[:24]!r} reported-model={reported!r}" if status == 200 and text
              else f"HTTP {status} {str(payload)[:200]}")

# --- A-6: no plaintext credential at rest in the container (R-4) ------------
# This inspects the MOUNTED STORE FILE, not the process environment: the
# decrypted values are supposed to live in the router process's environment
# (and only there), so finding one there is expected behavior, not a finding.
# Pointing STORE_PATH at a process's environ is therefore not a valid
# negative control for this check.
if not CONTAINER:
    check("A-6 mounted key store holds no plaintext", False,
          "skipped: set ROUTER_CONTAINER", skip=True)
else:
    try:
        # The credential is fed on stdin, never in argv: it cannot be read out
        # of a process list on the operator host or inside the container.
        p = subprocess.run(
            ["docker", "exec", "-i", CONTAINER, "sh", "-c",
             "grep -qF -f - " + shlex.quote(STORE_PATH)],
            input=KEY.encode(), capture_output=True, timeout=TIMEOUT)
        if p.returncode == 0:
            check("A-6 mounted key store holds no plaintext", False,
                  "the decrypted credential appears in the mounted store file")
        elif p.returncode == 1:
            check("A-6 mounted key store holds no plaintext", True, "ciphertext only")
        else:
            check("A-6 mounted key store holds no plaintext", False,
                  f"could not inspect the store: {p.stderr.decode('utf-8', 'replace').strip()[:160]}")
    except Exception as e:
        check("A-6 mounted key store holds no plaintext", False, f"docker exec failed: {e}"[:160])

# --- A-14: every route in the surface table is registered (R-1) --------------
# An unregistered path answers 404 while a registered one answers 401 without a
# credential, so one unauthenticated request per row separates "the route
# exists" from "this deployment lacks it". This is the failure a router built
# for a single protocol has: invisible to every provider-side check, and the
# reason this row is worth running on its own. Costs no tokens.
ROUTES = [
    ("GET", "/v1/models"),
    ("POST", "/v1/chat/completions"),
    ("POST", "/v1/completions"),
    ("POST", "/v1/embeddings"),
    ("POST", "/v1/messages"),
    ("POST", "/v1/responses"),
    ("POST", "/v1/rerank"),
    ("POST", "/v1/moderations"),
    ("POST", "/v1/images/generations"),
    ("POST", "/v1/batches"),
]
CONTROL = "/v1/bogus-route-xyz"

control_status, _ = request(CONTROL, method="POST", key=None, base=ORIGIN)
check("A-14 unserved path answers 404 (the control)", control_status == 404,
      f"HTTP {control_status} POST {ORIGIN}{CONTROL}"
      + ("" if control_status == 404 else " — without a 404 here the 401s prove nothing"))

registered = {}
for method, path in ROUTES:
    status, _ = request(path, method=method, key=None, base=ORIGIN)
    registered[path] = status in (401, 403)
    detail = f"HTTP {status} {method} {ORIGIN}{path}"
    if status == 404:
        detail += " — 404: this router does not serve the route"
    elif not registered[path]:
        detail += " — expected 401 (or 403) with no credential"
    check(f"A-14 {method} {path} is registered", registered[path], detail)

# The two protocol rows are the ones a single-protocol build silently lacks, so
# they get their own named result rather than being folded into the list above.
for path, family in (("/v1/messages", "Claude-family"), ("/v1/responses", "Codex-family")):
    check(f"A-14 {path} serves the {family} client wired in A-10",
          registered.get(path, False),
          "" if registered.get(path) else "route not registered: that client cannot reach the router")

for path in (HEALTH, "/health/readiness"):
    status, _ = request(path, base=ORIGIN, key=None)
    check(f"A-14 {path} answers 200 with no credential", status == 200, f"HTTP {status} {ORIGIN}{path}")

# --- Summary -----------------------------------------------------------------
failed = [n for n, s, _ in results if s == "FAIL"]
skipped = [n for n, s, _ in results if s == "SKIP"]
print()
print(f"{len(results) - len(failed) - len(skipped)} passed, {len(failed)} failed, {len(skipped)} skipped")
if failed:
    print("failed: " + "; ".join(failed))
sys.exit(1 if failed else 0)
PY
