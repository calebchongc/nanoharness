//! graff's live model catalog, ported from `crates/harness/src/acp/graff_models.rs`
//! and graff's branches of `crates/harness/src/acp/mod.rs`
//! (`model_context`, `model_catalog`, `models`, `configure_adapter_environment`):
//!
//! - `discover`: graff's `graff/models` ACP extension (initialize →
//!   session/new in a private scratch folder → `graff/models`), whose
//!   authenticated rows become `provider/name` models with their own effort
//!   ladders, maker, billing and context; the session's current model first.
//! - Older graff without the extension (`-32601`): the legacy `graff route` +
//!   `graff models` listing, ranked like Rust.
//! - graff is live-only: its credentials may live in the OS keychain, so it
//!   has no cache context (`ContextResult.none`), no in-memory cache and no
//!   static rows.
//!
//! Std-only, testable with `zig test catalog_graff.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const core = @import("catalog_core.zig");
const acp = @import("catalog_acp.zig");
const Failure = core.Failure;
const Model = core.Model;

const spec = &acp.specs.graff;

// ── engine settings graff's launch reads ───────────────────────────────────

/// Settings → draft subagents (`with_graff_draft_subagents`).
pub var draft_subagents: std.atomic.Value(bool) = .init(false);
/// Settings → graff's compaction point, percent; 0 = graff's default
/// (`with_graff_compact_at`).
pub var compact_at: std.atomic.Value(u8) = .init(0);

var device_mutex: Io.Mutex = .init;
var device_buf: [256]u8 = undefined;
var device_len: usize = 0;

/// `graff_client::set_device_name`: the name this computer has in Harness.
pub fn setDeviceName(io: Io, name: []const u8) void {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    device_mutex.lockUncancelable(io);
    defer device_mutex.unlock(io);
    device_len = @min(trimmed.len, device_buf.len);
    @memcpy(device_buf[0..device_len], trimmed[0..device_len]);
}

var timeout_ms: std.atomic.Value(u64) = .init(acp.default_discovery_timeout_ms);

/// Tests (`with_model_discovery_timeout`): the probe bound.
pub fn setDiscoveryTimeoutMs(ms: u64) void {
    timeout_ms.store(ms, .release);
}

pub fn resetForTests() void {
    timeout_ms.store(acp.default_discovery_timeout_ms, .release);
    draft_subagents.store(false, .release);
    compact_at.store(0, .release);
    device_len = 0;
}

/// `configure_adapter_environment` for graff plus `graff_client::env()`.
fn graffEnv(arena: Allocator, io: Io, env: *Environ.Map) anyerror!void {
    try env.put("GRAFF_AUTO_ISOLATE", "0");
    if (env.get("GRAFF_CODEX_WS") == null) try env.put("GRAFF_CODEX_WS", "off");
    const env_draft = if (env.get("GRAFF_ACP_DRAFT_SUBAGENTS")) |v| std.mem.eql(u8, v, "1") else false;
    if (env_draft or draft_subagents.load(.acquire)) try env.put("GRAFF_ACP_DRAFT_SUBAGENTS", "1");
    const pct = compact_at.load(.acquire);
    if (env.get("GRAFF_COMPACT_PCT") == null and pct != 0) try env.put("GRAFF_COMPACT_PCT", try std.fmt.allocPrint(arena, "{d}", .{pct}));
    if (env.get("GRAFF_HOST_APP") == null) try env.put("GRAFF_HOST_APP", try std.fmt.allocPrint(arena, "harness/{s}", .{acp.client_version}));
    if (env.get("GRAFF_DEVICE_NAME") == null) {
        device_mutex.lockUncancelable(io);
        defer device_mutex.unlock(io);
        if (device_len > 0) try env.put("GRAFF_DEVICE_NAME", device_buf[0..device_len]);
    }
}

// ── pure rules ─────────────────────────────────────────────────────────────

/// `normalize_legacy_id`: `provider:model` → `provider/model` for known
/// providers; anything else unchanged.
pub fn normalizeLegacyId(arena: Allocator, id: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, id, ':') orelse return id;
    const provider = id[0..colon];
    const name = id[colon + 1 ..];
    if (name.len == 0) return id;
    for ([_][]const u8{ "anthropic", "claude-agent", "codegraff", "codex", "deepseek", "openai", "cerebras", "kimi", "xai", "xiaomi", "openrouter", "fugu", "mlx", "lmstudio" }) |known| {
        if (std.mem.eql(u8, provider, known)) return std.fmt.allocPrint(arena, "{s}/{s}", .{ provider, name });
    }
    return id;
}

/// `harness_proto::context_label`.
pub fn contextLabel(arena: Allocator, tokens: u64) ![]const u8 {
    if (tokens >= 1 << 10 and std.math.isPowerOfTwo(tokens)) {
        return if (tokens >= 1 << 20) std.fmt.allocPrint(arena, "{d}M", .{tokens >> 20}) else std.fmt.allocPrint(arena, "{d}k", .{tokens >> 10});
    }
    if (tokens < 1_000) return std.fmt.allocPrint(arena, "{d}", .{tokens});
    const t: u128 = tokens;
    const thousands = (t + 500) / 1_000;
    if (thousands < 1_000) return std.fmt.allocPrint(arena, "{d}k", .{thousands});
    const hundredths = (t + 5_000) / 10_000;
    const whole = hundredths / 100;
    const frac = hundredths % 100;
    if (frac == 0) return std.fmt.allocPrint(arena, "{d}M", .{whole});
    if (frac % 10 == 0) return std.fmt.allocPrint(arena, "{d}.{d}M", .{ whole, frac / 10 });
    return std.fmt.allocPrint(arena, "{d}.{d:0>2}M", .{ whole, frac });
}

/// `describe`: `codex · 272k context`, or the provider alone.
fn describe(arena: Allocator, provider: []const u8, context: ?u64) ![]const u8 {
    const c = context orelse return provider;
    return std.fmt.allocPrint(arena, "{s} · {s} context", .{ provider, try contextLabel(arena, c) });
}

/// `no_authenticated_models`.
pub fn noAuthenticatedModels() Failure {
    return Failure.discoveryFailure(.auth_required, "graff has no reachable provider — run `graff login`");
}

pub const ModelsOutcome = union(enum) { ok: []Model, err: Failure };

/// `models_from_acp`: authenticated rows only, one per (provider, name),
/// the session's current model first.
pub fn modelsFromAcp(arena: Allocator, catalog: json.Value) !ModelsOutcome {
    const rows = acp.arrField(catalog, "models") orelse return .{ .err = Failure.protocol("graff/models omitted its model rows", .{}) };
    const current = acp.field(catalog, "current");
    var seen: std.ArrayList([2][]const u8) = .empty;
    var out: std.ArrayList(Model) = .empty;
    rows: for (rows) |row| {
        const auth = acp.field(row, "authenticated") orelse continue;
        if (auth != .bool or !auth.bool) continue;
        const provider = acp.strField(row, "provider") orelse continue;
        const name = acp.strField(row, "name") orelse continue;
        if (provider.len == 0 or name.len == 0) continue;
        for (seen.items) |s| if (std.mem.eql(u8, s[0], provider) and std.mem.eql(u8, s[1], name)) continue :rows;
        try seen.append(arena, .{ provider, name });
        var levels: std.ArrayList([]const u8) = .empty;
        if (acp.arrField(row, "effortLevels")) |values| for (values) |v| {
            if (v != .string) continue;
            const level = acp.reasoningFromValue(v.string) orelse continue;
            const level_name = acp.levelName(level);
            const dup = for (levels.items) |l| {
                if (std.mem.eql(u8, l, level_name)) break true;
            } else false;
            if (!dup) try levels.append(arena, level_name);
        };
        const context = acp.asU64(acp.field(row, "context"));
        const model: Model = .{
            .id = try std.fmt.allocPrint(arena, "{s}/{s}", .{ provider, name }),
            .label = name,
            .description = try describe(arena, provider, context),
            .reasoning_levels = levels.items,
            .maker = nonEmpty(acp.strField(row, "maker")),
            .billing = nonEmpty(acp.strField(row, "cost")),
            .context = context,
        };
        const is_current = if (current) |c|
            optIs(acp.strField(c, "provider"), provider) and optIs(acp.strField(c, "model"), name)
        else
            false;
        if (is_current) try out.insert(arena, 0, model) else try out.append(arena, model);
    }
    if (out.items.len == 0) return .{ .err = noAuthenticatedModels() };
    return .{ .ok = out.items };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

fn optIs(a: ?[]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, a.?, b);
}

/// `extension_unavailable`: only an unknown `graff/models` method may fall
/// back to the legacy listing.
pub fn extensionUnavailable(f: *const Failure) bool {
    if (f.discovery) return false;
    const m = f.message();
    return std.mem.startsWith(u8, m, "harness protocol error: graff/models:") and std.mem.endsWith(u8, m, "(code -32601)");
}

/// Rust's `str::lines`: `\n`-separated, a trailing `\r` dropped.
const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    fn init(text: []const u8) Lines {
        const t = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
        var l: Lines = .{ .it = std.mem.splitScalar(u8, t, '\n') };
        if (text.len == 0) _ = l.it.next();
        return l;
    }
    fn next(self: *Lines) ?[]const u8 {
        const line = self.it.next() orelse return null;
        return std.mem.trimEnd(u8, line, "\r");
    }
};

const ws = " \t\r\n";

pub const Route = struct {
    default: ?[]const u8,
    providers: []const []const u8,
    advertised: []const []const u8,
};

/// `parse_route`: the session default, reachable providers in table order,
/// and the frontier/mid/small seats they advertise.
pub fn parseRoute(arena: Allocator, text: []const u8) !Route {
    var default: ?[]const u8 = null;
    var lines = Lines.init(text);
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, ws);
        if (!std.mem.startsWith(u8, t, "session default:")) continue;
        var parts = std.mem.tokenizeAny(u8, t["session default:".len..], ws);
        const seat = parts.next() orelse continue;
        default = if (std.mem.indexOfScalar(u8, seat, '/')) |slash| seat[slash + 1 ..] else seat;
        break;
    }
    var providers: std.ArrayList([]const u8) = .empty;
    var advertised: std.ArrayList([]const u8) = .empty;
    lines = Lines.init(text);
    var in_table = false;
    while (lines.next()) |line| {
        if (!in_table) {
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, ws), "provider")) in_table = true;
            continue;
        }
        if (std.mem.trim(u8, line, ws).len == 0) break;
        const row = try parseProviderRow(arena, line) orelse continue;
        try providers.append(arena, row.provider);
        for (row.models) |m| {
            const dup = for (advertised.items) |a| {
                if (std.mem.eql(u8, a, m)) break true;
            } else false;
            if (!dup) try advertised.append(arena, m);
        }
    }
    return .{ .default = default, .providers = providers.items, .advertised = advertised.items };
}

const ProviderRow = struct { provider: []const u8, models: []const []const u8 };

fn parseProviderRow(arena: Allocator, line: []const u8) !?ProviderRow {
    var parts = std.mem.tokenizeAny(u8, line, ws);
    const provider = parts.next() orelse return null;
    if (std.mem.eql(u8, provider, "usage:")) return null;
    var saw_billing = false;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "metered") or std.mem.eql(u8, part, "subscription") or std.mem.eql(u8, part, "unpriced")) {
            saw_billing = true;
            break;
        }
    }
    if (!saw_billing) return .{ .provider = provider, .models = &.{} };
    var rest: std.ArrayList(u8) = .empty;
    while (parts.next()) |part| {
        if (rest.items.len > 0) try rest.append(arena, ' ');
        try rest.appendSlice(arena, part);
    }
    if (rest.items.len == 0 or rest.items[0] == '(') return .{ .provider = provider, .models = &.{} };
    var models: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, rest.items, " / ");
    while (it.next()) |raw| {
        const m = std.mem.trim(u8, raw, ws);
        if (m.len == 0 or std.mem.eql(u8, m, "-")) continue;
        try models.append(arena, m);
    }
    return .{ .provider = provider, .models = models.items };
}

pub const Seat = struct { provider: []const u8, name: []const u8, context: ?u64 };

/// `parse_models_listing`: `provider:` headers, then `name ctx` rows.
pub fn parseModelsListing(arena: Allocator, text: []const u8) ![]Seat {
    var provider: []const u8 = "";
    var seats: std.ArrayList(Seat) = .empty;
    var lines = Lines.init(text);
    while (lines.next()) |line| {
        if (parseListingProvider(line)) |name| {
            provider = name;
            continue;
        }
        if (provider.len == 0) continue;
        const m = parseListingModel(line) orelse continue;
        if (std.mem.indexOfScalar(u8, m.name, ':') != null) continue;
        try seats.append(arena, .{ .provider = provider, .name = m.name, .context = m.context });
    }
    return seats.items;
}

fn parseListingProvider(raw: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw, ws);
    if (!std.mem.endsWith(u8, line, ":")) return null;
    const head = line[0 .. line.len - 1];
    if (head.len == 0 or std.mem.indexOf(u8, head, " ctx") != null) return null;
    const cut = std.mem.indexOf(u8, head, " (") orelse head.len;
    return std.mem.trim(u8, head[0..cut], ws);
}

fn parseListingModel(raw: []const u8) ?struct { name: []const u8, context: ?u64 } {
    const line = std.mem.trim(u8, raw, ws);
    if (line.len == 0 or std.mem.endsWith(u8, line, ":")) return null;
    var parts = std.mem.tokenizeAny(u8, line, ws);
    const name = parts.next() orelse return null;
    var context: ?u64 = null;
    if (parts.next()) |n| if (std.fmt.parseInt(u64, n, 10)) |v| {
        if (parts.next()) |unit| if (std.mem.eql(u8, unit, "ctx")) {
            context = v;
        };
    } else |_| {};
    return .{ .name = name, .context = context };
}

/// `promote_missing_codex_seats`.
pub fn promoteMissingCodexSeats(arena: Allocator, seats: *std.ArrayList(Seat), providers: []const []const u8) !void {
    const codex = for (providers) |p| {
        if (std.mem.eql(u8, p, "codex")) break true;
    } else false;
    if (!codex) return;
    var missing: std.ArrayList([]const u8) = .empty;
    for (seats.items) |seat| {
        if (!std.mem.eql(u8, seat.provider, "openrouter")) continue;
        if (!std.mem.startsWith(u8, seat.name, "openai/")) continue;
        const name = seat.name["openai/".len..];
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
        const have = for (seats.items) |s| {
            if (std.mem.eql(u8, s.provider, "codex") and std.mem.eql(u8, s.name, name)) break true;
        } else false;
        if (!have) try missing.append(arena, name);
    }
    for (missing.items) |name| try seats.append(arena, .{ .provider = "codex", .name = name, .context = 272_000 });
}

fn isAlias(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "/:") != null;
}

/// `close_sibling`: `grok-4.7` beside a `grok-4.6` default.
fn closeSibling(default: []const u8, name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, default, '.') orelse return false;
    const prefix = default[0..dot];
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    return !std.mem.eql(u8, name, default) and std.mem.indexOfScalar(u8, rest, '-') == null;
}

fn providerPref(provider: []const u8, table_rank: usize) usize {
    for ([_][]const u8{ "codex", "xai", "openai", "anthropic", "kimi", "codegraff" }, 0..) |home, i| {
        if (std.mem.eql(u8, home, provider)) return i;
    }
    return 100 + table_rank;
}

const SeatRank = struct {
    default: ?[]const u8,
    advertised: []const []const u8,

    fn key(r: SeatRank, s: Seat) [4]bool {
        const is_default = r.default != null and std.mem.eql(u8, s.name, r.default.?);
        const sibling = if (r.default) |d| closeSibling(d, s.name) else false;
        const adv = for (r.advertised) |a| {
            if (std.mem.eql(u8, a, s.name)) break true;
        } else false;
        // (name != default, !sibling-or-no-default, !advertised, is_alias)
        return .{ !is_default, r.default == null or !sibling, !adv, isAlias(s.name) };
    }

    fn lessThan(r: SeatRank, a: Seat, b: Seat) bool {
        const ka = r.key(a);
        const kb = r.key(b);
        for (ka, kb) |x, y| if (x != y) return !x;
        const pa = providerPref(a.provider, 0);
        const pb = providerPref(b.provider, 0);
        if (pa != pb) return pa < pb;
        switch (std.mem.order(u8, a.name, b.name)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        return std.mem.order(u8, a.provider, b.provider) == .lt;
    }
};

/// `models_from_seats`: one row per seat on a reachable provider, ranked;
/// a repeated bare name gets a `provider:name` id.
pub fn modelsFromSeats(arena: Allocator, seats: []const Seat, providers: []const []const u8, default: ?[]const u8, advertised: []const []const u8) ![]Model {
    var ranked: std.ArrayList(Seat) = .empty;
    for (seats) |s| for (providers) |p| if (std.mem.eql(u8, p, s.provider)) {
        try ranked.append(arena, s);
        break;
    };
    std.mem.sort(Seat, ranked.items, SeatRank{ .default = default, .advertised = advertised }, SeatRank.lessThan);
    var out: std.ArrayList(Model) = .empty;
    var used: std.ArrayList([]const u8) = .empty;
    seats: for (ranked.items, 0..) |s, i| {
        for (ranked.items[0..i]) |prev| if (std.mem.eql(u8, prev.provider, s.provider) and std.mem.eql(u8, prev.name, s.name)) continue :seats;
        const name_used = for (used.items) |u| {
            if (std.mem.eql(u8, u, s.name)) break true;
        } else false;
        const id = if (name_used) try std.fmt.allocPrint(arena, "{s}:{s}", .{ s.provider, s.name }) else s.name;
        if (!name_used) try used.append(arena, s.name);
        try out.append(arena, .{ .id = id, .label = s.name, .description = try describe(arena, s.provider, s.context), .context = s.context });
    }
    return out.items;
}

// ── discovery ──────────────────────────────────────────────────────────────

const StdoutResult = union(enum) { ok: []const u8, err: Failure };

/// `run(exe, args, timeout)`: graff's stdout, or why not.
fn runGraff(gpa: Allocator, arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, t_ms: u64, env: *const Environ.Map) !StdoutResult {
    var joined: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i > 0) try joined.append(arena, ' ');
        try joined.appendSlice(arena, a);
    }
    switch (try acp.runCapture(gpa, arena, io, exe, args, t_ms, env)) {
        .timed_out => return .{ .err = Failure.protocol("graff {s} timed out", .{joined.items}) },
        .err => |f| return .{ .err = f },
        .ok => |c| {
            if (!acp.success(c.term)) {
                return .{ .err = Failure.protocol("graff {s} failed ({s}): {s}", .{ joined.items, try acp.exitStatusText(arena, c.term), c.stderr }) };
            }
            return .{ .ok = c.stdout };
        },
    }
}

/// `discover_legacy`: `graff route` + `graff models`.
fn discoverLegacy(gpa: Allocator, arena: Allocator, io: Io, exe: []const u8, t_ms: u64, env: *const Environ.Map) !ModelsOutcome {
    const route_text = switch (try runGraff(gpa, arena, io, exe, &.{"route"}, t_ms, env)) {
        .ok => |s| s,
        .err => |f| return .{ .err = f },
    };
    const route = try parseRoute(arena, route_text);
    if (route.providers.len == 0) return .{ .err = noAuthenticatedModels() };
    const listing = switch (try runGraff(gpa, arena, io, exe, &.{"models"}, t_ms, env)) {
        .ok => |s| s,
        .err => |f| return .{ .err = f },
    };
    var seats: std.ArrayList(Seat) = .empty;
    try seats.appendSlice(arena, try parseModelsListing(arena, listing));
    try promoteMissingCodexSeats(arena, &seats, route.providers);
    const rows = try modelsFromSeats(arena, seats.items, route.providers, route.default, route.advertised);
    if (rows.len == 0) return .{ .err = Failure.protocol("graff models listed nothing for reachable providers", .{}) };
    return .{ .ok = rows };
}

/// `discover_acp`: the `graff/models` reply, from a private scratch cwd.
fn discoverAcp(gpa: Allocator, arena: Allocator, io: Io, exe: []const u8, t_ms: u64, env: *const Environ.Map) !acp.Outcome {
    const scratch = acp.Scratch.create(arena, io, env, "graff-model-discovery") catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
    defer scratch.remove(io);
    var spawned = switch (try acp.spawnAgent(gpa, arena, io, spec, exe, scratch.path, env, graffEnv)) {
        .ok => |s| s,
        .err => |f| return .{ .err = f },
    };
    defer spawned.destroy(io);
    const deadline = acp.nowNs(io) + @as(i96, t_ms) * std.time.ns_per_ms;
    spawned.proc.armDeadline(@intCast(@min(t_ms, std.math.maxInt(u32))));
    var rpc: acp.Rpc = .{ .arena = arena, .proc = spawned.proc };
    const outcome: acp.Outcome = blk: {
        // `initialize_params(Graff)`: only the environment enables subagents.
        const env_draft = if (env.get("GRAFF_ACP_DRAFT_SUBAGENTS")) |v| std.mem.eql(u8, v, "1") else false;
        const init = switch (rpc.request("initialize", try acp.initializeParams(arena, "graff", env_draft), true)) {
            .err => |f| break :blk .{ .err = f },
            .ok => |v| v,
        };
        if (acp.asU64(acp.field(init, "protocolVersion")) != 1) break :blk .{ .err = Failure.protocol("graff model discovery requires ACP v1", .{}) };
        const params = try std.fmt.allocPrint(arena, "{{\"cwd\":{f},\"mcpServers\":[]}}", .{json.fmt(scratch.path, .{})});
        switch (rpc.request("session/new", params, true)) {
            .err => |f| break :blk .{ .err = f },
            .ok => {},
        }
        break :blk rpc.request("graff/models", "{}", true);
    };
    const timed_out = outcome == .err and acp.nowNs(io) >= deadline;
    spawned.shutdown();
    if (timed_out) return .{ .err = Failure.protocol("graff model discovery timed out", .{}) };
    return outcome;
}

/// `graff_models::discover(harness, exe, timeout)`: models JSON (owned by
/// `gpa`) or the failure.
pub fn discover(gpa: Allocator, io: Io, exe: []const u8, t_ms: u64) !core.Discovered {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try core.currentEnv(arena);
    const outcome: ModelsOutcome = switch (try discoverAcp(gpa, arena, io, exe, t_ms, &env)) {
        .ok => |catalog| try modelsFromAcp(arena, catalog),
        .err => |f| if (extensionUnavailable(&f)) try discoverLegacy(gpa, arena, io, exe, t_ms, &env) else .{ .err = f },
    };
    return switch (outcome) {
        .ok => |rows| .{ .ok = try core.modelsJson(gpa, rows) },
        .err => |f| .{ .err = f },
    };
}

// ── the harness surface ────────────────────────────────────────────────────

fn ctxFn(_: *anyopaque, _: Allocator, _: Io) anyerror!core.ContextResult {
    // An OS keychain account cannot be fingerprinted: live-only.
    return .none;
}

fn catFn(_: *anyopaque, gpa: Allocator, io: Io, _: bool) anyerror!core.Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const exe = switch (acp.resolveProgram(arena_state.allocator(), io, spec)) {
        .ok => |p| p,
        .err => |f| return .{ .err = f },
    };
    return switch (try discover(gpa, io, exe, timeout_ms.load(.acquire))) {
        .ok => |m| .{ .ok = .{ .models = m, .source = .live } },
        .err => |f| .{ .err = f },
    };
}

fn fbFn(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
    return gpa.dupe(u8, "[]");
}

const vtable: core.Harness.VTable = .{ .modelContext = ctxFn, .modelCatalog = catFn, .fallbackModels = fbFn };
var instance: u8 = 0;

pub fn harness() core.Harness {
    return .{ .id = spec.id, .ptr = &instance, .vtable = &vtable };
}

/// `Harness::models` for graff: always live, failures returned.
pub fn harnessModels(gpa: Allocator, io: Io) !core.ListResult {
    return switch (try catFn(&instance, gpa, io, true)) {
        .ok => |c| .{ .ok = c.models },
        .err => |f| .{ .err = f },
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseTest(arena: Allocator, text: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, arena, text, .{ .allocate = .alloc_always });
}

fn rowsJson(arena: Allocator, rows: []const Model) ![]const u8 {
    return core.modelsJson(arena, rows);
}

test "catalog_graff graff/models pins the provider, keeps each row's ladder and filters unauthenticated rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = try parseTest(arena,
        \\{"current":{"provider":"first","model":"shared"},"models":[
        \\ {"provider":"second","name":"shared","authenticated":true,"context":200000,"effortLevels":["low","low","medium","turbo","high"]},
        \\ {"provider":"first","name":"shared","authenticated":true,"context":100000,"effortLevels":["low","xhigh","ultra"]},
        \\ {"provider":"third","name":"plain","authenticated":true,"context":50000,"effortLevels":[]},
        \\ {"provider":"fourth","name":"hidden","authenticated":false,"effortLevels":["max"]},
        \\ {"provider":"fifth","name":"unknown"},
        \\ {"provider":"second","name":"shared","authenticated":true,"effortLevels":["ultra"]}]}
    );
    const rows = (try modelsFromAcp(arena, catalog)).ok;
    try testing.expectEqualStrings(
        "[{\"id\":\"first/shared\",\"label\":\"shared\",\"description\":\"first · 100k context\",\"reasoningLevels\":[\"low\",\"xhigh\",\"ultra\"],\"options\":[],\"context\":100000}," ++
            "{\"id\":\"second/shared\",\"label\":\"shared\",\"description\":\"second · 200k context\",\"reasoningLevels\":[\"low\",\"medium\",\"high\"],\"options\":[],\"context\":200000}," ++
            "{\"id\":\"third/plain\",\"label\":\"plain\",\"description\":\"third · 50k context\",\"reasoningLevels\":[],\"options\":[],\"context\":50000}]",
        try rowsJson(arena, rows),
    );
    const meta = try parseTest(arena,
        \\{"models":[
        \\ {"provider":"codex","name":"gpt-6-sol","authenticated":true,"cost":"plan","maker":"openai"},
        \\ {"provider":"codegraff","name":"mimo-v2.6-flash","authenticated":true,"cost":"credits"},
        \\ {"provider":"lmstudio","name":"local","authenticated":true,"cost":""}]}
    );
    const m = (try modelsFromAcp(arena, meta)).ok;
    try testing.expectEqualStrings("plan", m[0].billing.?);
    try testing.expectEqualStrings("openai", m[0].maker.?);
    try testing.expectEqualStrings("credits", m[1].billing.?);
    try testing.expect(m[1].maker == null and m[2].billing == null);
    try testing.expectEqualStrings("lmstudio", m[2].description.?);

    var buf: [256]u8 = undefined;
    const none = (try modelsFromAcp(arena, try parseTest(arena, "{\"models\":[{\"provider\":\"x\",\"name\":\"y\",\"authenticated\":false}]}"))).err;
    try testing.expectEqualStrings("model discovery auth_required: graff has no reachable provider — run `graff login`", none.display(&buf));
    const missing = (try modelsFromAcp(arena, try parseTest(arena, "{}"))).err;
    try testing.expectEqualStrings("harness protocol error: graff/models omitted its model rows", missing.display(&buf));
}

test "catalog_graff context labels and legacy ids" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { u64, []const u8 }{
        .{ 272_000, "272k" }, .{ 1_000_000, "1M" }, .{ 1_050_000, "1.05M" }, .{ 1_048_576, "1M" },
        .{ 131_072, "128k" }, .{ 999, "999" },      .{ 1_500_000, "1.5M" },  .{ 999_499, "999k" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try contextLabel(arena, c[0]));
    try testing.expectEqualStrings("codex/gpt-6-sol", try normalizeLegacyId(arena, "codex:gpt-6-sol"));
    try testing.expectEqualStrings("claude-agent/claude-opus-5-5", try normalizeLegacyId(arena, "claude-agent:claude-opus-5-5"));
    try testing.expectEqualStrings("gpt-6-sol:batch", try normalizeLegacyId(arena, "gpt-6-sol:batch"));
    try testing.expectEqualStrings("kimi/k3", try normalizeLegacyId(arena, "kimi/k3"));
}

test "catalog_graff only an unknown graff/models method uses the legacy listing" {
    try testing.expect(extensionUnavailable(&Failure.protocol("graff/models: method not found: graff/models (code -32601)", .{})));
    for ([_][]const u8{
        "graff/models: authentication required (code -32001)",
        "graff/models: app-server exited before responding",
        "session/new: method not found (code -32601)",
        "graff/models: malformed (code -32601): detail",
    }) |m| try testing.expect(!extensionUnavailable(&Failure.protocol("{s}", .{m})));
}

const route_fixture =
    "session default: codegraff/claude-sonnet-5 · auth: OAuth/login · billing: metered\n\n" ++
    "provider     auth           billing        frontier / mid / small\n" ++
    "codegraff    OAuth/login    metered        claude-opus-5 / gpt-5.6-sol / gpt-5.6-luna\n" ++
    "codex        OAuth/login    subscription   gpt-5.6-sol / - / gpt-5.6-luna\n\n" ++
    "usage: graff route <model> [<model>…]\n";

test "catalog_graff legacy route and listing rank like Rust" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try parseRoute(arena, route_fixture);
    try testing.expectEqualStrings("claude-sonnet-5", r.default.?);
    try testing.expectEqual(@as(usize, 2), r.providers.len);
    try testing.expectEqualStrings("codex", r.providers[1]);
    try testing.expectEqual(@as(usize, 3), r.advertised.len);
    try testing.expectEqualStrings("gpt-5.6-luna", r.advertised[2]);

    const listing =
        "model catalog — 8 entries\n\n" ++
        "codex (dynamic cache):\n" ++
        "  gpt-5.6-sol                           270000 ctx   (subscription)\n" ++
        "openrouter:\n" ++
        "  openai/gpt-6-sol                     1050000 ctx   (unpriced)\n" ++
        "  openai/gpt-6-sol:batch               1050000 ctx   (unpriced)\n";
    const route2 =
        "session default: xai/grok-4.6 · auth: OAuth/login · billing: subscription\n\n" ++
        "provider     auth           billing        frontier / mid / small\n" ++
        "codex        OAuth/login    subscription   gpt-5.6-sol / - / -\n" ++
        "openrouter   secure store   metered        x-ai/grok-4.5 / - / -\n\n";
    const r2 = try parseRoute(arena, route2);
    var seats: std.ArrayList(Seat) = .empty;
    try seats.appendSlice(arena, try parseModelsListing(arena, listing));
    try promoteMissingCodexSeats(arena, &seats, r2.providers);
    const rows = try modelsFromSeats(arena, seats.items, r2.providers, r2.default, r2.advertised);
    try testing.expectEqualStrings(
        "[{\"id\":\"gpt-5.6-sol\",\"label\":\"gpt-5.6-sol\",\"description\":\"codex · 270k context\",\"reasoningLevels\":[],\"options\":[],\"context\":270000}," ++
            "{\"id\":\"gpt-6-sol\",\"label\":\"gpt-6-sol\",\"description\":\"codex · 272k context\",\"reasoningLevels\":[],\"options\":[],\"context\":272000}," ++
            "{\"id\":\"openai/gpt-6-sol\",\"label\":\"openai/gpt-6-sol\",\"description\":\"openrouter · 1.05M context\",\"reasoningLevels\":[],\"options\":[],\"context\":1050000}]",
        try rowsJson(arena, rows),
    );
    // Default, then its close sibling, then advertised seats; a repeated
    // bare name gets a provider-qualified id.
    const sib = [_]Seat{
        .{ .provider = "codegraff", .name = "claude-opus-5", .context = 1_000_000 },
        .{ .provider = "codegraff", .name = "grok-4.7", .context = 500_000 },
        .{ .provider = "xai", .name = "grok-4.7", .context = 500_000 },
        .{ .provider = "xai", .name = "grok-4.6", .context = 500_000 },
        .{ .provider = "elsewhere", .name = "ignored", .context = null },
    };
    const rows2 = try modelsFromSeats(arena, &sib, &.{ "codegraff", "xai" }, "grok-4.6", &.{"claude-opus-5"});
    try testing.expectEqual(@as(usize, 4), rows2.len);
    try testing.expectEqualStrings("grok-4.6", rows2[0].id);
    try testing.expectEqualStrings("grok-4.7", rows2[1].id);
    try testing.expectEqualStrings("xai · 500k context", rows2[1].description.?);
    try testing.expectEqualStrings("codegraff:grok-4.7", rows2[2].id);
    try testing.expectEqualStrings("claude-opus-5", rows2[3].id);
}

fn skipUnlessSpawn() !void {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
}

fn expectErr(r: core.Result, code: core.Code, text: []const u8) !void {
    switch (r) {
        .ok => |c| {
            defer testing.allocator.free(c.models);
            std.debug.print("unexpected catalog: {s}\n", .{c.models});
            return error.TestUnexpectedResult;
        },
        .err => |f| {
            var buf: [1024]u8 = undefined;
            try testing.expectEqualStrings(text, f.display(&buf));
            try testing.expectEqual(code, f.code);
        },
    }
}

const acp_handshake =
    \\recv
    \\send '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
    \\recv
    \\send '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"g-1"}}'
    \\recv
;

test "catalog_graff the graff/models extension is live-only and runs in a private scratch folder" {
    try skipUnlessSpawn();
    const te = try acp.TestEnv.init();
    defer te.deinit();
    defer resetForTests();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("graff.log");
    const body = try acp.mockAgent(gpa, log, acp_handshake ++ "\n" ++
        \\send '{"jsonrpc":"2.0","id":3,"result":{"current":{"provider":"codex","model":"gpt-6-sol"},"models":[{"provider":"anthropic","name":"claude-opus-5-5","authenticated":true,"context":1000000,"effortLevels":["low","high","max"],"maker":"anthropic","cost":"credits"},{"provider":"codex","name":"gpt-6-sol","authenticated":true,"context":272000,"effortLevels":["medium"]},{"provider":"kimi","name":"k3","authenticated":false}]}}'
    );
    defer gpa.free(body);
    te.bind("graff", try te.script("graff", body));
    try te.env.put("GRAFF_CODEX_WS", "on");
    setDeviceName(io, "  Synthetic Mac ");
    const h = harness();
    try testing.expect((try h.modelContext(gpa, io)) == .none);
    // `list` with no context goes straight to the live catalog.
    const listed = try core.list(gpa, io, null, h, false);
    defer listed.deinit(gpa);
    try testing.expect(listed == .ok);
    try testing.expectEqualStrings(
        "[{\"id\":\"codex/gpt-6-sol\",\"label\":\"gpt-6-sol\",\"description\":\"codex · 272k context\",\"reasoningLevels\":[\"medium\"],\"options\":[],\"context\":272000}," ++
            "{\"id\":\"anthropic/claude-opus-5-5\",\"label\":\"claude-opus-5-5\",\"description\":\"anthropic · 1M context\",\"reasoningLevels\":[\"low\",\"high\",\"max\"],\"options\":[],\"maker\":\"anthropic\",\"billing\":\"credits\",\"context\":1000000}]",
        listed.ok,
    );
    const fb = try h.fallbackModels(gpa);
    defer gpa.free(fb);
    try testing.expectEqualStrings("[]", fb);
    const logged = try te.read("graff.log");
    defer gpa.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "args: acp --yolo") != null);
    // A user's own GRAFF_CODEX_WS wins; the host app is announced.
    try testing.expect(std.mem.indexOf(u8, logged, "GRAFF_AUTO_ISOLATE=0 GRAFF_CODEX_WS=on GRAFF_HOST_APP=harness/") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "/harness-graff-model-discovery-") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"elicitation\":{\"form\":{}},\"session\":{\"compaction\":{}}}") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"method\":\"graff/models\",\"params\":{}") != null);
    // The scratch folder is removed afterwards.
    var dir = try te.tmp.dir.openDir(io, "tmp", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "catalog_graff unauthenticated rows, an old protocol and a missing binary" {
    try skipUnlessSpawn();
    const te = try acp.TestEnv.init();
    defer te.deinit();
    defer resetForTests();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("graff.log");
    const h = harness();

    try expectErr(try h.modelCatalog(gpa, io, false), .missing_executable, "harness binary not found: " ++ acp.specs.graff.install_hint);

    const unauth = try acp.mockAgent(gpa, log, acp_handshake ++ "\n" ++
        \\send '{"jsonrpc":"2.0","id":3,"result":{"models":[{"provider":"kimi","name":"k3","authenticated":false}]}}'
    );
    defer gpa.free(unauth);
    te.bind("graff", try te.script("graff-unauth", unauth));
    try expectErr(try h.modelCatalog(gpa, io, false), .auth_required, "model discovery auth_required: graff has no reachable provider — run `graff login`");
    const listed = try harnessModels(gpa, io);
    try testing.expect(listed == .err and listed.err.code == .auth_required);

    const v2 = try acp.mockAgent(gpa, log,
        \\recv
        \\send '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2}}'
    );
    defer gpa.free(v2);
    te.bind("graff", try te.script("graff-v2", v2));
    try expectErr(try h.modelCatalog(gpa, io, false), .failed, "harness protocol error: graff model discovery requires ACP v1");
}

test "catalog_graff an older graff without the extension uses route and models" {
    try skipUnlessSpawn();
    const te = try acp.TestEnv.init();
    defer te.deinit();
    defer resetForTests();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("graff.log");
    const route_file = try te.path("route.txt");
    try te.tmp.dir.writeFile(io, .{ .sub_path = "route.txt", .data = route_fixture });
    const models_file = try te.path("models.txt");
    try te.tmp.dir.writeFile(io, .{ .sub_path = "models.txt", .data = "codegraff:\n  claude-sonnet-5  1000000 ctx\n  claude-opus-5    1000000 ctx\ncodex:\n  gpt-5.6-sol      1050000 ctx\n" });
    const acp_part = try acp.mockAgent(gpa, log, acp_handshake ++ "\n" ++
        \\send '{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"method not found: graff/models"}}'
    );
    defer gpa.free(acp_part);
    const script_text = try std.fmt.allocPrint(gpa, "#!/bin/sh\nif [ \"$1\" = \"route\" ]; then cat '{s}'; exit 0; fi\nif [ \"$1\" = \"models\" ]; then cat '{s}'; exit 0; fi\n{s}", .{ route_file, models_file, acp_part["#!/bin/sh\n".len..] });
    defer gpa.free(script_text);
    te.bind("graff", try te.script("graff", script_text));
    const r = try harness().modelCatalog(gpa, io, false);
    try testing.expect(r == .ok);
    defer gpa.free(r.ok.models);
    try testing.expectEqualStrings(
        "[{\"id\":\"claude-sonnet-5\",\"label\":\"claude-sonnet-5\",\"description\":\"codegraff · 1M context\",\"reasoningLevels\":[],\"options\":[],\"context\":1000000}," ++
            "{\"id\":\"gpt-5.6-sol\",\"label\":\"gpt-5.6-sol\",\"description\":\"codex · 1.05M context\",\"reasoningLevels\":[],\"options\":[],\"context\":1050000}," ++
            "{\"id\":\"claude-opus-5\",\"label\":\"claude-opus-5\",\"description\":\"codegraff · 1M context\",\"reasoningLevels\":[],\"options\":[],\"context\":1000000}]",
        r.ok.models,
    );

    // A failing `graff route` names its exit status and stderr.
    const failing_text = try std.fmt.allocPrint(gpa, "#!/bin/sh\nif [ \"$1\" = \"route\" ]; then echo 'Error: not logged in' >&2; exit 1; fi\n{s}", .{acp_part["#!/bin/sh\n".len..]});
    defer gpa.free(failing_text);
    te.bind("graff", try te.script("graff-failing", failing_text));
    try expectErr(try harness().modelCatalog(gpa, io, false), .auth_required, "harness protocol error: graff route failed (exit status: 1): Error: not logged in");
}

test "catalog_graff a silent graff times out with Rust's text" {
    try skipUnlessSpawn();
    const te = try acp.TestEnv.init();
    defer te.deinit();
    defer resetForTests();
    const gpa = testing.allocator;
    const io = testing.io;
    te.bind("graff", try te.script("graff", "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'graff 0.0.302.25'; exit 0; fi\nsleep 30\n"));
    setDiscoveryTimeoutMs(500);
    const started = acp.nowNs(io);
    try expectErr(try harness().modelCatalog(gpa, io, false), .timeout, "harness protocol error: graff model discovery timed out");
    try testing.expect(@divFloor(acp.nowNs(io) - started, std.time.ns_per_ms) < 10_000);
}
