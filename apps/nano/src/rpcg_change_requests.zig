//! A checkout's pull request, resolved on the host that owns the checkout
//! (`crates/engine/src/source_control.rs`, `change_requests.rs`): Git tells
//! the branch, its upstream and the remote's GitHub identity; the host's own
//! `gh` lists that branch's pull requests; the open one (else the newest
//! closed or merged one) is the checkout's. `MergeChangeRequest` merges a
//! pull request only while it is still that branch's open one, with the first
//! merge method the repository allows.
//!
//! Git here never runs remote transport (no `ls-remote`): a watched checkout
//! must not be able to run its configured commands on the host.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const exes = @import("rpcw_executables.zig");
const g = @import("rpcg_git.zig");

const git_timeout_ms: i64 = 10_000;
const github_timeout_ms: i64 = 20_000;
/// A merge waits on GitHub's own mergeability checks.
const github_merge_timeout_ms: i64 = 60_000;
const merge_message_limit: usize = 240;
const github_output_limit: usize = 1024 * 1024;
const github_result_limit = "20";
const github_json_fields = "number,title,url,state,baseRefName,headRefName,updatedAt,isCrossRepository,headRepositoryOwner";

/// `ChangeRequestError`: safe classes, never command output.
pub const Error = enum {
    repository_unavailable,
    unsupported_repository,
    cli_unavailable,
    authentication,
    rate_limited,
    timeout,
    decode,
    command_failed,

    pub fn text(e: Error) []const u8 {
        return switch (e) {
            .repository_unavailable => "Git repository context is unavailable",
            .unsupported_repository => "GitHub is unavailable for this repository",
            .cli_unavailable => "GitHub CLI is not installed",
            .authentication => "GitHub CLI is not authenticated for this host",
            .rate_limited => "GitHub API rate limit reached",
            .timeout => "GitHub request timed out",
            .decode => "GitHub returned an invalid response",
            .command_failed => "GitHub request failed",
        };
    }
};

pub fn Res(comptime T: type) type {
    return union(enum) { ok: T, err: Error };
}

// ── remotes and branches ───────────────────────────────────────────────────

pub const GitRemote = struct { host: []const u8, owner: []const u8, repository: []const u8 };

fn hostFromAuthority(authority: []const u8) ?[]const u8 {
    var host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    if (std.mem.indexOfScalar(u8, host, ':')) |c| host = host[0..c];
    return if (host.len == 0) null else host;
}

/// `parse_git_remote`: scp-like SSH, `ssh://` and `http(s)://` forms; any
/// host (GitHub Enterprise), exactly `owner/repo[.git]`.
pub fn parseGitRemote(arena: Allocator, raw: []const u8) !?GitRemote {
    const url = std.mem.trim(u8, raw, " \t\r\n");
    if (url.len == 0) return null;
    for (url) |c| if (std.ascii.isWhitespace(c)) return null;
    var host: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.indexOf(u8, url, "://")) |sep| {
        const scheme = url[0..sep];
        if (!(std.ascii.eqlIgnoreCase(scheme, "ssh") or std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https"))) return null;
        const rest = url[sep + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        host = hostFromAuthority(rest[0..slash]) orelse return null;
        path = rest[slash + 1 ..];
    } else {
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        const authority = url[0..colon];
        path = url[colon + 1 ..];
        if (std.mem.indexOfScalar(u8, authority, '/') != null or std.mem.startsWith(u8, path, "/")) return null;
        host = hostFromAuthority(authority) orelse return null;
    }
    path = std.mem.trim(u8, path, "/");
    var segs = std.mem.splitScalar(u8, path, '/');
    const owner = segs.next() orelse return null;
    var repository = segs.next() orelse return null;
    if (segs.next() != null or owner.len == 0 or repository.len == 0) return null;
    if (std.mem.endsWith(u8, repository, ".git")) repository = repository[0 .. repository.len - 4];
    if (repository.len == 0) return null;
    return .{ .host = try std.ascii.allocLowerString(arena, host), .owner = owner, .repository = repository };
}

fn normalizedUpstream(upstream: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, upstream, "refs/remotes/")) upstream["refs/remotes/".len..] else upstream;
}

fn remoteFromUpstream(upstream: []const u8) ?[]const u8 {
    const u = normalizedUpstream(upstream);
    const slash = std.mem.indexOfScalar(u8, u, '/') orelse return null;
    return u[0..slash];
}

fn branchFromUpstream(arena: Allocator, upstream: []const u8, remote_name: ?[]const u8) !?[]const u8 {
    const u = normalizedUpstream(upstream);
    if (remote_name) |r| {
        const prefix = try std.fmt.allocPrint(arena, "{s}/", .{r});
        if (std.mem.startsWith(u8, u, prefix)) {
            const b = u[prefix.len..];
            return if (b.len == 0) null else b;
        }
    }
    const slash = std.mem.indexOfScalar(u8, u, '/') orelse return null;
    const b = u[slash + 1 ..];
    return if (b.len == 0) null else b;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = std.mem.trim(u8, v orelse return null, " \t\r\n");
    return if (s.len == 0) null else s;
}

/// `BranchHeadContext`.
pub const BranchHead = struct {
    local_branch: []const u8,
    upstream_ref: ?[]const u8,
    remote_name: ?[]const u8,
    remote_url: ?[]const u8,
    host: ?[]const u8,
    repository: ?[]const u8,
    owner: ?[]const u8,
    head_branch: []const u8,
    head_selectors: []const []const u8,

    /// `BranchHeadContext::resolve`: the provider head selectors for a branch.
    pub fn resolve(arena: Allocator, local_branch: []const u8, upstream_in: ?[]const u8, remote_name_in: ?[]const u8, remote_url_in: ?[]const u8) !BranchHead {
        const upstream = nonEmpty(upstream_in);
        const remote_name = nonEmpty(remote_name_in) orelse (if (upstream) |u| remoteFromUpstream(u) else null);
        const remote_url = nonEmpty(remote_url_in);
        const parsed = if (remote_url) |u| try parseGitRemote(arena, u) else null;
        const upstream_branch = if (upstream) |u| try branchFromUpstream(arena, u, remote_name) else null;
        const head_branch = upstream_branch orelse local_branch;
        var selectors: std.ArrayList([]const u8) = .empty;
        const Push = struct {
            fn f(a: Allocator, list: *std.ArrayList([]const u8), v: []const u8) !void {
                for (list.items) |x| if (std.mem.eql(u8, x, v)) return;
                try list.append(a, v);
            }
        };
        if (parsed) |r| try Push.f(arena, &selectors, try std.fmt.allocPrint(arena, "{s}:{s}", .{ r.owner, head_branch }));
        if (upstream != null) try Push.f(arena, &selectors, head_branch);
        if (upstream == null or std.mem.eql(u8, local_branch, head_branch)) try Push.f(arena, &selectors, local_branch);
        return .{
            .local_branch = local_branch,
            .upstream_ref = upstream,
            .remote_name = remote_name,
            .remote_url = remote_url,
            .host = if (parsed) |r| r.host else null,
            .repository = if (parsed) |r| r.repository else null,
            .owner = if (parsed) |r| r.owner else null,
            .head_branch = head_branch,
            .head_selectors = selectors.items,
        };
    }
};

/// `CheckoutSourceContext`.
pub const Source = struct {
    checkout_root: []const u8,
    branch: BranchHead,
    default_branch: ?[]const u8,
};

/// `GitCheckoutInspector::git`: trimmed UTF-8 stdout, or null.
fn gitLine(arena: Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) !?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "git");
    try argv.appendSlice(arena, args);
    var r = common.run(arena, io, argv.items, cwd, git_timeout_ms) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!r.success() or r.stdout.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(r.stdout)) return null;
    return std.mem.trim(u8, r.stdout, " \t\r\n");
}

/// `GitCheckoutInspector::inspect`: the branch, its upstream, the remote
/// (branch config, upstream, `remote.pushDefault`, then `origin` or the only
/// one) and its URL, and the default branch from local refs only.
pub fn inspect(arena: Allocator, io: std.Io, cwd: []const u8) !Res(Source) {
    const root = (try gitLine(arena, io, cwd, &.{ "rev-parse", "--show-toplevel" })) orelse return .{ .err = .repository_unavailable };
    if (root.len == 0) return .{ .err = .repository_unavailable };
    const local = (try gitLine(arena, io, root, &.{ "branch", "--show-current" })) orelse return .{ .err = .repository_unavailable };
    if (local.len == 0 or std.mem.eql(u8, local, "HEAD")) return .{ .err = .repository_unavailable };
    const upstream = try gitLine(arena, io, root, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" });
    const key = try std.fmt.allocPrint(arena, "branch.{s}.remote", .{local});
    var remote_name: ?[]const u8 = try gitLine(arena, io, root, &.{ "config", "--get", key });
    if (remote_name) |r| if (std.mem.eql(u8, r, ".")) {
        remote_name = null;
    };
    if (remote_name == null) remote_name = if (upstream) |u| remoteFromUpstream(u) else null;
    if (remote_name == null) remote_name = try gitLine(arena, io, root, &.{ "config", "--get", "remote.pushDefault" });
    if (remote_name == null) {
        if (try gitLine(arena, io, root, &.{"remote"})) |remotes| {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, remotes, '\n');
            while (it.next()) |r| if (r.len > 0) try list.append(arena, r);
            for (list.items) |r| if (std.mem.eql(u8, r, "origin")) {
                remote_name = r;
                break;
            };
            if (remote_name == null and list.items.len == 1) remote_name = list.items[0];
        }
    }
    var remote_url: ?[]const u8 = null;
    if (remote_name) |r| {
        // A push URL that isn't a remote (a fork's "DISABLED…" one) falls back to the fetch URL.
        if (try gitLine(arena, io, root, &.{ "remote", "get-url", "--push", r })) |u| {
            if (try parseGitRemote(arena, u) != null) remote_url = u;
        }
        if (remote_url == null) remote_url = try gitLine(arena, io, root, &.{ "remote", "get-url", r });
    }
    const branch = try BranchHead.resolve(arena, local, upstream, remote_name, remote_url);
    var default_branch: ?[]const u8 = null;
    if (branch.remote_name) |r| {
        const remote_head = try std.fmt.allocPrint(arena, "refs/remotes/{s}/HEAD", .{r});
        if (try gitLine(arena, io, root, &.{ "symbolic-ref", "--quiet", "--short", remote_head })) |reference| {
            default_branch = try branchFromUpstream(arena, reference, r);
        }
    }
    return .{ .ok = .{ .checkout_root = root, .branch = branch, .default_branch = default_branch } };
}

/// A watched branch other than the checked-out one keeps the checkout's
/// remote identity (`watch_for_branch`).
pub fn withBranch(arena: Allocator, source: Source, branch: ?[]const u8) !Source {
    const b = branch orelse return source;
    if (std.mem.eql(u8, source.branch.local_branch, b)) return source;
    var s = source;
    s.branch = try BranchHead.resolve(arena, b, null, source.branch.remote_name, source.branch.remote_url);
    return s;
}

// ── gh ─────────────────────────────────────────────────────────────────────

const Output = struct { success: bool, stdout: []const u8, stderr: []const u8, truncated: bool };

fn runGh(arena: Allocator, io: std.Io, source: Source, args: []const []const u8, timeout_ms: i64) !Res(Output) {
    const gh = (exes.findOnPaths(arena, io, "gh", &.{}) catch null) orelse return .{ .err = .cli_unavailable };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, gh);
    try argv.appendSlice(arena, args);
    var env = try @import("rpcg_diff.zig").currentEnvMap(arena);
    try env.put("GH_PROMPT_DISABLED", "1");
    if (exes.loginShellPath(arena, io)) |login_path| {
        const current = env.get("PATH") orelse "";
        try env.put("PATH", if (current.len == 0) login_path else try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ current, std.fs.path.delimiter, login_path }));
    }
    const deadline: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake }) };
    const res = std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = .{ .path = source.checkout_root },
        .environ_map = &env,
        .stdout_limit = .limited(github_output_limit + 1),
        .stderr_limit = .limited(github_output_limit),
        .timeout = deadline,
        .create_no_window = true,
    }) catch |e| return .{ .err = switch (e) {
        error.Timeout => .timeout,
        error.StreamTooLong => return .{ .ok = .{ .success = true, .stdout = "", .stderr = "", .truncated = true } },
        error.FileNotFound => .cli_unavailable,
        error.OutOfMemory => return error.OutOfMemory,
        else => .command_failed,
    } };
    return .{ .ok = .{
        .success = res.term == .exited and res.term.exited == 0,
        .stdout = res.stdout,
        .stderr = res.stderr,
        .truncated = res.stdout.len > github_output_limit,
    } };
}

/// `classify_github_failure`.
pub fn classifyFailure(stderr: []const u8) Error {
    var buf: [4096]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(buf.len, stderr.len)], stderr[0..@min(buf.len, stderr.len)]);
    if (std.mem.indexOf(u8, lower, "rate limit") != null or std.mem.indexOf(u8, lower, "secondary rate") != null) return .rate_limited;
    for ([_][]const u8{ "not logged", "authentication", "authenticate", "gh auth login", "bad credentials" }) |n| {
        if (std.mem.indexOf(u8, lower, n) != null) return .authentication;
    }
    return .command_failed;
}

pub const State = enum { open, closed, merged };

pub const Summary = struct {
    number: u64,
    title: []const u8,
    url: []const u8,
    state: State,
    base_ref: []const u8,
    head_ref: []const u8,
};

const Pull = struct {
    number: u64,
    title: []const u8,
    url: []const u8,
    state: State,
    base_ref_name: []const u8,
    head_ref_name: []const u8,
    updated_at: []const u8,
    is_cross_repository: bool,
    owner_login: []const u8,
};

fn str(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// `serde_json::from_slice::<Vec<GhPullRequest>>`: every field present and typed.
pub fn parsePulls(arena: Allocator, bytes: []const u8) ?[]Pull {
    const v = json.parseFromSliceLeaky(json.Value, arena, bytes, .{}) catch return null;
    if (v != .array) return null;
    var out: std.ArrayList(Pull) = .empty;
    for (v.array.items) |item| {
        if (item != .object) return null;
        const o = item.object;
        const number = o.get("number") orelse return null;
        if (number != .integer or number.integer < 0) return null;
        const state_text = str(o, "state") orelse return null;
        const state: State = if (std.mem.eql(u8, state_text, "OPEN")) .open else if (std.mem.eql(u8, state_text, "CLOSED")) .closed else if (std.mem.eql(u8, state_text, "MERGED")) .merged else return null;
        const cross = o.get("isCrossRepository") orelse return null;
        if (cross != .bool) return null;
        const owner = o.get("headRepositoryOwner") orelse return null;
        if (owner != .object) return null;
        const updated = str(o, "updatedAt") orelse return null;
        if (updated.len < 20 or updated[4] != '-' or updated[10] != 'T') return null;
        out.append(arena, .{
            .number = @intCast(number.integer),
            .title = str(o, "title") orelse return null,
            .url = str(o, "url") orelse return null,
            .state = state,
            .base_ref_name = str(o, "baseRefName") orelse return null,
            .head_ref_name = str(o, "headRefName") orelse return null,
            .updated_at = updated,
            .is_cross_repository = cross.bool,
            .owner_login = str(owner.object, "login") orelse return null,
        }) catch return null;
    }
    return out.items;
}

fn listForSelector(arena: Allocator, io: std.Io, source: Source, selector: []const u8) !Res([]Pull) {
    const out = switch (try runGh(arena, io, source, &.{ "pr", "list", "--head", selector, "--state", "all", "--limit", github_result_limit, "--json", github_json_fields }, github_timeout_ms)) {
        .ok => |o| o,
        .err => |e| return .{ .err = e },
    };
    if (!out.success) return .{ .err = classifyFailure(out.stderr) };
    if (out.truncated) return .{ .err = .decode };
    return .{ .ok = parsePulls(arena, out.stdout) orelse return .{ .err = .decode } };
}

/// The remote's default branch through the provider; failures read as unknown.
fn defaultBranch(arena: Allocator, io: std.Io, source: Source) !?[]const u8 {
    const host = source.branch.host orelse return null;
    const owner = source.branch.owner orelse return null;
    const repository = source.branch.repository orelse return null;
    const slug = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ host, owner, repository });
    const out = switch (try runGh(arena, io, source, &.{ "repo", "view", slug, "--json", "defaultBranchRef" }, github_timeout_ms)) {
        .ok => |o| o,
        .err => return null,
    };
    if (!out.success or out.truncated) return null;
    const v = json.parseFromSliceLeaky(json.Value, arena, out.stdout, .{}) catch return null;
    if (v != .object) return null;
    const r = v.object.get("defaultBranchRef") orelse return null;
    if (r != .object) return null;
    const name = str(r.object, "name") orelse return null;
    return if (name.len == 0) null else name;
}

fn validUrl(url: []const u8) bool {
    const u = std.mem.trim(u8, url, " \t\r\n");
    const rest = if (std.ascii.startsWithIgnoreCase(u, "https://")) u[8..] else if (std.ascii.startsWithIgnoreCase(u, "http://")) u[7..] else return false;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return end > 0 and hostFromAuthority(rest[0..end]) != null;
}

/// `select_pull_request`: the branch's own pull requests (from the expected
/// owner, or same-repository ones without one), terminal ones dropped on the
/// default branch; open first, then newest, then highest number.
pub fn selectPull(source: Source, default_branch: ?[]const u8, candidates: []Pull) Res(?Summary) {
    const on_default = if (default_branch) |d| std.mem.eql(u8, d, source.branch.head_branch) else false;
    var best: ?Pull = null;
    for (candidates) |c| {
        if (!std.mem.eql(u8, c.head_ref_name, source.branch.head_branch)) continue;
        const owner_ok = if (source.branch.owner) |o| std.ascii.eqlIgnoreCase(c.owner_login, o) else !c.is_cross_repository;
        if (!owner_ok) continue;
        if (on_default and c.state != .open) continue;
        if (best) |b| {
            const c_open = c.state == .open;
            const b_open = b.state == .open;
            const better = if (c_open != b_open) c_open else switch (std.mem.order(u8, c.updated_at, b.updated_at)) {
                .gt => true,
                .lt => false,
                .eq => c.number > b.number,
            };
            if (better) best = c;
        } else best = c;
    }
    const p = best orelse return .{ .ok = null };
    if (p.number == 0 or std.mem.trim(u8, p.title, " \t\r\n").len == 0 or
        std.mem.trim(u8, p.base_ref_name, " \t\r\n").len == 0 or
        std.mem.trim(u8, p.head_ref_name, " \t\r\n").len == 0 or !validUrl(p.url)) return .{ .err = .decode };
    return .{ .ok = .{
        .number = p.number,
        .title = p.title,
        .url = std.mem.trim(u8, p.url, " \t\r\n"),
        .state = p.state,
        .base_ref = p.base_ref_name,
        .head_ref = p.head_ref_name,
    } };
}

/// `GitHubCli::find_for_branch`: the first head selector with candidates decides.
pub fn findForBranch(arena: Allocator, io: std.Io, source: Source) !Res(?Summary) {
    if (source.branch.host == null or source.branch.owner == null or source.branch.repository == null) return .{ .err = .unsupported_repository };
    for (source.branch.head_selectors) |selector| {
        const candidates = switch (try listForSelector(arena, io, source, selector)) {
            .ok => |c| c,
            .err => |e| return .{ .err = e },
        };
        if (candidates.len == 0) continue;
        var default_branch = source.default_branch;
        if (default_branch == null) {
            for (candidates) |c| {
                if (std.mem.eql(u8, c.head_ref_name, source.branch.head_branch) and c.state != .open) {
                    default_branch = try defaultBranch(arena, io, source);
                    break;
                }
            }
        }
        return selectPull(source, default_branch, candidates);
    }
    return .{ .ok = null };
}

pub const MergeResult = struct { merged: bool, message: []const u8 };

/// `merge_refusal`: GitHub's own reason, first line, glyph stripped.
pub fn mergeRefusal(arena: Allocator, stderr: []const u8, number: u64) ![]const u8 {
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        for ([_][]const u8{ "X ", "! ", "✗ " }) |glyph| {
            if (std.mem.startsWith(u8, line, glyph)) {
                line = line[glyph.len..];
                break;
            }
        }
        line = std.mem.trim(u8, line, " \t\r");
        if (line.len > 0) return arena.dupe(u8, g.boundedField(line, merge_message_limit));
    }
    return std.fmt.allocPrint(arena, "GitHub did not merge #{d}", .{number});
}

/// `GitHubCli::merge`.
pub fn merge(arena: Allocator, io: std.Io, source: Source, number: u64) !Res(MergeResult) {
    const current = switch (try findForBranch(arena, io, source)) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    const pr = if (current) |c| (if (c.number == number) c else null) else null;
    if (pr == null) return .{ .ok = .{ .merged = false, .message = try std.fmt.allocPrint(arena, "#{d} is no longer this branch's pull request", .{number}) } };
    switch (pr.?.state) {
        .open => {},
        .merged => return .{ .ok = .{ .merged = false, .message = try std.fmt.allocPrint(arena, "#{d} is already merged", .{number}) } },
        .closed => return .{ .ok = .{ .merged = false, .message = try std.fmt.allocPrint(arena, "#{d} is closed", .{number}) } },
    }
    const slug = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ source.branch.host.?, source.branch.owner.?, source.branch.repository.? });
    const settings = switch (try runGh(arena, io, source, &.{ "repo", "view", slug, "--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed" }, github_timeout_ms)) {
        .ok => |o| o,
        .err => |e| return .{ .err = e },
    };
    if (!settings.success) return .{ .err = classifyFailure(settings.stderr) };
    const v = json.parseFromSliceLeaky(json.Value, arena, settings.stdout, .{}) catch return .{ .err = .decode };
    if (v != .object) return .{ .err = .decode };
    const allowed = struct {
        fn f(o: json.ObjectMap, k: []const u8) ?bool {
            const x = o.get(k) orelse return false;
            return if (x == .bool) x.bool else null;
        }
    }.f;
    const flags = [_]struct { []const u8, []const u8 }{ .{ "mergeCommitAllowed", "--merge" }, .{ "squashMergeAllowed", "--squash" }, .{ "rebaseMergeAllowed", "--rebase" } };
    var method: ?[]const u8 = null;
    for (flags) |fl| {
        const a = allowed(v.object, fl[0]) orelse return .{ .err = .decode };
        if (a and method == null) method = fl[1];
    }
    const m = method orelse return .{ .ok = .{ .merged = false, .message = "This repository allows no merge method" } };
    const num_text = try std.fmt.allocPrint(arena, "{d}", .{number});
    const out = switch (try runGh(arena, io, source, &.{ "pr", "merge", num_text, "--repo", slug, m }, github_merge_timeout_ms)) {
        .ok => |o| o,
        .err => |e| return .{ .err = e },
    };
    if (out.success) return .{ .ok = .{ .merged = true, .message = try std.fmt.allocPrint(arena, "Merged #{d}", .{number}) } };
    return switch (classifyFailure(out.stderr)) {
        .authentication, .rate_limited => |e| .{ .err = e },
        else => .{ .ok = .{ .merged = false, .message = try mergeRefusal(arena, out.stderr, number) } },
    };
}

// ── JSON ───────────────────────────────────────────────────────────────────

pub fn writeSummary(w: *std.Io.Writer, s: Summary) !void {
    try w.writeAll("{\"provider\":\"github\"");
    try w.print(",\"number\":{d}", .{s.number});
    try g.field(w, true, "title", s.title);
    try g.field(w, true, "url", s.url);
    try w.print(",\"state\":\"{s}\"", .{@tagName(s.state)});
    try g.field(w, true, "baseRef", s.base_ref);
    try g.field(w, true, "headRef", s.head_ref);
    try w.writeByte('}');
}

/// `CheckoutChangeRequestStatus` without `updatedAt` (what decides a re-emit)
/// and the full status.
pub fn writeStatusBody(w: *std.Io.Writer, checkout_id: []const u8, device_id: []const u8, source: Source, summary: ?Summary) !void {
    try w.writeAll("{\"checkoutId\":");
    try g.writeJsonString(w, checkout_id);
    try g.field(w, true, "deviceId", device_id);
    try g.field(w, true, "cwd", source.checkout_root);
    try g.field(w, true, "branch", source.branch.local_branch);
    try w.writeAll(",\"changeRequest\":");
    if (summary) |s| try writeSummary(w, s) else try w.writeAll("null");
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "rpcg_change_requests parses GitHub remotes and builds head selectors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "git@github.com:Synth/Repo.git", "ssh://git@GitHub.com/Synth/Repo", "https://github.com/Synth/Repo.git/", "https://user@github.com:443/Synth/Repo" }) |u| {
        const r = (try parseGitRemote(a, u)).?;
        try testing.expectEqualStrings("github.com", r.host);
        try testing.expectEqualStrings("Synth", r.owner);
        try testing.expectEqualStrings("Repo", r.repository);
    }
    for ([_][]const u8{ "", "ftp://github.com/a/b", "git@github.com:/a/b", "https://github.com/a", "https://github.com/a/b/c", "has space:a/b", "file:///a/b" }) |u| {
        try testing.expect(try parseGitRemote(a, u) == null);
    }
    const fork = try BranchHead.resolve(a, "feature", "origin/feature", null, "git@github.com:me/repo.git");
    try testing.expectEqualStrings("origin", fork.remote_name.?);
    try testing.expectEqual(@as(usize, 2), fork.head_selectors.len);
    try testing.expectEqualStrings("me:feature", fork.head_selectors[0]);
    try testing.expectEqualStrings("feature", fork.head_selectors[1]);
    const renamed = try BranchHead.resolve(a, "local", "origin/remote-name", "origin", null);
    try testing.expectEqualStrings("remote-name", renamed.head_branch);
    try testing.expectEqual(@as(usize, 1), renamed.head_selectors.len);
    const bare = try BranchHead.resolve(a, "solo", null, null, null);
    try testing.expectEqualStrings("solo", bare.head_selectors[0]);
}

test "rpcg_change_requests selects open first, then newest, and classifies failures" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const source: Source = .{ .checkout_root = "/r", .branch = try BranchHead.resolve(a, "feature", null, "origin", "git@github.com:me/repo.git"), .default_branch = "main" };
    const listed =
        \\[{"number":3,"title":"Old","url":"https://github.com/me/repo/pull/3","state":"MERGED","baseRefName":"main","headRefName":"feature","updatedAt":"2026-01-03T00:00:00Z","isCrossRepository":false,"headRepositoryOwner":{"login":"me"}},
        \\ {"number":4,"title":"Open","url":"https://github.com/me/repo/pull/4","state":"OPEN","baseRefName":"main","headRefName":"feature","updatedAt":"2026-01-01T00:00:00Z","isCrossRepository":false,"headRepositoryOwner":{"login":"ME"}},
        \\ {"number":5,"title":"Fork","url":"https://github.com/me/repo/pull/5","state":"OPEN","baseRefName":"main","headRefName":"feature","updatedAt":"2026-01-09T00:00:00Z","isCrossRepository":true,"headRepositoryOwner":{"login":"someone"}}]
    ;
    const pulls = parsePulls(a, listed).?;
    const picked = selectPull(source, "main", pulls).ok.?;
    try testing.expectEqual(@as(u64, 4), picked.number);
    try testing.expectEqual(State.open, picked.state);
    const newest = selectPull(source, "main", pulls[0..1]).ok.?;
    try testing.expectEqual(@as(u64, 3), newest.number);
    var on_default = source;
    on_default.branch = try BranchHead.resolve(a, "main", null, "origin", "git@github.com:me/repo.git");
    var main_pulls = parsePulls(a, "[{\"number\":9,\"title\":\"t\",\"url\":\"https://github.com/me/repo/pull/9\",\"state\":\"CLOSED\",\"baseRefName\":\"x\",\"headRefName\":\"main\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"isCrossRepository\":false,\"headRepositoryOwner\":{\"login\":\"me\"}}]").?;
    try testing.expect(selectPull(on_default, "main", main_pulls).ok == null);
    main_pulls[0].url = "javascript:alert(1)";
    try testing.expect(selectPull(on_default, "other", main_pulls).err == .decode);
    try testing.expect(parsePulls(a, "[{\"number\":1}]") == null);
    try testing.expect(parsePulls(a, "{not json") == null);
    try testing.expectEqual(Error.rate_limited, classifyFailure("API rate limit exceeded"));
    try testing.expectEqual(Error.authentication, classifyFailure("To get started with GitHub CLI, please run:  gh auth login"));
    try testing.expectEqual(Error.command_failed, classifyFailure("something else"));
    try testing.expectEqualStrings("Pull request is not mergeable", try mergeRefusal(a, "\nX Pull request is not mergeable\nmore", 7));
    try testing.expectEqualStrings("GitHub did not merge #7", try mergeRefusal(a, "  \n", 7));
}

// ── watch and merge (change_requests.rs) ───────────────────────────────────

const engine_host = @import("engine_host.zig");
const watch = @import("rpcg_watch.zig");
const rpc = @import("rpcg_rpc.zig");
const auth_host = @import("auth_host.zig");
const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

const with_change_request_ttl_ms: i64 = 3 * 60 * 1000;
const terminal_change_request_ttl_ms: i64 = 15 * 60 * 1000;
const without_change_request_ttl_ms: i64 = 5 * 60 * 1000;
const failure_initial_backoff_ms: i64 = 30 * 1000;
const failure_max_backoff_ms: i64 = 15 * 60 * 1000;
const context_poll_interval_ms: i64 = 60 * 1000;

pub const cr_prefix = "\x1ecr:";

/// One `WatchCheckoutChangeRequest` stream. Guarded by `host.mutex`.
pub const Sub = struct {
    target: []u8,
    cwd: []u8,
    branch: ?[]u8,
    checkout_id: []u8,
    last_emitted: ?[]u8 = null,
    next_check_ms: i64 = 0,

    pub fn deinit(s: *Sub, gpa: Allocator) void {
        gpa.free(s.target);
        gpa.free(s.cwd);
        if (s.branch) |b| gpa.free(b);
        gpa.free(s.checkout_id);
        if (s.last_emitted) |e| gpa.free(e);
    }
};

/// The latest successful lookup for one checkout + branch + upstream +
/// remote; failures keep it and back off. Worker-only.
pub const Entry = struct {
    body: ?[]u8 = null,
    next_refresh_ms: i64 = 0,
    failures: u32 = 0,

    pub fn deinit(e: *Entry, gpa: Allocator) void {
        if (e.body) |b| gpa.free(b);
    }
};

/// A checkout inspection shared by every watch on the same folder. Worker-only.
pub const Inspection = struct {
    arena: std.heap.ArenaAllocator,
    at_ms: i64,
    result: Res(Source),
};

fn failureBackoff(failures: u32) i64 {
    const exponent: u6 = @intCast(@min(@as(u32, 31), failures -| 1));
    const scaled = std.math.mul(i64, failure_initial_backoff_ms, @as(i64, 1) << exponent) catch failure_max_backoff_ms;
    return @min(scaled, failure_max_backoff_ms);
}

/// `change_request_root`: a folder a local chat names exactly, or a checkout
/// of a local space. Anything else is refused before git runs there.
fn changeRequestRoot(host: *EngineHost, io: std.Io, cwd: []const u8) !?[]u8 {
    for (host.chats.items) |c| {
        if (!std.mem.eql(u8, c.device_id, host.device_id)) continue;
        if (c.cwd) |cc| if (std.mem.eql(u8, cc, cwd)) return try host.gpa.dupe(u8, cwd);
    }
    for (host.spaces.items) |s| {
        if (!std.mem.eql(u8, s.device_id, host.device_id)) continue;
        if (try g.workspaceCheckout(host.gpa, io, s.path, cwd)) |root| return root;
    }
    return null;
}

/// `WatchCheckoutChangeRequest { cwd, branch? }` → a checked stream of
/// `CheckoutChangeRequestStatus`, re-sent whenever the branch's pull request
/// changes; a failed lookup keeps the last good one.
pub fn watchCheckoutChangeRequest(host: *EngineHost, call_id: u64, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    if (params != .object) return common.badParams("invalid type: expected struct CheckoutChangeRequestParams", .{});
    const o = params.object;
    const cwd = switch (rpc.strOrFail(o, "cwd", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const branch = rpc.optStr(o, "branch");
    const io = host.io orelse return common.failedMsg(Error.repository_unavailable.text());
    const gpa = host.gpa;
    const root = (try changeRequestRoot(host, io, cwd)) orelse return common.badParams("cwd is not a known checkout on this device", .{});
    defer gpa.free(root);
    const ident = switch (try g.checkoutIdentity(gpa, io, host.device_id, root)) {
        .ok => |i| i,
        .failed => return common.failedMsg(Error.repository_unavailable.text()),
    };
    defer ident.deinit(gpa);
    const s = (try watch.ensure(host)) orelse return common.failedMsg(Error.repository_unavailable.text());
    s.cr_seq += 1;
    const target = try std.fmt.allocPrint(gpa, "{s}{d}", .{ cr_prefix, s.cr_seq });
    errdefer gpa.free(target);
    var sub: Sub = .{
        .target = target,
        .cwd = try gpa.dupe(u8, root),
        .branch = if (branch) |b| try gpa.dupe(u8, b) else null,
        .checkout_id = try gpa.dupe(u8, ident.id),
    };
    if (call_id != 0) {
        try host.registerWatch(call_id, watch.watch_kind, target);
        try s.cr_subs.append(gpa, sub);
        _ = s.kick.fetchAdd(1, .acq_rel);
    } else sub.deinit(gpa);
    return .{ .stream_items_json = .{ .checked = true, .items = try gpa.alloc([]u8, 0) } };
}

/// `MergeChangeRequest { cwd, branch?, number }` → `{merged, message}`.
pub fn mergeChangeRequest(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    if (params != .object) return common.badParams("invalid type: expected struct MergeChangeRequestParams", .{});
    const o = params.object;
    const cwd = switch (rpc.strOrFail(o, "cwd", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const number: u64 = switch (o.get("number") orelse return common.badParams("missing field `number`", .{})) {
        .integer => |n| if (n >= 0) @intCast(n) else return common.badParams("invalid value: integer `{d}`, expected u64", .{n}),
        else => return common.badParams("invalid type: expected u64 for `number`", .{}),
    };
    const io = host.io orelse return common.failedMsg(Error.repository_unavailable.text());
    const gpa = host.gpa;
    const root = (try changeRequestRoot(host, io, cwd)) orelse return common.badParams("cwd is not a known checkout on this device", .{});
    defer gpa.free(root);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = switch (try inspect(arena, io, root)) {
        .ok => |src| try withBranch(arena, src, rpc.optStr(o, "branch")),
        .err => |e| return common.failedMsg(e.text()),
    };
    const result = switch (try merge(arena, io, source, number)) {
        .ok => |r| r,
        .err => |e| return common.failedMsg(e.text()),
    };
    if (result.merged) {
        if (watch.existing(host)) |s| {
            s.cr_refresh_all.store(true, .release);
            _ = s.kick.fetchAdd(1, .acq_rel);
        }
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print("{{\"merged\":{},\"message\":", .{result.merged});
    try g.writeJsonString(&aw.writer, result.message);
    try aw.writer.writeByte('}');
    return .{ .unary_json = try aw.toOwnedSlice() };
}

fn targetWatched(host: *EngineHost, target: []const u8) bool {
    for (host.watches.items) |w| {
        if (w.kind != watch.watch_kind) continue;
        if (w.target_id) |t| if (std.mem.eql(u8, t, target)) return true;
    }
    return false;
}

const Due = struct { target: []const u8, cwd: []const u8, branch: ?[]const u8, checkout_id: []const u8, last: ?[]const u8 };
const Outcome = struct { target: []const u8, body: ?[]const u8, frame: ?[]const u8, next_check_ms: i64 };

/// One worker pass over the change-request streams (called off the lock).
pub fn process(s: *watch.State, io: std.Io, now: i64) !void {
    const host = s.host;
    const gpa = s.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var due: std.ArrayList(Due) = .empty;
    var refresh = false;
    {
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        // After a merge every cached lookup expires and every watch wakes (`refresh_now`).
        refresh = s.cr_refresh_all.swap(false, .acq_rel);
        if (refresh) for (s.cr_subs.items) |*sub| {
            sub.next_check_ms = 0;
        };
        var i: usize = 0;
        while (i < s.cr_subs.items.len) {
            const sub = &s.cr_subs.items[i];
            if (!targetWatched(host, sub.target)) {
                var gone = s.cr_subs.orderedRemove(i);
                gone.deinit(gpa);
                continue;
            }
            i += 1;
            if (now < sub.next_check_ms) continue;
            try due.append(arena, .{
                .target = try arena.dupe(u8, sub.target),
                .cwd = try arena.dupe(u8, sub.cwd),
                .branch = if (sub.branch) |b| try arena.dupe(u8, b) else null,
                .checkout_id = try arena.dupe(u8, sub.checkout_id),
                .last = if (sub.last_emitted) |e| try arena.dupe(u8, e) else null,
            });
        }
        if (s.cr_subs.items.len == 0) {
            clearCaches(s);
            return;
        }
    }
    if (refresh) {
        clearInspections(s);
        var it = s.cr_cache.valueIterator();
        while (it.next()) |e| e.next_refresh_ms = 0;
    }
    if (due.items.len == 0) return;

    var outcomes: std.ArrayList(Outcome) = .empty;
    var ts: [32]u8 = undefined;
    const updated_at = auth_host.formatRfc3339Ms(&ts, now);
    for (due.items) |d| {
        if (@atomicLoad(bool, &host.stop_requested, .acquire)) return;
        const insp = try inspection(s, io, d.cwd, now);
        const base = switch (insp.result) {
            .ok => |src| src,
            .err => {
                try outcomes.append(arena, .{ .target = d.target, .body = null, .frame = null, .next_check_ms = now + context_poll_interval_ms });
                continue;
            },
        };
        const source = try withBranch(arena, base, d.branch);
        const remote = if (source.branch.remote_url) |u| (try parseGitRemote(arena, u)) else null;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}\x00{s}", .{
            d.checkout_id,
            source.branch.local_branch,
            source.branch.upstream_ref orelse "",
            if (remote) |r| try std.ascii.allocLowerString(arena, try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ r.host, r.owner, r.repository })) else "",
        });
        const gop = try s.cr_cache.getOrPut(gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, key);
            gop.value_ptr.* = .{};
        }
        const entry = gop.value_ptr;
        if (now >= entry.next_refresh_ms) {
            switch (try findForBranch(arena, io, source)) {
                .ok => |summary| {
                    var aw: std.Io.Writer.Allocating = .init(gpa);
                    errdefer aw.deinit();
                    try writeStatusBody(&aw.writer, d.checkout_id, host.device_id, source, summary);
                    if (entry.body) |old| gpa.free(old);
                    entry.body = try aw.toOwnedSlice();
                    entry.failures = 0;
                    entry.next_refresh_ms = now + if (summary) |sm| switch (sm.state) {
                        .open => with_change_request_ttl_ms,
                        .merged, .closed => terminal_change_request_ttl_ms,
                    } else without_change_request_ttl_ms;
                },
                .err => |e| {
                    entry.failures +|= 1;
                    entry.next_refresh_ms = now + failureBackoff(entry.failures);
                    std.log.debug("change request refresh failed: {s}", .{e.text()});
                },
            }
        }
        const body = entry.body;
        const changed = if (body) |b| (if (d.last) |l| !std.mem.eql(u8, l, b) else true) else false;
        const frame = if (changed) try std.fmt.allocPrint(arena, "{s},\"updatedAt\":\"{s}\"}}", .{ body.?, updated_at }) else null;
        try outcomes.append(arena, .{
            .target = d.target,
            .body = if (changed) try arena.dupe(u8, body.?) else null,
            .frame = frame,
            .next_check_ms = @min(entry.next_refresh_ms, now + context_poll_interval_ms),
        });
    }

    host.mutex.lockUncancelable(io);
    defer host.mutex.unlock(io);
    for (outcomes.items) |oc| {
        const sub = for (s.cr_subs.items) |*x| {
            if (std.mem.eql(u8, x.target, oc.target)) break x;
        } else continue;
        sub.next_check_ms = oc.next_check_ms;
        if (oc.frame) |f| {
            try host.broadcastWatch(watch.watch_kind, sub.target, f);
            if (sub.last_emitted) |old| gpa.free(old);
            sub.last_emitted = try gpa.dupe(u8, oc.body.?);
        }
    }
}

fn inspection(s: *watch.State, io: std.Io, cwd: []const u8, now: i64) !*Inspection {
    if (s.cr_inspections.getPtr(cwd)) |i| {
        if (now - i.at_ms < context_poll_interval_ms) return i;
        i.arena.deinit();
        i.arena = std.heap.ArenaAllocator.init(s.gpa);
        i.at_ms = now;
        i.result = try inspect(i.arena.allocator(), io, cwd);
        return i;
    }
    var insp: Inspection = .{ .arena = std.heap.ArenaAllocator.init(s.gpa), .at_ms = now, .result = undefined };
    errdefer insp.arena.deinit();
    insp.result = try inspect(insp.arena.allocator(), io, cwd);
    const key = try s.gpa.dupe(u8, cwd);
    errdefer s.gpa.free(key);
    try s.cr_inspections.put(s.gpa, key, insp);
    return s.cr_inspections.getPtr(cwd).?;
}

fn clearInspections(s: *watch.State) void {
    var it = s.cr_inspections.iterator();
    while (it.next()) |kv| {
        s.gpa.free(kv.key_ptr.*);
        kv.value_ptr.arena.deinit();
    }
    s.cr_inspections.clearRetainingCapacity();
}

/// Drop every cached lookup (no stream needs them any more).
pub fn clearCaches(s: *watch.State) void {
    clearInspections(s);
    var it = s.cr_cache.iterator();
    while (it.next()) |kv| {
        s.gpa.free(kv.key_ptr.*);
        kv.value_ptr.deinit(s.gpa);
    }
    s.cr_cache.clearRetainingCapacity();
}

pub fn deinitState(s: *watch.State) void {
    clearCaches(s);
    s.cr_inspections.deinit(s.gpa);
    s.cr_cache.deinit(s.gpa);
    for (s.cr_subs.items) |*sub| sub.deinit(s.gpa);
    s.cr_subs.deinit(s.gpa);
}
