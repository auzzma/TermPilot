#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
python3 scripts/mobile/generate-design.py --check
TARGET=${1:-aarch64-apple-ios-sim}
case "$TARGET" in
  aarch64-apple-ios-sim) SDK=iphonesimulator ;;
  aarch64-apple-ios) SDK=iphoneos ;;
  *) echo 'Use aarch64-apple-ios-sim or aarch64-apple-ios' >&2; exit 2 ;;
esac
export BINDGEN_EXTRA_CLANG_ARGS="-isysroot $(xcrun --sdk "$SDK" --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export CFLAGS_aarch64_apple_ios='-miphoneos-version-min=17.0'
export CFLAGS_aarch64_apple_ios_sim='-mios-simulator-version-min=17.0'
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=8
cargo fetch --locked --target "$TARGET"
python3 scripts/build-privacy.py cargo build -p termpilot-mobile --lib --release --target "$TARGET" --locked
xcodegen generate --spec apps/ios/project.yml
if [[ "$SDK" == iphonesimulator ]]; then
  python3 scripts/build-privacy.py xcodebuild -project apps/ios/TermPilot.xcodeproj -scheme TermPilot -sdk "$SDK" -configuration Release -derivedDataPath apps/ios/.derived CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 build
else
  python3 scripts/build-privacy.py xcodebuild -project apps/ios/TermPilot.xcodeproj -scheme TermPilot -sdk "$SDK" -configuration Release -derivedDataPath apps/ios/.derived CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
fi
