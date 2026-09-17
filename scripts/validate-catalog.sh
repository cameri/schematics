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
#   schematics/*/SCHEMATIC.md           frontmatter: the seven fields the
#     frontmatter                       companion's § Frontmatter Fields
#                                       requires are present and well-formed
#                                       (kebab-case name equal to the package
#                                       directory, semantic version, status in
#                                       the enum, ISO dates with updated >=
#                                       created, non-empty description), and
#                                       name/description agree with the
#                                       package's .agent-schematics entry;
#                                       unknown fields warn
#   a pull request's own diff           every schematics/<name>/SCHEMATIC.md it
#                                       changes carries a bumped `updated`, and
#                                       a change to any file under
#                                       skills/schematics/ raises the plugin's
#                                       version in .claude-plugin/plugin.json
#                                       (BASE_REF=<base branch>; the workflow
#                                       sets it for pull requests only)
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
import datetime, glob, hashlib, json, os, re, subprocess, sys

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

# ─── Specs: frontmatter fields ───────────────────────────────────
# schemas/spec-<N>/SCHEMATIC.md.schema § Frontmatter Fields declares seven
# required fields. `spec:` is checked above, because the companion is resolved
# by it; the rest are checked here, values included: a field nothing enforces
# drifts, and a catalog entry that disagrees with the frontmatter it is copied
# from is worse than no entry.
FIELD = re.compile(r'^([A-Za-z_][\w-]*):[ \t]*(.*?)[ \t]*$', re.M)
KEBAB = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
SEMVER = re.compile(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
ISO_DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
STATUSES = ('draft', 'published', 'stable', 'superseded')
FIELDS = ('name', 'version', 'status', 'spec', 'description', 'created', 'updated')
catalog = {p['name']: p for p in plugins}

def parse_frontmatter(text):
    """The frontmatter fields of a SCHEMATIC.md, or None without a block."""
    block = FRONTMATTER.search(text)
    if not block:
        return None
    fields = {}
    for line in block.group(1).splitlines():
        m = FIELD.match(line)
        if not m:
            continue
        value = re.sub(r'\s+#.*$', '', m.group(2)).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
            value = value[1:-1]
        fields[m.group(1)] = value
    return fields

def is_date(value):
    """YYYY-MM-DD, and a date that exists (2026-02-30 does not)."""
    if not ISO_DATE.match(value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True

seen_fields = {}
for spec in specs:
    fields = parse_frontmatter(open(spec, encoding='utf-8').read())
    if fields is None:
        errors.append(f"{spec}: no YAML frontmatter block")
        continue
    seen_fields[spec] = fields
    pkg = os.path.basename(os.path.dirname(spec))
    for field in FIELDS:
        if not fields.get(field):
            errors.append(f"{spec}: frontmatter field {field!r} is missing or empty "
                          f"(schemas/spec-1/SCHEMATIC.md.schema, frontmatter fields)")
    undefined = sorted(set(fields) - set(FIELDS))
    if undefined:
        warnings.append(f"{spec}: frontmatter field(s) the format does not define: "
                        f"{', '.join(undefined)}")
    name, version = fields.get('name', ''), fields.get('version', '')
    status, created, updated = fields.get('status', ''), fields.get('created', ''), fields.get('updated', '')
    if name and not KEBAB.match(name):
        errors.append(f"{spec}: name {name!r} is not kebab-case")
    if name and name != pkg:
        errors.append(f"{spec}: name {name!r} does not match its directory {pkg!r}")
    if version and not SEMVER.match(version):
        errors.append(f"{spec}: version {version!r} is not a semantic version")
    if status and status not in STATUSES:
        errors.append(f"{spec}: status {status!r} is not one of {' | '.join(STATUSES)}")
    for field, value in (('created', created), ('updated', updated)):
        if value and not is_date(value):
            errors.append(f"{spec}: {field} {value!r} is not a YYYY-MM-DD date")
    if is_date(created) and is_date(updated) and updated < created:
        errors.append(f"{spec}: updated {updated} is earlier than created {created}")
    # The schema defines description as "Copied to marketplace.json": the
    # frontmatter is the source, the catalog entry the copy, and this is what
    # makes that a fact instead of an intention.
    entry = catalog.get(name)
    if entry is None:
        if name:
            warnings.append(f"{spec}: the catalog has no {name!r} entry to agree with")
    else:
        for field in ('name', 'description'):
            mine, theirs = fields.get(field, ''), entry.get(field, '')
            if mine != theirs:
                errors.append(f"{spec}: {field} differs from the {name!r} entry in "
                              f".agent-schematics/marketplace.json: frontmatter "
                              f"{mine[:48]!r}... vs catalog {theirs[:48]!r}...")
        if entry.get('version') and entry['version'] != version:
            errors.append(f"{spec}: version {version!r} differs from the {name!r} entry "
                          f"in .agent-schematics/marketplace.json ({entry['version']!r})")

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

# ─── Pull requests: the two diff-aware rules ─────────────────────
PLUGIN_DIR = 'skills/schematics/'
MANIFEST = PLUGIN_DIR + '.claude-plugin/plugin.json'

def manifest_version(text):
    """The plugin manifest's version, or None when it does not parse."""
    try:
        return json.loads(text).get('version')
    except ValueError:
        return None

def semver_key(value):
    """A comparable key, or None when the value is not a semantic version.
    Numeric parts compare as numbers, so 0.10.0 is greater than 0.9.0; a
    pre-release sorts below its release."""
    m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?', value or '')
    if not m:
        return None
    pre = m.group(4)
    if pre is None:
        pre_key = (1,)
    else:
        pre_key = (0,) + tuple((0, int(p)) if p.isdigit() else (1, p)
                               for p in pre.split('.'))
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), pre_key)

# ─── Pull requests: the two diff-aware rules ─────────────────────
# `updated` is defined as the date the spec last changed, and only the diff can
# enforce that: a spec edited without moving the field drifts silently. A plugin
# change needs its version raised for the same reason: the install is keyed by
# version. Both rules run against the pull request's merge base with its base
# branch (BASE_REF, which the workflow sets for pull requests only), never
# against a push to main, where no base branch exists — and both live inside
# the resolve test below, so that no rule runs on a base ref that did not
# resolve: a diff-aware check that cannot compute its diff reports that one
# error and nothing else.
base_ref = os.environ.get('BASE_REF', '').strip()
if not base_ref:
    warnings.append('BASE_REF unset: the updated-bump rule applies to pull requests '
                    'and was not checked (set BASE_REF=<base branch> to check it)')
elif not can_verify:
    warnings.append('BASE_REF set, but the history is not a full clone: the '
                    'updated-bump rule was not checked')
else:
    remote = base_ref if base_ref.startswith(('origin/', 'refs/')) else 'origin/' + base_ref
    if git('rev-parse', '--verify', '--quiet', remote + '^{commit}').returncode != 0:
        errors.append(f"BASE_REF {base_ref!r} does not resolve to a commit ({remote}): "
                      f"the updated-bump rule cannot be checked")
    else:
        merge_base = git('merge-base', remote, 'HEAD').stdout.decode().strip()
        changed_on = git('show', '-s', '--format=%cs', 'HEAD').stdout.decode().strip()
        # The working tree, not just HEAD: in CI they are the same commit, and
        # locally this also catches an edit that has not been committed yet.
        changed = git('diff', '--name-only', merge_base).stdout.decode().split()
        for path in changed:
            if not re.fullmatch(r'schematics/[^/]+/SCHEMATIC\.md', path):
                continue
            before = git('show', f'{merge_base}:{path}')
            if before.returncode != 0:
                continue                      # a new spec: `updated` is its creation date
            was = parse_frontmatter(before.stdout.decode('utf-8', 'replace')) or {}
            now = seen_fields.get(path, {})
            old, new = was.get('updated', ''), now.get('updated', '')
            if not is_date(old) or not is_date(new):
                continue                      # the field check already reported it
            if new < old:
                errors.append(f"{path}: updated went backwards, {old} -> {new}")
            elif new == old and old < changed_on:
                # The field is the date the spec last changed, so it has to
                # move when it is older than this change. A spec already
                # carrying the change's date needs no second bump.
                errors.append(f"{path}: SCHEMATIC.md changed on {changed_on} but updated "
                              f"is still {old}; set it to the date of this change")

        # ─── Pull requests: a plugin change carries its version ──────
        # The plugin's install is keyed by version, so a change that ships without
        # a bump claims a content set it does not have: the installed copies stay
        # stale and nothing notices until someone compares them by hand. Same base
        # ref, same pull-request-only condition as the rule above.
        changed_plugin = [p for p in changed if p.startswith(PLUGIN_DIR)]
        if changed_plugin:
            at_base = git('show', f'{merge_base}:{MANIFEST}')
            before = (manifest_version(at_base.stdout.decode('utf-8', 'replace'))
                      if at_base.returncode == 0 else None)
            after = (manifest_version(open(MANIFEST, encoding='utf-8').read())
                     if os.path.isfile(MANIFEST) else None)
            before_key, after_key = semver_key(before), semver_key(after)
            if after is None:
                errors.append(f"{MANIFEST}: no version to compare, and {len(changed_plugin)} "
                              f"file(s) under {PLUGIN_DIR} changed")
            elif before_key is None or after_key is None:
                errors.append(f"{MANIFEST}: version {after!r} (base {before!r}) is not a "
                              f"semantic version, so a bump cannot be checked")
            elif after_key < before_key:
                errors.append(f"{MANIFEST}: version went backwards, {before} -> {after}; a "
                              f"plugin change needs a greater version, not a lower one "
                              f"(this repository has exactly one version manifest, so this "
                              f"is a single-file comparison)")
            elif after_key == before_key:
                errors.append(f"{MANIFEST}: {len(changed_plugin)} file(s) under {PLUGIN_DIR} "
                              f"changed but the version is still {after} — bump it. If a "
                              f"parallel pull request already took the next number, bump "
                              f"again rather than removing this check; and note this "
                              f"repository has exactly one version manifest, so this is a "
                              f"single-file comparison")
            elif changed_plugin == [MANIFEST]:
                # A version reserved ahead of its content: odd, but harmless.
                warnings.append(f"{MANIFEST}: version raised {before} -> {after} with no "
                                f"other file under {PLUGIN_DIR} changed")

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
print(f"frontmatter ok: {len(seen_fields)} specs checked against "
      f"schemas/spec-1/SCHEMATIC.md.schema")
print(f"catalog ok: {len(plugins)} entries, featured={featured}, "
      f"{len(specs)} specs, {pin_status}")
PY
