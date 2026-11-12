//! The fake-arm gate: every RPC method that still answers with canned or
//! placeholder data instead of doing the work, each with why. The list can
//! only shrink:
//! - a method answering the shared no-op `{"ok":true}` that isn't listed
//!   (or known to mean it) fails the gate;
//! - a listed method whose reply is no longer the canned one fails it too:
//!   it has become real, so take it off the list.
//! `fake_arms.len` is the scoreboard (`scripts/prove-zig.sh` reports it).
//! Every call runs on a fresh engine host without I/O, so nothing here
//! spawns, dials or writes; no Rust source is read.
const std = @import("std");
const testing = std.testing;
const json = std.json;
const engine_host = @import("engine_host.zig");

pub const Reason = enum {
    no_implementation,
    local_identity,
    signin_without_session,
    projects_not_created,
    not_ported_import,

    pub fn text(r: Reason) []const u8 {
        return switch (r) {
            .no_implementation => "fixed reply; the engine does not do this yet",
            .local_identity => "the built-in signed-in `user-local`/`org-personal` identity, not a session (auth_host.zig AuthManager.init)",
            .signin_without_session => "development sign-in that succeeds without a session or a URL",
            .projects_not_created => "answers the default project; nothing is added, cloned or created",
            .not_ported_import => "refuses every real local profile (the Loro registry is not read)",
        };
    }
};

pub const FakeArm = struct {
    method: []const u8,
    params: []const u8 = "{}",
    /// The canned reply's start (or the error text for refusals).
    canned: []const u8,
    reason: Reason,
};

pub const fake_arms = [_]FakeArm{
    .{ .method = "ListCommands", .canned = "[{\"name\":\"compact\",\"description\":\"Compact conversation history\"},{\"name\":\"clear\",\"description\":\"Start a fresh chat\"}]", .reason = .no_implementation },
    .{ .method = "CodegraffJobs", .canned = "{\"jobs\":[]}", .reason = .no_implementation },
    .{ .method = "WatchTransfers", .canned = "[]", .reason = .no_implementation },
    .{ .method = "WatchConnectivity", .canned = "{\"state\":\"connected\",\"online\":true}", .reason = .no_implementation },
    .{ .method = "WatchToolProgress", .canned = "{\"items\":[]}", .reason = .no_implementation },
    .{ .method = "WatchWorkspaceFiles", .canned = "{\"changed\":[]}", .reason = .no_implementation },
    .{ .method = "WatchLocalhostPage", .canned = "{\"frame\":null}", .reason = .no_implementation },
    .{ .method = "LocalhostPageInput", .canned = "{\"ok\":true}", .reason = .no_implementation },
    .{ .method = "ListLocalhostServers", .canned = "{\"servers\":[]}", .reason = .no_implementation },
    .{ .method = "ListGraffLogins", .canned = "[{\"id\":\"anthropic\",\"name\":\"Anthropic\",\"signedIn\":true", .reason = .no_implementation },
    .{ .method = "RetryDelivery", .params = "{\"chatId\":\"chat-gate\"}", .canned = "{\"retried\":true}", .reason = .no_implementation },
    .{ .method = "AuthStatus", .canned = "{\"state\":\"signedIn\",\"user\":{\"id\":\"user-local\"", .reason = .local_identity },
    .{ .method = "GetAuthStatus", .canned = "{\"signedIn\":true,\"email\":\"local@codegraff.com\"", .reason = .local_identity },
    .{ .method = "GetCodegraffStatus", .canned = "{\"signedIn\":true,\"email\":\"local@codegraff.com\"", .reason = .local_identity },
    .{ .method = "CodegraffAuthStatus", .canned = "{\"signedIn\":true,\"pending\":false,\"email\":\"local@codegraff.com\"", .reason = .local_identity },
    .{ .method = "SignIn", .canned = "{\"url\":\"\",\"ok\":true", .reason = .signin_without_session },
    .{ .method = "CodegraffSignIn", .canned = "{\"url\":\"\",\"ok\":true,\"signedIn\":true}", .reason = .signin_without_session },
    .{ .method = "AddRepo", .canned = "{\"path\":\".\",\"spaceId\":\"space-zig-default\"}", .reason = .projects_not_created },
    .{ .method = "CloneRepo", .canned = "{\"path\":\".\",\"spaceId\":\"space-zig-default\"}", .reason = .projects_not_created },
    .{ .method = "CreateRepo", .canned = "{\"path\":\".\",\"spaceId\":\"space-zig-default\"}", .reason = .projects_not_created },
};

/// Methods whose `{"ok":true}` is the real answer (Rust's too).
const ok_is_real = [_][]const u8{ "StopEngine", "CheckForUpdates" };

/// The reply's first body, or the error text, for `method` on a fresh host.
fn replyOf(gpa: std.mem.Allocator, method: []const u8, params_text: []const u8) !union(enum) { body: []u8, err: []const u8, none } {
    var host = try engine_host.EngineHost.init(gpa, "dev-gate", "Gate");
    defer host.deinit();
    var params = try json.parseFromSlice(json.Value, gpa, params_text, .{});
    defer params.deinit();
    var out = try host.handle(method, params.value);
    switch (out) {
        .unary_json => |b| return .{ .body = b },
        .stream_items_json => |*st| {
            defer st.deinit(gpa);
            if (st.items.len == 0) return .none;
            return .{ .body = try gpa.dupe(u8, st.items[0]) };
        },
        .err => |e| return .{ .err = switch (e) {
            inline else => |m| m,
        } },
    }
}

fn listed(method: []const u8) bool {
    for (fake_arms) |f| if (std.mem.eql(u8, f.method, method)) return true;
    return false;
}

test "fake-arm gate: no unlisted method answers the shared no-op reply" {
    const gpa = testing.allocator;
    var offenders: usize = 0;
    for (engine_host.rpc_method_map.keys()) |method| {
        const r = try replyOf(gpa, method, "{}");
        switch (r) {
            .body => |b| {
                defer gpa.free(b);
                if (!std.mem.eql(u8, b, "{\"ok\":true}")) continue;
                if (listed(method)) continue;
                for (ok_is_real) |m| {
                    if (std.mem.eql(u8, m, method)) break;
                } else {
                    std.debug.print("fake-arm gate: {s} answers the shared {{\"ok\":true}} and is not listed\n", .{method});
                    offenders += 1;
                }
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 0), offenders);
}

test "fake-arm gate: every listed method is still canned (the list only shrinks)" {
    const gpa = testing.allocator;
    var became_real: usize = 0;
    for (fake_arms) |f| {
        try testing.expect(engine_host.rpc_method_map.get(f.method) != null);
        const r = try replyOf(gpa, f.method, f.params);
        const still = switch (r) {
            .body => |b| blk: {
                defer gpa.free(b);
                break :blk std.mem.startsWith(u8, b, f.canned);
            },
            .err => |m| std.mem.startsWith(u8, m, f.canned),
            .none => false,
        };
        if (!still) {
            std.debug.print("fake-arm gate: {s} no longer answers its canned reply; take it off the list\n", .{f.method});
            became_real += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), became_real);
    std.debug.print("fake-arm gate: {d} methods still canned\n", .{fake_arms.len});
}
