//! Items pushed to a live `Watch*` stream from a thread other than the
//! client's (`{id, item}` frames, then `{id, done: true}` as
//! `crates/rpc/src/server.rs` ends a stream).
//!
//! The client's writer lives on its socket thread's stack and goes away when
//! the socket closes; `EngineHost.removeClientWatches` and `cancelWatch` are
//! the only signals of that. So every background stream also registers a
//! `WatchSubscription` whose target is a token no chat id can equal (it starts
//! with a NUL byte), and a push first checks, under `host.mutex`, that the
//! entry is still there. `broadcastWatch(.queue, ...)` is only ever called
//! with a chat id, so the token entry never receives another stream's items.
const std = @import("std");
const engine_host = @import("engine_host.zig");
const ws_server = @import("ws_server.zig");

const EngineHost = engine_host.EngineHost;

pub const Sub = struct {
    sub_id: u64,
    writer: ?*std.Io.Writer,
    token: []const u8,
};

/// Called from a handler (the caller holds `host.mutex`).
pub fn open(host: *EngineHost, call_id: u64, token: []const u8) !Sub {
    std.debug.assert(token.len > 0 and token[0] == 0);
    try host.registerWatch(call_id, .queue, token);
    return .{ .sub_id = call_id, .writer = host.live_ws_writer, .token = token };
}

pub fn lock(host: *EngineHost) void {
    if (host.io) |io| host.mutex.lockUncancelable(io);
}

pub fn unlock(host: *EngineHost) void {
    if (host.io) |io| host.mutex.unlock(io);
}

fn indexOf(host: *EngineHost, sub: Sub) ?usize {
    for (host.watches.items, 0..) |w, i| {
        if (w.sub_id != sub.sub_id or w.kind != .queue or w.client_writer != sub.writer) continue;
        const t = w.target_id orelse continue;
        if (std.mem.eql(u8, t, sub.token)) return i;
    }
    return null;
}

/// Whether the client still watches. Caller holds `host.mutex`.
pub fn aliveLocked(host: *EngineHost, sub: Sub) bool {
    return indexOf(host, sub) != null;
}

/// Send one item; false once the client has gone. Caller holds `host.mutex`.
pub fn sendLocked(host: *EngineHost, sub: Sub, item_json: []const u8) bool {
    if (indexOf(host, sub) == null) return false;
    if (sub.writer) |w| {
        const frame = std.fmt.allocPrint(host.gpa, "{{\"id\":{d},\"item\":{s}}}", .{ sub.sub_id, item_json }) catch return true;
        defer host.gpa.free(frame);
        ws_server.writeServerFrame(w, .text, frame) catch return false;
        w.flush() catch return false;
    } else {
        // No socket (a direct `handle` call): queue it as `broadcastWatch` does.
        const copy = host.gpa.dupe(u8, item_json) catch return true;
        host.pushed_frames.append(host.gpa, .{ .sub_id = sub.sub_id, .item_json = copy }) catch host.gpa.free(copy);
    }
    return true;
}

/// End the stream (`{id, done: true}`) and drop its token. Caller holds `host.mutex`.
pub fn doneLocked(host: *EngineHost, sub: Sub) void {
    const i = indexOf(host, sub) orelse return;
    if (sub.writer) |w| {
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{{\"id\":{d},\"done\":true}}", .{sub.sub_id})) |frame| {
            ws_server.writeServerFrame(w, .text, frame) catch {};
            w.flush() catch {};
        } else |_| {}
    }
    host.watches.items[i].deinit(host.gpa);
    _ = host.watches.orderedRemove(i);
}

/// A one-item reply the dispatcher writes as `{id, item}` (the first frame).
pub fn firstItem(gpa: std.mem.Allocator, item_json: []u8) !engine_host.RpcOutcome {
    errdefer gpa.free(item_json);
    const items = try gpa.alloc([]u8, 1);
    items[0] = item_json;
    return .{ .stream_items_json = .{ .checked = false, .items = items } };
}

test "a background item reaches only a live subscription and stops after cancel" {
    const gpa = std.testing.allocator;
    var host = try EngineHost.init(gpa, "dev-a", "Mac");
    defer host.deinit();
    const sub = try open(&host, 7, "\x00stream:test");
    try std.testing.expect(sendLocked(&host, sub, "{\"n\":1}"));
    try std.testing.expectEqual(@as(usize, 1), host.pushed_frames.items.len);
    try std.testing.expectEqualStrings("{\"n\":1}", host.pushed_frames.items[0].item_json);
    // A chat broadcast never reaches the token entry.
    try host.broadcastWatch(.queue, "chat-1", "{}");
    try std.testing.expectEqual(@as(usize, 1), host.pushed_frames.items.len);
    host.cancelWatch(7);
    try std.testing.expect(!sendLocked(&host, sub, "{\"n\":2}"));
    try std.testing.expectEqual(@as(usize, 1), host.pushed_frames.items.len);
}

test "done writes the end frame to the socket and drops the token" {
    const gpa = std.testing.allocator;
    var host = try EngineHost.init(gpa, "dev-a", "Mac");
    defer host.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    host.live_ws_writer = &out.writer;
    const sub = try open(&host, 9, "\x00stream:test");
    host.live_ws_writer = null;
    try std.testing.expect(sendLocked(&host, sub, "{\"a\":true}"));
    doneLocked(&host, sub);
    try std.testing.expect(!aliveLocked(&host, sub));
    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{\"id\":9,\"item\":{\"a\":true}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{\"id\":9,\"done\":true}") != null);
}
