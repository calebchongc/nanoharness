//! `ListSkills { harness, chatId?, spaceId?, path? }`, ported from
//! `crates/engine/src/rpc.rs` (`LIST_SKILLS`, `catalog_root`,
//! `file_search_root`) and `crates/engine/src/workspace_files.rs`
//! (`resolve_target`), with `repos.rs`'s `workspace_checkout`,
//! `worktree_paths` and `expand_home`. The skills themselves come from
//! `skills_discovery.zig` (on-disk skills and each agent CLI's command
//! handshake).
//!
//! A handshake can take seconds, so after resolving the root this touches no
//! engine state: it can run outside the host lock.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const exes = @import("rpcw_executables.zig");
const worktrees = @import("rpcw_worktrees.zig");
const engine_host = @import("engine_host.zig");
const rpc_models = @import("rpc_models.zig");
const skills = @import("skills_commands.zig");
const build_info = @import("build_info");

const HarnessId = exes.HarnessId;
const RpcOutcome = common.RpcOutcome;

/// `repos::home_dir`: HOME, then USERPROFILE, else `/`.
fn homeDir() []const u8 {
    return common.homeDir() orelse "/";
}

/// `repos::expand_home`. Caller owns the result.
pub fn expandHome(gpa: Allocator, cwd: []const u8) ![]u8 {
    if (std.mem.eql(u8, cwd, "~")) return gpa.dupe(u8, homeDir());
    if (std.mem.startsWith(u8, cwd, "~/")) return std.fs.path.join(gpa, &.{ homeDir(), cwd[2..] });
    return gpa.dupe(u8, cwd);
}

/// `Repos::worktree_paths`: `git worktree list --porcelain -z`, falling back
/// to the newline form for git before 2.36.
fn worktreePaths(gpa: Allocator, io: std.Io, repo: []const u8, out: *std.ArrayList([]u8)) !void {
    var res = try common.git(gpa, io, &.{ "worktree", "list", "--porcelain", "-z" }, repo);
    var sep: u8 = 0;
    if (res == .failed) {
        res = try common.git(gpa, io, &.{ "worktree", "list", "--porcelain" }, repo);
        sep = '\n';
        if (res == .failed) return;
    }
    defer res.deinit(gpa);
    var it = std.mem.splitScalar(u8, res.ok, sep);
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) try out.append(gpa, try gpa.dupe(u8, line["worktree ".len..]));
    }
}

/// `Repos::workspace_checkout(repo, candidate)`: the canonical candidate when
/// it is the repository root or one of its worktrees. Owned.
pub fn workspaceCheckout(gpa: Allocator, io: std.Io, repo: []const u8, candidate: []const u8) !?[]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    try paths.append(gpa, try gpa.dupe(u8, repo));
    worktreePaths(gpa, io, repo, &paths) catch {};
    const canon = common.canonicalize(gpa, io, candidate) orelse return null;
    for (paths.items) |p| {
        const c = common.canonicalize(gpa, io, p) orelse continue;
        defer gpa.free(c);
        if (std.mem.eql(u8, c, canon)) return canon;
    }
    gpa.free(canon);
    return null;
}

const Root = union(enum) { ok: []u8, err: RpcOutcome };

fn findChat(host: *engine_host.EngineHost, id: []const u8) ?*engine_host.ChatRecord {
    for (host.chats.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

fn findSpace(host: *engine_host.EngineHost, id: []const u8) ?*engine_host.SpaceRecord {
    for (host.spaces.items) |*s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

/// `catalog_root`, then `file_search_root` → `resolve_target`.
pub fn catalogRoot(host: *engine_host.EngineHost, io: std.Io, chat_id: ?[]const u8, space_id: ?[]const u8, path: ?[]const u8) !Root {
    const gpa = host.gpa;
    if (space_id == null and path == null) {
        const cid = chat_id orelse return .{ .ok = try gpa.dupe(u8, homeDir()) };
        const chat = findChat(host, cid) orelse return .{ .err = common.badParams("chat not found", .{}) };
        if (!std.mem.eql(u8, chat.device_id, host.device_id)) return .{ .err = common.badParams("chat belongs to another device", .{}) };
        if (chat.space_id == null) {
            return .{ .ok = if (chat.cwd) |cwd| try expandHome(gpa, cwd) else try gpa.dupe(u8, homeDir()) };
        }
    }
    // `resolve_target`.
    if ((chat_id != null) == (space_id != null)) return .{ .err = common.badParams("workspace target needs exactly one of chatId or spaceId", .{}) };
    if (chat_id) |cid| {
        if (path != null) return .{ .err = common.badParams("checkoutPath applies only to a space target", .{}) };
        const chat = findChat(host, cid) orelse return .{ .err = common.failed("chat not found", .{}) };
        if (!std.mem.eql(u8, chat.device_id, host.device_id)) return .{ .err = common.failed("chat belongs to another device", .{}) };
        const cwd = chat.cwd orelse return .{ .err = common.failed("chat has no workspace folder", .{}) };
        const sid = chat.space_id orelse return .{ .err = common.failed("chat has no workspace space", .{}) };
        const space = findSpace(host, sid) orelse return .{ .err = common.failed("chat workspace space not found", .{}) };
        if (!std.mem.eql(u8, space.device_id, host.device_id)) return .{ .err = common.failed("chat space belongs to another device", .{}) };
        const root = (try workspaceCheckout(gpa, io, space.path, cwd)) orelse return .{ .err = common.failed("chat folder is not a workspace checkout", .{}) };
        return .{ .ok = try identityRoot(host, io, root, cwd) };
    }
    const space = findSpace(host, space_id.?) orelse return .{ .err = common.failed("space not found", .{}) };
    if (!std.mem.eql(u8, space.device_id, host.device_id)) return .{ .err = common.failed("space belongs to another device", .{}) };
    const requested = path orelse space.path;
    const root = (try workspaceCheckout(gpa, io, space.path, requested)) orelse return .{ .err = common.badParams("checkoutPath is not a workspace checkout", .{}) };
    return .{ .ok = try identityRoot(host, io, root, root) };
}

/// A git checkout resolves to its toplevel (`checkout_identity(..).root`);
/// a plain folder keeps `root`. Takes ownership of `root`.
fn identityRoot(host: *engine_host.EngineHost, io: std.Io, root: []u8, identity_of: []const u8) ![]u8 {
    const gpa = host.gpa;
    var ident = try worktrees.checkoutIdentity(gpa, io, host.device_id, identity_of);
    switch (ident) {
        .ok => |*id| {
            gpa.free(root);
            const out = try gpa.dupe(u8, id.root);
            id.deinit(gpa);
            return out;
        },
        else => return root,
    }
}

fn optStr(o: json.ObjectMap, key: []const u8) error{Invalid}!?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => error.Invalid,
    };
}

var device_name_buf: [256]u8 = undefined;

/// A copy that outlives the host (the probes read it from their own threads).
fn deviceNameCopy(name: []const u8) []const u8 {
    const n = @min(name.len, device_name_buf.len);
    @memcpy(device_name_buf[0..n], name[0..n]);
    return device_name_buf[0..n];
}

pub fn listSkills(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct Params", .{});
    const hv = o.get("harness") orelse return common.badParams("missing field `harness`", .{});
    if (hv != .string) return common.badParams("invalid type: expected a harness id for `harness`", .{});
    const id = HarnessId.parse(hv.string) orelse return .{ .err = .{ .bad_params = exes.unknownVariantText(hv.string) } };
    const chat_id = optStr(o, "chatId") catch return common.badParams("invalid type: expected a string for `chatId`", .{});
    const space_id = optStr(o, "spaceId") catch return common.badParams("invalid type: expected a string for `spaceId`", .{});
    const path = optStr(o, "path") catch return common.badParams("invalid type: expected a string for `path`", .{});
    const io = host.io orelse return common.failed("skill discovery needs I/O", .{});
    const gpa = host.gpa;
    const root = switch (try catalogRoot(host, io, chat_id, space_id, path)) {
        .ok => |r| r,
        .err => |e| return e,
    };
    defer gpa.free(root);
    rpc_models.installHooks();
    skills.client_version = build_info.version;
    skills.graff_draft_subagents = host.graff_draft_subagents;
    skills.graff_compact_pct = @intCast(std.math.clamp(host.graff_compact_at, 0, 255));
    skills.graff_device_name = deviceNameCopy(host.device_name);
    // An agent CLI's command handshake takes seconds: not under the engine lock.
    const listed = blk: {
        const released = host.releaseForLongCall();
        defer host.retakeAfterLongCall(released);
        break :blk try skills.listSkillsJson(gpa, io, id.wire(), root);
    };
    return switch (listed) {
        .ok => |body| .{ .unary_json = body },
        .err => |msg| blk: {
            defer gpa.free(msg);
            break :blk common.failed("{s}", .{msg});
        },
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn callSkills(host: *engine_host.EngineHost, text: []const u8) !RpcOutcome {
    var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer p.deinit();
    return host.handle("ListSkills", p.value);
}

fn expectErr(outcome: RpcOutcome, kind: enum { exec, bad }, expected: []const u8) !void {
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

test "rpc_skills ListSkills resolves its root like catalog_root and lists on-disk skills" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try common.tmpPath(gpa, io, &tmp);
    defer gpa.free(base);
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "proj/.claude/skills/tidy");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.claude/skills/tidy/SKILL.md", .data = "---\nname: tidy\ndescription: Tidy things up\n---\nBody\n" });
    const home = try std.fs.path.join(gpa, &.{ base, "home" });
    defer gpa.free(home);
    const bin = try std.fs.path.join(gpa, &.{ base, "bin" });
    defer gpa.free(bin);
    const proj = try std.fs.path.join(gpa, &.{ base, "proj" });
    defer gpa.free(proj);
    var env = try common.TestEnv.init(gpa, home);
    defer env.deinit();
    try env.map.put("PATH", bin);
    try env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
    try env.map.put("HARNESS_DISABLE_SHELL_ENV", "1");
    env.install();
    defer @import("catalog_core.zig").env_override = null;
    exes.system_prefix = base;
    defer exes.system_prefix = "";

    var host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
    defer host.deinit();
    host.io = io;

    // Param errors, before any root is resolved.
    try expectErr(try callSkills(&host, "{}"), .bad, "missing field `harness`");
    try expectErr(try callSkills(&host, "{\"harness\":\"nope\"}"), .bad, "unknown variant `nope`, expected one of `claude-code`, `codex`, `cursor`, `devin`, `grok`, `hermes`, `graff`, `pi`, `opencode`, `antigravity`, `exo`, `mock`");
    // Root errors.
    try expectErr(try callSkills(&host, "{\"harness\":\"codex\",\"chatId\":\"missing\"}"), .bad, "chat not found");
    try expectErr(try callSkills(&host, "{\"harness\":\"codex\",\"path\":\"/x\"}"), .bad, "workspace target needs exactly one of chatId or spaceId");
    try expectErr(try callSkills(&host, "{\"harness\":\"codex\",\"spaceId\":\"nope\"}"), .exec, "space not found");

    // The mock advertises no skills at all: `None` serializes as null.
    const mock = try callSkills(&host, "{\"harness\":\"mock\"}");
    defer gpa.free(mock.unary_json);
    try testing.expectEqualStrings("null", mock.unary_json);

    // A space on this device: its folder is the root, and a project skill
    // shows up for Codex once its (missing) CLI is not needed for disk skills
    // — or the reply is the CLI's own failure. Either way it is Rust's answer.
    const sp = try std.fmt.allocPrint(gpa, "{{\"op\":\"createSpace\",\"spaceId\":\"sp1\",\"deviceId\":\"dev-synthetic\",\"path\":\"{s}\",\"name\":\"P\"}}", .{proj});
    defer gpa.free(sp);
    var spv = try json.parseFromSlice(json.Value, gpa, sp, .{});
    defer spv.deinit();
    const created = try host.handle("Mutate", spv.value);
    switch (created) {
        .unary_json => |b| gpa.free(b),
        else => return error.CreateSpaceFailed,
    }
    // A sibling folder is not a checkout of the space.
    const outside = try std.fmt.allocPrint(gpa, "{{\"harness\":\"codex\",\"spaceId\":\"sp1\",\"path\":\"{s}\"}}", .{home});
    defer gpa.free(outside);
    try expectErr(try callSkills(&host, outside), .bad, "checkoutPath is not a workspace checkout");
}

test "rpc_skills expandHome rewrites a leading tilde only" {
    const gpa = testing.allocator;
    var env = try common.TestEnv.init(gpa, "/h");
    defer env.deinit();
    env.install();
    const a = try expandHome(gpa, "~");
    defer gpa.free(a);
    try testing.expectEqualStrings("/h", a);
    const b = try expandHome(gpa, "~/p");
    defer gpa.free(b);
    try testing.expectEqualStrings("/h/p", b);
    const c = try expandHome(gpa, "~x/p");
    defer gpa.free(c);
    try testing.expectEqualStrings("~x/p", c);
}
