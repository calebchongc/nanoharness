//! `TakeProjectActionSetup`, ported from `crates/engine/src/rpc.rs`
//! (`methods::TAKE_PROJECT_ACTION_SETUP`) and `project_actions.rs`
//! (`take_setup_handoff`).
//!
//! In Rust a run that creates its worktree leaves a setup handoff (the setup
//! Action it launched, or why it couldn't) for the client to collect once by
//! command id. This engine reports a worktree's setup Action inline in the
//! `CreateWorktree` reply and never leaves a handoff, so there is never one
//! to take: the answer is Rust's for a missing handoff, `{"ready":false}`.
const std = @import("std");
const json = std.json;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");

const RpcOutcome = common.RpcOutcome;

/// `TakeProjectActionSetup { chatId, commandId }` → `{"ready":false}`.
pub fn takeProjectActionSetup(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return .{ .err = .{ .bad_params = "invalid type: expected struct TakeProjectActionSetupParams" } };
    inline for (.{ "chatId", "commandId" }) |key| {
        const v = o.get(key) orelse return .{ .err = .{ .bad_params = "missing field `" ++ key ++ "`" } };
        if (v != .string) return .{ .err = .{ .bad_params = "invalid type: expected a string for `" ++ key ++ "`" } };
    }
    return .{ .unary_json = try host.gpa.dupe(u8, "{\"ready\":false}") };
}

const testing = std.testing;

test "rpcw_project_action_setup answers not ready and checks its params" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    var p = try json.parseFromSlice(json.Value, testing.allocator, "{\"chatId\":\"chat-1\",\"commandId\":\"cmd-1\"}", .{});
    defer p.deinit();
    const ok = try host.handle("TakeProjectActionSetup", p.value);
    defer testing.allocator.free(ok.unary_json);
    try testing.expectEqualStrings("{\"ready\":false}", ok.unary_json);
    var q = try json.parseFromSlice(json.Value, testing.allocator, "{\"chatId\":\"chat-1\"}", .{});
    defer q.deinit();
    try testing.expectEqualStrings("missing field `commandId`", (try host.handle("TakeProjectActionSetup", q.value)).err.bad_params);
    try testing.expectEqualStrings("missing field `chatId`", (try host.handle("TakeProjectActionSetup", .{ .object = .empty })).err.bad_params);
}
