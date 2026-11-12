//! Another device's chat, as this engine keeps it: the host publishes the
//! transcript as the chat's tail sidecar (`PUT /chat2/:chatId/tail`, served
//! verbatim by the Worker's ChatRoom) and announces the change with the
//! chat's registry rows (`chats`, `sessions`). This engine reads Loro rows
//! from no one, so the tail is its only copy of a remote transcript.
//!
//! - a changed row for a chat another device hosts drops the cached tail, so
//!   the next prefetch (`prefetchRecentChatTailsUnlocked`) fetches the new
//!   one and pushes it to the chat's watchers;
//! - the host uploads its dirty tails before it pushes the rows that announce
//!   them (`syncFromEdgeRegistryUnlocked`), so a reader that sees the row
//!   never fetches the tail from before it.
const std = @import("std");
const engine_host = @import("engine_host.zig");

/// A registry row for `chat_id` arrived from the edge (not the saved copy an
/// engine replays at start, whose tail is as old as the row): drop its
/// cached tail when another device hosts it.
pub fn rowChanged(host: *engine_host.EngineHost, chat_id: []const u8) void {
    for (host.chats.items) |c| if (std.mem.eql(u8, c.id, chat_id)) {
        if (c.device_id.len > 0 and !std.mem.eql(u8, c.device_id, host.device_id)) host.invalidateCachedTail(chat_id);
        return;
    };
}

/// Whether this engine holds `chat_id`'s transcript itself. An open chat
/// has a doc even when it is empty (`WatchDocMessages` makes one for a remote
/// chat it shows from the tail): that one still reads the edge's tail.
pub fn hasLocalTranscript(host: *engine_host.EngineHost, chat_id: []const u8) bool {
    if (host.docs.getPtr(chat_id)) |doc| return doc.messages.items.len > 0;
    return host.store.loadSnapshot(chat_id) != null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const json = std.json;
const Io = std.Io;

fn chatRow(id: []const u8, device: []const u8, title: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator,
        \\{{"seq":{d},"rows":[{{"kind":"chats","id":"{s}","deleted":false,"fields":{{"id":"{s}","deviceId":"{s}","title":"{s}","archived":false,"createdAt":1794000000000,"lastMessageAt":1794000000000,"config":{{"harness":"mock"}}}},"clocks":{{}}}}]}}
    , .{ title.len, id, id, device, title });
}

test "remote tail: a changed row of another device's chat drops its cached tail; this device's own stays" {
    const gpa = testing.allocator;
    var host = try engine_host.EngineHost.init(gpa, "dev-reader", "Reader");
    defer host.deinit();
    for ([_][2][]const u8{ .{ "chat-remote", "dev-host" }, .{ "chat-own", "dev-reader" } }) |c| {
        const body = try chatRow(c[0], c[1], "first");
        defer gpa.free(body);
        _ = host.applyRegistryResponseJson("org-synthetic", body, true);
        _ = host.storeCachedTailInMemoryOwned(c[0], try gpa.dupe(u8, "[{\"id\":\"m1\",\"role\":\"user\",\"parts\":[]}]"), false);
        try testing.expect(host.lookupCachedTailJson(c[0]) != null);
    }
    for ([_][2][]const u8{ .{ "chat-remote", "dev-host" }, .{ "chat-own", "dev-reader" } }) |c| {
        const body = try chatRow(c[0], c[1], "second turn");
        defer gpa.free(body);
        _ = host.applyRegistryResponseJson("org-synthetic", body, true);
    }
    // The host's transcript moved on: fetch it again.
    try testing.expect(host.lookupCachedTailJson("chat-remote") == null);
    try testing.expect(host.lookupCachedTailJson("chat-own") != null);
}

/// A loopback edge that answers every request 200 and records "METHOD path".
const RecordingEdge = struct {
    srv: Io.net.Server,
    port: u16,
    io: Io,
    lock: Io.Mutex = .init,
    seen: std.ArrayList([]u8) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *RecordingEdge, io: Io) !void {
        const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{ .srv = try addr.listen(io, .{ .reuse_address = true }), .port = 0, .io = io };
        self.port = self.srv.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *RecordingEdge) void {
        while (!self.stop.load(.acquire)) {
            var stream = self.srv.accept(self.io) catch return;
            defer stream.close(self.io);
            var rbuf: [8192]u8 = undefined;
            var wbuf: [512]u8 = undefined;
            var reader = stream.reader(self.io, &rbuf);
            var writer = stream.writer(self.io, &wbuf);
            const req = reader.interface.takeDelimiterInclusive('\n') catch continue;
            var it = std.mem.tokenizeScalar(u8, req, ' ');
            const method = it.next() orelse continue;
            const target = it.next() orelse continue;
            const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
            var len: usize = 0;
            while (reader.interface.takeDelimiterInclusive('\n')) |line| {
                const t = std.mem.trimEnd(u8, line, "\r\n");
                if (t.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(t, "content-length:")) len = std.fmt.parseInt(usize, std.mem.trim(u8, t[15..], " "), 10) catch 0;
            } else |_| continue;
            reader.interface.discardAll(len) catch continue;
            self.lock.lockUncancelable(self.io);
            if (std.fmt.allocPrint(testing.allocator, "{s} {s}", .{ method, path })) |line| self.seen.append(testing.allocator, line) catch testing.allocator.free(line) else |_| {}
            self.lock.unlock(self.io);
            const body = if (std.mem.indexOf(u8, path, "/rows") != null) "{\"seq\":0,\"rows\":[]}" else "{\"ok\":true}";
            writer.interface.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ body.len, body }) catch continue;
            writer.interface.flush() catch continue;
        }
    }

    fn deinit(self: *RecordingEdge) void {
        self.stop.store(true, .release);
        if (Io.net.IpAddress.parseIp4("127.0.0.1", self.port)) |a| {
            if (a.connect(self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.srv.deinit(self.io);
        for (self.seen.items) |l| testing.allocator.free(l);
        self.seen.deinit(testing.allocator);
    }

    fn count(self: *RecordingEdge, needle: []const u8) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var n: usize = 0;
        for (self.seen.items) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) n += 1;
        }
        return n;
    }

    fn indexOf(self: *RecordingEdge, needle: []const u8) ?usize {
        for (self.seen.items, 0..) |l, i| if (std.mem.indexOf(u8, l, needle) != null) return i;
        return null;
    }
};

test "remote tail: the host uploads a chat's tail before the registry rows that announce it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var edge: RecordingEdge = undefined;
    try edge.start(io);
    defer edge.deinit();
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{edge.port});
    defer gpa.free(url);

    var host = try engine_host.EngineHost.init(gpa, "dev-host", "Host");
    defer host.deinit();
    host.io = io;
    try host.auth.configureCodegraff(url, null, null, null);
    try host.auth.signInWithKey("ada-synthetic@org-synthetic");
    {
        var p = try json.parseFromSlice(json.Value, gpa, "{\"op\":\"createChat\",\"chatId\":\"chat-order\",\"config\":{\"harness\":\"mock\"}}", .{});
        defer p.deinit();
        gpa.free((try host.handle("Mutate", p.value)).unary_json);
    }
    try (try host.getOrCreateDoc("chat-order")).appendUserMessage("m-order-1", "part-u", "a synthetic prompt", host.nowMs());
    host.markChatTailDirty("chat-order");
    _ = host.syncFromEdgeRegistryUnlocked(io);

    const tail = edge.indexOf("PUT /chat2/chat-order/tail") orelse return error.NoTailUpload;
    const push = edge.indexOf("/push") orelse return error.NoRegistryPush;
    try testing.expect(tail < push);
}

test "remote tail: a remote chat open on this device (an empty local doc) still fetches the host's new tail" {
    const gpa = testing.allocator;
    const io = testing.io;
    var edge: RecordingEdge = undefined;
    try edge.start(io);
    defer edge.deinit();
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{edge.port});
    defer gpa.free(url);

    var host = try engine_host.EngineHost.init(gpa, "dev-reader", "Reader");
    defer host.deinit();
    host.io = io;
    try host.auth.configureCodegraff(url, null, null, null);
    try host.auth.signInWithKey("ada-synthetic@org-synthetic");
    const body = try chatRow("chat-open", "dev-host", "first");
    defer gpa.free(body);
    _ = host.applyRegistryResponseJson("org-synthetic", body, false);
    // Opening the chat here makes an empty doc for it.
    _ = try host.getOrCreateDoc("chat-open");
    host.prefetchRecentChatTailsUnlocked(io, 16);
    try testing.expectEqual(@as(usize, 1), edge.count("GET /chat2/chat-open/tail"));
}
