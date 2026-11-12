//! `ListDrives` and `WriteWorkspaceFile`.
//!
//! `ListDrives` is `Repos::list_drives` (`crates/engine/src/repos.rs`):
//! `/Volumes` on macOS, `/proc/mounts` on Linux, the drive letters on Windows,
//! deduplicated, the system root first, then by name, at most 50.
//!
//! `WriteWorkspaceFile` writes inside the chat's own workspace and fails the
//! call when it can't (an unknown chat, a chat with no workspace, a path that
//! leaves it, a write error). Rust's checkout-id and content-hash conflict
//! protocol (`workspace_files.rs` `write_file`) is not ported: it depends on
//! `ReadWorkspaceFile` handing out those ids, which this engine does not yet.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const workspace_files_host = @import("workspace_files_host.zig");

const RpcOutcome = common.RpcOutcome;

/// `DRIVE_LIST_MAX_ENTRIES`.
pub const drive_list_max: usize = 50;

pub const Drive = struct {
    name: []u8,
    path: []u8,

    fn deinit(d: Drive, gpa: Allocator) void {
        gpa.free(d.name);
        gpa.free(d.path);
    }
};

pub const DriveList = struct {
    items: std.ArrayList(Drive) = .empty,

    pub fn deinit(self: *DriveList, gpa: Allocator) void {
        for (self.items.items) |d| d.deinit(gpa);
        self.items.deinit(gpa);
    }

    fn add(self: *DriveList, gpa: Allocator, name: []const u8, path: []const u8) !void {
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        const p = try gpa.dupe(u8, path);
        errdefer gpa.free(p);
        try self.items.append(gpa, .{ .name = n, .path = p });
    }
};

/// `FHS_TOP_LEVEL`: depth-one mount points the system owns.
const fhs_top_level = [_][]const u8{
    "bin",   "boot", "dev", "efi", "etc",  "home", "lib", "lib32", "lib64", "libx32", "lost+found",
    "media", "mnt",  "nix", "opt", "proc", "root", "run", "sbin",  "snap",  "srv",    "sys",
    "tmp",   "usr",  "var",
};

fn isFhs(name: []const u8) bool {
    for (fhs_top_level) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

/// `unescape_mount_point`: `/proc/mounts` writes whitespace as `\040`.
pub fn unescapeMountPoint(gpa: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 4 <= raw.len) {
            if (std.fmt.parseInt(u8, raw[i + 1 .. i + 4], 8)) |code| {
                try out.append(gpa, code);
                i += 4;
                continue;
            } else |_| {}
        }
        try out.append(gpa, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// `linux_drives`: conventional removable mounts, block devices at custom
/// depth-one points (not squashfs/erofs images), then "System" for `/`.
pub fn linuxDrives(gpa: Allocator, mounts: []const u8, out: *DriveList) !void {
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const source = fields.next() orelse continue;
        const raw_point = fields.next() orelse continue;
        const fstype = fields.next();
        const point = try unescapeMountPoint(gpa, raw_point);
        defer gpa.free(point);
        const conventional = std.mem.startsWith(u8, point, "/media/") or
            std.mem.startsWith(u8, point, "/run/media/") or
            std.mem.eql(u8, point, "/mnt") or
            std.mem.startsWith(u8, point, "/mnt/");
        const image = if (fstype) |t| std.mem.eql(u8, t, "squashfs") or std.mem.eql(u8, t, "erofs") else false;
        const custom_block = std.mem.startsWith(u8, source, "/dev/") and !image and point.len > 1 and point[0] == '/' and
            std.mem.indexOfScalar(u8, point[1..], '/') == null and !isFhs(point[1..]);
        if (!conventional and !custom_block) continue;
        const trimmed = std.mem.trimEnd(u8, point, "/");
        const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |k| trimmed[k + 1 ..] else trimmed;
        try out.add(gpa, if (last.len == 0) "Drive" else last, point);
    }
    try out.add(gpa, "System", "/");
}

/// `macos_drives`: every visible entry of `/Volumes` that is a folder (a
/// dangling symlink drops out), at its resolved path.
pub fn volumeDrives(gpa: Allocator, io: std.Io, volumes: []const u8, out: *DriveList) !void {
    var dir = std.Io.Dir.cwd().openDir(io, volumes, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        const path = try std.fs.path.join(gpa, &.{ volumes, entry.name });
        defer gpa.free(path);
        if (!common.isDir(io, path)) continue;
        const resolved = common.canonicalize(gpa, io, path);
        defer if (resolved) |r| gpa.free(r);
        try out.add(gpa, entry.name, resolved orelse path);
    }
}

/// `windows_drives`: the letters whose root exists.
fn windowsDrives(gpa: Allocator, io: std.Io, out: *DriveList) !void {
    var letter: u8 = 'A';
    while (letter <= 'Z') : (letter += 1) {
        const path = [_]u8{ letter, ':', '\\' };
        std.Io.Dir.cwd().access(io, &path, .{}) catch continue;
        const name = [_]u8{ letter, ':' };
        try out.add(gpa, &name, &path);
    }
}

fn lowerLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    return a.len < b.len;
}

/// `finish_drives`: first mention of a path wins, `/` first, then by
/// lower-cased name, capped.
pub fn finishDrives(gpa: Allocator, list: *DriveList) void {
    var i: usize = 0;
    while (i < list.items.items.len) {
        var dup = false;
        for (list.items.items[0..i]) |prev| {
            if (std.mem.eql(u8, prev.path, list.items.items[i].path)) dup = true;
        }
        if (dup) {
            list.items.orderedRemove(i).deinit(gpa);
        } else i += 1;
    }
    std.mem.sort(Drive, list.items.items, {}, struct {
        fn less(_: void, a: Drive, b: Drive) bool {
            const ar = std.mem.eql(u8, a.path, "/");
            const br = std.mem.eql(u8, b.path, "/");
            if (ar != br) return ar;
            return lowerLess(a.name, b.name);
        }
    }.less);
    while (list.items.items.len > drive_list_max) list.items.pop().?.deinit(gpa);
}

fn drivesJson(gpa: Allocator, list: *const DriveList) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"drives\":[");
    for (list.items.items, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":{f},\"path\":{f}}}", .{ json.fmt(d.name, .{}), json.fmt(d.path, .{}) });
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

/// Where the platform's drives come from; tests point it at a synthetic tree.
pub var volumes_root: []const u8 = "/Volumes";
pub var proc_mounts: []const u8 = "/proc/mounts";

/// `ListDrives` → `{ drives: [{ name, path }] }`.
pub fn listDrives(host: *engine_host.EngineHost) !RpcOutcome {
    const gpa = host.gpa;
    const io = host.io orelse return common.failedMsg("drive listing worker exited");
    var list: DriveList = .{};
    defer list.deinit(gpa);
    switch (builtin.os.tag) {
        .macos => try volumeDrives(gpa, io, volumes_root, &list),
        .linux => {
            const text = std.Io.Dir.cwd().readFileAlloc(io, proc_mounts, gpa, .limited(4 << 20)) catch try gpa.dupe(u8, "");
            defer gpa.free(text);
            try linuxDrives(gpa, text, &list);
        },
        .windows => try windowsDrives(gpa, io, &list),
        else => {},
    }
    finishDrives(gpa, &list);
    return .{ .unary_json = try drivesJson(gpa, &list) };
}

// ── WriteWorkspaceFile ─────────────────────────────────────────────────────

/// The workspace folder a chat writes into: its space's path. Rust's
/// `resolve_target` errors, for the cases this engine can tell apart.
const Root = union(enum) { ok: []const u8, err: []const u8 };

fn chatRoot(host: *const engine_host.EngineHost, chat_id: []const u8) Root {
    for (host.chats.items) |c| {
        if (!std.mem.eql(u8, c.id, chat_id)) continue;
        if (!std.mem.eql(u8, c.device_id, host.device_id)) return .{ .err = "chat belongs to another device" };
        const sid = c.space_id orelse return .{ .err = "chat has no workspace space" };
        for (host.spaces.items) |s| {
            if (std.mem.eql(u8, s.id, sid)) return .{ .ok = s.path };
        }
        return .{ .err = "chat workspace space not found" };
    }
    return .{ .err = "chat not found" };
}

/// `WriteWorkspaceFile { chatId, path, text | content }` → `{ "written": true }`
/// only once the bytes are on disk.
pub fn writeWorkspaceFile(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct WriteWorkspaceFileRequest", .{});
    const path = common.str(o, "path") orelse return common.badParams("missing field `path`", .{});
    const text = common.str(o, "text") orelse common.str(o, "content") orelse return common.badParams("missing field `text`", .{});
    if (!workspace_files_host.isSafeRelativePath(path) or path.len == 0) return common.badParams("path traversal denied", .{});
    const chat_id = common.str(o, "chatId") orelse return common.badParams("workspace target needs exactly one of chatId or spaceId", .{});
    const root = switch (chatRoot(host, chat_id)) {
        .ok => |r| r,
        .err => |m| return common.failedMsg(m),
    };
    const io = host.io orelse return common.failedMsg("file write worker failed: the engine has no I/O");
    workspace_files_host.writeWorkspaceFile(host.gpa, io, root, path, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.failed("Could not save {s}: {s}", .{ path, @errorName(e) }),
    };
    return .{ .unary_json = try host.gpa.dupe(u8, "{\"written\":true}") };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectDrives(list: *const DriveList, want: []const [2][]const u8) !void {
    try testing.expectEqual(want.len, list.items.items.len);
    for (want, list.items.items) |w, d| {
        try testing.expectEqualStrings(w[0], d.name);
        try testing.expectEqualStrings(w[1], d.path);
    }
}

test "rpcw_workspace_files linuxDrives keeps removable and custom block mounts, then System" {
    const gpa = testing.allocator;
    const mounts =
        \\/dev/sda2 / ext4 rw 0 0
        \\/dev/sda1 /boot vfat rw 0 0
        \\/dev/sdb1 /disk2 ext4 rw 0 0
        \\/dev/loop3 /snapimg squashfs ro 0 0
        \\/dev/sdc1 /media/user/My\040Stick vfat rw 0 0
        \\tmpfs /run tmpfs rw 0 0
        \\C:\134 /mnt/c 9p rw 0 0
        \\/dev/sdd1 /data/deep ext4 rw 0 0
        \\/dev/sdb1 /disk2 ext4 rw 0 0
    ;
    var list: DriveList = .{};
    defer list.deinit(gpa);
    try linuxDrives(gpa, mounts, &list);
    finishDrives(gpa, &list);
    try expectDrives(&list, &.{
        .{ "System", "/" },
        .{ "c", "/mnt/c" },
        .{ "disk2", "/disk2" },
        .{ "My Stick", "/media/user/My Stick" },
    });
}

test "rpcw_workspace_files finishDrives caps at 50" {
    const gpa = testing.allocator;
    var list: DriveList = .{};
    defer list.deinit(gpa);
    for (0..60) |i| {
        var buf: [32]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "/media/d{d:0>2}", .{i});
        try list.add(gpa, p[7..], p);
    }
    finishDrives(gpa, &list);
    try testing.expectEqual(drive_list_max, list.items.items.len);
    try testing.expectEqualStrings("d00", list.items.items[0].name);
}

test "rpcw_workspace_files ListDrives lists a synthetic /Volumes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try common.tmpPath(gpa, testing.io, &tmp);
    defer gpa.free(base);
    try tmp.dir.createDirPath(testing.io, "Volumes/Zeta Disk");
    try tmp.dir.createDirPath(testing.io, "Volumes/alpha");
    try tmp.dir.createDirPath(testing.io, "Volumes/.hidden");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Volumes/file.txt", .data = "" });
    const vols = try std.fs.path.join(gpa, &.{ base, "Volumes" });
    defer gpa.free(vols);
    volumes_root = vols;
    defer volumes_root = "/Volumes";

    var host = try engine_host.EngineHost.init(gpa, "dev-drives", "Synthetic");
    defer host.deinit();
    host.io = testing.io;
    const out = try host.handle("ListDrives", .{ .object = .empty });
    defer gpa.free(out.unary_json);
    var parsed = try json.parseFromSlice(json.Value, gpa, out.unary_json, .{});
    defer parsed.deinit();
    const drives = parsed.value.object.get("drives").?.array.items;
    try testing.expectEqual(@as(usize, 2), drives.len);
    try testing.expectEqualStrings("alpha", drives[0].object.get("name").?.string);
    try testing.expectEqualStrings("Zeta Disk", drives[1].object.get("name").?.string);
    try testing.expect(std.mem.endsWith(u8, drives[1].object.get("path").?.string, "/Volumes/Zeta Disk"));

    // No I/O: an error, not a made-up drive.
    var bare = try engine_host.EngineHost.init(gpa, "dev-bare", "Synthetic");
    defer bare.deinit();
    const none = try bare.handle("ListDrives", .{ .object = .empty });
    try testing.expect(none == .err);
}

test "rpcw_workspace_files WriteWorkspaceFile writes into the chat's space and reports failures" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try common.tmpPath(gpa, testing.io, &tmp);
    defer gpa.free(base);
    var host = try engine_host.EngineHost.init(gpa, "dev-write", "Synthetic");
    defer host.deinit();
    host.io = testing.io;

    const space_body = try std.fmt.allocPrint(gpa, "{{\"op\":\"createSpace\",\"spaceId\":\"sp-w\",\"name\":\"w\",\"path\":{f}}}", .{json.fmt(base, .{})});
    defer gpa.free(space_body);
    var sp = try json.parseFromSlice(json.Value, gpa, space_body, .{});
    defer sp.deinit();
    const sr = try host.handle("Mutate", sp.value);
    if (sr == .unary_json) gpa.free(sr.unary_json);
    var cp = try json.parseFromSlice(json.Value, gpa, "{\"op\":\"createChat\",\"chatId\":\"ch-w\",\"spaceId\":\"sp-w\",\"config\":{\"harness\":\"mock\"}}", .{});
    defer cp.deinit();
    const cr = try host.handle("Mutate", cp.value);
    if (cr == .unary_json) gpa.free(cr.unary_json);

    const call = struct {
        fn f(h: *engine_host.EngineHost, text: []const u8) !RpcOutcome {
            var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
            defer p.deinit();
            return h.handle("WriteWorkspaceFile", p.value);
        }
    }.f;

    const ok = try call(&host, "{\"chatId\":\"ch-w\",\"path\":\"notes/a.txt\",\"text\":\"synthetic\"}");
    defer gpa.free(ok.unary_json);
    try testing.expectEqualStrings("{\"written\":true}", ok.unary_json);
    const disk = try tmp.dir.readFileAlloc(testing.io, "notes/a.txt", gpa, .limited(64));
    defer gpa.free(disk);
    try testing.expectEqualStrings("synthetic", disk);

    // A folder where the file should go: the write fails, and says so.
    try tmp.dir.createDirPath(testing.io, "taken");
    const blocked = try call(&host, "{\"chatId\":\"ch-w\",\"path\":\"taken\",\"text\":\"x\"}");
    try testing.expect(blocked == .err);
    try testing.expect(std.mem.startsWith(u8, blocked.err.exec_error, "Could not save taken"));

    const unknown = try call(&host, "{\"chatId\":\"nope\",\"path\":\"a.txt\",\"text\":\"x\"}");
    try testing.expectEqualStrings("chat not found", unknown.err.exec_error);
    const escape = try call(&host, "{\"chatId\":\"ch-w\",\"path\":\"../out.txt\",\"text\":\"x\"}");
    try testing.expectEqualStrings("path traversal denied", escape.err.bad_params);
    const missing = try call(&host, "{\"chatId\":\"ch-w\",\"path\":\"a.txt\"}");
    try testing.expectEqualStrings("missing field `text`", missing.err.bad_params);
}
