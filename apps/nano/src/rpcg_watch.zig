//! The checkout diff watcher behind `WatchCheckoutDiffs` and
//! `WatchWorkspaceGitStatus` (`crates/engine/src/diff_sync.rs`
//! `CheckoutDiffSync`): this device's non-archived chats are grouped by
//! checkout identity, each checkout gets one bounded snapshot, and an
//! unchanged checksum (or status revision) publishes nothing.
//!
//! Rust follows checkouts with recursive file-system watchers backed by a
//! 2-minute repair tick. This port polls instead: a worker re-captures every
//! tracked checkout every `poll_interval_ms` while anything subscribes, and
//! sooner when a discard, ref switch or fetch kicks it. Identities are
//! memoized per cwd and revalidated every `repair_interval_ms`, and a checkout
//! whose chats are gone is dropped only after that long (Rust's orphan grace).
//!
//! Subscriptions ride the engine's own watch list so a cancelled call or a
//! closed connection drops them: kind `.queue` with a target id that starts
//! with an ASCII record separator, which no chat id contains.
//!
//! Locking: every RPC runs under `host.mutex`; the worker takes it only to
//! read chats and to publish, never across a git call.
const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");
const g = @import("rpcg_git.zig");
const d = @import("rpcg_diff.zig");
const cr = @import("rpcg_change_requests.zig");

const EngineHost = engine_host.EngineHost;

pub const poll_interval_ms: i64 = 2_000;
pub const repair_interval_ms: i64 = 120_000;

pub const watch_kind: engine_host.WatchKind = .queue;
pub const diffs_target = "\x1echeckout-diffs";
pub const status_prefix = "\x1egit-status:";

pub fn statusTarget(buf: []u8, checkout_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ status_prefix, checkout_id }) catch status_prefix;
}

const Entry = struct {
    checkout_id: []u8,
    root: []u8,
    checksum: ?[64]u8 = null,
    /// Latest `CheckoutDiff` JSON, once captured.
    diff_json: ?[]u8 = null,
    /// Latest `CheckoutGitStatus` JSON and its revision.
    status_json: ?[]u8 = null,
    status_revision: ?[64]u8 = null,
    orphaned_since_ms: ?i64 = null,

    fn deinit(e: *Entry, gpa: Allocator) void {
        gpa.free(e.checkout_id);
        gpa.free(e.root);
        if (e.diff_json) |j| gpa.free(j);
        if (e.status_json) |j| gpa.free(j);
    }
};

const Memo = struct { id: []u8, root: []u8, at_ms: i64 };
const Turn = struct { root: []u8, tree: []u8 };
const PendingTurn = struct {
    chat_id: []u8,
    cwd: []u8,

    fn deinit(p: PendingTurn, gpa: Allocator) void {
        gpa.free(p.chat_id);
        gpa.free(p.cwd);
    }
};

pub const State = struct {
    host: *EngineHost,
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// cwd → identity; touched only by the worker.
    memo: std.StringHashMapUnmanaged(Memo) = .empty,
    kick: std.atomic.Value(u32) = .init(1),
    /// chat id → the tree its latest turn started from (`TurnSnapshot`).
    turns: std.StringHashMapUnmanaged(Turn) = .empty,
    /// Turns that started since the last tick, snapshotted off the lock.
    pending_turns: std.ArrayList(PendingTurn) = .empty,
    /// `WatchCheckoutChangeRequest` streams (guarded by `host.mutex`) and
    /// their worker-only caches (`rpcg_change_requests.zig`).
    cr_subs: std.ArrayList(cr.Sub) = .empty,
    cr_cache: std.StringHashMapUnmanaged(cr.Entry) = .empty,
    cr_inspections: std.StringHashMapUnmanaged(cr.Inspection) = .empty,
    cr_refresh_all: std.atomic.Value(bool) = .init(false),
    cr_seq: u64 = 0,

    fn deinit(s: *State) void {
        cr.deinitState(s);
        var tit = s.turns.iterator();
        while (tit.next()) |kv| {
            s.gpa.free(kv.key_ptr.*);
            s.gpa.free(kv.value_ptr.root);
            s.gpa.free(kv.value_ptr.tree);
        }
        s.turns.deinit(s.gpa);
        for (s.pending_turns.items) |p| p.deinit(s.gpa);
        s.pending_turns.deinit(s.gpa);
        for (s.entries.items) |*e| e.deinit(s.gpa);
        s.entries.deinit(s.gpa);
        var it = s.memo.iterator();
        while (it.next()) |kv| {
            s.gpa.free(kv.key_ptr.*);
            s.gpa.free(kv.value_ptr.id);
            s.gpa.free(kv.value_ptr.root);
        }
        s.memo.deinit(s.gpa);
    }

    pub fn findEntry(s: *State, checkout_id: []const u8) ?*Entry {
        for (s.entries.items) |*e| if (std.mem.eql(u8, e.checkout_id, checkout_id)) return e;
        return null;
    }
};

/// One state per engine host, created with its worker and freed by it when
/// the host stops (`host.deinit` waits on `bg_workers_active`). Accessed only
/// under `host.mutex`.
var states: std.AutoHashMapUnmanaged(*EngineHost, *State) = .empty;
var states_gpa: Allocator = std.heap.page_allocator;

pub fn existing(host: *EngineHost) ?*State {
    return states.get(host);
}

/// The host's watcher, starting it on first use. Null without I/O.
pub fn ensure(host: *EngineHost) !?*State {
    if (states.get(host)) |s| return s;
    const io = host.io orelse return null;
    const s = try host.gpa.create(State);
    s.* = .{ .host = host, .gpa = host.gpa };
    errdefer host.gpa.destroy(s);
    try states.put(states_gpa, host, s);
    errdefer _ = states.remove(host);
    _ = host.bg_workers_active.fetchAdd(1, .acq_rel);
    const th = std.Thread.spawn(.{}, workerMain, .{ s, io }) catch |e| {
        _ = host.bg_workers_active.fetchSub(1, .acq_rel);
        return e;
    };
    th.detach();
    return s;
}

/// A turn is starting for `chat_id` in `cwd` (`CheckoutDiffSync::note_turn_start`):
/// snapshot the checkout's tree off the lock so "Latest turn" has a base.
/// Called with `host.mutex` held; a folder outside a checkout records nothing.
pub fn noteTurnStart(host: *EngineHost, chat_id: []const u8, cwd: []const u8) !void {
    const s = (try ensure(host)) orelse return;
    const c = try s.gpa.dupe(u8, chat_id);
    errdefer s.gpa.free(c);
    const w = try s.gpa.dupe(u8, cwd);
    errdefer s.gpa.free(w);
    try s.pending_turns.append(s.gpa, .{ .chat_id = c, .cwd = w });
    _ = s.kick.fetchAdd(1, .acq_rel);
}

/// The tree `chat_id`'s latest turn started from, when it was recorded in
/// the checkout at `root` (an owned copy).
pub fn turnTree(host: *EngineHost, gpa: Allocator, chat_id: []const u8, root: []const u8) !?[]u8 {
    const s = states.get(host) orelse return null;
    const t = s.turns.get(chat_id) orelse return null;
    if (!std.mem.eql(u8, t.root, root)) return null;
    return try gpa.dupe(u8, t.tree);
}

fn recordTurns(s: *State, io: std.Io, pending: []const PendingTurn) !void {
    const host = s.host;
    for (pending) |p| {
        if (@atomicLoad(bool, &host.stop_requested, .acquire)) return;
        const ident = switch (try g.checkoutIdentity(s.gpa, io, host.device_id, p.cwd)) {
            .ok => |i| i,
            .failed => continue, // not a checkout
        };
        defer ident.deinit(s.gpa);
        const tree = switch (try d.snapshotTree(s.gpa, io, ident.root)) {
            .ok => |t| t,
            .failed => continue,
        };
        errdefer s.gpa.free(tree);
        const root = try s.gpa.dupe(u8, ident.root);
        errdefer s.gpa.free(root);
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (s.turns.fetchRemove(p.chat_id)) |old| {
            s.gpa.free(old.value.root);
            s.gpa.free(old.value.tree);
            try s.turns.put(s.gpa, old.key, .{ .root = root, .tree = tree });
        } else {
            const key = try s.gpa.dupe(u8, p.chat_id);
            errdefer s.gpa.free(key);
            try s.turns.put(s.gpa, key, .{ .root = root, .tree = tree });
        }
    }
}

/// Ask for an immediate re-capture (Rust's `sync_all`).
pub fn kick(host: *EngineHost) void {
    if (states.get(host)) |s| _ = s.kick.fetchAdd(1, .acq_rel);
}

fn hasSubscribers(host: *EngineHost) bool {
    for (host.watches.items) |w| {
        if (w.kind != watch_kind) continue;
        const t = w.target_id orelse continue;
        if (std.mem.startsWith(u8, t, "\x1e") and
            (std.mem.eql(u8, t, diffs_target) or std.mem.startsWith(u8, t, status_prefix))) return true;
    }
    return false;
}

fn workerMain(s: *State, io: std.Io) void {
    const host = s.host;
    defer _ = host.bg_workers_active.fetchSub(1, .acq_rel);
    while (!@atomicLoad(bool, &host.stop_requested, .acquire)) {
        tick(s, io) catch |e| std.log.debug("checkout watch: {t}", .{e});
        var waited: i64 = 0;
        while (waited < poll_interval_ms and !@atomicLoad(bool, &host.stop_requested, .acquire)) : (waited += 100) {
            if (s.kick.load(.acquire) != 0) break;
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch break;
        }
    }
    host.mutex.lockUncancelable(io);
    _ = states.remove(host);
    s.deinit();
    host.gpa.destroy(s);
    host.mutex.unlock(io);
}

const Target = struct { id: []const u8, root: []const u8 };

fn tick(s: *State, io: std.Io) !void {
    const host = s.host;
    const gpa = s.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Under the lock: who listens, and which folders this device's chats use.
    var cwds: std.ArrayList([]const u8) = .empty;
    var device_id: []const u8 = undefined;
    var pending: std.ArrayList(PendingTurn) = .empty;
    defer {
        for (pending.items) |p| p.deinit(gpa);
        pending.deinit(gpa);
    }
    {
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        pending = s.pending_turns;
        s.pending_turns = .empty;
    }
    try recordTurns(s, io, pending.items);
    try cr.process(s, io, @intCast(std.Io.Clock.real.now(io).toMilliseconds()));
    {
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        const kicked = s.kick.swap(0, .acq_rel) != 0;
        if (!hasSubscribers(host) and !kicked) return;
        device_id = try arena.dupe(u8, host.device_id);
        for (host.chats.items) |c| {
            if (c.archived or !std.mem.eql(u8, c.device_id, host.device_id)) continue;
            const cwd = c.cwd orelse continue;
            var dup = false;
            for (cwds.items) |x| if (std.mem.eql(u8, x, cwd)) {
                dup = true;
                break;
            };
            if (!dup) try cwds.append(arena, try arena.dupe(u8, cwd));
        }
    }

    // 2. Unlocked: resolve identities (memoized; revalidated after the repair interval).
    const now = @as(i64, @intCast(std.Io.Clock.real.now(io).toMilliseconds()));
    var targets: std.ArrayList(Target) = .empty;
    for (cwds.items) |cwd| {
        if (@atomicLoad(bool, &host.stop_requested, .acquire)) return;
        const id_root: ?Target = blk: {
            if (s.memo.get(cwd)) |m| if (now - m.at_ms < repair_interval_ms) break :blk .{ .id = m.id, .root = m.root };
            switch (try g.checkoutIdentity(gpa, io, device_id, cwd)) {
                .ok => |ident| {
                    defer gpa.free(ident.git_dir);
                    const key = if (s.memo.fetchRemove(cwd)) |old| blk2: {
                        gpa.free(old.value.id);
                        gpa.free(old.value.root);
                        break :blk2 old.key;
                    } else try gpa.dupe(u8, cwd);
                    try s.memo.put(gpa, key, .{ .id = ident.id, .root = ident.root, .at_ms = now });
                    break :blk .{ .id = ident.id, .root = ident.root };
                },
                .failed => {
                    // Keep a memoized identity unless the folder is gone.
                    if (s.memo.get(cwd)) |m| {
                        if (@import("rpcw_common.zig").pathExists(io, cwd)) break :blk .{ .id = m.id, .root = m.root };
                        if (s.memo.fetchRemove(cwd)) |old| {
                            gpa.free(old.key);
                            gpa.free(old.value.id);
                            gpa.free(old.value.root);
                        }
                    }
                    break :blk null;
                },
            }
        };
        const t = id_root orelse continue;
        var dup = false;
        for (targets.items) |x| if (std.mem.eql(u8, x.id, t.id)) {
            dup = true;
            break;
        };
        if (!dup) try targets.append(arena, .{ .id = try arena.dupe(u8, t.id), .root = try arena.dupe(u8, t.root) });
    }

    // 3. Unlocked: one snapshot per checkout.
    const Captured = struct { target: Target, snap: ?d.Snapshot };
    var captured: std.ArrayList(Captured) = .empty;
    defer for (captured.items) |*c| if (c.snap) |*sn| sn.deinit();
    for (targets.items) |t| {
        if (@atomicLoad(bool, &host.stop_requested, .acquire)) return;
        const r = try d.captureDiff(gpa, io, t.root, .{ .stop = &host.stop_requested });
        try captured.append(arena, .{ .target = t, .snap = switch (r) {
            .ok => |sn| sn,
            .failed => null,
        } });
    }

    // 4. Under the lock: update entries and publish what changed.
    host.mutex.lockUncancelable(io);
    defer host.mutex.unlock(io);
    if (@atomicLoad(bool, &host.stop_requested, .acquire)) return;
    var diffs_changed = false;
    // Orphans: entries no chat names any more go after the grace period.
    var i: usize = 0;
    while (i < s.entries.items.len) {
        const e = &s.entries.items[i];
        var live = false;
        for (targets.items) |t| if (std.mem.eql(u8, t.id, e.checkout_id)) {
            live = true;
            break;
        };
        if (live) {
            e.orphaned_since_ms = null;
        } else if (e.orphaned_since_ms) |since| {
            if (now - since >= repair_interval_ms) {
                if (e.diff_json != null) diffs_changed = true;
                var removed = s.entries.orderedRemove(i);
                removed.deinit(gpa);
                continue;
            }
        } else e.orphaned_since_ms = now;
        i += 1;
    }
    var ts_buf: [32]u8 = undefined;
    const updated_at = auth_host.formatRfc3339Ms(&ts_buf, now);
    for (captured.items) |*c| {
        const e = s.findEntry(c.target.id) orelse blk: {
            try s.entries.append(gpa, .{ .checkout_id = try gpa.dupe(u8, c.target.id), .root = try gpa.dupe(u8, c.target.root) });
            break :blk &s.entries.items[s.entries.items.len - 1];
        };
        if (c.snap) |*sn| {
            if (sn.git_status) |st| try publishStatus(s, e, st);
            if (e.checksum == null or !std.mem.eql(u8, &e.checksum.?, &sn.checksum)) {
                var aw: std.Io.Writer.Allocating = .init(gpa);
                errdefer aw.deinit();
                try d.writeCheckoutDiff(&aw.writer, e.checkout_id, host.device_id, e.root, sn, updated_at);
                if (e.diff_json) |old| gpa.free(old);
                e.diff_json = try aw.toOwnedSlice();
                e.checksum = sn.checksum;
                diffs_changed = true;
            }
        } else {
            // Capture failed: the status is unavailable, never "clean".
            try publishStatus(s, e, .{ .files = &.{}, .complete = false });
        }
    }
    if (diffs_changed) try publishDiffs(s);
}

/// Record and publish a checkout's status when its revision changed.
fn publishStatus(s: *State, e: *Entry, st: d.GitStatus) !void {
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    var aw: std.Io.Writer.Allocating = .init(s.gpa);
    defer aw.deinit();
    try d.writeCheckoutGitStatus(arena_state.allocator(), &aw.writer, e.checkout_id, s.host.device_id, st);
    const json_text = aw.written();
    // The revision is the 64 hex characters after `"revision":"`.
    const marker = "\"revision\":\"";
    const at = (std.mem.indexOf(u8, json_text, marker) orelse return) + marker.len;
    var rev: [64]u8 = undefined;
    @memcpy(&rev, json_text[at .. at + 64]);
    if (e.status_revision) |old| if (std.mem.eql(u8, &old, &rev) and e.status_json != null) return;
    if (e.status_json) |old| s.gpa.free(old);
    e.status_json = try s.gpa.dupe(u8, json_text);
    e.status_revision = rev;
    const frame = try std.fmt.allocPrint(s.gpa, "{{\"status\":{s}}}", .{json_text});
    defer s.gpa.free(frame);
    var tbuf: [160]u8 = undefined;
    try s.host.broadcastWatch(watch_kind, statusTarget(&tbuf, e.checkout_id), frame);
}

/// The `WatchCheckoutDiffs` item: every captured checkout's latest diff,
/// sorted by checkout id.
pub fn diffsJson(s: *State, gpa: Allocator) ![]u8 {
    var order: std.ArrayList(*Entry) = .empty;
    defer order.deinit(gpa);
    for (s.entries.items) |*e| if (e.diff_json != null) try order.append(gpa, e);
    std.mem.sort(*Entry, order.items, {}, struct {
        fn lt(_: void, a: *Entry, b: *Entry) bool {
            return std.mem.order(u8, a.checkout_id, b.checkout_id) == .lt;
        }
    }.lt);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeByte('[');
    for (order.items, 0..) |e, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.writeAll(e.diff_json.?);
    }
    try aw.writer.writeByte(']');
    return aw.toOwnedSlice();
}

fn publishDiffs(s: *State) !void {
    const list = try diffsJson(s, s.gpa);
    defer s.gpa.free(list);
    try s.host.broadcastWatch(watch_kind, diffs_target, list);
}

/// After a discard: publish the checkout's final snapshot at once instead of
/// waiting for the next poll (Rust runs `sync_entry` before replying).
pub fn publishSnapshot(host: *EngineHost, checkout_id: []const u8, root: []const u8, snap: *const d.Snapshot) !void {
    const s = states.get(host) orelse return;
    const e = s.findEntry(checkout_id) orelse blk: {
        try s.entries.append(s.gpa, .{ .checkout_id = try s.gpa.dupe(u8, checkout_id), .root = try s.gpa.dupe(u8, root) });
        break :blk &s.entries.items[s.entries.items.len - 1];
    };
    if (snap.git_status) |st| try publishStatus(s, e, st);
    if (e.checksum == null or !std.mem.eql(u8, &e.checksum.?, &snap.checksum)) {
        var ts_buf: [32]u8 = undefined;
        var aw: std.Io.Writer.Allocating = .init(s.gpa);
        errdefer aw.deinit();
        try d.writeCheckoutDiff(&aw.writer, e.checkout_id, host.device_id, e.root, snap, auth_host.formatRfc3339Ms(&ts_buf, host.nowMs()));
        if (e.diff_json) |old| s.gpa.free(old);
        e.diff_json = try aw.toOwnedSlice();
        e.checksum = snap.checksum;
        try publishDiffs(s);
    }
    _ = s.kick.fetchAdd(1, .acq_rel);
}
