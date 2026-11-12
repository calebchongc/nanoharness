//! The device settings kept in `{data_dir}/harness-prefs.json`, ported from
//! `crates/engine/src/registry.rs` (`HarnessPrefsFile`, `load_prefs`,
//! `persist_prefs`, `autonomy`, `graff_draft_subagents`, `keep_awake`,
//! `graff_compact_at`, `title_settings`) and their arms in
//! `crates/engine/src/rpc.rs`: `GetAutonomy`/`SetAutonomy`,
//! `GetKeepAwake`/`SetKeepAwake`, `GetGraffDraftSubagents`/`SetGraffDraftSubagents`,
//! `GetGraffCompactAt`/`SetGraffCompactAt`, `GetTitleSettings`/`SetTitleSettings`.
//!
//! The file is the one `rpcw_harnesses.zig` keeps the agent opt-ins and
//! opt-outs in; both go through its `loadPrefs`/`persistPrefs`, which write
//! every field back in serde order, so a folder written by either engine reads
//! in the other. Without a data folder (Rust's `prefs_path: None`) the values
//! live in memory only.
//!
//! The engine fields `autonomy_level`, `graff_draft_subagents`,
//! `graff_compact_at` and `keep_awake_enabled` mirror the file for the run
//! paths that read them (`turn_host.zig`, `rpcw_keep_awake.zig`);
//! `loadInto` fills them when the engine gets its data folder.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const harnesses = @import("rpcw_harnesses.zig");
const exes = @import("rpcw_executables.zig");
const keep_awake = @import("rpcw_keep_awake.zig");

const RpcOutcome = common.RpcOutcome;
const EngineHost = engine_host.EngineHost;
const HarnessId = exes.HarnessId;

/// `harness_proto::Autonomy` (kebab-case); the default is full access.
pub const Autonomy = enum {
    read_only,
    workspace,
    full_access,

    pub fn wire(a: Autonomy) []const u8 {
        return switch (a) {
            .read_only => "read-only",
            .workspace => "workspace",
            .full_access => "full-access",
        };
    }

    pub fn parse(text: []const u8) ?Autonomy {
        for (std.meta.tags(Autonomy)) |a| if (std.mem.eql(u8, text, a.wire())) return a;
        return null;
    }
};

/// `GRAFF_COMPACT_AT_MIN`..`GRAFF_COMPACT_AT_MAX`.
pub const compact_at_min: u8 = 10;
pub const compact_at_max: u8 = 95;

pub fn validCompactAt(pct: i64) bool {
    return pct >= compact_at_min and pct <= compact_at_max;
}

/// `harness_adapters::supports_titles`.
pub fn supportsTitles(id: HarnessId) bool {
    return id == .codex or id == .claude_code or id == .mock;
}

/// The settings this file owns, as read from the prefs file.
pub const Settings = struct {
    autonomy: ?Autonomy = null,
    graff_draft_subagents: bool = false,
    keep_awake: bool = false,
    /// The stored value as written; `loadInto` hands runs only a valid one.
    graff_compact_at: ?i64 = null,
    title_harness: ?HarnessId = null,
    /// Borrowed from the prefs it was read from.
    title_model: ?[]const u8 = null,
};

/// Read the settings out of a loaded prefs file, the way serde reads
/// `HarnessPrefsFile` with `#[serde(default)]`: a field of the wrong type
/// fails the whole file, which then reads as the defaults.
pub fn fromPrefs(prefs: *const harnesses.Prefs) Settings {
    const raw = prefs.raw orelse return .{};
    const o = raw.value.object;
    var s: Settings = .{};
    if (o.get("autonomy")) |v| switch (v) {
        .null => {},
        .string => |t| s.autonomy = Autonomy.parse(t) orelse return .{},
        else => return .{},
    };
    if (o.get("graffDraftSubagents")) |v| switch (v) {
        .bool => |b| s.graff_draft_subagents = b,
        else => return .{},
    };
    if (o.get("keepAwake")) |v| switch (v) {
        .bool => |b| s.keep_awake = b,
        else => return .{},
    };
    if (o.get("graffCompactAt")) |v| switch (v) {
        .null => {},
        .integer => |n| {
            if (n < 0 or n > 255) return .{};
            s.graff_compact_at = n;
        },
        else => return .{},
    };
    if (o.get("titles")) |v| switch (v) {
        .null => {},
        .object => |t| {
            if (t.get("harness")) |h| if (h == .string) {
                s.title_harness = HarnessId.parse(h.string);
            };
            if (t.get("model")) |m| switch (m) {
                .null => {},
                .string => |ms| s.title_model = ms,
                else => return .{},
            };
        },
        else => return .{},
    };
    return s;
}

// ── memory store (no data folder) ──────────────────────────────────────────

/// Rust keeps these in the registry when it has nowhere to persist them.
var memory_autonomy: ?Autonomy = null;
var memory_title_harness: ?HarnessId = null;
var memory_title_model_buf: [256]u8 = undefined;
var memory_title_model_len: ?usize = null;

/// For tests that rebuild the memory-only engine.
pub fn resetMemory() void {
    memory_autonomy = null;
    memory_title_harness = null;
    memory_title_model_len = null;
}

fn persisted(host: *const EngineHost) bool {
    return host.data_dir != null and host.io != null;
}

/// Load the file (or the memory store) as `Settings` plus the prefs to write back.
const Loaded = struct {
    prefs: harnesses.Prefs,
    settings: Settings,

    fn deinit(self: *Loaded, gpa: Allocator) void {
        self.prefs.deinit(gpa);
    }
};

fn load(host: *EngineHost) !Loaded {
    if (!persisted(host)) {
        return .{ .prefs = .{}, .settings = .{
            .autonomy = memory_autonomy,
            .graff_draft_subagents = host.graff_draft_subagents,
            .keep_awake = host.keep_awake_enabled,
            .graff_compact_at = if (host.graff_compact_at == 0) null else host.graff_compact_at,
            .title_harness = memory_title_harness,
            .title_model = if (memory_title_model_len) |n| memory_title_model_buf[0..n] else null,
        } };
    }
    var prefs = try harnesses.loadPrefs(host.gpa, host.io.?, host.data_dir);
    errdefer prefs.deinit(host.gpa);
    const s = fromPrefs(&prefs);
    mirror(host, s);
    return .{ .prefs = prefs, .settings = s };
}

/// Copy the settings onto the engine fields the run paths read.
fn mirror(host: *EngineHost, s: Settings) void {
    const level = (s.autonomy orelse Autonomy.full_access).wire();
    if (!std.mem.eql(u8, host.autonomy_level, level)) {
        if (host.gpa.dupe(u8, level)) |copy| {
            host.gpa.free(host.autonomy_level);
            host.autonomy_level = copy;
        } else |_| {}
    }
    host.graff_draft_subagents = s.graff_draft_subagents;
    host.graff_compact_at = if (s.graff_compact_at) |n| (if (validCompactAt(n)) n else 0) else 0;
    if (host.keep_awake_enabled != s.keep_awake) {
        host.keep_awake_enabled = s.keep_awake;
        keep_awake.follow(host);
    }
}

/// When the engine gets its data folder: read the saved settings into it.
pub fn loadInto(host: *EngineHost) void {
    if (!persisted(host)) return;
    var l = load(host) catch return;
    l.deinit(host.gpa);
}

/// Put `key: value` into the prefs' raw object (made if the file had none),
/// in the prefs' own arena.
fn setField(gpa: Allocator, prefs: *harnesses.Prefs, key: []const u8, value: json.Value) !void {
    if (prefs.raw == null) prefs.raw = try json.parseFromSlice(json.Value, gpa, "{}", .{});
    const raw = &prefs.raw.?;
    const a = raw.arena.allocator();
    const v: json.Value = switch (value) {
        .string => |t| .{ .string = try a.dupe(u8, t) },
        else => value,
    };
    try raw.value.object.put(a, try a.dupe(u8, key), v);
}

/// Write the changed field and mirror the result. `persist_prefs` is best
/// effort in Rust (a failed save is logged, the call still succeeds).
fn save(host: *EngineHost, l: *Loaded, key: []const u8, value: json.Value) !void {
    if (persisted(host)) {
        try setField(host.gpa, &l.prefs, key, value);
        harnesses.persistPrefs(host.gpa, host.io.?, host.data_dir, &l.prefs);
        mirror(host, fromPrefs(&l.prefs));
    }
}

fn badType(o: json.ObjectMap, key: []const u8, expected: []const u8) RpcOutcome {
    const v = o.get(key).?;
    return switch (v) {
        .string => |t| common.badParams("invalid type: string \"{s}\", expected {s}", .{ t, expected }),
        .integer => |n| common.badParams("invalid type: integer `{d}`, expected {s}", .{ n, expected }),
        .bool => |b| common.badParams("invalid type: boolean `{}`, expected {s}", .{ b, expected }),
        .null => common.badParams("invalid type: null, expected {s}", .{expected}),
        else => common.badParams("invalid type: expected {s}", .{expected}),
    };
}

fn enabledParam(params: json.Value, comptime name: []const u8) union(enum) { ok: bool, err: RpcOutcome } {
    const o = common.obj(params) orelse return .{ .err = common.badParams("invalid type: expected struct " ++ name, .{}) };
    const v = o.get("enabled") orelse return .{ .err = common.badParams("missing field `enabled`", .{}) };
    if (v != .bool) return .{ .err = badType(o, "enabled", "a boolean") };
    return .{ .ok = v.bool };
}

// ── autonomy ───────────────────────────────────────────────────────────────

fn autonomyReply(gpa: Allocator, s: Settings) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"autonomy\":\"{s}\",\"chosen\":{}}}", .{ (s.autonomy orelse Autonomy.full_access).wire(), s.autonomy != null });
}

pub fn getAutonomy(host: *EngineHost) !RpcOutcome {
    var l = try load(host);
    defer l.deinit(host.gpa);
    return .{ .unary_json = try autonomyReply(host.gpa, l.settings) };
}

pub fn setAutonomy(host: *EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct SetAutonomyParams", .{});
    const v = o.get("autonomy") orelse return common.badParams("missing field `autonomy`", .{});
    if (v != .string) return badType(o, "autonomy", "one of `read-only`, `workspace`, `full-access`");
    const level = Autonomy.parse(v.string) orelse
        return common.badParams("unknown variant `{s}`, expected one of `read-only`, `workspace`, `full-access`", .{v.string});
    var l = try load(host);
    defer l.deinit(host.gpa);
    if (!persisted(host)) {
        memory_autonomy = level;
        l.settings.autonomy = level;
        mirror(host, l.settings);
    } else try save(host, &l, "autonomy", .{ .string = level.wire() });
    var s = l.settings;
    s.autonomy = level;
    return .{ .unary_json = try autonomyReply(host.gpa, s) };
}

// ── keep awake ─────────────────────────────────────────────────────────────

fn keepAwakeReply(gpa: Allocator, enabled: bool) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"enabled\":{},\"supported\":{}}}", .{ enabled, keep_awake.supported });
}

pub fn getKeepAwake(host: *EngineHost) !RpcOutcome {
    var l = try load(host);
    defer l.deinit(host.gpa);
    return .{ .unary_json = try keepAwakeReply(host.gpa, l.settings.keep_awake) };
}

pub fn setKeepAwake(host: *EngineHost, params: json.Value) !RpcOutcome {
    const on = switch (enabledParam(params, "SetKeepAwakeParams")) {
        .ok => |b| b,
        .err => |e| return e,
    };
    if (on and !keep_awake.supported) return common.failedMsg("Keeping this computer awake is not supported");
    var l = try load(host);
    defer l.deinit(host.gpa);
    if (!persisted(host)) {
        l.settings.keep_awake = on;
        mirror(host, l.settings);
    } else try save(host, &l, "keepAwake", .{ .bool = on });
    return .{ .unary_json = try keepAwakeReply(host.gpa, on) };
}

// ── graff draft subagents ──────────────────────────────────────────────────

pub fn getGraffDraftSubagents(host: *EngineHost) !RpcOutcome {
    var l = try load(host);
    defer l.deinit(host.gpa);
    return .{ .unary_json = try host.gpa.dupe(u8, if (l.settings.graff_draft_subagents) "true" else "false") };
}

pub fn setGraffDraftSubagents(host: *EngineHost, params: json.Value) !RpcOutcome {
    const on = switch (enabledParam(params, "SetGraffDraftSubagentsParams")) {
        .ok => |b| b,
        .err => |e| return e,
    };
    var l = try load(host);
    defer l.deinit(host.gpa);
    if (!persisted(host)) {
        l.settings.graff_draft_subagents = on;
        mirror(host, l.settings);
    } else try save(host, &l, "graffDraftSubagents", .{ .bool = on });
    return .{ .unary_json = try host.gpa.dupe(u8, if (on) "true" else "false") };
}

// ── graff compact-at ───────────────────────────────────────────────────────

fn compactReply(gpa: Allocator, pct: ?i64) ![]u8 {
    return if (pct) |n| std.fmt.allocPrint(gpa, "{d}", .{n}) else gpa.dupe(u8, "null");
}

pub fn getGraffCompactAt(host: *EngineHost) !RpcOutcome {
    var l = try load(host);
    defer l.deinit(host.gpa);
    return .{ .unary_json = try compactReply(host.gpa, l.settings.graff_compact_at) };
}

/// `SetGraffCompactAt { pct }`: `null` (or no `pct`) restores graff's default.
pub fn setGraffCompactAt(host: *EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct SetGraffCompactAtParams", .{});
    var pct: ?i64 = null;
    if (o.get("pct")) |v| switch (v) {
        .null => {},
        .integer => |n| {
            if (n < 0 or n > 255) return common.badParams("invalid value: integer `{d}`, expected u8", .{n});
            pct = n;
        },
        else => return badType(o, "pct", "u8"),
    };
    if (pct) |n| if (!validCompactAt(n)) return common.failed("compaction point must be {d}-{d}%", .{ compact_at_min, compact_at_max });
    var l = try load(host);
    defer l.deinit(host.gpa);
    if (!persisted(host)) {
        l.settings.graff_compact_at = pct;
        mirror(host, l.settings);
    } else try save(host, &l, "graffCompactAt", if (pct) |n| .{ .integer = n } else .null);
    return .{ .unary_json = try compactReply(host.gpa, pct) };
}

// ── title settings ─────────────────────────────────────────────────────────

fn titlesReply(gpa: Allocator, s: Settings) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"harness\":{f},\"model\":{f}}}", .{
        json.fmt(if (s.title_harness) |h| h.wire() else null, .{}),
        json.fmt(s.title_model, .{}),
    });
}

pub fn getTitleSettings(host: *EngineHost) !RpcOutcome {
    var l = try load(host);
    defer l.deinit(host.gpa);
    return .{ .unary_json = try titlesReply(host.gpa, l.settings) };
}

/// `SetTitleSettings { harness?, model? }` (`TitleSettings`, every field
/// defaulted): the harness must support titles and be enabled here; a model
/// needs a harness; a blank model is none.
pub fn setTitleSettings(host: *EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct TitleSettings", .{});
    var harness: ?HarnessId = null;
    if (o.get("harness")) |v| switch (v) {
        .null => {},
        // `known_harness_opt`: an id from a newer build reads as none.
        .string => |t| harness = HarnessId.parse(t),
        else => {},
    };
    var model: ?[]const u8 = null;
    if (o.get("model")) |v| switch (v) {
        .null => {},
        .string => |t| model = t,
        else => return badType(o, "model", "a string"),
    };
    if (harness) |id| {
        const io = host.io orelse return common.failedMsg("Choose an enabled harness that supports title generation");
        var prefs = try harnesses.loadPrefs(gpa, io, host.data_dir);
        defer prefs.deinit(gpa);
        const probed = try harnesses.probeAll(gpa, io);
        if (!supportsTitles(id) or !harnesses.enabledSet(&prefs, probed).contains(id))
            return common.failedMsg("Choose an enabled harness that supports title generation");
    } else if (model != null) {
        return common.failedMsg("Choose a title harness before choosing a model");
    }
    if (model) |m| if (std.mem.trim(u8, m, " \t\r\n").len == 0) {
        model = null;
    };

    var l = try load(host);
    defer l.deinit(gpa);
    if (!persisted(host)) {
        memory_title_harness = harness;
        if (model) |m| {
            const n = @min(m.len, memory_title_model_buf.len);
            @memcpy(memory_title_model_buf[0..n], m[0..n]);
            memory_title_model_len = n;
        } else memory_title_model_len = null;
    } else {
        var titles: json.ObjectMap = .empty;
        if (l.prefs.raw == null) l.prefs.raw = try json.parseFromSlice(json.Value, gpa, "{}", .{});
        const a = l.prefs.raw.?.arena.allocator();
        try titles.put(a, "harness", if (harness) |h| .{ .string = h.wire() } else .null);
        try titles.put(a, "model", if (model) |m| .{ .string = try a.dupe(u8, m) } else .null);
        try save(host, &l, "titles", .{ .object = titles });
    }
    return .{ .unary_json = try titlesReply(gpa, .{ .title_harness = harness, .title_model = model }) };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    data: []u8,
    env: common.TestEnv,
    host: EngineHost,

    fn init(f: *Fx) !void {
        const gpa = testing.allocator;
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, testing.io, &f.tmp);
        f.data = try std.fs.path.join(gpa, &.{ f.base, "data" });
        try f.tmp.dir.createDirPath(testing.io, "bin");
        try f.tmp.dir.createDirPath(testing.io, "home");
        const home = try std.fs.path.join(gpa, &.{ f.base, "home" });
        defer gpa.free(home);
        f.env = try common.TestEnv.init(gpa, home);
        const bin = try std.fs.path.join(gpa, &.{ f.base, "bin" });
        defer gpa.free(bin);
        try f.env.map.put("PATH", bin);
        try f.env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
        f.env.install();
        exes.system_prefix = f.base;
        try f.open();
    }

    /// A fresh engine over the same data folder: what a restart sees.
    fn open(f: *Fx) !void {
        f.host = try EngineHost.init(testing.allocator, "dev-settings", "Synthetic");
        f.host.io = testing.io;
        try f.host.setDataDir(f.data);
    }

    fn restart(f: *Fx) !void {
        f.host.deinit();
        try f.open();
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        f.host.deinit();
        keep_awake.release();
        f.env.deinit();
        exes.system_prefix = "";
        gpa.free(f.base);
        gpa.free(f.data);
        f.tmp.cleanup();
    }

    fn call(f: *Fx, method: []const u8, text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
        defer p.deinit();
        return f.host.handle(method, p.value);
    }

    fn expectOk(f: *Fx, method: []const u8, text: []const u8, want: []const u8) !void {
        const out = try f.call(method, text);
        switch (out) {
            .unary_json => |b| {
                defer testing.allocator.free(b);
                try testing.expectEqualStrings(want, b);
            },
            .err => |e| {
                std.debug.print("{s} failed: {any}\n", .{ method, e });
                return error.UnexpectedError;
            },
            else => return error.UnexpectedStream,
        }
    }

    fn exe(f: *Fx, name: []const u8) !void {
        const sub = try std.fmt.allocPrint(testing.allocator, "bin/{s}", .{name});
        defer testing.allocator.free(sub);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "#!/bin/sh\nexit 0\n", .flags = .{ .permissions = .executable_file } });
    }

    fn prefsFile(f: *Fx) !json.Parsed(json.Value) {
        const gpa = testing.allocator;
        const path = try std.fs.path.join(gpa, &.{ f.data, "harness-prefs.json" });
        defer gpa.free(path);
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 16));
        defer gpa.free(text);
        return json.parseFromSlice(json.Value, gpa, text, .{});
    }
};

fn expectErr(outcome: RpcOutcome, kind: enum { exec, bad }, want: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .exec_error => |m| {
                try testing.expect(kind == .exec);
                try testing.expectEqualStrings(want, m);
            },
            .bad_params => |m| {
                try testing.expect(kind == .bad);
                try testing.expectEqualStrings(want, m);
            },
            else => return error.UnexpectedErrorKind,
        },
        .unary_json => |b| {
            defer testing.allocator.free(b);
            std.debug.print("unexpected success: {s}\n", .{b});
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

test "rpcw_settings autonomy defaults to full access, persists, and survives a restart" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOk("GetAutonomy", "{}", "{\"autonomy\":\"full-access\",\"chosen\":false}");
    try testing.expectEqualStrings("full-access", f.host.autonomy_level);
    try f.expectOk("SetAutonomy", "{\"autonomy\":\"read-only\"}", "{\"autonomy\":\"read-only\",\"chosen\":true}");
    try testing.expectEqualStrings("read-only", f.host.autonomy_level);
    try f.restart();
    try testing.expectEqualStrings("read-only", f.host.autonomy_level); // runs see it at once
    try f.expectOk("GetAutonomy", "{}", "{\"autonomy\":\"read-only\",\"chosen\":true}");
    var saved = try f.prefsFile();
    defer saved.deinit();
    try testing.expectEqualStrings("read-only", saved.value.object.get("autonomy").?.string);

    try expectErr(try f.call("SetAutonomy", "{\"autonomy\":\"full\"}"), .bad, "unknown variant `full`, expected one of `read-only`, `workspace`, `full-access`");
    try expectErr(try f.call("SetAutonomy", "{}"), .bad, "missing field `autonomy`");
    try expectErr(try f.call("SetAutonomy", "{\"autonomy\":3}"), .bad, "invalid type: integer `3`, expected one of `read-only`, `workspace`, `full-access`");
}

test "rpcw_settings keep awake persists, follows working chats, and refuses where unsupported" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    keep_awake.Fake.reset();
    defer keep_awake.Fake.reset();
    const sup = if (keep_awake.supported) "true" else "false";
    try f.expectOk("GetKeepAwake", "{}", "{\"enabled\":false,\"supported\":" ++ sup ++ "}");
    if (!keep_awake.supported) {
        try expectErr(try f.call("SetKeepAwake", "{\"enabled\":true}"), .exec, "Keeping this computer awake is not supported");
        try f.expectOk("SetKeepAwake", "{\"enabled\":false}", "{\"enabled\":false,\"supported\":false}");
        return;
    }
    // A working chat on this device; the setting turns the assertion on.
    const r = try f.call("Mutate", "{\"op\":\"createChat\",\"chatId\":\"c1\",\"config\":{\"harness\":\"mock\"}}");
    if (r == .unary_json) testing.allocator.free(r.unary_json);
    for (f.host.chats.items) |*c| c.activity_status = try testing.allocator.dupe(u8, "working");
    try f.expectOk("SetKeepAwake", "{\"enabled\":true}", "{\"enabled\":true,\"supported\":true}");
    try testing.expectEqual(@as(usize, 1), keep_awake.Fake.holding);

    // Restart: the setting is read back; shutdown released the assertion.
    try f.restart();
    try testing.expectEqual(@as(usize, 0), keep_awake.Fake.holding);
    try testing.expect(f.host.keep_awake_enabled);
    try f.expectOk("GetKeepAwake", "{}", "{\"enabled\":true,\"supported\":true}");
    try f.expectOk("SetKeepAwake", "{\"enabled\":false}", "{\"enabled\":false,\"supported\":true}");
    try f.restart();
    try f.expectOk("GetKeepAwake", "{}", "{\"enabled\":false,\"supported\":true}");

    try expectErr(try f.call("SetKeepAwake", "{}"), .bad, "missing field `enabled`");
    try expectErr(try f.call("SetKeepAwake", "{\"enabled\":\"yes\"}"), .bad, "invalid type: string \"yes\", expected a boolean");
}

test "rpcw_settings graff draft subagents and compact-at persist with Rust's names and rules" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOk("GetGraffDraftSubagents", "{}", "false");
    try f.expectOk("GetGraffCompactAt", "{}", "null");
    try testing.expectEqual(@as(i64, 0), f.host.graff_compact_at);

    try f.expectOk("SetGraffDraftSubagents", "{\"enabled\":true}", "true");
    try f.expectOk("SetGraffCompactAt", "{\"pct\":70}", "70");
    try f.restart();
    try testing.expect(f.host.graff_draft_subagents);
    try testing.expectEqual(@as(i64, 70), f.host.graff_compact_at);
    try f.expectOk("GetGraffDraftSubagents", "{}", "true");
    try f.expectOk("GetGraffCompactAt", "{}", "70");
    {
        var saved = try f.prefsFile();
        defer saved.deinit();
        try testing.expectEqual(@as(i64, 70), saved.value.object.get("graffCompactAt").?.integer);
        try testing.expect(saved.value.object.get("graffDraftSubagents").?.bool);
    }

    // `null` (or no pct) restores graff's default and drops the field.
    try f.expectOk("SetGraffCompactAt", "{\"pct\":null}", "null");
    try f.restart();
    try f.expectOk("GetGraffCompactAt", "{}", "null");
    try testing.expectEqual(@as(i64, 0), f.host.graff_compact_at);
    {
        var saved = try f.prefsFile();
        defer saved.deinit();
        try testing.expect(saved.value.object.get("graffCompactAt") == null);
    }

    try expectErr(try f.call("SetGraffCompactAt", "{\"pct\":5}"), .exec, "compaction point must be 10-95%");
    try expectErr(try f.call("SetGraffCompactAt", "{\"pct\":300}"), .bad, "invalid value: integer `300`, expected u8");
    try expectErr(try f.call("SetGraffDraftSubagents", "{}"), .bad, "missing field `enabled`");
    // The old Zig field name is not Rust's: `percent` is ignored, so this resets.
    try f.expectOk("SetGraffCompactAt", "{\"percent\":40}", "null");
}

test "rpcw_settings title settings validate the harness, persist, and keep agent opt-outs" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.exe("codex");
    try f.exe("graff");
    try f.expectOk("GetTitleSettings", "{}", "{\"harness\":null,\"model\":null}");
    try f.expectOk("SetTitleSettings", "{\"harness\":\"codex\",\"model\":\"  \"}", "{\"harness\":\"codex\",\"model\":null}");
    try f.expectOk("SetTitleSettings", "{\"harness\":\"codex\",\"model\":\"synthetic-mini\"}", "{\"harness\":\"codex\",\"model\":\"synthetic-mini\"}");
    // The agent opt-outs written alongside stay put.
    const off = try f.call("SetHarnessEnabled", "{\"harness\":\"graff\",\"enabled\":false}");
    testing.allocator.free(off.unary_json);
    try f.restart();
    try f.expectOk("GetTitleSettings", "{}", "{\"harness\":\"codex\",\"model\":\"synthetic-mini\"}");
    {
        var saved = try f.prefsFile();
        defer saved.deinit();
        try testing.expectEqualStrings("graff", saved.value.object.get("disabled").?.array.items[0].string);
        try testing.expectEqualStrings("synthetic-mini", saved.value.object.get("titles").?.object.get("model").?.string);
    }

    try expectErr(try f.call("SetTitleSettings", "{\"harness\":\"graff\"}"), .exec, "Choose an enabled harness that supports title generation");
    try expectErr(try f.call("SetTitleSettings", "{\"harness\":\"claude-code\"}"), .exec, "Choose an enabled harness that supports title generation");
    try expectErr(try f.call("SetTitleSettings", "{\"model\":\"m\"}"), .exec, "Choose a title harness before choosing a model");
    try f.expectOk("SetTitleSettings", "{}", "{\"harness\":null,\"model\":null}");
    try f.restart();
    try f.expectOk("GetTitleSettings", "{}", "{\"harness\":null,\"model\":null}");
}

test "rpcw_settings reads a prefs file in the Rust engine's shape" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "data");
    try f.tmp.dir.writeFile(testing.io, .{
        .sub_path = "data/harness-prefs.json",
        .data =
        \\{
        \\  "disabled": ["codex"],
        \\  "titles": { "harness": "future-agent", "model": null },
        \\  "autonomy": "workspace",
        \\  "graffDraftSubagents": true,
        \\  "keepAwake": false,
        \\  "graffCompactAt": 120
        \\}
        ,
    });
    try f.restart();
    try testing.expectEqualStrings("workspace", f.host.autonomy_level);
    try testing.expectEqual(@as(i64, 0), f.host.graff_compact_at); // out of range: graff's default for runs
    try f.expectOk("GetGraffCompactAt", "{}", "120"); // the stored value, as Rust reports it
    try f.expectOk("GetTitleSettings", "{}", "{\"harness\":null,\"model\":null}");
    try f.expectOk("GetAutonomy", "{}", "{\"autonomy\":\"workspace\",\"chosen\":true}");

    // A field of the wrong type fails the whole file, which reads as defaults.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/harness-prefs.json", .data = "{\"keepAwake\":\"yes\",\"autonomy\":\"read-only\"}" });
    try f.expectOk("GetAutonomy", "{}", "{\"autonomy\":\"full-access\",\"chosen\":false}");
}

test "rpcw_settings without a data folder keeps settings in memory" {
    const gpa = testing.allocator;
    resetMemory();
    defer resetMemory();
    var host = try EngineHost.init(gpa, "dev-mem", "Synthetic");
    defer host.deinit();
    const call = struct {
        fn f(h: *EngineHost, m: []const u8, t: []const u8) ![]u8 {
            var p = try json.parseFromSlice(json.Value, testing.allocator, t, .{});
            defer p.deinit();
            const out = try h.handle(m, p.value);
            return out.unary_json;
        }
    }.f;
    const a = try call(&host, "GetAutonomy", "{}");
    defer gpa.free(a);
    try testing.expectEqualStrings("{\"autonomy\":\"full-access\",\"chosen\":false}", a);
    const b = try call(&host, "SetAutonomy", "{\"autonomy\":\"workspace\"}");
    defer gpa.free(b);
    const c = try call(&host, "GetAutonomy", "{}");
    defer gpa.free(c);
    try testing.expectEqualStrings("{\"autonomy\":\"workspace\",\"chosen\":true}", c);
    const d = try call(&host, "SetGraffCompactAt", "{\"pct\":50}");
    defer gpa.free(d);
    const e = try call(&host, "GetGraffCompactAt", "{}");
    defer gpa.free(e);
    try testing.expectEqualStrings("50", e);
}
