"""Two explicitly authorized Macs, one UDP broker and isolated production engines.

The optional two-window viewer receives decoded frames over a private pipe.
Credentials, compressed media and pixels are never saved. Remote inputs,
clipboard and file transfer are not exercised by this transport experiment.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tests/migration-poc"))
from remote_config import configuration


class BrokerClient:
    async def start(self, hosts):
        self.guard = asyncio.Lock()
        self.child = await asyncio.create_subprocess_exec(sys.executable, str(HERE / "shared_udp_broker_probe.py"),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        config = dict(targets=[dict(host=h, port=5900) for h in hosts],
            lockDirectory=str(Path(tempfile.gettempdir()) / "com.termpilot.screen-sharing"))
        self.child.stdin.write(json.dumps(config).encode() + b"\n")
        await self.child.stdin.drain()
        line = await asyncio.wait_for(self.child.stdout.readline(), 10)
        if not line:
            raise RuntimeError("Shared UDP broker did not start")
        result = json.loads(line)
        assert result["kind"] == "ready"
        self.pid = result["pid"]
        return result

    async def request(self, kind, **values):
        async with self.guard:
            self.child.stdin.write(json.dumps(dict(kind=kind, **values)).encode() + b"\n")
            await self.child.stdin.drain()
            line = await asyncio.wait_for(self.child.stdout.readline(), 10)
            if not line:
                raise RuntimeError("Shared UDP broker exited")
            result = json.loads(line)
            if result["kind"] == "error":
                raise RuntimeError(result["error"])
            return result

    async def close(self):
        if self.child.returncode is None:
            await self.request("stop")
            self.child.stdin.close()
            await asyncio.wait_for(self.child.wait(), 10)
        assert self.child.returncode == 0, "Broker shutdown failed"


class Worker:
    async def start(self, base, broker, library, engine, directory, codec, size, viewer):
        self.broker, self.viewer = broker, viewer
        self.sid = uuid.uuid4().hex
        self.host, self.codec, self.size = base["host"], codec, size
        self.frames = self.audio = 0
        self.tiles = set()
        self.errors = []
        self.bindings = []
        self.diagnostics = {}
        self.connected = False
        self.stopping = False
        self.started = time.monotonic()
        self.last_frame = self.last_audio = None
        self.route = await broker.request("register", sessionID=self.sid, host=self.host)
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library), TERMPILOT_BROKER_REMOTE=self.host,
                   TERMPILOT_BROKER_AUDIO=str(self.route["ipcPorts"][0]),
                   TERMPILOT_BROKER_VIDEO=str(self.route["ipcPorts"][1]))
        lock = directory / self.sid
        lock.mkdir(mode=0o700)
        self.child = await asyncio.create_subprocess_exec(str(engine), "screen-sharing",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env=env)
        self.reader = asyncio.create_task(self.read())
        self.stderr = asyncio.create_task(self.read_stderr())
        await self.send(dict(base, kind="connect", mode="highPerformance", videoCodec=codec,
            width=size[0], height=size[1], frameRate=30, audio=True, lockDirectory=str(lock)))
        return self

    async def send(self, command):
        self.child.stdin.write(json.dumps(command).encode() + b"\n")
        await self.child.stdin.drain()

    async def read_stderr(self):
        while line := await self.child.stderr.readline():
            if line.startswith(b"UDP_BROKER_PROBE "):
                self.bindings.append(json.loads(line[len(b"UDP_BROKER_PROBE "):]))

    async def read(self):
        try:
            while True:
                size = struct.unpack(">I", await self.child.stdout.readexactly(4))[0]
                assert 2 <= size <= 65536
                header = json.loads(await self.child.stdout.readexactly(size))
                length = header["payloadLength"]
                assert 0 <= length <= 64 * 1024 * 1024
                payload = await self.child.stdout.readexactly(length)
                kind = header.get("kind")
                if kind == "connected":
                    self.connected = True
                    self.tile_count = header["tiles"]
                    self.negotiated = [header["width"], header["height"]]
                    assert self.negotiated == list(self.size)
                elif kind == "frame":
                    self.frames += 1
                    self.tiles.add(header["tile"])
                    self.last_frame = time.monotonic()
                    if self.viewer:
                        self.viewer.put(self, header, payload)
                elif kind == "audio":
                    self.audio += 1
                    self.last_audio = time.monotonic()
                elif kind == "mediaDiagnostics":
                    self.diagnostics = {k: v for k, v in header.items() if k not in ("kind", "payloadLength")}
                elif kind == "mediaTransport":
                    self.media_transport = {k: v for k, v in header.items() if k != "payloadLength"}
                elif kind == "error":
                    self.errors.append(str(header.get("code", "unknown"))[:200])
        except asyncio.IncompleteReadError:
            if not self.stopping:
                self.errors.append("Unexpected engine EOF")
        except Exception as error:
            self.errors.append(type(error).__name__ + ": " + str(error)[:120])

    def check(self):
        assert not self.errors, f"{self.host}: {self.errors}"
        assert self.child.returncode is None, f"{self.host}: engine exited"

    async def ready(self):
        async with asyncio.timeout(95):
            while True:
                self.check()
                if self.connected and self.tiles == set(range(self.tile_count)) and self.audio:
                    assert len(self.bindings) == 2 and all(x["status"] == 0 for x in self.bindings)
                    return
                await asyncio.sleep(.2)

    def report(self):
        now = time.monotonic()
        return dict(host=self.host, sessionID=self.sid, pid=self.child.pid, codec=self.codec,
            requested=self.size, connected=self.connected, negotiated=getattr(self, "negotiated", None),
            frames=self.frames, audioOutputs=self.audio, tiles=sorted(self.tiles), bindings=self.bindings,
            errors=self.errors, diagnostics=self.diagnostics, elapsedSeconds=round(now-self.started, 3),
            mediaTransport=getattr(self, "media_transport", {}),
            frameAgeSeconds=round(now-self.last_frame, 3) if self.last_frame else None,
            audioAgeSeconds=round(now-self.last_audio, 3) if self.last_audio else None)

    async def close(self, force=False):
        self.stopping = True
        if self.child.returncode is None:
            if force:
                self.child.kill()
            else:
                try:
                    await self.send(dict(kind="disconnect"))
                    self.child.stdin.close()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            try:
                await asyncio.wait_for(self.child.wait(), 10)
            except asyncio.TimeoutError:
                self.child.kill()
                await self.child.wait()
                self.errors.append("Shutdown timeout")
        await self.reader
        await self.stderr
        await self.broker.request("unregister", sessionID=self.sid)
        if self.viewer:
            self.viewer.clear(self.host)
        if not force:
            assert self.child.returncode == 0, f"{self.host}: shutdown exit {self.child.returncode}"


class Viewer:
    async def start(self, binary):
        self.latest = {}
        self.presented = {}
        self.child = await asyncio.create_subprocess_exec(str(binary), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        self.pump = asyncio.create_task(self.write())
        self.reader = asyncio.create_task(self.read())
        return self

    def put(self, worker, header, payload):
        self.latest[(worker.host, header["tile"])] = (dict(header, host=worker.host,
            generation=worker.sid, desktopWidth=worker.size[0], desktopHeight=worker.size[1]), payload)

    def clear(self, host):
        self.latest = {k:v for k,v in self.latest.items() if k[0] != host}

    async def write(self):
        while True:
            frames, self.latest = self.latest, {}
            for header, data in frames.values():
                encoded = json.dumps(header).encode()
                self.child.stdin.write(struct.pack(">I", len(encoded)) + encoded + data)
                await self.child.stdin.drain()
            await asyncio.sleep(.1)

    async def read(self):
        while line := await self.child.stdout.readline():
            event = json.loads(line)
            self.presented[event["host"]] = event

    async def close(self):
        self.pump.cancel()
        await asyncio.gather(self.pump, return_exceptions=True)
        self.child.stdin.close()
        await asyncio.wait_for(self.child.wait(), 10)
        await self.reader
        assert self.child.returncode == 0


async def observe(workers, seconds):
    baseline = [(w.frames, w.audio, w.child.pid, w.diagnostics.get("videoPackets", 0)) for w in workers]
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for worker in workers:
            worker.check()
            await worker.send(dict(kind="refresh"))
        await asyncio.sleep(min(3, max(.01, deadline-time.monotonic())))
    for worker, (frames, audio, pid, packets) in zip(workers, baseline):
        worker.check()
        # An unchanged desktop may stop video even after FIR. Fresh authenticated
        # audio proves the shared route remains alive; if video is arriving,
        # require decode progress instead of accepting a stuck decoder.
        assert worker.frames > frames or worker.diagnostics.get("videoPackets", 0) == packets, \
            f"{worker.host}: video packets arrived without decode progress"
        assert worker.audio > audio, f"{worker.host}: no fresh decoded audio during observation"
        assert worker.child.pid == pid


async def main(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    library = output / "broker_transport_probe.dylib"
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O2", "-dynamiclib",
        str(HERE / "broker_transport_probe.c"), "-o", str(library)], check=True)
    engine = args.engine.resolve()
    base = [configuration("vnc", host=host) for host in args.hosts]
    report = dict(hosts=args.hosts, engineSHA256=hashlib.sha256(engine.read_bytes()).hexdigest(),
        method="One separate UDP broker, loopback datagram IPC, isolated unchanged production engines",
        startedUTC=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), phases=[], sessions=[], passed=False)
    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    broker = BrokerClient()
    viewer = None
    workers = []
    async def checkpoint(name, active):
        phase = dict(name=name, workers=[w.report() for w in active], broker=await broker.request("stats"))
        if viewer:
            phase["viewer"] = dict(viewer.presented)
        report["phases"].append(phase)
        save()
        print(json.dumps(dict(phase=name, workers=[dict(host=w.host, pid=w.child.pid, codec=w.codec,
            frames=w.frames, audio=w.audio, size=w.size) for w in active])), flush=True)
    async def start(index, codec, size=(1920,1080)):
        worker = await Worker().start(base[index], broker, library, engine, Path(directory), codec, size, viewer)
        workers.append(worker)
        await worker.ready()
        return worker
    async def close(worker, force=False):
        await worker.close(force=force)
        report["sessions"].append(dict(worker.report(), exitCode=worker.child.returncode, intentionalKill=force))
        workers.remove(worker)
        save()
    with tempfile.TemporaryDirectory(prefix="tp-multi-", dir="/tmp") as directory:
        try:
            report["brokerStart"] = await broker.start(args.hosts)
            if args.viewer:
                viewer = await Viewer().start(args.viewer.resolve())
            for codec in args.codecs:
                a, b = await asyncio.gather(start(0, codec), start(1, codec))
                await checkpoint(codec + "-both-connected", [a,b])
                await observe([a,b], args.seconds)
                await checkpoint(codec + "-simultaneous", [a,b])
                await close(a)
                await observe([b], 10)
                await checkpoint(codec + "-A-closed-B-survives", [b])
                sizes = [(1280,720),(2560,1440),(3840,2160)] if codec == args.codecs[0] else [(1920,1080)]
                for size in sizes:
                    a = await start(0, codec, size)
                    await observe([a,b], 10)
                    await checkpoint(codec + "-A-reconnected-" + str(size[0]), [a,b])
                    if size != sizes[-1]:
                        await close(a)
                await close(b, force=True)
                await observe([a], 10)
                await checkpoint(codec + "-B-killed-A-survives", [a])
                b = await start(1, codec)
                await observe([a,b], 10)
                await checkpoint(codec + "-B-restarted", [a,b])
                await close(a)
                await close(b)
            report["finalBroker"] = await broker.request("stats")
            assert not report["finalBroker"]["sessions"]
            assert len({x["pid"] for p in report["phases"] for x in p["workers"]}) >= 4
            if viewer:
                report["viewer"] = dict(viewer.presented)
                assert all(viewer.presented.get(h, {}).get("presented", 0) > 0 for h in args.hosts)
            report["passed"] = True
        except Exception as error:
            report["error"] = type(error).__name__ + ": " + str(error)[:300]
            print(json.dumps(dict(error=report["error"])), flush=True)
        finally:
            for worker in list(workers):
                try:
                    await close(worker)
                except Exception as error:
                    report.setdefault("cleanupErrors", []).append(type(error).__name__)
            if hasattr(broker, "child"):
                await broker.close()
            if viewer:
                await viewer.close()
            report["engineUnchanged"] = report["engineSHA256"] == hashlib.sha256(engine.read_bytes()).hexdigest()
            save()
    print(json.dumps(dict(passed=report["passed"], phases=len(report["phases"]),
                         sessions=len(report["sessions"]), report=str(output / "results.json"))), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--hosts", nargs=2, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engine", type=Path, default=ROOT / "target/release/termpilot-engine")
    parser.add_argument("--viewer", type=Path)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--codecs", nargs="+", choices=["h264","h265"], default=["h264","h265"])
    sys.exit(asyncio.run(main(parser.parse_args())))
