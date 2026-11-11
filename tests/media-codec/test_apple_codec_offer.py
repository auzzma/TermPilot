"""Opt-in real Apple HP codec probe; remote compressed pixels stay in memory.

Build: cargo build -p termpilot-engine --release --example apple_codec_probe
Run: python3 tests/media-codec/test_apple_codec_offer.py --codec h264
Uses saved credentials for the explicitly authorized test Mac, never argv/logs.
No remote input, clipboard access, persisted frame capture, or server changes.
"""
import argparse
import asyncio
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/migration-poc"))
from remote_config import configuration


def parse_config(payload):
    start = payload.find(b"avc1")
    at = payload.find(b"avcC", max(0, start)) + 4
    if at < 4 or at + 6 > len(payload):
        return None
    config = {"profile": payload[at + 1], "compatibility": payload[at + 2], "level": payload[at + 3]}
    count = payload[at + 5] & 31
    at += 6
    nals = []
    for category in range(2):
        for _ in range(count):
            if at + 2 > len(payload):
                return None
            n = int.from_bytes(payload[at:at + 2], "big")
            at += 2
            if not 0 < n <= len(payload) - at:
                return None
            nals.append(payload[at:at + n])
            at += n
        if category == 0:
            if at >= len(payload):
                return None
            count = payload[at]
            at += 1
    if not any(n[0] & 31 == 7 for n in nals) or not any(n[0] & 31 == 8 for n in nals):
        return None
    return config, nals


def assemble(group):
    """Strict complete, contiguous RFC 6184 FU-A/FU-B, STAP and single NALs."""
    seqs = list(group)
    origin = seqs[0]
    order = sorted(seqs, key=lambda s: ((s - origin + 32768) % 65536) - 32768)
    if any((b - a) % 65536 != 1 for a, b in zip(order, order[1:])):
        return []
    output, pending = [], None
    for sequence in order:
        p = group[sequence]
        if not p or p[0] == 0x92:
            continue
        kind = p[0] & 31
        if kind in (28, 29) and len(p) >= (3 if kind == 28 else 5):
            offset = 2 if kind == 28 else 4
            start, end = p[1] & 128, p[1] & 64
            if start:
                if pending is not None:
                    return []
                pending = bytearray([(p[0] & 0xe0) | (p[1] & 31)])
            if pending is None:
                return []
            pending.extend(p[offset:])
            if end:
                output.append(bytes(pending))
                pending = None
        elif kind in (24, 25):
            if pending is not None:
                return []
            at = 1 if kind == 24 else 3
            while at + 2 <= len(p):
                n = int.from_bytes(p[at:at + 2], "big")
                at += 2
                if not 0 < n <= len(p)-at:
                    return []
                output.append(p[at:at+n])
                at += n
            if at != len(p):
                return []
        elif 1 <= kind <= 23:
            if pending is not None:
                return []
            output.append(p)
        else:
            return []
    return output if pending is None else []


async def capture(args):
    cfg = configuration("vnc")
    cfg["seconds"] = args.seconds
    env = dict(os.environ, TERMPILOT_CODEC_PROBE=args.codec, TERMPILOT_CODEC_TILES=str(args.tiles))
    child = await asyncio.create_subprocess_exec(
        str(ROOT / "target/release/examples/apple_codec_probe"),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, env=env,
    )
    child.stdin.write(json.dumps(cfg).encode() + b"\n")
    await child.stdin.drain()
    child.stdin.close()
    groups = defaultdict(dict)
    arrivals, configs, config_meta = {}, {}, {}
    packet_types, packet_sources = Counter(), Counter()
    negotiated, complete = None, None
    total = 0
    try:
        while True:
            try:
                b = await asyncio.wait_for(child.stdout.readexactly(4), 85)
            except asyncio.IncompleteReadError:
                break
            n = struct.unpack(">I", b)[0]
            assert 2 <= n <= 65536
            h = json.loads(await child.stdout.readexactly(n))
            n = h["payloadLength"]
            assert 0 <= n <= 65536
            p = await child.stdout.readexactly(n)
            if h["kind"] == "negotiated":
                negotiated = h
                print(json.dumps(h), flush=True)
            elif h["kind"] == "complete":
                complete = h
            elif h["kind"] == "rtp":
                total += len(p)
                assert total <= 128 * 1024 * 1024, "In-memory stream limit"
                source = h["ssrc"]
                packet_sources[source] += 1
                kind = str(p[0] & 31 if args.codec == "h264" else p[0] >> 1 & 63) if p else "empty"
                packet_types[kind] += 1
                if args.codec == "h264":
                    parsed = parse_config(p) if p and p[0] == 0x92 else None
                    if parsed:
                        config_meta[source], configs[source] = parsed
                    else:
                        key = source, h["timestamp"]
                        groups[key][h["sequence"]] = p
                        arrivals.setdefault(key, h["elapsed"])
        code = await child.wait()
        error = (await child.stderr.read()).decode(errors="replace")
        assert code == 0, "Probe failed: " + error[:1500]
    finally:
        if child.returncode is None:
            child.kill()
            await child.wait()
    assert negotiated and complete
    report = dict(requested=args.codec, requestedTiles=args.tiles if args.codec=="h264" else 4,
                  negotiation=negotiated, capture=complete, authenticatedPayloadBytes=total,
                  packetTypes=dict(packet_types), sources=len(packet_sources),
                  probeNotes=error.strip().splitlines())
    if args.codec == "h264":
        report["avcConfigurations"] = list(config_meta.values())
        report["groupSummary"] = [
            dict(packets=len(group), types=dict(Counter(str(p[0]&31) for p in group.values() if p)),
                 starts=sum(bool(p[1]&128) for p in group.values() if len(p)>1 and p[0]&31 in (28,29)),
                 ends=sum(bool(p[1]&64) for p in group.values() if len(p)>1 and p[0]&31 in (28,29)),
                 firstSequence=next(iter(group)), lastSequence=next(reversed(group)))
            for group in list(groups.values())[:12]
        ]
        target = ROOT / args.output
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(report, indent=2) + "\n")
        streams = {}
        types = Counter()
        missing = 0
        for key in sorted(groups, key=arrivals.get):
            nals = assemble(groups[key])
            if not nals:
                missing += 1
                continue
            source = key[0]
            if source not in streams:
                params = configs.get(source) or next(iter(configs.values()), [])
                streams[source] = bytearray(b"".join(b"\x00\x00\x00\x01" + n for n in params))
            for nal in nals:
                streams[source].extend(b"\x00\x00\x00\x01" + nal)
                types[str(nal[0] & 31)] += 1
        assert configs, "No real avc1/avcC SPS/PPS received"
        assert streams, "No complete H.264 NAL stream"
        # Decode one SSRC generation at a time; never mix unrelated references.
        source = max(streams, key=lambda s: len(streams[s]))
        stream = bytes(streams[source])
        command = ["ffprobe", "-v", "error", "-f", "h264", "-i", "pipe:0", "-count_frames",
                   "-show_entries", "stream=codec_name,profile,level,width,height,pix_fmt,nb_read_frames",
                   "-of", "json"]
        checked = subprocess.run(command, input=stream, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        details = json.loads(checked.stdout)
        metadata = details["streams"][0]
        frames = int(metadata.get("nb_read_frames", 0))
        warnings = checked.stderr.decode(errors="replace").splitlines()
        report.update(avcConfigurations=list(config_meta.values()), nalTypes=dict(types),
                      incompleteOrUnsupportedGroups=missing, selectedStreamBytes=len(stream),
                      decodedStream=metadata, decoderExitCode=checked.returncode,
                      decoderDiagnosticLines=len(warnings), decoderDiagnosticExamples=warnings[:8])
        assert checked.returncode == 0 and metadata["codec_name"] == "h264" and frames > 10, report
        report["h264Verified"] = True
    target = ROOT / args.output
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--codec", choices=["hevc", "h264"], required=True)
    parser.add_argument("--tiles", type=int, choices=[1, 4], default=1)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--output", default="validation/apple-h264-20261011/probe.json")
    asyncio.run(capture(parser.parse_args()))
