"""Validate the persistent Android signing identity without logging private values."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SECRET_NAMES = ('ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')


def policy():
    value = json.loads((ROOT/'apps/android/release-signing.json').read_text(encoding='utf-8'))
    if (value.get('application_id') != 'com.termpilot.app' or value.get('store_type') != 'PKCS12'
            or not re.fullmatch(r'[0-9a-f]{64}', value.get('certificate_sha256', ''))):
        raise ValueError('Invalid Android release signing policy')
    return value


def android_version_code():
    source = (ROOT/'apps/android/app/build.gradle.kts').read_text(encoding='utf-8')
    match = re.search(r'^\s*versionCode\s*=\s*([0-9]+)\s*$', source, re.MULTILINE)
    if not match or not 0 < int(match[1]) <= 2100000000:
        raise ValueError('Invalid Android versionCode')
    return int(match[1])


def quiet(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True)
    if result.returncode:
        # keytool/Gradle diagnostics must never echo a password or private key.
        raise ValueError(Path(str(args[0])).name + ' failed; check the signing configuration')
    return result.stdout


def prepare_signing_key():
    if any(not os.environ.get(name) for name in SECRET_NAMES):
        raise ValueError('Android signing requires all four ANDROID signing secrets')
    expected = policy()
    data = base64.b64decode(os.environ['ANDROID_KEYSTORE_BASE64'], validate=True)
    if not 100 <= len(data) <= 48 * 1024:
        raise ValueError('Unexpected Android keystore size')
    folder = Path(os.environ['RUNNER_TEMP']).resolve()
    if folder == ROOT or ROOT in folder.parents:
        raise ValueError('Private signing key must stay outside the source tree')
    path = folder/'termpilot-android-signing.p12'
    # O_EXCL also prevents overwriting a symlink or a pre-existing key.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
        certificate = quiet('keytool', '-exportcert', '-keystore', path, '-storetype', 'PKCS12',
                            '-storepass:env', 'ANDROID_KEYSTORE_PASSWORD',
                            '-alias', os.environ['ANDROID_KEY_ALIAS'])
        if hashlib.sha256(certificate).hexdigest() != expected['certificate_sha256']:
            raise ValueError('Signing key does not match the pinned Android release certificate')
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
            output.write('TERMPILOT_ANDROID_SIGN=1\nANDROID_KEYSTORE_PATH=' + str(path) + '\n')
    except Exception:
        path.unlink(missing_ok=True)
        raise
    print('Persistent Android signing key prepared and certificate verified; private values are not logged.')


def verify_signed_apk(path, version, abi, sdk=None):
    expected = policy()
    sdk = Path(sdk or os.environ['ANDROID_HOME'])/'build-tools/36.0.0'
    certificate = quiet(sdk/'apksigner', 'verify', '--verbose', '--print-certs', path).decode('utf-8')
    digests = re.findall(r'^Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$', certificate, re.MULTILINE)
    if [digest.lower() for digest in digests] != [expected['certificate_sha256']]:
        raise ValueError('APK does not have exactly the pinned Android release signer')
    badging = quiet(sdk/'aapt', 'dump', 'badging', path).decode('utf-8')
    package = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'", badging, re.MULTILINE)
    native = re.search(r'^native-code: (.+)$', badging, re.MULTILINE)
    if not package or (package[1], int(package[2]), package[3]) != (expected['application_id'], android_version_code(), version):
        raise ValueError('Signed APK package name or version does not match the source')
    if not native or re.findall(r"'([^']+)'", native[1]) != [abi] or 'application-debuggable' in badging:
        raise ValueError('Signed APK must be a non-debuggable build for the requested ABI')
    quiet(sdk/'zipalign', '-c', '-P', '16', '-v', '4', path)
    return {'certificate_sha256': expected['certificate_sha256'], 'application_id': package[1],
            'version_name': package[3], 'version_code': int(package[2]), 'abi': abi}
