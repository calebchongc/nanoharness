//! The MCP server's link to the engine (`crates/mcp/src/harness.rs`, the
//! transport half): unary calls and scoped watch subscriptions over the
//! engine's RPC frames (`rpc.zig`).
//!
//! Two backends share one interface:
//! - `WsEngine`: the engine's loopback WebSocket, dialed lazily on the first
//!   tool call (so `initialize` answers before the engine is up), one reader
//!   thread routing frames by id, and one reconnect when the socket closed
//!   under a call — the Rust client's `RpcError::Closed` retry.
//! - `HostEngine`: an in-process `EngineHost`, the same dispatch the socket
//!   serves (`engine_main.dispatchClientLineWithArena`), for tests and
//!   embedding. Watch items the host broadcasts while a subscription is open
//!   arrive through `pushed_frames`.
//!
//! Errors come back as text in the Rust client's wording: `"{method}: {e}"`.
const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ws = @import("../ws.zig");
const engine_host = @import("../engine_host.zig");

/// A unary reply, or the error text the tools surface.
pub const Result = union(enum) {
    ok: json.Value,
    err: []const u8,
};

pub const Next = union(enum) {
    item: json.Value,
    /// The engine ended (or errored) the stream.
    ended,
    /// The deadline passed with nothing new.
    timeout,
};

pub const Subscription = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque, arena: Allocator, timeout_ms: i64) anyerror!Next,
        close: *const fn (ptr: *anyopaque) void,
    };

    /// The next item, waiting at most `timeout_ms`.
    pub fn next(s: Subscription, arena: Allocator, timeout_ms: i64) !Next {
        return s.vtable.next(s.ptr, arena, timeout_ms);
    }

    /// Drops the subscription; the engine-side watch is cancelled at once.
    pub fn close(s: Subscription) void {
        s.vtable.close(s.ptr);
    }
};

pub const Subscribed = union(enum) {
    sub: Subscription,
    err: []const u8,
};

pub const Engine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        call: *const fn (ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Result,
        subscribe: *const fn (ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Subscribed,
    };

    pub fn call(e: Engine, arena: Allocator, method: []const u8, params_json: []const u8) !Result {
        return e.vtable.call(e.ptr, arena, method, params_json);
    }

    pub fn subscribe(e: Engine, arena: Allocator, method: []const u8, params_json: []const u8) !Subscribed {
        return e.vtable.subscribe(e.ptr, arena, method, params_json);
    }
};

/// First-item wait for a watch snapshot (`SNAPSHOT_TIMEOUT`).
pub const snapshot_timeout_ms: i64 = 15_000;

/// First item of a watch stream, then cancel it (`Harness::snapshot`).
pub fn snapshot(e: Engine, arena: Allocator, method: []const u8, params_json: []const u8) !Result {
    const sub = switch (try e.subscribe(arena, method, params_json)) {
        .sub => |s| s,
        .err => |m| return .{ .err = m },
    };
    defer sub.close();
    return switch (try sub.next(arena, snapshot_timeout_ms)) {
        .item => |v| .{ .ok = v },
        .ended => .{ .err = try std.fmt.allocPrint(arena, "{s}: stream ended before its first snapshot", .{method}) },
        .timeout => .{ .err = try std.fmt.allocPrint(arena, "{s}: no snapshot within {d}s", .{ method, @divTrunc(snapshot_timeout_ms, 1000) }) },
    };
}

/// The wire's error string as the Rust client words it (`wire_error` +
/// `RpcError` display): `unknown method: X` stays as sent, anything else is
/// `Failed(msg)` and displays as the message itself.
fn wireErr(arena: Allocator, method: []const u8, msg: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ method, msg });
}

// ---- WebSocket backend ---------------------------------------------------------

pub const WsEngine = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    client: ?*ws.Client = null,
    /// Bumped on every dial; a slot from an older connection is dead.
    generation: u64 = 0,
    next_id: u64 = 1,
    slots: std.AutoHashMapUnmanaged(u64, *Slot) = .empty,
    readers: std.ArrayList(std.Thread) = .empty,

    const Slot = struct {
        generation: u64,
        frames: std.ArrayList([]u8) = .empty,
        closed: bool = false,
    };

    pub fn init(gpa: Allocator, io: Io, port: u16) WsEngine {
        return .{ .gpa = gpa, .io = io, .port = port };
    }

    pub fn deinit(self: *WsEngine) void {
        self.mutex.lockUncancelable(self.io);
        if (self.client) |c| c.shutdown();
        self.mutex.unlock(self.io);
        for (self.readers.items) |t| t.join();
        self.readers.deinit(self.gpa);
        var it = self.slots.iterator();
        while (it.next()) |e| self.freeSlot(e.value_ptr.*);
        self.slots.deinit(self.gpa);
    }

    pub fn engine(self: *WsEngine) Engine {
        return .{ .ptr = self, .vtable = &.{ .call = callFn, .subscribe = subscribeFn } };
    }

    fn url(self: *WsEngine, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}", .{self.port}) catch "ws://127.0.0.1";
    }

    fn freeSlot(self: *WsEngine, slot: *Slot) void {
        for (slot.frames.items) |f| self.gpa.free(f);
        slot.frames.deinit(self.gpa);
        self.gpa.destroy(slot);
    }

    /// Dials when there is no connection. Called with `mutex` held.
    fn ensureConnected(self: *WsEngine, arena: Allocator) !?[]const u8 {
        if (self.client != null) return null;
        const client = ws.Client.connect(self.gpa, self.io, self.port, "/") catch |err| {
            var buf: [64]u8 = undefined;
            return try std.fmt.allocPrint(arena, "no Harness engine listening at {s} (transport: {t}) — is Harness running?", .{ self.url(&buf), err });
        };
        self.generation += 1;
        self.client = client;
        const t = std.Thread.spawn(.{}, readLoop, .{ self, client, self.generation }) catch |err| {
            client.deinit(self.gpa);
            self.client = null;
            return try std.fmt.allocPrint(arena, "engine reader: {t}", .{err});
        };
        try self.readers.append(self.gpa, t);
        return null;
    }

    fn readLoop(self: *WsEngine, client: *ws.Client, generation: u64) void {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.gpa);
        while (true) {
            const op = client.readMessage(self.gpa, &msg) catch break;
            if (op != .text) continue;
            const id = frameId(msg.items) orelse continue;
            const copy = self.gpa.dupe(u8, msg.items) catch continue;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.slots.get(id)) |slot| {
                if (slot.generation == generation) {
                    slot.frames.append(self.gpa, copy) catch self.gpa.free(copy);
                    self.cond.broadcast(self.io);
                    continue;
                }
            }
            self.gpa.free(copy);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.slots.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.generation == generation) e.value_ptr.*.closed = true;
        }
        if (self.client == client) self.client = null;
        client.deinit(self.gpa);
        self.cond.broadcast(self.io);
    }

    fn frameId(text: []const u8) ?u64 {
        // `{"id":N,...}`: the engine always writes the id first.
        const key = "\"id\":";
        const at = std.mem.indexOf(u8, text, key) orelse return null;
        var i = at + key.len;
        var n: u64 = 0;
        var digits: usize = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            n = n *% 10 +% (text[i] - '0');
            digits += 1;
        }
        return if (digits > 0) n else null;
    }

    const Opened = union(enum) { slot: struct { id: u64, slot: *Slot }, err: []const u8, closed };

    /// Registers a slot and sends the call frame.
    fn open(self: *WsEngine, arena: Allocator, method: []const u8, params_json: []const u8) !Opened {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (try self.ensureConnected(arena)) |m| return .{ .err = m };
        const id = self.next_id;
        self.next_id += 1;
        const slot = try self.gpa.create(Slot);
        slot.* = .{ .generation = self.generation };
        try self.slots.put(self.gpa, id, slot);
        const frame = try std.fmt.allocPrint(arena, "{{\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ id, json.fmt(method, .{}), params_json });
        self.client.?.sendText(frame) catch {
            _ = self.slots.remove(id);
            self.freeSlot(slot);
            if (self.client) |c| c.shutdown();
            return .closed;
        };
        return .{ .slot = .{ .id = id, .slot = slot } };
    }

    fn drop(self: *WsEngine, id: u64, send_cancel: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.slots.fetchRemove(id) orelse return;
        const slot = removed.value;
        if (send_cancel and !slot.closed and self.client != null and slot.generation == self.generation) {
            var buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cancel\":true}}", .{id})) |frame| {
                self.client.?.sendText(frame) catch {};
            } else |_| {}
        }
        self.freeSlot(slot);
    }

    /// Waits for the next frame of `slot`. Null when closed or timed out.
    fn take(self: *WsEngine, slot: *Slot, deadline: ?Io.Clock.Timestamp) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (slot.frames.items.len == 0 and !slot.closed) {
            if (deadline) |d| {
                self.cond.waitTimeout(self.io, &self.mutex, .{ .deadline = d }) catch return null;
            } else {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
        }
        if (slot.frames.items.len == 0) return null;
        return slot.frames.orderedRemove(0);
    }

    fn callOnce(self: *WsEngine, arena: Allocator, method: []const u8, params_json: []const u8) !?Result {
        const opened = try self.open(arena, method, params_json);
        const o = switch (opened) {
            .slot => |s| s,
            .err => |m| return .{ .err = m },
            .closed => return null,
        };
        defer self.drop(o.id, false);
        while (true) {
            const raw = self.take(o.slot, null) orelse return null;
            defer self.gpa.free(raw);
            const frame = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .allocate = .alloc_always });
            if (frame != .object) continue;
            if (frame.object.get("err")) |e| {
                return .{ .err = try wireErr(arena, method, if (e == .string) e.string else "error") };
            }
            if (frame.object.get("ok")) |v| return .{ .ok = v };
            // A stream answered a unary call: its first item stands in.
            if (frame.object.get("item")) |v| return .{ .ok = v };
        }
    }

    fn callFn(ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Result {
        const self: *WsEngine = @ptrCast(@alignCast(ptr));
        if (try self.callOnce(arena, method, params_json)) |r| return r;
        // Closed underneath: the engine restarted. Dial once more.
        if (try self.callOnce(arena, method, params_json)) |r| return r;
        return .{ .err = try std.fmt.allocPrint(arena, "{s}: connection closed", .{method}) };
    }

    const WsSub = struct {
        owner: *WsEngine,
        id: u64,
        slot: *Slot,
        method: []const u8,
    };

    fn subscribeFn(ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Subscribed {
        const self: *WsEngine = @ptrCast(@alignCast(ptr));
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            switch (try self.open(arena, method, params_json)) {
                .err => |m| return .{ .err = m },
                .closed => continue,
                .slot => |o| {
                    const s = try self.gpa.create(WsSub);
                    s.* = .{ .owner = self, .id = o.id, .slot = o.slot, .method = method };
                    return .{ .sub = .{ .ptr = s, .vtable = &.{ .next = subNext, .close = subClose } } };
                },
            }
        }
        return .{ .err = try std.fmt.allocPrint(arena, "{s}: connection closed", .{method}) };
    }

    fn subNext(ptr: *anyopaque, arena: Allocator, timeout_ms: i64) anyerror!Next {
        const s: *WsSub = @ptrCast(@alignCast(ptr));
        const io = s.owner.io;
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(@max(0, timeout_ms)), .clock = .awake });
        while (true) {
            const raw = s.owner.take(s.slot, deadline) orelse {
                s.owner.mutex.lockUncancelable(io);
                const closed = s.slot.closed;
                s.owner.mutex.unlock(io);
                return if (closed) .ended else .timeout;
            };
            defer s.owner.gpa.free(raw);
            const frame = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .allocate = .alloc_always });
            if (frame != .object) continue;
            if (frame.object.get("item")) |v| return .{ .item = v };
            if (frame.object.get("err") != null) return .ended;
            if (frame.object.get("done")) |d| if (d == .bool and d.bool) return .ended;
            // `ok` opens a checked stream; keep reading.
        }
    }

    fn subClose(ptr: *anyopaque) void {
        const s: *WsSub = @ptrCast(@alignCast(ptr));
        const owner = s.owner;
        owner.drop(s.id, true);
        owner.gpa.destroy(s);
    }
};

// ---- In-process backend --------------------------------------------------------

pub const HostEngine = struct {
    host: *engine_host.EngineHost,
    /// Ids for subscriptions; far from the socket's so they never collide.
    next_id: u64 = 1 << 40,

    pub fn engine(self: *HostEngine) Engine {
        return .{ .ptr = self, .vtable = &.{ .call = callFn, .subscribe = subscribeFn } };
    }

    fn errText(e: engine_host.RpcError) []const u8 {
        return switch (e) {
            .bad_params => |m| m,
            .unknown_method => |m| m,
            .exec_error => |m| m,
        };
    }

    fn callFn(ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Result {
        const self: *HostEngine = @ptrCast(@alignCast(ptr));
        const gpa = self.host.gpa;
        const params = try json.parseFromSliceLeaky(json.Value, arena, params_json, .{ .allocate = .alloc_always });
        var outcome = try self.host.handleWithId(0, method, params);
        switch (outcome) {
            .unary_json => |body| {
                defer gpa.free(body);
                return .{ .ok = try json.parseFromSliceLeaky(json.Value, arena, body, .{ .allocate = .alloc_always }) };
            },
            .stream_items_json => |*st| {
                defer st.deinit(gpa);
                if (st.items.len == 0) return .{ .ok = .null };
                return .{ .ok = try json.parseFromSliceLeaky(json.Value, arena, st.items[0], .{ .allocate = .alloc_always }) };
            },
            .err => |e| return .{ .err = try wireErr(arena, method, errText(e)) },
        }
    }

    const HostSub = struct {
        owner: *HostEngine,
        id: u64,
        queued: std.ArrayList([]u8) = .empty,
    };

    fn subscribeFn(ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Subscribed {
        const self: *HostEngine = @ptrCast(@alignCast(ptr));
        const gpa = self.host.gpa;
        const params = try json.parseFromSliceLeaky(json.Value, arena, params_json, .{ .allocate = .alloc_always });
        const id = self.next_id;
        self.next_id += 1;
        var outcome = try self.host.handleWithId(id, method, params);
        switch (outcome) {
            .err => |e| return .{ .err = try wireErr(arena, method, errText(e)) },
            .unary_json => |body| {
                const s = try gpa.create(HostSub);
                s.* = .{ .owner = self, .id = id };
                try s.queued.append(gpa, body);
                return .{ .sub = .{ .ptr = s, .vtable = &.{ .next = subNext, .close = subClose } } };
            },
            .stream_items_json => |*st| {
                const s = try gpa.create(HostSub);
                s.* = .{ .owner = self, .id = id };
                for (st.items) |it| try s.queued.append(gpa, it);
                gpa.free(st.items);
                return .{ .sub = .{ .ptr = s, .vtable = &.{ .next = subNext, .close = subClose } } };
            },
        }
    }

    fn subNext(ptr: *anyopaque, arena: Allocator, _: i64) anyerror!Next {
        const s: *HostSub = @ptrCast(@alignCast(ptr));
        const host = s.owner.host;
        const gpa = host.gpa;
        // Items the host broadcast to this watch since the last read.
        var i: usize = 0;
        while (i < host.pushed_frames.items.len) {
            if (host.pushed_frames.items[i].sub_id == s.id) {
                const p = host.pushed_frames.orderedRemove(i);
                try s.queued.append(gpa, p.item_json);
                continue;
            }
            i += 1;
        }
        if (s.queued.items.len == 0) {
            // Nothing else runs in this process while the caller waits, so
            // the deadline is already as good as passed.
            return .timeout;
        }
        const raw = s.queued.orderedRemove(0);
        defer gpa.free(raw);
        return .{ .item = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .allocate = .alloc_always }) };
    }

    fn subClose(ptr: *anyopaque) void {
        const s: *HostSub = @ptrCast(@alignCast(ptr));
        const host = s.owner.host;
        const gpa = host.gpa;
        host.cancelWatch(s.id);
        var i: usize = 0;
        while (i < host.pushed_frames.items.len) {
            if (host.pushed_frames.items[i].sub_id == s.id) {
                var p = host.pushed_frames.orderedRemove(i);
                p.deinit(gpa);
                continue;
            }
            i += 1;
        }
        for (s.queued.items) |q| gpa.free(q);
        s.queued.deinit(gpa);
        gpa.destroy(s);
    }
};

const testing = std.testing;

test "mcp engine link: frame ids parse and an absent engine is reported like the Rust client" {
    try testing.expectEqual(@as(?u64, 42), WsEngine.frameId("{\"id\":42,\"ok\":{}}"));
    try testing.expectEqual(@as(?u64, null), WsEngine.frameId("{\"ok\":{}}"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Port 1 on loopback: nothing listens there.
    var link = WsEngine.init(testing.allocator, testing.io, 1);
    defer link.deinit();
    const r = try link.engine().call(arena, "LocalDevice", "{}");
    try testing.expect(r == .err);
    try testing.expect(std.mem.startsWith(u8, r.err, "no Harness engine listening at ws://127.0.0.1:1 ("));
    try testing.expect(std.mem.endsWith(u8, r.err, ") — is Harness running?"));
}

test "mcp engine link: the in-process host answers calls, snapshots and pushed watch items" {
    const gpa = testing.allocator;
    var host = try engine_host.EngineHost.init(gpa, "dev-test", "Test Mac");
    defer host.deinit();
    var link: HostEngine = .{ .host = &host };
    const e = link.engine();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ld = try e.call(arena, "LocalDevice", "{}");
    try testing.expectEqualStrings("dev-test", ld.ok.object.get("deviceId").?.string);

    const bad = try e.call(arena, "Mutate", "{}");
    try testing.expectEqualStrings("Mutate: missing op", bad.err);

    const chats = try snapshot(e, arena, "WatchChats", "{}");
    try testing.expect(chats.ok == .array);

    const sub = switch (try e.subscribe(arena, "WatchSpaces", "{}")) {
        .sub => |s| s,
        .err => return error.TestUnexpectedResult,
    };
    defer sub.close();
    try testing.expect((try sub.next(arena, 10)) == .item);
    try testing.expect((try sub.next(arena, 10)) == .timeout);
    _ = try e.call(arena, "Mutate", "{\"op\":\"createSpace\",\"spaceId\":\"sp-1\",\"path\":\"/tmp/synthetic\"}");
    const pushed = try sub.next(arena, 10);
    try testing.expect(pushed == .item);
    try testing.expectEqual(@as(usize, 1), pushed.item.array.items.len);
}
