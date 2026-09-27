// Code timing in the browser client: the Timing panel's settings, the
// server's analysis of the blocks a program marks on a pin, and under the
// display a table of their statistics, a histogram, and buttons that zoom
// the capture to the longest or shortest one.
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

import { $, eng, parseSI } from "./util.js";

const BINS = 40;

export class TimingPanel {
  constructor(conn, scope, say) {
    this.conn = conn;
    this.scope = scope;
    this.say = say;
    this.result = null;

    $("tim-run").addEventListener("click", () => this.run());
    $("tim-clear").addEventListener("click", () => this.clear());
    $("tim-which").addEventListener("change", () => this.draw());
    $("tim-longest").addEventListener("click", () => this.zoom("longest"));
    $("tim-shortest").addEventListener("click", () => this.zoom("shortest"));
    window.addEventListener("resize", () => { if (this.result) this.draw(); });
  }

  // The members of "timing"; throws for a burst gap that is no number
  settings() {
    const ch = Number($("tim-ch").value);
    const m = { ch, polarity: $("tim-polarity").value, bins: BINS };
    if ($("tim-to").value !== "0") m.to = 3 - ch;
    const gap = $("tim-gap").value.trim().toLowerCase();
    if (gap !== "off" && gap !== "") {
      const seconds = parseSI(gap);
      if (!(seconds > 0)) throw new Error("the burst gap is not a number: off, or e.g. 50u");
      m.burst_gap = seconds;
    }
    return m;
  }

  run() {
    if (this.scope.mode !== "capture") {
      this.say("Timing works on a capture: press Capture memory first", true);
      return;
    }
    let members;
    try {
      members = this.settings();
    } catch (e) {
      this.say(e.message, true);
      return;
    }
    this.say("Timing ...");
    this.conn.request("timing", members)
      .then(({ reply }) => this.show(reply))
      .catch((e) => this.say("Error: " + e.message, true));
  }

  show(reply) {
    this.result = reply;
    $("timing-table").textContent = TimingPanel.table(reply);
    $("timing").hidden = false;
    this.draw();
    this.say("Timed " + reply.block.count + " blocks on CH" + reply.ch +
             ".  Longest and Shortest zoom to them.");
  }

  // The statistics as a text table, one line per set of values
  static table(r) {
    const pad = (s, n) => s.padStart(n);
    const row = (name, s, unit) => {
      let line = name.padEnd(15) + pad(String(s.count), 6);
      if (s.count > 0) {
        const f = unit ? (v) => eng(v, unit) : (v) => v.toFixed(2);
        for (const k of ["min", "mean", "max", "std_dev"]) line += pad(f(s[k]), 10);
      }
      return line;
    };
    const lines = ["".padEnd(15) + pad("count", 6) + pad("min", 10) + pad("mean", 10) +
                   pad("max", 10) + pad("std dev", 10),
                   row("block", r.block, "s"), row("idle", r.idle, "s"),
                   row("period", r.period, "s")];
    if (r.latency) lines.push(row("latency to CH" + r.to, r.latency, "s"));
    if (r.burst) {
      lines.push(row("burst", r.burst, "s"));
      lines.push(row("pulses/burst", r.burst_pulses, ""));
    }
    if (r.duty !== undefined) {
      lines.push("duty " + (100 * r.duty).toFixed(1) + " %, resolution " +
                 eng(r.resolution, "s") + ", over " + eng(r.span, "s"));
    }
    return lines.join("\n");
  }

  // The set of values the histogram shows, if the result has it
  chosen() {
    return this.result ? this.result[$("tim-which").value] : undefined;
  }

  draw() {
    const canvas = $("timing-hist");
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (w === 0) return;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    const g = canvas.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.fillStyle = "#000";
    g.fillRect(0, 0, w, h);
    g.font = "12px ui-monospace, 'DejaVu Sans Mono', monospace";
    g.fillStyle = "#d9d9d9";
    const s = this.chosen();
    if (!s || s.count === 0) {
      g.fillText("Nothing to show", 8, h / 2);
      return;
    }
    const counts = s.histogram.counts;
    const most = Math.max(1, ...counts);
    const left = 8, top = 18, base = h - 20;
    const bar = (w - 2 * left) / counts.length;
    g.fillText(most + " most in a bin", left, 12);
    g.fillText(eng(s.histogram.from, "s"), left, h - 5);
    const right = eng(s.histogram.to, "s");
    g.fillText(right, w - left - g.measureText(right).width, h - 5);
    g.fillStyle = getComputedStyle(document.documentElement)
      .getPropertyValue(this.result.ch === 2 ? "--ch2" : "--ch1");
    counts.forEach((n, k) => {
      if (n === 0) return;
      // At least 4 pixels: a single outlier among hundreds is the bar that
      // matters most, and must not vanish
      const height = Math.max(4, (base - top) * n / most);
      g.fillRect(left + bar * k + 1, base - height, Math.max(1, bar - 2), height);
    });
    g.fillStyle = "#666";
    g.fillRect(left, base, w - 2 * left, 1);
  }

  zoom(which) {
    const s = this.chosen();
    if (!s || s.count === 0) return;
    const at = s[which];
    this.scope.zoomTo(at.first, at.last, 2);
    this.say("The " + which + " " + $("tim-which").value + ": " +
             eng(which === "longest" ? s.max : s.min, "s") + " at " + eng(at.t, "s"));
  }

  clear() {
    this.result = null;
    $("timing").hidden = true;
  }

  // A new capture is in: time it again, if results are shown
  captured() {
    if (this.result) this.run();
  }
}
