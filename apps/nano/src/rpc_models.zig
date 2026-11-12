//! `ListModels { harness, force? }`, ported from `crates/engine/src/rpc.rs`
//! (`LIST_MODELS`: `registry.resolve(harness)` then
//! `model_catalogs::list(data_dir, harness, force)`).
//!
//! Every harness's catalog is its live probe (`catalog_*.zig`) behind the
//! shared cache rules in `catalog_core.zig`; the mock harness answers its two
//! scripted rows (`crates/harness/src/mock.rs`), as Rust's does.
//!
//! The call can take as long as a probe's deadline (35 s for Claude), so it
//! touches no engine state beyond the data dir: it can run outside the host
//! lock.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const exes = @import("rpcw_executables.zig");
const engine_host = @import("engine_host.zig");
const core = @import("catalog_core.zig");
const build_info = @import("build_info");

const HarnessId = exes.HarnessId;
const RpcOutcome = common.RpcOutcome;

// ── the mock harness (`MockHarness::models`) ───────────────────────────────

pub const mock_models = [_]core.Model{
    .{ .id = "mock-1", .label = "Mock 1", .reasoning_levels = &.{"medium"} },
    // Claude-mirroring demo model: scripted runs carry the same chip labels.
    .{ .id = "mock-fable-5", .label = "Fable 5", .reasoning_levels = &.{ "low", "medium", "high", "xhigh" } },
};

const Mock = struct {
    var instance: u8 = 0;

    fn harness() core.Harness {
        return .{ .id = "mock", .ptr = &instance, .vtable = &.{ .modelContext = ctx, .modelCatalog = catalog, .fallbackModels = fallback } };
    }
    fn ctx(_: *anyopaque, _: Allocator, _: std.Io) anyerror!core.ContextResult {
        return .none;
    }
    fn catalog(_: *anyopaque, gpa: Allocator, _: std.Io, _: bool) anyerror!core.Result {
        return .{ .ok = .{ .models = try core.modelsJson(gpa, &mock_models), .source = .live } };
    }
    fn fallback(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
        return gpa.dupe(u8, "[]");
    }
};

/// Each registered harness's discovery surface.
pub fn harnessFor(id: HarnessId) core.Harness {
    return switch (id) {
        .mock => Mock.harness(),
        .claude_code => @import("catalog_claude.zig").harness(),
        .codex => @import("catalog_codex.zig").harness(),
        .cursor => @import("catalog_cursor.zig").harness(),
        .pi => @import("catalog_pi.zig").harness(),
        .opencode => @import("catalog_opencode.zig").harness(),
        .graff => @import("catalog_graff.zig").harness(),
        .devin => @import("catalog_devin.zig").harness(),
        .grok, .hermes, .antigravity, .exo => @import("catalog_acp.zig").harness(id.wire()).?,
    };
}

/// The engine's CLI discovery for the probes (`resolve_launch` /
/// `resolve_executable`).
fn resolveCli(gpa: Allocator, io: std.Io, wire: []const u8) anyerror!?[]u8 {
    const id = HarnessId.parse(wire) orelse return null;
    return switch (id) {
        // The ACP server is `harness exo-acp`, which this engine does not
        // ship: only an explicit server override launches.
        .exo => if (common.getenvNonEmpty("EXO_ACP_EXECUTABLE")) |v| (if (common.isFile(io, v)) try gpa.dupe(u8, v) else null) else null,
        .antigravity => resolveAntigravity(gpa, io),
        else => exes.resolveCli(gpa, io, id),
    };
}

/// Antigravity's `resolve_launch`: the override, the server on PATH (also
/// as `.par`/`.exe`), then the managed archive entry when its install marker
/// matches the pin (`archive_install::installed_entry`).
fn resolveAntigravity(gpa: Allocator, io: std.Io) !?[]u8 {
    if (common.getenvNonEmpty("ANTIGRAVITY_ACP_EXECUTABLE")) |v| return if (common.isFile(io, v)) try gpa.dupe(u8, v) else null;
    for ([_][]const u8{ "agy_acp_server", "agy_acp_server.par", "agy_acp_server.exe" }) |name| {
        if (try exes.findOnPaths(gpa, io, name, &.{})) |p| return p;
    }
    const pin = exes.antigravityArchive() orelse return null;
    const root = (try exes.adaptersRoot(gpa)) orelse return null;
    defer gpa.free(root);
    return archiveEntry(gpa, io, root, pin);
}

/// `installed_entry(pin)`: the entry when `.harness-install-ok` holds the
/// pin's sha512 and the entry is a file. Owned.
pub fn archiveEntry(gpa: Allocator, io: std.Io, root: []const u8, pin: exes.ArchivePin) !?[]u8 {
    const marker = try std.fs.path.join(gpa, &.{ root, pin.name, pin.version, ".harness-install-ok" });
    defer gpa.free(marker);
    const text = std.Io.Dir.cwd().readFileAlloc(io, marker, gpa, .limited(4096)) catch return null;
    defer gpa.free(text);
    if (!std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), pin.sha512)) return null;
    const entry = try std.fs.path.join(gpa, &.{ root, pin.name, pin.version, pin.entry });
    if (common.isFile(io, entry)) return entry;
    gpa.free(entry);
    return null;
}

/// Point the shared probes at this engine's environment, CLI discovery,
/// version and graff settings.
pub fn installHooks() void {
    core.resolve_cli = resolveCli;
    core.env_override = common.env_override;
    @import("catalog_codex.zig").client_version = build_info.version;
    @import("catalog_acp.zig").client_version = build_info.version;
}

fn applyGraffSettings(host: *engine_host.EngineHost, io: std.Io) void {
    const graff = @import("catalog_graff.zig");
    graff.draft_subagents.store(host.graff_draft_subagents, .release);
    graff.compact_at.store(@intCast(std.math.clamp(host.graff_compact_at, 0, 255)), .release);
    graff.setDeviceName(io, host.device_name);
}

pub const Params = union(enum) {
    ok: struct { id: HarnessId, force: bool },
    err: RpcOutcome,
};

/// `ListModelsParams { harness: HarnessId, #[serde(default)] force: bool }`.
pub fn parseParams(params: json.Value) Params {
    const o = common.obj(params) orelse return .{ .err = common.badParams("invalid type: expected struct ListModelsParams", .{}) };
    const v = o.get("harness") orelse return .{ .err = common.badParams("missing field `harness`", .{}) };
    if (v != .string) return .{ .err = common.badParams("invalid type: expected a harness id for `harness`", .{}) };
    const id = HarnessId.parse(v.string) orelse return .{ .err = .{ .err = .{ .bad_params = exes.unknownVariantText(v.string) } } };
    var force = false;
    if (o.get("force")) |f| switch (f) {
        .bool => |b| force = b,
        .null => {},
        else => return .{ .err = common.badParams("invalid type: expected a boolean for `force`", .{}) },
    };
    return .{ .ok = .{ .id = id, .force = force } };
}

pub fn listModels(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const p = switch (parseParams(params)) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const gpa = host.gpa;
    if (p.id == .mock) return .{ .unary_json = try core.modelsJson(gpa, &mock_models) };
    const io = host.io orelse return common.failed("model discovery needs I/O", .{});
    installHooks();
    applyGraffSettings(host, io);
    // A probe can take its full deadline (35 s): not under the engine lock.
    const data_dir = if (host.data_dir) |d| try gpa.dupe(u8, d) else null;
    defer if (data_dir) |d| gpa.free(d);
    const r = blk: {
        const released = host.releaseForLongCall();
        defer host.retakeAfterLongCall(released);
        break :blk try core.list(gpa, io, data_dir, harnessFor(p.id), p.force);
    };
    return switch (r) {
        .ok => |m| .{ .unary_json = m },
        .err => |f| blk: {
            var buf: [1200]u8 = undefined;
            break :blk common.failed("{s}", .{f.display(&buf)});
        },
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn call(host: *engine_host.EngineHost, text: []const u8) !RpcOutcome {
    var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer p.deinit();
    return host.handle("ListModels", p.value);
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

test "rpc_models ListModels answers the mock harness's two rows" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    const out = try call(&host, "{\"harness\":\"mock\"}");
    defer testing.allocator.free(out.unary_json);
    try testing.expectEqualStrings(
        "[{\"id\":\"mock-1\",\"label\":\"Mock 1\",\"reasoningLevels\":[\"medium\"],\"options\":[]}," ++
            "{\"id\":\"mock-fable-5\",\"label\":\"Fable 5\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\"],\"options\":[]}]",
        out.unary_json,
    );
}

test "rpc_models ListModels refuses bad params like serde" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    try expectErr(try call(&host, "{}"), .bad, "missing field `harness`");
    try expectErr(try call(&host, "{\"harness\":\"nope\"}"), .bad, "unknown variant `nope`, expected one of `claude-code`, `codex`, `cursor`, `devin`, `grok`, `hermes`, `graff`, `pi`, `opencode`, `antigravity`, `exo`, `mock`");
    try expectErr(try call(&host, "{\"harness\":\"mock\",\"force\":\"yes\"}"), .bad, "invalid type: expected a boolean for `force`");
    try expectErr(try call(&host, "[]"), .bad, "invalid type: expected struct ListModelsParams");
}

test "rpc_models ListModels reports a missing CLI as Rust's discovery failure" {
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
    exes.system_prefix = base;
    defer exes.system_prefix = "";
    defer core.env_override = null;
    var host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
    defer host.deinit();
    host.io = io;
    try host.setDataDir(data);
    const out = try call(&host, "{\"harness\":\"codex\"}");
    switch (out) {
        .err => |e| {
            try testing.expect(e == .exec_error);
            try testing.expect(std.mem.startsWith(u8, e.exec_error, "model discovery missing_executable: harness binary not found"));
        },
        .unary_json => |b| {
            defer gpa.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}
