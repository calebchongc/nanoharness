//! The loopback HTTP/1.1 the browse link speaks: one `POST` to
//! `http://127.0.0.1:<port><path>` with a deadline (Rust's `reqwest` client
//! with `.no_proxy()` and `timeout(180s)`), and, for tests and a future relay,
//! reading a request and writing an answer the way `proxy.rs`'s
//! `read_request`/`response` do.
//!
//! Every exchange has a deadline: a helper thread shuts the socket down when
//! it passes, which fails the blocked read or write.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;

pub const Header = struct { name: []const u8, value: []const u8 };

/// The most a browse answer may hold.
pub const max_body: usize = 16 << 20;

/// Ends an exchange that outlives its deadline (`auth_host.SocketWatchdog`'s
/// shape, std-only).
pub const Watchdog = struct {
    io: Io,
    stream: net.Stream,
    ms: u32,
    done: Io.Event = .unset,
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn arm(self: *Watchdog) void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    fn run(self: *Watchdog) void {
        self.done.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(self.ms), .clock = .awake } }) catch {
            self.fired.store(true, .release);
            self.stream.shutdown(self.io, .both) catch {};
        };
    }

    /// Stop watching; true when the deadline had already passed.
    pub fn disarm(self: *Watchdog) bool {
        self.done.set(self.io);
        if (self.thread) |t| t.join();
        self.thread = null;
        return self.fired.load(.acquire);
    }
};

pub const Response = struct {
    status: u16,
    body: []u8,
    /// `X-Signature`, when browse sent one.
    signature: ?[]u8,

    pub fn deinit(self: *Response, gpa: Allocator) void {
        gpa.free(self.body);
        if (self.signature) |s| gpa.free(s);
        self.* = undefined;
    }
};

pub const PostError = error{
    /// Nothing accepted the connection (reqwest's `is_connect()`).
    ConnectFailed,
    /// Writing the request or reading the answer's head failed, or the
    /// deadline passed.
    SendFailed,
    /// The answer's body couldn't be read.
    BodyFailed,
    OutOfMemory,
};

/// `POST http://127.0.0.1:{port}{path}` with a JSON body and `headers`.
pub fn post(gpa: Allocator, io: Io, port: u16, path: []const u8, headers: []const Header, body: []const u8, timeout_ms: u32) PostError!Response {
    const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return error.ConnectFailed;
    const stream = addr.connect(io, .{ .mode = .stream }) catch |e| return switch (e) {
        error.Canceled => error.SendFailed,
        else => error.ConnectFailed,
    };
    defer stream.close(io);
    var dog: Watchdog = .{ .io = io, .stream = stream, .ms = timeout_ms };
    dog.arm();
    const result = exchange(gpa, io, stream, port, path, headers, body);
    if (dog.disarm()) {
        if (result) |r| {
            var late = r;
            late.deinit(gpa);
        } else |_| {}
        return error.SendFailed;
    }
    return result;
}

fn exchange(gpa: Allocator, io: Io, stream: net.Stream, port: u16, path: []const u8, headers: []const Header, body: []const u8) PostError!Response {
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;
    // The Host browse checks (`127.0.0.1:<port>`), and never an Origin.
    w.print("POST {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: */*\r\nContent-Type: application/json\r\n", .{ path, port }) catch return error.SendFailed;
    for (headers) |h| w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.SendFailed;
    w.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return error.SendFailed;
    w.writeAll(body) catch return error.SendFailed;
    w.flush() catch return error.SendFailed;

    const r = &reader.interface;
    const status_line = r.takeDelimiterInclusive('\n') catch return error.SendFailed;
    var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, status_line, "\r\n"), ' ');
    const version = parts.next() orelse return error.SendFailed;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.SendFailed;
    const status = std.fmt.parseInt(u16, parts.next() orelse return error.SendFailed, 10) catch return error.SendFailed;

    var content_length: ?usize = null;
    var chunked = false;
    var signature: ?[]u8 = null;
    errdefer if (signature) |s| gpa.free(s);
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch return error.SendFailed;
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.SendFailed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = std.ascii.findIgnoreCase(value, "chunked") != null;
        } else if (std.ascii.eqlIgnoreCase(name, "x-signature")) {
            if (signature) |old| gpa.free(old);
            signature = try gpa.dupe(u8, value);
        }
    }

    const answer = if (chunked)
        try readChunked(gpa, r)
    else if (content_length) |n| blk: {
        if (n > max_body) return error.BodyFailed;
        const out = try gpa.alloc(u8, n);
        r.readSliceAll(out) catch {
            gpa.free(out);
            return error.BodyFailed;
        };
        break :blk out;
    } else r.allocRemaining(gpa, .limited(max_body)) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BodyFailed,
    };
    return .{ .status = status, .body = answer, .signature = signature };
}

fn readChunked(gpa: Allocator, r: *Io.Reader) PostError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch return error.BodyFailed;
        const size_text = std.mem.trim(u8, std.mem.trimEnd(u8, line, "\r\n"), " \t");
        const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
        const size = std.fmt.parseInt(usize, size_text[0..semi], 16) catch return error.BodyFailed;
        if (size == 0) {
            // Trailers, then the blank line.
            while (true) {
                const t = r.takeDelimiterInclusive('\n') catch return error.BodyFailed;
                if (std.mem.trimEnd(u8, t, "\r\n").len == 0) break;
            }
            return out.toOwnedSlice(gpa);
        }
        if (out.items.len + size > max_body) return error.BodyFailed;
        const start = out.items.len;
        try out.resize(gpa, start + size);
        r.readSliceAll(out.items[start..]) catch return error.BodyFailed;
        _ = r.takeDelimiterInclusive('\n') catch return error.BodyFailed;
    }
}

// ── the serving side (`proxy.rs`'s `read_request` / `response`) ────────────

pub const Request = struct {
    method: []u8,
    path: []u8,
    /// Names lowercased.
    headers: []Header,
    body: []u8,
    arena: std.heap.ArenaAllocator,

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn deinit(self: *Request) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// One request from `r`, or null when the peer closed before sending one.
pub fn readRequest(gpa: Allocator, r: *Io.Reader) !?Request {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const first = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => {
            arena.deinit();
            return null;
        },
        else => return e,
    };
    var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, first, "\r\n"), ' ');
    const method = try a.dupe(u8, parts.next() orelse return error.BadRequest);
    const path = try a.dupe(u8, parts.next() orelse return error.BadRequest);
    var headers: std.ArrayList(Header) = .empty;
    var length: usize = 0;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = try std.ascii.allocLowerString(a, std.mem.trim(u8, trimmed[0..colon], " \t"));
        const value = try a.dupe(u8, std.mem.trim(u8, trimmed[colon + 1 ..], " \t"));
        if (std.mem.eql(u8, name, "content-length")) length = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
        try headers.append(a, .{ .name = name, .value = value });
    }
    if (length > max_body) return error.BadRequest;
    const body = try a.alloc(u8, length);
    try r.readSliceAll(body);
    return .{ .method = method, .path = path, .headers = headers.items, .body = body, .arena = arena };
}

pub fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        else => "Status",
    };
}

/// An answer: status, JSON body, `extra` headers, `Connection: close`.
pub fn writeResponse(w: *Io.Writer, status: u16, body: []const u8, extra: []const Header) !void {
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ status, reason(status), body.len });
    for (extra) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    try w.writeAll("\r\n");
    try w.writeAll(body);
    try w.flush();
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A one-shot loopback server: answers each connection with `answer`
/// (raw bytes) after reading its request, or holds it unanswered.
const OneShot = struct {
    server: net.Server,
    answer: ?[]const u8,
    thread: ?std.Thread = null,
    release: Io.Event = .unset,
    seen_host: [64]u8 = undefined,
    seen_host_len: usize = 0,
    seen_signature_header: bool = false,

    fn run(self: *OneShot) void {
        const io = testing.io;
        const conn = self.server.accept(io) catch return;
        defer conn.close(io);
        var dog: Watchdog = .{ .io = io, .stream = conn, .ms = 5_000 };
        dog.arm();
        defer _ = dog.disarm();
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var rd = conn.reader(io, &rbuf);
        var wr = conn.writer(io, &wbuf);
        var req = (readRequest(testing.allocator, &rd.interface) catch return) orelse return;
        defer req.deinit();
        if (req.header("host")) |h| {
            const n = @min(h.len, self.seen_host.len);
            @memcpy(self.seen_host[0..n], h[0..n]);
            self.seen_host_len = n;
        }
        self.seen_signature_header = req.header("x-signature") != null;
        if (self.answer) |a| {
            wr.interface.writeAll(a) catch return;
            wr.interface.flush() catch return;
        } else {
            self.release.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch {};
        }
    }

    fn start(self: *OneShot) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *OneShot) void {
        self.release.set(testing.io);
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }

    fn port(self: *OneShot) u16 {
        return self.server.socket.address.getPort();
    }
};

fn oneShot(answer: ?[]const u8) !OneShot {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    return .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }), .answer = answer };
}

test "http: a POST reads status, body and X-Signature, and sends browse's Host" {
    var srv = try oneShot("HTTP/1.1 200 OK\r\nx-signature: c2ln\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
    try srv.start();
    defer srv.stop();
    var resp = try post(testing.allocator, testing.io, srv.port(), "/pair", &.{.{ .name = "X-Signature", .value = "abc" }}, "{}", 5_000);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("{}", resp.body);
    try testing.expectEqualStrings("c2ln", resp.signature.?);
    var want: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "127.0.0.1:{d}", .{srv.port()}), srv.seen_host[0..srv.seen_host_len]);
    try testing.expect(srv.seen_signature_header);
}

test "http: chunked and read-to-close answers" {
    {
        var srv = try oneShot("HTTP/1.1 401 Unauthorized\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n{\"a\r\n4\r\n\":1}\r\n0\r\n\r\n");
        try srv.start();
        defer srv.stop();
        var resp = try post(testing.allocator, testing.io, srv.port(), "/x", &.{}, "", 5_000);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 401), resp.status);
        try testing.expectEqualStrings("{\"a\":1}", resp.body);
        try testing.expect(resp.signature == null);
    }
    {
        var srv = try oneShot("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello");
        try srv.start();
        defer srv.stop();
        var resp = try post(testing.allocator, testing.io, srv.port(), "/x", &.{}, "", 5_000);
        defer resp.deinit(testing.allocator);
        try testing.expectEqualStrings("hello", resp.body);
    }
}

test "http: nothing listening is a connect failure; silence fails at the deadline" {
    // A port that was just free.
    const port = blk: {
        var srv = try oneShot(null);
        const p = srv.port();
        srv.server.deinit(testing.io);
        break :blk p;
    };
    try testing.expectError(error.ConnectFailed, post(testing.allocator, testing.io, port, "/x", &.{}, "", 5_000));

    var srv = try oneShot(null);
    try srv.start();
    defer srv.stop();
    const started = Io.Clock.awake.now(testing.io);
    try testing.expectError(error.SendFailed, post(testing.allocator, testing.io, srv.port(), "/x", &.{}, "", 300));
    const elapsed = started.durationTo(Io.Clock.awake.now(testing.io)).toMilliseconds();
    try testing.expect(elapsed >= 250 and elapsed < 5_000);
}
