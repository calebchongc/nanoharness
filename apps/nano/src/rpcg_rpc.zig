//! RPC handlers for the git, branch, history, checkout-diff and discard
//! methods, matching `crates/engine/src/rpc.rs`: same request fields (serde
//! names and aliases), reply shapes and error texts. `engine_host.zig` calls
//! these from the method switch; each runs under `host.mutex` like every RPC.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const common = @import("rpcw_common.zig");
const g = @import("rpcg_git.zig");
const d = @import("rpcg_diff.zig");
const watch = @import("rpcg_watch.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

// ── params ─────────────────────────────────────────────────────────────────

pub const Str = union(enum) { ok: []const u8, missing, wrong };

/// A required string field (serde: `missing field` / `invalid type`).
pub fn reqStr(o: json.ObjectMap, key: []const u8, alias: ?[]const u8) Str {
    const v = o.get(key) orelse (if (alias) |a| o.get(a) else null) orelse return .missing;
    return if (v == .string) .{ .ok = v.string } else .wrong;
}

/// An `Option<String>` with `#[serde(default)]`: absent or null is None.
pub fn optStr(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn strOrFail(o: json.ObjectMap, key: []const u8, alias: ?[]const u8) union(enum) { ok: []const u8, err: RpcOutcome } {
    return switch (reqStr(o, key, alias)) {
        .ok => |s| .{ .ok = s },
        .missing => .{ .err = common.badParams("missing field `{s}`", .{key}) },
        .wrong => .{ .err = common.badParams("invalid type: expected a string for `{s}`", .{key}) },
    };
}

/// A `usize` with a default.
fn usizeField(o: json.ObjectMap, key: []const u8, default: usize) union(enum) { ok: usize, err: RpcOutcome } {
    const v = o.get(key) orelse return .{ .ok = default };
    return switch (v) {
        .integer => |n| if (n >= 0) .{ .ok = @intCast(n) } else .{ .err = common.badParams("invalid value: integer `{d}`, expected usize", .{n}) },
        .null => .{ .err = common.badParams("invalid type: null, expected usize", .{}) },
        else => .{ .err = common.badParams("invalid type: expected usize for `{s}`", .{key}) },
    };
}

/// Calls aimed at another device are not served here.
pub fn targetProblem(params: json.Value, local_device: []const u8) ?RpcOutcome {
    if (params != .object) return null;
    const t = params.object.get("targetDeviceId") orelse return null;
    if (t == .null) return null;
    if (t != .string) return common.badParams("invalid type for `targetDeviceId`, expected a string", .{});
    if (std.mem.eql(u8, t.string, local_device)) return null;
    return common.failedMsg("target device not connected");
}

fn object(params: json.Value, comptime name: []const u8) union(enum) { ok: json.ObjectMap, err: RpcOutcome } {
    if (params == .object) return .{ .ok = params.object };
    return .{ .err = common.badParams("invalid type: expected struct " ++ name, .{}) };
}

fn noIo() RpcOutcome {
    return common.failedMsg("git spawn failed: no I/O");
}

fn fromResult(gpa: Allocator, r: g.Result([]u8)) RpcOutcome {
    _ = gpa;
    return switch (r) {
        .ok => |body| .{ .unary_json = body },
        .failed => |m| common.failedMsg(m),
    };
}

pub fn stream(gpa: Allocator, items: []const []u8) !RpcOutcome {
    const list = try gpa.alloc([]u8, items.len);
    @memcpy(list, items);
    return .{ .stream_items_json = .{ .checked = false, .items = list } };
}

// ── branches, refs, history ────────────────────────────────────────────────

/// `ListBranches { repoPath | repo }` → `string[]`, default branch first.
pub fn listBranches(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "RepoPathParams")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const repo = switch (strOrFail(o, "repoPath", "repo")) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const io = host.io orelse return noIo();
    return fromResult(host.gpa, try g.branchesJson(host.gpa, io, repo));
}

/// `ListRefs { repoPath | repo }` → `RepoRef[]`.
pub fn listRefs(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "RepoPathParams")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const repo = switch (strOrFail(o, "repoPath", "repo")) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const io = host.io orelse return noIo();
    return fromResult(host.gpa, try g.refsJson(host.gpa, io, repo));
}

/// `ListGitHistory { cwd, cursor?, limit? }` → `GitHistoryPage`.
pub fn listGitHistory(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "P")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const cwd = switch (strOrFail(o, "cwd", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const cursor = switch (usizeField(o, "cursor", 0)) {
        .ok => |n| n,
        .err => |e| return e,
    };
    const limit = switch (usizeField(o, "limit", g.history_default_limit)) {
        .ok => |n| n,
        .err => |e| return e,
    };
    const io = host.io orelse return noIo();
    return fromResult(host.gpa, try g.historyJson(host.gpa, io, cwd, cursor, limit));
}

/// `SearchGitHistory { cwd, query, cursor?, limit? }` → `GitHistoryPage`.
pub fn searchGitHistory(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "P")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const cwd = switch (strOrFail(o, "cwd", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const query = switch (strOrFail(o, "query", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const cursor = switch (usizeField(o, "cursor", 0)) {
        .ok => |n| n,
        .err => |e| return e,
    };
    const limit = switch (usizeField(o, "limit", g.history_default_limit)) {
        .ok => |n| n,
        .err => |e| return e,
    };
    const io = host.io orelse return noIo();
    return fromResult(host.gpa, try g.searchHistoryJson(host.gpa, io, cwd, query, cursor, limit));
}

/// `FetchAll { repoPath | repo }` → `{ok:true}`; then every watched checkout
/// re-publishes (remote refs are repository state too).
pub fn fetchAll(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "RepoPathParams")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const repo = switch (strOrFail(o, "repoPath", "repo")) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const io = host.io orelse return noIo();
    switch (try g.fetchAll(host.gpa, io, repo)) {
        .failed => |m| return common.failedMsg(m),
        .ok => {},
    }
    watch.kick(host);
    return .{ .unary_json = try host.gpa.dupe(u8, "{\"ok\":true}") };
}

/// `SwitchRef { repoPath, refName }` → `{branch}`.
pub fn switchRef(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "SwitchRefParams")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const repo = switch (strOrFail(o, "repoPath", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const ref_name = switch (strOrFail(o, "refName", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const io = host.io orelse return noIo();
    const branch = switch (try g.switchRef(host.gpa, io, repo, ref_name)) {
        .ok => |b| b,
        .failed => |m| return common.failedMsg(m),
    };
    defer host.gpa.free(branch);
    watch.kick(host);
    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"branch\":");
    try g.writeJsonString(&aw.writer, branch);
    try aw.writer.writeByte('}');
    return .{ .unary_json = try aw.toOwnedSlice() };
}

// ── checkout diffs ─────────────────────────────────────────────────────────

const Scoped = struct {
    snap: d.Snapshot,
    /// The diff's old side for `GetCheckoutFileDiffText` (owned).
    base: []u8,
    /// The committed new side (`commit` mode), else the live working tree.
    target: ?[]const u8,
};

/// The four Changes-pane scopes: `branch` (against merge-base(baseRef, HEAD)),
/// `commit` (one commit's own changes), `turn` (since the chat's turn began),
/// anything else the working tree.
fn captureScoped(host: *EngineHost, io: std.Io, root: []const u8, mode: []const u8, o: json.ObjectMap, base_hint: ?[]const u8) !g.Result(Scoped) {
    const gpa = host.gpa;
    if (std.mem.eql(u8, mode, "branch")) {
        const base: []u8 = if (base_hint) |b| try gpa.dupe(u8, b) else blk: {
            const base_ref = optStr(o, "baseRef") orelse return .{ .failed = "baseRef required" };
            break :blk switch (try d.mergeBase(gpa, io, root, base_ref)) {
                .ok => |sha| sha,
                .failed => |m| return .{ .failed = m },
            };
        };
        errdefer gpa.free(base);
        return switch (try d.captureDiffAgainst(gpa, io, root, base, .{})) {
            .ok => |s| .{ .ok = .{ .snap = s, .base = base, .target = null } },
            .failed => |m| blk: {
                gpa.free(base);
                break :blk .{ .failed = m };
            },
        };
    }
    if (std.mem.eql(u8, mode, "commit")) {
        const sha = optStr(o, "commitSha") orelse return .{ .failed = "commitSha required" };
        const base = try d.commitDiffBase(gpa, io, root, sha);
        errdefer gpa.free(base);
        return switch (try d.captureCommitDiff(gpa, io, root, sha)) {
            .ok => |s| .{ .ok = .{ .snap = s, .base = base, .target = sha } },
            .failed => |m| blk: {
                gpa.free(base);
                break :blk .{ .failed = m };
            },
        };
    }
    if (std.mem.eql(u8, mode, "turn")) {
        const chat_id = optStr(o, "chatId") orelse return .{ .failed = "chatId required" };
        const tree = (try watch.turnTree(host, gpa, chat_id, root)) orelse return .{ .failed = "no turn recorded" };
        errdefer gpa.free(tree);
        return switch (try d.captureTurnDiff(gpa, io, root, tree)) {
            .ok => |s| .{ .ok = .{ .snap = s, .base = tree, .target = null } },
            .failed => |m| blk: {
                gpa.free(tree);
                break :blk .{ .failed = m };
            },
        };
    }
    const base = try d.workingDiffBase(gpa, io, root);
    errdefer gpa.free(base);
    return switch (try d.captureDiff(gpa, io, root, .{})) {
        .ok => |s| .{ .ok = .{ .snap = s, .base = base, .target = null } },
        .failed => |m| blk: {
            gpa.free(base);
            break :blk .{ .failed = m };
        },
    };
}

/// `GetCheckoutDiff { cwd, mode?, baseRef?, chatId?, commitSha? }` → `CheckoutDiff`.
pub fn getCheckoutDiff(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "P")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const cwd = switch (strOrFail(o, "cwd", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const mode = optStr(o, "mode") orelse "";
    const io = host.io orelse return noIo();
    const gpa = host.gpa;
    const ident = switch (try g.checkoutIdentity(gpa, io, host.device_id, cwd)) {
        .ok => |i| i,
        .failed => |m| return common.failedMsg(m),
    };
    defer ident.deinit(gpa);
    var scoped = switch (try captureScoped(host, io, ident.root, mode, o, null)) {
        .ok => |s| s,
        .failed => |m| return common.failedMsg(m),
    };
    defer scoped.snap.deinit();
    defer gpa.free(scoped.base);
    var ts: [32]u8 = undefined;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try d.writeCheckoutDiff(&aw.writer, ident.id, host.device_id, ident.root, &scoped.snap, @import("auth_host.zig").formatRfc3339Ms(&ts, host.nowMs()));
    return .{ .unary_json = try aw.toOwnedSlice() };
}

fn staleText(gpa: Allocator, checksum: []const u8) !RpcOutcome {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"diffChecksum\":");
    try g.writeJsonString(&aw.writer, checksum);
    try aw.writer.writeAll(",\"binary\":false,\"truncated\":false,\"stale\":true}");
    return .{ .unary_json = try aw.toOwnedSlice() };
}

/// `GetCheckoutFileDiffText`: one file's exact old/new text from the snapshot
/// the client holds (`diffChecksum`), or `stale: true` when the checkout moved
/// on before or while it was read.
pub fn getCheckoutFileDiffText(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "GetCheckoutFileDiffTextRequest")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const checkout_id = switch (strOrFail(o, "checkoutId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const cwd = switch (strOrFail(o, "cwd", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const path = switch (strOrFail(o, "path", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const checksum = switch (strOrFail(o, "diffChecksum", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const mode = optStr(o, "mode") orelse "";
    const io = host.io orelse return noIo();
    const gpa = host.gpa;
    const ident = switch (try g.checkoutIdentity(gpa, io, host.device_id, cwd)) {
        .ok => |i| i,
        .failed => |m| return common.failedMsg(m),
    };
    defer ident.deinit(gpa);
    if (!std.mem.eql(u8, ident.id, checkout_id)) return common.failedMsg("checkoutId does not match cwd");
    var scoped = switch (try captureScoped(host, io, ident.root, mode, o, null)) {
        .ok => |s| s,
        .failed => |m| return common.failedMsg(m),
    };
    defer scoped.snap.deinit();
    defer gpa.free(scoped.base);
    if (!std.mem.eql(u8, &scoped.snap.checksum, checksum)) return staleText(gpa, checksum);
    const file = for (scoped.snap.files) |f| {
        if (std.mem.eql(u8, f.path, path)) break f;
    } else return common.failedMsg("path is not part of diff snapshot");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const pair = switch (try d.readDiffFileTextAt(arena_state.allocator(), io, ident.root, scoped.base, scoped.target, file)) {
        .ok => |p| p,
        .failed => |m| return common.failedMsg(m),
    };
    // Close the filesystem race: the pair must still belong to that snapshot.
    // `branch` and `turn` recheck against the same base they read from.
    var current = switch (try captureScoped(host, io, ident.root, mode, o, if (std.mem.eql(u8, mode, "branch") or std.mem.eql(u8, mode, "turn")) scoped.base else null)) {
        .ok => |s| s,
        .failed => |m| return common.failedMsg(m),
    };
    defer current.snap.deinit();
    defer gpa.free(current.base);
    if (!std.mem.eql(u8, &current.snap.checksum, checksum)) return staleText(gpa, checksum);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"diffChecksum\":");
    try g.writeJsonString(w, checksum);
    if (pair.old_text) |t| {
        try w.writeAll(",\"oldText\":");
        try g.writeJsonString(w, t);
    }
    if (pair.new_text) |t| {
        try w.writeAll(",\"newText\":");
        try g.writeJsonString(w, t);
    }
    if (pair.old_hash) |h| try g.field(w, true, "oldContentHash", &h);
    if (pair.new_hash) |h| try g.field(w, true, "newContentHash", &h);
    try w.print(",\"binary\":{},\"truncated\":{},\"stale\":false}}", .{ pair.binary, pair.truncated });
    return .{ .unary_json = try aw.toOwnedSlice() };
}

fn findChat(host: *EngineHost, id: []const u8) ?*engine_host.ChatRecord {
    for (host.chats.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

fn findSpace(host: *EngineHost, id: []const u8) ?*engine_host.SpaceRecord {
    for (host.spaces.items) |*s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

fn agentActive(c: engine_host.ChatRecord) bool {
    const st = c.activity_status orelse return false;
    return std.mem.eql(u8, st, "working") or std.mem.eql(u8, st, "awaitingInput") or std.mem.eql(u8, st, "awaiting_input");
}

/// `DiscardWorkingTree { chatId, checkoutId, expectedChecksum }` → `{ok, checksum}`.
/// Refused unless the chat is this device's, its checkout is still the one
/// the confirmation named, no local agent is running in it, and the tree is
/// exactly the snapshot the user saw.
pub fn discardWorkingTree(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "DiscardWorkingTreeParams")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const chat_id = switch (strOrFail(o, "chatId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const checkout_id = switch (strOrFail(o, "checkoutId", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const expected = switch (strOrFail(o, "expectedChecksum", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const gpa = host.gpa;
    const chat = findChat(host, chat_id) orelse return common.failedMsg("chat not found");
    if (!std.mem.eql(u8, chat.device_id, host.device_id)) return common.failedMsg("chat is not hosted by this device");
    const cwd = chat.cwd orelse return common.failedMsg("chat has no checkout");
    const io = host.io orelse return noIo();
    const ident = switch (try g.checkoutIdentity(gpa, io, host.device_id, cwd)) {
        .ok => |i| i,
        .failed => |m| return common.failedMsg(m),
    };
    defer ident.deinit(gpa);
    if (!std.mem.eql(u8, ident.id, checkout_id)) return common.failedMsg("chat checkout changed since the confirmation was opened");

    // Never interrupt an agent as a side effect of discarding its files; a
    // checkout no live chat names is not tracked any more.
    var tracked = false;
    for (host.chats.items) |c| {
        if (!std.mem.eql(u8, c.device_id, host.device_id)) continue;
        const ccwd = c.cwd orelse continue;
        const same = std.mem.eql(u8, ccwd, cwd) or blk: {
            const other = switch (try g.checkoutIdentity(gpa, io, host.device_id, ccwd)) {
                .ok => |i| i,
                .failed => break :blk false,
            };
            defer other.deinit(gpa);
            break :blk std.mem.eql(u8, other.id, ident.id);
        };
        if (!same) continue;
        if (!c.archived) tracked = true;
        if (agentActive(c)) return common.failedMsg("an agent is active in this working tree");
    }
    if (!tracked) return common.failedMsg("checkout is no longer available");

    var final = switch (try d.discardWorkingTree(gpa, io, ident.root, expected)) {
        .ok => |s| s,
        .failed => |m| {
            watch.kick(host);
            return common.failedMsg(m);
        },
    };
    defer final.deinit();
    try watch.publishSnapshot(host, ident.id, ident.root, &final);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"ok\":true,\"checksum\":");
    try g.writeJsonString(&aw.writer, &final.checksum);
    try aw.writer.writeByte('}');
    return .{ .unary_json = try aw.toOwnedSlice() };
}

// ── watches ────────────────────────────────────────────────────────────────

/// `WatchCheckoutDiffs` → stream of `CheckoutDiff[]`: the latest list now,
/// then a new list whenever a tracked checkout's diff changes.
pub fn watchCheckoutDiffs(host: *EngineHost, call_id: u64, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const st = try watch.ensure(host);
    if (call_id != 0) try host.registerWatch(call_id, watch.watch_kind, watch.diffs_target);
    const first = if (st) |s| try watch.diffsJson(s, host.gpa) else try host.gpa.dupe(u8, "[]");
    errdefer host.gpa.free(first);
    return stream(host.gpa, &.{first});
}

pub const ResolvedWorkspace = struct { checkout_id: []u8, root: []u8 };

/// `WorkspaceFiles::resolve_target`: exactly one of `chatId` / `spaceId`
/// (plus an optional `checkoutPath` for a space), authorized against this
/// device's records before git runs in it. Plain folders get a stable key.
pub fn resolveTarget(host: *EngineHost, io: std.Io, o: json.ObjectMap) !union(enum) { ok: ResolvedWorkspace, err: RpcOutcome } {
    const gpa = host.gpa;
    const chat_id = optStr(o, "chatId");
    const space_id = optStr(o, "spaceId");
    if ((chat_id == null) == (space_id == null)) return .{ .err = common.badParams("workspace target needs exactly one of chatId or spaceId", .{}) };
    var root: []u8 = undefined;
    if (chat_id) |cid| {
        if (optStr(o, "checkoutPath") != null) return .{ .err = common.badParams("checkoutPath applies only to a space target", .{}) };
        const chat = findChat(host, cid) orelse return .{ .err = common.failedMsg("chat not found") };
        if (!std.mem.eql(u8, chat.device_id, host.device_id)) return .{ .err = common.failedMsg("chat belongs to another device") };
        const cwd = chat.cwd orelse return .{ .err = common.failedMsg("chat has no workspace folder") };
        const sid = chat.space_id orelse return .{ .err = common.failedMsg("chat has no workspace space") };
        const space = findSpace(host, sid) orelse return .{ .err = common.failedMsg("chat workspace space not found") };
        if (!std.mem.eql(u8, space.device_id, host.device_id)) return .{ .err = common.failedMsg("chat space belongs to another device") };
        root = (try g.workspaceCheckout(gpa, io, space.path, cwd)) orelse return .{ .err = common.failedMsg("chat folder is not a workspace checkout") };
    } else {
        const space = findSpace(host, space_id.?) orelse return .{ .err = common.failedMsg("space not found") };
        if (!std.mem.eql(u8, space.device_id, host.device_id)) return .{ .err = common.failedMsg("space belongs to another device") };
        const requested = optStr(o, "checkoutPath") orelse space.path;
        root = (try g.workspaceCheckout(gpa, io, space.path, requested)) orelse return .{ .err = common.badParams("checkoutPath is not a workspace checkout", .{}) };
    }
    errdefer gpa.free(root);
    switch (try g.checkoutIdentity(gpa, io, host.device_id, root)) {
        .ok => |ident| {
            gpa.free(ident.git_dir);
            gpa.free(root);
            return .{ .ok = .{ .checkout_id = ident.id, .root = ident.root } };
        },
        .failed => {
            var hex: [64]u8 = undefined;
            const digest = g.sha256Hex(&hex, &.{ host.device_id, &.{0}, "plain-folder", &.{0}, root });
            return .{ .ok = .{ .checkout_id = try std.fmt.allocPrint(gpa, "folder-{s}", .{digest}), .root = root } };
        },
    }
}

/// `WatchWorkspaceGitStatus { chatId | spaceId, checkoutPath? }` → stream of
/// `{status: CheckoutGitStatus | null}`: null while unavailable (plain
/// folders, untracked checkouts, a starting watcher), never "clean".
pub fn watchWorkspaceGitStatus(host: *EngineHost, call_id: u64, params: json.Value) !RpcOutcome {
    if (targetProblem(params, host.device_id)) |e| return e;
    const o = switch (object(params, "WatchWorkspaceFilesRequest")) {
        .ok => |o| o,
        .err => |e| return e,
    };
    const io = host.io orelse return noIo();
    const ws = switch (try resolveTarget(host, io, o)) {
        .ok => |w| w,
        .err => |e| return e,
    };
    defer host.gpa.free(ws.checkout_id);
    defer host.gpa.free(ws.root);
    const st = try watch.ensure(host);
    var tbuf: [160]u8 = undefined;
    if (call_id != 0) try host.registerWatch(call_id, watch.watch_kind, watch.statusTarget(&tbuf, ws.checkout_id));
    const current: ?[]const u8 = if (st) |s| (if (s.findEntry(ws.checkout_id)) |e| e.status_json else null) else null;
    const first = try std.fmt.allocPrint(host.gpa, "{{\"status\":{s}}}", .{current orelse "null"});
    errdefer host.gpa.free(first);
    return stream(host.gpa, &.{first});
}
