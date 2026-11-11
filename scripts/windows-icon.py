#!/usr/bin/env python3
"""Repackage the existing macOS icon's PNG representations as a Windows ICO."""
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]


def build():
    data = (ROOT / 'apps/macos/Resources/TermPilot.icns').read_bytes()
    assert data[:4] == b'icns'
    images, offset = {}, 8
    while offset < len(data):
        _, length = struct.unpack_from('>4sI', data, offset)
        payload = data[offset + 8:offset + length]
        if payload.startswith(b'\x89PNG\r\n\x1a\n'):
            width, height = struct.unpack_from('>II', payload, 16)
            if width == height and width in (32, 64, 128, 256):
                images[width] = payload
        offset += length
    assert set(images) == {32, 64, 128, 256}
    header = struct.pack('<HHH', 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, payloads = [], []
    for size, png in sorted(images.items()):
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(png), offset))
        payloads.append(png)
        offset += len(png)
    destination = ROOT / 'apps/windows/Assets/TermPilot.ico'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(header + b''.join(entries + payloads))
    print(destination)


if __name__ == '__main__':
    build()
