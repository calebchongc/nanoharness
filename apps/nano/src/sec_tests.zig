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
