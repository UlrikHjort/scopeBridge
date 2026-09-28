# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Client for scopebridge-server (protocol: docs/PROTOCOL.md).

    from scopebridge_client import ScopeBridgeClient
    with ScopeBridgeClient() as scope:              # 127.0.0.1:5026
        print(scope.hello["idn"])
        scope.request("set_channel", ch=1, scale=0.5)
        info, raw = scope.request("capture", ch=1)
        volts = scope.volts(info, raw)

Requests block until their reply arrives. Events that arrive meanwhile
are queued; take them with next_event().
"""

import collections
import json
import os
import socket
import struct


def settings(section):
    """The settings of a [section] of ~/.scopebridgerc ($SCOPEBRIDGE_RC instead
    if set; empty: none), as a dict; {} if there is no file.  The same file,
    and the same rules, as the Ada programs': '#' starts a comment, and
    options given explicitly win over it."""
    name = os.environ.get("SCOPEBRIDGE_RC")
    if name is None:
        name = os.path.join(os.path.expanduser("~"), ".scopebridgerc")
    result, current = {}, None
    try:
        with open(name, encoding="utf-8") as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line.startswith("[") and line.endswith("]"):
                    current = line[1:-1].strip().lower()
                elif "=" in line and current == section:
                    key, value = line.split("=", 1)
                    result[key.strip().lower()] = value.strip()
    except OSError:
        pass
    return result


def default_server():
    """Where to find the server when not told: $SCOPEBRIDGE_HOST and
    $SCOPEBRIDGE_PORT, then ~/.scopebridgerc's [client], then 127.0.0.1:5026."""
    client = settings("client")
    host = os.environ.get("SCOPEBRIDGE_HOST") or client.get("host") or "127.0.0.1"
    port = int(os.environ.get("SCOPEBRIDGE_PORT") or client.get("port") or 5026)
    return host, port


class ServerError(Exception):
    """The server answered a request with "ok": false."""


class ScopeBridgeClient:
    def __init__(self, host="127.0.0.1", port=5026, timeout=30.0):
        self._sock = socket.create_connection((host, port), timeout=timeout)
        self._buffer = bytearray()
        self._events = collections.deque()
        self._next_id = 1
        self.hello, _ = self._read()
        if self.hello.get("event") != "hello":
            raise ServerError("expected hello, got %r" % self.hello)

    def close(self):
        self._sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _fill(self):
        chunk = self._sock.recv(1 << 20)
        if not chunk:
            raise ConnectionError("server closed the connection")
        self._buffer += chunk

    def _read(self):
        """One message and its payload (bytes, or None).

        Buffered here rather than with socket.makefile(), which becomes
        unusable after a timeout; a timeout leaves partial input in the
        buffer and the next call carries on."""
        while b"\n" not in self._buffer:
            self._fill()
        end = self._buffer.index(b"\n")
        message = json.loads(self._buffer[:end])
        size = message.get("bytes")
        if size is not None:
            while len(self._buffer) < end + 1 + size:
                self._fill()
        del self._buffer[:end + 1]
        payload = None
        if size is not None:
            payload = bytes(self._buffer[:size])
            del self._buffer[:size]
        return message, payload

    def request(self, cmd, **members):
        """Send a request; return (reply, payload). Raises ServerError."""
        request_id = self._next_id
        self._next_id += 1
        self.send_raw(json.dumps(dict(members, id=request_id, cmd=cmd)))
        while True:
            message, payload = self._read()
            if "event" in message:
                self._events.append((message, payload))
            elif message.get("id") == request_id:
                if not message.get("ok"):
                    raise ServerError(message.get("error", "unknown error"))
                return message, payload

    def send_raw(self, line):
        """Send one line as is (for testing malformed requests)."""
        self._sock.sendall(line.encode() + b"\n")

    def read_reply(self):
        """The next non-event message (after send_raw)."""
        while True:
            message, payload = self._read()
            if "event" in message:
                self._events.append((message, payload))
            else:
                return message, payload

    def next_event(self, timeout=None):
        """The next event as (event, payload); waits up to timeout s."""
        if self._events:
            return self._events.popleft()
        old = self._sock.gettimeout()
        self._sock.settimeout(timeout)
        try:
            while True:
                message, payload = self._read()
                if "event" in message:
                    return message, payload
                raise ServerError("unexpected reply %r" % message)
        finally:
            self._sock.settimeout(old)

    @staticmethod
    def volts(waveform, raw):
        """Raw samples to volts, using a message's waveform members."""
        y_inc, y_origin, y_ref = (waveform["y_inc"], waveform["y_origin"],
                                  waveform["y_ref"])
        return [(r - y_ref - y_origin) * y_inc for r in raw]

    @staticmethod
    def floats(payload):
        """The float32 values of a "math" or "spectrum" payload."""
        return list(struct.unpack("<%df" % (len(payload) // 4), payload))

    @staticmethod
    def frequencies(spectrum):
        """Frequency in Hz of each point of a spectrum message."""
        return [spectrum["f0"] + i * spectrum["df"]
                for i in range(spectrum["points"])]

    @staticmethod
    def times(waveform, count=None):
        """Sample times in seconds for a message's waveform members."""
        n = waveform["points"] if count is None else count
        return [waveform["x_origin"] + i * waveform["x_inc"] for i in range(n)]
