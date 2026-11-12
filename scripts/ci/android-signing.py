#!/usr/bin/env python3
"""Decode an explicitly requested CI key outside the source/distribution tree."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_signing import prepare_signing_key

if __name__ == '__main__':
    prepare_signing_key()
