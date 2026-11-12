// Real retained-Loro acceptance: local Worker, two native Zig engines and
// harness-sync's real Rust ChatClient. No JSON-tail path can satisfy it.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Run, startEdge, startEngine, newIdentity, edgeUrl, seedProject, runPrompt, http, until, portListening } from "./main.mjs";
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const PEER = path.join(ROOT, "target/nano-loro/debug/examples/local_peer");
const SWIFT = process.env.LOCAL_LORO_SWIFT_BIN ?? path.join(ROOT, "target/nano-loro-swift/out/Products/Debug/LoroCompatibility");
let swiftApplied = false;
const run = Run.create();
run.state.mode = "full-sync";
run.state.identity = newIdentity(); run.save();
const chat = "synthetic-loro-fixture";
const rustDir = run.p("rust-peer");
const results = [];
let a, b;
const close = () => { a?.close(); b?.close(); };
const deadline = setTimeout(async () => { close(); await run.stopAll(); console.error("full-sync: exceeded 8 minute deadline"); process.exit(1); }, 8 * 60_000);
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, async () => { close(); await run.stopAll(); process.exit(130); });
function peer(mode, dir = rustDir, extra, mayFail = false) {
  fs.mkdirSync(dir, { recursive: true });
  const p = spawnSync(PEER, [mode, edgeUrl(run), chat, dir, ...(extra ? [extra] : [])], {
    encoding: "utf8", timeout: 75_000, killSignal: "SIGKILL",
    env: { PATH: "/usr/bin:/bin", HOME: run.p("peer-home"), HARNESS_EDGE_TOKEN: run.state.identity.bearer },
  });
  if (p.status !== 0) { if (mayFail) return null; throw new Error(`retained Rust ${mode} failed: ${run.scrub(p.stderr).slice(-2400)}`); }
  const line = p.stdout.split("\n").find((l) => l.startsWith("RESULT:"));
  if (!line) throw new Error(`retained Rust ${mode}: no result`);
  return JSON.parse(line.slice(7));
}
async function step(title, f) {
  const t = Date.now();
  const detail = await f();
  const status = detail?.skipped ? "skipped" : "pass";
  results.push({ title, status, seconds: (Date.now() - t) / 1000, detail });
  console.log(`${status === "pass" ? "PASS" : "SKIP"} ${title}: ${JSON.stringify(detail)}`);
  return detail;
}
async function stats() {
  const r = await http("GET", `${edgeUrl(run)}/chat2/${chat}/stats`, { bearer: run.state.identity.bearer });
  if (r.status !== 200) throw new Error(`chat2 stats ${r.status}`);
  return r.json;
}
const reset = (items) => [...items].reverse().find((i) => Array.isArray(i?.reset))?.reset;
async function history(rpc, pred, label, ms = 45_000) {
  const w = rpc.watch("WatchDocMessages", { chatId: chat, openingTail: false });
  try { return await w.waitFor((items) => { const r = reset(items); return r && pred(r) ? r : null; }, ms, label); }
  finally { w.cancel(); }
}
const text = (m) => (m.parts ?? []).map((p) => p.text ?? "").join("");
const completed = (rows, prompt) => {
  const i = rows.findIndex((m) => m.role === "user" && text(m).includes(prompt));
  return i >= 0 && rows.slice(i + 1).some((m) => m.role === "assistant" && m.status === "complete" && text(m));
};
function assertHistory(rows) {
  if (rows.length < 130 || rows[0].id !== "rust-0" || rows[65].id !== "rust-65") throw new Error("full history first/middle entries missing (tail-only success refused)");
}
async function queueContains(rpc, ids) {
  const w = rpc.watch("WatchQueue", { chatId: chat });
  try { return await w.waitFor((items) => [...items].reverse().find((x) => ids.every((id) => x?.items?.some((q) => q.id === id))), 45_000, "concurrent offline queue rows"); }
  finally { w.cancel(); }
}
let repo;
let passed = false;
try {
  await step("loopback Worker + explicit retained-Loro Zig engine", async () => {
    await startEdge(run);
    const first = await startEngine(run, "a"); a = first.rpc;
    if (first.info.loroSync !== true) throw new Error("engine was not built with retained Loro; refusing legacy/tail-only demo");
    if (first.info.loroDynamic !== true && process.env.LOCAL_LORO_ALLOW_STATIC !== "1") throw new Error("acceptance requires the sideloaded dylib (explicit LOCAL_LORO_ALLOW_STATIC=1 permits static developer tests)");
    ({ repo } = await seedProject(run, a, first.info.deviceId));
    await a.call("Mutate", { op: "createChat", chatId: chat, spaceId: "space-synthetic-demo", config: { harness: "mock", modelOptions: {}, sandbox: "workspace-write" } });
    return { engine: first.info.version, realLoro: first.info.loroSync, dynamicLibrary: first.info.loroDynamic === true };
  });
  await step("retained Rust binary doc -> Worker rows -> native full history", async () => {
    const pending = peer("seed-pending");
    await until("causally pending row durably held before restart", 20_000, () => {
      const q = "SELECT cursor,json_array_length(CAST(substr(bytes,5) AS TEXT),'$.pending') FROM snapshots WHERE doc_id='synthetic-loro-fixture';";
      const r = spawnSync("/usr/bin/sqlite3", [run.p("a", "data", "docs.sqlite"), q], { encoding: "utf8", timeout: 5000 });
      const [cursor, pendingCount] = r.stdout.trim().split("|").map(Number);
      return r.status === 0 && cursor === 0 && pendingCount > 0;
    });
    a.close(); await run.stop("engine-a");
    a = (await startEngine(run, "a")).rpc;
    const seeded = peer("seed-baseline");
    const rows = await history(a, (r) => r.length >= 131, "131 genuine Loro messages after B-before-A restart"); assertHistory(rows);
    if (!pending.dependentFirst) throw new Error("dependent-first setup missing");
    const st = await stats(); if (!(st.headSeq > 0)) throw new Error("Worker has no real update sequence");
    return { ...seeded, dependentBeforePrerequisite: true, pendingPersistedAcrossRestart: true, appliedCursorHeld: 0, headSeq: st.headSeq, messages: rows.length, first: rows[0].id, middle: rows[65].id, last: rows.at(-1).id };
  });
  await step("Zig turn -> retained Rust ChatClient typed document", async () => {
    await runPrompt(a, chat, repo, "Zig writes real Loro updates 🦀 é");
    await history(a, (r) => completed(r, "Zig writes real Loro updates"), "native mock turn");
    const result = peer("inspect");
    if (result.messages < 133 || !result.nativeUnicodeRoundtrip || (!result.rowsApplied && !result.checkpointApplied)) throw new Error("Rust client did not consume real document data with native Unicode content");
    return result;
  });
  await step("Rust document command executes once on Zig host and returns via Loro", async () => {
    const result = peer("send", rustDir, repo);
    const rows = await history(a, (r) => completed(r, "Remote Loro command executes once"), "remote doc command outcome");
    if (result.remoteRunCount !== 1 || rows.filter((m) => m.id === "remote-message").length !== 1) throw new Error("remote command was duplicated");
    return result;
  });
  await step("second Zig device reads >64 messages from document, not tail", async () => {
    const second = await startEngine(run, "b"); b = second.rpc;
    if (!second.info.loroSync) throw new Error("B lacks Loro bridge");
    const rows = await history(b, (r) => r.length >= 135, "full document on B"); assertHistory(rows);
    return { messages: rows.length, first: rows[0].id, middle: rows[65].id, last: rows.at(-1).id };
  });
  await step("offline concurrent Rust/Zig updates survive process and Worker restart", async () => {
    await run.stop("edge");
    await runPrompt(a, chat, repo, "Zig offline turn survives restart");
    await history(a, (r) => completed(r, "Zig offline turn survives restart"), "offline native turn");
    await a.call("QueueMessage", { chatId: chat, id: "q-zig-offline", text: "Zig offline queue row", holdForTurnEnd: true });
    const offline = peer("offline-edit");
    await until("Zig durable outgoing Loro bytes", 20_000, () => {
      const r = spawnSync("/usr/bin/sqlite3", [run.p("a", "data", "docs.sqlite"), "SELECT count(*) FROM chat_outbox;"], { encoding: "utf8", timeout: 5000 });
      return r.status === 0 && Number(r.stdout.trim()) > 0;
    });
    close(); await run.stop("engine-a"); await run.stop("engine-b");
    await startEdge(run);
    // Deliver once but deliberately discard the ACK while the Rust outbox
    // remains durable. Reconnect resends its SAME ID, exercising server dedupe.
    const update = fs.readFileSync(path.join(rustDir, "offline.update"));
    const lost = await http("POST", `${edgeUrl(run)}/chat2/${chat}/rows?device=retained-rust&batchId=rust-offline-stable`, { bearer: run.state.identity.bearer, body: update, headers: { "content-type": "application/octet-stream" } });
    if (lost.status !== 200) throw new Error("lost-ACK setup push refused");
    a = (await startEngine(run, "a")).rpc;
    b = (await startEngine(run, "b")).rpc;
    const resumed = peer("inspect");
    if (resumed.pendingPushes !== 0) throw new Error("Rust outbox did not recover after lost ACK");
    const dup = await http("POST", `${edgeUrl(run)}/chat2/${chat}/rows?device=retained-rust&batchId=rust-offline-stable`, { bearer: run.state.identity.bearer, body: update, headers: { "content-type": "application/octet-stream" } });
    if (!dup.json?.dup || dup.json.seq !== lost.json.seq) throw new Error("stable-ID resend appended a duplicate row");
    const rows = await history(b, (r) => completed(r, "Zig offline turn survives restart"), "offline turn on B after restart"); assertHistory(rows);
    await queueContains(a, ["q-offline", "q-zig-offline"]); await queueContains(b, ["q-offline", "q-zig-offline"]);
    if (rows.filter((m) => m.id === "remote-message").length !== 1) throw new Error("command executed twice after restart");
    return { ...offline, messagesAfterRestart: rows.length, stableDuplicateSeq: dup.json.seq, remoteCommandCount: 1 };
  });
  await step("host checkpoint trims log; fresh Rust and cold Zig catch up below floor", async () => {
    for (let i = 0; i < 4; i++) {
      const before = (await stats()).headSeq;
      await a.call("QueueMessage", { chatId: chat, id: `q-checkpoint-${i}`, text: `checkpoint queue ${i}`, holdForTurnEnd: true });
      await until("new genuine update row", 20_000, async () => (await stats()).headSeq > before);
    }
    const st = await until("host-published checkpoint and trimmed prefix", 30_000, async () => { const s = await stats(); return s.checkpointSeq > 0 && s.seqFloor > 0 ? s : null; });
    const fresh = peer("inspect", run.p("rust-fresh"));
    if (!fresh.checkpointApplied || fresh.messages < 137) throw new Error("fresh retained Rust client did not import checkpoint");
    b.close(); await run.stop("engine-b");
    fs.renameSync(run.p("b", "data"), run.p("b", "saved-data")); // preserve original synthetic evidence
    b = (await startEngine(run, "b")).rpc;
    const rows = await history(b, (r) => r.length >= 137, "cold Zig document checkpoint catchup"); assertHistory(rows);
    return { headSeq: st.headSeq, checkpointSeq: st.checkpointSeq, seqFloor: st.seqFloor, freshRustCheckpoint: fresh.checkpointApplied, coldZigMessages: rows.length };
  });
  await step("pinned Swift core reads native/Rust schema and sends a real Loro update", async () => {
    if (!fs.existsSync(SWIFT)) return { skipped: true, reason: "build pinned Swift compatibility runner with scripts/check-loro-swift.sh" };
    peer("inspect");
    const out = run.p("swift-compat");
    const p = spawnSync(SWIFT, [path.join(rustDir, "rust.snapshot"), path.join(rustDir, "rust.vv"), out], { encoding: "utf8", timeout: 30_000, killSignal: "SIGKILL", env: { PATH: "/usr/bin:/bin", HOME: run.p("swift-home") } });
    if (p.status !== 0) throw new Error(`pinned Swift compatibility failed: ${run.scrub(p.stderr).slice(-1500)}`);
    const result = JSON.parse(p.stdout.split("\n").find((l) => l.startsWith("RESULT:")).slice(7));
    const update = fs.readFileSync(path.join(out, "swift.update"));
    const pushed = await http("POST", `${edgeUrl(run)}/chat2/${chat}/rows?device=retained-swift&batchId=swift-compat-stable`, { bearer: run.state.identity.bearer, body: update, headers: { "content-type": "application/octet-stream" } });
    if (pushed.status !== 200) throw new Error("Worker refused real Swift update");
    peer("inspect");
    const applied = await until("Swift update in both actual Rust and native Zig documents", 30_000, () => peer("compare-swift", rustDir, run.p("a", "data", "docs.sqlite"), true));
    if (!applied.swiftUpdateApplied) throw new Error("Swift metadata update did not reach both consumers");
    swiftApplied = true;
    return { ...result, updateSeq: pushed.json.seq, appliedByRustAndZig: true };
  });
  await step("independent typed projections + mutual VV convergence", async () => {
    peer("inspect");
    const converged = await until("Rust and Zig typed/VV convergence", 30_000, () => peer(swiftApplied ? "compare-swift" : "compare", rustDir, run.p("a", "data", "docs.sqlite"), true), 500);
    if (!converged.typedConverged || !converged.mutualVV) throw new Error("typed/VV mismatch");
    return converged;
  });
  passed = true;
} catch (e) { console.error(`FAIL full-sync: ${run.scrub(e.stack ?? e.message)}`); }
finally {
  close();
  const errors = await run.stopAll();
  const open = [];
  for (const p of new Set([...Object.values(run.state.ports), ...run.state.extraListeners.map((l) => l.port)])) if (await portListening(p)) open.push(p);
  if (errors.length || open.length) { console.error("FAIL cleanup", errors, open); passed = false; }
  else { results.push({ title: "cleanup", detail: { processGroups: Object.keys(run.state.procs).length, allPortsClosed: true } }); console.log("PASS cleanup: all owned process groups stopped and ports closed"); }
  clearTimeout(deadline);
  fs.writeFileSync(run.p("full-sync-result.json"), JSON.stringify({ passed, results }, null, 2));
  console.log(`synthetic evidence: ${run.dir}`);
  if (passed && !process.argv.includes("--keep")) fs.rmSync(run.dir, { recursive: true, force: true });
}
process.exit(passed ? 0 : 1);
