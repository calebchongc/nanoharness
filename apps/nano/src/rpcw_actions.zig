//! Project Actions, ported from `crates/engine/src/project_actions.rs`
//! (`ProjectActionsStore`, `harness.json` imports, setup handoffs, launching)
//! and the `ListProjectActions`, `UpsertProjectAction`, `DeleteProjectAction`,
//! `RunProjectAction` and `TakeProjectActionSetup` arms of
//! `crates/engine/src/rpc.rs`.
//!
//! Actions are stored outside the synced registry, in the engine profile's
//! store root: `{data}/profiles/local/project-actions.json` signed out,
//! `{data}/orgs/{org}/{user}/project-actions.json` signed in (`profile.rs`),
//! in Rust's `ProjectActionsFile` shape (`version` 1, `projects` by space id).
//!
//! Running an action opens a terminal session in the engine's PTY terminal
//! manager (`terminals_host.zig`), as Rust's `Terminals::open_with_command`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const agent_proc = @import("agent_proc.zig");

const RpcOutcome = common.RpcOutcome;
const EngineHost = engine_host.EngineHost;

pub const max_actions: usize = 50;
pub const max_name_chars: usize = 80;
pub const max_command_bytes: usize = 16 * 1024;
pub const max_id_bytes: usize = 96;
const store_file = "project-actions.json";
const store_version: i64 = 1;
const project_file = "harness.json";
const max_project_file_bytes: usize = 256 * 1024;
const setup_handoff_ttl_ms: i64 = 10 * 60 * 1000;
/// `MAX_TERMINALS` in `terminals.rs`.
const max_terminals: usize = 32;

pub const Icon = enum {
    play,
    @"test",
    lint,
    configure,
    build,
    debug,

    pub fn parse(t: []const u8) ?Icon {
        return std.meta.stringToEnum(Icon, t);
    }
};

const icon_variants = "`play`, `test`, `lint`, `configure`, `build`, `debug`";

pub const Action = struct {
    id: []const u8,
    name: []const u8,
    command: []const u8,
    icon: Icon,
    run_on_worktree_create: bool,
};

pub const Draft = struct {
    name: []const u8,
    command: []const u8,
    icon: Icon,
    run_on_worktree_create: bool = false,
};

// ── store root ─────────────────────────────────────────────────────────────

/// `sanitize_path_id`.
fn sanitizePathId(a: Allocator, id: []const u8) ![]u8 {
    const out = try a.dupe(u8, id);
    for (out) |*c| {
        if (!(std.ascii.isAlphanumeric(c.*) or c.* == '-' or c.* == '_')) c.* = '_';
    }
    return out;
}

/// `EngineProfile::store_root`: the local profile when signed out, else the
/// account's folder.
pub fn storeRoot(a: Allocator, host: *const EngineHost) !?[]u8 {
    const data = host.data_dir orelse return null;
    const local = std.mem.eql(u8, host.workspace_scope, "local") or !host.auth.signed_in or host.auth.org_id == null;
    if (local) return try std.fs.path.join(a, &.{ data, "profiles", "local" });
    return try std.fs.path.join(a, &.{ data, "orgs", try sanitizePathId(a, host.auth.org_id.?), try sanitizePathId(a, host.auth.user_id) });
}

// ── the store file ─────────────────────────────────────────────────────────

const Project = struct {
    root: []const u8,
    actions: std.ArrayList(Action) = .empty,
};

/// `ProjectActionsFile`, in an arena.
const StoreFile = struct {
    /// Space ids in `BTreeMap` order once written.
    projects: std.StringArrayHashMapUnmanaged(Project) = .empty,

    fn get(self: *StoreFile, space_id: []const u8) ?*Project {
        return self.projects.getPtr(space_id);
    }
};

fn str(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// `ProjectActionsStore::open`'s read: a missing, corrupt or other-version
/// file is empty; any other read failure is an error.
fn readStore(a: Allocator, io: std.Io, path: []const u8) !StoreFile {
    var file: StoreFile = .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => return file,
        else => return e,
    };
    const v = json.parseFromSliceLeaky(json.Value, a, bytes, .{}) catch {
        std.log.warn("invalid project Actions store; starting empty: {s}", .{path});
        return file;
    };
    if (v != .object) return file;
    const ver = v.object.get("version") orelse return .{};
    if (ver != .integer) return .{};
    if (ver.integer != store_version) {
        std.log.warn("unsupported project Actions store version {d}; starting empty", .{ver.integer});
        return file;
    }
    const projects = v.object.get("projects") orelse return file;
    if (projects != .object) return .{};
    var it = projects.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) return .{};
        const po = e.value_ptr.object;
        const root = str(po, "projectRoot") orelse return .{};
        var project: Project = .{ .root = root };
        if (po.get("actions")) |acts| {
            if (acts != .array) return .{};
            for (acts.array.items) |av| {
                if (av != .object) return .{};
                const ao = av.object;
                const icon_v = str(ao, "icon") orelse return .{};
                const rowc = ao.get("runOnWorktreeCreate") orelse return .{};
                if (rowc != .bool) return .{};
                try project.actions.append(a, .{
                    .id = str(ao, "id") orelse return .{},
                    .name = str(ao, "name") orelse return .{},
                    .command = str(ao, "command") orelse return .{},
                    .icon = Icon.parse(icon_v) orelse return .{},
                    .run_on_worktree_create = rowc.bool,
                });
            }
        }
        try file.projects.put(a, e.key_ptr.*, project);
    }
    return file;
}

fn writeAction(s: *json.Stringify, act: Action) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(act.id);
    try s.objectField("name");
    try s.write(act.name);
    try s.objectField("command");
    try s.write(act.command);
    try s.objectField("icon");
    try s.write(@tagName(act.icon));
    try s.objectField("runOnWorktreeCreate");
    try s.write(act.run_on_worktree_create);
    try s.endObject();
}

/// `persist`: pretty JSON plus a newline, written to a fresh temporary file,
/// synced, and renamed over the store. Errors are the call's.
fn persist(a: Allocator, io: std.Io, dir: []const u8, file: *StoreFile) !void {
    const keys = file.projects.keys();
    const order = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, order, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("version");
    try s.write(store_version);
    try s.objectField("projects");
    try s.beginObject();
    for (order) |k| {
        const p = file.projects.get(k).?;
        try s.objectField(k);
        try s.beginObject();
        try s.objectField("projectRoot");
        try s.write(p.root);
        try s.objectField("actions");
        try s.beginArray();
        for (p.actions.items) |act| try writeAction(&s, act);
        try s.endArray();
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
    try aw.writer.writeByte('\n');

    try std.Io.Dir.cwd().createDirPath(io, dir);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp_name = try std.fmt.allocPrint(a, ".{s}.tmp-{x}", .{ store_file, rnd });
    const tmp_path = try std.fs.path.join(a, &.{ dir, tmp_name });
    const final_path = try std.fs.path.join(a, &.{ dir, store_file });
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .exclusive = true });
        defer f.close(io);
        try f.writeStreamingAll(io, aw.written());
        try f.sync(io);
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), final_path, io);
}

// ── drafts, ids ────────────────────────────────────────────────────────────

const DraftResult = union(enum) { ok: Draft, err: []const u8 };

/// `normalize_draft`.
pub fn normalizeDraft(d: Draft) DraftResult {
    const name = std.mem.trim(u8, d.name, " \t\r\n");
    if (name.len == 0) return .{ .err = "Action name is required" };
    const chars = std.unicode.utf8CountCodepoints(name) catch name.len;
    if (chars > max_name_chars) return .{ .err = common.errText("Action name must not exceed {d} characters", .{max_name_chars}) };
    const command = std.mem.trim(u8, d.command, " \t\r\n");
    if (command.len == 0) return .{ .err = "Action command is required" };
    if (command.len > max_command_bytes) return .{ .err = common.errText("Action command must not exceed {d} bytes", .{max_command_bytes}) };
    return .{ .ok = .{ .name = name, .command = command, .icon = d.icon, .run_on_worktree_create = d.run_on_worktree_create } };
}

fn hasId(actions: []const Action, id: []const u8) bool {
    for (actions) |act| if (std.mem.eql(u8, act.id, id)) return true;
    return false;
}

/// `truncate_utf8`: cut at a character boundary, then drop trailing dashes.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var b = max;
    while (b > 0 and (s[b] & 0xC0) == 0x80) b -= 1;
    return std.mem.trimEnd(u8, s[0..b], "-");
}

/// `unique_action_id`: a lower-case slug of the name's letters and digits
/// with single dashes between runs, `action` when empty, then `-2`, `-3`, …
/// Non-ASCII characters are kept as they are.
pub fn uniqueActionId(a: Allocator, name: []const u8, actions: []const Action) ![]const u8 {
    var slug: std.ArrayList(u8) = .empty;
    var needs_sep = false;
    var i: usize = 0;
    while (i < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[i]) catch 1;
        const end = @min(i + len, name.len);
        const alnum = if (len == 1) std.ascii.isAlphanumeric(name[i]) else true;
        if (alnum) {
            if (needs_sep and slug.items.len > 0) try slug.append(a, '-');
            needs_sep = false;
            if (len == 1) try slug.append(a, std.ascii.toLower(name[i])) else try slug.appendSlice(a, name[i..end]);
        } else needs_sep = true;
        i = end;
    }
    if (slug.items.len == 0) try slug.appendSlice(a, "action");
    const base = truncateUtf8(slug.items, max_id_bytes);
    if (!hasId(actions, base)) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        var buf: [24]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&buf, "-{d}", .{n});
        const cand = try std.fmt.allocPrint(a, "{s}{s}", .{ truncateUtf8(base, max_id_bytes - suffix.len), suffix });
        if (!hasId(actions, cand)) return cand;
    }
}

// ── harness.json ───────────────────────────────────────────────────────────

const Imported = struct {
    drafts: std.ArrayList(Draft) = .empty,
    issue: ?[]const u8 = null,
};

fn issue(a: Allocator, comptime fmt: []const u8, args: anytype) !Imported {
    return .{ .issue = try std.fmt.allocPrint(a, "Invalid harness.json: " ++ fmt, args) };
}

/// `read_project_file`: strict (unknown fields refused), at most 256 KiB and
/// 50 actions, every action normalized; a problem is reported, not raised.
fn readProjectFile(a: Allocator, io: std.Io, root: []const u8) !Imported {
    const path = try std.fs.path.join(a, &.{ root, project_file });
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return issue(a, "could not read file: {s}", .{@errorName(e)}),
    };
    if (st.kind != .file) return issue(a, "could not read file: expected a regular file", .{});
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_project_file_bytes + 1)) catch |e| switch (e) {
        error.StreamTooLong => return issue(a, "file exceeds the {d} byte limit", .{max_project_file_bytes}),
        else => return issue(a, "could not read file: {s}", .{@errorName(e)}),
    };
    if (bytes.len > max_project_file_bytes) return issue(a, "file exceeds the {d} byte limit", .{max_project_file_bytes});
    const v = json.parseFromSliceLeaky(json.Value, a, bytes, .{}) catch |e|
        return issue(a, "invalid JSON: {s}", .{@errorName(e)});
    if (v != .object) return issue(a, "invalid JSON: invalid type: expected struct ProjectFile", .{});
    var it = v.object.iterator();
    while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, "actions"))
        return issue(a, "invalid JSON: unknown field `{s}`, expected `actions`", .{e.key_ptr.*});
    const acts = v.object.get("actions") orelse return issue(a, "invalid JSON: missing field `actions`", .{});
    if (acts != .array) return issue(a, "invalid JSON: invalid type: expected a sequence", .{});
    if (acts.array.items.len > max_actions) return issue(a, "file contains more than {d} actions", .{max_actions});
    var out: Imported = .{};
    for (acts.array.items) |av| {
        const d = switch (parseDraft(av, true)) {
            .ok => |d| d,
            .err => |m| return issue(a, "invalid JSON: {s}", .{m}),
        };
        switch (normalizeDraft(d)) {
            .ok => |n| try out.drafts.append(a, n),
            .err => |m| return issue(a, "{s}", .{m}),
        }
    }
    return out;
}

/// `ProjectActionDraft` (and `ProjectFileAction` when `strict`).
fn parseDraft(v: json.Value, strict: bool) DraftResult {
    if (v != .object) return .{ .err = "invalid type: expected struct ProjectActionDraft" };
    const o = v.object;
    if (strict) {
        var it = o.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (!(std.mem.eql(u8, k, "name") or std.mem.eql(u8, k, "command") or std.mem.eql(u8, k, "icon") or std.mem.eql(u8, k, "runOnWorktreeCreate")))
                return .{ .err = common.errText("unknown field `{s}`, expected one of `name`, `command`, `icon`, `runOnWorktreeCreate`", .{k}) };
        }
    }
    const name = str(o, "name") orelse return .{ .err = if (o.get("name") == null) "missing field `name`" else "invalid type: expected a string for `name`" };
    const command = str(o, "command") orelse return .{ .err = if (o.get("command") == null) "missing field `command`" else "invalid type: expected a string for `command`" };
    const icon_t = str(o, "icon") orelse return .{ .err = if (o.get("icon") == null) "missing field `icon`" else "invalid type: expected a string for `icon`" };
    const icon = Icon.parse(icon_t) orelse return .{ .err = common.errText("unknown variant `{s}`, expected one of " ++ icon_variants, .{icon_t}) };
    var rowc = false;
    if (o.get("runOnWorktreeCreate")) |r| switch (r) {
        .bool => |b| rowc = b,
        else => return .{ .err = "invalid type: expected a boolean for `runOnWorktreeCreate`" },
    };
    return .{ .ok = .{ .name = name, .command = command, .icon = icon, .run_on_worktree_create = rowc } };
}

fn eqlLower(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

/// `snapshot_from_actions` as `ProjectActionsSnapshot` JSON.
fn snapshotJson(gpa: Allocator, a: Allocator, io: std.Io, space_id: []const u8, root: []const u8, actions: []const Action) ![]u8 {
    var imported = try readProjectFile(a, io, root);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("spaceId");
    try s.write(space_id);
    try s.objectField("actions");
    try s.beginArray();
    for (actions) |act| try writeAction(&s, act);
    try s.endArray();
    try s.objectField("importableActions");
    try s.beginArray();
    outer: for (imported.drafts.items) |d| {
        for (actions) |saved| {
            if (std.mem.eql(u8, saved.command, d.command) or eqlLower(saved.name, d.name)) continue :outer;
        }
        try s.beginObject();
        try s.objectField("name");
        try s.write(d.name);
        try s.objectField("command");
        try s.write(d.command);
        try s.objectField("icon");
        try s.write(@tagName(d.icon));
        try s.objectField("runOnWorktreeCreate");
        try s.write(d.run_on_worktree_create);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("projectFileIssue");
    try s.write(imported.issue);
    try s.endObject();
    imported.drafts.deinit(a);
    return aw.toOwnedSlice();
}

// ── the RPC context ────────────────────────────────────────────────────────

const Space = struct { id: []const u8, path: []const u8 };

/// `local_project_action_space`.
fn localSpace(host: *const EngineHost, space_id: []const u8) union(enum) { ok: Space, err: []const u8 } {
    for (host.spaces.items) |s| {
        if (!std.mem.eql(u8, s.id, space_id)) continue;
        if (!std.mem.eql(u8, s.device_id, host.device_id)) return .{ .err = "Project space belongs to another device" };
        return .{ .ok = .{ .id = s.id, .path = s.path } };
    }
    return .{ .err = "Project space not found" };
}

const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    dir: []const u8,
    store_path: []const u8,

    fn deinit(self: *Ctx) void {
        self.arena.deinit();
    }
};

fn openCtx(host: *const EngineHost) !union(enum) { ok: Ctx, err: RpcOutcome } {
    const io = host.io orelse return .{ .err = common.failedMsg("io: the engine has no I/O") };
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const dir = (try storeRoot(a, host)) orelse {
        arena.deinit();
        return .{ .err = common.failedMsg("io: the engine has no data directory") };
    };
    const store_path = try std.fs.path.join(a, &.{ dir, store_file });
    return .{ .ok = .{ .arena = arena, .io = io, .dir = dir, .store_path = store_path } };
}

fn ioFailed(e: anyerror) RpcOutcome {
    return common.failed("io: {s}", .{@errorName(e)});
}

const identity_mismatch = "Project identity no longer matches its stored action configuration";

fn spaceParam(o: json.ObjectMap) ?[]const u8 {
    return str(o, "spaceId");
}

// ── RPCs ───────────────────────────────────────────────────────────────────

/// `ListProjectActions { spaceId }` → `ProjectActionsSnapshot`.
pub fn list(host: *EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct ListProjectActionsParams", .{});
    const space_id = spaceParam(o) orelse return common.badParams("missing field `spaceId`", .{});
    const space = switch (localSpace(host, space_id)) {
        .ok => |s| s,
        .err => |m| return common.failedMsg(m),
    };
    var ctx = switch (try openCtx(host)) {
        .ok => |c| c,
        .err => |e| return e,
    };
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    var file = readStore(a, ctx.io, ctx.store_path) catch |e| return ioFailed(e);
    const actions: []const Action = if (file.get(space.id)) |p| blk: {
        if (!std.mem.eql(u8, p.root, space.path)) return common.failedMsg(identity_mismatch);
        break :blk p.actions.items;
    } else &.{};
    return .{ .unary_json = try snapshotJson(host.gpa, a, ctx.io, space.id, space.path, actions) };
}

/// `UpsertProjectAction { spaceId, actionId?, action }` → the snapshot.
pub fn upsert(host: *EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct UpsertProjectActionParams", .{});
    const space_id = spaceParam(o) orelse return common.badParams("missing field `spaceId`", .{});
    const action_id: ?[]const u8 = if (o.get("actionId")) |v| switch (v) {
        .null => null,
        .string => |t| t,
        else => return common.badParams("invalid type: expected a string for `actionId`", .{}),
    } else null;
    const draft_v = o.get("action") orelse return common.badParams("missing field `action`", .{});
    const raw_draft = switch (parseDraft(draft_v, false)) {
        .ok => |d| d,
        .err => |m| return common.badParams("{s}", .{m}),
    };
    const space = switch (localSpace(host, space_id)) {
        .ok => |s| s,
        .err => |m| return common.failedMsg(m),
    };
    const draft = switch (normalizeDraft(raw_draft)) {
        .ok => |d| d,
        .err => |m| return common.failedMsg(m),
    };
    var ctx = switch (try openCtx(host)) {
        .ok => |c| c,
        .err => |e| return e,
    };
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    var file = readStore(a, ctx.io, ctx.store_path) catch |e| return ioFailed(e);
    const gop = try file.projects.getOrPut(a, space.id);
    if (!gop.found_existing) gop.value_ptr.* = .{ .root = space.path };
    const project = gop.value_ptr;
    if (!std.mem.eql(u8, project.root, space.path)) return common.failedMsg(identity_mismatch);

    const index: usize = if (action_id) |id| blk: {
        for (project.actions.items, 0..) |act, i| if (std.mem.eql(u8, act.id, id)) break :blk i;
        return common.failedMsg("Project action not found");
    } else blk: {
        if (project.actions.items.len >= max_actions) return common.failed("A project can have at most {d} actions", .{max_actions});
        break :blk project.actions.items.len;
    };
    if (draft.run_on_worktree_create) {
        for (project.actions.items) |*act| act.run_on_worktree_create = false;
    }
    const id = action_id orelse try uniqueActionId(a, draft.name, project.actions.items);
    const action: Action = .{
        .id = try a.dupe(u8, id),
        .name = try a.dupe(u8, draft.name),
        .command = try a.dupe(u8, draft.command),
        .icon = draft.icon,
        .run_on_worktree_create = draft.run_on_worktree_create,
    };
    if (index == project.actions.items.len) try project.actions.append(a, action) else project.actions.items[index] = action;
    persist(a, ctx.io, ctx.dir, &file) catch |e| return ioFailed(e);
    return .{ .unary_json = try snapshotJson(host.gpa, a, ctx.io, space.id, space.path, project.actions.items) };
}

/// `DeleteProjectAction { spaceId, actionId }` → the snapshot.
pub fn delete(host: *EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct DeleteProjectActionParams", .{});
    const space_id = spaceParam(o) orelse return common.badParams("missing field `spaceId`", .{});
    const action_id = str(o, "actionId") orelse return common.badParams("missing field `actionId`", .{});
    const space = switch (localSpace(host, space_id)) {
        .ok => |s| s,
        .err => |m| return common.failedMsg(m),
    };
    var ctx = switch (try openCtx(host)) {
        .ok => |c| c,
        .err => |e| return e,
    };
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    var file = readStore(a, ctx.io, ctx.store_path) catch |e| return ioFailed(e);
    const project = file.get(space.id) orelse return common.failedMsg("Project action not found");
    if (!std.mem.eql(u8, project.root, space.path)) return common.failedMsg(identity_mismatch);
    const before = project.actions.items.len;
    var i: usize = 0;
    while (i < project.actions.items.len) {
        if (std.mem.eql(u8, project.actions.items[i].id, action_id)) _ = project.actions.orderedRemove(i) else i += 1;
    }
    if (project.actions.items.len == before) return common.failedMsg("Project action not found");
    persist(a, ctx.io, ctx.dir, &file) catch |e| return ioFailed(e);
    return .{ .unary_json = try snapshotJson(host.gpa, a, ctx.io, space.id, space.path, project.actions.items) };
}

fn u16Param(o: json.ObjectMap, comptime key: []const u8) union(enum) { ok: u16, err: RpcOutcome } {
    const v = o.get(key) orelse return .{ .err = common.badParams("missing field `" ++ key ++ "`", .{}) };
    if (v != .integer) return .{ .err = common.badParams("invalid type: expected u16 for `" ++ key ++ "`", .{}) };
    if (v.integer < 0 or v.integer > 65535) return .{ .err = common.badParams("invalid value: integer `{d}`, expected u16", .{v.integer}) };
    return .{ .ok = @intCast(v.integer) };
}

/// `Repos::workspace_checkout`: the canonical `candidate` when it is the
/// repository folder or one of its worktrees.
pub fn workspaceCheckout(a: Allocator, io: std.Io, repo_path: []const u8, candidate: []const u8) !?[]const u8 {
    const cand = common.canonicalize(a, io, candidate) orelse return null;
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(a, repo_path);
    var listed = try common.git(a, io, &.{ "worktree", "list", "--porcelain", "-z" }, repo_path);
    if (listed == .failed) listed = try common.git(a, io, &.{ "worktree", "list", "--porcelain" }, repo_path);
    if (listed == .ok) {
        var it = std.mem.tokenizeAny(u8, listed.ok, "\x00\n");
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "worktree ")) try paths.append(a, line["worktree ".len..]);
        }
    }
    for (paths.items) |p| {
        const c = common.canonicalize(a, io, p) orelse continue;
        if (std.mem.eql(u8, c, cand)) return cand;
    }
    return null;
}

/// `RunProjectAction { spaceId, chatId, actionId, cols, rows }` →
/// `ProjectActionRun { actionId, actionName, terminal }`.
pub fn run(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (@import("rpcg_rpc.zig").targetProblem(params, host.device_id)) |e| return e;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct RunProjectActionParams", .{});
    const space_id = spaceParam(o) orelse return common.badParams("missing field `spaceId`", .{});
    const chat_id = str(o, "chatId") orelse return common.badParams("missing field `chatId`", .{});
    const action_id = str(o, "actionId") orelse return common.badParams("missing field `actionId`", .{});
    const cols = switch (u16Param(o, "cols")) {
        .ok => |n| n,
        .err => |e| return e,
    };
    const rows = switch (u16Param(o, "rows")) {
        .ok => |n| n,
        .err => |e| return e,
    };
    const space = switch (localSpace(host, space_id)) {
        .ok => |s| s,
        .err => |m| return common.failedMsg(m),
    };
    const chat = for (host.chats.items) |*c| {
        if (std.mem.eql(u8, c.id, chat_id)) break c;
    } else return common.failedMsg("Project chat not found");
    if (!std.mem.eql(u8, chat.device_id, host.device_id)) return common.failedMsg("Project chat belongs to another device");
    if (chat.space_id == null or !std.mem.eql(u8, chat.space_id.?, space.id)) return common.failedMsg("Project chat belongs to another space");
    const chat_cwd = chat.cwd orelse return common.failedMsg("Project chat has no checkout");

    var ctx = switch (try openCtx(host)) {
        .ok => |c| c,
        .err => |e| return e,
    };
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const checkout = (try workspaceCheckout(a, ctx.io, space.path, chat_cwd)) orelse return common.failedMsg("Project chat checkout is unavailable");
    const project_root = common.canonicalize(a, ctx.io, space.path) orelse return common.failedMsg("Project root is unavailable");
    var file = readStore(a, ctx.io, ctx.store_path) catch |e| return ioFailed(e);
    const action: Action = blk: {
        const p = file.get(space.id) orelse return common.failedMsg("Project action not found");
        if (!std.mem.eql(u8, p.root, space.path)) return common.failedMsg(identity_mismatch);
        for (p.actions.items) |act| if (std.mem.eql(u8, act.id, action_id)) break :blk act;
        return common.failedMsg("Project action not found");
    };

    // `launch_project_action_with_environment`.
    var env: std.ArrayList([2][]const u8) = .empty;
    try env.append(a, .{ "HARNESS_PROJECT_ROOT", project_root });
    if (!std.mem.eql(u8, checkout, project_root)) try env.append(a, .{ "HARNESS_WORKTREE_PATH", checkout });
    const opened = switch (try openActionTerminal(host, ctx.io, checkout, cols, rows, env.items, action.command)) {
        .ok => |t| t,
        .err => |m| return common.failedMsg(m),
    };
    defer host.gpa.free(opened.id);
    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    errdefer aw.deinit();
    try aw.writer.print("{{\"actionId\":{f},\"actionName\":{f},\"terminal\":{{\"id\":{f},\"cwd\":{f},\"shell\":{f}}}}}", .{
        json.fmt(action.id, .{}),         json.fmt(action.name, .{}),
        json.fmt(opened.id, .{}),         json.fmt(checkout, .{}),
        json.fmt(opened.shell_name, .{}),
    });
    return .{ .unary_json = try aw.toOwnedSlice() };
}

// ── setup handoffs ─────────────────────────────────────────────────────────

const Handoff = struct {
    command_id: []u8,
    chat_id: []u8,
    completed_at_ms: i64,
    /// `{"setupAction":…,"setupError":…}` members, as JSON.
    setup_action_json: ?[]u8,
    setup_error: ?[]u8,

    fn deinit(h: Handoff, gpa: Allocator) void {
        gpa.free(h.command_id);
        gpa.free(h.chat_id);
        if (h.setup_action_json) |s| gpa.free(s);
        if (h.setup_error) |s| gpa.free(s);
    }
};

/// The non-durable handoff cache (`setup_handoffs`), process-wide like the
/// engine's one store.
var handoffs: std.ArrayList(Handoff) = .empty;
var handoffs_gpa: ?Allocator = null;

fn pruneHandoffs(now_ms: i64) void {
    const gpa = handoffs_gpa orelse return;
    var i: usize = 0;
    while (i < handoffs.items.len) {
        if (now_ms - handoffs.items[i].completed_at_ms >= setup_handoff_ttl_ms) handoffs.orderedRemove(i).deinit(gpa) else i += 1;
    }
}

/// `complete_setup_handoff`: what the queue drain publishes after it ran a
/// setup action for a Run command (`setup_action_json` is a
/// `ProjectActionRun`).
/// The space's saved setup Action (`setup_action`: the first one marked
/// `runOnWorktreeCreate`), read from the persisted store into `a`; null when
/// it has none or the store can't be read.
pub fn persistedSetupAction(host: *const EngineHost, a: Allocator, space_id: []const u8) ?Action {
    const io = host.io orelse return null;
    const dir = (storeRoot(a, host) catch return null) orelse return null;
    const path = std.fs.path.join(a, &.{ dir, store_file }) catch return null;
    var file = readStore(a, io, path) catch return null;
    const project = file.get(space_id) orelse return null;
    for (project.actions.items) |act| if (act.run_on_worktree_create) return act;
    return null;
}

pub fn completeSetupHandoff(gpa: Allocator, now_ms: i64, command_id: []const u8, chat_id: []const u8, setup_action_json: ?[]const u8, setup_error: ?[]const u8) !void {
    handoffs_gpa = gpa;
    pruneHandoffs(now_ms);
    for (handoffs.items, 0..) |h, i| if (std.mem.eql(u8, h.command_id, command_id)) {
        handoffs.orderedRemove(i).deinit(gpa);
        break;
    };
    const h: Handoff = .{
        .command_id = try gpa.dupe(u8, command_id),
        .chat_id = try gpa.dupe(u8, chat_id),
        .completed_at_ms = now_ms,
        .setup_action_json = if (setup_action_json) |s| try gpa.dupe(u8, s) else null,
        .setup_error = if (setup_error) |s| try gpa.dupe(u8, s) else null,
    };
    try handoffs.append(gpa, h);
}

pub fn clearHandoffs() void {
    const gpa = handoffs_gpa orelse return;
    for (handoffs.items) |h| h.deinit(gpa);
    handoffs.deinit(gpa);
    handoffs = .empty;
}

/// `TakeProjectActionSetup { chatId, commandId }` → `{ ready: false }`, or
/// `{ ready: true, setupAction, setupError }` once (scoped to its chat).
pub fn takeSetup(host: *EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct TakeProjectActionSetupParams", .{});
    const chat_id = str(o, "chatId") orelse return common.badParams("missing field `chatId`", .{});
    const command_id = str(o, "commandId") orelse return common.badParams("missing field `commandId`", .{});
    pruneHandoffs(host.nowMs());
    for (handoffs.items, 0..) |h, i| {
        if (!std.mem.eql(u8, h.command_id, command_id)) continue;
        if (!std.mem.eql(u8, h.chat_id, chat_id)) break;
        const taken = handoffs.orderedRemove(i);
        defer taken.deinit(handoffs_gpa.?);
        return .{ .unary_json = try std.fmt.allocPrint(host.gpa, "{{\"ready\":true,\"setupAction\":{s},\"setupError\":{f}}}", .{
            taken.setup_action_json orelse "null",
            json.fmt(taken.setup_error, .{}),
        }) };
    }
    return .{ .unary_json = try host.gpa.dupe(u8, "{\"ready\":false}") };
}

// ── running an action (the terminal seam) ──────────────────────────────────

pub const Opened = struct { id: []u8, shell_name: []const u8 };

/// Open a PTY terminal in `cwd` that runs `command` in the user's login
/// shell with `env` added (`Terminals::open_with_command`); its id (owned)
/// and the shell's name.
pub fn openActionTerminal(
    host: *EngineHost,
    io: std.Io,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    env: []const [2][]const u8,
    command: []const u8,
) !union(enum) { ok: Opened, err: []const u8 } {
    _ = io;
    @import("rpcg_terminals.zig").attach(host);
    const opened = switch (try host.terminals.open(.{ .cwd = cwd, .cols = cols, .rows = rows, .env = env, .command = command })) {
        .ok => |o| o,
        .failed => |m| return .{ .err = m },
    };
    return .{ .ok = .{ .id = try host.gpa.dupe(u8, opened.id), .shell_name = std.fs.path.basename(opened.shell) } };
}

/// Engine shutdown: actions run in terminals, which the terminal manager
/// stops with the engine.
pub fn shutdown() void {}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    project: []u8,
    data: []u8,
    env: common.TestEnv,
    host: EngineHost,

    const Output = struct { text: []u8, exit_code: ?i64 };

    /// The terminal's decoded output (owned) and exit code, read from its
    /// replay until the shell exits, or (`until` set) until the output holds
    /// that text; 10 s at most.
    fn terminalOutput(f: *Fx, tid: []const u8, until: ?[]const u8) !Output {
        const gpa = testing.allocator;
        var waited: usize = 0;
        while (true) : (waited += 50) {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(gpa);
            var exit_code: ?i64 = null;
            {
                f.host.mutex.lockUncancelable(testing.io);
                defer f.host.mutex.unlock(testing.io);
                const rep = switch (try f.host.terminals.replay(gpa, tid, 0)) {
                    .ok => |r| r,
                    .failed => |m| {
                        std.debug.print("terminal replay failed: {s}\n", .{m});
                        return error.TerminalNotFound;
                    },
                };
                defer {
                    for (rep.items) |it| gpa.free(it);
                    gpa.free(rep.items);
                }
                for (rep.items) |item| {
                    var ev = try json.parseFromSlice(json.Value, gpa, item, .{});
                    defer ev.deinit();
                    const ty = ev.value.object.get("type").?.string;
                    if (std.mem.eql(u8, ty, "data")) {
                        const b64 = ev.value.object.get("data").?.string;
                        const dec = std.base64.standard.Decoder;
                        const buf = try gpa.alloc(u8, try dec.calcSizeForSlice(b64));
                        defer gpa.free(buf);
                        try dec.decode(buf, b64);
                        try text.appendSlice(gpa, buf);
                    } else if (std.mem.eql(u8, ty, "exit")) {
                        exit_code = ev.value.object.get("exitCode").?.integer;
                    }
                }
            }
            const done = if (until) |needle| std.mem.indexOf(u8, text.items, needle) != null else exit_code != null;
            if (done) return .{ .text = try gpa.dupe(u8, text.items), .exit_code = exit_code };
            if (waited >= 10_000) {
                std.debug.print("terminal output so far: {f}\n", .{json.fmt(text.items, .{})});
                return error.TerminalOutputNeverArrived;
            }
            try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
        }
    }

    fn init(f: *Fx) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, io, &f.tmp);
        try f.tmp.dir.createDirPath(io, "project");
        try f.tmp.dir.createDirPath(io, "home");
        f.project = try std.fs.path.join(gpa, &.{ f.base, "project" });
        f.data = try std.fs.path.join(gpa, &.{ f.base, "data" });
        const home = try std.fs.path.join(gpa, &.{ f.base, "home" });
        defer gpa.free(home);
        f.env = try common.TestEnv.init(gpa, home);
        try f.env.map.put("SHELL", "/bin/sh");
        try f.env.map.put("TMPDIR", f.base);
        f.env.install();
        try f.open();
    }

    fn open(f: *Fx) !void {
        const gpa = testing.allocator;
        f.host = try EngineHost.init(gpa, "dev-actions", "Synthetic");
        f.host.io = testing.io;
        f.host.workspace_scope = "local";
        try f.host.setDataDir(f.data);
        const sp = try std.fmt.allocPrint(gpa, "{{\"op\":\"createSpace\",\"spaceId\":\"sp-1\",\"name\":\"p\",\"path\":{f}}}", .{json.fmt(f.project, .{})});
        defer gpa.free(sp);
        try f.ok("Mutate", sp);
        const ch = try std.fmt.allocPrint(gpa, "{{\"op\":\"createChat\",\"chatId\":\"ch-1\",\"spaceId\":\"sp-1\",\"cwd\":{f},\"config\":{{\"harness\":\"mock\"}}}}", .{json.fmt(f.project, .{})});
        defer gpa.free(ch);
        try f.ok("Mutate", ch);
    }

    fn restart(f: *Fx) !void {
        shutdown();
        f.host.deinit();
        try f.open();
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        shutdown();
        f.host.deinit();
        clearHandoffs();
        f.env.deinit();
        gpa.free(f.base);
        gpa.free(f.project);
        gpa.free(f.data);
        f.tmp.cleanup();
    }

    fn call(f: *Fx, method: []const u8, text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
        defer p.deinit();
        return f.host.handle(method, p.value);
    }

    fn ok(f: *Fx, method: []const u8, text: []const u8) !void {
        const out = try f.call(method, text);
        switch (out) {
            .unary_json => |b| testing.allocator.free(b),
            .err => |e| {
                std.debug.print("{s} failed: {any}\n", .{ method, e });
                return error.UnexpectedError;
            },
            .stream_items_json => |s| {
                var st = s;
                st.deinit(testing.allocator);
            },
        }
    }

    fn json_(f: *Fx, method: []const u8, text: []const u8) !json.Parsed(json.Value) {
        const out = try f.call(method, text);
        if (out != .unary_json) {
            std.debug.print("{s} failed: {any}\n", .{ method, out });
            return error.UnexpectedError;
        }
        defer testing.allocator.free(out.unary_json);
        return json.parseFromSlice(json.Value, testing.allocator, out.unary_json, .{});
    }
};

fn expectFail(outcome: RpcOutcome, want: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .exec_error, .bad_params => |m| try testing.expectEqualStrings(want, m),
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

test "rpcw_actions upsert, list and delete persist in the profile store and survive a restart" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    {
        var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
        defer s.deinit();
        try testing.expectEqualStrings("sp-1", s.value.object.get("spaceId").?.string);
        try testing.expectEqual(@as(usize, 0), s.value.object.get("actions").?.array.items.len);
        try testing.expect(s.value.object.get("projectFileIssue").? == .null);
    }
    {
        var s = try f.json_("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\" Dev Server \",\"command\":\" npm run dev \",\"icon\":\"play\"}}");
        defer s.deinit();
        const act = s.value.object.get("actions").?.array.items[0].object;
        try testing.expectEqualStrings("dev-server", act.get("id").?.string);
        try testing.expectEqualStrings("Dev Server", act.get("name").?.string);
        try testing.expectEqualStrings("npm run dev", act.get("command").?.string);
        try testing.expect(!act.get("runOnWorktreeCreate").?.bool);
    }
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"dev server\",\"command\":\"x\",\"icon\":\"build\",\"runOnWorktreeCreate\":true}}");
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"Setup\",\"command\":\"make setup\",\"icon\":\"configure\",\"runOnWorktreeCreate\":true}}");
    try f.restart();
    {
        var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
        defer s.deinit();
        const acts = s.value.object.get("actions").?.array.items;
        try testing.expectEqual(@as(usize, 3), acts.len);
        try testing.expectEqualStrings("dev-server-2", acts[1].object.get("id").?.string);
        // Only one setup action: the newest one took the mark.
        try testing.expect(!acts[1].object.get("runOnWorktreeCreate").?.bool);
        try testing.expect(acts[2].object.get("runOnWorktreeCreate").?.bool);
    }
    // The file is Rust's shape, under the local profile.
    {
        const path = try std.fs.path.join(testing.allocator, &.{ f.data, "profiles", "local", "project-actions.json" });
        defer testing.allocator.free(path);
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(text);
        try testing.expect(std.mem.endsWith(u8, text, "}\n"));
        var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
        defer p.deinit();
        try testing.expectEqual(@as(i64, 1), p.value.object.get("version").?.integer);
        const proj = p.value.object.get("projects").?.object.get("sp-1").?.object;
        try testing.expectEqualStrings(f.project, proj.get("projectRoot").?.string);
        try testing.expectEqualStrings("configure", proj.get("actions").?.array.items[2].object.get("icon").?.string);
    }
    // Edit in place, then delete.
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"actionId\":\"dev-server\",\"action\":{\"name\":\"Dev\",\"command\":\"pnpm dev\",\"icon\":\"debug\"}}");
    {
        var s = try f.json_("DeleteProjectAction", "{\"spaceId\":\"sp-1\",\"actionId\":\"dev-server-2\"}");
        defer s.deinit();
        const acts = s.value.object.get("actions").?.array.items;
        try testing.expectEqual(@as(usize, 2), acts.len);
        try testing.expectEqualStrings("pnpm dev", acts[0].object.get("command").?.string);
    }
    try f.restart();
    {
        var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
        defer s.deinit();
        try testing.expectEqual(@as(usize, 2), s.value.object.get("actions").?.array.items.len);
    }
}

test "rpcw_actions error replies" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try expectFail(try f.call("ListProjectActions", "{}"), "missing field `spaceId`");
    try expectFail(try f.call("ListProjectActions", "{\"spaceId\":\"nope\"}"), "Project space not found");
    try expectFail(try f.call("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\" \",\"command\":\"x\",\"icon\":\"play\"}}"), "Action name is required");
    try expectFail(try f.call("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"a\",\"command\":\"  \",\"icon\":\"play\"}}"), "Action command is required");
    try expectFail(try f.call("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"a\",\"command\":\"x\",\"icon\":\"rocket\"}}"), "unknown variant `rocket`, expected one of " ++ icon_variants);
    try expectFail(try f.call("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"a\",\"command\":\"x\"}}"), "missing field `icon`");
    try expectFail(try f.call("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"actionId\":\"ghost\",\"action\":{\"name\":\"a\",\"command\":\"x\",\"icon\":\"play\"}}"), "Project action not found");
    try expectFail(try f.call("DeleteProjectAction", "{\"spaceId\":\"sp-1\",\"actionId\":\"ghost\"}"), "Project action not found");
    var long_name: [81]u8 = undefined;
    @memset(&long_name, 'n');
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"spaceId\":\"sp-1\",\"action\":{{\"name\":\"{s}\",\"command\":\"x\",\"icon\":\"play\"}}}}", .{&long_name});
    defer testing.allocator.free(body);
    try expectFail(try f.call("UpsertProjectAction", body), "Action name must not exceed 80 characters");
    for (0..max_actions) |i| {
        const b = try std.fmt.allocPrint(testing.allocator, "{{\"spaceId\":\"sp-1\",\"action\":{{\"name\":\"a{d}\",\"command\":\"x\",\"icon\":\"play\"}}}}", .{i});
        defer testing.allocator.free(b);
        try f.ok("UpsertProjectAction", b);
    }
    try expectFail(try f.call("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"one more\",\"command\":\"x\",\"icon\":\"play\"}}"), "A project can have at most 50 actions");

    // The space moved: the stored actions no longer match it.
    for (f.host.spaces.items) |*s| {
        testing.allocator.free(s.path);
        s.path = try testing.allocator.dupe(u8, f.base);
    }
    try expectFail(try f.call("ListProjectActions", "{\"spaceId\":\"sp-1\"}"), identity_mismatch);
}

test "rpcw_actions harness.json offers importable actions and reports a bad file" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "project/harness.json", .data =
        \\{"actions":[{"name":"Test","command":"zig build test","icon":"test"},{"name":"Lint","command":"make lint","icon":"lint","runOnWorktreeCreate":false}]}
    });
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"test\",\"command\":\"other\",\"icon\":\"play\"}}");
    {
        var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
        defer s.deinit();
        const imp = s.value.object.get("importableActions").?.array.items;
        try testing.expectEqual(@as(usize, 1), imp.len); // "Test" is already saved by name
        try testing.expectEqualStrings("Lint", imp[0].object.get("name").?.string);
    }
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "project/harness.json", .data = "{\"actions\":[],\"extra\":1}" });
    {
        var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
        defer s.deinit();
        try testing.expectEqualStrings("Invalid harness.json: invalid JSON: unknown field `extra`, expected `actions`", s.value.object.get("projectFileIssue").?.string);
    }
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "project/harness.json", .data = "{\"actions\":[{\"name\":\"\",\"command\":\"x\",\"icon\":\"play\"}]}" });
    {
        var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
        defer s.deinit();
        try testing.expectEqualStrings("Invalid harness.json: Action name is required", s.value.object.get("projectFileIssue").?.string);
    }
}

test "rpcw_actions a corrupt store reads as empty and is repaired on write" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "data/profiles/local");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/profiles/local/project-actions.json", .data = "not json" });
    {
        var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
        defer s.deinit();
        try testing.expectEqual(@as(usize, 0), s.value.object.get("actions").?.array.items.len);
    }
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"Build\",\"command\":\"make\",\"icon\":\"build\"}}");
    try f.restart();
    var s = try f.json_("ListProjectActions", "{\"spaceId\":\"sp-1\"}");
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.value.object.get("actions").?.array.items.len);
}

test "rpcw_actions uniqueActionId slugs names like Rust" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("run-the-tests", try uniqueActionId(a, "  Run the  Tests! ", &.{}));
    try testing.expectEqualStrings("action", try uniqueActionId(a, "!!!", &.{}));
    const taken = [_]Action{
        .{ .id = "dev", .name = "", .command = "", .icon = .play, .run_on_worktree_create = false },
        .{ .id = "dev-2", .name = "", .command = "", .icon = .play, .run_on_worktree_create = false },
    };
    try testing.expectEqualStrings("dev-3", try uniqueActionId(a, "Dev", &taken));
}

test "rpcw_actions RunProjectAction runs the saved command in the chat's checkout and records its output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"Hello\",\"command\":\"printf 'hello from %s' \\\"$(basename \\\"$HARNESS_PROJECT_ROOT\\\")\\\"; echo oops >&2; exit 3\",\"icon\":\"play\"}}");
    var run_reply = try f.json_("RunProjectAction", "{\"spaceId\":\"sp-1\",\"chatId\":\"ch-1\",\"actionId\":\"hello\",\"cols\":80,\"rows\":24}");
    defer run_reply.deinit();
    try testing.expectEqualStrings("hello", run_reply.value.object.get("actionId").?.string);
    try testing.expectEqualStrings("Hello", run_reply.value.object.get("actionName").?.string);
    const term = run_reply.value.object.get("terminal").?.object;
    try testing.expectEqualStrings("sh", term.get("shell").?.string);
    const tid = term.get("id").?.string;

    // Wait (bounded) for the process to finish and its output to land.
    const got = try f.terminalOutput(tid, null);
    defer testing.allocator.free(got.text);
    try testing.expect(std.mem.indexOf(u8, got.text, "hello from project") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "oops") != null);
    try testing.expectEqual(@as(?i64, 3), got.exit_code);
}

test "rpcw_actions RunProjectAction errors and a long action stops when its terminal closes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try expectFail(try f.call("RunProjectAction", "{\"spaceId\":\"sp-1\",\"chatId\":\"ch-1\",\"actionId\":\"x\",\"cols\":80}"), "missing field `rows`");
    try expectFail(try f.call("RunProjectAction", "{\"spaceId\":\"sp-1\",\"chatId\":\"nope\",\"actionId\":\"x\",\"cols\":80,\"rows\":24}"), "Project chat not found");
    try expectFail(try f.call("RunProjectAction", "{\"spaceId\":\"sp-1\",\"chatId\":\"ch-1\",\"actionId\":\"x\",\"cols\":80,\"rows\":24}"), "Project action not found");
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"Serve\",\"command\":\"sleep 30\",\"icon\":\"play\"}}");
    var reply = try f.json_("RunProjectAction", "{\"spaceId\":\"sp-1\",\"chatId\":\"ch-1\",\"actionId\":\"serve\",\"cols\":80,\"rows\":24}");
    defer reply.deinit();
    const tid = reply.value.object.get("terminal").?.object.get("id").?.string;
    f.host.mutex.lockUncancelable(testing.io);
    _ = try f.host.terminals.close(tid);
    f.host.mutex.unlock(testing.io);
    // Closing the terminal ends it: the session is gone at once.
    {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        try testing.expect(f.host.terminals.sessions.get(tid) == null);
    }

    // A chat without a checkout.
    for (f.host.chats.items) |*c| {
        if (c.cwd) |old| testing.allocator.free(old);
        c.cwd = null;
    }
    try expectFail(try f.call("RunProjectAction", "{\"spaceId\":\"sp-1\",\"chatId\":\"ch-1\",\"actionId\":\"serve\",\"cols\":80,\"rows\":24}"), "Project chat has no checkout");
}

test "rpcw_actions TakeProjectActionSetup hands a completed setup to its chat once" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    {
        const out = try f.call("TakeProjectActionSetup", "{\"chatId\":\"ch-1\",\"commandId\":\"cmd-1\"}");
        defer gpa.free(out.unary_json);
        try testing.expectEqualStrings("{\"ready\":false}", out.unary_json);
    }
    try completeSetupHandoff(gpa, f.host.nowMs(), "cmd-1", "ch-1", null, "setup failed");
    {
        const other = try f.call("TakeProjectActionSetup", "{\"chatId\":\"ch-2\",\"commandId\":\"cmd-1\"}");
        defer gpa.free(other.unary_json);
        try testing.expectEqualStrings("{\"ready\":false}", other.unary_json);
        const out = try f.call("TakeProjectActionSetup", "{\"chatId\":\"ch-1\",\"commandId\":\"cmd-1\"}");
        defer gpa.free(out.unary_json);
        try testing.expectEqualStrings("{\"ready\":true,\"setupAction\":null,\"setupError\":\"setup failed\"}", out.unary_json);
        const again = try f.call("TakeProjectActionSetup", "{\"chatId\":\"ch-1\",\"commandId\":\"cmd-1\"}");
        defer gpa.free(again.unary_json);
        try testing.expectEqualStrings("{\"ready\":false}", again.unary_json);
    }
    // Expired after ten minutes.
    try completeSetupHandoff(gpa, f.host.nowMs() - setup_handoff_ttl_ms, "cmd-2", "ch-1", null, null);
    {
        const out = try f.call("TakeProjectActionSetup", "{\"chatId\":\"ch-1\",\"commandId\":\"cmd-2\"}");
        defer gpa.free(out.unary_json);
        try testing.expectEqualStrings("{\"ready\":false}", out.unary_json);
    }
    try expectFail(try f.call("TakeProjectActionSetup", "{\"chatId\":\"ch-1\"}"), "missing field `commandId`");
}

test "rpcw_actions a new worktree runs the persisted setup Action, and RunProjectAction checks the target device" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("UpsertProjectAction", "{\"spaceId\":\"sp-1\",\"action\":{\"name\":\"Prepare\",\"command\":\"echo prepared\",\"icon\":\"play\",\"runOnWorktreeCreate\":true}}");
    // Nothing in the in-memory list: the setup must come from the store.
    try testing.expectEqual(@as(usize, 0), f.host.actions.items.len);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        try @import("rpcg_terminals.zig").writeWorktreeSetup(&f.host, &aw.writer, "sp-1", f.project, f.project);
    }
    const out = aw.written();
    try testing.expect(std.mem.startsWith(u8, out, ",\"setupAction\":{\"actionId\":\"prepare\",\"actionName\":\"Prepare\""));
    const id_at = std.mem.indexOf(u8, out, "\"terminal\":{\"id\":\"").? + "\"terminal\":{\"id\":\"".len;
    const tid = out[id_at .. id_at + std.mem.indexOfScalar(u8, out[id_at..], '"').?];
    const got = try f.terminalOutput(tid, "prepared");
    defer testing.allocator.free(got.text);

    try expectFail(try f.call("RunProjectAction", "{\"spaceId\":\"sp-1\",\"chatId\":\"ch-1\",\"actionId\":\"prepare\",\"cols\":80,\"rows\":24,\"targetDeviceId\":\"dev-elsewhere\"}"), "target device not connected");
}
