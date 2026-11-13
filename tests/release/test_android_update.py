import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('android_update', ROOT/'scripts/ci/replace-android-release.py')
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class AndroidReleaseUpdateTests(unittest.TestCase):
    def setUp(self):
        fixture_version = patch.object(updater, 'project_version', return_value='0.2.0')
        fixture_version.start()
        self.addCleanup(fixture_version.stop)
        # Keep the historical release fixture independent of the current app version.
        source_code = patch.object(updater, 'android_version_code', return_value=22)
        source_code.start()
        self.addCleanup(source_code.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.folder = self.root/'dist/mobile/android'
        self.folder.mkdir(parents=True)
        self.apks = [f'TermPilot-0.2.0-Android-{abi}-signed.apk' for abi in updater.ABIS]
        self.support = 'TermPilot-0.2.0-android-support.zip'
        self.checksums = {}
        for name in self.apks:
            data = name.encode()
            (self.folder/name).write_bytes(data)
            self.checksums[name] = hashlib.sha256(data).hexdigest()
        with zipfile.ZipFile(self.folder/self.support, 'w') as bundle:
            for name in ['LICENSE', 'NOTICE.md', 'INSTALL.txt', 'TermPilot-0.2.0-CorrespondingSource.tar.gz']:
                data = name.encode()
                bundle.writestr('TermPilot/'+name, data)
                self.checksums[name] = hashlib.sha256(data).hexdigest()
            bundle.writestr('TermPilot/SHA256SUMS', ''.join(f'{value}  {name}\n' for name, value in self.checksums.items()))
        (self.folder/(self.support+'.sha256')).write_text(updater.sha256(self.folder/self.support)+'  '+self.support+'\n')
        self.old_files = {name.replace('-signed.apk', '-test.apk'): b'old test apk' for name in self.apks}
        self.old_files.update({self.support: b'old support', self.support+'.sha256': b'old checksums',
                              'TermPilot-0.2.0-macos-arm64.zip': b'unchanged macOS', 'SHA256SUMS.txt': b'desktop sums',
                              'TermPilot-0.2.0-ios-ipados.zip': b'unchanged iOS'})
        self.release = dict(id=123, draft=False, tag_name='v0.2.0', body='Existing macOS update notes',
                            assets=[dict(id=index, name=name, size=len(data), digest='sha256:'+hashlib.sha256(data).hexdigest())
                                    for index, (name, data) in enumerate(self.old_files.items(), 1)])

    def run_publisher(self, *, change_other=False, tag_changed=False, invalid_signer=False):
        release = copy.deepcopy(self.release)
        calls = []
        def gh(*args):
            calls.append(args)
            if args[:2] == ('release', 'download'):
                name, folder = args[args.index('--pattern')+1], Path(args[args.index('--dir')+1])
                (folder/name).write_bytes(self.old_files[name])
            if args[:2] == ('release', 'upload'):
                for file in args[3:-1]:
                    path = Path(file)
                    release['assets'] = [a for a in release['assets'] if a['name'] != path.name]
                    release['assets'].append(dict(id=100+len(release['assets']), name=path.name, size=path.stat().st_size,
                                                  digest='sha256:'+updater.sha256(path)))
                if change_other:
                    next(a for a in release['assets'] if a['name'].endswith('macos-arm64.zip'))['id'] = 999
            if args[:2] == ('release', 'delete-asset'):
                release['assets'] = [a for a in release['assets'] if a['name'] != args[3]]
            return ''
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            with patch.dict(os.environ, GH_REPO='fixture/TermPilot', RELEASE_TAG='v0.2.0', RELEASE_COMMIT='a'*40), \
                    patch.object(updater, 'gh', side_effect=gh), \
                    patch.object(updater, 'api', side_effect=lambda _: copy.deepcopy(release)), \
                    patch.object(updater, 'verify_tag', side_effect=ValueError('tag changed') if tag_changed else None), \
                    patch.object(updater, 'verify_signed_apk', side_effect=ValueError('wrong signer') if invalid_signer else None), \
                    patch.object(updater, 'check_previous_apk'):
                if change_other or tag_changed or invalid_signer:
                    with self.assertRaises(ValueError):
                        updater.main()
                else:
                    updater.main()
                    for name, data in self.old_files.items():
                        if name.endswith(('-test.apk', '-android-support.zip', '-android-support.zip.sha256')):
                            self.assertEqual((Path('dist/android-release-backup')/name).read_bytes(), data)
                    notes = Path('dist/android-release-notes.md').read_text()
                    self.assertIn('Existing macOS update notes', notes)
                    self.assertIn('versionCode 22', notes)
        finally:
            os.chdir(previous)
        return calls, release

    def test_signed_apks_are_verified_and_uploaded_before_test_apks_are_removed(self):
        calls, release = self.run_publisher()
        upload_index = next(i for i, call in enumerate(calls) if call[:2] == ('release', 'upload'))
        deletes = [(i, call) for i, call in enumerate(calls) if call[:2] == ('release', 'delete-asset')]
        self.assertEqual(len(deletes), 2)
        self.assertTrue(all(i > upload_index and call[3].endswith('-test.apk') for i, call in deletes))
        names = {a['name'] for a in release['assets']}
        self.assertTrue(set(self.apks) <= names)
        self.assertFalse(any(name.endswith('-test.apk') for name in names))
        self.assertEqual(calls[-1][:2], ('release', 'edit'))

    def test_unrelated_asset_change_stops_removal_and_release_metadata_update(self):
        calls, _ = self.run_publisher(change_other=True)
        self.assertFalse(any(call[:2] in [('release', 'delete-asset'), ('release', 'edit')] for call in calls))

    def test_stale_tag_or_untrusted_signature_prevents_all_writes(self):
        for kwargs in ({'tag_changed': True}, {'invalid_signer': True}):
            calls, _ = self.run_publisher(**kwargs)
            self.assertEqual(calls, [])

    def test_corrupted_apk_or_support_checksum_is_rejected(self):
        with patch.object(updater, 'verify_signed_apk'):
            updater.validate_artifacts(self.folder, '0.2.0')
            (self.folder/self.apks[0]).write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                updater.validate_artifacts(self.folder, '0.2.0')


if __name__ == '__main__':
    unittest.main()
