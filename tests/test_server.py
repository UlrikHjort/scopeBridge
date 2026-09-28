# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Protocol tests for scopebridge-server, run against its simulated scope.

    python3 tests/test_server.py            (make check-server)

Starts bin/scopebridge-server --sim on a free port and checks every request
and event of docs/PROTOCOL.md.
"""

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))

from scopebridge_client import ServerError, ScopeBridgeClient  # noqa: E402

SERVER = os.path.join(ROOT, "bin", "scopebridge-server")

#  The version the programs are built with (server/src/scopebridge_version.ads)
with open(os.path.join(ROOT, "server", "src", "scopebridge_version.ads"), encoding="utf-8") as f:
    VERSION = re.search(r'Version : constant String := "([^"]+)"', f.read()).group(1)
MEMORY_DEPTH = 1_200_000


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ServerBase(unittest.TestCase):
    """Runs a server on the simulator for the test class."""

    extra_args = []

    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        cls.server = subprocess.Popen(
            [SERVER, "--sim", "--port", str(cls.port)] + cls.extra_args,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = cls.server.stdout.readline()
        assert "listening" in line, line

    @classmethod
    def tearDownClass(cls):
        cls.server.kill()
        cls.server.wait()

    def setUp(self):
        self.c = ScopeBridgeClient(port=self.port)
        self.c.request("scpi", text="*RST")

    def tearDown(self):
        self.c.close()

    def assertFails(self, fragment, cmd, **members):
        with self.assertRaises(ServerError) as ctx:
            self.c.request(cmd, **members)
        self.assertIn(fragment, str(ctx.exception))

    def capture(self, ch=1):
        info, _ = self.c.request("capture", ch=ch)
        progress = []
        while self.c._events:
            event, _ = self.c.next_event()
            if event["event"] == "progress":
                progress.append(event["done"])
        return info, progress


class ServerTest(ServerBase):

    # -- connection ---------------------------------------------------------

    def test_hello(self):
        h = self.c.hello
        self.assertEqual(h["protocol"], 1)
        self.assertEqual(h["source"], "sim")
        self.assertIn("SIMULATED", h["idn"])
        self.assertEqual(h["version"], VERSION)

    def test_malformed_requests(self):
        self.c.send_raw("this is not json")
        reply, _ = self.c.read_reply()
        self.assertIsNone(reply["id"])
        self.assertFalse(reply["ok"])

        self.c.send_raw('{"id": 5}')
        reply, _ = self.c.read_reply()
        self.assertEqual(reply["id"], 5)
        self.assertIn('missing "cmd"', reply["error"])

        self.assertFails('unknown cmd "fly"', "fly")
        # the connection is still usable
        self.c.request("run")

    # -- settings -----------------------------------------------------------

    def test_status_after_reset(self):
        st, _ = self.c.request("status")
        self.assertEqual(st["trigger_status"], "td")
        ch1, ch2 = st["channels"]
        self.assertEqual((ch1["ch"], ch1["display"]), (1, True))
        self.assertEqual((ch2["ch"], ch2["display"]), (2, False))
        self.assertEqual(ch1["coupling"], "dc")
        self.assertAlmostEqual(st["timebase"]["scale"], 1e-3)
        self.assertEqual(st["trigger"]["source"], "ch1")
        self.assertEqual(st["trigger"]["slope"], "rising")
        self.assertEqual(st["trigger"]["sweep"], "auto")

    def test_set_channel(self):
        self.c.request("set_channel", ch=2, display=True, scale=0.5,
                       offset=-0.25, coupling="ac", probe=1)
        ch2 = self.c.request("status")[0]["channels"][1]
        self.assertEqual(ch2["display"], True)
        self.assertAlmostEqual(ch2["scale"], 0.5)
        self.assertAlmostEqual(ch2["offset"], -0.25)
        self.assertEqual(ch2["coupling"], "ac")
        self.assertAlmostEqual(ch2["probe"], 1)

        # integers are accepted where numbers are expected
        self.c.request("set_channel", ch=1, scale=2)
        self.assertAlmostEqual(
            self.c.request("status")[0]["channels"][0]["scale"], 2.0)

    def test_set_channel_rejects(self):
        self.assertFails('"ch" must be 1 or 2', "set_channel", ch=3)
        self.assertFails('missing "ch"', "set_channel", scale=1)
        self.assertFails('"coupling" must be', "set_channel", ch=1,
                         coupling="xx")
        self.assertFails('"probe" must be one of', "set_channel", ch=1,
                         probe=3)
        self.assertFails('"scale" must be positive', "set_channel", ch=1,
                         scale=0)
        self.assertFails('"scale" must be a number', "set_channel", ch=1,
                         scale="big")
        # a rejected request changes nothing, even its valid members
        self.assertFails('"coupling" must be', "set_channel", ch=1,
                         scale=5, coupling="xx")
        self.assertAlmostEqual(
            self.c.request("status")[0]["channels"][0]["scale"], 1.0)

    def test_timebase_and_trigger(self):
        self.c.request("set_timebase", scale=2e-4, offset=1e-4)
        self.c.request("set_trigger", source="ch2", slope="falling",
                       level=0.25, sweep="normal")
        st, _ = self.c.request("status")
        self.assertAlmostEqual(st["timebase"]["scale"], 2e-4)
        self.assertAlmostEqual(st["timebase"]["offset"], 1e-4)
        self.assertEqual(st["trigger"], {"source": "ch2", "slope": "falling",
                                         "level": 0.25, "sweep": "normal",
                                         "mode": "edge"})
        self.assertFails('"slope" must be', "set_trigger", slope="up")

    def test_pulse_trigger(self):
        self.c.request("set_trigger", mode="pulse",
                       pulse={"source": "ch1", "when": "neg_in_range",
                              "lower": 1e-4, "upper": 8e-4, "level": 1.2})
        t = self.c.request("status")[0]["trigger"]
        self.assertEqual(t["mode"], "pulse")
        self.assertEqual((t["pulse"]["when"], t["pulse"]["source"]),
                         ("neg_in_range", "ch1"))
        # widened from the default 1 .. 2 us: the order of setting matters
        self.assertAlmostEqual(t["pulse"]["lower"], 1e-4)
        self.assertAlmostEqual(t["pulse"]["upper"], 8e-4)
        self.assertNotIn("slope_trigger", t)
        # and narrowed again, below the old lower limit
        self.c.request("set_trigger", pulse={"lower": 1e-6, "upper": 5e-6})
        t = self.c.request("status")[0]["trigger"]
        self.assertAlmostEqual(t["pulse"]["lower"], 1e-6)
        self.assertAlmostEqual(t["pulse"]["upper"], 5e-6)

    def test_slope_trigger(self):
        self.c.request("set_trigger", mode="slope",
                       slope_trigger={"when": "pos_less", "time": 5e-6,
                                      "window": "both", "level_a": 2.5,
                                      "level_b": 0.5})
        t = self.c.request("status")[0]["trigger"]
        self.assertEqual(t["mode"], "slope")
        d = t["slope_trigger"]
        self.assertEqual((d["when"], d["window"]), ("pos_less", "both"))
        self.assertAlmostEqual(d["time"], 5e-6)
        self.assertAlmostEqual(d["level_a"], 2.5)
        self.assertNotIn("pulse", t)

    def test_trigger_rejects(self):
        self.assertFails('"mode" must be', "set_trigger", mode="video")
        self.assertFails('"when" must be', "set_trigger", pulse={"when": "x"})
        self.assertFails('"source" must be "ch1" or "ch2"', "set_trigger",
                         pulse={"source": "ext"})
        self.assertFails('"width" must be positive', "set_trigger",
                         pulse={"width": 0})
        self.assertFails("need lower < upper", "set_trigger",
                         slope_trigger={"lower": 2e-6, "upper": 1e-6})
        self.assertFails('"pulse" must be an object', "set_trigger", pulse=3)
        # a rejected request changes nothing, even its valid members
        self.assertFails('"when" must be', "set_trigger", mode="pulse",
                         pulse={"when": "x"})
        self.assertEqual(self.c.request("status")[0]["trigger"]["mode"], "edge")

    def test_setups(self):
        import base64
        self.c.request("set_channel", ch=2, display=True, scale=0.5, offset=0.25)
        self.c.request("set_trigger", level=0.75, slope="falling", sweep="normal")
        self.c.request("set_acquire", type="average", averages=32, memory_depth=60000)
        setup = self.c.request("save_setup")[0]["setup"]
        saved = self.c.request("status")[0]

        self.c.request("set_timebase", scale=5e-3)
        self.c.request("set_channel", ch=1, scale=2, coupling="ac")
        self.c.request("set_channel", ch=2, display=False)
        self.c.request("set_trigger", mode="pulse", level=0.1, slope="rising")
        self.c.request("set_acquire", type="peak", memory_depth=0)
        reply = self.c.request("load_setup", setup=setup)[0]
        self.assertNotIn("warnings", reply)
        st = self.c.request("status")[0]
        for key in ("channels", "timebase", "acquire"):
            self.assertEqual(st[key], saved[key], key)
        self.assertEqual(st["trigger"]["mode"], "edge")
        self.assertEqual((st["trigger"]["slope"], st["trigger"]["level"],
                          st["trigger"]["sweep"]), ("falling", 0.75, "normal"))

        # the scope's own block alone (older setup files): only what the
        # scope restores from it, the timebase
        data = base64.b64decode(setup)
        self.assertTrue(data.startswith(b"RIGOL-SERVER-SETUP 1\n"))
        block = data.split(b"\n", 2)[2]
        self.c.request("set_timebase", scale=5e-3)
        self.c.request("set_channel", ch=1, scale=2)
        self.c.request("load_setup", setup=base64.b64encode(block).decode())
        st = self.c.request("status")[0]
        self.assertAlmostEqual(st["timebase"]["scale"], 1e-3)
        self.assertAlmostEqual(st["channels"][0]["scale"], 2.0)

        self.assertFails("not base64", "load_setup", setup="#not*base64")
        self.assertFails('"setup" is empty', "load_setup", setup="")
        self.assertFails("damaged", "load_setup",
                         setup=base64.b64encode(b"RIGOL-SERVER-SETUP 1\n{no").decode())

    def test_acquire(self):
        a = self.c.request("status")[0]["acquire"]
        self.assertEqual((a["type"], a["memory_depth"]), ("normal", 0))
        self.assertAlmostEqual(a["sample_rate"], MEMORY_DEPTH / 12e-3, delta=1)
        self.c.request("set_acquire", type="average", averages=64, memory_depth=120000)
        a = self.c.request("status")[0]["acquire"]
        self.assertEqual((a["type"], a["averages"], a["memory_depth"]),
                         ("average", 64, 120000))
        info, _ = self.capture(1)
        self.assertEqual(info["points"], 120000)
        # both channels on: the scope keeps the depth's place in its list
        self.c.request("set_channel", ch=2, display=True)
        self.assertEqual(self.c.request("status")[0]["acquire"]["memory_depth"], 60000)
        self.assertFails("with both channels on, 6000, 60000, 600000, 6000000 or "
                         "12000000", "set_acquire", memory_depth=120000)
        self.assertFails("power of two", "set_acquire", averages=3)
        self.assertFails('"type"', "set_acquire", type="fast")
        # stopped, as after the capture above: the scope would ignore it
        self.assertFails("only while running", "set_acquire", memory_depth=0)
        self.c.request("run")
        self.c.request("set_acquire", memory_depth=0)
        self.assertEqual(self.c.request("status")[0]["acquire"]["memory_depth"], 0)

    def test_run_stop(self):
        self.c.request("stop")
        self.assertEqual(self.c.request("status")[0]["trigger_status"], "stop")
        self.c.request("run")
        self.assertEqual(self.c.request("status")[0]["trigger_status"], "td")

    # -- measuring ----------------------------------------------------------

    def test_measure(self):
        m, _ = self.c.request("measure", ch=1)
        self.assertAlmostEqual(m["freq"], 1000.0)
        self.assertAlmostEqual(m["vpp"], 3.0)
        self.assertNotIn("period", m)                   # not asked for
        m, _ = self.c.request("measure", ch=2)          # not displayed
        self.assertEqual((m["freq"], m["vpp"], m["vrms"]), (None, None, None))

    def test_measure_items(self):
        items = ["freq", "period", "vpp", "vmax", "vmin", "vtop", "vbase",
                 "vamp", "vavg", "vrms", "rise", "fall", "pwidth", "nwidth",
                 "pduty", "nduty"]
        m, _ = self.c.request("measure", ch=1, items=items)
        self.assertEqual(set(items) - set(m), set())
        self.assertAlmostEqual(m["period"], 1e-3)
        self.assertAlmostEqual(m["vavg"], 1.5)
        self.assertAlmostEqual(m["pduty"], 0.5)
        self.assertIsNone(m["rise"])        # "measure error!" on the scope
        self.assertFails('items must be among', "measure", ch=1,
                         items=["freq", "bogus"])
        self.assertFails('"items" must be an array', "measure", ch=1,
                         items="freq")

    def collect_live(self, seconds=1.0, **members):
        """Frames and measure events of one live period, by channel."""
        self.c.request("live", on=True, interval_ms=50, **members)
        frames, measures = {}, {}
        deadline = time.time() + seconds
        while time.time() < deadline:
            event, payload = self.c.next_event(timeout=5)
            if event["event"] == "frame":
                frames[event["ch"]] = (event, payload)
            elif event["event"] == "measure":
                measures[event["ch"]] = event
        self.c.request("live", on=False)
        self.c._events.clear()
        return frames, measures

    def test_live(self):
        self.c.request("set_channel", ch=2, display=True)
        frames, measures = self.collect_live()
        self.assertEqual(sorted(frames), [1, 2])
        # measurements for one channel only: by default the lowest shown
        self.assertEqual(sorted(measures), [1])

        event, payload = frames[1]
        self.assertEqual(event["points"], 1200)
        self.assertEqual(len(payload), 1200)
        volts = ScopeBridgeClient.volts(event, payload)
        self.assertAlmostEqual(min(volts), 0.0, delta=0.05)
        self.assertAlmostEqual(max(volts), 3.0, delta=0.05)
        self.assertAlmostEqual(event["x_inc"], 1e-5)
        self.assertAlmostEqual(measures[1]["vpp"], 3.0)

        # after the reply to live off, no more frames
        with self.assertRaises(socket.timeout):
            self.c.next_event(timeout=0.3)

    def test_live_measure_ch(self):
        self.c.request("set_channel", ch=2, display=True)
        _, measures = self.collect_live(measure_ch=2)
        self.assertEqual(sorted(measures), [2])
        self.assertAlmostEqual(measures[2]["vpp"], 2.0)

        frames, measures = self.collect_live(measure_ch=0)
        self.assertEqual((sorted(frames), measures), ([1, 2], {}))

        _, measures = self.collect_live(
            measure_items=["period", "vavg", "pduty", "vmax", "vmin"])
        self.assertEqual(set(measures[1]) - {"ch", "event"},
                         {"period", "vavg", "pduty", "vmax", "vmin"})
        self.assertFails("at most 5 items", "live", on=True,
                         measure_items=["freq"] * 6)
        # a rejected request changes nothing
        self.assertFails('"measure_ch" must be', "live", on=True,
                         measure_ch=7, measure_items=["freq"])

        self.assertFails('"measure_ch" must be 0, 1 or 2', "live", on=True,
                         measure_ch=3)
        self.assertFails('"interval_ms" must be >= 50', "live", on=True,
                         interval_ms=10)

    def test_live_after_capture(self):
        # a memory read leaves STARt/STOP at its last batch; live frames
        # must still be whole screens
        self.capture()
        self.c.request("run")
        frames, _ = self.collect_live(seconds=0.5)
        self.assertEqual(frames[1][0]["points"], 1200)

    def test_screen(self):
        info, raw = self.c.request("screen", ch=1)
        self.assertEqual((info["ch"], info["points"], len(raw)), (1, 1200, 1200))
        volts = ScopeBridgeClient.volts(info, raw)
        self.assertAlmostEqual(max(volts), 3.0, delta=0.05)
        # also right after a capture moved the waveform settings
        self.capture()
        info, raw = self.c.request("screen", ch=1)
        self.assertEqual(info["points"], 1200)

    # -- capture ------------------------------------------------------------

    def test_capture(self):
        info, progress = self.capture()
        self.assertEqual(info["points"], MEMORY_DEPTH)
        self.assertEqual(progress, [250_000, 500_000, 750_000, 1_000_000,
                                    MEMORY_DEPTH])
        self.assertAlmostEqual(info["x_inc"], 12e-3 / MEMORY_DEPTH)
        # capture stops the scope
        self.assertEqual(self.c.request("status")[0]["trigger_status"], "stop")

    def test_view_and_samples(self):
        info, _ = self.capture()
        view, data = self.c.request("view", ch=1, first=0,
                                    last=MEMORY_DEPTH - 1, columns=800)
        self.assertEqual((view["columns"], len(data)), (800, 1600))
        lows, highs = data[0::2], data[1::2]
        self.assertTrue(all(lo <= hi for lo, hi in zip(lows, highs)))
        # 12 ms of 1 kHz square: 0 V (raw 127) and 3 V (raw 202) both seen
        self.assertAlmostEqual(min(lows), 127, delta=2)
        self.assertAlmostEqual(max(highs), 202, delta=2)
        # a column across an edge spans both levels
        self.assertTrue(any(hi - lo > 60 for lo, hi in zip(lows, highs)))

        # fewer samples than columns: one column per sample
        view, data = self.c.request("view", ch=1, first=100, last=109,
                                    columns=800)
        self.assertEqual((view["columns"], len(data)), (10, 20))
        self.assertEqual(data[0::2], data[1::2])

        _, raw = self.c.request("samples", ch=1, first=100, last=109)
        self.assertEqual(raw, data[0::2])

        self.assertFails("need 0 <= first <= last", "view", ch=1, first=5,
                         last=MEMORY_DEPTH, columns=10)
        self.assertFails("need 0 <= first <= last", "samples", ch=1, first=9,
                         last=8)
        self.assertFails("at most", "samples", ch=1, first=0,
                         last=MEMORY_DEPTH - 1)
        self.assertFails('"columns" must be', "view", ch=1, first=0, last=9,
                         columns=0)

    def test_view_before_capture(self):
        self.assertFails("not captured yet", "view", ch=2, first=0, last=9,
                         columns=10)

    def test_capture_survives_reconnect(self):
        self.capture()
        self.c.close()
        self.c = ScopeBridgeClient(port=self.port)
        view, data = self.c.request("view", ch=1, first=0, last=999,
                                    columns=10)
        self.assertEqual(len(data), 20)

    # -- math and spectra ---------------------------------------------------

    def events_of(self, name, seconds=2.0):
        """Events called name during a live period (live must be on)."""
        found = []
        deadline = time.time() + seconds
        while time.time() < deadline:
            event, payload = self.c.next_event(timeout=5)
            if event["event"] == name:
                found.append((event, payload))
        self.c.request("live", on=False)
        self.c._events.clear()
        return found

    def test_status_math(self):
        m = self.c.request("status")[0]["math"]
        self.assertEqual((m["display"], m["operator"], m["fft_window"],
                          m["fft_unit"], m["fft_mode"]),
                         (False, "add", "rect", "db", "trace"))

    def test_set_math(self):
        self.c.request("set_math", display=True, operator="fft",
                       fft_source="ch2", fft_window="blackman", fft_unit="vrms",
                       fft_mode="memory", fft_hscale=2500, fft_hcenter=10000)
        m = self.c.request("status")[0]["math"]
        self.assertEqual((m["display"], m["operator"], m["fft_source"],
                          m["fft_window"], m["fft_unit"], m["fft_mode"]),
                         (True, "fft", "ch2", "blackman", "vrms", "memory"))
        self.assertAlmostEqual(m["fft_hscale"], 2500)
        self.assertFails('"operator" must be', "set_math", operator="pow")
        self.assertFails('"fft_window" must be', "set_math", fft_window="x")
        # a rejected request changes nothing
        self.assertFails('"fft_unit" must be', "set_math", operator="add",
                         fft_unit="x")
        self.assertEqual(self.c.request("status")[0]["math"]["operator"], "fft")

    def test_live_scope_math(self):
        self.c.request("set_channel", ch=2, display=True)
        self.c.request("set_math", display=True, operator="add",
                       source1="ch1", source2="ch2")
        self.c.request("live", on=True, interval_ms=50, scope_math=True)
        event, payload = self.events_of("math")[-1]
        self.assertEqual((event["source"], event["operator"], event["unit"]),
                         ("scope", "add", "V"))
        values = ScopeBridgeClient.floats(payload)
        self.assertEqual(len(values), event["points"])
        self.assertAlmostEqual(min(values), -1.0, delta=0.1)
        self.assertAlmostEqual(max(values), 4.0, delta=0.1)

    def test_live_scope_fft(self):
        self.c.request("set_math", display=True, operator="fft",
                       fft_source="ch1", fft_hscale=2500, fft_hcenter=10000)
        self.c.request("live", on=True, interval_ms=50, scope_math=True)
        event, payload = self.events_of("spectrum")[-1]
        self.assertEqual((event["source"], event["ch"], event["unit"]),
                         ("scope", 1, "dBV"))
        self.assertEqual(event["f0"], 0)             # screen edge -5 kHz
        self.assertAlmostEqual(event["df"], 25.0)
        values = ScopeBridgeClient.floats(payload)
        peak = max(range(5, len(values)), key=values.__getitem__)
        self.assertAlmostEqual(ScopeBridgeClient.frequencies(event)[peak], 1000,
                               delta=25)

    def test_live_server_math_and_spectrum(self):
        self.c.request("set_channel", ch=2, display=True)
        self.c.request("live", on=True, interval_ms=50, math="sub",
                       spectrum={"ch": 1, "window": "hann"})
        deadline, math, spec = time.time() + 2, None, None
        while time.time() < deadline and not (math and spec):
            event, payload = self.c.next_event(timeout=5)
            if event["event"] == "math":
                math = (event, payload)
            elif event["event"] == "spectrum":
                spec = (event, payload)
        self.c.request("live", on=False)
        self.c._events.clear()

        event, payload = math
        self.assertEqual((event["source"], event["operator"], event["points"]),
                         ("server", "sub", 1200))
        values = ScopeBridgeClient.floats(payload)
        # square and sine are in phase: 3 V - [0, 1] V, then 0 V - [-1, 0] V
        self.assertAlmostEqual(min(values), 0.0, delta=0.1)
        self.assertAlmostEqual(max(values), 3.0, delta=0.1)

        event, payload = spec
        self.assertEqual((event["source"], event["window"], event["f0"]),
                         ("server", "hann", 0))
        # 1200 samples at 10 us: a 1024-point FFT, 97.66 Hz per bin
        self.assertAlmostEqual(event["df"], 1 / (1024 * 1e-5), places=2)
        values = ScopeBridgeClient.floats(payload)
        self.assertEqual(len(values), 513)
        peak = max(range(3, len(values)), key=values.__getitem__)
        self.assertAlmostEqual(peak * event["df"], 1000, delta=event["df"])
        # fundamental of a 0..3 V square: 4/pi * 1.5 V peak = 2.6 dBV
        self.assertAlmostEqual(values[peak], 2.6, delta=1.5)

        self.assertFails('"spectrum" must be an object', "live", on=True,
                         spectrum=1)
        self.assertFails('"math" must be', "live", on=True, math="pow")

    def test_capture_spectrum(self):
        self.capture()
        info, payload = self.c.request("spectrum", ch=1, window="hann")
        # fine (default): 1.2M samples at 10 ns, averaged in pairs to 600k,
        # in one transform padded to 2^20: bins of 1 / (2^20 * 20 ns)
        self.assertEqual((info["resolution"], info["decimation"]), ("fine", 2))
        self.assertAlmostEqual(info["df"], 1 / (2**20 * 2e-8), places=3)
        # the resolution is that of the data, not of the padding: 1 / 12 ms
        self.assertAlmostEqual(info["bin_width"], 1 / 12e-3, places=1)
        self.assertEqual(info["points"], 2**19 + 1)
        self.assertEqual(len(payload), 4 * info["points"])

        # wide: 2^20-sample segments at the full rate, averaged
        wide, _ = self.c.request("spectrum", ch=1, window="hann",
                                 resolution="wide")
        self.assertEqual((wide["resolution"], wide["decimation"]), ("wide", 1))
        self.assertAlmostEqual(wide["bin_width"], 1 / (2**20 * 1e-8), places=3)
        self.assertFails('"resolution" must be', "spectrum", ch=1,
                         resolution="best")

        # zoomed: 0 .. 20 kHz in 100 columns, peak-hold per column; flat
        # top, as 1 kHz lies between bins (95.4 Hz apart) and the flat-top
        # window reads the level right there
        info, payload = self.c.request("spectrum", ch=1, window="flattop",
                                       f_min=0, f_max=20000, columns=100)
        self.assertEqual(info["points"], 100)
        values = ScopeBridgeClient.floats(payload)
        freqs = ScopeBridgeClient.frequencies(info)
        peak = max(range(2, 100), key=values.__getitem__)
        self.assertAlmostEqual(freqs[peak], 1000, delta=2 * info["df"])
        self.assertAlmostEqual(values[peak], 2.6, delta=0.2)
        # odd harmonics strong, even ones missing
        at = lambda f: values[round((f - info["f0"]) / info["df"])]
        self.assertGreater(at(3000), at(2000) + 30)

        self.assertFails('"window" must be', "spectrum", ch=1, window="x")
        self.assertFails("need f_min <= f_max", "spectrum", ch=1, f_min=10,
                         f_max=5)

    # -- other --------------------------------------------------------------

    def test_screenshot(self):
        info, image = self.c.request("screenshot")
        self.assertEqual(info["format"], "bmp")
        self.assertEqual(len(image), 1_152_054)
        self.assertEqual(image[:2], b"BM")

    def test_scpi(self):
        reply, _ = self.c.request("scpi", text="*IDN?", query=True)
        self.assertIn("SIMULATED", reply["response"])
        self.c.request("scpi", text=":STOP")
        self.assertEqual(self.c.request("status")[0]["trigger_status"], "stop")
        self.assertFails("scope: no reply", "scpi", text=":BOGUS?", query=True)


class FakeLanScope(threading.Thread):
    """A TCP stand-in for the scope's SCPI port, answering like the
    DS1202Z-E over LAN, including its quirks.  With drop_after, the first
    connection is closed after that many commands, as when the scope is
    switched off and on; stop() is the scope gone."""

    REPLIES = [("ACQUIRE:TYPE", "NORM"), ("AVER", "2"), ("MDEP", "AUTO"),
               ("COUP", "DC"), ("DISP", "1"), ("SWE", "AUTO"), ("SOUR", "CHAN1"),
               ("SLOP", "POS"), ("STAT", "TD"), ("MODE", "EDGE"), ("OPER", "ADD"),
               ("WIND", "RECT"), ("UNIT", "DB"), ("FFT:MODE", "TRAC"),
               ("IDN", "RIGOL TECHNOLOGIES,DS1202Z-E,FAKE-LAN,00.06.04")]

    def __init__(self, drop_after=None):
        super().__init__(daemon=True)
        self.drop_after = drop_after
        self.connections = 0
        self.conn = None
        self.server = socket.socket()
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.port = self.server.getsockname()[1]

    def reply(self, command):
        if "MEAS" in command:
            return "measure error!\n\n"          # two terminators
        for key, value in self.REPLIES:
            if key in command.upper():
                return value + "\n"
        return "1.000000e+00\n"

    def run(self):
        while True:
            try:
                self.conn, _ = self.server.accept()
            except OSError:
                return                      # stopped
            self.connections += 1
            self.serve(self.conn)
            self.conn.close()

    def serve(self, conn):
        count = 0
        try:
            for line in conn.makefile("rb"):
                command = line.decode().strip()
                if command.endswith("?") or "? " in command:
                    conn.sendall(self.reply(command).encode())
                count += 1
                if self.connections == 1 and self.drop_after and count >= self.drop_after:
                    return
        except OSError:
            pass

    def stop(self):
        self.server.close()
        if self.conn:
            self.conn.shutdown(socket.SHUT_RDWR)


class LanTransportTest(unittest.TestCase):
    """The server over LAN, against a fake scope."""

    def serve(self, scope):
        """scopebridge-server --lan to the fake scope, stopped at the end"""
        scope.start()
        port = free_port()
        server = subprocess.Popen(
            [SERVER, "--lan", "127.0.0.1:%d" % scope.port, "--port", str(port)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.addCleanup(server.stdout.close)
        self.addCleanup(server.wait)
        self.addCleanup(server.kill)
        self.assertIn("listening", server.stdout.readline())
        return port

    def idn(self, c):
        reply, _ = c.request("scpi", text="*IDN?", query=True)
        return reply["response"]

    def test_connection_lost_and_back(self):
        # The request the connection breaks in fails; the next connects again
        scope = FakeLanScope(drop_after=40)
        with ScopeBridgeClient(port=self.serve(scope)) as c:
            failed = 0
            for _ in range(60):
                try:
                    self.assertIn("FAKE-LAN", self.idn(c))
                except ServerError as e:
                    self.assertIn("LAN connection", str(e))
                    failed += 1
            self.assertEqual(failed, 1)
            self.assertEqual(scope.connections, 2)

    def test_scope_gone(self):
        scope = FakeLanScope()
        with ScopeBridgeClient(port=self.serve(scope)) as c:
            self.assertIn("FAKE-LAN", self.idn(c))
            scope.stop()
            with self.assertRaises(ServerError):
                self.idn(c)                 # the connection is found closed
            with self.assertRaises(ServerError) as ctx:
                self.idn(c)
            self.assertIn("does not answer", str(ctx.exception))

    def test_extra_terminator_does_not_shift_replies(self):
        scope = FakeLanScope()
        with ScopeBridgeClient(port=self.serve(scope)) as c:
            self.assertIn("FAKE-LAN", c.hello["idn"])
            m, _ = c.request("measure", ch=1)
            self.assertIsNone(m["freq"])      # "measure error!" = none
            # the second LF must not become the next reply
            for _ in range(2):
                st, _ = c.request("status")
                self.assertEqual(st["channels"][0]["coupling"], "dc")
                self.assertEqual(st["timebase"]["scale"], 1.0)


class TwoChannelCaptureTest(ServerBase):
    """Captures both channels, so on a server of its own: captures last
    between sessions, and ServerTest expects CH2 never to be captured."""

    def test_math_view(self):
        self.c.request("set_channel", ch=2, display=True)
        self.assertFails("not captured yet", "math_view", operator="add",
                         first=0, last=9, columns=10)
        self.capture(1)
        self.capture(2)
        info, payload = self.c.request("math_view", operator="add", first=0,
                                       last=MEMORY_DEPTH - 1, columns=500)
        self.assertEqual((info["columns"], info["unit"]), (500, "V"))
        pairs = ScopeBridgeClient.floats(payload)
        lows, highs = pairs[0::2], pairs[1::2]
        self.assertAlmostEqual(min(lows), -1.0, delta=0.1)
        self.assertAlmostEqual(max(highs), 4.0, delta=0.1)
        info, _ = self.c.request("math_view", operator="mul", first=0,
                                 last=9, columns=500)
        self.assertEqual((info["columns"], info["unit"]), (10, "V^2"))



class MultiClientTest(ServerBase):
    """Several clients at once, and the command log."""

    log_path = os.path.join(tempfile.mkdtemp(), "session.jsonl")
    extra_args = ["--log", log_path]

    def frames_within(self, client, seconds):
        count, deadline = 0, time.time() + seconds
        try:
            while time.time() < deadline:
                event, _ = client.next_event(timeout=max(0.01, deadline - time.time()))
                count += event["event"] == "frame"
        except socket.timeout:
            pass
        return count

    def test_two_clients(self):
        b = ScopeBridgeClient(port=self.port)
        try:
            self.assertNotEqual(self.c.hello["client"], b.hello["client"])
            self.c.request("live", on=True, interval_ms=50)
            # B is served in between A's live updates, and gets no frames
            for _ in range(5):
                b.request("status")
            self.assertEqual(self.frames_within(b, 0.3), 0)
            self.assertGreater(self.frames_within(self.c, 0.5), 2)

            # B's capture does not stop A's live view
            b.request("capture", ch=1)
            self.c._events.clear()
            self.assertGreater(self.frames_within(self.c, 0.5), 2)
            self.c.request("live", on=False)
        finally:
            b.close()
        # A carries on when B is gone
        self.c.request("status")

    def test_slow_client_does_not_hold_up_others(self):
        slow = ScopeBridgeClient(port=self.port)
        try:
            slow.request("live", on=True, interval_ms=50)
            time.sleep(2)                  # slow reads nothing meanwhile
            worst = 0
            for _ in range(5):
                t0 = time.time()
                self.c.request("status")
                worst = max(worst, time.time() - t0)
            self.assertLess(worst, 1.0)
            # its queue was capped, not grown without end: it has kept
            # at most the queued events plus what the socket buffers hold
            self.assertGreater(self.frames_within(slow, 0.5), 0)
        finally:
            slow.close()

    def test_log(self):
        b = ScopeBridgeClient(port=self.port)
        b.request("set_channel", ch=1, scale=0.5)
        b.request("screenshot")
        try:
            b.request("fly")
        except ServerError:
            pass
        b_id = b.hello["client"]
        b.close()
        time.sleep(0.3)
        with open(self.log_path) as f:
            lines = [json.loads(line) for line in f]
        mine = [l for l in lines if l["client"] == b_id]
        self.assertIn("connect", mine[0])
        self.assertTrue(mine[-1].get("disconnect"))
        requests = [l["request"] for l in mine if "request" in l]
        replies = [l["reply"] for l in mine if "reply" in l]
        self.assertEqual([r["cmd"] for r in requests],
                         ["set_channel", "screenshot", "fly"])
        self.assertEqual(requests[0]["scale"], 0.5)
        self.assertEqual(replies[1]["bytes"], 1_152_054)   # size, no payload
        self.assertFalse(replies[2]["ok"])
        self.assertTrue(all("t" in l for l in mine))

class DecodeTest(ServerBase):
    """Bus decoding of captures, on the simulator's serial signals."""

    def signal(self, name):
        self.c.request("scpi", text=":SIMulator:SIGNal " + name)
        self.c.request("set_channel", ch=2, display=True)
        self.capture(1)
        self.capture(2)

    def test_uart(self):
        self.signal("UART")
        reply, _ = self.c.request("decode", protocol="uart", tx=1, rx=2, baud=115200)
        items = reply["items"]
        self.assertEqual(reply["count"], len(items))
        self.assertFalse(reply["truncated"])
        self.assertAlmostEqual(reply["samples_per_bit"], 868.06, places=1)
        self.assertAlmostEqual(reply["thresholds"]["ch1"], 1.65, delta=0.1)
        tx = "".join(chr(i["value"]) for i in items if i["ch"] == 1)
        rx = "".join(chr(i["value"]) for i in items if i["ch"] == 2)
        self.assertIn("Hello, Rigol!\r\nHello, Rigol!\r\n", tx)
        self.assertIn("OK\r\nOK\r\n", rx)
        self.assertTrue(all("error" not in i for i in items))
        # in time order, with times matching the sample numbers
        firsts = [i["first"] for i in items]
        self.assertEqual(firsts, sorted(firsts))
        info, _ = self.c.request("capture", ch=1)
        self.c._events.clear()
        i = items[0]
        self.assertAlmostEqual(i["t"], info["x_origin"] + i["first"] * info["x_inc"],
                               delta=1e-9)
        self.assertEqual(i["type"], "data")

    def test_uart_wrong_baud_and_range(self):
        self.signal("UART")
        # at twice the baud rate every frame breaks
        reply, _ = self.c.request("decode", protocol="uart", tx=1, baud=230400)
        self.assertTrue(any("error" in i for i in reply["items"]))
        # a range: only its items, numbered in the whole capture
        reply, _ = self.c.request("decode", protocol="uart", tx=1, baud=115200,
                                  first=400_000, last=800_000)
        self.assertTrue(all(400_000 <= i["first"] <= 800_000 for i in reply["items"]))
        self.assertGreater(reply["count"], 10)
        reply, _ = self.c.request("decode", protocol="uart", tx=1, baud=115200,
                                  max_items=5)
        self.assertEqual(reply["count"], 5)
        self.assertTrue(reply["truncated"])
        self.assertFails("samples per bit", "decode", protocol="uart", tx=1,
                         baud=50_000_000)

    def test_i2c(self):
        self.signal("IIC")
        reply, _ = self.c.request("decode", protocol="i2c", scl=1, sda=2)
        items = reply["items"]
        start = next(k for k, i in enumerate(items) if i["type"] == "start")
        first = items[start:start + 10]
        first = items[start:start + 13]
        self.assertEqual([i["type"] for i in first],
                         ["start", "address", "data", "data", "stop",
                          "start", "address", "data", "start", "address", "data", "data", "stop"])
        self.assertEqual(first[1]["value"], 0x50)
        self.assertFalse(first[1]["read"])
        self.assertFalse(first[6]["read"])
        self.assertTrue(first[9]["read"])
        self.assertEqual([first[k]["value"] for k in (2, 3, 7, 10, 11)],
                         [0x00, 0x10, 0x00, 0xA5, 0x3C])
        self.assertTrue(first[10]["ack"])
        self.assertFalse(first[11]["ack"])

    def test_spi(self):
        self.signal("SPI")
        reply, _ = self.c.request("decode", protocol="spi", clk=1, data=2)
        values = [i["value"] for i in reply["items"]]
        self.assertEqual(values[:8], [0x9F, 0xEF, 0x40, 0x18] * 2)
        self.assertAlmostEqual(reply["timeout"], 1.5e-6, delta=1e-7)
        reply, _ = self.c.request("decode", protocol="spi", clk=1, data=2, width=32)
        self.assertEqual(reply["items"][0]["value"], 0x9FEF4018)
        reply, _ = self.c.request("decode", protocol="spi", clk=1, data=2,
                                  timeout=50e-6)
        self.assertEqual(reply["items"][0]["value"], 0x9F)

    def test_errors(self):
        self.assertFails("protocol", "decode", protocol="can")
        self.assertFails("must differ", "decode", protocol="i2c", scl=1, sda=1)
        self.assertFails("bits", "decode", protocol="uart", tx=1, bits=12)
        self.assertFails("width", "decode", protocol="spi", width=64)
        self.c.request("scpi", text=":SIMulator:SIGNal UART")
        self.c.request("set_channel", ch=2, display=True)
        self.capture(1)
        self.c.request("set_timebase", scale=2e-3)
        self.capture(2)
        self.assertFails("differ", "decode", protocol="uart", tx=1, rx=2, baud=115200)

    def test_flat_line(self):
        self.c.request("scpi", text=":SIMulator:SIGNal SPI")
        self.c.request("set_channel", ch=1, offset=100)   # the trace clips flat
        self.capture(1)
        self.c.request("set_channel", ch=1, offset=0)
        self.capture(2)
        self.assertFails("no logic signal", "decode", protocol="spi", clk=1, data=2)

    def test_set_decoder(self):
        self.c.request("set_decoder", bus=2, protocol="spi", clk=1, data=2,
                       width=16, format="ascii")
        self.c.request("set_decoder", protocol="uart", tx=1, baud=9600,
                       display=False)
        self.assertFails("5 .. 8", "set_decoder", protocol="uart", tx=1, bits=9)
        self.assertFails("format", "set_decoder", protocol="i2c", format="morse")
        self.assertFails("bus", "set_decoder", protocol="i2c", bus=3)


class TimingTest(ServerBase):
    """Code timing on the simulator's marker pins: CH1 marks a block every
    1 ms (200 us + 2 us * (k mod 5), and 150 us more when k mod 7 = 3),
    CH2 a burst of 8 pulses (12 in slow runs) 20..30 us into each block."""

    def setUp(self):
        super().setUp()
        self.c.request("scpi", text=":SIMulator:SIGNal TIMing")
        self.c.request("set_channel", ch=2, display=True)
        self.capture(1)
        self.capture(2)

    def test_blocks_period_latency(self):
        r, _ = self.c.request("timing", ch=1, to=2)
        self.assertEqual(r["ch"], 1)
        self.assertEqual(r["polarity"], "high")
        self.assertAlmostEqual(r["resolution"], 10e-9, delta=1e-12)
        self.assertAlmostEqual(r["span"], 12e-3, delta=1e-6)
        block = r["block"]
        self.assertEqual(block["count"], 12)
        self.assertAlmostEqual(block["min"], 200e-6, delta=20e-9)
        self.assertAlmostEqual(block["max"], 356e-6, delta=20e-9)
        self.assertLess(block["median"], 210e-6)
        # the slow run is the longest, and its time matches its samples
        info, _ = self.c.request("capture", ch=1)
        self.c._events.clear()
        longest = block["longest"]
        self.assertAlmostEqual(longest["t"], info["x_origin"] + longest["first"] * info["x_inc"],
                               delta=1e-9)
        self.assertAlmostEqual((longest["last"] - longest["first"] + 1) * info["x_inc"],
                               block["max"], delta=20e-9)
        counts = block["histogram"]["counts"]
        self.assertEqual(len(counts), 40)
        self.assertEqual(sum(counts), 12)
        self.assertEqual(counts[-1], 1)
        period = r["period"]
        self.assertEqual(period["count"], 11)
        self.assertAlmostEqual(period["mean"], 1e-3, delta=20e-9)
        self.assertAlmostEqual(r["duty"], block["mean"] / period["mean"], places=6)
        self.assertEqual(r["idle"]["count"], 11)
        latency = r["latency"]
        self.assertEqual(r["to"], 2)
        self.assertEqual(latency["count"], 12)
        self.assertAlmostEqual(latency["min"], 20e-6, delta=20e-9)
        self.assertAlmostEqual(latency["max"], 30e-6, delta=20e-9)
        self.assertAlmostEqual(r["thresholds"]["ch1"], 1.65, delta=0.1)
        self.assertIn("ch2", r["thresholds"])

    def test_bursts(self):
        r, _ = self.c.request("timing", ch=2, burst_gap=100e-6, bins=5)
        self.assertAlmostEqual(r["block"]["min"], 10e-6, delta=20e-9)
        self.assertAlmostEqual(r["block"]["max"], 10e-6, delta=20e-9)
        burst = r["burst"]
        self.assertEqual(burst["count"], 12)
        self.assertAlmostEqual(burst["min"], 115e-6, delta=20e-9)   # 8 pulses
        self.assertAlmostEqual(burst["max"], 175e-6, delta=20e-9)   # 12
        pulses = r["burst_pulses"]
        self.assertEqual((pulses["min"], pulses["max"]), (8, 12))
        self.assertEqual(pulses["histogram"]["counts"], [10, 0, 0, 0, 2])
        self.assertNotIn("latency", r)

    def test_range_polarity_threshold(self):
        whole, _ = self.c.request("timing", ch=1)
        half, _ = self.c.request("timing", ch=1, first=0, last=599_999)
        self.assertEqual(half["block"]["count"], 6)
        self.assertAlmostEqual(half["span"], 6e-3, delta=1e-6)
        low, _ = self.c.request("timing", ch=1, polarity="low")
        self.assertEqual(low["block"]["count"], whole["idle"]["count"])
        self.assertAlmostEqual(low["block"]["max"], whole["idle"]["max"], delta=1e-12)
        given, _ = self.c.request("timing", ch=1, threshold=1.0)
        self.assertAlmostEqual(given["thresholds"]["ch1"], 1.0, delta=0.05)
        self.assertEqual(given["block"]["count"], 12)
        # above the signal there are no blocks, and the stats say so
        none, _ = self.c.request("timing", ch=1, threshold=10.0)
        self.assertEqual(none["block"]["count"], 0)
        self.assertNotIn("min", none["block"])

    def test_errors(self):
        self.assertFails("polarity", "timing", ch=1, polarity="up")
        self.assertFails("bins", "timing", ch=1, bins=0)
        self.assertFails("burst_gap", "timing", ch=1, burst_gap=0)
        self.assertFails("other channel", "timing", ch=1, to=1)
        self.c.request("set_timebase", scale=2e-3)
        self.capture(2)
        self.assertFails("differ", "timing", ch=1, to=2)


class MaskTest(ServerBase):

    def test_pass_fail(self):
        self.c.request("set_mask", enable=True, source="ch1", x=0.2, y=0.48,
                       create=True, reset=True, run=True)
        m, _ = self.c.request("mask")
        self.assertTrue(m["enable"] and m["running"])
        self.assertEqual((m["x"], m["y"]), (0.2, 0.48))
        for _ in range(5):
            self.c.request("screen", ch=1)
        self.c.request("set_channel", ch=1, offset=-1.0)
        for _ in range(3):
            self.c.request("screen", ch=1)
        m, _ = self.c.request("mask")
        self.assertEqual((m["passed"], m["failed"], m["total"]), (5, 3, 8))
        st, _ = self.c.request("status")
        self.assertEqual(st["mask"]["failed"], 3)
        self.c.request("set_mask", reset=True, stop_on_fail=True)
        self.c.request("screen", ch=1)
        st, _ = self.c.request("status")
        self.assertEqual(st["trigger_status"], "stop")
        self.c.request("set_mask", enable=False)
        st, _ = self.c.request("status")
        self.assertEqual(st["mask"], {"enable": False})

    def test_errors(self):
        self.assertFails("0.02 .. 4", "set_mask", x=5)
        self.assertFails("0.04 .. 5.12", "set_mask", y=0)
        self.assertFails("bool", "set_mask", run="yes")
        self.assertFails("source", "set_mask", source="ch3")

    def test_timebase_mode(self):
        self.c.request("set_timebase", mode="roll")
        st, _ = self.c.request("status")
        self.assertEqual(st["timebase"]["mode"], "roll")
        self.c.request("set_timebase", mode="yt")
        self.assertFails("mode", "set_timebase", mode="zt")


class ReferenceTest(ServerBase):

    def test_save_read_clear(self):
        other = ScopeBridgeClient(port=self.port)
        try:
            self.c.request("ref_clear")
            reply, _ = self.c.request("ref_save", slot=2, ch=1)
            self.assertEqual((reply["slot"], reply["ch"], reply["points"]), (2, 1, 1200))
            self.assertTrue(reply["label"].startswith("CH1 "))
            # every client hears of the change, live or not
            event, _ = other.next_event(timeout=2)
            self.assertEqual(event["event"], "refs")
            info, raw = self.c.request("ref", slot=2)
            screen, screen_raw = self.c.request("screen", ch=1)
            self.assertEqual(len(raw), 1200)
            self.assertEqual(info["x_inc"], screen["x_inc"])
            refs, _ = self.c.request("refs")
            self.assertEqual([r["slot"] for r in refs["refs"]], [2])
            self.c.request("ref_clear", slot=2)
            self.assertFails("empty", "ref", slot=2)
            self.assertFails("slot", "ref_save", slot=5, ch=1)
        finally:
            other.close()

    def test_load(self):
        import base64
        data = bytes(range(50, 150))
        self.c.request("ref_load", slot=1, data=base64.b64encode(data).decode(),
                       x_inc=1e-6, x_origin=-5e-5, y_inc=0.01, y_origin=0,
                       y_ref=127, label="mine", ch=2)
        info, raw = self.c.request("ref", slot=1)
        self.assertEqual(raw, data)
        self.assertEqual((info["label"], info["ch"], info["points"]), ("mine", 2, 100))
        self.assertFails("samples", "ref_load", slot=1, data="QQ==", x_inc=1,
                         x_origin=0, y_inc=1, y_origin=0, y_ref=127)
        self.assertFails("positive", "ref_load", slot=1,
                         data=base64.b64encode(data).decode(), x_inc=0,
                         x_origin=0, y_inc=1, y_origin=0, y_ref=127)


if __name__ == "__main__":
    unittest.main(verbosity=2)
