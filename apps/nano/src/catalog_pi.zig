//! Pi's live model catalog, ported from `crates/harness/src/pi/{mod.rs,
//! catalog.rs, rpc.rs}` (`PiHarness::{model_context, model_catalog,
//! fallback_models, probe, spawn}`, `catalog::{models, levels,
//! thinking_option}`, `Process::{next, query}`, `ui::Dialogs::request`).
//!
//! Discovery spawns `pi --mode rpc --no-themes --no-session` and speaks
//! Pi's JSONL RPC: `get_available_models`, then for each model `set_model`
//! and `get_available_thinking_levels`. Rows are `provider/id`, labelled by
//! the model's name, described by its provider, with the thinking levels Pi
//! reports and a `pi_thinking` option when Pi offers "off". Extension
//! dialogs raised during the probe are cancelled (nobody can answer them).
//!
//! Std-only (plus `catalog_core.zig`, `agent_proc.zig`,
//! `harness_version.zig`): `zig test catalog_pi.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const core = @import("catalog_core.zig");
const agent_proc = @import("agent_proc.zig");
const harness_version = @import("harness_version.zig");
const Failure = core.Failure;

/// Wire id (disk cache folder, `resolve_cli` id).
pub const id = "pi";
/// `HarnessError::NotInstalled` text when no Pi CLI resolves.
pub const install_hint = "Pi CLI: install Pi or set PI_EXECUTABLE (the pi-acp adapter is not used)";

/// `get_with_timeout(force, 65 s, …)`.
pub var catalog_timeout_ms: u64 = 65_000;
/// `probe`'s own 60 s bound ("Pi discovery timed out").
pub var probe_timeout_ms: u64 = 60_000;
/// `PiHarness::kill_grace`.
pub var kill_grace_ms: u32 = 3_000;
/// `rpc::MAX_FRAME`.
const max_frame = 32 * 1024 * 1024;
/// Pi below this lacks the RPC the probe speaks.
const min_version: harness_version.Version = .{ .major = 0, .minor = 85, .patch = 1 };

// ── the harness ────────────────────────────────────────────────────────────

const State = struct {
    cache: core.MemCache = .{},
};

var state: State = .{};

const vtable: core.Harness.VTable = .{
    .modelContext = modelContextFn,
    .modelCatalog = modelCatalogFn,
    .fallbackModels = fallbackModelsFn,
};

/// Pi's discovery surface (process-global state: its in-memory catalog).
pub fn harness() core.Harness {
    return .{ .id = id, .ptr = &state, .vtable = &vtable };
}

/// Forget the in-memory catalog.
pub fn resetForTests() void {
    if (state.cache.models) |m| core.long_gpa.free(m);
    state.cache = .{};
}

fn modelContextFn(_: *anyopaque, gpa: Allocator, io: Io) anyerror!core.ContextResult {
    return modelContext(gpa, io);
}

fn modelCatalogFn(_: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!core.Result {
    var probe: Probe = .{ .gpa = gpa, .io = io };
    return state.cache.getWithTimeout(gpa, io, force, catalog_timeout_ms, &probe, &probe);
}

fn fallbackModelsFn(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
    return core.modelsJson(gpa, &fallback_models);
}

/// `fallback_models`: the model configured in Pi.
pub const fallback_models = [_]core.Model{.{ .id = "default", .label = "Pi default", .description = "Model configured in Pi" }};

/// `model_context`: the CLI (resolved through `catalog_core.resolve_cli`),
/// Pi's `auth.json`, and `models.json`/`settings.json` under
/// `PI_CODING_AGENT_DIR` (default `~/.pi/agent`).
pub fn modelContext(gpa: Allocator, io: Io) !core.ContextResult {
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    const exe = (core.resolve_cli(gpa, io, id) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) }) orelse
        return .{ .err = Failure.notInstalled(install_hint) };
    defer gpa.free(exe);
    const home = try core.homeOrCwd(gpa, io, &env);
    defer gpa.free(home);
    const root = try core.envRoot(gpa, &env, "PI_CODING_AGENT_DIR", &.{ home, ".pi/agent" });
    defer gpa.free(root);
    const models_file = try std.fs.path.join(gpa, &.{ root, "models.json" });
    defer gpa.free(models_file);
    const settings_file = try std.fs.path.join(gpa, &.{ root, "settings.json" });
    defer gpa.free(settings_file);
    const ctx = core.computeContext(gpa, io, id, exe, &.{ models_file, settings_file }, &env) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .err = Failure.ioError(.other, @errorName(e)) },
    };
    return .{ .ok = ctx };
}

/// The keyer/discoverer `MemCache.getWithTimeout` drives.
const Probe = struct {
    gpa: Allocator,
    io: Io,

    pub fn key(self: *Probe) core.KeyResult {
        var res = modelContext(self.gpa, self.io) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
        switch (res) {
            .ok => |*c| {
                defer c.deinit(self.gpa);
                return .{ .ok = c.key() };
            },
            .err => |f| return .{ .err = f },
            .none => return .{ .err = Failure.protocol("Pi model context", .{}) },
        }
    }

    pub fn discover(_: *Probe, gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
        return probeModels(gpa, io, budget_ms);
    }
};

// ── the probe ──────────────────────────────────────────────────────────────

/// The child's environment: the engine's, without the variables a nested
/// agent must not inherit, and PATH composed as `compose_child_path` does.
fn childEnv(gpa: Allocator, io: Io, env: *const Environ.Map, exe: []const u8) !Environ.Map {
    var out = try env.clone(gpa);
    errdefer out.deinit();
    for (agent_proc.stripped_env) |k| _ = out.swapRemove(k);
    _ = out.swapRemove("HARNESS_BUILD_WAIT_DIR");
    const login = if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(gpa, io, env, null);
    const path = try agent_proc.composeChildPath(gpa, exe, env.get("PATH"), login);
    defer gpa.free(path);
    try out.put("PATH", path);
    return out;
}

/// `HarnessError::Io` for a failed spawn.
fn spawnFailure(e: anyerror) Failure {
    return switch (e) {
        error.NotInstalled, error.FileNotFound => Failure.ioError(.not_found, "No such file or directory (os error 2)"),
        else => Failure.ioError(.other, @errorName(e)),
    };
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// `probe(cwd, models: true)`: one short-lived `pi --mode rpc` answering the
/// catalog. Bounded by `min(probe_timeout_ms, budget_ms)`.
pub fn probeModels(gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    const exe = (core.resolve_cli(gpa, io, id) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) }) orelse
        return .{ .err = Failure.notInstalled(install_hint) };
    defer gpa.free(exe);

    var vbuf: [128]u8 = undefined;
    if (harness_version.binaryVersionString(io, exe, &vbuf)) |v| {
        if (harness_version.parseSemver(v)) |ver| if (ver.precedence(min_version) == .lt)
            return .{ .err = Failure.protocol("Pi {s} is unsupported; update Pi to 0.85.1 or newer", .{v}) };
    }

    var child_env = try childEnv(gpa, io, &env, exe);
    defer child_env.deinit();
    const proc = agent_proc.AgentProc.spawn(gpa, io, &.{ exe, "--mode", "rpc", "--no-themes", "--no-session" }, null, &child_env, .{}) catch |e|
        return .{ .err = spawnFailure(e) };
    defer proc.destroy();
    const limit_ms = @min(probe_timeout_ms, budget_ms);
    const started = nowNs(io);
    proc.armDeadline(@intCast(@min(limit_ms, std.math.maxInt(u32))));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rpc: Rpc = .{ .proc = proc, .a = arena_state.allocator() };
    const result = models(&rpc);
    const timed_out = nowNs(io) - started >= @as(i96, limit_ms) * std.time.ns_per_ms;

    // `Process::shutdown(kill_grace)`.
    proc.closeStdin();
    proc.escalate(0, kill_grace_ms);
    _ = proc.wait();

    const rows = result catch |e| switch (e) {
        error.Fail => return .{ .err = if (timed_out) Failure.protocol("Pi discovery timed out", .{}) else rpc.failure },
        error.OutOfMemory => return e,
    };
    return .{ .ok = try core.modelsJson(gpa, rows) };
}

const Error = error{ Fail, OutOfMemory };

/// Pi's JSONL RPC over the probe's stdio (`rpc::Transport`, `Process::query`).
const Rpc = struct {
    proc: *agent_proc.AgentProc,
    /// Frames are parsed into this arena.
    a: Allocator,
    next_id: u64 = 1,
    failure: Failure = undefined,

    fn fail(self: *Rpc, f: Failure) error{Fail} {
        self.failure = f;
        return error.Fail;
    }

    /// `Process::next`: the next non-blank frame.
    fn next(self: *Rpc) Error!json.Value {
        while (true) {
            const line = (self.proc.readLine() catch null) orelse return self.fail(Failure.protocol("Pi stdout closed", .{}));
            if (line.len > max_frame) return self.fail(Failure.protocol("Pi RPC frame exceeds 32 MiB", .{}));
            if (std.mem.trim(u8, line, " \t\r\n\x0c").len == 0) continue;
            return json.parseFromSliceLeaky(json.Value, self.a, line, .{ .allocate = .alloc_always }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(Failure.protocol("Invalid Pi RPC JSON: {s}", .{@errorName(e)})),
            };
        }
    }

    fn send(self: *Rpc, line: []const u8) Error!void {
        self.proc.writeLine(line) catch return self.fail(Failure.protocol("Pi stdin closed", .{}));
    }

    /// `Process::query`: send `{"id":"harness-N",<fields>}` and return the
    /// matching response's `data`. Extension dialogs are cancelled; other
    /// frames (lifecycle events) are dropped.
    fn query(self: *Rpc, comptime fields: []const u8, args: anytype) Error!json.Value {
        const rid = self.next_id;
        self.next_id += 1;
        var want_buf: [32]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "harness-{d}", .{rid}) catch unreachable;
        const line = try std.fmt.allocPrint(self.a, "{{\"id\":\"{s}\"," ++ fields ++ "}}", .{want} ++ args);
        try self.send(line);
        while (true) {
            const frame = try self.next();
            const ty = str(frame, "type");
            if (std.mem.eql(u8, ty, "response")) {
                if (field(frame, "id")) |fid| if (fid == .string and std.mem.eql(u8, fid.string, want)) return self.responseData(frame);
                continue;
            }
            if (std.mem.eql(u8, ty, "extension_ui_request")) try self.cancelDialog(frame);
        }
    }

    /// `response_data`.
    fn responseData(self: *Rpc, frame: json.Value) Error!json.Value {
        const ok = if (field(frame, "success")) |s| s == .bool and s.bool else false;
        if (ok) return field(frame, "data") orelse .null;
        const err_text = if (field(frame, "error")) |e| (if (e == .string) e.string else "command failed") else "command failed";
        return self.fail(Failure.protocol("Pi {s}: {s}", .{ str(frame, "command"), err_text }));
    }

    /// `Dialogs::request` with no input channel: answer "cancelled".
    fn cancelDialog(self: *Rpc, frame: json.Value) Error!void {
        const method = str(frame, "method");
        for ([_][]const u8{ "select", "confirm", "input", "editor" }) |m| {
            if (std.mem.eql(u8, method, m)) break;
        } else return;
        const rid: json.Value = field(frame, "id") orelse .null;
        const line = try std.fmt.allocPrint(self.a, "{{\"type\":\"extension_ui_response\",\"id\":{f},\"cancelled\":true}}", .{json.fmt(rid, .{})});
        // A closed stdin surfaces on the next query, as in Rust (send is best effort).
        self.proc.writeLine(line) catch {};
    }
};

fn field(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// `normalize::string`: the string at `key`, or "".
fn str(v: json.Value, key: []const u8) []const u8 {
    const f = field(v, key) orelse return "";
    return if (f == .string) f.string else "";
}

/// `catalog::models`.
fn models(rpc: *Rpc) Error![]core.Model {
    const a = rpc.a;
    const data = try rpc.query("\"type\":\"get_available_models\"", .{});
    var out: std.ArrayList(core.Model) = .empty;
    const list = field(data, "models") orelse return out.items;
    if (list != .array) return out.items;
    for (list.array.items) |m| {
        const provider = str(m, "provider");
        const mid = str(m, "id");
        _ = try rpc.query("\"type\":\"set_model\",\"provider\":{f},\"modelId\":{f}", .{ json.fmt(provider, .{}), json.fmt(mid, .{}) });
        const supported = try rpc.query("\"type\":\"get_available_thinking_levels\"", .{});
        const name = field(m, "name");
        try out.append(a, .{
            .id = try std.fmt.allocPrint(a, "{s}/{s}", .{ provider, mid }),
            .label = if (name != null and name.? == .string) name.?.string else mid,
            .description = provider,
            .reasoning_levels = try levels(a, supported),
            .options = thinkingOption(supported),
        });
    }
    return out.items;
}

/// `catalog::levels`: the reported levels that are Harness reasoning levels.
pub fn levels(a: Allocator, data: json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const list = field(data, "levels") orelse return out.items;
    if (list != .array) return out.items;
    for (list.array.items) |v| {
        if (v == .string and core.isReasoningLevel(v.string)) try out.append(a, v.string);
    }
    return out.items;
}

const pi_thinking = [_]core.ModelOption{.{
    .id = "pi_thinking",
    .label = "Thinking",
    .choices = &.{ .{ .id = "auto", .label = "Use reasoning level" }, .{ .id = "off", .label = "Off" } },
    .default_choice = "auto",
}};

/// `catalog::thinking_option`: offered when Pi can turn thinking off.
pub fn thinkingOption(data: json.Value) []const core.ModelOption {
    const list = field(data, "levels") orelse return &.{};
    if (list != .array) return &.{};
    for (list.array.items) |v| {
        if (v == .string and std.mem.eql(u8, v.string, "off")) return &pi_thinking;
    }
    return &.{};
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

var test_cli: ?[]const u8 = null;

fn testResolve(gpa: Allocator, _: Io, wire: []const u8) anyerror!?[]u8 {
    if (!std.mem.eql(u8, wire, id)) return null;
    const p = test_cli orelse return null;
    return try gpa.dupe(u8, p);
}

/// A mock `pi` replaying the RPC. `mode` (a file beside it) picks the
/// scenario; `version` is what `--version` prints. It appends each run's
/// argv to `args` and each stdin line to `in`.
const mock_pi =
    \\#!/bin/sh
    \\d='@DIR@'
    \\if [ "$1" = "--version" ]; then read -r v < "$d/version"; echo "pi $v"; exit 0; fi
    \\printf '%s\n' "$*" >> "$d/args"
    \\read -r mode < "$d/mode"
    \\case "$mode" in
    \\  exit) echo "pi: cannot start" >&2; exit 2;;
    \\  hang) exec /bin/sleep 30;;
    \\  malformed) echo 'not json'; exec /bin/sleep 30;;
    \\esac
    \\model=
    \\while IFS= read -r line; do
    \\  printf '%s\n' "$line" >> "$d/in"
    \\  id=${line#*\"id\":\"}; id=${id%%\"*}
    \\  case "$line" in
    \\    *extension_ui_response*) ;;
    \\    *get_available_models*)
    \\      if [ "$mode" = auth ]; then printf '{"type":"response","id":"%s","command":"get_available_models","success":false,"error":"Not authenticated: run /login"}\n' "$id"; continue; fi
    \\      if [ "$mode" = empty ]; then printf '{"type":"response","id":"%s","command":"get_available_models","success":true,"data":{"models":[]}}\n' "$id"; continue; fi
    \\      printf '%s\n' '{"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Trust this folder?"}'
    \\      printf '%s\n' '{"type":"extension_ui_request","id":"ui-2","method":"notify","message":"hello"}'
    \\      printf '\n'
    \\      printf '{"type":"response","id":"harness-999","success":true}\n'
    \\      printf '{"type":"response","id":"%s","command":"get_available_models","success":true,"data":{"models":[{"provider":"anthropic","id":"opus","name":"Opus"},{"provider":"local","id":"tiny"}]}}\n' "$id";;
    \\    *set_model*)
    \\      case "$line" in *opus*) model=opus;; *) model=tiny;; esac
    \\      printf '{"type":"agent_settled"}\n'
    \\      printf '{"type":"response","id":"%s","command":"set_model","success":true,"data":null}\n' "$id";;
    \\    *get_available_thinking_levels*)
    \\      if [ "$model" = opus ]; then lv='["off","low","high","turbo"]'; else lv='[]'; fi
    \\      printf '{"type":"response","id":"%s","command":"get_available_thinking_levels","success":true,"data":{"levels":%s}}\n' "$id" "$lv";;
    \\  esac
    \\done
    \\
;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: Environ.Map,
    cli: []u8,

    fn init(mode: []const u8) !*Fixture {
        const gpa = testing.allocator;
        const io = testing.io;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.tmp = testing.tmpDir(.{});
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
        try f.tmp.dir.createDirPath(io, "home");
        const script = try std.mem.replaceOwned(u8, gpa, mock_pi, "@DIR@", f.root);
        defer gpa.free(script);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "pi", .data = script, .flags = .{ .permissions = .executable_file } });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "version", .data = "0.86.0\n" });
        f.cli = try std.fs.path.join(gpa, &.{ f.root, "pi" });
        f.env = Environ.Map.init(gpa);
        const home = try std.fs.path.join(gpa, &.{ f.root, "home" });
        defer gpa.free(home);
        try f.env.put("HOME", home);
        try f.env.put("PATH", "/usr/bin:/bin");
        try f.env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        try f.setMode(mode);
        core.env_override = &f.env;
        core.resolve_cli = testResolve;
        test_cli = f.cli;
        resetForTests();
        return f;
    }

    fn setMode(f: *Fixture, mode: []const u8) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "mode", .data = mode });
    }

    fn read(f: *Fixture, name: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
    }

    fn deinit(f: *Fixture) void {
        const gpa = testing.allocator;
        resetForTests();
        core.env_override = null;
        test_cli = null;
        f.env.deinit();
        gpa.free(f.cli);
        gpa.free(f.root);
        f.tmp.cleanup();
        gpa.destroy(f);
    }
};

fn expectFailure(r: core.Result, want: []const u8) !void {
    switch (r) {
        .ok => |c| {
            defer testing.allocator.free(c.models);
            std.debug.print("unexpected catalog: {s}\n", .{c.models});
            return error.TestUnexpectedResult;
        },
        .err => |f| {
            var buf: [1024]u8 = undefined;
            try testing.expectEqualStrings(want, f.display(&buf));
        },
    }
}

const expected_rows =
    "[{\"id\":\"anthropic/opus\",\"label\":\"Opus\",\"description\":\"anthropic\",\"reasoningLevels\":[\"low\",\"high\"]," ++
    "\"options\":[{\"id\":\"pi_thinking\",\"label\":\"Thinking\",\"choices\":[{\"id\":\"auto\",\"label\":\"Use reasoning level\"},{\"id\":\"off\",\"label\":\"Off\"}],\"defaultChoice\":\"auto\"}]}," ++
    "{\"id\":\"local/tiny\",\"label\":\"tiny\",\"description\":\"local\",\"reasoningLevels\":[],\"options\":[]}]";

test "catalog_pi lists models with thinking levels and cancels dialogs raised mid-probe" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init("ok");
    defer f.deinit();
    const h = harness();
    const r = try h.modelCatalog(testing.allocator, testing.io, false);
    try testing.expect(r == .ok);
    defer testing.allocator.free(r.ok.models);
    try testing.expectEqualStrings(expected_rows, r.ok.models);
    try testing.expectEqual(core.Source.live, r.ok.source);
    const args = try f.read("args");
    defer testing.allocator.free(args);
    try testing.expectEqualStrings("--mode rpc --no-themes --no-session\n", args);
    const in = try f.read("in");
    defer testing.allocator.free(in);
    try testing.expect(std.mem.indexOf(u8, in, "{\"id\":\"harness-1\",\"type\":\"get_available_models\"}") != null);
    try testing.expect(std.mem.indexOf(u8, in, "{\"type\":\"extension_ui_response\",\"id\":\"ui-1\",\"cancelled\":true}") != null);
    // `notify` is not a dialog.
    try testing.expect(std.mem.indexOf(u8, in, "\"ui-2\"") == null);
    try testing.expect(std.mem.indexOf(u8, in, "\"type\":\"set_model\",\"provider\":\"anthropic\",\"modelId\":\"opus\"") != null);
    // Within the cooldown the cached catalog answers without a probe.
    const again = try h.modelCatalog(testing.allocator, testing.io, false);
    defer testing.allocator.free(again.ok.models);
    try testing.expectEqual(core.Source.cache, again.ok.source);
    const args2 = try f.read("args");
    defer testing.allocator.free(args2);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, args2, "\n"));
}

test "catalog_pi without a CLI is not installed, with Rust's text" {
    const f = try Fixture.init("ok");
    defer f.deinit();
    test_cli = null;
    const h = harness();
    try expectFailure(try h.modelCatalog(testing.allocator, testing.io, false), "harness binary not found: " ++ install_hint);
    const ctx = try h.modelContext(testing.allocator, testing.io);
    try testing.expect(ctx == .err and ctx.err.code == .missing_executable);
    const listed = try core.list(testing.allocator, testing.io, null, h, false);
    defer listed.deinit(testing.allocator);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("model discovery missing_executable: harness binary not found: " ++ install_hint, listed.err.display(&buf));
}

test "catalog_pi auth failures stop at one probe and are auth_required" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init("auth");
    defer f.deinit();
    const r = try harness().modelCatalog(testing.allocator, testing.io, true);
    try expectFailure(r, "model discovery auth_required: harness protocol error: Pi get_available_models: Not authenticated: run /login");
    const args = try f.read("args");
    defer testing.allocator.free(args);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, args, "\n"));
}

test "catalog_pi malformed frames, early exits and old CLIs fail the probe" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("malformed");
    defer f.deinit();
    var buf: [512]u8 = undefined;
    const bad = try probeModels(gpa, io, 20_000);
    try testing.expectEqualStrings("harness protocol error: Invalid Pi RPC JSON: SyntaxError", bad.err.display(&buf));
    try testing.expectEqual(core.Code.failed, bad.err.code);
    try f.setMode("exit");
    const gone = try probeModels(gpa, io, 20_000);
    try testing.expectEqualStrings("harness protocol error: Pi stdout closed", gone.err.display(&buf));
    try f.setMode("ok");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "version", .data = "0.80.3\n" });
    // A rewritten script is a new binary to the version cache.
    const script = try f.read("pi");
    defer gpa.free(script);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "pi2", .data = script, .flags = .{ .permissions = .executable_file } });
    const old = try std.fs.path.join(gpa, &.{ f.root, "pi2" });
    defer gpa.free(old);
    test_cli = old;
    const stale = try probeModels(gpa, io, 20_000);
    try testing.expectEqualStrings("harness protocol error: Pi 0.80.3 is unsupported; update Pi to 0.85.1 or newer", stale.err.display(&buf));
}

test "catalog_pi an empty catalog is a failure and the fallback is Pi's default row" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init("empty");
    defer f.deinit();
    try expectFailure(try harness().modelCatalog(testing.allocator, testing.io, true), "model discovery failed: Harness returned an empty model catalog");
    const fb = try harness().fallbackModels(testing.allocator);
    defer testing.allocator.free(fb);
    try testing.expectEqualStrings("[{\"id\":\"default\",\"label\":\"Pi default\",\"description\":\"Model configured in Pi\",\"reasoningLevels\":[],\"options\":[]}]", fb);
    // `list` serves the fallback when nothing live or on disk exists.
    const listed = try core.list(testing.allocator, testing.io, null, harness(), false);
    defer listed.deinit(testing.allocator);
    try testing.expectEqualStrings(fb, listed.ok);
}

test "catalog_pi a hung Pi is bounded by the probe timeout and the catalog timeout" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("hang");
    defer f.deinit();
    const saved_probe = probe_timeout_ms;
    const saved_catalog = catalog_timeout_ms;
    defer {
        probe_timeout_ms = saved_probe;
        catalog_timeout_ms = saved_catalog;
    }
    probe_timeout_ms = 300;
    const started = nowNs(io);
    const r = try probeModels(gpa, io, 20_000);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: Pi discovery timed out", r.err.display(&buf));
    try testing.expectEqual(core.Code.timeout, r.err.code);
    probe_timeout_ms = 60_000;
    catalog_timeout_ms = 400;
    try expectFailure(try harness().modelCatalog(gpa, io, true), "model discovery timeout: Harness model discovery timed out");
    try testing.expect(nowNs(io) - started < 10 * std.time.ns_per_s);
}

test "catalog_pi context follows Pi's agent dir files and its environment" {
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("ok");
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "agent");
    const agent = try std.fs.path.join(gpa, &.{ f.root, "agent" });
    defer gpa.free(agent);
    try f.env.put("PI_CODING_AGENT_DIR", agent);
    var c1 = (try modelContext(gpa, io)).ok;
    defer c1.deinit(gpa);
    try testing.expectEqualStrings("0.86.0", c1.binary_version.?);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "agent/models.json", .data = "{\"providers\":{}}" });
    var c2 = (try modelContext(gpa, io)).ok;
    defer c2.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c1.hash, &c2.hash));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "agent/auth.json", .data = "{\"synthetic\":1}" });
    var c3 = (try modelContext(gpa, io)).ok;
    defer c3.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c2.hash, &c3.hash));
    try f.env.put("ANTHROPIC_API_KEY", "synthetic");
    var c4 = (try modelContext(gpa, io)).ok;
    defer c4.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c3.hash, &c4.hash));
}

test "catalog_pi levels keep only Harness levels and thinking needs off" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a, "{\"levels\":[\"off\",\"minimal\",\"xhigh\",\"turbo\",3]}", .{});
    const l = try levels(a, v);
    try testing.expectEqual(@as(usize, 2), l.len);
    try testing.expectEqualStrings("minimal", l[0]);
    try testing.expectEqualStrings("xhigh", l[1]);
    try testing.expectEqual(@as(usize, 1), thinkingOption(v).len);
    const none = try json.parseFromSliceLeaky(json.Value, a, "{\"levels\":[\"low\"]}", .{});
    try testing.expectEqual(@as(usize, 0), thinkingOption(none).len);
    try testing.expectEqual(@as(usize, 0), thinkingOption(.null).len);
}
