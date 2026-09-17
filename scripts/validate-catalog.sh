#!/bin/sh
# Validates the catalog and the specs it lists. Runs in CI on every pull
# request and push to main (.github/workflows/validate.yml); run it locally
# before opening a PR.
#
#   .agent-schematics/marketplace.json  parses, unique names, sources and spec
#                                       files exist, exactly five featured,
#                                       every `composes` entry names a plugin
#   schematics/*/SCHEMATIC.md           declares a spec: revision whose
#                                       schemas/spec-<N>/SCHEMATIC.md.schema
#                                       companion exists; every modules/,
#                                       scripts/, skeleton/, templates/,
#                                       assets/ path it references exists in
#                                       the package
#   schematic-kind dependency pins      every link into this repository is a
#                                       well-formed pin: [<name> v<version>](
#                                       .../blob/<commit-sha>/schematics/<name>/
#                                       SCHEMATIC.md) `sha256:<hex>`; the sha is
#                                       a commit reachable from the checked-out
#                                       history (not a tag or branch name), the
#                                       file exists at that commit, its SHA-256
#                                       matches, and the link's name and version
#                                       match the pinned file's frontmatter
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
# A package path anywhere in the text (prose, code spans, or code blocks), not
# only directly after a backtick. Segments may not end in '.', so a path at
# the end of a sentence is matched without its full stop.
SEG = r'[A-Za-z0-9._-]*[A-Za-z0-9_-]'
REF = re.compile(r'(?<![\w/.-])((?:modules|scripts|skeleton|templates|assets)/(?:' + SEG + r'/)*' + SEG + r')')
specs = sorted(glob.glob('schematics/*/SCHEMATIC.md'))

# ─── Specs: declared format revision ─────────────────────────────
# A spec's `spec:` frontmatter field selects its format companion, so it must
# be present and the companion must exist. The catalog resolves the companion
# by this field; without it, a reader cannot tell which revision a spec claims.
# An inline YAML comment after the value is allowed: the template and the
# companion both write one.
FRONTMATTER = re.compile(r'^---\s*\n(.*?)\n---\s*$', re.S | re.M)
SPEC_REVISION = re.compile(r'^spec:\s*([^\s#]+)\s*(?:#.*)?$', re.M)
for spec in specs:
    fm = FRONTMATTER.search(open(spec, encoding='utf-8').read())
    declared = SPEC_REVISION.search(fm.group(1)) if fm else None
    if not declared:
        errors.append(f"{spec}: frontmatter declares no spec: revision")
        continue
    companion = f'schemas/spec-{declared.group(1)}/SCHEMATIC.md.schema'
    if not os.path.isfile(companion):
        errors.append(f"{spec}: declares spec: {declared.group(1)}, "
                      f"but {companion} does not exist")

for spec in specs:
    text = open(spec, encoding='utf-8').read()
    pkg = os.path.dirname(spec)
    for ref in sorted(set(REF.findall(text))):
        if not os.path.exists(os.path.join(pkg, ref)):
            errors.append(f"{spec}: references {ref}, which does not exist in the package")

# ─── Specs: required sections ────────────────────────────────────
# The format companion (schemas/spec-1/SCHEMATIC.md.schema, § Required
# Sections) lists the sections every SCHEMATIC.md carries, in order, and the
# title plus the ten binding principles are part of that list. A spec that
# omits one, or replaces it with a pointer at another file, is not the
# self-contained package the format promises — and nothing else in this
# script would notice.
REQUIRED_SECTIONS = (
    'applicable context',
    'scope',
    'requirements',
    'design principles',
    'dependencies',
    'parameters',
    'modules',
    'interfaces and contracts',
    'implementation phases',
    'verification and acceptance',
    'failure modes and rollback',
    'removal',
    'decisions and open questions',
)
SECTION_HEADING = re.compile(r'^##\s*(?:\d+\.\s*)?(.+?)\s*$', re.M)
for spec in specs:
    headings = [h.lower() for h in SECTION_HEADING.findall(open(spec, encoding='utf-8').read())]
    position = -1
    for wanted in REQUIRED_SECTIONS:
        found = next((i for i, h in enumerate(headings) if i > position and wanted in h), None)
        if found is None:
            errors.append(f"{spec}: no {wanted!r} section in the required order "
                          f"(schemas/spec-1/SCHEMATIC.md.schema, required sections)")
            break
        position = found

# ─── Specs: schematic-kind dependency pins ───────────────────────
# Any link into this repository's blob/ tree is a dependency pin and must have
# exactly this shape; anything else on such a line is a malformed pin.
PIN = re.compile(
    r'\[([a-z0-9-]+) v([0-9][0-9A-Za-z.+-]*)\]'
    r'\(https://github\.com/cameri/schematics/blob/([^/\s)]+)/(schematics/([a-z0-9-]+)/SCHEMATIC\.md)\)'
    r' `sha256:([0-9a-f]{64})`')
LINK = re.compile(r'https://github\.com/cameri/schematics/blob/')
HEX = re.compile(r'^[0-9a-f]{7,40}$')

def git(*args):
    return subprocess.run(['git', *args], capture_output=True)

in_repo = git('rev-parse', '--is-inside-work-tree').returncode == 0
shallow = in_repo and git('rev-parse', '--is-shallow-repository').stdout.strip() == b'true'
can_verify = in_repo and not shallow
if not in_repo:
    warnings.append('not a git checkout: dependency pins were found but not verified')
elif shallow:
    warnings.append('shallow clone: dependency pins were found but not verified (fetch the full history)')

pins_found = 0
pins_verified = 0
for spec in specs:
    for lineno, line in enumerate(open(spec, encoding='utf-8'), 1):
        links = len(LINK.findall(line))
        if not links:
            continue
        matches = PIN.findall(line)
        if len(matches) != links:
            errors.append(f"{spec}:{lineno}: malformed dependency pin; expected "
                          "[<name> v<version>](https://github.com/cameri/schematics/blob/<commit-sha>/"
                          "schematics/<name>/SCHEMATIC.md) `sha256:<64 hex>`")
            continue
        for name, version, ref, path, dirname, digest in matches:
            pins_found += 1
            if name != dirname:
                errors.append(f"{spec}:{lineno}: pin text names {name!r} but links to {path}")
            if not HEX.match(ref):
                errors.append(f"{spec}:{lineno}: pin uses ref {ref!r}; pin a commit sha, not a tag or branch")
                continue
            if not can_verify:
                continue
            resolved = git('rev-parse', '--verify', '--quiet', ref + '^{commit}').stdout.decode().strip()
            if not resolved or not resolved.startswith(ref):
                errors.append(f"{spec}:{lineno}: pinned commit {ref} is not a commit in this repository ({path})")
                continue
            if git('merge-base', '--is-ancestor', resolved, 'HEAD').returncode != 0:
                errors.append(f"{spec}:{lineno}: pinned commit {ref} is not reachable from the checked-out history ({path})")
                continue
            shown = git('show', f'{resolved}:{path}')
            if shown.returncode != 0:
                errors.append(f"{spec}:{lineno}: {path} does not exist at commit {ref}")
                continue
            actual = hashlib.sha256(shown.stdout).hexdigest()
            if actual != digest:
                errors.append(f"{spec}:{lineno}: sha256 mismatch for {path} at {ref[:12]}: "
                              f"pinned {digest[:12]}, actual {actual[:12]}")
                continue
            fm = re.search(r'^version:\s*(\S+)', shown.stdout.decode('utf-8', 'replace'), re.M)
            pinned_version = fm.group(1) if fm else None
            if pinned_version != version:
                errors.append(f"{spec}:{lineno}: pin text says {name} v{version} but the file at {ref[:12]} "
                              f"is version {pinned_version}")
                continue
            pins_verified += 1

for w in warnings:
    print('WARN: ' + w)
if errors:
    print('\n'.join('FAIL: ' + e for e in errors))
    sys.exit(1)
pin_status = (f"{pins_verified} pins verified" if can_verify
              else f"{pins_found} pins found, not verified")
print(f"catalog ok: {len(plugins)} entries, featured={featured}, "
      f"{len(specs)} specs, {pin_status}")
PY
