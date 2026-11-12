// Minimal client for harness-engine's local WebSocket RPC (one JSON object
// per text frame: {id, method, params} -> {id, ok|err|item}). Node's built-in
// WebSocket sends no Origin header, which the engine requires.
export class Rpc {
  static async connect(port, { attempts = 20, delayMs = 500 } = {}) {
    let last;
    for (let i = 0; i < attempts; i++) {
      try {
        const ws = new WebSocket(`ws://127.0.0.1:${port}`);
        await new Promise((resolve, reject) => {
          const t = setTimeout(() => reject(new Error("connect timed out")), 5000);
          ws.onopen = () => { clearTimeout(t); resolve(); };
          ws.onerror = (e) => { clearTimeout(t); reject(new Error(`connect failed: ${e.message ?? "error"}`)); };
        });
        return new Rpc(ws);
      } catch (e) {
        last = e;
        await new Promise((r) => setTimeout(r, delayMs));
      }
    }
    throw new Error(`engine on port ${port} did not accept a connection after ${attempts} tries: ${last?.message}`);
  }
  constructor(ws) {
    this.ws = ws;
    this.next = 1;
    this.pending = new Map();
    this.streams = new Map();
    ws.onmessage = (ev) => {
      let m;
      try { m = JSON.parse(typeof ev.data === "string" ? ev.data : Buffer.from(ev.data).toString()); } catch { return; }
      const p = this.pending.get(m.id);
      const s = this.streams.get(m.id);
      if ("item" in m) { s?.items.push(m.item); s?.notify(); return; }
      if (p) {
        this.pending.delete(m.id);
        if ("err" in m) p.reject(new Error(`${p.method}: ${typeof m.err === "string" ? m.err : JSON.stringify(m.err)}`));
        else p.resolve(m.ok);
      }
    };
    ws.onclose = () => {
      for (const p of this.pending.values()) p.reject(new Error(`${p.method}: engine closed the connection`));
      this.pending.clear();
    };
  }
  call(method, params = {}, timeoutMs = 30000) {
    const id = this.next++;
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method}: no answer in ${timeoutMs} ms`)); }, timeoutMs);
      this.pending.set(id, {
        method,
        resolve: (v) => { clearTimeout(t); resolve(v); },
        reject: (e) => { clearTimeout(t); reject(e); },
      });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  /** Open a stream; returns {items, waitFor(pred, ms), cancel()}. */
  watch(method, params = {}) {
    const id = this.next++;
    const s = { items: [], waiters: [], notify() { for (const w of this.waiters.splice(0)) w(); } };
    this.streams.set(id, s);
    this.pending.set(id, { method, resolve: () => {}, reject: () => {} });
    this.ws.send(JSON.stringify({ id, method, params }));
    s.waitFor = async (pred, ms, what) => {
      const end = Date.now() + ms;
      for (;;) {
        const hit = pred(s.items);
        if (hit) return hit;
        const left = end - Date.now();
        if (left <= 0) throw new Error(`${method}: timed out after ${ms} ms waiting for ${what ?? "an item"}`);
        await new Promise((r) => { const t = setTimeout(r, Math.min(left, 500)); s.waiters.push(() => { clearTimeout(t); r(); }); });
      }
    };
    s.cancel = () => { this.streams.delete(id); try { this.ws.send(JSON.stringify({ id, cancel: true })); } catch {} };
    return s;
  }
  close() { try { this.ws.close(); } catch {} }
}
