#!/usr/bin/env python3
"""Release metadata, native architecture checks and archives. Build-time only."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ("macos", "windows")
ARCHITECTURES = ("x64", "arm64")


def valid_version(value):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value):
        raise ValueError("Version must be major.minor.patch (no prerelease suffix)")
    # Windows VERSIONINFO components are 16-bit values.
    if any(int(part) > 65534 for part in value.split(".")):
        raise ValueError("Version component exceeds Windows VERSIONINFO limits")
    return value


def project_version(tag=None):
    with (ROOT / "Cargo.toml").open("rb") as handle:
        version = valid_version(tomllib.load(handle)["workspace"]["package"]["version"])
    with (ROOT / "apps/macos/Resources/Info.plist").open("rb") as handle:
        mac_version = plistlib.load(handle)["CFBundleShortVersionString"]
    if version != mac_version:
        raise ValueError("Cargo.toml and macOS Info.plist versions must match")
    for name in ("apps/windows/package.json", "apps/windows/package-lock.json",
                 "apps/windows/src-tauri/tauri.conf.json"):
        metadata = json.loads((ROOT / name).read_text(encoding="utf-8"))
        if metadata["version"] != version:
            raise ValueError(f"{name} version must match Cargo.toml ({version})")
        if name.endswith("package-lock.json") and metadata["packages"][""]["version"] != version:
            raise ValueError(f"{name} root package version must match Cargo.toml ({version})")
    for name in ("apps/windows/src-tauri/Cargo.toml", "engines/rdp/Cargo.toml"):
        with (ROOT / name).open("rb") as handle:
            if tomllib.load(handle)["package"]["version"] != version:
                raise ValueError(f"{name} version must match Cargo.toml ({version})")
    for name, pattern in (
        ("apps/android/app/build.gradle.kts", r'versionName\s*=\s*"([^"]+)"'),
        ("apps/ios/project.yml", r"MARKETING_VERSION:\s*['\"]([^'\"]+)['\"]"),
    ):
        match = re.search(pattern, (ROOT / name).read_text(encoding='utf-8'))
        if not match or match[1] != version:
            raise ValueError(f"{name} version must match Cargo.toml ({version})")
    if tag and tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} must match project version v{version}")
    return version


def stamp_macos(path, version, build):
    valid_version(version)
    if not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Build number must be a positive integer")
    with path.open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "com.termpilot.app":
        raise ValueError("Unexpected application identity")
    info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    with path.open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=False)


def pe_machine(path):
    with path.open("rb") as handle:
        if handle.read(2) != b"MZ":
            raise ValueError(f"Not a Windows PE binary: {path}")
        handle.seek(0x3C)
        offset = struct.unpack("<I", handle.read(4))[0]
        handle.seek(offset)
        if handle.read(4) != b"PE\0\0":
            raise ValueError(f"Invalid PE header: {path}")
        return struct.unpack("<H", handle.read(2))[0]


def audit(source, platform, arch):
    if not source.is_dir():
        raise ValueError(f"Missing distribution: {source}")
    if platform == "macos":
        if source.name != "TermPilot.app":
            raise ValueError("macOS input must be TermPilot.app")
        required = ["Contents/MacOS/TermPilot", "Contents/Resources/engine/termpilot-engine", "Contents/Resources/engine/termpilot-rdp"]
        notices = "Contents/Resources/"
        source_archive = "TermPilot-CorrespondingSource.tar.gz"
    else:
        required = ["TermPilot.exe", "app/TermPilot.exe", "app/engine/termpilot-engine.exe", "app/engine/termpilot-rdp.exe", "app/engine/termpilot-media.exe", "app/engine/libde265.dll", "app/engine/fdk-aac.dll"]
        notices = "app/"
        source_archive = "CorrespondingSource.tar.gz"
        unexpected = sorted(path.name for path in source.iterdir() if path.name not in {"TermPilot.exe", "app", "AppData"})
        if unexpected:
            raise ValueError(f"Unexpected Windows root entries; runtime belongs in app/: {unexpected}")
        data = source / "AppData"
        if not data.is_dir() or any(data.iterdir()):
            raise ValueError("Windows release must contain an empty AppData directory; never package user data")
        if not (source / "app/Assets/TermPilot.ico").is_file():
            raise ValueError("Missing Windows application icon")
    for relative in required + [notices + item for item in
            ("LICENSE.txt", "NOTICE.md", "LICENSE-ISHARESCREEN.txt", source_archive,
             "Licenses/dependencies.json")]:
        if not (source / relative).is_file() or (source / relative).stat().st_size == 0:
            raise ValueError(f"Missing or empty packaged file: {relative}")
    for relative in required:
        path = source / relative
        if platform == "windows":
            expected = {"x64": 0x8664, "arm64": 0xAA64}[arch]
            if pe_machine(path) != expected:
                raise ValueError(f"Wrong {arch} PE architecture: {relative}")
        else:
            expected = {"x64": "x86_64", "arm64": "arm64"}[arch]
            actual = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
            if actual != [expected]:
                raise ValueError(f"Expected native {expected} binary, got {actual}: {relative}")
    if platform == "windows":
        for kind in ("Tauri", "Frontend"):
            if not (source / f"app/Licenses/{kind}/dependencies.json").is_file():
                raise ValueError(f"Missing {kind} license inventory")
        if any(p.suffix.lower() == ".winmd" or p.name.lower() in {"coreclr.dll", "hostfxr.dll", "microsoft.ui.xaml.dll"} for p in source.rglob("*")):
            raise ValueError("Obsolete WinUI/.NET runtime in Tauri distribution")
    for path in source.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(source.resolve()):
            raise ValueError(f"External symlink in distribution: {path}")
        if not path.is_file():
            continue
        name = path.name.lower()
        if (name in {"node", "node.exe", "python", "python.exe", "python3", "python3.exe"}
                or path.suffix.lower() in {".py", ".pyc", ".cjs", ".mjs", ".node"}
                or re.match(r"(?:lib)?python\d.*\.(?:dll|dylib)$", name)
                or "node_modules" in path.parts):
            raise ValueError(f"Interpreter or legacy runtime in distribution: {path}")


def archive_name(version, platform, arch):
    valid_version(version)
    suffix = "-portable" if platform == "windows" else ""
    return f"TermPilot-{version}-{platform}-{arch}{suffix}.zip"


def archive(source, output, platform, arch, version):
    audit(source, platform, arch)
    output.mkdir(parents=True, exist_ok=True)
    if output.resolve().is_relative_to(source.resolve()):
        raise ValueError("Archive output cannot be inside the application directory")
    destination = output / archive_name(version, platform, arch)
    temporary = destination.with_suffix(".partial.zip")
    try:
        if platform == "macos":
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                            str(source), str(temporary)], check=True)
        else:
            # NuGet runtime files may carry reproducible timestamps before 1980.
            # Clamp only ZIP metadata to its supported date range.
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, strict_timestamps=False) as bundle:
                for path in sorted(source.rglob("*")):
                    if path.is_file() or (path.is_dir() and not any(path.iterdir())):
                        bundle.write(path, Path("TermPilot") / path.relative_to(source))
        with zipfile.ZipFile(temporary) as bundle:
            bad_file = bundle.testzip()
            if bad_file:
                raise ValueError(f"Corrupt archive member: {bad_file}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def checksums(directory, version):
    expected = {archive_name(version, platform, arch)
                for platform in PLATFORMS for arch in ARCHITECTURES}
    actual = {path.name for path in directory.glob("*.zip")}
    if actual != expected:
        raise ValueError(f"Expected four release archives; missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
    lines = []
    for name in sorted(expected):
        with (directory / name).open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        lines.append(f"{digest}  {name}\n")
    result = directory / "SHA256SUMS.txt"
    result.write_text("".join(lines), encoding="utf-8", newline="\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    version_parser = commands.add_parser("version")
    version_parser.add_argument("--tag")
    version_parser.add_argument("--github-output", type=Path)
    stamp_parser = commands.add_parser("stamp-macos")
    stamp_parser.add_argument("plist", type=Path)
    stamp_parser.add_argument("--version", required=True)
    stamp_parser.add_argument("--build", required=True)
    for command in ("audit", "archive"):
        child = commands.add_parser(command)
        child.add_argument("--platform", choices=PLATFORMS, required=True)
        child.add_argument("--arch", choices=ARCHITECTURES, required=True)
        child.add_argument("--input", type=Path, required=True)
        if command == "archive":
            child.add_argument("--version", required=True)
            child.add_argument("--output", type=Path, default=ROOT / "dist/release")
    checksum_parser = commands.add_parser("checksums")
    checksum_parser.add_argument("directory", type=Path)
    checksum_parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if args.command == "version":
        version = project_version(args.tag)
        print(version)
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8") as handle:
                handle.write(f"version={version}\n")
    elif args.command == "stamp-macos":
        if not args.plist.resolve().is_relative_to(ROOT / "dist"):
            raise ValueError("Only stamp a packaged plist inside this checkout's dist directory")
        stamp_macos(args.plist, args.version, args.build)
    elif args.command == "audit":
        audit(args.input, args.platform, args.arch)
        print(f"Validated {args.platform} {args.arch}: {args.input}")
    elif args.command == "archive":
        if not args.output.resolve().is_relative_to(ROOT / "dist"):
            raise ValueError("Archive output must be inside this checkout's dist directory")
        print(archive(args.input, args.output, args.platform, args.arch, args.version))
    else:
        print(checksums(args.directory, args.version))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, struct.error, subprocess.CalledProcessError) as error:
        sys.exit(f"Release error: {error}")
