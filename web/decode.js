// Bus decoding in the browser client: the Decode panel's settings, the
// server's decoding of the capture, the list of items (choosing one zooms
// the capture to it), and the scope's own bus decoder.
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

import { $, eng, parseSI } from "./util.js";

const MAX_ITEMS = 50000;
const MAX_ROWS = 20000;   // table rows: more make the page slow
const BAUDS = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400,
               460800, 921600, 1000000];

export class DecodePanel {
  constructor(conn, scope, say) {
    this.conn = conn;
    this.scope = scope;
    this.say = say;
    this.shown = false;

    const list = $("dec-bauds");
    for (const b of BAUDS) {
      const o = document.createElement("option");
      o.value = String(b);
      list.appendChild(o);
    }
    $("dec-protocol").addEventListener("change", () => this.showProtocol());
    $("dec-format").addEventListener("change", () => { if (this.shown) this.run(); });
    $("dec-run").addEventListener("click", () => this.run());
    $("dec-scope").addEventListener("click", () => this.showOnScope());
    $("dec-clear").addEventListener("click", () => this.clear());
    $("decoded-rows").addEventListener("click", (e) => {
      const row = e.target.closest("tr");
      if (!row) return;
      for (const r of document.querySelectorAll("#decoded-rows tr.chosen")) r.classList.remove("chosen");
      row.classList.add("chosen");
      this.scope.zoomTo(Number(row.dataset.first), Number(row.dataset.last));
    });
    this.showProtocol();
  }

  protocol() {
    return $("dec-protocol").value;
  }

  showProtocol() {
    const p = this.protocol();
    $("dec-uart").hidden = p !== "uart";
    $("dec-i2c").hidden = p !== "i2c";
    $("dec-spi").hidden = p !== "spi";
  }

  // Bits per data word, for binary and hex labels
  width() {
    const p = this.protocol();
    return p === "spi" ? Number($("dec-width").value) : p === "uart" ? Number($("dec-bits").value) : 8;
  }

  // The settings as "decode" and "set_decoder" take them; throws for a
  // baud rate or timeout that is no number
  settings() {
    const p = this.protocol();
    const m = { protocol: p };
    if (p === "uart") {
      const baud = parseSI($("dec-baud").value);
      if (!(baud > 0)) throw new Error("the baud rate is not a number");
      m.tx = Number($("dec-tx").value);
      if ($("dec-rx").value !== "0") m.rx = Number($("dec-rx").value);
      m.baud = Math.round(baud);
      m.bits = Number($("dec-bits").value);
      m.parity = $("dec-parity").value;
      m.stop = Number($("dec-stop").value);
      m.inverted = $("dec-uart-inverted").checked;
      m.msb_first = $("dec-uart-msb").checked;
    } else if (p === "i2c") {
      m.scl = Number($("dec-scl").value);
      m.sda = 3 - m.scl;
    } else {
      m.clk = Number($("dec-clk").value);
      m.data = 3 - m.clk;
      m.edge = $("dec-edge").value;
      m.width = Number($("dec-width").value);
      m.msb_first = !$("dec-spi-lsb").checked;
      m.inverted = $("dec-spi-inverted").checked;
      const t = $("dec-timeout").value.trim().toLowerCase();
      if (t !== "auto" && t !== "") {
        const seconds = parseSI(t);
        if (!(seconds > 0)) throw new Error("the timeout is not a number: auto, or e.g. 5u");
        m.timeout = seconds;
      }
    }
    return m;
  }

  // An item's text, as the lanes and the list show it
  label(item) {
    const format = $("dec-format").value;
    const hex = (v, digits) => v.toString(16).toUpperCase().padStart(digits, "0");
    if (item.type === "start") return "S";
    if (item.type === "stop") return "P";
    const v = item.value;
    if (item.type === "address") return (item.read ? "R " : "W ") + hex(v, 2);
    const bits = this.width();
    if (format === "dec") return String(v);
    if (format === "bin") return v.toString(2).padStart(bits, "0");
    if (format === "ascii") {
      if (v === 32) return "SP";
      return v > 32 && v < 127 ? String.fromCharCode(v) : "\\x" + hex(v, 2);
    }
    return hex(v, Math.ceil(bits / 4));
  }

  run() {
    if (this.scope.mode !== "capture") {
      this.say("Decoding works on a capture: press Capture memory first", true);
      return;
    }
    let members;
    try {
      members = this.settings();
    } catch (e) {
      this.say(e.message, true);
      return;
    }
    members.max_items = MAX_ITEMS;
    this.say("Decoding ...");
    this.conn.request("decode", members)
      .then(({ reply }) => this.show(reply))
      .catch((e) => this.say("Error: " + e.message, true));
  }

  show(reply) {
    const items = reply.items;
    this.scope.setDecoded(items, (it) => this.label(it));
    const rows = document.createDocumentFragment();
    const format = $("dec-format").value;
    for (const it of items.slice(0, MAX_ROWS)) {
      const tr = document.createElement("tr");
      tr.dataset.first = it.first;
      tr.dataset.last = it.last;
      const note = "error" in it ? it.error + " error" : "ack" in it ? (it.ack ? "ack" : "no ack") : "";
      let value = this.label(it);
      if (it.type === "data" && format !== "ascii" && it.value > 32 && it.value < 127) {
        value += "  '" + String.fromCharCode(it.value) + "'";
      }
      for (const [text, bad] of [[eng(it.t, "s"), false], ["CH" + it.ch, false], [it.type, false],
                                 [value, false], [note, "error" in it || it.ack === false]]) {
        const td = document.createElement("td");
        td.textContent = text;
        if (bad) td.className = "bad";
        tr.appendChild(td);
      }
      rows.appendChild(tr);
    }
    $("decoded-rows").replaceChildren(rows);
    const th = reply.thresholds || {};
    $("decoded-summary").textContent =
      reply.count + " items, " + this.protocol().toUpperCase() +
      (reply.truncated ? " (the first " + MAX_ITEMS + ")" : "") +
      (items.length > MAX_ROWS ? "; the list shows the first " + MAX_ROWS : "") +
      ";  thresholds" + (th.ch1 !== undefined ? " CH1 " + eng(th.ch1, "V") : "") +
      (th.ch2 !== undefined ? " CH2 " + eng(th.ch2, "V") : "") +
      ".  Choose an item to zoom to it.";
    $("decoded").hidden = false;
    this.shown = true;
    this.say("Decoded " + reply.count + " items");
  }

  showOnScope() {
    let members;
    try {
      members = this.settings();
    } catch (e) {
      this.say(e.message, true);
      return;
    }
    const format = $("dec-format").value;
    Object.assign(members, { bus: 1, display: true, format: format === "dec" ? "dec" : format });
    this.conn.request("set_decoder", members)
      .then(() => this.say("The scope shows the bus (decoder 1)"))
      .catch((e) => this.say("Error: " + e.message, true));
  }

  clear() {
    this.shown = false;
    $("decoded-rows").replaceChildren();
    $("decoded").hidden = true;
    this.scope.clearDecoded();
  }

  // A new capture is in: decode it again, if items are shown
  captured() {
    if (this.shown) this.run();
  }
}
