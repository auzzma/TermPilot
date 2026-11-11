import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_script("release")


def write_pe(path, machine):
    path.parent.mkdir(parents=True, exist_ok=True)
    contents = bytearray(134)
    contents[:2] = b"MZ"
    struct.pack_into("<I", contents, 0x3C, 128)
    contents[128:132] = b"PE\0\0"
    struct.pack_into("<H", contents, 132, machine)
    path.write_bytes(contents)


def windows_fixture(path, arch):
    (path / "AppData").mkdir(parents=True)
    (path / "app/Assets").mkdir(parents=True)
    (path / "app/Assets/TermPilot.ico").write_bytes(b"fixture")
    machine = {"x64": 0x8664, "arm64": 0xAA64}[arch]
    for relative in ("TermPilot.exe", "app/TermPilot.exe", "app/engine/termpilot-engine.exe", "app/engine/termpilot-rdp.exe", "app/engine/termpilot-media.exe", "app/engine/libde265.dll", "app/engine/fdk-aac.dll"):
        write_pe(path / relative, machine)
    for relative in ("LICENSE.txt", "NOTICE.md", "LICENSE-ISHARESCREEN.txt", "CorrespondingSource.tar.gz",
                     "Licenses/dependencies.json", "Licenses/Tauri/dependencies.json", "Licenses/Frontend/dependencies.json"):
        target = path / "app" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture", encoding="utf-8")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write_version_fixture(self):
        (self.root / "Cargo.toml").write_text('[workspace.package]\nversion = "0.2.0"\n')
        plist = self.root / "apps/macos/Resources/Info.plist"
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.2.0"}))
        for name in ("apps/windows/package.json", "apps/windows/package-lock.json", "apps/windows/src-tauri/tauri.conf.json"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"version": "0.2.0", "packages": {"": {"version": "0.2.0"}}}))
        for name in ("apps/windows/src-tauri/Cargo.toml", "engines/rdp/Cargo.toml"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('[package]\nversion = "0.2.0"\n')
        for name, content in (
            ('apps/android/app/build.gradle.kts', 'versionName = "0.2.0"'),
            ('apps/ios/project.yml', "MARKETING_VERSION: '0.2.0'"),
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        return plist

    def test_version_matches_tag_and_both_projects(self):
        plist = self.write_version_fixture()
        with patch.object(release, "ROOT", self.root):
            self.assertEqual(release.project_version("v0.2.0"), "0.2.0")
            with self.assertRaisesRegex(ValueError, "Tag"):
                release.project_version("v0.3.0")
            plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.0"}))
            with self.assertRaisesRegex(ValueError, "must match"):
                release.project_version()

    def test_version_rejects_stale_tauri_or_rdp_metadata(self):
        self.write_version_fixture()
        names = ("apps/windows/package.json", "apps/windows/package-lock.json",
                 "apps/windows/src-tauri/tauri.conf.json", "apps/windows/src-tauri/Cargo.toml", "engines/rdp/Cargo.toml",
                 "apps/android/app/build.gradle.kts", "apps/ios/project.yml")
        for name in names:
            with self.subTest(name=name), patch.object(release, "ROOT", self.root):
                path = self.root / name
                original = path.read_text()
                path.write_text(original.replace("0.2.0", "0.1.0"))
                with self.assertRaisesRegex(ValueError, "must match"):
                    release.project_version()
                path.write_text(original)
        lock = self.root / "apps/windows/package-lock.json"
        lock.write_text(json.dumps({"version": "0.2.0", "packages": {"": {"version": "0.1.0"}}}))
        with patch.object(release, "ROOT", self.root), self.assertRaisesRegex(ValueError, "root package version"):
            release.project_version()

    def test_invalid_version_rejected(self):
        for version in ("../0.2.0", "0.2.0\n", "0.2.0-rc1", "01.2.0", "1.2.65535"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.valid_version(version)

    def test_macos_stamp_preserves_identity_and_permissions(self):
        path = self.root / "Info.plist"
        original = {"CFBundleIdentifier": "com.termpilot.app", "NSMicrophoneUsageDescription": "Audio"}
        path.write_bytes(plistlib.dumps(original))
        release.stamp_macos(path, "0.2.1", "37")
        data = plistlib.loads(path.read_bytes())
        self.assertEqual(data["CFBundleVersion"], "37")
        self.assertEqual(data["CFBundleShortVersionString"], "0.2.1")
        self.assertEqual({key: data[key] for key in original}, original)
        with self.assertRaises(ValueError):
            release.stamp_macos(path, "0.2.1", "0")

    def test_windows_native_architectures_and_mixed_dll_rejected(self):
        for arch in ("x64", "arm64"):
            source = self.root / arch
            windows_fixture(source, arch)
            release.audit(source, "windows", arch)
            wrong = "arm64" if arch == "x64" else "x64"
            with self.assertRaisesRegex(ValueError, "architecture"):
                release.audit(source, "windows", wrong)
            write_pe(source / "app/engine/termpilot-engine.exe", 0x14C)
            with self.assertRaisesRegex(ValueError, "termpilot-engine.exe"):
                release.audit(source, "windows", arch)

    def test_windows_root_rejects_loose_dependencies(self):
        source = self.root / "app"
        windows_fixture(source, "x64")
        (source / "leftover.winmd").write_bytes(b"metadata")
        with self.assertRaisesRegex(ValueError, "Unexpected Windows root"):
            release.audit(source, "windows", "x64")

    def test_bad_pe_header(self):
        path = self.root / "fake.exe"
        path.write_bytes(b"not an executable")
        with self.assertRaisesRegex(ValueError, "PE"):
            release.pe_machine(path)

    def test_windows_package_rejects_user_data(self):
        source = self.root / "app"
        windows_fixture(source, "x64")
        (source / "AppData/credential.key").write_bytes(b"private")
        with self.assertRaisesRegex(ValueError, "never package user data"):
            release.archive(source, self.root / "out", "windows", "x64", "0.2.0")
        self.assertFalse((self.root / "out").exists())

    def test_windows_archive_has_one_product_directory_and_all_resources(self):
        source = self.root / "app"
        windows_fixture(source, "arm64")
        (source / "app/.hidden-resource").write_bytes(b"resource")
        output = release.archive(source, self.root / "out", "windows", "arm64", "0.2.0")
        self.assertEqual(output.name, "TermPilot-0.2.0-windows-arm64-portable.zip")
        with zipfile.ZipFile(output) as bundle:
            self.assertIn("TermPilot/TermPilot.exe", bundle.namelist())
            self.assertIn("TermPilot/AppData/", bundle.namelist())
            self.assertIn("TermPilot/app/TermPilot.exe", bundle.namelist())
            self.assertIn("TermPilot/app/engine/termpilot-engine.exe", bundle.namelist())
            self.assertIn("TermPilot/app/.hidden-resource", bundle.namelist())
            self.assertIn("TermPilot/app/Licenses/Tauri/dependencies.json", bundle.namelist())
            self.assertTrue(all(name.startswith("TermPilot/") for name in bundle.namelist()))

    def test_windows_archive_accepts_early_dependency_timestamps(self):
        source = self.root / "app"
        windows_fixture(source, "x64")
        dependency = source / "app/engine/termpilot-engine.exe"
        contents = dependency.read_bytes()
        os.utime(dependency, (0, 0))
        original_mtime = dependency.stat().st_mtime
        output = release.archive(source, self.root / "out", "windows", "x64", "0.2.0")
        with zipfile.ZipFile(output) as bundle:
            member = "TermPilot/app/engine/termpilot-engine.exe"
            self.assertEqual(bundle.getinfo(member).date_time, (1980, 1, 1, 0, 0, 0))
            self.assertEqual(bundle.read(member), contents)
            self.assertIsNone(bundle.testzip())
        self.assertEqual(dependency.stat().st_mtime, original_mtime)

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS ditto")
    def test_macos_archive_preserves_app_root_and_executable_mode(self):
        source = self.root / "TermPilot.app"
        for relative in ("Contents/MacOS/TermPilot", "Contents/Resources/engine/termpilot-engine", "Contents/Resources/engine/termpilot-rdp",
                         "Contents/Resources/LICENSE.txt", "Contents/Resources/NOTICE.md",
                         "Contents/Resources/LICENSE-ISHARESCREEN.txt",
                         "Contents/Resources/TermPilot-CorrespondingSource.tar.gz",
                         "Contents/Resources/Licenses/dependencies.json"):
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
        (source / "Contents/MacOS/TermPilot").chmod(0o755)
        with patch.object(release.subprocess, "check_output", return_value="arm64\n"):
            archive = release.archive(source, self.root / "out", "macos", "arm64", "0.2.0")
        with zipfile.ZipFile(archive) as bundle:
            binary = bundle.getinfo("TermPilot.app/Contents/MacOS/TermPilot")
            self.assertEqual((binary.external_attr >> 16) & 0o777, 0o755)
            self.assertIn("TermPilot.app/Contents/Resources/engine/termpilot-engine", bundle.namelist())

    def test_missing_runtime_or_license_fails_audit(self):
        source = self.root / "app"
        windows_fixture(source, "x64")
        (source / "app/engine/termpilot-engine.exe").unlink()
        with self.assertRaisesRegex(ValueError, "termpilot-engine.exe"):
            release.audit(source, "windows", "x64")

    def test_interpreter_cannot_leak_into_archive(self):
        source = self.root / "app"
        windows_fixture(source, "x64")
        (source / "app/python313.dll").write_bytes(b"runtime")
        with self.assertRaisesRegex(ValueError, "Interpreter"):
            release.archive(source, self.root / "out", "windows", "x64", "0.2.0")
        self.assertFalse((self.root / "out").exists())

    def test_checksums_require_exactly_four_packages(self):
        for platform in release.PLATFORMS:
            for arch in release.ARCHITECTURES:
                name = release.archive_name("0.2.0", platform, arch)
                (self.root / name).write_bytes(name.encode())
        output = release.checksums(self.root, "0.2.0")
        lines = output.read_text().splitlines()
        self.assertEqual(len(lines), 4)
        for line in lines:
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256(name.encode()).hexdigest())
        extra = self.root / "stale.zip"
        extra.write_bytes(b"old")
        with self.assertRaisesRegex(ValueError, "extra"):
            release.checksums(self.root, "0.2.0")
        extra.unlink()
        next(self.root.glob("*.zip")).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            release.checksums(self.root, "0.2.0")

