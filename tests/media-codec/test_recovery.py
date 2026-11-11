"""Synthetic packet-loss regression: a full DPB must recover at the next IRAP."""
import json
import struct
import subprocess
from pathlib import Path


def validate(helper):
    data = Path(__file__).with_name('hevc-recovery.fixture').read_bytes()
    nals = []
    while data:
        size, = struct.unpack('>I', data[:4])
        assert 2 <= size <= len(data) - 4
        nals.append(data[4:4 + size])
        data = data[4 + size:]
    params = {n[0] >> 1 & 63: n for n in nals if 32 <= n[0] >> 1 & 63 <= 34}
    config = b''.join(struct.pack('>I', len(n)) + n for n in params.values())
    frames = [n for n in nals if n[0] >> 1 & 63 < 32]
    assert len(frames) == 200

    def request(op, data, tag=0):
        return struct.pack('<4I', op, tag % 4, tag, len(data)) + data

    results = []
    for losses in (set(), {8}, {8, 98}):
        requests = [request(1, config)]
        requests += [request(2, n, i) for i, n in enumerate(frames) if i not in losses]
        run = subprocess.run([str(helper)], input=b''.join(requests), capture_output=True,
                             check=True, timeout=30)
        data = run.stdout
        tags, errors = [], []
        for _ in requests:
            status, count = struct.unpack('<iI', data[:8])
            data = data[8:]
            if status < 0:
                errors.append(status)
            assert count <= 16
            for _ in range(count):
                kind, tile, tag, w, h, size = struct.unpack('<6I', data[:24])
                data = data[24:]
                assert (kind, tile, w, h, size) == (1, tag % 4, 96, 64, 96 * 64 * 3)
                assert len(data) >= size
                data = data[size:]
                tags.append(tag)
        assert not data
        # Old decoder stalls forever with -1009, including both later IDRs.
        assert errors == [-1009] * len(losses), errors
        assert tags[-20:] == list(range(180, 200)), tags[-20:]
        assert tags[:8] == list(range(8))
        assert 90 in tags, tags
        if not losses:
            assert tags == list(range(200))
        results.append(dict(lostFrames=sorted(losses), decoded=len(tags), errors=errors,
                            lastFrame=tags[-1]))
    return results


if __name__ == '__main__':
    import sys
    print(json.dumps(validate(Path(sys.argv[1]).resolve())))
