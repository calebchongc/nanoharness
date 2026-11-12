//! The loopback preview proxy (`crates/preview/src/proxy.rs`): an HTTP/1
//! reverse proxy on 127.0.0.1 and ::1 at the preview port (7331).
//!
//! The Host header must name a live catalog service at the proxy's own port;
//! the backend is the listener the catalog observed, rechecked to still be the
//! same process before each connection. Hop-by-hop headers go, Host and
//! Origin stay together, `X-Forwarded-Host`/`-Proto` are set, client proxy
//! credentials never reach the project, and absolute localhost redirects are
//! rewritten to the preview origin. WebSocket upgrades keep their byte stream.
//! `CONNECT` reaches only catalog names at the proxy port (WebKit's
//! per-domain proxy on older macOS). Bodies stream with their own framing.
//!
//! Remote (peer) services aren't served: the Zig engine has no peer
//! transport, so the catalog only ever holds this device's services.
const std = @import("std");
const builtin = @import("builtin");
const catalog_mod = @import("preview_catalog.zig");
const discovery = @import("preview_discovery.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;
const Catalog = catalog_mod.Catalog;

pub const max_connections: u32 = 128;
pub const max_tunnels: u32 = 128;
pub const header_read_timeout_ms: i64 = 15_000;
const max_head_bytes = 64 * 1024;
const poll_ms: i32 = 100;

pub const not_running = "This preview is not running. Start the project's dev server and try again.";

/// Whether the observed process still owns its listener (seam for tests).
pub const Verify = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: Io, pid: u32, started_at: u64) bool,
};

pub fn nativeVerify() Verify {
    return .{ .func = struct {
        fn f(_: ?*anyopaque, gpa: Allocator, io: Io, pid: u32, started_at: u64) bool {
            return discovery.sameProcess(gpa, io, discovery.Sys.native(), pid, started_at);
        }
    }.f };
}

pub const Proxy = struct {
    gpa: Allocator,
    io: Io,
    catalog: *Catalog,
    verify: Verify,
    stop_flag: std.atomic.Value(bool) = .init(false),
    connections: std.atomic.Value(u32) = .init(0),
    tunnels: std.atomic.Value(u32) = .init(0),
    servers: [2]?net.Server = .{ null, null },
    threads: [2]?std.Thread = .{ null, null },
    port: u16 = 0,

    /// Bind both loopback families (`.localhost` often resolves to ::1 first).
    pub fn bind(p: *Proxy, port: u16) !u16 {
        const v4 = try net.IpAddress.parseIp4("127.0.0.1", port);
        var s4 = try v4.listen(p.io, .{});
        errdefer s4.deinit(p.io);
        const bound = s4.socket.address.getPort();
        const v6 = try net.IpAddress.parseIp6("::1", bound);
        const s6: ?net.Server = v6.listen(p.io, .{}) catch |e| switch (e) {
            error.AddressFamilyUnsupported, error.ProtocolUnsupportedBySystem, error.ProtocolUnsupportedByAddressFamily, error.AddressUnavailable => null,
            else => return e,
        };
        p.servers = .{ s4, s6 };
        p.port = bound;
        return bound;
    }

    pub fn start(p: *Proxy) !void {
        for (&p.servers, 0..) |*s, i| {
            if (s.* == null) continue;
            p.threads[i] = try std.Thread.spawn(.{}, acceptLoop, .{ p, &s.*.? });
        }
    }

    pub fn stopped(p: *Proxy) bool {
        return p.stop_flag.load(.acquire);
    }

    /// Stop accepting, end every connection and tunnel, free the port.
    pub fn stop(p: *Proxy) void {
        p.stop_flag.store(true, .release);
        for (&p.threads) |*t| {
            if (t.*) |th| th.join();
            t.* = null;
        }
        for (&p.servers) |*s| {
            if (s.*) |*srv| srv.deinit(p.io);
            s.* = null;
        }
        while (p.connections.load(.acquire) > 0) {
            Io.sleep(p.io, .fromMilliseconds(10), .awake) catch {};
        }
    }

    fn acceptLoop(p: *Proxy, server: *net.Server) void {
        while (!p.stopped()) {
            if (!discovery.readable(server.socket.handle, poll_ms)) continue;
            const stream = server.accept(p.io) catch continue;
            if (p.connections.fetchAdd(1, .acq_rel) >= max_connections) {
                _ = p.connections.fetchSub(1, .acq_rel);
                stream.close(p.io);
                continue;
            }
            const t = std.Thread.spawn(.{}, serveConnection, .{ p, stream }) catch {
                _ = p.connections.fetchSub(1, .acq_rel);
                stream.close(p.io);
                continue;
            };
            t.detach();
        }
    }

    fn serveConnection(p: *Proxy, stream: net.Stream) void {
        defer _ = p.connections.fetchSub(1, .acq_rel);
        defer stream.close(p.io);
        var client: Conn = .{ .p = p, .s = stream };
        var arena = std.heap.ArenaAllocator.init(p.gpa);
        defer arena.deinit();
        while (!p.stopped()) {
            defer _ = arena.reset(.retain_capacity);
            const keep = p.handleOne(arena.allocator(), &client) catch false;
            if (!keep) return;
        }
    }

    /// One request on `client`; true to read another on the same connection.
    fn handleOne(p: *Proxy, a: Allocator, client: *Conn) !bool {
        const deadline = discovery.nowMs(p.io) + header_read_timeout_ms;
        const head_bytes = (try client.readHead(a, deadline)) orelse return false;
        var req = parseRequest(a, head_bytes) catch {
            try client.writeAll("HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n");
            return false;
        };
        if (std.ascii.eqlIgnoreCase(req.method, "CONNECT")) {
            p.connectLoopback(a, client, req.target) catch |e| {
                try client.writeError(errorText(e));
            };
            return false;
        }
        return p.forward(a, client, &req) catch |e| {
            try client.writeError(errorText(e));
            return false;
        };
    }

    fn connectLoopback(p: *Proxy, a: Allocator, client: *Conn, authority: []const u8) !void {
        const hp = splitAuthority(authority) orelse return error.InvalidPreviewConnect;
        const port = p.catalog.proxyPort();
        const host = try std.ascii.allocLowerString(a, hp.host);
        if (hp.port == null or hp.port.? != port or !p.catalog.hasHostname(host)) return error.UnknownPreviewConnectTarget;
        if (p.tunnels.fetchAdd(1, .acq_rel) >= max_tunnels) {
            _ = p.tunnels.fetchSub(1, .acq_rel);
            return error.NoPermitsAvailable;
        }
        defer _ = p.tunnels.fetchSub(1, .acq_rel);
        const self_addr = try net.IpAddress.parseIp4("127.0.0.1", port);
        const s = try self_addr.connect(p.io, .{ .mode = .stream });
        defer s.close(p.io);
        try client.writeAll("HTTP/1.1 200 OK\r\n\r\n");
        var upstream: Conn = .{ .p = p, .s = s };
        p.tunnel(client, &upstream);
    }

    fn forward(p: *Proxy, a: Allocator, client: *Conn, req: *Request) !bool {
        if (req.target.len == 0 or (req.target[0] != '/' and !std.mem.eql(u8, req.target, "*")))
            return error.OnlyOriginForm;
        const host_raw = req.headers.get("host") orelse return error.MissingPreviewHostname;
        const host = try std.ascii.allocLowerString(a, std.mem.trim(u8, host_raw, " \t"));
        const hp = splitAuthority(host) orelse return error.InvalidAuthority;
        if ((hp.port orelse 80) != p.catalog.proxyPort()) return error.IncorrectPreviewProxyPort;
        const route = (try p.catalog.routeByHostname(a, hp.host)) orelse return error.PreviewNotRunning;
        const upgrade = if (req.headers.get("upgrade")) |u| std.ascii.eqlIgnoreCase(std.mem.trim(u8, u, " \t"), "websocket") else false;
        const wants_upgrade = upgrade and req.headers.connectionHas("upgrade");
        if (wants_upgrade) {
            if (p.tunnels.fetchAdd(1, .acq_rel) >= max_tunnels) {
                _ = p.tunnels.fetchSub(1, .acq_rel);
                return error.NoPermitsAvailable;
            }
        }
        defer if (wants_upgrade) {
            _ = p.tunnels.fetchSub(1, .acq_rel);
        };
        const client_close = req.http10 or req.headers.connectionHas("close");
        const request_body = req.headers.bodyFraming(false);
        const expect_continue = if (req.headers.get("expect")) |e| std.ascii.eqlIgnoreCase(std.mem.trim(u8, e, " \t"), "100-continue") else false;

        if (!p.verify.func(p.verify.ctx, a, p.io, route.listener.pid, route.listener.started_at))
            return error.PreviewProcessChanged;
        const backend = route.listener.address.toIp();
        const s = try backend.connect(p.io, .{ .mode = .stream });
        defer s.close(p.io);
        var upstream: Conn = .{ .p = p, .s = s };

        // Request head: Host and Origin together, the forwarded host, no hop
        // headers and no client proxy credentials.
        var head: std.ArrayList(u8) = .empty;
        try head.print(a, "{s} {s} HTTP/1.1\r\n", .{ req.method, req.target });
        req.headers.stripHop(wants_upgrade);
        req.headers.remove("host");
        req.headers.remove("x-forwarded-host");
        req.headers.remove("x-forwarded-proto");
        req.headers.remove("expect");
        try req.headers.writeTo(a, &head);
        try head.print(a, "host: {s}\r\nx-forwarded-host: {s}\r\nx-forwarded-proto: http\r\n", .{ host, host });
        if (request_body == .chunked) try head.appendSlice(a, "transfer-encoding: chunked\r\n");
        try head.appendSlice(a, if (wants_upgrade) "connection: upgrade\r\n\r\n" else "connection: close\r\n\r\n");
        try upstream.writeAll(head.items);
        if (expect_continue and request_body != .none) try client.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
        try p.copyBody(client, &upstream, request_body);

        // Response head; interim 1xx (other than 101) are not passed on.
        var resp: Response = while (true) {
            const rh = (try upstream.readHead(a, null)) orelse return error.UpstreamClosed;
            const r = try parseResponse(a, rh);
            if (r.status >= 100 and r.status < 200 and r.status != 101) continue;
            break r;
        };
        if (resp.status == 101) {
            if (!wants_upgrade) return error.UnsolicitedServerUpgrade;
            resp.headers.stripHop(true);
            var out: std.ArrayList(u8) = .empty;
            try out.print(a, "HTTP/1.1 101 {s}\r\n", .{resp.reason});
            try resp.headers.writeTo(a, &out);
            try out.appendSlice(a, "connection: upgrade\r\n\r\n");
            try client.writeAll(out.items);
            p.tunnel(client, &upstream);
            return false;
        }
        const no_body = std.ascii.eqlIgnoreCase(req.method, "HEAD") or resp.status == 204 or resp.status == 304;
        const response_body: Framing = if (no_body) .none else resp.headers.bodyFraming(true);
        const keep = !client_close and response_body != .until_close;
        resp.headers.stripHop(false);
        if (resp.headers.getPtr("location")) |loc| {
            const upstream_prefix = try std.fmt.allocPrint(a, "http://localhost:{d}", .{route.service.port});
            if (std.mem.startsWith(u8, loc.*, upstream_prefix)) {
                const path = loc.*[upstream_prefix.len..];
                if (path.len == 0 or path[0] == '/' or path[0] == '?' or path[0] == '#')
                    loc.* = try std.fmt.allocPrint(a, "http://{s}{s}", .{ host, path });
            }
        }
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "HTTP/1.1 {d} {s}\r\n", .{ resp.status, resp.reason });
        try resp.headers.writeTo(a, &out);
        if (response_body == .chunked) try out.appendSlice(a, "transfer-encoding: chunked\r\n");
        try out.appendSlice(a, if (keep) "\r\n" else "connection: close\r\n\r\n");
        try client.writeAll(out.items);
        try p.copyBody(&upstream, client, response_body);
        return keep;
    }

    fn copyBody(p: *Proxy, src: *Conn, dst: *Conn, framing: Framing) !void {
        _ = p;
        switch (framing) {
            .none => {},
            .length => |n| try src.copyN(dst, n),
            .until_close => try src.copyUntilClose(dst),
            .chunked => {
                while (true) {
                    const line = (try src.readLine()) orelse return error.UpstreamClosed;
                    try dst.writeAll(line);
                    const size_text = std.mem.trim(u8, line[0 .. std.mem.indexOfAny(u8, line, ";\r\n") orelse line.len], " \t");
                    const size = std.fmt.parseInt(u64, size_text, 16) catch return error.InvalidChunk;
                    if (size == 0) {
                        // Trailers, then the empty line.
                        while (true) {
                            const t = (try src.readLine()) orelse return error.UpstreamClosed;
                            try dst.writeAll(t);
                            if (std.mem.eql(u8, t, "\r\n") or std.mem.eql(u8, t, "\n")) break;
                        }
                        break;
                    }
                    try src.copyN(dst, size + 2);
                }
            },
        }
        try dst.flush();
    }

    /// Bytes both ways until both sides finish (or the proxy stops).
    fn tunnel(p: *Proxy, a: *Conn, b: *Conn) void {
        a.flush() catch return;
        b.flush() catch return;
        // Bytes already read past a head go first.
        if (a.end > a.start) {
            b.writeAll(a.buf[a.start..a.end]) catch return;
            b.flush() catch return;
            a.start = a.end;
        }
        if (b.end > b.start) {
            a.writeAll(b.buf[b.start..b.end]) catch return;
            a.flush() catch return;
            b.start = b.end;
        }
        var a_done = false;
        var b_done = false;
        var buf: [16 * 1024]u8 = undefined;
        while (!p.stopped() and !(a_done and b_done)) {
            const ready = pollTwo(a.s.socket.handle, !a_done, b.s.socket.handle, !b_done, poll_ms);
            inline for (.{ .{ 0, false }, .{ 1, true } }) |side| {
                const from = if (side[1]) b else a;
                const to = if (side[1]) a else b;
                const done = if (side[1]) &b_done else &a_done;
                if (ready[side[0]] and !done.*) {
                    var bufs = [_][]u8{&buf};
                    const n = (from.s.readWithControl(p.io, &bufs, &.{}) catch return).data_len;
                    if (n == 0) {
                        done.* = true;
                        to.s.shutdown(p.io, .send) catch {};
                    } else {
                        to.writeAll(buf[0..n]) catch return;
                        to.flush() catch return;
                    }
                }
            }
        }
    }
};

fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.PreviewNotRunning => not_running,
        error.OnlyOriginForm => "only origin-form HTTP requests are supported",
        error.MissingPreviewHostname => "missing preview hostname",
        error.InvalidAuthority => "invalid authority",
        error.IncorrectPreviewProxyPort => "incorrect preview proxy port",
        error.PreviewProcessChanged => "preview process changed; waiting for rediscovery",
        error.UnsolicitedServerUpgrade => "unsolicited server upgrade",
        error.InvalidPreviewConnect => "invalid preview CONNECT",
        error.UnknownPreviewConnectTarget => "unknown preview CONNECT target",
        error.NoPermitsAvailable => "no permits available",
        error.ConnectionRefused => "Connection refused",
        error.UpstreamClosed => "connection closed before message completed",
        else => @errorName(e),
    };
}

// ---------------------------------------------------------------- framing

const Framing = union(enum) { none, length: u64, chunked, until_close };

const Header = struct { name: []const u8, value: []const u8 };

const Headers = struct {
    a: Allocator,
    list: std.ArrayList(Header) = .empty,

    fn get(h: *const Headers, name: []const u8) ?[]const u8 {
        for (h.list.items) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
        return null;
    }

    fn getPtr(h: *Headers, name: []const u8) ?*[]const u8 {
        for (h.list.items) |*x| if (std.ascii.eqlIgnoreCase(x.name, name)) return &x.value;
        return null;
    }

    fn remove(h: *Headers, name: []const u8) void {
        var i: usize = 0;
        while (i < h.list.items.len) {
            if (std.ascii.eqlIgnoreCase(h.list.items[i].name, name)) {
                _ = h.list.orderedRemove(i);
            } else i += 1;
        }
    }

    fn connectionHas(h: *const Headers, token: []const u8) bool {
        for (h.list.items) |x| {
            if (!std.ascii.eqlIgnoreCase(x.name, "connection")) continue;
            var it = std.mem.splitScalar(u8, x.value, ',');
            while (it.next()) |v| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), token)) return true;
        }
        return false;
    }

    /// Chunked when the last transfer coding is chunked, else Content-Length;
    /// with neither, a response runs until close and a request has no body.
    fn bodyFraming(h: *const Headers, response: bool) Framing {
        var chunked = false;
        var any_te = false;
        for (h.list.items) |x| {
            if (!std.ascii.eqlIgnoreCase(x.name, "transfer-encoding")) continue;
            any_te = true;
            var it = std.mem.splitScalar(u8, x.value, ',');
            var last: []const u8 = "";
            while (it.next()) |v| last = std.mem.trim(u8, v, " \t");
            chunked = std.ascii.eqlIgnoreCase(last, "chunked");
        }
        if (chunked) return .chunked;
        if (any_te) return if (response) .until_close else .none;
        if (h.get("content-length")) |cl| {
            const n = std.fmt.parseInt(u64, std.mem.trim(u8, cl, " \t"), 10) catch return if (response) .until_close else .none;
            return if (n == 0) .none else .{ .length = n };
        }
        return if (response) .until_close else .none;
    }

    /// `strip_hop_headers`, keeping framing aside (re-added by the caller).
    fn stripHop(h: *Headers, upgrade: bool) void {
        var nominated: std.ArrayList([]const u8) = .empty;
        for (h.list.items) |x| {
            if (!std.ascii.eqlIgnoreCase(x.name, "connection")) continue;
            var it = std.mem.splitScalar(u8, x.value, ',');
            while (it.next()) |v| {
                const t = std.mem.trim(u8, v, " \t");
                if (t.len > 0) nominated.append(h.a, t) catch {};
            }
        }
        for (nominated.items) |name| {
            if (!(upgrade and std.ascii.eqlIgnoreCase(name, "upgrade"))) h.remove(name);
        }
        for ([_][]const u8{ "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding" }) |n| h.remove(n);
        if (!upgrade) h.remove("upgrade");
    }

    fn writeTo(h: *const Headers, a: Allocator, out: *std.ArrayList(u8)) !void {
        for (h.list.items) |x| try out.print(a, "{s}: {s}\r\n", .{ x.name, x.value });
    }
};

const Request = struct { method: []const u8, target: []const u8, http10: bool, headers: Headers };
const Response = struct { status: u16, reason: []const u8, headers: Headers };

fn parseHeaders(a: Allocator, lines: *std.mem.SplitIterator(u8, .sequence)) !Headers {
    var h: Headers = .{ .a = a };
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
        const name = line[0..colon];
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t") != null) return error.BadHeader;
        try h.list.append(a, .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " \t") });
    }
    return h;
}

fn parseRequest(a: Allocator, head: []const u8) !Request {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const first = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (parts.next() != null or method.len == 0 or target.len == 0) return error.BadRequest;
    const http10 = std.mem.eql(u8, version, "HTTP/1.0");
    if (!http10 and !std.mem.eql(u8, version, "HTTP/1.1")) return error.BadRequest;
    return .{ .method = method, .target = target, .http10 = http10, .headers = try parseHeaders(a, &lines) };
}

fn parseResponse(a: Allocator, head: []const u8) !Response {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const first = lines.next() orelse return error.BadResponse;
    if (first.len < 12 or !std.mem.startsWith(u8, first, "HTTP/1.")) return error.BadResponse;
    const status = std.fmt.parseInt(u16, first[9..12], 10) catch return error.BadResponse;
    const reason = if (first.len > 13) first[13..] else "";
    return .{ .status = status, .reason = reason, .headers = try parseHeaders(a, &lines) };
}

const HostPort = struct { host: []const u8, port: ?u16 };

fn splitAuthority(authority: []const u8) ?HostPort {
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        const rest = authority[close + 1 ..];
        if (rest.len == 0) return .{ .host = authority[0 .. close + 1], .port = null };
        if (rest[0] != ':') return null;
        return .{ .host = authority[0 .. close + 1], .port = std.fmt.parseInt(u16, rest[1..], 10) catch return null };
    }
    if (std.mem.indexOfAny(u8, authority, "/?#@ ") != null) return null;
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return .{ .host = authority, .port = null };
    return .{ .host = authority[0..colon], .port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null };
}

// ---------------------------------------------------------------- sockets

const Conn = struct {
    p: *Proxy,
    s: net.Stream,
    buf: [32 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    out: [16 * 1024]u8 = undefined,
    out_len: usize = 0,

    /// More bytes into the buffer; false at end of stream.
    fn fill(c: *Conn, deadline: ?i64) !bool {
        if (c.start == c.end) {
            c.start = 0;
            c.end = 0;
        } else if (c.end == c.buf.len) {
            std.mem.copyForwards(u8, &c.buf, c.buf[c.start..c.end]);
            c.end -= c.start;
            c.start = 0;
        }
        if (c.end == c.buf.len) return error.HeadTooLarge;
        while (true) {
            if (c.p.stopped()) return error.Stopped;
            var wait = poll_ms;
            if (deadline) |d| {
                const left = d - discovery.nowMs(c.p.io);
                if (left <= 0) return error.Timeout;
                wait = @intCast(@min(left, poll_ms));
            }
            if (discovery.readable(c.s.socket.handle, wait)) break;
        }
        var bufs = [_][]u8{c.buf[c.end..]};
        const n = (try c.s.readWithControl(c.p.io, &bufs, &.{})).data_len;
        if (n == 0) return false;
        c.end += n;
        return true;
    }

    /// A message head through its blank line (copied into `a`); null when the
    /// peer closed before sending one.
    fn readHead(c: *Conn, a: Allocator, deadline: ?i64) !?[]u8 {
        var scanned: usize = 0;
        while (true) {
            const avail = c.buf[c.start..c.end];
            if (std.mem.indexOfPos(u8, avail, if (scanned > 3) scanned - 3 else 0, "\r\n\r\n")) |i| {
                const head = try a.dupe(u8, avail[0 .. i + 2]);
                c.start += i + 4;
                return head;
            }
            scanned = avail.len;
            if (avail.len >= max_head_bytes) return error.HeadTooLarge;
            if (!try c.fill(deadline)) {
                if (c.end == c.start) return null;
                return error.UpstreamClosed;
            }
        }
    }

    /// One line including its newline, from the buffer.
    fn readLine(c: *Conn) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, c.buf[c.start..c.end], '\n')) |i| {
                const line = c.buf[c.start .. c.start + i + 1];
                c.start += i + 1;
                return line;
            }
            if (c.end - c.start >= 8 * 1024) return error.LineTooLong;
            if (!try c.fill(null)) return null;
        }
    }

    fn copyN(c: *Conn, dst: *Conn, n_in: u64) !void {
        var n = n_in;
        while (n > 0) {
            if (c.start == c.end and !try c.fill(null)) return error.UpstreamClosed;
            const take: usize = @intCast(@min(n, c.end - c.start));
            try dst.writeAll(c.buf[c.start .. c.start + take]);
            c.start += take;
            n -= take;
        }
    }

    fn copyUntilClose(c: *Conn, dst: *Conn) !void {
        while (true) {
            if (c.start < c.end) {
                try dst.writeAll(c.buf[c.start..c.end]);
                c.start = c.end;
            }
            try dst.flush();
            if (!try c.fill(null)) return;
        }
    }

    fn writeAll(c: *Conn, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            if (c.out_len == c.out.len) try c.flush();
            const n = @min(rest.len, c.out.len - c.out_len);
            @memcpy(c.out[c.out_len..][0..n], rest[0..n]);
            c.out_len += n;
            rest = rest[n..];
        }
    }

    fn flush(c: *Conn) !void {
        if (c.out_len == 0) return;
        var w = c.s.writer(c.p.io, &.{});
        try w.interface.writeAll(c.out[0..c.out_len]);
        try w.interface.flush();
        c.out_len = 0;
    }

    fn writeError(c: *Conn, message: []const u8) !void {
        var head: [256]u8 = undefined;
        const h = try std.fmt.bufPrint(&head, "HTTP/1.1 502 Bad Gateway\r\ncontent-type: text/plain; charset=utf-8\r\ncache-control: no-store\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{message.len});
        try c.writeAll(h);
        try c.writeAll(message);
        try c.flush();
    }
};

fn pollTwo(a: net.Socket.Handle, want_a: bool, b: net.Socket.Handle, want_b: bool, ms: i32) [2]bool {
    if (comptime builtin.os.tag == .windows) {
        const WsaPollFd = extern struct { fd: net.Socket.Handle, events: i16, revents: i16 };
        const ws = struct {
            extern "ws2_32" fn WSAPoll(fdarray: [*]WsaPollFd, fds: u32, timeout: c_int) callconv(.winapi) c_int;
        };
        var fds = [_]WsaPollFd{
            .{ .fd = a, .events = if (want_a) 0x0100 else 0, .revents = 0 },
            .{ .fd = b, .events = if (want_b) 0x0100 else 0, .revents = 0 },
        };
        if (ws.WSAPoll(&fds, 2, ms) <= 0) return .{ false, false };
        return .{ want_a and fds[0].revents != 0, want_b and fds[1].revents != 0 };
    }
    const IN = std.posix.POLL.IN;
    var fds = [_]std.posix.pollfd{
        .{ .fd = a, .events = if (want_a) IN else 0, .revents = 0 },
        .{ .fd = b, .events = if (want_b) IN else 0, .revents = 0 },
    };
    const n = std.posix.poll(&fds, ms) catch return .{ false, false };
    if (n == 0) return .{ false, false };
    return .{ want_a and fds[0].revents != 0, want_b and fds[1].revents != 0 };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A made-up dev server: answers by path, records each request head.
const Upstream = struct {
    server: net.Server,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    last_head: [4096]u8 = undefined,
    last_len: usize = 0,

    fn begin(u: *Upstream) !void {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        u.server = try addr.listen(testing.io, .{});
        u.port = u.server.socket.address.getPort();
        u.thread = try std.Thread.spawn(.{}, run, .{u});
    }

    fn end(u: *Upstream) void {
        u.stop.store(true, .release);
        if (u.thread) |t| t.join();
        u.server.deinit(testing.io);
    }

    fn lastHead(u: *Upstream) []const u8 {
        u.mutex.lockUncancelable(testing.io);
        defer u.mutex.unlock(testing.io);
        return u.last_head[0..u.last_len];
    }

    fn run(u: *Upstream) void {
        while (!u.stop.load(.acquire)) {
            if (!discovery.readable(u.server.socket.handle, 50)) continue;
            const c = u.server.accept(testing.io) catch continue;
            u.serve(c);
            c.close(testing.io);
        }
    }

    fn serve(u: *Upstream, c: net.Stream) void {
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        const head_end = while (true) {
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |i| break i + 4;
            if (!discovery.readable(c.socket.handle, 3000)) return;
            var bufs = [_][]u8{buf[n..]};
            const got = (c.readWithControl(testing.io, &bufs, &.{}) catch return).data_len;
            if (got == 0) return;
            n += got;
        };
        {
            u.mutex.lockUncancelable(testing.io);
            defer u.mutex.unlock(testing.io);
            @memcpy(u.last_head[0..head_end], buf[0..head_end]);
            u.last_len = head_end;
        }
        const head = buf[0..head_end];
        var reply_buf: [512]u8 = undefined;
        var w = c.writer(testing.io, &.{});
        if (std.mem.startsWith(u8, head, "GET /hello ")) {
            w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nSet-Cookie: a=b\r\n\r\nhello") catch {};
        } else if (std.mem.startsWith(u8, head, "GET /redirect ")) {
            const r = std.fmt.bufPrint(&reply_buf, "HTTP/1.1 302 Found\r\nLocation: http://localhost:{d}/next?x=1\r\nContent-Length: 0\r\n\r\n", .{u.port}) catch return;
            w.interface.writeAll(r) catch {};
        } else if (std.mem.startsWith(u8, head, "GET /chunked ")) {
            w.interface.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n") catch {};
        } else if (std.mem.startsWith(u8, head, "POST /echo ")) {
            const body = buf[head_end..n];
            const r = std.fmt.bufPrint(&reply_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch return;
            w.interface.writeAll(r) catch {};
        } else if (std.mem.startsWith(u8, head, "GET /ws ")) {
            w.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n") catch return;
            // Echo until the client closes.
            while (discovery.readable(c.socket.handle, 3000)) {
                var bufs = [_][]u8{&buf};
                const got = (c.readWithControl(testing.io, &bufs, &.{}) catch return).data_len;
                if (got == 0) return;
                w.interface.writeAll(buf[0..got]) catch return;
            }
        } else {
            w.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") catch {};
        }
    }
};

const Fixture = struct {
    up: Upstream = undefined,
    cat: *Catalog = undefined,
    proxy: Proxy = undefined,
    port: u16 = 0,
    alive: bool = true,

    fn verify(ctx: ?*anyopaque, _: Allocator, _: Io, _: u32, _: u64) bool {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        return f.alive;
    }

    fn begin(f: *Fixture) !void {
        try f.up.begin();
        f.cat = try Catalog.open(testing.allocator, testing.io, null, "dev-a", "Mac");
        try f.cat.replaceLocal(&.{.{ .root = "/work/my-app", .listener = .{
            .pid = 4242,
            .cwd = "/work/my-app",
            .args = &.{ "node", "vite" },
            .started_at = 1,
            .address = .loopback4(f.up.port),
        } }});
        f.proxy = .{ .gpa = testing.allocator, .io = testing.io, .catalog = f.cat, .verify = .{ .ctx = f, .func = verify } };
        f.port = try f.proxy.bind(0);
        f.cat.setProxyStatus(f.port, null);
        try f.proxy.start();
    }

    fn end(f: *Fixture) void {
        f.proxy.stop();
        f.up.end();
        f.cat.deinit();
    }
};

const Client = struct {
    s: net.Stream,
    buf: [16384]u8 = undefined,
    len: usize = 0,

    fn open(port: u16) !Client {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
        return .{ .s = try addr.connect(testing.io, .{ .mode = .stream }) };
    }

    fn send(c: *Client, bytes: []const u8) !void {
        var w = c.s.writer(testing.io, &.{});
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// Read until `needle` shows up (or 3 s pass); the bytes so far.
    fn until(c: *Client, needle: []const u8) []const u8 {
        const deadline = discovery.nowMs(testing.io) + 3000;
        while (std.mem.indexOf(u8, c.buf[0..c.len], needle) == null) {
            const left = deadline - discovery.nowMs(testing.io);
            if (left <= 0 or !discovery.readable(c.s.socket.handle, @intCast(left))) break;
            var bufs = [_][]u8{c.buf[c.len..]};
            const got = (c.s.readWithControl(testing.io, &bufs, &.{}) catch break).data_len;
            if (got == 0) break;
            c.len += got;
        }
        return c.buf[0..c.len];
    }

    fn reset(c: *Client) void {
        c.len = 0;
    }
};

test "the preview proxy forwards by catalog hostname and rewrites redirects" {
    var f: Fixture = .{};
    try f.begin();
    defer f.end();
    var c = try Client.open(f.port);
    defer c.s.close(testing.io);
    var req: [512]u8 = undefined;
    try c.send(try std.fmt.bufPrint(&req, "GET /hello HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\nOrigin: http://mac.my-app.localhost:{d}\r\nProxy-Authorization: Basic c2VjcmV0\r\nX-Forwarded-Host: evil\r\n\r\n", .{ f.port, f.port }));
    const r1 = c.until("hello");
    try testing.expect(std.mem.startsWith(u8, r1, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, r1, "Set-Cookie: a=b") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "Keep-Alive") == null);
    try testing.expect(std.mem.endsWith(u8, r1, "\r\n\r\nhello"));
    const seen = f.up.lastHead();
    var expect_host: [128]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, seen, try std.fmt.bufPrint(&expect_host, "x-forwarded-host: mac.my-app.localhost:{d}", .{f.port})) != null);
    try testing.expect(std.mem.indexOf(u8, seen, try std.fmt.bufPrint(&expect_host, "Origin: http://mac.my-app.localhost:{d}", .{f.port})) != null);
    try testing.expect(std.mem.indexOf(u8, seen, "x-forwarded-proto: http") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "Proxy-Authorization") == null);
    try testing.expect(std.mem.indexOf(u8, seen, "evil") == null);

    // Same connection: an absolute localhost redirect becomes the preview origin.
    c.reset();
    try c.send(try std.fmt.bufPrint(&req, "GET /redirect HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\n\r\n", .{f.port}));
    const r2 = c.until("\r\n\r\n");
    var loc: [128]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, r2, try std.fmt.bufPrint(&loc, "Location: http://mac.my-app.localhost:{d}/next?x=1", .{f.port})) != null);

    c.reset();
    try c.send(try std.fmt.bufPrint(&req, "GET /chunked HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\n\r\n", .{f.port}));
    const r3 = c.until("0\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, r3, "transfer-encoding: chunked\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, r3, "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"));

    c.reset();
    try c.send(try std.fmt.bufPrint(&req, "POST /echo HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\nContent-Length: 4\r\nConnection: close\r\n\r\nping", .{f.port}));
    const r4 = c.until("ping");
    try testing.expect(std.mem.indexOf(u8, r4, "connection: close") != null);
    try testing.expect(std.mem.endsWith(u8, r4, "ping"));
}

test "the preview proxy refuses unknown names, wrong ports and stale processes" {
    var f: Fixture = .{};
    try f.begin();
    defer f.end();
    var req: [512]u8 = undefined;
    const cases = [_]struct { host: []const u8, port_delta: u16, want: []const u8 }{
        .{ .host = "mac.other.localhost", .port_delta = 0, .want = not_running },
        .{ .host = "mac.my-app.localhost", .port_delta = 1, .want = "incorrect preview proxy port" },
    };
    for (cases) |case| {
        var c = try Client.open(f.port);
        defer c.s.close(testing.io);
        try c.send(try std.fmt.bufPrint(&req, "GET / HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ case.host, f.port +% case.port_delta }));
        const r = c.until(case.want);
        try testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 502 Bad Gateway\r\n"));
        try testing.expect(std.mem.indexOf(u8, r, "cache-control: no-store") != null);
        try testing.expect(std.mem.endsWith(u8, r, case.want));
    }
    {
        var c = try Client.open(f.port);
        defer c.s.close(testing.io);
        try c.send("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n");
        try testing.expect(std.mem.endsWith(u8, c.until("supported"), "only origin-form HTTP requests are supported"));
    }
    {
        var c = try Client.open(f.port);
        defer c.s.close(testing.io);
        try c.send("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n");
        try testing.expect(std.mem.endsWith(u8, c.until("target"), "unknown preview CONNECT target"));
    }
    f.alive = false;
    {
        var c = try Client.open(f.port);
        defer c.s.close(testing.io);
        try c.send(try std.fmt.bufPrint(&req, "GET /hello HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\n\r\n", .{f.port}));
        try testing.expect(std.mem.endsWith(u8, c.until("rediscovery"), "preview process changed; waiting for rediscovery"));
    }
}

test "the preview proxy keeps websocket bytes and CONNECT tunnels" {
    var f: Fixture = .{};
    try f.begin();
    defer f.end();
    var req: [512]u8 = undefined;
    {
        var c = try Client.open(f.port);
        defer c.s.close(testing.io);
        try c.send(try std.fmt.bufPrint(&req, "GET /ws HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: vite-hmr\r\n\r\n", .{f.port}));
        const r = c.until("\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 101 Switching Protocols\r\n"));
        try testing.expect(std.mem.indexOf(u8, r, "Upgrade: websocket") != null);
        try testing.expect(std.mem.indexOf(u8, f.up.lastHead(), "Sec-WebSocket-Protocol: vite-hmr") != null);
        try testing.expect(std.mem.indexOf(u8, f.up.lastHead(), "connection: upgrade") != null);
        c.reset();
        try c.send("\x81\x04ping");
        try testing.expectEqualStrings("\x81\x04ping", c.until("ping"));
    }
    {
        var c = try Client.open(f.port);
        defer c.s.close(testing.io);
        try c.send(try std.fmt.bufPrint(&req, "CONNECT mac.my-app.localhost:{d} HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\n\r\n", .{ f.port, f.port }));
        try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\n", c.until("\r\n\r\n"));
        c.reset();
        try c.send(try std.fmt.bufPrint(&req, "GET /hello HTTP/1.1\r\nHost: mac.my-app.localhost:{d}\r\n\r\n", .{f.port}));
        try testing.expect(std.mem.endsWith(u8, c.until("hello"), "hello"));
    }
}

test "the preview proxy reports a taken port" {
    const io = testing.io;
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var taken = try addr.listen(io, .{});
    defer taken.deinit(io);
    const cat = try Catalog.open(testing.allocator, io, null, "dev-a", "Mac");
    defer cat.deinit();
    var p: Proxy = .{ .gpa = testing.allocator, .io = io, .catalog = cat, .verify = nativeVerify() };
    try testing.expectError(error.AddressInUse, p.bind(taken.socket.address.getPort()));
}
