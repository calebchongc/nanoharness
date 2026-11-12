//! Repository-level Git operations behind the History, ref picker and
//! checkout RPCs, ported from `crates/engine/src/repos.rs`:
//! `checkout_identity`, `current_branch`, `branches`, `refs`, `history`,
//! `search_history`, `switch_ref`, `fetch_all` and `workspace_checkout`.
//!
//! Every `git` call goes through `rpcw_common.git` (Rust's `Repos::git`: trimmed
//! stdout, `git: <stderr>` on failure, a deadline so a wedged hook never hangs
//! a request). Failure messages are `rpcw_common.errText` slices: valid until
//! the next formatted error on the same thread.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");

/// `GIT_HISTORY_MAX_LIMIT` / `GIT_HISTORY_DEFAULT_LIMIT`.
pub const history_max_limit: usize = 200;
pub const history_default_limit: usize = 100;

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: []const u8,
    };
}

// ── JSON ───────────────────────────────────────────────────────────────────

/// A JSON string the way serde_json writes one: `"`, `\` and control bytes
/// escaped, everything else raw. Invalid UTF-8 (git output is bytes) becomes
/// U+FFFD, as Rust's `String::from_utf8_lossy` makes it before serializing.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch {
            try w.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            try w.writeAll("\u{FFFD}");
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(s[i .. i + n]) catch {
            try w.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        try w.writeAll(s[i .. i + n]);
        i += n;
    }
    try w.writeByte('"');
}

pub fn writeOptString(w: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |v| try writeJsonString(w, v) else try w.writeAll("null");
}

/// `"key":"value"` with a leading comma when `comma`.
pub fn field(w: *std.Io.Writer, comma: bool, key: []const u8, value: []const u8) !void {
    if (comma) try w.writeByte(',');
    try writeJsonString(w, key);
    try w.writeByte(':');
    try writeJsonString(w, value);
}

/// `value.chars().take(max_chars)`: at most `max_chars` UTF-8 scalar values.
pub fn boundedField(value: []const u8, max_chars: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (count == max_chars) return value[0..i];
        const n = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        i = @min(value.len, i + n);
        count += 1;
    }
    return value;
}

// ── plumbing ───────────────────────────────────────────────────────────────

/// `repos::expand_home`: `~` and `~/rest` become the home folder.
pub fn expandHome(gpa: Allocator, cwd: []const u8) ![]u8 {
    if (std.mem.eql(u8, cwd, "~")) return gpa.dupe(u8, common.homeDir() orelse "");
    if (std.mem.startsWith(u8, cwd, "~/")) {
        const home = common.homeDir() orelse "";
        return std.fs.path.join(gpa, &.{ home, cwd[2..] });
    }
    return gpa.dupe(u8, cwd);
}

pub fn hexLower(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 15];
    }
    return out[0 .. bytes.len * 2];
}

pub fn sha256Hex(out: *[64]u8, parts: []const []const u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |p| h.update(p);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return hexLower(out, &digest);
}

/// `Repos::checkout_identity`: the canonical worktree root and git dir, and
/// `sha256(deviceId ‖ NUL ‖ canonical git dir)` as the checkout id.
pub const Identity = struct {
    id: []u8,
    root: []u8,
    git_dir: []u8,

    pub fn deinit(self: Identity, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.root);
        gpa.free(self.git_dir);
    }
};

pub fn checkoutIdentity(gpa: Allocator, io: std.Io, device_id: []const u8, path: []const u8) !Result(Identity) {
    const out = switch (try common.git(gpa, io, &.{ "rev-parse", "--show-toplevel", "--path-format=absolute", "--git-dir" }, path)) {
        .ok => |o| o,
        .failed => |m| return .{ .failed = m },
    };
    defer gpa.free(out);
    var root_raw: []const u8 = "";
    var git_dir_raw: []const u8 = "";
    var second: ?[]u8 = null;
    defer if (second) |s| gpa.free(s);
    var third: ?[]u8 = null;
    defer if (third) |s| gpa.free(s);
    var lines = std.mem.splitScalar(u8, out, '\n');
    const l1 = lines.next();
    const l2 = lines.next();
    const l3 = lines.next();
    if (l1 != null and l2 != null and l3 == null) {
        root_raw = l1.?;
        git_dir_raw = l2.?;
    } else {
        // A path with a `\n` in its name.
        second = switch (try common.git(gpa, io, &.{ "rev-parse", "--show-toplevel" }, path)) {
            .ok => |o| o,
            .failed => |m| return .{ .failed = m },
        };
        third = switch (try common.git(gpa, io, &.{ "rev-parse", "--path-format=absolute", "--git-dir" }, path)) {
            .ok => |o| o,
            .failed => |m| return .{ .failed = m },
        };
        root_raw = second.?;
        git_dir_raw = third.?;
    }
    const root = common.canonicalize(gpa, io, root_raw) orelse try gpa.dupe(u8, root_raw);
    errdefer gpa.free(root);
    const git_dir = common.canonicalize(gpa, io, git_dir_raw) orelse try gpa.dupe(u8, git_dir_raw);
    errdefer gpa.free(git_dir);
    var hex: [64]u8 = undefined;
    const id = try gpa.dupe(u8, sha256Hex(&hex, &.{ device_id, &.{0}, git_dir }));
    return .{ .ok = .{ .id = id, .root = root, .git_dir = git_dir } };
}

/// `Repos::current_branch`: `"HEAD"` when detached.
pub fn currentBranch(gpa: Allocator, io: std.Io, path: []const u8) !Result([]u8) {
    const out = switch (try common.git(gpa, io, &.{ "branch", "--show-current" }, path)) {
        .ok => |o| o,
        .failed => |m| return .{ .failed = m },
    };
    if (out.len == 0) {
        gpa.free(out);
        return .{ .ok = try gpa.dupe(u8, "HEAD") };
    }
    return .{ .ok = out };
}

/// Every checkout of `repo_path`, main one first (`worktree list -z`).
fn worktreePaths(gpa: Allocator, io: std.Io, repo_path: []const u8) !Result(std.ArrayList([]u8)) {
    var raw: []u8 = undefined;
    var nul_separated = true;
    switch (try common.git(gpa, io, &.{ "worktree", "list", "--porcelain", "-z" }, repo_path)) {
        .ok => |o| raw = o,
        .failed => switch (try common.git(gpa, io, &.{ "worktree", "list", "--porcelain" }, repo_path)) {
            .ok => |o| {
                raw = o;
                nul_separated = false;
            },
            .failed => |m| return .{ .failed = m },
        },
    }
    defer gpa.free(raw);
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, raw, if (nul_separated) 0 else '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) try list.append(gpa, try gpa.dupe(u8, line["worktree ".len..]));
    }
    return .{ .ok = list };
}

/// `Repos::workspace_checkout`: `candidate` canonicalized when it is the
/// repository root or one of its linked worktrees, else null.
pub fn workspaceCheckout(gpa: Allocator, io: std.Io, repo_path: []const u8, candidate: []const u8) !?[]u8 {
    var worktrees: std.ArrayList([]u8) = switch (try worktreePaths(gpa, io, repo_path)) {
        .ok => |l| l,
        .failed => .empty,
    };
    defer {
        for (worktrees.items) |p| gpa.free(p);
        worktrees.deinit(gpa);
    }
    const canonical = common.canonicalize(gpa, io, candidate) orelse return null;
    errdefer gpa.free(canonical);
    if (common.canonicalize(gpa, io, repo_path)) |r| {
        defer gpa.free(r);
        if (std.mem.eql(u8, r, canonical)) return canonical;
    }
    for (worktrees.items) |p| {
        const c = common.canonicalize(gpa, io, p) orelse continue;
        defer gpa.free(c);
        if (std.mem.eql(u8, c, canonical)) return canonical;
    }
    gpa.free(canonical);
    return null;
}

// ── branches and refs ──────────────────────────────────────────────────────

/// `Repos::branches`: locals, then remote-only names without their remote,
/// deduplicated, with the default branch first.
pub fn branches(gpa: Allocator, io: std.Io, repo_path: []const u8) !Result(std.ArrayList([]u8)) {
    const out = switch (try common.git(gpa, io, &.{ "branch", "-a", "--format=%(refname)" }, repo_path)) {
        .ok => |o| o,
        .failed => |m| return .{ .failed = m },
    };
    defer gpa.free(out);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    const Push = struct {
        fn push(a: Allocator, list: *std.ArrayList([]u8), name: []const u8) !void {
            if (name.len == 0 or std.mem.eql(u8, name, "HEAD")) return;
            for (list.items) |n| if (std.mem.eql(u8, n, name)) return;
            try list.append(a, try a.dupe(u8, name));
        }
    };
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "refs/heads/")) try Push.push(gpa, &names, line["refs/heads/".len..]);
    }
    lines.reset();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "refs/remotes/")) {
            const remote = line["refs/remotes/".len..];
            const slash = std.mem.indexOfScalar(u8, remote, '/') orelse continue;
            try Push.push(gpa, &names, remote[slash + 1 ..]);
        }
    }

    var default: ?[]u8 = null;
    defer if (default) |d| gpa.free(d);
    switch (try common.git(gpa, io, &.{ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, repo_path)) {
        .ok => |short| {
            defer gpa.free(short);
            if (std.mem.indexOfScalar(u8, short, '/')) |slash| default = try gpa.dupe(u8, short[slash + 1 ..]);
        },
        .failed => {},
    }
    if (default == null) {
        for (names.items) |n| if (std.mem.eql(u8, n, "main")) {
            default = try gpa.dupe(u8, "main");
            break;
        };
    }
    if (default == null) {
        for (names.items) |n| if (std.mem.eql(u8, n, "master")) {
            default = try gpa.dupe(u8, "master");
            break;
        };
    }
    if (default == null) {
        switch (try currentBranch(gpa, io, repo_path)) {
            .ok => |b| {
                if (std.mem.eql(u8, b, "HEAD")) gpa.free(b) else default = b;
            },
            .failed => {},
        }
    }
    if (default) |d| {
        for (names.items, 0..) |n, i| if (std.mem.eql(u8, n, d)) {
            const head = names.orderedRemove(i);
            try names.insert(gpa, 0, head);
            break;
        };
    }
    return .{ .ok = names };
}

fn freeNames(gpa: Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |n| gpa.free(n);
    names.deinit(gpa);
}

/// `ListBranches` reply: a JSON array of names.
pub fn branchesJson(gpa: Allocator, io: std.Io, repo_path: []const u8) !Result([]u8) {
    var names = switch (try branches(gpa, io, repo_path)) {
        .ok => |l| l,
        .failed => |m| return .{ .failed = m },
    };
    defer freeNames(gpa, &names);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    for (names.items, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, n);
    }
    try w.writeByte(']');
    return .{ .ok = try aw.toOwnedSlice() };
}

/// `Repos::refs` → `RepoRef[]`: each branch, whether the main folder has it
/// checked out, and the linked worktree it lives in.
pub fn refsJson(gpa: Allocator, io: std.Io, repo_path: []const u8) !Result([]u8) {
    var names = switch (try branches(gpa, io, repo_path)) {
        .ok => |l| l,
        .failed => |m| return .{ .failed = m },
    };
    defer freeNames(gpa, &names);
    const current: ?[]u8 = switch (try currentBranch(gpa, io, repo_path)) {
        .ok => |b| b,
        .failed => null,
    };
    defer if (current) |c| gpa.free(c);

    // `branch -> linked worktree path`; the first stanza is the main checkout.
    const wt_out: ?[]u8 = switch (try common.git(gpa, io, &.{ "worktree", "list", "--porcelain" }, repo_path)) {
        .ok => |o| o,
        .failed => null,
    };
    defer if (wt_out) |o| gpa.free(o);
    const Pair = struct { branch: []const u8, path: []const u8 };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);
    if (wt_out) |o| {
        var stanza: usize = 0;
        var path: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, o, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "worktree ")) {
                stanza += 1;
                path = if (stanza > 1) line["worktree ".len..] else null;
            } else if (std.mem.startsWith(u8, line, "branch refs/heads/")) {
                if (path) |p| {
                    const b = line["branch refs/heads/".len..];
                    var replaced = false;
                    for (pairs.items) |*pr| if (std.mem.eql(u8, pr.branch, b)) {
                        pr.path = p;
                        replaced = true;
                    };
                    if (!replaced) try pairs.append(gpa, .{ .branch = b, .path = p });
                    path = null;
                }
            }
        }
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    for (names.items, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, n);
        const is_current = if (current) |c| std.mem.eql(u8, c, n) else false;
        try w.print(",\"current\":{}", .{is_current});
        for (pairs.items) |pr| if (std.mem.eql(u8, pr.branch, n)) {
            try w.writeAll(",\"worktreePath\":");
            try writeJsonString(w, pr.path);
            break;
        };
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return .{ .ok = try aw.toOwnedSlice() };
}

// ── switch and fetch ───────────────────────────────────────────────────────

/// `Repos::switch_ref`: a local branch is checked out; a remote-only one gets
/// a tracking branch from `origin`; anything else lets git explain. A dirty
/// tree or a branch held by another worktree fails with git's message.
pub fn switchRef(gpa: Allocator, io: std.Io, cwd: []const u8, ref_name: []const u8) !Result([]u8) {
    const local_ref = try std.fmt.allocPrint(gpa, "refs/heads/{s}", .{ref_name});
    defer gpa.free(local_ref);
    const checkout: Result(void) = if (common.gitOk(gpa, io, &.{ "show-ref", "--verify", "--quiet", local_ref }, cwd))
        try runOk(gpa, io, &.{ "checkout", ref_name }, cwd)
    else blk: {
        const remote = try std.fmt.allocPrint(gpa, "origin/{s}", .{ref_name});
        defer gpa.free(remote);
        const remote_ref = try std.fmt.allocPrint(gpa, "refs/remotes/{s}", .{remote});
        defer gpa.free(remote_ref);
        if (common.gitOk(gpa, io, &.{ "show-ref", "--verify", "--quiet", remote_ref }, cwd)) {
            break :blk try runOk(gpa, io, &.{ "checkout", "--track", remote }, cwd);
        }
        break :blk try runOk(gpa, io, &.{ "checkout", ref_name }, cwd);
    };
    switch (checkout) {
        .failed => |m| return .{ .failed = m },
        .ok => {},
    }
    return switch (try common.git(gpa, io, &.{ "branch", "--show-current" }, cwd)) {
        .ok => |o| .{ .ok = o },
        .failed => |m| .{ .failed = m },
    };
}

fn runOk(gpa: Allocator, io: std.Io, args: []const []const u8, cwd: []const u8) !Result(void) {
    const r = try common.git(gpa, io, args, cwd);
    defer r.deinit(gpa);
    return switch (r) {
        .ok => .{ .ok = {} },
        .failed => |m| .{ .failed = m },
    };
}

/// `Repos::fetch_all`: update every remote's refs; HEAD, index and files stay.
pub fn fetchAll(gpa: Allocator, io: std.Io, repo_path: []const u8) !Result(void) {
    return runOk(gpa, io, &.{ "fetch", "--all", "--quiet" }, repo_path);
}

// ── history ────────────────────────────────────────────────────────────────

pub const RefKind = enum {
    branch,
    remote,
    tag,

    fn order(k: RefKind) u8 {
        return switch (k) {
            .branch => 0,
            .tag => 1,
            .remote => 2,
        };
    }
};

pub const HistoryRef = struct { kind: RefKind, label: []const u8 };

pub const Commit = struct {
    sha: []const u8,
    parents: []const []const u8,
    subject: []const u8,
    author_name: []const u8,
    author_email: []const u8,
    authored_at: []const u8,
    refs: []const HistoryRef,
};

const RefsBySha = std.StringHashMapUnmanaged(std.ArrayList(HistoryRef));

const history_format = "--format=%H%x00%P%x00%s%x00%an%x00%ae%x00%aI%x00";
const refs_format = "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00%(symref)%00";

/// `parse_history_refs`: public branches, remotes and tags by the commit
/// they name (annotated tags peeled), branches before tags before remotes.
pub fn parseHistoryRefs(arena: Allocator, output: []const u8) !RefsBySha {
    var map: RefsBySha = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output, 0);
    while (it.next()) |f| try fields.append(arena, f);
    var i: usize = 0;
    while (i + 6 <= fields.items.len) : (i += 6) {
        const record = fields.items[i .. i + 6];
        const full_name = std.mem.trimStart(u8, record[0], "\r\n");
        if (full_name.len == 0 or record[5].len != 0) continue;
        const kind: RefKind, const label: []const u8 = if (std.mem.startsWith(u8, full_name, "refs/heads/"))
            .{ .branch, full_name["refs/heads/".len..] }
        else if (std.mem.startsWith(u8, full_name, "refs/remotes/"))
            .{ .remote, full_name["refs/remotes/".len..] }
        else if (std.mem.startsWith(u8, full_name, "refs/tags/"))
            .{ .tag, full_name["refs/tags/".len..] }
        else
            continue;
        const target = if (std.mem.eql(u8, record[2], "commit"))
            record[1]
        else if (std.mem.eql(u8, record[2], "tag") and std.mem.eql(u8, record[4], "commit"))
            record[3]
        else
            continue;
        const gop = try map.getOrPut(arena, target);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{ .kind = kind, .label = boundedField(label, 1024) });
    }
    var vit = map.valueIterator();
    while (vit.next()) |list| {
        std.mem.sort(HistoryRef, list.items, {}, struct {
            fn lt(_: void, a: HistoryRef, b: HistoryRef) bool {
                if (a.kind.order() != b.kind.order()) return a.kind.order() < b.kind.order();
                return std.mem.order(u8, a.label, b.label) == .lt;
            }
        }.lt);
    }
    return map;
}

/// `parse_history_log`: `%H %P %s %an %ae %aI`, NUL-separated.
pub fn parseHistoryLog(arena: Allocator, output: []const u8, refs: *const RefsBySha) ![]Commit {
    var fields: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output, 0);
    while (it.next()) |f| try fields.append(arena, f);
    var out: std.ArrayList(Commit) = .empty;
    var i: usize = 0;
    while (i + 6 <= fields.items.len) : (i += 6) {
        const record = fields.items[i .. i + 6];
        const sha = std.mem.trimStart(u8, record[0], "\r\n");
        if (sha.len == 0) continue;
        var parents: std.ArrayList([]const u8) = .empty;
        var pit = std.mem.tokenizeAny(u8, record[1], " \t\r\n");
        while (pit.next()) |p| try parents.append(arena, p);
        try out.append(arena, .{
            .sha = sha,
            .parents = parents.items,
            .subject = boundedField(record[2], 4096),
            .author_name = boundedField(record[3], 512),
            .author_email = boundedField(record[4], 512),
            .authored_at = boundedField(record[5], 128),
            .refs = if (refs.get(sha)) |l| l.items else &.{},
        });
    }
    return out.items;
}

fn writeCommit(w: *std.Io.Writer, c: Commit) !void {
    try w.writeAll("{\"sha\":");
    try writeJsonString(w, c.sha);
    try w.writeAll(",\"parentShas\":[");
    for (c.parents, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, p);
    }
    try w.writeAll("]");
    try field(w, true, "subject", c.subject);
    try field(w, true, "authorName", c.author_name);
    try field(w, true, "authorEmail", c.author_email);
    try field(w, true, "authoredAt", c.authored_at);
    try w.writeAll(",\"refs\":[");
    for (c.refs, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"kind\":\"{s}\",\"label\":", .{@tagName(r.kind)});
        try writeJsonString(w, r.label);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

pub const Comparison = struct { base: []const u8, ahead: usize, behind: usize };

const Page = struct {
    commits: []const Commit,
    branch_tips: []const Commit = &.{},
    head_sha: ?[]const u8,
    next_cursor: ?usize,
    total_count: ?usize,
    head_commit_count: ?usize,
    comparison: ?Comparison = null,
};

fn writePage(gpa: Allocator, p: Page) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"commits\":[");
    for (p.commits, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try writeCommit(w, c);
    }
    try w.writeAll("],\"branchTips\":[");
    for (p.branch_tips, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try writeCommit(w, c);
    }
    try w.writeAll("],\"headSha\":");
    try writeOptString(w, p.head_sha);
    try w.writeAll(",\"nextCursor\":");
    if (p.next_cursor) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.writeAll(",\"totalCount\":");
    if (p.total_count) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.writeAll(",\"headCommitCount\":");
    if (p.head_commit_count) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    if (p.comparison) |c| {
        try w.writeAll(",\"comparison\":{\"base\":");
        try writeJsonString(w, c.base);
        try w.print(",\"ahead\":{d},\"behind\":{d}}}", .{ c.ahead, c.behind });
    }
    try w.writeByte('}');
    return aw.toOwnedSlice();
}

fn headSha(arena: Allocator, io: std.Io, repo_path: []const u8) !?[]const u8 {
    return switch (try common.git(arena, io, &.{ "rev-parse", "--verify", "HEAD^{commit}" }, repo_path)) {
        .ok => |o| if (o.len == 0) null else o,
        .failed => null,
    };
}

fn gitArena(arena: Allocator, io: std.Io, args: []const []const u8, cwd: []const u8) !Result([]const u8) {
    return switch (try common.git(arena, io, args, cwd)) {
        .ok => |o| .{ .ok = o },
        .failed => |m| .{ .failed = m },
    };
}

fn parseCount(text: ?[]const u8) ?usize {
    const t = text orelse return null;
    return std.fmt.parseInt(usize, t, 10) catch null;
}

/// `Repos::history`: one topological page plus, on the first page, every
/// branch tip, the total and HEAD commit counts and the comparison with the
/// integration branch.
pub fn historyJson(gpa: Allocator, io: std.Io, repo_path: []const u8, cursor: usize, limit_in: usize) !Result([]u8) {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const limit = std.math.clamp(limit_in, 1, history_max_limit);
    const head = try headSha(arena, io, repo_path);

    const refs_out = switch (try gitArena(arena, io, &.{ "for-each-ref", refs_format, "refs/heads", "refs/remotes", "refs/tags" }, repo_path)) {
        .ok => |o| o,
        .failed => |m| return .{ .failed = m },
    };
    const refs = try parseHistoryRefs(arena, refs_out);
    if (head == null and refs.count() == 0) {
        return .{ .ok = try writePage(gpa, .{ .commits = &.{}, .head_sha = null, .next_cursor = null, .total_count = 0, .head_commit_count = 0 }) };
    }

    var log_args: std.ArrayList([]const u8) = .empty;
    try log_args.appendSlice(arena, &.{
        "log",                                                  "--topo-order",                                                 "--no-color",   "--no-decorate", "--no-show-signature", "--no-patch",
        try std.fmt.allocPrint(arena, "--skip={d}", .{cursor}), try std.fmt.allocPrint(arena, "--max-count={d}", .{limit + 1}), history_format,
    });
    if (head != null) try log_args.append(arena, "HEAD");
    try log_args.appendSlice(arena, &.{ "--branches", "--remotes", "--tags" });
    const log = switch (try gitArena(arena, io, log_args.items, repo_path)) {
        .ok => |o| o,
        .failed => |m| return .{ .failed = m },
    };
    var commits = try parseHistoryLog(arena, log, &refs);
    const has_next = commits.len > limit;
    if (has_next) commits = commits[0..limit];

    var tips: []const Commit = &.{};
    var total: ?usize = null;
    var head_count: ?usize = null;
    var comparison: ?Comparison = null;
    if (cursor == 0) {
        var tip_args: std.ArrayList([]const u8) = .empty;
        try tip_args.appendSlice(arena, &.{ "log", "--no-walk=sorted", "--no-color", "--no-decorate", "--no-show-signature", "--no-patch", history_format });
        if (head != null) try tip_args.append(arena, "HEAD");
        try tip_args.appendSlice(arena, &.{ "--branches", "--remotes" });
        const tip_out = switch (try gitArena(arena, io, tip_args.items, repo_path)) {
            .ok => |o| o,
            .failed => |m| return .{ .failed = m },
        };
        tips = try parseHistoryLog(arena, tip_out, &refs);

        var count_args: std.ArrayList([]const u8) = .empty;
        try count_args.appendSlice(arena, &.{ "rev-list", "--count" });
        if (head != null) try count_args.append(arena, "HEAD");
        try count_args.appendSlice(arena, &.{ "--branches", "--remotes", "--tags" });
        total = switch (try gitArena(arena, io, count_args.items, repo_path)) {
            .ok => |o| parseCount(o),
            .failed => null,
        };
        if (head != null) {
            head_count = switch (try gitArena(arena, io, &.{ "rev-list", "--count", "HEAD" }, repo_path)) {
                .ok => |o| parseCount(o),
                .failed => null,
            };
            comparison = try historyComparison(arena, io, repo_path);
        }
    }
    return .{ .ok = try writePage(gpa, .{
        .commits = commits,
        .branch_tips = tips,
        .head_sha = head,
        .next_cursor = if (has_next) cursor + commits.len else null,
        .total_count = total,
        .head_commit_count = head_count,
        .comparison = comparison,
    }) };
}

/// `Repos::history_comparison`: ahead/behind against the first locally
/// available integration ref (upstream/origin HEAD, conventional mains, then
/// the tracking ref). Detached checkouts have none. Never touches the network.
fn historyComparison(arena: Allocator, io: std.Io, repo_path: []const u8) !?Comparison {
    switch (try gitArena(arena, io, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" }, repo_path)) {
        .ok => {},
        .failed => return null,
    }
    var candidates: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "upstream", "origin" }) |remote| {
        const remote_head = try std.fmt.allocPrint(arena, "refs/remotes/{s}/HEAD", .{remote});
        switch (try gitArena(arena, io, &.{ "symbolic-ref", "--quiet", "--short", remote_head }, repo_path)) {
            .ok => |b| if (b.len > 0) try candidates.append(arena, b),
            .failed => {},
        }
    }
    try candidates.appendSlice(arena, &.{ "upstream/main", "origin/main", "upstream/master", "origin/master" });
    switch (try gitArena(arena, io, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }, repo_path)) {
        .ok => |b| if (b.len > 0) try candidates.append(arena, b),
        .failed => {},
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (candidates.items) |base| {
        if ((try seen.getOrPut(arena, base)).found_existing) continue;
        const commit_ref = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{base});
        switch (try gitArena(arena, io, &.{ "rev-parse", "--verify", "--quiet", commit_ref }, repo_path)) {
            .ok => {},
            .failed => continue,
        }
        const range = try std.fmt.allocPrint(arena, "HEAD...{s}", .{base});
        const counts = switch (try gitArena(arena, io, &.{ "rev-list", "--left-right", "--count", range }, repo_path)) {
            .ok => |o| o,
            .failed => continue,
        };
        var it = std.mem.tokenizeAny(u8, counts, " \t\r\n");
        const a = it.next() orelse continue;
        const b = it.next() orelse continue;
        const ahead = std.fmt.parseInt(usize, a, 10) catch continue;
        const behind = std.fmt.parseInt(usize, b, 10) catch continue;
        return .{ .base = base, .ahead = ahead, .behind = behind };
    }
    return null;
}

/// Simple lowercase for the scripts commit subjects are written in: ASCII,
/// Latin-1, Latin Extended-A, Greek and Cyrillic capitals.
fn lowerCodepoint(c: u21) u21 {
    return switch (c) {
        'A'...'Z' => c + 32,
        0xC0...0xD6, 0xD8...0xDE => c + 0x20,
        0x100...0x137, 0x14A...0x177 => if (c % 2 == 0) c + 1 else c,
        0x139...0x148, 0x179...0x17E => if (c % 2 == 1) c + 1 else c,
        0x391...0x3A1, 0x3A3...0x3AB => c + 0x20,
        0x410...0x42F => c + 0x20,
        0x400...0x40F => c + 0x50,
        else => c,
    };
}

fn lowerUtf8(arena: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(arena, s[i]);
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            try out.appendSlice(arena, s[i..]);
            break;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            try out.append(arena, s[i]);
            i += 1;
            continue;
        };
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(lowerCodepoint(cp), &buf) catch unreachable;
        try out.appendSlice(arena, buf[0..len]);
        i += n;
    }
    return out.items;
}

/// `fuzzy_score(..).is_some()`: every whitespace-separated term of the query
/// is a case-insensitive subsequence of the candidate.
pub fn fuzzyMatches(arena: Allocator, query: []const u8, candidate: []const u8) !bool {
    const cand = try lowerUtf8(arena, candidate);
    var terms = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (terms.next()) |term_raw| {
        const term = try lowerUtf8(arena, term_raw);
        var at: usize = 0;
        var i: usize = 0;
        while (i < term.len) {
            const n = std.unicode.utf8ByteSequenceLength(term[i]) catch 1;
            const needle = term[i..@min(term.len, i + n)];
            const found = std.mem.indexOfPos(u8, cand, at, needle) orelse return false;
            at = found + needle.len;
            i += n;
        }
    }
    return true;
}

/// `git_history_matches`: a SHA prefix, or a fuzzy match on `sha subject`.
pub fn historyMatches(arena: Allocator, query_in: []const u8, c: Commit) !bool {
    const query = std.mem.trim(u8, query_in, " \t\r\n");
    if (query.len == 0) return true;
    if (query.len <= c.sha.len and std.ascii.eqlIgnoreCase(c.sha[0..query.len], query)) return true;
    const candidate = try std.fmt.allocPrint(arena, "{s} {s}", .{ c.sha, c.subject });
    return fuzzyMatches(arena, query, candidate);
}

/// `compact_history_commits`: keep the visible commits, each hidden parent
/// replaced by its nearest visible ancestors (iteratively, memoized).
pub fn compactHistory(arena: Allocator, commits: []const Commit, visible: *const std.StringHashMapUnmanaged(void)) ![]Commit {
    var by_sha: std.StringHashMapUnmanaged(usize) = .empty;
    for (commits, 0..) |c, i| try by_sha.put(arena, c.sha, i);
    var memo: std.StringHashMapUnmanaged([]const []const u8) = .empty;

    const Frame = struct {
        sha: []const u8,
        next_parent: usize = 0,
        resolved: std.ArrayList([]const u8) = .empty,
        seen: std.StringHashMapUnmanaged(void) = .empty,

        fn extend(f: *@This(), a: Allocator, parents: []const []const u8) !void {
            for (parents) |p| if (!(try f.seen.getOrPut(a, p)).found_existing) try f.resolved.append(a, p);
        }
    };

    var out: std.ArrayList(Commit) = .empty;
    for (commits) |commit| {
        if (!visible.contains(commit.sha)) continue;
        var parents: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (commit.parents) |parent| {
            const resolved: []const []const u8 = blk: {
                if (visible.contains(parent) or !by_sha.contains(parent)) break :blk &.{parent};
                if (memo.get(parent)) |m| break :blk m;
                var visiting: std.StringHashMapUnmanaged(void) = .empty;
                try visiting.put(arena, parent, {});
                var stack: std.ArrayList(Frame) = .empty;
                try stack.append(arena, .{ .sha = parent });
                while (true) {
                    const top = &stack.items[stack.items.len - 1];
                    const ps = commits[by_sha.get(top.sha).?].parents;
                    if (top.next_parent >= ps.len) {
                        const done = stack.pop().?;
                        _ = visiting.remove(done.sha);
                        try memo.put(arena, done.sha, done.resolved.items);
                        if (stack.items.len > 0) {
                            try stack.items[stack.items.len - 1].extend(arena, done.resolved.items);
                            continue;
                        }
                        break :blk done.resolved.items;
                    }
                    const p = ps[top.next_parent];
                    top.next_parent += 1;
                    if (visible.contains(p) or !by_sha.contains(p)) {
                        try top.extend(arena, &.{p});
                    } else if (memo.get(p)) |m| {
                        try top.extend(arena, m);
                    } else if (visiting.contains(p)) {
                        // Malformed (cyclic) input: resolve to nothing.
                    } else {
                        try visiting.put(arena, p, {});
                        try stack.append(arena, .{ .sha = p });
                    }
                }
            };
            for (resolved) |r| if (!(try seen.getOrPut(arena, r)).found_existing) try parents.append(arena, r);
        }
        var copy = commit;
        copy.parents = parents.items;
        try out.append(arena, copy);
    }
    return out.items;
}

/// `Repos::search_history`: fuzzy subject / SHA-prefix search over the
/// complete public history, kept in topological order and compacted.
pub fn searchHistoryJson(gpa: Allocator, io: std.Io, repo_path: []const u8, query_in: []const u8, cursor: usize, limit_in: usize) !Result([]u8) {
    const query = std.mem.trim(u8, query_in, " \t\r\n");
    if (query.len == 0) {
        return .{ .ok = try writePage(gpa, .{ .commits = &.{}, .head_sha = null, .next_cursor = null, .total_count = 0, .head_commit_count = null }) };
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const limit = std.math.clamp(limit_in, 1, history_max_limit);
    const head = try headSha(arena, io, repo_path);
    const refs_out = switch (try gitArena(arena, io, &.{ "for-each-ref", refs_format, "refs/heads", "refs/remotes", "refs/tags" }, repo_path)) {
        .ok => |o| o,
        .failed => |m| return .{ .failed = m },
    };
    const refs = try parseHistoryRefs(arena, refs_out);
    if (head == null and refs.count() == 0) {
        return .{ .ok = try writePage(gpa, .{ .commits = &.{}, .head_sha = null, .next_cursor = null, .total_count = 0, .head_commit_count = null }) };
    }
    var log_args: std.ArrayList([]const u8) = .empty;
    try log_args.appendSlice(arena, &.{ "log", "--topo-order", "--no-color", "--no-decorate", "--no-show-signature", "--no-patch", history_format });
    if (head != null) try log_args.append(arena, "HEAD");
    try log_args.appendSlice(arena, &.{ "--branches", "--remotes", "--tags" });
    const log = switch (try gitArena(arena, io, log_args.items, repo_path)) {
        .ok => |o| o,
        .failed => |m| return .{ .failed = m },
    };
    const all = try parseHistoryLog(arena, log, &refs);
    var visible: std.StringHashMapUnmanaged(void) = .empty;
    for (all) |c| if (try historyMatches(arena, query, c)) try visible.put(arena, c.sha, {});
    const matches = try compactHistory(arena, all, &visible);
    const total = matches.len;
    const start = @min(cursor, total);
    const end = @min(start +| limit, total);
    return .{ .ok = try writePage(gpa, .{
        .commits = matches[start..end],
        .head_sha = head,
        .next_cursor = if (end < total) end else null,
        .total_count = total,
        .head_commit_count = null,
    }) };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

pub const TestRepo = struct {
    tmp: testing.TmpDir,
    base: []u8,
    repo: []u8,
    env: common.TestEnv,

    pub fn init() !*TestRepo {
        const gpa = testing.allocator;
        const t = try gpa.create(TestRepo);
        errdefer gpa.destroy(t);
        t.tmp = testing.tmpDir(.{});
        t.base = try common.tmpPath(gpa, testing.io, &t.tmp);
        t.repo = try std.fs.path.join(gpa, &.{ t.base, "repo" });
        t.env = try common.TestEnv.init(gpa, t.base);
        try t.env.map.put("GIT_AUTHOR_DATE", "2026-01-02T03:04:05Z");
        try t.env.map.put("GIT_COMMITTER_DATE", "2026-01-02T03:04:05Z");
        // The temporary folder sits inside this checkout: git must never walk
        // up out of it into the real repository.
        try t.env.map.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(t.base) orelse t.base);
        t.env.install();
        try t.sh("git init -q -b main repo && cd repo && printf 'one\\n' > a.txt && git add a.txt && git commit -q -m 'first commit'");
        return t;
    }

    pub fn deinit(t: *TestRepo) void {
        const gpa = testing.allocator;
        t.env.deinit();
        gpa.free(t.base);
        gpa.free(t.repo);
        t.tmp.cleanup();
        gpa.destroy(t);
    }

    /// Run a fixed shell script in the temporary base folder, with a deadline.
    pub fn sh(t: *TestRepo, script: []const u8) !void {
        var r = try common.run(testing.allocator, testing.io, &.{ "/bin/sh", "-c", script }, t.base, 20_000);
        defer r.deinit(testing.allocator);
        if (!r.success()) {
            std.debug.print("script failed: {s}\n{s}\n", .{ script, r.stderr });
            return error.ScriptFailed;
        }
    }
};

test "rpcg_git JSON strings escape like serde and replace invalid UTF-8" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeJsonString(&aw.writer, "a\"b\\c\n\x01é\xff");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\u0001é\u{FFFD}\"", aw.written());
    try testing.expectEqualStrings("ab", boundedField("abc", 2));
    try testing.expectEqualStrings("éé", boundedField("ééé", 2));
}

test "rpcg_git fuzzy history matching folds case, including accented capitals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: Commit = .{ .sha = "a1b2c3d4", .parents = &.{}, .subject = "RÉPARER la recherche", .author_name = "", .author_email = "", .authored_at = "", .refs = &.{} };
    try testing.expect(try historyMatches(a, "réparer", c));
    try testing.expect(try historyMatches(a, "A1B2", c));
    try testing.expect(try historyMatches(a, "rpr rch", c));
    try testing.expect(!try historyMatches(a, "zzz", c));
}

test "rpcg_git history compaction contracts a long hidden gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth = 20_000;
    var commits = try a.alloc(Commit, depth);
    var idx: usize = depth;
    var k: usize = 0;
    while (idx > 0) : (k += 1) {
        idx -= 1;
        const sha = try std.fmt.allocPrint(a, "c{d:0>5}", .{idx});
        const parents: []const []const u8 = if (idx > 0) blk: {
            const p = try a.alloc([]const u8, 1);
            p[0] = try std.fmt.allocPrint(a, "c{d:0>5}", .{idx - 1});
            break :blk p;
        } else &.{};
        commits[k] = .{ .sha = sha, .parents = parents, .subject = "", .author_name = "", .author_email = "", .authored_at = "", .refs = &.{} };
    }
    var visible: std.StringHashMapUnmanaged(void) = .empty;
    try visible.put(a, "c19999", {});
    try visible.put(a, "c00000", {});
    const compact = try compactHistory(a, commits, &visible);
    try testing.expectEqual(@as(usize, 2), compact.len);
    try testing.expectEqualStrings("c19999", compact[0].sha);
    try testing.expectEqual(@as(usize, 1), compact[0].parents.len);
    try testing.expectEqualStrings("c00000", compact[0].parents[0]);
    try testing.expectEqual(@as(usize, 0), compact[1].parents.len);
}

test "rpcg_git branches, refs, history, search and switch on a temporary repository" {
    if (comptime !std.process.can_spawn) return;
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try TestRepo.init();
    defer t.deinit();
    try t.sh("cd repo && git branch feature && git tag -a v1 -m v1 && printf 'two\\n' >> a.txt && git commit -q -am 'second: fix parser' && git worktree add -q ../wt feature");

    const names = try branchesJson(gpa, io, t.repo);
    defer gpa.free(names.ok);
    try testing.expectEqualStrings("[\"main\",\"feature\"]", names.ok);

    const refs = try refsJson(gpa, io, t.repo);
    defer gpa.free(refs.ok);
    var parsed = try json.parseFromSlice(json.Value, gpa, refs.ok, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expect(rows[0].object.get("current").?.bool);
    try testing.expect(rows[0].object.get("worktreePath") == null);
    try testing.expect(!rows[1].object.get("current").?.bool);
    try testing.expect(std.mem.endsWith(u8, rows[1].object.get("worktreePath").?.string, "/wt"));

    const page = try historyJson(gpa, io, t.repo, 0, 1);
    defer gpa.free(page.ok);
    var hp = try json.parseFromSlice(json.Value, gpa, page.ok, .{});
    defer hp.deinit();
    const commits = hp.value.object.get("commits").?.array.items;
    try testing.expectEqual(@as(usize, 1), commits.len);
    try testing.expectEqualStrings("second: fix parser", commits[0].object.get("subject").?.string);
    try testing.expectEqualStrings("Synthetic", commits[0].object.get("authorName").?.string);
    try testing.expectEqual(@as(i64, 1), hp.value.object.get("nextCursor").?.integer);
    try testing.expectEqual(@as(i64, 2), hp.value.object.get("totalCount").?.integer);
    try testing.expectEqual(@as(i64, 2), hp.value.object.get("headCommitCount").?.integer);
    try testing.expectEqual(@as(usize, 2), hp.value.object.get("branchTips").?.array.items.len);
    try testing.expectEqualStrings("branch", commits[0].object.get("refs").?.array.items[0].object.get("kind").?.string);

    const second = try historyJson(gpa, io, t.repo, 1, 5);
    defer gpa.free(second.ok);
    var sp = try json.parseFromSlice(json.Value, gpa, second.ok, .{});
    defer sp.deinit();
    try testing.expect(sp.value.object.get("nextCursor").? == .null);
    try testing.expect(sp.value.object.get("totalCount").? == .null);
    const first_refs = sp.value.object.get("commits").?.array.items[0].object.get("refs").?.array.items;
    try testing.expectEqualStrings("feature", first_refs[0].object.get("label").?.string);
    try testing.expectEqualStrings("tag", first_refs[1].object.get("kind").?.string);

    const found = try searchHistoryJson(gpa, io, t.repo, "parser", 0, 10);
    defer gpa.free(found.ok);
    var fp = try json.parseFromSlice(json.Value, gpa, found.ok, .{});
    defer fp.deinit();
    try testing.expectEqual(@as(i64, 1), fp.value.object.get("totalCount").?.integer);
    try testing.expectEqual(@as(usize, 0), fp.value.object.get("commits").?.array.items[0].object.get("parentShas").?.array.items.len);
    const empty = try searchHistoryJson(gpa, io, t.repo, "  ", 0, 10);
    defer gpa.free(empty.ok);
    try testing.expect(std.mem.indexOf(u8, empty.ok, "\"totalCount\":0") != null);

    // A branch held by the linked worktree: git's own refusal.
    const held = try switchRef(gpa, io, t.repo, "feature");
    try testing.expect(held == .failed);
    try testing.expect(std.mem.startsWith(u8, held.failed, "git: "));
    try t.sh("cd repo && git branch other");
    const switched = try switchRef(gpa, io, t.repo, "other");
    defer gpa.free(switched.ok);
    try testing.expectEqualStrings("other", switched.ok);
    const unknown = try switchRef(gpa, io, t.repo, "no-such-ref");
    try testing.expect(unknown == .failed);

    const not_repo = try branchesJson(gpa, io, t.base);
    try testing.expect(not_repo == .failed);

    var ident = (try checkoutIdentity(gpa, io, "dev-1", t.repo)).ok;
    defer ident.deinit(gpa);
    try testing.expectEqual(@as(usize, 64), ident.id.len);
    try testing.expect(std.mem.endsWith(u8, ident.root, "/repo"));
    const wt_path = try std.fs.path.join(gpa, &.{ t.base, "wt" });
    defer gpa.free(wt_path);
    const auth = (try workspaceCheckout(gpa, io, t.repo, wt_path)).?;
    defer gpa.free(auth);
    try testing.expect(try workspaceCheckout(gpa, io, t.repo, t.base) == null);
}
