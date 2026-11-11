"""Opt-in production Apple HP resolution probe. Pixels and credentials stay in memory.

Requires an explicitly authorized --host with an existing saved credential.
Each mode opens and closes its own virtual-display session; no remote input,
clipboard requests, file transfers or persisted screenshots are performed.
"""
import argparse
import asyncio
import json
from pathlib import Path
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/migration-poc"))
from remote_config import configuration

MODES = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]


async def probe(base, codec, width, height, lock_directory):
    config = dict(base, kind="connect", mode="highPerformance", width=width, height=height,
                  videoCodec=codec, audio=False, frameRate=30, lockDirectory=lock_directory)
    child = await asyncio.create_subprocess_exec(
        str(ROOT / "target/release/termpilot-engine"), "screen-sharing",
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    result = dict(codec=codec, requested=[width, height], frames=0, ok=False)
    frames, sizes = set(), set()
    loop = asyncio.get_running_loop()
    deadline = loop.time() + 90
    try:
        child.stdin.write(json.dumps(config).encode() + b"\n")
        await child.stdin.drain()
        while loop.time() < deadline:
            async def packet():
                length = struct.unpack(">I", await child.stdout.readexactly(4))[0]
                assert 2 <= length <= 65536, "invalid header length"
                header = json.loads(await child.stdout.readexactly(length))
                length = header["payloadLength"]
                assert 0 <= length <= 64 * 1024 * 1024, "invalid payload length"
                # Drain without retaining or writing remote pixels.
                while length:
                    chunk = await child.stdout.readexactly(min(length, 262144))
                    length -= len(chunk)
                return header
            try:
                header = await asyncio.wait_for(packet(), max(.01, deadline - loop.time()))
            except asyncio.TimeoutError:
                break
            kind = header["kind"]
            if kind == "error":
                result["errorCode"] = str(header.get("code", "unknown"))[:200]
                break
            if kind == "connected":
                result["negotiated"] = [header["width"], header["height"]]
                result["tileCount"] = header["tiles"]
                result["decoder"] = header.get("decoder")
                assert result["negotiated"] == [width, height], "resolution mismatch"
            if kind == "frame":
                assert header["width"] == width, "decoded width mismatch"
                assert 0 < header["height"] <= 2176, "decoded height out of range"
                frames.add(header["tile"])
                sizes.add((header["width"], header["height"], header.get("chromaWidth"), header.get("chromaHeight")))
                result["frames"] += 1
                if result.get("tileCount") and frames == set(range(result["tileCount"])):
                    if not result["ok"]:
                        deadline = min(deadline, loop.time() + 3)
                    result["ok"] = True
        result["tilesReceived"] = sorted(frames)
        result["decodedSizes"] = sorted(sizes)
        result["ok"] = result["ok"] and "errorCode" not in result
    except (AssertionError, asyncio.IncompleteReadError) as error:
        result["ok"] = False
        result["error"] = str(error)[:200]
    finally:
        async def drain():
            while await child.stdout.read(262144):
                pass
        if child.returncode is None:
            try:
                child.stdin.write(b'{"kind":"disconnect"}\n')
                await child.stdin.drain()
                child.stdin.close()
                await asyncio.wait_for(asyncio.gather(child.wait(), drain()), 8)
            except (BrokenPipeError, ConnectionResetError, asyncio.TimeoutError):
                if child.returncode is None:
                    child.kill()
                await child.wait()
        result["exitCode"] = child.returncode
    return result


async def main(args):
    base = configuration("vnc", host=args.host)
    results = []
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="TermPilot-resolution-") as directory:
        for codec in args.codecs:
            for width, height in MODES:
                result = await probe(base, codec, width, height, directory)
                results.append(result)
                output.write_text(json.dumps(dict(results=results), indent=2) + "\n")
                print(json.dumps(result), flush=True)
                if not result["ok"]:
                    return 1
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--codecs", nargs="+", choices=["h264", "h265"], default=["h264", "h265"])
    parser.add_argument("--output", default="validation/high-performance-resolution-20261109/live.json")
    sys.exit(asyncio.run(main(parser.parse_args())))
