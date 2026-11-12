//! The engine's accept loop: one thread per client until the engine stops.
//!
//! `StopEngine` stops it at once: the client that stopped the engine wakes
//! the blocked `accept` by connecting to the listener, so the loop doesn't
//! wait for some later connection. An `accept` that keeps failing (out of
//! descriptors, say) backs off instead of spinning a core.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

pub const max_backoff_ms: u64 = 1000;

/// The pause after `failures` accepts in a row failed: 10 ms, doubling, at most 1 s.
pub fn backoffMs(failures: u32) u64 {
    if (failures == 0) return 0;
    const shift: u6 = @intCast(@min(failures - 1, 10));
    return @min(max_backoff_ms, @as(u64, 10) << shift);
}

/// Connect to `addr` and hang up: wakes an `accept` blocked on it.
pub fn wake(io: Io, addr: net.IpAddress) void {
    if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
}

/// Serves `server` until `host.stop_requested`. `serveFn` runs one client
/// (`serveSocket(gpa, io, host, &stream)`); the stream is closed after it.
pub fn serve(
    gpa: Allocator,
    io: Io,
    server: *net.Server,
    host: anytype,
    comptime serveFn: anytype,
) void {
    const Host = @TypeOf(host);
    const Worker = struct {
        gpa: Allocator,
        io: Io,
        host: Host,
        stream: net.Stream,
        listener: net.IpAddress,

        fn run(w: *@This()) void {
            const me = w.*;
            me.gpa.destroy(w);
            var stream = me.stream;
            serveFn(me.gpa, me.io, me.host, &stream) catch |err| {
                std.log.debug("harness-engine: client ended: {t}", .{err});
            };
            stream.close(me.io);
            if (me.host.stop_requested) wake(me.io, me.listener);
        }
    };
    const listener = server.socket.address;
    var failures: u32 = 0;
    while (!host.stop_requested) {
        const stream = server.accept(io) catch {
            failures +|= 1;
            Io.sleep(io, .fromMilliseconds(@intCast(backoffMs(failures))), .awake) catch {};
            continue;
        };
        failures = 0;
        if (host.stop_requested) {
            stream.close(io);
            break;
        }
        const w = gpa.create(Worker) catch {
            stream.close(io);
            continue;
        };
        w.* = .{ .gpa = gpa, .io = io, .host = host, .stream = stream, .listener = listener };
        if (std.Thread.spawn(.{}, Worker.run, .{w})) |th| {
            th.detach();
        } else |_| {
            Worker.run(w);
        }
    }
}

const testing = std.testing;

test "fix-sec 17: accept backs off on repeated failures" {
    try testing.expectEqual(@as(u64, 0), backoffMs(0));
    try testing.expectEqual(@as(u64, 10), backoffMs(1));
    try testing.expectEqual(@as(u64, 20), backoffMs(2));
    try testing.expectEqual(@as(u64, 640), backoffMs(7));
    try testing.expectEqual(max_backoff_ms, backoffMs(8));
    try testing.expectEqual(max_backoff_ms, backoffMs(std.math.maxInt(u32)));
}

const FakeHost = struct {
    stop_requested: bool = false,
    served: std.atomic.Value(u32) = .init(0),
};

/// A client that sends `S` stops the engine, as `StopEngine` does.
fn fakeServe(_: Allocator, io: Io, host: *FakeHost, stream: *net.Stream) anyerror!void {
    var buf: [16]u8 = undefined;
    var rd = stream.reader(io, &buf);
    const b = try rd.interface.takeByte();
    _ = host.served.fetchAdd(1, .acq_rel);
    if (b == 'S') host.stop_requested = true;
}

test "fix-sec 17: a client that stops the engine ends the accept loop without another connection" {
    const io = testing.io;
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var host: FakeHost = .{};
    var done: Io.Event = .unset;
    const Loop = struct {
        fn run(s: *net.Server, h: *FakeHost, d: *Io.Event) void {
            serve(testing.allocator, testing.io, s, h, fakeServe);
            d.set(testing.io);
        }
    };
    const loop = try std.Thread.spawn(.{}, Loop.run, .{ &server, &host, &done });

    // An ordinary client is served and the loop goes on.
    const c1 = try server.socket.address.connect(io, .{ .mode = .stream });
    var w1buf: [8]u8 = undefined;
    var w1 = c1.writer(io, &w1buf);
    try w1.interface.writeAll("x");
    try w1.interface.flush();
    c1.close(io);
    // Then one that stops it.
    const c2 = try server.socket.address.connect(io, .{ .mode = .stream });
    var w2buf: [8]u8 = undefined;
    var w2 = c2.writer(io, &w2buf);
    try w2.interface.writeAll("S");
    try w2.interface.flush();
    defer c2.close(io);

    const ended = if (done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } })) |_| true else |_| false;
    if (!ended) {
        // Let the test end either way; the assertion below reports it.
        host.stop_requested = true;
        wake(io, server.socket.address);
    }
    loop.join();
    try testing.expect(ended);
    try testing.expectEqual(@as(u32, 2), host.served.load(.acquire));
}
