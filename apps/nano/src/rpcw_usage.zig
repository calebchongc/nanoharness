//! `CodegraffUsage` and `ListAgentAccounts`' no-home answer.
//!
//! `CodegraffUsage` is `CodegraffAuth::usage` (`crates/engine/src/codegraff_auth.rs`):
//! `null` without a key (the saved one, else `CODEGRAFF_API_KEY`), otherwise
//! `GET {gateway}/v1/usage/summary` with the key, the gateway checked by
//! `validate_secure_url`, and the reply re-read as `CodegraffUsage`. Its three
//! failures are the call's error, as in Rust: unreachable, a non-2xx status,
//! and a reply that isn't the usage shape.
//!
//! `ListAgentAccounts` with no home folder: no CLI's account files can be
//! found, so the snapshot is empty, which is what Rust's providers report
//! without a home.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");

const RpcOutcome = common.RpcOutcome;

/// `is_loopback_http_url` / `validate_secure_url`.
pub fn secureUrlProblem(name: []const u8, raw: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(raw) catch return common.errText("{s} URL is invalid", .{name});
    if (std.mem.eql(u8, uri.scheme, "https")) return null;
    if (std.mem.eql(u8, uri.scheme, "http")) {
        if (uri.host) |h| {
            const host = switch (h) {
                .raw => |r| r,
                .percent_encoded => |p| p,
            };
            if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1")) return null;
        }
    }
    return common.errText("{s} must use HTTPS (plain HTTP is allowed only on loopback)", .{name});
}

/// `current_key`: the saved key, else a non-blank `CODEGRAFF_API_KEY`.
fn currentKey(host: *const engine_host.EngineHost) ?[]const u8 {
    if (host.auth.codegraff_api_key) |k| if (k.len > 0) return k;
    const env = common.getenv("CODEGRAFF_API_KEY") orelse return null;
    if (std.mem.trim(u8, env, " \t\r\n").len == 0) return null;
    return env;
}

const fields_i64 = [_][]const u8{
    "credits_micro_usd", "spend_30d_micro_usd",   "requests_30d",
    "prompt_tokens_30d", "completion_tokens_30d", "key_spend_monthly_micro_usd",
};

/// Re-read the gateway's body as `CodegraffUsage` (unknown fields dropped,
/// every field but the key budget required) and write it back out.
pub fn usageJson(gpa: Allocator, body: []const u8) !union(enum) { ok: []u8, err: []const u8 } {
    var parsed = json.parseFromSlice(json.Value, gpa, body, .{}) catch |e|
        return .{ .err = common.errText("unexpected CodeGraff usage response: {s}", .{@errorName(e)}) };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .err = "unexpected CodeGraff usage response: invalid type: expected struct CodegraffUsage" };
    const o = parsed.value.object;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    inline for (.{ "email", "tier" }) |k| {
        const v = o.get(k) orelse return .{ .err = "unexpected CodeGraff usage response: missing field `" ++ k ++ "`" };
        if (v != .string) return .{ .err = "unexpected CodeGraff usage response: invalid type for `" ++ k ++ "`, expected a string" };
        try s.objectField(k);
        try s.write(v.string);
    }
    inline for (fields_i64[0..5]) |k| {
        const v = o.get(k) orelse return .{ .err = "unexpected CodeGraff usage response: missing field `" ++ k ++ "`" };
        if (v != .integer) return .{ .err = "unexpected CodeGraff usage response: invalid type for `" ++ k ++ "`, expected i64" };
        try s.objectField(k);
        try s.write(v.integer);
    }
    try s.objectField("key_budget_monthly_micro_usd");
    if (o.get("key_budget_monthly_micro_usd")) |v| switch (v) {
        .null => try s.write(null),
        .integer => |n| try s.write(n),
        else => return .{ .err = "unexpected CodeGraff usage response: invalid type for `key_budget_monthly_micro_usd`, expected i64" },
    } else try s.write(null);
    {
        const k = "key_spend_monthly_micro_usd";
        const v = o.get(k) orelse return .{ .err = "unexpected CodeGraff usage response: missing field `" ++ k ++ "`" };
        if (v != .integer) return .{ .err = "unexpected CodeGraff usage response: invalid type for `" ++ k ++ "`, expected i64" };
        try s.objectField(k);
        try s.write(v.integer);
    }
    {
        const k = "key_budget_resets_at";
        const v = o.get(k) orelse return .{ .err = "unexpected CodeGraff usage response: missing field `" ++ k ++ "`" };
        if (v != .string) return .{ .err = "unexpected CodeGraff usage response: invalid type for `" ++ k ++ "`, expected a string" };
        try s.objectField(k);
        try s.write(v.string);
    }
    try s.endObject();
    return .{ .ok = try aw.toOwnedSlice() };
}

/// `CodegraffUsage` → `CodegraffUsage | null`.
pub fn codegraffUsage(host: *engine_host.EngineHost) !RpcOutcome {
    const gpa = host.gpa;
    const key = currentKey(host) orelse return .{ .unary_json = try gpa.dupe(u8, "null") };
    const gateway = std.mem.trimEnd(u8, host.auth.codegraff_gateway, "/");
    if (secureUrlProblem("CodeGraff gateway", gateway)) |m| return common.failedMsg(m);
    const io = host.io orelse return common.failedMsg("couldn't reach CodeGraff: the engine has no I/O");
    const url = try std.fmt.allocPrint(gpa, "{s}/v1/usage/summary", .{gateway});
    defer gpa.free(url);
    // The request is network-bound: not under the engine lock.
    const released = host.releaseForLongCall();
    const reply = auth_host.AuthManager.edgeRequest(gpa, io, "GET", url, key, null);
    host.retakeAfterLongCall(released);
    var r = reply catch |e| return common.failed("couldn't reach CodeGraff: {s}", .{@errorName(e)});
    defer r.deinit(gpa);
    if (r.status < 200 or r.status > 299)
        return common.failed("CodeGraff usage is unavailable: HTTP status {d} for url ({s})", .{ r.status, url });
    return switch (try usageJson(gpa, r.body)) {
        .ok => |b| .{ .unary_json = b },
        .err => |m| common.failedMsg(m),
    };
}

/// `ListAgentAccounts` when this engine has no home folder to read.
pub fn noHomeAccounts(gpa: Allocator) !RpcOutcome {
    return .{ .unary_json = try gpa.dupe(u8, "{\"accounts\":[],\"warnings\":[]}") };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// One loopback HTTP/1.1 reply, served once.
const OneShot = struct {
    server: std.Io.net.Server,
    status_line: []const u8,
    body: []const u8,
    saw_auth: bool = false,
    thread: ?std.Thread = null,

    fn start(self: *OneShot) !u16 {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.server = try addr.listen(testing.io, .{ .reuse_address = true });
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self.server.socket.address.getPort();
    }

    fn serve(self: *OneShot) void {
        const io = testing.io;
        var stream = self.server.accept(io) catch return;
        defer stream.close(io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            const t = std.mem.trimEnd(u8, line, "\r\n");
            if (t.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(t, "authorization: bearer cg-synthetic")) self.saw_auth = true;
        }
        writer.interface.print("HTTP/1.1 {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ self.status_line, self.body.len, self.body }) catch return;
        writer.interface.flush() catch {};
    }

    fn stop(self: *OneShot, port: u16) void {
        // Unblock an accept that never got its client, then join.
        if (std.Io.net.IpAddress.parseIp4("127.0.0.1", port)) |a| {
            if (a.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }
};

fn usageCall(host: *engine_host.EngineHost) !RpcOutcome {
    return host.handle("CodegraffUsage", .{ .object = .empty });
}

fn setGateway(host: *engine_host.EngineHost, url: []const u8) !void {
    host.gpa.free(host.auth.codegraff_gateway);
    host.auth.codegraff_gateway = try host.gpa.dupe(u8, url);
}

test "rpcw_usage CodegraffUsage is null without a key and re-reads the gateway summary with one" {
    const gpa = testing.allocator;
    var env = try common.TestEnv.init(gpa, "/nonexistent-home");
    defer env.deinit();
    env.install();
    var host = try engine_host.EngineHost.init(gpa, "dev-usage", "Synthetic");
    defer host.deinit();
    host.io = testing.io;
    if (host.auth.codegraff_api_key) |k| gpa.free(k);
    host.auth.codegraff_api_key = null;

    const none = try usageCall(&host);
    defer gpa.free(none.unary_json);
    try testing.expectEqualStrings("null", none.unary_json);

    var srv: OneShot = .{ .server = undefined, .status_line = "200 OK", .body =
        \\{"email":"synthetic@example.invalid","tier":"free","credits_micro_usd":5,"spend_30d_micro_usd":6,"requests_30d":7,"prompt_tokens_30d":8,"completion_tokens_30d":9,"key_spend_monthly_micro_usd":10,"key_budget_resets_at":"2026-12-01T00:00:00Z","extra":true}
    };
    const port = try srv.start();
    defer srv.stop(port);
    try env.map.put("CODEGRAFF_API_KEY", "cg-synthetic");
    const gw = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(gw);
    try setGateway(&host, gw);
    const out = try usageCall(&host);
    defer gpa.free(out.unary_json);
    try testing.expectEqualStrings(
        "{\"email\":\"synthetic@example.invalid\",\"tier\":\"free\",\"credits_micro_usd\":5,\"spend_30d_micro_usd\":6,\"requests_30d\":7,\"prompt_tokens_30d\":8,\"completion_tokens_30d\":9,\"key_budget_monthly_micro_usd\":null,\"key_spend_monthly_micro_usd\":10,\"key_budget_resets_at\":\"2026-12-01T00:00:00Z\"}",
        out.unary_json,
    );
    try testing.expect(srv.saw_auth);
}

test "rpcw_usage CodegraffUsage errors: insecure gateway, a refused status, an unexpected body" {
    const gpa = testing.allocator;
    var env = try common.TestEnv.init(gpa, "/nonexistent-home");
    defer env.deinit();
    try env.map.put("CODEGRAFF_API_KEY", "cg-synthetic");
    env.install();
    var host = try engine_host.EngineHost.init(gpa, "dev-usage", "Synthetic");
    defer host.deinit();
    host.io = testing.io;

    try setGateway(&host, "http://gateway.example.invalid");
    const insecure = try usageCall(&host);
    try testing.expectEqualStrings("CodeGraff gateway must use HTTPS (plain HTTP is allowed only on loopback)", insecure.err.exec_error);

    {
        var srv: OneShot = .{ .server = undefined, .status_line = "401 Unauthorized", .body = "{}" };
        const port = try srv.start();
        defer srv.stop(port);
        const gw = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
        defer gpa.free(gw);
        try setGateway(&host, gw);
        const refused = try usageCall(&host);
        try testing.expect(std.mem.startsWith(u8, refused.err.exec_error, "CodeGraff usage is unavailable: HTTP status 401"));
    }
    {
        var srv: OneShot = .{ .server = undefined, .status_line = "200 OK", .body = "{\"email\":\"x\"}" };
        const port = try srv.start();
        defer srv.stop(port);
        const gw = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
        defer gpa.free(gw);
        try setGateway(&host, gw);
        const odd = try usageCall(&host);
        try testing.expectEqualStrings("unexpected CodeGraff usage response: missing field `tier`", odd.err.exec_error);
    }
}

test "rpcw_usage ListAgentAccounts without a home lists nothing (no made-up plans)" {
    const gpa = testing.allocator;
    var host = try engine_host.EngineHost.init(gpa, "dev-accts", "Synthetic");
    defer host.deinit();
    try testing.expect(host.agent_accounts.home_dir == null);
    const out = try host.handle("ListAgentAccounts", .{ .object = .empty });
    defer gpa.free(out.unary_json);
    try testing.expectEqualStrings("{\"accounts\":[],\"warnings\":[]}", out.unary_json);
}
