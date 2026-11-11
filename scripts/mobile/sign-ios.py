#!/usr/bin/env python3
"""Sign an unsigned device app for registered devices using CI-only secrets."""
import argparse
import base64
from datetime import datetime, timezone
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import tempfile
import zipfile


def signing_entitlements(profile, bundle_id):
    expires = profile['ExpirationDate'].replace(tzinfo=timezone.utc)
    if expires <= datetime.now(timezone.utc):
        raise ValueError('The iOS provisioning profile has expired')
    if not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'):
        raise ValueError('Direct installation requires a development, ad-hoc or enterprise profile; an App Store profile is not installable directly')
    entitlements = dict(profile['Entitlements'])
    prefix = profile['ApplicationIdentifierPrefix'][0] + '.'
    application_id = prefix + bundle_id
    if not fnmatch.fnmatchcase(application_id, entitlements['application-identifier']):
        raise ValueError('Provisioning profile does not allow the application bundle identifier')
    entitlements['application-identifier'] = application_id
    if 'keychain-access-groups' in entitlements:
        entitlements['keychain-access-groups'] = [
            group.replace('*', bundle_id) for group in entitlements['keychain-access-groups']
        ]
    return entitlements


def quiet(*command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        # Security tools can print certificate/account details. Do not place
        # private signing identity or command arguments in public CI logs.
        raise RuntimeError(f'{Path(command[0]).name} failed (exit {result.returncode}); check the signing secrets/profile')
    return result.stdout


def sign(source, output):
    names = ('IOS_CERTIFICATE_P12_BASE64', 'IOS_CERTIFICATE_PASSWORD', 'IOS_PROVISION_PROFILE_BASE64')
    if any(not os.environ.get(name) for name in names):
        raise ValueError('All three IOS signing secrets must be configured')
    with tempfile.TemporaryDirectory(prefix='termpilot-sign-', dir=os.environ.get('RUNNER_TEMP')) as folder:
        temporary = Path(folder)
        certificate = temporary / 'identity.p12'
        certificate.write_bytes(base64.b64decode(os.environ[names[0]], validate=True))
        profile_path = temporary / 'app.mobileprovision'
        profile_path.write_bytes(base64.b64decode(os.environ[names[2]], validate=True))
        profile = plistlib.loads(quiet('security', 'cms', '-D', '-i', str(profile_path)))
        payload = temporary / 'Payload'
        payload.mkdir()
        app = payload / 'TermPilot.app'
        shutil.copytree(source, app, symlinks=True)
        with (app / 'Info.plist').open('rb') as handle:
            bundle_id = plistlib.load(handle)['CFBundleIdentifier']
        entitlements = temporary / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(signing_entitlements(profile, bundle_id)))
        keychain = temporary / 'signing.keychain-db'
        password = secrets.token_urlsafe(32)
        try:
            quiet('security', 'create-keychain', '-p', password, str(keychain))
            quiet('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
            quiet('security', 'unlock-keychain', '-p', password, str(keychain))
            quiet('security', 'import', str(certificate), '-k', str(keychain),
                  '-P', os.environ[names[1]], '-T', '/usr/bin/codesign')
            quiet('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                  '-k', password, str(keychain))
            identities = quiet('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)).decode()
            allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']}
            matching = [identity for identity in re.findall(r'\b[A-F0-9]{40}\b', identities) if identity in allowed]
            if len(matching) != 1:
                raise ValueError('Expected one valid signing identity matching the provisioning profile')
            identity = matching[0]
            shutil.copy2(profile_path, app / 'embedded.mobileprovision')
            # Embedded frameworks/dylibs are signed inside-out before the app.
            embedded = [path for path in app.rglob('*') if path.suffix in ('.framework', '.dylib')]
            for path in sorted(embedded, key=lambda path: len(path.parts), reverse=True):
                quiet('codesign', '--force', '--sign', identity, '--keychain', str(keychain), '--timestamp=none', str(path))
            quiet('codesign', '--force', '--sign', identity, '--keychain', str(keychain),
                  '--timestamp=none', '--entitlements', str(entitlements), str(app))
            quiet('codesign', '--verify', '--deep', '--strict', str(app))
            root = Path(__file__).resolve().parents[2]
            subprocess.run(['python3', str(root / 'scripts/audit-privacy.py'), str(app), '--allow-development-signing'], check=True)
            with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(payload.rglob('*')):
                    if path.is_file():
                        archive.write(path, path.relative_to(temporary))
        finally:
            if keychain.exists():
                quiet('security', 'delete-keychain', str(keychain))
    print('Signed IPA created for devices permitted by the provisioning profile.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    sign(args.app, args.output)
