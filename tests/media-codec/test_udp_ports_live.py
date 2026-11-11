"""Opt-in comparison of fixed and OS-assigned Apple HP local UDP ports.

Uses the existing production engine with a test-only bind interposer. Only the
explicit --host's saved credentials are read; passwords and remote pixels stay
in memory. Passive fixed-port listeners count datagrams from the selected host
without saving their contents. No remote input, clipboard or file operations.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/migration-poc"))
from remote_config import configuration


def instrumented_environment(library, mode):
    env = dict(os.environ)
    env["DYLD_INSERT_LIBRARIES"] = str(library)
    env["TERMPILOT_UDP_PORT_PROBE"] = mode
    return env


def selftest(library, executable, mode):
    result = subprocess.run([str(executable)], capture_output=True, timeout=10,
                            env=instrumented_environment(library, mode))
    assert result.returncode == 0, "Local UDP instrumentation self-test failed"
    ports = json.loads(result.stdout)
    assert len(ports) == 2 and len(set(ports)) == 2
    assert (ports == [5900, 5901]) if mode == "fixed" else all(p not in (5900, 5901, 0) for p in ports)
    assert result.stderr.count(b"UDP_PORT_PROBE ") == 2
    return dict(mode=mode, actualPorts=ports, passed=True)


async def probe(base, engine, library, mode, codec, seconds, lock_directory, observe_fixed_ports):
    loop = asyncio.get_running_loop()
    started = loop.time()
    result = dict(mode=mode, codec=codec, remote=base["host"], requested=[1920, 1080],
                  frames=0, audioFrames=0, tilesReceived=[], bindings=[], connected=False,
                  fixedPortPackets={}, observeFixedPorts=observe_fixed_ports, mediaPassed=False)
    fixed_sockets, fixed_tasks = [], []
    child = None
    stderr_task = None
    address = socket.gethostbyname(base["host"])
    tiles = set()
    connected_at = None

    async def observe(port, sock):
        counter = result["fixedPortPackets"][str(port)]
        while True:
            data, peer = await loop.sock_recvfrom(sock, 65536)
            if peer[0] != address:
                counter["otherHostPackets"] += 1
                continue
            counter["packets"] += 1
            counter["bytes"] += len(data)
            counter.setdefault("firstPacketAfterSeconds", round(loop.time() - started, 3))
            counter["lastPacketAfterSeconds"] = round(loop.time() - started, 3)
            counter["sourcePorts"][str(peer[1])] = counter["sourcePorts"].get(str(peer[1]), 0) + 1
            if len(data) >= 12 and data[0] >> 6 == 2:
                if 192 <= data[1] <= 223:
                    counter["rtcpPackets"] += 1
                else:
                    key = str(data[1] & 127)
                    counter["rtpPayloadTypes"][key] = counter["rtpPayloadTypes"].get(key, 0) + 1

    async def consume_stderr():
        while line := await child.stderr.readline():
            if line.startswith(b"UDP_PORT_PROBE "):
                result["bindings"].append(json.loads(line[len(b"UDP_PORT_PROBE "):]))
            # All other stderr is discarded, not persisted.

    async def packet():
        size = struct.unpack(">I", await child.stdout.readexactly(4))[0]
        assert 2 <= size <= 65536, "Invalid IPC header size"
        header = json.loads(await child.stdout.readexactly(size))
        remaining = header["payloadLength"]
        assert 0 <= remaining <= 64 * 1024 * 1024, "Invalid IPC payload size"
        while remaining:
            chunk = await child.stdout.readexactly(min(remaining, 262144))
            remaining -= len(chunk)
        return header

    try:
        if mode == "ephemeral" and observe_fixed_ports:
            for port in (5900, 5901):
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                fixed_sockets.append(sock)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
                sock.bind(("0.0.0.0", port))
                sock.setblocking(False)
                result["fixedPortPackets"][str(port)] = dict(packets=0, bytes=0,
                    sourcePorts={}, rtpPayloadTypes={}, rtcpPackets=0, otherHostPackets=0)
                fixed_tasks.append(asyncio.create_task(observe(port, sock)))
        child = await asyncio.create_subprocess_exec(str(engine), "screen-sharing",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env=instrumented_environment(library, mode))
        stderr_task = asyncio.create_task(consume_stderr())
        config = dict(base, kind="connect", mode="highPerformance", width=1920, height=1080,
                      videoCodec=codec, audio=True, frameRate=30, lockDirectory=str(lock_directory))
        child.stdin.write(json.dumps(config).encode() + b"\n")
        await child.stdin.drain()
        deadline = loop.time() + 95
        while loop.time() < deadline:
            try:
                header = await asyncio.wait_for(packet(), max(.01, deadline - loop.time()))
            except asyncio.TimeoutError:
                break
            kind = header.get("kind")
            if kind == "status":
                result["lastStage"] = header.get("stage")
            elif kind == "error":
                result["errorCode"] = str(header.get("code", "unknown"))[:160]
                break
            elif kind == "connected":
                result["connected"] = True
                result["negotiated"] = [header["width"], header["height"]]
                result["tileCount"] = header["tiles"]
                result["decoder"] = header.get("decoder")
                connected_at = loop.time()
                for counter in result["fixedPortPackets"].values():
                    counter["packetsAtConnected"] = counter["packets"]
                result["connectedAfterSeconds"] = round(connected_at - started, 3)
                deadline = connected_at + seconds
            elif kind == "frame":
                result["frames"] += 1
                tiles.add(header["tile"])
                result.setdefault("firstFrameAfterSeconds", round(loop.time() - started, 3))
                result["lastFrameAfterSeconds"] = round(loop.time() - started, 3)
            elif kind == "audio":
                result["audioFrames"] += 1
            elif kind == "mediaDiagnostics":
                result["mediaDiagnostics"] = {key: value for key, value in header.items()
                                               if key not in ("kind", "payloadLength")}
        result["observedConnectedSeconds"] = round(loop.time() - connected_at, 3) if connected_at else 0
    except (AssertionError, asyncio.IncompleteReadError, OSError) as error:
        result["probeError"] = type(error).__name__ + ": " + str(error)[:160]
    finally:
        async def drain():
            while await child.stdout.read(262144):
                pass
        if child is not None:
            if child.returncode is None:
                try:
                    child.stdin.write(b'{"kind":"disconnect"}\n')
                    await child.stdin.drain()
                    child.stdin.close()
                    await asyncio.wait_for(asyncio.gather(child.wait(), drain()), 8)
                except (BrokenPipeError, ConnectionResetError, asyncio.TimeoutError):
                    result["forcedStop"] = True
                    if child.returncode is None:
                        child.kill()
                    await child.wait()
            result["exitCode"] = child.returncode
        if stderr_task:
            await stderr_task
        for task in fixed_tasks:
            task.cancel()
        outcomes = await asyncio.gather(*fixed_tasks, return_exceptions=True)
        for outcome in outcomes:
            if isinstance(outcome, Exception):
                result["observerError"] = type(outcome).__name__
        for sock in fixed_sockets:
            sock.close()
    result["tilesReceived"] = sorted(tiles)
    actual = [item["actual"] for item in result["bindings"] if item["status"] == 0]
    result["instrumentationPassed"] = (len(actual) == 2 and len(set(actual)) == 2
        and ((actual == [5900, 5901]) if mode == "fixed" else all(p not in (0, 5900, 5901) for p in actual)))
    result["mediaPassed"] = (result["connected"] and result["instrumentationPassed"]
        # Apple may stop video on an unchanged desktop. Validate decoded tile
        # coverage and the full observation period, not an arbitrary FPS floor.
        and result["frames"] >= result.get("tileCount", 1)
        and tiles == set(range(result.get("tileCount", 0)))
        and result.get("observedConnectedSeconds", 0) >= seconds - .1
        and result.get("exitCode") == 0 and "errorCode" not in result and "probeError" not in result
        and not result.get("forcedStop", False))
    result["elapsedSeconds"] = round(loop.time() - started, 3)
    return result


async def main(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    engine = args.engine.resolve()
    library = output / "udp_port_probe.dylib"
    smoke = output / "udp_port_probe_selftest"
    source = ROOT / "tests/media-codec/udp_port_probe.c"
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-O2", "-dynamiclib",
                    str(source), "-o", str(library)], check=True)
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-O2", "-DPORT_PROBE_SELFTEST",
                    str(source), "-o", str(smoke)], check=True)
    report = dict(host=args.host, engineSHA256=hashlib.sha256(engine.read_bytes()).hexdigest(),
                  startedUTC=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  method="Production engine; only bind(UDP 5900/5901) interposed; remote endpoints unchanged",
                  selftests=[selftest(library, smoke, mode) for mode in ("fixed", "ephemeral")],
                  results=[])
    base = configuration("vnc", host=args.host)
    assert base["port"] == 5900
    lock_directory = Path(tempfile.gettempdir()) / "com.termpilot.screen-sharing"
    for codec in args.codecs:
        for mode in args.modes:
            result = await probe(base, engine, library, mode, codec, args.seconds, lock_directory,
                                 args.observe_fixed_ports)
            report["results"].append(result)
            (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(result), flush=True)
            if not result["instrumentationPassed"] or (mode == "fixed" and not result["mediaPassed"]):
                return 1
            await asyncio.sleep(3)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--engine", type=Path, default=ROOT / "target/release/termpilot-engine")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--observe-fixed-ports", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--modes", nargs="+", choices=("fixed", "ephemeral"),
                        default=["fixed", "ephemeral", "ephemeral", "fixed"])
    parser.add_argument("--codecs", nargs="+", choices=("h264", "h265"), default=["h264"])
    sys.exit(asyncio.run(main(parser.parse_args())))
