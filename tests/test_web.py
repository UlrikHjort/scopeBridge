# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Tests of scopebridge-server's web interface (--web): the browser client's
files over HTTP, and the protocol over WebSocket, with a minimal
WebSocket client.

    python3 tests/test_web.py            (part of make check-server)
"""

import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))

from scopebridge_client import ScopeBridgeClient  # noqa: E402
from test_server import SERVER, free_port  # noqa: E402


def http_get(port, target, headers=""):
    """The raw response to GET target."""
    with socket.create_connection(("127.0.0.1", port)) as s:
        s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n%s\r\n" % (target, headers)).encode())
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                return data
            data += chunk


class WebSocket:
    """Just enough of a WebSocket client for the tests."""

    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port))
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
                           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                           "Sec-WebSocket-Version: 13\r\n\r\n" % key).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(1)
        self.status = head.split(b"\r\n")[0].decode()
        want = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.accepted = ("sec-websocket-accept: " + want).encode() in head.lower() \
            or ("Sec-WebSocket-Accept: " + want).encode() in head
        self.next_id = 1

    def exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

    def frame(self):
        """(opcode, data) of the next frame."""
        h = self.exact(2)
        n = h[1] & 127
        if n == 126:
            n = struct.unpack(">H", self.exact(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self.exact(8))[0]
        return h[0] & 15, self.exact(n)

    def send(self, data, opcode=1, final=True):
        mask = os.urandom(4)
        n = len(data)
        size = bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n)
        self.sock.sendall(bytes([(0x80 if final else 0) | opcode]) + size + mask +
                          bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def request(self, cmd, **members):
        """(reply, payload): the reply text frame, and the binary frame
        after it if it announces bytes."""
        members.update(id=self.next_id, cmd=cmd)
        self.next_id += 1
        self.send(json.dumps(members).encode())
        while True:
            op, data = self.frame()
            assert op == 1, op
            msg = json.loads(data)
            payload = b""
            if msg.get("bytes"):
                op, payload = self.frame()
                assert op == 2, op
            if msg.get("id") == members["id"]:
                return msg, payload

    def close(self):
        self.sock.close()


class WebTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        cls.web = free_port()
        cls.server = subprocess.Popen(
            [SERVER, "--sim", "--port", str(cls.port), "--web", str(cls.web)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert "listening" in cls.server.stdout.readline()
        assert "web interface" in cls.server.stdout.readline()

    @classmethod
    def tearDownClass(cls):
        cls.server.kill()
        cls.server.wait()
        cls.server.stdout.close()

    def test_files(self):
        page = http_get(self.web, "/")
        self.assertTrue(page.startswith(b"HTTP/1.1 200 OK"))
        self.assertIn(b"Content-Type: text/html", page)
        self.assertIn(b'<script type="module" src="app.js">', page)
        for module in ("app.js", "conn.js", "util.js", "scope.js", "spectrum.js", "decode.js",
                       "timing.js"):
            js = http_get(self.web, "/" + module)
            self.assertTrue(js.startswith(b"HTTP/1.1 200 OK"), module)
            self.assertIn(b"Content-Type: text/javascript", js)
        css = http_get(self.web, "/style.css?v=2")
        self.assertIn(b"Content-Type: text/css", css)
        for target in ("/missing.js", "/../README.md", "/%2e%2e/README.md",
                       "/.hidden", "/sub/app.js", "//etc/passwd"):
            self.assertTrue(http_get(self.web, target).startswith(b"HTTP/1.1 404"), target)

    def test_not_get(self):
        with socket.create_connection(("127.0.0.1", self.web)) as s:
            s.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
            self.assertTrue(s.recv(100).startswith(b"HTTP/1.1 405"))

    def test_ws_needs_upgrade(self):
        self.assertTrue(http_get(self.web, "/ws").startswith(b"HTTP/1.1 400"))

    def test_protocol(self):
        ws = WebSocket(self.web)
        try:
            self.assertEqual(ws.status, "HTTP/1.1 101 Switching Protocols")
            self.assertTrue(ws.accepted)
            op, data = ws.frame()
            hello = json.loads(data)
            self.assertEqual((op, hello["event"], hello["source"]), (1, "hello", "sim"))
            reply, _ = ws.request("status")
            self.assertTrue(reply["ok"])
            self.assertIn("acquire", reply)
            # a payload comes as the binary frame after its message
            reply, payload = ws.request("screen", ch=1)
            self.assertEqual((reply["bytes"], len(payload)), (1200, 1200))
            reply, payload = ws.request("screenshot")    # > 64 KB: 8-byte size
            self.assertEqual(len(payload), reply["bytes"])
            self.assertTrue(payload.startswith(b"BM"))
            # megabytes: sent in place, not copied on the writer's stack
            reply, _ = ws.request("capture", ch=1)
            reply, payload = ws.request("spectrum", ch=1)
            self.assertGreater(reply["bytes"], 2_000_000)
            self.assertEqual(len(payload), reply["bytes"])
            reply, _ = ws.request("fly")
            self.assertFalse(reply["ok"])
            # a request in two fragments
            text = json.dumps({"id": 99, "cmd": "status"}).encode()
            ws.send(text[:10], opcode=1, final=False)
            ws.send(text[10:], opcode=0, final=True)
            while True:
                op, data = ws.frame()
                if json.loads(data).get("id") == 99:
                    break
        finally:
            ws.close()

    def test_live_and_other_clients(self):
        ws = WebSocket(self.web)
        plain = ScopeBridgeClient(port=self.port)
        try:
            ws.frame()   # hello
            ws.request("live", on=True, interval_ms=50)
            frames = 0
            for _ in range(20):
                op, data = ws.frame()
                msg = json.loads(data)
                if msg.get("event") == "frame":
                    op, payload = ws.frame()
                    self.assertEqual((op, len(payload)), (2, msg["bytes"]))
                    frames += 1
                    break
            self.assertEqual(frames, 1)
            # a setting by another client reaches the same scope
            plain.request("set_channel", ch=1, scale=0.2)
            reply, _ = ws.request("status")
            self.assertEqual(reply["channels"][0]["scale"], 0.2)
            ws.request("live", on=False)
        finally:
            ws.close()
            plain.close()


class NoWebTest(unittest.TestCase):

    def test_without_web(self):
        port = free_port()
        server = subprocess.Popen([SERVER, "--sim", "--port", str(port)],
                                  stdout=subprocess.PIPE, text=True)
        try:
            line = server.stdout.readline()
            self.assertIn("listening", line)
            with ScopeBridgeClient(port=port) as c:
                self.assertTrue(c.request("status")[0]["ok"])
        finally:
            server.kill()
            server.wait()
            server.stdout.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
