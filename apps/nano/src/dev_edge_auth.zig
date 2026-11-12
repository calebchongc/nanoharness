//! Explicit loopback-only local sign-in. HARNESS_EDGE_TOKEN is an opaque,
//! ephemeral session issued by the local runner, not an asserted identity.
//! The local Worker must verify it before the engine becomes signed in.
//! Production CodeGraff authentication is never replaced by a local session.
const std = @import("std");
const auth_host = @import("auth_host.zig");
const AuthEnv = @import("engine_cli.zig").AuthEnv;
const testing = std.testing;

/// Only the literal IPv4 loopback origin supported by the HTTP transport.
/// No DNS, URL credentials, paths, query, fragments, or normalized lookalikes.
pub fn localOrigin(url: []const u8) bool {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const port = url[prefix.len..];
    if (port.len == 0) return false;
    for (port) |c| if (!std.ascii.isDigit(c)) return false;
    return (std.fmt.parseInt(u16, port, 10) catch return false) > 0;
}

pub fn configure(auth: *auth_host.AuthManager, io: std.Io, cfg: AuthEnv, org_env: ?[]const u8, data_dir: ?[]const u8) !void {
    if (cfg.disabled) return;
    // AuthManager defaults to permissive offline development; local auth is
    // fail-closed even before the first request and when reconfigured.
    auth.signOut();
    const bearer = cfg.edge_token orelse {
        if (cfg.local_edge_auth) return error.MissingLocalSession;
        try auth.configureCodegraff(cfg.edge_url, null, cfg.api_base, data_dir);
        return;
    };
    if (!cfg.local_edge_auth) return error.LocalAuthNotEnabled;
    if (!localOrigin(cfg.edge_url)) return error.LocalAuthRequiresLoopback;
    if (bearer.len == 0 or std.mem.indexOfAny(u8, bearer, " \t\r\n") != null) return error.InvalidLocalSession;
    const url = try std.fmt.allocPrint(auth.gpa, "{s}/auth/local-session", .{cfg.edge_url});
    defer auth.gpa.free(url);
    var reply = try auth_host.AuthManager.edgeRequestTimed(null, auth.gpa, io, "GET", url, bearer, &.{}, null, 5_000);
    defer reply.deinit(auth.gpa);
    if (reply.status != 200) return error.InvalidLocalSession;
    var parsed = try std.json.parseFromSlice(std.json.Value, auth.gpa, reply.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLocalSession;
    const mode = parsed.value.object.get("mode") orelse return error.InvalidLocalSession;
    const user = parsed.value.object.get("userId") orelse return error.InvalidLocalSession;
    const org = parsed.value.object.get("orgId") orelse return error.InvalidLocalSession;
    if (mode != .string or !std.mem.eql(u8, mode.string, "local") or
        user != .string or user.string.len == 0 or org != .string or org.string.len == 0) return error.InvalidLocalSession;
    if (org_env) |expected| {
        if (expected.len > 0 and !std.mem.eql(u8, expected, org.string)) return error.LocalOrgMismatch;
    }
    try auth.configureCodegraff(cfg.edge_url, null, cfg.api_base, data_dir);
    try replace(auth, &auth.user_id, user.string);
    try replace(auth, &auth.email, user.string);
    const org_copy = try auth.gpa.dupe(u8, org.string);
    if (auth.org_id) |old| auth.gpa.free(old);
    auth.org_id = org_copy;
    // Last: no error path above can report a signed-in session.
    try auth.signInWithKey(bearer);
}

fn replace(auth: *auth_host.AuthManager, slot: *[]u8, value: []const u8) !void {
    const copy = try auth.gpa.dupe(u8, value);
    auth.gpa.free(slot.*);
    slot.* = copy;
}

fn envWith(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "dev edge auth: a bearer alone cannot bypass production or unavailable local auth" {
    for ([_][]const u8{ "https://edge.codegraff.com", "http://127.0.0.1:9" }) |url| {
        var env = try envWith(&.{
            .{ "HARNESS_EDGE_URL", url },
            .{ "HARNESS_EDGE_TOKEN", "not-a-valid-local-session" },
            .{ "HARNESS_CODEGRAFF_CLIENT_ID", "" },
        });
        defer env.deinit();
        var auth = try auth_host.AuthManager.init(testing.allocator);
        defer auth.deinit();
        configure(&auth, testing.io, AuthEnv.from(&env), null, null) catch {};
        try testing.expect(!auth.signed_in);
        try testing.expect(auth.api_key == null);
    }
}

test "dev edge auth: explicitly local auth never signs in without a live session" {
    var env = try envWith(&.{
        .{ "HARNESS_EDGE_URL", "http://127.0.0.1:9" },
        .{ "HARNESS_EDGE_TOKEN", "not-a-valid-local-session" },
        .{ "HARNESS_LOCAL_EDGE_AUTH", "1" },
        .{ "HARNESS_CODEGRAFF_CLIENT_ID", "" },
    });
    defer env.deinit();
    var auth = try auth_host.AuthManager.init(testing.allocator);
    defer auth.deinit();
    configure(&auth, testing.io, AuthEnv.from(&env), null, null) catch {};
    try testing.expect(!auth.signed_in);
    try testing.expect(auth.api_key == null);
}

test "dev edge auth: auth turned off configures no edge" {
    var env = try envWith(&.{
        .{ "HARNESS_AUTH_DISABLED", "1" },
        .{ "HARNESS_EDGE_URL", "http://127.0.0.1:40123" },
        .{ "HARNESS_EDGE_TOKEN", "synthetic-session" },
    });
    defer env.deinit();
    var auth = try auth_host.AuthManager.init(testing.allocator);
    defer auth.deinit();
    try configure(&auth, testing.io, AuthEnv.from(&env), null, null);
    try testing.expect(auth.edge_url == null);
    try testing.expect(auth.api_key == null);
}

test "dev edge auth: explicit local auth rejects remote and ambiguous origins" {
    for ([_][]const u8{
        "https://edge.codegraff.com",          "http://localhost:40123",      "http://127.0.0.1.example.invalid:40123",
        "http://127.0.0.1:40123@evil.invalid", "http://127.0.0.1:40123/path", "http://127.0.0.1:40123?x=1",
        "http://127.0.0.1:0",                  "http://127.0.0.1:65536",      "http://192.0.2.1:40123",
    }) |url| {
        try testing.expect(!localOrigin(url));
        var env = try envWith(&.{
            .{ "HARNESS_LOCAL_EDGE_AUTH", "1" }, .{ "HARNESS_EDGE_URL", url }, .{ "HARNESS_EDGE_TOKEN", "synthetic-session" },
        });
        defer env.deinit();
        var auth = try auth_host.AuthManager.init(testing.allocator);
        defer auth.deinit();
        try testing.expectError(error.LocalAuthRequiresLoopback, configure(&auth, testing.io, AuthEnv.from(&env), null, null));
        try testing.expect(!auth.signed_in);
    }
    try testing.expect(localOrigin("http://127.0.0.1:40123"));
}

test "dev edge auth: verified Worker identity only, rejection and malformed sessions fail closed" {
    const mock = @import("sec_tests.zig");
    for ([_]mock.MockEdge.Route{
        .{ .path = "/auth/local-session", .status = 200, .body = "{\"mode\":\"local\",\"userId\":\"ada-synthetic\",\"orgId\":\"user-ada-synthetic\"}" },
        .{ .path = "/auth/local-session", .status = 401, .body = "{\"error\":\"unauthenticated\"}" },
        .{ .path = "/auth/local-session", .status = 200, .body = "{}" },
        .{ .path = "/auth/local-session", .status = 200, .body = "{\"mode\":\"codegraff\",\"userId\":\"ada\",\"orgId\":\"org\"}" },
    }, 0..) |route, i| {
        var server: mock.MockEdge = .{ .server = try mock.listenLoopback(), .routes = &.{route} };
        try server.start();
        defer server.deinit();
        var buf: [128]u8 = undefined;
        var env = try envWith(&.{
            .{ "HARNESS_LOCAL_EDGE_AUTH", "1" }, .{ "HARNESS_EDGE_URL", server.url(&buf) }, .{ "HARNESS_EDGE_TOKEN", "opaque-synthetic-session" },
        });
        defer env.deinit();
        var auth = try auth_host.AuthManager.init(testing.allocator);
        defer auth.deinit();
        if (i == 0) {
            try testing.expectError(error.LocalOrgMismatch, configure(&auth, testing.io, AuthEnv.from(&env), "different-org", null));
            try testing.expect(!auth.signed_in);
            try configure(&auth, testing.io, AuthEnv.from(&env), null, null);
            try testing.expect(auth.signed_in);
            try testing.expectEqualStrings("ada-synthetic", auth.user_id);
            try testing.expectEqualStrings("user-ada-synthetic", auth.org_id.?);
        } else {
            try testing.expectError(error.InvalidLocalSession, configure(&auth, testing.io, AuthEnv.from(&env), null, null));
            try testing.expect(!auth.signed_in);
            try testing.expect(auth.api_key == null);
        }
    }
}
