#!/usr/bin/env python3
"""Validate the publishable checkout, without relying on ignored local files."""
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    # .gitignore cannot hide files which were already added to the real index.
    if (ROOT / '.git').exists():
        tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT)
        if tracked:
            ignored = subprocess.run(['git', '-c', f'core.excludesFile={os.devnull}',
                                      'check-ignore', '--no-index', '--stdin', '-z'],
                                     input=tracked, cwd=ROOT, capture_output=True)
            if ignored.returncode not in (0, 1):
                raise RuntimeError('Cannot inspect tracked source files')
            if ignored.stdout:
                raise RuntimeError('Tracked files violate .gitignore; untrack them without deleting local copies:\n' +
                                   ignored.stdout.decode().replace('\0', '\n'))
    with tempfile.TemporaryDirectory(prefix='TermPilot-clean-source-') as temporary:
        archive = Path(temporary) / 'CorrespondingSource.tar.gz'
        subprocess.run([sys.executable, str(ROOT / 'scripts/package-source.py'), str(archive)], check=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(temporary, filter='data')
        checkout = Path(temporary) / 'TermPilot'
        required = [
            '.gitattributes', 'rust-toolchain.toml', 'Cargo.lock',
            'apps/macos/Package.resolved', 'apps/ios/project.yml',
            'apps/android/gradle/wrapper/gradle-wrapper.jar',
            'apps/android/gradle/wrapper/gradle-wrapper.properties',
            'vendor/ironrdp-tls-mobile/tests/certs/server-key.pem',
            'apps/windows/package-lock.json', 'apps/windows/src-tauri/Cargo.lock',
            'engines/rdp/Cargo.lock', 'bindings/c/termpilot_core.h',
            'bindings/mobile/TermPilotMobile.h', 'apps/mobile/design/tokens.json',
        ]
        for name in required:
            if not (checkout / name).is_file():
                raise RuntimeError('Required build input excluded from Git: ' + name)
        for args in [
            ['scripts/verify-independence.py'],
            ['scripts/sync-resources.py'],
            ['scripts/mobile/generate-design.py', '--check'],
            ['scripts/release.py', 'version'],
            ['-m', 'unittest', 'discover', '-s', 'tests/release', '-v'],
        ]:
            subprocess.run([sys.executable, *args], cwd=checkout, check=True)
        print('Publishable source verified from a clean export; local caches and private files were not copied.')


if __name__ == '__main__':
    main()
