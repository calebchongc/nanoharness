#!/usr/bin/env node
// Isolated iOS Simulator consumer of the real local Worker/Loro demo.
// This uses a simulator-target STATIC Rust bridge, not the macOS dylib.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { Run, http, until, runPrompt } from "./local-edge/main.mjs";
import { Rpc } from "./local-edge/rpc.mjs";
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIR = path.join(ROOT, "target/nano-simulator-demo");
const CONFIG = path.join(DIR, "config.json");
const POINTER = path.join(os.tmpdir(), "harness-local-edge.current");
const UDID = process.env.HARNESS_IOS_SIM_UDID;
const APP = path.join(ROOT, "apps/nano/zig-out/ios/Harness.app");
const ID = "harness.codegraff.ios.nano.localsync-adaptation";
const arg = process.argv[2] ?? "status";
fs.mkdirSync(DIR, { recursive: true });
const load = () => JSON.parse(fs.readFileSync(CONFIG, "utf8"));
const save = (s) => fs.writeFileSync(CONFIG, JSON.stringify(s, null, 2));
function command(cmd, args, options = {}) {
  const p = spawnSync(cmd, args, { cwd: ROOT, encoding: "utf8", timeout: 90_000, ...options });
  if (p.status !== 0) throw new Error(`${path.basename(cmd)} ${args[0]} failed: ${(p.stderr ?? p.stdout ?? "").slice(-1800)}`);
  return p.stdout.trim();
}
function sim(s, args, options = {}) { return command("/usr/bin/xcrun", ["simctl", ...args], options); }
function backend(s) {
  if (!s.runDir || !fs.existsSync(path.join(s.runDir, "state.json"))) throw new Error("this demo's backend is not running");
  return new Run(s.runDir);
}
function launch(s) {
  const run = backend(s), id = run.state.identity;
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("SIMCTL_CHILD_")));
  Object.assign(env, {
    SIMCTL_CHILD_HARNESS_LOCAL_EDGE_AUTH: "1",
    SIMCTL_CHILD_HARNESS_EDGE_URL: `http://127.0.0.1:${run.state.ports.edge}`,
    SIMCTL_CHILD_HARNESS_EDGE_TOKEN: id.bearer,
    SIMCTL_CHILD_HARNESS_ORG_ID: id.org,
    SIMCTL_CHILD_HARNESS_CODEGRAFF_CLIENT_ID: "",
    SIMCTL_CHILD_HARNESS_NANO_NO_RELEASE_CHECK: "1",
    SIMCTL_CHILD_HARNESS_NANO_HARNESS: "mock",
    SIMCTL_CHILD_HARNESS_SETUP_OFF: "1",
    SIMCTL_CHILD_HARNESS_NANO_OPEN_CHAT: run.state.chatId,
  });
  const out = sim(s, ["launch", s.udid, s.bundleId], { env });
  const pid = Number(out.split(":").at(-1).trim());
  if (!Number.isInteger(pid) || pid <= 0) throw new Error("simctl returned no app pid");
  s.pid = pid; save(s); console.log(`launched synthetic simulator app, pid ${pid}`);
}
async function connect(s) {
  const port = await until("embedded simulator loopback RPC", 45_000, () => {
    const p = spawnSync("/usr/sbin/lsof", ["-nP", "-a", "-p", String(s.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], { encoding: "utf8", timeout: 5000 });
    const line = p.stdout.split("\n").find((x) => /^n127\.0\.0\.1:\d+$/.test(x));
    return line ? Number(line.split(":").at(-1)) : null;
  });
  s.port = port; save(s);
  return Rpc.connect(port);
}
async function queueHas(rpc, chatId, ids) {
  const w = rpc.watch("WatchQueue", { chatId });
  try { return await w.waitFor((items) => items.findLast((x) => ids.every((id) => x?.items?.some((q) => q.id === id))), 45_000, "real Loro queue rows"); }
  finally { w.cancel(); }
}
async function history(rpc, chatId, prompt) {
  const w = rpc.watch("WatchDocMessages", { chatId, openingTail: false });
  try { return await w.waitFor((items) => items.findLast((x) => {
    const rows = x?.reset;
    if (!Array.isArray(rows)) return false;
    const at = rows.findIndex((m) => m.role === "user" && m.parts?.some((p) => p.text?.includes(prompt)));
    return at >= 0 && rows.slice(at + 1).some((m) => m.role === "assistant" && m.status === "complete" && m.parts?.some((p) => p.text?.length));
  }), 45_000, "completed synced transcript"); }
  finally { w.cancel(); }
}

if (arg === "up") {
  if (!UDID) throw new Error("set HARNESS_IOS_SIM_UDID explicitly; no default personal simulator");
  const existing = fs.existsSync(CONFIG) ? load() : null;
  const container = spawnSync("/usr/bin/xcrun", ["simctl", "get_app_container", UDID, ID, "data"], { encoding: "utf8", timeout: 15_000 });
  if (container.status === 0 && (!existing || existing.udid !== UDID || existing.bundleId !== ID)) throw new Error("bundle already installed without this demo's ownership record; refusing replacement");
  if (fs.existsSync(POINTER)) throw new Error("another local-edge pointer exists; refusing to replace it");
  sim({}, ["bootstatus", UDID, "-b"]);
  const platform = command("/usr/bin/otool", ["-l", path.join(APP, "harness-nano")]);
  if (!/platform\s+(7|IOSSIMULATOR)\b/.test(platform)) throw new Error("not an iOS SIMULATOR Mach-O");
  const bundleId = command("/usr/bin/plutil", ["-extract", "CFBundleIdentifier", "raw", path.join(APP, "Info.plist")]);
  if (bundleId !== ID) throw new Error("bundle identifier is not the isolated local-sync build");
  const s = { udid: UDID, bundleId: ID };
  save(s); // Claim only our separate identifier before first install.
  command(path.join(ROOT, "scripts/local-loro.sh"), ["up", "--no-app", "--ttl-minutes", "120"], {
    env: { ...process.env, LOCAL_LORO_NO_BUILD: "1", HARNESS_NANO_NO_RELEASE_CHECK: "1" },
  });
  s.runDir = fs.readFileSync(POINTER, "utf8").trim(); save(s);
  sim(s, ["install", s.udid, APP]); launch(s);
  const run = backend(s);
  run.start("simulator-watchdog", process.execPath, [fileURLToPath(import.meta.url), "watchdog"], { cwd: ROOT, env: { PATH: process.env.PATH } });
  const developer = process.env.DEVELOPER_DIR ?? command("/usr/bin/xcode-select", ["-p"]);
  const simulatorApp = path.join(developer, "Applications/Simulator.app");
  if (fs.existsSync(simulatorApp)) command("/usr/bin/open", [simulatorApp, "--args", "-CurrentDeviceUDID", s.udid]);
  else console.log("Simulator.app is not installed; select the running iPhone simulator in Harness Device Manager");
  console.log("backend and simulator app left running; TTL 120 minutes; stop: node scripts/local-loro-simulator.mjs down");
} else if (arg === "check") {
  const s = load(), run = backend(s), chat = run.state.chatId;
  let phone = await connect(s), host = await Rpc.connect(run.state.ports.a);
  try {
    const info = await phone.call("EngineInfo");
    const aw = phone.watch("AuthStatus", {});
    let auth;
    try { auth = await aw.waitFor((items) => items.find((x) => x?.state), 10_000, "verified local session"); }
    finally { aw.cancel(); }
    if (!info.loroSync || info.loroDynamic || info.workspaceScope !== "development" || auth.state !== "signedIn") throw new Error("not a verified simulator static-Loro local session");
    await history(phone, chat, "Summarise the synthetic demo repo");
    const stats = async () => (await http("GET", `http://127.0.0.1:${run.state.ports.edge}/chat2/${chat}/stats`, { bearer: run.state.identity.bearer })).json;
    const before = await stats();
    const id = `q-simulator-${Date.now()}`;
    await phone.call("QueueMessage", { chatId: chat, id, text: "Live iOS Simulator Loro update", holdForTurnEnd: true });
    await queueHas(host, chat, [id]);
    const fromPhone = await stats(); if (!(fromPhone.headSeq > before.headSeq)) throw new Error("no Worker update from simulator");
    const back = `q-host-${Date.now()}`;
    await host.call("QueueMessage", { chatId: chat, id: back, text: "Host-to-simulator Loro reply", holdForTurnEnd: true });
    await queueHas(phone, chat, [id, back]);
    phone.close(); sim(s, ["terminate", s.udid, s.bundleId]); launch(s); phone = await connect(s);
    await queueHas(phone, chat, [id, back]);
    await history(phone, chat, "Summarise the synthetic demo repo");
    const prompt = `Live simulator round trip after restart ${Date.now()}`;
    await runPrompt(phone, chat, run.state.repo, prompt);
    await history(host, chat, prompt); await history(phone, chat, prompt);
    const final = await stats();
    const result = { simulatorPlatform: "iOS Simulator arm64", staticRetainedLoro: true, signedIn: true, simulatorToWorkerToHost: true, hostToSimulator: true, survivedAppRestart: true, remotePromptReturned: true, initialSeq: before.headSeq, simulatorSeq: fromPhone.headSeq, finalSeq: final.headSeq };
    fs.writeFileSync(path.join(DIR, "result.json"), JSON.stringify(result, null, 2)); console.log(JSON.stringify(result));
  } finally { phone.close(); host.close(); }
} else if (arg === "down") {
  const s = load();
  spawnSync("/usr/bin/xcrun", ["simctl", "terminate", s.udid, s.bundleId], { timeout: 15_000 });
  if (fs.existsSync(POINTER) && fs.readFileSync(POINTER, "utf8").trim() === s.runDir) command(path.join(ROOT, "scripts/local-loro.sh"), ["down"]);
  console.log("stopped only this simulator app and its owned local backend; app/container retained");
} else if (arg === "watchdog") {
  const s = load(), run = backend(s);
  setTimeout(() => { spawnSync("/usr/bin/xcrun", ["simctl", "terminate", s.udid, s.bundleId], { timeout: 15_000 }); }, Math.max(0, run.state.expiresAt - Date.now() - 5_000));
} else if (arg === "status") {
  const s = load(); console.log(JSON.stringify({ bundleId: s.bundleId, simulator: s.udid, pid: s.pid, loopbackRpcPort: s.port, expiresAt: backend(s).state.expiresAt }));
} else { throw new Error("usage: node scripts/local-loro-simulator.mjs up|check|status|down"); }
