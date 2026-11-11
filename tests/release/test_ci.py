import importlib.util
import hashlib
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('sign_ios', ROOT/'scripts/mobile/sign-ios.py')
sign_ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sign_ios)


class SourcePolicyTests(unittest.TestCase):
    def test_independence_check_reads_utf8_under_windows_default_encoding(self):
        probe = '''
import io, runpy, sys
from unittest.mock import patch
with patch.object(io, 'text_encoding', side_effect=lambda encoding, *args: encoding or 'cp1252'):
    runpy.run_path(sys.argv[1], run_name='__main__')
'''
        result = subprocess.run([sys.executable, '-c', probe, str(ROOT/'scripts/verify-independence.py')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_build_inputs_survive_but_machine_data_and_outputs_are_excluded(self):
        # A fresh index prevents a developer's global excludes from affecting CI.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(['git', '-c', 'init.templateDir=', 'init', '--quiet', folder], check=True)
            shutil.copy2(ROOT/'.gitignore', root/'.gitignore')
            inputs = [
                '.gitattributes', 'rust-toolchain.toml', '.github/workflows/mobile.yml',
                'apps/android/gradle/wrapper/gradle-wrapper.jar',
                'apps/ios/project.yml', 'apps/macos/Package.resolved',
                'scripts/ci/check-source.py', 'engines/media-codec/mobile/adapter.cpp',
                'bindings/mobile/TermPilotMobile.h', 'apps/windows/src-tauri/Cargo.lock',
                'vendor/ironrdp-tls-mobile/tests/certs/server-key.pem',
            ]
            private = [
                'validation/report.json', 'dist/app.zip', '.tools/sdk/tool',
                'docs/local-plan.md', 'apps/retired/Old.cs',
                'apps/android/local.properties', 'apps/android/app/build/output.apk',
                'apps/ios/TermPilot.xcodeproj/project.pbxproj',
                'apps/ios/.derived/app', 'apps/ios/signing.p12', 'scripts/local.env',
                'apps/macos/.build/checkouts/a.swift', 'apps/windows/node_modules/pkg/index.js',
                'crates/termpilot-core/target/cache', 'apps/windows/AppData/vault.sqlite',
                'apps/ios/backups/test.tpbackup', 'apps/android/key.properties',
                'apps/android/debug.keystore', 'apps/macos/mobile-fixture.json',
                'apps/macos/id_ed25519', 'apps/macos/private.pem',
                'vendor/fdk-aac/.github/workflows/ci.yml', 'scripts/package-nuget-licenses.py',
            ]
            for name in inputs + private:
                file = root/name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('fixture')
            actual = set(subprocess.check_output(['git', '-c', 'core.excludesFile=',
                'ls-files', '--others', '--exclude-standard'], cwd=root, text=True).splitlines())
            self.assertEqual(actual, set(inputs) | {'.gitignore'})


class IOSSigningTests(unittest.TestCase):
    def profile(self):
        return {'ExpirationDate': datetime.now(timezone.utc)+timedelta(days=10),
                'ProvisionedDevices': ['fixture-device'],
                'ApplicationIdentifierPrefix': ['FIXTURE'],
                'Entitlements': {'application-identifier': 'FIXTURE.*',
                                 'keychain-access-groups': ['FIXTURE.*'],
                                 'get-task-allow': True}}

    def test_wildcard_profile_is_bound_to_actual_app(self):
        result = sign_ios.signing_entitlements(self.profile(), 'com.termpilot.app')
        self.assertEqual(result['application-identifier'], 'FIXTURE.com.termpilot.app')
        self.assertEqual(result['keychain-access-groups'], ['FIXTURE.com.termpilot.app'])
        self.assertTrue(result['get-task-allow'])

    def test_wrong_app_expired_and_store_only_profiles_fail_before_signing(self):
        profile = self.profile()
        profile['Entitlements']['application-identifier'] = 'FIXTURE.com.other.app'
        with self.assertRaisesRegex(ValueError, 'bundle identifier'):
            sign_ios.signing_entitlements(profile, 'com.termpilot.app')
        profile = self.profile()
        profile['ExpirationDate'] = datetime.now(timezone.utc)-timedelta(days=1)
        with self.assertRaisesRegex(ValueError, 'expired'):
            sign_ios.signing_entitlements(profile, 'com.termpilot.app')
        profile = self.profile()
        del profile['ProvisionedDevices']
        with self.assertRaisesRegex(ValueError, 'App Store'):
            sign_ios.signing_entitlements(profile, 'com.termpilot.app')


class MobileBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root/'scripts/mobile').mkdir(parents=True)
        shutil.copy2(ROOT/'scripts/mobile/bundle.py', self.root/'scripts/mobile/bundle.py')
        (self.root/'scripts/release.py').write_text('print("0.2.0")\n')
        self.output = self.root/'dist/mobile/android'
        self.output.mkdir(parents=True)
        names = ['LICENSE', 'NOTICE.md', 'INSTALL.txt', 'TermPilot-0.2.0-CorrespondingSource.tar.gz',
                 'TermPilot-0.2.0-Android-arm64-v8a-test.apk', 'TermPilot-0.2.0-Android-x86_64-test.apk']
        self.checksums = {}
        for name in names:
            data = ('fixture '+name).encode()
            (self.output/name).write_bytes(data)
            self.checksums[name] = hashlib.sha256(data).hexdigest()
        (self.output/'Licenses').mkdir()
        (self.output/'Licenses/NOTICE.txt').write_text('fixture notice')
        self.manifest()

    def manifest(self):
        (self.output/'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name,digest in self.checksums.items()))

    def run_bundle(self):
        return subprocess.run([sys.executable, str(self.root/'scripts/mobile/bundle.py'), 'android'], capture_output=True, text=True)

    def test_bundle_keeps_installers_notices_and_verifiable_checksums(self):
        result = self.run_bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.output/'TermPilot-0.2.0-android.zip'
        with zipfile.ZipFile(output) as bundle:
            self.assertIn('TermPilot/Licenses/NOTICE.txt', bundle.namelist())
            self.assertTrue(all('TermPilot/'+name in bundle.namelist() for name in self.checksums))
        self.assertEqual(output.with_suffix('.zip.sha256').read_text().split()[0], hashlib.sha256(output.read_bytes()).hexdigest())

    def test_changed_apk_and_unexpected_files_are_rejected(self):
        apk = self.output/'TermPilot-0.2.0-Android-arm64-v8a-test.apk'
        original = apk.read_bytes()
        apk.write_bytes(b'changed after audit')
        self.assertIn('checksum mismatch', self.run_bundle().stderr)
        apk.write_bytes(original)
        (self.output/'debug.log').write_text('not distributable')
        self.checksums['debug.log'] = hashlib.sha256(b'not distributable').hexdigest()
        self.manifest()
        self.assertIn('Invalid checksum filename', self.run_bundle().stderr)

    def test_reproducible_notice_timestamps_do_not_prevent_packaging(self):
        notice = self.output/'Licenses/NOTICE.txt'
        original = notice.read_bytes()
        os.utime(notice, (0, 0))
        result = self.run_bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.output/'TermPilot-0.2.0-android.zip') as bundle:
            name = 'TermPilot/Licenses/NOTICE.txt'
            self.assertEqual(bundle.read(name), original)
            self.assertEqual(bundle.getinfo(name).date_time, (1980, 1, 1, 0, 0, 0))
        self.assertEqual(notice.stat().st_mtime, 0)
