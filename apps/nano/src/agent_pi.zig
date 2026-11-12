//! Pi adapter (`crates/harness/src/pi/{mod,rpc,normalize,ui,sessions}.rs`).
//!
//! `pi --mode rpc --no-themes` over Pi's own JSONL commands: a bootstrap
//! (steering mode, model, thinking level, state), `prompt`, streamed agent
//! events, `extension_ui_request` questions, `abort` to interrupt and
//! `prompt` with `streamingBehavior: "steer"` to steer. A `get_state`
//! barrier after `agent_settled` ends the turn.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const agent_turn = @import("agent_turn.zig");
const agent_proc = @import("agent_proc.zig");
const Turn = agent_turn.Turn;
const Event = agent_turn.Event;
const Call = agent_turn.Call;
const get = agent_turn.get;
const getStr = agent_turn.getStr;

pub const adapter: agent_turn.Adapter = .{
    .name = "Pi",
    .run = run,
    .interrupt = interrupt,
    .steer = steer,
    .answer = answer,
    .steers_mid_turn = true,
};

pub const install_hint = "Pi CLI: install Pi or set PI_EXECUTABLE (the pi-acp adapter is not used)";
pub const extra_paths = [_][]const u8{ "~/.local/bin/pi", "~/.npm-global/bin/pi", "/opt/homebrew/bin/pi", "/usr/local/bin/pi" };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Pi's settings directory: `PI_CODING_AGENT_DIR`, else `~/.pi/agent`.
pub fn agentDir(a: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |d| if (d.len > 0) return d;
    return std.fs.path.join(a, &.{ env.get("HOME") orelse ".", ".pi/agent" });
}

/// `Store::key`: `<agent>/harness-sessions/<sha256(id)>.json`.
pub fn indexPath(a: Allocator, agent: []const u8, id: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return std.fmt.allocPrint(a, "{s}/harness-sessions/{x}.json", .{ agent, digest });
}

fn readJson(a: Allocator, io: Io, path: []const u8) ?json.Value {
    const raw = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch return null;
    return json.parseFromSliceLeaky(json.Value, a, raw, .{}) catch null;
}

/// A session file belongs to `id` when its first line is `{"type":"session","id":id}`.
fn matchesId(a: Allocator, io: Io, path: []const u8, id: []const u8) bool {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = f.readStreaming(io, &.{&buf}) catch return false;
    const first = std.mem.sliceTo(buf[0..n], '\n');
    const v = json.parseFromSliceLeaky(json.Value, a, first, .{}) catch return false;
    return eq(getStr(v, "type") orelse "", "session") and eq(getStr(v, "id") orelse "", id);
}

/// `Store::resolve`: the index, the legacy pi-acp map, then a scan of
/// `<agent>/sessions` (two levels, at most 20000 entries).
pub fn resolveSession(a: Allocator, io: Io, env: *const std.process.Environ.Map, id: []const u8) !?[]const u8 {
    const agent = try agentDir(a, env);
    var candidates: std.ArrayList([]const u8) = .empty;
    if (readJson(a, io, try indexPath(a, agent, id))) |rec| if (getStr(rec, "sessionFile")) |f| try candidates.append(a, f);
    if (env.get("HOME")) |home| if (readJson(a, io, try std.fs.path.join(a, &.{ home, ".pi/pi-acp/session-map.json" }))) |legacy| {
        if (get(legacy, "sessions")) |ss| if (get(ss, id)) |e| if (getStr(e, "sessionFile")) |f| try candidates.append(a, f);
    };
    for (candidates.items) |c| if (matchesId(a, io, c, id)) return c;
    const root = try std.fs.path.join(a, &.{ agent, "sessions" });
    var seen: usize = 0;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        seen += 1;
        if (seen > 20000) break;
        const p = try std.fs.path.join(a, &.{ root, e.name });
        if (e.kind == .file) {
            if (std.mem.endsWith(u8, e.name, ".jsonl") and matchesId(a, io, p, id)) return p;
        } else if (e.kind == .directory) {
            var sub = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            var sit = sub.iterate();
            while (sit.next(io) catch null) |se| {
                seen += 1;
                if (seen > 20000) break;
                if (se.kind != .file or !std.mem.endsWith(u8, se.name, ".jsonl")) continue;
                const sp = try std.fs.path.join(a, &.{ p, se.name });
                if (matchesId(a, io, sp, id)) return sp;
            }
        }
    }
    return null;
}

/// `Store::remember`.
fn rememberSession(a: Allocator, io: Io, env: *const std.process.Environ.Map, id: []const u8, file: []const u8) void {
    if (!std.fs.path.isAbsolute(file)) return;
    const agent = agentDir(a, env) catch return;
    const path = indexPath(a, agent, id) catch return;
    Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?) catch return;
    const body = std.fmt.allocPrint(a, "{{\"sessionId\":{f},\"sessionFile\":{f}}}", .{ json.fmt(id, .{}), json.fmt(file, .{}) }) catch return;
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = std.fmt.allocPrint(a, "{s}/{x}.tmp", .{ std.fs.path.dirname(path).?, rnd }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = body }) catch return;
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io) catch Io.Dir.cwd().deleteFile(io, tmp) catch {};
}

fn steeringConfigured(a: Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8) bool {
    const agent = agentDir(a, env) catch return false;
    for ([_][]const u8{ std.fs.path.join(a, &.{ agent, "settings.json" }) catch return false, std.fs.path.join(a, &.{ cwd, ".pi/settings.json" }) catch return false }) |p| {
        if (readJson(a, io, p)) |v| if (get(v, "steeringMode") != null) return true;
    }
    return false;
}

/// The highest supported thinking level at or below the desired one.
pub fn pickThinking(desired: []const u8, levels: []const []const u8) ?[]const u8 {
    const order = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max" };
    var rank: usize = order.len - 1;
    for (order, 0..) |o, i| if (eq(o, desired)) {
        rank = i;
    };
    var i = rank + 1;
    while (i > 0) {
        i -= 1;
        for (levels) |l| if (eq(l, order[i])) return order[i];
    }
    return null;
}

/// `pi_tool_call`.
pub fn toolCall(a: Allocator, name: []const u8, args: json.Value) ![]u8 {
    const s = struct {
        fn f(v: json.Value, k: []const u8) []const u8 {
            return getStr(v, k) orelse "";
        }
    }.f;
    const call: Call = if (eq(name, "bash"))
        .{ .exec = s(args, "command") }
    else if (eq(name, "read"))
        .{ .read_file = s(args, "path") }
    else if (eq(name, "write"))
        .{ .write_file = s(args, "path") }
    else if (eq(name, "edit"))
        .{ .edit_file = s(args, "path") }
    else if (eq(name, "grep"))
        .{ .search = .{ .pattern = s(args, "pattern"), .path = getStr(args, "path") } }
    else if (eq(name, "find"))
        .{ .glob = s(args, "pattern") }
    else if (std.mem.startsWith(u8, name, "harness_"))
        // Rust slices `name[6..]` (keeping "s_"); kept identical on purpose.
        .{ .mcp = .{ .server = "harness", .tool = name[6..] } }
    else
        .{ .unknown = .{ .name = name, .input = args } };
    return call.toJson(a);
}

/// Event normalizer (`normalize.rs`).
pub const Normalizer = struct {
    /// Bytes already emitted per (kind, contentIndex) of the current message.
    seen: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    tools: std.ArrayList([]const u8) = .empty,
    err: ?[]const u8 = null,

    fn key(thinking: bool, index: i64) u64 {
        return (@as(u64, @intFromBool(thinking)) << 63) | @as(u64, @bitCast(index & 0x7fffffffffffffff));
    }

    pub fn apply(self: *Normalizer, gpa: Allocator, a: Allocator, frame: json.Value, out: *std.ArrayList(Event)) !void {
        const ty = getStr(frame, "type") orelse return;
        if (eq(ty, "message_start")) {
            const msg = get(frame, "message") orelse return;
            if (eq(getStr(msg, "role") orelse "", "assistant")) self.seen.clearRetainingCapacity();
        } else if (eq(ty, "message_update")) {
            const ev = get(frame, "assistantMessageEvent") orelse return;
            const et = getStr(ev, "type") orelse "";
            const thinking = eq(et, "thinking_delta");
            if (!thinking and !eq(et, "text_delta")) return;
            const delta = getStr(ev, "delta") orelse return;
            if (delta.len == 0) return;
            const idx: i64 = if (get(ev, "contentIndex")) |c| (if (c == .integer) c.integer else 0) else 0;
            const gop = try self.seen.getOrPut(gpa, key(thinking, idx));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += delta.len;
            try out.append(a, if (thinking) .{ .reasoning = delta } else .{ .text = delta });
        } else if (eq(ty, "message_end")) {
            const msg = get(frame, "message") orelse return;
            if (!eq(getStr(msg, "role") orelse "", "assistant")) return;
            const stop = getStr(msg, "stopReason") orelse "";
            if (eq(stop, "error")) self.err = try a.dupe(u8, getStr(msg, "errorMessage") orelse "Pi provider failed");
            if (get(msg, "content")) |content| if (content == .array) for (content.array.items, 0..) |part, i| {
                const pt = getStr(part, "type") orelse continue;
                const thinking = eq(pt, "thinking");
                if (!thinking and !eq(pt, "text")) continue;
                const full = getStr(part, if (thinking) "thinking" else "text") orelse continue;
                const done = self.seen.get(key(thinking, @intCast(i))) orelse 0;
                if (full.len > done) try out.append(a, if (thinking) .{ .reasoning = full[done..] } else .{ .text = full[done..] });
            };
            try out.append(a, .message_completed);
        } else if (eq(ty, "tool_execution_start")) {
            const id = getStr(frame, "toolCallId") orelse return;
            for (self.tools.items) |t| if (eq(t, id)) return;
            try self.tools.append(gpa, try gpa.dupe(u8, id));
            try out.append(a, .{ .tool_call = .{ .id = id, .call = try toolCall(a, getStr(frame, "toolName") orelse "", get(frame, "args") orelse json.Value{ .null = {} }) } });
        } else if (eq(ty, "tool_execution_end")) {
            const id = getStr(frame, "toolCallId") orelse return;
            try out.append(a, .{ .tool_result = .{ .id = id, .is_error = agent_turn.getBool(frame, "isError") orelse false } });
        } else if (eq(ty, "extension_error")) {
            const msg = try std.fmt.allocPrint(a, "Pi extension: {s}", .{getStr(frame, "error") orelse ""});
            self.err = msg;
            try out.append(a, .{ .err = msg });
        }
    }

    pub fn deinit(self: *Normalizer, gpa: Allocator) void {
        self.seen.deinit(gpa);
        for (self.tools.items) |t| gpa.free(t);
        self.tools.deinit(gpa);
    }
};

/// `extension_ui_request` → question (null for methods that don't ask).
pub fn uiQuestion(a: Allocator, frame: json.Value) !?agent_turn.Question {
    const method = getStr(frame, "method") orelse return null;
    if (!(eq(method, "select") or eq(method, "confirm") or eq(method, "input") or eq(method, "editor"))) return null;
    const title = getStr(frame, "title") orelse "";
    const message = getStr(frame, "message");
    var opts: std.ArrayList([]const u8) = .empty;
    if (eq(method, "confirm")) {
        try opts.appendSlice(a, &.{ "Yes", "No" });
    } else if (get(frame, "options")) |os| if (os == .array) for (os.array.items) |o| {
        if (o == .string) try opts.append(a, o.string) else if (getStr(o, "label") orelse getStr(o, "value")) |l| try opts.append(a, l);
    };
    return .{
        .id = "pi",
        .header = "Pi",
        .question = if (message) |m| try std.fmt.allocPrint(a, "{s}\n{s}", .{ title, m }) else title,
        .options = opts.items,
        .prefill = getStr(frame, "prefill"),
        .multiline = eq(method, "editor"),
    };
}

const State = struct { next: u64 = 1 };

fn state(t: *Turn) ?*State {
    return @ptrCast(@alignCast(t.state orelse return null));
}

/// Send a command with a fresh `harness-{n}` id; returns n.
fn command(t: *Turn, body_without_brace: []const u8) ?u64 {
    t.mu.lockUncancelable(t.io);
    const st = state(t) orelse {
        t.mu.unlock(t.io);
        return null;
    };
    const id = st.next;
    st.next += 1;
    t.mu.unlock(t.io);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    buf.print(t.gpa, "{{\"id\":\"harness-{d}\",{s}", .{ id, body_without_brace }) catch return null;
    if (!t.send(buf.items)) return null;
    return id;
}

fn responseId(frame: json.Value) ?u64 {
    if (!eq(getStr(frame, "type") orelse "", "response")) return null;
    const id = getStr(frame, "id") orelse return null;
    if (!std.mem.startsWith(u8, id, "harness-")) return null;
    return std.fmt.parseInt(u64, id["harness-".len..], 10) catch null;
}

const kind_ui: u8 = 1;

fn answer(t: *Turn, p: *const agent_turn.Pending, answers: ?[]const agent_turn.Answer) void {
    if (p.kind != kind_ui) return;
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const data = json.parseFromSliceLeaky(json.Value, a, p.data, .{}) catch return;
    const id = getStr(data, "id") orelse return;
    const method = getStr(data, "method") orelse "";
    const labels = agent_turn.labelsFor(answers, "pi");
    const line = if (answers == null or labels.len == 0)
        std.fmt.allocPrint(a, "{{\"type\":\"extension_ui_response\",\"id\":{f},\"cancelled\":true}}", .{json.fmt(id, .{})})
    else if (eq(method, "confirm"))
        std.fmt.allocPrint(a, "{{\"type\":\"extension_ui_response\",\"id\":{f},\"confirmed\":{}}}", .{ json.fmt(id, .{}), agent_turn.answeredYes(answers) })
    else
        std.fmt.allocPrint(a, "{{\"type\":\"extension_ui_response\",\"id\":{f},\"value\":{f}}}", .{ json.fmt(id, .{}), json.fmt(labels[0], .{}) });
    _ = t.send(line catch return);
}

fn interrupt(t: *Turn) void {
    _ = command(t, "\"type\":\"clear_queue\"}");
    _ = command(t, "\"type\":\"abort\"}");
}

fn steer(t: *Turn, text: []const u8) bool {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    buf.print(t.gpa, "\"type\":\"prompt\",\"message\":{f},\"streamingBehavior\":\"steer\"}}", .{json.fmt(text, .{})}) catch return false;
    return command(t, buf.items) != null;
}

/// Pi below 0.85.1 lacks the RPC this adapter speaks.
pub fn versionSupported(version: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, std.mem.trimStart(u8, version, "v"), ".-+ ");
    const want = [_]u64{ 0, 85, 1 };
    for (want) |w| {
        const part = it.next() orelse return true;
        const n = std.fmt.parseInt(u64, part, 10) catch return true;
        if (n != w) return n > w;
    }
    return true;
}

fn probeVersion(t: *Turn, exe: []const u8, env: *const std.process.Environ.Map) ?[]const u8 {
    const p = agent_proc.AgentProc.spawn(t.gpa, t.io, &.{ exe, "--version" }, null, env, .{ .stdin = false }) catch return null;
    defer p.destroy();
    // The turn's process while it runs, so an interrupt or shutdown ends it.
    t.setProc(p);
    defer {
        t.mu.lockUncancelable(t.io);
        t.proc = null;
        t.mu.unlock(t.io);
    }
    if (t.interrupted.load(.acquire)) p.terminate();
    p.armDeadline(10_000);
    const line = (p.readLine() catch return null) orelse return null;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (it.next()) |tok| if (tok.len > 0 and std.ascii.isDigit(std.mem.trimStart(u8, tok, "v")[0])) return t.arena.allocator().dupe(u8, tok) catch null;
    return null;
}

const Wire = struct {
    t: *Turn,
    proc: *agent_proc.AgentProc,
    norm: Normalizer = .{},
    events: std.ArrayList(Event) = .empty,
    settled: bool = false,

    fn route(self: *Wire, a: Allocator, frame: json.Value) !?u64 {
        if (responseId(frame)) |id| return id;
        const ty = getStr(frame, "type") orelse return null;
        if (eq(ty, "extension_ui_request")) {
            const id = getStr(frame, "id") orelse return null;
            if (try uiQuestion(a, frame)) |q| {
                const data = try std.fmt.allocPrint(a, "{{\"id\":{f},\"method\":{f}}}", .{ json.fmt(id, .{}), json.fmt(getStr(frame, "method") orelse "", .{}) });
                try self.t.ask(kind_ui, data, &.{q});
            } else if (eq(getStr(frame, "method") orelse "", "notify")) {
                try self.events.append(a, .{ .text = try std.fmt.allocPrint(a, "\n{s}\n", .{getStr(frame, "message") orelse ""}) });
            }
            return null;
        }
        if (eq(ty, "agent_settled")) self.settled = true;
        try self.norm.apply(self.t.gpa, a, frame, &self.events);
        return null;
    }

    /// Send `body` and wait for its response's `data` (error → failure).
    fn query(self: *Wire, a: Allocator, body: []const u8) !json.Value {
        const id = command(self.t, body) orelse return self.t.fail("Pi disconnected", .{});
        while (try self.proc.readLine()) |line| {
            const frame = json.parseFromSliceLeaky(json.Value, a, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
            if (frame != .object) continue;
            if (try self.route(a, frame)) |rid| if (rid == id) {
                if (!(agent_turn.getBool(frame, "success") orelse false)) {
                    return self.t.fail("harness protocol error: Pi {s}: {s}", .{ getStr(frame, "command") orelse "command", getStr(frame, "error") orelse "command failed" });
                }
                return get(frame, "data") orelse json.Value{ .null = {} };
            };
        }
        return self.t.fail("{s}", .{self.t.crash(self.proc)});
    }
};

fn run(t: *Turn) !void {
    const a = t.arena.allocator();
    var st: State = .{};
    t.state = &st;
    defer {
        t.mu.lockUncancelable(t.io);
        t.state = null;
        t.mu.unlock(t.io);
    }
    const exe = try t.resolveExe("pi", "PI_EXECUTABLE", &extra_paths, install_hint);
    var env = try t.childEnv(exe);
    defer env.deinit();
    if (probeVersion(t, exe, &env)) |v| if (!versionSupported(v)) return t.fail("harness protocol error: Pi {s} is unsupported; update Pi to 0.85.1 or newer", .{v});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ exe, "--mode", "rpc", "--no-themes" });
    var restore_note: ?[]const u8 = null;
    if (t.req.resume_id) |id| {
        if (try resolveSession(a, t.io, t.req.env, id)) |file| {
            try argv.appendSlice(a, &.{ "--session", file });
        } else {
            restore_note = try std.fmt.allocPrint(a, "Pi could not restore session {s}; starting a new session without the previous context: no session file found", .{id});
        }
    }
    const proc = try t.spawn(argv.items, &env, .{});
    if (restore_note) |n| t.emit(.{ .err = n });

    var wire: Wire = .{ .t = t, .proc = proc };
    defer wire.norm.deinit(t.gpa);
    var line_arena = std.heap.ArenaAllocator.init(t.gpa);
    defer line_arena.deinit();
    const la = line_arena.allocator();
    proc.escalate(120_000, 120_000 + agent_turn.kill_grace_ms);

    if (!steeringConfigured(la, t.io, t.req.env, t.req.cwd)) _ = try wire.query(la, "\"type\":\"set_steering_mode\",\"mode\":\"all\"}");
    if (t.req.model) |model| if (!eq(model, "default")) {
        const data = try wire.query(la, "\"type\":\"get_available_models\"}");
        const models = get(data, "models") orelse return t.fail("harness protocol error: Pi returned no models", .{});
        if (models != .array) return t.fail("harness protocol error: Pi returned no models", .{});
        var found: ?json.Value = null;
        for (models.array.items) |m| {
            const full = try std.fmt.allocPrint(la, "{s}/{s}", .{ getStr(m, "provider") orelse "", getStr(m, "id") orelse "" });
            if (eq(full, model)) found = m;
        }
        if (found == null) {
            var n: usize = 0;
            for (models.array.items) |m| if (eq(getStr(m, "id") orelse "", model)) {
                n += 1;
                found = m;
            };
            if (n != 1) found = null;
        }
        const m = found orelse return t.fail("harness protocol error: Pi model is not available: {s}", .{model});
        _ = try wire.query(la, try std.fmt.allocPrint(la, "\"type\":\"set_model\",\"provider\":{f},\"modelId\":{f}}}", .{ json.fmt(getStr(m, "provider") orelse "", .{}), json.fmt(getStr(m, "id") orelse "", .{}) }));
    };
    const thinking_off = blk: {
        const mo = t.req.model_options_json orelse break :blk false;
        const v = json.parseFromSliceLeaky(json.Value, la, mo, .{}) catch break :blk false;
        break :blk eq(getStr(v, "pi_thinking") orelse "", "off");
    };
    if (t.req.reasoning != null or thinking_off) {
        const data = try wire.query(la, "\"type\":\"get_available_thinking_levels\"}");
        var levels: std.ArrayList([]const u8) = .empty;
        if (get(data, "levels")) |ls| if (ls == .array) for (ls.array.items) |l| if (l == .string) try levels.append(la, l.string);
        const desired = if (thinking_off) "off" else t.req.reasoning.?;
        const level = pickThinking(desired, levels.items) orelse return t.fail("harness protocol error: Pi returned no supported thinking level", .{});
        _ = try wire.query(la, try std.fmt.allocPrint(la, "\"type\":\"set_thinking_level\",\"level\":{f}}}", .{json.fmt(level, .{})}));
    }
    const state0 = try wire.query(la, "\"type\":\"get_state\"}");
    const session_id = try a.dupe(u8, getStr(state0, "sessionId") orelse return t.fail("harness protocol error: Pi get_state omitted sessionId", .{}));
    if (t.req.resume_id) |r| if (restore_note == null and !eq(r, session_id)) return t.fail("harness protocol error: Pi resumed a different session", .{});
    if (getStr(state0, "sessionFile")) |f| rememberSession(la, t.io, t.req.env, session_id, f);
    proc.clearDeadline();
    t.emit(.{ .session_started = session_id });
    for (wire.events.items) |ev| t.emit(ev);
    wire.events = .empty;
    _ = line_arena.reset(.retain_capacity);
    if (t.interrupted.load(.acquire)) {
        t.emit(.{ .done = .{ .status = .interrupted, .session_id = session_id } });
        return;
    }

    var pbuf: std.ArrayList(u8) = .empty;
    defer pbuf.deinit(t.gpa);
    try pbuf.print(t.gpa, "\"type\":\"prompt\",\"message\":{f},\"streamingBehavior\":\"followUp\"}}", .{json.fmt(t.req.prompt, .{})});
    const prompt_id = command(t, pbuf.items) orelse return t.fail("Pi disconnected", .{});
    var acked = false;
    var barrier: ?u64 = null;
    var saw_done = false;
    while (try proc.readLine()) |line| {
        defer _ = line_arena.reset(.retain_capacity);
        const lla = line_arena.allocator();
        wire.events = .empty;
        const frame = json.parseFromSliceLeaky(json.Value, lla, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
        if (frame != .object) continue;
        const rid = try wire.route(lla, frame);
        for (wire.events.items) |ev| t.emit(ev);
        if (rid) |r| {
            if (r == prompt_id) {
                if (!(agent_turn.getBool(frame, "success") orelse false)) {
                    t.emit(.{ .done = .{ .status = if (t.interrupted.load(.acquire)) .interrupted else .errored, .err = try std.fmt.allocPrint(a, "harness protocol error: Pi prompt: {s}", .{getStr(frame, "error") orelse "command failed"}), .session_id = session_id } });
                    saw_done = true;
                    break;
                }
                acked = true;
                barrier = command(t, "\"type\":\"get_state\"}");
            } else if (barrier != null and r == barrier.?) {
                barrier = null;
                const data = get(frame, "data") orelse json.Value{ .null = {} };
                const streaming = agent_turn.getBool(data, "isStreaming") orelse true;
                const compacting = agent_turn.getBool(data, "isCompacting") orelse true;
                if (acked and !streaming and !compacting) {
                    if (getStr(data, "sessionFile")) |f| rememberSession(lla, t.io, t.req.env, session_id, f);
                    const status: agent_turn.DoneStatus = if (t.interrupted.load(.acquire)) .interrupted else if (wire.norm.err != null) .errored else .completed;
                    t.emit(.{ .done = .{ .status = status, .err = if (status == .errored) try a.dupe(u8, wire.norm.err.?) else null, .session_id = session_id } });
                    saw_done = true;
                    break;
                }
            }
        }
        if (wire.settled and barrier == null) {
            wire.settled = false;
            barrier = command(t, "\"type\":\"get_state\"}");
        }
    }
    if (!saw_done) {
        if (t.interrupted.load(.acquire)) {
            t.emit(.{ .done = .{ .status = .interrupted, .session_id = session_id } });
        } else {
            t.emit(.{ .done = .{ .status = .errored, .err = t.crash(proc), .session_id = session_id } });
        }
    }
    proc.closeStdin();
    proc.escalate(agent_turn.kill_grace_ms, agent_turn.kill_grace_ms * 2);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pi: version gate, thinking ladder, tool calls and session index path" {
    try testing.expect(versionSupported("0.85.1"));
    try testing.expect(versionSupported("v0.90.0"));
    try testing.expect(versionSupported("1.0.0"));
    try testing.expect(!versionSupported("0.85.0"));
    try testing.expect(!versionSupported("0.7.9"));
    try testing.expectEqualStrings("high", pickThinking("xhigh", &.{ "off", "low", "high" }).?);
    try testing.expectEqualStrings("off", pickThinking("off", &.{ "off", "low" }).?);
    try testing.expect(pickThinking("low", &.{"high"}) == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try json.parseFromSliceLeaky(json.Value, a, "{\"command\":\"ls\",\"path\":\"x\",\"pattern\":\"*.zig\"}", .{});
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"ls\"}", try toolCall(a, "bash", args));
    try testing.expectEqualStrings("{\"kind\":\"glob\",\"pattern\":\"*.zig\"}", try toolCall(a, "find", args));
    try testing.expectEqualStrings("{\"kind\":\"mcp\",\"server\":\"harness\",\"tool\":\"s_rooms\"}", try toolCall(a, "harness_rooms", args));
    const p = try indexPath(a, "/agent", "abc");
    try testing.expect(std.mem.startsWith(u8, p, "/agent/harness-sessions/ba7816bf"));
}

test "pi: events stream deltas and only the unseen suffix at message end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n: Normalizer = .{};
    defer n.deinit(testing.allocator);
    var out: std.ArrayList(Event) = .empty;
    const frames = [_][]const u8{
        "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\"}}",
        "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"Hel\"}}",
        "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}}",
        "{\"type\":\"tool_execution_start\",\"toolCallId\":\"t1\",\"toolName\":\"read\",\"args\":{\"path\":\"a.md\"}}",
        "{\"type\":\"tool_execution_start\",\"toolCallId\":\"t1\",\"toolName\":\"read\",\"args\":{\"path\":\"a.md\"}}",
        "{\"type\":\"tool_execution_end\",\"toolCallId\":\"t1\",\"isError\":true}",
        "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"error\",\"errorMessage\":\"rate limited\",\"content\":[]}}",
    };
    for (frames) |f| try n.apply(testing.allocator, a, try json.parseFromSliceLeaky(json.Value, a, f, .{}), &out);
    try testing.expectEqualStrings("Hel", out.items[0].text);
    try testing.expectEqualStrings("lo", out.items[1].text);
    try testing.expect(out.items[2] == .message_completed);
    try testing.expectEqualStrings("{\"kind\":\"readFile\",\"path\":\"a.md\"}", out.items[3].tool_call.call);
    try testing.expect(out.items[4].tool_result.is_error);
    try testing.expectEqual(@as(usize, 6), out.items.len);
    try testing.expectEqualStrings("rate limited", n.err.?);
    const q = (try uiQuestion(a, try json.parseFromSliceLeaky(json.Value, a, "{\"type\":\"extension_ui_request\",\"id\":\"u1\",\"method\":\"confirm\",\"title\":\"Deploy?\",\"message\":\"to prod\"}", .{}))).?;
    try testing.expectEqualStrings("Deploy?\nto prod", q.question);
    try testing.expectEqual(@as(usize, 2), q.options.len);
}

const testkit = @import("agent_testkit.zig");

const mock_pi =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\if [ "$1" = "--version" ]; then echo "0.86.2"; exit 0; fi
    \\printf '%s\n' "$@" > "$d/argv.txt"
    \\idof() { printf '%s' "$1" | sed 's/.*"id":"\(harness-[0-9]*\)".*/\1/'; }
    \\mkdir -p "$d/sess"
    \\echo '{"type":"session","id":"pi-sess-1"}' > "$d/sess/s.jsonl"
    \\while IFS= read -r line; do
    \\  printf '%s\n' "$line" >> "$d/stdin.txt"
    \\  id=$(idof "$line")
    \\  case "$line" in
    \\    *'"type":"get_state"'*)
    \\      if [ -f "$d/settled" ]; then busy=false; else busy=true; fi
    \\      echo '{"type":"response","id":"'$id'","command":"get_state","success":true,"data":{"sessionId":"pi-sess-1","sessionFile":"'$d'/sess/s.jsonl","isStreaming":'$busy',"isCompacting":false}}';;
    \\    *'"type":"prompt"'*'"streamingBehavior":"followUp"'*)
    \\      rm -f "$d/settled"
    \\      echo '{"type":"response","id":"'$id'","command":"prompt","success":true}'
    \\      echo '{"type":"message_start","message":{"role":"assistant"}}'
    \\      echo '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Pi says hi"}}'
    \\      echo '{"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Proceed?"}';;
    \\    *'"type":"extension_ui_response"'*'"confirmed":true'*)
    \\      echo '{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash","args":{"command":"echo ok"}}'
    \\      echo '{"type":"tool_execution_end","toolCallId":"t1","isError":false}'
    \\      echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Pi says hi"}]}}'
    \\      touch "$d/settled"; echo '{"type":"agent_settled"}';;
    \\    *'"type":"abort"'*) touch "$d/settled"; echo '{"type":"response","id":"'$id'","command":"abort","success":true}'; echo '{"type":"agent_settled"}';;
    \\    *'"type":'*) echo '{"type":"response","id":"'$id'","success":true,"data":{}}';;
    \\  esac
    \\done
    \\
;

test "pi: a turn against a mock pi asks, runs a tool, settles and resumes its session file" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "pi", .override_var = "PI_EXECUTABLE", .script = mock_pi });
    defer rig.destroy();
    try rig.run("m-1", "say hi");
    try rig.waitQuestion(5000);
    try rig.waitFor("\"question\":\"Proceed?\"", 1000);
    try rig.answerOpen("pi", "Yes");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"Pi says hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"call\":{\"kind\":\"exec\",\"command\":\"echo ok\"},\"resolved\":true,\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"complete\"") != null);
    try testing.expectEqualStrings("pi-sess-1", rig.chatSessionId().?);

    try rig.run("m-2", "again");
    try rig.waitQuestion(5000);
    try rig.command("{\"kind\":\"interrupt\"}");
    try rig.waitIdle(8000);
    const argv = try rig.readFile("argv.txt");
    defer testing.allocator.free(argv);
    try testing.expect(std.mem.indexOf(u8, argv, "--mode\nrpc\n--no-themes\n--session\n") != null);
    try testing.expect(std.mem.indexOf(u8, argv, "/sess/s.jsonl\n") != null);
    const stdin = try rig.readFile("stdin.txt");
    defer testing.allocator.free(stdin);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"type\":\"clear_queue\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"type\":\"abort\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"type\":\"extension_ui_response\",\"id\":\"ui-1\",\"cancelled\":true") != null);
    const doc2 = try rig.docJson();
    defer testing.allocator.free(doc2);
    try testing.expect(std.mem.indexOf(u8, doc2, "\"status\":\"aborted\"") != null);
}

test "pi: a missing binary is reported with Rust's hint" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "pi", .override_var = "PI_EXECUTABLE", .script = mock_pi, .missing_binary = true });
    defer rig.destroy();
    try rig.run("m-1", "hi");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "harness binary not found: /nonexistent/harness-agent-mock does not exist") != null);
}
