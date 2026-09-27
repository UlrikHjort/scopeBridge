// The spectrum display of the browser client: dBV (or Vrms) against
// frequency, with a peak marker, a linear or log frequency axis, and zoom.
// Like the desktop GUI's (gui/src/spectrum_view.adb).
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

import { eng } from "./util.js";

const COLOUR = "#f259d9";
const DB_TOP = 20;       // dBV at the top line
const DB_PER_DIV = 10;
const DIVISIONS = 10;

// Bins either side of DC a window spreads the DC level into
const DC_LOBE = { rect: 1, hann: 2, hamming: 2, triangle: 2, blackman: 3, flattop: 5 };

export class SpectrumView {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.data = null;
    this.log = false;
    this.range = null;       // [fLo, fHi] in view, or null: everything
    this.full = null;        // the whole spectrum's range
    this.pointers = new Map();
    this.scheduled = false;
    new ResizeObserver(() => this.redraw()).observe(canvas);
    this.listen();
  }

  // Forget the spectrum and the range: a new source
  reset() {
    this.data = null;
    this.range = null;
    this.full = null;
    this.redraw();
  }

  // { values, f0, df, rbw, unit, window, label }; values is a Float32Array
  show(data) {
    this.data = data;
    this.full = [data.f0, data.f0 + (data.values.length - 1) * data.df];
    this.redraw();
  }

  setLog(on) {
    this.log = on;
    this.redraw();
  }

  redraw() {
    if (this.scheduled) return;
    this.scheduled = true;
    const now = () => {
      if (!this.scheduled) return;
      this.scheduled = false;
      this.draw();
    };
    requestAnimationFrame(now);
    setTimeout(now, 250);
  }

  view() {
    const [lo, hi] = this.range || this.full || [0, 1];
    // A log axis starts above 0 Hz: at the first point, or a thousandth
    if (this.log) {
      const d = this.data;
      const first = d ? Math.max(d.f0, d.df) : hi / 1000;
      return [Math.max(lo, first, hi / 1e6), hi];
    }
    return [lo, hi];
  }

  geometry() {
    const w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    return { w, h, L: 8, T: 24, W: w - 16, H: h - 24 - 22 };
  }

  xOf(f, [lo, hi], g) {
    return this.log
      ? g.L + (g.W * Math.log(f / lo)) / Math.log(hi / lo)
      : g.L + (g.W * (f - lo)) / (hi - lo);
  }

  fOf(x, [lo, hi], g) {
    const frac = (x - g.L) / g.W;
    return this.log ? lo * Math.pow(hi / lo, frac) : lo + frac * (hi - lo);
  }

  draw() {
    const ctx = this.ctx;
    const dpr = window.devicePixelRatio || 1;
    const g = this.geometry();
    if (this.canvas.width !== Math.round(g.w * dpr) || this.canvas.height !== Math.round(g.h * dpr)) {
      this.canvas.width = Math.round(g.w * dpr);
      this.canvas.height = Math.round(g.h * dpr);
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, g.w, g.h);
    if (g.W < 50 || g.H < 30) return;
    ctx.font = "12px ui-monospace, 'DejaVu Sans Mono', Menlo, monospace";

    ctx.strokeStyle = "#555";
    ctx.lineWidth = 1;
    ctx.setLineDash([1, 4]);
    ctx.beginPath();
    for (let i = 1; i < 10; i++) {
      const x = Math.floor(g.L + (g.W * i) / 10) + 0.5;
      ctx.moveTo(x, g.T); ctx.lineTo(x, g.T + g.H);
    }
    for (let j = 1; j < DIVISIONS; j++) {
      const y = Math.floor(g.T + (g.H * j) / DIVISIONS) + 0.5;
      ctx.moveTo(g.L, y); ctx.lineTo(g.L + g.W, y);
    }
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.strokeRect(g.L + 0.5, g.T + 0.5, g.W - 1, g.H - 1);

    const d = this.data;
    if (!d || d.values.length < 2) {
      ctx.fillStyle = "#888";
      ctx.fillText("FFT: waiting for a spectrum ...", g.L, 16);
      return;
    }
    const v = this.view();
    const dB = d.unit === "dBV";
    let top = DB_TOP, bottom = DB_TOP - DB_PER_DIV * DIVISIONS;
    if (!dB) {
      let max = 0;
      for (const x of d.values) max = Math.max(max, x);
      top = max > 0 ? max * 1.1 : 1;
      bottom = 0;
    }
    const yOf = (x) => g.T + (g.H * (top - x)) / (top - bottom);

    // The highest point per pixel column, so no line is lost
    ctx.save();
    ctx.beginPath();
    ctx.rect(g.L, g.T, g.W, g.H);
    ctx.clip();
    ctx.strokeStyle = COLOUR;
    ctx.lineWidth = 1.2;
    ctx.beginPath();
    let column = null, best = -Infinity, started = false;
    const flush = () => {
      if (column === null) return;
      if (started) ctx.lineTo(column, yOf(best)); else ctx.moveTo(column, yOf(best));
      started = true;
    };
    for (let i = 0; i < d.values.length; i++) {
      const f = d.f0 + i * d.df;
      if (f < v[0] - d.df || f > v[1] + d.df || (this.log && f <= 0)) continue;
      const x = Math.round(this.xOf(f, v, g));
      if (x !== column) {
        flush();
        column = x;
        best = d.values[i];
      } else {
        best = Math.max(best, d.values[i]);
      }
    }
    flush();
    ctx.stroke();

    // Peak: the highest point in view, away from DC
    const dcLimit = ((DC_LOBE[d.window] || 2) + 0.5) * d.rbw;
    let peak = -1;
    for (let i = 0; i < d.values.length; i++) {
      const f = d.f0 + i * d.df;
      if (f < Math.max(v[0], dcLimit) || f > v[1]) continue;
      if (peak < 0 || d.values[i] > d.values[peak]) peak = i;
    }
    let peakText = "";
    if (peak >= 0) {
      const fp = d.f0 + peak * d.df;
      const x = this.xOf(fp, v, g), y = yOf(d.values[peak]);
      ctx.fillStyle = "#fff";
      ctx.beginPath();
      ctx.moveTo(x, y - 4); ctx.lineTo(x - 5, y - 12); ctx.lineTo(x + 5, y - 12);
      ctx.closePath();
      ctx.fill();
      peakText = "peak " + eng(fp, "Hz") + " " +
        (dB ? d.values[peak].toFixed(2) + " dBV" : eng(d.values[peak], "V"));
    }
    ctx.restore();

    ctx.fillStyle = COLOUR;
    const head = d.label + "   RBW " + eng(d.rbw, "Hz") + "   " +
      (dB ? DB_TOP + " dBV top, " + DB_PER_DIV + " dB/div" : eng(top, "V") + " top");
    ctx.fillText(head, g.L, 16);
    ctx.fillStyle = "#d8d8d8";
    ctx.fillText(peakText, g.L + g.W - ctx.measureText(peakText).width, 16);
    ctx.fillText(eng(v[0], "Hz") + " .. " + eng(v[1], "Hz") + (this.log ? " (log)" : "") +
                 "   wheel or pinch zooms, drag pans, double-click shows all",
                 g.L, g.T + g.H + 16);
  }

  setRange(lo, hi) {
    const [flo, fhi] = this.full || [lo, hi];
    const span = Math.max(hi - lo, (fhi - flo) / 1e6);
    lo = Math.max(flo, Math.min(lo, fhi - span));
    this.range = [lo, Math.min(fhi, lo + span)];
    this.redraw();
  }

  showAll() {
    if (!this.full) return;
    this.range = null;
    this.redraw();
  }

  listen() {
    const c = this.canvas;
    const xIn = (e) => e.clientX - c.getBoundingClientRect().left;
    const zoom = (x, factor) => {
      if (!this.data) return;
      const g = this.geometry(), v = this.view();
      const f = this.fOf(x, v, g);
      if (this.log) {
        this.setRange(f * Math.pow(v[0] / f, factor), f * Math.pow(v[1] / f, factor));
      } else {
        this.setRange(f - (f - v[0]) * factor, f + (v[1] - f) * factor);
      }
    };
    c.addEventListener("wheel", (e) => {
      e.preventDefault();
      zoom(xIn(e), e.deltaY < 0 ? 0.8 : 1.25);
    }, { passive: false });
    c.addEventListener("dblclick", () => this.showAll());
    c.addEventListener("pointerdown", (e) => {
      c.setPointerCapture(e.pointerId);
      this.pointers.set(e.pointerId, xIn(e));
      this.drag = { x: xIn(e), view: this.view() };
    });
    c.addEventListener("pointermove", (e) => {
      if (!this.pointers.has(e.pointerId) || !this.data) return;
      const before = [...this.pointers.values()];
      this.pointers.set(e.pointerId, xIn(e));
      const g = this.geometry();
      if (this.pointers.size === 2) {
        const after = [...this.pointers.values()];
        const d0 = Math.abs(before[0] - before[1]), d1 = Math.abs(after[0] - after[1]);
        if (d0 > 10 && d1 > 10) zoom((after[0] + after[1]) / 2, d0 / d1);
        return;
      }
      const v = this.drag.view;
      const shift = (this.drag.x - xIn(e)) / g.W;
      if (this.log) {
        const k = Math.pow(v[1] / v[0], shift);
        this.setRange(v[0] * k, v[1] * k);
      } else {
        this.setRange(v[0] + shift * (v[1] - v[0]), v[1] + shift * (v[1] - v[0]));
      }
    });
    const end = (e) => this.pointers.delete(e.pointerId);
    c.addEventListener("pointerup", end);
    c.addEventListener("pointercancel", end);
    c.style.touchAction = "none";
  }
}
