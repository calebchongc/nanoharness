//! End to end against a fake browse on loopback that answers and checks every
//! request the way browse does (the Rust fake in
//! `crates/engine/src/browse_link/tests.rs`): pairing, refusals, forged
//! answers, scope changes, revocation, key mismatch and disconnect. Synthetic
//! data only: a temporary directory, an in-memory key store, a fake browse.
//! Every socket has a deadline.
//!
//! The fake never fails on what it receives; what Harness gets wrong is
//! collected in `faults` and asserted by the tests.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const testing = std.testing;
const bl = @import("browse_link.zig");
const wire = bl.wire;
const http = bl.http;
const keystore = bl.keystore;
const Link = bl.Link;

const tio = testing.io;
const CLIENT_ID = "client-1";

const PairRefusal = struct { status: u16, body: []const u8 };

const Fake = struct {
    gpa: Allocator,
    server: net.Server,
    port: u16,
    key: wire.KeyPair,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),

    mutex: Io.Mutex = .init,
    // What was seen.
    client_key: ?[]u8 = null,
    nonce: ?[]u8 = null,
    /// Every request nonce, for browse's replay check.
    nonces: std.StringHashMapUnmanaged(void) = .empty,
    faults: std.ArrayList([]u8) = .empty,
    strangers: usize = 0,
    pair_requests: usize = 0,
    // Behaviour.
    /// Sign answers with this instead (a squatter on the port).
    forge: ?wire.KeyPair = null,
    /// Answer every signed request with a signed 401 unknown_client.
    revoked: bool = false,
    scopes: []const []const u8 = &.{ "read", "act-own-pages" },
    /// `/pair/status` before the user answers: pending, paired, declined.
    pairing: []const u8 = "paired",
    pair_refusal: ?PairRefusal = null,
    /// Name this key in `/pair`'s answer instead of its own.
    pair_answer_key: ?[]const u8 = null,

    fn start(gpa: Allocator) !*Fake {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        const self = try gpa.create(Fake);
        self.* = .{
            .gpa = gpa,
            .server = try addr.listen(tio, .{ .reuse_address = true }),
            .port = 0,
            .key = wire.newKey(tio),
        };
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    fn stop(self: *Fake) void {
        self.stopping.store(true, .release);
        // Wake the accept.
        if (net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
            if (addr.connect(tio, .{ .mode = .stream })) |s| s.close(tio) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit(tio);
        const gpa = self.gpa;
        if (self.client_key) |k| gpa.free(k);
        if (self.nonce) |n| gpa.free(n);
        var it = self.nonces.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.nonces.deinit(gpa);
        for (self.faults.items) |f| gpa.free(f);
        self.faults.deinit(gpa);
        gpa.destroy(self);
    }

    fn lock(self: *Fake) void {
        self.mutex.lockUncancelable(tio);
    }
    fn unlock(self: *Fake) void {
        self.mutex.unlock(tio);
    }

    fn browseKey(self: *Fake) [wire.public_key_b64_len]u8 {
        return wire.publicKeyB64(self.key);
    }

    fn nonceCount(self: *Fake) usize {
        self.lock();
        defer self.unlock();
        return self.nonces.count();
    }

    fn expectNoFaults(self: *Fake) !void {
        self.lock();
        defer self.unlock();
        for (self.faults.items) |f| std.debug.print("fault: {s}\n", .{f});
        try testing.expectEqual(@as(usize, 0), self.faults.items.len);
    }

    /// `connect.json` in `dir` (absolute); returns its path.
    fn publish(self: *Fake, gpa: Allocator, dir: []const u8) ![]u8 {
        const key = self.browseKey();
        const text = try std.fmt.allocPrint(gpa, "{{\"protocol\":[\"{s}\"],\"port\":{d},\"browse_key\":\"{s}\"}}", .{ wire.PROTOCOL, self.port, &key });
        defer gpa.free(text);
        const path = try std.fs.path.join(gpa, &.{ dir, "connect.json" });
        try Io.Dir.cwd().writeFile(tio, .{ .sub_path = path, .data = text });
        return path;
    }

    fn acceptLoop(self: *Fake) void {
        while (!self.stopping.load(.acquire)) {
            const conn = self.server.accept(tio) catch continue;
            defer conn.close(tio);
            if (self.stopping.load(.acquire)) return;
            self.handle(conn);
        }
    }

    fn handle(self: *Fake, conn: net.Stream) void {
        var dog: http.Watchdog = .{ .io = tio, .stream = conn, .ms = 5_000 };
        dog.arm();
        defer _ = dog.disarm();
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var rd = conn.reader(tio, &rbuf);
        var wr = conn.writer(tio, &wbuf);
        var req = (http.readRequest(self.gpa, &rd.interface) catch return) orelse return;
        defer req.deinit();
        const a = self.answer(&req) catch return;
        defer self.gpa.free(a.body);
        defer if (a.nonce) |n| self.gpa.free(n);
        if (a.nonce) |n| {
            self.lock();
            const signer = self.forge orelse self.key;
            self.unlock();
            const digest = wire.sha256Hex(a.body);
            const text = std.fmt.allocPrint(self.gpa, "{s}|{s}", .{ &digest, n }) catch return;
            defer self.gpa.free(text);
            const sig = wire.sign(self.gpa, signer, text) catch return;
            defer self.gpa.free(sig);
            http.writeResponse(&wr.interface, a.status, a.body, &.{.{ .name = "X-Signature", .value = sig }}) catch return;
        } else {
            http.writeResponse(&wr.interface, a.status, a.body, &.{}) catch return;
        }
    }

    const Out = struct { status: u16, body: []u8, nonce: ?[]u8 };

    fn fault(self: *Fake, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.faults.append(self.gpa, text) catch self.gpa.free(text);
    }

    fn out(self: *Fake, status: u16, body: []const u8, nonce: ?[]const u8) !Out {
        const b = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(b);
        return .{ .status = status, .body = b, .nonce = if (nonce) |n| try self.gpa.dupe(u8, n) else null };
    }

    /// browse's answer to one request.
    fn answer(self: *Fake, req: *const http.Request) !Out {
        const gpa = self.gpa;
        self.lock();
        defer self.unlock();
        const is_post = std.mem.eql(u8, req.method, "POST");
        const harness = req.header("x-client-id") != null or std.mem.startsWith(u8, req.path, "/pair");
        if (!is_post or !harness) {
            // Not a connected app's: browse's own agent's token check refuses it.
            self.strangers += 1;
            return self.out(if (is_post) 401 else 405, "", null);
        }
        var host_buf: [32]u8 = undefined;
        const want_host = std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{self.port}) catch unreachable;
        if (req.header("origin") != null or !std.mem.eql(u8, req.header("host") orelse "", want_host)) {
            self.fault("{s}: Origin or Host", .{req.path});
            return self.out(403, "{\"error\":\"bad_origin\"}", null);
        }
        if (std.mem.eql(u8, req.path, "/pair")) {
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, req.body, .{}) catch {
                self.fault("/pair {s}", .{req.body});
                return self.out(400, "{\"error\":\"bad_request\"}", null);
            };
            defer parsed.deinit();
            const o = if (parsed.value == .object) parsed.value.object else {
                self.fault("/pair {s}", .{req.body});
                return self.out(400, "{\"error\":\"bad_request\"}", null);
            };
            var offers = false;
            if (o.get("protocol")) |p| if (p == .array) for (p.array.items) |v| {
                if (v == .string and std.mem.eql(u8, v.string, wire.PROTOCOL)) offers = true;
            };
            const name_ok = if (o.get("name")) |n| n == .string and std.mem.eql(u8, n.string, "Harness") else false;
            if (!name_ok or !offers) {
                self.fault("/pair {s}", .{req.body});
                return self.out(400, "{\"error\":\"bad_request\"}", null);
            }
            self.pair_requests += 1;
            if (self.client_key) |k| gpa.free(k);
            self.client_key = if (o.get("client_key")) |v| (if (v == .string) try gpa.dupe(u8, v.string) else null) else null;
            if (self.nonce) |n| gpa.free(n);
            self.nonce = if (o.get("nonce")) |v| (if (v == .string) try gpa.dupe(u8, v.string) else null) else null;
            if (self.pair_refusal) |r| return self.out(r.status, r.body, null);
            const own = self.browseKey();
            const named = self.pair_answer_key orelse &own;
            const body = try std.fmt.allocPrint(gpa, "{{\"protocol\":\"{s}\",\"client_id\":\"{s}\",\"browse_key\":\"{s}\",\"expires_in\":120}}", .{ wire.PROTOCOL, CLIENT_ID, named });
            defer gpa.free(body);
            return self.out(200, body, null);
        }
        const nonce = req.header("x-nonce") orelse "";
        if (self.verify(req)) |problem| {
            self.fault("{s}: {s}", .{ req.path, problem });
            return self.out(401, "{\"error\":\"bad_signature\"}", nonce);
        }
        if (self.nonces.contains(nonce)) {
            self.fault("{s}: nonce reused", .{req.path});
            return self.out(401, "{\"error\":\"replayed\"}", nonce);
        }
        try self.nonces.put(gpa, try gpa.dupe(u8, nonce), {});
        if (self.revoked) return self.out(401, "{\"error\":\"unknown_client\"}", nonce);
        if (std.mem.eql(u8, req.path, "/pair/status")) {
            if (!std.mem.eql(u8, self.pairing, "paired")) {
                const body = try std.fmt.allocPrint(gpa, "{{\"status\":\"{s}\"}}", .{self.pairing});
                defer gpa.free(body);
                return self.out(200, body, nonce);
            }
            const body = try std.json.Stringify.valueAlloc(gpa, .{ .status = "paired", .scopes = self.scopes }, .{});
            defer gpa.free(body);
            return self.out(200, body, nonce);
        }
        return self.out(404, "{\"error\":\"not_found\"}", nonce);
    }

    /// A signed request's headers checked as browse's `Connect.verify` does;
    /// null when fine.
    fn verify(self: *Fake, req: *const http.Request) ?[]const u8 {
        const id = req.header("x-client-id") orelse return "no x-client-id";
        const stamp_text = req.header("x-timestamp") orelse return "no x-timestamp";
        const stamp = std.fmt.parseInt(i64, stamp_text, 10) catch return "x-timestamp isn't unix ms";
        const nonce = req.header("x-nonce") orelse return "no x-nonce";
        if (nonce.len != 32) return "nonce isn't 16 bytes of hex";
        for (nonce) |c| if (!std.ascii.isHex(c)) return "nonce isn't 16 bytes of hex";
        if (!std.mem.eql(u8, id, CLIENT_ID)) return "client id";
        const now = Io.Clock.real.now(tio).toMilliseconds();
        if (@abs(now - stamp) > 60_000) return "stale";
        const client_key = self.client_key orelse return "signed before pairing";
        const text = wire.canonical(self.gpa, req.method, req.path, req.body, stamp, nonce, id) catch return "oom";
        defer self.gpa.free(text);
        const pk = wire.parsePublicKey(client_key) orelse return "client key";
        const sig = req.header("x-signature") orelse return "no x-signature";
        if (!wire.verifyB64(pk, text, sig)) return "bad signature";
        return null;
    }
};

// ── helpers ───────────────────────────────────────────────────────────────

const Env = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    mem: keystore.MemoryKeyStore = .{},

    fn init() !Env {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(tio, ".", testing.allocator);
        return .{ .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *Env) void {
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn path(self: *Env, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.dir, name });
    }

    /// A link on this directory's state file and memory key store.
    fn link(self: *Env, connect: ?[]const u8) !*Link {
        const gpa = testing.allocator;
        const state = try self.path(bl.STATE_FILE);
        errdefer gpa.free(state);
        const c = if (connect) |p| try gpa.dupe(u8, p) else null;
        const l = try Link.create(gpa, tio, state, self.mem.keyStore(), c);
        l.poll_interval_ms = 20;
        l.request_timeout_ms = 5_000;
        l.refresh_timeout_ms = 3_000;
        return l;
    }

    fn exists(self: *Env, name: []const u8) bool {
        self.tmp.dir.access(tio, name, .{}) catch return false;
        return true;
    }
};

fn statusOf(link: *Link) !bl.Status {
    return link.status(testing.allocator);
}

fn isPaired(link: *Link) bool {
    var s = statusOf(link) catch return false;
    defer s.deinit(testing.allocator);
    return s.paired;
}

fn codeGone(link: *Link) bool {
    var s = statusOf(link) catch return false;
    defer s.deinit(testing.allocator);
    return s.pairing_code == null;
}

fn sleepMs(ms: i64) void {
    tio.sleep(.fromMilliseconds(ms), .awake) catch {};
}

/// Up to 10 s for `pred(link)`.
fn eventually(link: *Link, comptime pred: fn (*Link) bool) !void {
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        if (pred(link)) return;
        sleepMs(20);
    }
    return error.TimedOut;
}

fn expectCode(r: bl.PairResult) ![6]u8 {
    return switch (r) {
        .code => |c| c,
        .failed => |m| {
            std.debug.print("pairing failed: {s}\n", .{m});
            testing.allocator.free(m);
            return error.TestUnexpectedResult;
        },
    };
}

fn expectFailed(r: bl.PairResult, want: []const u8) !void {
    switch (r) {
        .code => return error.TestUnexpectedResult,
        .failed => |m| {
            defer testing.allocator.free(m);
            try testing.expectEqualStrings(want, m);
        },
    }
}

/// Pair `link` against `fake` (which says "paired") and wait until recorded.
fn pairNow(link: *Link) !void {
    _ = try expectCode(try link.startPair(testing.allocator));
    try eventually(link, isPaired);
}

/// Raw bytes to `port`; the first line of the answer.
fn rawFirstLine(port: u16, request: []const u8, out: []u8) ![]const u8 {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    const s = try addr.connect(tio, .{ .mode = .stream });
    defer s.close(tio);
    var dog: http.Watchdog = .{ .io = tio, .stream = s, .ms = 5_000 };
    dog.arm();
    defer _ = dog.disarm();
    var wbuf: [512]u8 = undefined;
    var wr = s.writer(tio, &wbuf);
    try wr.interface.writeAll(request);
    try wr.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var rd = s.reader(tio, &rbuf);
    const line = try rd.interface.takeDelimiterInclusive('\n');
    const n = @min(line.len, out.len);
    @memcpy(out[0..n], line[0..n]);
    return out[0..n];
}

// ── tests ─────────────────────────────────────────────────────────────────

test "browse link: without browse, status says not running and pairing says why" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const missing = try env.path("missing-connect.json");
    defer gpa.free(missing);
    const link = try env.link(missing);
    defer link.destroy();
    const json_text = try link.rpcStatus(gpa);
    defer gpa.free(json_text);
    try testing.expectEqualStrings(
        "{\"browseRunning\":false,\"paired\":false,\"scopes\":[],\"pairingCode\":null,\"keyMismatch\":false,\"error\":null}",
        json_text,
    );
    const reply = try link.rpcPair(gpa);
    defer reply.deinit(gpa);
    try testing.expect(reply == .failed);
    try testing.expectEqualStrings("browse isn't running with Settings › Agent › Connected apps on", reply.failed);
    // The key is only made once browse is found.
    try testing.expectEqual(@as(usize, 0), env.mem.writes);

    // No connect file at all (no HOME): never running.
    const none = try env.link(null);
    defer none.destroy();
    var s = try statusOf(none);
    defer s.deinit(gpa);
    try testing.expect(!s.browse_running);
}

test "browse link: connect.json must speak the protocol and belong to a live browse" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const path = try env.path("connect.json");
    defer gpa.free(path);
    const link = try env.link(path);
    defer link.destroy();
    const cases = [_]struct { text: []const u8, running: bool }{
        .{ .text = "{\"port\":4100,\"browse_key\":\"k\"}", .running = false },
        .{ .text = "{\"protocol\":[\"v0\"],\"port\":4100,\"browse_key\":\"k\"}", .running = false },
        .{ .text = "{\"protocol\":[\"v1-p256-sig\"],\"port\":70000,\"browse_key\":\"k\"}", .running = false },
        .{ .text = "{\"protocol\":[\"v1-p256-sig\"],\"port\":4100}", .running = false },
        .{ .text = "not json", .running = false },
        .{ .text = "{\"protocol\":[\"v0\",\"v1-p256-sig\"],\"port\":4100,\"browse_key\":\"k\",\"pid\":null}", .running = true },
        // A crashed browse's file: no such process.
        .{ .text = "{\"protocol\":[\"v1-p256-sig\"],\"port\":4100,\"browse_key\":\"k\",\"pid\":2147483647}", .running = builtin.os.tag == .windows },
    };
    for (cases) |c| {
        try Io.Dir.cwd().writeFile(tio, .{ .sub_path = path, .data = c.text });
        var s = try statusOf(link);
        defer s.deinit(gpa);
        testing.expectEqual(c.running, s.browse_running) catch |e| {
            std.debug.print("case: {s}\n", .{c.text});
            return e;
        };
    }
}

test "browse link: connect.json's location comes from the environment" {
    const gpa = testing.allocator;
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try testing.expect((try bl.connectFilePath(gpa, &map)) == null);
    try map.put("HOME", "/synthetic/home");
    const from_home = (try bl.connectFilePath(gpa, &map)).?;
    defer gpa.free(from_home);
    const want = try std.fs.path.join(gpa, &.{ "/synthetic/home", "Library/Application Support/browse/Agent/connect.json" });
    defer gpa.free(want);
    try testing.expectEqualStrings(want, from_home);
    try map.put("HARNESS_BROWSE_CONNECT", "");
    const still_home = (try bl.connectFilePath(gpa, &map)).?;
    defer gpa.free(still_home);
    try testing.expectEqualStrings(want, still_home);
    try map.put("HARNESS_BROWSE_CONNECT", "/synthetic/world/connect.json");
    const world = (try bl.connectFilePath(gpa, &map)).?;
    defer gpa.free(world);
    try testing.expectEqualStrings("/synthetic/world/connect.json", world);
}

test "browse link: the full flow against a fake browse" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const fake = try Fake.start(gpa);
    defer fake.stop();
    const connect = try fake.publish(gpa, env.dir);
    defer gpa.free(connect);
    const link = try env.link(connect);
    defer link.destroy();

    // Something else probing browse's port is answered and changes nothing.
    var line_buf: [64]u8 = undefined;
    var probe_buf: [128]u8 = undefined;
    const probe = try std.fmt.bufPrint(&probe_buf, "HEAD / HTTP/1.1\r\nHost: localhost:{d}\r\nConnection: close\r\n\r\n", .{fake.port});
    try testing.expect(std.mem.startsWith(u8, try rawFirstLine(fake.port, probe, &line_buf), "HTTP/1.1 405"));

    // Running and not paired.
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expect(s.browse_running and !s.paired and !s.key_mismatch);
    }

    // Pairing: both sides derive the same six digits, shown until the user
    // answers in browse.
    fake.lock();
    fake.pairing = "pending";
    fake.unlock();
    const reply = try link.rpcPair(gpa);
    defer reply.deinit(gpa);
    try testing.expect(reply == .json);
    try testing.expect(std.mem.startsWith(u8, reply.json, "{\"code\":\"") and reply.json.len == "{\"code\":\"123456\"}".len);
    const code = reply.json[9..15];
    {
        fake.lock();
        defer fake.unlock();
        const bk = fake.browseKey();
        const derived = (try wire.pairingCode(gpa, &bk, fake.client_key.?, fake.nonce.?)).?;
        try testing.expectEqualStrings(&derived, code);
    }
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expectEqualStrings(code, &s.pairing_code.?);
    }
    // Asked at least once and still pending: the code stays up.
    var i: usize = 0;
    while (fake.nonceCount() == 0 and i < 500) : (i += 1) sleepMs(20);
    try testing.expect(fake.nonceCount() > 0);
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expectEqualStrings(code, &s.pairing_code.?);
        try testing.expect(!s.paired);
    }
    fake.lock();
    fake.pairing = "paired";
    fake.unlock();
    try eventually(link, isPaired);
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), s.scopes.len);
        try testing.expectEqualStrings("read", s.scopes[0]);
        try testing.expectEqualStrings("act-own-pages", s.scopes[1]);
        try testing.expect(s.pairing_code == null);
        try testing.expect(s.@"error" == null);
    }
    // The pairing survives a restart, and its file holds nothing secret.
    {
        const reloaded = try env.link(connect);
        defer reloaded.destroy();
        try testing.expect(isPaired(reloaded));
        const saved = try env.tmp.dir.readFileAlloc(tio, bl.STATE_FILE, gpa, .limited(1 << 16));
        defer gpa.free(saved);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, saved, .{});
        defer parsed.deinit();
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        for (parsed.value.object.keys()) |k| try names.append(gpa, k);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        try testing.expectEqual(@as(usize, 4), names.items.len);
        try testing.expectEqualStrings("browseKey", names.items[0]);
        try testing.expectEqualStrings("clientId", names.items[1]);
        try testing.expectEqualStrings("pairedAt", names.items[2]);
        try testing.expectEqualStrings("scopes", names.items[3]);
        const secret = env.mem.bytes.?;
        var hex: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, saved, wire.hexInto(&hex, &secret)) == null);
        var b64: [44]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, saved, std.base64.standard.Encoder.encode(&b64, &secret)) == null);
        if (builtin.os.tag != .windows) {
            const f = try env.tmp.dir.openFile(tio, bl.STATE_FILE, .{});
            defer f.close(tio);
            try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try f.stat(tio)).permissions.toMode() & 0o777);
        }
    }

    // The user allows more in browse: Settings shows it on its next look.
    fake.lock();
    fake.scopes = &.{ "read", "act-own-pages", "run-js" };
    fake.unlock();
    {
        const text = try link.rpcStatus(gpa);
        defer gpa.free(text);
        try testing.expectEqualStrings(
            "{\"browseRunning\":true,\"paired\":true,\"scopes\":[\"read\",\"act-own-pages\",\"run-js\"],\"pairingCode\":null,\"keyMismatch\":false,\"error\":null}",
            text,
        );
    }

    // A squatter's answers aren't believed: neither new scopes nor an
    // unsigned "unknown_client" change anything.
    fake.lock();
    fake.forge = wire.newKey(tio);
    fake.scopes = &.{"read"};
    fake.unlock();
    link.refresh();
    fake.lock();
    fake.revoked = true;
    fake.unlock();
    link.refresh();
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expect(s.paired);
        try testing.expectEqual(@as(usize, 3), s.scopes.len);
    }
    // Signed by a different key, the request itself reports why.
    {
        var r = try link.request(gpa, "/pair/status", "{}", 5_000);
        defer r.deinit(gpa);
        try testing.expect(r == .err and r.err == .untrusted);
        const m = try r.err.message(gpa);
        defer gpa.free(m);
        try testing.expect(std.mem.indexOf(u8, m, "wasn't signed") != null);
    }
    fake.lock();
    fake.forge = null;
    fake.unlock();

    // Revoked in browse: a signed unknown_client forgets the pairing.
    link.refresh();
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expect(!s.paired);
        try testing.expectEqualStrings("browse no longer knows Harness (revoked, or unused for 30 days). Connect again.", s.@"error".?);
    }
    try testing.expect(!env.exists(bl.STATE_FILE));

    // Paired again: connecting clears the old error.
    fake.lock();
    fake.revoked = false;
    fake.unlock();
    try pairNow(link);
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expect(s.@"error" == null);
    }

    try fake.expectNoFaults();
    fake.lock();
    defer fake.unlock();
    try testing.expect(fake.strangers >= 1);
}

test "browse link: a different browse on the port is a key mismatch and isn't asked" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const fake = try Fake.start(gpa);
    defer fake.stop();
    const connect = try fake.publish(gpa, env.dir);
    defer gpa.free(connect);
    const link = try env.link(connect);
    defer link.destroy();
    try pairNow(link);

    // Another browse publishes itself in the same place.
    const other = try Fake.start(gpa);
    defer other.stop();
    const again = try other.publish(gpa, env.dir);
    defer gpa.free(again);
    const text = try link.rpcStatus(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings(
        "{\"browseRunning\":true,\"paired\":true,\"scopes\":[\"read\",\"act-own-pages\"],\"pairingCode\":null,\"keyMismatch\":true,\"error\":null}",
        text,
    );
    other.lock();
    defer other.unlock();
    try testing.expectEqual(@as(usize, 0), other.nonces.count());
    try testing.expectEqual(@as(usize, 0), other.strangers);
    try testing.expectEqual(@as(usize, 0), other.pair_requests);
}

test "browse link: browse's refusals to pair read as Rust's texts" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const fake = try Fake.start(gpa);
    defer fake.stop();
    const connect = try fake.publish(gpa, env.dir);
    defer gpa.free(connect);
    const link = try env.link(connect);
    defer link.destroy();

    const cases = [_]struct { refusal: PairRefusal, want: []const u8 }{
        .{ .refusal = .{ .status = 403, .body = "{\"error\":\"connected_apps_off\"}" }, .want = "Turn on Connected apps in browse (Settings › Agent), then try again." },
        .{ .refusal = .{ .status = 409, .body = "{\"error\":\"pairing_in_progress\"}" }, .want = "browse is already pairing with another app. Finish or cancel that first." },
        .{ .refusal = .{ .status = 500, .body = "{\"error\":\"boom\"}" }, .want = "browse refused pairing (500 boom)" },
        .{ .refusal = .{ .status = 502, .body = "not json" }, .want = "browse refused pairing (502 )" },
        .{ .refusal = .{ .status = 200, .body = "{\"protocol\":\"v1-p256-sig\",\"browse_key\":\"x\"}" }, .want = "browse's pairing answer didn't match what it published" },
    };
    for (cases) |c| {
        fake.lock();
        fake.pair_refusal = c.refusal;
        fake.unlock();
        try expectFailed(try link.startPair(gpa), c.want);
    }
    // /pair names a key other than the one browse published.
    fake.lock();
    fake.pair_refusal = null;
    fake.pair_answer_key = "BOGUS";
    fake.unlock();
    try expectFailed(try link.startPair(gpa), "browse's pairing answer didn't match what it published");
    var s = try statusOf(link);
    defer s.deinit(gpa);
    try testing.expect(!s.paired and s.pairing_code == null);
    try fake.expectNoFaults();
}

test "browse link: a declined, superseded or cancelled pairing" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const fake = try Fake.start(gpa);
    defer fake.stop();
    const connect = try fake.publish(gpa, env.dir);
    defer gpa.free(connect);
    const link = try env.link(connect);
    defer link.destroy();

    // Declined in browse: Settings says so.
    fake.lock();
    fake.pairing = "declined";
    fake.unlock();
    _ = try expectCode(try link.startPair(gpa));
    try eventually(link, codeGone);
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expectEqualStrings("Pairing was declined in browse.", s.@"error".?);
        try testing.expect(!s.paired);
    }

    // Connect, then Connect again: the second code is the one up, and the
    // first pairing's end doesn't take it down.
    fake.lock();
    fake.pairing = "pending";
    fake.unlock();
    _ = try expectCode(try link.startPair(gpa));
    const second = try expectCode(try link.startPair(gpa));
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expectEqualStrings(&second, &s.pairing_code.?);
        try testing.expect(s.@"error" == null);
    }
    const asked = fake.nonceCount();
    var i: usize = 0;
    while (fake.nonceCount() <= asked + 1 and i < 500) : (i += 1) sleepMs(20);
    {
        var s = try statusOf(link);
        defer s.deinit(gpa);
        try testing.expectEqualStrings(&second, &s.pairing_code.?);
    }
    fake.lock();
    fake.pairing = "paired";
    fake.unlock();
    try eventually(link, isPaired);
    link.disconnect();

    // Cancel while browse is still asking: nothing is recorded afterwards,
    // even once browse would have said yes.
    link.poll_interval_ms = 400;
    _ = try expectCode(try link.startPair(gpa));
    const reply = try link.rpcDisconnect(gpa);
    defer gpa.free(reply);
    try testing.expectEqualStrings("{\"ok\":true}", reply);
    try testing.expect(codeGone(link));
    const polls = fake.nonceCount();
    sleepMs(1_000);
    try testing.expect(!isPaired(link));
    try testing.expectEqual(polls, fake.nonceCount()); // no more polling
    try fake.expectNoFaults();
}

test "browse link: disconnect forgets the pairing and the key" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const fake = try Fake.start(gpa);
    defer fake.stop();
    const connect = try fake.publish(gpa, env.dir);
    defer gpa.free(connect);
    const link = try env.link(connect);
    defer link.destroy();
    try pairNow(link);
    try testing.expect(env.exists(bl.STATE_FILE));
    try testing.expect(env.mem.has(tio));

    const reply = try link.rpcDisconnect(gpa);
    defer gpa.free(reply);
    try testing.expectEqualStrings("{\"ok\":true}", reply);
    try testing.expect(!env.exists(bl.STATE_FILE));
    try testing.expect(!env.mem.has(tio));
    const text = try link.rpcStatus(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings(
        "{\"browseRunning\":true,\"paired\":false,\"scopes\":[],\"pairingCode\":null,\"keyMismatch\":false,\"error\":null}",
        text,
    );
    // A new pairing makes a new key.
    try pairNow(link);
    try testing.expectEqual(@as(usize, 2), env.mem.writes);
    try fake.expectNoFaults();
}

test "browse link: key store failures" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    const fake = try Fake.start(gpa);
    defer fake.stop();
    const connect = try fake.publish(gpa, env.dir);
    defer gpa.free(connect);
    const link = try env.link(connect);
    defer link.destroy();

    // The key can't be saved: pairing says so and browse is never asked.
    env.mem.fail_write = "couldn't save the pairing key in the Keychain: User interaction is not allowed.";
    const reply = try link.rpcPair(gpa);
    defer reply.deinit(gpa);
    try testing.expect(reply == .failed);
    try testing.expectEqualStrings("couldn't save the pairing key in the Keychain: User interaction is not allowed.", reply.failed);
    fake.lock();
    try testing.expectEqual(@as(usize, 0), fake.pair_requests);
    fake.unlock();

    // Paired, then the key can't be read: the status keeps the pairing and
    // browse isn't asked (no key to sign with).
    env.mem.fail_write = null;
    try pairNow(link);
    env.mem.fail_read = true;
    const before = fake.nonceCount();
    const text = try link.rpcStatus(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"paired\":true") != null);
    try testing.expectEqual(before, fake.nonceCount());
    var r = try link.request(gpa, "/pair/status", "{}", 5_000);
    defer r.deinit(gpa);
    try testing.expect(r == .err and r.err == .unknown_client);
    try fake.expectNoFaults();
}

test "browse link: the engine's entry points share one link per data dir" {
    const gpa = testing.allocator;
    var env = try Env.init();
    defer env.deinit();
    keystore.override = env.mem.keyStore();
    defer keystore.override = null;
    const missing = try env.path("no-browse/connect.json");
    defer gpa.free(missing);
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("HARNESS_BROWSE_CONNECT", missing);

    const a = try bl.shared(tio, env.dir, &map);
    const b = try bl.shared(tio, env.dir, &map);
    try testing.expect(a == b);
    const s = try bl.status(gpa, tio, env.dir, &map);
    defer gpa.free(s);
    try testing.expectEqualStrings(
        "{\"browseRunning\":false,\"paired\":false,\"scopes\":[],\"pairingCode\":null,\"keyMismatch\":false,\"error\":null}",
        s,
    );
    const p = try bl.pair(gpa, tio, env.dir, &map);
    defer p.deinit(gpa);
    try testing.expectEqualStrings("browse isn't running with Settings › Agent › Connected apps on", p.failed);
    const d = try bl.disconnect(gpa, tio, env.dir, &map);
    defer gpa.free(d);
    try testing.expectEqualStrings("{\"ok\":true}", d);
    try testing.expectEqual(@as(usize, 1), env.mem.deletes);
}
