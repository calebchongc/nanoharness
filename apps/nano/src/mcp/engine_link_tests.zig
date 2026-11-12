//! `engine_link.WsEngine` against an in-process WebSocket server on a
//! loopback port the test owns (never the engine's): concurrent calls,
//! a connection dropped mid-call, reconnects, reader shutdown, a send that
//! blocks while replies arrive, and watches that really wait for an event.
//! Every wait here is bounded: calls by the link's own deadline, threads by
//! `joinWithin`.
const std = @import("std");
const json = std.json;
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ws = @import("../ws.zig");
const link = @import("engine_link.zig");
const tools = @import("tools.zig");
const peer = @import("peer.zig");
const bots = @import("bots.zig");
const u = @import("util.zig");
const Value = json.Value;

const io = testing.io;

fn nowMs() i64 {
    return @intCast(Io.Clock.awake.now(io).toMilliseconds());
}

fn sleepMs(n: i64) void {
    Io.sleep(io, .fromMilliseconds(n), .awake) catch {};
}

/// What the scripted engine does with each request.
const Mode = enum {
    /// Holds calls until `batch` have arrived, then answers them newest
    /// first, each echoing its own `n`.
    echo_reversed,
    /// The first connection drops on its first call; later ones answer.
    drop_first,
    /// Every connection drops on its first call.
    drop_always,
    /// Answers, then closes the connection.
    answer_then_close,
    /// On `Slow`: stops reading, answers after 300 ms, and reads again
    /// only once the test says the answer arrived (or after 4 s).
    stall_reads,
    /// A small engine for the tools: chats, a session that goes from
    /// working to idle 400 ms later, and an empty transcript.
    watch,
};

const Peer = struct {
    server: *TestServer,
    index: usize,
    stream: net.Stream,
    rd: net.Stream.Reader = undefined,
    wr: net.Stream.Writer = undefined,
    rbuf: [64 * 1024]u8 = undefined,
    wbuf: [64 * 1024]u8 = undefined,
    write_lock: Io.Mutex = .init,
    thread: ?std.Thread = null,

    fn send(p: *Peer, text: []const u8) void {
        p.write_lock.lockUncancelable(io);
        defer p.write_lock.unlock(io);
        ws.writeFrame(&p.wr.interface, .text, text, .{ 0, 0, 0, 0 }) catch return;
        p.wr.interface.flush() catch {};
    }

    fn sendf(p: *Peer, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        p.send(std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    fn close(p: *Peer) void {
        p.stream.shutdown(io, .both) catch {};
    }

    fn handshake(p: *Peer) !void {
        const r = &p.rd.interface;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (line.len <= 2) break;
        }
        try p.wr.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: synthetic\r\n\r\n");
        try p.wr.interface.flush();
    }

    fn run(p: *Peer) void {
        const gpa = testing.allocator;
        p.handshake() catch return;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        while (true) {
            const op = ws.readMessageFrom(gpa, &p.rd.interface, &msg, p, pong) catch return;
            if (op != .text) continue;
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const frame = json.parseFromSliceLeaky(Value, arena.allocator(), msg.items, .{}) catch continue;
            const id: u64 = @intCast(u.int(frame, "id") orelse continue);
            if (u.boolean(frame, "cancel") orelse false) {
                p.server.note(.cancel, id);
                continue;
            }
            p.server.note(.call, id);
            if (!p.server.handle(p, id, u.str(frame, "method") orelse "", u.get(frame, "params") orelse .null)) {
                p.close();
                return;
            }
        }
    }

    fn pong(_: *Peer, _: []const u8) void {}
};

const TestServer = struct {
    listener: net.Server,
    port: u16,
    mode: Mode,
    batch: usize = 4,
    accept_thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    stopping: bool = false,
    peers: std.ArrayList(*Peer) = .empty,
    calls: usize = 0,
    cancels: usize = 0,
    held: std.ArrayList(struct { p: *Peer, id: u64, n: i64 }) = .empty,
    slow_received: std.atomic.Value(bool) = .init(false),
    slow_answered: std.atomic.Value(bool) = .init(false),

    fn start(self: *TestServer, mode: Mode) !void {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{ .listener = try addr.listen(io, .{ .reuse_address = true }), .port = 0, .mode = mode };
        self.port = self.listener.socket.address.getPort();
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn accepted(self: *TestServer) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.peers.items.len;
    }

    fn count(self: *TestServer, what: enum { call, cancel }) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return if (what == .call) self.calls else self.cancels;
    }

    fn note(self: *TestServer, what: enum { call, cancel }, _: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (what == .call) self.calls += 1 else self.cancels += 1;
    }

    fn acceptLoop(self: *TestServer) void {
        while (true) {
            const stream = self.listener.accept(io) catch return;
            self.mutex.lockUncancelable(io);
            if (self.stopping) {
                self.mutex.unlock(io);
                stream.close(io);
                return;
            }
            const p = testing.allocator.create(Peer) catch {
                self.mutex.unlock(io);
                stream.close(io);
                continue;
            };
            p.* = .{ .server = self, .index = self.peers.items.len, .stream = stream };
            p.rd = net.Stream.Reader.init(stream, io, &p.rbuf);
            p.wr = net.Stream.Writer.init(stream, io, &p.wbuf);
            self.peers.append(testing.allocator, p) catch {};
            p.thread = std.Thread.spawn(.{}, Peer.run, .{p}) catch null;
            self.mutex.unlock(io);
        }
    }

    /// Answers one call; false closes the connection.
    fn handle(self: *TestServer, p: *Peer, id: u64, method: []const u8, params: Value) bool {
        const eq = std.mem.eql;
        switch (self.mode) {
            .echo_reversed => {
                self.mutex.lockUncancelable(io);
                self.held.append(testing.allocator, .{ .p = p, .id = id, .n = u.int(params, "n") orelse -1 }) catch {};
                const ready = self.held.items.len == self.batch;
                self.mutex.unlock(io);
                if (!ready) return true;
                var k = self.held.items.len;
                while (k > 0) {
                    k -= 1;
                    const h = self.held.items[k];
                    h.p.sendf("{{\"id\":{d},\"ok\":{{\"n\":{d}}}}}", .{ h.id, h.n });
                }
                return true;
            },
            .drop_first, .drop_always => {
                if (self.mode == .drop_always or p.index == 0) return false;
                p.sendf("{{\"id\":{d},\"ok\":{{\"connection\":{d}}}}}", .{ id, p.index });
                return true;
            },
            .answer_then_close => {
                p.sendf("{{\"id\":{d},\"ok\":{{\"connection\":{d}}}}}", .{ id, p.index });
                return false;
            },
            .stall_reads => {
                if (!eq(u8, method, "Slow")) {
                    const pad: []const u8 = u.str(params, "pad") orelse "";
                    p.sendf("{{\"id\":{d},\"ok\":{{\"bytes\":{d}}}}}", .{ id, pad.len });
                    return true;
                }
                self.slow_received.store(true, .release);
                // Not reading now: a large frame from the client backs up.
                sleepMs(300);
                p.sendf("{{\"id\":{d},\"ok\":{{\"slow\":true}}}}", .{id});
                const until = nowMs() + 4000;
                while (!self.slow_answered.load(.acquire) and nowMs() < until) sleepMs(5);
                return true;
            },
            .watch => {
                if (eq(u8, method, "WatchChats")) {
                    p.sendf("{{\"id\":{d},\"item\":[{{\"id\":\"chat-wait-1\",\"title\":\"Waiter\",\"deviceId\":\"dev-x\",\"archived\":false}}]}}", .{id});
                } else if (eq(u8, method, "WatchSessions")) {
                    p.sendf("{{\"id\":{d},\"item\":[{{\"chatId\":\"chat-wait-1\",\"deviceId\":\"dev-x\",\"status\":\"working\",\"lastCompletedTurn\":8,\"updatedAt\":\"2026-11-10T00:00:01Z\"}}]}}", .{id});
                    sleepMs(400);
                    p.sendf("{{\"id\":{d},\"item\":[{{\"chatId\":\"chat-wait-1\",\"deviceId\":\"dev-x\",\"status\":\"idle\",\"lastCompletedTurn\":9,\"updatedAt\":\"2026-11-10T00:00:02Z\"}}]}}", .{id});
                } else if (eq(u8, method, "WatchDocMessages")) {
                    p.sendf("{{\"id\":{d},\"item\":{{\"reset\":[]}}}}", .{id});
                } else {
                    p.sendf("{{\"id\":{d},\"err\":\"unknown method: {s}\"}}", .{ id, method });
                }
                return true;
            },
        }
    }

    fn stop(self: *TestServer) void {
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.mutex.unlock(io);
        // Wake the accept with a connection of our own.
        if (net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
            if (addr.connect(io, .{ .mode = .stream })) |c| c.close(io) else |_| {}
        } else |_| {}
        if (self.accept_thread) |t| t.join();
        self.slow_answered.store(true, .release);
        for (self.peers.items) |p| p.close();
        for (self.peers.items) |p| {
            if (p.thread) |t| t.join();
            p.stream.close(io);
            testing.allocator.destroy(p);
        }
        self.peers.deinit(testing.allocator);
        self.held.deinit(testing.allocator);
        self.listener.deinit(io);
    }
};

/// Runs `func(args)` on a thread and waits at most `ms` for it; a hang is a
/// test failure, not a stuck run (the thread is then left behind).
fn joinWithin(ms: i64, comptime func: anytype, args: anytype) !void {
    const Ctx = struct {
        done: std.atomic.Value(bool) = .init(false),
        fn run(ctx: *@This(), a: @TypeOf(args)) void {
            @call(.auto, func, a);
            ctx.done.store(true, .release);
        }
    };
    const ctx = try testing.allocator.create(Ctx);
    ctx.* = .{};
    const t = try std.Thread.spawn(.{}, Ctx.run, .{ ctx, args });
    const until = nowMs() + ms;
    while (!ctx.done.load(.acquire)) {
        if (nowMs() > until) {
            t.detach();
            return error.TestTimedOut;
        }
        sleepMs(5);
    }
    t.join();
    testing.allocator.destroy(ctx);
}

/// The link's live reader threads (an older link kept one per dial).
fn liveReaders(l: *link.WsEngine) usize {
    return if (comptime @hasDecl(link.WsEngine, "readerCount")) l.readerCount() else l.readers.items.len;
}

fn setCallTimeout(l: *link.WsEngine, ms: i64) void {
    if (comptime @hasField(link.WsEngine, "call_timeout_ms")) l.call_timeout_ms = ms;
}

test "mcp engine link (live): concurrent calls each get their own reply, answered out of order" {
    var srv: TestServer = undefined;
    try srv.start(.echo_reversed);
    defer srv.stop();
    var l = link.WsEngine.init(testing.allocator, io, srv.port);
    defer l.deinit();
    setCallTimeout(&l, 5000);
    const Caller = struct {
        fn run(lk: *link.WsEngine, n: usize, got: *?i64) void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var buf: [32]u8 = undefined;
            const params = std.fmt.bufPrint(&buf, "{{\"n\":{d}}}", .{n}) catch return;
            const r = lk.engine().call(arena.allocator(), "Echo", params) catch return;
            if (r == .ok) got.* = u.int(r.ok, "n");
        }
    };
    var got: [4]?i64 = .{ null, null, null, null };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Caller.run, .{ &l, k + 10, &got[k] });
    // Each call ends by its reply or its 5 s deadline.
    for (threads) |t| t.join();
    for (got, 0..) |g, k| try testing.expectEqual(@as(?i64, @intCast(k + 10)), g);
    try testing.expectEqual(@as(usize, 1), srv.accepted());
}

test "mcp engine link (live): a connection dropped mid-call is redialed once; dropped twice, the call fails" {
    {
        var srv: TestServer = undefined;
        try srv.start(.drop_first);
        defer srv.stop();
        var l = link.WsEngine.init(testing.allocator, io, srv.port);
        defer l.deinit();
        setCallTimeout(&l, 5000);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try l.engine().call(arena.allocator(), "LocalDevice", "{}");
        try testing.expectEqual(@as(?i64, 1), u.int(r.ok, "connection"));
        try testing.expectEqual(@as(usize, 2), srv.accepted());
    }
    {
        var srv: TestServer = undefined;
        try srv.start(.drop_always);
        defer srv.stop();
        var l = link.WsEngine.init(testing.allocator, io, srv.port);
        defer l.deinit();
        setCallTimeout(&l, 5000);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try l.engine().call(arena.allocator(), "LocalDevice", "{}");
        try testing.expectEqualStrings("LocalDevice: connection closed", r.err);
        try testing.expectEqual(@as(usize, 2), srv.accepted());
    }
}

test "mcp engine link (live): reconnects keep one reader thread, not one per dial" {
    var srv: TestServer = undefined;
    try srv.start(.answer_then_close);
    defer srv.stop();
    var l = link.WsEngine.init(testing.allocator, io, srv.port);
    defer l.deinit();
    setCallTimeout(&l, 5000);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..6) |_| {
        const r = try l.engine().call(arena.allocator(), "LocalDevice", "{}");
        try testing.expect(r == .ok);
        // The closed connection's reader ends on its own.
        const until = nowMs() + 2000;
        while (liveReaders(&l) > 1 and nowMs() < until) sleepMs(5);
        try testing.expect(liveReaders(&l) <= 1);
    }
    try testing.expect(srv.accepted() >= 6);
}

test "mcp engine link (live): closing the link wakes its blocked reader and waits for it" {
    var srv: TestServer = undefined;
    try srv.start(.watch);
    defer srv.stop();
    const l = try testing.allocator.create(link.WsEngine);
    defer testing.allocator.destroy(l);
    l.* = link.WsEngine.init(testing.allocator, io, srv.port);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The connection stays open: its reader is blocked reading.
    const r = try l.engine().call(arena.allocator(), "WatchChats", "{}");
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(usize, 1), liveReaders(l));
    try joinWithin(5000, link.WsEngine.deinit, .{l});
    try testing.expectEqual(@as(usize, 0), if (comptime @hasField(link.WsEngine, "live_readers")) l.live_readers else 0);
}

test "mcp engine link (live): a reply arrives while another call's large send is blocked" {
    var srv: TestServer = undefined;
    try srv.start(.stall_reads);
    defer srv.stop();
    var l = link.WsEngine.init(testing.allocator, io, srv.port);
    defer l.deinit();
    setCallTimeout(&l, 15_000);
    const Slow = struct {
        fn run(lk: *link.WsEngine, done_ms: *i64, ok: *bool) void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const r = lk.engine().call(arena.allocator(), "Slow", "{}") catch return;
            ok.* = r == .ok;
            done_ms.* = nowMs();
        }
    };
    const Big = struct {
        fn run(lk: *link.WsEngine, ok: *bool) void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const pad = a.alloc(u8, 16 * 1024 * 1024) catch return;
            @memset(pad, 'p');
            const params = std.fmt.allocPrint(a, "{{\"pad\":\"{s}\"}}", .{pad}) catch return;
            const r = lk.engine().call(a, "Big", params) catch return;
            ok.* = r == .ok and u.int(r.ok, "bytes") == 16 * 1024 * 1024;
        }
    };
    var slow_done: i64 = 0;
    var slow_ok = false;
    var big_ok = false;
    const started = nowMs();
    const t1 = try std.Thread.spawn(.{}, Slow.run, .{ &l, &slow_done, &slow_ok });
    {
        const until = nowMs() + 3000;
        while (!srv.slow_received.load(.acquire) and nowMs() < until) sleepMs(2);
    }
    // 16 MiB to an engine that is not reading: this send blocks.
    const t2 = try std.Thread.spawn(.{}, Big.run, .{ &l, &big_ok });
    {
        const until = nowMs() + 6000;
        while (@atomicLoad(i64, &slow_done, .acquire) == 0 and nowMs() < until) sleepMs(5);
    }
    const slow_latency = @atomicLoad(i64, &slow_done, .acquire) - started;
    srv.slow_answered.store(true, .release);
    t1.join();
    t2.join();
    try testing.expect(slow_ok);
    try testing.expect(big_ok);
    // Answered at 300 ms; with the lock held across the blocked send, it
    // would wait until the engine read again (4 s).
    try testing.expect(slow_latency > 0 and slow_latency < 2500);
}

test "mcp engine link (live): a unary call without a reply ends at its deadline" {
    var srv: TestServer = undefined;
    try srv.start(.echo_reversed);
    srv.batch = 100; // never answers
    defer srv.stop();
    var l = link.WsEngine.init(testing.allocator, io, srv.port);
    defer l.deinit();
    if (comptime !@hasField(link.WsEngine, "call_timeout_ms")) return error.TestUnexpectedResult;
    setCallTimeout(&l, 300);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t0 = nowMs();
    const r = try l.engine().call(arena.allocator(), "Echo", "{\"n\":1}");
    try testing.expectEqualStrings("Echo: no reply from the engine within 1s", r.err);
    try testing.expect(nowMs() - t0 < 3000);
}

test "mcp engine link (live): a watch blocks until the engine pushes, and closing it cancels" {
    var srv: TestServer = undefined;
    try srv.start(.watch);
    defer srv.stop();
    var l = link.WsEngine.init(testing.allocator, io, srv.port);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub = switch (try l.engine().subscribe(a, "WatchSessions", "{}")) {
        .sub => |s| s,
        .err => return error.TestUnexpectedResult,
    };
    const first = try sub.next(a, 5000);
    try testing.expectEqualStrings("working", u.str(first.item.array.items[0], "status").?);
    const t0 = nowMs();
    const second = try sub.next(a, 5000);
    const waited = nowMs() - t0;
    try testing.expectEqualStrings("idle", u.str(second.item.array.items[0], "status").?);
    // It waited for the push (sent 400 ms after the first item).
    try testing.expect(waited >= 250);
    // Nothing more: the deadline passes.
    try testing.expect((try sub.next(a, 100)) == .timeout);
    sub.close();
    const until = nowMs() + 2000;
    while (srv.count(.cancel) == 0 and nowMs() < until) sleepMs(5);
    try testing.expectEqual(@as(usize, 1), srv.count(.cancel));
}

test "mcp engine link (live): wait_for_turn blocks on the engine's watch until the turn ends" {
    var srv: TestServer = undefined;
    try srv.start(.watch);
    defer srv.stop();
    var l = link.WsEngine.init(testing.allocator, io, srv.port);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const NoPeer = struct {
        fn send(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!peer.PeerSend.SendResult {
            return .{ .err = "unused" };
        }
        fn bot(_: *anyopaque, _: Allocator, _: []const u8, _: []const []const u8) anyerror!bots.BotCli.Result {
            return .{ .err = "unused" };
        }
    };
    var unused: u8 = 0;
    var t: tools.Tools = .{
        .io = io,
        .engine = l.engine(),
        .origin = .{},
        .peer = .{ .ptr = &unused, .send_fn = NoPeer.send },
        .relay = .{ .io = io, .dir = null },
        .bots = .{ .ptr = &unused, .bot_fn = NoPeer.bot },
        .git = null,
    };
    const t0 = nowMs();
    const out = try t.call(a, "wait_for_turn", try json.parseFromSliceLeaky(Value, a, "{\"chat\":\"Waiter\",\"timeout_secs\":10}", .{}));
    const waited = nowMs() - t0;
    const turn = u.get(out.ok, "turn").?;
    try testing.expectEqualStrings("completed", u.str(turn, "outcome").?);
    try testing.expectEqualStrings("idle", u.str(turn, "status").?);
    try testing.expect(waited >= 250 and waited < 8000);
}
