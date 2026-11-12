//! `ListHarnesses`, `SetHarnessEnabled` and `CancelInstall`, ported from
//! `crates/engine/src/registry.rs` (`HarnessRegistry::descriptors`,
//! `enabled_set`, `set_enabled`, `harness-prefs.json`, the legacy allow-list
//! migration) and `crates/engine/src/rpc.rs`.
//!
//! The catalog order and static descriptors are `default_registry()`'s; the
//! `installed` and `canInstall` columns come from real probes on this device
//! (`rpcw_executables.zig`). Enablement persists in `{data_dir}/harness-prefs.json`
//! as opt-outs (`disabled`) and opt-ins (`optedIn`), the same file the Rust
//! engine reads.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const exes = @import("rpcw_executables.zig");
const engine_host = @import("engine_host.zig");

const HarnessId = exes.HarnessId;
const RpcOutcome = common.RpcOutcome;

pub const SteeringMode = enum { step_boundary, turn_boundary };

pub const Descriptor = struct {
    id: HarnessId,
    name: []const u8,
    supports_steering: bool,
    steering_mode: SteeringMode,
    reasoning_levels: []const []const u8,
};

/// `default_registry()`'s registration order and static descriptors.
pub const catalog = [_]Descriptor{
    .{ .id = .mock, .name = "Mock", .supports_steering = true, .steering_mode = .step_boundary, .reasoning_levels = &.{"medium"} },
    .{ .id = .graff, .name = "graff", .supports_steering = true, .steering_mode = .step_boundary, .reasoning_levels = &.{ "low", "medium", "high", "xhigh", "max", "ultra" } },
    .{ .id = .claude_code, .name = "Claude Code", .supports_steering = true, .steering_mode = .step_boundary, .reasoning_levels = &.{ "low", "medium", "high", "xhigh", "max" } },
    .{ .id = .codex, .name = "Codex", .supports_steering = true, .steering_mode = .step_boundary, .reasoning_levels = &.{ "minimal", "low", "medium", "high", "xhigh", "max", "ultra" } },
    .{ .id = .cursor, .name = "Cursor", .supports_steering = true, .steering_mode = .turn_boundary, .reasoning_levels = &.{} },
    .{ .id = .devin, .name = "Devin", .supports_steering = true, .steering_mode = .turn_boundary, .reasoning_levels = &.{} },
    .{ .id = .grok, .name = "Grok", .supports_steering = true, .steering_mode = .turn_boundary, .reasoning_levels = &.{ "low", "medium", "high", "xhigh" } },
    .{ .id = .hermes, .name = "Hermes", .supports_steering = true, .steering_mode = .turn_boundary, .reasoning_levels = &.{} },
    .{ .id = .pi, .name = "Pi", .supports_steering = true, .steering_mode = .step_boundary, .reasoning_levels = &.{} },
    .{ .id = .opencode, .name = "OpenCode", .supports_steering = true, .steering_mode = .turn_boundary, .reasoning_levels = &.{ "low", "medium", "high", "xhigh", "max" } },
    .{ .id = .antigravity, .name = "Antigravity", .supports_steering = true, .steering_mode = .turn_boundary, .reasoning_levels = &.{} },
    .{ .id = .exo, .name = "Exo", .supports_steering = true, .steering_mode = .turn_boundary, .reasoning_levels = &.{} },
};

/// `auto_enabled`: detection alone never switches the mock on.
pub fn autoEnabled(id: HarnessId) bool {
    return id != .mock;
}

/// `default_on`: found ⇒ on unless switched off.
pub fn defaultOn(id: HarnessId) bool {
    return id == .graff or id == .codex or id == .claude_code;
}

// ── prefs ──────────────────────────────────────────────────────────────────

pub const IdSet = std.EnumSet(HarnessId);

pub const Prefs = struct {
    /// Ordered as written; a set view answers membership.
    disabled: std.ArrayList(HarnessId) = .empty,
    opted_in: std.ArrayList(HarnessId) = .empty,
    /// The parsed file, kept to write the other settings back unchanged.
    raw: ?json.Parsed(json.Value) = null,

    pub fn deinit(self: *Prefs, gpa: Allocator) void {
        self.disabled.deinit(gpa);
        self.opted_in.deinit(gpa);
        if (self.raw) |*r| r.deinit();
    }

    fn contains(list: []const HarnessId, id: HarnessId) bool {
        return std.mem.indexOfScalar(HarnessId, list, id) != null;
    }
};

/// Process memory for an engine without a data dir (Rust's `prefs_path: None`).
var memory_disabled: IdSet = .empty;
var memory_opted_in: IdSet = .empty;

fn prefsPath(gpa: Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, "harness-prefs.json" });
}

/// `known_harnesses`: ids from a newer build are skipped, not fatal.
fn readIds(gpa: Allocator, v: ?json.Value, out: *std.ArrayList(HarnessId)) !void {
    const arr = v orelse return;
    if (arr != .array) return;
    for (arr.array.items) |item| {
        if (item != .string) continue;
        const id = HarnessId.parse(item.string) orelse continue;
        try out.append(gpa, id);
    }
}

/// `load_prefs` + `migrate_legacy_prefs`. A corrupt or missing file is the
/// default set.
pub fn loadPrefs(gpa: Allocator, io: std.Io, data_dir: ?[]const u8) !Prefs {
    var prefs: Prefs = .{};
    errdefer prefs.deinit(gpa);
    const dir = data_dir orelse {
        var it = memory_disabled.iterator();
        while (it.next()) |id| try prefs.disabled.append(gpa, id);
        var it2 = memory_opted_in.iterator();
        while (it2.next()) |id| try prefs.opted_in.append(gpa, id);
        return prefs;
    };
    const path = try prefsPath(gpa, dir);
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return prefs;
    defer gpa.free(text);
    const parsed = json.parseFromSlice(json.Value, gpa, text, .{}) catch return prefs;
    if (parsed.value != .object) {
        parsed.deinit();
        return prefs;
    }
    prefs.raw = parsed;
    const o = parsed.value.object;
    try readIds(gpa, o.get("disabled"), &prefs.disabled);
    try readIds(gpa, o.get("optedIn"), &prefs.opted_in);
    if (o.get("enabled")) |legacy_v| if (legacy_v == .array) {
        var legacy: std.ArrayList(HarnessId) = .empty;
        defer legacy.deinit(gpa);
        try readIds(gpa, legacy_v, &legacy);
        prefs.disabled.clearRetainingCapacity();
        prefs.opted_in.clearRetainingCapacity();
        for (catalog) |d| {
            if (defaultOn(d.id) and !Prefs.contains(legacy.items, d.id)) try prefs.disabled.append(gpa, d.id);
        }
        for (legacy.items) |id| {
            if (autoEnabled(id) and !defaultOn(id) and !Prefs.contains(prefs.opted_in.items, id)) try prefs.opted_in.append(gpa, id);
        }
        persistPrefs(gpa, io, data_dir, &prefs);
    };
    return prefs;
}

fn writeIdArray(s: *json.Stringify, ids: []const HarnessId) !void {
    try s.beginArray();
    for (ids) |id| try s.write(id.wire());
    try s.endArray();
}

/// `persist_prefs`: the prefs file's fields in serde order, written to a
/// temporary file and renamed into place. Best effort, like Rust's.
pub fn persistPrefs(gpa: Allocator, io: std.Io, data_dir: ?[]const u8, prefs: *const Prefs) void {
    const dir = data_dir orelse {
        memory_disabled = .empty;
        memory_opted_in = .empty;
        for (prefs.disabled.items) |id| memory_disabled.insert(id);
        for (prefs.opted_in.items) |id| memory_opted_in.insert(id);
        return;
    };
    persistPrefsFile(gpa, io, dir, prefs) catch {};
}

fn persistPrefsFile(gpa: Allocator, io: std.Io, dir: []const u8, prefs: *const Prefs) !void {
    const raw_obj: ?json.ObjectMap = if (prefs.raw) |r| r.value.object else null;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("disabled");
    try writeIdArray(&s, prefs.disabled.items);
    if (prefs.opted_in.items.len > 0) {
        try s.objectField("optedIn");
        try writeIdArray(&s, prefs.opted_in.items);
    }
    try s.objectField("titles");
    const titles: ?json.Value = if (raw_obj) |o| o.get("titles") else null;
    if (titles != null and titles.? == .object) try s.write(titles.?) else try writeDefaultTitles(&s);
    if (raw_obj) |o| if (o.get("autonomy")) |a| if (a != .null) {
        try s.objectField("autonomy");
        try s.write(a);
    };
    try s.objectField("graffDraftSubagents");
    try s.write(if (raw_obj) |o| (if (o.get("graffDraftSubagents")) |v| (v == .bool and v.bool) else false) else false);
    try s.objectField("keepAwake");
    try s.write(if (raw_obj) |o| (if (o.get("keepAwake")) |v| (v == .bool and v.bool) else false) else false);
    if (raw_obj) |o| if (o.get("graffCompactAt")) |v| if (v == .integer) {
        try s.objectField("graffCompactAt");
        try s.write(v);
    };
    try s.endObject();

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try prefsPath(gpa, dir);
    defer gpa.free(path);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = aw.written() });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}

fn writeDefaultTitles(s: *json.Stringify) !void {
    try s.beginObject();
    try s.objectField("harness");
    try s.write(null);
    try s.objectField("model");
    try s.write(null);
    try s.endObject();
}

// ── the registry view ──────────────────────────────────────────────────────

pub const Probed = struct {
    installed: IdSet = .empty,
};

pub fn probeAll(gpa: Allocator, io: std.Io) !Probed {
    var p: Probed = .{};
    for (catalog) |d| {
        if (try exes.installed(gpa, io, d.id)) p.installed.insert(d.id);
    }
    return p;
}

/// `enabled_set`.
pub fn enabledSet(prefs: *const Prefs, probed: Probed) IdSet {
    var set: IdSet = .empty;
    for (catalog) |d| {
        const id = d.id;
        if (autoEnabled(id) and !Prefs.contains(prefs.disabled.items, id) and
            (defaultOn(id) or Prefs.contains(prefs.opted_in.items, id)) and probed.installed.contains(id))
        {
            set.insert(id);
        }
    }
    return set;
}

/// `HarnessRegistry::descriptors()` as the `ListHarnesses` JSON array.
pub fn descriptorsJson(gpa: Allocator, io: std.Io, data_dir: ?[]const u8) ![]u8 {
    var prefs = try loadPrefs(gpa, io, data_dir);
    defer prefs.deinit(gpa);
    const probed = try probeAll(gpa, io);
    return writeDescriptors(gpa, io, &prefs, probed);
}

fn writeDescriptors(gpa: Allocator, io: std.Io, prefs: *const Prefs, probed: Probed) ![]u8 {
    const enabled = enabledSet(prefs, probed);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    for (catalog, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"name\":{f},\"supportsSteering\":{},\"steeringMode\":\"{s}\",\"reasoningLevels\":[", .{
            d.id.wire(),
            json.fmt(d.name, .{}),
            d.supports_steering,
            if (d.steering_mode == .step_boundary) "step-boundary" else "turn-boundary",
        });
        for (d.reasoning_levels, 0..) |lvl, j| {
            if (j > 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{lvl});
        }
        try w.print("],\"installed\":{},\"canInstall\":{},\"enabled\":{}}}", .{
            probed.installed.contains(d.id),
            exes.canInstall(gpa, io, d.id),
            enabled.contains(d.id),
        });
    }
    try w.writeByte(']');
    return aw.toOwnedSlice();
}

pub const SetEnabledError = union(enum) { failed: []const u8 };

/// `HarnessRegistry::set_enabled`.
pub fn setEnabled(gpa: Allocator, io: std.Io, data_dir: ?[]const u8, prefs: *Prefs, probed: Probed, id: HarnessId, on: bool) !?[]const u8 {
    if (on and !autoEnabled(id)) return common.errText("{s} cannot be enabled from Settings", .{id.debugName()});
    if (on and !probed.installed.contains(id)) return common.errText("{s} CLI is not installed on this device", .{id.debugName()});
    const enabled = enabledSet(prefs, probed);
    const is_on = enabled.contains(id);
    if (on and !is_on) {
        removeId(&prefs.disabled, id);
        if (!defaultOn(id) and !Prefs.contains(prefs.opted_in.items, id)) try prefs.opted_in.append(gpa, id);
    } else if (!on and is_on) {
        if (enabled.count() == 1) return "cannot disable the last enabled harness";
        removeId(&prefs.opted_in, id);
        if (defaultOn(id) and !Prefs.contains(prefs.disabled.items, id)) try prefs.disabled.append(gpa, id);
    } else return null;
    persistPrefs(gpa, io, data_dir, prefs);
    return null;
}

fn removeId(list: *std.ArrayList(HarnessId), id: HarnessId) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == id) _ = list.orderedRemove(i) else i += 1;
    }
}

const HarnessParam = union(enum) { ok: HarnessId, err: RpcOutcome };

fn harnessParam(o: json.ObjectMap) HarnessParam {
    const v = o.get("harness") orelse return .{ .err = common.badParams("missing field `harness`", .{}) };
    if (v != .string) return .{ .err = common.badParams("invalid type: expected a harness id for `harness`", .{}) };
    const id = HarnessId.parse(v.string) orelse return .{ .err = .{ .err = .{ .bad_params = exes.unknownVariantText(v.string) } } };
    return .{ .ok = id };
}

// ── RPCs ───────────────────────────────────────────────────────────────────

pub fn listHarnesses(host: *engine_host.EngineHost) !RpcOutcome {
    const io = host.io orelse return common.failed("harness probes need I/O", .{});
    return .{ .unary_json = try descriptorsJson(host.gpa, io, host.data_dir) };
}

/// `SetHarnessEnabled { harness, enabled }` → the fresh catalog.
pub fn setHarnessEnabled(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct SetHarnessEnabledParams", .{});
    const id = switch (harnessParam(o)) {
        .ok => |id| id,
        .err => |e| return e,
    };
    const on = common.boolField(o, "enabled") orelse
        return if (o.get("enabled") == null) common.badParams("missing field `enabled`", .{}) else common.badParams("invalid type: expected a boolean for `enabled`", .{});
    const io = host.io orelse return common.failed("harness probes need I/O", .{});
    var prefs = try loadPrefs(gpa, io, host.data_dir);
    defer prefs.deinit(gpa);
    const probed = try probeAll(gpa, io);
    if (try setEnabled(gpa, io, host.data_dir, &prefs, probed, id, on)) |m| return .{ .err = .{ .exec_error = m } };
    return .{ .unary_json = try writeDescriptors(gpa, io, &prefs, probed) };
}

/// `CancelInstall { harness }` → `{}`: cancels this device's running install
/// of that harness. This engine never has one running (it does not run
/// installers yet), so the reply is all there is.
pub fn cancelInstall(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct ListModelsParams", .{});
    switch (harnessParam(o)) {
        .ok => {},
        .err => |e| return e,
    }
    if (o.get("force")) |f| if (f != .bool and f != .null) return common.badParams("invalid type: expected a boolean for `force`", .{});
    return .{ .unary_json = try host.gpa.dupe(u8, "{}") };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    data: []u8,
    env: common.TestEnv,
    host: engine_host.EngineHost,

    fn init() !*Fx {
        const gpa = testing.allocator;
        const io = testing.io;
        const f = try gpa.create(Fx);
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, io, &f.tmp);
        f.data = try std.fs.path.join(gpa, &.{ f.base, "data" });
        try f.tmp.dir.createDirPath(io, "bin");
        try f.tmp.dir.createDirPath(io, "home");
        try f.tmp.dir.createDirPath(io, "data");
        const home = try std.fs.path.join(gpa, &.{ f.base, "home" });
        defer gpa.free(home);
        f.env = try common.TestEnv.init(gpa, home);
        const bin = try std.fs.path.join(gpa, &.{ f.base, "bin" });
        defer gpa.free(bin);
        try f.env.map.put("PATH", bin);
        try f.env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
        f.env.install();
        exes.system_prefix = f.base;
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = io;
        try f.host.setDataDir(f.data);
        return f;
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        f.host.deinit();
        f.env.deinit();
        exes.system_prefix = "";
        gpa.free(f.base);
        gpa.free(f.data);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    fn exe(f: *Fx, name: []const u8) !void {
        const io = testing.io;
        const sub = try std.fmt.allocPrint(testing.allocator, "bin/{s}", .{name});
        defer testing.allocator.free(sub);
        try f.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "#!/bin/sh\nexit 0\n", .flags = .{ .permissions = .executable_file } });
    }

    fn call(f: *Fx, method: []const u8, params_text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        return f.host.handle(method, p.value);
    }

    fn row(parsed: json.Parsed(json.Value), id: []const u8) json.ObjectMap {
        for (parsed.value.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("id").?.string, id)) return r.object;
        }
        unreachable;
    }
};

fn expectFailed(outcome: RpcOutcome, kind: enum { exec, bad }, expected: []const u8) !void {
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

test "rpcw_harnesses ListHarnesses reports detected CLIs, installers and enablement" {
    const f = try Fx.init();
    defer f.deinit();
    const gpa = testing.allocator;
    try f.exe("codex");
    try f.exe("cursor-agent");

    const out = try f.call("ListHarnesses", "{}");
    defer gpa.free(out.unary_json);
    var parsed = try json.parseFromSlice(json.Value, gpa, out.unary_json, .{});
    defer parsed.deinit();
    const ids = [_][]const u8{ "mock", "graff", "claude-code", "codex", "cursor", "devin", "grok", "hermes", "pi", "opencode", "antigravity", "exo" };
    try testing.expectEqual(ids.len, parsed.value.array.items.len);
    for (ids, parsed.value.array.items) |id, r| try testing.expectEqualStrings(id, r.object.get("id").?.string);

    const codex = Fx.row(parsed, "codex");
    try testing.expectEqualStrings("Codex", codex.get("name").?.string);
    try testing.expectEqualStrings("step-boundary", codex.get("steeringMode").?.string);
    try testing.expectEqual(@as(usize, 7), codex.get("reasoningLevels").?.array.items.len);
    try testing.expect(codex.get("installed").?.bool);
    try testing.expect(codex.get("enabled").?.bool); // default-on and found
    try testing.expect(!codex.get("canInstall").?.bool); // no sh/curl/npm on this PATH

    const cursor = Fx.row(parsed, "cursor");
    try testing.expect(cursor.get("installed").?.bool);
    try testing.expect(!cursor.get("enabled").?.bool); // off by default until opted in
    try testing.expectEqualStrings("turn-boundary", cursor.get("steeringMode").?.string);

    const claude = Fx.row(parsed, "claude-code");
    try testing.expect(!claude.get("installed").?.bool);
    try testing.expect(!claude.get("enabled").?.bool);

    const mock = Fx.row(parsed, "mock");
    try testing.expect(mock.get("installed").?.bool);
    try testing.expect(!mock.get("enabled").?.bool);

    // Installer prerequisites on PATH turn on canInstall.
    try f.exe("sh");
    try f.exe("curl");
    try f.exe("bash");
    try f.exe("tar");
    const out2 = try f.call("ListHarnesses", "{}");
    defer gpa.free(out2.unary_json);
    var parsed2 = try json.parseFromSlice(json.Value, gpa, out2.unary_json, .{});
    defer parsed2.deinit();
    try testing.expect(Fx.row(parsed2, "claude-code").get("canInstall").?.bool);
    try testing.expect(Fx.row(parsed2, "graff").get("canInstall").?.bool);
    try testing.expect(!Fx.row(parsed2, "exo").get("canInstall").?.bool);
    try testing.expect(!Fx.row(parsed2, "mock").get("canInstall").?.bool);
}

test "rpcw_harnesses SetHarnessEnabled persists opt-ins and opt-outs and guards the last agent" {
    const f = try Fx.init();
    defer f.deinit();
    const gpa = testing.allocator;
    try f.exe("codex");
    try f.exe("cursor-agent");

    // Opt in an off-by-default agent.
    const on = try f.call("SetHarnessEnabled", "{\"harness\":\"cursor\",\"enabled\":true}");
    defer gpa.free(on.unary_json);
    var p1 = try json.parseFromSlice(json.Value, gpa, on.unary_json, .{});
    defer p1.deinit();
    try testing.expect(Fx.row(p1, "cursor").get("enabled").?.bool);

    // Opt out a default-on agent.
    const off = try f.call("SetHarnessEnabled", "{\"harness\":\"codex\",\"enabled\":false}");
    defer gpa.free(off.unary_json);
    var p2 = try json.parseFromSlice(json.Value, gpa, off.unary_json, .{});
    defer p2.deinit();
    try testing.expect(!Fx.row(p2, "codex").get("enabled").?.bool);

    const prefs_path = try std.fs.path.join(gpa, &.{ f.data, "harness-prefs.json" });
    defer gpa.free(prefs_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, prefs_path, gpa, .limited(1 << 16));
    defer gpa.free(text);
    var saved = try json.parseFromSlice(json.Value, gpa, text, .{});
    defer saved.deinit();
    try testing.expectEqualStrings("codex", saved.value.object.get("disabled").?.array.items[0].string);
    try testing.expectEqualStrings("cursor", saved.value.object.get("optedIn").?.array.items[0].string);
    try testing.expect(saved.value.object.get("titles").? == .object);
    try testing.expect(!saved.value.object.get("keepAwake").?.bool);

    // The last enabled agent stays on.
    try expectFailed(try f.call("SetHarnessEnabled", "{\"harness\":\"cursor\",\"enabled\":false}"), .exec, "cannot disable the last enabled harness");
    // Not installed, the mock, and bad params.
    try expectFailed(try f.call("SetHarnessEnabled", "{\"harness\":\"grok\",\"enabled\":true}"), .exec, "Grok CLI is not installed on this device");
    try expectFailed(try f.call("SetHarnessEnabled", "{\"harness\":\"mock\",\"enabled\":true}"), .exec, "Mock cannot be enabled from Settings");
    try expectFailed(try f.call("SetHarnessEnabled", "{\"enabled\":true}"), .bad, "missing field `harness`");
    try expectFailed(try f.call("SetHarnessEnabled", "{\"harness\":\"codex\"}"), .bad, "missing field `enabled`");
    try expectFailed(
        try f.call("SetHarnessEnabled", "{\"harness\":\"nope\",\"enabled\":true}"),
        .bad,
        "unknown variant `nope`, expected one of `claude-code`, `codex`, `cursor`, `devin`, `grok`, `hermes`, `graff`, `pi`, `opencode`, `antigravity`, `exo`, `mock`",
    );
    // Turning off something already off is a clean no-op.
    const noop = try f.call("SetHarnessEnabled", "{\"harness\":\"grok\",\"enabled\":false}");
    gpa.free(noop.unary_json);
}

test "rpcw_harnesses migrates a legacy allow-list and skips unknown ids" {
    const f = try Fx.init();
    defer f.deinit();
    const gpa = testing.allocator;
    try f.exe("codex");
    try f.exe("graff");
    try f.exe("cursor-agent");
    try f.tmp.dir.writeFile(testing.io, .{
        .sub_path = "data/harness-prefs.json",
        .data = "{\"enabled\":[\"graff\",\"cursor\",\"future-agent\"],\"keepAwake\":true,\"autonomy\":\"read-only\"}",
    });
    const out = try f.call("ListHarnesses", "{}");
    defer gpa.free(out.unary_json);
    var parsed = try json.parseFromSlice(json.Value, gpa, out.unary_json, .{});
    defer parsed.deinit();
    try testing.expect(Fx.row(parsed, "graff").get("enabled").?.bool);
    try testing.expect(Fx.row(parsed, "cursor").get("enabled").?.bool);
    try testing.expect(!Fx.row(parsed, "codex").get("enabled").?.bool);

    const prefs_path = try std.fs.path.join(gpa, &.{ f.data, "harness-prefs.json" });
    defer gpa.free(prefs_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, prefs_path, gpa, .limited(1 << 16));
    defer gpa.free(text);
    var saved = try json.parseFromSlice(json.Value, gpa, text, .{});
    defer saved.deinit();
    const o = saved.value.object;
    try testing.expect(o.get("enabled") == null);
    try testing.expect(o.get("keepAwake").?.bool);
    try testing.expectEqualStrings("read-only", o.get("autonomy").?.string);
    try testing.expectEqual(@as(usize, 2), o.get("disabled").?.array.items.len); // claude-code, codex
}

test "rpcw_harnesses CancelInstall replies {} and validates the harness" {
    const f = try Fx.init();
    defer f.deinit();
    const out = try f.call("CancelInstall", "{\"harness\":\"codex\"}");
    defer testing.allocator.free(out.unary_json);
    try testing.expectEqualStrings("{}", out.unary_json);
    try expectFailed(try f.call("CancelInstall", "{}"), .bad, "missing field `harness`");
}
