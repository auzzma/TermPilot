import base64
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
import android_signing


@unittest.skipUnless(os.name == 'posix', 'Signing keys are prepared on Linux CI')
class AndroidPrivateKeyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.env_file = self.folder/'github-env'
        self.certificate = b'public certificate fixture'
        self.policy = {'application_id': 'com.termpilot.app', 'store_type': 'PKCS12',
                       'certificate_sha256': hashlib.sha256(self.certificate).hexdigest()}
        self.env = dict(RUNNER_TEMP=str(self.folder), GITHUB_ENV=str(self.env_file),
                        ANDROID_KEYSTORE_BASE64=base64.b64encode(b'private fixture'*40).decode(),
                        ANDROID_KEYSTORE_PASSWORD='fixture-store-password', ANDROID_KEY_PASSWORD='fixture-key-password',
                        ANDROID_KEY_ALIAS='fixture-alias')

    def prepare(self, certificate=None):
        with patch.dict(os.environ, self.env), patch.object(android_signing, 'policy', return_value=self.policy), \
                patch.object(android_signing, 'quiet', return_value=certificate or self.certificate) as command:
            output = io.StringIO()
            with redirect_stdout(output):
                android_signing.prepare_signing_key()
            for value in self.env.values():
                self.assertNotIn(value, output.getvalue())
            self.assertNotIn('fixture-store-password', str(command.call_args))

    def test_key_is_private_and_only_path_is_written_to_runner_environment(self):
        self.prepare()
        key = self.folder/'termpilot-android-signing.p12'
        self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
        self.assertEqual(key.read_bytes(), b'private fixture'*40)
        env = self.env_file.read_text()
        self.assertIn('TERMPILOT_ANDROID_SIGN=1\n', env)
        self.assertIn(str(key), env)
        self.assertNotIn('fixture-store-password', env)
        self.assertNotIn(self.env['ANDROID_KEYSTORE_BASE64'], env)

    def test_wrong_certificate_removes_key_and_does_not_enable_signing(self):
        with self.assertRaisesRegex(ValueError, 'pinned'):
            self.prepare(b'wrong certificate')
        self.assertFalse((self.folder/'termpilot-android-signing.p12').exists())
        self.assertFalse(self.env_file.exists())

    def test_existing_file_is_never_overwritten(self):
        key = self.folder/'termpilot-android-signing.p12'
        key.write_bytes(b'preserve')
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(key.read_bytes(), b'preserve')

    def test_missing_secret_fails_before_writing_a_key(self):
        self.env['ANDROID_KEY_PASSWORD'] = ''
        with self.assertRaisesRegex(ValueError, 'four ANDROID'):
            self.prepare()
        self.assertFalse((self.folder/'termpilot-android-signing.p12').exists())


class AndroidAPKIdentityTests(unittest.TestCase):
    def verify(self, fingerprint=None, code=22, package='com.termpilot.app', version='0.2.0', abi='arm64-v8a', debug=False):
        expected = android_signing.policy()['certificate_sha256']
        certificate = f'Signer #1 certificate SHA-256 digest: {fingerprint or expected}\n'.encode()
        badging = (f"package: name='{package}' versionCode='{code}' versionName='{version}'\n"
                   f"native-code: '{abi}'\n"+('application-debuggable\n' if debug else '')).encode()
        with patch.object(android_signing, 'quiet', side_effect=[certificate, badging, b'']):
            return android_signing.verify_signed_apk(Path('fixture.apk'), '0.2.0', 'arm64-v8a', Path('sdk'))

    def test_pinned_release_certificate_and_package_version_are_accepted(self):
        self.assertEqual(self.verify()['version_code'], 22)

    def test_test_key_and_wrong_app_version_abi_or_debug_mode_are_rejected(self):
        for kwargs in ({'fingerprint': '0'*64}, {'code': 21}, {'package': 'com.example.other'},
                       {'version': '0.3.0'}, {'abi': 'x86_64'}, {'debug': True}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.verify(**kwargs)


if __name__ == '__main__':
    unittest.main()
