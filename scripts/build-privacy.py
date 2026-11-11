#!/usr/bin/env python3
"""Build with anonymous source paths, without changing runtime data locations.

Use this wrapper for release builds. --environment is for PowerShell entry
points; no credentials or account settings are read by this module.
"""
from pathlib import Path
import json
import os
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def source_maps(root=ROOT, home=None, environment=None):
    home = Path.home() if home is None else Path(home)
    environment = os.environ if environment is None else environment
    # rustc uses the last matching mapping. Specific roots must come last.
    paths = [(home, '/build/user'),
             (Path(environment.get('CARGO_HOME', home / '.cargo')), '/build/cargo'),
             (Path(environment.get('RUSTUP_HOME', home / '.rustup')), '/build/rustup'),
             (Path(root), '/build/termpilot')]
    result = []
    for source, destination in paths:
        for spelling in dict.fromkeys([str(source), str(source.resolve()),
                                      str(source).replace('\\', '/')]):
            if (spelling, destination) not in result:
                result.append((spelling, destination))
    return result


def build_environment(environment=None, maps=None, windows=None):
    env = dict(os.environ if environment is None else environment)
    maps = source_maps(environment=env) if maps is None else maps
    windows = os.name == 'nt' if windows is None else windows
    if 'CARGO_ENCODED_RUSTFLAGS' in env:
        flags = [value for value in env['CARGO_ENCODED_RUSTFLAGS'].split('\x1f') if value]
    else:
        # Cargo's ordinary RUSTFLAGS is whitespace-delimited, not shell code.
        flags = env.get('RUSTFLAGS', '').split()
    additions = [f'--remap-path-prefix={source}={dest}' for source, dest in maps]
    if windows:
        # MSVC otherwise records the full PDB location in the shipped PE file.
        additions += ['-Clink-arg=/PDBALTPATH:%_PDB%']
    for flag in additions:
        if flag not in flags:
            flags.append(flag)
    env['CARGO_ENCODED_RUSTFLAGS'] = '\x1f'.join(flags)
    env['CARGO_INCREMENTAL'] = '0'
    # cc-rs/CMake dependencies also embed __FILE__ and source debug paths.
    native = [f'/pathmap:{source}={dest}' if windows else
              f'-ffile-prefix-map={source}={dest}' for source, dest in maps]
    if windows:
        # MSVC accepts /pathmap only with deterministic compilation enabled;
        # otherwise it merely warns and silently retains the original paths.
        native.insert(0, '/experimental:deterministic')
        # ring selects the GNU-style clang driver on Windows ARM64, while
        # other dependencies use cl.exe. Translate only in Clang's documented
        # driver override hook; MSVC keeps its original /pathmap flags. Regex
        # replacement operates on whole arguments, including paths with spaces.
        # Release objects also omit CodeView records of the compiler command
        # and output filename, which /pathmap does not rewrite in Clang.
        edits = r'x/experimental:deterministic s/^.pathmap:(.*)$/-ffile-prefix-map=\1/ +-g0'
        overrides = env.get('CCC_OVERRIDE_OPTIONS', '#')
        if edits not in overrides:
            overrides = (overrides + ' ' + edits).strip()
        env['CCC_OVERRIDE_OPTIONS'] = overrides
    for name in ('CFLAGS', 'CXXFLAGS'):
        value = env.get(name, '')
        for flag in native:
            quoted = subprocess.list2cmdline([flag]) if windows else shlex.quote(flag)
            if quoted not in value:
                value = (value + ' ' + quoted).strip()
        env[name] = value
        if windows:
            # rquickjs-sys replaces plain CFLAGS on Windows. cc-rs also reads
            # target-specific flags, so retain anonymous paths even when a
            # dependency overwrites the generic variable in its build script.
            for target in ('x86_64_pc_windows_msvc', 'aarch64_pc_windows_msvc'):
                target_name = name + '_' + target
                target_value = env.get(target_name, value)
                for flag in native:
                    quoted = subprocess.list2cmdline([flag])
                    if quoted not in target_value:
                        target_value = (target_value + ' ' + quoted).strip()
                env[target_name] = target_value
    return env


def swift_flags(maps):
    flags = ['-file-compilation-dir', '/build/termpilot']
    # Swift applies its first matching prefix (unlike rustc's last match).
    for source, dest in reversed(maps):
        flags += ['-file-prefix-map', f'{source}={dest}']
    return flags


def main():
    args = sys.argv[1:]
    maps = source_maps()
    env = build_environment(maps=maps)
    if args == ['--environment']:
        keys = ['CARGO_ENCODED_RUSTFLAGS', 'CARGO_INCREMENTAL', 'CFLAGS', 'CXXFLAGS']
        if os.name == 'nt':
            keys += ['CCC_OVERRIDE_OPTIONS']
            keys += [name + '_' + target for name in ('CFLAGS', 'CXXFLAGS')
                     for target in ('x86_64_pc_windows_msvc', 'aarch64_pc_windows_msvc')]
        print(json.dumps({key: env[key] for key in keys}))
        return
    if args and args[0] == '--':
        args.pop(0)
    if not args:
        raise SystemExit('Usage: build-privacy.py COMMAND [ARGS...] | --environment')
    name = Path(args[0]).name
    if name == 'swift' and len(args) > 1 and args[1] in ('build', 'test'):
        for flag in swift_flags(maps):
            args += ['-Xswiftc', flag]
        for source, dest in maps:
            args += ['-Xcc', f'-ffile-prefix-map={source}={dest}']
    elif name == 'xcodebuild':
        flags = ' '.join('"' + value.replace('"', '\\"') + '"'
                         for value in swift_flags(maps))
        args += ['OTHER_SWIFT_FLAGS=$(inherited) ' + flags,
                 'OTHER_CFLAGS=$(inherited) ' + env['CFLAGS'],
                 'OTHER_CPLUSPLUSFLAGS=$(inherited) ' + env['CXXFLAGS']]
    raise SystemExit(subprocess.call(args, env=env))


if __name__ == '__main__':
    main()
