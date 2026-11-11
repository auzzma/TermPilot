#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
python3 scripts/sync-resources.py
python3 scripts/build-privacy.py cargo build --locked --release -p termpilot-core -p termpilot-engine
python3 scripts/build-privacy.py cargo build --locked --release --manifest-path engines/rdp/Cargo.toml
python3 scripts/stamp-core.py
cd apps/macos
python3 "$ROOT/scripts/build-privacy.py" swift build --build-system native -c release --product TermPilot "$@"
