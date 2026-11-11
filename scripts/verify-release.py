#!/usr/bin/env python3
"""Audit the distributable, and run its Rust worker without development runtimes."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tarfile

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
assert app.is_relative_to(root / 'dist'), 'Only checkout distribution outputs are audited'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.termpilot.app'
assert info['CFBundleExecutable'] == 'TermPilot'
for path in app.rglob('*'):
    if path.is_symlink():
        assert path.resolve().is_relative_to(app), f'External runtime symlink: {path}'
    if not path.is_file():
        continue
    assert path.suffix not in {'.py', '.pyc', '.cjs', '.mjs', '.node'}, f'Retired runtime: {path}'
    assert path.name not in {'node', 'node.exe', 'node_modules', 'python', 'python3', 'python.exe'}, f'Interpreter: {path}'
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'):
        continue
    libraries = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    for line in libraries:
        library = line.strip().split(' (')[0]
        assert library.startswith(('/System/', '/usr/lib/', '@rpath/', '@loader_path/', '@executable_path/')), f'Nonportable library: {library}'
    commands = subprocess.check_output(['otool', '-l', str(path)], text=True).splitlines()
    for i, line in enumerate(commands):
        if line.strip() == 'cmd LC_RPATH':
            value = commands[i + 2].strip().split(' (offset ')[0].removeprefix('path ')
            assert value.startswith(('/usr/lib/swift', '/System/', '@')), f'Development rpath: {value}'
resources = app / 'Contents/Resources'
for required in ('LICENSE.txt', 'LICENSE-ISHARESCREEN.txt', 'NOTICE.md', 'TermPilot-CorrespondingSource.tar.gz', 'Licenses/dependencies.json'):
    assert (resources / required).is_file(), f'Missing distribution notice/source: {required}'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
engine = resources / 'engine/termpilot-engine'
env = {'PATH': '/usr/bin:/bin', 'HOME': os.environ['HOME'], 'LANG': 'en_US.UTF-8'}
config = {'keyType': 'ed25519', 'comment': 'release-audit', 'passphrase': 'synthetic-release-audit'}
probe = subprocess.run([str(engine), 'keygen'], input=json.dumps(config)+"\n", text=True, capture_output=True, env=env, timeout=20)
assert probe.returncode == 0, 'Packaged worker failed with clean runtime environment'
pair = json.loads(probe.stdout)
assert pair['privateKey'].startswith('-----BEGIN OPENSSH PRIVATE KEY-----')
assert pair['publicKey'].startswith('ssh-ed25519 ')
logical = sum(p.stat().st_size for p in app.rglob('*') if p.is_file())
disk = int(subprocess.check_output(['du', '-sk', str(app)], text=True).split()[0]) * 1024
report = dict(passed=True, artifact=str(app), logical_bytes=logical, disk_bytes=disk,
              engine_sha256=hashlib.sha256(engine.read_bytes()).hexdigest(),
              logical_mib=round(logical/1024**2, 2), disk_mib=round(disk/1024**2, 2),
              checks=['TermPilot identity', 'No Node/Python runtime or engine scripts',
                      'System/relative Mach-O dependencies only', 'Source and licenses present',
                      'Strict nested code signature', 'Packaged key generation with system-only PATH'],
              boundary='Environment isolation is not a clean-machine GUI acceptance test')
# A long run may finish while independent SSH/UI fixes are being built. Record
# exact binary identity separately from screen/media source identity; matching
# sources do not mean the final binary itself completed the long run.
provenance = root / 'validation/rust-hp-stability-build.json'
if provenance.is_file():
    long_run = json.loads(provenance.read_text())
    expected = long_run.get('high_performance_sources', {})
    with tarfile.open(resources / 'TermPilot-CorrespondingSource.tar.gz', 'r:gz') as archive:
        actual = {}
        for name in expected:
            source = archive.extractfile('TermPilot/' + name)
            assert source is not None, f'Missing corresponding source: {name}'
            actual[name] = hashlib.sha256(source.read()).hexdigest()
    report['high_performance_sources_match_long_run'] = bool(expected) and actual == expected
    report['long_run_engine_sha256'] = long_run['engine_sha256']
    report['long_run_binary_matches'] = report['engine_sha256'] == long_run['engine_sha256']
report_path = root / 'validation/rust-release.json'
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
