# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""A minimal client of Marionette, Firefox's remote control, for testing the
web interface in a real browser: start headless Firefox, navigate, run
scripts in the page, take screenshots."""

import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time


class Firefox:
    def __init__(self, width=1280, height=800, port=2828, downloads=None):
        """Headless Firefox with Marionette on port, and a session;
        downloads go to the directory downloads, without asking"""
        self.profile = tempfile.mkdtemp()
        with open(os.path.join(self.profile, "user.js"), "w") as f:
            f.write('user_pref("marionette.port", %d);\n' % port)
            if downloads:
                f.write('user_pref("browser.download.folderList", 2);\n'
                        'user_pref("browser.download.dir", "%s");\n'
                        'user_pref("browser.download.useDownloadDir", true);\n'
                        'user_pref("browser.download.always_ask_before_handling_new_types", false);\n'
                        % downloads)
        self.proc = subprocess.Popen(
            ["firefox", "--headless", "--marionette", "--profile", self.profile,
             "--window-size=%d,%d" % (width, height)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                self.sock = socket.create_connection(("127.0.0.1", port))
                break
            except OSError:
                time.sleep(0.2)
        self.buf = b""
        self.read()                       # the server's hello
        self.id = 0
        self.call("WebDriver:NewSession", {"capabilities": {}})
        self.call("WebDriver:SetWindowRect", {"width": width, "height": height})

    def read(self):
        while b":" not in self.buf:
            self.buf += self.sock.recv(65536)
        n, rest = self.buf.split(b":", 1)
        n = int(n)
        while len(rest) < n:
            rest += self.sock.recv(65536)
        self.buf = rest[n:]
        return json.loads(rest[:n])

    def call(self, name, params=None):
        self.id += 1
        data = json.dumps([0, self.id, name, params or {}]).encode()
        self.sock.sendall(str(len(data)).encode() + b":" + data)
        while True:
            msg = self.read()
            if msg[0] == 1 and msg[1] == self.id:
                if msg[2]:
                    raise RuntimeError("%s: %s" % (name, msg[2].get("message")))
                return msg[3]

    def go(self, url):
        self.call("WebDriver:Navigate", {"url": url})

    def js(self, script, *args):
        return self.call("WebDriver:ExecuteScript",
                         {"script": script, "args": list(args)}).get("value")

    def shot(self, path):
        data = self.call("WebDriver:TakeScreenshot", {"full": False})["value"]
        with open(path, "wb") as f:
            f.write(base64.b64decode(data))

    def close(self):
        try:
            self.call("Marionette:Quit")
        except Exception:
            pass
        self.proc.wait(timeout=10)
        shutil.rmtree(self.profile, ignore_errors=True)
