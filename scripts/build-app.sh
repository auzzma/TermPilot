#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/TermPilot.app"
STAGING_DIR="$ROOT/.release-staging"
SOURCE_INFO_PLIST="$ROOT/Resources/Info.plist"
SOURCE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$SOURCE_INFO_PLIST")"
SOURCE_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$SOURCE_INFO_PLIST")"
VERSION="${1:-${TERMPILOT_VERSION:-$SOURCE_VERSION}}"
BUILD_NUMBER="${2:-${TERMPILOT_BUILD_NUMBER:-$SOURCE_BUILD_NUMBER}}"
ARTIFACT_PREFIX="TermPilot-${VERSION}-build${BUILD_NUMBER}"
ARM64_ZIP="$DIST_DIR/${ARTIFACT_PREFIX}-arm64.zip"
X64_ZIP="$DIST_DIR/${ARTIFACT_PREFIX}-x86_64.zip"
UNIVERSAL_ZIP="$DIST_DIR/${ARTIFACT_PREFIX}-universal.zip"
CHECKSUMS="$DIST_DIR/SHA256SUMS.txt"
IDENTITY="${SIGNING_IDENTITY:--}"
ARM_BUILD="$ROOT/.build-arm64"
X64_BUILD="$ROOT/.build-x86_64"
BRIDGE_RUNTIME_SOURCE="$ROOT/Vendor/ssh2-bridge-runtime"
NODE_ENTITLEMENTS="$ROOT/Resources/NodeRuntime.entitlements.plist"
APP_ICON="$ROOT/Resources/TermPilot.icns"
BUILD_PATH_MAP_FLAGS=(
  -Xswiftc -enable-experimental-concise-pound-file
  -Xcc "-fmacro-prefix-map=$ROOT=TermPilot"
)
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0=/dev/null
export COPYFILE_DISABLE=1

if [[ "$#" -gt 2 ]]; then
  echo "Usage: $0 [version] [build-number]" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must use major.minor.patch format: $VERSION" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Build number must be a non-negative integer: $BUILD_NUMBER" >&2
  exit 2
fi

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT"

if [[ "${TERMPILOT_PREPARE_SSH2_BRIDGE_RUNTIME:-1}" != "0" ]]; then
  bash "$ROOT/scripts/prepare-ssh2-bridge-runtime.sh"
fi

if [[ ! -x "$BRIDGE_RUNTIME_SOURCE/node/bin/node" ]]; then
  echo "Missing bundled Node runtime: $BRIDGE_RUNTIME_SOURCE/node/bin/node" >&2
  echo "Run scripts/prepare-ssh2-bridge-runtime.sh or unset TERMPILOT_PREPARE_SSH2_BRIDGE_RUNTIME=0." >&2
  exit 1
fi
if [[ ! -d "$BRIDGE_RUNTIME_SOURCE/node_modules/ssh2" ]]; then
  echo "Missing bundled ssh2 dependency: $BRIDGE_RUNTIME_SOURCE/node_modules/ssh2" >&2
  echo "Run scripts/prepare-ssh2-bridge-runtime.sh or unset TERMPILOT_PREPARE_SSH2_BRIDGE_RUNTIME=0." >&2
  exit 1
fi
if [[ ! -f "$APP_ICON" ]]; then
  echo "Missing application icon: $APP_ICON" >&2
  exit 1
fi

SCAN_NODE="$BRIDGE_RUNTIME_SOURCE/node/bin/node"

scan_payload() {
  TERMPILOT_SCAN_USER="$(id -un)" \
    TERMPILOT_SCAN_HOME="$HOME" \
    TERMPILOT_SCAN_HOSTNAME="$(hostname)" \
    TERMPILOT_SCAN_COMPUTER_NAME="$(scutil --get ComputerName 2>/dev/null || true)" \
    TERMPILOT_SCAN_PROJECT_PATH="$ROOT" \
    "$SCAN_NODE" "$ROOT/scripts/scan-release-payload.mjs" "$@"
}

sha256_file() {
  local output
  output="$(openssl dgst -sha256 -r "$1")"
  printf '%s' "${output%% *}"
}

verify_runtime_allowlist() {
  local forbidden
  for forbidden in \
    "node_modules/ssh2/test" \
    "node_modules/ssh2/examples" \
    "node_modules/ssh2/util" \
    "node_modules/ssh2/lib/protocol/crypto/build" \
    "node_modules/ssh2/lib/protocol/crypto/src" \
    "node_modules/ssh2/lib/protocol/crypto/binding.gyp"
  do
    if [[ -e "$BRIDGE_RUNTIME_SOURCE/$forbidden" ]]; then
      echo "Bundled runtime contains a forbidden development path: $forbidden" >&2
      exit 1
    fi
  done
}

verify_runtime_allowlist
scan_payload "$BRIDGE_RUNTIME_SOURCE"

assemble_app() {
  local app="$1"
  local executable="$2"
  local node_arch="$3"
  local resource_bin_dir="$4"
  local contents="$app/Contents"
  local bridge_runtime_dest="$contents/Resources/ssh2-bridge-runtime"
  local node_binary="$bridge_runtime_dest/node/bin/node"

  rm -rf "$app"
  mkdir -p "$contents/MacOS" "$contents/Resources"
  cp "$executable" "$contents/MacOS/TermPilot"
  chmod 755 "$contents/MacOS/TermPilot"
  strip -S -x "$contents/MacOS/TermPilot"
  cp "$ROOT/Resources/Info.plist" "$contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$VERSION" \
    "$contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" \
    "$contents/Info.plist"
  cp "$APP_ICON" "$contents/Resources/TermPilot.icns"

  for localization in "$ROOT/Sources/TermPilotApp/Resources"/*.lproj; do
    if [[ -d "$localization" ]]; then
      cp -R "$localization" "$contents/Resources/"
    fi
  done
  for bundle in "$resource_bin_dir"/*.bundle; do
    if [[ -d "$bundle" \
      && "$(basename "$bundle")" != "TermPilot_TermPilotTerminal.bundle" ]]; then
      cp -R "$bundle" "$contents/Resources/"
    fi
  done
  cp -R "$BRIDGE_RUNTIME_SOURCE" "$bridge_runtime_dest"

  if [[ -n "$node_arch" ]]; then
    lipo "$node_binary" \
      -thin "$node_arch" \
      -output "$node_binary.thin"
    mv "$node_binary.thin" "$node_binary"
    chmod 755 "$node_binary"
  fi

  chmod -R u+w "$app"
  xattr -cr "$app"
  codesign --remove-signature "$node_binary" 2>/dev/null || true
  codesign \
    --force \
    --timestamp=none \
    --options runtime \
    --entitlements "$NODE_ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$node_binary"

  codesign \
    --force \
    --timestamp=none \
    --options runtime \
    --sign "$IDENTITY" \
    "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
}

verify_binary_architecture() {
  local binary="$1"
  local expected="$2"
  local actual
  actual="$(lipo -archs "$binary")"

  if [[ "$expected" == "universal" ]]; then
    if [[ "$actual" != "arm64 x86_64" && "$actual" != "x86_64 arm64" ]]; then
      echo "Expected Universal binary, found: $actual ($binary)" >&2
      exit 1
    fi
  elif [[ "$actual" != "$expected" ]]; then
    echo "Expected $expected binary, found: $actual ($binary)" >&2
    exit 1
  fi
}

verify_app_architecture() {
  local app="$1"
  local expected="$2"
  verify_binary_architecture "$app/Contents/MacOS/TermPilot" "$expected"
  verify_binary_architecture \
    "$app/Contents/Resources/ssh2-bridge-runtime/node/bin/node" \
    "$expected"
}

create_zip() {
  local app="$1"
  local output="$2"
  rm -f "$output"
  (
    cd "$(dirname "$app")"
    COPYFILE_DISABLE=1 zip -qry -X "$output" "$(basename "$app")"
  )
}

swift build \
  --disable-sandbox \
  --scratch-path "$ARM_BUILD" \
  --configuration release \
  --product TermPilot \
  --arch arm64 \
  "${BUILD_PATH_MAP_FLAGS[@]}"

swift build \
  --disable-sandbox \
  --scratch-path "$X64_BUILD" \
  --configuration release \
  --product TermPilot \
  --arch x86_64 \
  "${BUILD_PATH_MAP_FLAGS[@]}"

ARM_BIN_DIR="$(
  swift build \
    --disable-sandbox \
    --scratch-path "$ARM_BUILD" \
    --configuration release \
    --show-bin-path \
    --arch arm64
)"
X64_BIN_DIR="$(
  swift build \
    --disable-sandbox \
    --scratch-path "$X64_BUILD" \
    --configuration release \
    --show-bin-path \
    --arch x86_64
)"

rm -rf "$STAGING_DIR"
mkdir -p "$DIST_DIR" "$STAGING_DIR"
rm -f \
  "$DIST_DIR/TermPilot.zip" \
  "$ARM64_ZIP" \
  "$X64_ZIP" \
  "$UNIVERSAL_ZIP" \
  "$CHECKSUMS"

UNIVERSAL_BINARY="$STAGING_DIR/TermPilot-universal"
lipo -create \
  "$ARM_BIN_DIR/TermPilot" \
  "$X64_BIN_DIR/TermPilot" \
  -output "$UNIVERSAL_BINARY"

ARM64_APP="$STAGING_DIR/arm64/TermPilot.app"
X64_APP="$STAGING_DIR/x86_64/TermPilot.app"

assemble_app "$APP" "$UNIVERSAL_BINARY" "" "$ARM_BIN_DIR"
assemble_app "$ARM64_APP" "$ARM_BIN_DIR/TermPilot" "arm64" "$ARM_BIN_DIR"
assemble_app "$X64_APP" "$X64_BIN_DIR/TermPilot" "x86_64" "$ARM_BIN_DIR"

verify_app_architecture "$APP" universal
verify_app_architecture "$ARM64_APP" arm64
verify_app_architecture "$X64_APP" x86_64
for built_app in "$APP" "$ARM64_APP" "$X64_APP"; do
  [[ "$(plutil -extract CFBundleShortVersionString raw \
    "$built_app/Contents/Info.plist")" == "$VERSION" ]]
  [[ "$(plutil -extract CFBundleVersion raw \
    "$built_app/Contents/Info.plist")" == "$BUILD_NUMBER" ]]
done
scan_payload "$APP" "$ARM64_APP" "$X64_APP"

create_zip "$APP" "$UNIVERSAL_ZIP"
create_zip "$ARM64_APP" "$ARM64_ZIP"
create_zip "$X64_APP" "$X64_ZIP"

VERIFY_DIR="$STAGING_DIR/verification"
mkdir -p "$VERIFY_DIR/universal" "$VERIFY_DIR/arm64" "$VERIFY_DIR/x86_64"
unzip -q "$UNIVERSAL_ZIP" -d "$VERIFY_DIR/universal"
unzip -q "$ARM64_ZIP" -d "$VERIFY_DIR/arm64"
unzip -q "$X64_ZIP" -d "$VERIFY_DIR/x86_64"
scan_payload \
  "$VERIFY_DIR/universal" \
  "$VERIFY_DIR/arm64" \
  "$VERIFY_DIR/x86_64"

for archive in "$UNIVERSAL_ZIP" "$ARM64_ZIP" "$X64_ZIP"; do
  if unzip -Z1 "$archive" | grep -Eq '(^|/)\._|^__MACOSX/'; then
    echo "Archive contains AppleDouble metadata: $archive" >&2
    exit 1
  fi
done

: >"$CHECKSUMS"
for archive in "$ARM64_ZIP" "$X64_ZIP" "$UNIVERSAL_ZIP"; do
  printf '%s  %s\n' \
    "$(sha256_file "$archive")" \
    "$(basename "$archive")" \
    >>"$CHECKSUMS"
done
while read -r expected filename; do
  actual="$(sha256_file "$DIST_DIR/$filename")"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA-256 verification failed for $filename" >&2
    exit 1
  fi
  echo "$filename: OK"
done <"$CHECKSUMS"

for artifact in \
  "$APP" \
  "$ARM64_ZIP" \
  "$X64_ZIP" \
  "$UNIVERSAL_ZIP" \
  "$CHECKSUMS"
do
  xattr -rc "$artifact"
done

echo "Built $APP"
echo "Built $ARM64_ZIP"
echo "Built $X64_ZIP"
echo "Built $UNIVERSAL_ZIP"
echo "Built $CHECKSUMS"
echo "Version $VERSION ($BUILD_NUMBER)"
