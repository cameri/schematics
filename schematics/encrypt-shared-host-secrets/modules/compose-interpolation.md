# Module: Compose Interpolation

The Compose CLI resolves `${VAR}` inside a compose file **before any container
exists**: it reads the project's `.env`, or the file given with `--env-file`,
substitutes the values into the parsed configuration, and only then talks to the
Docker daemon. That step is a plaintext consumer by construction. No key, no
recipient and no wrapper changes it, because the thing that needs the plaintext
is the parser itself, and the parser runs inside the CLI process.

This module states what that means for a secret, which remedy applies, and how
the failure is made loud — because the failure is otherwise silent.

## Purpose

Owns the parse-time consumer: which values can be interpolated from where, the
three remedies for a secret that must be, and the guards that keep a missing
value from becoming an empty one. It does **not** own the classification
(`consumer-taxonomy.md`) or the container path, which is `D-5`'s.

## Inputs

- The compose files that interpolate a variable moving into the store.
- `P-4 PLAIN_ENV_FILE` (the narrow file the CLI reads by default),
  `P-13 COMPOSE_DIR`, `P-5 RUNTIME_DIR`, `P-14 RUNTIME_FILE_MODE`.
- The inventory row for each parse-time consumer: which variable, which remedy.
- `skeleton/preflight-compose-secrets.sh` to prove the guard; the wrapper
  (`skeleton/host-wrapper.sh`) when remedy (a) is chosen.

Error inputs tolerated: a stack whose values are all non-secret (nothing to
do); a CLI version without `--env-file` (remedy (b) then degrades to (a) or
(c)); a compose file that already uses `${VAR:?…}` (the guard is idempotent).

## Outputs

**The measured baseline, which is the reason this module exists** — Compose v2,
reproduced while authoring:

| Compose input | `.env` state | Result |
|---|---|---|
| `PLAIN: ${SHARED_SECRET}` | absent | **rc 0**, one warning on stderr (`The "SHARED_SECRET" variable is not set. Defaulting to a blank string.`), and `PLAIN: ""` in `docker compose config` |
| `REQUIRED: ${SHARED_SECRET:?SHARED_SECRET must be set}` | absent | rc 1, `error while interpolating services.probe.environment.REQUIRED: required variable SHARED_SECRET is missing a value: SHARED_SECRET must be set` |
| either form | present | rc 0, the value in the resolved config |
| either form, via `--env-file <other-file>` that lacks the variable | absent there | the same as the first row: blank, rc 0 |
| `SHARED_SECRET=fromfile` in `.env`, `SHARED_SECRET=fromenv` exported by the caller | present | rc 0, and the resolved value is **`fromenv`** — the CLI's own environment outranks the file |
| `SHARED_SECRET=` (empty) in `.env`, variable unset in the environment | empty string | rc 0, `SHARED_SECRET: ""` in the resolved config: set-but-empty and never-set are indistinguishable downstream |

An unset interpolated variable therefore **succeeds with an empty value**. A
compose file cannot tell "no secret configured" from "the secret mechanism did
not run", and the container starts.

**The three remedies, in the order they should be considered:**

**(a) Remove the need.** The best outcome for a secret is that the container
does not need it at parse time at all: the container's own boot path decrypts
it (`D-5`), or the value is not needed in that container's environment. This is
the default answer, and it is `R-3` rather than a compromise. After it, the
compose file has no `${SECRET}` in it, and the parse-time question disappears.

**(b) Materialize for the invocation.** When a value genuinely must be
interpolated, give the CLI a plaintext env-file for the duration of that run:
either hold the values in the CLI's own environment (`sops-env-exec --require
API_TOKEN 'docker compose up -d'`) or write a file under `${RUNTIME_DIR}` with
`materialize-env-file.sh` and pass it with `--env-file`. Cost, stated plainly:
plaintext exists on disk (or in the CLI's environment) for that window, so the
inventory records remedy (b), `A-4` bounds it to tmpfs where the platform
provides one, and `A-9` checks nothing is left behind. The trap that comes with
it: a **later invocation without the wrapper** sees the fail-fast form and
stops — which is why the fail-fast form is not optional under this remedy.

**(c) Narrow what is interpolated.** Split the file so the CLI reads only
non-secret values (the narrow file) and no secret is interpolated at all. This
is what a stack whose secrets all moved into containers ends at, and it is the
cheapest to operate: no wrapper, no materialization, no window.

**The guard, whichever remedy applies:** every interpolated secret is written
`${VAR:?message}`. This is the fail-fast form: absent, it aborts the parse and
names the variable (measured above). Non-secret interpolated values keep the
plain form — they are in the narrow file and their absence is a configuration
question, not a security one.

**The pre-flight check**, for the invocation that must not discover a missing
value at parse time: `docker compose config` resolves the whole file without
starting anything, so running it first (through
`skeleton/preflight-compose-secrets.sh --var NAME …`) turns "a consumer would
have started blank" into a named failure before anything is created.

## Dependencies

- `D-6` (Compose v2) for the whole module; without it there is no parse-time
  consumer.
- `P-4`, `P-5`, `P-13`, `P-14`.
- The wrapper (`skeleton/host-wrapper.sh`) for remedy (b)'s in-environment
  variant; `materialize-env-file.sh` for its file variant.

## Failure Behavior

- **A stack started outside the wrapper** (a unit at boot, a colleague, a CI
  job): with the fail-fast form it stops and names the variable — intended.
  Wrapping that invocation is the fix; removing the fail-fast form is not.
- **Someone drops the `:?` form** while debugging: the silent-blank baseline
  returns, and nothing reports it. Detect: `A-5` greps the resolved config for
  the variable and requires the parse to fail without it.
- **A materialized env-file left behind** (a crash between write and trap):
  plaintext persists at a path the inventory knows. Detect: `A-9`'s search for
  plaintext env files under `P-5`, run while the consumer is up as well as
  after it exits. Remedy: start the consumer through the wrapper so the removal
  is in the same process that owns the file, and remove any orphan by hand.
- **An empty resolved value with the fail-fast form present** (the file exists
  but holds `NAME=`): the parse succeeds and the container starts blank. Detect:
  the pre-flight script, which checks the resolved value is non-empty rather
  than merely defined.
- **A value interpolated from the wrong file** (a stray `.env` in
  `P-13 COMPOSE_DIR` overriding the intended source): the resolved config shows
  a value nobody set. Detect: `docker compose config | grep -A1 'NAME'` before
  deploying, and `--env-file` explicitly when remedy (b) is in use.
- **A stale value in the caller's environment**, which outranks the narrow file
  (measured above): the stack resolves a value from a shell someone exported
  hours ago, and the file that was changed has no effect. Detect: run the
  Compose command with `env -u NAME` and compare. Remedy: treat the wrapper's
  environment — the one invocation that supplies values deliberately — as the
  only supported way to put a value there, and export nothing by hand.

## Idempotency Notes

Rewriting an interpolation as `${VAR:?message}` is idempotent: a second pass
finds the form already in place. Materializing an env-file overwrites the
target, so a re-run converges on the current store contents. The pre-flight
check starts nothing and changes nothing, so it is safe as a unit's first step
and as a pre-deploy gate.

## Removal Notes

Removal restores the interpolated secret to the narrow file (or to whatever
plaintext source the stack used before) and drops the `:?` form for that
variable; the wrappers and the materialized files are removed with it. The
parse-time consumer is then exactly as it was found — which is also why the
inventory's record of its original mechanism matters at removal time.
