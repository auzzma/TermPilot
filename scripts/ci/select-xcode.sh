#!/bin/bash
set -euo pipefail
# The xcode-27 runner is an Apple silicon host running macOS 27.
# Pin the toolchain instead of following the image's changing default Xcode.
xcode_version=${TERMPILOT_XCODE_VERSION:-27}
macos_version=$(sw_vers -productVersion)
echo "Build host: macOS $macos_version ($(uname -m))"
if [[ "${GITHUB_ACTIONS:-}" == true && "$macos_version" != 27.* ]]; then
  echo "Expected the macOS 27 xcode-27 runner; found macOS $macos_version." >&2
  exit 1
fi
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
