#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
selection=$(mktemp -d "${TMPDIR:-/tmp}/termpilot-sim-tests.XXXXXX")
cleanup() {
  if [[ -f "$selection/created" ]]; then
    while IFS= read -r device; do
      xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
      xcrun simctl delete "$device" >/dev/null 2>&1 || true
    done < "$selection/created"
  fi
  rm -rf "$selection"
}
trap cleanup EXIT
python3 - "$selection" <<'PY'
import json, os
from pathlib import Path
import subprocess, sys

def command(*args):
    return subprocess.check_output(args, text=True).strip()

folder=Path(sys.argv[1])
state=json.loads(command('xcrun','simctl','list','--json'))
def version(value):
    return tuple(int(p) for p in value.split('.'))
sdk=version(command('xcrun','--sdk','iphonesimulator','--show-sdk-version'))
runtimes=[r for r in state['runtimes'] if r.get('isAvailable') and '.iOS-' in r['identifier'] and (17,) <= version(r['version']) <= sdk]
if not runtimes: raise SystemExit('No compatible iOS Simulator runtime installed for the selected Xcode')
runtime=max(runtimes,key=lambda r:version(r['version']))['identifier']
selected=[]
for family in ('iPhone','iPad'):
    if os.environ.get('GITHUB_ACTIONS')=='true':
        types=[t for t in state['devicetypes'] if t.get('productFamily')==family]
        if not types: raise SystemExit('No simulator device type for '+family)
        # Device types are listed by release; the newest is supported by this SDK.
        device=command('xcrun','simctl','create','TermPilot CI '+family,types[-1]['identifier'],runtime)
        with (folder/'created').open('a') as handle: handle.write(device+'\n')
    else:
        devices=[d for d in state['devices'].get(runtime,[]) if d.get('isAvailable') and family in d.get('deviceTypeIdentifier','')]
        if not devices: raise SystemExit('Create an available '+family+' simulator with the selected Xcode first')
        device=devices[0]['udid']
    selected.append(device)
(folder/'devices').write_text('\n'.join(selected)+'\n')
PY
while IFS= read -r device; do
  python3 scripts/build-privacy.py xcodebuild -project apps/ios/TermPilot.xcodeproj -scheme TermPilot \
    -configuration Release -destination "platform=iOS Simulator,id=$device" \
    -destination-timeout 120 -collect-test-diagnostics never \
    -derivedDataPath apps/ios/.derived CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
    ENABLE_TESTABILITY=YES ARCHS=arm64 test
done < "$selection/devices"
