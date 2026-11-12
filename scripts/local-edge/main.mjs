// scripts/local-edge.sh's engine: runs the Cloudflare edge Worker locally
// (`wrangler dev --local`, Miniflare/workerd, state in a temporary folder)
// and the Zig harness-engine against it. Nothing here talks to Cloudflare's
// account or the deployed edge, and every identity is made up.
//
//   check            the end-to-end proof, one line per step; exit 1 on a failure
//   up [--phone]     edge + engine A (+ engine B), a seeded chat, harness-nano windows
//   down             stops everything `up` started
//   status           what `up` started, and whether it still runs
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Rpc } from "./rpc.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const EDGE_DIR = path.join(ROOT, "edge");
const BIN = path.join(ROOT, "apps/nano/zig-out/bin");
const WRANGLER = path.join(EDGE_DIR, "node_modules/.bin/wrangler");
const POINTER = path.join(os.tmpdir(), "harness-local-edge.current");
/** Ports the installed app and the edge's defaults hold: never ours. */
const RESERVED = new Set([27664, 7331, 27640, 27643]);
const SYS_PATH = "/usr/bin:/bin:/usr/sbin:/sbin";

/** The run whose processes this process must stop if it is interrupted. */
let activeRun = null;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rand = (n = 6) => Math.random().toString(36).slice(2, 2 + n).padEnd(n, "0");
const uuid = () => crypto.randomUUID();

// ── state folder and processes ─────────────────────────────────────────────

class Run {
  constructor(dir) {
    this.dir = dir;
    this.statePath = path.join(dir, "state.json");
    this.state = fs.existsSync(this.statePath)
      ? JSON.parse(fs.readFileSync(this.statePath, "utf8"))
      : { procs: {}, ports: {}, extraListeners: [] };
  }
  static create() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "harness-local-edge-"));
    for (const sub of ["logs", "tmp"]) fs.mkdirSync(path.join(dir, sub));
    return new Run(dir);
  }
  save() { fs.writeFileSync(this.statePath, JSON.stringify(this.state, null, 2)); }
  p(...parts) { return path.join(this.dir, ...parts); }
  /** Hide the state folder in anything written to the proof. */
  scrub(text) { return String(text).split(this.dir).join("<state>").split(os.homedir()).join("<home>"); }

  /** Start `cmd` in its own process group; the group is what gets stopped. */
  start(name, cmd, args, { cwd, env }) {
    const log = fs.openSync(this.p("logs", `${name}.log`), "a");
    const child = spawn(cmd, args, { cwd, env, detached: true, stdio: ["ignore", log, log] });
    fs.closeSync(log);
    if (!child.pid) throw new Error(`${name}: could not start ${cmd}`);
    child.unref();
    this.state.procs[name] = { pid: child.pid, cmd: path.basename(cmd), args, cwd, env, startedAt: Date.now() };
    this.save();
    return child.pid;
  }

  alive(name) {
    const pr = this.state.procs[name];
    return !!pr && groupAlive(pr.pid);
  }

  async stop(name, graceMs = 10_000) {
    const pr = this.state.procs[name];
    if (!pr) return;
    signalGroup(pr.pid, "SIGTERM");
    const end = Date.now() + graceMs;
    while (groupAlive(pr.pid) && Date.now() < end) await sleep(100);
    if (groupAlive(pr.pid)) signalGroup(pr.pid, "SIGKILL");
    const hard = Date.now() + 5_000;
    while (groupAlive(pr.pid) && Date.now() < hard) await sleep(100);
    if (groupAlive(pr.pid)) throw new Error(`${name} (process group ${pr.pid}) would not stop`);
    pr.stoppedAt = Date.now();
    this.save();
  }

  async stopAll() {
    const errors = [];
    for (const name of Object.keys(this.state.procs).reverse()) {
      try { await this.stop(name); } catch (e) { errors.push(e.message); }
    }
    return errors;
  }
}

function signalGroup(pgid, sig) {
  try { process.kill(-pgid, sig); } catch {}
}
function groupAlive(pgid) {
  try { process.kill(-pgid, 0); return true; } catch (e) { return e.code === "EPERM"; }
}
function groupMembers(pgid) {
  const out = spawnSync("ps", ["-axo", "pid=,pgid=,comm="], { encoding: "utf8" }).stdout ?? "";
  return out.split("\n").map((l) => l.trim().split(/\s+/)).filter((f) => f.length >= 3 && Number(f[1]) === pgid)
    .map((f) => ({ pid: Number(f[0]), comm: path.basename(f.slice(2).join(" ")) }));
}

async function freePort() {
  for (let i = 0; i < 50; i++) {
    const port = await new Promise((resolve, reject) => {
      const s = net.createServer();
      s.once("error", reject);
      s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => resolve(p)); });
    });
    if (!RESERVED.has(port)) return port;
  }
  throw new Error("no free loopback port");
}

function portListening(port) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port });
    const done = (v) => { s.destroy(); resolve(v); };
    s.setTimeout(1500, () => done(false));
    s.once("connect", () => done(true));
    s.once("error", () => done(false));
  });
}

/** Listening TCP sockets owned by these process ids (lsof). */
function listenersOf(pids) {
  if (pids.length === 0) return [];
  const out = spawnSync("lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", pids.join(",")], { encoding: "utf8" }).stdout ?? "";
  return out.split("\n").slice(1).filter(Boolean).map((l) => {
    const f = l.split(/\s+/);
    return { pid: Number(f[1]), comm: f[0], addr: f[8] };
  });
}

/** Non-loopback connections owned by these process ids (lsof). */
function outboundOf(pids) {
  if (pids.length === 0) return [];
  const out = spawnSync("lsof", ["-nP", "-a", "-i", "-p", pids.join(",")], { encoding: "utf8" }).stdout ?? "";
  return out.split("\n").slice(1).filter(Boolean).map((l) => l.split(/\s+/)).filter((f) => f[8] && f[8].includes("->"))
    .map((f) => ({ comm: f[0], conn: f[8] }))
    .filter(({ conn }) => !/->(127\.0\.0\.1|\[::1\]|localhost):/.test(conn));
}

// ── HTTP and waiting ───────────────────────────────────────────────────────

async function http(method, url, { bearer, body, timeoutMs = 10_000, headers = {} } = {}) {
  const h = { ...headers };
  if (bearer) h.authorization = `Bearer ${bearer}`;
  if (body !== undefined && typeof body !== "string") { h["content-type"] = "application/json"; body = JSON.stringify(body); }
  const res = await fetch(url, { method, headers: h, body, signal: AbortSignal.timeout(timeoutMs) });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch {}
  return { status: res.status, text, json };
}

/** Retry `fn` until it returns a truthy value or `ms` passes; `what` names it in the error. */
async function until(what, ms, fn, everyMs = 500) {
  const end = Date.now() + ms;
  let last;
  for (;;) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (e) { last = e; }
    if (Date.now() >= end) throw new Error(`timed out after ${ms} ms waiting for ${what}${last ? ` (last error: ${last.message})` : ""}`);
    await sleep(everyMs);
  }
}

// ── the edge ───────────────────────────────────────────────────────────────

function edgeEnv(run) {
  const home = run.p("edge-home");
  fs.mkdirSync(home, { recursive: true });
  return {
    PATH: `${path.dirname(process.execPath)}:${SYS_PATH}`,
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, ".config"),
    TMPDIR: run.p("tmp"),
    // No telemetry, no npm update check, no `request.cf` download.
    WRANGLER_SEND_METRICS: "false",
    WRANGLER_SEND_ERROR_REPORTS: "false",
    WRANGLER_HIDE_BANNER: "true",
    CLOUDFLARE_CF_FETCH_ENABLED: "false",
    WRANGLER_LOG_PATH: run.p("logs", "wrangler"),
    NO_COLOR: "1",
  };
}

async function startEdge(run) {
  if (!fs.existsSync(WRANGLER)) throw new Error("edge/node_modules is missing: run `npm ci` in edge/");
  const ports = run.state.ports;
  ports.edge ??= await freePort();
  ports.inspector ??= await freePort();
  run.save();
  run.start("edge", WRANGLER, [
    "dev", "--config", "wrangler.local.jsonc", "--local",
    "--ip", "127.0.0.1", "--port", String(ports.edge), "--inspector-port", String(ports.inspector),
    "--persist-to", run.p("edge-state"), "--show-interactive-dev-session=false",
    "--var", `HARNESS_LOCAL_SESSION_TOKEN:${run.state.identity.bearer}`,
    "--var", `HARNESS_LOCAL_SESSION_USER:${run.state.identity.user}`,
  ], { cwd: EDGE_DIR, env: edgeEnv(run) });
  const health = await until(`the local edge on 127.0.0.1:${ports.edge} to answer /health`, 120_000, async () => {
    if (!run.alive("edge")) throw new Error(`wrangler exited (see the edge log)`);
    const r = await http("GET", `${edgeUrl(run)}/health`, { timeoutMs: 3000 });
    return r.status === 200 && r.json?.ok ? r.json : null;
  });
  if (health.auth !== "local") throw new Error(`the local edge runs auth "${health.auth}", expected local`);
  rememberListeners(run, "edge");
  return health;
}

const edgeUrl = (run) => `http://127.0.0.1:${run.state.ports.edge}`;

function rememberListeners(run, name) {
  const pr = run.state.procs[name];
  const pids = groupMembers(pr.pid).map((m) => m.pid);
  for (const l of listenersOf(pids)) {
    const port = Number(l.addr.split(":").pop());
    if (!run.state.extraListeners.some((x) => x.port === port)) run.state.extraListeners.push({ proc: name, comm: l.comm, port });
  }
  run.save();
}

// ── engines ────────────────────────────────────────────────────────────────

function engineEnv(run, dev) {
  const s = run.state;
  return {
    PATH: SYS_PATH,
    HOME: run.p(dev, "home"),
    TMPDIR: run.p("tmp"),
    LANG: "en_US.UTF-8",
    HARNESS_DATA_DIR: run.p(dev, "data"),
    HARNESS_IPC_PORT: String(s.ports[dev]),
    HARNESS_EDGE_URL: edgeUrl(run),
    // Explicit local auth; the Worker verifies this run's opaque session.
    HARNESS_CODEGRAFF_CLIENT_ID: "",
    HARNESS_LOCAL_EDGE_AUTH: "1",
    HARNESS_NANO_NO_RELEASE_CHECK: "1",
    HARNESS_EDGE_TOKEN: s.identity.bearer,
    HARNESS_DEVICE_NAME: `synthetic-${dev}`,
  };
}

async function startEngine(run, dev) {
  const engine = path.join(BIN, "harness-engine");
  if (!fs.existsSync(engine)) throw new Error("apps/nano/zig-out/bin/harness-engine is missing: run `zig build` in apps/nano");
  run.state.ports[dev] ??= await freePort();
  for (const sub of ["home", "data"]) fs.mkdirSync(run.p(dev, sub), { recursive: true });
  run.save();
  run.start(`engine-${dev}`, engine, ["headless"], { cwd: run.p(dev), env: engineEnv(run, dev) });
  const rpc = await Rpc.connect(run.state.ports[dev], { attempts: 60, delayMs: 500 });
  const info = await rpc.call("EngineInfo", {});
  run.state.devices ??= {};
  run.state.devices[dev] = info.deviceId;
  run.save();
  rememberListeners(run, `engine-${dev}`);
  return { rpc, info };
}

function newIdentity() {
  const user = `ada-${rand(6)}`;
  // The Worker's personal workspace for that user (auth.ts personalOrgId).
  const org = `user-${user}`;
  return { user, org, bearer: crypto.randomUUID() + crypto.randomUUID() };
}

// ── engine helpers ─────────────────────────────────────────────────────────

const textOf = (frame) => JSON.stringify(frame ?? "");
/** The newest full transcript (`reset`) in a WatchDocMessages stream. */
const lastReset = (items) => [...items].reverse().find((i) => Array.isArray(i?.reset))?.reset;

async function readTranscript(rpc, chatId, ms, pred, what) {
  const w = rpc.watch("WatchDocMessages", { chatId, openingTail: true });
  try {
    return await w.waitFor((items) => { const r = lastReset(items); return r && pred(r) ? r : null; }, ms, what);
  } finally { w.cancel(); }
}

const hasText = (msgs, needle) => msgs.some((m) => (m.parts ?? []).some((p) => (p.text ?? "").includes(needle)));
const assistantDone = (msgs, afterUserText) => {
  const i = msgs.findIndex((m) => m.role === "user" && (m.parts ?? []).some((p) => (p.text ?? "").includes(afterUserText)));
  if (i < 0) return false;
  const a = msgs.slice(i + 1).find((m) => m.role === "assistant");
  return !!a && a.status === "complete" && (a.parts ?? []).some((p) => p.kind === "text" && (p.text ?? "").length > 0);
};

async function edgeRows(run) {
  const { org, bearer } = run.state.identity;
  const r = await http("GET", `${edgeUrl(run)}/registry/${org}/rows`, { bearer });
  if (r.status !== 200) throw new Error(`GET /registry/:org/rows answered ${r.status}`);
  return r.json.rows;
}

async function seedProject(run, rpc, devId) {
  const repo = run.p("repo-synthetic");
  fs.mkdirSync(repo, { recursive: true });
  const git = (...a) => {
    const r = spawnSync("git", a, { cwd: repo, encoding: "utf8", env: { PATH: SYS_PATH, HOME: run.p("a", "home") } });
    if (r.status !== 0) throw new Error(`git ${a[0]} failed: ${r.stderr}`);
  };
  fs.writeFileSync(path.join(repo, "README.md"), "# Synthetic demo repo\n\nMade up for the local edge check.\n");
  git("init", "-q", "-b", "main");
  git("add", "README.md");
  git("-c", "user.name=Synthetic Person", "-c", "user.email=synthetic@example.invalid", "commit", "-q", "-m", "Synthetic first commit");
  const spaceId = "space-synthetic-demo";
  await rpc.call("Mutate", { op: "createSpace", spaceId, deviceId: devId, path: repo, gitDetected: true });
  return { repo, spaceId };
}

async function runPrompt(rpc, chatId, cwd, prompt) {
  const messageId = uuid();
  const ok = await rpc.call("QueueCommand", {
    chatId,
    command: { kind: "run", messageId, request: { prompt, turnOrigin: "human", harness: "mock", modelOptions: {}, cwd, sandbox: "workspace-write", autoApprove: false } },
  });
  if (ok?.commandId !== messageId) throw new Error(`QueueCommand answered ${JSON.stringify(ok)}`);
  return messageId;
}

// ── check ──────────────────────────────────────────────────────────────────

const STEPS = [
  [1, "local edge starts on fresh persisted state"],
  [2, "engine A (Zig) starts against it"],
  [3, "A signs in, org, device registered"],
  [4, "A: project, mock chat, turn, transcript"],
  [5, "the Worker holds the chat row and its history"],
  [6, "engine B: lists, reads, relays a prompt to A"],
  [7, "rooms, tool blob, attachment"],
  [8, "edge and A restart on the same state"],
  [9, "everything stopped, no process or port left"],
];

async function check(opts) {
  const run = Run.create();
  activeRun = run;
  run.state.mode = "check";
  run.state.identity = newIdentity();
  run.save();
  const results = [];
  const ctx = { run, notes: [], mismatches: [] };
  const deadline = setTimeout(async () => {
    console.error(`local-edge: the whole check passed its ${opts.maxMinutes} minute limit; stopping`);
    await run.stopAll();
    process.exit(1);
  }, opts.maxMinutes * 60_000);
  deadline.unref();
  const sampler = setInterval(() => sampleOutbound(run), 2000);
  sampler.unref();

  let failedAt = null;
  for (const [n, title] of STEPS) {
    const t0 = Date.now();
    let status = "pass", reason = "";
    if (n !== 9 && failedAt !== null) {
      status = "skipped"; reason = `step ${failedAt} failed`;
    } else {
      try {
        const out = await STEP_FNS[n](ctx);
        if (out?.status) status = out.status;
        reason = out?.reason ?? "";
      } catch (e) {
        status = "fail"; reason = e.message;
      }
      if (status === "fail" && n !== 9) failedAt = n;
    }
    const r = { n, title, status, ms: Date.now() - t0, reason: run.scrub(reason) };
    results.push(r);
    console.log(fmtRow(r));
    if (status === "fail" && n !== 9) {
      // Close the clients so step 9 can stop the engines cleanly.
      for (const c of [ctx.a, ctx.b]) c?.close();
    }
  }
  clearInterval(sampler);
  const outbound = run.state.outbound ?? [];
  console.log(`outbound (non-loopback) connections seen from our processes: ${outbound.length === 0 ? "none" : outbound.map((o) => `${o.comm} ${o.conn}`).join(", ")}`);
  const ok = results.every((r) => r.status !== "fail");
  fs.writeFileSync(run.p("result.json"), JSON.stringify({ ok, results, outbound, notes: ctx.notes }, null, 2));
  if (opts.proof) writeProof(run, results, outbound, ctx.notes, opts.streak);
  activeRun = null;
  if (!opts.keep) fs.rmSync(run.dir, { recursive: true, force: true });
  else console.log(`state kept in ${run.dir}`);
  return ok;
}

function sampleOutbound(run) {
  const pids = Object.values(run.state.procs).filter((p) => !p.stoppedAt).flatMap((p) => groupMembers(p.pid).map((m) => m.pid));
  for (const o of outboundOf(pids)) {
    run.state.outbound ??= [];
    if (!run.state.outbound.some((x) => x.conn === o.conn)) { run.state.outbound.push(o); run.save(); }
  }
}

const fmtRow = (r) =>
  `${String(r.n).padStart(2)}. ${r.title.padEnd(48)} ${r.status.toUpperCase().padEnd(7)} ${(r.ms / 1000).toFixed(1).padStart(6)}s  ${r.reason}`;

const STEP_FNS = {
  async 1(ctx) {
    const { run } = ctx;
    await startEdge(run);
    // Exercise the real Worker, not just a fake accepting our chosen identity.
    for (const bearer of [undefined, "arbitrary@org", crypto.randomUUID() + crypto.randomUUID()]) {
      const r = await http("GET", `${edgeUrl(run)}/auth/local-session`, { bearer });
      if (r.status !== 401) throw new Error(`invalid/missing local session answered ${r.status}, expected 401`);
    }
    const session = await http("GET", `${edgeUrl(run)}/auth/local-session`, { bearer: run.state.identity.bearer });
    if (session.status !== 200 || session.json?.mode !== "local" || session.json?.userId !== run.state.identity.user) {
      throw new Error("the configured local session was not verified by the Worker");
    }
    const protectedUrl = `${edgeUrl(run)}/registry/${run.state.identity.org}/rows`;
    if ((await http("GET", protectedUrl)).status !== 401) throw new Error("registry accepted a missing bearer");
    if ((await http("GET", protectedUrl, { bearer: run.state.identity.bearer })).status !== 200) {
      throw new Error("registry rejected the session's permitted org");
    }
    if ((await http("GET", `${edgeUrl(run)}/registry/org-other-synthetic/rows`, { bearer: run.state.identity.bearer })).status !== 403) {
      throw new Error("registry accepted a cross-org local session");
    }
    // A live local Worker must still reject an engine with a forged session.
    for (const sub of ["home", "data"]) fs.mkdirSync(run.p("rejected", sub), { recursive: true });
    run.state.ports.rejected = await freePort();
    const rejected = spawnSync(path.join(BIN, "harness-engine"), ["headless"], {
      cwd: run.p("rejected"), env: { ...engineEnv(run, "rejected"), HARNESS_EDGE_TOKEN: "not-a-valid-session" },
      encoding: "utf8", timeout: 15_000, killSignal: "SIGKILL",
    });
    if (rejected.error || rejected.status === 0 || !rejected.stderr.includes("InvalidLocalSession")) {
      throw new Error(`engine did not reject a forged local session (exit ${rejected.status})`);
    }
    return { reason: `wrangler dev --local; missing/forged/stale sessions rejected; registry no-bearer 401, own-org 200, cross-org 403; forged-session engine refused startup; ${Object.keys(run.state.ports).length} loopback ports` };
  },

  async 2(ctx) {
    const { rpc, info } = await startEngine(ctx.run, "a");
    ctx.a = rpc;
    return { reason: `harness-engine ${info.version}, scope ${info.workspaceScope}` };
  },

  async 3(ctx) {
    const { run, a } = ctx;
    const { user, org, bearer } = run.state.identity;
    const devA = run.state.devices.a;
    // The engine's own CLI, on A's isolated profile.
    const cli = spawnSync(path.join(BIN, "harness-engine"), ["status"], { env: engineEnv(run, "a"), encoding: "utf8", timeout: 30_000 });
    if (cli.status !== 0) throw new Error(`harness-engine status exited ${cli.status}: ${cli.stdout}${cli.stderr}`);
    if (!/Engine:\s+running/.test(cli.stdout)) throw new Error(`harness-engine status: ${cli.stdout.trim()}`);
    // RPC: the auth state.
    const auth = a.watch("AuthStatus", {});
    const st = await auth.waitFor((i) => i.find((x) => x?.state), 10_000, "an AuthStatus item");
    auth.cancel();
    if (st.state !== "signedIn" || st.user?.id !== user || st.orgId !== org) {
      throw new Error(`AuthStatus ${JSON.stringify(st)}; expected signedIn as ${user} in ${org}`);
    }
    // The Worker lists the user's workspace; the engine syncs that one.
    const orgs = await http("GET", `${edgeUrl(run)}/auth/orgs`, { bearer });
    if (orgs.status !== 200 || orgs.json?.orgs?.[0]?.id !== org) throw new Error(`GET /auth/orgs answered ${orgs.status} ${orgs.text}`);
    const engineOrgs = await a.call("ListOrgs", {});
    // Creating one: the Worker has no organization creation in any auth mode.
    const create = await http("POST", `${edgeUrl(run)}/auth/orgs`, { bearer, body: { name: "Synthetic Org" } });
    if (create.status !== 405) throw new Error(`POST /auth/orgs answered ${create.status}, expected the Worker's 405`);
    // The device: its registry row and its relay room's host.
    await until("A's device row on the Worker", 30_000, async () => (await edgeRows(run)).some((r) => r.kind === "devices" && r.id === devA));
    const status = await until("A's device room to show its host", 30_000, async () => {
      const r = await http("GET", `${edgeUrl(run)}/device/${devA}/status`, { bearer });
      return r.status === 200 && r.json?.hostConnected ? r.json : null;
    });
    return {
      reason: `CLI status ok; AuthStatus signedIn ${user} in ${org} (= /auth/orgs); engine ListOrgs ${JSON.stringify(engineOrgs.orgs)} (dev mode); ` +
        `org creation not offered by the Worker (405); device row + relay host online (${status.hostSockets} socket)`,
    };
  },

  async 4(ctx) {
    const { run, a } = ctx;
    const devA = run.state.devices.a;
    const { repo, spaceId } = await seedProject(run, a, devA);
    const chatId = `chat-synthetic-${rand(8)}`;
    await a.call("Mutate", { op: "createChat", chatId, spaceId, config: { harness: "mock", modelOptions: {}, sandbox: "workspace-write" } });
    const prompt = "Summarise the synthetic demo repo";
    const w = a.watch("WatchDocMessages", { chatId, openingTail: true });
    await runPrompt(a, chatId, repo, prompt);
    await w.waitFor((items) => { const r = lastReset(items); return r && assistantDone(r, prompt); }, 60_000, "the mock turn to complete");
    w.cancel();
    const msgs = await readTranscript(a, chatId, 10_000, (r) => assistantDone(r, prompt), "the transcript read back");
    const tools = msgs.flatMap((m) => m.parts ?? []).filter((p) => p.kind === "tool").length;
    Object.assign(ctx, { chatId, repo, prompt1: prompt });
    run.state.chatId = chatId; run.save();
    return { reason: `${msgs.length} messages read back, assistant complete, ${tools} tool parts` };
  },

  async 5(ctx) {
    const { run, chatId, prompt1 } = ctx;
    const { bearer } = run.state.identity;
    const devA = run.state.devices.a;
    const row = await until("the chat's registry row on the Worker", 30_000, async () =>
      (await edgeRows(run)).find((r) => r.kind === "chats" && r.id === chatId && r.fields?.deviceId === devA));
    const space = (await edgeRows(run)).find((r) => r.kind === "spaces" && r.fields?.deviceId === devA);
    const tail = await until("the chat's history (tail) on the Worker", 30_000, async () => {
      const r = await http("GET", `${edgeUrl(run)}/chat2/${chatId}/tail`, { bearer });
      return r.status === 200 && Array.isArray(r.json?.messages) && assistantDone(r.json.messages, prompt1) ? r.json : null;
    });
    const stats = await http("GET", `${edgeUrl(run)}/chat2/${chatId}/stats`, { bearer });
    ctx.notes.push(`chat2 log for the chat: headSeq ${stats.json?.headSeq} (the Zig engine writes no Loro rows; history is the host-published tail)`);
    return {
      reason: `chats row (title "${row.fields?.title ?? ""}", host A), spaces row ${space ? "present" : "MISSING"}; ` +
        `/chat2/:id/tail ${tail.messages.length} messages with the turn; chat2 log headSeq ${stats.json?.headSeq}`,
      status: space ? "pass" : "fail",
    };
  },

  async 6(ctx) {
    const { run, a, chatId, repo, prompt1 } = ctx;
    const { bearer } = run.state.identity;
    const devA = run.state.devices.a;
    const { rpc: b } = await startEngine(run, "b");
    ctx.b = b;
    const devB = run.state.devices.b;
    await until("B's device row on the Worker", 30_000, async () => (await edgeRows(run)).some((r) => r.kind === "devices" && r.id === devB));
    const chats = b.watch("WatchChats", {});
    const listed = await chats.waitFor((items) => items.at(-1)?.find?.((c) => c.id === chatId && c.deviceId === devA), 30_000, "A's chat in B's list");
    chats.cancel();
    await readTranscript(b, chatId, 30_000, (r) => assistantDone(r, prompt1), "A's transcript on B");
    // B → A through the Worker's device room.
    const prompt2 = "Second device asking: list the files";
    const wa = a.watch("WatchDocMessages", { chatId, openingTail: true });
    await runPrompt(b, chatId, repo, prompt2);
    await wa.waitFor((items) => { const r = lastReset(items); return r && assistantDone(r, prompt2); }, 60_000, "the relayed turn to run on A");
    wa.cancel();
    await readTranscript(b, chatId, 45_000, (r) => assistantDone(r, prompt2) && hasText(r, prompt1), "the relayed reply on B");
    const tail = await http("GET", `${edgeUrl(run)}/chat2/${chatId}/tail`, { bearer });
    if (!hasText(tail.json?.messages ?? [], prompt1) || !hasText(tail.json?.messages ?? [], prompt2)) {
      throw new Error("the Worker's tail lost a turn after the relayed prompt");
    }
    ctx.prompt2 = prompt2;
    return { reason: `B lists "${listed.title}" hosted on A and reads it; B's prompt ran on A, reply on B, Worker tail has both turns` };
  },

  async 7(ctx) {
    const { run, a, b, chatId, repo } = ctx;
    const { bearer } = run.state.identity;
    const devA = run.state.devices.a, devB = run.state.devices.b;
    const parts = [];
    let failed = false;
    // Rooms: A creates and posts, B joins and reads.
    {
      const roomReq = (rpc, method, p, body, query = []) => rpc.call("RoomRequest", { method, path: p, query, body });
      const made = await roomReq(a, "POST", "rooms", { name: "Synthetic room", member: "agent-a", device: devA });
      const roomId = made?.body?.room?.id;
      if (made?.status !== 201 || !roomId) throw new Error(`room create answered ${JSON.stringify(made).slice(0, 300)}`);
      const posted = await roomReq(a, "POST", `room/${roomId}/post`, { member: "agent-a", device: devA, body: "Hello from synthetic device A" });
      if (posted?.status !== 200) throw new Error(`room post answered ${JSON.stringify(posted).slice(0, 300)}`);
      const joined = await roomReq(b, "POST", `room/${roomId}/join`, { member: "agent-b", device: devB });
      if (joined?.status !== 200) throw new Error(`room join from B answered ${JSON.stringify(joined).slice(0, 300)}`);
      const read = await roomReq(b, "GET", `room/${roomId}/messages`, null, [["member", "agent-b"], ["device", devB]]);
      const seen = JSON.stringify(read?.body ?? "").includes("Hello from synthetic device A");
      if (!seen) failed = true;
      parts.push(`room: ${seen ? "B read A's post" : `B did not read A's post (${JSON.stringify(read).slice(0, 200)})`}`);
    }
    // Tool blob: only if a turn uploaded one.
    {
      const msgs = await readTranscript(a, chatId, 10_000, () => true, "A's transcript");
      const refs = msgs.flatMap((m) => m.parts ?? []).map((p) => p.blobRef ?? p.outputRef ?? p.call?.outputRef).filter(Boolean);
      let fetchNote;
      // The read path, with a blob the Worker holds for this user (as a Rust host's sidecar would be).
      const partId = "tool-synthetic-1";
      const put = await http("PUT", `${edgeUrl(run)}/blob/${chatId}/${partId}`, { bearer, body: "synthetic full tool output\n", headers: { "content-type": "text/plain; charset=utf-8" } });
      try {
        const got = await b.call("FetchToolBlob", { blobRef: `${chatId}/${partId}` });
        fetchNote = put.status === 200 && got?.text === "synthetic full tool output\n" ? "FetchToolBlob of a Worker-held blob ok" : `FetchToolBlob answered ${JSON.stringify(got)}`;
        if (!fetchNote.endsWith("ok")) failed = true;
      } catch (e) { fetchNote = `FetchToolBlob failed: ${e.message}`; failed = true; }
      parts.push(refs.length ? `tool blob: ${refs.length} refs` : `tool blob: skipped, no turn produced one (the Zig engine uploads no tool sidecars); ${fetchNote}`);
    }
    // Attachment: uploaded on B for the chat's host, sent with a relayed prompt.
    {
      const uploadId = uuid();
      const bytes = Buffer.from("Synthetic attachment: three made-up facts.\n");
      await b.call("UploadChunk", { uploadId, seq: 0, data: bytes.toString("base64"), targetDeviceId: devA });
      const commit = await b.call("UploadCommit", { uploadId, fileName: "synthetic-note.txt", targetDeviceId: devA });
      const p = commit?.path ?? "";
      const onA = p.startsWith(run.p("a")) && fs.existsSync(p) && fs.readFileSync(p).equals(bytes);
      const prompt3 = `Read the attached note.\n\nAttached images (local files — open them to view):\n- ${p}`;
      await runPrompt(b, chatId, repo, prompt3);
      await readTranscript(a, chatId, 60_000, (r) => assistantDone(r, "Read the attached note.") && hasText(r, path.basename(p)), "the attachment prompt on A");
      if (!onA) failed = true;
      parts.push(`attachment: ${onA ? "landed in A's uploads" : `not on A (${run.scrub(p)})`}, relayed prompt ran on A`);
    }
    return { status: failed ? "fail" : "pass", reason: parts.join("; ") };
  },

  async 8(ctx) {
    const { run, chatId, prompt1, prompt2 } = ctx;
    const { bearer, org, user } = run.state.identity;
    ctx.a.close();
    await run.stop("engine-a");
    await run.stop("edge");
    await startEdge(run);
    const { rpc: a } = await startEngine(run, "a");
    ctx.a = a;
    const auth = a.watch("AuthStatus", {});
    const st = await auth.waitFor((i) => i.find((x) => x?.state), 10_000, "AuthStatus after restart");
    auth.cancel();
    if (st.state !== "signedIn" || st.user?.id !== user || st.orgId !== org) throw new Error(`AuthStatus after restart ${JSON.stringify(st)}`);
    const chats = a.watch("WatchChats", {});
    await chats.waitFor((items) => items.at(-1)?.find?.((c) => c.id === chatId), 20_000, "the chat in A's list after restart");
    chats.cancel();
    await readTranscript(a, chatId, 20_000, (r) => assistantDone(r, prompt1) && assistantDone(r, prompt2), "both turns in A's transcript after restart");
    const tail = await http("GET", `${edgeUrl(run)}/chat2/${chatId}/tail`, { bearer });
    if (!hasText(tail.json?.messages ?? [], prompt1)) throw new Error("the Worker's tail did not survive its restart");
    // Signed in and syncing: a rename reaches the Worker's row.
    const title = "Synthetic chat, renamed after restart";
    await a.call("Mutate", { op: "renameChat", chatId, title });
    await until("the rename on the Worker", 30_000, async () => (await edgeRows(run)).some((r) => r.kind === "chats" && r.id === chatId && r.fields?.title === title));
    ctx.notes.push("agent rooms are in the Worker's in-memory dev store without Hyperdrive, so an edge restart empties them");
    return { reason: "A signed in again (verified local session), chat + both turns local, Worker tail + rows persisted, a rename synced" };
  },

  async 9(ctx) {
    const { run } = ctx;
    for (const c of [ctx.a, ctx.b]) c?.close();
    const errors = await run.stopAll();
    const left = [];
    for (const [name, pr] of Object.entries(run.state.procs)) {
      if (groupAlive(pr.pid)) left.push(`${name} (${groupMembers(pr.pid).map((m) => m.comm).join(", ")})`);
    }
    const ports = [...Object.values(run.state.ports), ...run.state.extraListeners.map((l) => l.port)];
    const open = [];
    for (const port of new Set(ports)) if (await portListening(port)) open.push(port);
    if (errors.length || left.length || open.length) {
      throw new Error([...errors, left.length ? `still running: ${left.join("; ")}` : "", open.length ? `still listening: ${open.join(", ")}` : ""].filter(Boolean).join("; "));
    }
    return { reason: `${Object.keys(run.state.procs).length} process groups stopped; ${new Set(ports).size} ports closed` };
  },
};

const allPassed = (results) => results.every((r) => r.status !== "fail");

function toolVersions() {
  const v = (cmd, args, opts) => (spawnSync(cmd, args, { encoding: "utf8", ...opts }).stdout ?? "").trim().split("\n")[0];
  return {
    commit: v("git", ["rev-parse", "--short", "HEAD"], { cwd: ROOT }),
    zig: v("zig", ["version"]),
    node: process.version,
    wrangler: v(WRANGLER, ["--version"], { env: { ...process.env, WRANGLER_SEND_METRICS: "false", WRANGLER_HIDE_BANNER: "true" } }),
    engine: v(path.join(BIN, "harness-engine"), ["version"], { env: { PATH: SYS_PATH } }),
  };
}

function writeProof(run, results, outbound, notes, streak = 1) {
  const file = path.join(ROOT, "apps/nano/docs/proof/LOCAL-EDGE.md");
  const tv = toolVersions();
  const begin = "<!-- local-edge:run:begin -->", end = "<!-- local-edge:run:end -->";
  const block = [
    begin,
    `Last \`scripts/local-edge.sh check\` run: commit \`${tv.commit}\`, ${tv.engine}, Zig ${tv.zig}, Node ${tv.node}, wrangler ${tv.wrangler.replace(/^.*?(\d+\.\d+\.\d+).*$/, "$1")} (the lockfile's). ${allPassed(results) ? `Passed; run ${streak} of ${streak} in a row.` : "Failed."}`,
    "",
    "| Step | | Result | Time | Detail |",
    "|---|---|---|---|---|",
    ...results.map((r) => `| ${r.n} | ${r.title} | ${r.status} | ${(r.ms / 1000).toFixed(1)} s | ${r.reason.replaceAll("|", "\\|").replaceAll("\n", " ")} |`),
    "",
    `Non-loopback connections seen from the edge and engines during the run: ${outbound.length ? outbound.map((o) => `${o.comm} → ${o.conn.split("->")[1]}`).join(", ") : "none"}.`,
    ...notes.map((n) => `- ${run.scrub(n)}`),
    end,
  ].join("\n");
  let doc = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : `# The Zig engine against the local edge\n\n${begin}\n${end}\n`;
  if (!doc.includes(begin)) doc += `\n${begin}\n${end}\n`;
  doc = doc.slice(0, doc.indexOf(begin)) + block + doc.slice(doc.indexOf(end) + end.length);
  fs.writeFileSync(file, doc);
  console.log(`wrote ${path.relative(ROOT, file)}`);
}

// ── up / down / status ─────────────────────────────────────────────────────

function nanoEnv(run, dev) {
  return {
    PATH: SYS_PATH,
    HOME: run.p(dev, "home"),
    TMPDIR: run.p("tmp"),
    LANG: "en_US.UTF-8",
    HARNESS_DATA_DIR: run.p(dev, "data"),
    HARNESS_IPC_PORT: String(run.state.ports[dev]),
    // Attach to the engine started here; never start (or look for) another.
    HARNESS_NANO_NO_ENGINE_START: "1",
    // Nothing leaves the machine: no release manifest, no graff download.
    HARNESS_NANO_NO_RELEASE_CHECK: "1",
    GRAFF_EXECUTABLE: "/nonexistent/graff",
    HARNESS_NANO_HARNESS: "mock",
    HARNESS_NANO_OPEN_CHAT: run.state.chatId,
  };
}

async function up(opts) {
  const prev = currentRun();
  if (prev && Object.keys(prev.state.procs).some((n) => prev.alive(n))) {
    throw new Error(`a local edge is already up (state ${prev.dir}); run \`scripts/local-edge.sh down\` first`);
  }
  const run = Run.create();
  activeRun = run;
  run.state.mode = "up";
  run.state.identity = newIdentity();
  run.state.expiresAt = Date.now() + opts.ttlMinutes * 60_000;
  run.save();
  fs.writeFileSync(POINTER, run.dir);
  const fail = async (e) => { await run.stopAll(); fs.rmSync(POINTER, { force: true }); throw e; };
  try {
    // The watchdog stops everything when the time is up, if `down` didn't.
    run.start("watchdog", process.execPath, [fileURLToPath(import.meta.url), "watchdog", run.dir], { cwd: run.dir, env: { PATH: process.env.PATH } });
    await startEdge(run);
    const { rpc: a } = await startEngine(run, "a");
    const { repo, spaceId } = await seedProject(run, a, run.state.devices.a);
    const chatId = `chat-synthetic-${rand(8)}`;
    await a.call("Mutate", { op: "createChat", chatId, spaceId, config: { harness: "mock", modelOptions: {}, sandbox: "workspace-write" } });
    run.state.chatId = chatId; run.state.repo = repo; run.save();
    await runPrompt(a, chatId, repo, "Summarise the synthetic demo repo");
    await readTranscript(a, chatId, 60_000, (r) => assistantDone(r, "Summarise the synthetic demo repo"), "the seeded turn");
    await until("the seeded chat on the Worker", 30_000, async () => (await edgeRows(run)).some((r) => r.kind === "chats" && r.id === chatId));
    a.close();
    if (opts.phone) {
      const { rpc: b } = await startEngine(run, "b");
      await until("B's device row on the Worker", 30_000, async () => (await edgeRows(run)).some((r) => r.kind === "devices" && r.id === run.state.devices.b));
      const chats = b.watch("WatchChats", {});
      await chats.waitFor((items) => items.at(-1)?.find?.((c) => c.id === chatId), 30_000, "the seeded chat on B");
      b.close();
    }
    if (!opts.noApp) {
      const nano = path.join(BIN, "harness-nano");
      run.start("app-a", nano, [], { cwd: run.p("a"), env: nanoEnv(run, "a") });
      if (opts.phone) run.start("app-b", nano, ["--mobile"], { cwd: run.p("b"), env: nanoEnv(run, "b") });
      await sleep(2000);
      for (const n of ["app-a", ...(opts.phone ? ["app-b"] : [])]) if (!run.alive(n)) throw new Error(`${n} exited at once (see ${run.p("logs", `${n}.log`)})`);
    }
  } catch (e) { await fail(e); }
  activeRun = null;
  printStatus(run);
}

function currentRun() {
  if (!fs.existsSync(POINTER)) return null;
  const dir = fs.readFileSync(POINTER, "utf8").trim();
  return fs.existsSync(path.join(dir, "state.json")) ? new Run(dir) : null;
}

function printStatus(run) {
  const s = run.state;
  console.log(`local edge (${s.mode}), state in ${run.dir}`);
  console.log(`  user ${s.identity.user}, workspace ${s.identity.org} (verified local session)`);
  console.log(`  expires ${new Date(s.expiresAt).toLocaleTimeString()} (the watchdog stops it then)`);
  const where = {
    edge: `http://127.0.0.1:${s.ports.edge} (inspector ${s.ports.inspector})`,
    "engine-a": `ws://127.0.0.1:${s.ports.a}, device ${s.devices?.a}`,
    "engine-b": `ws://127.0.0.1:${s.ports.b}, device ${s.devices?.b}`,
    "app-a": "harness-nano window on engine A",
    "app-b": "harness-nano --mobile window on engine B",
    watchdog: "stops everything at expiry",
  };
  for (const [name, pr] of Object.entries(s.procs)) {
    console.log(`  ${run.alive(name) ? "running" : "stopped"}  ${name.padEnd(9)} pid ${String(pr.pid).padEnd(6)} ${where[name] ?? ""}`);
  }
  if (s.chatId) console.log(`  seeded chat ${s.chatId} in the synthetic repo`);
  console.log(`  logs: ${run.p("logs")}`);
  console.log("  the ephemeral local session is stored only in the temporary state folder");
  console.log("  stop: scripts/local-edge.sh down");
}

async function down() {
  const run = currentRun();
  if (!run) { console.log("local edge: nothing is up"); return true; }
  const errors = await run.stopAll();
  const open = [];
  for (const port of new Set([...Object.values(run.state.ports), ...run.state.extraListeners.map((l) => l.port)])) {
    if (await portListening(port)) open.push(port);
  }
  for (const e of errors) console.error(`local edge: ${e}`);
  if (open.length) console.error(`local edge: still listening on ${open.join(", ")}`);
  if (errors.length || open.length) return false;
  fs.rmSync(run.dir, { recursive: true, force: true });
  fs.rmSync(POINTER, { force: true });
  console.log(`local edge: stopped ${Object.keys(run.state.procs).length} process groups; removed its state`);
  return true;
}

async function watchdog(dir) {
  const run = new Run(dir);
  const ms = Math.max(0, run.state.expiresAt - Date.now());
  await sleep(ms);
  for (const name of Object.keys(run.state.procs).filter((n) => n !== "watchdog").reverse()) {
    try { await run.stop(name); } catch {}
  }
}

// ── main ───────────────────────────────────────────────────────────────────

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const flag = (f) => rest.includes(f);
  const value = (f, d) => { const i = rest.indexOf(f); return i >= 0 ? Number(rest[i + 1]) : d; };
  switch (cmd) {
    case "check": {
      const runs = value("--repeat", 1);
      let passed = 0;
      for (let i = 1; i <= runs; i++) {
        if (runs > 1) console.log(`── run ${i} of ${runs}`);
        const ok = await check({ proof: flag("--proof") && i === runs, streak: i, keep: flag("--keep"), maxMinutes: value("--max-minutes", 15) });
        if (!ok) { console.log(`check failed on run ${i} (${passed} passed in a row before it)`); return 1; }
        passed++;
      }
      console.log(`check passed${runs > 1 ? ` ${passed} times in a row` : ""}`);
      return 0;
    }
    case "up":
      await up({ phone: flag("--phone"), noApp: flag("--no-app"), ttlMinutes: value("--ttl-minutes", 120) });
      return 0;
    case "down":
      return (await down()) ? 0 : 1;
    case "status": {
      const run = currentRun();
      if (!run) { console.log("local edge: nothing is up"); return 0; }
      printStatus(run);
      return 0;
    }
    case "watchdog":
      await watchdog(rest[0]);
      return 0;
    default:
      console.log("usage: scripts/local-edge.sh check [--repeat N] [--proof] [--keep] | up [--phone] [--ttl-minutes N] | down | status");
      return cmd ? 2 : 0;
  }
}

// A check's processes never outlive it, and neither do those of an `up`
// that is still starting; a finished `up` hands its own to `down`.
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    if (activeRun) await activeRun.stopAll();
    process.exit(130);
  });
}

main().then((code) => process.exit(code), async (e) => {
  console.error(`local-edge: ${e.message}`);
  if (activeRun) await activeRun.stopAll();
  process.exit(1);
});
