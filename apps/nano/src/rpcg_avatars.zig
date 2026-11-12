//! `ResolveGitAvatars` (`crates/engine/src/repos.rs` `history_avatar_urls`,
//! `cache_github_avatar`): Git stores only names and emails, so for a
//! github.com `origin` the History page's commits are looked up once per page
//! through GitHub's commits API, each author's 40px avatar is downloaded once
//! into `{dataDir}/cache/git-avatars/`, and the reply maps each requested
//! author's email to that image (base64). Best effort: anything missing is
//! simply absent.
//!
//! Caches live for the process (Rust keeps them per `Repos`), guarded by the
//! engine lock every RPC holds. `HARNESS_GITHUB_API_URL` replaces
//! `https://api.github.com` (tests point it at a loopback server).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");
const common = @import("rpcw_common.zig");
const g = @import("rpcg_git.zig");
const rpc = @import("rpcg_rpc.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

const github_avatar_timeout_ms: u32 = 6_000;
const max_avatar_bytes: usize = 2 * 1024 * 1024;

const cache_gpa = std.heap.page_allocator;
/// `github_avatar_pages`: pages already fetched (or being fetched).
var pages: std.StringHashMapUnmanaged(void) = .empty;
/// `github_avatars`: `{repo}|sha|{sha}` and `{repo}|email|{email}` → cached file.
var avatars: std.StringHashMapUnmanaged([]u8) = .empty;

/// `parse_github_remote` (repos.rs): github.com only, plain owner/repo names.
pub fn parseGithubRemote(remote_in: []const u8) ?struct { []const u8, []const u8 } {
    const remote = std.mem.trim(u8, remote_in, " \t\r\n");
    var path: []const u8 = undefined;
    inline for (.{ "https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:" }) |prefix| {
        if (std.mem.startsWith(u8, remote, prefix)) {
            path = remote[prefix.len..];
            break;
        }
    } else return null;
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    var it = std.mem.splitScalar(u8, path, '/');
    const owner = it.next() orelse return null;
    const repo = it.next() orelse return null;
    if (it.next() != null or owner.len == 0 or repo.len == 0) return null;
    for (owner) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return null;
    for (repo) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return null;
    return .{ owner, repo };
}

fn lowerTrim(a: Allocator, s: []const u8) ![]u8 {
    return std.ascii.allocLowerString(a, std.mem.trim(u8, s, " \t\r\n"));
}

/// `cache_github_avatar`: the cached image for `url`, downloading it once.
fn cacheAvatar(gpa: Allocator, io: std.Io, data_dir: []const u8, url: []const u8) !?[]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    var hex: [64]u8 = undefined;
    const dir = try std.fs.path.join(gpa, &.{ data_dir, "cache", "git-avatars" });
    defer gpa.free(dir);
    const name = try std.fmt.allocPrint(gpa, "{s}.img", .{g.hexLower(&hex, digest[0..16])});
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    errdefer gpa.free(path);
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.size > 0) return path;
    } else |_| {}
    std.Io.Dir.cwd().createDirPath(io, dir) catch {
        gpa.free(path);
        return null;
    };
    var reply = auth_host.AuthManager.edgeRequestTimed(null, gpa, io, "GET", url, null, &.{}, null, github_avatar_timeout_ms) catch {
        gpa.free(path);
        return null;
    };
    defer reply.deinit(gpa);
    if (reply.status < 200 or reply.status >= 300 or reply.body.len == 0 or reply.body.len > max_avatar_bytes) {
        gpa.free(path);
        return null;
    }
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    var hex8: [16]u8 = undefined;
    const tmp = try std.fmt.allocPrint(gpa, "{s}/.{s}.{s}.tmp", .{ dir, g.hexLower(&hex8, digest[0..8]), std.fmt.bytesToHex(rnd, .lower) });
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = reply.body }) catch {
        gpa.free(path);
        return null;
    };
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        if (!common.isFile(io, path)) {
            gpa.free(path);
            return null;
        }
    };
    return path;
}

fn putAvatar(key: []const u8, path: []const u8) !void {
    const v = try cache_gpa.dupe(u8, path);
    if (avatars.fetchRemove(key)) |old| {
        cache_gpa.free(old.value);
        try avatars.put(cache_gpa, old.key, v);
        return;
    }
    try avatars.put(cache_gpa, try cache_gpa.dupe(u8, key), v);
}

/// `history_avatar_urls`: fetch this page's authors once, then answer from
/// the cache by commit, else by normalized email.
fn avatarPaths(arena: Allocator, io: std.Io, data_dir: []const u8, repo_path: []const u8, authors: []const [2][]const u8, cursor: usize, limit: usize) !std.StringArrayHashMapUnmanaged([]const u8) {
    var out: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const remote = switch (try common.git(arena, io, &.{ "remote", "get-url", "origin" }, repo_path)) {
        .ok => |r| r,
        .failed => return out,
    };
    const owner, const repo = parseGithubRemote(remote) orelse return out;
    const repo_key = try std.ascii.allocLowerString(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ owner, repo }));
    const per_page = std.math.clamp(limit, 1, 100);
    const page = cursor / per_page + 1;
    const page_key = try std.fmt.allocPrint(arena, "{s}|{d}|{d}", .{ repo_key, page, per_page });
    const should_fetch = !pages.contains(page_key);
    if (should_fetch) {
        try pages.put(cache_gpa, try cache_gpa.dupe(u8, page_key), {});
        const base = common.getenvNonEmpty("HARNESS_GITHUB_API_URL") orelse "https://api.github.com";
        const url = try std.fmt.allocPrint(arena, "{s}/repos/{s}/{s}/commits?per_page={d}&page={d}", .{ std.mem.trimEnd(u8, base, "/"), owner, repo, per_page, page });
        const token = common.getenvNonEmpty("GITHUB_TOKEN") orelse common.getenvNonEmpty("GH_TOKEN");
        const rows: ?json.Value = blk: {
            const reply = auth_host.AuthManager.edgeRequestTimed(null, arena, io, "GET", url, token, &.{}, null, github_avatar_timeout_ms) catch break :blk null;
            if (reply.status < 200 or reply.status >= 300) break :blk null;
            const v = json.parseFromSliceLeaky(json.Value, arena, reply.body, .{}) catch break :blk null;
            break :blk if (v == .array) v else null;
        };
        if (rows) |r| {
            // url → identities, so each image downloads once.
            var by_url: std.StringArrayHashMapUnmanaged(std.ArrayList([2][]const u8)) = .empty;
            for (r.array.items) |row| {
                if (row != .object) continue;
                const sha = if (row.object.get("sha")) |s| (if (s == .string) s.string else continue) else continue;
                const author = row.object.get("author") orelse continue;
                if (author != .object) continue;
                const avatar = if (author.object.get("avatar_url")) |a| (if (a == .string) a.string else continue) else continue;
                if (!std.mem.startsWith(u8, avatar, "https://")) continue;
                const commit = row.object.get("commit") orelse continue;
                if (commit != .object) continue;
                const cauthor = commit.object.get("author") orelse continue;
                if (cauthor != .object) continue;
                const email = if (cauthor.object.get("email")) |e| (if (e == .string) e.string else continue) else continue;
                const sized = try std.fmt.allocPrint(arena, "{s}{s}s=40", .{ avatar, if (std.mem.indexOfScalar(u8, avatar, '?') != null) "&" else "?" });
                const gop = try by_url.getOrPut(arena, sized);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, .{ try std.ascii.allocLowerString(arena, sha), try lowerTrim(arena, email) });
            }
            var it = by_url.iterator();
            while (it.next()) |kv| {
                const path = (try cacheAvatar(arena, io, data_dir, kv.key_ptr.*)) orelse continue;
                for (kv.value_ptr.items) |ident| {
                    try putAvatar(try std.fmt.allocPrint(arena, "{s}|sha|{s}", .{ repo_key, ident[0] }), path);
                    if (ident[1].len > 0) try putAvatar(try std.fmt.allocPrint(arena, "{s}|email|{s}", .{ repo_key, ident[1] }), path);
                }
            }
        } else if (pages.fetchRemove(page_key)) |kv| {
            // A transient network or auth failure may be retried on refresh.
            cache_gpa.free(kv.key);
        }
    }
    for (authors) |a| {
        const sha_key = try std.fmt.allocPrint(arena, "{s}|sha|{s}", .{ repo_key, try std.ascii.allocLowerString(arena, a[0]) });
        const email = try lowerTrim(arena, a[1]);
        const email_key = try std.fmt.allocPrint(arena, "{s}|email|{s}", .{ repo_key, email });
        const path = avatars.get(sha_key) orelse avatars.get(email_key) orelse continue;
        try out.put(arena, email, path);
    }
    return out;
}

/// `ResolveGitAvatars { cwd, authors: [{sha, email}], cursor?, limit? }` →
/// `{ "<email>": "<base64 image>" }`.
pub fn resolveGitAvatars(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (rpc.targetProblem(params, host.device_id)) |e| return e;
    if (params != .object) return common.badParams("invalid type: expected struct P", .{});
    const o = params.object;
    const cwd = switch (rpc.strOrFail(o, "cwd", null)) {
        .ok => |s| s,
        .err => |e| return e,
    };
    const authors_v = o.get("authors") orelse return common.badParams("missing field `authors`", .{});
    if (authors_v != .array) return common.badParams("invalid type: expected a sequence for `authors`", .{});
    var cursor: usize = 0;
    var limit: usize = g.history_default_limit;
    inline for (.{ .{ "cursor", &cursor }, .{ "limit", &limit } }) |f| {
        if (o.get(f[0])) |v| switch (v) {
            .integer => |n| {
                if (n < 0) return common.badParams("invalid value: integer `{d}`, expected usize", .{n});
                f[1].* = @intCast(n);
            },
            else => return common.badParams("invalid type: expected usize for `" ++ f[0] ++ "`", .{}),
        };
    }
    var arena_state = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var authors: std.ArrayList([2][]const u8) = .empty;
    for (authors_v.array.items, 0..) |a, i| {
        if (a != .object) return common.badParams("invalid type: expected struct GitAvatarAuthor", .{});
        const sha = switch (rpc.strOrFail(a.object, "sha", null)) {
            .ok => |s| s,
            .err => |e| return e,
        };
        const email = switch (rpc.strOrFail(a.object, "email", null)) {
            .ok => |s| s,
            .err => |e| return e,
        };
        if (i >= g.history_max_limit) continue;
        if (sha.len <= 64 and email.len <= 512) try authors.append(arena, .{ sha, email });
    }
    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    errdefer aw.deinit();
    try aw.writer.writeByte('{');
    if (host.io) |io| if (host.data_dir) |data_dir| {
        var paths = try avatarPaths(arena, io, data_dir, cwd, authors.items, cursor, limit);
        var first = true;
        var it = paths.iterator();
        while (it.next()) |kv| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, kv.value_ptr.*, arena, .limited(max_avatar_bytes + 1)) catch continue;
            const enc = std.base64.standard.Encoder;
            const b64 = try arena.alloc(u8, enc.calcSize(bytes.len));
            _ = enc.encode(b64, bytes);
            if (!first) try aw.writer.writeByte(',');
            first = false;
            try g.writeJsonString(&aw.writer, kv.key_ptr.*);
            try aw.writer.writeByte(':');
            try g.writeJsonString(&aw.writer, b64);
        }
        _ = &paths;
    };
    try aw.writer.writeByte('}');
    return .{ .unary_json = try aw.toOwnedSlice() };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "rpcg_avatars parses only plain github.com remotes" {
    const ok = parseGithubRemote("git@github.com:synthetic-owner/synthetic.repo.git").?;
    try testing.expectEqualStrings("synthetic-owner", ok[0]);
    try testing.expectEqualStrings("synthetic.repo", ok[1]);
    try testing.expect(parseGithubRemote("https://github.com/a/b/c") == null);
    try testing.expect(parseGithubRemote("https://gitlab.com/a/b") == null);
    try testing.expect(parseGithubRemote("https://github.com/a b/c") == null);
    try testing.expect(parseGithubRemote("ssh://git@github.com/a/b") != null);
}

/// One loopback HTTP/1.1 exchange answered with `body`.
const OneShot = struct {
    server: std.Io.net.Server,
    body: []const u8,
    thread: ?std.Thread = null,
    path: [128]u8 = undefined,
    path_len: usize = 0,

    fn run(self: *OneShot) void {
        var stream = self.server.accept(testing.io) catch return;
        defer stream.close(testing.io);
        var rbuf: [4096]u8 = undefined;
        var rd = std.Io.net.Stream.Reader.init(stream, testing.io, &rbuf);
        const first = rd.interface.takeDelimiterInclusive('\n') catch return;
        self.path_len = @min(first.len, self.path.len);
        @memcpy(self.path[0..self.path_len], first[0..self.path_len]);
        while (true) {
            const l = rd.interface.takeDelimiterInclusive('\n') catch return;
            if (std.mem.trim(u8, l, "\r\n").len == 0) break;
        }
        var wbuf: [1024]u8 = undefined;
        var wr = std.Io.net.Stream.Writer.init(stream, testing.io, &wbuf);
        wr.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.body.len, self.body }) catch return;
        wr.interface.flush() catch return;
    }
};

test "rpcg_avatars ResolveGitAvatars maps authors to cached GitHub avatars" {
    if (comptime !std.process.can_spawn) return;
    const Fixture = @import("rpcg_rpc_tests.zig").Fixture;
    const f = try Fixture.init();
    defer f.deinit();
    try f.t.sh("cd repo && git remote add origin git@github.com:synthetic-avatar-owner/synthetic-repo.git");
    const data = try f.path("data");
    try f.host.setDataDir(data);

    // The avatar is already cached, so nothing is downloaded.
    const avatar_url = "https://avatars.example.invalid/u/1?s=40";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(avatar_url, &digest, .{});
    var hex: [64]u8 = undefined;
    try std.Io.Dir.cwd().createDirPath(testing.io, try f.path("data/cache/git-avatars"));
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = try std.fmt.allocPrint(f.arena.allocator(), "{s}/cache/git-avatars/{s}.img", .{ data, g.hexLower(&hex, digest[0..16]) }),
        .data = "SYNTHETIC-IMAGE",
    });

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv: OneShot = .{
        .server = try addr.listen(testing.io, .{ .reuse_address = true }),
        .body = "[{\"sha\":\"ABC123\",\"author\":{\"avatar_url\":\"https://avatars.example.invalid/u/1\"},\"commit\":{\"author\":{\"email\":\" Dev@Example.Invalid \"}}}," ++
            "{\"sha\":\"def\",\"author\":null,\"commit\":{\"author\":{\"email\":\"x@example.invalid\"}}}]",
    };
    srv.thread = try std.Thread.spawn(.{}, OneShot.run, .{&srv});
    defer {
        if (srv.thread) |t| t.join();
        srv.server.deinit(testing.io);
    }
    try f.t.env.map.put("HARNESS_GITHUB_API_URL", try std.fmt.allocPrint(f.arena.allocator(), "http://127.0.0.1:{d}", .{srv.server.socket.address.getPort()}));

    const P = "{{\"cwd\":\"{s}\",\"authors\":[{{\"sha\":\"abc123\",\"email\":\"someone-else@example.invalid\"}},{{\"sha\":\"zzz\",\"email\":\"dev@example.invalid\"}},{{\"sha\":\"def\",\"email\":\"x@example.invalid\"}}],\"limit\":30}}";
    const got = try f.ok("ResolveGitAvatars", try f.params(P, .{f.t.repo}));
    try testing.expectEqualStrings("U1lOVEhFVElDLUlNQUdF", got.object.get("someone-else@example.invalid").?.string);
    try testing.expectEqualStrings("U1lOVEhFVElDLUlNQUdF", got.object.get("dev@example.invalid").?.string);
    try testing.expect(got.object.get("x@example.invalid") == null);
    try testing.expect(std.mem.startsWith(u8, srv.path[0..srv.path_len], "GET /repos/synthetic-avatar-owner/synthetic-repo/commits?per_page=30&page=1 HTTP/1.1"));
    // The page is not fetched again: answered from the cache.
    const again = try f.ok("ResolveGitAvatars", try f.params(P, .{f.t.repo}));
    try testing.expectEqual(@as(usize, 2), again.object.count());

    try testing.expectEqualStrings("missing field `authors`", try f.err("ResolveGitAvatars", try f.params("{{\"cwd\":\"{s}\"}}", .{f.t.repo})));
    try testing.expectEqualStrings("missing field `cwd`", try f.err("ResolveGitAvatars", try f.params("{{\"authors\":[]}}", .{})));
    try f.t.sh("cd repo && git remote set-url origin /srv/synthetic.git");
    const none = try f.ok("ResolveGitAvatars", try f.params(P, .{f.t.repo}));
    try testing.expectEqual(@as(usize, 0), none.object.count());
}
