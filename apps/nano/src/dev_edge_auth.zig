//! Development sign-in against an edge in dev auth (`AUTH_MODE=dev`,
//! `edge/src/auth.ts` `verifyToken`): no CodeGraff, the bearer is
//! `HARNESS_EDGE_TOKEN` itself, `user` or `user@org`.
//!
//! The Worker reads `user@org` as user `user` scoped to org `org`, and its
//! `/registry/:orgId/*` and `/workspace/:orgId/*` routes answer 403 unless
//! the bearer's org is the URL's. So the engine's org is `HARNESS_ORG_ID`,
//! else the bearer's own `@org`, else `dev-org` (the Rust engine's default,
//! `workspace_host::DEFAULT_ORG_ID`); its user id is the part before `@`
//! (`Auth::user_id` in `crates/engine/src/auth.rs`).
const std = @import("std");
const auth_host = @import("auth_host.zig");
const AuthEnv = @import("engine_cli.zig").AuthEnv;

pub const default_org = "dev-org";

/// The user and org the Worker's dev auth reads from `bearer`, and the org
/// this engine syncs: `org_env` (`HARNESS_ORG_ID`) when set.
pub fn identity(bearer: []const u8, org_env: ?[]const u8) struct { user: []const u8, org: []const u8 } {
    const at = std.mem.indexOfScalar(u8, bearer, '@');
    const user = if (at) |i| (if (i > 0) bearer[0..i] else bearer) else bearer;
    const from_bearer: ?[]const u8 = if (at) |i| (if (i > 0 and i + 1 < bearer.len) bearer[i + 1 ..] else null) else null;
    const org = if (org_env) |o| (if (o.len > 0) o else null) else null;
    return .{ .user = user, .org = org orelse from_bearer orelse default_org };
}

/// Configure `auth` for an engine start without CodeGraff: the edge URL (the
/// sync worker and the device relay need it) and, with `HARNESS_EDGE_TOKEN`,
/// the bearer and the identity it stands for. Auth turned off configures
/// nothing: that engine never talks to an edge.
pub fn configure(auth: *auth_host.AuthManager, cfg: AuthEnv, org_env: ?[]const u8, data_dir: ?[]const u8) !void {
    if (cfg.disabled) return;
    try auth.configureCodegraff(cfg.edge_url, null, cfg.api_base, data_dir);
    const bearer = cfg.edge_token orelse return;
    try auth.signInWithKey(bearer);
    const who = identity(std.mem.trim(u8, bearer, " \t\r\n"), org_env);
    try replace(auth, &auth.user_id, who.user);
    try replace(auth, &auth.email, who.user);
    const org = try auth.gpa.dupe(u8, who.org);
    if (auth.org_id) |old| auth.gpa.free(old);
    auth.org_id = org;
}

fn replace(auth: *auth_host.AuthManager, slot: *[]u8, value: []const u8) !void {
    const copy = try auth.gpa.dupe(u8, value);
    auth.gpa.free(slot.*);
    slot.* = copy;
}

const testing = std.testing;

fn envWith(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "dev edge auth: a development bearer points the engine at the configured edge, as the Worker's dev auth reads it" {
    var env = try envWith(&.{
        .{ "HARNESS_EDGE_URL", "http://127.0.0.1:40123" },
        .{ "HARNESS_CODEGRAFF_CLIENT_ID", "" },
        .{ "HARNESS_EDGE_TOKEN", "ada-synthetic@org-synthetic" },
    });
    defer env.deinit();
    var auth = try auth_host.AuthManager.init(testing.allocator);
    defer auth.deinit();
    try configure(&auth, AuthEnv.from(&env), null, "/nonexistent/synthetic-data");
    // Without the edge URL the registry sync and the device relay never start.
    try testing.expectEqualStrings("http://127.0.0.1:40123", auth.edge_url.?);
    try testing.expect(auth.signed_in);
    try testing.expectEqualStrings("ada-synthetic@org-synthetic", auth.ensureAccessToken(testing.io, false).?);
    try testing.expectEqualStrings("ada-synthetic", auth.user_id);
    // `/registry/org-synthetic/*` is the only registry this bearer may use.
    try testing.expectEqualStrings("org-synthetic", auth.org_id.?);
}

test "dev edge auth: org, HARNESS_ORG_ID, else the bearer's own org, else dev-org" {
    try testing.expectEqualStrings("org-env", identity("ada@org-bearer", "org-env").org);
    try testing.expectEqualStrings("org-bearer", identity("ada@org-bearer", null).org);
    try testing.expectEqualStrings("org-bearer", identity("ada@org-bearer", "").org);
    try testing.expectEqualStrings("dev-org", identity("ada", null).org);
    try testing.expectEqualStrings("ada", identity("ada", null).user);
    try testing.expectEqualStrings("dev-org", identity("ada@", null).org);
}

test "dev edge auth: auth turned off configures no edge" {
    var env = try envWith(&.{
        .{ "HARNESS_AUTH_DISABLED", "1" },
        .{ "HARNESS_EDGE_URL", "http://127.0.0.1:40123" },
        .{ "HARNESS_EDGE_TOKEN", "ada-synthetic" },
    });
    defer env.deinit();
    var auth = try auth_host.AuthManager.init(testing.allocator);
    defer auth.deinit();
    try configure(&auth, AuthEnv.from(&env), null, null);
    try testing.expect(auth.edge_url == null);
    try testing.expect(auth.api_key == null);
}
