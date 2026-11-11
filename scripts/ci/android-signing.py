#!/usr/bin/env python3
"""Decode an explicitly requested CI key outside the source/distribution tree."""
import base64
import os
from pathlib import Path

required = ('ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')
if any(not os.environ.get(name) for name in required):
    raise SystemExit('Android signing requested: configure all four ANDROID signing secrets')
path = Path(os.environ['RUNNER_TEMP']) / 'termpilot-android-signing.jks'
path.write_bytes(base64.b64decode(os.environ[required[0]], validate=True))
path.chmod(0o600)
with open(os.environ['GITHUB_ENV'], 'a') as output:
    output.write('TERMPILOT_ANDROID_SIGN=1\nANDROID_KEYSTORE_PATH=' + str(path) + '\n')
print('Temporary Android signing key prepared; private values are not logged.')
