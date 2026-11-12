//! Devin's live model catalog, ported from
//! `crates/harness/src/acp/devin_models.rs` (`Catalog::refresh`,
//! `parse_catalog`) and Devin's branches of `crates/harness/src/acp/mod.rs`
//! (`model_context`, `model_catalog`, `models`).
//!
//! Devin's ACP `session/new` starts with a bundled catalog and refreshes it
//! later, so discovery runs `devin models list --format json`, which waits
//! for the account catalog. Rows are exact variant ids (effort and speed are
//! baked in), with the variant's cost summary as description. The catalog
//! is cached per credential/binary context (`MemCache`, `10 s * 3 + 1 s`);
//! overlapping refreshes share one command run. Devin never falls back to
//! its static rows in `models()`.
//!
//! Std-only, testable with `zig test catalog_devin.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const core = @import("catalog_core.zig");
const acp = @import("catalog_acp.zig");
const Failure = core.Failure;
const Model = core.Model;

const spec = &acp.specs.devin;

pub const ModelsOutcome = union(enum) { ok: []Model, err: Failure };

fn invalid(arena: Allocator, comptime fmt: []const u8, args: anytype) !ModelsOutcome {
    const detail = try std.fmt.allocPrint(arena, fmt, args);
    return .{ .err = Failure.protocol("invalid Devin model catalog: {s}", .{detail}) };
}

/// serde's description of an unexpected value.
fn unexpected(arena: Allocator, v: json.Value) ![]const u8 {
    return switch (v) {
        .null => "null",
        .bool => |b| std.fmt.allocPrint(arena, "boolean `{}`", .{b}),
        .integer => |n| std.fmt.allocPrint(arena, "integer `{d}`", .{n}),
        .float => |f| std.fmt.allocPrint(arena, "floating point `{d}`", .{f}),
        .number_string => |s| std.fmt.allocPrint(arena, "integer `{s}`", .{s}),
        .string => |s| std.fmt.allocPrint(arena, "string \"{s}\"", .{s}),
        .array => "sequence",
        .object => "map",
    };
}

/// `parse_catalog`: `{"families":[{"variants":[{"model_uid","label",
/// "cost_summary"?}]}]}`, strict like serde (wrong types and missing fields
/// fail; unknown fields are ignored), duplicate ids dropped.
pub fn parseCatalog(arena: Allocator, bytes: []const u8) !ModelsOutcome {
    const root = json.parseFromSliceLeaky(json.Value, arena, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .use_last }) catch |e| {
        if (e == error.OutOfMemory) return e;
        return invalid(arena, "{s}", .{@errorName(e)});
    };
    if (root != .object) return invalid(arena, "invalid type: {s}, expected struct ModelList", .{try unexpected(arena, root)});
    const families = root.object.get("families") orelse return invalid(arena, "missing field `families`", .{});
    if (families != .array) return invalid(arena, "invalid type: {s}, expected a sequence", .{try unexpected(arena, families)});

    var rows: std.ArrayList(Model) = .empty;
    var pending_error: ?[]const u8 = null;
    for (families.array.items) |family| {
        if (family != .object) return invalid(arena, "invalid type: {s}, expected struct Family", .{try unexpected(arena, family)});
        const variants = family.object.get("variants") orelse return invalid(arena, "missing field `variants`", .{});
        if (variants != .array) return invalid(arena, "invalid type: {s}, expected a sequence", .{try unexpected(arena, variants)});
        for (variants.array.items) |variant| {
            if (variant != .object) return invalid(arena, "invalid type: {s}, expected struct Variant", .{try unexpected(arena, variant)});
            // Type errors surface in the order fields appear, then missing ones.
            var it = variant.object.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                const v = e.value_ptr.*;
                const is_text = std.mem.eql(u8, k, "model_uid") or std.mem.eql(u8, k, "label");
                if (is_text and v != .string) return invalid(arena, "invalid type: {s}, expected a string", .{try unexpected(arena, v)});
                if (std.mem.eql(u8, k, "cost_summary") and v != .string and v != .null) return invalid(arena, "invalid type: {s}, expected a string", .{try unexpected(arena, v)});
            }
            const uid = (variant.object.get("model_uid") orelse return invalid(arena, "missing field `model_uid`", .{})).string;
            const label = (variant.object.get("label") orelse return invalid(arena, "missing field `label`", .{})).string;
            const cost: ?[]const u8 = if (variant.object.get("cost_summary")) |c| (if (c == .string) c.string else null) else null;
            if (pending_error != null) continue;
            if (std.mem.trim(u8, uid, " \t\r\n").len == 0 or std.mem.trim(u8, label, " \t\r\n").len == 0) {
                // serde finishes deserializing before the rows are checked.
                pending_error = "invalid empty Devin model id or label";
                continue;
            }
            const dup = for (rows.items) |m| {
                if (std.mem.eql(u8, m.id, uid)) break true;
            } else false;
            if (dup) continue;
            try rows.append(arena, .{ .id = uid, .label = label, .description = cost });
        }
    }
    if (pending_error) |m| return .{ .err = Failure.protocol("{s}", .{m}) };
    if (rows.items.len == 0) return .{ .err = Failure.protocol("Devin returned an empty model catalog", .{}) };
    return .{ .ok = rows.items };
}

// ── process-global state ───────────────────────────────────────────────────

const State = struct {
    cache: core.MemCache = .{},
    timeout_ms: std.atomic.Value(u64) = .init(acp.default_discovery_timeout_ms),
    /// `devin_models::Catalog::latest`: only overlapping callers share a run.
    latest_mutex: Io.Mutex = .init,
    completed_at: ?i96 = null,
    /// Owned by `core.long_gpa`.
    latest: ?[]u8 = null,
    /// Command runs so far (tests).
    runs: std.atomic.Value(usize) = .init(0),
};

var state: State = .{};

/// Tests (`with_model_discovery_timeout`): the probe bound.
pub fn setDiscoveryTimeoutMs(ms: u64) void {
    state.timeout_ms.store(ms, .release);
}

pub fn resetForTests() void {
    if (state.cache.models) |m| core.long_gpa.free(m);
    if (state.latest) |m| core.long_gpa.free(m);
    state = .{};
}

/// `Catalog::refresh(exe, timeout)`: `devin models list --format json`.
pub fn refresh(gpa: Allocator, io: Io, exe: []const u8, timeout_ms: u64) !core.Discovered {
    const requested_at = acp.nowNs(io);
    state.latest_mutex.lockUncancelable(io);
    defer state.latest_mutex.unlock(io);
    if (state.completed_at) |done| if (done >= requested_at) if (state.latest) |m| return .{ .ok = try gpa.dupe(u8, m) };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try core.currentEnv(arena);
    _ = state.runs.fetchAdd(1, .monotonic);
    const cap = switch (try acp.runCapture(gpa, arena, io, exe, &.{ "models", "list", "--format", "json" }, timeout_ms, &env)) {
        .timed_out => return .{ .err = Failure.protocol("Devin model discovery timed out", .{}) },
        .err => |f| return .{ .err = f },
        .ok => |c| c,
    };
    if (!acp.success(cap.term)) {
        return .{ .err = Failure.protocol("Devin models list failed ({s}): {s}", .{ try acp.exitStatusText(arena, cap.term), cap.stderr }) };
    }
    const rows = switch (try parseCatalog(arena, cap.stdout)) {
        .ok => |r| r,
        .err => |f| return .{ .err = f },
    };
    const text = try core.modelsJson(gpa, rows);
    errdefer gpa.free(text);
    const keep = try core.long_gpa.dupe(u8, text);
    if (state.latest) |old| core.long_gpa.free(old);
    state.latest = keep;
    state.completed_at = acp.nowNs(io);
    return .{ .ok = text };
}

const Discoverer = struct {
    timeout_ms: u64,

    pub fn discover(self: *Discoverer, gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const exe = switch (acp.resolveProgram(arena_state.allocator(), io, spec)) {
            .ok => |p| p,
            .err => |f| return .{ .err = f },
        };
        return refresh(gpa, io, exe, @min(self.timeout_ms, budget_ms));
    }
};

fn ctxFn(_: *anyopaque, gpa: Allocator, io: Io) anyerror!core.ContextResult {
    return acp.specContext(gpa, io, spec);
}

fn catFn(_: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!core.Result {
    var d: Discoverer = .{ .timeout_ms = state.timeout_ms.load(.acquire) };
    return acp.cachedCatalog(gpa, io, force, spec, &state.cache, d.timeout_ms, &d);
}

fn fbFn(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
    return core.modelsJson(gpa, spec.models);
}

const vtable: core.Harness.VTable = .{ .modelContext = ctxFn, .modelCatalog = catFn, .fallbackModels = fbFn };

pub fn harness() core.Harness {
    return .{ .id = spec.id, .ptr = &state, .vtable = &vtable };
}

/// `Harness::models` for Devin: a forced refresh; failures are returned,
/// never the static rows.
pub fn harnessModels(gpa: Allocator, io: Io) !core.ListResult {
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        switch (acp.resolveProgram(arena_state.allocator(), io, spec)) {
            .err => |f| return .{ .err = f },
            .ok => {},
        }
    }
    return switch (try catFn(&state, gpa, io, true)) {
        .ok => |c| .{ .ok = c.models },
        .err => |f| .{ .err = f },
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectInvalid(arena: Allocator, bytes: []const u8, want: []const u8) !void {
    const r = try parseCatalog(arena, bytes);
    try testing.expect(r == .err);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(want, r.err.display(&buf));
    try testing.expect(r.err.code.allowsStale());
}

test "catalog_devin parses exact variants without turning family aliases into models" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try parseCatalog(arena,
        \\{"families":[{"family_uid":"gpt-6-astra","aliases":["astra"],"variants":[
        \\ {"model_uid":"gpt-6-astra-medium","label":"GPT-6 Astra Medium Thinking","cost_summary":"Account pricing"},
        \\ {"model_uid":"gpt-6-astra-high","label":"GPT-6 Astra High Thinking","cost_summary":null},
        \\ {"model_uid":"gpt-6-astra-high","label":"Duplicate"}]}]}
    );
    const text = try core.modelsJson(arena, r.ok);
    try testing.expectEqualStrings(
        "[{\"id\":\"gpt-6-astra-medium\",\"label\":\"GPT-6 Astra Medium Thinking\",\"description\":\"Account pricing\",\"reasoningLevels\":[],\"options\":[]}," ++
            "{\"id\":\"gpt-6-astra-high\",\"label\":\"GPT-6 Astra High Thinking\",\"reasoningLevels\":[],\"options\":[]}]",
        text,
    );
}

test "catalog_devin invalid or empty catalogs are retryable errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectInvalid(arena, "{}", "harness protocol error: invalid Devin model catalog: missing field `families`");
    try expectInvalid(arena, "{\"families\":[]}", "harness protocol error: Devin returned an empty model catalog");
    try expectInvalid(arena, "{\"families\":[{\"variants\":[{\"label\":\"Missing id\"}]}]}", "harness protocol error: invalid Devin model catalog: missing field `model_uid`");
    try expectInvalid(arena, "{\"families\":[{\"variants\":[{\"model_uid\":\"\",\"label\":\"Empty id\"}]}]}", "harness protocol error: invalid empty Devin model id or label");
    try expectInvalid(arena, "{\"families\":[{\"variants\":[{\"model_uid\":7,\"label\":\"x\"}]}]}", "harness protocol error: invalid Devin model catalog: invalid type: integer `7`, expected a string");
    try expectInvalid(arena, "{\"families\":3}", "harness protocol error: invalid Devin model catalog: invalid type: integer `3`, expected a sequence");
    const garbage = try parseCatalog(arena, "not json");
    try testing.expect(garbage == .err);
    try testing.expect(std.mem.startsWith(u8, garbage.err.message(), "harness protocol error: invalid Devin model catalog: "));
}

fn skipUnlessSpawn() !void {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
}

fn devinScript(gpa: Allocator, log: []const u8, action: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\if [ "$1" = "--version" ]; then echo "devin 3000.6.14"; exit 0; fi
        \\echo "args: $*" >> '{s}'
        \\{s}
        \\
    , .{ log, action });
}

test "catalog_devin refreshes through its native catalog command and caches per login" {
    try skipUnlessSpawn();
    const te = try acp.TestEnv.init();
    defer te.deinit();
    defer resetForTests();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("devin.log");
    const body = try devinScript(gpa, log,
        \\cat <<'EOF'
        \\{"families":[{"variants":[{"model_uid":"swe-2-high","label":"SWE-2 High","cost_summary":"Included"},{"model_uid":"adaptive","label":"Adaptive"}]}]}
        \\EOF
    );
    defer gpa.free(body);
    te.bind("devin", try te.script("devin", body));
    const h = harness();
    const want = "[{\"id\":\"swe-2-high\",\"label\":\"SWE-2 High\",\"description\":\"Included\",\"reasoningLevels\":[],\"options\":[]},{\"id\":\"adaptive\",\"label\":\"Adaptive\",\"reasoningLevels\":[],\"options\":[]}]";
    const r = try h.modelCatalog(gpa, io, false);
    try testing.expect(r == .ok and r.ok.source == .live);
    defer gpa.free(r.ok.models);
    try testing.expectEqualStrings(want, r.ok.models);
    const logged = try te.read("devin.log");
    defer gpa.free(logged);
    try testing.expectEqualStrings("args: models list --format json\n", logged);
    // Cached for the same login; a new credentials file is a new context.
    const again = try h.modelCatalog(gpa, io, false);
    try testing.expect(again == .ok and again.ok.source == .cache);
    gpa.free(again.ok.models);
    try testing.expectEqual(@as(usize, 1), state.runs.load(.monotonic));
    try te.tmp.dir.createDirPath(io, "home/.local/share/devin");
    try te.tmp.dir.writeFile(io, .{ .sub_path = "home/.local/share/devin/credentials.toml", .data = "synthetic = true" });
    const fresh = try h.modelCatalog(gpa, io, false);
    try testing.expect(fresh == .ok and fresh.ok.source == .live);
    gpa.free(fresh.ok.models);
    try testing.expectEqual(@as(usize, 2), state.runs.load(.monotonic));
    const listed = try harnessModels(gpa, io);
    defer listed.deinit(gpa);
    try testing.expectEqualStrings(want, listed.ok);
}

test "catalog_devin failures never fall back to static rows" {
    try skipUnlessSpawn();
    const te = try acp.TestEnv.init();
    defer te.deinit();
    defer resetForTests();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("devin.log");
    const h = harness();

    var buf: [512]u8 = undefined;
    const missing = try harnessModels(gpa, io);
    try testing.expect(missing == .err);
    try testing.expectEqualStrings("harness binary not found: " ++ acp.specs.devin.install_hint, missing.err.display(&buf));

    const logged_out = try devinScript(gpa, log, "echo 'Error: not logged in' >&2; exit 1");
    defer gpa.free(logged_out);
    te.bind("devin", try te.script("devin-out", logged_out));
    const r = try h.modelCatalog(gpa, io, true);
    try testing.expect(r == .err);
    try testing.expectEqualStrings("model discovery auth_required: harness protocol error: Devin models list failed (exit status: 1): Error: not logged in", r.err.display(&buf));
    const listed = try harnessModels(gpa, io);
    try testing.expect(listed == .err and listed.err.code == .auth_required);

    resetForTests();
    const malformed = try devinScript(gpa, log, "echo '{\"families\":[]}'");
    defer gpa.free(malformed);
    te.bind("devin", try te.script("devin-empty", malformed));
    const empty = try harnessModels(gpa, io);
    try testing.expect(empty == .err);
    try testing.expectEqualStrings("model discovery failed: harness protocol error: Devin returned an empty model catalog", empty.err.display(&buf));
}

test "catalog_devin a hung models list times out with Rust's text" {
    try skipUnlessSpawn();
    const te = try acp.TestEnv.init();
    defer te.deinit();
    defer resetForTests();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("devin.log");
    const hung = try devinScript(gpa, log, "sleep 30");
    defer gpa.free(hung);
    const exe = try te.script("devin", hung);
    const started = acp.nowNs(io);
    const r = try refresh(gpa, io, exe, 500);
    try testing.expect(@divFloor(acp.nowNs(io) - started, std.time.ns_per_ms) < 10_000);
    try testing.expect(r == .err);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: Devin model discovery timed out", r.err.display(&buf));
    try testing.expectEqual(core.Code.timeout, r.err.code);
}
