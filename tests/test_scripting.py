# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Tests of the Python scripting module (clients/python/scopebridge.py) and of
scopebridge_run.py, against scopebridge-server's simulated scope.

    python3 tests/test_scripting.py            (part of make check-server)
"""

import csv
import glob
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENTS = os.path.join(ROOT, "clients", "python")
sys.path.insert(0, CLIENTS)
sys.path.insert(0, os.path.join(ROOT, "tests"))

from scopebridge import ServerError, Scope  # noqa: E402
from test_server import SERVER, free_port  # noqa: E402

RUN = os.path.join(CLIENTS, "scopebridge_run.py")


class ScriptingTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.log = os.path.join(cls.dir, "session.jsonl")
        cls.port = free_port()
        cls.server = subprocess.Popen(
            [SERVER, "--sim", "--port", str(cls.port), "--log", cls.log],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert "listening" in cls.server.stdout.readline()

    @classmethod
    def tearDownClass(cls):
        cls.server.kill()
        cls.server.wait()

    def setUp(self):
        self.scope = Scope(port=self.port)
        self.scope.scpi("*RST")

    def tearDown(self):
        self.scope.close()

    def path(self, name):
        return os.path.join(self.dir, name)

    def test_settings(self):
        self.assertIn("SIMULATED", self.scope.idn)
        self.scope.channel(1, scale=0.5, coupling="ac")
        self.scope.timebase(scale=2e-4)
        self.scope.trigger(level=0.25, slope="falling")
        st = self.scope.status()
        self.assertEqual((st["channels"][0]["scale"], st["channels"][0]["coupling"]),
                         (0.5, "ac"))
        self.assertAlmostEqual(st["timebase"]["scale"], 2e-4)
        self.assertEqual(st["trigger"]["slope"], "falling")
        with self.assertRaises(ServerError):
            self.scope.channel(3, scale=1)

    def test_triggers_and_setups(self):
        self.scope.pulse_trigger(when="pos_greater", width=3e-4, level=1.2)
        t = self.scope.status()["trigger"]
        self.assertEqual((t["mode"], t["pulse"]["when"]), ("pulse", "pos_greater"))
        self.scope.slope_trigger(time=5e-6, window="both")
        self.assertEqual(self.scope.status()["trigger"]["mode"], "slope")
        self.scope.edge_trigger(level=1.0)
        self.assertEqual(self.scope.status()["trigger"]["mode"], "edge")

        self.scope.timebase(scale=2e-3)
        self.scope.save_setup(self.path("a.setup"))
        self.scope.timebase(scale=5e-6)
        self.scope.load_setup(self.path("a.setup"))
        self.assertAlmostEqual(self.scope.status()["timebase"]["scale"], 2e-3)

    def test_measure(self):
        m = self.scope.measure(1)
        self.assertEqual(set(m), {"freq", "vpp", "vrms"})
        self.assertAlmostEqual(m["freq"], 1000)
        m = self.scope.measure(1, "period", "rise")
        self.assertAlmostEqual(m["period"], 1e-3)
        self.assertIsNone(m["rise"])

    def test_screen(self):
        w = self.scope.screen(1)
        self.assertEqual(w.points, 1200)
        self.assertAlmostEqual(max(w.volts()), 3.0, delta=0.05)
        w.save_csv(self.path("screen.csv"))
        with open(self.path("screen.csv")) as f:
            rows = list(csv.reader(f))
        self.assertEqual(rows[0], ["time_s", "ch1_V"])
        self.assertEqual(len(rows), 1201)

    def test_single_and_capture(self):
        self.scope.single()
        self.assertTrue(self.scope.wait_for_trigger(timeout=5))
        seen = []
        cap = self.scope.capture(1, progress=lambda d, t: seen.append(d))
        self.assertEqual(cap.points, 1_200_000)
        self.assertEqual(seen[-1], 1_200_000)
        self.assertAlmostEqual(cap.sample_rate, 1e8)
        volts = cap.volts(0, 99_999)
        self.assertEqual(len(volts), 100_000)
        cap.save_csv(self.path("cap.csv"), 0, 999)
        with open(self.path("cap.csv")) as f:
            self.assertEqual(sum(1 for _ in f), 1001)

        spectrum = cap.spectrum(window="flattop")
        f, level = spectrum.peak()
        self.assertAlmostEqual(f, 1000, delta=2 * spectrum.bin_width)
        self.assertAlmostEqual(level, 2.6, delta=0.2)
        zoom = cap.spectrum(f_max=20000, columns=200)
        self.assertEqual(len(zoom), 200)

    def test_decode(self):
        self.scope.scpi(":SIMulator:SIGNal UART")
        self.scope.channel(2, display=True)
        self.scope.capture(1)
        self.scope.capture(2)
        items = self.scope.decode("uart", tx=1, rx=2, baud=115200)
        self.assertIn("Hello, Rigol!", Scope.text(items, ch=1))
        self.assertIn("OK", Scope.text(items, ch=2))
        self.scope.bus("uart", tx=1, baud=115200, format="ascii")

    def test_timing(self):
        self.scope.scpi(":SIMulator:SIGNal TIMing")
        self.scope.channel(2, display=True)
        self.scope.capture(1)
        self.scope.capture(2)
        r = self.scope.timing(1, to=2)
        self.assertEqual(r["block"]["count"], 12)
        self.assertAlmostEqual(r["latency"]["min"], 20e-6, delta=1e-7)
        report = Scope.timing_report(r)
        self.assertIn("latency to CH2", report)
        self.assertIn("1 ms", report)
        r = self.scope.timing(2, burst_gap=100e-6)
        self.assertEqual(r["burst_pulses"]["max"], 12)
        self.assertIn("pulses/burst", Scope.timing_report(r))

    def test_acquire(self):
        self.scope.acquire(type="average", averages=8, memory_depth=12000)
        a = self.scope.status()["acquire"]
        self.assertEqual((a["type"], a["averages"], a["memory_depth"]),
                         ("average", 8, 12000))
        self.assertEqual(self.scope.capture(1).points, 12000)
        with self.assertRaises(ServerError):
            self.scope.acquire(memory_depth=5)

    def test_mask(self):
        m = self.scope.mask(enable=True, x=0.4, create=True, reset=True, run=True)
        self.assertTrue(m["running"])
        self.assertEqual(m["x"], 0.4)
        self.scope.screen(1)
        self.assertEqual(self.scope.mask()["passed"], 1)
        self.scope.mask(enable=False)

    def test_references(self):
        self.scope.ref_clear()
        self.scope.ref_save(1, 1, label="before")
        before = self.scope.ref(1)
        self.assertEqual((before.info["label"], before.points), ("before", 1200))
        # back in through ref_load, it keeps its volts within a count
        self.scope.ref_load(2, before.times(), before.volts(), label="copy", ch=1)
        copy = self.scope.ref(2)
        step = (max(before.volts()) - min(before.volts())) / 200
        for a, b in zip(before.volts(), copy.volts()):
            self.assertAlmostEqual(a, b, delta=step)
        self.assertEqual([r["slot"] for r in self.scope.refs()], [1, 2])
        self.scope.ref_clear()
        self.assertEqual(self.scope.refs(), [])

    def test_record(self):
        rows = self.scope.record(self.path("log.csv"), items=("freq", "vpp"),
                                 interval=0.1, count=3)
        self.assertEqual(rows, 3)
        with open(self.path("log.csv")) as f:
            table = list(csv.reader(f))
        self.assertEqual(table[0], ["time", "elapsed_s", "ch1_freq", "ch1_vpp"])
        self.assertEqual([r[2] for r in table[1:]], ["1000"] * 3)

    def test_screenshot(self):
        self.scope.screenshot(self.path("shot.bmp"))
        with open(self.path("shot.bmp"), "rb") as f:
            self.assertEqual(f.read(2), b"BM")

    def test_runner_script(self):
        script = self.path("script.py")
        with open(script, "w") as f:
            f.write("import sys\nfrom scopebridge import Scope\n"
                    "with Scope() as s:\n"
                    "    print(sys.argv[1], s.measure(1)['freq'])\n")
        out = subprocess.run([sys.executable, RUN, "--port", str(self.port),
                              script, "hello"],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(out.stdout.strip(), "hello 1000.0")

    def test_arduino_bench(self):
        # The bench on the simulator's serial signals: every case passes,
        # with the report and evidence written
        bench = os.path.join(ROOT, "examples", "arduino", "bench.py")
        out = subprocess.run([sys.executable, RUN, "--port", str(self.port), bench,
                              "--sim", "--out", self.path("bench")],
                             capture_output=True, text=True, timeout=120)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("4 of 4 passed", out.stdout)
        run = glob.glob(self.path("bench") + "/*/")[0]
        for name in ("report.md", "results.json", "uart-115200-8n1.bmp", "i2c-100k.csv",
                     "spi-mode0-msb.csv", "timing-crc16.txt"):
            self.assertTrue(os.path.exists(os.path.join(run, name)), name)
        with open(os.path.join(run, "results.json")) as f:
            timing = {r["name"]: r["timing"] for r in json.load(f)}
        self.assertEqual(timing["i2c-100k"], "SCL 100.0 kHz")
        self.assertEqual(timing["spi-mode0-msb"], "SCK 1.000 MHz")
        self.assertEqual(timing["timing-crc16"], "block 200.0 .. 356.0 us, latency 25.0 us")

    def test_arduino_bench_checks_fail(self):
        # A check that could not fail would prove nothing
        sys.path.insert(0, os.path.join(ROOT, "examples", "arduino"))
        import bench
        data = lambda values: [{"type": "data", "ch": 1, "value": v} for v in values]
        self.assertTrue(bench.check_spi([0x9F, 0xEF])(data([0x18, 0x9F, 0xEF]))[0])
        self.assertFalse(bench.check_spi([0x9F, 0xEF])(data([0x9F, 0xEE]))[0])
        stats = lambda n, lo, hi, mean=0, sd=0: {"count": n, "min": lo, "max": hi,
                                                  "mean": mean, "std_dev": sd}
        blocks = {"block": stats(12, 1e-4, 2e-4), "latency": stats(12, 2e-6, 3e-6)}
        timing = [blocks, {"burst_pulses": stats(12, 16, 32)}]
        self.assertTrue(bench.check_timing({16, 32})(timing)[0])
        self.assertFalse(bench.check_timing({8, 12})(timing)[0])
        blocks["latency"] = stats(12, 2e-6, 80e-6)
        self.assertFalse(bench.check_timing({16, 32})(timing)[0])
        # uart.c's echo
        echo = [{"type": "data", "ch": 2, "value": v} for v in b"rigol 42"] + \
               [{"type": "data", "ch": 1, "value": v} for v in b"RIGOL 42"]
        self.assertTrue(bench.check_echo("rigol 42")(echo)[0])
        self.assertIn("is D0 on CH2", bench.check_echo("rigol 42")(echo[8:])[1])
        self.assertIn("not the echo", bench.check_echo("rigol 42")(echo[:8])[1])
        # the channels' levels, and what a wrong probe setting looks like
        class FakeScope:
            def status(self):
                return {"channels": [{"ch": 1, "probe": 10.0}, {"ch": 2, "probe": 10.0}]}
        class FakeCapture:
            def __init__(self, low, high, overshoot=1.5):
                self.v = [low] * 500 + [high] * 500 + [high + overshoot] * 5
            def volts(self):
                return self.v
        levels = lambda low, high, overshoot=1.5: bench.level_problem(
            FakeScope(), {1: FakeCapture(low, high, overshoot)})
        self.assertIsNone(levels(0.0, 5.0))
        self.assertIn("7.90 V, far over 5 V: its probe is switched to x1, but the scope's "
                      "CH1 probe setting is 10x", levels(0.0, 7.9))      # clipped
        self.assertIn("0.50 V, a tenth of 5 V: its probe is switched to x10",
                      levels(0.0, 0.5, overshoot=0.1))
        self.assertIn("high level is 3.10 V, not about 5 V", levels(0.0, 3.1))
        self.assertIn("no signal", levels(0.0, 0.05, overshoot=0))       # not wired
        # delay.c: 100 us + 2 cycles, and markers of 2 cycles, at 8 ns samples
        delay = lambda mean, sd, marker: [
            {"block": stats(23, 0, 0, mean, sd), "resolution": 8e-9},
            {"block": stats(24, 0, 0, marker, 3e-9), "resolution": 8e-9}]
        check = bench.check_delay(100)
        self.assertTrue(check(delay(100.222e-6, 3.5e-9, 126.7e-9))[0])     # the real Uno
        self.assertFalse(check(delay(101.0e-6, 3.5e-9, 126.7e-9))[0])      # 0.9 % off
        self.assertFalse(check(delay(100.222e-6, 40e-9, 126.7e-9))[0])     # jitter
        self.assertFalse(check(delay(100.222e-6, 3.5e-9, 250e-9))[0])      # slow markers
        self.assertEqual(bench.delay_clock(100)(delay(100.222e-6, 0, 0), 8e-9),
                         "clock 15.9845 MHz (-0.097 %)")
        line = data(b"Hello, Rigol! 7\r\n")
        self.assertTrue(bench.check_uart(line)[0])
        line[3]["error"] = "parity"
        self.assertFalse(bench.check_uart(line)[0])
        self.assertFalse(bench.check_uart(data(b"Hello, Rig"))[0])
        good = [{"type": t[0]} if len(t) == 1 else
                {"type": t[0], "value": t[1], "read": t[2], "ack": t[3]} if t[0] == "address" else
                {"type": t[0], "value": t[1], "ack": t[2]} for t in bench.I2C_EXPECTED]
        self.assertTrue(bench.check_i2c(good)[0])
        good[11]["ack"] = True     # the last read acknowledged: wrong
        self.assertFalse(bench.check_i2c(good)[0])

    def test_runner_replay(self):
        # Act on this server, logged; replay the log on a fresh server
        self.scope.channel(1, scale=0.2)
        self.scope.timebase(scale=5e-4)
        client = self.scope.client.hello["client"]
        time.sleep(0.2)
        port = free_port()
        out = subprocess.run([sys.executable, RUN, "--sim", "--port", str(port),
                              "--replay", self.log, "--client", str(client)],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("ok    set_channel", out.stdout)
        self.assertIn("ok    set_timebase", out.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
