#!/usr/bin/env python3
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Run a script against scopebridge-server, or replay a command log.

    scopebridge_run.py script.py [args...]             a server already running
    scopebridge_run.py --lan 192.168.0.83 script.py    start a server for it
    scopebridge_run.py --sim script.py                 ... on the simulated scope
    scopebridge_run.py --replay session.jsonl          replay a --log file

Scripts use the scopebridge module (from scopebridge import Scope); the runner makes it
importable and points Scope() at the server.  A server the runner starts
is stopped when the script ends.

--replay sends the requests of a command log again, in order, and reports
each reply.  --client N replays only that client's requests; --timing keeps
the original pauses between them.  "live" requests are skipped, since a
replay does not watch events.
"""

import argparse
import json
import os
import runpy
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def find_server():
    """$SCOPEBRIDGE_SERVER, bin/ of the source tree, or scopebridge-server on the PATH
    (installed)."""
    import shutil
    if os.environ.get("SCOPEBRIDGE_SERVER"):
        return os.environ["SCOPEBRIDGE_SERVER"]
    built = os.path.join(ROOT, "bin", "scopebridge-server")
    if os.access(built, os.X_OK):
        return built
    return shutil.which("scopebridge-server") or built


SERVER = find_server()

sys.path.insert(0, HERE)
from scopebridge_client import ServerError, ScopeBridgeClient  # noqa: E402


def listening(host, port):
    with socket.socket() as s:
        s.settimeout(3)
        return s.connect_ex((host, port)) == 0


def start_server(source, port):
    server = subprocess.Popen([SERVER] + source + ["--port", str(port)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True)
    line = server.stdout.readline()
    if "listening" not in line:
        server.wait()
        sys.exit("scopebridge_run: the server did not start: " + line.strip())
    return server


def parse_time(stamp):
    return time.mktime(time.strptime(stamp[:19], "%Y-%m-%d %H:%M:%S")) + \
        float("0" + stamp[19:])


def replay(path, host, port, client_filter, timing):
    with open(path) as f:
        entries = [json.loads(line) for line in f if line.strip()]
    requests = [e for e in entries if "request" in e and
                isinstance(e["request"], dict) and
                (client_filter is None or e["client"] == client_filter)]
    failures = 0
    with ScopeBridgeClient(host, port) as client:
        previous = None
        for entry in requests:
            request = dict(entry["request"])
            cmd = request.pop("cmd", None)
            request.pop("id", None)
            if cmd is None or cmd == "live":
                continue
            if timing and previous is not None:
                time.sleep(max(0.0, parse_time(entry["t"]) - previous))
            previous = parse_time(entry["t"])
            try:
                reply, payload = client.request(cmd, **request)
                extra = {k: v for k, v in reply.items() if k not in ("id", "ok")}
                print("ok    %-12s %s%s" % (cmd, json.dumps(request),
                                           ("  -> " + json.dumps(extra)[:100])
                                           if extra else ""))
            except ServerError as e:
                failures += 1
                print("FAIL  %-12s %s  -> %s" % (cmd, json.dumps(request), e))
            # a replay does not use events such as capture progress
            client._events.clear()
    return failures


def main():
    parser = argparse.ArgumentParser(
        description="Run a script against scopebridge-server, or replay a log.")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--usb", metavar="DEVICE")
    source.add_argument("--lan", metavar="HOST[:PORT]")
    source.add_argument("--sim", action="store_true")
    parser.add_argument("--host", default=os.environ.get("RIGOL_HOST", "127.0.0.1"),
                        help="the server's computer (default $RIGOL_HOST, else "
                             "127.0.0.1)")
    parser.add_argument("--port", type=int, default=5026,
                        help="server port (default 5026)")
    parser.add_argument("--replay", metavar="LOG")
    parser.add_argument("--client", type=int, help="replay only this client")
    parser.add_argument("--timing", action="store_true",
                        help="replay with the original pauses")
    parser.add_argument("script", nargs="?")
    parser.add_argument("args", nargs=argparse.REMAINDER)
    options = parser.parse_args()

    if not options.replay and not options.script:
        parser.error("give a script or --replay LOG")

    server = None
    wanted = (["--usb", options.usb] if options.usb else
              ["--lan", options.lan] if options.lan else
              ["--sim"] if options.sim else None)
    local = options.host in ("127.0.0.1", "localhost", "::1")
    if wanted and not local:
        parser.error("--usb, --lan and --sim start a server here; with --host, "
                     "the server runs on that computer")
    if listening(options.host, options.port):
        if wanted:
            print("scopebridge_run: a server is already listening on port %d; using it"
                  % options.port, file=sys.stderr)
    elif wanted:
        server = start_server(wanted, options.port)
    else:
        sys.exit("scopebridge_run: no server at %s:%d; start one, or give "
                 "--usb, --lan or --sim" % (options.host, options.port))

    os.environ["RIGOL_HOST"] = options.host
    os.environ["RIGOL_PORT"] = str(options.port)
    try:
        if options.replay:
            failures = replay(options.replay, options.host, options.port, options.client,
                              options.timing)
            sys.exit(1 if failures else 0)
        sys.argv = [options.script] + options.args
        runpy.run_path(options.script, run_name="__main__")
    finally:
        if server:
            server.terminate()
            server.wait()


if __name__ == "__main__":
    main()
