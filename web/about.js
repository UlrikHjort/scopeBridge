// The About box: the name, the version, who made it, the licence and a link
// to the project, over a small scope screen doing the scope's classic
// trick: a running sine that turns into a Lissajous figure and back. The
// same as the GTK GUI's About box.
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

import { $ } from "./util.js";

const TWO_PI = 2 * Math.PI;
const CYCLE = 12;          // s: YT, a morph into XY, the figure turning, back
const FRAME_MS = 33;       // about 30 frames a second

// 0 .. 1, easing in and out
const smooth = (x) => x * x * (3 - 2 * x);

// How far into XY the screen is, 0 (YT) .. 1 (XY), at t seconds
function morph(t) {
  const c = t - CYCLE * Math.floor(t / CYCLE);
  if (c < 4) return 0;
  if (c < 6) return smooth((c - 4) / 2);
  if (c < 10) return 1;
  return 1 - smooth((c - 10) / 2);
}

export class AboutBox {
  constructor() {
    this.dialog = $("about");
    this.canvas = $("about-screen");
    this.timer = null;
    $("about-open").addEventListener("click", () => this.open());
    // Close, Escape, or a click outside the box
    this.dialog.addEventListener("close", () => this.stop());
    this.dialog.addEventListener("click", (e) => {
      if (e.target === this.dialog) this.dialog.close();
    });
  }

  // The server's version, from its hello
  setVersion(version) {
    $("about-version").textContent = version ? "Version " + version : "";
  }

  open() {
    this.dialog.showModal();
    this.started = performance.now();
    this.draw();
    this.timer = setInterval(() => this.draw(), FRAME_MS);
  }

  stop() {
    clearInterval(this.timer);
    this.timer = null;
  }

  draw() {
    const canvas = this.canvas;
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (w === 0) return;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    const g = canvas.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    const t = (performance.now() - this.started) / 1000;
    const m = morph(t);

    g.fillStyle = "#000";
    g.fillRect(0, 0, w, h);

    // The graticule: 10 x 8 divisions, dotted, as on the scope display
    g.strokeStyle = "#555";
    g.lineWidth = 1;
    g.setLineDash([1, 3]);
    g.beginPath();
    for (let i = 1; i < 10; i++) {
      const x = Math.floor(w * i / 10) + 0.5;
      g.moveTo(x, 0);
      g.lineTo(x, h);
    }
    for (let i = 1; i < 8; i++) {
      const y = Math.floor(h * i / 8) + 0.5;
      g.moveTo(0, y);
      g.lineTo(w, y);
    }
    g.stroke();
    g.setLineDash([]);
    g.strokeRect(0.5, 0.5, w - 1, h - 1);

    // The running sine (YT) and the Lissajous figure (XY, 3:2, its phase
    // drifting so that it seems to turn), blended
    const phase = TWO_PI * 0.6 * t, drift = TWO_PI * 0.08 * t;
    const amp = 0.35 * h, r = 0.36 * Math.min(w, h);
    const trace = () => {
      g.beginPath();
      for (let k = 0; k <= 400; k++) {
        const s = k / 400;
        const ytX = w * s, ytY = h / 2 - amp * Math.sin(TWO_PI * 2 * s + phase);
        const xyX = w / 2 + r * Math.sin(TWO_PI * 3 * s + drift);
        const xyY = h / 2 - r * Math.sin(TWO_PI * 2 * s);
        const x = (1 - m) * ytX + m * xyX, y = (1 - m) * ytY + m * xyY;
        if (k === 0) g.moveTo(x, y); else g.lineTo(x, y);
      }
    };
    // In CH1's yellow, with a phosphor glow: wide and faint under narrow
    // and bright
    g.lineJoin = "round";
    for (const [width, colour] of [[7, "rgba(255, 230, 0, 0.12)"], [3.5, "rgba(255, 230, 0, 0.25)"],
                                   [1.4, "rgb(255, 235, 77)"]]) {
      trace();
      g.lineWidth = width;
      g.strokeStyle = colour;
      g.stroke();
    }

    // The readouts: the channel, and the mode it is in
    g.font = "11px ui-monospace, 'DejaVu Sans Mono', monospace";
    g.fillStyle = "#ffe600";
    g.fillText("CH1", 6, 14);
    g.fillStyle = "#d9d9d9";
    g.fillText(m < 0.5 ? "YT" : "XY", w - 22, 14);
  }
}
