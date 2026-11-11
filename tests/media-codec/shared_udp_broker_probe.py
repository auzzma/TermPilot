"""Separate-process UDP broker for the explicitly authorized multi-Mac probe.

One process owns the external media ports. Each session gets two exclusive
loopback UDP IPC sockets, carrying unchanged encrypted media datagrams. Routes
are registered by the parent's private stdin pipe, not by network messages.
This is a validation implementation, not a production local-authentication API.
"""
import argparse
import asyncio
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import socket
import stat
import sys

MAX_PACKET = 16384


class Broker:
    def __init__(self, config):
        self.loop = asyncio.get_running_loop()
        self.allowed = {(str(ipaddress.IPv4Address(x["host"])), int(x.get("port", 5900)))
                        for x in config["targets"]}
        self.routes = {}
        self.sessions = {}
        self.history = []
        self.unknown = 0
        self.network = []
        self.lock = None
        directory = Path(config["lockDirectory"])
        assert directory.is_absolute()
        directory.mkdir(mode=0o700, exist_ok=True)
        info = directory.lstat()
        assert stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077
        fd = os.open(directory / "screen-sharing.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        self.lock = os.fdopen(fd, "r+b")
        try:
            fcntl.flock(self.lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            for role, port in enumerate(config.get("localPorts", [5900, 5901])):
                sock = self.make_socket(("0.0.0.0", port))
                self.network.append(sock)
                self.loop.add_reader(sock.fileno(), self.read_remote, role)
        except BaseException:
            self.close()
            raise

    @staticmethod
    def make_socket(address):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
            sock.setblocking(False)
            sock.bind(address)
            return sock
        except BaseException:
            sock.close()
            raise

    def register(self, command):
        sid = command["sessionID"]
        host, port = str(ipaddress.IPv4Address(command["host"])), int(command.get("port", 5900))
        assert (host, port) in self.allowed, "Target not authorized for this experiment"
        assert sid not in self.sessions, "Duplicate session identifier"
        assert all((role, host, port + role) not in self.routes for role in range(2)), "Target already registered"
        session = dict(sessionID=sid, host=host, port=port, active=True, channels=[])
        self.sessions[sid] = session
        try:
            for role in range(2):
                sock = self.make_socket(("127.0.0.1", 0))
                channel = dict(socket=sock, worker=None, role=role, remote=(host, port + role),
                               ipcPort=sock.getsockname()[1], inboundPackets=0, inboundBytes=0,
                               outboundPackets=0, outboundBytes=0, dropped=0, rejected=0)
                session["channels"].append(channel)
                self.routes[(role, host, port + role)] = channel
                self.loop.add_reader(sock.fileno(), self.read_worker, channel)
        except BaseException:
            self.unregister(sid)
            raise
        return {"sessionID": sid, "ipcPorts": [x["ipcPort"] for x in session["channels"]]}

    def read_worker(self, channel):
        for _ in range(64):
            try:
                data, source = channel["socket"].recvfrom(65536)
            except BlockingIOError:
                return
            except OSError:
                channel["dropped"] += 1
                return
            if source[0] != "127.0.0.1" or len(data) > MAX_PACKET:
                channel["rejected"] += 1
                continue
            if channel["worker"] is None:
                channel["worker"] = source
            if source != channel["worker"]:
                channel["rejected"] += 1
                continue
            try:
                n = self.network[channel["role"]].sendto(data, channel["remote"])
                channel["outboundPackets"] += 1
                channel["outboundBytes"] += n
            except OSError:
                channel["dropped"] += 1

    def read_remote(self, role):
        for _ in range(64):
            try:
                data, source = self.network[role].recvfrom(65536)
            except BlockingIOError:
                return
            except OSError:
                return
            channel = self.routes.get((role, source[0], source[1]))
            if channel is None:
                self.unknown += 1
                continue
            if len(data) > MAX_PACKET or channel["worker"] is None:
                channel["dropped"] += 1
                continue
            try:
                n = channel["socket"].sendto(data, channel["worker"])
                channel["inboundPackets"] += 1
                channel["inboundBytes"] += n
            except OSError:
                channel["dropped"] += 1

    @staticmethod
    def describe(session):
        return {**{k: v for k, v in session.items() if k != "channels"},
                "channels": [{k: v for k, v in x.items() if k != "socket"} for x in session["channels"]]}

    def unregister(self, sid):
        session = self.sessions.pop(sid, None)
        if session is None:
            return
        session["active"] = False
        for channel in session["channels"]:
            self.routes.pop((channel["role"], *channel["remote"]), None)
            self.loop.remove_reader(channel["socket"].fileno())
            channel["socket"].close()
        self.history.append(self.describe(session))

    def snapshot(self):
        return dict(pid=os.getpid(), localPorts=[s.getsockname()[1] for s in self.network],
                    sessions=[self.describe(s) for s in self.sessions.values()],
                    closedSessions=self.history, unknownRemotePackets=self.unknown)

    def close(self):
        for sid in list(self.sessions):
            self.unregister(sid)
        for sock in self.network:
            self.loop.remove_reader(sock.fileno())
            sock.close()
        self.network.clear()
        if self.lock:
            self.lock.close()
            self.lock = None


async def serve():
    reader = asyncio.StreamReader(limit=65536)
    await asyncio.get_running_loop().connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    config = json.loads(await reader.readline())
    broker = Broker(config)
    print(json.dumps(dict(kind="ready", **broker.snapshot())), flush=True)
    try:
        while line := await reader.readline():
            command = json.loads(line)
            kind = command["kind"]
            try:
                if kind == "register":
                    result = broker.register(command)
                elif kind == "unregister":
                    broker.unregister(command["sessionID"])
                    result = broker.snapshot()
                elif kind == "stats":
                    result = broker.snapshot()
                elif kind == "stop":
                    print(json.dumps(dict(kind="stopped", **broker.snapshot())), flush=True)
                    break
                else:
                    raise ValueError("Unknown broker command")
                print(json.dumps(dict(kind=kind, **result)), flush=True)
            except (AssertionError, ValueError) as error:
                print(json.dumps(dict(kind="error", error=str(error))), flush=True)
    finally:
        broker.close()


if __name__ == "__main__":
    asyncio.run(serve())
