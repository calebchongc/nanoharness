//! Engine-level tests for the sign-in, credential, update and start-up
//! hardening (`zig/fix-sec`). Synthetic data only: temporary directories and
//! in-process loopback servers; nothing here reaches the network.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");

const EngineHost = engine_host.EngineHost;

fn urlParam(a: std.mem.Allocator, reply_json: []const u8, name: []const u8) ![]const u8 {
    const v = try json.parseFromSliceLeaky(json.Value, a, reply_json, .{});
    const url = v.object.get("url").?.string;
    return (try auth_host.extractQueryParamAlloc(a, url, name)) orelse error.MissingParam;
}

test "fix-sec 1: SignInHeadless: every sign-in has its own random state and PKCE challenge and the configured client id" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var host = try EngineHost.init(gpa, "dev-sec-1", "SecHost");
    defer host.deinit();
    host.io = testing.io;
    try host.auth.configureCodegraff("http://127.0.0.1:9", "cg_client_synthetic", "https://codegraff.example", null);

    const empty = try json.parseFromSliceLeaky(json.Value, a, "{}", .{});
    const r1 = try host.handle("SignInHeadless", empty);
    defer gpa.free(r1.unary_json);
    const r2 = try host.handle("SignInHeadless", empty);
    defer gpa.free(r2.unary_json);

    const s1 = try urlParam(a, r1.unary_json, "state");
    const s2 = try urlParam(a, r2.unary_json, "state");
    try testing.expect(s1.len >= 32);
    try testing.expect(!std.mem.eql(u8, s1, s2));
    try testing.expect(!std.mem.eql(u8, try urlParam(a, r1.unary_json, "code_challenge"), try urlParam(a, r2.unary_json, "code_challenge")));
    try testing.expectEqualStrings("cg_client_synthetic", try urlParam(a, r1.unary_json, "client_id"));
    try testing.expectEqualStrings(s1, try urlParam(a, r1.unary_json, "nonce"));
    try testing.expectEqualStrings("http://127.0.0.1:9/auth/cli/callback", try urlParam(a, r1.unary_json, "redirect_uri"));
    // The verifier is never a constant.
    try testing.expect(!std.mem.startsWith(u8, host.auth.pending_verifier.?, "zig_pkce"));
    try testing.expect(host.auth.pending_verifier.?.len >= 43);
}

/// A made-up edge on 127.0.0.1: each request is answered by the first route
/// whose path occurs in its request line (else 404 `{}`).
pub const MockEdge = struct {
    pub const Route = struct { path: []const u8, status: u16, body: []const u8 };

    server: std.Io.net.Server,
    routes: []const Route,
    stop: std.atomic.Value(bool) = .init(false),
    hits: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    pub fn start(self: *MockEdge) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *MockEdge) void {
        const io = testing.io;
        while (!self.stop.load(.acquire)) {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);
            if (self.stop.load(.acquire)) return;
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var rd = stream.reader(io, &rbuf);
            var wr = stream.writer(io, &wbuf);
            const line = rd.interface.takeDelimiterInclusive('\n') catch continue;
            var req_line: [256]u8 = undefined;
            const n = @min(line.len, req_line.len);
            @memcpy(req_line[0..n], line[0..n]);
            var content_len: usize = 0;
            while (true) {
                const h = rd.interface.takeDelimiterInclusive('\n') catch break;
                const t = std.mem.trimEnd(u8, h, "\r\n");
                if (t.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(t, "content-length:")) {
                    content_len = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " \t"), 10) catch 0;
                }
            }
            rd.interface.discardAll(content_len) catch {};
            _ = self.hits.fetchAdd(1, .acq_rel);
            var status: u16 = 404;
            var body: []const u8 = "{}";
            for (self.routes) |r| if (std.mem.indexOf(u8, req_line[0..n], r.path) != null) {
                status = r.status;
                body = r.body;
                break;
            };
            wr.interface.print("HTTP/1.1 {d} X\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch continue;
            wr.interface.flush() catch continue;
        }
    }

    pub fn port(self: *const MockEdge) u16 {
        return self.server.socket.address.getPort();
    }

    pub fn url(self: *const MockEdge, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port()}) catch unreachable;
    }

    pub fn deinit(self: *MockEdge) void {
        self.stop.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", self.port())) |addr| {
            if (addr.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }
};

pub fn listenLoopback() !std.Io.net.Server {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    return addr.listen(testing.io, .{ .reuse_address = true });
}

/// `{"sub":"u-1","iat":1000,"exp":4600}` and the same with `org_id`.
const jwt_no_org = "e30.eyJzdWIiOiJ1c2VyXzEiLCJpYXQiOjEwMDAsImV4cCI6NDYwMH0.sig";
const jwt_org_1 = "e30.eyJzdWIiOiJ1c2VyXzEiLCJpYXQiOjEwMDAsImV4cCI6NDYwMCwib3JnX2lkIjoib3JnXzEifQ.sig";

fn errText(outcome: engine_host.RpcOutcome) ?[]const u8 {
    return switch (outcome) {
        .err => |e| switch (e) {
            inline else => |m| m,
        },
        else => null,
    };
}

fn freeOutcome(outcome: engine_host.RpcOutcome) void {
    switch (outcome) {
        .unary_json => |b| testing.allocator.free(b),
        else => {},
    }
}

fn orgLessHost(gpa: std.mem.Allocator, edge_url: []const u8, data_dir: []const u8) !EngineHost {
    var host = try EngineHost.init(gpa, "dev-sec-2", "SecHost");
    errdefer host.deinit();
    host.io = testing.io;
    try host.auth.configureCodegraff(edge_url, "cg_client_synthetic", "https://codegraff.example", data_dir);
    host.auth.refresh_token = try gpa.dupe(u8, "harness_rt_synthetic");
    host.auth.access_token = try gpa.dupe(u8, jwt_no_org);
    host.auth.access_expires_at_ms = std.math.maxInt(i64);
    host.auth.phase = .needs_organization;
    host.auth.signed_in = false;
    return host;
}

test "fix-sec 2: sign-in never reports success without a session" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    var edge: MockEdge = .{ .server = try listenLoopback(), .routes = &.{
        .{ .path = "/auth/orgs", .status = 500, .body = "{}" },
        .{ .path = "/auth/refresh", .status = 403, .body = "{\"error\":\"not a member\"}" },
    } };
    try edge.start();
    defer edge.deinit();
    var ubuf: [64]u8 = undefined;
    var host = try orgLessHost(gpa, edge.url(&ubuf), dir);
    defer host.deinit();

    // No code: an error, never a development sign-in.
    const no_code = try host.handle("CompleteSignIn", try json.parseFromSliceLeaky(json.Value, a, "{}", .{}));
    defer freeOutcome(no_code);
    try testing.expect(errText(no_code) != null);
    try testing.expectEqual(auth_host.AuthPhase.needs_organization, host.auth.phase);

    // A failed list is an error, not an invented personal workspace.
    const orgs = try host.handle("ListOrgs", try json.parseFromSliceLeaky(json.Value, a, "{}", .{}));
    defer freeOutcome(orgs);
    try testing.expectEqualStrings("workspace request failed (500)", errText(orgs) orelse "(ok)");

    // A refused switch leaves the session org-less and unsaved as signed in.
    const sel = try host.handle("SelectOrg", try json.parseFromSliceLeaky(json.Value, a, "{\"organizationId\":\"org_9\"}", .{}));
    defer freeOutcome(sel);
    try testing.expectEqualStrings("refresh failed (403)", errText(sel) orelse "(ok)");
    try testing.expect(!host.auth.signed_in);
    try testing.expect(host.auth.org_id == null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "session.json", .{}));
}

test "fix-sec 2: a switch whose token names another workspace fails" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    var edge: MockEdge = .{ .server = try listenLoopback(), .routes = &.{
        .{ .path = "/auth/refresh", .status = 200, .body = "{\"accessToken\":\"" ++ jwt_org_1 ++ "\",\"refreshToken\":\"harness_rt_rotated\"}" },
    } };
    try edge.start();
    defer edge.deinit();
    var ubuf: [64]u8 = undefined;
    var host = try orgLessHost(gpa, edge.url(&ubuf), dir);
    defer host.deinit();

    const sel = try host.handle("SelectOrg", try json.parseFromSliceLeaky(json.Value, a, "{\"organizationId\":\"org_9\"}", .{}));
    defer freeOutcome(sel);
    try testing.expect(std.mem.startsWith(u8, errText(sel) orelse "(ok)", "could not switch to that workspace"));
    // The state follows the token's claim, as the Rust engine.
    try testing.expectEqualStrings("org_1", host.auth.org_id.?);
}

test "fix-sec 3: credential files are written 0600 through a temporary file and a rename" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "session.json" });
    defer testing.allocator.free(path);

    // An old world-readable file and a link beside it to something else.
    try tmp.dir.writeFile(io, .{ .sub_path = "session.json", .data = "{\"refreshToken\":\"harness_rt_old_and_long\"}" });
    const old = try tmp.dir.openFile(io, "session.json", .{});
    try old.setPermissions(io, .fromMode(0o644));
    old.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "untouched" });
    try tmp.dir.symLink(io, "victim.txt", "key.json", .{});
    const key_path = try std.fs.path.join(testing.allocator, &.{ dir, "key.json" });
    defer testing.allocator.free(key_path);

    try auth_host.writePrivate(io, path, "{\"refreshToken\":\"new\"}");
    try auth_host.writePrivate(io, key_path, "{\"api_key\":\"cg_sk_synthetic\"}");

    const st = try tmp.dir.statFile(io, "session.json", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("{\"refreshToken\":\"new\"}", try tmp.dir.readFile(io, "session.json", &buf));
    // The link was replaced, its target left alone.
    try testing.expectEqualStrings("untouched", try tmp.dir.readFile(io, "victim.txt", &buf));
    const kst = try tmp.dir.statFile(io, "key.json", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.file, kst.kind);
    // No temporary file is left behind.
    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expect(!std.mem.startsWith(u8, e.name, ".session-"));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "fix-sec 4: one URL check: HTTPS, or plain HTTP to exactly 127.0.0.1 or [::1]" {
    const engine_cli = @import("engine_cli.zig");
    const sandboxes_host = @import("sandboxes_host.zig");
    const rpcw_codegraff = @import("rpcw_codegraff.zig");
    const good = [_][]const u8{ "https://edge.example.com", "https://edge.example.com:8443/x", "http://127.0.0.1", "http://127.0.0.1:8787/p", "http://[::1]:8787", "HTTP://127.0.0.1:1" };
    const bad = [_][]const u8{
        "http://127.0.0.1:80@evil.example",
        "http://127.0.0.1@evil.example/",
        "http://127.0.0.1.evil.example",
        "http://127.0.0.2:8787",
        "http://localhost:8787",
        "http://edge.example.com",
        "ftp://127.0.0.1",
        "https://",
        "127.0.0.1:8787",
    };
    for (good) |u| {
        try testing.expect(engine_cli.isSecureUrl(u));
        try testing.expect(sandboxes_host.gatewayProblem(u) == null);
        try testing.expect(rpcw_codegraff.validateSecureUrl("CodeGraff gateway", u) == null);
    }
    for (bad) |u| {
        if (engine_cli.isSecureUrl(u)) std.debug.print("accepted: {s}\n", .{u});
        try testing.expect(!engine_cli.isSecureUrl(u));
        try testing.expect(sandboxes_host.gatewayProblem(u) != null);
        try testing.expect(rpcw_codegraff.validateSecureUrl("CodeGraff gateway", u) != null);
    }
    try testing.expectEqualStrings("CodeGraff gateway must use HTTPS (plain HTTP is allowed only on loopback)", sandboxes_host.gatewayProblem("http://127.0.0.1:80@evil.example").?);
}

test "fix-sec 4: the engine refuses to start a sign-in toward a plain-HTTP edge" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var host = try EngineHost.init(gpa, "dev-sec-4", "SecHost");
    defer host.deinit();
    host.io = testing.io;
    try host.auth.configureCodegraff("http://127.0.0.1:80@evil.example", "cg_client_synthetic", "https://codegraff.example", null);
    const r = try host.handle("SignInHeadless", try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{}", .{}));
    defer freeOutcome(r);
    try testing.expectEqualStrings("Harness edge must use HTTPS (plain HTTP is allowed only on loopback)", errText(r) orelse "(ok)");
}
