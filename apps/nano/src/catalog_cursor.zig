//! Cursor's live model catalog, ported from `crates/harness/src/cursor/{mod.rs,
//! catalog.rs}` (`CursorHarness::{model_context, model_catalog,
//! discover_models, resolve_shim, sdk_version}`, `map_model_items`,
//! `max_mode_default_ids`, `catalog::credential_context`) and the shim's
//! `models` mode (`shim.mjs`).
//!
//! Discovery runs Harness's Node shim over the pinned `@cursor/sdk` as
//! `node <shim> models` (or `$CURSOR_SDK_SHIM_EXECUTABLE models`): it prints
//! `{"ev":"models","items":[…]}` (`Cursor.models.list()`) or
//! `{"ev":"fatal","message"}` and exits. Items map to picker rows with one
//! option per SDK parameter, defaulting to the catalog's default variant.
//!
//! The catalog is cached under Cursor's own context hash: the SDK's
//! credentials (`~/.cursor/sdk/auth.json` contents plus whether its key has
//! expired, and every `CURSOR_*` variable), the shim binary (the override's
//! path and metadata, or the pin), and the SDK version.
//!
//! Std-only (plus `catalog_core.zig`, `agent_proc.zig`): `zig test
//! catalog_cursor.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const Sha256 = std.crypto.hash.sha2.Sha256;
const core = @import("catalog_core.zig");
const agent_proc = @import("agent_proc.zig");
const Failure = core.Failure;

/// Wire id (disk cache folder).
pub const id = "cursor";
/// `CURSOR_SDK_PIN`.
pub const sdk_pin = "@cursor/sdk@1.0.31";
pub const sdk_version = "1.0.31";
/// What `sdk_version()` reports while `CURSOR_SDK_SHIM_EXECUTABLE` is set.
pub const custom_sdk_version = "custom override (unverified)";
/// The shim, embedded (identical to `crates/harness/src/cursor/shim.mjs`).
pub const shim_source = @embedFile("cursor_shim.mjs");
const ok_marker = ".harness-install-ok";

pub const npm_hint = "npm (required to install the Cursor SDK " ++ sdk_pin ++ "; searched PATH, the login shell's PATH, and fnm/nvm/volta/pnpm/bun install dirs)";
pub const node_hint = "node (required to run the agent's npm-distributed ACP adapter; searched PATH, the login shell's PATH, and fnm/nvm/volta/pnpm/bun install dirs)";

/// `get_with`: the 20 s catalog bound.
pub var catalog_timeout_ms: u64 = 20_000;
/// `discover_models`' own 15 s bound ("cursor models probe timed out").
pub var probe_timeout_ms: u64 = 15_000;

/// Installs the pinned SDK when it is missing (`ensure_installed_shim`'s
/// npm path) and returns the shim's absolute path. The engine points this
/// at the turn adapter's installer so both share one install lock. Unset,
/// a missing install reports npm as missing when it is, and otherwise the
/// install as not run.
pub const InstallResult = union(enum) { ok: []u8, err: Failure };
pub const InstallShim = *const fn (gpa: Allocator, io: Io, env: *const Environ.Map, budget_ms: u64) anyerror!InstallResult;
pub var install_shim: ?InstallShim = null;

// ── the harness ────────────────────────────────────────────────────────────

const State = struct {
    cache: core.MemCache = .{},
    /// `max_mode_defaults` from the latest discovery (owned by `long_gpa`).
    max_mode_mutex: Io.Mutex = .init,
    max_mode: std.ArrayList([]u8) = .empty,
};

var state: State = .{};

const vtable: core.Harness.VTable = .{
    .modelContext = modelContextFn,
    .modelCatalog = modelCatalogFn,
    .fallbackModels = fallbackModelsFn,
};

/// Cursor's discovery surface (process-global state: its in-memory catalog).
pub fn harness() core.Harness {
    return .{ .id = id, .ptr = &state, .vtable = &vtable };
}

/// Forget the in-memory catalog and the Max Mode defaults.
pub fn resetForTests() void {
    if (state.cache.models) |m| core.long_gpa.free(m);
    state.cache = .{};
    freeMaxMode();
    state.max_mode = .empty;
}

fn freeMaxMode() void {
    for (state.max_mode.items) |s| core.long_gpa.free(s);
    state.max_mode.deinit(core.long_gpa);
}

/// Whether the latest discovery marked `model`'s default variant Max Mode
/// (`catalog_for_defaults` leaves such models' defaults unsent).
pub fn isMaxModeDefault(io: Io, model: []const u8) bool {
    state.max_mode_mutex.lockUncancelable(io);
    defer state.max_mode_mutex.unlock(io);
    for (state.max_mode.items) |s| if (std.mem.eql(u8, s, model)) return true;
    return false;
}

fn setMaxMode(io: Io, ids: []const []const u8) !void {
    var next: std.ArrayList([]u8) = .empty;
    errdefer {
        for (next.items) |s| core.long_gpa.free(s);
        next.deinit(core.long_gpa);
    }
    for (ids) |s| {
        const copy = try core.long_gpa.dupe(u8, s);
        next.append(core.long_gpa, copy) catch |e| {
            core.long_gpa.free(copy);
            return e;
        };
    }
    state.max_mode_mutex.lockUncancelable(io);
    defer state.max_mode_mutex.unlock(io);
    freeMaxMode();
    state.max_mode = next;
}

fn modelContextFn(_: *anyopaque, gpa: Allocator, io: Io) anyerror!core.ContextResult {
    return modelContext(gpa, io);
}

fn modelCatalogFn(_: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!core.Result {
    // `self.model_context()?` before the cache.
    var ctx = try modelContext(gpa, io);
    switch (ctx) {
        .ok => |*c| c.deinit(gpa),
        .err => |f| return .{ .err = f },
        .none => {},
    }
    var probe: Probe = .{ .gpa = gpa, .io = io };
    return state.cache.getWithTimeout(gpa, io, force, catalog_timeout_ms, &probe, &probe);
}

/// No `fallback_models` override: a cold failure is an error, never a
/// fabricated catalog.
fn fallbackModelsFn(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
    return gpa.dupe(u8, "[]");
}

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
            .none => return .{ .err = Failure.protocol("Cursor model context", .{}) },
        }
    }

    pub fn discover(_: *Probe, gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
        return discoverModels(gpa, io, budget_ms);
    }
};

// ── the context ────────────────────────────────────────────────────────────

/// `CursorHarness::sdk_version`.
pub fn sdkVersion(env: *const Environ.Map) []const u8 {
    return if (env.get("CURSOR_SDK_SHIM_EXECUTABLE") != null) custom_sdk_version else sdk_version;
}

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// `catalog::credential_context`: SHA-256 over the SDK's `auth.json` bytes
/// (empty when missing), whether its `apiKeyExpiresAtMs` has passed, and
/// the sorted `CURSOR_*` variables (`key \0 value \0`).
pub fn credentialContext(gpa: Allocator, io: Io, env: *const Environ.Map) ![32]u8 {
    const home = try core.homeOrCwd(gpa, io, env);
    defer gpa.free(home);
    const path = try std.fs.path.join(gpa, &.{ home, ".cursor/sdk/auth.json" });
    defer gpa.free(path);
    const bytes: []u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => try gpa.alloc(u8, 0),
        else => return e,
    };
    defer gpa.free(bytes);
    var expired = false;
    if (json.parseFromSlice(json.Value, gpa, bytes, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("apiKeyExpiresAtMs")) |at| {
            if (at == .integer and at.integer >= 0) expired = nowMs(io) >= at.integer;
        };
    } else |_| {}
    var h = Sha256.init(.{});
    h.update(bytes);
    h.update(&.{@intFromBool(expired)});
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = env.iterator();
    while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, "CURSOR_")) try keys.append(gpa, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (keys.items) |k| {
        h.update(k);
        h.update(&.{0});
        h.update(env.get(k).?);
        h.update(&.{0});
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// `model_context`: Cursor's own hash (credentials, shim binary, SDK
/// version, and the binary's mtime/size when it exists).
pub fn modelContext(gpa: Allocator, io: Io) !core.ContextResult {
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    const cred = credentialContext(gpa, io, &env) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .err = Failure.ioError(.other, @errorName(e)) },
    };
    const raw = env.get("CURSOR_SDK_SHIM_EXECUTABLE") orelse sdk_pin;
    const binary: []u8 = if (raw.len == 0) try gpa.dupe(u8, raw) else if (Io.Dir.cwd().realPathFileAlloc(io, raw, gpa)) |z| blk: {
        defer gpa.free(z);
        break :blk try gpa.dupe(u8, z);
    } else |_| try gpa.dupe(u8, raw);
    errdefer gpa.free(binary);
    const version = sdkVersion(&env);
    var h = Sha256.init(.{});
    h.update(&cred);
    h.update(binary);
    h.update(version);
    if (binary.len > 0) if (Io.Dir.cwd().statFile(io, binary, .{})) |st| {
        var mbuf: [128]u8 = undefined;
        h.update(core.modifiedDebug(&mbuf, st));
    } else |_| {};
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return .{ .ok = .{
        .hash = std.fmt.bytesToHex(digest, .lower),
        .binary_path = binary,
        .binary_version = try gpa.dupe(u8, version),
    } };
}

// ── locating the shim ──────────────────────────────────────────────────────

/// `adapters_root` (Unix): `$HARNESS_ADAPTERS_DIR`, `$HARNESS_DATA_DIR/adapters`,
/// else `~/.harness/adapters` (`~/.harnesser/adapters` when only that exists).
fn adaptersRoot(gpa: Allocator, io: Io, env: *const Environ.Map) !?[]u8 {
    if (env.get("HARNESS_ADAPTERS_DIR")) |d| if (d.len > 0) return try gpa.dupe(u8, d);
    if (env.get("HARNESS_DATA_DIR")) |d| if (d.len > 0) return try std.fs.path.join(gpa, &.{ d, "adapters" });
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    const primary = try std.fs.path.join(gpa, &.{ home, ".harness" });
    defer gpa.free(primary);
    const legacy = try std.fs.path.join(gpa, &.{ home, ".harnesser" });
    defer gpa.free(legacy);
    const base = if (dirExists(io, primary)) primary else if (dirExists(io, legacy)) legacy else primary;
    return try std.fs.path.join(gpa, &.{ base, "adapters" });
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

const shim_name_len = "harness-cursor-shim-".len + 64 + ".mjs".len;

/// `materialize_shim`'s name: `harness-cursor-shim-<sha256>.mjs`.
pub fn shimFileName() [shim_name_len]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(shim_source, &digest, .{});
    var out: [shim_name_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "harness-cursor-shim-{x}.mjs", .{digest}) catch unreachable;
    return out;
}

/// `materialize_shim`: publish the shim complete, content-addressed.
fn materializeShim(gpa: Allocator, io: Io, dir: []const u8) ![]u8 {
    const name = shimFileName();
    const path = try std.fs.path.join(gpa, &.{ dir, &name });
    errdefer gpa.free(path);
    if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, shim_source)) return path;
    } else |_| {}
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}/.shim-{x}", .{ dir, rnd });
    defer gpa.free(tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = shim_source });
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        const now = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return err;
        defer gpa.free(now);
        if (!std.mem.eql(u8, now, shim_source)) return err;
    };
    return path;
}

fn findTool(gpa: Allocator, io: Io, env: *const Environ.Map, name: []const u8) !?[]u8 {
    const login = if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(gpa, io, env, null);
    return agent_proc.findExecutable(gpa, io, .{ .name = name, .path_env = env.get("PATH"), .login_path = login, .home = env.get("HOME"), .fnm_dir = env.get("FNM_DIR") });
}

/// What to spawn: `exe [shim] models`.
const Launch = struct {
    exe: []u8,
    shim: ?[]u8 = null,

    fn deinit(self: Launch, gpa: Allocator) void {
        gpa.free(self.exe);
        if (self.shim) |s| gpa.free(s);
    }
};

const LaunchResult = union(enum) { ok: Launch, err: Failure };

/// `resolve_shim`: the override, or node running the shim inside the
/// managed SDK install (`installed_shim`, then `launch_for_entry`).
fn resolveShim(gpa: Allocator, io: Io, env: *const Environ.Map, budget_ms: u64) !LaunchResult {
    if (env.get("CURSOR_SDK_SHIM_EXECUTABLE")) |p| if (p.len > 0) return .{ .ok = .{ .exe = try gpa.dupe(u8, p) } };

    var shim: ?[]u8 = null;
    errdefer if (shim) |s| gpa.free(s);
    if (try adaptersRoot(gpa, io, env)) |root| {
        defer gpa.free(root);
        const dir = try std.fs.path.join(gpa, &.{ root, "cursor__sdk", sdk_version });
        defer gpa.free(dir);
        const marker = try std.fs.path.join(gpa, &.{ dir, ok_marker });
        defer gpa.free(marker);
        if (Io.Dir.cwd().access(io, marker, .{})) |_| {
            shim = materializeShim(gpa, io, dir) catch null;
        } else |_| {}
    }
    if (shim == null) {
        if (install_shim) |install| {
            switch (try install(gpa, io, env, budget_ms)) {
                .ok => |p| shim = p,
                .err => |f| return .{ .err = f },
            }
        } else {
            const npm = try findTool(gpa, io, env, "npm");
            if (npm) |n| gpa.free(n) else return .{ .err = Failure.notInstalled(npm_hint) };
            return .{ .err = Failure.other("adapter install failed: the Cursor SDK (" ++ sdk_pin ++ ") is not installed and this engine has no installer wired for model discovery") };
        }
    }

    // `launch_for_entry`: npm's sibling node, else node on the search paths.
    const npm = try findTool(gpa, io, env, "npm");
    defer if (npm) |n| gpa.free(n);
    var node: ?[]u8 = null;
    if (npm) |n| if (std.fs.path.dirname(n)) |d| {
        const sibling = try std.fs.path.join(gpa, &.{ d, "node" });
        if (Io.Dir.cwd().statFile(io, sibling, .{})) |st| {
            if (st.kind == .file) node = sibling else gpa.free(sibling);
        } else |_| gpa.free(sibling);
    };
    if (node == null) node = try findTool(gpa, io, env, "node");
    const exe = node orelse {
        gpa.free(shim.?);
        shim = null;
        return .{ .err = Failure.notInstalled(node_hint) };
    };
    return .{ .ok = .{ .exe = exe, .shim = shim } };
}

// ── discovery ──────────────────────────────────────────────────────────────

/// `apply_run_environment` + `compose_child_path`.
fn childEnv(gpa: Allocator, io: Io, env: *const Environ.Map, exe: []const u8) !Environ.Map {
    var out = try env.clone(gpa);
    errdefer out.deinit();
    _ = out.swapRemove("HARNESS_BUILD_WAIT_DIR");
    const login = if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(gpa, io, env, null);
    const path = try agent_proc.composeChildPath(gpa, exe, env.get("PATH"), login);
    defer gpa.free(path);
    try out.put("PATH", path);
    return out;
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// Rust's `ExitStatus` display on Unix.
fn exitStatus(buf: []u8, term: ?std.process.Child.Term) []const u8 {
    const t = term orelse return "unknown";
    return switch (t) {
        .exited => |code| std.fmt.bufPrint(buf, "exit status: {d}", .{code}) catch "unknown",
        .signal => |sig| blk: {
            const n: u32 = @intCast(@backingInt(sig));
            const name: []const u8 = switch (n) {
                1 => " (SIGHUP)",
                2 => " (SIGINT)",
                3 => " (SIGQUIT)",
                6 => " (SIGABRT)",
                9 => " (SIGKILL)",
                11 => " (SIGSEGV)",
                13 => " (SIGPIPE)",
                15 => " (SIGTERM)",
                else => "",
            };
            break :blk std.fmt.bufPrint(buf, "signal: {d}{s}", .{ n, name }) catch "unknown";
        },
        else => "unknown",
    };
}

fn field(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn evIs(v: json.Value, ev: []const u8) bool {
    const f = field(v, "ev") orelse return false;
    return f == .string and std.mem.eql(u8, f.string, ev);
}

/// `discover_models`: spawn the shim in models mode and map its catalog.
/// Bounded by `min(probe_timeout_ms, budget_ms)`.
pub fn discoverModels(gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    const launch = switch (try resolveShim(gpa, io, &env, budget_ms)) {
        .ok => |l| l,
        .err => |f| return .{ .err = f },
    };
    defer launch.deinit(gpa);
    var child_env = try childEnv(gpa, io, &env, launch.exe);
    defer child_env.deinit();
    var argv_buf: [3][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = launch.exe;
    argc += 1;
    if (launch.shim) |s| {
        argv_buf[argc] = s;
        argc += 1;
    }
    argv_buf[argc] = "models";
    argc += 1;
    const proc = agent_proc.AgentProc.spawn(gpa, io, argv_buf[0..argc], null, &child_env, .{ .stdin = false }) catch |e| {
        const what: []const u8 = switch (e) {
            error.NotInstalled, error.FileNotFound => "No such file or directory (os error 2)",
            else => @errorName(e),
        };
        return .{ .err = Failure.protocol("cursor models probe: {s}", .{what}) };
    };
    defer proc.destroy();
    const limit_ms = @min(probe_timeout_ms, budget_ms);
    const started = nowNs(io);
    proc.armDeadline(@intCast(@min(limit_ms, std.math.maxInt(u32))));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    while (proc.readLine() catch null) |line| try lines.append(a, try a.dupe(u8, line));
    const term = proc.wait();
    if (nowNs(io) - started >= @as(i96, limit_ms) * std.time.ns_per_ms) {
        return .{ .err = Failure.protocol("cursor models probe timed out", .{}) };
    }

    var frames: std.ArrayList(json.Value) = .empty;
    for (lines.items) |line| {
        const v = json.parseFromSliceLeaky(json.Value, a, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
        try frames.append(a, v);
    }
    for (frames.items) |v| if (evIs(v, "fatal")) {
        const m = field(v, "message");
        const text = if (m != null and m.? == .string) m.?.string else "Cursor model discovery failed";
        return .{ .err = Failure.protocol("{s}", .{text}) };
    };
    const ok = if (term) |t| t == .exited and t.exited == 0 else false;
    if (!ok) {
        var sbuf: [64]u8 = undefined;
        return .{ .err = Failure.protocol("cursor models probe exited with {s}", .{exitStatus(&sbuf, term)}) };
    }
    const items = for (frames.items) |v| {
        if (evIs(v, "models")) if (field(v, "items")) |items| break items;
    } else return .{ .err = Failure.protocol("cursor models probe returned no catalog", .{}) };
    try setMaxMode(io, try maxModeDefaultIds(a, items));
    return .{ .ok = try core.modelsJson(gpa, try mapModelItems(a, items)) };
}

/// The first variant marked default, if any.
fn defaultVariant(item: json.Value) ?json.Value {
    const variants = field(item, "variants") orelse return null;
    if (variants != .array) return null;
    for (variants.array.items) |v| {
        const d = field(v, "isDefault") orelse continue;
        if (d == .bool and d.bool) return v;
    }
    return null;
}

/// `max_mode_default_ids`: items whose default variant is Max Mode.
pub fn maxModeDefaultIds(a: Allocator, items: json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (items != .array) return out.items;
    for (items.array.items) |item| {
        const dv = defaultVariant(item) orelse continue;
        const mm = field(dv, "isMaxMode") orelse continue;
        if (!(mm == .bool and mm.bool)) continue;
        const iid = field(item, "id") orelse continue;
        if (iid == .string) try out.append(a, iid.string);
    }
    return out.items;
}

/// `str_of`: a non-empty string at `key`.
fn strOf(v: json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    if (f != .string or f.string.len == 0) return null;
    return f.string;
}

/// `map_model_items`: `Cursor.models.list()` items → picker rows. The bare
/// `default` alias is dropped (it twins the parameterized Auto entry).
pub fn mapModelItems(a: Allocator, items: json.Value) ![]core.Model {
    var out: std.ArrayList(core.Model) = .empty;
    if (items != .array) return out.items;
    for (items.array.items) |item| {
        const mid = strOf(item, "id") orelse continue;
        if (std.mem.eql(u8, mid, "default")) continue;
        const dv_params: []const json.Value = blk: {
            const dv = defaultVariant(item) orelse break :blk &.{};
            const params = field(dv, "params") orelse break :blk &.{};
            break :blk if (params == .array) params.array.items else &.{};
        };
        var options: std.ArrayList(core.ModelOption) = .empty;
        if (field(item, "parameters")) |params| if (params == .array) for (params.array.items) |p| {
            const pid = strOf(p, "id") orelse continue;
            var choices: std.ArrayList(core.Choice) = .empty;
            if (field(p, "values")) |values| if (values == .array) for (values.array.items) |c| {
                const cid = strOf(c, "value") orelse continue;
                try choices.append(a, .{ .id = cid, .label = strOf(c, "displayName") orelse cid });
            };
            if (choices.items.len == 0) continue;
            const default_choice = for (dv_params) |dp| {
                const did = field(dp, "id") orelse continue;
                if (did == .string and std.mem.eql(u8, did.string, pid)) break strOf(dp, "value") orelse choices.items[0].id;
            } else choices.items[0].id;
            try options.append(a, .{ .id = pid, .label = strOf(p, "displayName") orelse pid, .choices = choices.items, .default_choice = default_choice });
        };
        try out.append(a, .{
            .id = mid,
            .label = strOf(item, "displayName") orelse mid,
            .description = strOf(item, "description"),
            .options = options.items,
        });
    }
    return out.items;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A mock shim (and mock `node`): appends its argv to `args`, then plays
/// the scenario named in `mode`.
const mock_shim =
    \\#!/bin/sh
    \\d='@DIR@'
    \\printf '%s\n' "$*" >> "$d/args"
    \\read -r mode < "$d/mode"
    \\case "$mode" in
    \\  ok) printf '%s\n' 'loading @cursor/sdk'; /bin/cat "$d/catalog";;
    \\  fatal) printf '%s\n' '{"ev":"fatal","message":"cursor model discovery failed: unauthenticated: sign in to Cursor"}'; exit 1;;
    \\  exit) echo boom >&2; exit 3;;
    \\  nocatalog) printf '%s\n' '{"ev":"progress"}';;
    \\  malformed) printf '%s\n' '{"ev":"models","items":[';;
    \\  empty) printf '%s\n' '{"ev":"models","items":[]}';;
    \\  hang) exec /bin/sleep 30;;
    \\esac
    \\
;

const catalog_fixture =
    \\{"ev":"models","items":[
    \\ {"id":"default","displayName":"Auto"},
    \\ {"id":"auto-smart","displayName":"Auto","parameters":[{"id":"optimize_for","displayName":"Optimize for","values":[{"value":"speed","displayName":"Speed"},{"value":"balanced"}]}],"variants":[{"params":[{"id":"optimize_for","value":"balanced"}],"isDefault":true}]},
    \\ {"id":"gpt-next","displayName":"","description":"Frontier","parameters":[{"id":"thinking","values":[{"value":"low"},{"value":"high","displayName":"High"}]},{"id":"empty","values":[]},{"values":[{"value":"x"}]}],"variants":[{"params":[{"id":"thinking","value":"high"}],"isDefault":false},{"params":[{"id":"thinking","value":"low"}],"isDefault":true,"isMaxMode":true}]},
    \\ {"id":"plain","displayName":"Plain","variants":[{"isDefault":true}],"parameters":[{"id":"fast","values":[{"value":"off"},{"value":"on"}]}]},
    \\ {"displayName":"no id"}
    \\]}
;

const expected_rows =
    "[{\"id\":\"auto-smart\",\"label\":\"Auto\",\"reasoningLevels\":[],\"options\":[{\"id\":\"optimize_for\",\"label\":\"Optimize for\",\"choices\":[{\"id\":\"speed\",\"label\":\"Speed\"},{\"id\":\"balanced\",\"label\":\"balanced\"}],\"defaultChoice\":\"balanced\"}]}," ++
    "{\"id\":\"gpt-next\",\"label\":\"gpt-next\",\"description\":\"Frontier\",\"reasoningLevels\":[],\"options\":[{\"id\":\"thinking\",\"label\":\"thinking\",\"choices\":[{\"id\":\"low\",\"label\":\"low\"},{\"id\":\"high\",\"label\":\"High\"}],\"defaultChoice\":\"low\"}]}," ++
    "{\"id\":\"plain\",\"label\":\"Plain\",\"reasoningLevels\":[],\"options\":[{\"id\":\"fast\",\"label\":\"fast\",\"choices\":[{\"id\":\"off\",\"label\":\"off\"},{\"id\":\"on\",\"label\":\"on\"}],\"defaultChoice\":\"off\"}]}]";

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: Environ.Map,
    shim: []u8,

    /// `override`: point `CURSOR_SDK_SHIM_EXECUTABLE` at the mock.
    fn init(mode: []const u8, override: bool) !*Fixture {
        const gpa = testing.allocator;
        const io = testing.io;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.tmp = testing.tmpDir(.{});
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
        try f.tmp.dir.createDirPath(io, "home");
        try f.tmp.dir.createDirPath(io, "bin");
        const script = try std.mem.replaceOwned(u8, gpa, mock_shim, "@DIR@", f.root);
        defer gpa.free(script);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "shim", .data = script, .flags = .{ .permissions = .executable_file } });
        // The shim prints its catalog as one JSONL frame.
        const one_line = try std.mem.replaceOwned(u8, gpa, catalog_fixture, "\n", "");
        defer gpa.free(one_line);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "catalog", .data = one_line });
        f.shim = try std.fs.path.join(gpa, &.{ f.root, "shim" });
        f.env = Environ.Map.init(gpa);
        const home = try std.fs.path.join(gpa, &.{ f.root, "home" });
        defer gpa.free(home);
        const bin = try std.fs.path.join(gpa, &.{ f.root, "bin" });
        defer gpa.free(bin);
        try f.env.put("HOME", home);
        // Only the fixture's own bin: no real npm or node is ever found.
        try f.env.put("PATH", bin);
        try f.env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        if (override) try f.env.put("CURSOR_SDK_SHIM_EXECUTABLE", f.shim);
        try f.setMode(mode);
        core.env_override = &f.env;
        resetForTests();
        return f;
    }

    fn setMode(f: *Fixture, mode: []const u8) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "mode", .data = mode });
    }

    fn read(f: *Fixture, name: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
    }

    fn calls(f: *Fixture) !usize {
        const args = f.read("args") catch return 0;
        defer testing.allocator.free(args);
        return std.mem.count(u8, args, "\n");
    }

    fn deinit(f: *Fixture) void {
        const gpa = testing.allocator;
        resetForTests();
        core.env_override = null;
        f.env.deinit();
        gpa.free(f.shim);
        gpa.free(f.root);
        f.tmp.cleanup();
        gpa.destroy(f);
    }
};

fn expectRows(r: core.Result, want: []const u8, source: core.Source) !void {
    switch (r) {
        .ok => |c| {
            defer testing.allocator.free(c.models);
            try testing.expectEqualStrings(want, c.models);
            try testing.expectEqual(source, c.source);
        },
        .err => |f| {
            std.debug.print("unexpected failure: {s}\n", .{f.message()});
            return error.TestUnexpectedResult;
        },
    }
}

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

test "catalog_cursor maps the shim's catalog: options, catalog defaults, no default alias" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init("ok", true);
    defer f.deinit();
    try expectRows(try harness().modelCatalog(testing.allocator, testing.io, false), expected_rows, .live);
    const args = try f.read("args");
    defer testing.allocator.free(args);
    try testing.expectEqualStrings("models\n", args);
    try testing.expect(isMaxModeDefault(testing.io, "gpt-next"));
    try testing.expect(!isMaxModeDefault(testing.io, "auto-smart"));
    const fb = try harness().fallbackModels(testing.allocator);
    defer testing.allocator.free(fb);
    try testing.expectEqualStrings("[]", fb);
}

test "catalog_cursor fatal frames, failed exits and missing catalogs are protocol errors" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("fatal", true);
    defer f.deinit();
    var buf: [512]u8 = undefined;
    const fatal = try discoverModels(gpa, io, 20_000);
    try testing.expectEqualStrings("harness protocol error: cursor model discovery failed: unauthenticated: sign in to Cursor", fatal.err.display(&buf));
    try testing.expectEqual(core.Code.auth_required, fatal.err.code);
    try f.setMode("exit");
    const exited = try discoverModels(gpa, io, 20_000);
    try testing.expectEqualStrings("harness protocol error: cursor models probe exited with exit status: 3", exited.err.display(&buf));
    try f.setMode("nocatalog");
    const none = try discoverModels(gpa, io, 20_000);
    try testing.expectEqualStrings("harness protocol error: cursor models probe returned no catalog", none.err.display(&buf));
    try f.setMode("malformed");
    const bad = try discoverModels(gpa, io, 20_000);
    try testing.expectEqualStrings("harness protocol error: cursor models probe returned no catalog", bad.err.display(&buf));
    // An auth failure through the catalog is not retried.
    try f.setMode("fatal");
    const before = try f.calls();
    try expectFailure(try harness().modelCatalog(gpa, io, true), "model discovery auth_required: harness protocol error: cursor model discovery failed: unauthenticated: sign in to Cursor");
    try testing.expectEqual(before + 1, try f.calls());
}

test "catalog_cursor a missing shim binary reads as a missing executable" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init("ok", true);
    defer f.deinit();
    try f.env.put("CURSOR_SDK_SHIM_EXECUTABLE", "/nonexistent/harness-cursor-shim");
    const r = try discoverModels(testing.allocator, testing.io, 20_000);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: cursor models probe: No such file or directory (os error 2)", r.err.display(&buf));
    try testing.expectEqual(core.Code.missing_executable, r.err.code);
}

test "catalog_cursor a hung shim is bounded by the probe timeout" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init("hang", true);
    defer f.deinit();
    const saved = probe_timeout_ms;
    defer probe_timeout_ms = saved;
    probe_timeout_ms = 300;
    const started = nowNs(testing.io);
    const r = try discoverModels(testing.allocator, testing.io, 20_000);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: cursor models probe timed out", r.err.display(&buf));
    try testing.expectEqual(core.Code.timeout, r.err.code);
    try testing.expect(nowNs(testing.io) - started < 5 * std.time.ns_per_s);
}

test "catalog_cursor keeps the last good catalog through malformed, empty and failed refreshes" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("ok", true);
    defer f.deinit();
    try expectRows(try harness().modelCatalog(gpa, io, false), expected_rows, .live);
    for ([_][]const u8{ "malformed", "empty", "exit" }) |mode| {
        try f.setMode(mode);
        state.cache.expire(io);
        try expectRows(try harness().modelCatalog(gpa, io, false), expected_rows, .cache);
        try f.setMode("ok");
        state.cache.expire(io);
        try expectRows(try harness().modelCatalog(gpa, io, false), expected_rows, .live);
    }
    // 1 + 3 × (3 failed attempts + 1 recovery).
    try testing.expectEqual(@as(usize, 13), try f.calls());
}

test "catalog_cursor runs node on the managed install's content-addressed shim" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("ok", false);
    defer f.deinit();
    const adapters = try std.fs.path.join(gpa, &.{ f.root, "adapters" });
    defer gpa.free(adapters);
    try f.env.put("HARNESS_ADAPTERS_DIR", adapters);
    const dir = "adapters/cursor__sdk/" ++ sdk_version;
    try f.tmp.dir.createDirPath(io, dir);
    try f.tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/" ++ ok_marker, .data = sdk_version });
    const script = try f.read("shim");
    defer gpa.free(script);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "bin/node", .data = script, .flags = .{ .permissions = .executable_file } });
    try expectRows(try harness().modelCatalog(gpa, io, false), expected_rows, .live);
    const name = shimFileName();
    const shim_path = try std.fs.path.join(gpa, &.{ f.root, dir, &name });
    defer gpa.free(shim_path);
    const args = try f.read("args");
    defer gpa.free(args);
    const want = try std.fmt.allocPrint(gpa, "{s} models\n", .{shim_path});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, args);
    const written = try Io.Dir.cwd().readFileAlloc(io, shim_path, gpa, .limited(1 << 20));
    defer gpa.free(written);
    try testing.expectEqualStrings(shim_source, written);
}

test "catalog_cursor without npm or node the SDK is not installed, with Rust's text" {
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("ok", false);
    defer f.deinit();
    const adapters = try std.fs.path.join(gpa, &.{ f.root, "adapters" });
    defer gpa.free(adapters);
    try f.env.put("HARNESS_ADAPTERS_DIR", adapters);
    try expectFailure(try harness().modelCatalog(gpa, io, false), "model discovery missing_executable: harness binary not found: " ++ npm_hint);
    // Installed SDK, but no node anywhere.
    const dir = "adapters/cursor__sdk/" ++ sdk_version;
    try f.tmp.dir.createDirPath(io, dir);
    try f.tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/" ++ ok_marker, .data = sdk_version });
    const r = try discoverModels(gpa, io, 20_000);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("harness binary not found: " ++ node_hint, r.err.display(&buf));
}

test "catalog_cursor context hashes credentials, expiry, CURSOR_ variables and the shim binary" {
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("ok", false);
    defer f.deinit();
    var pinned = (try modelContext(gpa, io)).ok;
    defer pinned.deinit(gpa);
    try testing.expectEqualStrings(sdk_pin, pinned.binary_path);
    try testing.expectEqualStrings(sdk_version, pinned.binary_version.?);

    // Missing auth.json hashes as empty, not yet expired.
    var want = Sha256.init(.{});
    want.update(&.{0});
    var want_digest: [32]u8 = undefined;
    want.final(&want_digest);
    try testing.expectEqualSlices(u8, &want_digest, &(try credentialContext(gpa, io, &f.env)));

    try f.tmp.dir.createDirPath(io, "home/.cursor/sdk");
    const expired_auth = "{\"apiKey\":\"synthetic\",\"apiKeyExpiresAtMs\":1000}";
    try f.tmp.dir.writeFile(io, .{ .sub_path = "home/.cursor/sdk/auth.json", .data = expired_auth });
    var w2 = Sha256.init(.{});
    w2.update(expired_auth);
    w2.update(&.{1});
    w2.final(&want_digest);
    try testing.expectEqualSlices(u8, &want_digest, &(try credentialContext(gpa, io, &f.env)));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "home/.cursor/sdk/auth.json", .data = "{\"apiKey\":\"synthetic\",\"apiKeyExpiresAtMs\":99999999999999}" });
    var fresh = (try modelContext(gpa, io)).ok;
    defer fresh.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &pinned.hash, &fresh.hash));

    try f.env.put("CURSOR_API_KEY", "synthetic");
    var keyed = (try modelContext(gpa, io)).ok;
    defer keyed.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &fresh.hash, &keyed.hash));
    try testing.expect(std.mem.indexOf(u8, &keyed.hash, "synthetic") == null);

    try f.env.put("CURSOR_SDK_SHIM_EXECUTABLE", f.shim);
    var custom = (try modelContext(gpa, io)).ok;
    defer custom.deinit(gpa);
    try testing.expectEqualStrings(custom_sdk_version, custom.binary_version.?);
    try testing.expectEqualStrings(f.shim, custom.binary_path);
    // The shim's own bytes (via its mtime/size) are part of the identity.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "shim", .data = "#!/bin/sh\nexit 0\n# a different shim\n", .flags = .{ .permissions = .executable_file } });
    var changed = (try modelContext(gpa, io)).ok;
    defer changed.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &custom.hash, &changed.hash));
}

test "catalog_cursor mapping skips id-less items, empty parameters and reads Max Mode defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try json.parseFromSliceLeaky(json.Value, a, catalog_fixture, .{});
    const items = field(parsed, "items").?;
    const rows = try mapModelItems(a, items);
    const text = try core.modelsJson(a, rows);
    try testing.expectEqualStrings(expected_rows, text);
    const mm = try maxModeDefaultIds(a, items);
    try testing.expectEqual(@as(usize, 1), mm.len);
    try testing.expectEqualStrings("gpt-next", mm[0]);
    try testing.expectEqual(@as(usize, 0), (try mapModelItems(a, .null)).len);
}
