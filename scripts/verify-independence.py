#!/usr/bin/env python3
"""Check only this checkout: no sibling project or installed app is required."""
import os
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1]
SKIP = {'.git', 'target', 'Vendor', 'node_modules', 'bin', 'obj', 'dist',
        '.runtime-cache', '.release-staging', '.swiftpm', '__pycache__', '.tools', '.derived', '.gradle', '.generated', 'build'}
errors = []
count = 0
source_suffixes = {'.rs', '.swift', '.cs', '.csproj', '.toml', '.sh', '.ps1', '.py', '.cjs', '.json', '.yml', '.ts', '.tsx', '.js', '.css'}
for directory, dirs, files in os.walk(ROOT):
    for name in dirs:
        path = Path(directory) / name
        if path.is_symlink() and not path.resolve().is_relative_to(ROOT):
            errors.append(f'External directory symlink: {path.relative_to(ROOT)}')
    dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith('.build')]
    for name in files:
        path = Path(directory) / name
        relative = path.relative_to(ROOT)
        if path.is_symlink():
            if not path.resolve().is_relative_to(ROOT): errors.append(f'External symlink: {relative}')
            continue
        if path.suffix not in source_suffixes or relative.parts[0] == 'docs' or name == Path(__file__).name: continue
        content = path.read_text(errors='replace')
        # Provenance documentation may name old projects; executable code may not.
        if 'TermPilot-Swift' in content or 'TermPilot-Tauri' in content:
            errors.append(f'Sibling project reference: {relative}')
        count += 1
for production in ('engines/node', 'engines/screen-sharing'):
    if (ROOT / production).exists(): errors.append(f'Retired production engine: {production}')
resources = ROOT / 'apps/macos/Sources/TermPilotApp/Resources'
for extension in ('*.cjs', '*.py'):
    for path in resources.rglob(extension): errors.append(f'Retired executable resource: {path.relative_to(ROOT)}')
for folder in ('apps/windows', 'bindings', 'crates', 'scripts'):
    for path in (ROOT/folder).rglob('*'):
        if not path.is_file() or path.suffix not in source_suffixes or any(p in SKIP for p in path.parts): continue
        if path.name == Path(__file__).name: continue
        content = path.read_text(errors='replace')
        if any(old in content for old in ('engines/node/', 'engines/screen-sharing/', 'tests/legacy-engines/')):
            errors.append(f'Production dependency on retired engine: {path.relative_to(ROOT)}')
info = plistlib.loads((ROOT/'apps/macos/Resources/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'com.termpilot.app': errors.append('macOS app identity must be com.termpilot.app')
vault = (ROOT/'apps/macos/Sources/TermPilotPersistence/VaultStore.swift').read_text()
if 'root.appendingPathComponent("TermPilot"' not in vault: errors.append('macOS data directory must be TermPilot')
if errors: raise SystemExit('\n'.join(errors))
print(f'Independent checkout verified: {count} source/configuration files; no sibling references; consistent TermPilot identity.')
