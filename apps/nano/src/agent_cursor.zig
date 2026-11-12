//! Cursor adapter (`crates/harness/src/cursor/{mod,state}.rs`, `shim.mjs`,
//! `adapter_install.rs`).
//!
//! Cursor runs through Harness's Node shim over the pinned `@cursor/sdk`:
//! `{"op":"run",…}` on stdin starts the turn, `{"ev":…}` JSONL frames come
//! back, `{"op":"interrupt"}` stops it. The SDK is installed into the
//! managed adapters directory on first use, with the shim written beside it
//! under a content-addressed name.
const std = @import("std");
const builtin = @import("builtin");
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

/// This process's id, for a temp folder name unique to it.
fn currentPid() u64 {
    if (comptime builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

pub const adapter: agent_turn.Adapter = .{
    .name = "cursor shim",
    .run = run,
    .interrupt = interrupt,
    .answer = answer,
    // The SDK has no mid-turn injection; steers wait for the turn boundary.
    .steers_mid_turn = false,
};

pub const sdk_name = "@cursor/sdk";
pub const sdk_version = "1.0.31";
pub const shim_source = @embedFile("cursor_shim.mjs");
const ok_marker = ".harness-install-ok";

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `adapters_root` (Unix): `$HARNESS_ADAPTERS_DIR`, `$HARNESS_DATA_DIR/adapters`,
/// else `~/.harness/adapters` (or `~/.harnesser/adapters` when only that exists).
pub fn adaptersRoot(a: Allocator, io: Io, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("HARNESS_ADAPTERS_DIR")) |d| if (d.len > 0) return d;
    if (env.get("HARNESS_DATA_DIR")) |d| if (d.len > 0) return try std.fs.path.join(a, &.{ d, "adapters" });
    const home = env.get("HOME") orelse return null;
    const primary = try std.fs.path.join(a, &.{ home, ".harness" });
    const legacy = try std.fs.path.join(a, &.{ home, ".harnesser" });
    const base = if (dirExists(io, primary)) primary else if (dirExists(io, legacy)) legacy else primary;
    return try std.fs.path.join(a, &.{ base, "adapters" });
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// `install_dir_in`: `<root>/cursor__sdk/<version>`.
pub fn installDir(a: Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, "cursor__sdk", sdk_version });
}

/// `materialize_shim`'s file name: `harness-cursor-shim-<sha256>.mjs`.
pub fn shimFileName(a: Allocator) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(shim_source, &digest, .{});
    return std.fmt.allocPrint(a, "harness-cursor-shim-{x}.mjs", .{digest});
}

fn materializeShim(a: Allocator, io: Io, dir: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ dir, try shimFileName(a) });
    if (Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20))) |existing| {
        if (eq(existing, shim_source)) return path;
    } else |_| {}
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(a, "{s}/.shim-{x}", .{ dir, rnd });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = shim_source });
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    return path;
}

const npm_hint = "npm (required to install the Cursor SDK @cursor/sdk@1.0.31; searched PATH, the login shell's PATH, and fnm/nvm/volta/pnpm/bun install dirs)";
const node_hint = "node (required to run the agent's npm-distributed ACP adapter; searched PATH, the login shell's PATH, and fnm/nvm/volta/pnpm/bun install dirs)";

var install_mutex: Io.Mutex = .init;

fn findTool(t: *Turn, name: []const u8) !?[]const u8 {
    const login = if (t.req.env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(t.gpa, t.io, t.req.env);
    const found = try agent_proc.findExecutable(t.gpa, t.io, .{ .name = name, .path_env = t.req.env.get("PATH"), .login_path = login, .home = t.req.env.get("HOME"), .fnm_dir = t.req.env.get("FNM_DIR") });
    const f = found orelse return null;
    defer t.gpa.free(f);
    return try t.arena.allocator().dupe(u8, f);
}

/// `ensure_installed_shim`: the shim path inside a complete SDK install.
fn ensureShim(t: *Turn) ![]const u8 {
    const a = t.arena.allocator();
    const io = t.io;
    const root = (try adaptersRoot(a, io, t.req.env)) orelse return t.fail("adapter install failed: cannot locate a platform data directory for managed adapters", .{});
    const final_dir = try installDir(a, root);
    const marker = try std.fs.path.join(a, &.{ final_dir, ok_marker });
    install_mutex.lockUncancelable(io);
    defer install_mutex.unlock(io);
    if (Io.Dir.cwd().access(io, marker, .{})) |_| {
        return materializeShim(a, io, final_dir);
    } else |_| {}

    const npm = (try findTool(t, "npm")) orelse return t.fail("harness binary not found: {s}", .{npm_hint});
    const tmp = try std.fmt.allocPrint(a, "{s}/.tmp-cursor__sdk-{s}-{d}", .{ root, sdk_version, currentPid() });
    const cache = try std.fs.path.join(a, &.{ root, ".npm-cache" });
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().createDirPath(io, cache);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ tmp, "package.json" }), .data = "{\"private\":true}\n" });
    var env = try t.childEnv(npm);
    defer env.deinit();
    const spec = sdk_name ++ "@" ++ sdk_version;
    const proc = agent_proc.AgentProc.spawn(t.gpa, io, &.{ npm, "install", "--no-audit", "--no-fund", "--no-progress", "--loglevel=error", "--include=optional", "--cache", cache, spec }, tmp, &env, .{ .stdin = false }) catch |err|
        return t.fail("adapter install failed: npm install of the Cursor adapter ({s}) could not start: {t}", .{ spec, err });
    defer proc.destroy();
    t.setProc(proc);
    defer {
        t.mu.lockUncancelable(io);
        t.proc = null;
        t.mu.unlock(io);
    }
    proc.armDeadline(600_000);
    while (try proc.readLine()) |_| {}
    const term = proc.wait();
    const ok = if (term) |tm| tm == .exited and tm.exited == 0 else false;
    if (!ok) {
        Io.Dir.cwd().deleteTree(io, tmp) catch {};
        if (t.interrupted.load(.acquire)) return t.fail("interrupted", .{});
        const tail = proc.stderrTail(t.gpa);
        defer if (tail) |s| t.gpa.free(s);
        var sbuf: [48]u8 = undefined;
        return t.fail("adapter install failed: npm install of the Cursor adapter ({s}) failed ({s}): {s}", .{ spec, agent_proc.describeExit(&sbuf, term), tail orelse "" });
    }
    _ = try materializeShim(a, io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ tmp, ok_marker }), .data = sdk_version });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(final_dir).?);
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), final_dir, io) catch {
        if (Io.Dir.cwd().access(io, marker, .{})) |_| {
            Io.Dir.cwd().deleteTree(io, tmp) catch {};
        } else |_| {
            Io.Dir.cwd().deleteTree(io, final_dir) catch {};
            try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), final_dir, io);
        }
    };
    return materializeShim(a, io, final_dir);
}

/// `state_root`.
pub fn stateRoot(a: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("HARNESS_CURSOR_STATE_DIR")) |d| if (d.len > 0) {
        if (std.fs.path.isAbsolute(d)) return d;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.c.getcwd(&buf, buf.len) orelse return d;
        return std.fs.path.join(a, &.{ std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd)), 0), d });
    };
    return std.fs.path.join(a, &.{ env.get("HOME") orelse ".", ".harness/cursor-state" });
}

const Lease = struct { file: Io.File, store_dir: ?[]const u8 };

/// `Lease::acquire`: one owner per conversation, waiting up to 5 s.
fn acquireLease(t: *Turn, root: []const u8) !Lease {
    const a = t.arena.allocator();
    const io = t.io;
    var store_dir: ?[]const u8 = null;
    if (t.req.resume_id) |id| {
        if (id.len == 0 or std.mem.indexOfAny(u8, id, "/\\") != null or eq(id, ".") or eq(id, "..")) return t.fail("harness protocol error: Invalid Cursor session id", .{});
        const marker = try std.fs.path.join(a, &.{ root, "by-agent", id });
        if (Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(64 * 1024))) |raw| {
            const dir = std.mem.trim(u8, raw, " \t\r\n");
            if (dir.len == 0 or !dirExists(io, dir)) return t.fail("harness protocol error: Cursor conversation storage is missing; restore its state directory before resuming", .{});
            store_dir = dir;
        } else |err| if (err != error.FileNotFound) return err;
    } else {
        var rnd: [16]u8 = undefined;
        io.random(&rnd);
        rnd[6] = (rnd[6] & 0x0f) | 0x40;
        rnd[8] = (rnd[8] & 0x3f) | 0x80;
        const h = std.fmt.bytesToHex(rnd, .lower);
        const uuid = try std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
        store_dir = try std.fs.path.join(a, &.{ root, "agents", uuid });
    }
    const lock_dir = store_dir orelse try std.fs.path.join(a, &.{ root, "legacy-locks" });
    try Io.Dir.cwd().createDirPath(io, lock_dir);
    const name = if (store_dir != null) ".harness-owner.lock" else blk: {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(t.req.resume_id orelse "", &digest, .{});
        break :blk try std.fmt.allocPrint(a, "{x}.lock", .{digest});
    };
    const file = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ lock_dir, name }), .{ .truncate = false, .read = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
    errdefer file.close(io);
    var waited: u32 = 0;
    while (!(try file.tryLock(io, .exclusive))) : (waited += 25) {
        if (waited >= 5000) return t.fail("harness protocol error: This Cursor conversation is still running. Stop the current run before retrying.", .{});
        try Io.sleep(io, .fromMilliseconds(25), .awake);
    }
    return .{ .file = file, .store_dir = store_dir };
}

/// The first stdin line (`{"op":"run",…}`).
pub fn runOp(a: Allocator, req: agent_turn.Request, store_dir: ?[]const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"op\":\"run\",\"prompt\":{f},\"cwd\":{f},\"model\":{f},\"modelOptions\":{s},\"resume\":{f},\"storeDir\":{f}}}", .{
        json.fmt(req.prompt, .{}),
        json.fmt(req.cwd, .{}),
        json.fmt(req.model, .{}),
        req.model_options_json orelse "{}",
        json.fmt(req.resume_id, .{}),
        json.fmt(store_dir, .{}),
    });
}

fn firstStr(v: json.Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| if (getStr(v, k)) |s| return s;
    return null;
}

/// `decode_tool`.
pub fn decodeTool(a: Allocator, name: []const u8, args: json.Value) ![]u8 {
    const path_keys: []const []const u8 = &.{ "path", "filePath", "file_path" };
    const call: Call = if (eq(name, "shell"))
        .{ .exec = getStr(args, "command") orelse "" }
    else if (eq(name, "read"))
        .{ .read_file = firstStr(args, path_keys) orelse "" }
    else if (eq(name, "write"))
        .{ .write_file = firstStr(args, path_keys) orelse "" }
    else if (eq(name, "edit"))
        .{ .edit_file = firstStr(args, path_keys) orelse "" }
    else if (eq(name, "delete"))
        .{ .unknown = .{ .name = try std.fmt.allocPrint(a, "Delete: {s}", .{firstStr(args, path_keys) orelse ""}) } }
    else if (eq(name, "grep"))
        .{ .search = .{ .pattern = firstStr(args, &.{ "pattern", "query" }) orelse "", .path = firstStr(args, &.{ "path", "directory" }) } }
    else if (eq(name, "glob"))
        .{ .glob = firstStr(args, &.{ "pattern", "globPattern" }) orelse "" }
    else if (eq(name, "webSearch"))
        .{ .web_search = firstStr(args, &.{ "query", "search" }) orelse "" }
    else if (eq(name, "webFetch"))
        .{ .web_fetch = getStr(args, "url") orelse "" }
    else if (eq(name, "updateTodos")) blk: {
        var items: std.ArrayList(Call.TodoItem) = .empty;
        const list = get(args, "todos") orelse get(args, "items");
        if (list) |l| if (l == .array) for (l.array.items) |x| {
            const done = eq(getStr(x, "status") orelse "", "completed") or (agent_turn.getBool(x, "completed") orelse false);
            try items.append(a, .{ .text = firstStr(x, &.{ "content", "text" }) orelse "", .done = done });
        };
        break :blk .{ .todo = items.items };
    } else if (eq(name, "mcp"))
        .{ .mcp = .{ .server = firstStr(args, &.{ "server", "serverName" }) orelse "", .tool = firstStr(args, &.{ "tool", "toolName", "name" }) orelse "" } }
    else if (eq(name, "task")) blk: {
        const d = firstStr(args, &.{ "description", "prompt" }) orelse "";
        break :blk .{ .unknown = .{ .name = if (d.len > 0) try std.fmt.allocPrint(a, "Agent: {s}", .{d}) else "Agent", .input = args } };
    } else .{ .unknown = .{ .name = name } };
    return call.toJson(a);
}

/// `map_shim_frame` for top-level frames (subagent frames stay out).
pub fn mapFrame(a: Allocator, root: json.Value, interrupted: bool, out: *std.ArrayList(Event)) !void {
    const ev = getStr(root, "ev") orelse return;
    if (get(root, "parent")) |p| if (p == .string) return;
    if (eq(ev, "ready")) {
        if (getStr(root, "agentId")) |id| try out.append(a, .{ .session_started = id });
    } else if (eq(ev, "text")) {
        if (getStr(root, "text")) |s| try out.append(a, .{ .text = s });
    } else if (eq(ev, "thinking")) {
        if (getStr(root, "text")) |s| try out.append(a, .{ .reasoning = s });
    } else if (eq(ev, "tool")) {
        const id = getStr(root, "id") orelse return;
        const call = try decodeTool(a, getStr(root, "name") orelse "", get(root, "args") orelse json.Value{ .null = {} });
        try out.append(a, .{ .tool_call = .{ .id = id, .call = call } });
        if (eq(getStr(root, "phase") orelse "", "end")) try out.append(a, .{ .tool_result = .{ .id = id, .is_error = agent_turn.getBool(root, "error") orelse false } });
    } else if (eq(ev, "turn")) {
        const status = getStr(root, "status") orelse "";
        const st: agent_turn.DoneStatus = if (interrupted or eq(status, "cancelled")) .interrupted else if (eq(status, "error")) .errored else .completed;
        try out.append(a, .{ .done = .{ .status = st, .err = if (st == .errored) getStr(root, "error") else null } });
    } else if (eq(ev, "fatal")) {
        const msg = getStr(root, "message") orelse "cursor shim failed";
        try out.append(a, .{ .done = .{ .status = if (interrupted) .interrupted else .errored, .err = if (msg.len > 0) msg else "cursor shim failed" } });
    }
}

fn run(t: *Turn) !void {
    const a = t.arena.allocator();
    var exe: []const u8 = undefined;
    var args: []const []const u8 = &.{};
    const override = t.req.env.get("CURSOR_SDK_SHIM_EXECUTABLE") orelse "";
    if (override.len > 0) {
        exe = override;
    } else {
        const shim = try ensureShim(t);
        exe = (try findTool(t, "node")) orelse return t.fail("harness binary not found: {s}", .{node_hint});
        args = try a.dupe([]const u8, &.{shim});
    }

    const root = try stateRoot(a, t.req.env);
    const lease = try acquireLease(t, root);
    defer lease.file.close(t.io);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, args);
    var env = try t.childEnv(exe);
    defer env.deinit();
    try env.put("HARNESS_CURSOR_STATE_DIR", root);
    const proc = try t.spawn(argv.items, &env, .{});
    _ = t.send(try runOp(a, t.req, lease.store_dir));

    var line_arena = std.heap.ArenaAllocator.init(t.gpa);
    defer line_arena.deinit();
    var session: ?[]const u8 = null;
    var saw_done = false;
    while (try proc.readLine()) |line| {
        defer _ = line_arena.reset(.retain_capacity);
        const la = line_arena.allocator();
        const root_v = json.parseFromSliceLeaky(json.Value, la, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
        if (root_v != .object) continue;
        var events: std.ArrayList(Event) = .empty;
        try mapFrame(la, root_v, t.interrupted.load(.acquire), &events);
        for (events.items) |ev| {
            switch (ev) {
                .session_started => |s| session = try a.dupe(u8, s),
                .done => |d| {
                    saw_done = true;
                    var dd = d;
                    dd.session_id = session;
                    t.emit(.{ .done = dd });
                    continue;
                },
                else => {},
            }
            t.emit(ev);
        }
        if (saw_done) break;
    }
    if (!saw_done) {
        if (t.interrupted.load(.acquire)) {
            t.emit(.{ .done = .{ .status = .interrupted, .session_id = session } });
        } else {
            t.emit(.{ .done = .{ .status = .errored, .err = t.crash(proc), .session_id = session } });
        }
    }
    // EOF on stdin ends the shim.
    proc.closeStdin();
    proc.escalate(agent_turn.interrupt_grace_ms, agent_turn.interrupt_grace_ms + agent_turn.kill_grace_ms);
}

fn interrupt(t: *Turn) void {
    _ = t.send("{\"op\":\"interrupt\"}");
}

/// Cursor runs never ask (askQuestion is disallowed in the shim).
fn answer(_: *Turn, _: *const agent_turn.Pending, _: ?[]const agent_turn.Answer) void {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cursor: install layout, shim name and run op match the Rust adapter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HARNESS_DATA_DIR", "/data");
    try testing.expectEqualStrings("/data/adapters", (try adaptersRoot(a, testing.io, &env)).?);
    try env.put("HARNESS_ADAPTERS_DIR", "/ad");
    try testing.expectEqualStrings("/ad", (try adaptersRoot(a, testing.io, &env)).?);
    try testing.expectEqualStrings("/ad/cursor__sdk/1.0.31", try installDir(a, "/ad"));
    const name = try shimFileName(a);
    try testing.expect(std.mem.startsWith(u8, name, "harness-cursor-shim-") and std.mem.endsWith(u8, name, ".mjs") and name.len == "harness-cursor-shim-".len + 64 + 4);
    var req: agent_turn.Request = .{ .chat_id = "c", .harness = "cursor", .prompt = "go", .cwd = "/w", .env = &env, .resume_id = "agent-1" };
    try testing.expectEqualStrings("{\"op\":\"run\",\"prompt\":\"go\",\"cwd\":\"/w\",\"model\":null,\"modelOptions\":{},\"resume\":\"agent-1\",\"storeDir\":\"/s\"}", try runOp(a, req, "/s"));
    req.model = "auto";
    req.resume_id = null;
    try testing.expect(std.mem.indexOf(u8, try runOp(a, req, null), "\"model\":\"auto\",\"modelOptions\":{},\"resume\":null,\"storeDir\":null") != null);
}

test "cursor: shim frames map to events and tools decode like decode_tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Event) = .empty;
    const frames = [_][]const u8{
        "{\"ev\":\"ready\",\"agentId\":\"ag-1\",\"model\":\"auto\"}",
        "{\"ev\":\"thinking\",\"text\":\"plan\"}",
        "{\"ev\":\"text\",\"text\":\"child\",\"parent\":\"t0\"}",
        "{\"ev\":\"tool\",\"phase\":\"start\",\"id\":\"t1\",\"name\":\"grep\",\"args\":{\"pattern\":\"fn\",\"directory\":\"src\"}}",
        "{\"ev\":\"tool\",\"phase\":\"end\",\"id\":\"t1\",\"name\":\"grep\",\"args\":{\"pattern\":\"fn\"},\"error\":true}",
        "{\"ev\":\"turn\",\"status\":\"error\",\"error\":\"quota\"}",
    };
    for (frames) |f| try mapFrame(a, try json.parseFromSliceLeaky(json.Value, a, f, .{}), false, &out);
    try testing.expectEqualStrings("ag-1", out.items[0].session_started);
    try testing.expectEqualStrings("plan", out.items[1].reasoning);
    try testing.expectEqualStrings("{\"kind\":\"search\",\"pattern\":\"fn\",\"path\":\"src\"}", out.items[2].tool_call.call);
    try testing.expect(out.items[4].tool_result.is_error);
    try testing.expectEqualStrings("quota", out.items[5].done.err.?);
    try testing.expectEqualStrings("{\"kind\":\"unknown\",\"name\":\"Delete: a.txt\"}", try decodeTool(a, "delete", try json.parseFromSliceLeaky(json.Value, a, "{\"path\":\"a.txt\"}", .{})));
}

const testkit = @import("agent_testkit.zig");

const mock_shim =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\env > "$d/env.txt"
    \\IFS= read -r first
    \\printf '%s\n' "$first" > "$d/stdin.txt"
    \\echo '{"ev":"ready","agentId":"cursor-agent-1","model":"auto"}'
    \\echo '{"ev":"text","text":"On it"}'
    \\echo '{"ev":"tool","phase":"start","id":"t1","name":"shell","args":{"command":"npm test"}}'
    \\case "$first" in
    \\  *'"prompt":"stop me"'*)
    \\    while IFS= read -r line; do case "$line" in *'"op":"interrupt"'*) echo '{"ev":"turn","status":"cancelled"}';; esac; done;;
    \\  *)
    \\    echo '{"ev":"tool","phase":"end","id":"t1","name":"shell","args":{"command":"npm test"}}'
    \\    echo '{"ev":"turn","status":"completed"}'
    \\    IFS= read -r rest;;
    \\esac
    \\
;

test "cursor: a turn against a mock shim streams, records the agent id and interrupts" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "cursor", .override_var = "CURSOR_SDK_SHIM_EXECUTABLE", .script = mock_shim });
    defer rig.destroy();
    try rig.run("m-1", "fix tests");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"On it\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"call\":{\"kind\":\"exec\",\"command\":\"npm test\"},\"resolved\":true,\"isError\":false") != null);
    try testing.expectEqualStrings("cursor-agent-1", rig.chatSessionId().?);
    const stdin = try rig.readFile("stdin.txt");
    defer testing.allocator.free(stdin);
    try testing.expect(std.mem.indexOf(u8, stdin, "{\"op\":\"run\",\"prompt\":\"fix tests\",\"cwd\":") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"storeDir\":\"") != null);
    const env = try rig.readFile("env.txt");
    defer testing.allocator.free(env);
    try testing.expect(std.mem.indexOf(u8, env, "HARNESS_CURSOR_STATE_DIR=") != null);

    try rig.run("m-2", "stop me");
    try rig.waitFor("\"status\":\"streaming\",\"parts\":[{\"id\":\"t0\",\"kind\":\"text\",\"text\":\"On it\"}", 5000);
    try rig.command("{\"kind\":\"interrupt\"}");
    try rig.waitIdle(8000);
    const doc2 = try rig.docJson();
    defer testing.allocator.free(doc2);
    try testing.expect(std.mem.indexOf(u8, doc2, "\"status\":\"aborted\"") != null);
    const stdin2 = try rig.readFile("stdin.txt");
    defer testing.allocator.free(stdin2);
    try testing.expect(std.mem.indexOf(u8, stdin2, "\"resume\":\"cursor-agent-1\"") != null);
}

test "cursor: a missing shim executable is reported" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "cursor", .override_var = "CURSOR_SDK_SHIM_EXECUTABLE", .script = mock_shim, .missing_binary = true });
    defer rig.destroy();
    try rig.run("m-1", "hi");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "harness binary not found: /nonexistent/harness-agent-mock (version unknown)") != null);
}

test "cursor: first use installs the pinned SDK with npm, writes the shim and runs it with node" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "cursor", .override_var = "HARNESS_TEST_UNUSED", .script = mock_shim });
    defer rig.destroy();
    const io = testing.io;
    const gpa = testing.allocator;
    const bin = try std.fmt.allocPrint(gpa, "{s}/bin", .{rig.dir});
    defer gpa.free(bin);
    try Io.Dir.cwd().createDirPath(io, bin);
    const npm =
        \\#!/bin/sh
        \\printf '%s\n' "$@" > "$(dirname "$0")/../npm-args.txt"
        \\mkdir -p node_modules/@cursor/sdk && echo '{}' > node_modules/@cursor/sdk/package.json
        \\
    ;
    const node =
        \\#!/bin/sh
        \\printf '%s\n' "$1" > "$(dirname "$0")/../node-args.txt"
        \\exec /bin/sh "$(dirname "$0")/../agent.sh"
        \\
    ;
    inline for (.{ .{ "npm", npm }, .{ "node", node } }) |e| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bin, e[0] });
        defer gpa.free(p);
        var f = try Io.Dir.cwd().createFile(io, p, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, e[1]);
    }
    const path = try std.fmt.allocPrint(gpa, "{s}:/usr/bin:/bin", .{bin});
    defer gpa.free(path);
    try rig.env.put("PATH", path);
    const adapters = try std.fmt.allocPrint(gpa, "{s}/adapters", .{rig.dir});
    defer gpa.free(adapters);
    try rig.env.put("HARNESS_ADAPTERS_DIR", adapters);

    try rig.run("m-1", "fix tests");
    try rig.waitIdle(8000);
    const doc = try rig.docJson();
    defer gpa.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"On it\"") != null);
    const npm_args = try rig.readFile("npm-args.txt");
    defer gpa.free(npm_args);
    try testing.expect(std.mem.startsWith(u8, npm_args, "install\n--no-audit\n--no-fund\n--no-progress\n--loglevel=error\n--include=optional\n--cache\n"));
    try testing.expect(std.mem.endsWith(u8, npm_args, "@cursor/sdk@1.0.31\n"));
    const node_args = try rig.readFile("node-args.txt");
    defer gpa.free(node_args);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const shim = try std.fmt.allocPrint(arena.allocator(), "{s}/cursor__sdk/1.0.31/{s}\n", .{ adapters, try shimFileName(arena.allocator()) });
    try testing.expectEqualStrings(shim, node_args);
    const written = try Io.Dir.cwd().readFileAlloc(io, shim[0 .. shim.len - 1], gpa, .limited(1 << 20));
    defer gpa.free(written);
    try testing.expectEqualStrings(shim_source, written);
}
