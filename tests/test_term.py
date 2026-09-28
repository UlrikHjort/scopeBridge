# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Tests of scopebridge-term, the terminal client, fed commands through a pipe,
against scopebridge-server's simulated scope.

    python3 tests/test_term.py            (part of make check-server)
"""

import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#  Never the user's own ~/.scopebridgerc: its [client] host could send
#  the tests to a real scope elsewhere
os.environ["SCOPEBRIDGE_RC"] = ""

sys.path.insert(0, os.path.join(ROOT, "tests"))

from test_server import SERVER, VERSION, free_port  # noqa: E402

TERM = os.path.join(ROOT, "bin", "scopebridge-term")


class TermTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.port = free_port()
        cls.server = subprocess.Popen([SERVER, "--sim", "--port", str(cls.port)],
                                      stdout=subprocess.PIPE, text=True)
        assert "listening" in cls.server.stdout.readline()

    @classmethod
    def tearDownClass(cls):
        cls.server.kill()
        cls.server.wait()

    def run_term(self, commands):
        return subprocess.run([TERM, "--port", str(self.port)],
                              input="scpi *RST\n" + commands, capture_output=True,
                              text=True, timeout=60)

    def test_versions(self):
        for program in ("server", "gui", "term"):
            out = subprocess.run([os.path.join(ROOT, "bin", "scopebridge-" + program), "--version"],
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(out.returncode, 0, program)
            self.assertEqual(out.stdout, "scopebridge-%s %s\n" % (program, VERSION))

    def test_settings_and_measure(self):
        out = self.run_term("ch 1 scale 500m coupling ac\ntb scale 2m\nstatus\n"
                            "measure 1 freq vpp pduty\n")
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertIn("CH1  on  500.0 mV/div", out.stdout)
        self.assertIn("AC", out.stdout)
        self.assertIn("timebase 2.00 ms/div", out.stdout)
        self.assertIn("freq 1.00 kHz", out.stdout)
        self.assertIn("pduty 50.0 %", out.stdout)

    def test_watch_draws_both_channels(self):
        out = self.run_term("ch 2 on\nwatch all 1\n")
        plot = [l for l in out.stdout.splitlines() if l.startswith("|")]
        self.assertEqual(len(plot), 17)
        self.assertTrue(any("#" in l for l in plot))
        self.assertTrue(any("o" in l for l in plot))
        self.assertIn("CH1: freq 1.00 kHz", out.stdout)

    def test_capture_save_spectrum(self):
        csv = os.path.join(self.dir, "cap.csv")
        out = self.run_term("capture 1\nsave %s\nspectrum 1 flattop\n" % csv)
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertIn("CH1: 1200000 points", out.stdout)
        with open(csv) as f:
            self.assertEqual(sum(1 for _ in f), 1_200_001)
        # strongest line: the fundamental at 1 kHz, 2.6 dBV; and no line
        # from DC's spread (as there was at 286 Hz)
        lines = [l for l in out.stdout.splitlines() if l.strip()[:2] in
                 ("1.", "2.", "3.", "4.", "5.", "6.", "7.", "8.")]
        self.assertIn("1.00 kHz   2.6", lines[0])
        self.assertFalse(any(" Hz " in l and "kHz" not in l for l in lines), lines)

    def test_files(self):
        shot = os.path.join(self.dir, "s.bmp")
        setup = os.path.join(self.dir, "s.setup")
        out = self.run_term("screenshot %s\nsetup save %s\ntb scale 5m\n"
                            "setup load %s\ntb\n" % (shot, setup, setup))
        self.assertEqual(out.returncode, 0, out.stdout)
        with open(shot, "rb") as f:
            self.assertEqual(f.read(2), b"BM")
        self.assertIn("timebase 1.00 ms/div", out.stdout)   # restored

    def test_decode_and_bus(self):
        out = self.run_term("scpi :SIMulator:SIGNal IIC\nch 2 on\ncapture 1\ncapture 2\n"
                            "decode i2c show 3\nbus i2c scl 1 sda 2\nbus 2 off\n")
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertIn("START", out.stdout)
        self.assertIn("address 50 write  ack", out.stdout)
        self.assertIn("(show N for more)", out.stdout)
        out = self.run_term("scpi :SIMulator:SIGNal UART\nch 2 on\ncapture 1\ncapture 2\n"
                            "decode uart tx 1 rx 2 baud 115200 show 0\n")
        self.assertIn("CH1 text: Hello, Rigol!\\r\\n", out.stdout)
        self.assertIn("CH2 text: OK", out.stdout)

    def test_timing(self):
        out = self.run_term("scpi :SIMulator:SIGNal TIMing\nch 2 on\ncapture 1\ncapture 2\n"
                            "timing 1 to 2\ntiming 2 gap 100u bins 5\n")
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertRegex(out.stdout, r"block +12 +200.0 us +229.0 us +356.0 us")
        self.assertRegex(out.stdout, r"period +11 +1.00 ms")
        self.assertIn("latency to CH2", out.stdout)
        self.assertIn("longest block at 3.10 ms", out.stdout)
        self.assertRegex(out.stdout, r"200.0 us \|#{40} 10")
        self.assertRegex(out.stdout, r"pulses/burst +12 +8.00 +8.67 +12.00")
        self.assertIn("burst lengths:", out.stdout)

    def test_mask_and_refs(self):
        csv = os.path.join(self.dir, "r1.csv")
        out = self.run_term("mask on create run x 0.2\nwatch 1 2\nmask\nmask off\n"
                            "ref save 1 1\nref export 1 %s\nref load 2 %s 1\nref\n"
                            "ref clear\nref\n" % (csv, csv))
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertIn("pass/fail on, running, ch1, mask x 0.20 div, y 0.96 div", out.stdout)
        self.assertRegex(out.stdout, r"passed [1-9]\d*   failed 0")
        self.assertIn("saved 1200 points", out.stdout)
        self.assertIn("R2  r1.csv  1200 points over 12.0 ms", out.stdout)
        self.assertIn("no references", out.stdout)

    def test_acquisition(self):
        out = self.run_term("acq type average averages 16 depth 120k\nstatus\n"
                            "ch 2 on\nacq\nacq depth 120k\n")
        self.assertIn("acquisition average of 16, memory 120.0 kpts", out.stdout)
        self.assertIn("acquisition average of 16, memory 60.0 kpts", out.stdout)
        self.assertIn("with both channels on, 6000", out.stdout)
        self.assertEqual(out.returncode, 1)   # the last command failed

    def test_errors_do_not_stop_a_script(self):
        out = self.run_term("bogus\nch 3 scale 1\nch 1 scale lots\n"
                            'raw {"cmd": "fly"}\nscpi *IDN?\n')
        self.assertEqual(out.returncode, 1)                 # there were errors
        self.assertIn("unknown command bogus", out.stdout)
        self.assertIn("channel must be 1 or 2", out.stdout)
        self.assertIn("not a number: lots", out.stdout)
        self.assertIn('unknown cmd "fly"', out.stdout)
        self.assertIn("SIMULATED", out.stdout)              # and it went on


if __name__ == "__main__":
    unittest.main(verbosity=2)
