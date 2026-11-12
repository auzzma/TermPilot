import importlib.util
import hashlib
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('sign_ios', ROOT/'scripts/mobile/sign-ios.py')
sign_ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sign_ios)
spec = importlib.util.spec_from_file_location('simulators', ROOT/'scripts/mobile/select-ios-simulators.py')
simulators = importlib.util.module_from_spec(spec)
spec.loader.exec_module(simulators)
spec = importlib.util.spec_from_file_location('android_install', ROOT/'scripts/mobile/check-android-install.py')
android_install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(android_install)


@unittest.skipUnless(os.name == 'posix', 'The release publisher runs on Linux')
class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in (
            'release/TermPilot-0.2.0-macos-arm64.zip', 'release/SHA256SUMS.txt',
            'mobile/android/TermPilot-0.2.0-Android-arm64-v8a-test.apk',
            'mobile/android/TermPilot-0.2.0-Android-x86_64-test.apk',
            'mobile/android/TermPilot-0.2.0-android-support.zip',
            'mobile/android/TermPilot-0.2.0-android-support.zip.sha256',
            'mobile/ios/TermPilot-0.2.0-ios-ipados.zip',
            'mobile/ios/TermPilot-0.2.0-ios-ipados.zip.sha256',
        ):
            path = self.root/'dist'/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'validated fixture')
        workflow = (ROOT/'.github/workflows/release.yml').read_text(encoding='utf-8')
        self.script = textwrap.dedent(workflow.split('      - name: Publish validated packages\n', 1)[1]
                                     .split('        run: |\n', 1)[1])
        executable = self.root/'gh'
        executable.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n'
                              'if [[ "$2" == view ]]; then exit "${VIEW_EXIT:-1}"; fi\n'
                              'if [[ "$2" == upload ]]; then exit "${UPLOAD_EXIT:-0}"; fi\n')
        executable.chmod(0o755)
        self.log = self.root/'calls'
        self.env = dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH'],
                        CALL_LOG=str(self.log), RELEASE_TAG='v0.2.0', RELEASE_COMMIT='1234567'+'0'*33)

    def run_publish(self, **env):
        return subprocess.run(['bash', '-euo', 'pipefail', '-c', self.script], cwd=self.root,
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_new_release_is_published_after_upload_with_commit_title_and_direct_apks(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual([line.split()[1] for line in calls], ['view', 'create', 'edit'])
        self.assertIn('--draft --title v0.2.0-1234567', calls[1])
        for arch in ('arm64-v8a', 'x86_64'):
            self.assertIn(f'TermPilot-0.2.0-Android-{arch}-test.apk', calls[1])
        self.assertIn('--title v0.2.0-1234567 --draft=false', calls[2])

    def test_missing_android_architecture_prevents_publication(self):
        next(self.root.glob('dist/mobile/android/*x86_64*.apk')).unlink()
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_failed_upload_does_not_publish_an_existing_draft(self):
        self.assertNotEqual(self.run_publish(VIEW_EXIT='0', UPLOAD_EXIT='1').returncode, 0)
        self.assertEqual([line.split()[1] for line in self.log.read_text().splitlines()], ['view', 'upload'])


class AndroidInstallTargetTests(unittest.TestCase):
    def test_physical_and_offline_devices_cannot_be_reset(self):
        devices = 'List of devices attached\nfixture-phone\tdevice\nemulator-5554\toffline\n'
        with self.assertRaisesRegex(ValueError, 'running Android emulator'):
            android_install.select_emulator(devices, 'fixture-phone')
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            android_install.select_emulator(devices)

    def test_ambiguous_emulators_require_explicit_selection(self):
        devices = 'List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n'
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            android_install.select_emulator(devices)
        self.assertEqual(android_install.select_emulator(devices, 'emulator-5556'), 'emulator-5556')
        self.assertEqual(android_install.select_emulator('List of devices attached\nemulator-5554\tdevice\n'), 'emulator-5554')


class IOSSimulatorSelectionTests(unittest.TestCase):
    def test_runtime_supported_types_override_global_order_and_exclude_ipod(self):
        def device(name, family):
            return dict(name=name, productFamily=family, identifier='type.'+name)
        phone, pad = device('iPhone fixture', 'iPhone'), device('iPad fixture', 'iPad')
        ipod = device('iPod touch', 'iPhone')
        runtime = dict(identifier='runtime.iOS-27-0', version='27.0', isAvailable=True,
                       supportedDeviceTypes=[ipod, phone, pad])
        state = dict(devicetypes=[phone, pad, ipod], runtimes=[runtime,
                     dict(runtime, identifier='runtime.iOS-27-1', version='27.1'),
                     dict(runtime, identifier='runtime.iOS-27-0-unavailable', isAvailable=False)])
        identifier, selected = simulators.select_types(state, '27.0.0')
        self.assertEqual(identifier, 'runtime.iOS-27-0')
        self.assertEqual(selected, [phone, pad])
        with self.assertRaisesRegex(ValueError, 'No compatible'):
            simulators.select_types(state, '26.0')
        runtime['supportedDeviceTypes'] = [ipod, pad]
        with self.assertRaisesRegex(ValueError, 'No supported iPhone'):
            simulators.select_types(state, '27.0')


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

    def test_android_apks_stay_direct_while_support_bundle_keeps_notices_and_checksums(self):
        result = self.run_bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.output/'TermPilot-0.2.0-android-support.zip'
        with zipfile.ZipFile(output) as bundle:
            self.assertIn('TermPilot/Licenses/NOTICE.txt', bundle.namelist())
            self.assertFalse(any(name.endswith('.apk') for name in bundle.namelist()))
            for name, digest in self.checksums.items():
                self.assertEqual(hashlib.sha256((self.output/name).read_bytes()).hexdigest(), digest)
                if not name.endswith('.apk'):
                    self.assertIn('TermPilot/'+name, bundle.namelist())
                self.assertIn(digest+'  '+name, bundle.read('TermPilot/SHA256SUMS').decode())
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
        with zipfile.ZipFile(self.output/'TermPilot-0.2.0-android-support.zip') as bundle:
            name = 'TermPilot/Licenses/NOTICE.txt'
            self.assertEqual(bundle.read(name), original)
            self.assertEqual(bundle.getinfo(name).date_time, (1980, 1, 1, 0, 0, 0))
        self.assertEqual(notice.stat().st_mtime, 0)
