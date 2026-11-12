//! Git & Diff Host (`crates/engine/src/diff_sync.rs`, `repos.rs`, `source_control.rs`, `graff_worktree.rs`).
//!
//! Pure-Zig parsers and runners for `git status --porcelain=v2 --branch`,
//! unified diffs (`git diff HEAD`), GitHub remote URL extraction, and
//! optimistic working-tree checksum verification (`DiscardWorkingTree`).
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const GitRemoteRepo = struct {
    owner: []const u8,
    repo: []const u8,
};

/// Parse `git@github.com:owner/repo.git` or `https://github.com/owner/repo.git`.
pub fn parseGitRemoteUrl(raw_url: []const u8) ?GitRemoteRepo {
    const trimmed = std.mem.trim(u8, raw_url, " \t\r\n");
    const after_host = if (std.mem.indexOf(u8, trimmed, "github.com:")) |idx|
        trimmed[idx + "github.com:".len ..]
    else if (std.mem.indexOf(u8, trimmed, "github.com/")) |idx|
        trimmed[idx + "github.com/".len ..]
    else
        return null;

    const clean = if (std.mem.endsWith(u8, after_host, ".git"))
        after_host[0 .. after_host.len - 4]
    else
        after_host;

    const slash = std.mem.indexOfScalar(u8, clean, '/') orelse return null;
    const owner = clean[0..slash];
    const repo = clean[slash + 1 ..];
    if (owner.len == 0 or repo.len == 0 or std.mem.indexOfScalar(u8, repo, '/') != null) return null;
    return .{ .owner = owner, .repo = repo };
}

pub const PorcelainStatus = struct {
    branch: []u8,
    ahead: u32 = 0,
    behind: u32 = 0,
    staged_count: u32 = 0,
    unstaged_count: u32 = 0,
    untracked_count: u32 = 0,

    pub fn deinit(self: *PorcelainStatus, gpa: Allocator) void {
        gpa.free(self.branch);
    }

    pub fn isClean(self: PorcelainStatus) bool {
        return self.staged_count == 0 and self.unstaged_count == 0 and self.untracked_count == 0;
    }
};

/// Parse `git status --porcelain=v2 --branch` output.
pub fn parseGitStatusPorcelainV2(gpa: Allocator, text: []const u8) !PorcelainStatus {
    var branch: []const u8 = "HEAD";
    var ahead: u32 = 0;
    var behind: u32 = 0;
    var staged: u32 = 0;
    var unstaged: u32 = 0;
    var untracked: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            branch = std.mem.trim(u8, line["# branch.head ".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            var toks = std.mem.tokenizeScalar(u8, line["# branch.ab ".len..], ' ');
            while (toks.next()) |t| {
                if (std.mem.startsWith(u8, t, "+")) {
                    ahead = std.fmt.parseInt(u32, t[1..], 10) catch 0;
                } else if (std.mem.startsWith(u8, t, "-")) {
                    behind = std.fmt.parseInt(u32, t[1..], 10) catch 0;
                }
            }
        } else if (std.mem.startsWith(u8, line, "1 ") or std.mem.startsWith(u8, line, "2 ")) {
            if (line.len >= 4) {
                const x = line[2];
                const y = line[3];
                if (x != '.') staged += 1;
                if (y != '.') unstaged += 1;
            }
        } else if (std.mem.startsWith(u8, line, "? ")) {
            untracked += 1;
        }
    }

    return .{
        .branch = try gpa.dupe(u8, branch),
        .ahead = ahead,
        .behind = behind,
        .staged_count = staged,
        .unstaged_count = unstaged,
        .untracked_count = untracked,
    };
}

/// Compute a 16-hex-character checksum of a unified diff for `DiscardWorkingTree`.
pub fn computeDiffChecksum(diff_text: []const u8) [16]u8 {
    const h = std.hash.Wyhash.hash(0, diff_text);
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{h}) catch unreachable;
    return out;
}

/// Parse a unified diff (`git diff HEAD`) into the JSON payload returned by
/// `GetCheckoutDiff` / `WatchCheckoutDiffs`.
pub fn parseUnifiedDiffToJson(gpa: Allocator, checkout_path: []const u8, branch: []const u8, diff_text: []const u8) ![]u8 {
    const FileStat = struct {
        path: []const u8,
        additions: u32 = 0,
        deletions: u32 = 0,
    };
    var files: std.ArrayList(FileStat) = .empty;
    defer files.deinit(gpa);

    var lines = std.mem.splitScalar(u8, diff_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            const b_marker = " b/";
            const path = if (std.mem.lastIndexOf(u8, line, b_marker)) |idx|
                line[idx + b_marker.len ..]
            else
                line["diff --git ".len..];
            try files.append(gpa, .{ .path = path });
        } else if (files.items.len > 0) {
            if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
                files.items[files.items.len - 1].additions += 1;
            } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
                files.items[files.items.len - 1].deletions += 1;
            }
        }
    }

    const checksum = computeDiffChecksum(diff_text);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"checkoutPath\":");
    try json.Stringify.encodeJsonString(checkout_path, .{}, w);
    try w.writeAll(",\"branch\":");
    try json.Stringify.encodeJsonString(branch, .{}, w);
    try w.writeAll(",\"checksum\":");
    try json.Stringify.encodeJsonString(&checksum, .{}, w);
    try w.writeAll(",\"files\":[");
    for (files.items, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try json.Stringify.encodeJsonString(f.path, .{}, w);
        try w.print(",\"additions\":{d},\"deletions\":{d}}}", .{ f.additions, f.deletions });
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

/// Every production git call's deadline. The Rust engine's `Repos::git`
/// has none; a wedged hook or credential helper must not hang a request.
pub const git_timeout_ms: u32 = 30_000;

pub const GitOutput = union(enum) {
    /// stdout (owned).
    ok: []u8,
    /// The Rust engine's error text (`repos.rs` `Repos::git`), owned.
    err: []u8,

    pub fn deinit(self: GitOutput, gpa: Allocator) void {
        switch (self) {
            inline else => |b| gpa.free(b),
        }
    }
};

/// Run `git <args>` in `cwd`, killed at `timeout_ms`.
pub fn runGit(gpa: Allocator, io: std.Io, cwd: []const u8, args: []const []const u8, timeout_ms: u32) !GitOutput {
    const verb = if (args.len > 0) args[0] else "?";
    if (comptime !std.process.can_spawn) return .{ .err = try gpa.dupe(u8, "git spawn failed: this platform cannot start processes") };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);
    const deadline: std.Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake }) };
    const res = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = deadline,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return .{ .err = try std.fmt.allocPrint(gpa, "git {s} timed out after {d} s", .{ verb, timeout_ms / 1000 }) },
        else => return .{ .err = try std.fmt.allocPrint(gpa, "git spawn failed: {t}", .{e}) },
    };
    defer gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ok) return .{ .ok = res.stdout };
    gpa.free(res.stdout);
    const message = std.mem.trim(u8, res.stderr, " \t\r\n");
    if (message.len > 0) return .{ .err = try std.fmt.allocPrint(gpa, "git: {s}", .{message}) };
    return .{ .err = switch (res.term) {
        .exited => |code| try std.fmt.allocPrint(gpa, "git {s} failed (exit status: {d})", .{ verb, code }),
        .signal => |sig| try std.fmt.allocPrint(gpa, "git {s} failed (signal: {d})", .{ verb, @backingInt(sig) }),
        else => try std.fmt.allocPrint(gpa, "git {s} failed", .{verb}),
    } };
}

/// A git-backed reply: the JSON, or the error to answer with (both owned).
pub const GitJson = GitOutput;

/// Run `git status --porcelain=v2 --branch` in `checkout_path` when `maybe_io` is set.
/// A folder git can't read (or no Io) reports a clean `main`, as before.
pub fn runGitStatusJson(gpa: Allocator, maybe_io: ?std.Io, checkout_path: []const u8) ![]u8 {
    if (maybe_io) |io| {
        const res = try runGit(gpa, io, checkout_path, &.{ "status", "--porcelain=v2", "--branch" }, git_timeout_ms);
        defer res.deinit(gpa);
        if (res == .ok and res.ok.len > 0) {
            var st = try parseGitStatusPorcelainV2(gpa, res.ok);
            defer st.deinit(gpa);
            return std.fmt.allocPrint(
                gpa,
                "{{\"branch\":{f},\"dirty\":{},\"ahead\":{d},\"behind\":{d}}}",
                .{ json.fmt(st.branch, .{}), !st.isClean(), st.ahead, st.behind },
            );
        }
    }
    return gpa.dupe(u8, "{\"branch\":\"main\",\"dirty\":false,\"ahead\":0,\"behind\":0}");
}

/// Run `git diff HEAD` in `cwd` when `maybe_io` is set; git's error when it fails.
pub fn runGitDiffJson(gpa: Allocator, maybe_io: ?std.Io, cwd: []const u8) !GitJson {
    if (maybe_io) |io| {
        const res = try runGit(gpa, io, cwd, &.{ "diff", "HEAD" }, git_timeout_ms);
        switch (res) {
            .err => return res,
            .ok => |diff_text| {
                defer gpa.free(diff_text);
                return .{ .ok = try parseUnifiedDiffToJson(gpa, cwd, "HEAD", diff_text) };
            },
        }
    }
    return .{ .ok = try parseUnifiedDiffToJson(gpa, cwd, "HEAD", "") };
}

/// `ListBranches`: the local branches (`git for-each-ref`), or git's error.
pub fn listBranchesJson(gpa: Allocator, maybe_io: ?std.Io, cwd: []const u8) !GitJson {
    const io = maybe_io orelse return .{ .err = try gpa.dupe(u8, "git spawn failed: the engine has no I/O") };
    const res = try runGit(gpa, io, cwd, &.{ "for-each-ref", "--format=%(HEAD)|%(refname:short)", "refs/heads/" }, git_timeout_ms);
    const out = switch (res) {
        .err => return res,
        .ok => |o| o,
    };
    defer gpa.free(out);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 3) continue;
        const sep = std.mem.indexOfScalar(u8, line, '|') orelse continue;
        const is_cur = std.mem.eql(u8, line[0..sep], "*");
        const bname = line[sep + 1 ..];
        if (bname.len == 0) continue;
        if (count > 0) try w.writeByte(',');
        try w.print("{{\"name\":{f},\"current\":{}}}", .{ json.fmt(bname, .{}), is_cur });
        count += 1;
    }
    try w.writeByte(']');
    return .{ .ok = try aw.toOwnedSlice() };
}

/// `ListRefs`: branches and tags (`git for-each-ref`), or git's error.
pub fn listRefsJson(gpa: Allocator, maybe_io: ?std.Io, cwd: []const u8) !GitJson {
    const io = maybe_io orelse return .{ .err = try gpa.dupe(u8, "git spawn failed: the engine has no I/O") };
    const res = try runGit(gpa, io, cwd, &.{ "for-each-ref", "--format=%(refname:short)", "refs/heads/", "refs/tags/" }, git_timeout_ms);
    const out = switch (res) {
        .err => return res,
        .ok => |o| o,
    };
    defer gpa.free(out);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const rname = std.mem.trim(u8, raw, " \t\r");
        if (rname.len == 0) continue;
        if (count > 0) try w.writeByte(',');
        try w.print("{{\"name\":{f}}}", .{json.fmt(rname, .{})});
        count += 1;
        if (count >= 128) break;
    }
    try w.writeByte(']');
    return .{ .ok = try aw.toOwnedSlice() };
}

test "git_host parses porcelain v2 status, unified diffs, GitHub remotes, and runs real git status" {
    const gpa = testing.allocator;

    const r1 = parseGitRemoteUrl("git@github.com:justrach/harness.git").?;
    try testing.expectEqualStrings("justrach", r1.owner);
    try testing.expectEqualStrings("harness", r1.repo);

    const r2 = parseGitRemoteUrl("https://github.com/justrach/http-zig").?;
    try testing.expectEqualStrings("justrach", r2.owner);
    try testing.expectEqualStrings("http-zig", r2.repo);

    var st = try parseGitStatusPorcelainV2(
        gpa,
        "# branch.oid c9517005\n# branch.head experimental-zig-branch\n# branch.ab +3 -1\n1 M. N... 100644 100644 100644 abc def src/a.zig\n1 .M N... 100644 100644 100644 abc def src/b.zig\n? src/new.zig\n",
    );
    defer st.deinit(gpa);
    try testing.expectEqualStrings("experimental-zig-branch", st.branch);
    try testing.expectEqual(@as(u32, 3), st.ahead);
    try testing.expectEqual(@as(u32, 1), st.behind);
    try testing.expectEqual(@as(u32, 1), st.staged_count);
    try testing.expectEqual(@as(u32, 1), st.unstaged_count);
    try testing.expectEqual(@as(u32, 1), st.untracked_count);

    const diff_json = try parseUnifiedDiffToJson(
        gpa,
        "/repo",
        "experimental-zig-branch",
        "diff --git a/src/a.zig b/src/a.zig\n--- a/src/a.zig\n+++ b/src/a.zig\n@@ -1,2 +1,3 @@\n-old\n+new1\n+new2\n",
    );
    defer gpa.free(diff_json);
    var parsed = try json.parseFromSlice(json.Value, gpa, diff_json, .{});
    defer parsed.deinit();
    const files = parsed.value.object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("src/a.zig", files[0].object.get("path").?.string);
    try testing.expectEqual(@as(i64, 2), files[0].object.get("additions").?.integer);
    try testing.expectEqual(@as(i64, 1), files[0].object.get("deletions").?.integer);

    // Real git status, from a fresh repository on a made-up branch so the
    // result never depends on the branch this checkout is on. Every git
    // process here has a deadline: a hang fails the test.
    if (comptime !std.process.can_spawn) return;
    var repo = testing.tmpDir(.{});
    defer repo.cleanup();
    const repo_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{repo.sub_path});
    defer gpa.free(repo_path);
    const branch = "synthetic-status-branch";
    const deadline: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } };
    const init = try std.process.run(gpa, testing.io, .{ .argv = &.{ "git", "init", "-q", "-b", branch, repo_path }, .timeout = deadline });
    defer gpa.free(init.stdout);
    defer gpa.free(init.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, init.term);
    const live = try std.process.run(gpa, testing.io, .{ .argv = &.{ "git", "status", "--porcelain=v2", "--branch" }, .cwd = .{ .path = repo_path }, .timeout = deadline });
    defer gpa.free(live.stdout);
    defer gpa.free(live.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, live.term);
    var live_st = try parseGitStatusPorcelainV2(gpa, live.stdout);
    defer live_st.deinit(gpa);
    try testing.expectEqualStrings(branch, live_st.branch);
    try testing.expect(live_st.isClean());
}

/// A fresh folder outside any repository (not under this checkout, where
/// git would find the checkout's own `.git`).
fn outsideTmp(gpa: Allocator, io: std.Io) ![]u8 {
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const dir = try std.fmt.allocPrint(gpa, "/tmp/harness-git-host-{x}", .{rnd});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "git_host: a folder git can't read answers git's own error, never a made-up branch list" {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const dir = try outsideTmp(gpa, io);
    defer gpa.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const branches = try listBranchesJson(gpa, io, dir);
    defer branches.deinit(gpa);
    try testing.expect(branches == .err);
    try testing.expect(std.mem.startsWith(u8, branches.err, "git: fatal: not a git repository"));
    const refs = try listRefsJson(gpa, io, dir);
    defer refs.deinit(gpa);
    try testing.expect(refs == .err);
    const diff = try runGitDiffJson(gpa, io, dir);
    defer diff.deinit(gpa);
    try testing.expect(diff == .err);
    const no_io = try listBranchesJson(gpa, null, dir);
    defer no_io.deinit(gpa);
    try testing.expect(no_io == .err);

    // Through the engine (rpcg_rpc.zig): RpcError::Failed with git's text.
    const engine_host = @import("engine_host.zig");
    var host = try engine_host.EngineHost.init(gpa, "dev-git", "Synthetic");
    defer host.deinit();
    host.io = io;
    const params_text = try std.fmt.allocPrint(gpa, "{{\"repoPath\":{f}}}", .{json.fmt(dir, .{})});
    defer gpa.free(params_text);
    const params = try json.parseFromSlice(json.Value, gpa, params_text, .{});
    defer params.deinit();
    const out = try host.handle("ListBranches", params.value);
    try testing.expect(out == .err and out.err == .exec_error);
    try testing.expect(std.mem.indexOf(u8, out.err.exec_error, "not a git repository") != null);
}

test "git_host: branches and refs of a real repository" {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const dir = try outsideTmp(gpa, io);
    defer gpa.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    for ([_][]const []const u8{
        &.{ "init", "-q", "-b", "synthetic-main" },
        &.{ "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "--allow-empty", "-m", "first" },
        &.{ "branch", "synthetic-feature" },
        &.{ "tag", "v0.0.1-synthetic" },
    }) |args| {
        const r = try runGit(gpa, io, dir, args, git_timeout_ms);
        defer r.deinit(gpa);
        if (r == .err) std.debug.print("{s}\n", .{r.err});
        try testing.expect(r == .ok);
    }
    const branches = try listBranchesJson(gpa, io, dir);
    defer branches.deinit(gpa);
    try testing.expectEqualStrings("[{\"name\":\"synthetic-feature\",\"current\":false},{\"name\":\"synthetic-main\",\"current\":true}]", branches.ok);
    const refs = try listRefsJson(gpa, io, dir);
    defer refs.deinit(gpa);
    try testing.expectEqualStrings("[{\"name\":\"synthetic-feature\"},{\"name\":\"synthetic-main\"},{\"name\":\"v0.0.1-synthetic\"}]", refs.ok);
}

test "git_host: a git command that hangs is killed at its deadline" {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const dir = try outsideTmp(gpa, io);
    defer gpa.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const started = std.Io.Clock.awake.now(io);
    const r = try runGit(gpa, io, dir, &.{ "-c", "alias.synthetic-wait=!sleep 4", "synthetic-wait" }, 1_000);
    defer r.deinit(gpa);
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(r == .err);
    try testing.expectEqualStrings("git -c timed out after 1 s", r.err);
    try testing.expect(elapsed_ms < 10_000);
}
