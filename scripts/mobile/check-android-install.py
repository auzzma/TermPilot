#!/usr/bin/env python3
"""Install and launch the distributable APK on a disposable emulator."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import time
import zipfile

PACKAGE = 'com.termpilot.app'


def command(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout.strip() + '\n' + result.stderr.strip())
    return result.stdout.strip()


def select_emulator(devices, requested=None):
    ready = [line.split()[0] for line in devices.splitlines()[1:]
             if len(line.split()) >= 2 and line.split()[1] == 'device'
             and line.split()[0].startswith('emulator-')]
    if requested:
        if requested not in ready:
            raise ValueError('The selected target must be a running Android emulator')
        return requested
    if len(ready) != 1:
        raise ValueError('Expected exactly one running Android emulator; use --serial')
    return ready[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--serial')
    parser.add_argument('--reset-test-app', action='store_true',
                        help='Remove the existing app and its fixture data on the test emulator')
    args = parser.parse_args()
    if not args.apk.is_file() or args.apk.suffix != '.apk':
        parser.error('Expected one existing APK')
    sdk = Path(os.environ['ANDROID_HOME'])
    adb = sdk/'platform-tools/adb'
    badging = command(sdk/'build-tools/36.0.0/aapt', 'dump', 'badging', args.apk)
    match = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
    if not match or match.group(1) != PACKAGE:
        raise ValueError('Only the TermPilot APK can be tested')
    serial = select_emulator(command(adb, 'devices'), args.serial)

    def device(*arguments):
        return command(adb, '-s', serial, *arguments)

    if device('shell', 'getprop', 'ro.kernel.qemu') != '1':
        raise ValueError('Installation checks are restricted to emulators')
    supported = set(device('shell', 'getprop', 'ro.product.cpu.abilist').split(','))
    with zipfile.ZipFile(args.apk) as archive:
        packaged = {name.split('/')[1] for name in archive.namelist()
                    if name.startswith('lib/') and name.endswith('.so')}
    if not supported.intersection(packaged):
        raise ValueError('APK architecture does not match the test emulator')
    if 'package:' + PACKAGE in device('shell', 'pm', 'list', 'packages', PACKAGE).splitlines():
        if not args.reset_test_app:
            raise ValueError('Use a disposable emulator or explicitly pass --reset-test-app')
        device('uninstall', PACKAGE)

    for label, options in [('Fresh installation', []), ('Same-key update', ['-r'])]:
        result = device('install', '--no-streaming', *options, args.apk)
        if 'Success' not in result:
            raise RuntimeError(label + ' failed: ' + result)
        device('shell', 'am', 'force-stop', PACKAGE)
        started = device('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
        if 'Status: ok' not in started or 'Error:' in started:
            raise RuntimeError('Packaged app failed to launch: ' + started)
        time.sleep(3)
        if not device('shell', 'pidof', PACKAGE):
            raise RuntimeError('Packaged app exited immediately after launch')
        print(label + ' and startup passed: ' + args.apk.name, flush=True)
    device('shell', 'am', 'force-stop', PACKAGE)


if __name__ == '__main__':
    main()
