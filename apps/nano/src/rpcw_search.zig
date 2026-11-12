//! `SearchWorkspaceFiles`, ported from `crates/engine/src/workspace_files.rs`
//! (`resolve_target`, `search_workspace_blocking`, `workspace_search_score`,
//! `compare_workspace_search_matches`, `validate_workspace_search_query`).
//!
//! What it does that the old Zig search did not:
//! - resolves the target as Rust does: exactly one of `chatId`/`spaceId`, the
//!   chat's own folder only when it is the space's repository or one of its
//!   worktrees, `checkoutPath` only for a space, each refusal with Rust's text;
//! - walks like the `ignore` crate's `WalkBuilder` with hidden files shown:
//!   `.gitignore` (inside a git repository, the folder's and its parents' up
//!   to the repository), `.ignore` (any folder, parents too),
//!   `.git/info/exclude`, the global excludes file, last matching pattern
//!   wins, `!` re-includes, `dir/` matches folders, `/` anchors, `**` spans
//!   folders; `includeIgnored` turns every filter off; symlinks are listed,
//!   never followed; `.git` is never listed;
//! - lists folders and symlinks as well as files, with Rust's `kind`, `name`
//!   and `score` (exact name, name prefix, name substring, path substring,
//!   then in-order characters), sorted by score then path;
//! - `limit` (default and maximum 200, 0 = none), a 256-character query cap,
//!   an empty query refused, the six-second deadline, and the editor's
//!   `.harness-save-*.tmp` files hidden.
//! Case folding is ASCII where Rust folds Unicode.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const actions = @import("rpcw_actions.zig");

const RpcOutcome = common.RpcOutcome;
const EngineHost = engine_host.EngineHost;

pub const max_query_chars: usize = 256;
pub const max_results: usize = 200;
pub const rpc_timeout_ms: i64 = 6_000;

// ── gitignore ──────────────────────────────────────────────────────────────

const Pattern = struct {
    glob: []const u8,
    negate: bool,
    dir_only: bool,
    anchored: bool,
};

/// One ignore file: its patterns and the folder they are relative to.
const IgnoreFile = struct {
    dir: []const u8,
    patterns: []const Pattern,
};

/// Parse gitignore lines (comments, blanks, `\` escapes, trailing spaces).
pub fn parsePatterns(a: Allocator, text: []const u8) ![]const Pattern {
    var out: std.ArrayList(Pattern) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Trailing spaces go unless escaped.
        while (line.len > 0 and line[line.len - 1] == ' ' and !(line.len >= 2 and line[line.len - 2] == '\\')) line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        var p: Pattern = .{ .glob = "", .negate = false, .dir_only = false, .anchored = false };
        if (line[0] == '!') {
            p.negate = true;
            line = line[1..];
        } else if (line.len >= 2 and line[0] == '\\' and (line[1] == '!' or line[1] == '#')) {
            line = line[1..];
        }
        if (line.len > 1 and line[line.len - 1] == '/') {
            p.dir_only = true;
            line = line[0 .. line.len - 1];
        }
        if (line.len > 0 and line[0] == '/') {
            p.anchored = true;
            line = line[1..];
        } else if (std.mem.indexOfScalar(u8, line, '/') != null) {
            p.anchored = true;
        }
        if (line.len == 0) continue;
        p.glob = try a.dupe(u8, line);
        try out.append(a, p);
    }
    return out.toOwnedSlice(a);
}

/// Glob match with gitignore's rules: `*` and `?` stop at `/`, `**/`, `/**`
/// and `/**/` span folders, `[...]` classes (with `!`/`^`), `\` escapes.
pub fn globMatch(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (std.mem.startsWith(u8, p, "**")) {
        const rest = p[2..];
        if (rest.len == 0) return true;
        if (rest[0] == '/') {
            if (globMatch(rest[1..], s)) return true;
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                if (s[i] == '/' and globMatch(rest[1..], s[i + 1 ..])) return true;
            }
            return false;
        }
        // `**` not at a folder boundary is a `*`.
        return globMatch(p[1..], s);
    }
    switch (p[0]) {
        '*' => {
            var i: usize = 0;
            while (true) : (i += 1) {
                if (globMatch(p[1..], s[i..])) return true;
                if (i >= s.len or s[i] == '/') return false;
            }
        },
        '?' => return s.len > 0 and s[0] != '/' and globMatch(p[1..], s[1..]),
        '[' => {
            if (s.len == 0 or s[0] == '/') return false;
            var i: usize = 1;
            var negate = false;
            if (i < p.len and (p[i] == '!' or p[i] == '^')) {
                negate = true;
                i += 1;
            }
            var matched = false;
            var first = true;
            while (i < p.len and (first or p[i] != ']')) : (first = false) {
                var lo = p[i];
                if (lo == '\\' and i + 1 < p.len) {
                    i += 1;
                    lo = p[i];
                }
                var hi = lo;
                if (i + 2 < p.len and p[i + 1] == '-' and p[i + 2] != ']') {
                    hi = p[i + 2];
                    i += 2;
                }
                if (s[0] >= lo and s[0] <= hi) matched = true;
                i += 1;
            }
            if (i >= p.len) return false; // unterminated: no match
            if (matched == negate) return false;
            return globMatch(p[i + 1 ..], s[1..]);
        },
        '\\' => {
            if (p.len < 2) return false;
            return s.len > 0 and s[0] == p[1] and globMatch(p[2..], s[1..]);
        },
        else => return s.len > 0 and s[0] == p[0] and globMatch(p[1..], s[1..]),
    }
}

const Verdict = enum { none, ignore, include };

/// The last pattern of `file` that matches `abs` (a path under `file.dir`).
fn fileVerdict(file: IgnoreFile, abs: []const u8, is_dir: bool) Verdict {
    const dir = std.mem.trimEnd(u8, file.dir, "/");
    if (!std.mem.startsWith(u8, abs, dir) or abs.len <= dir.len + 1 or abs[dir.len] != '/') return .none;
    const rel = abs[dir.len + 1 ..];
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |k| rel[k + 1 ..] else rel;
    var v: Verdict = .none;
    for (file.patterns) |p| {
        if (p.dir_only and !is_dir) continue;
        const hit = if (p.anchored) globMatch(p.glob, rel) else globMatch(p.glob, base);
        if (hit) v = if (p.negate) .include else .ignore;
    }
    return v;
}

/// The filters in force in one folder, deepest first within each kind.
const Filters = struct {
    dot_ignore: []const IgnoreFile,
    git_ignore: []const IgnoreFile,
    exclude: ?IgnoreFile,
    global: ?IgnoreFile,

    /// The ignore crate's order: `.ignore`, then `.gitignore`, then the
    /// repository's exclude file, then the global one; within each the
    /// deepest file that matches decides.
    fn ignored(self: Filters, abs: []const u8, is_dir: bool) bool {
        inline for (.{ "dot_ignore", "git_ignore" }) |field| {
            const files = @field(self, field);
            var i = files.len;
            while (i > 0) {
                i -= 1;
                switch (fileVerdict(files[i], abs, is_dir)) {
                    .none => {},
                    .ignore => return true,
                    .include => return false,
                }
            }
        }
        inline for (.{ "exclude", "global" }) |field| {
            if (@field(self, field)) |f| switch (fileVerdict(f, abs, is_dir)) {
                .none => {},
                .ignore => return true,
                .include => return false,
            };
        }
        return false;
    }
};

fn readIgnoreFile(a: Allocator, io: std.Io, dir: []const u8, name: []const u8) !?IgnoreFile {
    const path = try std.fs.path.join(a, &.{ dir, name });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch return null;
    const patterns = try parsePatterns(a, text);
    if (patterns.len == 0) return null;
    return .{ .dir = dir, .patterns = patterns };
}

/// The repository folder containing `start` (a `.git` folder or file), if any.
fn findRepo(io: std.Io, start: []const u8) ?[]const u8 {
    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const git = std.fmt.bufPrint(&buf, "{s}/.git", .{std.mem.trimEnd(u8, d, "/")}) catch return null;
        if (common.pathExists(io, git)) return d;
    }
    return null;
}

/// `.git/info/exclude`, following a worktree's `gitdir:` to its common dir.
fn excludeFile(a: Allocator, io: std.Io, repo: []const u8) !?IgnoreFile {
    const dot_git = try std.fs.path.join(a, &.{ repo, ".git" });
    var git_dir: []const u8 = dot_git;
    if (common.isFile(io, dot_git)) {
        const text = std.Io.Dir.cwd().readFileAlloc(io, dot_git, a, .limited(4096)) catch return null;
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (!std.mem.startsWith(u8, t, "gitdir:")) return null;
        const target = std.mem.trim(u8, t["gitdir:".len..], " \t");
        git_dir = if (std.fs.path.isAbsolute(target)) target else try std.fs.path.join(a, &.{ repo, target });
        const commondir_path = try std.fs.path.join(a, &.{ git_dir, "commondir" });
        if (std.Io.Dir.cwd().readFileAlloc(io, commondir_path, a, .limited(4096))) |cd| {
            const c = std.mem.trim(u8, cd, " \t\r\n");
            git_dir = if (std.fs.path.isAbsolute(c)) c else try std.fs.path.join(a, &.{ git_dir, c });
        } else |_| {}
    }
    const info = try std.fs.path.join(a, &.{ git_dir, "info" });
    var f = (try readIgnoreFile(a, io, info, "exclude")) orelse return null;
    f.dir = repo;
    return f;
}

/// The global excludes file: `core.excludesFile` from `~/.gitconfig`, else
/// `$XDG_CONFIG_HOME/git/ignore` (or `~/.config/git/ignore`).
fn globalFile(a: Allocator, io: std.Io, repo: []const u8) !?IgnoreFile {
    const home = common.homeDir() orelse return null;
    var path: ?[]const u8 = null;
    const cfg_path = try std.fs.path.join(a, &.{ home, ".gitconfig" });
    if (std.Io.Dir.cwd().readFileAlloc(io, cfg_path, a, .limited(1 << 20))) |cfg| {
        var in_core = false;
        var lines = std.mem.splitScalar(u8, cfg, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0 and line[0] == '[') {
                in_core = std.ascii.startsWithIgnoreCase(line, "[core");
                continue;
            }
            if (!in_core) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..eq], " \t"), "excludesfile")) continue;
            var v = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
            if (std.mem.startsWith(u8, v, "~/")) v = try std.fs.path.join(a, &.{ home, v[2..] });
            path = v;
        }
    } else |_| {}
    const file = path orelse blk: {
        const xdg = common.getenvNonEmpty("XDG_CONFIG_HOME") orelse try std.fs.path.join(a, &.{ home, ".config" });
        break :blk try std.fs.path.join(a, &.{ xdg, "git", "ignore" });
    };
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(4 << 20)) catch return null;
    const patterns = try parsePatterns(a, text);
    if (patterns.len == 0) return null;
    return .{ .dir = repo, .patterns = patterns };
}

// ── scoring ────────────────────────────────────────────────────────────────

pub const Kind = enum { file, directory, symlink };

pub const Match = struct {
    path: []const u8,
    name: []const u8,
    kind: Kind,
    score: i64,
};

/// `workspace_search_score` (`query` already lower-cased).
pub fn score(a: Allocator, name_raw: []const u8, path_raw: []const u8, query: []const u8) !?i64 {
    if (query.len == 0) return 0;
    const name = try std.ascii.allocLowerString(a, name_raw);
    const path = try std.ascii.allocLowerString(a, path_raw);
    const nlen: i64 = @intCast(name.len);
    const plen: i64 = @intCast(path.len);
    if (std.mem.eql(u8, name, query)) return 10_000;
    if (std.mem.startsWith(u8, name, query)) return 8_000 - nlen;
    if (std.mem.indexOf(u8, name, query)) |i| return 6_000 - @as(i64, @intCast(i)) - nlen;
    if (std.mem.indexOf(u8, path, query)) |i| return 4_000 - @as(i64, @intCast(i)) - plen;
    var qi: usize = 0;
    var gaps: i64 = 0;
    for (path) |c| {
        if (c == query[qi]) {
            qi += 1;
            if (qi == query.len) return 2_000 - gaps - plen;
        } else gaps += 1;
    }
    return null;
}

/// `compare_workspace_search_matches`: score down, then path (folded, then exact).
fn before(_: void, l: Match, r: Match) bool {
    if (l.score != r.score) return l.score > r.score;
    const n = @min(l.path.len, r.path.len);
    for (l.path[0..n], r.path[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    if (l.path.len != r.path.len) return l.path.len < r.path.len;
    return std.mem.order(u8, l.path, r.path) == .lt;
}

// ── the walk ───────────────────────────────────────────────────────────────

pub const SearchError = error{ TimedOut, Unreadable } || Allocator.Error;

const Walk = struct {
    a: Allocator,
    io: std.Io,
    root: []const u8,
    query: []const u8,
    limit: usize,
    filtered: bool,
    git_repo: bool,
    deadline_ms: i64,
    matches: std.ArrayList(Match) = .empty,
    exclude: ?IgnoreFile = null,
    global: ?IgnoreFile = null,

    fn nowMs(self: *Walk) i64 {
        return @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
    }

    fn visit(self: *Walk, dir_abs: []const u8, dot_ignore: *std.ArrayList(IgnoreFile), git_ignore: *std.ArrayList(IgnoreFile)) SearchError!void {
        if (self.nowMs() > self.deadline_ms) return error.TimedOut;
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_abs, .{ .iterate = true }) catch {
            if (std.mem.eql(u8, dir_abs, self.root) and self.matches.items.len == 0) return error.Unreadable;
            return;
        };
        defer dir.close(self.io);
        const di_len = dot_ignore.items.len;
        const gi_len = git_ignore.items.len;
        defer dot_ignore.shrinkRetainingCapacity(di_len);
        defer git_ignore.shrinkRetainingCapacity(gi_len);
        if (self.filtered) {
            if (try readIgnoreFile(self.a, self.io, dir_abs, ".ignore")) |f| try dot_ignore.append(self.a, f);
            if (self.git_repo) if (try readIgnoreFile(self.a, self.io, dir_abs, ".gitignore")) |f| try git_ignore.append(self.a, f);
        }
        const filters: Filters = .{ .dot_ignore = dot_ignore.items, .git_ignore = git_ignore.items, .exclude = self.exclude, .global = self.global };
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, ".git")) continue;
            const kind: Kind = switch (entry.kind) {
                .sym_link => .symlink,
                .directory => .directory,
                .file => .file,
                else => continue,
            };
            const abs = try std.fs.path.join(self.a, &.{ dir_abs, entry.name });
            if (self.filtered and filters.ignored(abs, kind == .directory)) continue;
            const rel = abs[self.root.len + 1 ..];
            const is_temp = std.mem.startsWith(u8, entry.name, ".harness-save-") and std.mem.endsWith(u8, entry.name, ".tmp");
            if (!is_temp) {
                if (try score(self.a, entry.name, rel, self.query)) |sc| {
                    try self.matches.append(self.a, .{ .path = rel, .name = try self.a.dupe(u8, entry.name), .kind = kind, .score = sc });
                    if (self.matches.items.len > self.limit) {
                        std.mem.sort(Match, self.matches.items, {}, before);
                        self.matches.shrinkRetainingCapacity(self.limit);
                    }
                }
            }
            if (kind == .directory) try self.visit(abs, dot_ignore, git_ignore);
        }
    }
};

/// `search_workspace_blocking` over the resolved `root` (absolute, canonical).
pub fn searchRoot(a: Allocator, io: std.Io, root: []const u8, query: []const u8, include_ignored: bool, limit: usize, timeout_ms: i64) SearchError![]Match {
    if (limit == 0) return &.{};
    const q = try std.ascii.allocLowerString(a, query);
    var w: Walk = .{
        .a = a,
        .io = io,
        .root = std.mem.trimEnd(u8, root, "/"),
        .query = q,
        .limit = limit,
        .filtered = !include_ignored,
        .git_repo = false,
        .deadline_ms = 0,
    };
    w.deadline_ms = w.nowMs() + timeout_ms;
    var dot_ignore: std.ArrayList(IgnoreFile) = .empty;
    var git_ignore: std.ArrayList(IgnoreFile) = .empty;
    if (w.filtered) {
        const repo = findRepo(io, w.root);
        w.git_repo = repo != null;
        // Parents' ignore files, outermost first (`parents(true)`).
        var chain: std.ArrayList([]const u8) = .empty;
        var d: ?[]const u8 = std.fs.path.dirname(w.root);
        while (d) |dd| : (d = std.fs.path.dirname(dd)) try chain.append(a, dd);
        std.mem.reverse([]const u8, chain.items);
        for (chain.items) |pd| {
            if (try readIgnoreFile(a, io, pd, ".ignore")) |f| try dot_ignore.append(a, f);
            if (repo) |r| if (pd.len >= r.len and std.mem.startsWith(u8, pd, r)) {
                if (try readIgnoreFile(a, io, pd, ".gitignore")) |f| try git_ignore.append(a, f);
            };
        }
        if (repo) |r| {
            w.exclude = try excludeFile(a, io, r);
            w.global = try globalFile(a, io, r);
        }
    }
    try w.visit(w.root, &dot_ignore, &git_ignore);
    std.mem.sort(Match, w.matches.items, {}, before);
    return w.matches.items;
}

// ── target resolution ──────────────────────────────────────────────────────

const Resolved = union(enum) { ok: []const u8, bad: []const u8, failed: []const u8 };

/// `WorkspaceFiles::resolve_target` → the checkout root to search.
fn resolveTarget(a: Allocator, io: std.Io, host: *const EngineHost, o: json.ObjectMap) !Resolved {
    const chat_id = common.str(o, "chatId");
    const space_id = common.str(o, "spaceId");
    const checkout_path = common.str(o, "checkoutPath");
    if ((chat_id == null) == (space_id == null)) return .{ .bad = "workspace target needs exactly one of chatId or spaceId" };
    var root: []const u8 = undefined;
    if (chat_id) |cid| {
        if (checkout_path != null) return .{ .bad = "checkoutPath applies only to a space target" };
        const chat = for (host.chats.items) |*c| {
            if (std.mem.eql(u8, c.id, cid)) break c;
        } else return .{ .failed = "chat not found" };
        if (!std.mem.eql(u8, chat.device_id, host.device_id)) return .{ .failed = "chat belongs to another device" };
        const cwd = chat.cwd orelse return .{ .failed = "chat has no workspace folder" };
        const sid = chat.space_id orelse return .{ .failed = "chat has no workspace space" };
        const space = for (host.spaces.items) |*s| {
            if (std.mem.eql(u8, s.id, sid)) break s;
        } else return .{ .failed = "chat workspace space not found" };
        if (!std.mem.eql(u8, space.device_id, host.device_id)) return .{ .failed = "chat space belongs to another device" };
        root = (try actions.workspaceCheckout(a, io, space.path, cwd)) orelse return .{ .failed = "chat folder is not a workspace checkout" };
    } else {
        const sid = space_id.?;
        const space = for (host.spaces.items) |*s| {
            if (std.mem.eql(u8, s.id, sid)) break s;
        } else return .{ .failed = "space not found" };
        if (!std.mem.eql(u8, space.device_id, host.device_id)) return .{ .failed = "space belongs to another device" };
        root = (try actions.workspaceCheckout(a, io, space.path, checkout_path orelse space.path)) orelse
            return .{ .bad = "checkoutPath is not a workspace checkout" };
    }
    // A git checkout searches from its top level (`checkout_identity`).
    const top = try common.git(a, io, &.{ "rev-parse", "--show-toplevel" }, root);
    if (top == .ok) if (common.canonicalize(a, io, top.ok)) |c| return .{ .ok = c };
    return .{ .ok = root };
}

/// `SearchWorkspaceFiles { chatId | spaceId, checkoutPath?, query, includeIgnored?, limit? }`
/// → `[{ path, name, kind, score }]`.
pub fn searchWorkspaceFiles(host: *EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct SearchWorkspaceFilesRequest", .{});
    const query = common.str(o, "query") orelse return common.badParams("missing field `query`", .{});
    var include_ignored = false;
    if (o.get("includeIgnored")) |v| switch (v) {
        .bool => |b| include_ignored = b,
        else => return common.badParams("invalid type: expected a boolean for `includeIgnored`", .{}),
    };
    var limit: usize = max_results;
    if (o.get("limit")) |v| switch (v) {
        .null => {},
        .integer => |n| {
            if (n < 0 or n > 65535) return common.badParams("invalid value: integer `{d}`, expected u16", .{n});
            limit = @min(@as(usize, @intCast(n)), max_results);
        },
        else => return common.badParams("invalid type: expected u16 for `limit`", .{}),
    };
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) return common.badParams("query must not be empty", .{});
    if ((std.unicode.utf8CountCodepoints(query) catch query.len) > max_query_chars)
        return common.badParams("query must not exceed {d} characters", .{max_query_chars});
    const io = host.io orelse return common.failedMsg("workspace file search timed out");

    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = switch (try resolveTarget(a, io, host, o)) {
        .ok => |r| r,
        .bad => |m| return common.badParams("{s}", .{m}),
        .failed => |m| return common.failedMsg(m),
    };
    const found = searchRoot(a, io, root, query, include_ignored, limit, rpc_timeout_ms) catch |e| switch (e) {
        error.TimedOut => return common.failedMsg("workspace file search timed out"),
        error.Unreadable => return common.failed("could not read {s}", .{root}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    errdefer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    for (found) |m| {
        try s.beginObject();
        try s.objectField("path");
        try s.write(m.path);
        try s.objectField("name");
        try s.write(m.name);
        try s.objectField("kind");
        try s.write(@tagName(m.kind));
        try s.objectField("score");
        try s.write(m.score);
        try s.endObject();
    }
    try s.endArray();
    return .{ .unary_json = try aw.toOwnedSlice() };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "rpcw_search globMatch follows gitignore's wildcards" {
    try testing.expect(globMatch("*.log", "a.log"));
    try testing.expect(!globMatch("*.log", "dir/a.log"));
    try testing.expect(globMatch("**/build", "build"));
    try testing.expect(globMatch("**/build", "a/b/build"));
    try testing.expect(globMatch("logs/**", "logs/x/y"));
    try testing.expect(!globMatch("logs/**", "logs"));
    try testing.expect(globMatch("a/**/b", "a/b"));
    try testing.expect(globMatch("a/**/b", "a/x/y/b"));
    try testing.expect(globMatch("file[0-9].txt", "file7.txt"));
    try testing.expect(!globMatch("file[!0-9].txt", "file7.txt"));
    try testing.expect(globMatch("?.md", "a.md"));
    try testing.expect(globMatch("\\#notes", "#notes"));
}

test "rpcw_search score ranks name, prefix, substring, path and scattered matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?i64, 10_000), try score(a, "README.md", "README.md", "readme.md"));
    try testing.expectEqual(@as(?i64, 8_000 - 9), try score(a, "README.md", "docs/README.md", "read"));
    try testing.expectEqual(@as(?i64, 6_000 - 2 - 9), try score(a, "README.md", "README.md", "adm"));
    try testing.expectEqual(@as(?i64, 4_000 - 0 - 10), try score(a, "a.md", "src/x/a.md", "src/"));
    try testing.expectEqual(@as(?i64, 2_000 - 4 - 10), try score(a, "a.md", "src/x/a.md", "sxa"));
    try testing.expectEqual(@as(?i64, null), try score(a, "a.md", "src/x/a.md", "zz"));
}

/// A synthetic tree under `/tmp`, outside any git repository (a
/// `testing.tmpDir` sits inside this checkout, whose `.gitignore` would
/// apply to it, as it does in Rust).
const Tree = struct {
    base: []u8,
    root: []u8,
    env: common.TestEnv,

    fn init(t: *Tree) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const made = try std.fmt.allocPrint(gpa, "/tmp/rpcw-search-{x}", .{rnd});
        defer gpa.free(made);
        try std.Io.Dir.cwd().createDirPath(io, made);
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, made, gpa);
        defer gpa.free(real);
        t.base = try gpa.dupe(u8, real);
        const home = try std.fs.path.join(gpa, &.{ t.base, "home" });
        defer gpa.free(home);
        try std.Io.Dir.cwd().createDirPath(io, home);
        t.root = try std.fs.path.join(gpa, &.{ t.base, "repo" });
        try std.Io.Dir.cwd().createDirPath(io, t.root);
        t.env = try common.TestEnv.init(gpa, home);
        t.env.install();
    }

    fn deinit(t: *Tree) void {
        t.env.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, t.base) catch {};
        testing.allocator.free(t.root);
        testing.allocator.free(t.base);
    }

    fn file(t: *Tree, sub: []const u8, data: []const u8) !void {
        const p = try std.fs.path.join(testing.allocator, &.{ t.root, sub });
        defer testing.allocator.free(p);
        if (std.fs.path.dirname(p)) |d| try std.Io.Dir.cwd().createDirPath(testing.io, d);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = data });
    }

    fn paths(t: *Tree, a: Allocator, query: []const u8, include_ignored: bool) ![]const u8 {
        const found = try searchRoot(a, testing.io, t.root, query, include_ignored, max_results, rpc_timeout_ms);
        var out: std.ArrayList(u8) = .empty;
        for (found) |m| {
            try out.appendSlice(a, m.path);
            try out.append(a, ' ');
        }
        return out.items;
    }
};

test "rpcw_search walks with .gitignore, .ignore, exclude and negation like the ignore crate" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.file(".git/info/exclude", "secret.txt\n");
    try t.file(".git/HEAD", "ref: refs/heads/main\n");
    try t.file(".gitignore", "# build output\nbuild/\n*.log\n!keep.log\n/rooted.txt\n");
    try t.file(".ignore", "scratch\n");
    try t.file("src/.gitignore", "gen.txt\n");
    try t.file("src/main.txt", "");
    try t.file("src/gen.txt", "");
    try t.file("src/rooted.txt", "");
    try t.file("rooted.txt", "");
    try t.file("build/out.txt", "");
    try t.file("a.log", "");
    try t.file("keep.log", "");
    try t.file("secret.txt", "");
    try t.file("scratch/notes.txt", "");
    try t.file(".hidden.txt", "");
    try t.file(".harness-save-1.tmp", "");

    const txt = try t.paths(a, "txt", false);
    try testing.expect(std.mem.indexOf(u8, txt, "src/main.txt ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "src/rooted.txt ") != null); // anchored to the root only
    try testing.expect(std.mem.indexOf(u8, txt, ".hidden.txt ") != null); // hidden files are listed
    for ([_][]const u8{ "src/gen.txt", "build/out.txt", "secret.txt", "scratch/notes.txt", ".git/" }) |gone| {
        if (std.mem.indexOf(u8, txt, gone) != null) {
            std.debug.print("unexpected {s} in {s}\n", .{ gone, txt });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(std.mem.indexOf(u8, txt, " rooted.txt ") == null and !std.mem.startsWith(u8, txt, "rooted.txt "));

    const logs = try t.paths(a, "log", false);
    try testing.expectEqualStrings("keep.log ", logs);

    // includeIgnored turns every filter off (but never lists .git or editor temps).
    const all = try t.paths(a, "txt", true);
    for ([_][]const u8{ "src/gen.txt", "build/out.txt", "secret.txt", "scratch/notes.txt" }) |back| {
        try testing.expect(std.mem.indexOf(u8, all, back) != null);
    }
    try testing.expect(std.mem.indexOf(u8, all, ".git/") == null);
    try testing.expect(std.mem.indexOf(u8, all, ".harness-save") == null);
}

test "rpcw_search .gitignore applies only inside a git repository; folders and limits" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.file(".gitignore", "*.txt\n");
    try t.file("notes/one.txt", "");
    try t.file("notes/two.txt", "");
    const found = try searchRoot(a, testing.io, t.root, "notes", false, max_results, rpc_timeout_ms);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("notes", found[0].path); // exact name first
    try testing.expectEqual(Kind.directory, found[0].kind);
    const one = try searchRoot(a, testing.io, t.root, "notes", false, 1, rpc_timeout_ms);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(usize, 0), (try searchRoot(a, testing.io, t.root, "notes", false, 0, rpc_timeout_ms)).len);
    try testing.expectError(error.TimedOut, searchRoot(a, testing.io, t.root, "notes", false, 10, -1));
}

test "rpcw_search SearchWorkspaceFiles resolves the chat's checkout and refuses bad targets" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const gpa = testing.allocator;
    try t.file("docs/readme.md", "");
    try t.file("src/app.zig", "");
    var host = try EngineHost.init(gpa, "dev-search", "Synthetic");
    defer host.deinit();
    host.io = testing.io;
    const call = struct {
        fn f(h: *EngineHost, text: []const u8) !RpcOutcome {
            var p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
            defer p.deinit();
            return h.handle("SearchWorkspaceFiles", p.value);
        }
    }.f;
    const sp = try std.fmt.allocPrint(gpa, "{{\"op\":\"createSpace\",\"spaceId\":\"sp-s\",\"name\":\"s\",\"path\":{f}}}", .{json.fmt(t.root, .{})});
    defer gpa.free(sp);
    var p1 = try json.parseFromSlice(json.Value, gpa, sp, .{});
    defer p1.deinit();
    const r1 = try host.handle("Mutate", p1.value);
    if (r1 == .unary_json) gpa.free(r1.unary_json);
    const ch = try std.fmt.allocPrint(gpa, "{{\"op\":\"createChat\",\"chatId\":\"ch-s\",\"spaceId\":\"sp-s\",\"cwd\":{f},\"config\":{{\"harness\":\"mock\"}}}}", .{json.fmt(t.root, .{})});
    defer gpa.free(ch);
    var p2 = try json.parseFromSlice(json.Value, gpa, ch, .{});
    defer p2.deinit();
    const r2 = try host.handle("Mutate", p2.value);
    if (r2 == .unary_json) gpa.free(r2.unary_json);

    const ok = try call(&host, "{\"chatId\":\"ch-s\",\"query\":\"readme\",\"limit\":5}");
    defer gpa.free(ok.unary_json);
    try testing.expectEqualStrings("[{\"path\":\"docs/readme.md\",\"name\":\"readme.md\",\"kind\":\"file\",\"score\":7991}]", ok.unary_json);
    const by_space = try call(&host, "{\"spaceId\":\"sp-s\",\"query\":\"app\"}");
    defer gpa.free(by_space.unary_json);
    try testing.expect(std.mem.indexOf(u8, by_space.unary_json, "\"src/app.zig\"") != null);

    try testing.expectEqualStrings("workspace target needs exactly one of chatId or spaceId", (try call(&host, "{\"query\":\"x\"}")).err.bad_params);
    try testing.expectEqualStrings("workspace target needs exactly one of chatId or spaceId", (try call(&host, "{\"chatId\":\"ch-s\",\"spaceId\":\"sp-s\",\"query\":\"x\"}")).err.bad_params);
    try testing.expectEqualStrings("checkoutPath applies only to a space target", (try call(&host, "{\"chatId\":\"ch-s\",\"checkoutPath\":\"/\",\"query\":\"x\"}")).err.bad_params);
    try testing.expectEqualStrings("checkoutPath is not a workspace checkout", (try call(&host, "{\"spaceId\":\"sp-s\",\"checkoutPath\":\"/\",\"query\":\"x\"}")).err.bad_params);
    try testing.expectEqualStrings("chat not found", (try call(&host, "{\"chatId\":\"nope\",\"query\":\"x\"}")).err.exec_error);
    try testing.expectEqualStrings("space not found", (try call(&host, "{\"spaceId\":\"nope\",\"query\":\"x\"}")).err.exec_error);
    try testing.expectEqualStrings("query must not be empty", (try call(&host, "{\"chatId\":\"ch-s\",\"query\":\"  \"}")).err.bad_params);
    var long: [257]u8 = undefined;
    @memset(&long, 'q');
    const body = try std.fmt.allocPrint(gpa, "{{\"chatId\":\"ch-s\",\"query\":\"{s}\"}}", .{&long});
    defer gpa.free(body);
    try testing.expectEqualStrings("query must not exceed 256 characters", (try call(&host, body)).err.bad_params);
}
