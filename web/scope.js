// The scope display of the browser client: live frames, captures with
// zoom and pan, the math trace, references, cursors, decoded bus items
// and XY.  Like the desktop GUI's display (gui/src/scope_view.adb).
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

import { COLOURS, MATH_COLOUR, REF_COLOURS, eng, floats, volts } from "./util.js";

const SCREEN_POINTS = 1200;   // the scope's screen, 12 divisions across
const MAX_COLUMNS = 10000;
const CURSOR_COLOURS = { 0: "#ff8c33", 1: "#cc80ff" };

export class ScopeView {
  constructor(canvas, conn) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.conn = conn;
    this.status = null;
    this.mode = "live";
    this.xy = false;
    this.frames = { 1: null, 2: null };
    this.math = { mode: "off", op: "add", scale: 1, offset: 0, live: null,
                  cols: null, first: 0, last: 0, pending: false, dirty: false };
    this.refs = {};
    this.refsOn = true;
    this.decoded = [];
    this.lanes = {};
    this.cursors = { on: false, t: [0, 0], samples: [{}, {}], drag: -1 };
    this.cap = { total: 0, xInc: 1, xOrigin: 0, first: 0, last: 0, chans: {} };
    this.hover = null;
    this.pointers = new Map();
    this.pan = null;
    this.scheduled = false;
    this.onCursors = null;   // called when the cursor readout changes

    new ResizeObserver(() => { this.requestViews(); this.redraw(); }).observe(canvas);
    this.listen();
    this.touchMode();
  }

  // -------------------------------------------------------------------------
  //  Settings and data
  // -------------------------------------------------------------------------

  setStatus(s) {
    this.status = s;
    this.redraw();
  }

  channel(ch) {
    return this.status ? this.status.channels.find((c) => c.ch === ch) : null;
  }

  // Where Ch's trace is placed: its settings now, or at capture time
  placement(ch) {
    const c = this.channel(ch);
    const k = this.cap.chans[ch];
    if (this.mode === "capture" && k && k.captured) return { scale: k.scale, offset: k.offset };
    return c ? { scale: c.scale, offset: c.offset } : { scale: 1, offset: 0 };
  }

  liveFrame(ch, info, raw) {
    this.frames[ch] = { info, raw };
    if (this.mode === "live") this.redraw();
  }

  setMath(mode, op, scale, offset) {
    const changed = mode !== this.math.mode || op !== this.math.op;
    Object.assign(this.math, { mode, op, scale: Math.max(1e-12, scale), offset });
    if (changed) {
      this.math.live = null;
      this.math.cols = null;
      if (this.mode === "capture") this.requestMathView();
    }
    this.redraw();
  }

  // A live "math" event, of the kind of math shown
  mathFrame(info, payload) {
    if (this.math.mode === "off" || (info.source === "scope") !== (this.math.mode === "scope")) return;
    this.math.live = { info, values: floats(payload) };
    if (this.mode === "live") this.redraw();
  }

  // Touch gestures on the display only where they do something; else a
  // finger scrolls the page (on a phone the controls are below)
  touchMode() {
    this.canvas.style.touchAction =
      this.mode === "capture" || this.cursors.on ? "none" : "pan-y";
  }

  setMode(mode) {
    this.mode = mode;
    this.hover = null;
    this.touchMode();
    if (mode === "capture") {
      this.requestViews();
      this.requestCursorSamples();
    }
    this.redraw();
  }

  setXY(on) {
    this.xy = on;
    this.redraw();
  }

  clearCaptures() {
    this.cap.chans = {};
    this.cap.total = 0;
    this.math.cols = null;
    this.cursors.samples = [{}, {}];
    this.redraw();
  }

  // A "capture" reply: Ch's memory is in the server
  captured(ch, info) {
    const first = this.cap.total === 0;
    const place = this.channel(ch) || { scale: 1, offset: 0 };
    this.cap.chans[ch] = { captured: true, info, scale: place.scale, offset: place.offset,
                           cols: null, count: 0, colFirst: 0, colLast: 0,
                           pending: false, dirty: false };
    this.cap.total = info.points;
    this.cap.xInc = info.x_inc;
    this.cap.xOrigin = info.x_origin;
    if (first) {
      this.cap.first = 0;
      this.cap.last = info.points - 1;
    }
    this.requestView(ch);
    this.requestCursorSamples();
    this.redraw();
  }

  isCaptured(ch) {
    return !!(this.cap.chans[ch] && this.cap.chans[ch].captured);
  }

  viewRange() {
    return [this.cap.first, this.cap.last];
  }

  // -------------------------------------------------------------------------
  //  Capture views: at most one request per channel at a time
  // -------------------------------------------------------------------------

  plotWidth() {
    return Math.max(1, Math.min(MAX_COLUMNS, Math.floor(this.canvas.clientWidth - 16)));
  }

  requestView(ch) {
    const k = this.cap.chans[ch];
    if (!k || !k.captured || this.cap.total === 0 || this.mode !== "capture") return;
    if (k.pending) {
      k.dirty = true;
      return;
    }
    const first = this.cap.first, last = this.cap.last;
    k.pending = true;
    this.conn.request("view", { ch, first, last, columns: this.plotWidth() })
      .then(({ reply, payload }) => {
        k.cols = payload;
        k.count = reply.columns;
        k.colFirst = first;
        k.colLast = last;
      })
      .catch(() => {})
      .finally(() => {
        k.pending = false;
        if (k.dirty) {
          k.dirty = false;
          this.requestView(ch);
        }
        this.redraw();
      });
  }

  requestMathView() {
    const m = this.math;
    if (m.mode !== "pc" || m.op === "div" || this.mode !== "capture" ||
        !this.isCaptured(1) || !this.isCaptured(2)) return;
    if (m.pending) {
      m.dirty = true;
      return;
    }
    const first = this.cap.first, last = this.cap.last;
    m.pending = true;
    this.conn.request("math_view", { operator: m.op, first, last, columns: this.plotWidth() })
      .then(({ payload }) => {
        m.cols = floats(payload);
        m.first = first;
        m.last = last;
      })
      .catch(() => {})
      .finally(() => {
        m.pending = false;
        if (m.dirty) {
          m.dirty = false;
          this.requestMathView();
        }
        this.redraw();
      });
  }

  requestViews() {
    for (const ch of [1, 2]) this.requestView(ch);
    this.requestMathView();
  }

  // Show samples first .. first + span - 1, clamped to the capture
  showSamples(first, span) {
    const total = this.cap.total;
    if (total === 0) return;
    const s = Math.max(10, Math.min(span, total));
    const f = Math.max(0, Math.min(first, total - s));
    this.cap.first = Math.floor(f);
    this.cap.last = Math.min(total - 1, this.cap.first + Math.floor(s) - 1);
    this.requestViews();
    this.redraw();
  }

  showAll() {
    this.showSamples(0, this.cap.total);
  }

  // Samples first .. last centred, with some around them: the view spans
  // times their length
  zoomTo(first, last, times = 12) {
    const n = last - first + 1;
    const span = Math.max(n * times, 200);
    this.showSamples(first + n / 2 - span / 2, span);
  }

  // -------------------------------------------------------------------------
  //  Time and cursors
  // -------------------------------------------------------------------------

  // Times at the left and right edge of the plot
  window() {
    if (this.mode === "capture" && this.cap.total > 0) {
      return [this.cap.xOrigin + this.cap.first * this.cap.xInc,
              this.cap.xOrigin + (this.cap.last + 1) * this.cap.xInc];
    }
    for (const ch of [1, 2]) {
      const f = this.frames[ch], c = this.channel(ch);
      if (f && c && c.display) {
        return [f.info.x_origin, f.info.x_origin + (SCREEN_POINTS - 1) * f.info.x_inc];
      }
    }
    const tb = this.status ? this.status.timebase : { scale: 1e-3, offset: 0 };
    return [tb.offset - 6 * tb.scale, tb.offset + 6 * tb.scale];
  }

  setCursors(on) {
    this.cursors.on = on;
    this.touchMode();
    if (on) {
      const [t0, t1] = this.window();
      this.cursors.t = [t0 + (t1 - t0) / 3, t0 + (2 * (t1 - t0)) / 3];
      this.requestCursorSamples();
    }
    this.redraw();
  }

  sampleAt(t) {
    return Math.max(0, Math.min(this.cap.total - 1,
                                Math.round((t - this.cap.xOrigin) / this.cap.xInc)));
  }

  // In capture mode the exact sample under each cursor, fetched when it
  // moves; one request per cursor and channel at a time
  requestCursorSamples() {
    if (!this.cursors.on || this.mode !== "capture" || this.cap.total === 0) return;
    for (const c of [0, 1]) {
      for (const ch of [1, 2]) {
        if (!this.isCaptured(ch)) continue;
        const index = this.sampleAt(this.cursors.t[c]);
        const s = this.cursors.samples[c][ch] || (this.cursors.samples[c][ch] = {});
        if (s.index === index) continue;
        if (s.pending) {
          s.dirty = true;
          continue;
        }
        s.pending = true;
        this.conn.request("samples", { ch, first: index, last: index })
          .then(({ payload }) => {
            s.index = index;
            s.raw = payload[0];
          })
          .catch(() => {})
          .finally(() => {
            s.pending = false;
            if (s.dirty) {
              s.dirty = false;
              this.requestCursorSamples();
            }
            this.redraw();
          });
      }
    }
  }

  // Ch's voltage at cursor c, or null
  cursorVolts(c, ch) {
    const t = this.cursors.t[c];
    if (this.mode === "capture") {
      const k = this.cap.chans[ch];
      const s = this.cursors.samples[c][ch];
      if (!k || !s || s.index !== this.sampleAt(t)) return null;
      return volts(k.info, s.raw);
    }
    const f = this.frames[ch];
    if (!f) return null;
    const i = Math.round((t - f.info.x_origin) / f.info.x_inc);
    return i >= 0 && i < f.raw.length ? volts(f.info, f.raw[i]) : null;
  }

  // -------------------------------------------------------------------------
  //  References and decoded items
  // -------------------------------------------------------------------------

  setRef(slot, info, raw) {
    this.refs[slot] = { info, raw };
    this.redraw();
  }

  clearRefs() {
    this.refs = {};
    this.redraw();
  }

  setRefsShown(on) {
    this.refsOn = on;
    this.redraw();
  }

  // Items of a "decode" reply, with their labels
  setDecoded(items, label) {
    this.decoded = [];
    this.lanes = {};
    let lanes = 0;
    for (const it of items) {
      if (!this.lanes[it.ch]) this.lanes[it.ch] = ++lanes;
      this.decoded.push({
        first: it.first, last: it.last, ch: it.ch,
        kind: it.type === "start" ? "S" : it.type === "stop" ? "P" : it.type === "address" ? "A" : "D",
        bad: "error" in it || it.ack === false,
        label: label(it),
      });
    }
    this.redraw();
  }

  clearDecoded() {
    this.decoded = [];
    this.redraw();
  }

  // -------------------------------------------------------------------------
  //  Drawing
  // -------------------------------------------------------------------------

  redraw() {
    if (this.scheduled) return;
    this.scheduled = true;
    const now = () => {
      if (!this.scheduled) return;
      this.scheduled = false;
      this.draw();
    };
    requestAnimationFrame(now);
    setTimeout(now, 250);   // a hidden tab runs no animation frames
  }

  geometry() {
    const w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    return { w, h, L: 8, T: 24, W: w - 16, H: h - 24 - 24 };
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
    if (g.W < 50 || g.H < 50) return;
    ctx.font = "12px ui-monospace, 'DejaVu Sans Mono', Menlo, monospace";

    if (this.mode === "live" && this.xy) {
      this.drawXY(g);
    } else {
      this.drawGraticule(g);
      ctx.save();
      ctx.beginPath();
      ctx.rect(g.L, g.T, g.W, g.H);
      ctx.clip();
      this.drawRefs(g);
      if (this.mode === "live") this.drawLive(g);
      else this.drawCapture(g);
      this.drawMath(g);
      if (this.mode === "capture") this.drawDecoded(g);
      if (this.mode === "capture" && this.hover !== null) {
        ctx.strokeStyle = "#aaa";
        ctx.setLineDash([3, 3]);
        ctx.beginPath();
        ctx.moveTo(Math.floor(this.hover) + 0.5, g.T);
        ctx.lineTo(Math.floor(this.hover) + 0.5, g.T + g.H);
        ctx.stroke();
        ctx.setLineDash([]);
      }
      if (this.cursors.on) this.drawCursorLines(g);
      ctx.restore();
      if (this.cursors.on) this.drawCursorReadout(g);
    }
    this.drawHeader(g);
    this.drawFooter(g);
  }

  drawGraticule({ L, T, W, H }) {
    const ctx = this.ctx;
    ctx.strokeStyle = "#555";
    ctx.lineWidth = 1;
    ctx.setLineDash([1, 4]);
    ctx.beginPath();
    for (let i = 1; i < 12; i++) {
      const x = Math.floor(L + (W * i) / 12) + 0.5;
      ctx.moveTo(x, T); ctx.lineTo(x, T + H);
    }
    for (let j = 1; j < 8; j++) {
      const y = Math.floor(T + (H * j) / 8) + 0.5;
      ctx.moveTo(L, y); ctx.lineTo(L + W, y);
    }
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.strokeRect(L + 0.5, T + 0.5, W - 1, H - 1);
  }

  yOf(v, place, { T, H }) {
    return T + H / 2 - ((v + place.offset) / place.scale) * (H / 8);
  }

  drawLive(g) {
    const ctx = this.ctx;
    for (const ch of [1, 2]) {
      const f = this.frames[ch], c = this.channel(ch);
      if (!f || !c || !c.display || f.raw.length < 2) continue;
      ctx.strokeStyle = COLOURS[ch];
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      for (let i = 0; i < f.raw.length; i++) {
        // Placed on the scope's 1200-point screen: at slow timebases the
        // scope sends a partly filled screen, from the left
        const x = g.L + (g.W * i) / (SCREEN_POINTS - 1);
        const y = this.yOf(volts(f.info, f.raw[i]), c, g);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
      ctx.stroke();
    }
    // Trigger level: a short line at the right edge
    const s = this.status;
    if (s) {
      const t = s.trigger;
      const src = t.mode === "pulse" && t.pulse ? t.pulse.source : t.source;
      const level = t.mode === "pulse" && t.pulse ? t.pulse.level : t.level;
      const ch = src === "ch1" ? 1 : src === "ch2" ? 2 : 0;
      const c = ch ? this.channel(ch) : null;
      if (c && c.display && t.mode !== "slope") {
        const y = this.yOf(level, c, g);
        ctx.strokeStyle = COLOURS[ch];
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(g.L + g.W - 14, y); ctx.lineTo(g.L + g.W, y);
        ctx.stroke();
      }
    }
  }

  drawCapture(g) {
    const ctx = this.ctx;
    const span = this.cap.last - this.cap.first + 1;
    const xOf = (sample) => g.L + (g.W * (sample - this.cap.first)) / span;
    for (const ch of [1, 2]) {
      const k = this.cap.chans[ch];
      if (!k || !k.captured || !k.cols || k.count === 0) continue;
      const n = k.colLast - k.colFirst + 1;
      const y = (raw) => this.yOf(volts(k.info, raw), k, g);
      ctx.strokeStyle = COLOURS[ch];
      ctx.beginPath();
      if (k.count < g.W / 3) {
        // Few samples: join them, and mark each when there is room
        ctx.lineWidth = 1.5;
        for (let i = 0; i < k.count; i++) {
          const x = xOf(k.colFirst + (i * n) / k.count);
          if (i === 0) ctx.moveTo(x, y(k.cols[2 * i])); else ctx.lineTo(x, y(k.cols[2 * i]));
        }
        ctx.stroke();
        if (k.count < g.W / 8) {
          ctx.fillStyle = COLOURS[ch];
          for (let i = 0; i < k.count; i++) {
            ctx.fillRect(xOf(k.colFirst + (i * n) / k.count) - 2, y(k.cols[2 * i]) - 2, 4, 4);
          }
        }
      } else {
        // A stroke per column from its lowest to its highest sample, so a
        // short glitch still shows
        ctx.lineWidth = 1;
        for (let i = 0; i < k.count; i++) {
          const x = Math.floor(xOf(k.colFirst + (i * n) / k.count)) + 0.5;
          ctx.moveTo(x, y(k.cols[2 * i]) + 0.5);
          ctx.lineTo(x, y(k.cols[2 * i + 1]) - 0.5);
        }
        ctx.stroke();
      }
    }
  }

  drawMath(g) {
    const m = this.math, ctx = this.ctx;
    if (m.mode === "off") return;
    const place = { scale: m.scale, offset: m.offset };
    ctx.strokeStyle = MATH_COLOUR;
    ctx.beginPath();
    if (this.mode === "live") {
      if (!m.live || m.live.values.length < 2) return;
      ctx.lineWidth = 1.5;
      const v = m.live.values;
      for (let i = 0; i < v.length; i++) {
        const x = g.L + (g.W * i) / (SCREEN_POINTS - 1);
        const y = this.yOf(v[i], place, g);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
    } else {
      if (!m.cols || m.cols.length < 2) return;
      const cols = m.cols.length / 2, n = m.last - m.first + 1;
      const span = this.cap.last - this.cap.first + 1;
      ctx.lineWidth = 1;
      for (let i = 0; i < cols; i++) {
        const sample = m.first + (i * n) / cols;
        const x = Math.floor(g.L + (g.W * (sample - this.cap.first)) / span) + 0.5;
        if (cols < g.W / 3) {
          if (i === 0) ctx.moveTo(x, this.yOf(m.cols[2 * i], place, g));
          else ctx.lineTo(x, this.yOf(m.cols[2 * i], place, g));
        } else {
          ctx.moveTo(x, this.yOf(m.cols[2 * i], place, g) + 0.5);
          ctx.lineTo(x, this.yOf(m.cols[2 * i + 1], place, g) - 0.5);
        }
      }
    }
    ctx.stroke();
  }

  // References at their own times, in volts like their channel now
  drawRefs(g) {
    if (!this.refsOn) return;
    const ctx = this.ctx;
    const [t0, t1] = this.window();
    if (!(t1 > t0)) return;
    for (const slot of Object.keys(this.refs)) {
      const r = this.refs[slot];
      const n = r.raw.length;
      if (n < 2) continue;
      const place = this.placement(r.info.ch >= 1 && r.info.ch <= 2 ? r.info.ch : 1);
      const step = Math.max(1, Math.floor(n / (2 * g.W + 1)));
      ctx.strokeStyle = REF_COLOURS[slot];
      ctx.globalAlpha = 0.8;
      ctx.lineWidth = 1.2;
      ctx.beginPath();
      for (let i = 0; i < n; i += step) {
        const t = r.info.x_origin + i * r.info.x_inc;
        const x = g.L + (g.W * (t - t0)) / (t1 - t0);
        const y = this.yOf(volts(r.info, r.raw[i]), place, g);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
  }

  drawDecoded(g) {
    if (this.decoded.length === 0 || this.cap.total === 0) return;
    const ctx = this.ctx;
    const span = this.cap.last - this.cap.first + 1;
    const xOf = (s) => g.L + (g.W * (s - this.cap.first)) / span;
    const boxH = 16;
    // The first item that may be in view: they are in order of first sample
    let lo = 0, hi = this.decoded.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.decoded[mid].last < this.cap.first) lo = mid + 1; else hi = mid;
    }
    ctx.lineWidth = 1;
    for (let k = Math.max(0, lo - 1); k < this.decoded.length; k++) {
      const it = this.decoded[k];
      if (it.first > this.cap.last) break;
      if (it.last < this.cap.first) continue;
      const x0 = Math.max(g.L - 2, xOf(it.first));
      const x1 = Math.min(g.L + g.W + 2, xOf(it.last + 1));
      const y = g.T + g.H - 6 - boxH - (this.lanes[it.ch] - 1) * (boxH + 4);
      if (it.kind === "S" || it.kind === "P") {
        ctx.strokeStyle = ctx.fillStyle = it.kind === "S" ? "#4dff59" : "#ff5959";
        ctx.beginPath();
        ctx.moveTo(Math.floor(x0) + 0.5, y);
        ctx.lineTo(Math.floor(x0) + 0.5, y + boxH);
        ctx.stroke();
        ctx.fillText(it.label, x0 + 2, y + 12);
        continue;
      }
      const tip = Math.min(4, (x1 - x0) / 2);
      ctx.beginPath();
      ctx.moveTo(x0, y + boxH / 2);
      ctx.lineTo(x0 + tip, y);
      ctx.lineTo(x1 - tip, y);
      ctx.lineTo(x1, y + boxH / 2);
      ctx.lineTo(x1 - tip, y + boxH);
      ctx.lineTo(x0 + tip, y + boxH);
      ctx.closePath();
      ctx.fillStyle = it.ch === 1 ? "rgba(90,80,0,0.9)" : "rgba(0,75,90,0.9)";
      ctx.fill();
      ctx.strokeStyle = it.bad ? "#ff4040" : COLOURS[it.ch];
      ctx.stroke();
      const w = ctx.measureText(it.label).width;
      if (x1 - x0 > w + 8) {
        ctx.fillStyle = it.bad ? "#ff8080" : "#e8e8e8";
        ctx.fillText(it.label, (x0 + x1 - w) / 2, y + 12);
      }
    }
  }

  drawXY(g) {
    const ctx = this.ctx;
    const side = Math.min(g.W, g.H);
    const x0 = g.L + (g.W - side) / 2, y0 = g.T + (g.H - side) / 2;
    ctx.strokeStyle = "#555";
    ctx.setLineDash([1, 4]);
    ctx.beginPath();
    for (let i = 1; i < 8; i++) {
      const p = Math.floor((side * i) / 8) + 0.5;
      ctx.moveTo(x0 + p, y0); ctx.lineTo(x0 + p, y0 + side);
      ctx.moveTo(x0, y0 + p); ctx.lineTo(x0 + side, y0 + p);
    }
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.strokeRect(x0 + 0.5, y0 + 0.5, side - 1, side - 1);
    const a = this.frames[1], b = this.frames[2], ca = this.channel(1), cb = this.channel(2);
    if (!a || !b || !ca || !cb || !ca.display || !cb.display) {
      ctx.fillStyle = "#ccc";
      ctx.fillText("XY needs both channels on", x0 + 12, y0 + 24);
      return;
    }
    ctx.fillStyle = "#66ff66";
    const n = Math.min(a.raw.length, b.raw.length);
    for (let i = 0; i < n; i++) {
      const x = x0 + side / 2 + ((volts(a.info, a.raw[i]) + ca.offset) / ca.scale) * (side / 8);
      const y = y0 + side / 2 - ((volts(b.info, b.raw[i]) + cb.offset) / cb.scale) * (side / 8);
      ctx.fillRect(x - 1, y - 1, 2, 2);
    }
  }

  drawCursorLines(g) {
    const ctx = this.ctx;
    const [t0, t1] = this.window();
    for (const c of [0, 1]) {
      const x = g.L + (g.W * (this.cursors.t[c] - t0)) / (t1 - t0);
      if (x < g.L || x > g.L + g.W) continue;
      ctx.strokeStyle = ctx.fillStyle = CURSOR_COLOURS[c];
      ctx.lineWidth = 1;
      ctx.setLineDash([6, 4]);
      ctx.beginPath();
      ctx.moveTo(Math.floor(x) + 0.5, g.T);
      ctx.lineTo(Math.floor(x) + 0.5, g.T + g.H);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillText(c === 0 ? "A" : "B", x + 4, g.T + g.H - 6);
    }
  }

  cursorLines() {
    const [ta, tb] = this.cursors.t;
    const dt = tb - ta;
    const lines = [
      { text: "A " + eng(ta, "s") + "   B " + eng(tb, "s"), colour: "#ddd" },
      { text: "ΔT " + eng(dt, "s") + (dt !== 0 ? "   1/ΔT " + eng(1 / Math.abs(dt), "Hz") : ""),
        colour: "#ddd" },
    ];
    for (const ch of [1, 2]) {
      const shown = this.mode === "capture" ? this.isCaptured(ch)
        : this.frames[ch] && this.channel(ch) && this.channel(ch).display;
      if (!shown) continue;
      const va = this.cursorVolts(0, ch), vb = this.cursorVolts(1, ch);
      lines.push({
        text: "CH" + ch + "  A " + (va === null ? "..." : eng(va, "V")) +
          "  B " + (vb === null ? "..." : eng(vb, "V")) +
          (va !== null && vb !== null ? "  ΔV " + eng(vb - va, "V") : ""),
        colour: COLOURS[ch],
      });
    }
    return lines;
  }

  drawCursorReadout(g) {
    const ctx = this.ctx;
    const lines = this.cursorLines();
    const w = Math.max(...lines.map((l) => ctx.measureText(l.text).width));
    ctx.fillStyle = "rgba(0,0,0,0.75)";
    ctx.fillRect(g.L + 6, g.T + 6, w + 12, 16 * lines.length + 8);
    lines.forEach((l, i) => {
      ctx.fillStyle = l.colour;
      ctx.fillText(l.text, g.L + 12, g.T + 20 + 16 * i);
    });
  }

  drawHeader(g) {
    const ctx = this.ctx, s = this.status;
    ctx.textBaseline = "alphabetic";
    if (!s) {
      ctx.fillStyle = "#888";
      ctx.fillText("waiting for the scope ...", g.L, 16);
      return;
    }
    const status = this.mode === "capture" ? "CAPTURE" : s.trigger_status.toUpperCase();
    const perDiv = this.mode === "capture"
      ? ((this.cap.last - this.cap.first + 1) * this.cap.xInc) / 12 : s.timebase.scale;
    const parts = (full) => {
      const p = [];
      for (const ch of [1, 2]) {
        const shown = this.mode === "capture" ? this.isCaptured(ch) : this.channel(ch).display;
        if (shown) {
          p.push({ colour: COLOURS[ch],
                   text: (full ? "CH" + ch + " " : "") + eng(this.placement(ch).scale, "V") +
                     (full ? "/div" : "") });
        }
      }
      if (this.refsOn) {
        for (const slot of Object.keys(this.refs)) p.push({ colour: REF_COLOURS[slot], text: "R" + slot });
      }
      if (this.math.mode !== "off" && full) {
        const sym = { add: "A+B", sub: "A-B", mul: "AxB", div: "A/B" }[this.math.op] || "";
        p.push({ colour: MATH_COLOUR, text: "MATH " + sym + " " + eng(this.math.scale, "") + "/div" +
                 (this.math.mode === "pc" ? " (PC)" : "") });
      }
      p.push({ colour: "#d8d8d8",
               text: this.mode === "live" && this.xy ? "XY  (X = CH1, Y = CH2)"
                 : (full ? "H " : "") + eng(perDiv, "s") + (full ? "/div" : "") });
      return p;
    };
    const width = (p) => p.reduce((sum, x) => sum + ctx.measureText(x.text).width + 14, 0);
    const room = g.W - ctx.measureText(status).width - 10;
    let x = g.L;
    for (const p of width(parts(true)) <= room ? parts(true) : parts(false)) {
      ctx.fillStyle = p.colour;
      ctx.fillText(p.text, x, 16);
      x += ctx.measureText(p.text).width + 14;
    }
    ctx.fillStyle = "#d8d8d8";
    ctx.fillText(status, g.L + g.W - ctx.measureText(status).width, 16);
  }

  // Capture mode: the range in view, or the pointer's time and volts
  drawFooter(g) {
    if (this.mode !== "capture" || this.cap.total === 0) return;
    const ctx = this.ctx;
    let text;
    if (this.hover !== null) {
      const frac = Math.max(0, Math.min(1, (this.hover - g.L) / g.W));
      const sample = this.cap.first + frac * (this.cap.last - this.cap.first + 1);
      text = "t = " + eng(this.cap.xOrigin + sample * this.cap.xInc, "s");
      for (const ch of [1, 2]) {
        const k = this.cap.chans[ch];
        if (!k || !k.cols || k.count === 0) continue;
        const i = Math.floor(((sample - k.colFirst) * k.count) / (k.colLast - k.colFirst + 1));
        if (i < 0 || i >= k.count) continue;
        const lo = volts(k.info, k.cols[2 * i]), hi = volts(k.info, k.cols[2 * i + 1]);
        text += "   CH" + ch + " " + (hi - lo < k.info.y_inc / 2 ? eng(lo, "V")
                                                           : eng(lo, "V") + " .. " + eng(hi, "V"));
      }
    } else {
      const t0 = this.cap.xOrigin + this.cap.first * this.cap.xInc;
      const t1 = this.cap.xOrigin + this.cap.last * this.cap.xInc;
      text = eng(t0, "s") + " .. " + eng(t1, "s") + "   (" + (this.cap.last - this.cap.first + 1) +
        " of " + this.cap.total + " samples; wheel or pinch zooms, drag pans, double-click shows all)";
    }
    ctx.fillStyle = "#d8d8d8";
    ctx.fillText(text, g.L, g.T + g.H + 17);
  }

  // -------------------------------------------------------------------------
  //  Mouse and touch
  // -------------------------------------------------------------------------

  listen() {
    const c = this.canvas;
    const xIn = (e) => e.clientX - c.getBoundingClientRect().left;

    c.addEventListener("wheel", (e) => {
      if (this.mode !== "capture" || this.cap.total === 0) return;
      e.preventDefault();
      this.zoomAround(xIn(e), e.deltaY < 0 ? 0.8 : 1.25);
    }, { passive: false });

    c.addEventListener("dblclick", () => {
      if (this.mode === "capture") this.showAll();
    });

    c.addEventListener("pointerdown", (e) => {
      c.setPointerCapture(e.pointerId);
      this.pointers.set(e.pointerId, xIn(e));
      if (this.pointers.size === 2) {
        const [a, b] = [...this.pointers.values()];
        this.pinch = { distance: Math.abs(a - b), first: this.cap.first,
                       span: this.cap.last - this.cap.first + 1, centre: (a + b) / 2 };
        this.pan = null;
        this.cursors.drag = -1;
        return;
      }
      const g = this.geometry(), x = xIn(e);
      if (this.cursors.on) {
        const [t0, t1] = this.window();
        for (const k of [0, 1]) {
          const cx = g.L + (g.W * (this.cursors.t[k] - t0)) / (t1 - t0);
          if (Math.abs(x - cx) <= (e.pointerType === "touch" ? 16 : 6)) {
            this.cursors.drag = k;
            return;
          }
        }
      }
      if (this.mode === "capture" && this.cap.total > 0) {
        this.pan = { x, first: this.cap.first };
      }
    });

    c.addEventListener("pointermove", (e) => {
      const g = this.geometry(), x = xIn(e);
      if (this.pointers.has(e.pointerId)) this.pointers.set(e.pointerId, x);
      if (this.pinch && this.pointers.size === 2) {
        const [a, b] = [...this.pointers.values()];
        const d = Math.max(10, Math.abs(a - b));
        const span = (this.pinch.span * this.pinch.distance) / d;
        const frac = (this.pinch.centre - g.L) / g.W;
        const anchor = this.pinch.first + frac * this.pinch.span;
        this.showSamples(anchor - frac * span, span);
        return;
      }
      if (this.cursors.drag >= 0) {
        const [t0, t1] = this.window();
        this.cursors.t[this.cursors.drag] = t0 + (t1 - t0) * Math.max(0, Math.min(1, (x - g.L) / g.W));
        this.requestCursorSamples();
        this.redraw();
        return;
      }
      if (this.pan) {
        const span = this.cap.last - this.cap.first + 1;
        this.showSamples(this.pan.first + ((this.pan.x - x) / g.W) * span, span);
        return;
      }
      if (this.mode === "capture" && e.pointerType !== "touch") {
        this.hover = x >= g.L && x <= g.L + g.W ? x : null;
        this.redraw();
      }
    });

    const end = (e) => {
      this.pointers.delete(e.pointerId);
      if (this.pointers.size < 2) this.pinch = null;
      this.pan = null;
      this.cursors.drag = -1;
    };
    c.addEventListener("pointerup", end);
    c.addEventListener("pointercancel", end);
    c.addEventListener("pointerleave", () => {
      if (this.hover !== null) {
        this.hover = null;
        this.redraw();
      }
    });
  }

  // Zoom by factor around the pointer at x
  zoomAround(x, factor) {
    const g = this.geometry();
    const frac = Math.max(0, Math.min(1, (x - g.L) / g.W));
    const span = this.cap.last - this.cap.first + 1;
    const anchor = this.cap.first + frac * span;
    this.showSamples(anchor - frac * span * factor, span * factor);
  }
}
