#!/bin/sh
# Validates .agent-schematics/marketplace.json: parses, unique names,
# sources exist, exactly five featured. Runs in CI before deploy.

set -eu
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, sys

d = json.load(open('.agent-schematics/marketplace.json'))
plugins = d['plugins']
errors = []

names = [p['name'] for p in plugins]
if len(names) != len(set(names)):
    errors.append('duplicate plugin names')

for p in plugins:
    src = p['source'].lstrip('./')
    spec = p.get('spec', 'SCHEMATIC.md')
    if not os.path.isfile(os.path.join(src, spec)):
        errors.append(f"{p['name']}: missing {src}/{spec}")

featured = [p['name'] for p in plugins if p.get('featured')]
if len(featured) != 5:
    errors.append(f"featured count is {len(featured)}, must be exactly 5: {featured}")

if errors:
    print('\n'.join('FAIL: ' + e for e in errors))
    sys.exit(1)
print(f"catalog ok: {len(plugins)} entries, featured={featured}")
PY
