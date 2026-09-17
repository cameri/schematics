#!/bin/sh
# Validates the catalog and the specs it lists. Runs in CI on every pull
# request and push to main (.github/workflows/validate.yml); run it locally
# before opening a PR.
#
#   .agent-schematics/marketplace.json  parses, unique names, sources and spec
#                                       files exist, exactly five featured,
#                                       every `composes` entry names a plugin
#   schematics/*/SCHEMATIC.md           every modules/, scripts/, skeleton/,
#                                       templates/, assets/ path it references
#                                       exists in the package
#   schematic-kind dependency pins      the pinned commit exists in this
#                                       repository, the file exists at that
#                                       commit, and its SHA-256 matches; no
#                                       floating refs (main/HEAD/master)
#
# Pin checks need the full history: a shallow clone skips them with a warning.

set -eu
cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob, hashlib, json, os, re, subprocess, sys

errors = []
warnings = []

# ─── Catalog ─────────────────────────────────────────────────────
d = json.load(open('.agent-schematics/marketplace.json'))
plugins = d['plugins']

names = [p['name'] for p in plugins]
if len(names) != len(set(names)):
    errors.append('duplicate plugin names')

for p in plugins:
    src = p['source']
    src = src[2:] if src.startswith('./') else src
    spec = p.get('spec', 'SCHEMATIC.md')
    if not os.path.isfile(os.path.join(src, spec)):
        errors.append(f"{p['name']}: missing {src}/{spec}")
    for c in p.get('composes', []):
        if c not in names:
            errors.append(f"{p['name']}: composes unknown plugin {c!r}")

featured = [p['name'] for p in plugins if p.get('featured')]
if len(featured) != 5:
    errors.append(f"featured count is {len(featured)}, must be exactly 5: {featured}")

# ─── Specs: referenced package files ─────────────────────────────
REF = re.compile(r'`((?:modules|scripts|skeleton|templates|assets)/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*)`')
specs = sorted(glob.glob('schematics/*/SCHEMATIC.md'))
for spec in specs:
    text = open(spec, encoding='utf-8').read()
    pkg = os.path.dirname(spec)
    for ref in sorted(set(REF.findall(text))):
        if not os.path.exists(os.path.join(pkg, ref)):
            errors.append(f"{spec}: references {ref}, which does not exist in the package")

# ─── Specs: schematic-kind dependency pins ───────────────────────
PIN = re.compile(r'https://github\.com/cameri/schematics/blob/([^/\s)]+)/([^)\s]+)\)\s*`sha256:([0-9a-f]{64})`')
FLOAT = re.compile(r'https://github\.com/cameri/schematics/blob/(main|HEAD|master)/')

def git(*args):
    return subprocess.run(['git', *args], capture_output=True)

in_repo = git('rev-parse', '--is-inside-work-tree').returncode == 0
shallow = in_repo and git('rev-parse', '--is-shallow-repository').stdout.strip() == b'true'
if not in_repo:
    warnings.append('not a git checkout: dependency pins were not verified')
elif shallow:
    warnings.append('shallow clone: dependency pins were not verified (fetch the full history)')

pins = 0
for spec in specs:
    text = open(spec, encoding='utf-8').read()
    for ref in FLOAT.findall(text):
        errors.append(f"{spec}: dependency link uses floating ref {ref!r}; pin a commit")
    for commit, path, digest in PIN.findall(text):
        pins += 1
        if not in_repo or shallow:
            continue
        if git('cat-file', '-e', commit + '^{commit}').returncode != 0:
            errors.append(f"{spec}: pinned commit {commit} is not in this repository ({path})")
            continue
        shown = git('show', f'{commit}:{path}')
        if shown.returncode != 0:
            errors.append(f"{spec}: {path} does not exist at commit {commit}")
            continue
        actual = hashlib.sha256(shown.stdout).hexdigest()
        if actual != digest:
            errors.append(f"{spec}: sha256 mismatch for {path} at {commit[:12]}: "
                          f"pinned {digest[:12]}, actual {actual[:12]}")

for w in warnings:
    print('WARN: ' + w)
if errors:
    print('\n'.join('FAIL: ' + e for e in errors))
    sys.exit(1)
print(f"catalog ok: {len(plugins)} entries, featured={featured}, "
      f"{len(specs)} specs, {pins} pins verified")
PY
