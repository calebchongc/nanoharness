//! Engine-level tests for the git, history, checkout-diff and discard RPCs:
//! each method's success reply and its error replies, through
//! `EngineHost.handle` against temporary repositories. Calls take
//! `host.mutex` as the real dispatcher does, since the checkout watcher's
//! thread takes it too.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const common = @import("rpcw_common.zig");
const g = @import("rpcg_git.zig");
const watch = @import("rpcg_watch.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

pub const Fixture = struct {
    t: *g.TestRepo,
    host: EngineHost,
    arena: std.heap.ArenaAllocator,

    pub fn init() !*Fixture {
        const gpa = testing.allocator;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.t = try g.TestRepo.init();
        errdefer f.t.deinit();
        f.host = try EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = testing.io;
        f.arena = .init(gpa);
        return f;
    }

    pub fn deinit(f: *Fixture) void {
        f.host.deinit();
        f.arena.deinit();
        f.t.deinit();
        testing.allocator.destroy(f);
    }

    pub fn path(f: *Fixture, rel: []const u8) ![]const u8 {
        return std.fs.path.join(f.arena.allocator(), &.{ f.t.base, rel });
    }

    pub fn params(f: *Fixture, comptime fmt: []const u8, args: anytype) !json.Value {
        const text = try std.fmt.allocPrint(f.arena.allocator(), fmt, args);
        return json.parseFromSliceLeaky(json.Value, f.arena.allocator(), text, .{});
    }

    /// One RPC under the engine lock.
    pub fn call(f: *Fixture, id: u64, method: []const u8, p: json.Value) !RpcOutcome {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        return f.host.handleWithId(id, method, p);
    }

    /// A unary reply's JSON (kept in the fixture arena), or the test fails.
    pub fn ok(f: *Fixture, method: []const u8, p: json.Value) !json.Value {
        const out = try f.call(0, method, p);
        switch (out) {
            .unary_json => |body| {
                defer testing.allocator.free(body);
                return json.parseFromSliceLeaky(json.Value, f.arena.allocator(), try f.arena.allocator().dupe(u8, body), .{});
            },
            .err => |e| {
                std.debug.print("{s} failed: {any}\n", .{ method, e });
                return error.UnexpectedError;
            },
            .stream_items_json => |*s| {
                var st = s.*;
                st.deinit(testing.allocator);
                return error.UnexpectedStream;
            },
        }
    }

    /// An error reply's message (`exec_error` or `bad_params`).
    pub fn err(f: *Fixture, method: []const u8, p: json.Value) ![]const u8 {
        var out = try f.call(0, method, p);
        switch (out) {
            .err => |e| return switch (e) {
                .bad_params, .exec_error, .unknown_method => |m| try f.arena.allocator().dupe(u8, m),
            },
            .unary_json => |body| {
                std.debug.print("{s} unexpectedly succeeded: {s}\n", .{ method, body });
                testing.allocator.free(body);
                return error.ExpectedError;
            },
            .stream_items_json => |*s| {
                s.deinit(testing.allocator);
                return error.ExpectedError;
            },
        }
    }

    pub fn addSpace(f: *Fixture, id: []const u8, device: []const u8, space_path: []const u8) !void {
        const gpa = testing.allocator;
        try f.host.spaces.append(gpa, .{ .id = try gpa.dupe(u8, id), .device_id = try gpa.dupe(u8, device), .path = try gpa.dupe(u8, space_path), .name = try gpa.dupe(u8, "repo"), .git_detected = true });
    }

    pub fn addChat(f: *Fixture, id: []const u8, device: []const u8, space: ?[]const u8, cwd: ?[]const u8) !*engine_host.ChatRecord {
        const gpa = testing.allocator;
        try f.host.chats.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .space_id = if (space) |s| try gpa.dupe(u8, s) else null,
            .device_id = try gpa.dupe(u8, device),
            .harness = try gpa.dupe(u8, "mock"),
            .cwd = if (cwd) |c| try gpa.dupe(u8, c) else null,
        });
        return &f.host.chats.items[f.host.chats.items.len - 1];
    }

    /// Wait (with a deadline) for a pushed watch item for `sub_id` that
    /// contains `needle`; returns a copy.
    pub fn waitPushed(f: *Fixture, sub_id: u64, needle: []const u8) ![]const u8 {
        var waited: usize = 0;
        while (waited < 15_000) : (waited += 50) {
            {
                f.host.mutex.lockUncancelable(testing.io);
                defer f.host.mutex.unlock(testing.io);
                var i: usize = f.host.pushed_frames.items.len;
                while (i > 0) {
                    i -= 1;
                    const p = f.host.pushed_frames.items[i];
                    if (p.sub_id == sub_id and std.mem.indexOf(u8, p.item_json, needle) != null) {
                        return f.arena.allocator().dupe(u8, p.item_json);
                    }
                }
            }
            try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
        }
        return error.WatchItemNeverArrived;
    }

    pub fn clearPushed(f: *Fixture) void {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        for (f.host.pushed_frames.items) |*p| p.deinit(testing.allocator);
        f.host.pushed_frames.clearRetainingCapacity();
    }
};

fn firstItem(f: *Fixture, out: *RpcOutcome) ![]const u8 {
    defer out.stream_items_json.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.stream_items_json.items.len);
    return f.arena.allocator().dupe(u8, out.stream_items_json.items[0]);
}

test "rpcg_rpc branch, ref, history, search, switch and fetch replies" {
    if (comptime !std.process.can_spawn) return;
    const f = try Fixture.init();
    defer f.deinit();
    try f.t.sh("git clone -q --bare repo origin.git && cd repo && git remote add origin ../origin.git && git fetch -q origin && git branch topic && printf 'b\\n' >> a.txt && git commit -q -am 'second change'");
    const repo = f.t.repo;

    const branches = try f.ok("ListBranches", try f.params("{{\"repoPath\":\"{s}\"}}", .{repo}));
    try testing.expectEqualStrings("main", branches.array.items[0].string);
    try testing.expectEqualStrings("topic", branches.array.items[1].string);
    // `repo` is accepted as an alias.
    _ = try f.ok("ListBranches", try f.params("{{\"repo\":\"{s}\"}}", .{repo}));
    try testing.expectEqualStrings("missing field `repoPath`", try f.err("ListBranches", try f.params("{{}}", .{})));
    try testing.expect(std.mem.startsWith(u8, try f.err("ListBranches", try f.params("{{\"repoPath\":\"{s}\"}}", .{f.t.base})), "git: "));
    try testing.expectEqualStrings("target device not connected", try f.err("ListBranches", try f.params("{{\"repoPath\":\"{s}\",\"targetDeviceId\":\"dev-elsewhere\"}}", .{repo})));

    const refs = try f.ok("ListRefs", try f.params("{{\"repoPath\":\"{s}\"}}", .{repo}));
    try testing.expect(refs.array.items[0].object.get("current").?.bool);
    try testing.expectEqualStrings("missing field `repoPath`", try f.err("ListRefs", try f.params("{{\"cwd\":\"{s}\"}}", .{repo})));

    const page = try f.ok("ListGitHistory", try f.params("{{\"cwd\":\"{s}\",\"limit\":1}}", .{repo}));
    try testing.expectEqualStrings("second change", page.object.get("commits").?.array.items[0].object.get("subject").?.string);
    try testing.expectEqual(@as(i64, 1), page.object.get("nextCursor").?.integer);
    try testing.expectEqualStrings("origin/main", page.object.get("comparison").?.object.get("base").?.string);
    try testing.expectEqual(@as(i64, 1), page.object.get("comparison").?.object.get("ahead").?.integer);
    try testing.expectEqualStrings("missing field `cwd`", try f.err("ListGitHistory", try f.params("{{}}", .{})));
    try testing.expect(std.mem.startsWith(u8, try f.err("ListGitHistory", try f.params("{{\"cwd\":\"{s}\",\"cursor\":-1}}", .{repo})), "invalid value"));

    const found = try f.ok("SearchGitHistory", try f.params("{{\"cwd\":\"{s}\",\"query\":\"second\"}}", .{repo}));
    try testing.expectEqual(@as(i64, 1), found.object.get("totalCount").?.integer);
    try testing.expectEqualStrings("missing field `query`", try f.err("SearchGitHistory", try f.params("{{\"cwd\":\"{s}\"}}", .{repo})));

    const switched = try f.ok("SwitchRef", try f.params("{{\"repoPath\":\"{s}\",\"refName\":\"topic\"}}", .{repo}));
    try testing.expectEqualStrings("topic", switched.object.get("branch").?.string);
    try testing.expectEqualStrings("missing field `refName`", try f.err("SwitchRef", try f.params("{{\"repoPath\":\"{s}\"}}", .{repo})));
    try f.t.sh("cd repo && printf 'dirty\\n' >> a.txt");
    // A dirty tree that conflicts: git's own refusal comes back.
    try testing.expect(std.mem.startsWith(u8, try f.err("SwitchRef", try f.params("{{\"repoPath\":\"{s}\",\"refName\":\"main\"}}", .{repo})), "git: "));

    const fetched = try f.ok("FetchAll", try f.params("{{\"repoPath\":\"{s}\"}}", .{repo}));
    try testing.expect(fetched.object.get("ok").?.bool);
    try testing.expect(std.mem.startsWith(u8, try f.err("FetchAll", try f.params("{{\"repoPath\":\"{s}\"}}", .{f.t.base})), "git: "));
}

test "rpcg_rpc GetCheckoutDiff scopes and GetCheckoutFileDiffText" {
    if (comptime !std.process.can_spawn) return;
    const f = try Fixture.init();
    defer f.deinit();
    const repo = f.t.repo;
    try f.t.sh("cd repo && git checkout -q -b feature && printf 'two\\n' >> a.txt && git commit -q -am feature && printf 'three\\n' >> a.txt && printf 'new\\n' > b.txt");

    const working = try f.ok("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"workingTree\"}}", .{repo}));
    const o = working.object;
    try testing.expectEqualStrings("dev-synthetic", o.get("deviceId").?.string);
    try testing.expectEqual(@as(usize, 64), o.get("checkoutId").?.string.len);
    try testing.expectEqual(@as(usize, 2), o.get("files").?.array.items.len);
    try testing.expectEqual(@as(i64, 2), o.get("additions").?.integer);
    try testing.expect(!o.get("truncated").?.bool);
    try testing.expect(std.mem.endsWith(u8, o.get("cwd").?.string, "/repo"));

    const branch = try f.ok("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"branch\",\"baseRef\":\"main\"}}", .{repo}));
    try testing.expectEqual(@as(i64, 3), branch.object.get("additions").?.integer);
    try testing.expectEqualStrings("baseRef required", try f.err("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"branch\"}}", .{repo})));
    try testing.expect(std.mem.startsWith(u8, try f.err("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"branch\",\"baseRef\":\"nope\"}}", .{repo})), "git: "));

    const head = try f.ok("ListGitHistory", try f.params("{{\"cwd\":\"{s}\",\"limit\":1}}", .{repo}));
    const sha = head.object.get("headSha").?.string;
    const commit = try f.ok("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"commit\",\"commitSha\":\"{s}\"}}", .{ repo, sha }));
    try testing.expectEqual(@as(i64, 1), commit.object.get("additions").?.integer);
    try testing.expectEqualStrings("commitSha required", try f.err("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"commit\"}}", .{repo})));
    try testing.expectEqualStrings("chatId required", try f.err("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"turn\"}}", .{repo})));
    try testing.expectEqualStrings("no turn recorded", try f.err("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"turn\",\"chatId\":\"chat-1\"}}", .{repo})));
    try testing.expectEqualStrings("missing field `cwd`", try f.err("GetCheckoutDiff", try f.params("{{\"mode\":\"workingTree\"}}", .{})));
    try testing.expect(std.mem.startsWith(u8, try f.err("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\"}}", .{f.t.base})), "git: "));

    // A recorded turn start gives "Latest turn" its base.
    {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        try watch.noteTurnStart(&f.host, "chat-1", repo);
    }
    var waited: usize = 0;
    while (waited < 15_000) : (waited += 50) {
        f.host.mutex.lockUncancelable(testing.io);
        const tree = try watch.turnTree(&f.host, testing.allocator, "chat-1", (try g.checkoutIdentity(f.arena.allocator(), testing.io, "dev-synthetic", repo)).ok.root);
        f.host.mutex.unlock(testing.io);
        if (tree) |t| {
            testing.allocator.free(t);
            break;
        }
        try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    }
    try f.t.sh("cd repo && printf 'turn\\n' > c.txt");
    const turn = try f.ok("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\",\"mode\":\"turn\",\"chatId\":\"chat-1\"}}", .{repo}));
    try testing.expectEqual(@as(usize, 1), turn.object.get("files").?.array.items.len);
    try testing.expectEqualStrings("c.txt", turn.object.get("files").?.array.items[0].object.get("path").?.string);

    // One file's text, pinned to the checksum the client holds.
    const now = try f.ok("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\"}}", .{repo}));
    const id = now.object.get("checkoutId").?.string;
    const sum = now.object.get("checksum").?.string;
    const text = try f.ok("GetCheckoutFileDiffText", try f.params("{{\"checkoutId\":\"{s}\",\"cwd\":\"{s}\",\"path\":\"a.txt\",\"diffChecksum\":\"{s}\"}}", .{ id, repo, sum }));
    try testing.expectEqualStrings("one\ntwo\n", text.object.get("oldText").?.string);
    try testing.expectEqualStrings("one\ntwo\nthree\n", text.object.get("newText").?.string);
    try testing.expectEqual(@as(usize, 64), text.object.get("newContentHash").?.string.len);
    try testing.expect(!text.object.get("stale").?.bool);
    const added = try f.ok("GetCheckoutFileDiffText", try f.params("{{\"checkoutId\":\"{s}\",\"cwd\":\"{s}\",\"path\":\"b.txt\",\"diffChecksum\":\"{s}\"}}", .{ id, repo, sum }));
    try testing.expect(added.object.get("oldText") == null);
    try testing.expectEqualStrings("new\n", added.object.get("newText").?.string);
    const stale = try f.ok("GetCheckoutFileDiffText", try f.params("{{\"checkoutId\":\"{s}\",\"cwd\":\"{s}\",\"path\":\"a.txt\",\"diffChecksum\":\"old\"}}", .{ id, repo }));
    try testing.expect(stale.object.get("stale").?.bool);
    try testing.expect(stale.object.get("newText") == null);
    const branch_sum = branch.object.get("checksum").?.string;
    _ = branch_sum;
    try testing.expectEqualStrings("checkoutId does not match cwd", try f.err("GetCheckoutFileDiffText", try f.params("{{\"checkoutId\":\"x\",\"cwd\":\"{s}\",\"path\":\"a.txt\",\"diffChecksum\":\"{s}\"}}", .{ repo, sum })));
    try testing.expectEqualStrings("path is not part of diff snapshot", try f.err("GetCheckoutFileDiffText", try f.params("{{\"checkoutId\":\"{s}\",\"cwd\":\"{s}\",\"path\":\"zzz\",\"diffChecksum\":\"{s}\"}}", .{ id, repo, sum })));
    try testing.expectEqualStrings("missing field `diffChecksum`", try f.err("GetCheckoutFileDiffText", try f.params("{{\"checkoutId\":\"{s}\",\"cwd\":\"{s}\",\"path\":\"a.txt\"}}", .{ id, repo })));
}

test "rpcg_rpc DiscardWorkingTree safety checks and success" {
    if (comptime !std.process.can_spawn) return;
    const f = try Fixture.init();
    defer f.deinit();
    const repo = f.t.repo;
    try f.t.sh("cd repo && printf 'changed\\n' > a.txt && mkdir -p d/e && printf 'u\\n' > d/e/u.txt");
    const before = try f.ok("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\"}}", .{repo}));
    const id = before.object.get("checkoutId").?.string;
    const sum = before.object.get("checksum").?.string;

    try testing.expectEqualStrings("chat not found", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-x\",\"checkoutId\":\"{s}\",\"expectedChecksum\":\"{s}\"}}", .{ id, sum })));
    _ = try f.addChat("chat-remote", "dev-elsewhere", null, repo);
    try testing.expectEqualStrings("chat is not hosted by this device", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-remote\",\"checkoutId\":\"{s}\",\"expectedChecksum\":\"{s}\"}}", .{ id, sum })));
    _ = try f.addChat("chat-nowhere", "dev-synthetic", null, null);
    try testing.expectEqualStrings("chat has no checkout", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-nowhere\",\"checkoutId\":\"{s}\",\"expectedChecksum\":\"{s}\"}}", .{ id, sum })));
    const chat = try f.addChat("chat-1", "dev-synthetic", null, repo);
    try testing.expectEqualStrings("chat checkout changed since the confirmation was opened", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-1\",\"checkoutId\":\"other\",\"expectedChecksum\":\"{s}\"}}", .{sum})));
    try testing.expectEqualStrings("missing field `expectedChecksum`", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-1\",\"checkoutId\":\"{s}\"}}", .{id})));

    chat.activity_status = try testing.allocator.dupe(u8, "working");
    try testing.expectEqualStrings("an agent is active in this working tree", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-1\",\"checkoutId\":\"{s}\",\"expectedChecksum\":\"{s}\"}}", .{ id, sum })));
    testing.allocator.free(chat.activity_status.?);
    chat.activity_status = null;
    chat.archived = true;
    try testing.expectEqualStrings("checkout is no longer available", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-1\",\"checkoutId\":\"{s}\",\"expectedChecksum\":\"{s}\"}}", .{ id, sum })));
    chat.archived = false;
    try testing.expectEqualStrings("working tree changed since the confirmation was opened", try f.err("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-1\",\"checkoutId\":\"{s}\",\"expectedChecksum\":\"stale\"}}", .{id})));

    const done = try f.ok("DiscardWorkingTree", try f.params("{{\"chatId\":\"chat-1\",\"checkoutId\":\"{s}\",\"expectedChecksum\":\"{s}\"}}", .{ id, sum }));
    try testing.expect(done.object.get("ok").?.bool);
    const after = try f.ok("GetCheckoutDiff", try f.params("{{\"cwd\":\"{s}\"}}", .{repo}));
    try testing.expectEqualStrings(done.object.get("checksum").?.string, after.object.get("checksum").?.string);
    try testing.expectEqual(@as(usize, 0), after.object.get("files").?.array.items.len);
    try testing.expect(!common.pathExists(testing.io, try f.path("repo/d")));
}

test "rpcg_rpc WatchCheckoutDiffs and WatchWorkspaceGitStatus publish changes" {
    if (comptime !std.process.can_spawn) return;
    const f = try Fixture.init();
    defer f.deinit();
    const repo = f.t.repo;
    try f.addSpace("space-1", "dev-synthetic", repo);
    try f.addSpace("space-remote", "dev-elsewhere", repo);
    _ = try f.addChat("chat-1", "dev-synthetic", "space-1", repo);

    // Target errors first (no watcher needed).
    try testing.expectEqualStrings("workspace target needs exactly one of chatId or spaceId", try f.err("WatchWorkspaceGitStatus", try f.params("{{}}", .{})));
    try testing.expectEqualStrings("checkoutPath applies only to a space target", try f.err("WatchWorkspaceGitStatus", try f.params("{{\"chatId\":\"chat-1\",\"checkoutPath\":\"{s}\"}}", .{repo})));
    try testing.expectEqualStrings("chat not found", try f.err("WatchWorkspaceGitStatus", try f.params("{{\"chatId\":\"nope\"}}", .{})));
    try testing.expectEqualStrings("space not found", try f.err("WatchWorkspaceGitStatus", try f.params("{{\"spaceId\":\"nope\"}}", .{})));
    try testing.expectEqualStrings("space belongs to another device", try f.err("WatchWorkspaceGitStatus", try f.params("{{\"spaceId\":\"space-remote\"}}", .{})));
    try testing.expectEqualStrings("checkoutPath is not a workspace checkout", try f.err("WatchWorkspaceGitStatus", try f.params("{{\"spaceId\":\"space-1\",\"checkoutPath\":\"{s}\"}}", .{f.t.base})));

    var diffs = try f.call(41, "WatchCheckoutDiffs", try f.params("{{}}", .{}));
    const first = try firstItem(f, &diffs);
    try testing.expect(first[0] == '[');
    var status = try f.call(42, "WatchWorkspaceGitStatus", try f.params("{{\"spaceId\":\"space-1\",\"checkoutPath\":\"{s}\"}}", .{repo}));
    _ = try firstItem(f, &status);

    // The worker captures the chat's checkout and publishes both.
    const clean = try f.waitPushed(41, "\"checkoutId\"");
    try testing.expect(std.mem.indexOf(u8, clean, "\"files\":[]") != null);
    const clean_status = try f.waitPushed(42, "\"complete\":true");
    try testing.expect(std.mem.indexOf(u8, clean_status, "\"files\":[]") != null);

    f.clearPushed();
    try f.t.sh("cd repo && printf 'edit\\n' >> a.txt");
    {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        watch.kick(&f.host);
    }
    const edited = try f.waitPushed(41, "\"path\":\"a.txt\"");
    try testing.expect(std.mem.indexOf(u8, edited, "\"additions\":1") != null);
    const edited_status = try f.waitPushed(42, "\"worktree\":\"modified\"");
    try testing.expect(std.mem.indexOf(u8, edited_status, "\"index\":\"unchanged\"") != null);

    // A later subscriber starts from the cached state.
    var late = try f.call(43, "WatchWorkspaceGitStatus", try f.params("{{\"chatId\":\"chat-1\"}}", .{}));
    try testing.expect(std.mem.indexOf(u8, try firstItem(f, &late), "\"worktree\":\"modified\"") != null);
    var late_diffs = try f.call(44, "WatchCheckoutDiffs", try f.params("{{}}", .{}));
    try testing.expect(std.mem.indexOf(u8, try firstItem(f, &late_diffs), "a.txt") != null);

    try testing.expectEqualStrings("target device not connected", try f.err("WatchCheckoutDiffs", try f.params("{{\"targetDeviceId\":\"dev-elsewhere\"}}", .{})));
    for ([_]u64{ 41, 42, 43, 44 }) |id| {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        f.host.cancelWatch(id);
    }
}
