// Helpers of the browser client: formatting, lists of values, files.
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

export const $ = (id) => document.getElementById(id);

export const COLOURS = { 1: "#ffe600", 2: "#00d9ff" };
export const MATH_COLOUR = "#f259d9";
export const REF_COLOURS = { 1: "#ebebeb", 2: "#ff9933", 3: "#80ff80", 4: "#ff8cbf" };

// 1, 2, 5, 10, ... from low to high
export function steps125(low, high) {
  const result = [];
  for (let e = Math.floor(Math.log10(low)) - 1; e <= Math.log10(high) + 1; e++) {
    for (const m of [1, 2, 5]) {
      const v = m * Math.pow(10, e);
      if (v >= low * 0.999 && v <= high * 1.001) result.push(Number(v.toPrecision(3)));
    }
  }
  return result;
}

// 1.00 kHz, 500 mV, 2.00 µs
export function eng(x, unit) {
  if (x === null || x === undefined || !isFinite(x)) return "-";
  const prefixes = [[1e9, "G"], [1e6, "M"], [1e3, "k"], [1, ""], [1e-3, "m"],
                    [1e-6, "µ"], [1e-9, "n"], [1e-12, "p"]];
  const a = Math.abs(x);
  if (a === 0) return "0.00 " + unit;
  for (const [f, p] of prefixes) {
    if (a >= f * 0.9995 || f === 1e-12) {
      const v = x / f;
      const digits = Math.abs(v) >= 100 ? 0 : Math.abs(v) >= 10 ? 1 : 2;
      return v.toFixed(digits) + " " + p + unit;
    }
  }
  return String(x) + " " + unit;
}

// "5u" -> 5e-6, "115200" -> 115200, "1.2k" -> 1200; NaN if not a number
export function parseSI(text) {
  const t = String(text).trim();
  const m = /^([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)\s*([pnuµmkMG]?)$/.exec(t);
  if (!m) return NaN;
  const f = { p: 1e-12, n: 1e-9, u: 1e-6, "µ": 1e-6, m: 1e-3, "": 1, k: 1e3, M: 1e6, G: 1e9 };
  return Number(m[1]) * f[m[2]];
}

// Index of the value in list closest to x, on a log scale
export function nearest(list, x) {
  let best = 0;
  for (let i = 1; i < list.length; i++) {
    if (Math.abs(Math.log(list[i] / x)) < Math.abs(Math.log(list[best] / x))) best = i;
  }
  return best;
}

// Options of a select: values, labelled by label (value) or pairs [value, label]
export function fillSelect(select, values, label = (v) => String(v)) {
  select.innerHTML = "";
  for (const v of values) {
    const o = document.createElement("option");
    if (Array.isArray(v)) {
      o.value = String(v[0]);
      o.textContent = v[1];
    } else {
      o.value = String(v);
      o.textContent = label(v);
    }
    select.appendChild(o);
  }
}

// Set a control from the scope's settings, unless the user is at it
export function show(el, value) {
  if (document.activeElement !== el) el.value = String(value);
}

// The float32 values of a "math", "spectrum" or "math_view" payload
export function floats(payload) {
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const n = payload.byteLength / 4;
  const result = new Float32Array(n);
  for (let i = 0; i < n; i++) result[i] = view.getFloat32(4 * i, true);
  return result;
}

// Volts of a raw sample, by the waveform members of the protocol
export function volts(info, raw) {
  return (raw - info.y_ref - info.y_origin) * info.y_inc;
}

// Save data as a file in the browser's downloads
export function download(name, data, type = "application/octet-stream") {
  const url = URL.createObjectURL(new Blob([data], { type }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

// Ask for a file and resolve to its contents as an ArrayBuffer
export function pickFile(accept = "") {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = accept;
    input.onchange = () => {
      const file = input.files[0];
      if (file) file.arrayBuffer().then((data) => resolve({ name: file.name, data }));
    };
    input.click();
  });
}

export function toBase64(bytes) {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(text);
}

export function fromBase64(text) {
  const bin = atob(text);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// A number as CSV writes it: enough digits, no locale
export function num(x) {
  return Number.isFinite(x) ? String(Number(x.toPrecision(9))) : "";
}

// "20260926-143012", for file names
export function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + "-" +
    p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
}
