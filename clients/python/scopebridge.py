# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Scripting the Rigol DS1000Z-E through scopebridge-server.

    from scopebridge import Scope

    with Scope() as scope:                       # the server on 127.0.0.1:5026
        scope.channel(1, scale=0.5, coupling="dc")
        scope.timebase(scale=1e-3)
        print(scope.measure(1, "freq", "vpp"))
        scope.single()
        scope.wait_for_trigger()
        cap = scope.capture(1)                   # the whole acquisition memory
        cap.save_csv("capture.csv")
        print(cap.spectrum().peak())

The server must be running (scopebridge.sh, or scopebridge_run.py which can start one).
Scope() connects to RIGOL_HOST / RIGOL_PORT from the environment if set
(scopebridge_run.py sets them), else 127.0.0.1:5026.  Several scripts, and the
GUI, can be connected to the same server at once.

Sample data comes as numpy arrays when numpy is installed, else as lists.
The protocol underneath is described in docs/PROTOCOL.md; Scope.request()
sends any request directly.
"""

import base64
import csv
import os
import time

from scopebridge_client import ServerError, ScopeBridgeClient

try:
    import numpy
except ImportError:          # everything works without it, with lists
    numpy = None

__all__ = ["Scope", "Waveform", "Capture", "Spectrum", "ServerError"]

MEASUREMENTS = ("freq", "period", "vpp", "vmax", "vmin", "vtop", "vbase",
                "vamp", "vavg", "vrms", "rise", "fall", "pwidth", "nwidth",
                "pduty", "nduty")


def _array(values):
    return numpy.asarray(values, dtype=float) if numpy is not None else list(values)


def _volts(info, raw):
    scale = info["y_inc"]
    zero = info["y_ref"] + info["y_origin"]
    if numpy is not None:
        return (numpy.frombuffer(raw, dtype=numpy.uint8) - zero) * scale
    return [(r - zero) * scale for r in raw]


def _times(info, first, count):
    if numpy is not None:
        return info["x_origin"] + (first + numpy.arange(count)) * info["x_inc"]
    return [info["x_origin"] + (first + i) * info["x_inc"] for i in range(count)]


def _write_csv(path, header, columns):
    with open(path, "w", newline="") as f:
        out = csv.writer(f)
        out.writerow(header)
        for row in zip(*columns):
            out.writerow(["%.9g" % v for v in row])


class Waveform:
    """A channel's screen waveform (Scope.screen)."""

    def __init__(self, info, raw):
        self.info = info
        self.channel = info["ch"]
        self.points = info["points"]
        self.x_increment = info["x_inc"]
        self.raw = raw

    def times(self):
        return _times(self.info, 0, self.points)

    def volts(self):
        return _volts(self.info, self.raw)

    def save_csv(self, path):
        _write_csv(path, ["time_s", "ch%d_V" % self.channel],
                   [self.times(), self.volts()])


class Spectrum:
    """An amplitude spectrum: level per frequency (dBV or Vrms)."""

    def __init__(self, info, payload):
        self.info = info
        self.unit = info["unit"]
        self.window = info["window"]
        self.bin_width = info["bin_width"]
        self.f0 = info["f0"]
        self.df = info["df"]
        self.values = _array(ScopeBridgeClient.floats(payload))

    def __len__(self):
        return len(self.values)

    def frequencies(self):
        return _array(self.f0 + i * self.df for i in range(len(self.values)))

    def level_at(self, frequency):
        """The level of the point nearest to frequency."""
        i = round((frequency - self.f0) / self.df)
        return self.values[max(0, min(len(self.values) - 1, i))]

    # Bins around DC that a window's main lobe spreads the DC level over
    DC_LOBE_BINS = {"rect": 1, "hann": 2, "hamming": 2, "blackman": 3,
                    "flattop": 5, "triangle": 2}

    def dc_limit(self):
        """Up to here the window spreads the DC level over the spectrum."""
        return max((self.DC_LOBE_BINS.get(self.window, 5) + 0.5) * self.bin_width,
                   1.5 * self.df)

    def peak(self, f_min=None, f_max=None):
        """(frequency, level) of the strongest line from f_min to f_max, or
        None if there is none.  Without f_min, DC and the window's spread
        of it are left out."""
        f_min = self.dc_limit() if f_min is None else f_min
        best = None
        for i, level in enumerate(self.values):
            f = self.f0 + i * self.df
            if f < f_min or (f_max is not None and f > f_max):
                continue
            if best is None or level > best[1]:
                best = (f, float(level))
        return best

    def save_csv(self, path):
        _write_csv(path, ["frequency_Hz", "level_" + self.unit],
                   [self.frequencies(), self.values])


class Capture:
    """A channel's acquisition memory, held by the server (Scope.capture).

    Samples are fetched from the server when first asked for."""

    def __init__(self, scope, info):
        self._scope = scope
        self.info = info
        self.channel = info["ch"]
        self.points = info["points"]
        self.x_increment = info["x_inc"]
        self.sample_rate = 1.0 / info["x_inc"]
        self.duration = self.points * info["x_inc"]

    def raw(self, first=0, last=None):
        """The raw 8-bit samples first .. last (0-based, inclusive)."""
        last = self.points - 1 if last is None else last
        chunks = []
        while first <= last:
            end = min(last, first + 999_999)
            _, payload = self._scope.request("samples", ch=self.channel,
                                             first=first, last=end)
            chunks.append(payload)
            first = end + 1
        return b"".join(chunks)

    def volts(self, first=0, last=None):
        return _volts(self.info, self.raw(first, last))

    def times(self, first=0, last=None):
        last = self.points - 1 if last is None else last
        return _times(self.info, first, last - first + 1)

    def spectrum(self, window="hann", first=None, last=None,
                 f_min=None, f_max=None, columns=None):
        """The server's spectrum of the capture (or samples first .. last)."""
        members = {"ch": self.channel, "window": window}
        for name, value in (("first", first), ("last", last), ("f_min", f_min),
                            ("f_max", f_max), ("columns", columns)):
            if value is not None:
                members[name] = value
        if (first is None) != (last is None):
            members.setdefault("first", 0)
            members.setdefault("last", self.points - 1)
        info, payload = self._scope.request("spectrum", **members)
        return Spectrum(info, payload)

    def save_csv(self, path, first=0, last=None):
        last = self.points - 1 if last is None else last
        _write_csv(path, ["time_s", "ch%d_V" % self.channel],
                   [self.times(first, last), self.volts(first, last)])


class Scope:
    """A connection to scopebridge-server, with the scope's functions as methods.

    Settings that are not given are left as they are.  Errors from the
    server or the scope raise ServerError."""

    def __init__(self, host=None, port=None, timeout=60.0):
        host = host or os.environ.get("RIGOL_HOST", "127.0.0.1")
        port = int(port or os.environ.get("RIGOL_PORT", 5026))
        self.client = ScopeBridgeClient(host, port, timeout)
        self.idn = self.client.hello.get("idn")
        self.server_version = self.client.hello.get("version")
        self.source = self.client.hello.get("source")

    def close(self):
        self.client.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def request(self, cmd, **members):
        """Send any request of docs/PROTOCOL.md; returns (reply, payload)."""
        return self.client.request(cmd, **members)

    # -- acquisition --------------------------------------------------------

    def run(self):
        self.request("run")

    def stop(self):
        self.request("stop")

    def single(self):
        self.request("single")

    def auto(self):
        self.request("auto")

    def force(self):
        self.request("force")

    def trigger_status(self):
        """"td", "wait", "run", "auto", "armed" or "stop"."""
        return self.status()["trigger_status"]

    def wait_for_trigger(self, timeout=10.0, poll=0.05):
        """After single(): wait until the scope has triggered and stopped.
        Returns False on timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.trigger_status() == "stop":
                return True
            time.sleep(poll)
        return False

    # -- settings -----------------------------------------------------------

    def status(self):
        """All settings: channels, timebase, trigger, math."""
        reply, _ = self.request("status")
        return reply

    def channel(self, ch, **settings):
        """display, scale (V/div), offset (V), coupling ("dc", "ac", "gnd"),
        probe (1, 10, ...)."""
        self.request("set_channel", ch=ch, **settings)

    def timebase(self, **settings):
        """scale (s/div), offset (s), mode ("yt", "xy", "roll")."""
        self.request("set_timebase", **settings)

    def trigger(self, **settings):
        """Edge trigger: source ("ch1", "ch2", "ac", "ext"), slope
        ("rising", "falling", "either"), level (V); and sweep ("auto",
        "normal", "single").  Also mode ("edge", "pulse", "slope") and the
        pulse and slope_trigger settings, as in the protocol."""
        self.request("set_trigger", **settings)

    def pulse_trigger(self, **settings):
        """Switch to the pulse width trigger: source ("ch1", "ch2"), when
        ("pos_greater", "pos_less", "neg_greater", "neg_less",
        "pos_in_range", "neg_in_range"), width, lower, upper (s), level (V)."""
        self.request("set_trigger", mode="pulse", pulse=settings)

    def slope_trigger(self, **settings):
        """Switch to the slope trigger: source, when (as pulse_trigger),
        time, lower, upper (s), window ("a", "b", "both"), level_a,
        level_b (V)."""
        self.request("set_trigger", mode="slope", slope_trigger=settings)

    def edge_trigger(self, **settings):
        """Switch back to the edge trigger, with any edge settings."""
        self.request("set_trigger", mode="edge", **settings)

    def acquire(self, **settings):
        """Acquisition: type ("normal", "average", "peak", "hires"),
        averages (2, 4, ... 1024), memory_depth (points, 0 = automatic;
        12000 .. 24000000 with one channel on, 6000 .. 12000000 with two).
        status()["acquire"] reports them with the sample rate."""
        self.request("set_acquire", **settings)

    def math(self, **settings):
        """The scope's math channel: display, operator ("add", "sub", "mul",
        "div", "fft"), source1, source2, fft_source, fft_window, ..."""
        self.request("set_math", **settings)

    def save_setup(self, path):
        """Save the scope's complete setup to a file (binary, ~2 KB)."""
        reply, _ = self.request("save_setup")
        with open(path, "wb") as f:
            f.write(base64.b64decode(reply["setup"]))

    def load_setup(self, path):
        """Restore a setup saved with save_setup (or the GUI).  Returns the
        settings that could not be restored, with why (normally none)."""
        with open(path, "rb") as f:
            reply, _ = self.request("load_setup",
                                    setup=base64.b64encode(f.read()).decode())
        return reply.get("warnings", [])

    def scpi(self, text, query=False):
        """A raw SCPI command; with query, the scope's answer."""
        reply, _ = self.request("scpi", text=text, query=query)
        return reply.get("response")

    # -- pass/fail ----------------------------------------------------------

    def mask(self, **settings):
        """The pass/fail test.  With settings, changes them first: enable,
        source ("ch1", "ch2"), x, y (margins in divisions), stop_on_fail,
        beep, show_stats, create (a new mask around the waveform now),
        run (start or stop the test), reset (the counts).  Returns the
        settings and the passed, failed and total counts."""
        if settings:
            self.request("set_mask", **settings)
        reply, _ = self.request("mask")
        return {k: v for k, v in reply.items() if k not in ("id", "ok")}

    # -- references ---------------------------------------------------------

    def ref_save(self, slot, ch, label=None):
        """Keep channel ch's screen now as reference slot (1 .. 4) in the
        server, where every client sees it."""
        members = {"slot": slot, "ch": ch}
        if label:
            members["label"] = label
        self.request("ref_save", **members)

    def ref(self, slot):
        """Reference slot as a Waveform; its info has "label" and "ch"."""
        info, raw = self.request("ref", slot=slot)
        return Waveform(info, raw)

    def refs(self):
        """The references kept: a list of their info, without samples."""
        reply, _ = self.request("refs")
        return reply["refs"]

    def ref_clear(self, slot=None):
        """Forget reference slot, or all of them."""
        if slot is None:
            self.request("ref_clear")
        else:
            self.request("ref_clear", slot=slot)

    def ref_load(self, slot, times, volts, label="loaded", ch=0):
        """Store evenly spaced samples (volts at times, in seconds) as
        reference slot, as 8-bit values spanning their range.  ch: the
        channel whose vertical settings place it on the display."""
        volts = list(volts)
        times = list(times)
        lo, hi = min(volts), max(volts)
        y_inc = max(1e-6, (hi - lo) / 200.0)
        raw = bytes(max(0, min(255, int(round(27 + (v - lo) / y_inc))))
                    for v in volts)
        self.request("ref_load", slot=slot, ch=ch, label=label,
                     data=base64.b64encode(raw).decode(),
                     x_inc=(times[-1] - times[0]) / (len(times) - 1),
                     x_origin=times[0], y_inc=y_inc,
                     y_origin=-100.0 - lo / y_inc, y_ref=127.0)

    # -- bus decoding -------------------------------------------------------

    def decode(self, protocol, **settings):
        """Decode the captures (capture the channels first): protocol
        "uart" (tx, rx, baud, bits, parity, stop, inverted, msb_first),
        "i2c" (scl, sda) or "spi" (clk, data, edge, width, msb_first,
        inverted, timeout); also threshold1, threshold2 (V), first, last,
        max_items.  Returns the list of items: dicts with ch, type
        ("data", "address", "start", "stop"), t (s), first, last
        (samples), value, and for I2C ack and read, for UART error."""
        reply, _ = self.request("decode", protocol=protocol, **settings)
        return reply["items"]

    @staticmethod
    def text(items, ch=None):
        """The data bytes of decoded items (of channel ch) as text."""
        return "".join(chr(i["value"]) for i in items
                       if i["type"] == "data" and (ch is None or i["ch"] == ch))

    def timing(self, ch, to=None, burst_gap=None, polarity="high", **settings):
        """Time the blocks a program marks on channel ch (capture it first,
        and channel to as well): polarity "high" or "low", to (the other
        channel, for the latency from each block to the next pulse there),
        burst_gap (s: also group pulses into bursts split by longer
        pauses), bins, threshold (V), first, last.  Returns the reply: a
        dict with "block", "idle", "period" (and "latency", "burst",
        "burst_pulses"), each with count, min, max, mean, std_dev, median,
        shortest, longest and histogram; see timing_report."""
        members = dict(settings, ch=ch, polarity=polarity)
        if to is not None:
            members["to"] = to
        if burst_gap is not None:
            members["burst_gap"] = burst_gap
        reply, _ = self.request("timing", **members)
        return reply

    @staticmethod
    def timing_report(result):
        """A timing result as a table of text, one line per set of values."""
        def si(v, unit="s"):
            for scale, prefix in ((1, ""), (1e-3, "m"), (1e-6, "u"), (1e-9, "n")):
                if abs(v) >= scale * 0.99995 or scale == 1e-9:
                    return "%.4g %s%s" % (v / scale, prefix, unit)
        lines = ["%-16s %6s %11s %11s %11s %11s" % ("", "count", "min", "mean", "max", "std dev")]
        names = [("block", "block"), ("idle", "idle"), ("period", "period"),
                 ("latency", "latency to CH%s" % result.get("to")),
                 ("burst", "burst"), ("burst_pulses", "pulses/burst")]
        for key, name in names:
            s = result.get(key)
            if s is None:
                continue
            if s["count"] == 0:
                lines.append("%-16s %6d" % (name, 0))
                continue
            f = (lambda v: "%.4g" % v) if key == "burst_pulses" else si
            lines.append("%-16s %6d %11s %11s %11s %11s" % (
                name, s["count"], f(s["min"]), f(s["mean"]), f(s["max"]), f(s["std_dev"])))
        if "duty" in result:
            lines.append("duty %.1f %%, resolution %s" % (100 * result["duty"], si(result["resolution"])))
        return "\n".join(lines)

    def bus(self, protocol, bus=1, display=True, format="hex", **settings):
        """Show a decoded bus on the scope's screen: the settings of
        decode, and format ("hex", "ascii", "dec", "bin")."""
        self.request("set_decoder", protocol=protocol, bus=bus,
                     display=display, format=format, **settings)

    # -- data ---------------------------------------------------------------

    def measure(self, ch, *items):
        """{item: value}; None where the scope cannot measure.  Items as in
        MEASUREMENTS; default freq, vpp, vrms.  Up to 5 items stay fast."""
        members = {"ch": ch}
        if items:
            members["items"] = list(items)
        reply, _ = self.request("measure", **members)
        names = items or ("freq", "vpp", "vrms")
        return {name: reply.get(name) for name in names}

    def screen(self, ch):
        """The waveform on the scope's screen now (normally 1200 points)."""
        info, raw = self.request("screen", ch=ch)
        return Waveform(info, raw)

    def capture(self, ch, progress=None):
        """Read the channel's whole acquisition memory into the server
        (stops the scope).  progress(done, total) is called on the way."""
        info, _ = self.request("capture", ch=ch)
        while self.client._events:
            event, _ = self.client.next_event()
            if progress and event.get("event") == "progress":
                progress(event["done"], event["total"])
        return Capture(self, info)

    def screenshot(self, path):
        """Save the scope's screen as a BMP file."""
        _, image = self.request("screenshot")
        with open(path, "wb") as f:
            f.write(image)

    # -- logging ------------------------------------------------------------

    def record(self, path, ch=1, items=("freq", "vpp", "vrms"), interval=1.0,
               duration=None, count=None, on_row=None):
        """Measure items every interval seconds and append them to the CSV
        file path (created with a header if new), until duration seconds
        or count rows; without either, until interrupted (Ctrl-C).
        Returns the number of rows written.  on_row(row) sees each row."""
        new = not os.path.exists(path)
        rows = 0
        start = time.time()
        with open(path, "a", newline="") as f:
            out = csv.writer(f)
            if new:
                out.writerow(["time", "elapsed_s"] + ["ch%d_%s" % (ch, i)
                                                      for i in items])
            try:
                while (count is None or rows < count) and \
                      (duration is None or time.time() - start < duration):
                    tick = time.time()
                    values = self.measure(ch, *items)
                    row = [time.strftime("%Y-%m-%d %H:%M:%S"),
                           "%.3f" % (tick - start)] + \
                          ["" if values[i] is None else "%.6g" % values[i]
                           for i in items]
                    out.writerow(row)
                    f.flush()
                    rows += 1
                    if on_row:
                        on_row(row)
                    time.sleep(max(0.0, interval - (time.time() - tick)))
            except KeyboardInterrupt:
                pass
        return rows

    @staticmethod
    def sleep(seconds):
        time.sleep(seconds)
