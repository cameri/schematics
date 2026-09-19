#!/bin/sh
# Validates the catalog and the specs it lists. Runs in CI on every pull
# request and push to main (.github/workflows/validate.yml); run it locally
# before opening a PR.
#
#   .agent-schematics/marketplace.json  parses, its $schema resolves to this
#     (the schematic catalog)             repository's own format companion
#                                       (schemas/catalog-<N>/marketplace.json.
#                                       schema), and the file conforms to what
#                                       that companion declares: required
#                                       fields, types, patterns, and no field
#                                       it does not define. Every entry is a
#                                       schematic directory, names are unique,
#                                       sources and spec files exist, exactly
#                                       five featured, every `composes` entry
#                                       names another entry
#   .claude-plugin/marketplace.json     the plugin marketplace, in the harness's
#     (the plugin marketplace)           own format: a real directory (never a
#                                       symlink, which would put the catalog at
#                                       this path), declaring that format and
#                                       listing exactly one plugin — the
#                                       authoring plugin — whose source carries
#                                       a plugin manifest. No other file in the
#                                       repository may declare that format
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

# ─── Git, and whether this checkout can be verified ──────────────
# Used by the catalog checks (which scan tracked files) and by the pin checks
# below (which resolve commits); defined once, here, because both need it early.
def git(*args):
    return subprocess.run(['git', *args], capture_output=True)

in_repo = git('rev-parse', '--is-inside-work-tree').returncode == 0
shallow = in_repo and git('rev-parse', '--is-shallow-repository').stdout.strip() == b'true'
can_verify = in_repo and not shallow
if not in_repo:
    warnings.append('not a git checkout: dependency pins were found but not verified')
elif shallow:
    warnings.append('shallow clone: dependency pins were found but not verified (fetch the full history)')

# ─── Catalog: the file and its format ────────────────────────────
# The catalog lists the schematic packages this repository publishes. It is not
# a plugin marketplace and carries no installable anything: the two are
# separate files with separate formats, and the checks below keep them
# separate. Everything about the shape of the file is resolved from its own
# $schema field — the same way a spec selects its format companion with `spec:`
# — so the format lives in one document rather than in this script's memory.
CATALOG = '.agent-schematics/marketplace.json'
d = json.load(open(CATALOG))
entries = d.get('schematics', [])
if not isinstance(entries, list):
    errors.append(f"{CATALOG}: 'schematics' is {type(entries).__name__}, must be a list")
    entries = []

OWN_SCHEMA = re.compile(r'https://schemaformat\.ai/schemas/([a-z0-9-]+)/marketplace\.json\.schema')
companion = None
declared_schema = d.get('$schema', '')
resolved = OWN_SCHEMA.fullmatch(declared_schema.strip()) if isinstance(declared_schema, str) else None
if not resolved:
    errors.append(f"{CATALOG}: $schema is {declared_schema!r}. A catalog resolves its format from "
                  f"this field, and the format is this repository's own "
                  f"(https://schemaformat.ai/schemas/catalog-1/marketplace.json.schema). A catalog "
                  f"naming another project's marketplace schema has adopted that project's format "
                  f"instead of describing its own: the plugin marketplace is the separate file "
                  f".claude-plugin/marketplace.json")
else:
    companion = f"schemas/{resolved.group(1)}/marketplace.json.schema"
    if not os.path.isfile(companion):
        errors.append(f"{CATALOG}: declares $schema revision {resolved.group(1)!r}, "
                      f"but {companion} does not exist")
        companion = None

def schema_errors(value, node, defs, where):
    """What `value` breaks in one JSON Schema document, as sentences.

    Reads the subset the companions use: $ref into $defs, const, type,
    pattern, required, properties, additionalProperties, items, minItems. A
    schema is a contract only where something enforces it, and this is the
    cheapest way to make the companion the contract rather than a description
    of one nobody reads.
    """
    out = []
    if not isinstance(node, dict):
        return out
    if '$ref' in node:
        target = defs.get(node['$ref'].rsplit('/', 1)[-1])
        if target is None:
            out.append(f"{where}: the schema references {node['$ref']}, which it does not define")
        else:
            out.extend(schema_errors(value, target, defs, where))
    if 'const' in node and value != node['const']:
        out.append(f"{where}: is {value!r}, must be {node['const']!r}")
    declared = node.get('type')
    kinds = {'object': dict, 'array': list, 'string': str, 'boolean': bool,
             'number': (int, float), 'integer': int}
    if declared and declared in kinds and not isinstance(value, kinds[declared]):
        out.append(f"{where}: is {type(value).__name__}, must be {declared}")
        return out
    if isinstance(value, str) and 'pattern' in node and not re.fullmatch(node['pattern'], value):
        out.append(f"{where}: {value!r} does not match {node['pattern']}")
    if isinstance(value, list):
        if 'minItems' in node and len(value) < node['minItems']:
            out.append(f"{where}: has {len(value)} item(s), needs at least {node['minItems']}")
        if isinstance(node.get('items'), dict):
            for i, item in enumerate(value):
                out.extend(schema_errors(item, node['items'], defs, f"{where}[{i}]"))
    if isinstance(value, dict):
        for key in node.get('required', []):
            if key not in value:
                out.append(f"{where}: has no {key!r}, which the schema requires")
        properties = node.get('properties', {})
        for key, item in value.items():
            if key in properties:
                out.extend(schema_errors(item, properties[key], defs, f"{where}.{key}"))
            elif node.get('additionalProperties') is False:
                out.append(f"{where}: has {key!r}, which the schema does not define")
    return out

if companion is not None:
    schema = json.load(open(companion))
    defs = schema.get('$defs', {})
    for problem in schema_errors(d, schema, defs, CATALOG):
        errors.append(f"{problem} ({companion})")

# ─── Catalog: what the entries must satisfy ──────────────────────
names = [p['name'] for p in entries if isinstance(p, dict) and 'name' in p]
if len(names) != len(set(names)):
    errors.append(f"{CATALOG}: duplicate entry names")

for p in entries:
    if not isinstance(p, dict) or 'name' not in p or 'source' not in p:
        continue                     # the shape is the schema check's business
    src = p['source'][2:] if p['source'].startswith('./') else p['source']
    spec = p.get('spec', 'SCHEMATIC.md')
    if not os.path.isfile(os.path.join(src, spec)):
        errors.append(f"{CATALOG}: {p['name']}: missing {src}/{spec}")
    for c in p.get('composes', []):
        if c not in names:
            errors.append(f"{CATALOG}: {p['name']}: composes unknown schematic {c!r}")

featured = [p['name'] for p in entries if p.get('featured')]
if len(featured) != 5:
    errors.append(f"featured count is {len(featured)}, must be exactly 5: {featured}")

# ─── Plugin marketplace ──────────────────────────────────────────
# The other file, and the reason the two are checked together: a symlink here
# puts the catalog at the path a plugin client reads, which advertises every
# schematic as an installable plugin. That is a wiring mistake with a
# plausible-looking symptom (the client installs something), so it is an error
# rather than a style note.
MARKETPLACE = '.claude-plugin/marketplace.json'
HARNESS_SCHEMA = 'anthropic.com/claude-code/marketplace.schema.json'
if os.path.islink('.claude-plugin'):
    errors.append(f".claude-plugin is a symlink. The plugin marketplace must be a real file: "
                  f"a symlink to the catalog puts a schematic index where a plugin client "
                  f"looks, and every schematic reads as an installable plugin")
elif not os.path.isfile(MARKETPLACE):
    errors.append(f"{MARKETPLACE}: missing. The repository's plugin marketplace lists the plugins "
                  f"it ships, and the catalog is not one of them")
else:
    try:
        market = json.load(open(MARKETPLACE))
    except ValueError as e:
        errors.append(f"{MARKETPLACE}: does not parse ({e})")
        market = None
    if market is not None:
        if HARNESS_SCHEMA not in str(market.get('$schema', '')):
            errors.append(f"{MARKETPLACE}: $schema is {market.get('$schema')!r}; a plugin "
                          f"marketplace declares the harness format it implements")
        listed = market.get('plugins')
        if not isinstance(listed, list):
            errors.append(f"{MARKETPLACE}: has no 'plugins' list")
            listed = []
        if len(listed) != 1:
            found = ', '.join(str(p.get('name')) for p in listed if isinstance(p, dict)) or 'nothing'
            errors.append(f"{MARKETPLACE}: lists {len(listed)} plugin(s) ({found}). This "
                          f"marketplace ships exactly one plugin: the repository's schematics "
                          f"are catalog entries, not plugins, and do not belong here")
        for p in listed:
            if not isinstance(p, dict) or not p.get('source'):
                continue
            src = p['source'][2:] if p['source'].startswith('./') else p['source']
            manifest = os.path.join(src, '.claude-plugin/plugin.json')
            if not os.path.isfile(manifest):
                errors.append(f"{MARKETPLACE}: {p.get('name')}: source {p['source']} carries no "
                              f"{manifest}, so nothing installs from this entry")

# ─── No other file may declare the harness marketplace format ────
# The catalog used to, by pointing its $schema at that schema while listing
# every schematic as a plugin. One file implementing the format is the whole
# point of the split, and a grep is what makes it a fact rather than a promise.
# This script names the format in the checks above, so it excludes itself.
if can_verify:
    for path in git('ls-files').stdout.decode('utf-8', 'replace').split():
        if path in (MARKETPLACE, 'scripts/validate-catalog.sh'):
            continue
        try:
            text = open(path, encoding='utf-8').read()
        except (UnicodeDecodeError, OSError):
            continue
        if HARNESS_SCHEMA in text:
            errors.append(f"{path}: declares the harness plugin-marketplace format "
                          f"({HARNESS_SCHEMA}). Only {MARKETPLACE} implements it: this repository's "
                          f"catalog of schematics is not a plugin marketplace")

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
catalog = {p['name']: p for p in entries}

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

# ─── llms.txt: every catalogued schematic is listed, inside its section ──
# llms.txt is the first file a builder's model reads, and nothing generates
# it: the two lists drifted silently until a package shipped in the catalog
# and nowhere else. The catalog is the source; llms.txt is checked against it
# here, including that each entry sits in the Schematics section rather than
# appended somewhere below it.
if os.path.exists('llms.txt'):
    llms = open('llms.txt', encoding='utf-8').read()
    lines = llms.splitlines()
    heads = [i for i, l in enumerate(lines) if l.startswith('## ')]
    start = next((i for i, l in enumerate(lines) if l.strip() == '## Schematics'), None)
    if start is None:
        errors.append("llms.txt: no '## Schematics' section")
    else:
        end = next((i for i in heads if i > start), len(lines))
        section = "\n".join(lines[start:end])
        listed = set(re.findall(
            r'\[([a-z0-9-]+)\]\(https://schemaformat\.ai/schematics/\1/SCHEMATIC\.md\)', section))
        outside = set(re.findall(
            r'\[([a-z0-9-]+)\]\(https://schemaformat\.ai/schematics/\1/SCHEMATIC\.md\)',
            "\n".join(lines[:start] + lines[end:])))
        catalogued = {p['name'] for p in entries}
        for name in sorted(catalogued - listed):
            where = " (listed outside the Schematics section)" if name in outside else ""
            errors.append(f"llms.txt: {name!r} is in the catalog but not listed in the Schematics section{where}")
        for name in sorted(listed - catalogued):
            errors.append(f"llms.txt: {name!r} is listed but is not a schematic in the catalog")
        for i, line in enumerate(lines):
            if line.count('](https://schemaformat.ai/schematics/') > 1:
                errors.append(f"llms.txt:{i + 1}: two entries on one line; they render as one")

for w in warnings:
    print('WARN: ' + w)
if errors:
    print('\n'.join('FAIL: ' + e for e in errors))
    sys.exit(1)
pin_status = (f"{pins_verified} pins verified" if can_verify
              else f"{pins_found} pins found, not verified")
print(f"frontmatter ok: {len(seen_fields)} specs checked against "
      f"schemas/spec-1/SCHEMATIC.md.schema")
print(f"catalog ok: {len(entries)} entries, featured={featured}, "
      f"{len(specs)} specs, {pin_status}")
PY
