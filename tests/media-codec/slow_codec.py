#!/usr/bin/env python3
"""Validation-only IPC codec proxy. Simulates a busy decoder without saving pixels.

Usage: slow_codec.py /absolute/path/to/termpilot-media milliseconds
Never installed or used by a production client.
"""
import struct
import subprocess
import sys
import time


def exact(stream, size):
    parts = bytearray()
    while len(parts) < size:
        data = stream.read(size - len(parts))
        if not data:
            raise EOFError()
        parts.extend(data)
    return bytes(parts)


def main():
    delay = float(sys.argv[2]) / 1000
    assert 0 <= delay <= 0.2
    child = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        while True:
            try:
                header = exact(sys.stdin.buffer, 16)
            except EOFError:
                break
            kind, _, _, size = struct.unpack('<4I', header)
            assert size <= 16 * 1024 * 1024
            payload = exact(sys.stdin.buffer, size)
            if kind == 2:
                time.sleep(delay)
            child.stdin.write(header + payload)
            child.stdin.flush()
            reply = exact(child.stdout, 8)
            _, count = struct.unpack('<iI', reply)
            assert count <= 16
            sys.stdout.buffer.write(reply)
            for _ in range(count):
                picture = exact(child.stdout, 24)
                length = struct.unpack('<6I', picture)[-1]
                assert length <= 64 * 1024 * 1024
                sys.stdout.buffer.write(picture)
                sys.stdout.buffer.write(exact(child.stdout, length))
            sys.stdout.buffer.flush()
    finally:
        child.stdin.close()
        child.terminate()
        child.wait(timeout=5)


if __name__ == '__main__':
    main()
