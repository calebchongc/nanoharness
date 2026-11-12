//! Terminal and project-Action RPCs (`crates/engine/src/rpc.rs`,
//! `project_actions.rs`): `OpenTerminal`, `SubscribeTerminal`,
//! `WriteTerminal`, `ResizeTerminal`, `CloseTerminal`, `RunProjectAction`, and
//! the setup Action a new worktree runs. The PTYs themselves are
//! `terminals_host.zig`; this file resolves folders, checks ownership and
//! carries events to subscribers.
//!
//! A `SubscribeTerminal` stream is a watch on the engine's list (kind
//! `.queue`, a target id that starts with an ASCII record separator, which no
//! chat id has), so a cancel or a dropped connection detaches it. It ends
//! with a `done` frame after the shell's `exit` event, and when the terminal
//! is closed.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const ws_server = @import("ws_server.zig");
const common = @import("rpcw_common.zig");
const terms = @import("terminals_host.zig");
const g = @import("rpcg_git.zig");
const rpc = @import("rpcg_rpc.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

pub const watch_kind: engine_host.WatchKind = .queue;
const target_prefix = "\x1eterminal:";

fn targetFor(buf: []u8, terminal_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ target_prefix, terminal_id }) catch target_prefix;
}

/// Route the manager's events to this engine's subscribers (once).
pub fn attach(host: *EngineHost) void {
    if (host.terminals.guard != null) return;
    const io = host.io orelse return;
    host.terminals.attach(io, &host.mutex, .{ .ctx = host, .event = onEvent });
}

fn onEvent(ctx: *anyopaque, terminal_id: []const u8, event_json: []const u8, exit: bool) void {
    const host: *EngineHost = @ptrCast(@alignCast(ctx));
    var buf: [160]u8 = undefined;
    const target = targetFor(&buf, terminal_id);
    host.broadcastWatch(watch_kind, target, event_json) catch {};
    if (exit) endStreams(host, target);
}

/// Finish every subscription to `target` with a `done` frame and drop it.
fn endStreams(host: *EngineHost, target: []const u8) void {
    for (host.watches.items) |w| {
        if (w.kind != watch_kind) continue;
        const t = w.target_id orelse continue;
        if (!std.mem.eql(u8, t, target)) continue;
        if (w.client_writer orelse host.live_ws_writer) |wr| {
            var frame_buf: [64]u8 = undefined;
            const frame = std.fmt.bufPrint(&frame_buf, "{{\"id\":{d},\"done\":true}}", .{w.sub_id}) catch continue;
            ws_server.writeServerFrame(wr, .text, frame) catch {};
            wr.flush() catch {};
        }
    }
    host.removeTargetWatches(target);
}

// ── params ─────────────────────────────────────────────────────────────────

fn intField(comptime T: type, o: json.ObjectMap, key: []const u8, required: bool) union(enum) { ok: ?T, err: RpcOutcome } {
    const v = o.get(key) orelse return if (required) .{ .err = common.badParams("missing field `{s}`", .{key}) } else .{ .ok = null };
    switch (v) {
        .integer => |n| {
            if (n < std.math.minInt(T) or n > std.math.maxInt(T)) return .{ .err = common.badParams("invalid value: integer `{d}`, expected {s}", .{ n, @typeName(T) }) };
            return .{ .ok = @intCast(n) };
        },
        .null => return if (required) .{ .err = common.badParams("invalid type: null, expected {s}", .{@typeName(T)}) } else .{ .ok = null },
        else => return .{ .err = common.badParams("invalid type: expected {s} for `{s}`", .{ @typeName(T), key }) },
    }
}

fn object(params: json.Value) ?json.ObjectMap {
    return if (params == .object) params.object else null;
}

fn notObject(comptime name: []const u8) RpcOutcome {
    return common.badParams("invalid type: expected struct " ++ name, .{});
}

fn writeSession(w: *std.Io.Writer, s: terms.Opened) !void {
    try w.writeAll("{\"id\":");
    try g.writeJsonString(w, s.id);
    try g.field(w, true, "cwd", s.cwd);
    try g.field(w, true, "shell", s.shell);
    try w.writeByte('}');
}

fn okReply(gpa: Allocator) !RpcOutcome {
    return .{ .unary_json = try gpa.dupe(u8, "{\"ok\":true}") };
}

/// A folder the user meant ("~" and blanks mean the host's home instead).
fn meaningful(cwd: ?[]const u8) ?[]const u8 {
    const c = cwd orelse return null;
    const t = std.mem.trim(u8, c, " \t\r\n");
    if (t.len == 0 or std.mem.eql(u8, t, "~")) return null;
    return c;
}

const canvas_prefix = "space-canvas:";

/// `resolve_open_terminal_cwd`: an explicit real path, then the chat row's
/// folder, then the project named by a `space-canvas:{spaceId}` key, then `~`.
pub fn resolveOpenCwd(host: *EngineHost, gpa: Allocator, chat_id: []const u8, explicit: ?[]const u8) ![]u8 {
    var chat_cwd: ?[]const u8 = null;
    for (host.chats.items) |c| if (std.mem.eql(u8, c.id, chat_id)) {
        chat_cwd = c.cwd;
        break;
    };
    var space_cwd: ?[]const u8 = null;
    if (std.mem.startsWith(u8, chat_id, canvas_prefix) and chat_id.len > canvas_prefix.len) {
        const sid = chat_id[canvas_prefix.len..];
        for (host.spaces.items) |s| if (std.mem.eql(u8, s.id, sid)) {
            space_cwd = s.path;
            break;
        };
    }
    const raw = meaningful(explicit) orelse meaningful(chat_cwd) orelse meaningful(space_cwd) orelse "~";
    return g.expandHome(gpa, raw);
}

// ── terminals ──────────────────────────────────────────────────────────────

/// `OpenTerminal { chatId, cols, rows, cwd? }` → `TerminalSession`.
pub fn openTerminal(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    const o = object(params) orelse return notObject("OpenTerminalParams");
    const chat_id = switch (rpc.strOrFail(o, "chatId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const cols = switch (intField(u16, o, "cols", true)) {
        .ok => |n| n.?,
        .err => |e| return e,
    };
    const rows = switch (intField(u16, o, "rows", true)) {
        .ok => |n| n.?,
        .err => |e| return e,
    };
    attach(host);
    const cwd = try resolveOpenCwd(host, host.gpa, chat_id, rpc.optStr(o, "cwd"));
    defer host.gpa.free(cwd);
    const opened = switch (try host.terminals.open(.{ .cwd = cwd, .cols = cols, .rows = rows })) {
        .ok => |s| s,
        .failed => |m| return common.failedMsg(m),
    };
    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    errdefer aw.deinit();
    try writeSession(&aw.writer, opened);
    return .{ .unary_json = try aw.toOwnedSlice() };
}

/// `SubscribeTerminal { terminalId, afterSeq? }` → the replay after
/// `afterSeq`, then live events; the stream ends after `exit`.
pub fn subscribeTerminal(host: *EngineHost, call_id: u64, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    const o = object(params) orelse return notObject("SubscribeTerminalParams");
    const id = switch (rpc.strOrFail(o, "terminalId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const after = switch (intField(u64, o, "afterSeq", false)) {
        .ok => |n| n orelse 0,
        .err => |e| return e,
    };
    attach(host);
    const replay = switch (try host.terminals.replay(host.gpa, id, after)) {
        .ok => |r| r,
        .failed => |m| return common.failedMsg(m),
    };
    if (!replay.exited) {
        var buf: [160]u8 = undefined;
        if (call_id != 0) try host.registerWatch(call_id, watch_kind, targetFor(&buf, id));
        return .{ .stream_items_json = .{ .checked = false, .items = replay.items } };
    }
    // An exited terminal: the replay, then the end of the stream.
    if (host.live_ws_writer) |wr| if (call_id != 0) {
        defer {
            for (replay.items) |it| host.gpa.free(it);
            host.gpa.free(replay.items);
        }
        for (replay.items) |it| {
            const frame = try std.fmt.allocPrint(host.gpa, "{{\"id\":{d},\"item\":{s}}}", .{ call_id, it });
            defer host.gpa.free(frame);
            try ws_server.writeServerFrame(wr, .text, frame);
        }
        var done_buf: [64]u8 = undefined;
        try ws_server.writeServerFrame(wr, .text, try std.fmt.bufPrint(&done_buf, "{{\"id\":{d},\"done\":true}}", .{call_id}));
        return .{ .stream_items_json = .{ .checked = false, .items = try host.gpa.alloc([]u8, 0) } };
    };
    return .{ .stream_items_json = .{ .checked = false, .items = replay.items } };
}

/// `WriteTerminal { terminalId, data }` (base64; plain text accepted) → `{ok}`.
pub fn writeTerminal(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    const o = object(params) orelse return notObject("WriteTerminalParams");
    const id = switch (rpc.strOrFail(o, "terminalId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const data = switch (rpc.strOrFail(o, "data", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    attach(host);
    return switch (try host.terminals.write(id, data)) {
        .ok => okReply(host.gpa),
        .failed => |m| common.failedMsg(m),
    };
}

/// `ResizeTerminal { terminalId, cols, rows }` → `{ok}`.
pub fn resizeTerminal(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    const o = object(params) orelse return notObject("ResizeTerminalParams");
    const id = switch (rpc.strOrFail(o, "terminalId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const cols = switch (intField(u16, o, "cols", true)) {
        .ok => |n| n.?,
        .err => |e| return e,
    };
    const rows = switch (intField(u16, o, "rows", true)) {
        .ok => |n| n.?,
        .err => |e| return e,
    };
    attach(host);
    return switch (host.terminals.resize(id, cols, rows)) {
        .ok => okReply(host.gpa),
        .failed => |m| common.failedMsg(m),
    };
}

/// `CloseTerminal { terminalId }` → `{ok}`: kills the shell's session and
/// ends every stream attached to it.
pub fn closeTerminal(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    const o = object(params) orelse return notObject("TerminalIdParams");
    const id = switch (rpc.strOrFail(o, "terminalId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    attach(host);
    switch (try host.terminals.close(id)) {
        .failed => |m| return common.failedMsg(m),
        .ok => {},
    }
    var buf: [160]u8 = undefined;
    endStreams(host, targetFor(&buf, id));
    return okReply(host.gpa);
}

// ── project Actions ────────────────────────────────────────────────────────

/// `launch_project_action_with_environment`: the Action's command in a fresh
/// terminal in `cwd`, with `HARNESS_PROJECT_ROOT` and (for a worktree, or
/// always for setup) `HARNESS_WORKTREE_PATH`. Returns `ProjectActionRun` JSON.
pub fn launchAction(
    host: *EngineHost,
    action: *const engine_host.ProjectActionRecord,
    project_root: []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    always_include_worktree: bool,
) !terms.Result([]u8) {
    attach(host);
    var env_buf: [2][2][]const u8 = undefined;
    env_buf[0] = .{ "HARNESS_PROJECT_ROOT", project_root };
    var n_env: usize = 1;
    if (always_include_worktree or !std.mem.eql(u8, cwd, project_root)) {
        env_buf[1] = .{ "HARNESS_WORKTREE_PATH", cwd };
        n_env = 2;
    }
    const opened = switch (try host.terminals.open(.{ .cwd = cwd, .cols = cols, .rows = rows, .env = env_buf[0..n_env], .command = action.command })) {
        .ok => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"actionId\":");
    try g.writeJsonString(w, action.id);
    try g.field(w, true, "actionName", action.name);
    try w.writeAll(",\"terminal\":");
    try writeSession(w, opened);
    try w.writeByte('}');
    return .{ .ok = try aw.toOwnedSlice() };
}

/// The setup Action a project runs on a new worktree (`setup_action`):
/// the first one marked `runOnWorktreeCreate`.
pub fn setupAction(host: *EngineHost, space_id: []const u8) ?*const engine_host.ProjectActionRecord {
    for (host.actions.items) |*a| {
        if (std.mem.eql(u8, a.space_id, space_id) and a.run_on_worktree_create) return a;
    }
    return null;
}

/// `CreateWorktree`'s setup step (`launch_project_setup_action`): run the
/// space's setup Action in the new worktree at 80×24 and write
/// `,"setupAction":{…}` (or `,"setupError":"…"` when it can't start) to `w`.
/// Writes nothing when the space has no setup Action.
pub fn writeWorktreeSetup(host: *EngineHost, w: *std.Io.Writer, space_id: []const u8, project_root: []const u8, worktree_path: []const u8) !void {
    const io = host.io orelse return;
    // The persisted store (`project-actions.json`, rpcw_actions.zig) is where
    // Actions live; `host.actions` is only an in-memory fallback.
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    var persisted: engine_host.ProjectActionRecord = undefined;
    const action: *const engine_host.ProjectActionRecord = if (@import("rpcw_actions.zig").persistedSetupAction(host, arena.allocator(), space_id)) |act| blk: {
        persisted = .{
            .id = @constCast(act.id),
            .space_id = @constCast(space_id),
            .name = @constCast(act.name),
            .command = @constCast(act.command),
            .icon = @constCast(@tagName(act.icon)),
            .run_on_worktree_create = true,
        };
        break :blk &persisted;
    } else setupAction(host, space_id) orelse return;
    const root = common.canonicalize(host.gpa, io, worktree_path) orelse try host.gpa.dupe(u8, worktree_path);
    defer host.gpa.free(root);
    switch (try launchAction(host, action, project_root, root, 80, 24, true)) {
        .ok => |run| {
            defer host.gpa.free(run);
            try w.print(",\"setupAction\":{s}", .{run});
        },
        .failed => |m| {
            try w.writeAll(",\"setupError\":");
            try g.writeJsonString(w, m);
        },
    }
}

// `RunProjectAction` is rpcw_actions.run: the persisted store, launched here.
