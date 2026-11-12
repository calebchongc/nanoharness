//! Claude Code's live model catalog, ported from
//! `crates/harness/src/claude/{mod.rs, catalog.rs, discovery.rs}`:
//!
//! - `modelContext`: `ClaudeHarness::model_context` (the CLI resolved through
//!   `catalog_core.resolve_cli`, then `model_context::context`).
//! - `modelCatalog`: `ClaudeHarness::model_catalog`: the per-context memory
//!   cache (35 s budget) over `initialize()`, the shared, two-minute
//!   `InitializeCache` of the CLI's `initialize` control-request handshake
//!   (`probe_initialize`, 10 s), and `with_discovered_models`, which overlays
//!   the CLI's concrete model ids on the curated rows.
//! - `fallbackModels`: `configured_models()`: the curated rows plus the
//!   models named in Claude's `settings.json`.
//!
//! Std-only (plus `catalog_core.zig`, `agent_proc.zig`, `harness_version.zig`),
//! so it tests standalone with `zig test catalog_claude.zig`.
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
const Model = core.Model;
const ModelOption = core.ModelOption;

/// The wire id (`HarnessId::ClaudeCode`).
pub const id = "claude-code";

/// `resolve_executable`'s `NotInstalled` text.
pub const install_hint = "claude (searched PATH, the login shell's PATH, ~/.claude/local, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CLAUDE_CODE_EXECUTABLE to override)";

/// `model_catalog`'s `get_with_timeout` budget.
pub const catalog_timeout_ms: u64 = 35_000;
/// `probe_initialize`'s own timeout.
pub const initialize_timeout_ms: u64 = 10_000;
/// `ClaudeHarness::kill_grace`: SIGTERM → SIGKILL in `shutdown_child`.
pub const kill_grace_ms: u64 = 3_000;
/// `InitializeCache`: a successful response is reused for two minutes.
pub const initialize_ttl_ms: u64 = 120_000;

/// `probe_initialize`'s argv after the executable.
pub const probe_args = [_][]const u8{ "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose" };
pub const probe_id = "harness-command-probe";
/// The control request, as serde_json writes it (keys sorted).
pub const initialize_request = "{\"request\":{\"subtype\":\"initialize\"},\"request_id\":\"" ++ probe_id ++ "\",\"type\":\"control_request\"}";

const parse_opts: json.ParseOptions = .{ .duplicate_field_behavior = .use_last, .allocate = .alloc_always };

// ── the curated catalog (`catalog.rs`) ─────────────────────────────────────

const off_on = [_]core.Choice{ .{ .id = "off", .label = "Off" }, .{ .id = "on", .label = "On" } };

fn toggle(comptime oid: []const u8, comptime label: []const u8) ModelOption {
    return .{ .id = oid, .label = label, .choices = &off_on, .default_choice = "off" };
}

/// `chrome()`: every model carries it.
pub const chrome = toggle("chrome", "Chrome");

/// `context_window()`: the 200K/1M select.
pub const context_window: ModelOption = .{
    .id = "contextWindow",
    .label = "Context Window",
    .choices = &.{ .{ .id = "200k", .label = "200K" }, .{ .id = "1m", .label = "1M" } },
    .default_choice = "200k",
};

const fast_mode = toggle("fastMode", "Fast Mode");
const thinking = toggle("thinking", "Thinking");

pub const full_ladder = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "ultracode", "ultrathink" };
pub const xhigh_ladder = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "ultrathink" };

const chrome_only = [_]ModelOption{chrome};

/// `static_models()`.
pub const static_models = [_]Model{
    .{ .id = "claude-fable-5-1", .label = "Fable 5.1", .description = "Most intelligent model for building agents", .reasoning_levels = &full_ladder, .options = &.{ context_window, chrome } },
    .{ .id = "claude-fable-5", .label = "Fable 5", .description = "Previous generation Fable", .reasoning_levels = &full_ladder, .options = &.{ context_window, chrome } },
    .{ .id = "claude-opus-5-5", .label = "Opus 5.5", .description = "Best for everyday, complex tasks", .reasoning_levels = &full_ladder, .options = &.{ context_window, fast_mode, chrome } },
    .{ .id = "claude-opus-4-8", .label = "Opus 4.8", .description = "Previous generation Opus", .reasoning_levels = &full_ladder, .options = &.{ fast_mode, chrome } },
    .{ .id = "claude-opus-4-7", .label = "Opus 4.7", .description = "Older generation Opus", .reasoning_levels = &xhigh_ladder, .options = &.{ fast_mode, chrome } },
    .{ .id = "claude-sonnet-5", .label = "Sonnet 5", .description = "Balanced speed and intelligence", .reasoning_levels = &xhigh_ladder, .options = &.{ context_window, chrome } },
    .{ .id = "claude-haiku-4-5", .label = "Haiku 4.5", .description = "Fastest model for everyday tasks", .reasoning_levels = &.{}, .options = &.{ thinking, chrome } },
};

fn indexOfModel(models: []const Model, model_id: []const u8) ?usize {
    for (models, 0..) |m, i| if (std.mem.eql(u8, m.id, model_id)) return i;
    return null;
}

fn objGet(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strGet(v: json.Value, key: []const u8) ?[]const u8 {
    const x = objGet(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

/// `get(key).and_then(as_str).map(str::trim).filter(non-empty)`.
fn text(v: json.Value, key: []const u8) ?[]const u8 {
    const s = rustTrim(strGet(v, key) orelse return null);
    return if (s.len == 0) null else s;
}

/// `models_with_settings(path)`: the curated rows, then each model the
/// settings name (`model`, then the `env` overrides) that isn't listed yet,
/// on the full ladder with only the Chrome option. Strings live in `arena`.
pub fn modelsWithSettings(arena: Allocator, io: Io, path: []const u8) ![]Model {
    var models: std.ArrayList(Model) = .empty;
    try models.appendSlice(arena, &static_models);
    const settings: json.Value = blk: {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => break :blk .null,
        };
        break :blk json.parseFromSliceLeaky(json.Value, arena, bytes, parse_opts) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => .null,
        };
    };
    const env_v: json.Value = objGet(settings, "env") orelse .null;
    const keys = [_][]const u8{ "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL" };
    var candidates: [1 + keys.len]?[]const u8 = undefined;
    candidates[0] = strGet(settings, "model");
    for (keys, 1..) |k, i| candidates[i] = strGet(env_v, k);
    for (candidates) |maybe| {
        const model_id = rustTrim(maybe orelse continue);
        if (model_id.len == 0 or indexOfModel(models.items, model_id) != null) continue;
        try models.append(arena, .{ .id = model_id, .label = model_id, .reasoning_levels = &full_ladder, .options = &chrome_only });
    }
    return models.items;
}

/// `configured_models()`: `models_with_settings` on
/// `$CLAUDE_CONFIG_DIR/settings.json` (or `~/.claude/settings.json`).
pub fn configuredModels(arena: Allocator, io: Io, env: *const Environ.Map) ![]Model {
    const home = try core.homeOrCwd(arena, io, env);
    const root = try core.envRoot(arena, env, "CLAUDE_CONFIG_DIR", &.{ home, ".claude" });
    const path = try std.fs.path.join(arena, &.{ root, "settings.json" });
    return modelsWithSettings(arena, io, path);
}

/// `snapshot_base`: `claude-haiku-4-5-20251001` → `claude-haiku-4-5`.
pub fn snapshotBase(model_id: []const u8) ?[]const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, model_id, '-') orelse return null;
    const date = model_id[dash + 1 ..];
    if (date.len != 8) return null;
    for (date) |b| if (!std.ascii.isDigit(b)) return null;
    return model_id[0..dash];
}

fn moveToFront(models: []Model, index: usize) void {
    const m = models[index];
    var i = index;
    while (i > 0) : (i -= 1) models[i] = models[i - 1];
    models[0] = m;
}

pub const Overlay = union(enum) { ok: []Model, err: Failure };

/// `with_discovered_models(models, response)`: overlay the CLI's new
/// concrete model ids (`response.response.models`) on `base`; curated rows
/// keep their metadata. Bare aliases are skipped, dated snapshots fold into
/// their curated row, and the CLI's default (and its long-context base)
/// moves to the front. Strings borrow `response`; slices live in `arena`.
pub fn withDiscoveredModels(arena: Allocator, base: []const Model, response: json.Value) !Overlay {
    const empty: Overlay = .{ .err = Failure.protocol("Claude returned an empty model catalog", .{}) };
    const inner = objGet(response, "response") orelse return empty;
    const entries_v = objGet(inner, "models") orelse return empty;
    if (entries_v != .array or entries_v.array.items.len == 0) return empty;
    var models: std.ArrayList(Model) = .empty;
    try models.appendSlice(arena, base);
    var default: ?[]const u8 = null;
    var valid = false;
    for (entries_v.array.items) |entry| {
        const raw_id = text(entry, "resolvedModel") orelse text(entry, "value") orelse continue;
        const bare = if (std.mem.endsWith(u8, raw_id, "[1m]")) raw_id[0 .. raw_id.len - 4] else raw_id;
        const aliases = [_][]const u8{ "default", "opus", "sonnet", "haiku", "fable" };
        var alias = false;
        for (aliases) |a| if (std.mem.eql(u8, bare, a)) {
            alias = true;
        };
        if (alias) continue;
        valid = true;
        var model_id = raw_id;
        if (snapshotBase(raw_id)) |b| if (indexOfModel(models.items, b) != null) {
            model_id = b;
        };
        if (text(entry, "value")) |v| if (std.mem.eql(u8, v, "default")) {
            default = model_id;
        };
        if (indexOfModel(models.items, model_id) != null) continue;
        var ladder: std.ArrayList([]const u8) = .empty;
        if (objGet(entry, "supportedEffortLevels")) |efforts| if (efforts == .array) for (efforts.array.items) |e| {
            if (e != .string) continue;
            const level: []const u8 = for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |l| {
                if (std.mem.eql(u8, e.string, l)) break l;
            } else continue;
            var dup = false;
            for (ladder.items) |have| if (std.mem.eql(u8, have, level)) {
                dup = true;
            };
            if (!dup) try ladder.append(arena, level);
        };
        for (ladder.items) |l| if (std.mem.eql(u8, l, "xhigh")) {
            try ladder.appendSlice(arena, &.{ "ultracode", "ultrathink" });
            break;
        };
        try models.append(arena, .{
            .id = model_id,
            .label = text(entry, "displayName") orelse model_id,
            .description = text(entry, "description"),
            .reasoning_levels = ladder.items,
            .options = &chrome_only,
        });
    }
    if (!valid) return empty;
    if (default) |d| {
        // The picker folds long-context duplicates into their curated base:
        // put that base right behind the concrete default.
        if (std.mem.endsWith(u8, d, "[1m]")) if (indexOfModel(models.items, d[0 .. d.len - 4])) |i| moveToFront(models.items, i);
        if (indexOfModel(models.items, d)) |i| moveToFront(models.items, i);
    }
    return .{ .ok = models.items };
}

// ── the process-global state ───────────────────────────────────────────────

const InitResponse = union(enum) {
    /// The `control_response.response` object as JSON text.
    ok: []u8,
    err: Failure,
};

/// `discovery::InitializeCache`.
const InitializeCache = struct {
    mutex: Io.Mutex = .init,
    context: ?[32]u8 = null,
    completed_at: ?i96 = null,
    /// `ok` text owned by `core.long_gpa`.
    response: ?InitResponse = null,

    fn clear(self: *InitializeCache) void {
        if (self.response) |r| if (r == .ok) core.long_gpa.free(r.ok);
        self.context = null;
        self.completed_at = null;
        self.response = null;
    }

    fn copy(gpa: Allocator, r: InitResponse) !InitResponse {
        return switch (r) {
            .ok => |t| .{ .ok = try gpa.dupe(u8, t) },
            .err => |f| .{ .err = f },
        };
    }

    /// `get(context, probe)`: coalesced, two-minute reuse of a success, and
    /// never caching a response from a login that changed mid-probe. Probe
    /// errors come back as `Protocol(error.to_string())`.
    fn get(self: *InitializeCache, gpa: Allocator, io: Io, budget_ms: u64, probe_ms: u64) !InitResponse {
        const requested_at = nowNs(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const key = switch (contextKey(gpa, io)) {
            .ok => |k| k,
            .err => |f| return .{ .err = f },
        };
        if (self.context == null or !std.mem.eql(u8, &self.context.?, &key)) {
            self.clear();
            self.context = key;
        }
        if (self.completed_at) |at| if (self.response) |r| {
            if (at >= requested_at or (r == .ok and nowNs(io) - at < @as(i96, initialize_ttl_ms) * std.time.ns_per_ms))
                return copy(gpa, r);
        };
        const probe = try probeInitialize(gpa, io, probe_ms, budget_ms);
        var response: InitResponse = switch (probe.result) {
            .ok => |t| .{ .ok = t },
            .err => |f| blk: {
                var buf: [1024]u8 = undefined;
                break :blk .{ .err = Failure.protocol("{s}", .{f.display(&buf)}) };
            },
        };
        errdefer if (response == .ok) gpa.free(response.ok);
        // `catalog::get_with_timeout` dropped the request: nothing is recorded.
        if (probe.budget_expired) return response;
        const after = contextKey(gpa, io);
        if (after == .err) {
            if (response == .ok) gpa.free(response.ok);
            return .{ .err = after.err };
        }
        if (!std.mem.eql(u8, &after.ok, &key)) {
            self.clear();
            if (response == .ok) gpa.free(response.ok);
            response = .{ .err = Failure.protocol("Claude credentials changed during initialize; retry", .{}) };
            return response;
        }
        const stored = try copy(core.long_gpa, response);
        if (self.response) |old| if (old == .ok) core.long_gpa.free(old.ok);
        self.response = stored;
        self.completed_at = nowNs(io);
        return response;
    }
};

const State = struct {
    models: core.MemCache = .{},
    initialize: InitializeCache = .{},
};

var state: State = .{};

/// The Io the engine last called with: `fallbackModels` has none of its own
/// but reads `settings.json`.
var io_state: std.atomic.Value(u8) = .init(0);
var saved_io: Io = undefined;

fn rememberIo(io: Io) void {
    if (io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        saved_io = io;
        io_state.store(2, .release);
    }
}

fn fallbackIo() Io {
    if (io_state.load(.acquire) == 2) return saved_io;
    return Io.Threaded.global_single_threaded.io();
}

const vtable: core.Harness.VTable = .{
    .modelContext = vtModelContext,
    .modelCatalog = vtModelCatalog,
    .fallbackModels = vtFallbackModels,
};

/// Claude Code's discovery surface, backed by the process-global caches.
pub fn harness() core.Harness {
    return .{ .id = id, .ptr = &state, .vtable = &vtable };
}

/// Drop the memory catalog and the cached `initialize` response.
pub fn resetForTests() void {
    if (state.models.models) |m| core.long_gpa.free(m);
    state.models = .{};
    state.initialize.clear();
    state.initialize = .{};
}

fn vtModelContext(_: *anyopaque, gpa: Allocator, io: Io) anyerror!core.ContextResult {
    rememberIo(io);
    return modelContext(gpa, io);
}

fn vtModelCatalog(_: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!core.Result {
    rememberIo(io);
    return modelCatalogWithTimeout(gpa, io, force, catalog_timeout_ms, initialize_timeout_ms);
}

fn vtFallbackModels(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
    return fallbackModelsJson(gpa, fallbackIo());
}

/// `fallback_models()`: `configured_models()` as JSON.
pub fn fallbackModelsJson(gpa: Allocator, io: Io) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    return core.modelsJson(gpa, try configuredModels(arena_state.allocator(), io, &env));
}

/// `model_context()`: resolve the CLI each call, then fingerprint it.
pub fn modelContext(gpa: Allocator, io: Io) !core.ContextResult {
    const exe = (try core.resolve_cli(gpa, io, id)) orelse return .{ .err = Failure.notInstalled(install_hint) };
    defer gpa.free(exe);
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    const ctx = core.computeContext(gpa, io, id, exe, &.{}, &env) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .err = Failure.ioError(.other, @errorName(e)) },
    };
    return .{ .ok = ctx };
}

fn contextKey(gpa: Allocator, io: Io) core.KeyResult {
    var r = modelContext(gpa, io) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
    switch (r) {
        .ok => |*c| {
            defer c.deinit(gpa);
            return .{ .ok = c.key() };
        },
        .err => |f| return .{ .err = f },
        .none => unreachable,
    }
}

const Keyer = struct {
    gpa: Allocator,
    io: Io,
    pub fn key(self: *Keyer) core.KeyResult {
        return contextKey(self.gpa, self.io);
    }
};

const Discoverer = struct {
    probe_ms: u64,

    /// `initialize()` then `with_discovered_models(configured_models(), response)`.
    pub fn discover(self: *Discoverer, gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
        const r = try state.initialize.get(gpa, io, budget_ms, self.probe_ms);
        const response_text = switch (r) {
            .err => |f| return .{ .err = f },
            .ok => |t| t,
        };
        defer gpa.free(response_text);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const response = try json.parseFromSliceLeaky(json.Value, arena, response_text, parse_opts);
        var env = try core.currentEnv(gpa);
        defer env.deinit();
        const base = try configuredModels(arena, io, &env);
        return switch (try withDiscoveredModels(arena, base, response)) {
            .err => |f| .{ .err = f },
            .ok => |models| .{ .ok = try core.modelsJson(gpa, models) },
        };
    }
};

/// `model_catalog(force)` with its budgets as parameters (Rust: 35 s and
/// the 10 s initialize probe).
pub fn modelCatalogWithTimeout(gpa: Allocator, io: Io, force: bool, total_ms: u64, probe_ms: u64) !core.Result {
    var ctx = try modelContext(gpa, io);
    switch (ctx) {
        .err => |f| return .{ .err = f },
        .ok => |*c| c.deinit(gpa),
        .none => {},
    }
    var keyer: Keyer = .{ .gpa = gpa, .io = io };
    var discoverer: Discoverer = .{ .probe_ms = probe_ms };
    return state.models.getWithTimeout(gpa, io, force, total_ms, &keyer, &discoverer);
}

// ── the `initialize` handshake (`probe_initialize`) ────────────────────────

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

const Probe = struct {
    result: InitResponse,
    /// The caller's budget ran out first (Rust drops the future).
    budget_expired: bool = false,
};

/// `binary_hint(exe)`: `"{path} (version {v|unknown})"`.
fn binaryHint(buf: []u8, io: Io, exe: []const u8) []const u8 {
    var vbuf: [128]u8 = undefined;
    const v = harness_version.binaryVersionString(io, exe, &vbuf) orelse "unknown";
    return std.fmt.bufPrint(buf, "{s} (version {s})", .{ exe, v }) catch buf[0..0];
}

/// The environment probes run with: the engine's, minus the variables every
/// agent child drops, `HARNESS_BUILD_WAIT_DIR` removed
/// (`apply_run_environment(None)`), and PATH composed (`compose_child_path`).
fn childEnv(gpa: Allocator, io: Io, exe: []const u8) !Environ.Map {
    var env = try core.currentEnv(gpa);
    errdefer env.deinit();
    for (agent_proc.stripped_env) |k| _ = env.orderedRemove(k);
    _ = env.orderedRemove("HARNESS_BUILD_WAIT_DIR");
    const login = if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(gpa, io, &env, null);
    const path = try agent_proc.composeChildPath(gpa, exe, env.get("PATH"), login);
    defer gpa.free(path);
    try env.put("PATH", path);
    return env;
}

fn spawnFailure(io: Io, exe: []const u8, err: anyerror) Failure {
    if (err == error.NotInstalled) {
        var buf: [1024]u8 = undefined;
        return Failure.notInstalled(binaryHint(&buf, io, exe));
    }
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "AccessDenied") or std.mem.eql(u8, name, "PermissionDenied"))
        return Failure.ioError(.other, "Permission denied (os error 13)");
    return Failure.ioError(.other, name);
}

/// `shutdown_child`: SIGTERM the group, SIGKILL after the grace (cut to what
/// is left of the caller's budget), reap.
fn shutdown(proc: *agent_proc.AgentProc, io: Io, budget_at: i96) void {
    const left_ns = budget_at - nowNs(io);
    const left_ms: u64 = if (left_ns <= 0) 0 else @intCast(@divFloor(left_ns, std.time.ns_per_ms));
    proc.escalate(0, @intCast(@min(kill_grace_ms, left_ms)));
    _ = proc.wait();
    proc.destroy();
}

/// `probe_initialize(None)`: start the CLI in stream-json mode, send the
/// `initialize` control request, and return the matching
/// `control_response.response`. No user message is written. Bounded by
/// `probe_ms` (Rust: 10 s) and the caller's `budget_ms`; the child is
/// stopped either way.
pub fn probeInitialize(gpa: Allocator, io: Io, probe_ms: u64, budget_ms: u64) !Probe {
    const started = nowNs(io);
    const exe = (try core.resolve_cli(gpa, io, id)) orelse return .{ .result = .{ .err = Failure.notInstalled(install_hint) } };
    defer gpa.free(exe);
    var env = try childEnv(gpa, io, exe);
    defer env.deinit();
    var argv: [1 + probe_args.len][]const u8 = undefined;
    argv[0] = exe;
    @memcpy(argv[1..], &probe_args);
    const proc = agent_proc.AgentProc.spawn(gpa, io, &argv, null, &env, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .result = .{ .err = spawnFailure(io, exe, e) } },
    };
    const budget_at = started + @as(i96, budget_ms) * std.time.ns_per_ms;
    const timeout_at = started + @as(i96, probe_ms) * std.time.ns_per_ms;
    // The probe's timeout ends it like `shutdown_child` (SIGTERM, then SIGKILL
    // after the grace); the caller's budget kills it outright (`kill_on_drop`).
    {
        const term_ms = @min(probe_ms, budget_ms);
        const kill_ms = if (budget_ms <= probe_ms) budget_ms else @min(probe_ms + kill_grace_ms, budget_ms);
        proc.escalate(@intCast(term_ms), @intCast(kill_ms));
    }
    var result = try exchange(gpa, proc);
    shutdown(proc, io, budget_at);
    const now = nowNs(io);
    if (result == .err and now >= @min(timeout_at, budget_at)) {
        result = .{ .err = Failure.protocol("Claude initialize timed out", .{}) };
    }
    return .{ .result = result, .budget_expired = budget_ms < probe_ms and now >= budget_at };
}

fn exchange(gpa: Allocator, proc: *agent_proc.AgentProc) !InitResponse {
    proc.writeLine(initialize_request) catch return .{ .err = Failure.ioError(.other, "Broken pipe (os error 32)") };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    while (try proc.readLine()) |line| {
        _ = arena_state.reset(.retain_capacity);
        if (!std.unicode.utf8ValidateSlice(line)) return .{ .err = Failure.ioError(.other, "stream did not contain valid UTF-8") };
        const frame = json.parseFromSliceLeaky(json.Value, arena_state.allocator(), line, parse_opts) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue,
        };
        const kind = strGet(frame, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "control_response")) continue;
        const response: json.Value = objGet(frame, "response") orelse .null;
        const rid = strGet(response, "request_id") orelse continue;
        if (!std.mem.eql(u8, rid, probe_id)) continue;
        if (strGet(response, "subtype")) |s| if (std.mem.eql(u8, s, "error")) {
            return .{ .err = Failure.protocol("{s}", .{strGet(response, "error") orelse "initialize control request failed"}) };
        };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.print("{f}", .{json.fmt(response, .{})});
        return .{ .ok = try aw.toOwnedSlice() };
    }
    return .{ .err = Failure.protocol("claude exited before answering the initialize control request", .{}) };
}

// ── Rust's `str::trim` (Unicode White_Space) ───────────────────────────────

fn wsLenFront(s: []const u8) usize {
    if (s.len >= 1 and ((s[0] >= 0x09 and s[0] <= 0x0D) or s[0] == ' ')) return 1;
    if (s.len >= 2 and s[0] == 0xC2 and (s[1] == 0x85 or s[1] == 0xA0)) return 2;
    if (s.len >= 3) return ws3(s[0..3]);
    return 0;
}

fn wsLenBack(s: []const u8) usize {
    const n = s.len;
    if (n >= 1 and ((s[n - 1] >= 0x09 and s[n - 1] <= 0x0D) or s[n - 1] == ' ')) return 1;
    if (n >= 2 and s[n - 2] == 0xC2 and (s[n - 1] == 0x85 or s[n - 1] == 0xA0)) return 2;
    if (n >= 3) return ws3(s[n - 3 ..]);
    return 0;
}

fn ws3(b: []const u8) usize {
    const ok = (b[0] == 0xE1 and b[1] == 0x9A and b[2] == 0x80) or // U+1680
        (b[0] == 0xE2 and b[1] == 0x80 and ((b[2] >= 0x80 and b[2] <= 0x8A) or b[2] == 0xA8 or b[2] == 0xA9 or b[2] == 0xAF)) or // U+2000–200A, 2028, 2029, 202F
        (b[0] == 0xE2 and b[1] == 0x81 and b[2] == 0x9F) or // U+205F
        (b[0] == 0xE3 and b[1] == 0x80 and b[2] == 0x80); // U+3000
    return if (ok) 3 else 0;
}

pub fn rustTrim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const n = wsLenFront(s[start..]);
        if (n == 0) break;
        start += n;
    }
    var end = s.len;
    while (end > start) {
        const n = wsLenBack(s[start..end]);
        if (n == 0) break;
        end -= n;
    }
    return s[start..end];
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn rowsJson(arena: Allocator, rows: []const Model) ![]u8 {
    return core.modelsJson(arena, rows);
}

test "catalog_claude static rows keep Rust's ladders and options" {
    const gpa = testing.allocator;
    const text_json = try core.modelsJson(gpa, &static_models);
    defer gpa.free(text_json);
    try testing.expect(std.mem.startsWith(u8, text_json, "[{\"id\":\"claude-fable-5-1\",\"label\":\"Fable 5.1\",\"description\":\"Most intelligent model for building agents\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultracode\",\"ultrathink\"],\"options\":[{\"id\":\"contextWindow\",\"label\":\"Context Window\",\"choices\":[{\"id\":\"200k\",\"label\":\"200K\"},{\"id\":\"1m\",\"label\":\"1M\"}],\"defaultChoice\":\"200k\"},{\"id\":\"chrome\",\"label\":\"Chrome\",\"choices\":[{\"id\":\"off\",\"label\":\"Off\"},{\"id\":\"on\",\"label\":\"On\"}],\"defaultChoice\":\"off\"}]}"));
    try testing.expect(std.mem.endsWith(u8, text_json, "{\"id\":\"claude-haiku-4-5\",\"label\":\"Haiku 4.5\",\"description\":\"Fastest model for everyday tasks\",\"reasoningLevels\":[],\"options\":[{\"id\":\"thinking\",\"label\":\"Thinking\",\"choices\":[{\"id\":\"off\",\"label\":\"Off\"},{\"id\":\"on\",\"label\":\"On\"}],\"defaultChoice\":\"off\"},{\"id\":\"chrome\",\"label\":\"Chrome\",\"choices\":[{\"id\":\"off\",\"label\":\"Off\"},{\"id\":\"on\",\"label\":\"On\"}],\"defaultChoice\":\"off\"}]}]"));
    try testing.expectEqual(@as(usize, 7), static_models.len);
    try testing.expectEqualSlices([]const u8, &xhigh_ladder, static_models[4].reasoning_levels);
    try testing.expectEqualStrings("fastMode", static_models[2].options[1].id);
}

test "catalog_claude settings models keep the manifest and the full ladder" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ base, "settings.json" });
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data =
        \\{"model":"gateway/model","env":{"ANTHROPIC_MODEL":"gateway/model","ANTHROPIC_SMALL_FAST_MODEL":" fast ",
        \\"ANTHROPIC_DEFAULT_OPUS_MODEL":"opus","ANTHROPIC_DEFAULT_SONNET_MODEL":"sonnet","ANTHROPIC_DEFAULT_HAIKU_MODEL":"haiku",
        \\"OTHER":"ignored"}}
    });
    const models = try modelsWithSettings(arena, io, path);
    try testing.expectEqual(static_models.len + 5, models.len);
    for (models[0..static_models.len], static_models) |m, s| try testing.expectEqualStrings(s.id, m.id);
    const want = [_][]const u8{ "gateway/model", "fast", "opus", "sonnet", "haiku" };
    for (models[static_models.len..], want) |m, w| {
        try testing.expectEqualStrings(w, m.id);
        try testing.expectEqualStrings(w, m.label);
        try testing.expectEqualSlices([]const u8, &full_ladder, m.reasoning_levels);
        try testing.expectEqual(@as(usize, 1), m.options.len);
        try testing.expect(m.description == null);
    }
    // A curated id is not repeated; invalid or missing settings give the manifest.
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"model\":\"claude-sonnet-5\",\"env\":{\"ANTHROPIC_MODEL\":\"  \"}}" });
    try testing.expectEqual(static_models.len, (try modelsWithSettings(arena, io, path)).len);
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "invalid" });
    try testing.expectEqual(static_models.len, (try modelsWithSettings(arena, io, path)).len);
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "[\"model\"]" });
    try testing.expectEqual(static_models.len, (try modelsWithSettings(arena, io, path)).len);
    const missing = try std.fs.path.join(arena, &.{ base, "nope", "settings.json" });
    try testing.expectEqual(static_models.len, (try modelsWithSettings(arena, io, missing)).len);
}

fn overlay(arena: Allocator, response: []const u8) !Overlay {
    const v = try json.parseFromSliceLeaky(json.Value, arena, response, parse_opts);
    return withDiscoveredModels(arena, &static_models, v);
}

test "catalog_claude discovery folds snapshots, skips aliases and promotes the default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try overlay(arena,
        \\{"response":{"models":[
        \\ {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","description":"Fastest for quick answers"},
        \\ {"value":"claude-haiku-9-9-20990101","displayName":"Haiku 9.9"},
        \\ {"value":"opus"},{"value":"sonnet[1m]"},{"value":"default","resolvedModel":"claude-opus-9[1m]","displayName":" Opus 9 ","description":"  ",
        \\  "supportedEffortLevels":["low","high","xhigh","high","turbo",7]},
        \\ {"value":"claude-new","supportedEffortLevels":["low","max"]},
        \\ "not an object",{"resolvedModel":"   "}
        \\]}}
    );
    const models = r.ok;
    var haiku: usize = 0;
    for (models) |m| if (std.mem.eql(u8, m.label, "Haiku 4.5")) {
        haiku += 1;
    };
    try testing.expectEqual(@as(usize, 1), haiku);
    try testing.expect(indexOfModel(models, "claude-haiku-9-9-20990101") != null);
    try testing.expect(indexOfModel(models, "opus") == null);
    // The default leads; its long-context base (not curated here) is absent.
    try testing.expectEqualStrings("claude-opus-9[1m]", models[0].id);
    try testing.expectEqualStrings("Opus 9", models[0].label);
    try testing.expect(models[0].description == null);
    try testing.expectEqualSlices([]const u8, &.{ "low", "high", "xhigh", "ultracode", "ultrathink" }, models[0].reasoning_levels);
    const new = models[indexOfModel(models, "claude-new").?];
    try testing.expectEqualSlices([]const u8, &.{ "low", "max" }, new.reasoning_levels);
    try testing.expectEqualStrings("Chrome", new.options[0].label);
    try testing.expectEqualStrings("Haiku 9.9", models[indexOfModel(models, "claude-haiku-9-9-20990101").?].label);
    try testing.expectEqual(static_models.len + 3, models.len);

    // A `[1m]` default moves its curated base right behind it.
    const r2 = try overlay(arena, "{\"response\":{\"models\":[{\"value\":\"default\",\"resolvedModel\":\"claude-sonnet-5[1m]\"}]}}");
    try testing.expectEqualStrings("claude-sonnet-5[1m]", r2.ok[0].id);
    try testing.expectEqualStrings("claude-sonnet-5", r2.ok[1].id);
    try testing.expectEqualStrings("claude-fable-5-1", r2.ok[2].id);
    // A curated default moves to the front without a new row.
    const r3 = try overlay(arena, "{\"response\":{\"models\":[{\"value\":\"default\",\"resolvedModel\":\"claude-opus-4-8\"}]}}");
    try testing.expectEqualStrings("claude-opus-4-8", r3.ok[0].id);
    try testing.expectEqual(static_models.len, r3.ok.len);

    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "{}", "{\"response\":{\"models\":[]}}", "{\"response\":{\"models\":{}}}", "{\"response\":{\"models\":[{\"value\":\"default\"},{\"value\":\"haiku\"}]}}" }) |bad| {
        const e = try overlay(arena, bad);
        try testing.expectEqualStrings("harness protocol error: Claude returned an empty model catalog", e.err.display(&buf));
    }
    try testing.expectEqualStrings("claude-haiku-4-5", snapshotBase("claude-haiku-4-5-20251001").?);
    try testing.expect(snapshotBase("claude-haiku-4-5-2025100") == null);
    try testing.expect(snapshotBase("claude-x-2025100a") == null);
    try testing.expectEqualStrings("a\u{3000}b", rustTrim("\u{a0}\u{2009} a\u{3000}b\t\u{205f}"));
}

// A mock CLI: answers `--version`, records its argv, its stdin line and a
// call count, then replays `body` (a shell snippet).
const Mock = struct {
    tmp: testing.TmpDir,
    dir: []u8,
    script: []u8,
    home: []u8,
    env: Environ.Map,

    var cli: ?[]const u8 = null;

    fn resolve(gpa: Allocator, _: Io, wire: []const u8) anyerror!?[]u8 {
        if (!std.mem.eql(u8, wire, id)) return null;
        return if (cli) |c| try gpa.dupe(u8, c) else null;
    }

    fn init(body: []const u8) !Mock {
        const gpa = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(dir_z);
        const dir = try gpa.dupe(u8, dir_z);
        errdefer gpa.free(dir);
        try tmp.dir.createDirPath(io, "home/.claude");
        const script_text = try std.fmt.allocPrint(gpa,
            \\#!/bin/sh
            \\D='{s}'
            \\if [ "$1" = "--version" ]; then echo "2.1.300 (Claude Code)"; exit 0; fi
            \\echo "$@" > "$D/argv"
            \\echo x >> "$D/calls"
            \\echo $$ > "$D/pid"
            \\echo "$PATH|${{HARNESS_BUILD_WAIT_DIR-unset}}|${{CLAUDECODE-unset}}" > "$D/env"
            \\{s}
            \\
        , .{ dir, body });
        defer gpa.free(script_text);
        try tmp.dir.writeFile(io, .{ .sub_path = "claude", .data = script_text, .flags = .{ .permissions = .executable_file } });
        const script = try std.fs.path.join(gpa, &.{ dir, "claude" });
        errdefer gpa.free(script);
        const home = try std.fs.path.join(gpa, &.{ dir, "home" });
        errdefer gpa.free(home);
        var env = Environ.Map.init(gpa);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        try env.put("HARNESS_BUILD_WAIT_DIR", "synthetic/other-run");
        try env.put("CLAUDECODE", "1");
        return .{ .tmp = tmp, .dir = dir, .script = script, .home = home, .env = env };
    }

    /// Point the engine hooks at this mock (after the value has its final address).
    fn activate(self: *Mock) void {
        resetForTests();
        core.env_override = &self.env;
        cli = self.script;
        core.resolve_cli = resolve;
    }

    fn deinit(self: *Mock) void {
        resetForTests();
        core.env_override = null;
        cli = null;
        const gpa = testing.allocator;
        self.env.deinit();
        gpa.free(self.script);
        gpa.free(self.home);
        gpa.free(self.dir);
        self.tmp.cleanup();
    }

    fn read(self: *Mock, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
    }

    fn calls(self: *Mock) !usize {
        const t = self.read("calls") catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer testing.allocator.free(t);
        return std.mem.count(u8, t, "x");
    }

    /// The mock's process is gone (reaped and not a zombie we leaked).
    fn expectGone(self: *Mock) !void {
        // Process ids are handles on Windows; the mock scripts are Unix-only.
        if (comptime builtin.os.tag == .windows) return;
        const t = try self.read("pid");
        defer testing.allocator.free(t);
        const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, t, " \n"), 10);
        try testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @fromBackingInt(@intCast(0))));
    }
};

const success_body =
    \\IFS= read -r line
    \\printf '%s\n' "$line" > "$D/request"
    \\echo 'not json'
    \\echo '{"type":"system","subtype":"init"}'
    \\echo '{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}'
    \\echo '{"type":"control_response","response":{"subtype":"success","request_id":"harness-command-probe","response":{"commands":[],"models":[{"value":"default","resolvedModel":"claude-opus-9","displayName":"Opus 9","description":"Synthetic default","supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"sonnet"}]}}}'
    \\exec cat > /dev/null
;

fn expectFailure(r: core.Result, code: core.Code, want: []const u8) !void {
    switch (r) {
        .ok => |c| {
            testing.allocator.free(c.models);
            return error.TestUnexpectedResult;
        },
        .err => |f| {
            var buf: [1024]u8 = undefined;
            try testing.expectEqualStrings(want, f.display(&buf));
            try testing.expectEqual(code, f.code);
        },
    }
}

test "catalog_claude not installed reads as Rust's NotInstalled" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init("exit 0");
    defer m.deinit();
    m.activate();
    Mock.cli = null;
    const want = "harness binary not found: " ++ install_hint;
    const h = harness();
    try testing.expectEqualStrings("claude-code", h.id);
    const ctx = try h.modelContext(gpa, io);
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(want, ctx.err.display(&buf));
    try testing.expectEqual(core.Code.missing_executable, ctx.err.code);
    try expectFailure(try h.modelCatalog(gpa, io, false), .missing_executable, want);
    // The probe itself reports the same when the CLI disappears.
    const p = try probeInitialize(gpa, io, 1000, 1000);
    try testing.expectEqualStrings(want, p.result.err.display(&buf));
    // A resolved path that doesn't exist: `binary_hint`.
    Mock.cli = "/nonexistent/harness-claude-mock";
    const p2 = try probeInitialize(gpa, io, 1000, 1000);
    try testing.expectEqualStrings("harness binary not found: /nonexistent/harness-claude-mock (version unknown)", p2.result.err.display(&buf));
    try testing.expectEqual(@as(usize, 0), try m.calls());
}

test "catalog_claude live catalog from the initialize handshake, then cached" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(success_body);
    defer m.deinit();
    m.activate();
    try m.tmp.dir.writeFile(io, .{ .sub_path = "home/.claude/settings.json", .data = "{\"model\":\"gateway/model\"}" });
    const h = harness();
    const started = Io.Clock.awake.now(io).nanoseconds;
    const r = try h.modelCatalog(gpa, io, false);
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - started < 8 * std.time.ns_per_s);
    const c = r.ok;
    defer gpa.free(c.models);
    try testing.expectEqual(core.Source.live, c.source);
    try testing.expect(std.mem.startsWith(u8, c.models, "[{\"id\":\"claude-opus-9\",\"label\":\"Opus 9\",\"description\":\"Synthetic default\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultracode\",\"ultrathink\"],\"options\":[{\"id\":\"chrome\""));
    try testing.expect(std.mem.indexOf(u8, c.models, "\"id\":\"gateway/model\",\"label\":\"gateway/model\"") != null);
    try testing.expect(std.mem.indexOf(u8, c.models, "\"id\":\"claude-fable-5-1\"") != null);
    // The CLI's argv and the exact control request.
    const argv = try m.read("argv");
    defer gpa.free(argv);
    try testing.expectEqualStrings("--print --input-format stream-json --output-format stream-json --verbose\n", argv);
    const req = try m.read("request");
    defer gpa.free(req);
    try testing.expectEqualStrings(initialize_request ++ "\n", req);
    // The child's environment: the exe's dir leads PATH, the nesting and
    // build-wait variables are dropped.
    const child_env = try m.read("env");
    defer gpa.free(child_env);
    const want_env = try std.fmt.allocPrint(gpa, "{s}:/usr/bin:/bin|unset|unset\n", .{m.dir});
    defer gpa.free(want_env);
    try testing.expectEqualStrings(want_env, child_env);
    try m.expectGone();

    // Within the cooldown: the cache answers without a second probe.
    const again = try h.modelCatalog(gpa, io, false);
    defer gpa.free(again.ok.models);
    try testing.expectEqual(core.Source.cache, again.ok.source);
    try testing.expectEqualStrings(c.models, again.ok.models);
    try testing.expectEqual(@as(usize, 1), try m.calls());
    // A forced refresh reuses the two-minute initialize response.
    const forced = try h.modelCatalog(gpa, io, true);
    defer gpa.free(forced.ok.models);
    try testing.expectEqual(core.Source.live, forced.ok.source);
    try testing.expectEqual(@as(usize, 1), try m.calls());
    // A new login (settings file is part of the context) probes again.
    try m.tmp.dir.writeFile(io, .{ .sub_path = "home/.claude/.credentials.json", .data = "synthetic-account-two" });
    const relog = try h.modelCatalog(gpa, io, false);
    defer gpa.free(relog.ok.models);
    try testing.expectEqual(core.Source.live, relog.ok.source);
    try testing.expectEqual(@as(usize, 2), try m.calls());

    // The context is the CLI fingerprint; the fallback is the configured rows.
    var ctx = (try h.modelContext(gpa, io)).ok;
    defer ctx.deinit(gpa);
    try testing.expectEqualStrings("2.1.300", ctx.binary_version.?);
    const fb = try h.fallbackModels(gpa);
    defer gpa.free(fb);
    try testing.expect(std.mem.startsWith(u8, fb, "[{\"id\":\"claude-fable-5-1\""));
    try testing.expect(std.mem.endsWith(u8, fb, "{\"id\":\"gateway/model\",\"label\":\"gateway/model\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultracode\",\"ultrathink\"],\"options\":[{\"id\":\"chrome\",\"label\":\"Chrome\",\"choices\":[{\"id\":\"off\",\"label\":\"Off\"},{\"id\":\"on\",\"label\":\"On\"}],\"defaultChoice\":\"off\"}]}]"));
}

test "catalog_claude an auth error reply is not a catalog and cools down" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(
        \\IFS= read -r line
        \\echo '{"type":"control_response","response":{"subtype":"error","request_id":"harness-command-probe","error":"Not logged in · Please run /login"}}'
        \\exec cat > /dev/null
    );
    defer m.deinit();
    m.activate();
    const h = harness();
    try expectFailure(try h.modelCatalog(gpa, io, false), .auth_required, "model discovery auth_required: harness protocol error: harness protocol error: Not logged in · Please run /login");
    try testing.expectEqual(@as(usize, 1), try m.calls());
    // Cooling down: no new probe until forced.
    try expectFailure(try h.modelCatalog(gpa, io, false), .auth_required, "model discovery auth_required: harness protocol error: harness protocol error: Not logged in · Please run /login");
    try testing.expectEqual(@as(usize, 1), try m.calls());
    // An error without text gets Rust's default.
    resetForTests();
    try m.tmp.dir.writeFile(io, .{ .sub_path = "claude", .data = "#!/bin/sh\n[ \"$1\" = --version ] && { echo 2.1.300; exit 0; }\nread -r l\necho '{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"harness-command-probe\"}}'\n", .flags = .{ .permissions = .executable_file } });
    const p = try probeInitialize(gpa, io, 5000, 5000);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: initialize control request failed", p.result.err.display(&buf));
}

test "catalog_claude malformed output, early exit and an empty catalog fail" {
    const gpa = testing.allocator;
    const io = testing.io;
    {
        var m = try Mock.init(
            \\IFS= read -r line
            \\echo 'garbage {'
            \\echo '{"type":"control_response","response":"nope"}'
            \\exit 3
        );
        defer m.deinit();
        m.activate();
        const p = try probeInitialize(gpa, io, 5000, 5000);
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("harness protocol error: claude exited before answering the initialize control request", p.result.err.display(&buf));
        // Through the cache: wrapped once more, transient, retried three times.
        try expectFailure(try catalogOnce(gpa, io), .failed, "model discovery failed: harness protocol error: harness protocol error: claude exited before answering the initialize control request");
        try testing.expectEqual(@as(usize, 4), try m.calls());
    }
    {
        var m = try Mock.init(
            \\IFS= read -r line
            \\printf '\377\376 not utf-8\n'
            \\exec cat > /dev/null
        );
        defer m.deinit();
        m.activate();
        const p = try probeInitialize(gpa, io, 5000, 5000);
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("io: stream did not contain valid UTF-8", p.result.err.display(&buf));
    }
    {
        var m = try Mock.init(
            \\IFS= read -r line
            \\echo '{"type":"control_response","response":{"subtype":"success","request_id":"harness-command-probe","response":{"commands":[],"models":[]}}}'
            \\exec cat > /dev/null
        );
        defer m.deinit();
        m.activate();
        // The empty catalog is not retried as a probe (the initialize response
        // is reused for two minutes), and it is not a catalog.
        try expectFailure(try catalogOnce(gpa, io), .failed, "model discovery failed: harness protocol error: Claude returned an empty model catalog");
        try testing.expectEqual(@as(usize, 1), try m.calls());
        try m.expectGone();
    }
}

fn catalogOnce(gpa: Allocator, io: Io) !core.Result {
    return harness().modelCatalog(gpa, io, false);
}

test "catalog_claude a hung CLI is killed at the probe timeout and the budget" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(
        \\IFS= read -r line
        \\trap '' TERM
        \\sleep 30
    );
    defer m.deinit();
    m.activate();
    // The probe's own timeout: SIGTERM is ignored, SIGKILL follows the grace
    // (cut to the budget). A fresh script can take a few hundred ms to
    // start on macOS, so the timings leave room for that.
    var started = Io.Clock.awake.now(io).nanoseconds;
    const p = try probeInitialize(gpa, io, 1000, 2500);
    var elapsed = Io.Clock.awake.now(io).nanoseconds - started;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: Claude initialize timed out", p.result.err.display(&buf));
    try testing.expectEqual(core.Code.timeout, p.result.err.code);
    try testing.expect(!p.budget_expired);
    try testing.expect(elapsed >= 2 * std.time.ns_per_s and elapsed < 15 * std.time.ns_per_s);
    try m.expectGone();

    // Through the cache: the 1.5 s budget ends discovery before the probe's
    // grace does, and the child is killed.
    try m.tmp.dir.deleteFile(io, "pid");
    started = Io.Clock.awake.now(io).nanoseconds;
    try expectFailure(try modelCatalogWithTimeout(gpa, io, false, 1500, 1000), .timeout, "model discovery timeout: Harness model discovery timed out");
    elapsed = Io.Clock.awake.now(io).nanoseconds - started;
    try testing.expect(elapsed < 15 * std.time.ns_per_s);
    try m.expectGone();
    try testing.expectEqual(@as(usize, 2), try m.calls());
}

test "catalog_claude list serves the live catalog and curated rows for a logged-out CLI" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(
        \\IFS= read -r line
        \\echo '{"type":"control_response","response":{"subtype":"error","request_id":"harness-command-probe","error":"authentication required"}}'
        \\exec cat > /dev/null
    );
    defer m.deinit();
    m.activate();
    const r = try core.list(gpa, io, null, harness(), true);
    defer r.deinit(gpa);
    const fb = try harness().fallbackModels(gpa);
    defer gpa.free(fb);
    try testing.expectEqualStrings(fb, r.ok);
}
