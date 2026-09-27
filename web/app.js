// The browser client of scopebridge-server: the scope's controls, live view and
// captures, math and FFT, cursors, bus decoding, references, pass/fail,
// setups and files, over the protocol of docs/PROTOCOL.md.
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

import { Connection } from "./conn.js";
import { DecodePanel } from "./decode.js";
import { TimingPanel } from "./timing.js";
import { ScopeView } from "./scope.js";
import { SpectrumView } from "./spectrum.js";
import {
  $, download, eng, fillSelect, floats, fromBase64, nearest, num, pickFile, show,
  stamp, steps125, toBase64, volts,
} from "./util.js";

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

const LIVE_INTERVAL_MS = 100;
const STATUS_INTERVAL_MS = 1500;
const MAX_EXPORT = 2000000;   // samples per channel

const VOLT_STEPS = steps125(1e-3, 100);
const TIME_STEPS = steps125(5e-9, 50);
const TRIGGER_TIMES = steps125(1e-8, 10);
const MATH_SCALES = steps125(1e-3, 1000);
const PROBES = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000];
const AVERAGES = [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024];
const DEPTHS = {
  single: [12000, 120000, 1200000, 12000000, 24000000],
  dual: [6000, 60000, 600000, 6000000, 12000000],
};
const PULSE_WHENS = [
  ["pos_greater", "+ > width"], ["pos_less", "+ < width"], ["neg_greater", "- > width"],
  ["neg_less", "- < width"], ["pos_in_range", "+ in range"], ["neg_in_range", "- in range"],
];
const SLOPE_WHENS = [
  ["pos_greater", "rise > time"], ["pos_less", "rise < time"], ["neg_greater", "fall > time"],
  ["neg_less", "fall < time"], ["pos_in_range", "rise in range"], ["neg_in_range", "fall in range"],
];

// Measurement items: protocol name, label, unit
const ITEMS = [
  ["freq", "Frequency", "Hz"], ["period", "Period", "s"], ["vpp", "Vpp", "V"],
  ["vmax", "Vmax", "V"], ["vmin", "Vmin", "V"], ["vtop", "Vtop", "V"],
  ["vbase", "Vbase", "V"], ["vamp", "Vamp", "V"], ["vavg", "Vavg", "V"],
  ["vrms", "Vrms", "V"], ["rise", "Rise time", "s"], ["fall", "Fall time", "s"],
  ["pwidth", "+Width", "s"], ["nwidth", "-Width", "s"],
  ["pduty", "+Duty", "%"], ["nduty", "-Duty", "%"],
];
const DEFAULT_SLOTS = ["freq", "period", "vpp", "vrms", "vavg"];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const state = {
  status: null,
  dual: false,            // both channels on: the two-channel depths
  statusPending: false,
  capturing: false,
  scopeMathOn: false,     // we switched the scope's math channel on
  recording: null,        // { items, rows, start }
};

let messageTimer = null;

function say(text, isError = false) {
  const bar = $("status");
  bar.textContent = text;
  bar.classList.toggle("error", isError);
  clearTimeout(messageTimer);
  if (isError) messageTimer = setTimeout(() => say(""), 8000);
}

function fail(e) {
  say("Error: " + e.message, true);
}

const conn = new Connection(onEvent, onState);
const scope = new ScopeView($("scope"), conn);
const spectrum = new SpectrumView($("spectrum"));
const decode = new DecodePanel(conn, scope, say);
const timing = new TimingPanel(conn, scope, say);

// Send a setting; afterwards read the settings back (the scope may round)
function set(cmd, members) {
  return conn.request(cmd, members)
    .then((r) => { refreshStatus(); return r; })
    .catch((e) => { fail(e); refreshStatus(); });
}

function channelSettings(ch) {
  return state.status ? state.status.channels.find((c) => c.ch === ch) : null;
}

function channelBox(ch) {
  return document.querySelector(`.channel[data-ch="${ch}"]`);
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

function buildControls() {
  for (const ch of [1, 2]) {
    const box = channelBox(ch);
    fillSelect(box.querySelector(".ch-scale"), VOLT_STEPS, (v) => eng(v, "V") + "/div");
    fillSelect(box.querySelector(".ch-probe"), PROBES, (v) => v + "x");
    box.querySelector(".ch-on").addEventListener("change", (e) =>
      set("set_channel", { ch, display: e.target.checked }));
    box.querySelector(".ch-scale").addEventListener("change", (e) =>
      set("set_channel", { ch, scale: Number(e.target.value) }));
    box.querySelector(".ch-position").addEventListener("change", (e) => {
      const c = channelSettings(ch);
      if (c) set("set_channel", { ch, offset: Number(e.target.value) * c.scale });
    });
    box.querySelector(".ch-coupling").addEventListener("change", (e) =>
      set("set_channel", { ch, coupling: e.target.value }));
    box.querySelector(".ch-probe").addEventListener("change", (e) =>
      set("set_channel", { ch, probe: Number(e.target.value) }));
  }

  fillSelect($("tb-scale"), TIME_STEPS, (v) => eng(v, "s") + "/div");
  $("tb-scale").addEventListener("change", (e) =>
    set("set_timebase", { scale: Number(e.target.value) }));
  $("tb-position").addEventListener("change", (e) => {
    const s = state.status;
    if (s) set("set_timebase", { offset: Number(e.target.value) * s.timebase.scale });
  });

  // Trigger: the edge trigger's settings, and those of pulse and slope
  $("trig-mode").addEventListener("change", (e) => {
    showTriggerMode(e.target.value);
    set("set_trigger", { mode: e.target.value });
  });
  for (const [id, name] of [["trig-source", "source"], ["trig-slope", "slope"], ["trig-sweep", "sweep"]]) {
    $(id).addEventListener("change", (e) => set("set_trigger", { [name]: e.target.value }));
  }
  $("trig-level").addEventListener("change", (e) => set("set_trigger", { level: Number(e.target.value) }));
  fillSelect($("pulse-when"), PULSE_WHENS);
  fillSelect($("slope-when"), SLOPE_WHENS);
  for (const id of ["pulse-width", "pulse-lower", "pulse-upper", "slope-time", "slope-lower", "slope-upper"]) {
    fillSelect($(id), TRIGGER_TIMES, (v) => eng(v, "s"));
  }
  const detail = (group, name, numeric) => (e) =>
    set("set_trigger", { [group]: { [name]: numeric ? Number(e.target.value) : e.target.value } });
  for (const [id, name, numeric] of [["pulse-source", "source"], ["pulse-when", "when"],
                                     ["pulse-width", "width", 1], ["pulse-lower", "lower", 1],
                                     ["pulse-upper", "upper", 1], ["pulse-level", "level", 1]]) {
    $(id).addEventListener("change", detail("pulse", name, numeric));
  }
  for (const [id, name, numeric] of [["slope-source", "source"], ["slope-when", "when"],
                                     ["slope-time", "time", 1], ["slope-lower", "lower", 1],
                                     ["slope-upper", "upper", 1], ["slope-window", "window"],
                                     ["slope-a", "level_a", 1], ["slope-b", "level_b", 1]]) {
    $(id).addEventListener("change", detail("slope_trigger", name, numeric));
  }

  // Acquisition
  for (const b of document.querySelectorAll("button[data-cmd]")) {
    b.addEventListener("click", () => set(b.dataset.cmd, {}));
  }
  fillSelect($("acq-averages"), AVERAGES);
  $("acq-type").addEventListener("change", (e) => set("set_acquire", { type: e.target.value }));
  $("acq-averages").addEventListener("change", (e) =>
    set("set_acquire", { averages: Number(e.target.value) }));
  fillDepths();
  $("acq-depth").addEventListener("change", (e) =>
    set("set_acquire", { memory_depth: Number(e.target.value) }));

  // Measurement slots: an item each, and its value
  const slots = $("meas-slots");
  for (let k = 0; k < 5; k++) {
    const row = document.createElement("div");
    row.className = "row";
    const select = document.createElement("select");
    select.className = "meas-item";
    fillSelect(select, [["", "-"], ...ITEMS.map((i) => [i[0], i[1]])]);
    select.value = DEFAULT_SLOTS[k];
    const value = document.createElement("span");
    value.className = "value";
    value.textContent = "-";
    row.append(select, value);
    slots.appendChild(row);
    select.addEventListener("change", startLive);
  }
  $("meas-ch").addEventListener("change", startLive);
  $("record").addEventListener("click", toggleRecording);

  // Capture and files
  $("capture").addEventListener("click", capture);
  $("live").addEventListener("click", goLive);
  $("export").addEventListener("click", exportCSV);
  $("screenshot").addEventListener("click", screenshot);
  $("setup-save").addEventListener("click", saveSetup);
  $("setup-load").addEventListener("click", loadSetup);

  // Display and cursors
  $("display-mode").addEventListener("change", (e) => {
    scope.setXY(e.target.value === "xy");
    const c1 = channelSettings(1), c2 = channelSettings(2);
    if (e.target.value === "xy" && !(c1 && c2 && c1.display && c2.display)) {
      say("XY plots CH1 against CH2: switch both channels on");
    }
  });
  $("cursors").addEventListener("change", (e) => scope.setCursors(e.target.checked));

  // Math and FFT
  fillSelect($("math-scale"), MATH_SCALES, (v) => eng(v, "") + "/div");
  $("math-scale").value = "1";
  $("math-mode").addEventListener("change", () => onMathChoice(true));
  $("math-op").addEventListener("change", () => onMathChoice(false));
  $("math-scale").addEventListener("change", onMathScale);
  $("math-position").addEventListener("change", onMathScale);
  for (const id of ["fft-mode", "fft-source", "fft-window", "fft-data"]) {
    $(id).addEventListener("change", (e) => onFFTChoice(id === "fft-mode" ? e.target.value : null));
  }
  $("fft-log").addEventListener("change", (e) => spectrum.setLog(e.target.checked));

  // References
  $("ref-save").addEventListener("click", () =>
    set("ref_save", { slot: refSlot(), ch: Number($("ref-source").value) }));
  $("ref-clear").addEventListener("click", () => set("ref_clear", { slot: refSlot() }));
  $("ref-export").addEventListener("click", exportReference);
  $("ref-import").addEventListener("click", importReference);
  $("ref-show").addEventListener("change", (e) => scope.setRefsShown(e.target.checked));

  // Pass/fail
  for (const b of document.querySelectorAll("button[data-mask]")) {
    b.addEventListener("click", () => onMask(b.dataset.mask));
  }
}

function fillDepths() {
  const list = state.dual ? DEPTHS.dual : DEPTHS.single;
  fillSelect($("acq-depth"), [0, ...list], (v) => (v === 0 ? "Auto" : eng(v, "pts")));
}

function showTriggerMode(mode) {
  $("trig-edge").hidden = mode !== "edge";
  $("trig-pulse").hidden = mode !== "pulse";
  $("trig-slope-box").hidden = mode !== "slope";
}

// ---------------------------------------------------------------------------
// Status: the scope's settings, into the controls
// ---------------------------------------------------------------------------

function applyStatus(s) {
  state.status = s;
  scope.setStatus(s);
  for (const c of s.channels) {
    const box = channelBox(c.ch);
    box.querySelector(".ch-on").checked = c.display;
    show(box.querySelector(".ch-scale"), VOLT_STEPS[nearest(VOLT_STEPS, c.scale)]);
    show(box.querySelector(".ch-position"), (c.offset / c.scale).toFixed(1));
    show(box.querySelector(".ch-coupling"), c.coupling);
    show(box.querySelector(".ch-probe"), PROBES[nearest(PROBES, c.probe)]);
  }
  show($("tb-scale"), TIME_STEPS[nearest(TIME_STEPS, s.timebase.scale)]);
  show($("tb-position"), (s.timebase.offset / s.timebase.scale).toFixed(1));

  const t = s.trigger;
  show($("trig-mode"), t.mode);
  showTriggerMode(t.mode);
  show($("trig-source"), t.source);
  show($("trig-slope"), t.slope);
  show($("trig-level"), t.level.toFixed(2));
  show($("trig-sweep"), t.sweep);
  const time = (x) => TRIGGER_TIMES[nearest(TRIGGER_TIMES, x)];
  if (t.pulse) {
    show($("pulse-source"), t.pulse.source);
    show($("pulse-when"), t.pulse.when);
    show($("pulse-width"), time(t.pulse.width));
    show($("pulse-lower"), time(t.pulse.lower));
    show($("pulse-upper"), time(t.pulse.upper));
    show($("pulse-level"), t.pulse.level.toFixed(2));
  }
  if (t.slope_trigger) {
    const l = t.slope_trigger;
    show($("slope-source"), l.source);
    show($("slope-when"), l.when);
    show($("slope-time"), time(l.time));
    show($("slope-lower"), time(l.lower));
    show($("slope-upper"), time(l.upper));
    show($("slope-window"), l.window);
    show($("slope-a"), l.level_a.toFixed(2));
    show($("slope-b"), l.level_b.toFixed(2));
  }

  if (s.acquire) {
    const a = s.acquire;
    const dual = s.channels.every((c) => c.display);
    if (dual !== state.dual) {
      state.dual = dual;
      fillDepths();
    }
    show($("acq-type"), a.type);
    show($("acq-averages"), a.averages);
    $("acq-averages").disabled = a.type !== "average";
    show($("acq-depth"), a.memory_depth);
    $("acq-rate").textContent = eng(a.sample_rate, "Sa/s");
  }

  if (s.mask) {
    const m = s.mask;
    $("mask-counts").textContent = !m.enable ? "Test off"
      : (m.running ? "Running: " : "Stopped: ") + "passed " + m.passed + ", failed " + m.failed +
        (m.total > 0 ? " (" + ((100 * m.failed) / m.total).toFixed(1) + " %)" : "");
  }

  // The scope's own math: its scale and position
  if ($("math-mode").value === "scope" && s.math) {
    show($("math-scale"), MATH_SCALES[nearest(MATH_SCALES, s.math.scale)]);
    show($("math-position"), (s.math.offset / s.math.scale).toFixed(1));
    applyMathView();
  }
}

function refreshStatus() {
  if (state.statusPending || state.capturing || !conn.isOpen) return;
  state.statusPending = true;
  conn.request("status")
    .then(({ reply }) => applyStatus(reply))
    .catch(fail)
    .finally(() => { state.statusPending = false; });
}

// ---------------------------------------------------------------------------
// Live mode and measurements
// ---------------------------------------------------------------------------

function slotItems() {
  return [...document.querySelectorAll(".meas-item")].map((s) => s.value);
}

// Live mode, with the measurements, math and FFT chosen; not while a
// capture is shown
function startLive() {
  if (scope.mode !== "live") return;
  const mathMode = $("math-mode").value, fftMode = $("fft-mode").value;
  const members = {
    on: true,
    interval_ms: LIVE_INTERVAL_MS,
    measure_ch: Number($("meas-ch").value),
    measure_items: slotItems().filter((v) => v !== ""),
    scope_math: mathMode === "scope" || fftMode === "scope",
  };
  if (mathMode === "pc" && $("math-op").value !== "div") members.math = $("math-op").value;
  if (fftMode === "pc") {
    members.spectrum = { ch: Number($("fft-source").value), window: $("fft-window").value };
  }
  conn.request("live", members).catch(fail);
  showMeasurements({});
}

function showMeasurements(event) {
  const readout = [];
  for (const row of document.querySelectorAll("#meas-slots .row")) {
    const name = row.querySelector(".meas-item").value;
    const value = row.querySelector(".value");
    if (name === "") {
      value.textContent = "";
      continue;
    }
    const [, label, unit] = ITEMS.find((i) => i[0] === name);
    const v = event[name];
    const text = v === undefined || v === null ? "-" :
      unit === "%" ? eng(100 * v, "") + "%" : eng(v, unit);
    value.textContent = text;
    if (event.ch) readout.push(label + " <b>" + text + "</b>");
  }
  $("readout").innerHTML = event.ch
    ? "<span>CH" + event.ch + ":</span>" + readout.map((r) => "<span>" + r + "</span>").join("")
    : "";
}

// Recording: a row per measurement update, saved as CSV when stopped
function toggleRecording() {
  const r = state.recording;
  if (r) {
    state.recording = null;
    $("record").textContent = "Record ...";
    lockMeasurements(false);
    const unit = (n) => ITEMS.find((i) => i[0] === n)[2];
    const header = "time,elapsed_s,ch," +
      r.items.map((n) => n + "_" + (unit(n) === "%" ? "fraction" : unit(n))).join(",");
    download("measurements-" + stamp() + ".csv", header + "\n" + r.rows.join("\n") + "\n", "text/csv");
    say("Saved " + r.rows.length + " rows of measurements");
    return;
  }
  if ($("meas-ch").value === "0") {
    say("Choose a channel to measure first", true);
    return;
  }
  state.recording = { items: slotItems().filter((v) => v !== ""), rows: [], start: Date.now() };
  $("record").textContent = "Stop and save";
  lockMeasurements(true);
  say("Recording measurements ...");
}

function lockMeasurements(locked) {
  $("meas-ch").disabled = locked;
  for (const s of document.querySelectorAll(".meas-item")) s.disabled = locked;
}

function recordRow(event) {
  const r = state.recording;
  if (!r) return;
  const now = new Date();
  r.rows.push([now.toISOString(), ((now - r.start) / 1000).toFixed(3), event.ch,
               ...r.items.map((n) => (event[n] === null || event[n] === undefined ? "" : num(event[n])))]
    .join(","));
  if (r.rows.length % 10 === 1) say("Recording: " + r.rows.length + " rows");
}

// ---------------------------------------------------------------------------
// Math and FFT
// ---------------------------------------------------------------------------

function mathScale() {
  return Number($("math-scale").value);
}

function applyMathView() {
  scope.setMath($("math-mode").value, $("math-op").value, mathScale(),
                Number($("math-position").value) * mathScale());
}

// Set up the scope's math channel for whichever of math and FFT uses it,
// or switch it off if we switched it on and neither does now
function configureScopeMath() {
  const mathMode = $("math-mode").value, fftMode = $("fft-mode").value;
  let m;
  if (fftMode === "scope") {
    m = { display: true, operator: "fft", fft_source: "ch" + $("fft-source").value,
          fft_window: $("fft-window").value, fft_mode: $("fft-data").value };
  } else if (mathMode === "scope") {
    m = { display: true, operator: $("math-op").value, source1: "ch1", source2: "ch2" };
  } else if (state.scopeMathOn) {
    m = { display: false };
  } else {
    return;
  }
  state.scopeMathOn = fftMode === "scope" || mathMode === "scope";
  set("set_math", m);
}

function onMathChoice(modeChanged) {
  const mode = $("math-mode").value;
  if (mode === "scope" && $("fft-mode").value === "scope") {
    $("fft-mode").value = "off";
    $("spectrum").hidden = true;
    say("The scope has one math channel; its FFT is now off");
  }
  if (mode === "pc" && $("math-op").value === "div") {
    $("math-op").value = "add";
    say("A/B is only available on the scope");
  }
  if (modeChanged && mode === "pc") {
    const c = channelSettings(1);
    if (c) $("math-scale").value = String(MATH_SCALES[nearest(MATH_SCALES, c.scale)]);
    $("math-position").value = "0";
  }
  configureScopeMath();
  applyMathView();
  startLive();
}

function onMathScale() {
  if ($("math-mode").value === "scope") {
    set("set_math", { scale: mathScale(), offset: Number($("math-position").value) * mathScale() });
  }
  applyMathView();
}

function onFFTChoice(newMode) {
  const mode = $("fft-mode").value;
  if (newMode === "scope" && $("math-mode").value === "scope") {
    $("math-mode").value = "off";
    applyMathView();
    say("The scope has one math channel; its math is now off");
  }
  $("spectrum").hidden = mode === "off";
  spectrum.reset();
  configureScopeMath();
  if (scope.mode === "live") startLive();
  else requestCaptureSpectrum();
}

function spectrumLabel(source, ch, window, capture = false) {
  return "FFT CH" + ch + (capture ? " capture" : "") + " (" +
    (source === "server" ? "PC" : source) + ", " + window + ")";
}

// The server's spectrum of the captured FFT source: all of it (at most
// 2^20 points, 2 MB), so zooming in it shows every line and the peak
// marker finds the true one
function requestCaptureSpectrum() {
  const ch = Number($("fft-source").value);
  if ($("fft-mode").value !== "pc" || scope.mode !== "capture" || !scope.isCaptured(ch)) return;
  say("Computing the spectrum of the capture ...");
  conn.request("spectrum", { ch, window: $("fft-window").value })
    .then(({ reply, payload }) => {
      spectrum.show({ values: floats(payload), f0: reply.f0, df: reply.df, rbw: reply.bin_width,
                      unit: reply.unit, window: reply.window,
                      label: spectrumLabel("server", ch, reply.window, true) });
      say("Spectrum of the capture: RBW " + eng(reply.bin_width, "Hz"));
    })
    .catch(fail);
}

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

async function capture() {
  if (state.capturing) return;
  state.capturing = true;
  // The channels on now, not at the last status: one may just have been
  // switched on at the scope
  try {
    const { reply } = await conn.request("status");
    applyStatus(reply);
  } catch (e) {
    state.capturing = false;
    fail(e);
    return;
  }
  const chans = [1, 2].filter((ch) => channelSettings(ch).display);
  if (chans.length === 0) {
    state.capturing = false;
    say("No channel is on", true);
    return;
  }
  $("progress").hidden = false;
  $("progress").value = 0;
  say("Capturing the acquisition memory ...");
  const infos = {};
  try {
    for (const ch of chans) {
      const { reply } = await conn.request("capture", { ch });
      infos[ch] = reply;
    }
    scope.clearCaptures();
    scope.setMode("capture");
    for (const ch of chans) scope.captured(ch, infos[ch]);
    say("Captured; the scope is stopped.  Live returns to live view.");
    spectrum.reset();
    requestCaptureSpectrum();
    decode.captured();
    timing.captured();
  } catch (e) {
    fail(e);
  } finally {
    state.capturing = false;
    $("progress").hidden = true;
    refreshStatus();
  }
}

function goLive() {
  scope.setMode("live");
  spectrum.reset();
  set("run", {});
  startLive();
  say("Live");
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

// CSV of time and volts: the screen live, the range in view of a capture
async function exportCSV() {
  if (scope.mode === "live") {
    const chans = [1, 2].filter((ch) => scope.frames[ch] && channelSettings(ch).display);
    if (chans.length === 0) {
      say("No live data to export", true);
      return;
    }
    const f0 = scope.frames[chans[0]];
    const lines = ["time_s," + chans.map((ch) => "ch" + ch + "_V").join(",")];
    for (let i = 0; i < f0.raw.length; i++) {
      lines.push([num(f0.info.x_origin + i * f0.info.x_inc),
                  ...chans.map((ch) => {
                    const f = scope.frames[ch];
                    return i < f.raw.length ? num(volts(f.info, f.raw[i])) : "";
                  })].join(","));
    }
    download("screen-" + stamp() + ".csv", lines.join("\n") + "\n", "text/csv");
    say("Exported the screen");
    return;
  }
  const [first, last] = scope.viewRange();
  const n = last - first + 1;
  if (n > MAX_EXPORT) {
    say("The view holds " + n + " samples; zoom in to at most " + MAX_EXPORT + " to export", true);
    return;
  }
  const chans = [1, 2].filter((ch) => scope.isCaptured(ch));
  const data = {};
  try {
    for (const ch of chans) {
      data[ch] = new Uint8Array(n);
      for (let at = first; at <= last; at += 1000000) {
        say("Exporting CH" + ch + " ...");
        const to = Math.min(last, at + 999999);
        const { payload } = await conn.request("samples", { ch, first: at, last: to });
        data[ch].set(payload, at - first);
      }
    }
  } catch (e) {
    fail(e);
    return;
  }
  const info = (ch) => scope.cap.chans[ch].info;
  const i0 = info(chans[0]);
  const parts = ["time_s," + chans.map((ch) => "ch" + ch + "_V").join(",") + "\n"];
  let block = [];
  for (let i = 0; i < n; i++) {
    block.push([num(i0.x_origin + (first + i) * i0.x_inc),
                ...chans.map((ch) => num(volts(info(ch), data[ch][i])))].join(","));
    if (block.length === 100000) {
      parts.push(block.join("\n") + "\n");
      block = [];
    }
  }
  if (block.length) parts.push(block.join("\n") + "\n");
  download("capture-" + stamp() + ".csv", new Blob(parts, { type: "text/csv" }));
  say("Exported " + n + " samples");
}

function screenshot() {
  say("Reading the scope's screen ...");
  conn.request("screenshot")
    .then(({ payload }) => {
      download("screen-" + stamp() + ".bmp", payload, "image/bmp");
      say("Saved the screenshot");
    })
    .catch(fail);
}

function saveSetup() {
  conn.request("save_setup")
    .then(({ reply }) => {
      download("scope-" + stamp() + ".setup", fromBase64(reply.setup));
      say("Saved the setup");
    })
    .catch(fail);
}

async function loadSetup() {
  const file = await pickFile(".setup");
  say("Loading the setup from " + file.name + " ...");
  conn.request("load_setup", { setup: toBase64(new Uint8Array(file.data)) })
    .then(({ reply }) => {
      if (reply.warnings) say("Setup loaded, but not all of it: " + reply.warnings[0], true);
      else say("Setup loaded from " + file.name);
      refreshStatus();
    })
    .catch(fail);
}

// ---------------------------------------------------------------------------
// References: kept by the server; every client hears of changes ("refs")
// ---------------------------------------------------------------------------

function refSlot() {
  return Number($("ref-slot").value);
}

function refreshRefs() {
  conn.request("refs")
    .then(({ reply }) => {
      scope.clearRefs();
      $("ref-list").textContent = reply.refs.length === 0 ? "none"
        : reply.refs.map((r) => "R" + r.slot + "  " + r.label).join("\n");
      for (const r of reply.refs) {
        conn.request("ref", { slot: r.slot })
          .then(({ reply: info, payload }) => scope.setRef(r.slot, info, payload))
          .catch(() => {});
      }
    })
    .catch(() => {});
}

function exportReference() {
  const slot = refSlot();
  conn.request("ref", { slot })
    .then(({ reply, payload }) => {
      const lines = ["time_s,volts"];
      for (let i = 0; i < payload.length; i++) {
        lines.push(num(reply.x_origin + i * reply.x_inc) + "," + num(volts(reply, payload[i])));
      }
      download("reference" + slot + ".csv", lines.join("\n") + "\n", "text/csv");
    })
    .catch(fail);
}

// A CSV of time, volts as a reference: 8-bit samples spanning the volts'
// range, as the scope's are
async function importReference() {
  const file = await pickFile(".csv,text/csv");
  const times = [], values = [];
  for (const line of new TextDecoder().decode(file.data).split(/\r?\n/)) {
    const [t, v] = line.split(",").map(Number);
    if (Number.isFinite(t) && Number.isFinite(v)) {
      times.push(t);
      values.push(v);
    }
  }
  if (times.length < 2) {
    say("No time,volts lines in " + file.name, true);
    return;
  }
  let lo = values[0], hi = values[0];
  for (const v of values) {
    lo = Math.min(lo, v);
    hi = Math.max(hi, v);
  }
  const yInc = Math.max(1e-6, (hi - lo) / 200);
  const raw = new Uint8Array(values.map((v) => Math.max(0, Math.min(255, Math.round(27 + (v - lo) / yInc)))));
  set("ref_load", {
    slot: refSlot(), ch: Number($("ref-source").value), label: file.name,
    data: toBase64(raw), x_inc: (times[times.length - 1] - times[0]) / (times.length - 1),
    x_origin: times[0], y_inc: yInc, y_origin: -100 - lo / yInc, y_ref: 127,
  });
}

// ---------------------------------------------------------------------------
// Pass/fail
// ---------------------------------------------------------------------------

function onMask(action) {
  const settings = {
    enable: true, source: $("mask-source").value, x: Number($("mask-x").value),
    y: Number($("mask-y").value), stop_on_fail: $("mask-stop").checked, show_stats: true,
  };
  if (action === "create") {
    set("set_mask", Object.assign(settings, { create: true, reset: true }));
    say("A mask around " + settings.source.toUpperCase() + "'s waveform now; Start runs the test");
  } else if (action === "start") {
    set("set_mask", Object.assign(settings, { run: true })).then(() => set("run", {}));
  } else if (action === "stop") {
    set("set_mask", { run: false });
  } else if (action === "reset") {
    set("set_mask", { reset: true });
  } else {
    set("set_mask", { enable: false });
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

function onEvent(event, payload) {
  switch (event.event) {
    case "hello": {
      const idn = event.idn ? event.idn.split(",") : [];
      // The maker's first word, as a name ("RIGOL TECHNOLOGIES" -> "Rigol"),
      // and the model
      const maker = idn.length > 1 ? idn[0].split(" ")[0] : "";
      const name = maker.charAt(0) + maker.slice(1).toLowerCase();
      $("title").textContent = idn.length > 1 ? name + " " + idn[1] : "ScopeBridge";
      document.title = "ScopeBridge - " + $("title").textContent;
      $("connection").textContent = event.source + (event.idn ? "" : " - the scope does not answer");
      refreshStatus();
      refreshRefs();
      if (scope.mode === "live") startLive();
      break;
    }
    case "frame":
      scope.liveFrame(event.ch, event, payload);
      break;
    case "measure":
      showMeasurements(event);
      recordRow(event);
      break;
    case "math":
      scope.mathFrame(event, payload);
      break;
    case "spectrum": {
      const mode = $("fft-mode").value;
      if ((event.source === "scope" && mode === "scope") || (event.source === "server" && mode === "pc")) {
        spectrum.show({ values: floats(payload), f0: event.f0, df: event.df, rbw: event.bin_width,
                        unit: event.unit, window: event.window,
                        label: spectrumLabel(event.source, event.ch, event.window) });
      }
      break;
    }
    case "progress":
      $("progress").value = event.done / Math.max(1, event.total);
      say("Reading memory: " + eng(event.done, "") + "of " + eng(event.total, "") + "points");
      break;
    case "refs":
      refreshRefs();
      break;
    case "error":
      fail(new Error(event.error));
      break;
  }
}

function onState(up) {
  const c = $("connection");
  c.classList.toggle("up", up);
  c.classList.toggle("down", !up);
  if (!up) c.textContent = "disconnected - retrying";
}

buildControls();
setInterval(refreshStatus, STATUS_INTERVAL_MS);

// The page's parts, for a look in the browser's console (and the tests)
window.scopebridge = { conn, scope, spectrum, decode, timing };
