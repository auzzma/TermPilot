#!/usr/bin/env python3
"""Stage the shared C header; remove obsolete generated interpreter resources."""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / 'apps/macos'
resources = MAC / 'Sources/TermPilotApp/Resources'
for name in ('ssh2-bridge', 'sftp-bridge', 'proxy-bridge', 'keygen'):
    destination = resources / name
    if destination.exists(): shutil.rmtree(destination)
for generated in resources.glob('screen-sharing-*.py'):
    generated.unlink()
destination = MAC / 'ThirdParty/iShareScreen'
if destination.exists(): shutil.rmtree(destination)
headers = MAC / 'Sources/CTermPilotCore/include'
headers.mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT / 'bindings/c/termpilot_core.h', headers / 'termpilot_core.h')
print('Shared C header staged; runtime code is packaged from the Rust release build.')

# SwiftPM can leave deleted resources in an incremental output bundle.
# These generated files are retired engine entry points, never user assets.
for bundle in (MAC / '.build').glob('*/*/TermPilot_TermPilotApp.bundle'):
    for extension in ('*.py', '*.cjs'):
        for obsolete in bundle.rglob(extension): obsolete.unlink()
