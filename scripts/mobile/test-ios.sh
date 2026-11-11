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
python3 scripts/mobile/select-ios-simulators.py "$selection"
while IFS= read -r device; do
  python3 scripts/build-privacy.py xcodebuild -project apps/ios/TermPilot.xcodeproj -scheme TermPilot \
    -configuration Release -destination "platform=iOS Simulator,id=$device" \
    -destination-timeout 120 -collect-test-diagnostics never \
    -derivedDataPath apps/ios/.derived CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
    ENABLE_TESTABILITY=YES 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' ARCHS=arm64 test "$@"
done < "$selection/devices"
