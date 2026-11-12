#!/usr/bin/env python3
"""Replace one existing release's macOS archive while preserving other clients."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release import RELEASE_TARGETS, archive_name, project_version


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def updated_checksums(text, version, digest, assets):
    expected = {archive_name(version, platform, arch) for platform, arch in RELEASE_TARGETS}
    macos = archive_name(version, 'macos', 'arm64')
    checksums = {}
    for line in text.splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
        if not match or match[2] in checksums:
            raise ValueError('Malformed or duplicate release checksum')
        checksums[match[2]] = match[1]
    if set(checksums) != expected or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('Unexpected desktop archive list or digest')
    for name in expected - {macos}:
        if assets[name].get('digest') != 'sha256:' + checksums[name]:
            raise ValueError('Existing Windows checksum does not match release asset: ' + name)
    checksums[macos] = digest
    return ''.join(f'{value}  {name}\n' for name, value in sorted(checksums.items()))


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def api(path):
    return json.loads(gh('api', path))


def verify_tag(repo, tag, commit):
    obj = api(f'repos/{repo}/git/ref/tags/{tag}')['object']
    for _ in range(5):
        if obj['type'] != 'tag':
            break
        obj = api(f'repos/{repo}/git/tags/{obj["sha"]}')['object']
    if obj['type'] != 'commit' or obj['sha'] != commit:
        raise ValueError('Release tag no longer points to the built commit')


def assets_by_name(release):
    assets = {a['name']: a for a in release['assets']}
    if len(assets) != len(release['assets']):
        raise ValueError('Duplicate release assets')
    return assets


def main():
    repo, tag, commit = (os.environ[name] for name in ('GH_REPO', 'RELEASE_TAG', 'RELEASE_COMMIT'))
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid repository or commit')
    version = project_version(tag)
    name = archive_name(version, 'macos', 'arm64')
    package = Path('dist/release') / name
    if not package.is_file() or package.stat().st_size == 0:
        raise ValueError('Missing built macOS archive')
    verify_tag(repo, tag, commit)
    endpoint = f'repos/{repo}/releases/tags/{tag}'
    before = api(endpoint)
    if before['draft'] or before['tag_name'] != tag:
        raise ValueError('An existing published release is required')
    assets = assets_by_name(before)
    if not {name, 'SHA256SUMS.txt'} <= assets.keys():
        raise ValueError('Existing macOS archive and checksum file are required')

    backup = Path('dist/release-backup')
    backup.mkdir(parents=True, exist_ok=True)
    (backup/'release.json').write_text(json.dumps(before, indent=2), encoding='utf-8')
    for filename in (name, 'SHA256SUMS.txt'):
        gh('release', 'download', tag, '--pattern', filename, '--dir', str(backup), '--clobber')
        if assets[filename].get('digest') != 'sha256:' + sha256(backup/filename):
            raise ValueError('Release backup checksum mismatch: ' + filename)
    digest = sha256(package)
    checksums = package.parent/'SHA256SUMS.txt'
    checksums.write_text(updated_checksums((backup/'SHA256SUMS.txt').read_text(encoding='utf-8'),
                                          version, digest, assets), encoding='utf-8')
    verify_tag(repo, tag, commit)
    gh('release', 'upload', tag, str(package), str(checksums), '--clobber')
    after = api(endpoint)
    new_assets = assets_by_name(after)
    if set(new_assets) != set(assets):
        raise ValueError('Release asset list changed unexpectedly')
    for filename, asset in assets.items():
        current = new_assets[filename]
        if filename in (name, 'SHA256SUMS.txt'):
            path = package if filename == name else checksums
            if current.get('digest') != 'sha256:' + sha256(path) or current['size'] != path.stat().st_size:
                raise ValueError('Uploaded release checksum mismatch: ' + filename)
        elif any(current.get(key) != asset.get(key) for key in ('id', 'digest', 'size')):
            raise ValueError('An unrelated release asset changed: ' + filename)
    verify_tag(repo, tag, commit)
    marker = '<!-- macos-release-update -->'
    body = (before.get('body') or '').split(marker)[0].rstrip()
    body += (f'\n\n{marker}\n### macOS arm64 update\n\n'
             f'Fixes a freeze when switching from Settings to a terminal tab. '
             f'Rebuilt from [{commit[:7]}](https://github.com/{repo}/commit/{commit}).\n\n'
             'Windows, Android and iOS/iPadOS downloads are unchanged.\n')
    notes = package.parent/'macos-release-notes.md'
    notes.write_text(body, encoding='utf-8')
    gh('release', 'edit', tag, '--title', f'{tag}-{commit[:7]}', '--notes-file', str(notes))
    print(f'Updated {name}: {digest}; other release assets preserved.')


if __name__ == '__main__':
    main()
