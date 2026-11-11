#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ARCH="${TERMPILOT_MACOS_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo 'Unsupported macOS architecture' >&2; exit 2 ;; esac
python3 scripts/sync-resources.py
python3 scripts/build-privacy.py cargo build --locked --release -p termpilot-core -p termpilot-engine
python3 scripts/build-privacy.py cargo build --locked --release --manifest-path engines/rdp/Cargo.toml
python3 scripts/stamp-core.py
cd apps/macos
python3 "$ROOT/scripts/build-privacy.py" swift build --build-system native --arch "$ARCH" -c release --product TermPilot "$@"
