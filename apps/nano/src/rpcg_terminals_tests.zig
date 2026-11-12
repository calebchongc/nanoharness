//! Engine-level tests for the terminal and project-Action RPCs. Shells are
//! `/bin/sh` (`SHELL` in the synthetic environment) with `HOME` in a temporary
//! folder, driven by fixed scripts; every wait has a deadline and closing a
//! terminal kills its session.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const engine_host = @import("engine_host.zig");
const common = @import("rpcw_common.zig");
const terms = @import("terminals_host.zig");
const Fixture = @import("rpcg_rpc_tests.zig").Fixture;

fn initFixture() !*Fixture {
    const f = try Fixture.init();
    try f.t.env.map.put("SHELL", "/bin/sh");
    return f;
}

/// Wait for pushed `data` events on `sub_id` whose decoded bytes contain `needle`.
fn waitOutput(f: *Fixture, sub_id: u64, needle: []const u8) !void {
    var waited: usize = 0;
    while (waited < 15_000) : (waited += 25) {
        {
            f.host.mutex.lockUncancelable(testing.io);
            defer f.host.mutex.unlock(testing.io);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var out: std.ArrayList(u8) = .empty;
            for (f.host.pushed_frames.items) |p| {
                if (p.sub_id != sub_id) continue;
                const v = try json.parseFromSliceLeaky(json.Value, a, p.item_json, .{});
                if (!std.mem.eql(u8, v.object.get("type").?.string, "data")) continue;
                const b64 = v.object.get("data").?.string;
                const bytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
                try std.base64.standard.Decoder.decode(bytes, b64);
                try out.appendSlice(a, bytes);
            }
            if (std.mem.indexOf(u8, out.items, needle) != null) return;
        }
        try std.Io.sleep(testing.io, .fromMilliseconds(25), .awake);
    }
    return error.TerminalOutputNeverArrived;
}

fn watching(f: *Fixture, sub_id: u64) bool {
    f.host.mutex.lockUncancelable(testing.io);
    defer f.host.mutex.unlock(testing.io);
    for (f.host.watches.items) |w| if (w.sub_id == sub_id) return true;
    return false;
}

fn base64Of(f: *Fixture, text: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try f.arena.allocator().alloc(u8, enc.calcSize(text.len));
    return enc.encode(out, text);
}

test "rpcg_terminals open, subscribe, write, resize, exit and close over RPC" {
    if (comptime !terms.supported) return;
    const f = try initFixture();
    defer f.deinit();
    _ = try f.addChat("chat-1", "dev-synthetic", null, f.t.repo);

    const opened = try f.ok("OpenTerminal", try f.params("{{\"chatId\":\"chat-1\",\"cols\":90,\"rows\":20}}", .{}));
    const id = opened.object.get("id").?.string;
    try testing.expectEqualStrings(f.t.repo, opened.object.get("cwd").?.string);
    try testing.expectEqualStrings("sh", opened.object.get("shell").?.string);

    var sub = try f.call(7, "SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id}));
    sub.stream_items_json.deinit(testing.allocator);
    try testing.expect(watching(f, 7));

    const cmd = try base64Of(f, "stty size; printf 'H%s\\n' \"ERE=$(pwd)\"\n");
    const written = try f.ok("WriteTerminal", try f.params("{{\"terminalId\":\"{s}\",\"data\":\"{s}\"}}", .{ id, cmd }));
    try testing.expect(written.object.get("ok").?.bool);
    try waitOutput(f, 7, "20 90");
    try waitOutput(f, 7, try std.fmt.allocPrint(f.arena.allocator(), "HERE={s}", .{f.t.repo}));

    _ = try f.ok("ResizeTerminal", try f.params("{{\"terminalId\":\"{s}\",\"cols\":132,\"rows\":43}}", .{id}));
    // Plain text is accepted too.
    _ = try f.ok("WriteTerminal", try f.params("{{\"terminalId\":\"{s}\",\"data\":\"stty size\\n\"}}", .{id}));
    try waitOutput(f, 7, "43 132");

    _ = try f.ok("WriteTerminal", try f.params("{{\"terminalId\":\"{s}\",\"data\":\"exit 5\\n\"}}", .{id}));
    const exit_item = try f.waitPushed(7, "\"type\":\"exit\"");
    try testing.expect(std.mem.indexOf(u8, exit_item, "\"exitCode\":5") != null);
    // The stream ended with the exit.
    try testing.expect(!watching(f, 7));
    try testing.expectEqualStrings("Terminal has exited", try f.err("WriteTerminal", try f.params("{{\"terminalId\":\"{s}\",\"data\":\"x\"}}", .{id})));

    // A returning viewer gets the replay after its seq, ending with the exit.
    const exit_seq = (try json.parseFromSliceLeaky(json.Value, f.arena.allocator(), exit_item, .{})).object.get("seq").?.integer;
    var again = try f.call(8, "SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\",\"afterSeq\":{d}}}", .{ id, exit_seq - 1 }));
    defer again.stream_items_json.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), again.stream_items_json.items.len);
    try testing.expect(std.mem.indexOf(u8, again.stream_items_json.items[0], "\"type\":\"exit\"") != null);
    try testing.expect(!watching(f, 8));

    const closed = try f.ok("CloseTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id}));
    try testing.expect(closed.object.get("ok").?.bool);
    try testing.expectEqualStrings("Terminal not found", try f.err("CloseTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id})));
    try testing.expectEqualStrings("Terminal not found", try f.err("SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id})));
}

test "rpcg_terminals close ends live streams and the shell" {
    if (comptime !terms.supported) return;
    const f = try initFixture();
    defer f.deinit();
    const opened = try f.ok("OpenTerminal", try f.params("{{\"chatId\":\"draft\",\"cwd\":\"{s}\",\"cols\":80,\"rows\":24}}", .{f.t.base}));
    const id = opened.object.get("id").?.string;
    try testing.expectEqualStrings(f.t.base, opened.object.get("cwd").?.string);
    var sub = try f.call(9, "SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id}));
    sub.stream_items_json.deinit(testing.allocator);
    const pid = blk: {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        break :blk f.host.terminals.sessions.get(id).?.live.pid;
    };
    _ = try f.ok("CloseTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id}));
    try testing.expect(!watching(f, 9));
    var waited: usize = 0;
    while (waited < 5_000 and std.c.kill(pid, @fromBackingInt(@intCast(0))) == 0) : (waited += 25) {
        try std.Io.sleep(testing.io, .fromMilliseconds(25), .awake);
    }
    try testing.expect(std.c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
}

test "rpcg_terminals folder resolution and request errors" {
    if (comptime !terms.supported) return;
    const f = try initFixture();
    defer f.deinit();
    try f.addSpace("space-1", "dev-synthetic", f.t.repo);
    // A new-chat canvas names its project in the key; "~" is only a fallback.
    const canvas = try f.ok("OpenTerminal", try f.params("{{\"chatId\":\"space-canvas:space-1\",\"cwd\":\"~\",\"cols\":80,\"rows\":24}}", .{}));
    try testing.expectEqualStrings(f.t.repo, canvas.object.get("cwd").?.string);
    _ = try f.ok("CloseTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{canvas.object.get("id").?.string}));
    const home = try f.ok("OpenTerminal", try f.params("{{\"chatId\":\"nowhere\",\"cols\":80,\"rows\":24}}", .{}));
    try testing.expectEqualStrings(f.t.base, home.object.get("cwd").?.string);
    _ = try f.ok("CloseTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{home.object.get("id").?.string}));

    try testing.expectEqualStrings("missing field `chatId`", try f.err("OpenTerminal", try f.params("{{\"cols\":80,\"rows\":24}}", .{})));
    try testing.expectEqualStrings("missing field `rows`", try f.err("OpenTerminal", try f.params("{{\"chatId\":\"c\",\"cols\":80}}", .{})));
    try testing.expectEqualStrings("invalid value: integer `70000`, expected u16", try f.err("OpenTerminal", try f.params("{{\"chatId\":\"c\",\"cols\":70000,\"rows\":24}}", .{})));
    try testing.expectEqualStrings("Session working directory is unavailable", try f.err("OpenTerminal", try f.params("{{\"chatId\":\"c\",\"cwd\":\"/nonexistent-synthetic\",\"cols\":80,\"rows\":24}}", .{})));
    try testing.expectEqualStrings("target device not connected", try f.err("OpenTerminal", try f.params("{{\"chatId\":\"c\",\"cols\":80,\"rows\":24,\"targetDeviceId\":\"dev-elsewhere\"}}", .{})));
    try testing.expectEqualStrings("missing field `data`", try f.err("WriteTerminal", try f.params("{{\"terminalId\":\"t\"}}", .{})));
    try testing.expectEqualStrings("Terminal not found", try f.err("WriteTerminal", try f.params("{{\"terminalId\":\"t\",\"data\":\"eA==\"}}", .{})));
    try testing.expectEqualStrings("missing field `cols`", try f.err("ResizeTerminal", try f.params("{{\"terminalId\":\"t\"}}", .{})));
    try testing.expectEqualStrings("Terminal not found", try f.err("ResizeTerminal", try f.params("{{\"terminalId\":\"t\",\"cols\":1,\"rows\":1}}", .{})));
    try testing.expectEqualStrings("missing field `terminalId`", try f.err("SubscribeTerminal", try f.params("{{}}", .{})));
    try testing.expectEqualStrings("missing field `terminalId`", try f.err("CloseTerminal", try f.params("{{}}", .{})));
}

fn addAction(f: *Fixture, space: []const u8, id: []const u8, command: []const u8, setup: bool) !void {
    const gpa = testing.allocator;
    try f.host.actions.append(gpa, .{
        .id = try gpa.dupe(u8, id),
        .space_id = try gpa.dupe(u8, space),
        .name = try gpa.dupe(u8, "Synthetic action"),
        .command = try gpa.dupe(u8, command),
        .icon = try gpa.dupe(u8, "play"),
        .run_on_worktree_create = setup,
    });
}

test "rpcg_terminals RunProjectAction checks ownership and runs the Action in a terminal" {
    if (comptime !terms.supported) return;
    const f = try initFixture();
    defer f.deinit();
    const repo = f.t.repo;
    try f.t.sh("cd repo && git worktree add -q ../wt -b wt-branch");
    const wt = try f.path("wt");
    try f.addSpace("space-1", "dev-synthetic", repo);
    try f.addSpace("space-2", "dev-synthetic", f.t.base);
    try f.addSpace("space-remote", "dev-elsewhere", repo);
    _ = try f.addChat("chat-wt", "dev-synthetic", "space-1", wt);
    _ = try f.addChat("chat-remote", "dev-elsewhere", "space-1", repo);
    _ = try f.addChat("chat-other", "dev-synthetic", "space-2", repo);
    _ = try f.addChat("chat-nocwd", "dev-synthetic", "space-1", null);
    _ = try f.addChat("chat-outside", "dev-synthetic", "space-1", f.t.base);
    // Actions are saved in the engine's persisted store (rpcw_actions.zig).
    try f.host.setDataDir(try f.path("data"));
    {
        const cmd = "printf 'ROOT=%s WT=%s\\n' \"$HARNESS_PROJECT_ROOT\" \"$HARNESS_WORKTREE_PATH\"; exit 4";
        _ = try f.ok("UpsertProjectAction", try f.params("{{\"spaceId\":\"space-1\",\"action\":{{\"name\":\"show\",\"command\":{f},\"icon\":\"play\"}}}}", .{std.json.fmt(cmd, .{})}));
    }

    const P = "{{\"spaceId\":\"{s}\",\"chatId\":\"{s}\",\"actionId\":\"{s}\",\"cols\":80,\"rows\":24}}";
    try testing.expectEqualStrings("Project space not found", try f.err("RunProjectAction", try f.params(P, .{ "nope", "chat-wt", "show" })));
    try testing.expectEqualStrings("Project space belongs to another device", try f.err("RunProjectAction", try f.params(P, .{ "space-remote", "chat-wt", "show" })));
    try testing.expectEqualStrings("Project chat not found", try f.err("RunProjectAction", try f.params(P, .{ "space-1", "nope", "show" })));
    try testing.expectEqualStrings("Project chat belongs to another device", try f.err("RunProjectAction", try f.params(P, .{ "space-1", "chat-remote", "show" })));
    try testing.expectEqualStrings("Project chat belongs to another space", try f.err("RunProjectAction", try f.params(P, .{ "space-1", "chat-other", "show" })));
    try testing.expectEqualStrings("Project chat has no checkout", try f.err("RunProjectAction", try f.params(P, .{ "space-1", "chat-nocwd", "show" })));
    try testing.expectEqualStrings("Project chat checkout is unavailable", try f.err("RunProjectAction", try f.params(P, .{ "space-1", "chat-outside", "show" })));
    try testing.expectEqualStrings("Project action not found", try f.err("RunProjectAction", try f.params(P, .{ "space-1", "chat-wt", "nope" })));
    try testing.expectEqualStrings("missing field `cols`", try f.err("RunProjectAction", try f.params("{{\"spaceId\":\"space-1\",\"chatId\":\"chat-wt\",\"actionId\":\"show\"}}", .{})));

    const run = try f.ok("RunProjectAction", try f.params(P, .{ "space-1", "chat-wt", "show" }));
    try testing.expectEqualStrings("show", run.object.get("actionId").?.string);
    try testing.expectEqualStrings("show", run.object.get("actionName").?.string);
    const term = run.object.get("terminal").?.object;
    const real_wt = common.canonicalize(f.arena.allocator(), testing.io, wt).?;
    const real_repo = common.canonicalize(f.arena.allocator(), testing.io, repo).?;
    try testing.expectEqualStrings(real_wt, term.get("cwd").?.string);
    var sub = try f.call(11, "SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{term.get("id").?.string}));
    sub.stream_items_json.deinit(testing.allocator);
    // Either already in the replay or still to come: wait on both.
    var waited: usize = 0;
    const want = try std.fmt.allocPrint(f.arena.allocator(), "ROOT={s} WT={s}", .{ real_repo, real_wt });
    while (waited < 15_000) : (waited += 50) {
        var r = try f.call(0, "SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{term.get("id").?.string}));
        defer r.stream_items_json.deinit(testing.allocator);
        var seen = false;
        var exited = false;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var out: std.ArrayList(u8) = .empty;
        for (r.stream_items_json.items) |it| {
            const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(), it, .{});
            if (std.mem.eql(u8, v.object.get("type").?.string, "exit")) {
                exited = true;
                try testing.expectEqual(@as(i64, 4), v.object.get("exitCode").?.integer);
                continue;
            }
            const d = v.object.get("data").?.string;
            const bytes = try arena.allocator().alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(d));
            try std.base64.standard.Decoder.decode(bytes, d);
            try out.appendSlice(arena.allocator(), bytes);
        }
        seen = std.mem.indexOf(u8, out.items, want) != null;
        if (seen and exited) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    } else return error.ActionNeverRan;
    _ = try f.ok("CloseTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{term.get("id").?.string}));
}

test "rpcg_terminals worktree setup Action runs in the worktree or reports why it couldn't" {
    if (comptime !terms.supported) return;
    const f = try initFixture();
    defer f.deinit();
    const rt = @import("rpcg_terminals.zig");
    try f.t.sh("cd repo && git worktree add -q ../setup-wt -b setup-branch");
    const wt = try f.path("setup-wt");
    const root = common.canonicalize(f.arena.allocator(), testing.io, f.t.repo).?;
    try addAction(f, "space-1", "setup", "printf 'SETUP ROOT=%s WT=%s\\n' \"$HARNESS_PROJECT_ROOT\" \"$HARNESS_WORKTREE_PATH\"", true);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        // No setup Action for another space: nothing is written.
        try rt.writeWorktreeSetup(&f.host, &aw.writer, "space-2", root, wt);
        try testing.expectEqual(@as(usize, 0), aw.written().len);
        try rt.writeWorktreeSetup(&f.host, &aw.writer, "space-1", root, wt);
    }
    const text = try f.arena.allocator().dupe(u8, aw.written());
    try testing.expect(std.mem.startsWith(u8, text, ",\"setupAction\":{\"actionId\":\"setup\""));
    const v = try json.parseFromSliceLeaky(json.Value, f.arena.allocator(), text["\"setupAction\":".len + 1 ..], .{});
    const id = v.object.get("terminal").?.object.get("id").?.string;
    var sub = try f.call(21, "SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id}));
    sub.stream_items_json.deinit(testing.allocator);
    const real_wt = common.canonicalize(f.arena.allocator(), testing.io, wt).?;
    // The shell may have printed before the subscription: ask again for the replay.
    var waited: usize = 0;
    const want = try std.fmt.allocPrint(f.arena.allocator(), "SETUP ROOT={s} WT={s}", .{ root, real_wt });
    while (waited < 15_000) : (waited += 50) {
        var r = try f.call(0, "SubscribeTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id}));
        defer r.stream_items_json.deinit(testing.allocator);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var out: std.ArrayList(u8) = .empty;
        for (r.stream_items_json.items) |it| {
            const e = try json.parseFromSliceLeaky(json.Value, arena.allocator(), it, .{});
            const d = e.object.get("data") orelse continue;
            const bytes = try arena.allocator().alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(d.string));
            try std.base64.standard.Decoder.decode(bytes, d.string);
            try out.appendSlice(arena.allocator(), bytes);
        }
        if (std.mem.indexOf(u8, out.items, want) != null) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    } else return error.SetupNeverRan;
    _ = try f.ok("CloseTerminal", try f.params("{{\"terminalId\":\"{s}\"}}", .{id}));

    // A shell that can't start: the reason is reported, nothing else.
    try f.t.env.map.put("SHELL", "/nonexistent/synthetic-shell");
    var failed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer failed.deinit();
    {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        try rt.writeWorktreeSetup(&f.host, &failed.writer, "space-1", root, wt);
    }
    try testing.expect(std.mem.startsWith(u8, failed.written(), ",\"setupError\":\"could not spawn synthetic-shell: "));
}
