//! Test helpers for `wss.zig` and the device relay: an in-process loopback
//! WebSocket server, a server that accepts and never answers, a per-test
//! deadline that turns a hang into a failure, and a loopback TLS terminator
//! (python3's `ssl`, with a certificate `openssl` generates for the test).
//! Nothing here listens anywhere but 127.0.0.1.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const ws = @import("ws.zig");
const ws_server = @import("ws_server.zig");

/// Panics (failing the run) if the test is still going after `ms`.
pub const Deadline = struct {
    io: Io,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    ms: i64,

    pub fn start(io: Io, ms: i64) !*Deadline {
        const d = try std.heap.page_allocator.create(Deadline);
        d.* = .{ .io = io, .ms = ms };
        d.thread = try std.Thread.spawn(.{}, run, .{d});
        return d;
    }

    fn run(d: *Deadline) void {
        const end = Io.Clock.awake.now(d.io).toMilliseconds() + d.ms;
        while (!d.done.load(.acquire)) {
            if (Io.Clock.awake.now(d.io).toMilliseconds() > end) @panic("test exceeded its deadline (hang)");
            Io.sleep(d.io, .fromMilliseconds(20), .awake) catch return;
        }
    }

    pub fn finish(d: *Deadline) void {
        d.done.store(true, .release);
        if (d.thread) |t| t.join();
        std.heap.page_allocator.destroy(d);
    }
};

pub const Frame = struct {
    gpa: Allocator,
    op: ws.Opcode,
    fin: bool,
    payload: []u8,

    pub fn deinit(f: *Frame) void {
        f.gpa.free(f.payload);
    }
};

pub const Message = struct {
    op: ws.Opcode,
    payload: []u8,
    fragments: usize,
    pings: usize,
};

/// The server's end of one accepted, upgraded connection.
pub const Peer = struct {
    gpa: Allocator,
    io: Io,
    stream: net.Stream,
    rd: net.Stream.Reader,
    wr: net.Stream.Writer,
    write_lock: Io.Mutex = .init,
    rbuf: [64 * 1024]u8 = undefined,
    wbuf: [64 * 1024]u8 = undefined,
    request_target: []u8 = &.{},
    authorization: ?[]u8 = null,

    pub fn deinit(p: *Peer) void {
        p.gpa.free(p.request_target);
        if (p.authorization) |a| p.gpa.free(a);
    }

    pub const Request = struct {
        key: [64]u8 = undefined,
        key_len: usize = 0,
    };

    /// Reads the upgrade request: target, Authorization and the key.
    pub fn readRequest(p: *Peer) !Request {
        const r = &p.rd.interface;
        const line = try r.takeDelimiterInclusive('\n');
        var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r\n"), ' ');
        if (!std.mem.eql(u8, parts.next() orelse "", "GET")) return error.BadRequest;
        p.request_target = try p.gpa.dupe(u8, parts.next() orelse return error.BadRequest);
        var req: Request = .{};
        while (true) {
            const raw = try r.takeDelimiterInclusive('\n');
            const h = std.mem.trimEnd(u8, raw, "\r\n");
            if (h.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
            const name = std.mem.trim(u8, h[0..colon], " \t");
            const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "authorization")) {
                if (p.authorization) |old| p.gpa.free(old);
                p.authorization = try p.gpa.dupe(u8, value);
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key") and value.len <= req.key.len) {
                @memcpy(req.key[0..value.len], value);
                req.key_len = value.len;
            }
        }
        if (req.key_len == 0) return error.MissingWebSocketKey;
        return req;
    }

    /// Answers the upgrade: 101 switches protocols, anything else refuses.
    pub fn answer(p: *Peer, req: Request, status: u16) !void {
        const w = &p.wr.interface;
        if (status != 101) {
            try w.print("HTTP/1.1 {d} Nope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status});
            return w.flush();
        }
        var accept: [28]u8 = undefined;
        ws_server.computeAcceptKey(req.key[0..req.key_len], &accept);
        try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&accept});
        try w.flush();
    }

    fn handshake(p: *Peer, status: u16) !void {
        try p.answer(try p.readRequest(), status);
    }

    /// One frame from the client (which must mask), unmasked.
    pub fn readFrame(p: *Peer) !Frame {
        const r = &p.rd.interface;
        const h = try r.takeArray(2);
        const fin = (h[0] & 0x80) != 0;
        const op: ws.Opcode = @enumFromInt(@as(u4, @truncate(h[0] & 0x0f)));
        if (h[1] & 0x80 == 0) return error.UnmaskedClientFrame;
        var len: u64 = h[1] & 0x7f;
        if (len == 126) len = std.mem.readInt(u16, try r.takeArray(2), .big);
        if (len == 127) len = std.mem.readInt(u64, try r.takeArray(8), .big);
        const mask = (try r.takeArray(4)).*;
        const payload = try p.gpa.alloc(u8, @intCast(len));
        errdefer p.gpa.free(payload);
        try r.readSliceAll(payload);
        for (payload, 0..) |*b, i| b.* ^= mask[i & 3];
        return .{ .gpa = p.gpa, .op = op, .fin = fin, .payload = payload };
    }

    /// One data message, skipping (and counting) pings; pongs are skipped.
    pub fn readMessage(p: *Peer) !Message {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(p.gpa);
        var op: ?ws.Opcode = null;
        var fragments: usize = 0;
        var pings: usize = 0;
        while (true) {
            var f = try p.readFrame();
            defer f.deinit();
            switch (f.op) {
                .ping => pings += 1,
                .pong => {},
                .close => return error.PeerClosed,
                else => {
                    if (op == null) op = f.op;
                    fragments += 1;
                    try out.appendSlice(p.gpa, f.payload);
                    if (f.fin) return .{ .op = op.?, .payload = try out.toOwnedSlice(p.gpa), .fragments = fragments, .pings = pings };
                },
            }
        }
    }

    pub fn writeFrame(p: *Peer, op: ws.Opcode, payload: []const u8) !void {
        p.write_lock.lockUncancelable(p.io);
        defer p.write_lock.unlock(p.io);
        try ws_server.writeServerFrame(&p.wr.interface, op, payload);
        try p.wr.interface.flush();
    }

    pub fn writeRaw(p: *Peer, bytes: []const u8) !void {
        p.write_lock.lockUncancelable(p.io);
        defer p.write_lock.unlock(p.io);
        try p.wr.interface.writeAll(bytes);
        try p.wr.interface.flush();
    }

    pub fn shutdown(p: *Peer) void {
        p.stream.shutdown(p.io, .both) catch {};
    }
};

pub const Script = *const fn (*Peer) anyerror!void;

/// Accepts connections on 127.0.0.1 and runs `script` on each upgraded one,
/// one at a time, up to `max_conns`.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    listener: net.Server,
    port: u16,
    script: ?Script,
    reject_status: u16 = 101,
    max_conns: usize = 1,
    thread: ?std.Thread = null,
    result: anyerror!void = {},
    stopping: std.atomic.Value(bool) = .init(false),
    current: std.atomic.Value(?*Peer) = .init(null),
    accepted: std.atomic.Value(usize) = .init(0),

    pub fn start(gpa: Allocator, io: Io, script: Script) !*Server {
        return startWith(gpa, io, script, 101, 1);
    }

    pub fn startMany(gpa: Allocator, io: Io, script: Script, max_conns: usize) !*Server {
        return startWith(gpa, io, script, 101, max_conns);
    }

    pub fn startRejecting(gpa: Allocator, io: Io, status: u16) !*Server {
        return startWith(gpa, io, null, status, 1);
    }

    fn startWith(gpa: Allocator, io: Io, script: ?Script, status: u16, max_conns: usize) !*Server {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        var listener = try addr.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .script = script,
            .reject_status = status,
            .max_conns = max_conns,
        };
        s.thread = try std.Thread.spawn(.{}, run, .{s});
        return s;
    }

    fn run(s: *Server) void {
        var n: usize = 0;
        while (n < s.max_conns and !s.stopping.load(.acquire)) {
            const stream = s.listener.accept(s.io) catch |err| {
                if (!s.stopping.load(.acquire)) s.result = err;
                return;
            };
            const upgraded = s.serveOne(stream) catch |err| {
                if (!s.stopping.load(.acquire)) {
                    std.debug.print("test server script failed: {t}\n", .{err});
                    s.result = err;
                    return;
                }
                continue;
            };
            // Another process on this machine may dial a loopback port this
            // server just took (a reconnect loop aimed at a closed port).
            // A connection that never upgrades isn't one of ours.
            if (upgraded) {
                n += 1;
                _ = s.accepted.fetchAdd(1, .acq_rel);
            }
        }
    }

    /// False when the connection never sent a WebSocket upgrade.
    fn serveOne(s: *Server, stream: net.Stream) !bool {
        const peer = try s.gpa.create(Peer);
        defer s.gpa.destroy(peer);
        peer.* = .{ .gpa = s.gpa, .io = s.io, .stream = stream, .rd = undefined, .wr = undefined };
        peer.rd = net.Stream.Reader.init(stream, s.io, &peer.rbuf);
        peer.wr = net.Stream.Writer.init(stream, s.io, &peer.wbuf);
        defer {
            s.current.store(null, .release);
            stream.close(s.io);
            peer.deinit();
        }
        s.current.store(peer, .release);
        peer.handshake(s.reject_status) catch |err| switch (err) {
            error.BadRequest, error.MissingWebSocketKey, error.EndOfStream, error.ReadFailed, error.StreamTooLong => return false,
            else => |e| return e,
        };
        if (s.script) |script| try script(peer);
        return true;
    }

    /// Waits for the script(s) to finish and returns the first failure.
    pub fn join(s: *Server) !void {
        if (s.thread) |t| {
            t.join();
            s.thread = null;
        }
        return s.result;
    }

    /// Unblocks everything (accept, a blocked read) and frees.
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        (net.Stream{ .socket = s.listener.socket }).shutdown(s.io, .both) catch {};
        if (s.current.load(.acquire)) |p| p.shutdown();
        if (s.thread) |t| t.join();
        s.listener.deinit(s.io);
        s.gpa.destroy(s);
    }

    /// Shuts the connection the script is serving (simulates a dropped socket).
    pub fn dropCurrent(s: *Server) void {
        if (s.current.load(.acquire)) |p| p.shutdown();
    }
};

/// Accepts one TCP connection and never says anything.
pub const MuteServer = struct {
    io: Io,
    listener: net.Server,
    port: u16,
    thread: std.Thread,
    held: std.atomic.Value(i64) = .init(-1),
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn start(io: Io) !*MuteServer {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        var listener = try addr.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        const m = try std.heap.page_allocator.create(MuteServer);
        m.* = .{ .io = io, .listener = listener, .port = listener.socket.address.getPort(), .thread = undefined };
        m.thread = try std.Thread.spawn(.{}, run, .{m});
        return m;
    }

    fn run(m: *MuteServer) void {
        const stream = m.listener.accept(m.io) catch return;
        defer stream.close(m.io);
        while (!m.stopping.load(.acquire)) Io.sleep(m.io, .fromMilliseconds(10), .awake) catch return;
    }

    pub fn stop(m: *MuteServer) void {
        m.stopping.store(true, .release);
        (net.Stream{ .socket = m.listener.socket }).shutdown(m.io, .both) catch {};
        m.thread.join();
        m.listener.deinit(m.io);
        std.heap.page_allocator.destroy(m);
    }
};

/// TLS on 127.0.0.1 in front of a plain loopback port, through python3's
/// `ssl` with a fresh self-signed RSA certificate (`openssl`, CN and SAN for
/// localhost and 127.0.0.1). Skips the test when either tool is missing.
pub const TlsProxy = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    port: u16,
    dir: []u8,
    cert_path: []u8,

    const script =
        \\import socket, ssl, sys, threading
        \\cert, key, backend = sys.argv[1], sys.argv[2], int(sys.argv[3])
        \\ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        \\ctx.load_cert_chain(cert, key)
        \\ls = socket.socket()
        \\ls.bind(("127.0.0.1", 0))
        \\ls.listen(4)
        \\ls.settimeout(60)
        \\print(ls.getsockname()[1], flush=True)
        \\def pump(a, b):
        \\    try:
        \\        while True:
        \\            d = a.recv(65536)
        \\            if not d: break
        \\            b.sendall(d)
        \\    except Exception: pass
        \\    for s in (a, b):
        \\        try: s.shutdown(socket.SHUT_RDWR)
        \\        except Exception: pass
        \\def serve(raw):
        \\    try:
        \\        raw.settimeout(30)
        \\        tls = ctx.wrap_socket(raw, server_side=True)
        \\        first = tls.recv(65536)
        \\        if not first: return
        \\        tls.settimeout(None)
        \\        up = socket.create_connection(("127.0.0.1", backend))
        \\        up.sendall(first)
        \\        threading.Thread(target=pump, args=(up, tls), daemon=True).start()
        \\        pump(tls, up)
        \\    except Exception:
        \\        try: raw.close()
        \\        except Exception: pass
        \\while True:
        \\    try: raw, _ = ls.accept()
        \\    except Exception: break
        \\    threading.Thread(target=serve, args=(raw,), daemon=True).start()
    ;

    pub fn start(gpa: Allocator, io: Io, backend_port: u16) !TlsProxy {
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const dir = try std.fmt.allocPrint(gpa, "/tmp/harness-nano-wss-test-{x}", .{&rnd});
        errdefer gpa.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
        errdefer Io.Dir.cwd().deleteTree(io, dir) catch {};
        const key_path = try std.fmt.allocPrint(gpa, "{s}/key.pem", .{dir});
        defer gpa.free(key_path);
        const cert_path = try std.fmt.allocPrint(gpa, "{s}/cert.pem", .{dir});
        errdefer gpa.free(cert_path);

        // RSA: std's TLS 1.2 client offers only ECDHE_RSA suites, and the
        // system python's ssl may speak no TLS 1.3.
        if (!try runTool(gpa, io, &.{
            "openssl", "req",     "-x509",                                      "-newkey", "rsa:2048",   "-nodes", "-keyout", key_path,
            "-out",    cert_path, "-subj",                                      "/CN=localhost", "-days", "2",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        })) return error.SkipZigTest;

        var port_buf: [8]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{backend_port});
        var child = std.process.spawn(io, .{
            .argv = &.{ "python3", "-I", "-c", script, cert_path, key_path, port_text },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.SkipZigTest;
        errdefer child.kill(io);
        var buf: [64]u8 = undefined;
        var rd = child.stdout.?.reader(io, &buf);
        const line = (rd.interface.takeDelimiter('\n') catch return error.SkipZigTest) orelse return error.SkipZigTest;
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, line, " \r\n"), 10) catch return error.SkipZigTest;
        return .{ .gpa = gpa, .io = io, .child = child, .port = port, .dir = dir, .cert_path = cert_path };
    }

    fn runTool(gpa: Allocator, io: Io, argv: []const []const u8) !bool {
        const res = std.process.run(gpa, io, .{ .argv = argv, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } } }) catch return false;
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        return switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    pub fn stop(p: *TlsProxy) void {
        p.child.kill(p.io);
        Io.Dir.cwd().deleteTree(p.io, p.dir) catch {};
        p.gpa.free(p.cert_path);
        p.gpa.free(p.dir);
    }
};
