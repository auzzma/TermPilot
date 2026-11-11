#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC="$ROOT/apps/macos"
APP="${TERMPILOT_PACKAGE_OUTPUT:-$ROOT/dist/TermPilot.app}"
# Separate acceptance output lets long-running tests keep using their immutable
# bundle. Both destinations must remain inside this checkout's distribution tree.
APP="$(python3 - "$ROOT" "$APP" <<'PY'
from pathlib import Path
import sys
root, app = (Path(value).resolve() for value in sys.argv[1:])
assert app.is_relative_to(root / 'dist') and app.name == 'TermPilot.app', 'Invalid distribution output'
print(app)
PY
)"
IDENTITY="${SIGNING_IDENTITY:--}"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo 'Unsupported macOS architecture' >&2; exit 2 ;; esac
bash "$ROOT/scripts/build-macos.sh"
BIN="$(cd "$MAC" && swift build --build-system native -c release --show-bin-path)"
python3 "$ROOT/scripts/verify-independence.py"
mkdir -p "$ROOT/dist" "$MAC/dist"
python3 "$ROOT/scripts/package-source.py" "$MAC/dist/TermPilot-CorrespondingSource.tar.gz"
# Assemble out of Finder's view: publishing an empty .app before its Info.plist
# and icon arrive lets Launch Services cache the generic application icon.
DESTINATION_APP="$APP"
STAGING_ROOT="$(mktemp -d "$ROOT/dist/.TermPilot-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/TermPilot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TermPilot" "$APP/Contents/MacOS/TermPilot"
mkdir -p "$APP/Contents/Resources/engine"
cp "$ROOT/target/release/termpilot-engine" "$APP/Contents/Resources/engine/termpilot-engine"
cp "$ROOT/engines/rdp/target/release/termpilot-rdp" "$APP/Contents/Resources/engine/termpilot-rdp"
# The linker can retain OSO object paths even with compiler prefix maps.
for executable in "$APP/Contents/MacOS/TermPilot" "$APP/Contents/Resources/engine/termpilot-engine" "$APP/Contents/Resources/engine/termpilot-rdp"; do
    xcrun strip -S "$executable"
done
# Swift back-deployment libraries must travel with the app, not resolve from Xcode.
mkdir -p "$APP/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --platform macosx \
    --scan-executable "$APP/Contents/MacOS/TermPilot" \
    --scan-executable "$APP/Contents/Resources/engine/termpilot-engine" \
    --destination "$APP/Contents/Frameworks" --sign "$IDENTITY"
# The tool may leave an unthinned signing backup; it is not a runtime library.
find "$APP/Contents/Frameworks" -type f -name '*.dylib.original' -delete
python3 - "$APP/Contents/MacOS/TermPilot" <<'PY'
import subprocess, sys
binary = sys.argv[1]
lines = subprocess.check_output(['otool', '-l', binary], text=True).splitlines()
rpaths = [lines[i + 2].strip().split(' (offset ')[0].removeprefix('path ')
          for i, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH']
for path in rpaths:
    if path.startswith('/') and path != '/usr/lib/swift' and not path.startswith('/System/'):
        subprocess.run(['install_name_tool', '-delete_rpath', path, binary], check=True)
subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', binary], check=True)
PY
cp "$MAC/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${TERMPILOT_RELEASE_VERSION:-}" ]]; then
    python3 "$ROOT/scripts/release.py" stamp-macos "$APP/Contents/Info.plist" \
        --version "$TERMPILOT_RELEASE_VERSION" --build "${TERMPILOT_BUILD_NUMBER:-1}"
fi
cp "$MAC/Resources/TermPilot.icns" "$APP/Contents/Resources/TermPilot.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/NOTICE.md" "$APP/Contents/Resources/NOTICE.md"
cp "$ROOT/engines/rust/LICENSE" "$APP/Contents/Resources/LICENSE-ISHARESCREEN.txt"
cp "$MAC/dist/TermPilot-CorrespondingSource.tar.gz" "$APP/Contents/Resources/TermPilot-CorrespondingSource.tar.gz"
python3 "$ROOT/scripts/package-licenses.py" "$APP/Contents/Resources/Licenses"
for bundle in "$BIN"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
for localization in "$MAC/Sources/TermPilotApp/Resources"/*.lproj; do
    cp -R "$localization" "$APP/Contents/Resources/"
done
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/engine/termpilot-engine"
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/engine/termpilot-rdp"
codesign --force --timestamp=none --options runtime --entitlements "$MAC/Resources/TermPilot.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/audit-privacy.py" "$APP"
# Publish only the complete, signed bundle. This destination is confined to dist.
mkdir -p "$(dirname "$DESTINATION_APP")"
rm -rf "$DESTINATION_APP"
mv "$APP" "$DESTINATION_APP"
APP="$DESTINATION_APP"
touch "$APP"
# Update only this app's cached metadata. Headless CI does not need registration.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ "${CI:-}" != "true" && -x "$LSREGISTER" ]]; then
    if ! "$LSREGISTER" -f "$APP"; then
        echo "Application packaged; Launch Services metadata refresh was unavailable." >&2
    fi
fi
echo "Built $APP ($ARCH); original installed application unchanged."
