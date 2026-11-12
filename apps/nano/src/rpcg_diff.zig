//! Checkout diff capture for the Changes pane, ported from
//! `crates/engine/src/diff_sync.rs` and `diff_sync/git_status.rs`: one bounded
//! atomic working-tree snapshot (tracked diff against HEAD or another base,
//! untracked files as synthesized new-file hunks, a 3 MiB patch cap and a
//! sha256 checksum), commit and "latest turn" diffs, the exact old/new text of
//! one file, the porcelain status the explorer shows, and the checksum-guarded
//! discard of a working tree.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const g = @import("rpcg_git.zig");

/// `MAX_PATCH_BYTES` / `MAX_DIFF_SOURCE_BYTES`.
pub const max_patch_bytes: usize = 3 * 1024 * 1024;
pub const max_diff_source_bytes: usize = 2 * 1024 * 1024;
const listing_cap: usize = 2 * 1024 * 1024;
/// `git hash-object -t tree /dev/null`: the base for a repository with no commit.
pub const empty_tree_sha = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
/// Captures never hang a request or the watcher: a wedged git is killed.
pub const capture_timeout_ms: i64 = 120_000;

pub const Result = g.Result;

// ── bounded git capture ────────────────────────────────────────────────────

pub const Capture = struct {
    stdout: []u8,
    truncated: bool,
};

pub const CaptureOptions = struct {
    /// Replaces the child environment (default: the engine's, or the test override).
    env: ?*const std.process.Environ.Map = null,
    /// Polled while waiting; set means the engine is stopping.
    stop: ?*const bool = null,
    timeout_ms: i64 = capture_timeout_ms,
};

/// `capture_git`: `git -C root <args>` with stdout capped at `max_bytes`
/// (the child is killed once it is hit, and the capture says `truncated`).
pub fn captureGit(gpa: Allocator, io: std.Io, root: []const u8, args: []const []const u8, max_bytes: usize) !Result(Capture) {
    return captureGitWith(gpa, io, root, args, max_bytes, .{});
}

pub fn captureGitWith(gpa: Allocator, io: std.Io, root: []const u8, args: []const []const u8, max_bytes: usize, opts: CaptureOptions) !Result(Capture) {
    if (comptime !std.process.can_spawn) return .{ .failed = "git spawn failed: processes are unavailable" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", root });
    try argv.appendSlice(gpa, args);
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = opts.env orelse common.env_override,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |e| return .{ .failed = common.errText("git spawn failed: {s}", .{@errorName(e)}) };
    defer child.kill(io);

    var mr_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    const started = std.Io.Clock.awake.now(io);
    var truncated = false;
    while (true) {
        mr.fill(64 * 1024, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (opts.stop) |s| if (@atomicLoad(bool, s, .acquire)) return .{ .failed = "git capture stopped: the engine is shutting down" };
                const elapsed = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
                if (elapsed > opts.timeout_ms) return .{ .failed = common.errText("git {s} timed out", .{if (args.len > 0) args[0] else "?"}) };
                continue;
            },
            else => |e| return .{ .failed = common.errText("git read failed: {s}", .{@errorName(e)}) },
        };
        if (mr.reader(0).buffered().len > max_bytes) {
            truncated = true;
            break;
        }
    }
    if (truncated) {
        const all = mr.reader(0).buffered();
        return .{ .ok = .{ .stdout = try gpa.dupe(u8, all[0..max_bytes]), .truncated = true } };
    }
    mr.checkAnyError() catch |e| return .{ .failed = common.errText("git read failed: {s}", .{@errorName(e)}) };
    const term = child.wait(io) catch |e| return .{ .failed = common.errText("git wait failed: {s}", .{@errorName(e)}) };
    const out = try mr.toOwnedSlice(0);
    errdefer gpa.free(out);
    const err_out = try mr.toOwnedSlice(1);
    defer gpa.free(err_out);
    const ok = term == .exited and term.exited == 0;
    if (!ok) {
        gpa.free(out);
        const message = std.mem.trim(u8, err_out, " \t\r\n");
        if (message.len > 0) return .{ .failed = common.errText("git: {s}", .{message}) };
        return .{ .failed = switch (term) {
            .exited => |c| common.errText("git exited exit status: {d}", .{c}),
            else => "git exited (signal)",
        } };
    }
    return .{ .ok = .{ .stdout = out, .truncated = false } };
}

/// First line of a small capture, trimmed; "" on any failure.
fn captureLine(gpa: Allocator, io: std.Io, root: []const u8, args: []const []const u8) ![]u8 {
    const r = try captureGit(gpa, io, root, args, 256);
    return switch (r) {
        .ok => |c| blk: {
            defer gpa.free(c.stdout);
            break :blk gpa.dupe(u8, std.mem.trim(u8, c.stdout, " \t\r\n"));
        },
        .failed => gpa.dupe(u8, ""),
    };
}

// ── parsing ────────────────────────────────────────────────────────────────

pub const FileSummary = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    status: []const u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    binary: bool = false,
};

/// `String::from_utf8_lossy`, allocated in `arena`.
fn lossy(arena: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return arena.dupe(u8, bytes);
    var aw: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try aw.writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n <= bytes.len and (if (std.unicode.utf8Decode(bytes[i .. i + n])) |_| true else |_| false)) {
            try aw.writer.writeAll(bytes[i .. i + n]);
            i += n;
        } else {
            try aw.writer.writeAll("\u{FFFD}");
            i += 1;
        }
    }
    return aw.written();
}

/// `split_z`: non-empty NUL-separated fields, lossily decoded.
fn splitZ(arena: Allocator, value: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, 0);
    while (it.next()) |part| if (part.len > 0) try out.append(arena, try lossy(arena, part));
    return out.items;
}

/// `parse_name_status` over `git diff --name-status -z --find-renames`.
pub fn parseNameStatus(arena: Allocator, value: []const u8) !std.ArrayList(FileSummary) {
    const fields = try splitZ(arena, value);
    var out: std.ArrayList(FileSummary) = .empty;
    var i: usize = 0;
    while (i < fields.len) {
        const raw = fields[i];
        i += 1;
        const code: u8 = if (raw.len > 0) raw[0] else 'M';
        if (i >= fields.len) break;
        const first = fields[i];
        i += 1;
        const renamed = code == 'R' or code == 'C';
        var second: ?[]const u8 = null;
        if (renamed) {
            second = if (i < fields.len) fields[i] else null;
            i += 1;
        }
        const status: []const u8 = switch (code) {
            'A' => "added",
            'D' => "deleted",
            'R' => "renamed",
            'C' => "copied",
            'U' => "unmerged",
            else => "modified",
        };
        try out.append(arena, .{
            .path = second orelse first,
            .old_path = if (second != null) first else null,
            .status = status,
        });
    }
    return out;
}

/// `apply_numstat`: line counts and the binary flag from `--numstat -z`.
pub fn applyNumstat(arena: Allocator, files: []FileSummary, value: []const u8) !void {
    var records: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, 0);
    while (it.next()) |part| try records.append(arena, try lossy(arena, part));
    var i: usize = 0;
    while (i < records.items.len) {
        const record = records.items[i];
        if (record.len == 0) {
            i += 1;
            continue;
        }
        var parts = std.mem.splitScalar(u8, record, '\t');
        const adds = parts.next() orelse "";
        const dels = parts.next() orelse "";
        const inline_path = parts.rest();
        var path = inline_path;
        if (inline_path.len == 0) {
            path = if (i + 2 < records.items.len) records.items[i + 2] else "";
            i += 2;
        }
        i += 1;
        for (files) |*f| if (std.mem.eql(u8, f.path, path)) {
            f.additions = std.fmt.parseInt(u32, adds, 10) catch 0;
            f.deletions = std.fmt.parseInt(u32, dels, 10) catch 0;
            f.binary = std.mem.eql(u8, adds, "-") or std.mem.eql(u8, dels, "-");
            break;
        };
    }
}

fn quotePatchPath(arena: Allocator, path: []const u8) ![]const u8 {
    for (path) |c| {
        if (std.ascii.isWhitespace(c) or c == '"' or c == '\\') {
            var aw: std.Io.Writer.Allocating = .init(arena);
            try g.writeJsonString(&aw.writer, path);
            return aw.written();
        }
    }
    return path;
}

/// `untracked_patch`: a new-file hunk for an untracked file.
pub fn untrackedPatch(arena: Allocator, path: []const u8, content: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| try lines.append(arena, l);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const a = try quotePatchPath(arena, try std.fmt.allocPrint(arena, "a/{s}", .{path}));
    const b = try quotePatchPath(arena, try std.fmt.allocPrint(arena, "b/{s}", .{path}));
    try w.print("diff --git {s} {s}\nnew file mode 100644\n--- /dev/null\n+++ {s}\n@@ -0,0 +1,{d} @@\n", .{ a, b, b, lines.items.len });
    for (lines.items, 0..) |l, i| {
        if (i > 0) try w.writeByte('\n');
        try w.writeByte('+');
        try w.writeAll(l);
    }
    try w.writeByte('\n');
    return aw.written();
}

/// `has_non_utf8_status_path`.
pub fn hasNonUtf8StatusPath(value: []const u8) bool {
    var records: [2][]const u8 = undefined;
    _ = &records;
    var it = std.mem.splitScalar(u8, value, 0);
    var pending_old = false;
    while (it.next()) |record| {
        if (record.len == 0) continue;
        if (pending_old) {
            pending_old = false;
            if (!std.unicode.utf8ValidateSlice(record)) return true;
            continue;
        }
        if (record.len < 3 or record[2] != ' ') continue;
        if (!std.unicode.utf8ValidateSlice(record[3..])) return true;
        if (record[0] == 'R' or record[0] == 'C') pending_old = true;
    }
    return false;
}

pub const FileState = enum {
    unchanged,
    added,
    modified,
    deleted,
    renamed,
    copied,
    unmerged,
    untracked,
    typeChanged,

    fn of(code: u8) ?FileState {
        return switch (code) {
            ' ' => .unchanged,
            'A' => .added,
            'M' => .modified,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            'U' => .unmerged,
            '?' => .untracked,
            'T' => .typeChanged,
            else => null,
        };
    }
};

pub const GitFileStatus = struct {
    path: []const u8,
    old_path: ?[]const u8,
    index: FileState,
    worktree: FileState,
};

pub const GitStatus = struct {
    files: []GitFileStatus,
    complete: bool,
};

/// `git_status::parse`: porcelain v1 -z records (destination first for
/// renames), never turning a truncated record or invalid UTF-8 into a clean
/// row; two records for one path keep both sides.
pub fn parseGitStatus(arena: Allocator, bytes: []const u8, truncated: bool) !GitStatus {
    var complete = !truncated and (bytes.len == 0 or bytes[bytes.len - 1] == 0);
    var records: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |r| try records.append(arena, r);
    var files: std.ArrayList(GitFileStatus) = .empty;
    var i: usize = 0;
    while (i < records.items.len) {
        const record = records.items[i];
        i += 1;
        if (record.len == 0 and i == records.items.len) break;
        if (record.len < 4 or record[2] != ' ') {
            complete = false;
            break;
        }
        const renamed = record[0] == 'R' or record[0] == 'C' or record[1] == 'R' or record[1] == 'C';
        var old: ?[]const u8 = null;
        var has_old = false;
        if (renamed and i < records.items.len) {
            old = records.items[i];
            has_old = true;
            i += 1;
        }
        const index = FileState.of(record[0]) orelse {
            complete = false;
            continue;
        };
        const worktree = FileState.of(record[1]) orelse {
            complete = false;
            continue;
        };
        const path = record[3..];
        if (!std.unicode.utf8ValidateSlice(path)) {
            complete = false;
            continue;
        }
        var old_path: ?[]const u8 = null;
        if (renamed) {
            if (!has_old or old.?.len == 0 or !std.unicode.utf8ValidateSlice(old.?)) {
                complete = false;
                continue;
            }
            old_path = old;
        }
        try files.append(arena, .{ .path = path, .old_path = old_path, .index = index, .worktree = worktree });
    }
    std.mem.sort(GitFileStatus, files.items, {}, struct {
        fn lt(_: void, a: GitFileStatus, b: GitFileStatus) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);
    var merged: std.ArrayList(GitFileStatus) = .empty;
    for (files.items) |f| {
        if (merged.items.len > 0 and std.mem.eql(u8, merged.items[merged.items.len - 1].path, f.path)) {
            const prev = &merged.items[merged.items.len - 1];
            if (f.index != .unchanged and f.index != .untracked) prev.index = f.index;
            if (f.worktree != .unchanged) prev.worktree = f.worktree;
            if (prev.old_path == null) prev.old_path = f.old_path;
        } else {
            try merged.append(arena, f);
        }
    }
    return .{ .files = merged.items, .complete = complete };
}

// ── snapshots ──────────────────────────────────────────────────────────────

/// One bounded atomic snapshot (`DiffSnapshot`). Everything lives in `arena`.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    git_status: ?GitStatus = null,
    branch: []const u8,
    head_sha: ?[]const u8,
    patch: []const u8,
    files: []FileSummary,
    additions: u32,
    deletions: u32,
    truncated: bool,
    checksum: [64]u8,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

/// `files` as serde_json writes `Vec<DiffFileSummary>`.
pub fn writeFiles(w: *std.Io.Writer, files: []const FileSummary) !void {
    try w.writeByte('[');
    for (files, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try g.writeJsonString(w, f.path);
        if (f.old_path) |op| {
            try w.writeAll(",\"oldPath\":");
            try g.writeJsonString(w, op);
        }
        try w.writeAll(",\"status\":");
        try g.writeJsonString(w, f.status);
        try w.print(",\"additions\":{d},\"deletions\":{d},\"binary\":{}}}", .{ f.additions, f.deletions, f.binary });
    }
    try w.writeByte(']');
}

fn checksumOf(arena: Allocator, branch: []const u8, rev: []const u8, patch: []const u8, files: []const FileSummary, truncated: bool) ![64]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeFiles(&aw.writer, files);
    var hex: [64]u8 = undefined;
    _ = g.sha256Hex(&hex, &.{ branch, &.{0}, rev, &.{0}, patch, &.{0}, aw.written(), if (truncated) "1" else "0" });
    return hex;
}

fn sumCounts(files: []const FileSummary) struct { u32, u32 } {
    var a: u32 = 0;
    var d: u32 = 0;
    for (files) |f| {
        a +%= f.additions;
        d +%= f.deletions;
    }
    return .{ a, d };
}

fn branchOrHead(arena: Allocator, io: std.Io, root: []const u8) ![]const u8 {
    return switch (try g.currentBranch(arena, io, root)) {
        .ok => |b| b,
        .failed => "HEAD",
    };
}

/// Captures owned by `arena` for the three diff listings plus the patch.
const Listings = struct { names: Capture, nums: Capture, tracked: Capture };

fn diffListings(arena: Allocator, io: std.Io, root: []const u8, range: []const []const u8, opts: CaptureOptions) !Result(Listings) {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "diff", "--name-status", "-z", "--find-renames" });
    try args.appendSlice(arena, range);
    try args.append(arena, "--");
    const names = switch (try captureGitWith(arena, io, root, args.items, listing_cap, opts)) {
        .ok => |c| c,
        .failed => |m| return .{ .failed = m },
    };
    args.items[1] = "--numstat";
    const nums = switch (try captureGitWith(arena, io, root, args.items, listing_cap, opts)) {
        .ok => |c| c,
        .failed => |m| return .{ .failed = m },
    };
    var patch_args: std.ArrayList([]const u8) = .empty;
    try patch_args.appendSlice(arena, &.{ "diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3" });
    try patch_args.appendSlice(arena, range);
    try patch_args.append(arena, "--");
    const tracked = switch (try captureGitWith(arena, io, root, patch_args.items, max_patch_bytes, opts)) {
        .ok => |c| c,
        .failed => |m| return .{ .failed = m },
    };
    return .{ .ok = .{ .names = names, .nums = nums, .tracked = tracked } };
}

fn cutTruncatedPatch(arena: Allocator, patch: []const u8, marker: []const u8) ![]const u8 {
    const boundary = std.mem.lastIndexOfScalar(u8, patch, '\n') orelse 0;
    return std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ patch[0..boundary], marker });
}

/// `capture_diff_against`: the working tree against `base_override` (or HEAD,
/// or the empty tree), untracked files synthesized as new.
pub fn captureDiffAgainst(gpa: Allocator, io: std.Io, root: []const u8, base_override: ?[]const u8, opts: CaptureOptions) !Result(Snapshot) {
    var snap: Snapshot = undefined;
    snap.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer snap.arena.deinit();
    const arena = snap.arena.allocator();

    const head = try captureLine(arena, io, root, &.{ "rev-parse", "--verify", "HEAD" });
    const base: []const u8 = base_override orelse (if (head.len == 0) empty_tree_sha else head);
    const branch = try branchOrHead(arena, io, root);
    const lists = switch (try diffListings(arena, io, root, &.{base}, opts)) {
        .ok => |l| l,
        .failed => |m| {
            snap.arena.deinit();
            return .{ .failed = m };
        },
    };
    // `--no-optional-locks` keeps status read-only (no index refresh).
    const status = switch (try captureGitWith(arena, io, root, &.{ "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all" }, listing_cap, opts)) {
        .ok => |c| c,
        .failed => |m| {
            snap.arena.deinit();
            return .{ .failed = m };
        },
    };

    var files = try parseNameStatus(arena, lists.names.stdout);
    try applyNumstat(arena, files.items, lists.nums.stdout);
    var patch: std.ArrayList(u8) = .empty;
    try patch.appendSlice(arena, try lossy(arena, lists.tracked.stdout));
    var truncated = lists.tracked.truncated or lists.names.truncated or lists.nums.truncated or status.truncated;
    if (hasNonUtf8StatusPath(status.stdout)) truncated = true;
    if (lists.tracked.truncated) {
        const cut = try cutTruncatedPatch(arena, patch.items, "# Harness diff truncated");
        patch.clearRetainingCapacity();
        try patch.appendSlice(arena, cut);
    }

    // `?? path` records; a rename record's origin field is skipped.
    var untracked: std.ArrayList([]const u8) = .empty;
    const records = try splitZ(arena, status.stdout);
    var i: usize = 0;
    while (i < records.len) {
        const record = records[i];
        i += 1;
        if (record.len < 3) continue;
        const code = record[0..2];
        if (code[0] == 'R' or code[0] == 'C') i += 1;
        if (std.mem.eql(u8, code, "??")) try untracked.append(arena, std.mem.trimStart(u8, record[2..], " \t\r\n"));
    }
    std.mem.sort([]const u8, untracked.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var budget: usize = max_patch_bytes;
    for (untracked.items) |path| {
        if (budget == 0) {
            truncated = true;
            break;
        }
        const full = try std.fs.path.join(arena, &.{ root, path });
        const st = std.Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch continue;
        var binary = false;
        var additions: u32 = 0;
        if (st.kind == .directory) {
            // Nested repositories stay atomic: shown, never read or cleaned.
            binary = true;
        } else if (st.size > max_patch_bytes) {
            binary = true;
            truncated = true;
        } else {
            const bytes: []const u8 = if (st.kind == .sym_link) blk: {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = std.Io.Dir.cwd().readLink(io, full, &link_buf) catch continue;
                break :blk try arena.dupe(u8, link_buf[0..n]);
            } else std.Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(budget + 1)) catch |e| switch (e) {
                error.StreamTooLong => {
                    truncated = true;
                    break;
                },
                else => continue,
            };
            if (bytes.len > budget) {
                truncated = true;
                break;
            }
            budget -|= @max(bytes.len, 1);
            binary = std.mem.indexOfScalar(u8, bytes, 0) != null;
            if (!binary) {
                const text = try lossy(arena, bytes);
                if (text.len > 0) {
                    additions = @intCast(std.mem.count(u8, text, "\n") + 1 - @intFromBool(text[text.len - 1] == '\n'));
                }
                const addition = try untrackedPatch(arena, path, text);
                if (patch.items.len + addition.len <= max_patch_bytes) {
                    if (patch.items.len > 0 and patch.items[patch.items.len - 1] != '\n') try patch.append(arena, '\n');
                    try patch.appendSlice(arena, addition);
                } else {
                    truncated = true;
                }
            }
        }
        try files.append(arena, .{ .path = path, .status = "added", .additions = additions, .binary = binary });
    }

    const add, const del = sumCounts(files.items);
    snap.git_status = try parseGitStatus(arena, status.stdout, status.truncated);
    snap.branch = branch;
    snap.head_sha = if (head.len == 0) null else head;
    snap.patch = patch.items;
    snap.files = files.items;
    snap.additions = add;
    snap.deletions = del;
    snap.truncated = truncated;
    snap.checksum = try checksumOf(arena, branch, head, patch.items, files.items, truncated);
    return .{ .ok = snap };
}

pub fn captureDiff(gpa: Allocator, io: std.Io, root: []const u8, opts: CaptureOptions) !Result(Snapshot) {
    return captureDiffAgainst(gpa, io, root, null, opts);
}

/// Shared tail of the commit and turn diffs (no untracked synthesis).
fn treeDiff(gpa: Allocator, io: std.Io, root: []const u8, from: []const u8, to: []const u8, rev_for_checksum: ?[]const u8, marker: []const u8) !Result(Snapshot) {
    var snap: Snapshot = undefined;
    snap.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer snap.arena.deinit();
    const arena = snap.arena.allocator();
    const branch = try branchOrHead(arena, io, root);
    const head: []const u8 = rev_for_checksum orelse try captureLine(arena, io, root, &.{ "rev-parse", "--verify", "HEAD" });
    const lists = switch (try diffListings(arena, io, root, &.{ from, to }, .{})) {
        .ok => |l| l,
        .failed => |m| {
            snap.arena.deinit();
            return .{ .failed = m };
        },
    };
    const files = try parseNameStatus(arena, lists.names.stdout);
    try applyNumstat(arena, files.items, lists.nums.stdout);
    var patch = try lossy(arena, lists.tracked.stdout);
    const truncated = lists.tracked.truncated or lists.names.truncated or lists.nums.truncated;
    if (lists.tracked.truncated) patch = try cutTruncatedPatch(arena, patch, marker);
    const add, const del = sumCounts(files.items);
    snap.git_status = null;
    snap.branch = branch;
    snap.head_sha = if (head.len == 0) null else head;
    snap.patch = patch;
    snap.files = files.items;
    snap.additions = add;
    snap.deletions = del;
    snap.truncated = truncated;
    snap.checksum = try checksumOf(arena, branch, head, patch, files.items, truncated);
    return .{ .ok = snap };
}

/// `commit_diff_base`: the commit's parent, or the empty tree for a root commit.
pub fn commitDiffBase(gpa: Allocator, io: std.Io, root: []const u8, sha: []const u8) ![]u8 {
    const spec = try std.fmt.allocPrint(gpa, "{s}^", .{sha});
    defer gpa.free(spec);
    const parent = try captureLine(gpa, io, root, &.{ "rev-parse", "--verify", spec });
    if (parent.len == 0) {
        gpa.free(parent);
        return gpa.dupe(u8, empty_tree_sha);
    }
    return parent;
}

/// `working_diff_base`: HEAD, or the empty tree before the first commit.
pub fn workingDiffBase(gpa: Allocator, io: std.Io, root: []const u8) ![]u8 {
    const head = try captureLine(gpa, io, root, &.{ "rev-parse", "--verify", "HEAD" });
    if (head.len == 0) {
        gpa.free(head);
        return gpa.dupe(u8, empty_tree_sha);
    }
    return head;
}

/// `capture_commit_diff`: one commit's own changes against its first parent.
pub fn captureCommitDiff(gpa: Allocator, io: std.Io, root: []const u8, sha: []const u8) !Result(Snapshot) {
    const base = try commitDiffBase(gpa, io, root, sha);
    defer gpa.free(base);
    return treeDiff(gpa, io, root, base, sha, sha, "# Comet diff truncated");
}

/// `merge_base(base_ref, HEAD)`: the base of "Branch changes".
pub fn mergeBase(gpa: Allocator, io: std.Io, root: []const u8, base_ref: []const u8) !Result([]u8) {
    const r = try captureGit(gpa, io, root, &.{ "merge-base", base_ref, "HEAD" }, 256);
    switch (r) {
        .failed => |m| return .{ .failed = m },
        .ok => |c| {
            defer gpa.free(c.stdout);
            const sha = std.mem.trim(u8, c.stdout, " \t\r\n");
            if (sha.len == 0) return .{ .failed = common.errText("no merge base with {s}", .{base_ref}) };
            return .{ .ok = try gpa.dupe(u8, sha) };
        },
    }
}

/// The engine's environment as a map (the test override when installed).
pub fn currentEnvMap(gpa: Allocator) !std.process.Environ.Map {
    if (common.env_override) |m| return m.clone(gpa);
    if (comptime builtin.os.tag == .windows) {
        return (std.process.Environ{ .block = .global }).createMap(gpa) catch std.process.Environ.Map.init(gpa);
    }
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    if (comptime builtin.link_libc) {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const s = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
            if (eq == 0) continue;
            try map.put(s[0..eq], s[eq + 1 ..]);
        }
    }
    return map;
}

var snapshot_counter: std.atomic.Value(u64) = .init(0);

/// `snapshot_tree`: the tracked + untracked (unignored) tree written through a
/// throwaway index (`GIT_INDEX_FILE`); the real index is never touched.
pub fn snapshotTree(gpa: Allocator, io: std.Io, root: []const u8) !Result([]u8) {
    const tmp_dir = common.getenvNonEmpty("TMPDIR") orelse common.getenvNonEmpty("TEMP") orelse "/tmp";
    const now_us = @divTrunc(std.Io.Clock.real.now(io).nanoseconds, 1000);
    const pid: i64 = if (comptime builtin.os.tag != .windows and builtin.link_libc) std.c.getpid() else 0;
    const name = try std.fmt.allocPrint(gpa, "harness-turn-index-{d}-{d}-{d}", .{ pid, now_us, snapshot_counter.fetchAdd(1, .monotonic) });
    defer gpa.free(name);
    const index = try std.fs.path.join(gpa, &.{ tmp_dir, name });
    defer gpa.free(index);
    defer std.Io.Dir.cwd().deleteFile(io, index) catch {};
    var env = try currentEnvMap(gpa);
    defer env.deinit();
    try env.put("GIT_INDEX_FILE", index);
    const added = try captureGitWith(gpa, io, root, &.{ "add", "-A", "--ignore-errors", "." }, 64 * 1024, .{ .env = &env });
    switch (added) {
        .failed => |m| return .{ .failed = common.errText("git add: {s}", .{std.mem.trimStart(u8, m, "git: ")}) },
        .ok => |c| gpa.free(c.stdout),
    }
    const written = try captureGitWith(gpa, io, root, &.{"write-tree"}, 256, .{ .env = &env });
    switch (written) {
        .failed => |m| return .{ .failed = common.errText("git write-tree: {s}", .{std.mem.trimStart(u8, m, "git: ")}) },
        .ok => |c| {
            defer gpa.free(c.stdout);
            return .{ .ok = try gpa.dupe(u8, std.mem.trim(u8, c.stdout, " \t\r\n")) };
        },
    }
}

/// `capture_turn_diff`: turn-start tree against a fresh snapshot of now.
pub fn captureTurnDiff(gpa: Allocator, io: std.Io, root: []const u8, turn_tree: []const u8) !Result(Snapshot) {
    const current = switch (try snapshotTree(gpa, io, root)) {
        .ok => |t| t,
        .failed => |m| return .{ .failed = m },
    };
    defer gpa.free(current);
    return treeDiff(gpa, io, root, turn_tree, current, null, "# Harness diff truncated");
}

// ── discard ────────────────────────────────────────────────────────────────

/// `status_paths`: tracked paths (both sides of renames) and untracked ones.
fn statusPaths(arena: Allocator, status: []const u8) !struct { [][]const u8, [][]const u8 } {
    var tracked: std.ArrayList([]const u8) = .empty;
    var untracked: std.ArrayList([]const u8) = .empty;
    var records: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, status, 0);
    while (it.next()) |r| if (r.len > 0) try records.append(arena, r);
    var i: usize = 0;
    while (i < records.items.len) {
        const record = records.items[i];
        i += 1;
        if (record.len < 4 or record[2] != ' ') continue;
        const code = record[0..2];
        const path = record[3..];
        if (std.mem.eql(u8, code, "??")) {
            try untracked.append(arena, path);
            continue;
        }
        if (std.mem.eql(u8, code, "!!")) continue;
        try tracked.append(arena, path);
        if ((std.mem.indexOfAny(u8, code, "RC") != null) and i < records.items.len) {
            try tracked.append(arena, records.items[i]);
            i += 1;
        }
    }
    const lt = struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt;
    std.mem.sort([]const u8, tracked.items, {}, lt);
    std.mem.sort([]const u8, untracked.items, {}, lt);
    return .{ dedup(tracked.items), dedup(untracked.items) };
}

fn dedup(items: [][]const u8) [][]const u8 {
    if (items.len == 0) return items;
    var n: usize = 1;
    for (items[1..]) |it| {
        if (!std.mem.eql(u8, it, items[n - 1])) {
            items[n] = it;
            n += 1;
        }
    }
    return items[0..n];
}

/// Path bytes per git invocation (Windows caps a command line at 32,767 units).
const max_path_argument_bytes: usize = 16 * 1024;

/// `path_batches`: consecutive batches of at most `budget` bytes (one NUL per
/// path counted); a single oversized path is its own batch.
pub fn pathBatches(arena: Allocator, paths: []const []const u8, budget: usize) ![]const []const []const u8 {
    var batches: std.ArrayList([]const []const u8) = .empty;
    var start: usize = 0;
    var bytes: usize = 0;
    for (paths, 0..) |p, index| {
        const cost = p.len + 1;
        if (index > start and bytes + cost > budget) {
            try batches.append(arena, paths[start..index]);
            start = index;
            bytes = 0;
        }
        bytes += cost;
    }
    if (start < paths.len) try batches.append(arena, paths[start..]);
    return batches.items;
}

fn runGitForPaths(arena: Allocator, io: std.Io, root: []const u8, fixed: []const []const u8, paths: []const []const u8) !Result(void) {
    for (try pathBatches(arena, paths, max_path_argument_bytes)) |batch| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "git", "-C", root, "--literal-pathspecs" });
        try argv.appendSlice(arena, fixed);
        try argv.append(arena, "--");
        try argv.appendSlice(arena, batch);
        var res = common.run(arena, io, argv.items, null, capture_timeout_ms) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TimedOut => return .{ .failed = "git discard timed out" },
            else => return .{ .failed = common.errText("git spawn failed: {s}", .{@errorName(e)}) },
        };
        if (!res.success()) {
            const message = std.mem.trim(u8, res.stderr, " \t\r\n");
            if (message.len > 0) return .{ .failed = common.errText("git: {s}", .{message}) };
            return .{ .failed = switch (res.term) {
                .exited => |c| common.errText("git discard failed (exit status: {d})", .{c}),
                else => "git discard failed (signal)",
            } };
        }
    }
    return .{ .ok = {} };
}

/// `discard_working_tree`: restore tracked paths to the snapshot's HEAD and
/// remove exactly the untracked paths git reported, only when the UI acted on
/// this exact full snapshot. Ignored files, nested repositories and submodule
/// contents are never touched; anything unsafe is refused before mutating.
pub fn discardWorkingTree(gpa: Allocator, io: std.Io, root: []const u8, expected_checksum: []const u8) !Result(Snapshot) {
    {
        var snap = switch (try captureDiff(gpa, io, root, .{})) {
            .ok => |s| s,
            .failed => |m| return .{ .failed = m },
        };
        defer snap.deinit();
        if (snap.head_sha == null) return .{ .failed = "cannot discard changes before the first commit" };
        if (snap.truncated) return .{ .failed = "cannot safely discard a partial diff snapshot" };
        if (!std.mem.eql(u8, &snap.checksum, expected_checksum)) return .{ .failed = "working tree changed since the confirmation was opened" };

        const arena = snap.arena.allocator();
        const status = switch (try captureGit(arena, io, root, &.{ "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all" }, listing_cap)) {
            .ok => |c| c,
            .failed => |m| return .{ .failed = m },
        };
        if (status.truncated) return .{ .failed = "cannot safely discard a truncated working-tree status" };
        const tracked, const untracked = try statusPaths(arena, status.stdout);
        const isDirectory = struct {
            fn f(a: Allocator, i: std.Io, r: []const u8, p: []const u8) bool {
                const full = std.fs.path.join(a, &.{ r, p }) catch return false;
                const st = std.Io.Dir.cwd().statFile(i, full, .{ .follow_symlinks = false }) catch return false;
                return st.kind == .directory;
            }
        }.f;
        for (untracked) |p| if (isDirectory(arena, io, root, p)) return .{ .failed = "cannot discard an untracked nested repository safely" };
        for (tracked) |p| if (isDirectory(arena, io, root, p)) return .{ .failed = "cannot discard submodule or directory changes safely" };

        const source = try std.fmt.allocPrint(arena, "--source={s}", .{snap.head_sha.?});
        switch (try runGitForPaths(arena, io, root, &.{ "restore", source, "--staged", "--worktree" }, tracked)) {
            .failed => |m| return .{ .failed = m },
            .ok => {},
        }
        switch (try runGitForPaths(arena, io, root, &.{ "clean", "-fd" }, untracked)) {
            .failed => |m| return .{ .failed = m },
            .ok => {},
        }
        // `git clean` of exact files can leave their emptied parents behind.
        for (untracked) |p| {
            var dir = std.fs.path.dirname(p);
            while (dir) |d| {
                const full = try std.fs.path.join(arena, &.{ root, d });
                std.Io.Dir.cwd().deleteDir(io, full) catch break;
                dir = std.fs.path.dirname(d);
            }
        }
    }
    var final = switch (try captureDiff(gpa, io, root, .{})) {
        .ok => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    if (final.files.len != 0 or std.mem.trim(u8, final.patch, " \t\r\n").len != 0) {
        final.deinit();
        return .{ .failed = "some changes could not be discarded safely" };
    }
    return .{ .ok = final };
}

// ── one file's text ────────────────────────────────────────────────────────

pub const TextPair = struct {
    old_text: ?[]const u8 = null,
    new_text: ?[]const u8 = null,
    old_hash: ?[64]u8 = null,
    new_hash: ?[64]u8 = null,
    binary: bool = false,
    truncated: bool = false,
};

/// `validate_diff_path`: relative, every component a normal name.
pub fn validDiffPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    if (builtin.os.tag == .windows and path.len >= 2 and path[1] == ':') return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return false;
    }
    return std.mem.indexOf(u8, path, "//") == null;
}

const Source = struct { bytes: []const u8, truncated: bool };

fn readGitSource(arena: Allocator, io: std.Io, root: []const u8, revision: []const u8, path: []const u8) !Result(Source) {
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ revision, path });
    return switch (try captureGit(arena, io, root, &.{ "cat-file", "blob", spec }, max_diff_source_bytes)) {
        .ok => |c| .{ .ok = .{ .bytes = c.stdout, .truncated = c.truncated } },
        .failed => |m| .{ .failed = m },
    };
}

fn readWorktreeSource(arena: Allocator, io: std.Io, root: []const u8, path: []const u8) !Result(Source) {
    const canonical_root = common.canonicalize(arena, io, root) orelse return .{ .failed = "canonical checkout: the checkout folder is unavailable" };
    const full = try std.fs.path.join(arena, &.{ root, path });
    const st = std.Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch |e|
        return .{ .failed = common.errText("read diff file metadata: {s}", .{@errorName(e)}) };
    if (st.kind != .file) return .{ .failed = "diff source is not a regular checkout file" };
    const canonical = common.canonicalize(arena, io, full) orelse return .{ .failed = "canonical diff file: the file is unavailable" };
    if (!(std.mem.startsWith(u8, canonical, canonical_root) and
        (canonical.len == canonical_root.len or canonical[canonical_root.len] == std.fs.path.sep)))
        return .{ .failed = "diff source escapes checkout" };
    if (st.size > max_diff_source_bytes) return .{ .ok = .{ .bytes = "", .truncated = true } };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, canonical, arena, .limited(max_diff_source_bytes + 1)) catch |e|
        return .{ .failed = common.errText("read diff file: {s}", .{@errorName(e)}) };
    return .{ .ok = .{ .bytes = bytes, .truncated = false } };
}

fn decode(src: Source) struct { ?[]const u8, ?[64]u8, bool } {
    if (std.mem.indexOfScalar(u8, src.bytes, 0) != null or !std.unicode.utf8ValidateSlice(src.bytes)) return .{ null, null, true };
    var hex: [64]u8 = undefined;
    _ = g.sha256Hex(&hex, &.{src.bytes});
    return .{ src.bytes, hex, false };
}

/// `read_diff_file_text_at`: the old side from `base`, the new side from the
/// committed `target` or the live working tree.
pub fn readDiffFileTextAt(arena: Allocator, io: std.Io, root: []const u8, base: []const u8, target: ?[]const u8, file: FileSummary) !Result(TextPair) {
    if (!validDiffPath(file.path)) return .{ .failed = "diff path escapes checkout" };
    const old_path = file.old_path orelse file.path;
    if (!validDiffPath(old_path)) return .{ .failed = "diff path escapes checkout" };
    const old: ?Source = if (std.mem.eql(u8, file.status, "added")) null else switch (try readGitSource(arena, io, root, base, old_path)) {
        .ok => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    const new: ?Source = if (std.mem.eql(u8, file.status, "deleted")) null else if (target) |t| switch (try readGitSource(arena, io, root, t, file.path)) {
        .ok => |s| s,
        .failed => |m| return .{ .failed = m },
    } else switch (try readWorktreeSource(arena, io, root, file.path)) {
        .ok => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    if ((old != null and old.?.truncated) or (new != null and new.?.truncated)) return .{ .ok = .{ .truncated = true } };
    const old_text, const old_hash, const old_binary = if (old) |s| decode(s) else .{ null, null, false };
    const new_text, const new_hash, const new_binary = if (new) |s| decode(s) else .{ null, null, false };
    const binary = old_binary or new_binary or file.binary;
    if (binary) return .{ .ok = .{ .binary = true } };
    return .{ .ok = .{ .old_text = old_text, .new_text = new_text, .old_hash = old_hash, .new_hash = new_hash } };
}

// ── JSON ───────────────────────────────────────────────────────────────────

/// `CheckoutDiff`.
pub fn writeCheckoutDiff(w: *std.Io.Writer, checkout_id: []const u8, device_id: []const u8, cwd: []const u8, snap: *const Snapshot, updated_at: []const u8) !void {
    try w.writeAll("{\"checkoutId\":");
    try g.writeJsonString(w, checkout_id);
    try g.field(w, true, "deviceId", device_id);
    try g.field(w, true, "cwd", cwd);
    try g.field(w, true, "patch", snap.patch);
    try w.writeAll(",\"files\":");
    try writeFiles(w, snap.files);
    try w.print(",\"additions\":{d},\"deletions\":{d},\"truncated\":{}", .{ snap.additions, snap.deletions, snap.truncated });
    try g.field(w, true, "checksum", &snap.checksum);
    try g.field(w, true, "updatedAt", updated_at);
    try w.writeByte('}');
}

fn writeStatusFiles(w: *std.Io.Writer, files: []const GitFileStatus) !void {
    try w.writeByte('[');
    for (files, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try g.writeJsonString(w, f.path);
        try w.writeAll(",\"oldPath\":");
        try g.writeOptString(w, f.old_path);
        try w.print(",\"index\":\"{s}\",\"worktree\":\"{s}\"}}", .{ @tagName(f.index), @tagName(f.worktree) });
    }
    try w.writeByte(']');
}

/// `CheckoutGitStatus`; `revision` = sha256(files JSON ‖ complete byte).
pub fn writeCheckoutGitStatus(arena: Allocator, w: *std.Io.Writer, checkout_id: []const u8, device_id: []const u8, status: GitStatus) !void {
    var files_aw: std.Io.Writer.Allocating = .init(arena);
    try writeStatusFiles(&files_aw.writer, status.files);
    var hex: [64]u8 = undefined;
    const revision = g.sha256Hex(&hex, &.{ files_aw.written(), &.{@intFromBool(status.complete)} });
    try w.writeAll("{\"checkoutId\":");
    try g.writeJsonString(w, checkout_id);
    try g.field(w, true, "deviceId", device_id);
    try g.field(w, true, "revision", revision);
    try w.print(",\"complete\":{},\"files\":", .{status.complete});
    try w.writeAll(files_aw.written());
    try w.writeByte('}');
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "rpcg_diff parses name-status, numstat and untracked hunks like diff_sync" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try parseNameStatus(a, "M\x00src/a.zig\x00R100\x00old.txt\x00new.txt\x00A\x00b c.txt\x00");
    try testing.expectEqual(@as(usize, 3), files.items.len);
    try testing.expectEqualStrings("new.txt", files.items[1].path);
    try testing.expectEqualStrings("old.txt", files.items[1].old_path.?);
    try testing.expectEqualStrings("renamed", files.items[1].status);
    try applyNumstat(a, files.items, "3\t1\tsrc/a.zig\x000\t0\t\x00old.txt\x00new.txt\x00-\t-\tb c.txt\x00");
    try testing.expectEqual(@as(u32, 3), files.items[0].additions);
    try testing.expectEqual(@as(u32, 1), files.items[0].deletions);
    try testing.expect(files.items[2].binary);
    try testing.expectEqualStrings(
        "diff --git \"a/b c.txt\" \"b/b c.txt\"\nnew file mode 100644\n--- /dev/null\n+++ \"b/b c.txt\"\n@@ -0,0 +1,2 @@\n+x\n+y\n",
        try untrackedPatch(a, "b c.txt", "x\ny\n"),
    );
    try testing.expect(hasNonUtf8StatusPath("?? ok\x00?? bad\xff\x00"));
    try testing.expect(!hasNonUtf8StatusPath("R  new\x00old\x00"));
    const batches = try pathBatches(a, &.{ "aaaa", "bbbb", "cccccccccc", "d" }, 10);
    try testing.expectEqual(@as(usize, 3), batches.len);
    try testing.expect(validDiffPath("src/a.zig"));
    try testing.expect(!validDiffPath("../x"));
    try testing.expect(!validDiffPath("/etc/passwd"));
    try testing.expect(!validDiffPath("a/./b"));
}

test "rpcg_diff status keeps both columns, literal rename paths and marks partial output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const st = try parseGitStatus(a, "R  new name\x00old name\x00 M a.txt\x00?? z\x00", false);
    try testing.expect(st.complete);
    try testing.expectEqual(@as(usize, 3), st.files.len);
    try testing.expectEqualStrings("a.txt", st.files[0].path);
    try testing.expectEqual(FileState.modified, st.files[0].worktree);
    try testing.expectEqualStrings("old name", st.files[1].old_path.?);
    try testing.expectEqual(FileState.renamed, st.files[1].index);
    try testing.expect(!(try parseGitStatus(a, " M a.txt", false)).complete);
    try testing.expect(!(try parseGitStatus(a, " M a.txt\x00", true)).complete);
    const both = try parseGitStatus(a, "D  f\x00?? f\x00", false);
    try testing.expectEqual(@as(usize, 1), both.files.len);
    try testing.expectEqual(FileState.deleted, both.files[0].index);
    try testing.expectEqual(FileState.untracked, both.files[0].worktree);
}

test "rpcg_diff captures, reads text, diffs commits and turns, and discards a temporary repository" {
    if (comptime !std.process.can_spawn) return;
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try g.TestRepo.init();
    defer t.deinit();
    try t.sh("cd repo && printf 'one\\ntwo\\n' > a.txt && mkdir -p new/deep && printf 'n1\\nn2\\n' > new/deep/n.txt && printf 'ignored\\n' > .gitignore.local");

    var snap = (try captureDiff(gpa, io, t.repo, .{})).ok;
    defer snap.deinit();
    try testing.expectEqualStrings("main", snap.branch);
    try testing.expect(snap.head_sha != null);
    try testing.expectEqual(@as(usize, 3), snap.files.len);
    try testing.expectEqualStrings("a.txt", snap.files[0].path);
    try testing.expectEqual(@as(u32, 1), snap.files[0].additions);
    try testing.expectEqualStrings(".gitignore.local", snap.files[1].path);
    try testing.expectEqualStrings("new/deep/n.txt", snap.files[2].path);
    try testing.expectEqual(@as(u32, 2), snap.files[2].additions);
    try testing.expect(std.mem.indexOf(u8, snap.patch, "+++ b/new/deep/n.txt\n@@ -0,0 +1,2 @@\n+n1\n+n2\n") != null);
    try testing.expect(!snap.truncated);
    try testing.expect(snap.git_status.?.complete);

    // The same tree gives the same checksum; one edit changes it.
    var again = (try captureDiff(gpa, io, t.repo, .{})).ok;
    defer again.deinit();
    try testing.expectEqualStrings(&snap.checksum, &again.checksum);

    var text_arena = std.heap.ArenaAllocator.init(gpa);
    defer text_arena.deinit();
    const base = try workingDiffBase(gpa, io, t.repo);
    defer gpa.free(base);
    const pair = (try readDiffFileTextAt(text_arena.allocator(), io, t.repo, base, null, snap.files[0])).ok;
    try testing.expectEqualStrings("one\n", pair.old_text.?);
    try testing.expectEqualStrings("one\ntwo\n", pair.new_text.?);
    const escaped = try readDiffFileTextAt(text_arena.allocator(), io, t.repo, base, null, .{ .path = "../outside", .status = "modified" });
    try testing.expectEqualStrings("diff path escapes checkout", escaped.failed);

    // A stale checksum is refused before anything changes.
    const stale = try discardWorkingTree(gpa, io, t.repo, "0000");
    try testing.expectEqualStrings("working tree changed since the confirmation was opened", stale.failed);
    var after = (try discardWorkingTree(gpa, io, t.repo, &snap.checksum)).ok;
    defer after.deinit();
    try testing.expectEqual(@as(usize, 0), after.files.len);
    const kept = try std.fs.path.join(gpa, &.{ t.repo, "new" });
    defer gpa.free(kept);
    try testing.expect(!common.pathExists(io, kept));

    // Commit diff and branch merge base.
    try t.sh("cd repo && git checkout -q -b topic && printf 'three\\n' >> a.txt && git commit -q -am topic");
    const sha = try captureLine(gpa, io, t.repo, &.{ "rev-parse", "HEAD" });
    defer gpa.free(sha);
    var commit = (try captureCommitDiff(gpa, io, t.repo, sha)).ok;
    defer commit.deinit();
    try testing.expectEqual(@as(usize, 1), commit.files.len);
    try testing.expectEqual(@as(u32, 1), commit.additions);
    const mb = (try mergeBase(gpa, io, t.repo, "main")).ok;
    defer gpa.free(mb);
    var branch = (try captureDiffAgainst(gpa, io, t.repo, mb, .{})).ok;
    defer branch.deinit();
    try testing.expectEqual(@as(u32, 1), branch.additions);
    try testing.expect((try mergeBase(gpa, io, t.repo, "no-such-ref")) == .failed);

    // Turn diff: a tree written through a throwaway index, real index untouched.
    const tree = (try snapshotTree(gpa, io, t.repo)).ok;
    defer gpa.free(tree);
    try t.sh("cd repo && printf 'four\\n' > turn.txt");
    var turn = (try captureTurnDiff(gpa, io, t.repo, tree)).ok;
    defer turn.deinit();
    try testing.expectEqual(@as(usize, 1), turn.files.len);
    try testing.expectEqualStrings("turn.txt", turn.files[0].path);
    const status_after = (try captureGit(gpa, io, t.repo, &.{ "status", "--porcelain" }, 4096)).ok;
    defer gpa.free(status_after.stdout);
    try testing.expectEqualStrings("?? turn.txt\n", status_after.stdout);

    // Truncation: the capture stops at its cap and says so.
    const capped = (try captureGit(gpa, io, t.repo, &.{ "log", "--format=%H%n%H%n%H" }, 10)).ok;
    defer gpa.free(capped.stdout);
    try testing.expect(capped.truncated);
    try testing.expectEqual(@as(usize, 10), capped.stdout.len);
    const bad = try captureGit(gpa, io, t.repo, &.{ "rev-parse", "--verify", "nope" }, 256);
    try testing.expect(std.mem.startsWith(u8, bad.failed, "git: "));
}

test "rpcg_diff refuses to discard before the first commit and nested repositories" {
    if (comptime !std.process.can_spawn) return;
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try g.TestRepo.init();
    defer t.deinit();
    try t.sh("git init -q -b main empty && printf x > empty/f && cd repo && git init -q -b main nested && printf x > nested/f");
    const empty = try std.fs.path.join(gpa, &.{ t.base, "empty" });
    defer gpa.free(empty);
    var e_snap = (try captureDiff(gpa, io, empty, .{})).ok;
    defer e_snap.deinit();
    try testing.expect(e_snap.head_sha == null);
    try testing.expectEqualStrings("cannot discard changes before the first commit", (try discardWorkingTree(gpa, io, empty, &e_snap.checksum)).failed);

    var snap = (try captureDiff(gpa, io, t.repo, .{})).ok;
    defer snap.deinit();
    try testing.expect(snap.files[0].binary);
    try testing.expectEqualStrings("cannot discard an untracked nested repository safely", (try discardWorkingTree(gpa, io, t.repo, &snap.checksum)).failed);
}
