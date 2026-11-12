//! `StartAgentLogin`, `CompleteAgentLogin`, `PollAgentLogin`,
//! `CancelAgentLogin`, `ActivateAgentAccount` and `ForgetAgentAccount`,
//! ported from `crates/engine/src/rpc.rs` onto `agent_logins.zig` (Rust's
//! `AgentAccounts`: the login registry, saved-login slots and switching).
//!
//! One registry per data dir lives for the process, as Rust's `AgentAccounts`
//! lives for the engine. Start/Complete wait on login children and HTTP, and
//! Activate/Forget may run `security`: none of them touches engine state, so
//! they can run outside the host lock.
const std = @import("std");
const json = std.json;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const core = @import("catalog_core.zig");
const rpc_models = @import("rpc_models.zig");
const logins = @import("agent_logins.zig");

const RpcOutcome = common.RpcOutcome;
const long_gpa = core.long_gpa;

var registry_mutex: std.Io.Mutex = .init;
var registries: std.StringHashMapUnmanaged(*logins.Registry) = .empty;

fn registryFor(io: std.Io, data_dir: []const u8) !*logins.Registry {
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (registries.get(data_dir)) |r| return r;
    const key = try long_gpa.dupe(u8, data_dir);
    errdefer long_gpa.free(key);
    const r = try logins.Registry.init(long_gpa, io, data_dir);
    try registries.put(long_gpa, key, r);
    return r;
}

pub fn handle(host: *engine_host.EngineHost, method: []const u8, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const io = host.io orelse return common.failed("agent accounts need I/O", .{});
    const data_dir = host.data_dir orelse return common.failed("agent accounts need a data dir", .{});
    rpc_models.installHooks();
    const reg = try registryFor(io, data_dir);
    // Logins wait on their CLI children and HTTP: not under the engine lock
    // (the registry has its own).
    const reply = blk: {
        const released = host.releaseForLongCall();
        defer host.retakeAfterLongCall(released);
        break :blk reg.handle(method, params);
    } orelse return .{ .err = .{ .unknown_method = method } };
    defer reply.deinit(long_gpa);
    return switch (reply) {
        .ok => |body| .{ .unary_json = try gpa.dupe(u8, body) },
        .bad_params => |m| common.badParams("{s}", .{m}),
        .failed, .not_ported => |m| common.failed("{s}", .{m}),
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn call(host: *engine_host.EngineHost, method: []const u8, text: []const u8) !RpcOutcome {
    var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer p.deinit();
    return host.handle(method, p.value);
}

fn expectErr(outcome: RpcOutcome, kind: enum { exec, bad }, expected: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .exec_error => |m| {
                try testing.expect(kind == .exec);
                try testing.expectEqualStrings(expected, m);
            },
            .bad_params => |m| {
                try testing.expect(kind == .bad);
                try testing.expectEqualStrings(expected, m);
            },
            else => return error.UnexpectedErrorKind,
        },
        .unary_json => |b| {
            std.debug.print("unexpected success: {s}\n", .{b});
            testing.allocator.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

test "rpc_logins routes every login method through the registry" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try common.tmpPath(gpa, io, &tmp);
    defer gpa.free(base);
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "data");
    const home = try std.fs.path.join(gpa, &.{ base, "home" });
    defer gpa.free(home);
    const bin = try std.fs.path.join(gpa, &.{ base, "bin" });
    defer gpa.free(bin);
    const data = try std.fs.path.join(gpa, &.{ base, "data" });
    defer gpa.free(data);
    var env = try common.TestEnv.init(gpa, home);
    defer env.deinit();
    try env.map.put("PATH", bin);
    try env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
    try env.map.put("HARNESS_DISABLE_SHELL_ENV", "1");
    env.install();
    defer core.env_override = null;
    const exes = @import("rpcw_executables.zig");
    exes.system_prefix = base;
    defer exes.system_prefix = "";

    var host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
    defer host.deinit();
    host.io = io;
    try host.setDataDir(data);

    // Params are checked like serde.
    try expectErr(try call(&host, "ActivateAgentAccount", "{\"harness\":\"codex\"}"), .bad, "missing field `accountId`");
    try expectErr(try call(&host, "CompleteAgentLogin", "{\"loginId\":\"x\"}"), .bad, "missing field `code`");
    try expectErr(try call(&host, "StartAgentLogin", "{}"), .bad, "missing field `harness`");
    // The branch rules of StartAgentLogin.
    try expectErr(try call(&host, "StartAgentLogin", "{\"harness\":\"claude-code\",\"deviceAuth\":true}"), .exec, "Device authorization is supported only for explicit Codex recovery.");
    try expectErr(try call(&host, "StartAgentLogin", "{\"harness\":\"graff\"}"), .exec, "Say which graff provider to sign in to.");

    // A Claude sign-in is the PKCE paste-code flow: a real authorize URL.
    const start = try call(&host, "StartAgentLogin", "{\"harness\":\"claude-code\"}");
    defer gpa.free(start.unary_json);
    var sp = try json.parseFromSlice(json.Value, gpa, start.unary_json, .{});
    defer sp.deinit();
    const login_id = sp.value.object.get("loginId").?.string;
    try testing.expect(std.mem.indexOf(u8, sp.value.object.get("url").?.string, "code_challenge=") != null);

    // Cancelling it is always ok; afterwards it is unknown.
    const cancel_body = try std.fmt.allocPrint(gpa, "{{\"loginId\":\"{s}\"}}", .{login_id});
    defer gpa.free(cancel_body);
    const cancelled = try call(&host, "CancelAgentLogin", cancel_body);
    defer gpa.free(cancelled.unary_json);
    try testing.expectEqualStrings("{\"ok\":true}", cancelled.unary_json);
    const polled = try call(&host, "PollAgentLogin", cancel_body);
    try testing.expect(polled == .err and polled.err == .exec_error);

    // No saved login to switch to or forget.
    const act = try call(&host, "ActivateAgentAccount", "{\"harness\":\"codex\",\"accountId\":\"codex-none\"}");
    try testing.expect(act == .err and act.err == .exec_error);
}

test "rpc_logins needs a data dir like Rust's AgentAccounts" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    host.io = testing.io;
    const out = try call(&host, "CancelAgentLogin", "{\"loginId\":\"x\"}");
    try testing.expect(out == .err and out.err == .exec_error);
}

test "rpc_logins SwitchAgentAccount and RemoveAgentAccount are unknown methods, as in Rust" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    for ([_][]const u8{ "SwitchAgentAccount", "RemoveAgentAccount" }) |m| {
        const out = try call(&host, m, "{\"harness\":\"codex\",\"accountId\":\"a\"}");
        try testing.expect(out == .err and out.err == .unknown_method);
        try testing.expectEqualStrings(m, out.err.unknown_method);
    }
}
