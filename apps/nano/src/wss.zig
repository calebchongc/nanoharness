//! A WebSocket client (RFC 6455) for remote servers: `ws://` and `wss://`
//! (TLS from `std.crypto.tls.Client`, certificates checked against the system
//! roots), binary and text messages, client masking, ping/pong, the close
//! handshake, fragment reassembly, a bounded dial and a silence lease.
//!
//! `ws.zig` stays the loopback client for the engine's own socket; this one
//! dials the edge, the way `crates/sync/src/dial.rs` and `socket.rs` do:
//! - DNS, TCP, TLS and the HTTP upgrade together are bounded (20 s);
//! - a `token` query parameter is sent as `Authorization: Bearer` instead;
//! - messages over 16 KiB go out as 4 KiB fragments with an empty ping after
//!   each, so control frames keep flowing while a slow uplink drains;
//! - with a lease set, no inbound byte for that long (or a write that makes no
//!   progress for that long) shuts the socket, which fails the blocked read or
//!   write. A completed local write does not count as liveness.
//!
//! One thread reads; any thread may send (sends are serialized). The TLS
//! client shares its cipher state between the two directions; a server-sent
//! KeyUpdate that requests an update rotates the write keys from the reading
//! thread, which std's client does without telling the writer. Servers this
//! dials (Cloudflare) don't request key updates.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const Allocator = std.mem.Allocator;
const ws = @import("ws.zig");
const ws_server = @import("ws_server.zig");
const device_frame = @import("device_frame.zig");

pub const Opcode = ws.Opcode;

pub const Error = error{
    BadUrl,
    ConnectFailed,
    Timeout,
    TlsFailed,
    HandshakeFailed,
    /// The server answered the upgrade with a status other than 101.
    HandshakeRejected,
    PeerClosed,
    MessageTooLong,
    BadFrame,
    /// The socket was shut (lease expiry, `shutdown`, or a transport error).
    ConnectionLost,
} || Allocator.Error;

/// One reassembled message at most.
pub const message_cap = 64 * 1024 * 1024;
/// Rust `socket.rs`: messages above `4 * FRAGMENT_BYTES` are fragmented.
pub const fragment_bytes = 4096;
pub const fragment_threshold = 4 * fragment_bytes;
/// `connect_ws`: DNS, all TCP attempts, TLS and the upgrade together.
pub const default_connect_timeout_ms: u64 = 20_000;

pub const Url = struct {
    secure: bool,
    /// Without brackets for an IPv6 literal.
    host: []const u8,
    port: u16,
    /// Path and query, at least "/".
    target: []const u8,
    /// Whether the URL named the port.
    explicit_port: bool,
};

pub fn parseUrl(url: []const u8) error{BadUrl}!Url {
    const secure = if (std.mem.startsWith(u8, url, "wss://"))
        true
    else if (std.mem.startsWith(u8, url, "ws://"))
        false
    else
        return error.BadUrl;
    const rest = url[(if (secure) "wss://".len else "ws://".len)..];
    const path_at = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..path_at];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.BadUrl;
    var host: []const u8 = authority;
    var port_text: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.BadUrl;
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.BadUrl;
            port_text = after[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port_text = authority[colon + 1 ..];
    }
    if (host.len == 0) return error.BadUrl;
    const port: u16 = if (port_text) |p| std.fmt.parseInt(u16, p, 10) catch return error.BadUrl else if (secure) 443 else 80;
    var target = rest[path_at..];
    if (target.len == 0) target = "/";
    if (target[0] == '?') return error.BadUrl; // a query needs a path; callers always build one
    return .{ .secure = secure, .host = host, .port = port, .target = target, .explicit_port = port_text != null };
}

/// How a `wss://` server certificate is checked.
pub const Trust = union(enum) {
    /// The system's root certificates, scanned once per process.
    system,
    /// A caller-owned bundle (tests pin a generated certificate this way).
    bundle: *Certificate.Bundle,
};

pub const Options = struct {
    connect_timeout_ms: u64 = default_connect_timeout_ms,
    /// 0 = no lease. See the file comment.
    lease_ms: u64 = 0,
    trust: Trust = .system,
    /// Extra request header, e.g. "Authorization: Bearer …" is added from a
    /// URL `token` by `connectUrl`; callers may also pass one directly.
    authorization: ?[]const u8 = null,
    /// Set to the HTTP status when the upgrade is answered with another status.
    status_out: ?*u16 = null,
};

var system_bundle: Certificate.Bundle = .empty;
var system_bundle_lock: Io.RwLock = .init;
var system_bundle_scanned: bool = false;
var system_bundle_mutex: Io.Mutex = .init;

fn systemBundle(gpa: Allocator, io: Io) !*Certificate.Bundle {
    system_bundle_mutex.lockUncancelable(io);
    defer system_bundle_mutex.unlock(io);
    if (!system_bundle_scanned) {
        try system_bundle.rescan(gpa, io, Io.Clock.real.now(io));
        system_bundle_scanned = true;
    }
    return &system_bundle;
}

fn nowMs(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// Socket reader that stamps inbound progress (after `net.Stream.Reader`).
const SockReader = struct {
    conn: *Conn,
    interface: Io.Reader,

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *SockReader = @alignCast(@fieldParentPtr("interface", io_r));
        const c = r.conn;
        var iovecs: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
        const n = (c.stream.readWithControl(c.io, iovecs[0..dest_n], &.{}) catch return error.ReadFailed).data_len;
        if (n == 0) return error.EndOfStream;
        c.last_rx_ms.store(nowMs(c.io), .release);
        if (n > data_size) {
            io_r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// Socket writer that stamps outbound progress (after `net.Stream.Writer`).
const SockWriter = struct {
    conn: *Conn,
    interface: Io.Writer,

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *SockWriter = @alignCast(@fieldParentPtr("interface", io_w));
        const c = w.conn;
        const result = c.io.operate(.{ .net_write = .{
            .socket_handle = c.stream.socket.handle,
            .header = io_w.buffered(),
            .data = data,
            .splat = splat,
        } }) catch return error.WriteFailed;
        const n = result.net_write catch return error.WriteFailed;
        c.last_tx_ms.store(nowMs(c.io), .release);
        return io_w.consume(n);
    }
};

pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    stream: net.Stream,
    secure: bool,
    sock_r: SockReader,
    sock_w: SockWriter,
    tls_client: tls.Client,
    write_lock: Io.Mutex = .init,

    lease_ms: u64,
    last_rx_ms: std.atomic.Value(i64) = .init(0),
    last_tx_ms: std.atomic.Value(i64) = .init(0),
    /// Start of the write in progress (0 = none).
    write_started_ms: std.atomic.Value(i64) = .init(0),
    /// Connect phase deadline (0 = none).
    deadline_ms: std.atomic.Value(i64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    shut: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    sent_close: std.atomic.Value(bool) = .init(false),
    watchdog: ?std.Thread = null,
    /// The close code the peer sent, if it sent one.
    peer_close_code: ?u16 = null,

    sock_rbuf: [tls.Client.min_buffer_len]u8 = undefined,
    sock_wbuf: [tls.Client.min_buffer_len]u8 = undefined,
    tls_rbuf: [tls.Client.min_buffer_len]u8 = undefined,
    /// One TLS record of plaintext: std's `flush` drops bytes it can't fit in
    /// one ciphertext buffer, so the plaintext buffer must not exceed it.
    tls_wbuf: [16 * 1024]u8 = undefined,

    fn reader(self: *Conn) *Io.Reader {
        return if (self.secure) &self.tls_client.reader else &self.sock_r.interface;
    }

    fn writer(self: *Conn) *Io.Writer {
        return if (self.secure) &self.tls_client.writer else &self.sock_w.interface;
    }

    fn flushAll(self: *Conn) Io.Writer.Error!void {
        if (self.secure) try self.tls_client.writer.flush();
        try self.sock_w.interface.flush();
    }

    /// Closes the socket for reads and writes; a blocked read or write fails.
    pub fn shutdown(self: *Conn) void {
        if (self.shut.swap(true, .acq_rel)) return;
        self.stream.shutdown(self.io, .both) catch {};
    }

    /// Whether the lease or the connect deadline shut this socket.
    pub fn timedOut(self: *const Conn) bool {
        return self.timed_out.load(.acquire);
    }

    /// Stops the watchdog, closes the socket and frees. No other thread may
    /// still be using the connection.
    pub fn deinit(self: *Conn) void {
        self.stop.store(true, .release);
        if (self.watchdog) |t| t.join();
        self.shutdown();
        self.stream.close(self.io);
        self.gpa.destroy(self);
    }

    fn startWatchdog(self: *Conn) !void {
        self.watchdog = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn watch(self: *Conn) void {
        while (!self.stop.load(.acquire)) {
            Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            if (self.shut.load(.acquire)) continue;
            const now = nowMs(self.io);
            const deadline = self.deadline_ms.load(.acquire);
            var trip = deadline != 0 and now >= deadline;
            if (!trip and deadline == 0 and self.lease_ms > 0) {
                const lease: i64 = @intCast(self.lease_ms);
                const started = self.write_started_ms.load(.acquire);
                const last_tx = self.last_tx_ms.load(.acquire);
                const last_rx = self.last_rx_ms.load(.acquire);
                if (started != 0) {
                    // A blocked write: only its own byte progress keeps it alive,
                    // and that progress also excuses read silence meanwhile.
                    trip = now - @max(started, last_tx) > lease;
                } else {
                    trip = now - last_rx > lease;
                }
            }
            if (trip) {
                self.timed_out.store(true, .release);
                self.shutdown();
            }
        }
    }

    // -- sending ------------------------------------------------------------

    fn writeFrame(self: *Conn, op: Opcode, fin: bool, payload: []const u8) Io.Writer.Error!void {
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        const w = self.writer();
        var hdr: [14]u8 = undefined;
        hdr[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(op));
        var n: usize = 2;
        if (payload.len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            hdr[1] = 0x80 | 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            n = 4;
        } else {
            hdr[1] = 0x80 | 127;
            std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
            n = 10;
        }
        @memcpy(hdr[n .. n + 4], &mask);
        n += 4;
        try w.writeAll(hdr[0..n]);
        var tmp: [4096]u8 = undefined;
        var i: usize = 0;
        while (i < payload.len) {
            const chunk = @min(tmp.len, payload.len - i);
            for (0..chunk) |j| tmp[j] = payload[i + j] ^ mask[(i + j) & 3];
            try w.writeAll(tmp[0..chunk]);
            i += chunk;
        }
    }

    fn beginWrite(self: *Conn) void {
        self.write_lock.lockUncancelable(self.io);
        self.write_started_ms.store(nowMs(self.io), .release);
    }

    fn endWrite(self: *Conn) void {
        self.write_started_ms.store(0, .release);
        self.write_lock.unlock(self.io);
    }

    /// Sends one text or binary message, fragmenting large ones.
    pub fn send(self: *Conn, op: Opcode, payload: []const u8) Error!void {
        std.debug.assert(op == .text or op == .binary);
        if (self.shut.load(.acquire)) return error.ConnectionLost;
        self.beginWrite();
        defer self.endWrite();
        self.sendLocked(op, payload) catch return error.ConnectionLost;
    }

    fn sendLocked(self: *Conn, op: Opcode, payload: []const u8) Io.Writer.Error!void {
        if (payload.len <= fragment_threshold) {
            try self.writeFrame(op, true, payload);
            return self.flushAll();
        }
        var i: usize = 0;
        while (i < payload.len) {
            const end = @min(payload.len, i + fragment_bytes);
            try self.writeFrame(if (i == 0) op else .cont, end == payload.len, payload[i..end]);
            try self.writeFrame(.ping, true, "");
            try self.flushAll();
            i = end;
        }
    }

    pub fn sendBinary(self: *Conn, payload: []const u8) Error!void {
        return self.send(.binary, payload);
    }

    pub fn sendText(self: *Conn, payload: []const u8) Error!void {
        return self.send(.text, payload);
    }

    fn sendControl(self: *Conn, op: Opcode, payload: []const u8) void {
        if (self.shut.load(.acquire)) return;
        self.beginWrite();
        defer self.endWrite();
        self.writeFrame(op, true, payload) catch return;
        self.flushAll() catch {};
    }

    /// Starts the close handshake with `code` (no reason text), then shuts the
    /// socket without waiting for the answer: a close can itself block on the
    /// failed uplink being abandoned.
    pub fn close(self: *Conn, code: u16) void {
        if (!self.sent_close.swap(true, .acq_rel)) {
            var body: [2]u8 = undefined;
            std.mem.writeInt(u16, &body, code, .big);
            self.sendControl(.close, &body);
        }
        self.shutdown();
    }

    // -- receiving ----------------------------------------------------------

    /// One whole message into `out` (cleared first): `.text` or `.binary`.
    /// Pings are answered and pongs skipped. A close from the peer is answered
    /// and returned as `error.PeerClosed` (its code in `peer_close_code`).
    pub fn readMessage(self: *Conn, out: *std.ArrayList(u8)) Error!Opcode {
        return self.readMessageInner(out) catch |err| switch (err) {
            error.ReadFailed, error.EndOfStream => error.ConnectionLost,
            else => |e| e,
        };
    }

    fn readMessageInner(self: *Conn, out: *std.ArrayList(u8)) (Error || Io.Reader.Error)!Opcode {
        const r = self.reader();
        out.clearRetainingCapacity();
        var msg_op: ?Opcode = null;
        while (true) {
            const h = try r.takeArray(2);
            const fin = (h[0] & 0x80) != 0;
            if (h[0] & 0x70 != 0) return error.BadFrame; // no extensions negotiated
            const op: Opcode = @enumFromInt(@as(u4, @truncate(h[0] & 0x0f)));
            if (h[1] & 0x80 != 0) return error.BadFrame; // servers must not mask
            var len: u64 = h[1] & 0x7f;
            if (len == 126) {
                len = std.mem.readInt(u16, try r.takeArray(2), .big);
            } else if (len == 127) {
                len = std.mem.readInt(u64, try r.takeArray(8), .big);
            }
            switch (op) {
                .ping, .pong, .close => {
                    if (!fin or len > 125) return error.BadFrame;
                    var body: [125]u8 = undefined;
                    try r.readSliceAll(body[0..@intCast(len)]);
                    const p = body[0..@intCast(len)];
                    switch (op) {
                        .ping => self.sendControl(.pong, p),
                        .pong => {},
                        else => {
                            if (p.len >= 2) self.peer_close_code = std.mem.readInt(u16, p[0..2], .big);
                            if (!self.sent_close.swap(true, .acq_rel)) {
                                self.sendControl(.close, if (p.len >= 2) p[0..2] else "");
                            }
                            self.shutdown();
                            return error.PeerClosed;
                        },
                    }
                },
                .text, .binary, .cont => {
                    if (op == .cont and msg_op == null) return error.BadFrame;
                    if (op != .cont and msg_op != null) return error.BadFrame;
                    if (out.items.len + len > message_cap) return error.MessageTooLong;
                    const start = out.items.len;
                    try out.resize(self.gpa, start + @as(usize, @intCast(len)));
                    try r.readSliceAll(out.items[start..]);
                    if (msg_op == null) msg_op = op;
                    if (fin) return msg_op.?;
                },
                else => return error.BadFrame,
            }
        }
    }
};

/// `connect` with the URL's `token` query parameter sent as a bearer header
/// instead (`bearer_from_query`).
pub fn connectUrl(gpa: Allocator, io: Io, url: []const u8, options: Options) Error!*Conn {
    const parsed = try parseUrl(url);
    var split = try device_frame.bearerFromTarget(gpa, parsed.target);
    defer split.deinit(gpa);
    var opts = options;
    var auth_buf: ?[]u8 = null;
    defer if (auth_buf) |a| gpa.free(a);
    if (split.token) |tok| {
        if (opts.authorization == null) {
            auth_buf = try std.fmt.allocPrint(gpa, "Bearer {s}", .{tok});
            opts.authorization = auth_buf;
        }
    }
    var p = parsed;
    p.target = split.target;
    return connect(gpa, io, p, opts);
}

const Dial = struct {
    gpa: Allocator,
    io: Io,
    host: []u8,
    port: u16,
    /// 0 pending, 1 done (caller owns the result), 2 abandoned (dialer frees).
    state: std.atomic.Value(u8) = .init(0),
    result: anyerror!net.Stream = error.ConnectFailed,

    fn run(d: *Dial) void {
        const result: anyerror!net.Stream = blk: {
            const ip = net.IpAddress.parse(d.host, d.port) catch {
                const hn = net.HostName.init(d.host) catch break :blk error.ConnectFailed;
                break :blk hn.connect(d.io, d.port, .{ .mode = .stream });
            };
            break :blk ip.connect(d.io, .{ .mode = .stream });
        };
        d.result = result;
        if (d.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
            // The caller gave up: nobody will take this stream.
            if (result) |s| s.close(d.io) else |_| {}
            d.gpa.free(d.host);
            d.gpa.destroy(d);
        }
    }
};

/// TCP connect bounded by `timeout_ms`. A connect that outlives it is
/// abandoned to its thread, which closes the late socket.
fn dialTcp(gpa: Allocator, io: Io, host: []const u8, port: u16, timeout_ms: u64) Error!net.Stream {
    const d = try gpa.create(Dial);
    d.* = .{ .gpa = gpa, .io = io, .host = gpa.dupe(u8, host) catch {
        gpa.destroy(d);
        return error.OutOfMemory;
    }, .port = port };
    const thread = std.Thread.spawn(.{}, Dial.run, .{d}) catch {
        gpa.free(d.host);
        gpa.destroy(d);
        return error.ConnectFailed;
    };
    thread.detach();
    const deadline = nowMs(io) + @as(i64, @intCast(timeout_ms));
    while (d.state.load(.acquire) == 0) {
        if (nowMs(io) >= deadline) {
            if (d.state.cmpxchgStrong(0, 2, .acq_rel, .acquire) == null) return error.Timeout;
            break; // finished just now
        }
        Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
    }
    const result = d.result;
    gpa.free(d.host);
    gpa.destroy(d);
    return result catch error.ConnectFailed;
}

pub fn connect(gpa: Allocator, io: Io, url: Url, options: Options) Error!*Conn {
    const started = nowMs(io);
    const stream = try dialTcp(gpa, io, url.host, url.port, options.connect_timeout_ms);
    const self = gpa.create(Conn) catch |err| {
        stream.close(io);
        return err;
    };
    self.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .secure = url.secure,
        .sock_r = undefined,
        .sock_w = undefined,
        .tls_client = undefined,
        .lease_ms = options.lease_ms,
    };
    self.sock_r = .{ .conn = self, .interface = .{
        .vtable = &.{ .stream = SockReader.streamImpl, .readVec = SockReader.readVec },
        .buffer = &self.sock_rbuf,
        .seek = 0,
        .end = 0,
    } };
    self.sock_w = .{ .conn = self, .interface = .{ .vtable = &.{ .drain = SockWriter.drain }, .buffer = &self.sock_wbuf } };
    if (comptime builtin.os.tag != .windows) {
        const one: c_int = 1;
        _ = std.c.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(c_int));
    }
    // TLS and the upgrade share what is left of the connect budget.
    self.deadline_ms.store(started + @as(i64, @intCast(options.connect_timeout_ms)), .release);
    self.startWatchdog() catch {
        self.stream.close(io);
        gpa.destroy(self);
        return error.ConnectFailed;
    };
    errdefer self.deinit();

    if (url.secure) {
        const bundle = switch (options.trust) {
            .system => systemBundle(gpa, io) catch return error.TlsFailed,
            .bundle => |b| b,
        };
        const lock = switch (options.trust) {
            .system => &system_bundle_lock,
            .bundle => &test_bundle_lock,
        };
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        var alert: tls.Alert = undefined;
        self.tls_client = tls.Client.init(&self.sock_r.interface, &self.sock_w.interface, .{
            .host = .{ .explicit = url.host },
            .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = lock, .bundle = bundle } },
            .read_buffer = &self.tls_rbuf,
            .write_buffer = &self.tls_wbuf,
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(io),
            .alert = &alert,
        }) catch |err| {
            if (err == error.TlsAlert) {
                std.log.warn("wss: TLS alert from {s}: {t}", .{ url.host, alert.description });
            } else {
                std.log.debug("wss: TLS handshake with {s} failed: {t}", .{ url.host, err });
            }
            return if (self.timed_out.load(.acquire)) error.Timeout else error.TlsFailed;
        };
    }
    handshake(self, url, options) catch |err| return if (self.timed_out.load(.acquire)) error.Timeout else err;
    self.last_rx_ms.store(nowMs(io), .release);
    self.deadline_ms.store(0, .release);
    if (self.timed_out.load(.acquire)) return error.Timeout;
    return self;
}

var test_bundle_lock: Io.RwLock = .init;

fn handshake(self: *Conn, url: Url, options: Options) Error!void {
    var key_raw: [16]u8 = undefined;
    self.io.random(&key_raw);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_raw);
    const w = self.writer();
    const bracket = std.mem.indexOfScalar(u8, url.host, ':') != null;
    w.print("GET {s} HTTP/1.1\r\nHost: {s}{s}{s}", .{ url.target, if (bracket) "[" else "", url.host, if (bracket) "]" else "" }) catch return error.ConnectionLost;
    if (url.explicit_port) w.print(":{d}", .{url.port}) catch return error.ConnectionLost;
    w.print("\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n", .{&key}) catch return error.ConnectionLost;
    if (options.authorization) |auth| w.print("Authorization: {s}\r\n", .{auth}) catch return error.ConnectionLost;
    w.writeAll("\r\n") catch return error.ConnectionLost;
    self.flushAll() catch return error.ConnectionLost;

    var expected_accept: [28]u8 = undefined;
    ws_server.computeAcceptKey(&key, &expected_accept);
    const r = self.reader();
    const status_line = r.takeDelimiterInclusive('\n') catch return error.HandshakeFailed;
    var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, status_line, "\r\n"), ' ');
    const version = parts.next() orelse return error.HandshakeFailed;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.HandshakeFailed;
    const status = std.fmt.parseInt(u16, parts.next() orelse return error.HandshakeFailed, 10) catch return error.HandshakeFailed;
    var accept_ok = false;
    var upgrade_ok = false;
    while (true) {
        const raw = r.takeDelimiterInclusive('\n') catch return error.HandshakeFailed;
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            accept_ok = std.mem.eql(u8, value, &expected_accept);
        } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            upgrade_ok = std.ascii.eqlIgnoreCase(value, "websocket");
        }
    }
    if (status != 101) {
        if (options.status_out) |s| s.* = status;
        return error.HandshakeRejected;
    }
    if (!accept_ok or !upgrade_ok) return error.HandshakeFailed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
pub const testkit = @import("wss_testkit.zig");

test "wss: URLs split into scheme, host, port and target" {
    const a = try parseUrl("wss://edge.example/device/d/ws?role=host");
    try testing.expect(a.secure);
    try testing.expectEqualStrings("edge.example", a.host);
    try testing.expectEqual(@as(u16, 443), a.port);
    try testing.expectEqualStrings("/device/d/ws?role=host", a.target);
    try testing.expect(!a.explicit_port);
    const b = try parseUrl("ws://127.0.0.1:26640");
    try testing.expect(!b.secure);
    try testing.expectEqual(@as(u16, 26640), b.port);
    try testing.expectEqualStrings("/", b.target);
    const c = try parseUrl("wss://[::1]:8443/x");
    try testing.expectEqualStrings("::1", c.host);
    try testing.expectEqual(@as(u16, 8443), c.port);
    try testing.expectError(error.BadUrl, parseUrl("https://edge.example/"));
    try testing.expectError(error.BadUrl, parseUrl("wss://user@edge.example/"));
    try testing.expectError(error.BadUrl, parseUrl("wss://edge.example:99999/"));
    try testing.expectError(error.BadUrl, parseUrl("wss:///x"));
}

test "wss: plain loopback: bearer header, fragments, ping/pong, large send, close code" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 20_000);
    defer deadline.finish();

    const Script = struct {
        fn run(s: *testkit.Peer) anyerror!void {
            try testing.expectEqualStrings("/device/d1/ws?role=host&nudgeAck=1", s.request_target);
            try testing.expectEqualStrings("Bearer t0k", s.authorization.?);
            // "ab" (not final), ping "p", "c" (final): one message "abc".
            try s.writeRaw(&.{ 0x01, 2, 'a', 'b', 0x89, 1, 'p', 0x80, 1, 'c' });
            // The client answers the ping with a pong carrying "p".
            var f = try s.readFrame();
            try testing.expectEqual(Opcode.pong, f.op);
            try testing.expectEqualStrings("p", f.payload);
            f.deinit();
            // The client's large message arrives as 4 KiB fragments, each
            // followed by an empty ping, and reassembles intact.
            const big = try s.readMessage();
            defer s.gpa.free(big.payload);
            try testing.expectEqual(Opcode.binary, big.op);
            try testing.expectEqual(@as(usize, 70_000), big.payload.len);
            for (big.payload, 0..) |b, i| try testing.expectEqual(@as(u8, @truncate(i * 7)), b);
            try testing.expectEqual(@as(usize, 18), big.fragments);
            try testing.expectEqual(@as(usize, 17), big.pings);
            // A small message is one frame.
            const small = try s.readMessage();
            defer s.gpa.free(small.payload);
            try testing.expectEqualStrings("ping", small.payload);
            try testing.expectEqual(@as(usize, 1), small.fragments);
            // Close with 4409: the client echoes the code.
            try s.writeFrame(.close, &.{ 0x11, 0x39 });
            var echo = try s.readFrame();
            defer echo.deinit();
            try testing.expectEqual(Opcode.close, echo.op);
            try testing.expectEqualSlices(u8, &.{ 0x11, 0x39 }, echo.payload);
        }
    };
    const server = try testkit.Server.start(gpa, io, Script.run);
    defer server.stop();

    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/device/d1/ws?role=host&token=t0k&nudgeAck=1", .{server.port});
    defer gpa.free(url);
    const conn = try connectUrl(gpa, io, url, .{ .connect_timeout_ms = 5_000, .lease_ms = 5_000 });
    defer conn.deinit();

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    try testing.expectEqual(Opcode.text, try conn.readMessage(&msg));
    try testing.expectEqualStrings("abc", msg.items);

    const big = try gpa.alloc(u8, 70_000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 7);
    try conn.sendBinary(big);
    try conn.sendText("ping");

    try testing.expectError(error.PeerClosed, conn.readMessage(&msg));
    try testing.expectEqual(@as(?u16, 4409), conn.peer_close_code);
    try server.join();
}

test "wss: a silent server trips the read lease" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 15_000);
    defer deadline.finish();
    const Script = struct {
        fn run(s: *testkit.Peer) anyerror!void {
            // Upgrade, then say nothing until the client gives up.
            _ = s.readFrame() catch return;
        }
    };
    const server = try testkit.Server.start(gpa, io, Script.run);
    defer server.stop();
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/", .{server.port});
    defer gpa.free(url);
    const conn = try connectUrl(gpa, io, url, .{ .connect_timeout_ms = 5_000, .lease_ms = 300 });
    defer conn.deinit();
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const t0 = nowMs(io);
    try testing.expectError(error.ConnectionLost, conn.readMessage(&msg));
    const waited = nowMs(io) - t0;
    try testing.expect(conn.timedOut());
    try testing.expect(waited >= 250 and waited < 5_000);
    try server.join();
}

test "wss: an upgrade that never answers times out inside the connect budget" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 15_000);
    defer deadline.finish();
    const mute = try testkit.MuteServer.start(io);
    defer mute.stop();
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/", .{mute.port});
    defer gpa.free(url);
    const t0 = nowMs(io);
    try testing.expectError(error.Timeout, connectUrl(gpa, io, url, .{ .connect_timeout_ms = 400 }));
    const waited = nowMs(io) - t0;
    try testing.expect(waited >= 350 and waited < 5_000);
}

test "wss: a non-101 answer is rejected with its status" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 15_000);
    defer deadline.finish();
    const server = try testkit.Server.startRejecting(gpa, io, 403);
    defer server.stop();
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/", .{server.port});
    defer gpa.free(url);
    var status: u16 = 0;
    try testing.expectError(error.HandshakeRejected, connectUrl(gpa, io, url, .{ .connect_timeout_ms = 5_000, .status_out = &status }));
    try testing.expectEqual(@as(u16, 403), status);
    try server.join();
}

test "wss: TLS handshake against a loopback TLS server with a generated certificate" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 60_000);
    defer deadline.finish();

    const Script = struct {
        fn run(s: *testkit.Peer) anyerror!void {
            try testing.expectEqualStrings("Bearer secret", s.authorization.?);
            const m = try s.readMessage();
            defer s.gpa.free(m.payload);
            try s.writeFrame(.binary, m.payload); // echo the large message back
            try s.writeFrame(.text, "hello over tls");
            try s.writeFrame(.close, &.{ 0x03, 0xe8 });
            var echo = try s.readFrame();
            echo.deinit();
        }
    };
    const server = try testkit.Server.start(gpa, io, Script.run);
    defer server.stop();
    var tls_proxy = testkit.TlsProxy.start(gpa, io, server.port) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer tls_proxy.stop();

    var bundle: Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    try bundle.addCertsFromFilePathAbsolute(gpa, io, Io.Clock.real.now(io), tls_proxy.cert_path);

    // An empty bundle doesn't trust the generated certificate.
    var empty: Certificate.Bundle = .empty;
    defer empty.deinit(gpa);
    const url = try std.fmt.allocPrint(gpa, "wss://127.0.0.1:{d}/device/d/ws?role=host&token=secret", .{tls_proxy.port});
    defer gpa.free(url);
    try testing.expectError(error.TlsFailed, connectUrl(gpa, io, url, .{ .connect_timeout_ms = 10_000, .trust = .{ .bundle = &empty } }));

    const conn = try connectUrl(gpa, io, url, .{ .connect_timeout_ms = 10_000, .lease_ms = 10_000, .trust = .{ .bundle = &bundle } });
    defer conn.deinit();
    const big = try gpa.alloc(u8, 70_000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try conn.sendBinary(big);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    try testing.expectEqual(Opcode.binary, try conn.readMessage(&msg));
    try testing.expectEqualSlices(u8, big, msg.items);
    try testing.expectEqual(Opcode.text, try conn.readMessage(&msg));
    try testing.expectEqualStrings("hello over tls", msg.items);
    try testing.expectError(error.PeerClosed, conn.readMessage(&msg));
    try testing.expectEqual(@as(?u16, 1000), conn.peer_close_code);
    try server.join();
}
