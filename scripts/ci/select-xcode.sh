#!/bin/bash
set -euo pipefail
# Both native macOS runners currently provide this SDK; do not silently fall
# back to an older default Xcode, which may lack the iOS 26 APIs we compile.
xcode_version=${TERMPILOT_XCODE_VERSION:-26.3}
export DEVELOPER_DIR="/Applications/Xcode_${xcode_version}.app/Contents/Developer"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Required Xcode $xcode_version is absent; update the pinned runner/Xcode pair." >&2
  exit 1
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi
xcodebuild -version
swift --version
# SwiftTerm contains Metal shaders on both macOS and iOS.
xcodebuild -downloadComponent MetalToolchain
