#!/usr/bin/env python3
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""An automated protocol test bench: an Arduino Uno and the scope.

For each test case: flash the Uno with a test program (uart.c, i2c.c or
spi.c, with the case's build options), set the scope up for it (channels,
timebase, trigger, memory, and its own bus decoder, so its screen shows
the bus too), trigger once, capture, decode, and check the decoded bytes
against what the program sends.  The report gives each case's result and
its timing as measured on the scope (baud rate, clock), and keeps the
scope's screenshot and the decoded items.  The timing.c case times the
program's code instead: its CRC's run time, and its bytes per call.

    scopebridge-run --usb auto examples/arduino/bench.py
    scopebridge-run --lan 192.168.0.83 examples/arduino/bench.py --only spi
    scopebridge-run --sim examples/arduino/bench.py --sim    # no Uno: the simulator

Wiring, the same for every case (a pin a program does not use is an input,
so the unused pins on a probe's jumper only listen):

    CH1  to D1 (UART TX), A5 (I2C SCL) and D13 (SPI clock, marker A), joined
    CH2  to D0 (UART RX), A4 (I2C SDA) and D11 (SPI data, marker B), joined
    both probes' ground clips to GND

With --ask it stops before each program instead, for probes moved by hand.
Options: --port (the Uno's serial port, found if there is one), --only NAME
(the cases whose name contains NAME), --out DIR (where results go),
--skip-flash (the program is on the Uno already).  Exit status 1 if a case
fails.
"""

import argparse
import csv
import glob
import json
import os
import re
import subprocess
import sys
import termios
import time
import tty

from scopebridge import Scope, ServerError

HERE = os.path.dirname(os.path.abspath(__file__))

# -----------------------------------------------------------------------------
# Checks: what each program sends, as decoded items
# -----------------------------------------------------------------------------


def text_of(items, ch):
    return "".join(chr(i["value"]) for i in items if i["type"] == "data" and i["ch"] == ch)


def check_uart(items):
    """At least one whole "Hello, Rigol! <n>" line, and no errors."""
    errors = [i for i in items if "error" in i]
    text = text_of(items, 1)
    lines = re.findall(r"Hello, Rigol!(?: \d+)?\r\n", text)
    if errors:
        return False, "%d bytes with %s errors" % (len(errors), errors[0]["error"])
    if not lines:
        return False, "no whole line in %r" % text[:60]
    return True, "%d whole lines, e.g. %r" % (len(lines), lines[0])


def check_echo(text):
    """uart.c's echo: the text the PC sent on CH2 (the Uno's RX), and back
    in upper case on CH1 (its TX), without errors"""
    def check(items):
        errors = [i for i in items if "error" in i]
        sent, echoed = text_of(items, 2), text_of(items, 1)
        if errors:
            return False, "%d bytes with %s errors" % (len(errors), errors[0]["error"])
        if text not in sent:
            return False, "CH2 (RX) has %r, not %r: is D0 on CH2?" % (sent[:40], text)
        if text.upper() not in echoed:
            return False, "CH1 (TX) has %r, not the echo %r" % (echoed[:40], text.upper())
        return True, "sent %r, echoed %r" % (text, text.upper())
    return check


I2C_EXPECTED = [
    ("start",), ("address", 0x50, False, True), ("data", 0x00, True), ("data", 0x10, True),
    ("stop",),
    ("start",), ("address", 0x50, False, True), ("data", 0x00, True),
    ("start",), ("address", 0x50, True, True), ("data", 0xA5, True), ("data", 0x3C, False),
    ("stop",),
]


def i2c_signature(i):
    if i["type"] in ("start", "stop"):
        return (i["type"],)
    if i["type"] == "address":
        return ("address", i["value"], i["read"], i["ack"])
    return ("data", i["value"], i["ack"])


def check_i2c(items):
    """The write and the read with a repeated start, in full."""
    sig = [i2c_signature(i) for i in items]
    n = len(I2C_EXPECTED)
    for k in range(len(sig) - n + 1):
        if sig[k:k + n] == I2C_EXPECTED:
            return True, "write 00 10 to 50h, read A5 3C back (%d items)" % len(items)
    return False, "the transactions were not found in %d items" % len(items)


def check_spi(word_bytes):
    def check(items):
        values = [i["value"] for i in items if i["type"] == "data"]
        n = len(word_bytes)
        for k in range(len(values) - n + 1):
            if values[k:k + n] == word_bytes:
                return True, " ".join("%02X" % v for v in word_bytes) + \
                    " (%d words)" % len(values)
        return False, "got " + " ".join("%02X" % v for v in values[:8])
    return check

def check_timing(pulses):
    """timing.c: a CRC per block on CH1, its bytes as pulses on CH2, in
    bursts of the message sizes, the bytes starting soon after the call"""
    def check(results):
        blocks, bytes_ = results
        block, sizes, latency = blocks["block"], bytes_.get("burst_pulses"), blocks.get("latency")
        if block["count"] < 3:
            return False, "%d blocks on CH1: is the program running?" % block["count"]
        if not sizes or sizes["count"] < 3:
            return False, "no bursts of pulses on CH2"
        counts = {sizes["min"], sizes["max"]}
        if not counts <= pulses or sizes["min"] == sizes["max"]:
            return False, "bursts of %d .. %d pulses, not %s" % (
                sizes["min"], sizes["max"], "/".join(map(str, sorted(pulses))))
        if not latency or latency["count"] < block["count"] or latency["max"] > 50e-6:
            return False, "CH2 does not follow CH1 within 50 us"
        return True, "%d blocks, %d bursts of %d .. %d pulses" % (
            block["count"], sizes["count"], sizes["min"], sizes["max"])
    return check


def block_times(results, x_inc):
    """The blocks' run times, and the latency to the first byte"""
    b, l = results[0]["block"], results[0]["latency"]
    return "block %.1f .. %.1f us, latency %.1f us" % (b["min"] * 1e6, b["max"] * 1e6,
                                                      l["mean"] * 1e6)


F_CPU = 16e6
MARKER = 2 / F_CPU          # an sbi or cbi: 2 cycles


def check_delay(delay_us, tolerance=0.005):
    """delay.c: a block of the delay plus one marker on CH1, and the bare
    markers on CH2, to within the Uno's resonator (0.5 %) and a sample or
    two of the scope"""
    def check(results):
        delay, markers = results[0]["block"], results[1]["block"]
        sample = results[0]["resolution"]
        expected = delay_us * 1e-6 + MARKER
        if delay["count"] < 5 or markers["count"] < 5:
            return False, "%d blocks on CH1, %d on CH2: is the program running?" % (
                delay["count"], markers["count"])
        error = delay["mean"] / expected - 1
        if abs(error) > tolerance:
            return False, "blocks of %.3f us, not %.3f us" % (delay["mean"] * 1e6, expected * 1e6)
        if delay["std_dev"] > 2 * sample:
            return False, "blocks spread by %.1f ns: a delay should not vary" % (
                delay["std_dev"] * 1e9)
        if abs(markers["mean"] - MARKER * (1 + error)) > 2 * sample:
            return False, "markers of %.1f ns, not %.1f ns" % (markers["mean"] * 1e9, MARKER * 1e9)
        return True, "%d blocks of %.3f us (%.3f expected), markers %.1f ns" % (
            delay["count"], delay["mean"] * 1e6, expected * 1e6, markers["mean"] * 1e9)
    return check


def check_pwm(duty):
    """pwm.c: the hardware PWM on CH2 at 16 MHz / 64 / 256 with the duty
    asked for and no spread; the software PWM on CH1 at the same rate (its
    median period: the interrupt makes some periods longer)"""
    period = 64 * 256 / F_CPU
    def check(results):
        hw, sw = results
        hp, hb = hw["period"], hw["block"]
        if hp["count"] < 5 or sw["period"]["count"] < 5:
            return False, "%d periods on CH2, %d on CH1: is the program running?" % (
                hp["count"], sw["period"]["count"])
        if abs(hp["mean"] / period - 1) > 0.005:
            return False, "hardware period %.2f us, not %.2f us" % (hp["mean"] * 1e6, period * 1e6)
        got = hb["mean"] / hp["mean"]
        if abs(got - duty / 100) > 0.005:
            return False, "hardware duty %.1f %%, not %d %%" % (got * 100, duty)
        if hb["std_dev"] > 2 * hw["resolution"]:
            return False, "hardware pulses spread by %.0f ns" % (hb["std_dev"] * 1e9)
        if abs(sw["period"]["median"] / hp["mean"] - 1) > 0.01:
            return False, "software period %.1f us, not the hardware's %.1f us" % (
                sw["period"]["median"] * 1e6, hp["mean"] * 1e6)
        return True, "hardware %.1f %% with a spread of %.0f ns, software %.1f us spread" % (
            got * 100, hb["std_dev"] * 1e9, sw["block"]["std_dev"] * 1e6)
    return check


def pwm_rate(results, x_inc):
    """The hardware PWM's frequency"""
    return "%.2f Hz" % (1 / results[0]["period"]["mean"])


def check_latency(critical_us):
    """irq_latency.c: from each hardware edge on CH2 to the interrupt's
    marker on CH1, a few us; with a critical section, some events waiting
    for it, without one, all within a microsecond"""
    def check(results):
        lat = results[0].get("latency")
        if not lat or lat["count"] < 5:
            return False, "%d latencies: is the program running?" % (lat["count"] if lat else 0)
        if not 0.3e-6 <= lat["min"] <= 5e-6:
            return False, "the shortest latency is %.2f us, not a few us" % (lat["min"] * 1e6)
        if critical_us and lat["max"] < 20e-6:
            return False, "no event waited for the critical section (longest %.2f us)" % (
                lat["max"] * 1e6)
        if not critical_us and lat["max"] - lat["min"] > 1e-6:
            return False, "latencies spread from %.2f to %.2f us" % (lat["min"] * 1e6, lat["max"] * 1e6)
        return True, "%d interrupts, latency %.2f .. %.1f us" % (
            lat["count"], lat["min"] * 1e6, lat["max"] * 1e6)
    return check


def latency_median(results, x_inc):
    """The usual latency, and the longest"""
    lat = results[0]["latency"]
    return "usually %.2f us, longest %.1f us" % (lat["median"] * 1e6, lat["max"] * 1e6)


def delay_clock(delay_us):
    """The Uno's real clock, from the delay's length in cycles"""
    def measure(results, x_inc):
        cycles = delay_us * 1e-6 * F_CPU + 2
        clock = cycles / results[0]["block"]["mean"]
        return "clock %.4f MHz (%+.3f %%)" % (clock / 1e6, (clock / F_CPU - 1) * 100)
    return measure


# -----------------------------------------------------------------------------
# Timing, from the decoded items and the capture's sample interval
# -----------------------------------------------------------------------------


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else None


def uart_baud(bits_per_frame):
    """Characters sent back to back start a frame apart"""
    def measure(items, x_inc):
        gaps = [b["first"] - a["first"] for a, b in zip(items, items[1:])
                if a["ch"] == b["ch"] == 1]
        frame = median(gaps)
        return None if not frame else "%.0f baud" % (bits_per_frame / (frame * x_inc))
    return measure


def echo_latency(text):
    """How soon uart.c echoes: from the end of each character received (a
    frame after its start) to the start of its echo"""
    def measure(items, x_inc):
        sent = [i for i in items if i["ch"] == 2 and i["type"] == "data"]
        tx = [i for i in items if i["ch"] == 1 and i["type"] == "data"]
        k = "".join(chr(i["value"]) for i in tx).find(text.upper())
        sent_k = "".join(chr(i["value"]) for i in sent).find(text)
        if k < 0 or sent_k < 0:
            return None
        sent = sent[sent_k:sent_k + len(text)]
        echoed = tx[k:k + len(text)]
        frame = median([b["first"] - a["first"] for a, b in zip(sent, sent[1:])])
        delay = median([e["first"] - c["first"] - frame for c, e in zip(sent, echoed)])
        return "echo %.1f us after each character" % (delay * x_inc * 1e6)
    return measure


def i2c_clock(items, x_inc):
    """Bytes of a transaction start nine clocks apart"""
    bytes_ = [i for i in items if i["type"] in ("address", "data")]
    gaps = [b["first"] - a["first"] for a, b in zip(bytes_, bytes_[1:])]
    gap = median(gaps)
    return None if not gap else "SCL %.1f kHz" % (9 / (gap * x_inc) / 1e3)


def spi_clock(items, x_inc):
    """From a word's first to its last clock edge: seven clocks"""
    spans = [i["last"] - i["first"] for i in items if i["type"] == "data"]
    span = median(spans)
    return None if not span else "SCK %.3f MHz" % (7 / (span * x_inc) / 1e6)

# -----------------------------------------------------------------------------
# The cases
# -----------------------------------------------------------------------------

UART_115200 = dict(protocol="uart", tx=1, baud=115200)
# At 16 MHz the Uno's 115200 baud is 117647, 2.1 % fast.  The server's
# decoder takes that at 115200 (it finds every start bit afresh), but the
# scope's own loses step after two characters of 11-bit frames (parity, or
# two stop bits): its decoder on the screen gets the real rate.
UNO_115200 = dict(baud=117647)

CASES = [
    # name, program, build options, simulator signal, scope setup, decode
    # settings, check, timing; screen: the timebase for the screenshot
    dict(name="uart-115200-8n1", program="uart", defs="", sim="UART",
         timebase=2e-3, depth=600000, trigger=("ch1", "falling"), channels=(1,),
         decode=UART_115200, format="ascii",
         check=check_uart, timing=uart_baud(10),
         bus=UNO_115200,
         screen=dict(scale=100e-6, offset=500e-6)),
    dict(name="uart-9600-8e1", program="uart", defs="-DBAUD=9600 -DPARITY=2", sim=None,
         timebase=5e-3, depth=600000, trigger=("ch1", "falling"), channels=(1,),
         decode=dict(protocol="uart", tx=1, baud=9600, parity="even"), format="ascii",
         check=check_uart, timing=uart_baud(11),
         screen=dict(scale=500e-6, offset=2.5e-3)),
    dict(name="uart-115200-8o1", program="uart", defs="-DPARITY=1", sim=None,
         timebase=2e-3, depth=600000, trigger=("ch1", "falling"), channels=(1,),
         decode=dict(protocol="uart", tx=1, baud=115200, parity="odd"), format="ascii",
         check=check_uart, timing=uart_baud(11),
         bus=UNO_115200,
         screen=dict(scale=100e-6, offset=500e-6)),
    dict(name="uart-115200-8n2", program="uart", defs="-DSTOP_BITS=2", sim=None,
         timebase=2e-3, depth=600000, trigger=("ch1", "falling"), channels=(1,),
         decode=dict(protocol="uart", tx=1, baud=115200, stop=2), format="ascii",
         check=check_uart, timing=uart_baud(11),
         bus=UNO_115200,
         screen=dict(scale=100e-6, offset=500e-6)),
    dict(name="uart-1M-8n1", program="uart", defs="-DBAUD=1000000", sim=None,
         timebase=2e-3, depth=600000, trigger=("ch1", "falling"), channels=(1,),
         decode=dict(protocol="uart", tx=1, baud=1000000), format="ascii",
         check=check_uart, timing=uart_baud(10),
         screen=dict(scale=10e-6, offset=50e-6)),
    dict(name="uart-echo", program="uart", defs="", sim=None, echo="rigol 42",
         timebase=500e-6, offset=2e-3, depth=600000, trigger=("ch2", "falling"),
         channels=(1, 2), decode=dict(protocol="uart", tx=1, rx=2, baud=115200),
         format="ascii", check=check_echo("rigol 42"), timing=echo_latency("rigol 42"),
         bus=UNO_115200,
         screen=dict(scale=100e-6, offset=500e-6, single=False)),
    dict(name="i2c-100k", program="i2c", defs="", sim="IIC",
         timebase=500e-6, depth=0, trigger=("ch2", "falling"), channels=(1, 2),
         decode=dict(protocol="i2c", scl=1, sda=2), format="hex",
         check=check_i2c, timing=i2c_clock,
         screen=dict(scale=100e-6, offset=500e-6)),
    dict(name="spi-mode0-msb", program="spi", defs="", sim="SPI",
         timebase=20e-6, depth=0, trigger=("ch1", "rising"), channels=(1, 2),
         decode=dict(protocol="spi", clk=1, data=2, edge="rising"), format="hex",
         check=check_spi([0x9F, 0xEF, 0x40, 0x18]), timing=spi_clock,
         screen=dict(scale=5e-6, offset=20e-6,
                     pulse=dict(source="ch1", when="neg_greater", width=50e-6, level=2.5))),
    dict(name="spi-mode1", program="spi", defs="-DSPI_MODE=1", sim=None,
         timebase=20e-6, depth=0, trigger=("ch1", "rising"), channels=(1, 2),
         decode=dict(protocol="spi", clk=1, data=2, edge="falling"), format="hex",
         check=check_spi([0x9F, 0xEF, 0x40, 0x18]), timing=spi_clock,
         screen=dict(scale=5e-6, offset=20e-6,
                     pulse=dict(source="ch1", when="neg_greater", width=50e-6, level=2.5))),
    dict(name="spi-mode2", program="spi", defs="-DSPI_MODE=2", sim=None,
         timebase=20e-6, depth=0, trigger=("ch1", "falling"), channels=(1, 2),
         decode=dict(protocol="spi", clk=1, data=2, edge="falling"), format="hex",
         check=check_spi([0x9F, 0xEF, 0x40, 0x18]), timing=spi_clock,
         screen=dict(scale=5e-6, offset=20e-6,
                     pulse=dict(source="ch1", when="pos_greater", width=50e-6, level=2.5))),
    dict(name="spi-mode3", program="spi", defs="-DSPI_MODE=3", sim=None,
         timebase=20e-6, depth=0, trigger=("ch1", "falling"), channels=(1, 2),
         decode=dict(protocol="spi", clk=1, data=2, edge="rising"), format="hex",
         check=check_spi([0x9F, 0xEF, 0x40, 0x18]), timing=spi_clock,
         screen=dict(scale=5e-6, offset=20e-6,
                     pulse=dict(source="ch1", when="pos_greater", width=50e-6, level=2.5))),
    dict(name="spi-lsb-first", program="spi", defs="-DLSB_FIRST=1", sim=None,
         timebase=20e-6, depth=0, trigger=("ch1", "rising"), channels=(1, 2),
         decode=dict(protocol="spi", clk=1, data=2, edge="rising", msb_first=False),
         format="hex", check=check_spi([0x9F, 0xEF, 0x40, 0x18]), timing=spi_clock,
         screen=dict(scale=5e-6, offset=20e-6,
                     pulse=dict(source="ch1", when="neg_greater", width=50e-6, level=2.5))),
    dict(name="timing-crc16", program="timing", defs="", sim="TIMing",
         timebase=1e-3, depth=600000, trigger=("ch1", "rising"), channels=(1, 2),
         analyse=[dict(ch=1, to=2), dict(ch=2, burst_gap=50e-6)],
         check=check_timing({16, 32}), sim_check=check_timing({8, 12}),
         timing=block_times,
         screen=dict(scale=50e-6, offset=200e-6)),
    dict(name="pwm-50", program="pwm", defs="", sim=None,
         timebase=1e-3, depth=600000, trigger=("ch2", "rising"), channels=(1, 2),
         analyse=[dict(ch=2), dict(ch=1)],
         check=check_pwm(50), timing=pwm_rate,
         screen=dict(scale=200e-6, offset=800e-6)),
    dict(name="pwm-25", program="pwm", defs="-DDUTY=25", sim=None,
         timebase=1e-3, depth=600000, trigger=("ch2", "rising"), channels=(1, 2),
         analyse=[dict(ch=2), dict(ch=1)],
         check=check_pwm(25), timing=pwm_rate,
         screen=dict(scale=200e-6, offset=800e-6)),
    dict(name="irq-latency", program="irq_latency", defs="", sim=None,
         timebase=5e-3, depth=6000000, trigger=("ch2", "rising"), channels=(1, 2),
         analyse=[dict(ch=2, to=1)],
         check=check_latency(300), timing=latency_median,
         screen=dict(scale=1e-6, offset=4e-6)),
    dict(name="irq-no-critical", program="irq_latency", defs="-DCRITICAL_US=0", sim=None,
         timebase=5e-3, depth=6000000, trigger=("ch2", "rising"), channels=(1, 2),
         analyse=[dict(ch=2, to=1)],
         check=check_latency(0), timing=latency_median,
         screen=dict(scale=1e-6, offset=4e-6)),
    dict(name="delay-100us", program="delay", defs="", sim=None,
         timebase=200e-6, depth=600000, trigger=("ch1", "rising"), channels=(1, 2),
         analyse=[dict(ch=1), dict(ch=2)],
         check=check_delay(100), timing=delay_clock(100),
         screen=dict(scale=20e-6, offset=100e-6)),
]

WIRING = {
    "uart": "CH1 to D1 (TX)",
    "i2c": "CH1 to A5 (SCL), CH2 to A4 (SDA)",
    "spi": "CH1 to D13 (SCK), CH2 to D11 (MOSI)",
    "timing": "CH1 to D13 (marker A), CH2 to D11 (marker B)",
    "delay": "CH1 to D13 (marker A), CH2 to D11 (marker B)",
    "pwm": "CH1 to D13 (the software PWM), CH2 to D11 (the hardware PWM)",
    "irq_latency": "CH1 to D13 (the interrupt's marker), CH2 to D11 (the timer's edge)",
}

# -----------------------------------------------------------------------------
# Running a case
# -----------------------------------------------------------------------------


def find_port():
    ports = sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*"))
    if len(ports) != 1:
        sys.exit("bench: %s; give the Uno's port with --port" %
                 ("no serial port found" if not ports else "several ports: " + ", ".join(ports)))
    return ports[0]


def flash(case, port, log):
    """Build and upload the case's program; the Uno then resets and runs it"""
    result = subprocess.run(
        ["make", "-C", HERE, "flash-" + case["program"], "PORT=" + port, "DEFS=" + case["defs"]],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log.write(result.stdout)
    if result.returncode != 0:
        raise RuntimeError("flashing failed; see flash.log")
    time.sleep(2)   # the bootloader hands over, the program starts


def set_up(scope, case):
    """Channels, timebase, trigger and memory for the case: CH1 in the upper
    half, CH2 in the lower, both at 2 V/div for the Uno's 0 .. 5 V"""
    scope.run()                       # the memory depth changes only while running
    scope.channel(1, display=True, scale=2, offset=1)
    scope.channel(2, display=True, scale=2, offset=-7)
    scope.timebase(scale=case["timebase"], offset=case.get("offset", 0))
    source, slope = case["trigger"]
    scope.edge_trigger(source=source, slope=slope, level=2.5, sweep="normal")
    scope.acquire(type="normal", memory_depth=case["depth"])
    if "decode" in case:
        # On the scope's screen too; its own decoder may need the Uno's real
        # rate (see UNO_115200)
        scope.bus(format=case["format"], **dict(case["decode"], **case.get("bus", {})))
    else:
        scope.bus(protocol="uart", tx=1, display=False)


def screenshot(scope, case, path, sim):
    """The scope's screen, as evidence and for the eye: a new single
    acquisition at the case's screen timebase, where the bus or the blocks
    can be read (and with its pulse trigger, if it has one), with the
    measurements cleared from the bottom line"""
    scope.scpi(":MEASure:CLEar ALL")
    if "screen" in case:
        screen = case["screen"]
        # Stopped, the scope zooms into what it acquired: that is enough
        # for a case whose signal only comes when the bench sends it
        scope.timebase(scale=screen["scale"], offset=screen["offset"])
        if "pulse" in screen:
            scope.pulse_trigger(**screen["pulse"])
        if screen.get("single", True):
            scope.single()
            scope.wait_for_trigger(timeout=5)
    if not sim:
        # After a memory read the scope shows "Stop point changed!", then
        # "Can Operate Now!", and after clearing "No items!", one after
        # the other, a second or two each
        time.sleep(5)
    scope.screenshot(path)


def level_problem(scope, captures):
    """None if each captured channel's high level is about the Uno's 5 V;
    otherwise what is wrong, most likely the probe setting.  The high
    level is the median of the samples above the middle, which overshoot
    hardly moves; a 10 times wrong setting shows 0.5 V, or 50 V clipped at
    the edge of the scope's range."""
    probes = {c["ch"]: c["probe"] for c in scope.status()["channels"]}
    for ch, capture in captures.items():
        volts = capture.volts()
        low, high = float(min(volts)), float(max(volts))
        middle = (low + high) / 2
        highs = sorted(float(v) for v in volts if v > middle)
        top = highs[len(highs) // 2] if highs else high
        if 3.5 <= top <= 6.5:
            continue
        setting = "the scope's CH%d probe setting is %gx" % (ch, probes[ch])
        if high - low < 0.2:
            return "CH%d shows no signal (%.2f .. %.2f V): is it wired?" % (ch, low, high)
        if 0.3 <= top <= 0.8:
            return ("CH%d's high level is %.2f V, a tenth of 5 V: its probe is switched "
                    "to x10, but %s" % (ch, top, setting))
        if top > 6.5:
            return ("CH%d's high level is %.2f V, far over 5 V: its probe is switched "
                    "to x1, but %s" % (ch, top, setting))
        return ("CH%d's high level is %.2f V, not about 5 V: check the wiring, and "
                "that %s as the probe's switch" % (ch, top, setting.replace(" is ", " is the same ")))
    return None


def open_serial(port, baud):
    """The Uno's serial port, raw, at baud, reads not waiting.  Opening it
    resets the Uno."""
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    attrs[4] = attrs[5] = getattr(termios, "B%d" % baud)
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def read_until(fd, marker, timeout):
    """Serial input up to and including marker; b"" if it does not come"""
    data, end = b"", time.time() + timeout
    while marker not in data and time.time() < end:
        try:
            data += os.read(fd, 256)
        except BlockingIOError:
            time.sleep(0.001)
    return data if marker in data else b""


def send_for_echo(scope, port, text, attempts=3):
    """Arm the scope, then send text to uart.c just after one of its
    messages, when it has 10 ms with nothing to do but echo.  The echo
    comes back to the PC too: without it (the Uno still starting, say),
    arm and send again.  Returns the attempts it took."""
    fd = open_serial(port, 115200)
    try:
        # Opening the port resets the Uno: its bootloader runs for about a
        # second (and drives the LED on D13, on CH1 with TX) before
        # uart.c starts again.  What arrived before that is old.
        time.sleep(2)
        termios.tcflush(fd, termios.TCIFLUSH)
        if not read_until(fd, b"Hello, Rigol!", timeout=3):
            raise RuntimeError("uart.c does not answer on " + port)
        for attempt in range(1, attempts + 1):
            scope.single()
            for _ in range(100):
                if scope.trigger_status() == "wait":
                    break
                time.sleep(0.02)
            read_until(fd, b"\n", timeout=1)          # a message just ended
            os.write(fd, text.encode())
            if read_until(fd, text.upper().encode(), timeout=0.1):
                return attempt
        raise RuntimeError("no echo of %r in %d attempts" % (text, attempts))
    finally:
        os.close(fd)


def run_case(scope, case, folder, sim, port=None):
    set_up(scope, case)
    if sim:
        scope.scpi(":SIMulator:SIGNal " + case["sim"])
    time.sleep(0.5)
    attempts = 1
    if "echo" in case:
        attempts = send_for_echo(scope, port, case["echo"])
    else:
        scope.single()
    if not scope.wait_for_trigger(timeout=5):
        # Force one acquisition, and see whether the levels say why:
        # a wrong probe setting keeps the signal off the trigger level
        scope.force()
        time.sleep(0.5)
        screens = {ch: scope.screen(ch) for ch in case["channels"]}
        problem = None if sim else level_problem(scope, screens)
        return dict(ok=False, detail="no trigger within 5 s: " + (
            problem or "is the Uno running and wired?"))
    captures = {ch: scope.capture(ch) for ch in case["channels"]}
    x_inc = captures[case["channels"][0]].x_increment
    problem = None if sim else level_problem(scope, captures)
    if problem:
        return dict(ok=False, detail=problem)
    if "analyse" in case:
        return time_case(scope, case, folder, sim, captures, x_inc)
    items = scope.decode(**case["decode"])
    ok, detail = case["check"](items)
    if attempts > 1:
        detail += " (echoed at attempt %d)" % attempts
    timing = case["timing"](items, x_inc)

    # Evidence: the scope's screen (with its own decoded bus) and the items
    screenshot(scope, case, os.path.join(folder, case["name"] + ".bmp"), sim)
    with open(os.path.join(folder, case["name"] + ".csv"), "w", newline="") as f:
        out = csv.writer(f)
        out.writerow(["time_s", "ch", "type", "value", "ack", "read", "error"])
        for i in items:
            out.writerow(["%.9g" % i["t"], i["ch"], i["type"],
                          "" if "value" not in i else "0x%02X" % i["value"],
                          i.get("ack", ""), i.get("read", ""), i.get("error", "")])
    return dict(ok=ok, detail=detail, timing=timing, items=len(items),
                sample_rate=captures[case["channels"][0]].sample_rate)


def time_case(scope, case, folder, sim, captures, x_inc):
    """A code timing case: a timing request per entry of "analyse" """
    results = [scope.timing(**members) for members in case["analyse"]]
    ok, detail = (case["sim_check"] if sim else case["check"])(results)
    screenshot(scope, case, os.path.join(folder, case["name"] + ".bmp"), sim)
    with open(os.path.join(folder, case["name"] + ".txt"), "w") as f:
        for members, result in zip(case["analyse"], results):
            f.write("timing %s\n%s\n\n" % (
                " ".join("%s=%s" % kv for kv in members.items()), Scope.timing_report(result)))
    return dict(ok=ok, detail=detail, timing=case["timing"](results, x_inc) if ok else None,
                items=results[0]["block"]["count"],
                sample_rate=captures[case["channels"][0]].sample_rate)


def main():
    parser = argparse.ArgumentParser(description="Protocol test bench: an Arduino Uno and the scope")
    parser.add_argument("--port", help="the Uno's serial port (found if there is one)")
    parser.add_argument("--only", help="run the cases whose name contains this")
    parser.add_argument("--out", default="bench-results", help="where results go")
    parser.add_argument("--ask", action="store_true", help="stop to rewire before each program")
    parser.add_argument("--skip-flash", action="store_true", help="the program is on the Uno already")
    parser.add_argument("--sim", action="store_true",
                        help="no Uno: the simulated scope's own signals (scopebridge-run --sim)")
    options = parser.parse_args()

    cases = [c for c in CASES if (not options.only or options.only in c["name"])
             and (not options.sim or c["sim"])]
    if not cases:
        sys.exit("bench: no cases to run")
    port = None if options.sim else (options.port or find_port())
    folder = os.path.join(options.out, time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(folder)

    results = []
    with Scope() as scope, open(os.path.join(folder, "flash.log"), "w") as log:
        print("Scope: %s\nResults: %s" % (scope.idn, folder))
        if not options.sim:
            print("Probe settings: %s (as the probes' switches must be)\n" % ", ".join(
                "CH%d %gx" % (c["ch"], c["probe"]) for c in scope.status()["channels"]))
        wired = None
        for case in cases:
            print("%-16s " % case["name"], end="", flush=True)
            started = time.time()
            try:
                if options.ask and wired != case["program"]:
                    input("\n  wire %s, then press Enter " % WIRING[case["program"]])
                    wired = case["program"]
                if port and not options.skip_flash:
                    flash(case, port, log)
                result = run_case(scope, case, folder, options.sim, port)
            except (RuntimeError, ServerError) as e:
                result = dict(ok=False, detail=str(e))
            result.update(name=case["name"], program=case["program"], defs=case["defs"],
                          seconds=round(time.time() - started, 1))
            results.append(result)
            print("%s  %s%s" % ("pass" if result["ok"] else "FAIL", result["detail"],
                                "   [" + result["timing"] + "]" if result.get("timing") else ""))
        scope.bus(protocol="uart", tx=1, display=False)   # the scope's decoder off
        scope.run()

    passed = sum(r["ok"] for r in results)
    with open(os.path.join(folder, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    with open(os.path.join(folder, "report.md"), "w") as f:
        f.write("# Protocol test bench, %s\n\n" % time.strftime("%Y-%m-%d %H:%M"))
        f.write("Scope: %s  \n%d of %d cases passed.\n\n" % (scope.idn, passed, len(results)))
        f.write("| case | program | build options | result | measured | details |\n")
        f.write("|------|---------|---------------|--------|----------|---------|\n")
        for r in results:
            f.write("| %s | %s.c | %s | %s | %s | %s |\n" % (
                r["name"], r["program"], r["defs"] or "-", "pass" if r["ok"] else "**FAIL**",
                r.get("timing") or "-", r["detail"].replace("|", "\\|")))
        f.write("\nPer case: the scope's screenshot (`<case>.bmp`, with its own bus "
                "decoder on) and the decoded items (`<case>.csv`), or for code timing "
                "the statistics (`<case>.txt`).\n")
    print("\n%d of %d passed; report: %s" % (passed, len(results), os.path.join(folder, "report.md")))
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
