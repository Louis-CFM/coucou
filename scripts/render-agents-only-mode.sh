#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-focus-render.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/FocusRender.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj"
python3 - "$APP" <<'PY'
import json, plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'local.coucou-focus-control-render', 'CFBundleExecutable': 'FocusRender',
                  'CFBundlePackageType': 'APPL'}, f)
catalog = json.loads(Path('NotchBuddy/Resources/Localizable.xcstrings').read_text())['strings']
lines = []
for key, entry in catalog.items():
    if key.startswith('focus.'):
        value = entry['localizations']['en']['stringUnit']['value']
        lines.append(f'{json.dumps(key)} = {json.dumps(value)};')
(app / 'Contents/Resources/en.lproj/Localizable.strings').write_text('\n'.join(lines))
PY
swiftc -swift-version 6 -warnings-as-errors \
    NotchBuddy/Sources/App/AgentsOnlyModeControl.swift tests/AgentsOnlyModeRender.swift \
    -o "$APP/Contents/MacOS/FocusRender"
mkdir -p docs/media
"$APP/Contents/MacOS/FocusRender" "$PWD/docs/media/agents-only-settings.png"
