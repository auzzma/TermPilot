#!/usr/bin/env python3
"""Reject machine paths/user data in releases, including nested source archives.

Diagnostics contain filenames and finding categories, never matched contents.
Development signatures are an explicit exception, not an anonymized signature.
"""
import argparse
import io
import json
from pathlib import Path
import re
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HOME_PATH = re.compile(rb'(?:/Users/[A-Za-z0-9_.@-][^/\s\x00"<>]*/|/home/[A-Za-z0-9_.@-][^/\s\x00"<>]*/|[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9_.@-][^\\/\s\x00"<>]*[\\/])')
IPV4 = re.compile(rb'(?<![\d.])(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?![\d.])')
USER_DATA = {'vault.sqlite', 'vault.sqlite-wal', 'credential.key', 'known_hosts',
             'local.properties', 'mobile-fixture.json', '.env'}
# Explicit synthetic path examples in offline tests. Other source paths are
# checked even when CI runs under a different account than their author.
_example_home = b'/' + b'Users/'
_example_windows = b'C:' + b'\\Users\\'
_example_linux = b'/' + b'home/'
SOURCE_EXAMPLES = {
    'apps/windows/src/components/SftpPanel.test.ts': [_example_home + b'alice/', _example_windows + b'Alice\\'],
    'apps/windows/src/components/WorkspaceArea.test.ts': [_example_home + b'pilot/'],
    'apps/windows/src/components/TerminalSurface.test.ts': [_example_linux + b'user/'],
    'tests/release/test_privacy.py': [_example_home + b'fixture/', _example_windows + b'fixture\\'],
}


def findings(data, name, source=False, allow_development_signing=False):
    results = []
    basename = name.replace('\\', '/').rsplit('/', 1)[-1]
    if basename in USER_DATA or basename.endswith(('.p12', '.pfx', '.keystore', '.jks')):
        results.append('user-data-or-private-signing-file')
    if basename == 'embedded.mobileprovision' and not allow_development_signing:
        results.append('device-specific-development-profile')
    for prefix in (str(ROOT), str(Path.home())):
        # Also catch Windows spellings when this audit runs on Windows.
        for spelling in {prefix, prefix.replace('\\', '/')}:
            value = spelling.encode()
            if value in data or spelling.encode('utf-16-le') in data:
                results.append('current-machine-path')
    allowed = []
    if source:
        for filename, prefixes in SOURCE_EXAMPLES.items():
            if name.endswith(filename):
                allowed = prefixes
    # Scan narrow/wide strings and escaped source literals without printing them.
    inspected = data.replace(b'\\\\', b'\\') if source else data
    paths = [*HOME_PATH.finditer(inspected), *HOME_PATH.finditer(inspected.replace(b'\x00', b''))]
    if any(match.group() not in allowed for match in paths):
        results.append('absolute-user-directory')
    # Fixture addresses must be supplied outside source, not silently replaced
    # with a different live target. Generic offline unit-test examples are fine.
    live_test = any(part in name for part in (
        'AppFlowTests.', 'LiveConnectionTests.', 'HostKeyPersistenceTests.',
        'ToolsInterfaceTests.', 'RDPIntegrationTests.', 'remote_config.py'))
    if live_test and IPV4.search(data):
        results.append('hardcoded-live-test-address')
    return sorted(set(results))


def scan_bytes(data, name, *, source=False, allow_development_signing=False, depth=0):
    if depth > 8:
        raise ValueError('Archive nesting exceeds privacy audit limit')
    result = []
    lower = name.lower()
    # ditto stores resource forks as AppleDouble ._ sidecars, whose filenames
    # retain the original extension even though their bytes are not an archive.
    sidecar = name.rsplit('/', 1)[-1].startswith('._') and data[:4] == b'\x00\x05\x16\x07'
    if lower.endswith(('.zip', '.apk', '.ipa')) and not sidecar:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for item in archive.infolist():
                if not item.is_dir():
                    result += scan_bytes(archive.read(item), name + '!' + item.filename,
                                         source=source, allow_development_signing=allow_development_signing, depth=depth+1)
    elif lower.endswith(('.tar.gz', '.tgz')) and not sidecar:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            is_source = source or 'source' in lower
            for item in archive:
                if item.isfile():
                    if item.uname or item.gname or item.uid or item.gid:
                        result.append({'file': name + '!' + item.name, 'kinds': ['archive-owner-identity']})
                    result += scan_bytes(archive.extractfile(item).read(), name + '!' + item.name,
                                         source=is_source, allow_development_signing=allow_development_signing, depth=depth+1)
    else:
        kinds = findings(data, name, source, allow_development_signing)
        if kinds:
            result.append({'file': name, 'kinds': kinds})
    return result


def scan(path, **options):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('Audit a real release path, not a symlink')
    if path.is_file():
        return scan_bytes(path.read_bytes(), path.name, **options)
    result = []
    for item in sorted(path.rglob('*')):
        if item.is_file() and not item.is_symlink():
            result += scan_bytes(item.read_bytes(), item.relative_to(path).as_posix(), **options)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    parser.add_argument('--source', action='store_true')
    parser.add_argument('--allow-development-signing', action='store_true')
    args = parser.parse_args()
    if not args.path.exists():
        parser.error('Input does not exist')
    result = scan(args.path, source=args.source,
                  allow_development_signing=args.allow_development_signing)
    print(json.dumps({'passed': not result, 'developmentSignatureAllowed': args.allow_development_signing,
                      'findings': result}, ensure_ascii=False, indent=2))
    raise SystemExit(bool(result))


if __name__ == '__main__':
    main()
