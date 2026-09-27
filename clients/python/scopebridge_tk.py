#!/usr/bin/env python3
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""A small live view of the scope in tkinter, as a second front end.

    scopebridge_tk.py [--host 127.0.0.1] [--port 5026]

It speaks only the protocol of docs/PROTOCOL.md, like scopebridge-gui, and can
run next to it: both are clients of the same scopebridge-server.  Shows both
channels live with their measurements, and sets run/stop, V/div and
time/div.

tkinter must only be used from its own thread, so a network thread owns
the connection: it sends the GUI's requests and reads events, and hands
everything to the GUI through a queue that a timer drains.
"""

import argparse
import queue
import threading
import tkinter as tk
from tkinter import ttk

from scopebridge_client import ServerError, ScopeBridgeClient

COLOURS = {1: "#ffe600", 2: "#00d9ff"}
V_PER_DIV = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
             1, 2, 5, 10, 20, 50, 100]
S_PER_DIV = [m * 10.0 ** e for e in range(-9, 2) for m in (1, 2, 5)
             if 5e-9 <= m * 10.0 ** e <= 50]


def eng(x, unit):
    """1.00 ms, 500 mV, ..."""
    if x is None:
        return "-"
    for factor, prefix in ((1e9, "G"), (1e6, "M"), (1e3, "k"), (1, ""),
                           (1e-3, "m"), (1e-6, "µ"), (1e-9, "n")):
        if abs(x) >= factor or factor == 1e-9:
            return "%.3g %s%s" % (x / factor, prefix, unit)


class Network(threading.Thread):
    """Owns the server connection."""

    def __init__(self, host, port, inbox):
        super().__init__(daemon=True)
        self.client = ScopeBridgeClient(host, port)
        self.inbox = inbox            # to the GUI: ("event"|"reply"|"error", ...)
        self.requests = queue.Queue() # from the GUI: (cmd, members)

    def request(self, cmd, **members):
        self.requests.put((cmd, members))

    def run(self):
        while True:
            try:
                while not self.requests.empty():
                    cmd, members = self.requests.get_nowait()
                    try:
                        reply, _ = self.client.request(cmd, **members)
                        self.inbox.put(("reply", cmd, reply))
                    except ServerError as e:
                        self.inbox.put(("error", str(e)))
                while self.client._events:
                    self.inbox.put(("event",) + self.client._events.popleft())
                try:
                    self.inbox.put(("event",) + self.client.next_event(timeout=0.05))
                except OSError:        # socket.timeout: nothing arrived
                    pass
            except ConnectionError as e:
                self.inbox.put(("error", "connection lost: %s" % e))
                return


class App:
    def __init__(self, root, network):
        self.root = root
        self.net = network
        self.inbox = network.inbox
        self.frames = {}              # ch -> (event, payload)
        self.settings = {}            # from status

        root.title("ScopeBridge (Python)")
        self.canvas = tk.Canvas(root, width=720, height=480, bg="black",
                                highlightthickness=0)
        self.canvas.grid(row=0, column=0, rowspan=10, sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(9, weight=1)
        self.canvas.bind("<Configure>", lambda e: self.draw())

        side = ttk.Frame(root, padding=8)
        side.grid(row=0, column=1, sticky="n")
        buttons = ttk.Frame(side)
        buttons.pack(fill="x")
        for label, cmd in (("Run", "run"), ("Stop", "stop"),
                           ("Single", "single"), ("Auto", "auto")):
            ttk.Button(buttons, text=label, width=6,
                       command=lambda c=cmd: self.act(c)).pack(side="left")

        self.scale_vars = {}
        for ch in (1, 2):
            box = ttk.LabelFrame(side, text="CH%d" % ch, padding=6)
            box.pack(fill="x", pady=4)
            var = tk.StringVar()
            menu = ttk.Combobox(box, textvariable=var, state="readonly",
                                values=[eng(v, "V") + "/div" for v in V_PER_DIV])
            menu.bind("<<ComboboxSelected>>",
                      lambda e, c=ch, m=menu: self.set_scale(c, m.current()))
            menu.pack(fill="x")
            self.scale_vars[ch] = var

        box = ttk.LabelFrame(side, text="Timebase", padding=6)
        box.pack(fill="x", pady=4)
        self.time_var = tk.StringVar()
        self.time_menu = ttk.Combobox(box, textvariable=self.time_var,
                                      state="readonly",
                                      values=[eng(v, "s") + "/div" for v in S_PER_DIV])
        self.time_menu.bind("<<ComboboxSelected>>", lambda e: self.net.request(
            "set_timebase", scale=S_PER_DIV[self.time_menu.current()]))
        self.time_menu.pack(fill="x")

        box = ttk.LabelFrame(side, text="Measurements", padding=6)
        box.pack(fill="x", pady=4)
        self.meas = tk.StringVar(value="-")
        ttk.Label(box, textvariable=self.meas, justify="left",
                  font=("Monospace", 10)).pack(anchor="w")

        self.status = tk.StringVar(value="Connected to %s" %
                                   network.client.hello.get("source"))
        ttk.Label(root, textvariable=self.status).grid(row=10, column=0,
                                                       columnspan=2, sticky="w")

        self.net.request("status")
        self.net.request("live", on=True, interval_ms=100)
        root.after(30, self.poll)
        root.after(2000, self.periodic_status)

    def act(self, cmd):
        self.net.request(cmd)
        self.net.request("status")

    def set_scale(self, ch, index):
        self.net.request("set_channel", ch=ch, scale=V_PER_DIV[index])
        self.net.request("status")

    def periodic_status(self):
        self.net.request("status")
        self.root.after(2000, self.periodic_status)

    def poll(self):
        redraw = False
        try:
            while True:
                item = self.inbox.get_nowait()
                if item[0] == "event":
                    event, payload = item[1], item[2]
                    if event["event"] == "frame":
                        self.frames[event["ch"]] = (event, payload)
                        redraw = True
                    elif event["event"] == "measure":
                        self.meas.set("CH%d\n" % event["ch"] + "\n".join(
                            "%-5s %s" % (name, eng(event.get(name), unit))
                            for name, unit in (("freq", "Hz"), ("vpp", "V"),
                                               ("vrms", "V"))))
                elif item[0] == "reply" and item[1] == "status":
                    self.apply_status(item[2])
                    redraw = True
                elif item[0] == "error":
                    self.status.set("Error: " + item[1])
        except queue.Empty:
            pass
        if redraw:
            self.draw()
        self.root.after(30, self.poll)

    def apply_status(self, st):
        self.settings = st
        for c in st["channels"]:
            nearest = min(range(len(V_PER_DIV)),
                          key=lambda i: abs(V_PER_DIV[i] - c["scale"]))
            self.scale_vars[c["ch"]].set(eng(V_PER_DIV[nearest], "V") + "/div")
        tb = st["timebase"]["scale"]
        nearest = min(range(len(S_PER_DIV)), key=lambda i: abs(S_PER_DIV[i] - tb))
        self.time_var.set(eng(S_PER_DIV[nearest], "s") + "/div")

    def draw(self):
        c = self.canvas
        c.delete("all")
        w, h = c.winfo_width(), c.winfo_height()
        for i in range(1, 12):
            c.create_line(w * i / 12, 0, w * i / 12, h, fill="#444", dash=(1, 4))
        for j in range(1, 8):
            c.create_line(0, h * j / 8, w, h * j / 8, fill="#444", dash=(1, 4))
        channels = {x["ch"]: x for x in self.settings.get("channels", [])}
        for ch, (event, raw) in self.frames.items():
            setting = channels.get(ch)
            if not setting or not setting["display"] or len(raw) < 2:
                continue
            volts = ScopeBridgeClient.volts(event, raw)
            n = len(volts)
            points = []
            for i, v in enumerate(volts):
                div = (v + setting["offset"]) / setting["scale"]
                # a slow sweep sends the screen while it fills, from the
                # left: place points on the scope's 1200-point screen
                points += [w * i / 1199, h / 2 - div * h / 8]
            c.create_line(*points, fill=COLOURS[ch])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5026)
    options = parser.parse_args()
    network = Network(options.host, options.port, queue.Queue())
    network.start()
    root = tk.Tk()
    App(root, network)
    root.mainloop()


if __name__ == "__main__":
    main()
