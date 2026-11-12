//! The engine side of agent turns (`crates/engine/src/sessions.rs`,
//! `doc_host.rs`): dispatch a run to the chat's harness, fold the adapter's
//! events into the chat's document under the engine lock, finish the turn,
//! and route answers, steers and interrupts to a live turn.
//!
//! Turns run on their own threads with the engine lock released, so the
//! engine keeps serving every client (and the same client's Stop, answers
//! and steers) while an agent works.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const engine_host = @import("engine_host.zig");
const EngineHost = engine_host.EngineHost;
const session_doc = @import("session_doc.zig");
const agent_turn = @import("agent_turn.zig");
const agent_proc = @import("agent_proc.zig");
const Turn = agent_turn.Turn;
const Event = agent_turn.Event;

/// Harness ids whose turns this engine runs, mapped to their adapters.
pub fn adapterFor(harness: []const u8) ?*const agent_turn.Adapter {
    const map = .{
        .{ "mock", &@import("agent_mock.zig").adapter },
        .{ "claude-code", &@import("agent_claude.zig").adapter },
        .{ "codex", &@import("agent_codex.zig").adapter },
        .{ "graff", &@import("agent_acp.zig").graff },
        .{ "devin", &@import("agent_acp.zig").devin },
        .{ "grok", &@import("agent_acp.zig").grok },
        .{ "hermes", &@import("agent_acp.zig").hermes },
        .{ "cursor", &@import("agent_cursor.zig").adapter },
        .{ "pi", &@import("agent_pi.zig").adapter },
        .{ "opencode", &@import("agent_opencode.zig").adapter },
    };
    inline for (map) |e| if (std.mem.eql(u8, harness, e[0])) return e[1];
    return null;
}

/// Tests replace the engine's environment (agent overrides, PATH, HOME).
pub var env_override: ?*const Environ.Map = null;

/// Tests name the engine executable graff's Harness MCP server runs.
pub var engine_exe_override: ?[]const u8 = null;
var engine_exe_once: std.atomic.Value(bool) = .init(false);
var engine_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
var engine_exe_len: usize = 0;

/// This process's executable when it is `harness-engine`
/// (`exo_bridge_programs`: only the engine binary serves `mcp`).
fn engineExe(io: Io) ?[]const u8 {
    if (engine_exe_override) |e| return e;
    if (!engine_exe_once.load(.acquire)) {
        live_mutex.lockUncancelable(io);
        defer live_mutex.unlock(io);
        if (!engine_exe_once.load(.acquire)) {
            if (std.process.executablePath(io, &engine_exe_buf)) |n| {
                const base = std.fs.path.stem(engine_exe_buf[0..n]);
                if (std.mem.eql(u8, base, "harness-engine")) engine_exe_len = n;
            } else |_| {}
            engine_exe_once.store(true, .release);
        }
    }
    return if (engine_exe_len > 0) engine_exe_buf[0..engine_exe_len] else null;
}

/// A turn the host is running. It holds its own reference to `turn`, so
/// `liveTurn` and `shutdownHost` never see a freed one; it is freed with the
/// turn's Done (`destroyLive`) whatever that Done's folding does.
const Live = struct {
    host: *EngineHost,
    chat_id: []u8,
    turn: *Turn,
    /// The next text/reasoning delta starts a new part (after a steer).
    fresh: bool = false,
    /// A run that replaces this turn: started once this turn's Done is in.
    replacement: ?Replacement = null,
};

/// A `run` waiting for the chat's previous turn to stop (`dispatch_inner`'s
/// replace path). Everything is owned.
const Replacement = struct {
    chat_id: []u8,
    asst_id: []u8,
    prompt: []u8,
    cwd: []u8,
    /// The run's request object as JSON.
    req_json: []u8,

    fn deinit(self: Replacement, gpa: Allocator) void {
        gpa.free(self.chat_id);
        gpa.free(self.asst_id);
        gpa.free(self.prompt);
        gpa.free(self.cwd);
        gpa.free(self.req_json);
    }
};

var live_mutex: Io.Mutex = .init;
var live_list: std.ArrayList(*Live) = .empty;
const list_gpa = std.heap.smp_allocator;

fn findLive(io: Io, host: *EngineHost, chat_id: []const u8) ?*Live {
    live_mutex.lockUncancelable(io);
    defer live_mutex.unlock(io);
    for (live_list.items) |l| if (l.host == host and std.mem.eql(u8, l.chat_id, chat_id)) return l;
    return null;
}

fn removeLive(io: Io, l: *Live) void {
    live_mutex.lockUncancelable(io);
    defer live_mutex.unlock(io);
    for (live_list.items, 0..) |x, i| if (x == l) {
        _ = live_list.swapRemove(i);
        return;
    };
}

/// Unlist and free `l`, dropping its turn reference (idempotent unlisting).
fn destroyLive(io: Io, l: *Live) void {
    removeLive(io, l);
    const gpa = l.host.gpa;
    if (l.replacement) |r| r.deinit(gpa);
    l.turn.release();
    gpa.free(l.chat_id);
    gpa.destroy(l);
}

/// Live turns on `host` (tests poll this).
pub fn liveCount(io: Io, host: *EngineHost) usize {
    live_mutex.lockUncancelable(io);
    defer live_mutex.unlock(io);
    var n: usize = 0;
    for (live_list.items) |l| if (l.host == host) {
        n += 1;
    };
    return n;
}

/// The live turn for `chat_id`, retained (call `release`).
pub fn liveTurn(io: Io, host: *EngineHost, chat_id: []const u8) ?*Turn {
    live_mutex.lockUncancelable(io);
    defer live_mutex.unlock(io);
    for (live_list.items) |l| if (l.host == host and std.mem.eql(u8, l.chat_id, chat_id)) {
        l.turn.retain();
        return l.turn;
    };
    return null;
}

/// Chats whose queue an interrupt paused (`interrupt_and_pause_queue`); a new
/// user run clears it.
var paused_mutex: Io.Mutex = .init;
var paused: std.ArrayList([]u8) = .empty;

fn setPaused(io: Io, chat_id: []const u8, on: bool) void {
    paused_mutex.lockUncancelable(io);
    defer paused_mutex.unlock(io);
    for (paused.items, 0..) |c, i| if (std.mem.eql(u8, c, chat_id)) {
        if (!on) list_gpa.free(paused.swapRemove(i));
        return;
    };
    if (on) {
        const copy = list_gpa.dupe(u8, chat_id) catch return;
        paused.append(list_gpa, copy) catch list_gpa.free(copy);
    }
}

fn isPaused(io: Io, chat_id: []const u8) bool {
    paused_mutex.lockUncancelable(io);
    defer paused_mutex.unlock(io);
    for (paused.items) |c| if (std.mem.eql(u8, c, chat_id)) return true;
    return false;
}

fn findChat(host: *EngineHost, chat_id: []const u8) ?*engine_host.ChatRecord {
    for (host.chats.items) |*c| if (std.mem.eql(u8, c.id, chat_id)) return c;
    return null;
}

fn reqStr(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

/// Run the turn for a `run` command whose user message and streaming
/// assistant entry `asst_id` the engine already wrote. Called with the
/// engine lock held. Starts the chat's adapter on its own thread. A harness
/// whose CLI can't be found ends the turn with Rust's "harness binary not
/// found" error. Only a host with no `io` (unit tests that never run an
/// agent) completes the entry in place.
pub fn dispatchRun(host: *EngineHost, chat_id: []const u8, asst_id: []const u8, prompt: []const u8, cwd: []const u8, req: json.ObjectMap) anyerror!void {
    // Whether this turn answers peer mail only: any origin but a person's.
    if (findChat(host, chat_id)) |c| c.running_turn_peer_only = if (reqStr(req, "turnOrigin")) |o| !std.mem.eql(u8, o, "human") else false;
    setPaused(host.io orelse return ackInPlace(host, chat_id, asst_id, prompt), chat_id, false);
    const chat = findChat(host, chat_id);
    const harness = reqStr(req, "harness") orelse (if (chat) |c| (if (c.harness.len > 0) c.harness else null) else null) orelse "graff";
    const io = host.io.?;

    const adapter = adapterFor(harness) orelse {
        const msg = try std.fmt.allocPrint(host.gpa, "{s} is not supported in this build of the engine.", .{harness});
        defer host.gpa.free(msg);
        return failInPlace(host, chat_id, asst_id, msg);
    };
    const model = reqStr(req, "model") orelse (if (chat) |c| c.model else null);
    const reasoning = reqStr(req, "reasoning") orelse (if (chat) |c| c.reasoning else null);

    // One turn per chat (`dispatch_inner`): a run that the live turn's
    // runtime can take mid-turn is steered into it; any other replaces it
    // once it has stopped. Never a second process on the chat.
    if (findLive(io, host, chat_id)) |prev| {
        if (try routeIntoLive(host, prev, adapter, model, reasoning, asst_id, prompt)) return;
        try replaceLive(host, prev, chat_id, asst_id, prompt, cwd, req);
        return;
    }

    // "Latest turn" diffs start from the checkout's tree as this turn begins
    // (`CheckoutDiffSync::note_turn_start`); a folder outside a checkout
    // records nothing.
    @import("rpcg_watch.zig").noteTurnStart(host, chat_id, cwd) catch |err|
        std.log.warn("harness-engine: recording the turn's start tree failed: {t}", .{err});

    const live = try host.gpa.create(Live);
    errdefer host.gpa.destroy(live);
    const turn = try Turn.create(host.gpa, io, adapter, .{ .ctx = live, .emitFn = emit }, asst_id);
    errdefer turn.release();
    live.* = .{ .host = host, .chat_id = try host.gpa.dupe(u8, chat_id), .turn = turn };
    errdefer host.gpa.free(live.chat_id);
    // From here `live` owns the turn reference `create` returned.

    const a = turn.arena.allocator();
    const env = try a.create(Environ.Map);
    // A test that sets no environment gets none: no PATH, so no agent CLI
    // installed on the machine can start.
    env.* = if (env_override) |o| try o.clone(a) else if (@import("builtin").is_test) Environ.Map.init(a) else try agent_proc.currentEnv(a);
    const auto_req = if (req.get("autoApprove")) |v| v == .bool and v.bool else false;
    const autonomy = agent_turn.applyAutonomy(host.autonomy_level, auto_req);
    const resume_id: ?[]const u8 = if (chat) |c| (if (c.harness_session_id) |s| (if (s.len > 0) s else null) else null) else null;
    turn.req = .{
        .chat_id = try a.dupe(u8, chat_id),
        .harness = try a.dupe(u8, harness),
        .prompt = try a.dupe(u8, prompt),
        .cwd = try a.dupe(u8, cwd),
        .model = if (model) |m| try a.dupe(u8, m) else null,
        .reasoning = if (reasoning) |r| try a.dupe(u8, r) else null,
        .model_options_json = if (req.get("modelOptions")) |mo| (if (mo == .object) try json.Stringify.valueAlloc(a, mo, .{}) else null) else null,
        .sandbox = autonomy.sandbox,
        .auto_approve = autonomy.auto_approve,
        .resume_id = if (resume_id) |r| try a.dupe(u8, r) else null,
        .env = env,
        .exe_hint = if (std.mem.eql(u8, harness, "graff")) (if (host.graff_exe) |g| try a.dupe(u8, g) else null) else null,
        .graff_draft_subagents = host.graff_draft_subagents,
        .graff_compact_pct = host.graff_compact_at,
        .device_name = try a.dupe(u8, host.device_name),
        .engine_exe = if (engineExe(io)) |e| try a.dupe(u8, e) else null,
        .mcp_servers_json = if (req.get("mcpServers")) |ms| (if (ms == .array) try json.Stringify.valueAlloc(a, ms, .{}) else null) else null,
        .attachments = try stringArray(a, req.get("attachments")),
    };

    {
        live_mutex.lockUncancelable(io);
        defer live_mutex.unlock(io);
        try live_list.append(list_gpa, live);
    }
    startLive(host, live, chat_id, asst_id);
}

/// A JSON array's strings, copied into `a` (anything else: empty).
fn stringArray(a: Allocator, v: ?json.Value) ![]const []const u8 {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.array.items) |x| if (x == .string and x.string.len > 0) try out.append(a, try a.dupe(u8, x.string));
    return out.items;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Deliver a run into the live turn as a steer when its runtime can take it
/// (same harness and model, steered mid-turn). The run's user message and
/// entry `asst_id` are written already: the reply so far completes and the
/// turn continues in `asst_id`.
fn routeIntoLive(host: *EngineHost, prev: *Live, adapter: *const agent_turn.Adapter, model: ?[]const u8, reasoning: ?[]const u8, asst_id: []const u8, prompt: []const u8) !bool {
    const t = prev.turn;
    if (t.adapter != adapter or !adapter.steers_mid_turn) return false;
    if (!optEql(t.req.model, model) or !optEql(t.req.reasoning, reasoning)) return false;
    const steer_fn = adapter.steer orelse return false;
    if (t.interrupted.load(.acquire) or !steer_fn(t, prompt)) return false;
    const doc = try host.getOrCreateDoc(prev.chat_id);
    const next = try host.gpa.dupe(u8, asst_id);
    {
        t.mu.lockUncancelable(t.io);
        defer t.mu.unlock(t.io);
        doc.setMessageStatus(t.asst_id, "complete") catch {};
        host.journal.recordFinish(prev.chat_id, t.asst_id, "complete") catch {};
        host.gpa.free(t.asst_id);
        t.asst_id = next;
    }
    prev.fresh = true;
    const reset_frame = try doc.toResetFrameJson(host.gpa);
    defer host.gpa.free(reset_frame);
    try host.broadcastWatch(.doc_messages, prev.chat_id, reset_frame);
    return true;
}

/// Stop the live turn and start this run after its Done. A run already
/// waiting there is superseded: its entry ends aborted.
fn replaceLive(host: *EngineHost, prev: *Live, chat_id: []const u8, asst_id: []const u8, prompt: []const u8, cwd: []const u8, req: json.ObjectMap) !void {
    const gpa = host.gpa;
    const req_json = try json.Stringify.valueAlloc(gpa, json.Value{ .object = req }, .{});
    errdefer gpa.free(req_json);
    const r: Replacement = .{
        .chat_id = try gpa.dupe(u8, chat_id),
        .asst_id = try gpa.dupe(u8, asst_id),
        .prompt = try gpa.dupe(u8, prompt),
        .cwd = try gpa.dupe(u8, cwd),
        .req_json = req_json,
    };
    if (prev.replacement) |old| {
        defer old.deinit(gpa);
        if (host.getOrCreateDoc(chat_id)) |doc| doc.setMessageStatus(old.asst_id, "aborted") catch {} else |_| {}
        host.journal.recordFinish(chat_id, old.asst_id, "aborted") catch {};
    }
    prev.replacement = r;
    prev.turn.interrupt();
}

/// Start the run that waited for the chat's previous turn to stop.
fn startReplacement(host: *EngineHost, r: Replacement) void {
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    const parsed = json.parseFromSliceLeaky(json.Value, arena.allocator(), r.req_json, .{}) catch return;
    if (parsed != .object) return;
    if (findChat(host, r.chat_id)) |c| setActivity(host, c, "working", host.nowMs());
    broadcastRows(host);
    dispatchRun(host, r.chat_id, r.asst_id, r.prompt, r.cwd, parsed.object) catch |err| std.log.warn("harness-engine: starting the replacing run failed: {t}", .{err});
}

/// Start `live`'s thread; on failure the entry ends with the error. No
/// error escapes: `live` is either running or already freed.
fn startLive(host: *EngineHost, live: *Live, chat_id: []const u8, asst_id: []const u8) void {
    const io = live.turn.io;
    live.turn.start() catch |err| {
        destroyLive(io, live);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "io: {t}", .{err}) catch "io: spawn failed";
        failInPlace(host, chat_id, asst_id, msg) catch |e| std.log.warn("harness-engine: failing the turn failed: {t}", .{e});
    };
}

/// Test hosts without `io` only: production hosts always have one.
fn ackInPlace(host: *EngineHost, chat_id: []const u8, asst_id: []const u8, prompt: []const u8) !void {
    const doc = try host.getOrCreateDoc(chat_id);
    const reply_text = try std.fmt.allocPrint(host.gpa, "Ack from {s}: {s}", .{ host.device_id, prompt });
    defer host.gpa.free(reply_text);
    _ = try doc.appendPartDelta(asst_id, "part-text", "text", reply_text);
    try doc.setMessageStatus(asst_id, "complete");
    try finishTurn(host, chat_id, asst_id, "complete", "idle");
}

fn failInPlace(host: *EngineHost, chat_id: []const u8, asst_id: []const u8, msg: []const u8) !void {
    const doc = try host.getOrCreateDoc(chat_id);
    try appendError(doc, asst_id, msg);
    try doc.setMessageStatus(asst_id, "complete");
    try finishTurn(host, chat_id, asst_id, "complete", "errored");
}

/// The end of a turn: journal, snapshot, outbox, tail cache, the chat's row
/// and every watcher (the engine lock is held).
pub fn finishTurn(host: *EngineHost, chat_id: []const u8, asst_id: []const u8, journal_status: []const u8, activity: []const u8) !void {
    const doc = try host.getOrCreateDoc(chat_id);
    try host.journal.recordFinish(chat_id, asst_id, journal_status);

    const finish_now = host.nowMs();
    const snap = try doc.exportPersisted(host.gpa);
    defer host.gpa.free(snap);
    try host.store.saveSnapshot(chat_id, snap, finish_now);

    const batch_id = try std.fmt.allocPrint(host.gpa, "{s}-b-{d}", .{ host.device_id, doc.local_seq });
    defer host.gpa.free(batch_id);
    // Full-sync mode queues only genuine incremental Loro bytes in the sync
    // worker. The private persistence envelope must never reach chat2.
    if (!@import("loro.zig").enabled) try host.store.enqueueChatUpdate(chat_id, batch_id, snap);

    if (doc.toTailMessagesArrayJson(host.gpa, session_doc.tail_message_count)) |tail_arr| {
        _ = host.storeCachedTailInMemoryOwned(chat_id, tail_arr, true);
    } else |_| {}
    host.markChatTailDirty(chat_id);

    if (findChat(host, chat_id)) |c| {
        c.last_message_at_ms = finish_now;
        if (doc.latestTextPreview(140)) |prev_slice| {
            if (host.gpa.dupe(u8, prev_slice)) |p_copy| {
                if (c.preview) |old_p| host.gpa.free(old_p);
                c.preview = p_copy;
            } else |_| {}
        }
        // A successful turn advances the session's completion marker; an
        // interrupt or a failure never does (`set_status_with_completion`).
        if (std.mem.eql(u8, journal_status, "complete") and std.mem.eql(u8, activity, "idle")) {
            if (host.gpa.dupe(u8, asst_id)) |turn| {
                if (c.last_completed_turn) |old| host.gpa.free(old);
                c.last_completed_turn = turn;
                c.last_completed_peer_only = c.running_turn_peer_only;
            } else |_| {}
        }
        setActivity(host, c, activity, finish_now);
    }

    const reset_frame = try doc.toResetFrameJson(host.gpa);
    defer host.gpa.free(reset_frame);
    try host.broadcastWatch(.doc_messages, chat_id, reset_frame);
    broadcastRows(host);
    host.saveRegistryCacheFile();
    host.wakeBgSync();
}

fn setActivity(host: *EngineHost, c: *engine_host.ChatRecord, activity: []const u8, now: i64) void {
    if (host.gpa.dupe(u8, activity)) |copy| {
        if (c.activity_status) |old_s| host.gpa.free(old_s);
        c.activity_status = copy;
    } else |_| {}
    c.activity_updated_at_ms = now;
    host.enqueueChatUpsertOp(c.*);
    host.enqueueSessionUpsertOp(c.*);
}

fn broadcastRows(host: *EngineHost) void {
    if (host.chatsJson()) |chj| {
        defer host.gpa.free(chj);
        host.broadcastWatch(.chats, null, chj) catch {};
    } else |_| {}
    if (host.sessionsJson()) |sj| {
        defer host.gpa.free(sj);
        host.broadcastWatch(.sessions, null, sj) catch {};
    } else |_| {}
}

// ---------------------------------------------------------------------------
// Folding events into the doc (`fold_event_into_parts`)
// ---------------------------------------------------------------------------

fn emit(ctx: *anyopaque, t: *Turn, ev: Event) void {
    const live: *Live = @ptrCast(@alignCast(ctx));
    const host = live.host;
    host.mutex.lockUncancelable(t.io);
    defer host.mutex.unlock(t.io);
    // A stopping engine, or a chat deleted mid-turn: nothing to write, and
    // no doc, snapshot or outbox batch is recreated for it.
    if (!host.stop_requested and findChat(host, live.chat_id) != null) {
        applyEvent(host, live, t, ev) catch |err| std.log.warn("harness-engine: folding {t} failed: {t}", .{ ev, err });
    }
    if (ev != .done) return;
    // Done frees the entry however its folding went (Turn.emit drops any
    // event after Done, so nothing reaches it again), then starts the run
    // that replaces it.
    const next = live.replacement;
    live.replacement = null;
    destroyLive(t.io, live);
    if (next) |r| {
        defer r.deinit(host.gpa);
        if (!host.stop_requested and findChat(host, r.chat_id) != null) startReplacement(host, r);
    }
}

fn lastPart(doc: *session_doc.SessionDoc, msg_id: []const u8) ?*session_doc.PartItem {
    const idx = doc.findMessageIdx(msg_id) orelse return null;
    const parts = doc.messages.items[idx].parts.items;
    return if (parts.len > 0) &parts[parts.len - 1] else null;
}

fn findPart(doc: *session_doc.SessionDoc, msg_id: []const u8, part_id: []const u8) ?*session_doc.PartItem {
    const idx = doc.findMessageIdx(msg_id) orelse return null;
    for (doc.messages.items[idx].parts.items) |*p| if (std.mem.eql(u8, p.id, part_id)) return p;
    return null;
}

fn partCount(doc: *session_doc.SessionDoc, msg_id: []const u8) usize {
    const idx = doc.findMessageIdx(msg_id) orelse return 0;
    return doc.messages.items[idx].parts.items.len;
}

/// Append to the trailing `kind` part or start `"{prefix}{n}"`.
fn appendStreamed(host: *EngineHost, live: *Live, doc: *session_doc.SessionDoc, asst: []const u8, kind: []const u8, prefix: u8, delta: []const u8) !void {
    if (delta.len == 0) return;
    var id_buf: [32]u8 = undefined;
    const part_id: []const u8 = blk: {
        if (!live.fresh) if (lastPart(doc, asst)) |p| if (std.mem.eql(u8, p.kind, kind)) break :blk p.id;
        break :blk try std.fmt.bufPrint(&id_buf, "{c}{d}", .{ prefix, partCount(doc, asst) });
    };
    live.fresh = false;
    const id_copy = try host.gpa.dupe(u8, part_id);
    defer host.gpa.free(id_copy);
    const total = try doc.appendPartDelta(asst, id_copy, kind, delta);
    const frame = if (total > delta.len and std.mem.eql(u8, kind, "text"))
        try doc.toAppendDeltaFrameJson(host.gpa, asst, id_copy, delta, total)
    else
        try doc.toUpsertEntryFrameJson(host.gpa, asst);
    defer host.gpa.free(frame);
    host.broadcastWatch(.doc_messages, live.chat_id, frame) catch {};
}

pub fn appendError(doc: *session_doc.SessionDoc, asst: []const u8, msg: []const u8) !void {
    var id_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "e{d}", .{partCount(doc, asst)});
    _ = try doc.appendPartDelta(asst, id, "error", msg);
}

fn setPartJson(doc: *session_doc.SessionDoc, p: *session_doc.PartItem, call_json: []const u8) !void {
    const copy = try doc.gpa.dupe(u8, call_json);
    const old: usize = if (p.call_json) |c| c.len else 0;
    if (p.call_json) |c| doc.gpa.free(c);
    p.call_json = copy;
    doc.live_payload_bytes = doc.live_payload_bytes - old + copy.len;
}

fn upsertEntry(host: *EngineHost, live: *Live, doc: *session_doc.SessionDoc, asst: []const u8) void {
    const frame = doc.toUpsertEntryFrameJson(host.gpa, asst) catch return;
    defer host.gpa.free(frame);
    host.broadcastWatch(.doc_messages, live.chat_id, frame) catch {};
}

fn applyEvent(host: *EngineHost, live: *Live, t: *Turn, ev: Event) !void {
    const doc = try host.getOrCreateDoc(live.chat_id);
    const asst = t.asst_id;
    switch (ev) {
        .text => |d| try appendStreamed(host, live, doc, asst, "text", 't', d),
        .reasoning => |d| try appendStreamed(host, live, doc, asst, "reasoning", 'r', d),
        .message_completed => {},
        .tool_call => |c| {
            const existing = findPart(doc, asst, c.id);
            const resolved = if (existing) |p| p.resolved else false;
            const is_error = if (existing) |p| p.is_error else false;
            try doc.upsertToolPart(asst, c.id, c.call, null, resolved, is_error);
            upsertEntry(host, live, doc, asst);
        },
        .tool_result => |r| {
            try doc.upsertToolPart(asst, r.id, "", null, true, r.is_error);
            upsertEntry(host, live, doc, asst);
        },
        .input_requested => |q| {
            _ = try doc.appendPartDelta(asst, q.request_id, "input", "");
            if (findPart(doc, asst, q.request_id)) |p| try setPartJson(doc, p, q.questions);
            if (findChat(host, live.chat_id)) |c| setActivity(host, c, "awaitingInput", host.nowMs());
            upsertEntry(host, live, doc, asst);
            broadcastRows(host);
        },
        .input_resolved => |rid| {
            if (resolveInputPart(doc, rid)) {
                if (findChat(host, live.chat_id)) |c| setActivity(host, c, "working", host.nowMs());
                upsertEntry(host, live, doc, asst);
                broadcastRows(host);
            }
        },
        .err => |m| {
            try appendError(doc, asst, m);
            upsertEntry(host, live, doc, asst);
        },
        .session_started => |sid| rememberSession(host, live.chat_id, sid),
        .done => |d| try finishLive(host, live, t, doc, d),
    }
}

fn rememberSession(host: *EngineHost, chat_id: []const u8, sid: []const u8) void {
    if (sid.len == 0) return;
    const c = findChat(host, chat_id) orelse return;
    if (c.harness_session_id) |old| if (std.mem.eql(u8, old, sid)) return;
    const copy = host.gpa.dupe(u8, sid) catch return;
    if (c.harness_session_id) |old| host.gpa.free(old);
    c.harness_session_id = copy;
    host.enqueueChatUpsertOp(c.*);
}

/// Mark the input part `request_id` resolved anywhere in the doc.
fn resolveInputPart(doc: *session_doc.SessionDoc, request_id: []const u8) bool {
    var i = doc.messages.items.len;
    while (i > 0) {
        i -= 1;
        for (doc.messages.items[i].parts.items) |*p| {
            if (std.mem.eql(u8, p.kind, "input") and std.mem.eql(u8, p.id, request_id)) {
                if (p.resolved) return false;
                p.resolved = true;
                return true;
            }
        }
    }
    return false;
}

fn finishLive(host: *EngineHost, live: *Live, t: *Turn, doc: *session_doc.SessionDoc, d: anytype) !void {
    const asst = t.asst_id;
    const interrupted = d.status == .interrupted;
    if (d.err) |m| if (d.status == .errored) try appendError(doc, asst, m);
    if (interrupted) if (lastPart(doc, asst)) |p| if (std.mem.eql(u8, p.kind, "input") and p.resolved) {
        try appendError(doc, asst, "Stopped right after your answer, before the agent continued: Stop was requested. Send a message to continue the task.");
    };
    // Open questions are settled with the turn.
    if (doc.findMessageIdx(asst)) |idx| for (doc.messages.items[idx].parts.items) |*p| {
        if (std.mem.eql(u8, p.kind, "input")) p.resolved = true;
    };
    if (d.session_id) |sid| rememberSession(host, live.chat_id, sid);
    // Unlisted now so the next turn (the queue below) is the chat's live
    // one; `emit` frees the entry after this returns.
    removeLive(t.io, live);
    try doc.setMessageStatus(asst, if (interrupted) "aborted" else "complete");
    try finishTurn(host, live.chat_id, asst, if (interrupted) "aborted" else "complete", if (d.status == .errored) "errored" else "idle");
    // A replacing run goes first; its own Done drains the queue.
    if (live.replacement != null) return;
    drainQueue(host, live.chat_id) catch |err| std.log.warn("harness-engine: queue drain failed: {t}", .{err});
}

/// Start the first deliverable queued message as the next turn.
fn drainQueue(host: *EngineHost, chat_id: []const u8) anyerror!void {
    const io = host.io orelse return;
    if (isPaused(io, chat_id)) return;
    const doc = try host.getOrCreateDoc(chat_id);
    var row_id: ?[]u8 = null;
    defer if (row_id) |r| host.gpa.free(r);
    for (doc.queue.items) |q| if (q.isAutoDeliverable(false)) {
        row_id = try host.gpa.dupe(u8, q.id);
        break;
    };
    const rid = row_id orelse return;
    const text = doc.takeQueuedText(rid) orelse return;
    defer host.gpa.free(text);
    const q_frame = try doc.toQueueFrameJson(host.gpa);
    defer host.gpa.free(q_frame);
    host.broadcastWatch(.queue, chat_id, q_frame) catch {};
    try runCommand(host, chat_id, rid, text);
}

/// Dispatch a `run` through the engine's own QueueCommand path.
fn runCommand(host: *EngineHost, chat_id: []const u8, msg_id: []const u8, prompt: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd: ?[]const u8 = if (findChat(host, chat_id)) |c| c.cwd else null;
    const body = if (cwd) |cw|
        try std.fmt.allocPrint(a, "{{\"chatId\":{f},\"command\":{{\"kind\":\"run\",\"messageId\":{f},\"request\":{{\"prompt\":{f},\"cwd\":{f}}}}}}}", .{ json.fmt(chat_id, .{}), json.fmt(msg_id, .{}), json.fmt(prompt, .{}), json.fmt(cw, .{}) })
    else
        try std.fmt.allocPrint(a, "{{\"chatId\":{f},\"command\":{{\"kind\":\"run\",\"messageId\":{f},\"request\":{{\"prompt\":{f}}}}}}}", .{ json.fmt(chat_id, .{}), json.fmt(msg_id, .{}), json.fmt(prompt, .{}) });
    const params = try json.parseFromSliceLeaky(json.Value, a, body, .{});
    var out = try host.handle("QueueCommand", params);
    switch (out) {
        .unary_json => |b| host.gpa.free(b),
        .stream_items_json => |*s| s.deinit(host.gpa),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Steer, answers, interrupt
// ---------------------------------------------------------------------------

/// The `steer` command (`deliver_prompt`): steered into a live turn whose
/// harness steers mid-turn, held in the queue until a turn-boundary
/// harness's turn ends, or run as a new turn when nothing is running.
pub fn steer(host: *EngineHost, chat_id: []const u8, msg_id: []const u8, prompt: []const u8, now: i64) anyerror!void {
    const io = host.io orelse return runCommand(host, chat_id, msg_id, prompt);
    const live = findLive(io, host, chat_id) orelse return runCommand(host, chat_id, msg_id, prompt);
    const t = live.turn;
    if (!(try host.store.markCommandProcessed(msg_id, now))) return;
    const doc = try host.getOrCreateDoc(chat_id);
    const delivered = t.adapter.steers_mid_turn and (if (t.adapter.steer) |f| f(t, prompt) else false);
    if (!delivered) {
        try doc.enqueueMessage(msg_id, prompt, true, now);
        const q_frame = try doc.toQueueFrameJson(host.gpa);
        defer host.gpa.free(q_frame);
        try host.broadcastWatch(.queue, chat_id, q_frame);
        return;
    }
    // `Steered`: the reply so far completes, the steer is the next user
    // message, and the turn continues in a new assistant entry.
    try doc.setMessageStatus(t.asst_id, "complete");
    try host.journal.recordFinish(chat_id, t.asst_id, "complete");
    try doc.enqueueCommand(msg_id, "steer", prompt, "completed", now);
    try doc.appendUserMessage(msg_id, "part-steer", prompt, now);
    host.turn_counter += 1;
    const next = try std.fmt.allocPrint(host.gpa, "{s}-asst-{d}", .{ host.device_id, host.turn_counter });
    {
        t.mu.lockUncancelable(io);
        defer t.mu.unlock(io);
        try doc.beginAssistantMessage(next, now);
        host.gpa.free(t.asst_id);
        t.asst_id = next;
    }
    try host.journal.recordBegin(chat_id, next, now);
    live.fresh = true;
    if (findChat(host, chat_id)) |c| {
        c.last_prompt_at_ms = now;
        c.last_message_at_ms = now;
        host.enqueueChatUpsertOp(c.*);
    }
    host.markChatTailDirty(chat_id);
    host.wakeBgSync();
    const reset_frame = try doc.toResetFrameJson(host.gpa);
    defer host.gpa.free(reset_frame);
    try host.broadcastWatch(.doc_messages, chat_id, reset_frame);
}

/// The `respondInput` command: answer the live turn's open question, or —
/// when the turn that asked is gone — resolve it and send the answers as a
/// new turn ("Answering your earlier question:").
pub fn respondInput(host: *EngineHost, chat_id: []const u8, request_id: []const u8, answers_val: ?json.Value) anyerror!bool {
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    const answers = try agent_turn.parseAnswers(arena.allocator(), answers_val);
    if (host.io) |io| if (liveTurn(io, host, chat_id)) |t| {
        defer t.release();
        if (t.respond(request_id, answers)) {
            try markResolved(host, chat_id, request_id);
            return true;
        }
    };
    const doc = try host.getOrCreateDoc(chat_id);
    const questions = openQuestionsJson(doc, request_id) orelse return false;
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(host.gpa);
    try prompt.appendSlice(host.gpa, "Answering your earlier question:");
    const qs = json.parseFromSliceLeaky([]agent_turn.Question, arena.allocator(), questions, .{ .ignore_unknown_fields = true }) catch &.{};
    for (qs) |q| {
        const labels = agent_turn.labelsFor(answers, q.id);
        try prompt.print(host.gpa, "\n{s} — ", .{q.question});
        for (labels, 0..) |l, i| {
            if (i > 0) try prompt.appendSlice(host.gpa, ", ");
            try prompt.appendSlice(host.gpa, l);
        }
    }
    try markResolved(host, chat_id, request_id);
    const msg_id = try std.fmt.allocPrint(arena.allocator(), "answer-{s}", .{request_id});
    try runCommand(host, chat_id, msg_id, prompt.items);
    return true;
}

fn openQuestionsJson(doc: *session_doc.SessionDoc, request_id: []const u8) ?[]const u8 {
    for (doc.messages.items) |m| for (m.parts.items) |p| {
        if (std.mem.eql(u8, p.kind, "input") and std.mem.eql(u8, p.id, request_id) and !p.resolved) return p.call_json orelse "[]";
    };
    return null;
}

fn markResolved(host: *EngineHost, chat_id: []const u8, request_id: []const u8) !void {
    const doc = try host.getOrCreateDoc(chat_id);
    if (!resolveInputPart(doc, request_id)) return;
    if (findChat(host, chat_id)) |c| if (c.activity_status) |s| if (std.mem.eql(u8, s, "awaitingInput")) setActivity(host, c, "working", host.nowMs());
    const reset_frame = try doc.toResetFrameJson(host.gpa);
    defer host.gpa.free(reset_frame);
    try host.broadcastWatch(.doc_messages, chat_id, reset_frame);
    broadcastRows(host);
}

/// The `dismissInput` command: decline the question and stop the run
/// (`dismiss_input`, stop reason "question dismissed").
pub fn dismissInput(host: *EngineHost, chat_id: []const u8, request_id: []const u8) anyerror!bool {
    if (host.io) |io| if (liveTurn(io, host, chat_id)) |t| {
        defer t.release();
        if (t.respond(request_id, null)) {
            try markResolved(host, chat_id, request_id);
            setPaused(io, chat_id, true);
            t.interrupt();
            return true;
        }
    };
    try markResolved(host, chat_id, request_id);
    return false;
}

/// `deleteChat` (engine lock held): stop the chat's live turn. Its events
/// and Done then find no chat and write nothing (`emit`).
pub fn chatDeleted(host: *EngineHost, chat_id: []const u8) void {
    const io = host.io orelse return;
    setPaused(io, chat_id, false);
    const t = liveTurn(io, host, chat_id) orelse return;
    defer t.release();
    t.interrupt();
}

/// The `interrupt` command: stop the live turn (its Done finishes the entry
/// as "aborted") and pause the queue. False when nothing is running.
pub fn interrupt(host: *EngineHost, chat_id: []const u8) bool {
    const io = host.io orelse return false;
    const t = liveTurn(io, host, chat_id) orelse return false;
    defer t.release();
    setPaused(io, chat_id, true);
    t.interrupt();
    return true;
}

/// Engine shutdown: stop every turn on `host` and wait for their threads.
/// Called without the engine lock (from `EngineHost.deinit`).
pub fn shutdownHost(host: *EngineHost) void {
    const io = host.io orelse return;
    var turns: std.ArrayList(*Turn) = .empty;
    defer turns.deinit(list_gpa);
    {
        live_mutex.lockUncancelable(io);
        defer live_mutex.unlock(io);
        for (live_list.items) |l| if (l.host == host) {
            l.turn.retain();
            turns.append(list_gpa, l.turn) catch l.turn.release();
        };
    }
    defer for (turns.items) |t| t.release();
    killTurns(io, turns.items);
    // A hard gate: the host is freed after this returns, so no turn thread
    // (or the request threads that hold a turn) may still be running. Waits
    // inside a turn end on its interrupt; a process that respawned under a
    // turn is killed again on every round.
    while (!agent_turn.waitAllExited(io, 5000)) {
        std.log.warn("harness-engine: waiting for {d} agent thread(s) to stop", .{agent_turn.active_threads.load(.acquire)});
        killTurns(io, turns.items);
    }
}

fn killTurns(io: Io, turns: []const *Turn) void {
    for (turns) |t| {
        t.interrupted.store(true, .release);
        t.mu.lockUncancelable(io);
        if (t.proc) |p| p.terminate();
        t.mu.unlock(io);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testkit = @import("agent_testkit.zig");

test "turn_host: graff with no binary reports it missing instead of replying" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    // No configured graff copy, and GRAFF_EXECUTABLE names a missing file.
    const rig = try testkit.Rig.create(.{ .harness = "graff", .override_var = "GRAFF_EXECUTABLE", .script = "", .missing_binary = true });
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "Ack from") == null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"kind\":\"error\",\"message\":\"harness binary not found: /nonexistent/harness-agent-mock does not exist\"") != null);
}

fn mockRig(delay_ms: []const u8) !*testkit.Rig {
    const rig = try testkit.Rig.create(.{ .harness = "mock", .override_var = "HARNESS_TEST_UNUSED", .script = "" });
    errdefer rig.destroy();
    try rig.env.put("HARNESS_MOCK_DELAY_MS", delay_ms);
    return rig;
}

test "turn_host: deleting a chat mid-turn stops the turn and recreates nothing" {
    const rig = try mockRig("150");
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitFor("Streaming pipeline", 5000);
    try rig.call("Mutate", "{\"op\":\"deleteChat\",\"chatId\":\"chat-1\"}");
    try rig.waitIdle(5000);
    rig.host.mutex.lockUncancelable(rig.io);
    defer rig.host.mutex.unlock(rig.io);
    try testing.expect(rig.host.docs.get("chat-1") == null);
    try testing.expect(rig.host.store.snapshots.get("chat-1") == null);
    for (rig.host.store.outbox.items) |o| try testing.expect(!std.mem.eql(u8, o.doc_id, "chat-1"));
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

fn queueLen(rig: *testkit.Rig) !usize {
    rig.host.mutex.lockUncancelable(rig.io);
    defer rig.host.mutex.unlock(rig.io);
    return (try rig.host.getOrCreateDoc("chat-1")).queue.items.len;
}

test "turn_host: a second run on a live turn that steers mid-turn is steered into it" {
    const rig = try mockRig("100");
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitFor("Streaming pipeline", 5000);
    try rig.run("m-2", "follow up");
    // Never a second process (or turn) on the chat.
    try testing.expectEqual(@as(usize, 1), liveCount(rig.io, rig.host));
    try rig.waitIdle(8000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"follow up\"") != null);
    try testing.expectEqual(@as(usize, 1), count(doc, "Mock harness reporting in."));
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"aborted\"") == null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"streaming\"") == null);
}

test "turn_host: a run that changes the model replaces the live turn once it stopped" {
    const rig = try mockRig("100");
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitFor("Streaming pipeline", 5000);
    try rig.command("{\"kind\":\"run\",\"messageId\":\"m-2\",\"request\":{\"prompt\":\"on another model\",\"model\":\"mock-fable-5\"}}");
    // Never two turns on the chat. While the stopped turn hands over to its
    // replacement there can briefly be none, so this is "at most one".
    try testing.expect(liveCount(rig.io, rig.host) <= 1);
    try rig.waitIdle(8000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expectEqual(@as(usize, 1), count(doc, "\"status\":\"aborted\""));
    try testing.expectEqual(@as(usize, 1), count(doc, "Mock harness reporting in."));
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"streaming\"") == null);
}

test "turn_host: a held queued message runs as the next turn when the turn ends" {
    const rig = try mockRig("30");
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitFor("Streaming pipeline", 5000);
    try rig.call("QueueMessage", "{\"chatId\":\"chat-1\",\"id\":\"q-1\",\"text\":\"queued one\",\"holdForTurnEnd\":true}");
    try rig.waitFor("\"text\":\"queued one\"", 8000);
    try rig.waitIdle(8000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expectEqual(@as(usize, 2), count(doc, "Mock harness reporting in."));
    try testing.expectEqual(@as(usize, 0), try queueLen(rig));
}

test "turn_host: an interrupt pauses the queue" {
    const rig = try mockRig("100");
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitFor("Streaming pipeline", 5000);
    try rig.call("QueueMessage", "{\"chatId\":\"chat-1\",\"id\":\"q-1\",\"text\":\"queued one\",\"holdForTurnEnd\":true}");
    try rig.command("{\"kind\":\"interrupt\"}");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"aborted\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"queued one\"") == null);
    try testing.expectEqual(@as(usize, 1), try queueLen(rig));
}

test "turn_host: a steer for a turn-boundary harness waits in the queue" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "devin", .override_var = "DEVIN_EXECUTABLE", .script = @import("agent_acp.zig").mock_agent });
    defer rig.destroy();
    try rig.run("m-1", "clean up");
    try rig.waitQuestion(5000);
    try rig.command("{\"kind\":\"steer\",\"messageId\":\"s-1\",\"prompt\":\"also this\"}");
    try testing.expectEqual(@as(usize, 1), try queueLen(rig));
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "also this") == null);
    try rig.command("{\"kind\":\"interrupt\"}");
    try rig.waitIdle(8000);
}

test "turn_host: shutting the host down mid-turn waits for the turn thread" {
    const rig = try mockRig("200");
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitFor("Streaming pipeline", 5000);
    {
        rig.host.mutex.lockUncancelable(rig.io);
        defer rig.host.mutex.unlock(rig.io);
        rig.host.stop_requested = true;
    }
    shutdownHost(rig.host);
    try testing.expectEqual(@as(usize, 0), agent_turn.active_threads.load(.acquire));
    try testing.expectEqual(@as(usize, 0), liveCount(rig.io, rig.host));
}
