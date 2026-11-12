//! `RoomRequest`, ported from `crates/engine/src/rpc.rs` (`methods::ROOM_REQUEST`)
//! and `crates/engine/src/doc_host.rs` (`DocHost::room_request`).
//!
//! Agent rooms live on the edge server (`edge/src/room-core.ts`). The engine
//! makes one authenticated call to the edge's `/rooms…` or `/room/{id}/…`
//! routes with the signed-in session's bearer and answers `{status, body}`,
//! so the caller sees the room's own replies and refusals (`not_a_member`,
//! `secret_detected`, `claim_held`) intact. Only room paths pass: this is not
//! a general edge proxy.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");

const RpcOutcome = common.RpcOutcome;

/// `.timeout(Duration::from_secs(20))`.
pub const timeout_ms: u32 = 20_000;

/// The room routes `room_request` lets through. Pure.
pub fn isRoomPath(path: []const u8) bool {
    const fixed = [_][]const u8{ "rooms", "rooms/inbox", "rooms/invites", "rooms/wakes", "rooms/wakes/ack" };
    for (fixed) |p| if (std.mem.eql(u8, path, p)) return true;
    if (!std.mem.startsWith(u8, path, "room/")) return false;
    const rest = path["room/".len..];
    if (std.mem.indexOf(u8, rest, "..") != null) return false;
    return std.mem.count(u8, rest, "/") == 1;
}

/// `form_urlencoded::byte_serialize` (what reqwest's `.query()` writes):
/// alphanumerics and `*-._` pass, space is `+`, the rest `%XX`.
fn formEncode(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '*' or b == '-' or b == '.' or b == '_') {
            try w.writeByte(b);
        } else if (b == ' ') {
            try w.writeByte('+');
        } else {
            try w.print("%{X:0>2}", .{b});
        }
    }
}

pub const Params = struct {
    method: []const u8,
    path: []const u8,
    query: []const [2][]const u8,
    /// `None` when absent or `null`.
    body: ?json.Value,
};

/// `parse_params::<P>`; a refusal is serde's message. `arena` owns the query.
pub fn parseParams(arena: Allocator, params: json.Value) !union(enum) { ok: Params, bad: []const u8 } {
    const o = common.obj(params) orelse return .{ .bad = "invalid type: expected struct P" };
    const method_v = o.get("method") orelse return .{ .bad = "missing field `method`" };
    if (method_v != .string) return .{ .bad = "invalid type: expected a string for `method`" };
    const path_v = o.get("path") orelse return .{ .bad = "missing field `path`" };
    if (path_v != .string) return .{ .bad = "invalid type: expected a string for `path`" };
    var query: std.ArrayList([2][]const u8) = .empty;
    if (o.get("query")) |qv| {
        if (qv != .array) return .{ .bad = "invalid type: expected a sequence for `query`" };
        for (qv.array.items) |pair| {
            if (pair != .array or pair.array.items.len != 2) return .{ .bad = "invalid length: expected a tuple of size 2 in `query`" };
            const k = pair.array.items[0];
            const v = pair.array.items[1];
            if (k != .string or v != .string) return .{ .bad = "invalid type: expected a string in `query`" };
            try query.append(arena, .{ k.string, v.string });
        }
    }
    const body: ?json.Value = if (o.get("body")) |b| (if (b == .null) null else b) else null;
    return .{ .ok = .{ .method = method_v.string, .path = path_v.string, .query = query.items, .body = body } };
}

/// `{edge}/{path}` plus the query pairs, as reqwest builds it. Pure.
pub fn buildUrl(gpa: Allocator, edge_url: []const u8, path: []const u8, query: []const [2][]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{s}/{s}", .{ std.mem.trimEnd(u8, edge_url, "/"), path });
    for (query, 0..) |pair, i| {
        try w.writeByte(if (i == 0) '?' else '&');
        try formEncode(w, pair[0]);
        try w.writeByte('=');
        try formEncode(w, pair[1]);
    }
    return aw.toOwnedSlice();
}

/// `describe_http_error`: the edge's origin, then what went wrong.
pub fn describeTransportError(edge_url: []const u8, err: anyerror) []const u8 {
    const origin = originOf(edge_url);
    const cause: []const u8 = switch (err) {
        error.Timeout => "operation timed out",
        error.ConnectionRefused => "client error (Connect): tcp connect error: Connection refused",
        error.ConnectionResetByPeer => "connection reset by peer",
        error.UnknownHostName, error.NameServerFailure, error.HostLacksNetworkAddresses => "client error (Connect): dns error: failed to lookup address information",
        error.EndOfStream => "connection closed before message completed",
        else => @errorName(err),
    };
    return common.errText("{s}: error sending request: {s}", .{ origin, cause });
}

/// `url.origin().ascii_serialization()`: scheme and authority, no path.
fn originOf(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const after = url[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    return url[0 .. scheme_end + 3 + end];
}

/// `RoomRequest { method, path, query, body }` → `{status, body}`.
pub fn roomRequest(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = switch (try parseParams(arena, params)) {
        .bad => |m| return .{ .err = .{ .bad_params = m } },
        .ok => |v| v,
    };
    if (!isRoomPath(p.path)) return common.failed("not a room path: {s}", .{p.path});
    const edge_url = host.auth.edge_url orelse return common.failed("rooms need a signed-in engine (no edge configured)", .{});
    const io = host.io orelse return common.failed("rooms need a signed-in engine (no edge configured)", .{});
    if (!host.auth.signed_in) return common.failed("signed out", .{});
    const bearer = host.auth.ensureAccessToken(io, false) orelse return common.failed("signed out", .{});
    // Copied: a refresh during the request may replace the token.
    const bearer_owned = try arena.dupe(u8, bearer);
    const edge_owned = try arena.dupe(u8, edge_url);

    const body_text: ?[]const u8 = if (std.mem.eql(u8, p.method, "GET"))
        null
    else if (std.mem.eql(u8, p.method, "POST"))
        (if (p.body) |b| try std.fmt.allocPrint(arena, "{f}", .{json.fmt(b, .{})}) else "{}")
    else
        return common.failed("unsupported method {s}", .{p.method});

    const url = try buildUrl(arena, edge_owned, p.path, p.query);
    var reply = auth_host.AuthManager.edgeRequestTimed(&host.auth.h2_pool, gpa, io, p.method, url, bearer_owned, &.{}, body_text, timeout_ms) catch |e|
        return common.failedMsg(describeTransportError(edge_owned, e));
    defer reply.deinit(gpa);
    return .{ .unary_json = try replyJson(gpa, reply.status, reply.body) };
}

/// `json!({ "status": status, "body": res.json().unwrap_or(Null) })`: the
/// edge's JSON as sent, or `null` when the body isn't JSON. Pure.
pub fn replyJson(gpa: Allocator, status: u16, body: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const valid = trimmed.len > 0 and (json.validate(gpa, trimmed) catch false);
    return std.fmt.allocPrint(gpa, "{{\"status\":{d},\"body\":{s}}}", .{ status, if (valid) trimmed else "null" });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const net = std.Io.net;

test "rpcw_rooms isRoomPath lets only the room routes through" {
    for ([_][]const u8{ "rooms", "rooms/inbox", "rooms/invites", "rooms/wakes", "rooms/wakes/ack", "room/r1/post", "room/room_0123/state" }) |ok| {
        try testing.expect(isRoomPath(ok));
    }
    for ([_][]const u8{ "", "rooms/", "room/r1", "room/r1/a/b", "room/../x", "room/r1/..", "chat2/c1/tail", "auth/refresh", "/rooms", "rooms/other" }) |bad| {
        try testing.expect(!isRoomPath(bad));
    }
}

test "rpcw_rooms buildUrl appends form-encoded query pairs like reqwest" {
    const gpa = testing.allocator;
    const url_a = try buildUrl(gpa, "https://edge.example.test/", "rooms", &.{});
    defer gpa.free(url_a);
    try testing.expectEqualStrings("https://edge.example.test/rooms", url_a);
    const url_b = try buildUrl(gpa, "http://127.0.0.1:9", "room/r1/messages", &.{ .{ "after", "5" }, .{ "q", "a b&c/é~" } });
    defer gpa.free(url_b);
    try testing.expectEqualStrings("http://127.0.0.1:9/room/r1/messages?after=5&q=a+b%26c%2F%C3%A9%7E", url_b);
}

test "rpcw_rooms replyJson passes the edge's JSON and nulls anything else" {
    const gpa = testing.allocator;
    const a = try replyJson(gpa, 409, "{\"error\":\"claim_held\",\"holder\":\"beta\"}\n");
    defer gpa.free(a);
    try testing.expectEqualStrings("{\"status\":409,\"body\":{\"error\":\"claim_held\",\"holder\":\"beta\"}}", a);
    const b = try replyJson(gpa, 502, "<html>bad gateway</html>");
    defer gpa.free(b);
    try testing.expectEqualStrings("{\"status\":502,\"body\":null}", b);
    const c = try replyJson(gpa, 204, "");
    defer gpa.free(c);
    try testing.expectEqualStrings("{\"status\":204,\"body\":null}", c);
}

/// A loopback edge: answers every request with `status`/`body` and records
/// the request line, authorization header and body of the last one.
const FakeEdge = struct {
    server: net.Server = undefined,
    port: u16 = 0,
    status: u16 = 200,
    body: []const u8 = "{}",
    stop: std.atomic.Value(bool) = .init(false),
    last: [4096]u8 = undefined,
    last_len: usize = 0,
    hits: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    fn start(self: *FakeEdge) !void {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        self.server = try addr.listen(testing.io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    fn loop(self: *FakeEdge) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.server.accept(testing.io) catch return;
            defer stream.close(testing.io);
            if (self.stop.load(.acquire)) return;
            var rbuf: [4096]u8 = undefined;
            var reader = stream.reader(testing.io, &rbuf);
            var n: usize = 0;
            var content_len: usize = 0;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch break;
                const t = std.mem.trimEnd(u8, line, "\r\n");
                if (n + t.len + 1 < self.last.len and (n == 0 or std.ascii.startsWithIgnoreCase(t, "authorization:"))) {
                    @memcpy(self.last[n .. n + t.len], t);
                    self.last[n + t.len] = '\n';
                    n += t.len + 1;
                }
                if (std.ascii.startsWithIgnoreCase(t, "content-length:")) {
                    content_len = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " "), 10) catch 0;
                }
                if (t.len == 0) break;
            }
            if (content_len > 0 and n + content_len < self.last.len) {
                reader.interface.readSliceAll(self.last[n .. n + content_len]) catch {};
                n += content_len;
            }
            self.last_len = n;
            _ = self.hits.fetchAdd(1, .acq_rel);
            var wbuf: [1024]u8 = undefined;
            var w = stream.writer(testing.io, &wbuf);
            w.interface.print("HTTP/1.1 {d} X\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.status, self.body.len, self.body }) catch {};
            w.interface.flush() catch {};
        }
    }

    fn shutdown(self: *FakeEdge) void {
        self.stop.store(true, .release);
        if (net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
            if (addr.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }

    fn lastRequest(self: *FakeEdge) []const u8 {
        return self.last[0..self.last_len];
    }
};

const Fx = struct {
    host: engine_host.EngineHost,
    edge: FakeEdge = .{},

    fn init(signed_in: bool) !*Fx {
        const gpa = testing.allocator;
        const f = try gpa.create(Fx);
        f.* = .{ .host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic") };
        f.host.io = testing.io;
        try f.edge.start();
        if (f.host.auth.edge_url) |old| gpa.free(old);
        f.host.auth.edge_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{f.edge.port});
        if (signed_in) {
            if (f.host.auth.access_token) |old| gpa.free(old);
            f.host.auth.access_token = try gpa.dupe(u8, "synthetic-access-token");
            f.host.auth.access_expires_at_ms = 0;
            f.host.auth.signed_in = true;
        }
        return f;
    }

    fn deinit(f: *Fx) void {
        f.edge.shutdown();
        f.host.deinit();
        testing.allocator.destroy(f);
    }

    fn call(f: *Fx, params_text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        return f.host.handle("RoomRequest", p.value);
    }
};

fn expectErr(outcome: RpcOutcome, comptime kind: std.meta.Tag(engine_host.RpcError), expected: []const u8) !void {
    switch (outcome) {
        .err => |e| {
            try testing.expectEqual(kind, std.meta.activeTag(e));
            switch (e) {
                inline else => |m| try testing.expectEqualStrings(expected, m),
            }
        },
        .unary_json => |b| {
            std.debug.print("unexpected success: {s}\n", .{b});
            testing.allocator.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

test "rpcw_rooms RoomRequest forwards GET with the bearer and query, answering the edge's status and body" {
    const f = try Fx.init(true);
    defer f.deinit();
    f.edge.body = "{\"rooms\":[{\"id\":\"room_synthetic\",\"name\":\"build\"}]}";
    const ok = try f.call("{\"method\":\"GET\",\"path\":\"rooms\",\"query\":[[\"limit\",\"10\"],[\"q\",\"a b\"]],\"body\":null}");
    defer testing.allocator.free(ok.unary_json);
    try testing.expectEqualStrings("{\"status\":200,\"body\":{\"rooms\":[{\"id\":\"room_synthetic\",\"name\":\"build\"}]}}", ok.unary_json);
    const last = f.edge.lastRequest();
    try testing.expect(std.mem.startsWith(u8, last, "GET /rooms?limit=10&q=a+b HTTP/1.1\n"));
    try testing.expect(std.mem.indexOf(u8, last, "Bearer synthetic-access-token") != null);
}

test "rpcw_rooms RoomRequest POSTs the body (or {}) and hands back the edge's refusals intact" {
    const f = try Fx.init(true);
    defer f.deinit();
    f.edge.status = 422;
    f.edge.body = "{\"error\":\"secret_detected\",\"message\":\"the post looks like it holds a key\"}";
    const refused = try f.call("{\"method\":\"POST\",\"path\":\"room/room_synthetic/post\",\"body\":{\"body\":\"hello\",\"claimKey\":\"task-1\"}}");
    defer testing.allocator.free(refused.unary_json);
    try testing.expectEqualStrings("{\"status\":422,\"body\":{\"error\":\"secret_detected\",\"message\":\"the post looks like it holds a key\"}}", refused.unary_json);
    const last = f.edge.lastRequest();
    try testing.expect(std.mem.startsWith(u8, last, "POST /room/room_synthetic/post HTTP/1.1\n"));
    try testing.expect(std.mem.endsWith(u8, last, "{\"body\":\"hello\",\"claimKey\":\"task-1\"}"));

    f.edge.status = 409;
    f.edge.body = "{\"error\":\"claim_held\"}";
    const held = try f.call("{\"method\":\"POST\",\"path\":\"rooms/wakes/ack\"}");
    defer testing.allocator.free(held.unary_json);
    try testing.expectEqualStrings("{\"status\":409,\"body\":{\"error\":\"claim_held\"}}", held.unary_json);
    try testing.expect(std.mem.endsWith(u8, f.edge.lastRequest(), "\n{}"));

    f.edge.status = 500;
    f.edge.body = "upstream exploded";
    const not_json = try f.call("{\"method\":\"GET\",\"path\":\"rooms/inbox\"}");
    defer testing.allocator.free(not_json.unary_json);
    try testing.expectEqualStrings("{\"status\":500,\"body\":null}", not_json.unary_json);
}

test "rpcw_rooms RoomRequest refuses bad params, non-room paths, other methods and signed-out engines" {
    const f = try Fx.init(true);
    defer f.deinit();
    try expectErr(try f.call("{\"path\":\"rooms\"}"), .bad_params, "missing field `method`");
    try expectErr(try f.call("{\"method\":\"GET\"}"), .bad_params, "missing field `path`");
    try expectErr(try f.call("{\"method\":\"GET\",\"path\":\"rooms\",\"query\":[[\"a\"]]}"), .bad_params, "invalid length: expected a tuple of size 2 in `query`");
    try expectErr(try f.call("{\"method\":\"GET\",\"path\":\"chat2/c1/tail\"}"), .exec_error, "not a room path: chat2/c1/tail");
    try expectErr(try f.call("{\"method\":\"GET\",\"path\":\"room/../auth\"}"), .exec_error, "not a room path: room/../auth");
    try expectErr(try f.call("{\"method\":\"DELETE\",\"path\":\"rooms\"}"), .exec_error, "unsupported method DELETE");
    try testing.expectEqual(@as(u32, 0), f.edge.hits.load(.acquire));

    f.host.auth.signed_in = false;
    try expectErr(try f.call("{\"method\":\"GET\",\"path\":\"rooms\"}"), .exec_error, "signed out");
    testing.allocator.free(f.host.auth.edge_url.?);
    f.host.auth.edge_url = null;
    try expectErr(try f.call("{\"method\":\"GET\",\"path\":\"rooms\"}"), .exec_error, "rooms need a signed-in engine (no edge configured)");
}

test "rpcw_rooms RoomRequest maps an unreachable edge to describe_http_error's wording" {
    const f = try Fx.init(true);
    defer f.deinit();
    // A port nothing listens on: bind, note the port, close.
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var probe = try addr.listen(testing.io, .{ .reuse_address = true });
    const dead_port = probe.socket.address.getPort();
    probe.deinit(testing.io);
    testing.allocator.free(f.host.auth.edge_url.?);
    f.host.auth.edge_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{dead_port});
    var want_buf: [128]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "http://127.0.0.1:{d}: error sending request: client error (Connect): tcp connect error: Connection refused", .{dead_port});
    try expectErr(try f.call("{\"method\":\"GET\",\"path\":\"rooms\"}"), .exec_error, want);
}

test "rpcw_rooms describeTransportError words a deadline like reqwest" {
    try testing.expectEqualStrings(
        "https://edge.example.test: error sending request: operation timed out",
        describeTransportError("https://edge.example.test/", error.Timeout),
    );
}
