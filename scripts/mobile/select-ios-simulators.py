#!/usr/bin/env python3
"""Select iPhone/iPad devices supported by the selected Xcode's simulator SDK."""
import json
import os
from pathlib import Path
import subprocess
import sys


def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def select_types(state, sdk):
    runtimes = [r for r in state['runtimes'] if r.get('isAvailable')
                and '.iOS-' in r['identifier']
                and (17, 0, 0) <= version(r['version']) <= version(sdk)]
    if not runtimes:
        raise ValueError('No compatible iOS Simulator runtime installed for the selected Xcode')
    runtime = max(runtimes, key=lambda r: version(r['version']))
    # The global type list includes unsupported devices (including iPod touch
    # in the iPhone family). Only the runtime's supported list is authoritative.
    selected = []
    for family in ('iPhone', 'iPad'):
        types = [t for t in runtime.get('supportedDeviceTypes', [])
                 if t.get('productFamily') == family and t['name'].startswith(family)]
        if not types:
            raise ValueError('No supported ' + family + ' device type for ' + runtime['identifier'])
        selected.append(types[0])
    return runtime['identifier'], selected


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    folder = Path(sys.argv[1])
    state = json.loads(command('xcrun', 'simctl', 'list', '--json'))
    sdk = command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version')
    runtime, types = select_types(state, sdk)
    selected = []
    for kind in types:
        family = kind['productFamily']
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            device = command('xcrun', 'simctl', 'create', 'TermPilot CI ' + family,
                             kind['identifier'], runtime)
            with (folder / 'created').open('a', encoding='utf-8') as handle:
                handle.write(device + '\n')
        else:
            supported = {t['identifier'] for r in state['runtimes'] if r['identifier'] == runtime
                         for t in r.get('supportedDeviceTypes', [])
                         if t.get('productFamily') == family and t['name'].startswith(family)}
            devices = [d for d in state['devices'].get(runtime, []) if d.get('isAvailable')
                       and d.get('deviceTypeIdentifier') in supported]
            if not devices:
                raise ValueError('Create an available ' + family + ' simulator with the selected Xcode first')
            device = devices[0]['udid']
        selected.append(device)
    (folder / 'devices').write_text('\n'.join(selected) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
