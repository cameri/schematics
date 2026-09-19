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
#                        the mounted key store carries no plaintext (A-6) and the
#                        account check (A-15: not root, and every process running
#                        as the account the container states). Run this on the
#                        host that runs the container: A-15 resolves the names
#                        `docker top` prints against this host's passwd, which is
#                        the database ps read them from.
#   STORE_PATH           path, inside that container, of the mounted key store
#                        (default: /run/secrets/router-secrets.env)
#   SKIP_COMPLETIONS     set to 1 to skip every token-spending check
#   CLIENT_ARMS          comma-separated coding-agent client families this
#                        deployment wires, from: claude, codex
#                        (default: claude,codex — the reference deployment's)
#                        A-14 asserts the conformance floor only: the two routes
#                        every router must serve, plus the protocol route of each
#                        family named here. Every other row of the reference
#                        table is probed and REPORTED, never failed, because a
#                        router that serves a narrower surface is conformant
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
CLIENT_ARMS="${CLIENT_ARMS:-claude,codex}"
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
       ALIASES SKIP_COMPLETIONS CLIENT_ARMS TIMEOUT ROUTER_API_KEY

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
CLIENT_ARMS = [a.strip() for a in os.environ["CLIENT_ARMS"].split(",") if a.strip()]

results = []
def check(name, ok, detail="", skip=False):
    results.append((name, "SKIP" if skip else ("PASS" if ok else "FAIL"), detail))
    print(f"{'SKIP' if skip else ('PASS' if ok else 'FAIL')}  {name}" + (f" — {detail}" if detail else ""))

def runner_error(exc_type, exc, tb):
    """An error in this script still prints the checks that ran, and exits 2.

    The rows are the deliverable and the summary is how a caller reads them, so
    the one outcome that must never happen is a traceback where the verdicts
    should be. The traceback follows the summary, not instead of it.
    """
    import traceback
    print()
    print(f"RUNNER ERROR  {exc_type.__name__}: {exc} — the rows above are every check that ran; "
          f"this is a defect in the script, not a verdict on the router")
    failed = [n for n, state, _ in results if state == "FAIL"]
    skipped = [n for n, state, _ in results if state == "SKIP"]
    print(f"{len(results) - len(failed) - len(skipped)} passed, {len(failed)} failed, {len(skipped)} skipped")
    traceback.print_exception(exc_type, exc, tb)
    sys.exit(2)

sys.excepthook = runner_error

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
# A body is whatever the router answered with, including a JSON array or a bare
# string, so the shape is tested rather than assumed: `payload.get` on a list is
# the same defect as a name a failed command never set.
error = payload.get("error", payload) if isinstance(payload, dict) else payload
detail = (payload if isinstance(payload, str) else json.dumps(error))[:200]
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
        #
        # The verdict is text, and it is derived from the status of the command
        # under test and nothing else. grep gives meaning to exactly two of
        # them — 0 found, 1 not found — so every other status (a path that does
        # not exist or is a directory, an unreadable file, docker's own
        # failure) is "could not inspect", never "clean". A verdict taken from
        # another command's failure is how this check reported ciphertext for a
        # container that had already been removed (measured 2026-09-19), and
        # the same shape reads "clean" for a store path that is missing or a
        # directory.
        p = subprocess.run(
            ["docker", "exec", "-i", CONTAINER, "sh", "-c",
             'grep -qF -f - "$1"; status=$?; case $status in '
             '0) echo A6-FOUND;; 1) echo A6-CLEAN;; *) echo "A6-ERROR status=$status";; esac',
             "_", STORE_PATH],
            input=KEY.encode(), capture_output=True, timeout=TIMEOUT)
        verdict = p.stdout.decode("utf-8", "replace").strip()
        if verdict == "A6-FOUND":
            check("A-6 mounted key store holds no plaintext", False,
                  "the decrypted credential appears in the mounted store file")
        elif verdict == "A6-CLEAN":
            check("A-6 mounted key store holds no plaintext", True, "ciphertext only")
        else:
            check("A-6 mounted key store holds no plaintext", False,
                  f"could not inspect the store: "
                  f"{(p.stderr.decode('utf-8', 'replace').strip() or f'exit {p.returncode}')[:160]}")
    except Exception as e:
        check("A-6 mounted key store holds no plaintext", False, f"docker exec failed: {e}"[:160])

# --- A-15: the container does not run as root (R-12) -------------------------
# Two readings, because either alone is silenceable. `Config.User` is what the
# deployment ASKED for (the image's USER, unless a `user:` overrode it); the uid
# column of `docker top` is what the processes GOT. A deployment can pass the
# first and fail the second, and a root container passes every other row in this
# script — including A-1 and A-2 — so nothing else here would notice. Both need
# only `docker inspect`/`docker top`, so this row runs without `docker exec`.
#
# The readability half of R-12 needs no third check: the router read the mounted
# config and key store to get this far, so a healthy container has already
# proven that account can read them.
if not CONTAINER:
    check("A-15 container account is stated and is not root", False,
          "skipped: set ROUTER_CONTAINER", skip=True)
    check("A-15 every process runs as that account", False,
          "skipped: set ROUTER_CONTAINER", skip=True)
else:
    ROOTISH = ("", "0", "root", "0:0")

    def account_uid(identity):
        """The uid an identity string names, or None when it cannot be resolved.

        `docker inspect` reports the account as the image or the deployment
        stated it — a name, a number, or `uid:gid` — and `docker top` reports
        whatever `ps` prints, which is the number for a uid this host has no
        name for and the name otherwise. Resolving a name against this host's
        passwd puts both sides in one language: the number.
        """
        head = str(identity).split(":")[0].strip()
        if head.isdigit():
            return int(head)
        try:
            import pwd
            return pwd.getpwnam(head).pw_uid
        except (KeyError, ImportError):
            return None
    # Both are assigned before the attempt, so a failed `docker inspect` leaves
    # them at None rather than undefined: state that a command sets and a
    # handler skips is read on the far side of that handler, and an unbound name
    # there turns a failed check into a traceback with no summary at all.
    configured = None
    configured_uid = None
    try:
        p = subprocess.run(["docker", "inspect", "--format", "{{.Config.User}}", CONTAINER],
                           capture_output=True, timeout=TIMEOUT)
        configured = p.stdout.decode("utf-8", "replace").strip()
        if p.returncode != 0:
            raise RuntimeError(p.stderr.decode("utf-8", "replace").strip()[:120])
        check("A-15 container account is stated and is not root",
              configured.lower() not in ROOTISH,
              f"Config.User={configured!r}" if configured.lower() not in ROOTISH
              else f"Config.User={configured!r} — the image states no account, or a user: override set it to root")
        # An unstated account is the image's default, which is root.
        configured_uid = 0 if configured.strip() == "" else account_uid(configured)
    except Exception as e:
        check("A-15 container account is stated and is not root", False, f"docker inspect failed: {e}"[:160])
        # A failed inspect leaves no account to compare against, so the second
        # reading says so rather than blaming the host's passwd for a value the
        # command never returned.
        configured = None

    if configured is None:
        check("A-15 every process runs as that account", False,
              "could not inspect the container: the account it states is unknown, so nothing can be "
              "compared with it")
    elif configured_uid is None:
        check("A-15 every process runs as that account", False,
              f"cannot compare: this host cannot resolve the configured account {configured!r} to a "
              f"uid. Configure a numeric account (user: \"65532:65532\") so the check is decidable "
              f"rather than assumed")
    else:
        try:
            p = subprocess.run(["docker", "top", CONTAINER], capture_output=True, timeout=TIMEOUT)
            rows = [line.split() for line in p.stdout.decode("utf-8", "replace").splitlines() if line.split()]
            if p.returncode != 0 or len(rows) < 2:
                raise RuntimeError((p.stderr.decode("utf-8", "replace").strip() or "no processes returned")[:120])
            # The column is located by header name: ps output across hosts
            # differs (procps says UID, busybox says USER) but one of those two
            # headers is what both print first.
            header = [h.upper() for h in rows[0]]
            column = next((i for i, h in enumerate(header) if h in ("UID", "USER")), 0)
            seen = sorted({row[column] for row in rows[1:] if len(row) > column})
            # Every identity is resolved to a uid and compared with the
            # configured one. Names come from this host's passwd — the same
            # database ps read them from — so a name and its number compare
            # equal. Only the uid is comparable: `docker top` prints no group,
            # so a differing gid is outside this check.
            resolved = {token: account_uid(token) for token in seen}
            unresolved = [token for token, uid in resolved.items() if uid is None]
            mismatched = {token: uid for token, uid in resolved.items()
                          if uid is not None and uid != configured_uid}
            count = len(rows) - 1
            detail = (f"configured {configured!r} (uid {configured_uid}); docker top: {seen} "
                      f"({count} process{'es' if count != 1 else ''})")
            if unresolved:
                detail += (f" — this host cannot resolve {', '.join(unresolved)} to a uid, so the "
                           f"identity cannot be compared")
            if mismatched:
                detail += " — " + ", ".join(f"{t} is uid {u}" for t, u in sorted(mismatched.items()))
                if 0 in mismatched.values():
                    detail += "; uid 0 is running in this container"
            check("A-15 every process runs as that account",
                  configured_uid != 0 and not unresolved and not mismatched, detail)
        except Exception as e:
            check("A-15 every process runs as that account", False, f"docker top failed: {e}"[:160])

# --- A-14: the conformance floor is registered (R-1, R-11) -------------------
# An unregistered path answers 404 while a registered one answers 401 without a
# credential, so one unauthenticated request per row separates "the route
# exists" from "this deployment lacks it". This is the failure a router built
# for a single protocol has: invisible to every provider-side check, and the
# reason this row is worth running on its own. Costs no tokens.
#
# What this row ASSERTS is the conformance floor, not the reference
# implementation's whole surface. The table under Interfaces and Contracts is
# the reference router's, and the spec says a router that serves a narrower
# surface is still conformant — so only the routes the deployment's clients
# actually need can fail here: /v1/models and /v1/chat/completions, which every
# router must serve, plus the protocol route of each client family this
# deployment declares in CLIENT_ARMS (A-10 is the row that wires them). Every
# other row of the table is probed and REPORTED — a route this router does not
# serve is information about it, not a defect. A row added to the table and not
# to OPTIONAL below is simply unprobed, so keep the two in step.
FLOOR = [
    ("GET", "/v1/models"),
    ("POST", "/v1/chat/completions"),
]
# The client families A-10 can wire, each with the protocol route it needs.
FAMILIES = {
    "claude": ("POST", "/v1/messages"),
    "codex": ("POST", "/v1/responses"),
}
# The rest of the reference table (SCHEMATIC.md § Interfaces and Contracts):
# probed, reported, never failed.
OPTIONAL = [
    ("POST", "/v1/completions"),
    ("POST", "/v1/embeddings"),
    ("POST", "/v1/rerank"),
    ("POST", "/v1/moderations"),
    ("POST", "/v1/images/generations"),
    ("POST", "/v1/batches"),
]
CONTROL = "/v1/bogus-route-xyz"

# The control, in both methods: a router whose 404 handling is method-sensitive
# could answer the POST control without being unregistered in general, and then
# the 401s below would prove nothing. Two requests, no tokens.
for control_method in ("POST", "GET"):
    control_status, _ = request(CONTROL, method=control_method, key=None, base=ORIGIN)
    check(f"A-14 unserved path answers 404 (the control, {control_method})",
          control_status == 404,
          f"HTTP {control_status} {control_method} {ORIGIN}{CONTROL}"
          + ("" if control_status == 404 else " — without a 404 here the 401s prove nothing"))

unknown = [a for a in CLIENT_ARMS if a not in FAMILIES]
if unknown:
    check("A-14 CLIENT_ARMS names only client families this row knows", False,
          f"unknown: {', '.join(unknown)} (known: {', '.join(sorted(FAMILIES))})")

REQUIRED = list(FLOOR) + [FAMILIES[a] for a in CLIENT_ARMS if a in FAMILIES]
REQUIRED_PATHS = {path for _, path in REQUIRED}

registered = {}
for method, path in REQUIRED + OPTIONAL:
    status, _ = request(path, method=method, key=None, base=ORIGIN)
    registered[path] = status in (401, 403)
    if path not in REQUIRED_PATHS:
        continue
    detail = f"HTTP {status} {method} {ORIGIN}{path}"
    if status == 404:
        detail += " — 404: this deployment's clients need this route"
    elif not registered[path]:
        detail += " — expected 401 (or 403) with no credential"
    check(f"A-14 {method} {path} is registered", registered[path], detail)

# The protocol route of each wired family is the one a single-protocol build
# silently lacks, so each gets its own named result rather than being folded
# into the list above.
for arm in CLIENT_ARMS:
    if arm not in FAMILIES:
        continue
    arm_method, arm_path = FAMILIES[arm]
    check(f"A-14 {arm_path} serves the {arm}-family client wired in A-10",
          registered.get(arm_path, False),
          "" if registered.get(arm_path) else "route not registered: that client cannot reach the router")

narrower = [f"{m} {p}" for m, p in OPTIONAL if not registered.get(p)]
if narrower:
    print("      A-14 note: not served here — " + ", ".join(narrower)
          + " (optional: the reference table lists them, and a narrower router is conformant)")

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
