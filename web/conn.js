// The connection of the browser client to scopebridge-server: the protocol of
// docs/PROTOCOL.md over a WebSocket at /ws.
//
// Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

// Requests are answered by replies with the same id; a message with a
// binary payload ("bytes") is followed by a binary WebSocket message.
// Reconnects by itself when the server goes away.
export class Connection {
  constructor(onEvent, onState) {
    this.onEvent = onEvent;
    this.onState = onState;
    this.nextId = 1;
    this.waiting = new Map();
    this.pending = null;
    this.open();
  }

  open() {
    const scheme = location.protocol === "https:" ? "wss://" : "ws://";
    this.ws = new WebSocket(scheme + location.host + "/ws");
    this.ws.binaryType = "arraybuffer";
    this.ws.onopen = () => this.onState(true);
    this.ws.onmessage = (m) => this.receive(m.data);
    this.ws.onclose = () => {
      for (const [, w] of this.waiting) w.reject(new Error("connection lost"));
      this.waiting.clear();
      this.pending = null;
      this.onState(false);
      setTimeout(() => this.open(), 2000);
    };
  }

  get isOpen() {
    return this.ws && this.ws.readyState === WebSocket.OPEN;
  }

  receive(data) {
    if (typeof data === "string") {
      const message = JSON.parse(data);
      if (message.bytes > 0) {
        this.pending = message;   // its payload comes next
      } else {
        this.dispatch(message, new Uint8Array(0));
      }
    } else if (this.pending) {
      const message = this.pending;
      this.pending = null;
      this.dispatch(message, new Uint8Array(data));
    }
  }

  dispatch(message, payload) {
    if (message.event) {
      this.onEvent(message, payload);
    } else if (this.waiting.has(message.id)) {
      const w = this.waiting.get(message.id);
      this.waiting.delete(message.id);
      if (message.ok) w.resolve({ reply: message, payload });
      else w.reject(new Error(message.error || "request failed"));
    }
  }

  // Resolves to { reply, payload }; rejects with the server's error text
  request(cmd, members = {}) {
    if (!this.isOpen) return Promise.reject(new Error("not connected"));
    const id = this.nextId++;
    this.ws.send(JSON.stringify(Object.assign({ id, cmd }, members)));
    return new Promise((resolve, reject) => this.waiting.set(id, { resolve, reject }));
  }
}
