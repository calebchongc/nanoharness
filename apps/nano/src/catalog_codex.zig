//! Codex's live model catalog, ported from
//! `crates/harness/src/codex/{mod.rs, catalog.rs}` and the parts of
//! `crates/harness/src/jsonrpc.rs` the probe uses:
//!
//! - `modelContext`: `CodexHarness::model_context` (the CLI resolved through
//!   `catalog_core.resolve_cli`, then `model_context::context`).
//! - `modelCatalog`: `CodexHarness::model_catalog`: the per-context memory
//!   cache (`get_with`, 20 s) over `discover_models`: a short-lived
//!   `codex app-server` (`initialize`, `initialized`, then every page of
//!   `model/list`), bounded at 10 s, with service tiers, upgrade notes and
//!   the default model's family promoted to the front.
//! - `fallbackModels`: `static_models()`, the curated snapshot.
//!
//! Std-only (plus `catalog_core.zig`, `agent_proc.zig`, `harness_version.zig`),
//! so it tests standalone with `zig test catalog_codex.zig`.
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
const Choice = core.Choice;

/// The wire id (`HarnessId::Codex`).
pub const id = "codex";

/// `resolve_executable`'s `NotInstalled` text.
pub const install_hint = "codex (searched PATH, the login shell's PATH, ~/.local/bin, ~/.codex/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CODEX_EXECUTABLE to override)";

/// `Catalog::get_with`'s budget.
pub const catalog_timeout_ms: u64 = 20_000;
/// `discover_models`' own timeout.
pub const discovery_timeout_ms: u64 = 10_000;
/// `CodexHarness::kill_grace`: SIGTERM → SIGKILL in `shutdown_child`.
pub const kill_grace_ms: u64 = 3_000;

/// `clientInfo.version` in `initialize` (Rust: `CARGO_PKG_VERSION`). The
/// engine sets it from its build version; this file stays std-only.
pub var client_version: []const u8 = "0.0.0";

const parse_opts: json.ParseOptions = .{ .duplicate_field_behavior = .use_last, .allocate = .alloc_always };

// ── the curated fallback (`catalog.rs`) ────────────────────────────────────

pub const ultra_ladder = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "ultra" };
pub const max_ladder = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };
pub const xhigh_ladder = [_][]const u8{ "low", "medium", "high", "xhigh" };

/// `service_tier()`.
pub const service_tier: ModelOption = .{
    .id = "serviceTier",
    .label = "Service Tier",
    .choices = &.{ .{ .id = "default", .label = "Standard" }, .{ .id = "fast", .label = "Fast" } },
    .default_choice = "default",
};

const tier_only = [_]ModelOption{service_tier};

/// `static_models()`: newest family first.
pub const static_models = [_]Model{
    .{ .id = "gpt-6-astra", .label = "GPT-6-Astra", .description = "Our most capable model for complex, demanding work.", .reasoning_levels = &ultra_ladder, .options = &tier_only },
    .{ .id = "gpt-5.6-sol", .label = "GPT-5.6-Sol", .description = "Frontier reasoning flagship", .reasoning_levels = &ultra_ladder, .options = &tier_only },
    .{ .id = "gpt-5.6-terra", .label = "GPT-5.6-Terra", .description = "Deep multi-step agentic work", .reasoning_levels = &ultra_ladder, .options = &tier_only },
    .{ .id = "gpt-5.6-luna", .label = "GPT-5.6-Luna", .description = "Fast frontier model", .reasoning_levels = &max_ladder, .options = &tier_only },
    .{ .id = "gpt-daybreak-blue-latest", .label = "Daybreak Blue", .description = "Frontier model for defensive cybersecurity work", .reasoning_levels = &ultra_ladder, .options = &.{} },
    .{ .id = "gpt-5.5", .label = "GPT-5.5", .description = "Previous generation flagship", .reasoning_levels = &xhigh_ladder, .options = &tier_only },
    .{ .id = "gpt-5.4", .label = "GPT-5.4", .description = "Reliable general coding", .reasoning_levels = &xhigh_ladder, .options = &tier_only },
    .{ .id = "gpt-5.4-mini", .label = "GPT-5.4-Mini", .description = "Small, fast and capable", .reasoning_levels = &xhigh_ladder, .options = &tier_only },
    .{ .id = "gpt-5.3-codex-spark", .label = "GPT-5.3-Codex-Spark", .description = "Ultra-fast lightweight coding", .reasoning_levels = &xhigh_ladder, .options = &tier_only },
};

/// `model_family`: `gpt-5.6-sol` → `gpt-5.6`, `gpt-5.5` → `gpt`.
pub fn modelFamily(model_id: []const u8) []const u8 {
    const name = if (std.mem.lastIndexOfScalar(u8, model_id, '/')) |slash| model_id[slash + 1 ..] else model_id;
    var parts = std.mem.splitScalar(u8, name, '-');
    const first = parts.next().?;
    if (parts.next() != null and parts.next() != null) {
        const dash = std.mem.lastIndexOfScalar(u8, name, '-').?;
        return name[0..dash];
    }
    return first;
}

fn indexOfModel(models: []const Model, model_id: []const u8) ?usize {
    for (models, 0..) |m, i| if (std.mem.eql(u8, m.id, model_id)) return i;
    return null;
}

/// `promote_default_family`: the default (or the first model) first, then
/// the rest of its family, then everything else, each in server order.
pub fn promoteDefaultFamily(scratch: Allocator, models: []Model, default_id: ?[]const u8) !void {
    if (models.len == 0) return;
    const chosen: []const u8 = blk: {
        if (default_id) |d| if (indexOfModel(models, d) != null) break :blk d;
        break :blk models[0].id;
    };
    const family = modelFamily(chosen);
    const order = try scratch.dupe(Model, models);
    defer scratch.free(order);
    var n: usize = 0;
    for (order) |m| if (std.mem.eql(u8, m.id, chosen)) {
        models[n] = m;
        n += 1;
    };
    for (order) |m| if (!std.mem.eql(u8, m.id, chosen) and std.mem.eql(u8, modelFamily(m.id), family)) {
        models[n] = m;
        n += 1;
    };
    for (order) |m| if (!std.mem.eql(u8, m.id, chosen) and !std.mem.eql(u8, modelFamily(m.id), family)) {
        models[n] = m;
        n += 1;
    };
}

// ── `model/list` pages (`mod.rs`) ──────────────────────────────────────────

fn objGet(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strGet(v: json.Value, key: []const u8) ?[]const u8 {
    const x = objGet(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

fn boolGet(v: json.Value, key: []const u8) ?bool {
    const x = objGet(v, key) orelse return null;
    return if (x == .bool) x.bool else null;
}

fn arrayGet(v: json.Value, key: []const u8) []const json.Value {
    const x = objGet(v, key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

/// `reasoning_level`: the levels Codex reports (`none` is not one).
fn reasoningLevel(value: []const u8) ?[]const u8 {
    for ([_][]const u8{ "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "ultracode", "ultrathink" }) |l| {
        if (std.mem.eql(u8, value, l)) return l;
    }
    return null;
}

/// `normalized_service_tier`: `priority` is persisted as `fast`.
fn normalizedServiceTier(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "priority")) "fast" else value;
}

fn serviceTierLabel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "fast") or std.mem.eql(u8, value, "priority")) return "Fast";
    if (std.mem.eql(u8, value, "flex")) return "Flex";
    if (std.mem.eql(u8, value, "ultrafast")) return "Ultra Fast";
    return value;
}

fn seen(choices: []const Choice, choice_id: []const u8) bool {
    for (choices) |c| if (std.mem.eql(u8, c.id, choice_id)) return true;
    return false;
}

/// `model_service_tier(item)`: Standard plus each advertised tier, or null
/// when the model advertises none.
pub fn modelServiceTier(arena: Allocator, item: json.Value) !?ModelOption {
    var choices: std.ArrayList(Choice) = .empty;
    try choices.append(arena, .{ .id = "default", .label = "Standard" });
    for (arrayGet(item, "serviceTiers")) |tier| {
        const wire_id = strGet(tier, "id") orelse continue;
        const tier_id = normalizedServiceTier(wire_id);
        if (seen(choices.items, tier_id)) continue;
        const label = if (strGet(tier, "name")) |n| (if (n.len > 0) n else serviceTierLabel(wire_id)) else serviceTierLabel(wire_id);
        try choices.append(arena, .{ .id = tier_id, .label = label });
    }
    for (arrayGet(item, "additionalSpeedTiers")) |tier| {
        if (tier != .string) continue;
        const tier_id = normalizedServiceTier(tier.string);
        if (!seen(choices.items, tier_id)) try choices.append(arena, .{ .id = tier_id, .label = serviceTierLabel(tier.string) });
    }
    if (choices.items.len == 1) return null;
    const default_choice = blk: {
        const d = normalizedServiceTier(strGet(item, "defaultServiceTier") orelse break :blk "default");
        break :blk if (seen(choices.items, d)) d else "default";
    };
    return .{ .id = "serviceTier", .label = "Service Tier", .choices = choices.items, .default_choice = default_choice };
}

pub const PageModel = struct { model: Model, is_default: bool };
pub const Page = struct { models: []PageModel, next_cursor: ?[]const u8 };

/// `parse_model_list_page(result)`: hidden models are dropped; unknown
/// reasoning levels are ignored one by one. Strings borrow `result`.
pub fn parseModelListPage(arena: Allocator, result: json.Value) !Page {
    var out: std.ArrayList(PageModel) = .empty;
    for (arrayGet(result, "data")) |item| {
        if (boolGet(item, "hidden") == true) continue;
        const raw = strGet(item, "model") orelse strGet(item, "id") orelse continue;
        const model_id = rustTrim(raw);
        if (model_id.len == 0) continue;
        const label = if (strGet(item, "displayName")) |l| (if (rustTrim(l).len > 0) rustTrim(l) else model_id) else model_id;
        var description: ?[]const u8 = if (strGet(item, "description")) |d| (if (rustTrim(d).len > 0) rustTrim(d) else null) else null;
        if (strGet(item, "upgrade")) |upgrade| if (upgrade.len > 0) {
            description = if (description) |d|
                try std.fmt.allocPrint(arena, "{s} (upgrade: {s})", .{ d, upgrade })
            else
                try std.fmt.allocPrint(arena, "(upgrade: {s})", .{upgrade});
        };
        var levels: std.ArrayList([]const u8) = .empty;
        for (arrayGet(item, "supportedReasoningEfforts")) |effort| {
            const name = strGet(effort, "reasoningEffort") orelse (if (effort == .string) effort.string else continue);
            if (reasoningLevel(name)) |l| try levels.append(arena, l);
        }
        const options: []const ModelOption = if (try modelServiceTier(arena, item)) |o| try arena.dupe(ModelOption, &.{o}) else &.{};
        try out.append(arena, .{
            .model = .{ .id = model_id, .label = label, .description = description, .reasoning_levels = levels.items, .options = options },
            .is_default = boolGet(item, "isDefault") == true,
        });
    }
    return .{ .models = out.items, .next_cursor = strGet(result, "nextCursor") };
}

// ── the process-global state ───────────────────────────────────────────────

const State = struct {
    models: core.MemCache = .{},
};

var state: State = .{};

const vtable: core.Harness.VTable = .{
    .modelContext = vtModelContext,
    .modelCatalog = vtModelCatalog,
    .fallbackModels = vtFallbackModels,
};

/// Codex's discovery surface, backed by the process-global cache.
pub fn harness() core.Harness {
    return .{ .id = id, .ptr = &state, .vtable = &vtable };
}

/// Drop the memory catalog.
pub fn resetForTests() void {
    client_version = "0.0.0";
    if (state.models.models) |m| core.long_gpa.free(m);
    state.models = .{};
}

fn vtModelContext(_: *anyopaque, gpa: Allocator, io: Io) anyerror!core.ContextResult {
    return modelContext(gpa, io);
}

fn vtModelCatalog(_: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!core.Result {
    return modelCatalogWithTimeout(gpa, io, force, catalog_timeout_ms, discovery_timeout_ms);
}

fn vtFallbackModels(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
    return core.modelsJson(gpa, &static_models);
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

const Keyer = struct {
    gpa: Allocator,
    io: Io,
    pub fn key(self: *Keyer) core.KeyResult {
        var r = modelContext(self.gpa, self.io) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
        switch (r) {
            .ok => |*c| {
                defer c.deinit(self.gpa);
                return .{ .ok = c.key() };
            },
            .err => |f| return .{ .err = f },
            .none => unreachable,
        }
    }
};

const Discoverer = struct {
    probe_ms: u64,
    pub fn discover(self: *Discoverer, gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
        return discoverModels(gpa, io, self.probe_ms, budget_ms);
    }
};

/// `model_catalog(force)` with its budgets as parameters (Rust: `get_with`'s
/// 20 s and `discover_models`' 10 s).
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

// ── the app-server probe (`discover_models`, `jsonrpc.rs`) ─────────────────

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// `binary_hint(exe)`: `"{path} (version {v|unknown})"`.
fn binaryHint(buf: []u8, io: Io, exe: []const u8) []const u8 {
    var vbuf: [128]u8 = undefined;
    const v = harness_version.binaryVersionString(io, exe, &vbuf) orelse "unknown";
    return std.fmt.bufPrint(buf, "{s} (version {s})", .{ exe, v }) catch buf[0..0];
}

/// The engine's environment minus what every agent child drops, without
/// `HARNESS_BUILD_WAIT_DIR` (`apply_run_environment(None)`), PATH composed.
fn childEnv(gpa: Allocator, io: Io, exe: []const u8) !Environ.Map {
    var env = try core.currentEnv(gpa);
    errdefer env.deinit();
    for (agent_proc.stripped_env) |k| _ = env.orderedRemove(k);
    _ = env.orderedRemove("HARNESS_BUILD_WAIT_DIR");
    const login = if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(gpa, io, &env);
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

/// `shutdown_child`: SIGTERM the group, SIGKILL after the grace (cut to the
/// caller's remaining budget), reap.
fn shutdown(proc: *agent_proc.AgentProc, io: Io, budget_at: i96) void {
    const left_ns = budget_at - nowNs(io);
    const left_ms: u64 = if (left_ns <= 0) 0 else @intCast(@divFloor(left_ns, std.time.ns_per_ms));
    proc.escalate(0, @intCast(@min(kill_grace_ms, left_ms)));
    _ = proc.wait();
    proc.destroy();
}

/// JSON with object keys sorted, as `serde_json::Value::to_string` writes it.
fn writeSorted(arena: Allocator, w: *std.Io.Writer, v: json.Value) !void {
    switch (v) {
        .object => |o| {
            const keys = try arena.dupe([]const u8, o.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            try w.writeByte('{');
            for (keys, 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}:", .{json.fmt(k, .{})});
                try writeSorted(arena, w, o.get(k).?);
            }
            try w.writeByte('}');
        },
        .array => |a| {
            try w.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeSorted(arena, w, item);
            }
            try w.writeByte(']');
        },
        else => try w.print("{f}", .{json.fmt(v, .{})}),
    }
}

fn sortedJson(arena: Allocator, v: json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeSorted(arena, &aw.writer, v);
    return aw.toOwnedSlice();
}

/// `ReauthProvider::from_acp`: only the complete, allowlisted contract.
fn reauthProvider(data: json.Value) bool {
    const kind = strGet(data, "kind") orelse return false;
    if (!std.mem.eql(u8, kind, "reauth_required")) return false;
    const provider = strGet(data, "provider") orelse return false;
    const command: []const u8, const args: []const []const u8 = if (std.mem.eql(u8, provider, "chatgpt-new"))
        .{ "graff", &.{ "login", "chatgpt-new" } }
    else if (std.mem.eql(u8, provider, "codex"))
        .{ "codex", &.{"login"} }
    else
        return false;
    const login = objGet(data, "login") orelse return false;
    const cmd = strGet(login, "command") orelse return false;
    if (!std.mem.eql(u8, cmd, command)) return false;
    const got = objGet(login, "args") orelse return false;
    if (got != .array or got.array.items.len != args.len) return false;
    for (got.array.items, args) |g, a| if (g != .string or !std.mem.eql(u8, g.string, a)) return false;
    return true;
}

const reauth_text = "ChatGPT sign-in expired or was rejected. Sign in again to continue.";

fn intGet(v: json.Value, key: []const u8) ?i64 {
    const x = objGet(v, key) orelse return null;
    return if (x == .integer) x.integer else null;
}

/// `response_error`: the message with its code and data, or the error's JSON.
fn responseError(arena: Allocator, err: json.Value) ![]const u8 {
    const message = strGet(err, "message") orelse return sortedJson(arena, err);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, message);
    if (intGet(err, "code")) |code| try out.print(arena, " (code {d})", .{code});
    if (objGet(err, "data")) |data| if (data != .null) {
        const detail = if (data == .string) data.string else try sortedJson(arena, data);
        if (detail.len > 0) {
            try out.appendSlice(arena, ": ");
            try out.appendSlice(arena, detail);
        }
    };
    return out.items;
}

/// `response_failure` with `RpcClient::request`'s `{method}: ` prefix on
/// protocol errors.
fn responseFailure(arena: Allocator, method: []const u8, err: json.Value) !Failure {
    const data = objGet(err, "data");
    if (intGet(err, "code") == -32000) if (data) |d| if (reauthProvider(d)) return Failure.other(reauth_text);
    if (intGet(err, "code") == -32603 and (data == null or data.? == .null)) {
        if (strGet(err, "message")) |m| if (std.mem.startsWith(u8, m, "chatgpt-new api error [token_expired]:")) return Failure.other(reauth_text);
    }
    return Failure.protocol("{s}: {s}", .{ method, try responseError(arena, err) });
}

/// `response_id`: integers, numeric strings and integral floats.
fn responseId(v: json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .float => |f| if (@floor(f) == f and f >= -9.2e18 and f <= 9.2e18) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

const Reply = union(enum) { ok: json.Value, err: Failure };

/// The probe's `RpcClient`: one request in flight, read synchronously.
const Rpc = struct {
    proc: *agent_proc.AgentProc,
    arena: Allocator,
    next_id: i64 = 0,
    /// stdout ended (`closed`): later requests fail at once.
    closed: bool = false,
    /// A stdin write failed: the writer is gone (`app-server stdin closed`).
    writer_dead: bool = false,

    fn send(self: *Rpc, line: []const u8) void {
        if (self.writer_dead) return;
        self.proc.writeLine(line) catch {
            self.writer_dead = true;
        };
    }

    fn request(self: *Rpc, method: []const u8, params: []const u8) !Reply {
        self.next_id += 1;
        const rid = self.next_id;
        if (self.closed) return .{ .err = Failure.protocol("{s}: app-server exited before responding", .{method}) };
        if (self.writer_dead) return .{ .err = Failure.protocol("{s}: app-server stdin closed", .{method}) };
        self.send(try std.fmt.allocPrint(self.arena, "{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":{f},\"params\":{s}}}", .{ rid, json.fmt(method, .{}), params }));
        while (try self.proc.readLine()) |raw| {
            // A read error ends the stream like EOF.
            if (!std.unicode.utf8ValidateSlice(raw)) break;
            const line = rustTrim(raw);
            if (line.len == 0) continue;
            const msg = json.parseFromSliceLeaky(json.Value, self.arena, line, parse_opts) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => continue,
            };
            if (msg != .object) continue;
            if (msg.object.get("jsonrpc")) |ver| if (ver != .string or !std.mem.eql(u8, ver.string, "2.0")) continue;
            // Server requests and notifications are not this probe's business.
            if (strGet(msg, "method") != null) continue;
            const idv = msg.object.get("id") orelse continue;
            const result = msg.object.get("result");
            const err = msg.object.get("error");
            if (result == null and err == null) continue;
            if ((responseId(idv) orelse continue) != rid) continue;
            if (err) |e| return .{ .err = try responseFailure(self.arena, method, e) };
            return .{ .ok = result.? };
        }
        self.closed = true;
        return .{ .err = Failure.protocol("{s}: app-server exited before responding", .{method}) };
    }
};

/// `initialize`'s params, as serde_json writes them (keys sorted).
pub fn initializeParams(arena: Allocator) ![]u8 {
    return std.fmt.allocPrint(arena, "{{\"capabilities\":{{\"experimentalApi\":true}},\"clientInfo\":{{\"name\":\"harness-native\",\"title\":\"Harness\",\"version\":{f}}}}}", .{json.fmt(client_version, .{})});
}

/// `model/list`'s params for one page.
pub fn modelListParams(arena: Allocator, cursor: ?[]const u8) ![]u8 {
    if (cursor) |c| return std.fmt.allocPrint(arena, "{{\"cursor\":{f},\"includeHidden\":false,\"limit\":20}}", .{json.fmt(c, .{})});
    return arena.dupe(u8, "{\"includeHidden\":false,\"limit\":20}");
}

/// The handshake and every `model/list` page; the models JSON (owned by
/// `gpa`) or a failure.
fn exchange(gpa: Allocator, rpc: *Rpc) !core.Discovered {
    const arena = rpc.arena;
    switch (try rpc.request("initialize", try initializeParams(arena))) {
        .err => |f| return .{ .err = f },
        .ok => {},
    }
    rpc.send("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    var models: std.ArrayList(Model) = .empty;
    var cursors: std.ArrayList([]const u8) = .empty;
    var cursor: ?[]const u8 = null;
    var default_id: ?[]const u8 = null;
    while (true) {
        const page_v = switch (try rpc.request("model/list", try modelListParams(arena, cursor))) {
            .err => |f| return .{ .err = f },
            .ok => |v| v,
        };
        const page = try parseModelListPage(arena, page_v);
        for (page.models) |pm| {
            if (indexOfModel(models.items, pm.model.id) != null) continue;
            if (pm.is_default and default_id == null) default_id = pm.model.id;
            try models.append(arena, pm.model);
        }
        const next = page.next_cursor orelse break;
        if (next.len == 0) break;
        var repeated = false;
        for (cursors.items) |c| if (std.mem.eql(u8, c, next)) {
            repeated = true;
        };
        if (repeated) break;
        try cursors.append(arena, next);
        cursor = next;
    }
    try promoteDefaultFamily(arena, models.items, default_id);
    if (models.items.len == 0) return .{ .err = Failure.discoveryFailure(.failed, "Codex returned an empty model catalog") };
    return .{ .ok = try core.modelsJson(gpa, models.items) };
}

/// `discover_models()`: a short-lived `codex app-server` and its paginated
/// `model/list`, bounded by `probe_ms` (Rust: 10 s) and the caller's
/// `budget_ms`; the child is stopped either way.
pub fn discoverModels(gpa: Allocator, io: Io, probe_ms: u64, budget_ms: u64) !core.Discovered {
    const started = nowNs(io);
    const exe = (try core.resolve_cli(gpa, io, id)) orelse return .{ .err = Failure.notInstalled(install_hint) };
    defer gpa.free(exe);
    var env = try childEnv(gpa, io, exe);
    defer env.deinit();
    const proc = agent_proc.AgentProc.spawn(gpa, io, &.{ exe, "app-server" }, null, &env, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .err = spawnFailure(io, exe, e) },
    };
    const budget_at = started + @as(i96, budget_ms) * std.time.ns_per_ms;
    const timeout_at = started + @as(i96, probe_ms) * std.time.ns_per_ms;
    // The probe's timeout ends it like `shutdown_child` (SIGTERM, SIGKILL
    // after the grace); the caller's budget kills it outright (`kill_on_drop`).
    {
        const term_ms = @min(probe_ms, budget_ms);
        const kill_ms = if (budget_ms <= probe_ms) budget_ms else @min(probe_ms + kill_grace_ms, budget_ms);
        proc.escalate(@intCast(term_ms), @intCast(kill_ms));
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rpc: Rpc = .{ .proc = proc, .arena = arena_state.allocator() };
    var result = exchange(gpa, &rpc) catch |e| {
        shutdown(proc, io, budget_at);
        return e;
    };
    shutdown(proc, io, budget_at);
    if (result == .err and nowNs(io) >= @min(timeout_at, budget_at)) {
        result = .{ .err = Failure.protocol("model discovery timed out", .{}) };
    }
    return result;
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

test "catalog_codex the fallback is newest first with service tiers" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 9), static_models.len);
    try testing.expectEqualStrings("gpt-6-astra", static_models[0].id);
    for (static_models) |m| {
        const has_tier = m.options.len == 1 and std.mem.eql(u8, m.options[0].id, "serviceTier");
        try testing.expectEqual(!std.mem.eql(u8, m.id, "gpt-daybreak-blue-latest"), has_tier);
    }
    try testing.expectEqualSlices([]const u8, &ultra_ladder, static_models[4].reasoning_levels);
    try testing.expectEqualSlices([]const u8, &xhigh_ladder, static_models[5].reasoning_levels);
    const fb = try harness().fallbackModels(gpa);
    defer gpa.free(fb);
    try testing.expect(std.mem.startsWith(u8, fb, "[{\"id\":\"gpt-6-astra\",\"label\":\"GPT-6-Astra\",\"description\":\"Our most capable model for complex, demanding work.\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultra\"],\"options\":[{\"id\":\"serviceTier\",\"label\":\"Service Tier\",\"choices\":[{\"id\":\"default\",\"label\":\"Standard\"},{\"id\":\"fast\",\"label\":\"Fast\"}],\"defaultChoice\":\"default\"}]},"));
    try testing.expect(std.mem.indexOf(u8, fb, "{\"id\":\"gpt-daybreak-blue-latest\",\"label\":\"Daybreak Blue\",\"description\":\"Frontier model for defensive cybersecurity work\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultra\"],\"options\":[]}") != null);
}

test "catalog_codex promote_default_family keeps a generation together" {
    var models = [_]Model{
        .{ .id = "gpt-6-astra", .label = "Astra" },
        .{ .id = "gpt-5.6-terra", .label = "Terra" },
        .{ .id = "gpt-5.6-sol", .label = "Sol" },
        .{ .id = "gpt-5.5", .label = "5.5" },
    };
    try promoteDefaultFamily(testing.allocator, &models, "gpt-5.6-sol");
    const want = [_][]const u8{ "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra", "gpt-5.5" };
    for (models, want) |m, w| try testing.expectEqualStrings(w, m.id);
    // An unknown default falls back to the first model's family.
    try promoteDefaultFamily(testing.allocator, &models, "missing");
    for (models, want) |m, w| try testing.expectEqualStrings(w, m.id);
    try testing.expectEqualStrings("gpt", modelFamily("gpt-5.5"));
    try testing.expectEqualStrings("gpt-5.6", modelFamily("openai/gpt-5.6-sol"));
    try testing.expectEqualStrings("o3", modelFamily("o3"));
}

test "catalog_codex model/list pages: hidden rows, efforts, tiers and upgrades" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, arena,
        \\{"data":[
        \\ {"model":"gpt-x","displayName":" X ","description":" Fast ","upgrade":"gpt-y","hidden":false,"isDefault":true,
        \\  "supportedReasoningEfforts":[{"reasoningEffort":"low"},"high",{"reasoningEffort":"turbo"},"none",{"other":1}],
        \\  "serviceTiers":[{"id":"priority","name":""},{"id":"fast","name":"Dup"},{"id":"flex","name":"Flexible"},{"name":"no id"}],
        \\  "additionalSpeedTiers":["ultrafast","flex",7],"defaultServiceTier":"priority"},
        \\ {"id":"gpt-hidden","hidden":true},
        \\ {"model":"  ","id":"ignored-because-model-is-blank"},
        \\ {"model":7,"id":"gpt-by-id","upgrade":"gpt-z","serviceTiers":[],"defaultServiceTier":"flex"},
        \\ {"model":"gpt-plain","description":"","displayName":"","additionalSpeedTiers":["custom"],"defaultServiceTier":"other"}
        \\],"nextCursor":"c2"}
    , parse_opts);
    const page = try parseModelListPage(arena, v);
    try testing.expectEqualStrings("c2", page.next_cursor.?);
    try testing.expectEqual(@as(usize, 3), page.models.len);
    const x = page.models[0];
    try testing.expect(x.is_default);
    try testing.expectEqualStrings("gpt-x", x.model.id);
    try testing.expectEqualStrings("X", x.model.label);
    try testing.expectEqualStrings("Fast (upgrade: gpt-y)", x.model.description.?);
    try testing.expectEqualSlices([]const u8, &.{ "low", "high" }, x.model.reasoning_levels);
    const tier = x.model.options[0];
    try testing.expectEqualStrings("fast", tier.default_choice);
    const want_tiers = [_][2][]const u8{ .{ "default", "Standard" }, .{ "fast", "Fast" }, .{ "flex", "Flexible" }, .{ "ultrafast", "Ultra Fast" } };
    try testing.expectEqual(want_tiers.len, tier.choices.len);
    for (tier.choices, want_tiers) |c, w| {
        try testing.expectEqualStrings(w[0], c.id);
        try testing.expectEqualStrings(w[1], c.label);
    }
    const by_id = page.models[1].model;
    try testing.expectEqualStrings("gpt-by-id", by_id.id);
    try testing.expectEqualStrings("(upgrade: gpt-z)", by_id.description.?);
    try testing.expectEqual(@as(usize, 0), by_id.options.len);
    const plain = page.models[2].model;
    try testing.expectEqualStrings("gpt-plain", plain.label);
    try testing.expect(plain.description == null);
    try testing.expectEqualStrings("default", plain.options[0].default_choice);
    try testing.expectEqualStrings("custom", plain.options[0].choices[1].label);
}

test "catalog_codex JSON-RPC errors read like Rust's" {
    resetForTests();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [512]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "{\"code\":-32600,\"message\":\"unauthorized\",\"data\":{\"z\":1,\"a\":[true,null]}}", "harness protocol error: model/list: unauthorized (code -32600): {\"a\":[true,null],\"z\":1}" },
        .{ "{\"message\":\"boom\",\"data\":\"detail\"}", "harness protocol error: model/list: boom: detail" },
        .{ "{\"message\":\"boom\",\"code\":1.5,\"data\":\"\"}", "harness protocol error: model/list: boom" },
        .{ "{\"zeta\":1,\"alpha\":\"x\"}", "harness protocol error: model/list: {\"alpha\":\"x\",\"zeta\":1}" },
        .{ "\"bare\"", "harness protocol error: model/list: \"bare\"" },
        .{ "{\"code\":-32000,\"message\":\"x\",\"data\":{\"kind\":\"reauth_required\",\"provider\":\"codex\",\"login\":{\"command\":\"codex\",\"args\":[\"login\"]}}}", reauth_text },
        .{ "{\"code\":-32000,\"message\":\"x\",\"data\":{\"kind\":\"reauth_required\",\"provider\":\"codex\",\"login\":{\"command\":\"rm\",\"args\":[\"login\"]}}}", "harness protocol error: model/list: x (code -32000): {\"kind\":\"reauth_required\",\"login\":{\"args\":[\"login\"],\"command\":\"rm\"},\"provider\":\"codex\"}" },
        .{ "{\"code\":-32603,\"message\":\"chatgpt-new api error [token_expired]: gone\"}", reauth_text },
    };
    for (cases) |c| {
        const v = try json.parseFromSliceLeaky(json.Value, arena, c[0], parse_opts);
        const f = try responseFailure(arena, "model/list", v);
        try testing.expectEqualStrings(c[1], f.display(&buf));
    }
    try testing.expectEqual(@as(?i64, 5), responseId(.{ .string = "5" }));
    try testing.expectEqual(@as(?i64, 5), responseId(.{ .float = 5.0 }));
    try testing.expectEqual(@as(?i64, null), responseId(.{ .float = 5.5 }));
    try testing.expectEqualStrings("{\"capabilities\":{\"experimentalApi\":true},\"clientInfo\":{\"name\":\"harness-native\",\"title\":\"Harness\",\"version\":\"0.0.0\"}}", try initializeParams(arena));
    try testing.expectEqualStrings("{\"cursor\":\"c\\\"2\",\"includeHidden\":false,\"limit\":20}", try modelListParams(arena, "c\"2"));
}

// A mock app server: answers `--version`, records argv, stdin and a call
// count, then runs `body` (a shell snippet with `$D` set).
const Mock = struct {
    tmp: testing.TmpDir,
    dir: []u8,
    script: []u8,
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
        try tmp.dir.createDirPath(io, "home/.codex");
        try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = try mockScript(gpa, dir, body), .flags = .{ .permissions = .executable_file } });
        const script = try std.fs.path.join(gpa, &.{ dir, "codex" });
        errdefer gpa.free(script);
        const home = try std.fs.path.join(gpa, &.{ dir, "home" });
        defer gpa.free(home);
        var env = Environ.Map.init(gpa);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        try env.put("HARNESS_BUILD_WAIT_DIR", "synthetic/other-run");
        return .{ .tmp = tmp, .dir = dir, .script = script, .env = env };
    }

    var script_buf: [16 * 1024]u8 = undefined;

    fn mockScript(_: Allocator, dir: []const u8, body: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&script_buf,
            \\#!/bin/sh
            \\D='{s}'
            \\if [ "$1" = "--version" ]; then echo "codex-cli 0.160.0"; exit 0; fi
            \\echo "$@" > "$D/argv"
            \\echo x >> "$D/calls"
            \\echo $$ > "$D/pid"
            \\echo "$PATH|${{HARNESS_BUILD_WAIT_DIR-unset}}" > "$D/env"
            \\: > "$D/stdin"
            \\reply() {{ IFS= read -r line || exit 0; printf '%s\n' "$line" >> "$D/stdin"; }}
            \\{s}
            \\
        , .{ dir, body });
    }

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

    fn expectGone(self: *Mock) !void {
        // Process ids are handles on Windows; the mock scripts are Unix-only.
        if (comptime builtin.os.tag == .windows) return;
        const t = try self.read("pid");
        defer testing.allocator.free(t);
        const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, t, " \n"), 10);
        try testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @fromBackingInt(@intCast(0))));
    }
};

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

test "catalog_codex not installed reads as Rust's NotInstalled" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init("exit 0");
    defer m.deinit();
    m.activate();
    Mock.cli = null;
    const want = "harness binary not found: " ++ install_hint;
    const h = harness();
    try testing.expectEqualStrings("codex", h.id);
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(want, (try h.modelContext(gpa, io)).err.display(&buf));
    try expectFailure(try h.modelCatalog(gpa, io, false), .missing_executable, want);
    Mock.cli = "/nonexistent/harness-codex-mock";
    const d = try discoverModels(gpa, io, 1000, 1000);
    try testing.expectEqualStrings("harness binary not found: /nonexistent/harness-codex-mock (version unknown)", d.err.display(&buf));
    try testing.expectEqual(core.Code.missing_executable, d.err.code);
}

test "catalog_codex live catalog across pages, then cached" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(
        \\reply
        \\echo 'banner, not JSON'
        \\echo '{"jsonrpc":"1.0","id":1,"result":{}}'
        \\echo '{"jsonrpc":"2.0","method":"configWarning","params":{}}'
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"synthetic"}}'
        \\reply
        \\reply
        \\echo '{"jsonrpc":"2.0","id":99,"method":"item/tool/requestUserInput","params":{}}'
        \\echo '{"jsonrpc":"2.0","id":7,"result":{"data":[]}}'
        \\echo '{"jsonrpc":"2.0","id":"2","result":{"data":[{"model":"gpt-6-astra","displayName":"GPT-6-Astra","supportedReasoningEfforts":[{"reasoningEffort":"high"}]},{"model":"gpt-5.6-terra","displayName":"Terra"}],"nextCursor":"p2"}}'
        \\reply
        \\echo '{"jsonrpc":"2.0","id":3.0,"result":{"data":[{"model":"gpt-5.6-sol","displayName":"Sol","isDefault":true,"serviceTiers":[{"id":"priority","name":"Priority"}]},{"model":"gpt-6-astra","displayName":"Dup"},{"model":"gpt-secret","hidden":true}],"nextCursor":"p2"}}'
        \\exec cat > /dev/null
    );
    defer m.deinit();
    m.activate();
    const h = harness();
    const r = try h.modelCatalog(gpa, io, false);
    const c = r.ok;
    defer gpa.free(c.models);
    try testing.expectEqual(core.Source.live, c.source);
    try testing.expectEqualStrings(
        "[{\"id\":\"gpt-5.6-sol\",\"label\":\"Sol\",\"reasoningLevels\":[],\"options\":[{\"id\":\"serviceTier\",\"label\":\"Service Tier\",\"choices\":[{\"id\":\"default\",\"label\":\"Standard\"},{\"id\":\"fast\",\"label\":\"Priority\"}],\"defaultChoice\":\"default\"}]}," ++
            "{\"id\":\"gpt-5.6-terra\",\"label\":\"Terra\",\"reasoningLevels\":[],\"options\":[]}," ++
            "{\"id\":\"gpt-6-astra\",\"label\":\"GPT-6-Astra\",\"reasoningLevels\":[\"high\"],\"options\":[]}]",
        c.models,
    );
    const argv = try m.read("argv");
    defer gpa.free(argv);
    try testing.expectEqualStrings("app-server\n", argv);
    const stdin = try m.read("stdin");
    defer gpa.free(stdin);
    try testing.expectEqualStrings(
        "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"capabilities\":{\"experimentalApi\":true},\"clientInfo\":{\"name\":\"harness-native\",\"title\":\"Harness\",\"version\":\"0.0.0\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n" ++
            "{\"id\":2,\"jsonrpc\":\"2.0\",\"method\":\"model/list\",\"params\":{\"includeHidden\":false,\"limit\":20}}\n" ++
            "{\"id\":3,\"jsonrpc\":\"2.0\",\"method\":\"model/list\",\"params\":{\"cursor\":\"p2\",\"includeHidden\":false,\"limit\":20}}\n",
        stdin,
    );
    const child_env = try m.read("env");
    defer gpa.free(child_env);
    const want_env = try std.fmt.allocPrint(gpa, "{s}:/usr/bin:/bin|unset\n", .{m.dir});
    defer gpa.free(want_env);
    try testing.expectEqualStrings(want_env, child_env);
    try m.expectGone();

    const again = try h.modelCatalog(gpa, io, false);
    defer gpa.free(again.ok.models);
    try testing.expectEqual(core.Source.cache, again.ok.source);
    try testing.expectEqual(@as(usize, 1), try m.calls());
    // A new login changes the context and probes again.
    try m.tmp.dir.writeFile(io, .{ .sub_path = "home/.codex/auth.json", .data = "synthetic-account" });
    const relog = try h.modelCatalog(gpa, io, false);
    defer gpa.free(relog.ok.models);
    try testing.expectEqual(core.Source.live, relog.ok.source);
    try testing.expectEqual(@as(usize, 2), try m.calls());
    var ctx = (try h.modelContext(gpa, io)).ok;
    defer ctx.deinit(gpa);
    try testing.expectEqualStrings("0.160.0", ctx.binary_version.?);
}

test "catalog_codex auth and rpc error replies fail like Rust" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(
        \\reply
        \\echo '{"jsonrpc":"2.0","id":1,"result":{}}'
        \\reply
        \\reply
        \\echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Not logged in: run codex login"}}'
        \\exec cat > /dev/null
    );
    defer m.deinit();
    m.activate();
    const h = harness();
    const want = "model discovery auth_required: harness protocol error: model/list: Not logged in: run codex login (code -32600)";
    try expectFailure(try h.modelCatalog(gpa, io, false), .auth_required, want);
    try testing.expectEqual(@as(usize, 1), try m.calls());
    // Cooling down until forced.
    try expectFailure(try h.modelCatalog(gpa, io, false), .auth_required, want);
    try testing.expectEqual(@as(usize, 1), try m.calls());
    try expectFailure(try h.modelCatalog(gpa, io, true), .auth_required, want);
    try testing.expectEqual(@as(usize, 2), try m.calls());
    // `list` does not offer Codex's snapshot to a signed-out CLI.
    const l = try core.list(gpa, io, null, h, true);
    defer l.deinit(gpa);
    try testing.expect(l == .err and l.err.code == .auth_required);

    // An initialize rejection names its method.
    resetForTests();
    try m.tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = try Mock.mockScript(gpa, m.dir,
        \\reply
        \\echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"unknown method"}}'
        \\exec cat > /dev/null
    ), .flags = .{ .permissions = .executable_file } });
    const d = try discoverModels(gpa, io, 5000, 5000);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: initialize: unknown method (code -32601)", d.err.display(&buf));
}

test "catalog_codex malformed output, early exit and an empty catalog fail" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(
        \\reply
        \\echo '{"jsonrpc":"2.0","id":1,"result":{}}'
        \\reply
        \\reply
        \\echo 'garbage {'
        \\echo '{"jsonrpc":"2.0","id":2}'
        \\exit 1
    );
    defer m.deinit();
    m.activate();
    const d = try discoverModels(gpa, io, 5000, 5000);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: model/list: app-server exited before responding", d.err.display(&buf));
    try testing.expectEqual(core.Code.failed, d.err.code);
    // Through the cache: transient, three attempts, then a failure.
    try expectFailure(try harness().modelCatalog(gpa, io, false), .failed, "model discovery failed: harness protocol error: model/list: app-server exited before responding");
    try testing.expectEqual(@as(usize, 4), try m.calls());

    // Invalid UTF-8 ends the stream like EOF.
    try m.tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = try Mock.mockScript(gpa, m.dir,
        \\reply
        \\printf '\377\376\n'
        \\echo '{"jsonrpc":"2.0","id":1,"result":{}}'
        \\exec cat > /dev/null
    ), .flags = .{ .permissions = .executable_file } });
    const u = try discoverModels(gpa, io, 5000, 5000);
    try testing.expectEqualStrings("harness protocol error: initialize: app-server exited before responding", u.err.display(&buf));

    // Every row hidden: an empty catalog.
    resetForTests();
    try m.tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = try Mock.mockScript(gpa, m.dir,
        \\reply
        \\echo '{"jsonrpc":"2.0","id":1,"result":{}}'
        \\reply
        \\reply
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"data":[{"model":"gpt-secret","hidden":true}],"nextCursor":""}}'
        \\exec cat > /dev/null
    ), .flags = .{ .permissions = .executable_file } });
    const e = try discoverModels(gpa, io, 5000, 5000);
    try testing.expectEqualStrings("model discovery failed: Codex returned an empty model catalog", e.err.display(&buf));
    try m.expectGone();
}

test "catalog_codex a hung app server is killed at the probe timeout and the budget" {
    const gpa = testing.allocator;
    const io = testing.io;
    var m = try Mock.init(
        \\reply
        \\trap '' TERM
        \\sleep 30
    );
    defer m.deinit();
    m.activate();
    // The probe's own timeout; SIGTERM is ignored, SIGKILL follows (cut to
    // the budget). A fresh script can take a few hundred ms to start.
    var started = Io.Clock.awake.now(io).nanoseconds;
    const d = try discoverModels(gpa, io, 1000, 2500);
    var elapsed = Io.Clock.awake.now(io).nanoseconds - started;
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: model discovery timed out", d.err.display(&buf));
    try testing.expectEqual(core.Code.timeout, d.err.code);
    try testing.expect(elapsed >= 2 * std.time.ns_per_s and elapsed < 15 * std.time.ns_per_s);
    try m.expectGone();

    try m.tmp.dir.deleteFile(io, "pid");
    started = Io.Clock.awake.now(io).nanoseconds;
    try expectFailure(try modelCatalogWithTimeout(gpa, io, false, 1500, 1000), .timeout, "model discovery timeout: Harness model discovery timed out");
    elapsed = Io.Clock.awake.now(io).nanoseconds - started;
    try testing.expect(elapsed < 15 * std.time.ns_per_s);
    try m.expectGone();
    try testing.expectEqual(@as(usize, 2), try m.calls());
}
