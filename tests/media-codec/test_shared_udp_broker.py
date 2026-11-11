import asyncio
from pathlib import Path
import socket
import tempfile
import unittest

from shared_udp_broker_probe import Broker


def pair():
    for _ in range(30):
        a = Broker.make_socket(("127.0.0.1", 0))
        port = a.getsockname()[1]
        try:
            b = Broker.make_socket(("127.0.0.1", port + 1))
            return port, [a, b]
        except (OSError, OverflowError):
            a.close()
    raise RuntimeError("Unable to allocate loopback fixture ports")


class RoutingTests(unittest.IsolatedAsyncioTestCase):
    async def test_two_peers_bidirectional_and_unregister_isolation(self):
        loop = asyncio.get_running_loop()
        fixtures = [pair(), pair()]
        clients = []
        with tempfile.TemporaryDirectory(prefix="tp-broker-unit-") as directory:
            broker = Broker(dict(lockDirectory=directory, localPorts=[0, 0],
                targets=[dict(host="127.0.0.1", port=p) for p, _ in fixtures]))
            try:
                for index, (port, _) in enumerate(fixtures):
                    response = broker.register(dict(sessionID=str(index), host="127.0.0.1", port=port))
                    local = [Broker.make_socket(("127.0.0.1", 0)) for _ in range(2)]
                    for sock, ipc_port in zip(local, response["ipcPorts"]):
                        sock.connect(("127.0.0.1", ipc_port))
                    clients.append(local)
                for index, (_, remotes) in enumerate(fixtures):
                    for role in range(2):
                        data = f"session-{index}-role-{role}".encode()
                        clients[index][role].send(data)
                        actual, source = await asyncio.wait_for(loop.sock_recvfrom(remotes[role], 65536), 2)
                        self.assertEqual(actual, data)
                        self.assertEqual(source[1], broker.network[role].getsockname()[1])
                        remotes[role].sendto(b"reply-" + data, source)
                        actual = await asyncio.wait_for(loop.sock_recv(clients[index][role], 65536), 2)
                        self.assertEqual(actual, b"reply-" + data)
                with self.assertRaises(AssertionError):
                    broker.register(dict(sessionID="duplicate", host="127.0.0.1", port=fixtures[0][0]))
                with self.assertRaises(AssertionError):
                    broker.register(dict(sessionID="unauthorized", host="127.0.0.1", port=1))
                broker.unregister("0")
                self.assertEqual(len(broker.routes), 2)
                clients[1][1].send(b"survivor")
                actual, source = await asyncio.wait_for(loop.sock_recvfrom(fixtures[1][1][1], 65536), 2)
                self.assertEqual(actual, b"survivor")
                fixtures[1][1][1].sendto(b"still-live", source)
                self.assertEqual(await asyncio.wait_for(loop.sock_recv(clients[1][1], 65536), 2), b"still-live")
                broker.register(dict(sessionID="replacement", host="127.0.0.1", port=fixtures[0][0]))
                broker.unregister("0")  # Late cleanup cannot remove a replacement route.
                self.assertIn("replacement", broker.sessions)
                self.assertEqual(len(broker.routes), 4)
            finally:
                broker.close()
                for _, sockets in fixtures:
                    for sock in sockets:
                        sock.close()
                for sockets in clients:
                    for sock in sockets:
                        sock.close()


if __name__ == "__main__":
    unittest.main()
