import importlib.util
import io
import json
from pathlib import Path
import subprocess
import shutil
import shlex
import os
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load('build-privacy')
audit = load('audit-privacy')


class PrivacyTests(unittest.TestCase):
    def test_flags_preserve_existing_options_and_space_containing_paths(self):
        maps = [('/home/fixture user', '/build/user'),
                ('/home/fixture user/My App', '/build/termpilot')]
        env = build.build_environment({'CARGO_ENCODED_RUSTFLAGS': '-C\x1fopt-level=2',
                                       'CFLAGS': '-DKEEP=1'}, maps, windows=False)
        flags = env['CARGO_ENCODED_RUSTFLAGS'].split('\x1f')
        self.assertEqual(flags[:2], ['-C', 'opt-level=2'])
        self.assertIn('--remap-path-prefix=/home/fixture user/My App=/build/termpilot', flags)
        self.assertIn('-DKEEP=1', env['CFLAGS'])
        self.assertEqual(env, build.build_environment(env, maps, windows=False))

    def test_windows_pdb_path_is_not_absolute(self):
        env = build.build_environment({}, [('C:/Build Agent/app', '/build/termpilot')], windows=True)
        self.assertIn('-Clink-arg=/PDBALTPATH:%_PDB%', env['CARGO_ENCODED_RUSTFLAGS'].split('\x1f'))
        self.assertIn('/pathmap:', env['CFLAGS'])
        self.assertIn('/experimental:deterministic', env['CFLAGS'])

    def test_windows_paths_survive_dependency_overwriting_generic_flags(self):
        maps = [('C:/Build Agent/app', '/build/termpilot')]
        env = build.build_environment({'CFLAGS': '/DKEEP=1',
            'CFLAGS_aarch64_pc_windows_msvc': '/DTARGET=1'}, maps, windows=True)
        for target in ('x86_64_pc_windows_msvc', 'aarch64_pc_windows_msvc'):
            self.assertIn('/pathmap:', env['CFLAGS_' + target])
            self.assertIn('/experimental:deterministic', env['CFLAGS_' + target])
            self.assertIn('/pathmap:', env['CXXFLAGS_' + target])
        self.assertIn('/DKEEP=1', env['CFLAGS_x86_64_pc_windows_msvc'])
        self.assertIn('/DTARGET=1', env['CFLAGS_aarch64_pc_windows_msvc'])
        self.assertEqual(env, build.build_environment(env, maps, windows=True))
        # A dependency can replace CFLAGS without erasing the target mapping.
        env['CFLAGS'] = '/std:c11'
        self.assertIn('/pathmap:', env['CFLAGS_x86_64_pc_windows_msvc'])

    @unittest.skipUnless(shutil.which('clang'), 'Clang required for Windows compiler probes')
    def test_windows_clang_and_clang_cl_accept_maps_and_remove_source_paths(self):
        # Exercise ring's GNU driver AND aws-lc's CL driver, both architectures,
        # paths with spaces, and real COFF output. Reject ignored flags too.
        with tempfile.TemporaryDirectory(prefix='private clang fixture ') as folder:
            root = Path(folder)
            source = root / 'probe.c'
            source.write_text('const char *source_path = __FILE__;\n', encoding='utf-8')
            output = root / 'probe.obj'
            env = build.build_environment(os.environ, [(root.as_posix(), '/build/fixture')], windows=True)
            for arch in ('aarch64', 'x86_64'):
                flags = shlex.split(env['CFLAGS_' + arch + '_pc_windows_msvc'])
                for mode, debug_options in (
                    ('gcc', [('-g', '-gcodeview'), ('-g1',), ('-gline-directives-only',), ('-gdwarf-4',)]),
                    ('cl', [('/Z7',), ('-Z7',), ('/Zi',), ('/ZI',)]),
                ):
                    for debug in debug_options:
                        with self.subTest(arch=arch, driver=mode, debug=debug):
                            compile_args = (['/c', source.as_posix(), '/Fo' + str(output)]
                                            if mode == 'cl' else
                                            ['-c', source.as_posix(), '-o', str(output)])
                            result = subprocess.run([
                                'clang', '--driver-mode=' + mode,
                                '--target=' + arch + '-pc-windows-msvc', '-Werror',
                                *debug, *flags, *compile_args,
                            ], cwd=root, env=env, capture_output=True, text=True)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            data = output.read_bytes().replace(b'\\', b'/')
                            self.assertIn(b'/build/fixture/probe.c', data)
                            self.assertNotIn(root.as_posix().encode(), data)

    def test_nested_source_and_wide_paths_are_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            tar = io.BytesIO()
            with tarfile.open(fileobj=tar, mode='w:gz') as source:
                item = tarfile.TarInfo('TermPilot/tests/migration-poc/remote_config.py')
                payload = b'host = "10.24.35.46"'
                item.size = len(payload)
                source.addfile(item, io.BytesIO(payload))
            path = Path(folder) / 'release.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('app/CorrespondingSource.tar.gz', tar.getvalue())
                archive.writestr('app/program.exe', 'C:\\Users\\fixture\\source.rs'.encode('utf-16-le'))
                archive.writestr('AppData/vault.sqlite', b'not a real database')
            kinds = {kind for finding in audit.scan(path) for kind in finding['kinds']}
            self.assertEqual(kinds, {'hardcoded-live-test-address', 'absolute-user-directory',
                                     'user-data-or-private-signing-file'})

    def test_development_profile_exception_does_not_allow_build_paths(self):
        self.assertEqual(audit.findings(b'fixture', 'embedded.mobileprovision'),
                         ['device-specific-development-profile'])
        self.assertEqual(audit.findings(b'fixture', 'embedded.mobileprovision',
                                       allow_development_signing=True), [])
        self.assertIn('absolute-user-directory', audit.findings(
            b'/Users/fixture/source.rs', 'program', allow_development_signing=True))

    def test_source_audit_detects_another_build_accounts_path(self):
        path = ('/' + 'Users/' + 'another-builder/source.rs').encode()
        self.assertIn('absolute-user-directory', audit.findings(path, 'src/main.rs', source=True))
        self.assertEqual(audit.findings(b'/Users/fixture/source.rs',
                                       'tests/release/test_privacy.py', source=True), [])

    def test_source_archive_owner_identity_is_rejected(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as source:
            item = tarfile.TarInfo('README.md'); item.uname = 'fixture-owner'
            source.addfile(item, io.BytesIO())
        self.assertIn('archive-owner-identity', audit.scan_bytes(
            data.getvalue(), 'CorrespondingSource.tar.gz')[0]['kinds'])

    def test_macos_resource_fork_is_scanned_as_metadata(self):
        self.assertEqual(audit.scan_bytes(b'\x00\x05\x16\x07metadata',
                                         '__MACOSX/._CorrespondingSource.tar.gz'), [])
        self.assertIn('absolute-user-directory', audit.scan_bytes(
            b'\x00\x05\x16\x07/Users/fixture/private.txt',
            '__MACOSX/._CorrespondingSource.tar.gz')[0]['kinds'])

    @unittest.skipUnless(shutil.which('rustc'), 'Rust compiler required for the executable probe')
    def test_rust_file_macro_is_remapped_in_executable(self):
        # An executable regression catches flags that only strip DWARF but leave
        # file!()/panic strings intact. No network, Cargo cache or user data.
        with tempfile.TemporaryDirectory(prefix='private-build-fixture-') as folder:
            root = Path(folder)
            source = root / 'probe.rs'
            source.write_text('fn main() { println!("{}", file!()); }')
            output = root / ('probe.exe' if sys.platform == 'win32' else 'probe')
            linker = ['-Clink-arg=/PDBALTPATH:%_PDB%'] if sys.platform == 'win32' else []
            subprocess.run(['rustc', *linker, '--remap-path-prefix=' + folder + '=/build/fixture',
                            '-C', 'strip=debuginfo', str(source), '-o', str(output)], check=True)
            self.assertNotIn(folder.encode(), output.read_bytes())
            self.assertEqual(subprocess.check_output([str(output)], text=True).strip().replace('\\', '/'),
                             '/build/fixture/probe.rs')


if __name__ == '__main__':
    unittest.main()
