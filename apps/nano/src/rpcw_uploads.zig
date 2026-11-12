//! `UploadCommit`, ported from `crates/engine/src/uploads.rs` (`Uploads::commit`,
//! `staging_dir`, `sanitize`) and the `UPLOAD_COMMIT` arm of
//! `crates/engine/src/rpc.rs`.
//!
//! The staged chunks are the engine's in-memory `staged_uploads` (filled by
//! `UploadChunk`); the durable file is `{data_dir}/uploads/{id8}-{sanitize(name)}`,
//! the path Rust's `Uploads::new(data_dir)` writes. Every failure to create the
//! folder or write the file is the call's error, as in Rust (`io: …`).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");

const RpcOutcome = common.RpcOutcome;

/// `MAX_BYTES`: the largest upload the engine accepts.
pub const max_bytes: usize = 32 * 1024 * 1024;

/// `staging_dir`'s id jail: 1-64 of `[A-Za-z0-9_-]`.
pub fn validUploadId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '-' or b == '_')) return false;
    }
    return true;
}

/// `sanitize`: the file name's last component, every character outside
/// `[A-Za-z0-9._-]` replaced by `_`, its last 80 characters, or `upload`.
/// Rust maps per character, so a multi-byte character becomes one `_`.
pub fn sanitize(gpa: Allocator, file_name: []const u8) ![]u8 {
    const base = baseName(file_name);
    var chars: std.ArrayList(u8) = .empty;
    defer chars.deinit(gpa);
    var i: usize = 0;
    while (i < base.len) {
        const b = base[i];
        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (len == 1 and (std.ascii.isAlphanumeric(b) or b == '.' or b == '-' or b == '_')) {
            try chars.append(gpa, b);
        } else {
            try chars.append(gpa, '_');
        }
        i += @min(len, base.len - i);
    }
    const tail = if (chars.items.len > 80) chars.items[chars.items.len - 80 ..] else chars.items;
    if (tail.len == 0) return gpa.dupe(u8, "upload");
    return gpa.dupe(u8, tail);
}

/// `Path::file_name`: the last normal component; `..`, `.` and an empty
/// path have none.
fn baseName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| i + 1 else 0;
    const last = trimmed[start..];
    if (std.mem.eql(u8, last, "..") or std.mem.eql(u8, last, ".")) return "";
    return last;
}

/// `upload_id.chars().take(8)`.
fn id8(id: []const u8) []const u8 {
    return id[0..@min(id.len, 8)];
}

/// The committed file's name in the uploads folder: `{id8}-{sanitize(name)}`
/// (Rust's `UploadCommit`). Every reader of a `pending://{uploadId}/{name}`
/// ref finds the file through this.
pub fn storedLeaf(gpa: Allocator, upload_id: []const u8, file_name: []const u8) ![]u8 {
    const name = try sanitize(gpa, file_name);
    defer gpa.free(name);
    return std.fmt.allocPrint(gpa, "{s}-{s}", .{ id8(upload_id), name });
}

/// `UploadCommit { uploadId, fileName }` → `{ "path": … }`.
pub fn commit(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct UploadCommitParams", .{});
    const upload_id = common.str(o, "uploadId") orelse return common.badParams("missing field `uploadId`", .{});
    const file_name = common.str(o, "fileName") orelse return common.badParams("missing field `fileName`", .{});
    if (!validUploadId(upload_id)) return common.failedMsg("Invalid upload id");
    const staged = host.staged_uploads.getPtr(upload_id) orelse return common.failedMsg("Unknown or expired upload");
    if (staged.items.len > max_bytes) {
        dropStaged(host, upload_id);
        return common.failedMsg("Upload too large");
    }
    const io = host.io orelse return common.failedMsg("io: the engine has no I/O");
    const data_dir = host.data_dir orelse return common.failedMsg("io: the engine has no data directory");

    const dir = try std.fs.path.join(gpa, &.{ data_dir, "uploads" });
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch |e| return common.failed("io: {s}", .{@errorName(e)});
    const leaf = try storedLeaf(gpa, upload_id, file_name);
    defer gpa.free(leaf);
    const full_path = try std.fs.path.join(gpa, &.{ dir, leaf });
    var path_owned = true;
    defer if (path_owned) gpa.free(full_path);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = staged.items }) catch |e|
        return common.failed("io: {s}", .{@errorName(e)});

    const reply = try std.fmt.allocPrint(gpa, "{{\"path\":{f}}}", .{json.fmt(full_path, .{})});
    errdefer gpa.free(reply);
    // The bytes move to the read cache; the staging entry is gone, as Rust
    // removes its staging folder after the write.
    const kv = host.staged_uploads.fetchRemove(upload_id).?;
    gpa.free(kv.key);
    var list = kv.value;
    const bytes = list.toOwnedSlice(gpa) catch |e| {
        list.deinit(gpa);
        return e;
    };
    path_owned = false;
    try host.insertCommittedUploadBounded(full_path, bytes);
    return .{ .unary_json = reply };
}

fn dropStaged(host: *engine_host.EngineHost, upload_id: []const u8) void {
    if (host.staged_uploads.fetchRemove(upload_id)) |kv| {
        host.gpa.free(kv.key);
        var list = kv.value;
        list.deinit(host.gpa);
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fx = struct {
    tmp: testing.TmpDir,
    data: []u8,
    host: engine_host.EngineHost,

    fn init(f: *Fx) !void {
        const gpa = testing.allocator;
        f.tmp = testing.tmpDir(.{});
        const base = try common.tmpPath(gpa, testing.io, &f.tmp);
        defer gpa.free(base);
        f.data = try std.fs.path.join(gpa, &.{ base, "data" });
        f.host = try engine_host.EngineHost.init(gpa, "dev-upload", "Synthetic");
        f.host.io = testing.io;
        try f.host.setDataDir(f.data);
    }

    fn deinit(f: *Fx) void {
        f.host.deinit();
        testing.allocator.free(f.data);
        f.tmp.cleanup();
    }

    fn call(f: *Fx, method: []const u8, text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
        defer p.deinit();
        return f.host.handle(method, p.value);
    }
};

fn expectErr(outcome: RpcOutcome, expected: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .exec_error, .bad_params => |m| try testing.expectEqualStrings(expected, m),
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

test "rpcw_uploads UploadCommit writes {data}/uploads/{id8}-{name} and returns its path" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const chunk = try f.call("UploadChunk", "{\"uploadId\":\"abcdef123456\",\"seq\":0,\"data\":\"aGVsbG8tcG5n\"}");
    gpa.free(chunk.unary_json);
    const out = try f.call("UploadCommit", "{\"uploadId\":\"abcdef123456\",\"fileName\":\"dir/My Shot (1).png\"}");
    defer gpa.free(out.unary_json);
    const want = try std.fmt.allocPrint(gpa, "{s}/uploads/abcdef12-My_Shot__1_.png", .{f.data});
    defer gpa.free(want);
    var parsed = try json.parseFromSlice(json.Value, gpa, out.unary_json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(want, parsed.value.object.get("path").?.string);
    const disk = try std.Io.Dir.cwd().readFileAlloc(testing.io, want, gpa, .limited(1024));
    defer gpa.free(disk);
    try testing.expectEqualStrings("hello-png", disk);
    try testing.expectEqual(@as(u32, 0), f.host.staged_uploads.count());

    // The file reads back through ReadAttachmentChunk.
    const read_text = try std.fmt.allocPrint(gpa, "{{\"path\":{f},\"offset\":0}}", .{json.fmt(want, .{})});
    defer gpa.free(read_text);
    const read = try f.call("ReadAttachmentChunk", read_text);
    defer gpa.free(read.unary_json);
    try testing.expect(std.mem.indexOf(u8, read.unary_json, "\"data\":\"aGVsbG8tcG5n\"") != null);
}

test "rpcw_uploads UploadCommit errors: unknown upload, bad id, missing fields, unwritable folder, no data dir" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    try expectErr(try f.call("UploadCommit", "{\"uploadId\":\"nothing-here\",\"fileName\":\"a.png\"}"), "Unknown or expired upload");
    try expectErr(try f.call("UploadCommit", "{\"uploadId\":\"../escape\",\"fileName\":\"a.png\"}"), "Invalid upload id");
    try expectErr(try f.call("UploadCommit", "{\"fileName\":\"a.png\"}"), "missing field `uploadId`");
    try expectErr(try f.call("UploadCommit", "{\"uploadId\":\"u1\"}"), "missing field `fileName`");

    // `uploads` is a file, so the folder can't be made: the write fails loudly.
    try f.tmp.dir.createDirPath(testing.io, "data");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/uploads", .data = "not a folder" });
    const chunk = try f.call("UploadChunk", "{\"uploadId\":\"u1\",\"seq\":0,\"data\":\"aGk=\"}");
    gpa.free(chunk.unary_json);
    const out = try f.call("UploadCommit", "{\"uploadId\":\"u1\",\"fileName\":\"a.png\"}");
    try testing.expect(out == .err);
    try testing.expect(std.mem.startsWith(u8, out.err.exec_error, "io: "));

    // No data folder: an error, never a path somewhere else.
    var bare = try engine_host.EngineHost.init(gpa, "dev-bare", "Synthetic");
    defer bare.deinit();
    bare.io = testing.io;
    var p1 = try json.parseFromSlice(json.Value, gpa, "{\"uploadId\":\"u2\",\"seq\":0,\"data\":\"aGk=\"}", .{});
    defer p1.deinit();
    const c2 = try bare.handle("UploadChunk", p1.value);
    gpa.free(c2.unary_json);
    var p2 = try json.parseFromSlice(json.Value, gpa, "{\"uploadId\":\"u2\",\"fileName\":\"a.png\"}", .{});
    defer p2.deinit();
    try expectErr(try bare.handle("UploadCommit", p2.value), "io: the engine has no data directory");
}

test "rpcw_uploads sanitize keeps the last 80 safe characters" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "a b.png", "a_b.png" },
        .{ "../../etc/passwd", "passwd" },
        .{ "..", "upload" },
        .{ "", "upload" },
        .{ "héllo.txt", "h_llo.txt" },
    };
    for (cases) |c| {
        const got = try sanitize(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    var long: [104]u8 = undefined;
    @memset(long[0..100], 'x');
    @memcpy(long[100..], ".png");
    const got = try sanitize(gpa, &long);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 80), got.len);
    try testing.expect(std.mem.endsWith(u8, got, ".png"));
}

test "rpcw_uploads ShowImage, ShowVisual and OpenTerminal need their ids (no made-up defaults)" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try expectErr(try f.call("ShowImage", "{\"chatId\":\"c1\",\"path\":\"a.png\"}"), "missing field `id`");
    try expectErr(try f.call("ShowVisual", "{\"chatId\":\"c1\",\"title\":\"t\",\"script\":\"\"}"), "missing field `id`");
    try expectErr(try f.call("OpenTerminal", "{\"cols\":80,\"rows\":24}"), "missing field `chatId`");
}

test "rpcw_uploads a relayed command finds the file UploadCommit wrote, by its pending:// ref" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const id = "0123456789abcdef";
    const chunk = try f.call("UploadChunk", "{\"uploadId\":\"0123456789abcdef\",\"seq\":0,\"data\":\"aGVsbG8tcG5n\"}");
    gpa.free(chunk.unary_json);
    const out = try f.call("UploadCommit", "{\"uploadId\":\"0123456789abcdef\",\"fileName\":\"Screen Shot 2026-11-12 at 9.41.png\"}");
    defer gpa.free(out.unary_json);
    var parsed = try json.parseFromSlice(json.Value, gpa, out.unary_json, .{});
    defer parsed.deinit();
    const written = parsed.value.object.get("path").?.string;
    const uploads = try std.fs.path.join(gpa, &.{ f.data, "uploads" });
    defer gpa.free(uploads);
    const found = (try @import("relay_command.zig").pendingTargetPath(gpa, uploads, "pending://" ++ id ++ "/Screen Shot 2026-11-12 at 9.41.png")).?;
    defer gpa.free(found);
    try testing.expectEqualStrings(written, found);
}

