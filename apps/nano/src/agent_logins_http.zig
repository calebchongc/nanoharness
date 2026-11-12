//! One HTTP/1.1 request for the login registry, std-only (`std.http.Client`)
//! with a whole-exchange deadline: a watchdog shuts the socket down when the
//! deadline passes (reqwest's per-request timeout in the Rust service).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Method = enum { GET, POST };

pub const Request = struct {
    method: Method = .GET,
    url: []const u8,
    bearer: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// Sent with `content-type: application/json`.
    json_body: ?[]const u8 = null,
    timeout_ms: u32 = 8000,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn ok(r: Response) bool {
        return r.status >= 200 and r.status < 300;
    }
};

/// `Connect`: the connection itself failed (reqwest `is_connect`).
pub const Error = error{ Connect, Timeout, Failed, OutOfMemory };

const Watchdog = struct {
    io: Io,
    stream: std.Io.net.Stream,
    ms: u32,
    done: Io.Event = .unset,
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn arm(self: *Watchdog) void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    fn run(self: *Watchdog) void {
        self.done.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(self.ms), .clock = .awake } }) catch {
            self.fired.store(true, .release);
            self.stream.shutdown(self.io, .both) catch {};
        };
    }

    fn disarm(self: *Watchdog) bool {
        self.done.set(self.io);
        if (self.thread) |t| t.join();
        self.thread = null;
        return self.fired.load(.acquire);
    }
};

/// Send `req`; the body is read whatever the status. Allocations go to `a`.
pub fn send(a: Allocator, io: Io, req: Request) Error!Response {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse(req.url) catch return error.Failed;
    var auth: ?[]u8 = null;
    if (req.bearer) |b| auth = std.fmt.allocPrint(a, "Bearer {s}", .{b}) catch return error.OutOfMemory;
    var r = client.request(switch (req.method) {
        .GET => .GET,
        .POST => .POST,
    }, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = if (auth) |v| .{ .override = v } else .default,
            .content_type = if (req.json_body != null) .{ .override = "application/json" } else .default,
            .accept_encoding = .omit,
        },
        .extra_headers = req.headers,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Connect,
    };
    defer r.deinit();
    var dog: Watchdog = .{ .io = io, .stream = r.connection.?.stream_reader.stream, .ms = req.timeout_ms };
    dog.arm();
    var body: Io.Writer.Allocating = .init(a);
    const status = exchange(&r, req.json_body, &body.writer);
    if (dog.disarm()) return error.Timeout;
    const code = status catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    return .{ .status = code, .body = body.toOwnedSlice() catch return error.OutOfMemory };
}

fn exchange(r: *std.http.Client.Request, payload: ?[]const u8, out: *Io.Writer) !u16 {
    if (payload) |p| {
        r.transfer_encoding = .{ .content_length = p.len };
        var bw = try r.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(p);
        try bw.end();
        try r.connection.?.flush();
    } else {
        try r.sendBodiless();
    }
    var response = try r.receiveHead(&.{});
    var transfer: [64]u8 = undefined;
    const reader = response.reader(&transfer);
    _ = reader.streamRemaining(out) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return @backingInt(response.head.status);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "agent_logins_http: a refused connection is Connect, a silent server times out" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Bind then close to find a port nobody listens on.
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();
    srv.deinit(io);
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/x", .{port});
    try testing.expectError(error.Connect, send(arena.allocator(), io, .{ .url = url, .timeout_ms = 2000 }));

    var silent = try addr.listen(io, .{ .reuse_address = true });
    defer silent.deinit(io);
    const url2 = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/x", .{silent.socket.address.getPort()});
    try testing.expectError(error.Timeout, send(arena.allocator(), io, .{ .url = url2, .timeout_ms = 300 }));
}
