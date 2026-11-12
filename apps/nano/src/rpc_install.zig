//! `InstallHarness { harness, beta? }` and `CancelInstall { harness }`,
//! ported from `crates/engine/src/rpc.rs` (`INSTALL_HARNESS`,
//! `Installations`, `install_harness_with`, `run_requested_install`,
//! `CANCEL_INSTALL`) onto `harness_install.zig`.
//!
//! An install runs for up to 15 minutes; it touches no engine state while it
//! runs (only the data dir's prefs file afterwards), so it can run outside
//! the host lock. `CancelInstall` stops it from any connection.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const exes = @import("rpcw_executables.zig");
const harnesses = @import("rpcw_harnesses.zig");
const engine_host = @import("engine_host.zig");
const core = @import("catalog_core.zig");
const install = @import("harness_install.zig");

const HarnessId = exes.HarnessId;
const RpcOutcome = common.RpcOutcome;

/// The device's in-flight installs (`HarnessRegistry::installs`).
pub var registry: install.Registry = .{};

/// A test seam: `run_requested_install`'s `HARNESS_INSTALLER_COMMAND_*`
/// (`install_with_command`) — run this script instead of the installer.
pub var test_script: ?[]const u8 = null;

fn toInstallId(id: HarnessId) install.Id {
    return install.Id.parse(id.wire()).?;
}

/// Each harness's `installed()` probe, for `post_install`.
fn installedProbe(gpa: Allocator, io: std.Io, id: install.Id) bool {
    const h = HarnessId.parse(id.wire()) orelse return false;
    return exes.installed(gpa, io, h) catch false;
}

const Parsed = union(enum) { ok: struct { id: HarnessId, flag: bool }, err: RpcOutcome };

/// `{ harness: HarnessId, #[serde(default)] <flag>: bool }`.
fn parse(params: json.Value, struct_name: []const u8, flag: []const u8) Parsed {
    const o = common.obj(params) orelse return .{ .err = common.badParams("invalid type: expected struct {s}", .{struct_name}) };
    const v = o.get("harness") orelse return .{ .err = common.badParams("missing field `harness`", .{}) };
    if (v != .string) return .{ .err = common.badParams("invalid type: expected a harness id for `harness`", .{}) };
    const id = HarnessId.parse(v.string) orelse return .{ .err = .{ .err = .{ .bad_params = exes.unknownVariantText(v.string) } } };
    var on = false;
    if (o.get(flag)) |f| switch (f) {
        .bool => |b| on = b,
        .null => {},
        else => return .{ .err = common.badParams("invalid type: expected a boolean for `{s}`", .{flag}) },
    };
    return .{ .ok = .{ .id = id, .flag = on } };
}

pub fn installHarness(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const p = switch (parse(params, "InstallHarnessParams", "beta")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const gpa = host.gpa;
    const io = host.io orelse return common.failed("installers need I/O", .{});
    core.env_override = common.env_override;
    const id = toInstallId(p.id);
    var installing = registry.begin(gpa, io, id) catch |e| switch (e) {
        error.AlreadyInstalling => return common.failed("{s}", .{install.already_installing}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer installing.end();
    // Up to 15 minutes: not under the engine lock, so other requests (and
    // CancelInstall) are served meanwhile.
    const failure = blk: {
        const released = host.releaseForLongCall();
        defer host.retakeAfterLongCall(released);
        break :blk install.requestInstall(gpa, io, id, .{
            .beta = p.flag,
            .cancel = installing.token,
            .installed = installedProbe,
            .script = test_script,
        }) catch |e| return common.failed("installation failed: {s}", .{@errorName(e)});
    };
    if (failure) |msg| {
        defer gpa.free(msg);
        return common.failed("{s}", .{msg});
    }
    // Choosing Install is an opt-in: an off-by-default agent turns on.
    if (!harnesses.defaultOn(p.id)) {
        var prefs = try harnesses.loadPrefs(gpa, io, host.data_dir);
        defer prefs.deinit(gpa);
        const probed = try harnesses.probeAll(gpa, io);
        _ = harnesses.setEnabled(gpa, io, host.data_dir, &prefs, probed, p.id, true) catch null;
    }
    return .{ .unary_json = try harnesses.descriptorsJson(gpa, io, host.data_dir) };
}

/// `CancelInstall` (params are `ListModelsParams`): `{}`.
pub fn cancelInstall(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const p = switch (parse(params, "ListModelsParams", "force")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    if (host.io) |io| registry.cancel(io, toInstallId(p.id));
    return .{ .unary_json = try host.gpa.dupe(u8, "{}") };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn call(host: *engine_host.EngineHost, method: []const u8, text: []const u8) !RpcOutcome {
    var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer p.deinit();
    return host.handle(method, p.value);
}

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    env: common.TestEnv,
    host: engine_host.EngineHost,

    fn init(f: *Fx) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, io, &f.tmp);
        try f.tmp.dir.createDirPath(io, "home");
        try f.tmp.dir.createDirPath(io, "bin");
        try f.tmp.dir.createDirPath(io, "data");
        const home = try std.fs.path.join(gpa, &.{ f.base, "home" });
        defer gpa.free(home);
        const bin = try std.fs.path.join(gpa, &.{ f.base, "bin" });
        defer gpa.free(bin);
        const data = try std.fs.path.join(gpa, &.{ f.base, "data" });
        defer gpa.free(data);
        f.env = try common.TestEnv.init(gpa, home);
        try f.env.map.put("PATH", bin);
        try f.env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
        try f.env.map.put("HARNESS_DISABLE_SHELL_ENV", "1");
        f.env.install();
        exes.system_prefix = f.base;
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = io;
        try f.host.setDataDir(data);
    }

    fn deinit(f: *Fx) void {
        f.host.deinit();
        f.env.deinit();
        core.env_override = null;
        exes.system_prefix = "";
        test_script = null;
        testing.allocator.free(f.base);
        f.tmp.cleanup();
    }

    /// A stand-in tool on the synthetic PATH (never the machine's).
    fn tool(f: *Fx, name: []const u8, body: []const u8) !void {
        const sub = try std.fmt.allocPrint(testing.allocator, "bin/{s}", .{name});
        defer testing.allocator.free(sub);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = body, .flags = .{ .permissions = .executable_file } });
    }
};

fn expectFailed(outcome: RpcOutcome, expected: []const u8) !void {
    switch (outcome) {
        .err => |e| {
            try testing.expect(e == .exec_error);
            try testing.expectEqualStrings(expected, e.exec_error);
        },
        .unary_json => |b| {
            std.debug.print("unexpected success: {s}\n", .{b});
            testing.allocator.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

test "rpc_install refuses bad params and a device without installer tools" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const missing = try call(&f.host, "InstallHarness", "{}");
    try testing.expect(missing == .err and missing.err == .bad_params);
    // No sh/curl/npm on the synthetic PATH: no installer is available.
    try expectFailed(try call(&f.host, "InstallHarness", "{\"harness\":\"codex\"}"), install.no_installer);
    try expectFailed(try call(&f.host, "InstallHarness", "{\"harness\":\"mock\"}"), install.no_installer);
    const cancelled = try call(&f.host, "CancelInstall", "{\"harness\":\"codex\"}");
    defer testing.allocator.free(cancelled.unary_json);
    try testing.expectEqualStrings("{}", cancelled.unary_json);
}

test "rpc_install runs the installer, probes the CLI, enables it and replies with descriptors" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    // The prerequisites `available` checks for a shell installer.
    try f.tool("sh", "#!/bin/sh\nexec /bin/sh \"$@\"\n");
    try f.tool("bash", "#!/bin/sh\nexec /bin/sh \"$@\"\n");
    try f.tool("curl", "#!/bin/sh\nexit 1\n");
    // The installer script drops a fake `grok` on the synthetic PATH.
    const script = try std.fmt.allocPrint(testing.allocator, "printf '#!/bin/sh\\nexit 0\\n' > '{s}/bin/grok' && /bin/chmod +x '{s}/bin/grok'", .{ f.base, f.base });
    defer testing.allocator.free(script);
    test_script = script;
    const out = try call(&f.host, "InstallHarness", "{\"harness\":\"grok\"}");
    if (out == .err) {
        std.debug.print("install failed: {s}\n", .{out.err.exec_error});
        return error.InstallFailed;
    }
    defer testing.allocator.free(out.unary_json);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, out.unary_json, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |row| {
        if (!std.mem.eql(u8, row.object.get("id").?.string, "grok")) continue;
        try testing.expect(row.object.get("installed").?.bool);
        // Grok is off by default; Install opted it in.
        try testing.expect(row.object.get("enabled").?.bool);
    }
    // An installer that leaves no CLI fails the post-install probe.
    test_script = "true";
    const again = try call(&f.host, "InstallHarness", "{\"harness\":\"hermes\"}");
    switch (again) {
        .err => |e| try testing.expect(std.mem.indexOf(u8, e.exec_error, "was not found on PATH") != null),
        .unary_json => |b| {
            testing.allocator.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

test "rpc_install beta is only for graff and a second install of one harness is refused" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.tool("sh", "#!/bin/sh\nexec /bin/sh \"$@\"\n");
    try f.tool("bash", "#!/bin/sh\nexec /bin/sh \"$@\"\n");
    try f.tool("curl", "#!/bin/sh\nexit 1\n");
    var held = try registry.begin(testing.allocator, testing.io, .grok);
    try expectFailed(try call(&f.host, "InstallHarness", "{\"harness\":\"grok\"}"), install.already_installing);
    held.end();
    const beta = try call(&f.host, "InstallHarness", "{\"harness\":\"hermes\",\"beta\":true}");
    switch (beta) {
        .err => |e| try testing.expect(std.mem.indexOf(u8, e.exec_error, "beta updates are only available for Graff") != null),
        .unary_json => |b| {
            testing.allocator.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

const Dispatch = struct {
    host: *engine_host.EngineHost,
    line: []const u8,
    out: std.Io.Writer.Allocating,
    done: std.Io.Event = .unset,

    fn run(d: *Dispatch) void {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        @import("engine_main.zig").dispatchClientLineWithArena(testing.allocator, arena.allocator(), d.host, &d.out.writer, d.line) catch {};
        d.done.set(testing.io);
    }

    fn waitMs(d: *Dispatch, ms: i64) bool {
        d.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch return false;
        return true;
    }
};

test "rpc_install a running install holds no engine lock: other calls are answered and CancelInstall stops it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.tool("sh", "#!/bin/sh\nexec /bin/sh \"$@\"\n");
    try f.tool("bash", "#!/bin/sh\nexec /bin/sh \"$@\"\n");
    try f.tool("curl", "#!/bin/sh\nexit 1\n");
    test_script = "/bin/sleep 30";

    var install_call: Dispatch = .{ .host = &f.host, .line = "{\"id\":1,\"method\":\"InstallHarness\",\"params\":{\"harness\":\"grok\"}}", .out = .init(testing.allocator) };
    defer install_call.out.deinit();
    const th = try std.Thread.spawn(.{}, Dispatch.run, .{&install_call});
    // Wait until the install is registered (it runs its script after that).
    var waited: u32 = 0;
    while (!registry.running(testing.io, .grok)) : (waited += 10) {
        if (waited >= 5_000) return error.InstallNeverStarted;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }

    var quick: Dispatch = .{ .host = &f.host, .line = "{\"id\":2,\"method\":\"GetAutonomy\",\"params\":{}}", .out = .init(testing.allocator) };
    defer quick.out.deinit();
    const qt = try std.Thread.spawn(.{}, Dispatch.run, .{&quick});
    const quick_ok = quick.waitMs(2_000);
    var cancel: Dispatch = .{ .host = &f.host, .line = "{\"id\":3,\"method\":\"CancelInstall\",\"params\":{\"harness\":\"grok\"}}", .out = .init(testing.allocator) };
    defer cancel.out.deinit();
    const ct = try std.Thread.spawn(.{}, Dispatch.run, .{&cancel});
    const cancel_ok = cancel.waitMs(2_000);
    // The cancelled install ends long before its 30 s script would.
    const install_ended = install_call.waitMs(10_000);
    if (!install_ended) registry.cancel(testing.io, toInstallId(.grok));
    qt.join();
    ct.join();
    th.join();
    try testing.expect(quick_ok);
    try testing.expect(cancel_ok);
    try testing.expect(install_ended);
    try testing.expect(std.mem.indexOf(u8, install_call.out.written(), "\"id\":1,\"err\"") != null);
}
