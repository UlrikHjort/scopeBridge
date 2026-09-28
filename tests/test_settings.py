# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Tests of ~/.scopebridgerc: the programs' defaults from the settings file,
command-line options over it, and warnings for what it cannot use.  Each
test writes its own file and names it with $SCOPEBRIDGE_RC.

    python3 tests/test_settings.py            (make check-server)
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))

from test_server import SERVER, free_port  # noqa: E402

TERM = os.path.join(ROOT, "bin", "scopebridge-term")


class SettingsTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.rc = os.path.join(self.dir, "scopebridgerc")
        self.env = dict(os.environ, SCOPEBRIDGE_RC=self.rc)
        self.processes = []

    def tearDown(self):
        for p in self.processes:
            p.kill()
            p.wait()
            p.stdout.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, text):
        with open(self.rc, "w") as f:
            f.write(text)

    def server(self, *args):
        """The server's first lines of output, once it listens (or ends)"""
        p = subprocess.Popen([SERVER] + list(args), env=self.env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.processes.append(p)
        lines = []
        for line in p.stdout:
            lines.append(line)
            if "listening" in line:
                break
        return "".join(lines)

    def test_server_from_the_file(self):
        port = free_port()
        self.write("# a comment\n[server]\nsource = sim      # the simulator\nport = %d\n" % port)
        self.assertIn("sim, listening on 127.0.0.1:%d" % port, self.server())

    def test_options_win(self):
        port, other = free_port(), free_port()
        self.write("[server]\nsource = lan 192.0.2.1\nport = %d\n" % port)
        out = self.server("--sim", "--port", str(other))
        self.assertIn("sim, listening on 127.0.0.1:%d" % other, out)

    def test_unknown_setting_is_a_warning(self):
        port = free_port()
        self.write("[server]\nsource = sim\nport = %d\nprot = 1\n[clients]\nhost = x\n" % port)
        out = self.server()
        self.assertIn("scopebridgerc:4: unknown setting prot in [server]", out)
        self.assertIn("scopebridgerc:5: unknown section [clients]", out)
        self.assertIn("listening", out)

    def test_bad_source_is_an_error(self):
        self.write("[server]\nsource = usb\n")
        out = subprocess.run([SERVER], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("[server] source = usb: it must be usb DEVICE, usb auto", out.stderr)

    def test_clients_find_the_server(self):
        port = free_port()
        self.write("[server]\nsource = sim\nport = %d\n[client]\nhost = 127.0.0.1\nport = %d\n"
                   % (port, port))
        self.server()
        out = subprocess.run([TERM], input="scpi *IDN?\n", env=self.env,
                             capture_output=True, text=True, timeout=20)
        self.assertIn("SIMULATED", out.stdout)
        # Python too, in a process of its own with the same environment
        code = "from scopebridge import Scope\nwith Scope() as s: print(s.source)"
        out = subprocess.run([sys.executable, "-c", code], env=self.env, capture_output=True,
                             text=True, timeout=20,
                             cwd=os.path.join(ROOT, "clients", "python"))
        self.assertEqual(out.stdout.strip(), "sim", out.stderr)

    def test_start_script(self):
        # The script, as installed, with a stand-in GUI that tells how it
        # was started
        bin_dir = os.path.join(self.dir, "bin")
        os.mkdir(bin_dir)
        shutil.copy(os.path.join(ROOT, "scopebridge.sh"), bin_dir)
        os.symlink(SERVER, os.path.join(bin_dir, "scopebridge-server"))
        gui = os.path.join(bin_dir, "scopebridge-gui")
        with open(gui, "w") as f:
            f.write('#!/bin/sh\necho "GUI $*"\n')
        os.chmod(gui, 0o755)

        def run(*args):
            out = subprocess.run([os.path.join(bin_dir, "scopebridge.sh")] + list(args),
                                 env=self.env, capture_output=True, text=True, timeout=30)
            return out.stdout.strip().splitlines()[-1]

        # [client] host elsewhere: only the GUI, connected there
        self.write("[client]\nhost = 192.0.2.19\nport = 5030\n")
        self.assertEqual(run(), "GUI --host 192.0.2.19 --port 5030")
        self.assertEqual(run("--host", "other"), "GUI --host other --port 5030")
        # a server here, from [server]; the GUI connects to it, not elsewhere
        port = free_port()
        self.write("[server]\nsource = sim\nport = %d\n[client]\nhost = 192.0.2.19\n" % port)
        self.assertEqual(run("--sim", "--port", str(port)), "GUI --host 127.0.0.1 --port %d" % port)
        self.write("[server]\nsource = sim\nport = %d\n" % port)
        self.assertEqual(run(), "GUI --host 127.0.0.1 --port %d" % port)


if __name__ == "__main__":
    unittest.main(verbosity=2)
