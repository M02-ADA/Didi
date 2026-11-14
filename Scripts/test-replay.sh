#!/usr/bin/env bash
# One command: bash Scripts/test-replay.sh
# Optional: REPLAY_DESTINATION='platform=iOS Simulator,id=...' bash Scripts/test-replay.sh
set -euo pipefail

replay_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$replay_root"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun --find xcodebuild >/dev/null

if [[ -z "${REPLAY_DESTINATION:-}" ]]; then
  replay_devices="$(mktemp)"
  trap 'rm -f "$replay_devices"' EXIT
  xcrun simctl list devices available -j > "$replay_devices"
  REPLAY_DESTINATION="$(python3 - "$replay_devices" <<'PY'
import json, re, sys
from pathlib import Path
project = Path('Sedactive.xcodeproj/project.pbxproj').read_text()
minimum = tuple(map(int, re.search(r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);', project).group(1).split('.')))
choices = []
for runtime, devices in json.load(open(sys.argv[1]))['devices'].items():
    match = re.search(r'\.iOS-([0-9-]+)$', runtime)
    if not match:
        continue
    version = tuple(map(int, match.group(1).split('-')))
    if version < minimum:
        continue
    for device in devices:
        if device.get('isAvailable', True):
            choices.append(('iPad' in device['name'], device['state'] == 'Booted', version, device['name'], device['udid']))
if not choices:
    raise SystemExit('No compatible iOS Simulator is installed. Install one in Xcode or set REPLAY_DESTINATION.')
print('platform=iOS Simulator,id=' + max(choices)[-1])
PY
)"
fi

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination "$REPLAY_DESTINATION" \
  -derivedDataPath "${REPLAY_DERIVED_DATA:-${TMPDIR:-/tmp}/sedactive-replay-tests}" \
  -only-testing:SedactiveTests test CODE_SIGNING_ALLOWED=NO
