# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""The web interface in a real browser: headless Firefox, driven through
Marionette, changes the page's controls as a user would, and the scope's
settings are checked through a separate client.  Skipped if Firefox is
not installed.

    python3 tests/test_web_browser.py            (make check-web)
"""

import glob
import os
import shutil
import tempfile
import subprocess
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#  Never the user's own ~/.scopebridgerc: its [client] host could send
#  the tests to a real scope elsewhere
os.environ["SCOPEBRIDGE_RC"] = ""

sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))

from scopebridge import Scope  # noqa: E402
from test_server import SERVER, free_port  # noqa: E402

# A user's actions: set a control and fire its change event, or click
SET = """const el = document.querySelector(arguments[0]);
el.value = arguments[1]; el.dispatchEvent(new Event('change'));"""
CLICK = "document.querySelector(arguments[0]).click();"
TEXT = "return document.querySelector(arguments[0]).textContent;"


@unittest.skipUnless(shutil.which("firefox"), "Firefox is not installed")
class BrowserTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        from marionette import Firefox
        cls.port = free_port()
        cls.web = free_port()
        cls.start_server()
        cls.downloads = tempfile.mkdtemp()
        cls.ff = Firefox(1280, 800, port=free_port(), downloads=cls.downloads)
        cls.ff.go("http://127.0.0.1:%d/" % cls.web)
        time.sleep(2)

    @classmethod
    def start_server(cls):
        cls.server = subprocess.Popen(
            [SERVER, "--sim", "--port", str(cls.port), "--web", str(cls.web)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)

    @classmethod
    def tearDownClass(cls):
        cls.ff.close()
        cls.server.kill()
        cls.server.wait()
        shutil.rmtree(cls.downloads, ignore_errors=True)

    def setUp(self):
        # Each test starts from a reset scope, and the page in live view
        # once it has read the settings back
        self.scope = Scope(port=self.port)
        self.scope.scpi("*RST")
        if self.ff.js("return window.scopebridge.scope.mode") == "capture":
            self.ff.js(CLICK, "#live")
        time.sleep(1.8)

    def tearDown(self):
        self.scope.close()

    def act(self, script, *args, wait=0.6):
        self.ff.js(script, *args)
        time.sleep(wait)

    def test_01_shows_the_scope(self):
        self.assertEqual(self.ff.js("return document.title"), "ScopeBridge - Rigol DS1202Z-E")
        self.assertEqual(self.ff.js(TEXT, "#title"), "Rigol DS1202Z-E")
        self.assertEqual(self.ff.js(TEXT, "#connection"), "sim")
        self.assertIn("Frequency", self.ff.js(TEXT, "#readout"))

    def test_02_channels_and_timebase(self):
        self.act(CLICK, '.channel[data-ch="2"] .ch-on')
        self.act(SET, '.channel[data-ch="1"] .ch-scale', "0.5")
        self.act(SET, '.channel[data-ch="1"] .ch-position', "-3")
        self.act(SET, "#tb-scale", "0.0005")
        self.act(SET, "#tb-position", "1")
        st = self.scope.status()
        self.assertTrue(st["channels"][1]["display"])
        self.assertEqual(st["channels"][0]["scale"], 0.5)
        self.assertAlmostEqual(st["channels"][0]["offset"], -1.5)
        self.assertEqual(st["timebase"]["scale"], 0.0005)
        self.assertAlmostEqual(st["timebase"]["offset"], 0.0005)

    def test_03_trigger(self):
        self.act(SET, "#trig-level", "1.2")
        self.act(SET, "#trig-slope", "falling")
        self.act(SET, "#trig-sweep", "normal")
        t = self.scope.status()["trigger"]
        self.assertEqual((t["slope"], t["level"], t["sweep"]), ("falling", 1.2, "normal"))
        self.act(SET, "#trig-mode", "pulse", wait=2.2)   # and a status poll
        self.assertEqual(self.scope.status()["trigger"]["mode"], "pulse")
        self.assertTrue(self.ff.js("return !document.getElementById('trig-pulse').hidden"))
        self.assertTrue(self.ff.js("return document.getElementById('trig-edge').hidden"))
        self.act(SET, "#pulse-when", "neg_less")
        self.act(SET, "#pulse-width", "0.0002")
        self.act(SET, "#pulse-level", "0.8")
        p = self.scope.status()["trigger"]["pulse"]
        self.assertEqual((p["when"], p["level"]), ("neg_less", 0.8))
        self.assertAlmostEqual(p["width"], 2e-4)
        self.act(SET, "#trig-mode", "slope", wait=2.2)
        self.act(SET, "#slope-window", "both")
        self.assertEqual(self.scope.status()["trigger"]["slope_trigger"]["window"], "both")
        self.act(SET, "#trig-mode", "edge")

    def test_04_acquisition(self):
        self.scope.channel(2, display=True)
        time.sleep(2)   # a status poll: two channels on, two-channel depths
        depths = self.ff.js(
            "return [...document.querySelectorAll('#acq-depth option')].map(o => o.value)")
        self.assertEqual(depths, ["0", "6000", "60000", "600000", "6000000", "12000000"])
        self.act(SET, "#acq-type", "average")
        self.act(SET, "#acq-averages", "16")
        self.act(SET, "#acq-depth", "60000")
        a = self.scope.status()["acquire"]
        self.assertEqual((a["type"], a["averages"], a["memory_depth"]), ("average", 16, 60000))
        self.act(CLICK, 'button[data-cmd="stop"]')
        self.assertEqual(self.scope.status()["trigger_status"], "stop")
        self.act(SET, "#acq-depth", "600000", wait=1)
        self.assertIn("only while running", self.ff.js(TEXT, "#status"))
        self.act(CLICK, 'button[data-cmd="run"]')
        self.assertEqual(self.scope.status()["trigger_status"], "td")

    def test_05_measurements(self):
        self.act(SET, "#meas-slots .row:nth-child(1) .meas-item", "vmax", wait=1)
        self.assertIn("Vmax", self.ff.js(TEXT, "#readout"))
        self.act(SET, "#meas-ch", "0", wait=1)
        self.assertEqual(self.ff.js(TEXT, "#readout"), "")
        self.act(SET, "#meas-ch", "1")

    # -- stage 2: captures, FFT, math, cursors, files ------------------------

    def js(self, script):
        return self.ff.js("const r = window.scopebridge; " + script)

    def capture(self, wait=4):
        self.act(CLICK, "#capture", wait=wait)
        self.assertEqual(self.js("return r.scope.mode"), "capture")

    def test_07_capture_zoom_and_pan(self):
        self.scope.channel(2, display=False)
        self.capture()
        self.assertEqual(self.js("return r.scope.cap.total"), 1200000)
        self.assertGreater(self.js("return r.scope.cap.chans[1].count"), 500)
        self.assertIn("CAPTURE", "".join(self.ff.js("return document.title")) + "CAPTURE")
        # the wheel zooms around the pointer, a double-click shows all
        self.act("""const c = document.getElementById('scope'), b = c.getBoundingClientRect();
                    for (let i = 0; i < 5; i++)
                      c.dispatchEvent(new WheelEvent('wheel', {deltaY: -100, clientX: b.left + b.width / 2,
                                                                clientY: b.top + 100, bubbles: true}));""")
        span = self.js("return r.scope.cap.last - r.scope.cap.first + 1")
        self.assertLess(span, 1200000 * 0.4)
        self.assertEqual(self.js("return r.scope.cap.chans[1].colLast - r.scope.cap.chans[1].colFirst + 1"),
                         span)
        self.act("document.getElementById('scope').dispatchEvent(new MouseEvent('dblclick', {bubbles: true}))")
        self.assertEqual(self.js("return r.scope.cap.last - r.scope.cap.first + 1"), 1200000)
        self.act(CLICK, "#live", wait=1)
        self.assertEqual(self.js("return r.scope.mode"), "live")

    def test_08_fft_and_math(self):
        self.act(SET, "#fft-mode", "pc", wait=1.5)
        self.assertFalse(self.ff.js("return document.getElementById('spectrum').hidden"))
        self.assertIn("(PC, hann)", self.js("return r.spectrum.data.label"))
        self.assertGreater(self.js("return r.spectrum.data.values.length"), 100)
        self.act(SET, "#fft-mode", "scope", wait=3.5)   # the scope's math settles
        self.assertIn("(scope,", self.js("return r.spectrum.data ? r.spectrum.data.label : ''"))
        self.act(SET, "#fft-mode", "pc", wait=1)
        self.capture()
        self.assertIn("capture (PC", self.js("return r.spectrum.data.label"))
        self.assertAlmostEqual(self.js("return r.spectrum.data.rbw"), 1 / 12e-3, delta=1)
        self.act(CLICK, "#live", wait=1)
        self.act(SET, "#fft-mode", "off")
        self.assertTrue(self.ff.js("return document.getElementById('spectrum').hidden"))
        # PC math: A+B of the two channels
        self.scope.channel(2, display=True)
        self.act(SET, "#math-mode", "pc", wait=1.5)
        self.assertEqual(self.js("return r.scope.math.live.values.length"), 1200)
        self.act(SET, "#math-mode", "off")

    def test_09_cursors(self):
        self.act(CLICK, "#cursors", wait=0.5)
        lines = self.js("return r.scope.cursorLines().map(l => l.text)")
        self.assertTrue(lines[0].startswith("A "))
        self.assertIn("ΔT 4.00 ms", lines[1])
        self.assertTrue(any(l.startswith("CH1  A ") and "..." not in l for l in lines))
        self.act(CLICK, "#cursors")

    def test_10_files(self):
        self.scope.channel(2, display=False)
        self.act(CLICK, "#screenshot", wait=1.5)
        self.act(CLICK, "#setup-save", wait=1)
        self.act(CLICK, "#export", wait=1)
        names = sorted(os.path.basename(f)[:6] for f in glob.glob(self.downloads + "/*"))
        self.assertEqual(names, ["scope-", "screen", "screen"])
        csv = [f for f in glob.glob(self.downloads + "/*.csv")][0]
        with open(csv) as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0], "time_s,ch1_V")
        self.assertEqual(len(lines), 1201)

    # -- stage 3: decoding, references, pass/fail -----------------------------

    def test_11_decode(self):
        self.scope.scpi(":SIMulator:SIGNal UART")
        self.scope.channel(2, display=True)
        self.capture(wait=5)
        self.act(SET, "#dec-protocol", "uart")
        self.act(SET, "#dec-baud", "115200")
        self.act(SET, "#dec-rx", "2")
        self.act(SET, "#dec-format", "ascii")
        self.act(CLICK, "#dec-run", wait=1.5)
        self.assertFalse(self.ff.js("return document.getElementById('decoded').hidden"))
        rows = self.ff.js("return [...document.querySelectorAll('#decoded-rows tr')]"
                          ".slice(0, 5).map(r => r.cells[3].textContent)")
        self.assertEqual(rows, ["H", "e", "l", "l", "o"])
        self.assertIn("114 items, UART", self.ff.js(TEXT, "#decoded-summary"))
        # choosing an item shows it, twelve times its length across
        self.act("document.querySelector('#decoded-rows tr:nth-child(3)').click()")
        row = self.ff.js("const r = document.querySelector('#decoded-rows tr:nth-child(3)');"
                         "return [Number(r.dataset.first), Number(r.dataset.last)]")
        view = self.js("return [r.scope.cap.first, r.scope.cap.last]")
        self.assertLessEqual(view[0], row[0])
        self.assertGreaterEqual(view[1], row[1])
        self.assertAlmostEqual((view[1] - view[0]) / (row[1] - row[0] + 1), 12, delta=0.1)
        self.assertGreater(self.js("return r.scope.decoded.length"), 100)
        self.act(CLICK, "#dec-clear")
        self.assertTrue(self.ff.js("return document.getElementById('decoded').hidden"))
        self.scope.scpi(":SIMulator:SIGNal NORMal")
        self.act(CLICK, "#live", wait=1)

    def test_12_references(self):
        self.act(SET, "#ref-slot", "2")
        self.act(CLICK, "#ref-save", wait=1.5)
        self.assertIn("R2  CH1", self.ff.js(TEXT, "#ref-list"))
        self.assertEqual(self.js("return r.scope.refs[2].raw.length"), 1200)
        self.assertEqual([r["slot"] for r in self.scope.refs()], [2])
        # another client's reference shows up here too
        self.scope.ref_save(3, 1, label="theirs")
        time.sleep(1.5)
        self.assertIn("R3  theirs", self.ff.js(TEXT, "#ref-list"))
        self.act(CLICK, "#ref-clear", wait=1)
        self.scope.ref_clear()

    def test_13_pass_fail(self):
        self.act("document.querySelector('button[data-mask=\"create\"]').click()")
        self.act("document.querySelector('button[data-mask=\"start\"]').click()", wait=2.5)
        self.assertTrue(self.ff.js(TEXT, "#mask-counts").startswith("Running: passed"))
        self.act("document.querySelector('button[data-mask=\"off\"]').click()", wait=2)
        self.assertEqual(self.ff.js(TEXT, "#mask-counts"), "Test off")

    def test_14_timing(self):
        self.scope.scpi(":SIMulator:SIGNal TIMing")
        self.scope.channel(2, display=True)
        self.capture(wait=5)
        self.act(SET, "#tim-to", "1")
        self.act(SET, "#tim-gap", "off")
        self.act(CLICK, "#tim-run", wait=1.5)
        self.assertFalse(self.ff.js("return document.getElementById('timing').hidden"))
        table = self.ff.js(TEXT, "#timing-table")
        self.assertRegex(table, r"block +12 +200 µs +229 µs +356 µs")
        self.assertRegex(table, r"latency to CH2 +12 +20.0 µs")
        # the longest block, twice its length across
        self.act(CLICK, "#tim-longest")
        longest = self.js("return r.timing.result.block.longest")
        view = self.js("return [r.scope.cap.first, r.scope.cap.last]")
        self.assertLessEqual(view[0], longest["first"])
        self.assertGreaterEqual(view[1], longest["last"])
        self.assertAlmostEqual((view[1] - view[0]) / (longest["last"] - longest["first"] + 1),
                               2, delta=0.05)
        # bursts of pulses on CH2
        self.act(SET, "#tim-ch", "2")
        self.act(SET, "#tim-to", "0")
        self.act(SET, "#tim-gap", "100u")
        self.act(CLICK, "#tim-run", wait=1.5)
        self.assertRegex(self.ff.js(TEXT, "#timing-table"), r"pulses/burst +12 +8.00 +8.67 +12.00")
        self.act(SET, "#tim-which", "burst")
        self.assertEqual(self.js("return r.timing.chosen().count"), 12)
        self.act(SET, "#tim-gap", "soon")
        self.act(CLICK, "#tim-run")
        self.assertIn("burst gap", self.ff.js(TEXT, "#status"))
        self.act(CLICK, "#tim-clear")
        self.assertTrue(self.ff.js("return document.getElementById('timing').hidden"))
        self.scope.scpi(":SIMulator:SIGNal NORMal")
        self.act(CLICK, "#live", wait=1)

    def test_99_reconnects(self):
        type(self).server.kill()
        type(self).server.wait()
        time.sleep(1)
        self.assertIn("retrying", self.ff.js(TEXT, "#connection"))
        type(self).start_server()
        time.sleep(3)
        self.assertEqual(self.ff.js(TEXT, "#connection"), "sim")


if __name__ == "__main__":
    unittest.main(verbosity=2)
