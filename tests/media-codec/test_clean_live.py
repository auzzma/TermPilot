"""Observe the real screen through the portable decoder, without saving pixels.

Run with TERMPILOT_TEST_ENGINE pointing to the portable validation engine.
An idle desktop legitimately stops sending video; it is not a frozen decoder.
"""
import asyncio
import argparse
import json
import runpy
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCREEN = runpy.run_path(str(ROOT / 'tests/rust-screen-live.py'))


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='validation/android-video-order-groups-20261011/live-clean.json')
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--codec', choices=['h264','h265'], default='h265')
    args = parser.parse_args()
    client = SCREEN['Screen']()
    config = SCREEN['configuration']('vnc')
    frames, tiles, diagnostics = 0, set(), {}
    samples = []
    with tempfile.TemporaryDirectory(prefix='TermPilot-clean-video-') as lock:
        config.update(mode='highPerformance', lockDirectory=lock, audio=True, videoCodec=args.codec)
        await client.start(config)
        started = time.monotonic()
        try:
            while time.monotonic() - started < args.seconds:
                header, _ = await asyncio.wait_for(client.packet(), 20)
                if header['kind'] == 'error':
                    raise RuntimeError(header.get('code'))
                if header['kind'] == 'frame':
                    frames += 1
                    tiles.add(header['tile'])
                if header['kind'] == 'mediaDiagnostics':
                    diagnostics = header
                    samples.append(dict(elapsed=round(time.monotonic()-started,3), **header))
                    assert header['decodeErrors'] == 0, header
                    # Video recently arrived but no output for five seconds is
                    # a stall; an equally idle sender and decoder is valid.
                    assert not (header['videoIdleSeconds'] is not None and
                                header['videoIdleSeconds'] < 1 and
                                header['frameIdleSeconds'] > 5), header
            assert frames > 100 and tiles == ({0} if args.codec=='h264' else {0,1,2,3}), (frames, tiles)
            assert diagnostics, 'No decoder diagnostics received'
        finally:
            await client.close()
    report = dict(passed=True, codec=args.codec,
                  durationSeconds=round(time.monotonic() - started, 3),
                  framesReceived=frames, tiles=sorted(tiles),
                  diagnostics=diagnostics, samples=samples)
    destination = ROOT / args.output
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    asyncio.run(main())
