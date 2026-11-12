#!/usr/bin/env python3
"""Update an existing release's signed Android APKs without changing other clients."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_signing import android_version_code, policy, quiet, verify_signed_apk
from release import project_version

# Reuse the same GitHub API, tag and asset checks as the macOS updater.
spec = importlib.util.spec_from_file_location('release_update', Path(__file__).with_name('replace-macos-release.py'))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
gh, api, verify_tag, assets_by_name, sha256 = shared.gh, shared.api, shared.verify_tag, shared.assets_by_name, shared.sha256
ABIS = ('arm64-v8a', 'x86_64')


def validate_artifacts(folder, version):
    apks = [f'TermPilot-{version}-Android-{abi}-signed.apk' for abi in ABIS]
    support = f'TermPilot-{version}-android-support.zip'
    names = apks + [support, support+'.sha256']
    if {p.name for p in folder.iterdir() if p.is_file()} != set(names):
        raise ValueError('Expected only two signed APKs and Android support files')
    for name, abi in zip(apks, ABIS):
        verify_signed_apk(folder/name, version, abi)
    if (folder/(support+'.sha256')).read_text(encoding='utf-8').strip() != sha256(folder/support)+'  '+support:
        raise ValueError('Android support checksum mismatch')
    with zipfile.ZipFile(folder/support) as bundle:
        if bundle.testzip() is not None or any(name.endswith('.apk') for name in bundle.namelist()):
            raise ValueError('Invalid Android support archive; APKs must be separate')
        checksums = {}
        for line in bundle.read('TermPilot/SHA256SUMS').decode('utf-8').splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
            if not match or match[2] in checksums:
                raise ValueError('Malformed Android checksum manifest')
            checksums[match[2]] = match[1]
        required = set(apks) | {'LICENSE', 'NOTICE.md', 'INSTALL.txt', f'TermPilot-{version}-CorrespondingSource.tar.gz'}
        if set(checksums) != required:
            raise ValueError('Unexpected Android checksum manifest entries')
        for name, digest in checksums.items():
            data = (folder/name).read_bytes() if name in apks else bundle.read('TermPilot/'+name)
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError('Android artifact checksum mismatch: '+name)
    return names


def check_previous_apk(path, version, abi):
    sdk = Path(os.environ['ANDROID_HOME'])/'build-tools/36.0.0'
    badging = quiet(sdk/'aapt', 'dump', 'badging', path).decode('utf-8')
    package = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'", badging, re.MULTILINE)
    if not package or package[1] != 'com.termpilot.app' or package[3] != version or int(package[2]) > android_version_code():
        raise ValueError('Existing APK identity is unexpected or versionCode would decrease')
    if path.name.endswith('-signed.apk'):
        certificates = quiet(sdk/'apksigner', 'verify', '--print-certs', path).decode('utf-8')
        digests = re.findall(r'^Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$', certificates, re.MULTILINE)
        if [value.lower() for value in digests] != [policy()['certificate_sha256']]:
            raise ValueError('Cannot replace an existing signed APK with a different signing identity')


def main():
    repo, tag, commit = (os.environ[name] for name in ('GH_REPO', 'RELEASE_TAG', 'RELEASE_COMMIT'))
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid repository or commit')
    version = project_version(tag)
    folder = Path('dist/mobile/android')
    names = validate_artifacts(folder, version)
    verify_tag(repo, tag, commit)
    endpoint = f'repos/{repo}/releases/tags/{tag}'
    before = api(endpoint)
    if before['draft'] or before['tag_name'] != tag:
        raise ValueError('An existing published release is required')
    assets = assets_by_name(before)
    previous = set(names[2:])
    for abi in ABIS:
        candidates = {f'TermPilot-{version}-Android-{abi}-{label}.apk' for label in ('test', 'signed')}
        existing = candidates & assets.keys()
        if not existing:
            raise ValueError('Existing Android APK is missing: '+abi)
        previous.update(existing)
    if not previous <= assets.keys():
        raise ValueError('Existing Android support files are missing')
    backup = Path('dist/android-release-backup')
    backup.mkdir(parents=True, exist_ok=True)
    (backup/'release.json').write_text(json.dumps(before, indent=2), encoding='utf-8')
    for name in sorted(previous):
        gh('release', 'download', tag, '--pattern', name, '--dir', str(backup), '--clobber')
        if assets[name].get('digest') != 'sha256:'+sha256(backup/name):
            raise ValueError('Android backup checksum mismatch: '+name)
        if name.endswith('.apk'):
            abi = next(abi for abi in ABIS if '-'+abi+'-' in name)
            check_previous_apk(backup/name, version, abi)
    verify_tag(repo, tag, commit)
    gh('release', 'upload', tag, *(str(folder/name) for name in names), '--clobber')
    uploaded = assets_by_name(api(endpoint))
    if set(uploaded) != set(assets) | set(names):
        raise ValueError('Release asset list changed unexpectedly')
    for name in names:
        if uploaded[name].get('digest') != 'sha256:'+sha256(folder/name) or uploaded[name]['size'] != (folder/name).stat().st_size:
            raise ValueError('Uploaded Android checksum mismatch: '+name)
    for name in assets.keys() - previous:
        if any(uploaded[name].get(key) != assets[name].get(key) for key in ('id', 'digest', 'size')):
            raise ValueError('An unrelated release asset changed: '+name)
    verify_tag(repo, tag, commit)
    # Only remove superseded test APKs after signed downloads and backups are verified.
    for name in sorted(previous - set(names)):
        gh('release', 'delete-asset', tag, name, '--yes')
    after = assets_by_name(api(endpoint))
    if set(after) != (set(assets) - previous) | set(names) or any(
            any(after[name].get(key) != uploaded[name].get(key) for key in ('id', 'digest', 'size')) for name in after):
        raise ValueError('Release assets changed during Android finalization')
    verify_tag(repo, tag, commit)
    marker = '<!-- android-release-update -->'
    body = (before.get('body') or '').split(marker)[0].rstrip()
    body += (f'\n\n{marker}\n### Android signed update\n\n'
             f'Android {version} (versionCode {android_version_code()}) is signed with the persistent TermPilot release key. '
             f'Rebuilt from [{commit[:7]}](https://github.com/{repo}/commit/{commit}).\n\n'
             f'Certificate SHA-256: `{policy()["certificate_sha256"]}`.\n\n'
             'Existing test APKs use a different signing key: back up app data and uninstall the test build once before installing this signed build. '
             'Future signed APKs can update this installation with the same key.\n\n'
             'macOS, Windows and iOS/iPadOS downloads are unchanged.\n')
    notes = Path('dist/android-release-notes.md')
    notes.write_text(body, encoding='utf-8')
    gh('release', 'edit', tag, '--title', f'{tag}-{commit[:7]}', '--notes-file', str(notes))
    print('Updated signed Android APKs and support files; other release assets preserved.')


if __name__ == '__main__':
    main()
