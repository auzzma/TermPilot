#!/usr/bin/env python3
"""Collect mobile installers, checksums, source and licenses in a release ZIP."""
from pathlib import Path
import hashlib
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parents[2]
platform = sys.argv[1] if len(sys.argv) == 2 else ''
if platform not in ('android', 'ios'):
    raise SystemExit('bundle.py android|ios')
version = subprocess.check_output([sys.executable, str(root/'scripts/release.py'), 'version'], text=True).strip()
folder = root/'dist/mobile'/platform
label = 'ios-ipados' if platform == 'ios' else 'android'
output = folder/f'TermPilot-{version}-{label}.zip'
required = ['LICENSE', 'NOTICE.md', 'INSTALL.txt', 'SHA256SUMS', f'TermPilot-{version}-CorrespondingSource.tar.gz']
allowed = set(required)
if platform == 'ios':
    required += [f'TermPilot-{version}-iOS-unsigned-device.zip', f'TermPilot-{version}-iOS-simulator-arm64.zip']
    allowed.update(required)
    allowed.update([f'TermPilot-{version}-Mobile.xcframework.zip', f'TermPilot-{version}-iOS-iPadOS-signed.ipa'])
else:
    for abi in ('arm64-v8a', 'x86_64'):
        apks = list(folder.glob(f'TermPilot-{version}-Android-{abi}-*.apk'))
        if len(apks) != 1 or apks[0].name not in {
            f'TermPilot-{version}-Android-{abi}-test.apk', f'TermPilot-{version}-Android-{abi}-signed.apk',
        }:
            raise SystemExit('Expected exactly one APK for '+abi+'; use a clean output directory')
        required.append(apks[0].name)
        allowed.add(apks[0].name)
for name in required:
    if not (folder/name).is_file():
        raise SystemExit('Missing mobile artifact: '+name)
# Only package.py products are admitted; do not collect a stale package or logs.
checksums = {}
for line in (folder/'SHA256SUMS').read_text().splitlines():
    digest, name = line.split('  ', 1)
    if Path(name).name != name or name not in allowed or name == 'SHA256SUMS':
        raise SystemExit('Invalid checksum filename')
    checksums[name] = digest
    if hashlib.sha256((folder/name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Mobile artifact checksum mismatch: '+name)
if not (set(required) - {'SHA256SUMS'}) <= checksums.keys():
    raise SystemExit('Required mobile artifacts are absent from the checksum manifest')
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(checksums.keys() | {'SHA256SUMS'}):
        archive.write(folder/name, f'TermPilot/{name}')
    for path in sorted((folder/'Licenses').rglob('*')):
        if path.is_file():
            archive.write(path, 'TermPilot/'+path.relative_to(folder).as_posix())
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix('.zip.sha256').write_text(digest+'  '+output.name+'\n')
print(output)
