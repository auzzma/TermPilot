#!/usr/bin/env python3
"""Make SwiftPM relink when the external Rust static library changes."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
library=root/'target/release/libtermpilot_core.a'
stamp=root/'apps/macos/Sources/TermPilotCore/CoreBuildStamp.swift'
content='// Generated from the local Rust library; do not edit.\ninternal let termPilotCoreBuildDigest = "'+hashlib.sha256(library.read_bytes()).hexdigest()+'"\n'
if not stamp.exists() or stamp.read_text()!=content:stamp.write_text(content)
