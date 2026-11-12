import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('macos_update', ROOT/'scripts/ci/replace-macos-release.py')
macos_update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(macos_update)


class MacOSReleaseUpdateTests(unittest.TestCase):
    def setUp(self):
        self.version = '0.2.0'
        self.commit = 'a'*40
        self.mac = 'TermPilot-0.2.0-macos-arm64.zip'
        self.files = {self.mac: b'old mac',
                      'TermPilot-0.2.0-windows-x64-portable.zip': b'windows x64',
                      'TermPilot-0.2.0-windows-arm64-portable.zip': b'windows arm64'}
        self.sums = ''.join(f'{self.digest(data)}  {name}\n' for name, data in sorted(self.files.items()))
        self.files.update({'SHA256SUMS.txt': self.sums.encode(), 'android.apk': b'unchanged android'})
        self.release = {'tag_name': 'v0.2.0', 'draft': False, 'body': 'Existing notes', 'assets': [
            {'id': index, 'name': name, 'digest': 'sha256:'+self.digest(data), 'size': len(data)}
            for index, (name, data) in enumerate(self.files.items())]}

    @staticmethod
    def digest(data):
        return hashlib.sha256(data).hexdigest()

    def test_checksum_update_preserves_both_windows_entries(self):
        result = macos_update.updated_checksums(self.sums, self.version, 'b'*64,
                                               macos_update.assets_by_name(self.release))
        self.assertIn('b'*64+'  '+self.mac, result)
        for line in self.sums.splitlines():
            if self.mac not in line:
                self.assertIn(line, result)

    def test_invalid_checksum_list_and_wrong_existing_digest_are_rejected(self):
        assets = macos_update.assets_by_name(self.release)
        for sums in (self.sums+self.sums.splitlines()[0]+'\n', self.sums.splitlines()[0]+'\n', '../other\n'):
            with self.subTest(sums=sums), self.assertRaises(ValueError):
                macos_update.updated_checksums(sums, self.version, 'b'*64, assets)
        assets['TermPilot-0.2.0-windows-x64-portable.zip']['digest'] = 'sha256:'+'0'*64
        with self.assertRaisesRegex(ValueError, 'Windows checksum'):
            macos_update.updated_checksums(self.sums, self.version, 'b'*64, assets)

    def test_moved_tag_is_rejected_before_release_changes(self):
        with patch.object(macos_update, 'api', return_value={'object': {'type': 'commit', 'sha': 'b'*40}}):
            with self.assertRaisesRegex(ValueError, 'built commit'):
                macos_update.verify_tag('example/project', 'v0.2.0', self.commit)

    def run_publisher(self, change_other_asset=False):
        calls = []
        release = copy.deepcopy(self.release)

        def gh(*args):
            calls.append(args)
            if args[0] == 'api':
                if '/git/ref/' in args[1]:
                    return json.dumps({'object': {'type': 'tag', 'sha': 'c'*40}})
                if '/git/tags/' in args[1]:
                    return json.dumps({'object': {'type': 'commit', 'sha': self.commit}})
                return json.dumps(release)
            if args[1] == 'download':
                name = args[args.index('--pattern')+1]
                (Path(args[args.index('--dir')+1])/name).write_bytes(self.files[name])
            elif args[1] == 'upload':
                self.assertEqual(args[3:5], ('dist/release/'+self.mac, 'dist/release/SHA256SUMS.txt'))
                for path in map(Path, args[3:5]):
                    asset = next(a for a in release['assets'] if a['name'] == path.name)
                    asset.update(id=asset['id']+100, digest='sha256:'+self.digest(path.read_bytes()), size=path.stat().st_size)
                if change_other_asset:
                    next(a for a in release['assets'] if a['name'] == 'android.apk')['id'] += 1
            return ''

        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            try:
                os.chdir(directory)
                package = Path('dist/release')/self.mac
                package.parent.mkdir(parents=True)
                package.write_bytes(b'new mac')
                with patch.dict(os.environ, GH_REPO='example/project', RELEASE_TAG='v0.2.0', RELEASE_COMMIT=self.commit), \
                     patch.object(macos_update, 'gh', side_effect=gh):
                    if change_other_asset:
                        with self.assertRaisesRegex(ValueError, 'unrelated release asset'):
                            macos_update.main()
                    else:
                        macos_update.main()
                        self.assertEqual((Path('dist/release-backup')/self.mac).read_bytes(), b'old mac')
                        notes = Path('dist/release/macos-release-notes.md').read_text()
                        self.assertIn('Existing notes', notes)
                        self.assertIn(self.commit, notes)
            finally:
                os.chdir(previous)
        return calls

    def test_publisher_backs_up_and_replaces_only_macos_and_checksums(self):
        calls = self.run_publisher()
        edit = next(c for c in calls if c[:2] == ('release', 'edit'))
        self.assertIn('v0.2.0-aaaaaaa', edit)
        self.assertFalse(any(c[:2] in [('release', 'create'), ('release', 'delete')] for c in calls))

    def test_unrelated_asset_change_prevents_release_metadata_update(self):
        calls = self.run_publisher(change_other_asset=True)
        self.assertFalse(any(c[:2] == ('release', 'edit') for c in calls))


if __name__ == '__main__':
    unittest.main()
