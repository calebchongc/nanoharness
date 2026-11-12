//! graff's checksummed GitHub release into `~/.harness/bin/graff`, ported
//! from `crates/harness/src/graff_bundle.rs` (`update_managed`,
//! `update_managed_beta`, `install_release`, `install_unpacked_release`,
//! `install_file`, `replace_file_with`, `expected_sha`, `parse_dotted`,
//! `installed_beta_tag`, `current_is_at_least_target`) and
//! `crates/harness/src/graff_beta.rs` (the newest published beta of the
//! newest numeric release branch).
//!
//! Integrity is Rust's: the tarball's SHA-256 must equal the line for its
//! asset in the same release's `SHA256SUMS` before anything is unpacked, and
//! the unpacked binary must run (`--version`) before it replaces the managed
//! copy (copy beside it, chmod 755, rename over it).
//!
//! Not ported: nanocua.app placement (`nanocua_bundle::install`/`seed`,
//! graff_bundle.rs:612-624, 630-637) and `codedb_bundle::maybe_check_soon`
//! (graff_bundle.rs:569).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const net = @import("harness_install_net.zig");
const harness_version = @import("harness_version.zig");

const Failure = net.Failure;
const Error = net.Error;
const fail = net.fail;

/// `RELEASES`; tests point it at a loopback server.
pub var releases_base: []const u8 = "https://github.com/justrach/codegraff/releases/download";
/// graff_beta.rs `API` (also the base of `LATEST_RELEASE`); tests point it at
/// a loopback server.
pub var api_base: []const u8 = "https://api.github.com/repos/justrach/codegraff";

const max_tarball_bytes: usize = 256 * 1024 * 1024;
/// reqwest's `.text()`/`.json()` are unbounded; these bodies are small.
const max_api_bytes: usize = 32 * 1024 * 1024;
const user_agent = "harness-graff-updater";
const accept_json = "application/vnd.github+json";

/// `UPDATE_LOCK`: one release install at a time per process.
var update_lock: Io.Mutex = .init;

/// graff's executable name on this platform.
pub const graff_exe = if (builtin.os.tag == .windows) "graff.exe" else "graff";

// ── versions ───────────────────────────────────────────────────────────────

/// `parse_dotted`'s `Vec<u64>`, compared element-wise.
pub const Dotted = struct {
    parts: [16]u64 = undefined,
    len: usize = 0,

    pub fn slice(d: *const Dotted) []const u64 {
        return d.parts[0..d.len];
    }

    pub fn order(a: Dotted, b: Dotted) std.math.Order {
        return std.mem.order(u64, a.slice(), b.slice());
    }

    /// `display_version`: the parts joined by `.`.
    pub fn format(d: Dotted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (d.slice(), 0..) |p, i| {
            if (i > 0) try w.writeByte('.');
            try w.print("{d}", .{p});
        }
    }
};

/// Rust's `u64::from_str`: an optional `+`, then decimal digits only.
fn parseU64(text: []const u8) ?u64 {
    const digits = if (text.len > 0 and text[0] == '+') text[1..] else text;
    if (digits.len == 0) return null;
    var v: u64 = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    return v;
}

const whitespace = " \t\r\n\x0b\x0c";

/// `parse_dotted`: the first whitespace-separated word that, without leading
/// `v`s and anything from the first `-`, is three or more `.`-separated numbers.
pub fn parseDotted(text: []const u8) ?Dotted {
    var words = std.mem.tokenizeAny(u8, text, whitespace);
    outer: while (words.next()) |word| {
        const trimmed = std.mem.trimStart(u8, word, "v");
        const head = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '-') orelse trimmed.len];
        var d: Dotted = .{};
        var parts = std.mem.splitScalar(u8, head, '.');
        while (parts.next()) |p| {
            const n = parseU64(p) orelse continue :outer;
            if (d.len == d.parts.len) continue :outer;
            d.parts[d.len] = n;
            d.len += 1;
        }
        if (d.len >= 3) return d;
    }
    return null;
}

/// graff_beta.rs `numeric_version`: three or four numbers, zero-filled.
pub fn numericVersion(text: []const u8) ?[4]u64 {
    if (std.mem.count(u8, text, ".") + 1 < 3 or std.mem.count(u8, text, ".") + 1 > 4) return null;
    var v: [4]u64 = @splat(0);
    var parts = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (parts.next()) |p| : (i += 1) v[i] = parseU64(p) orelse return null;
    return v;
}

fn splitOnce(text: []const u8, sep: []const u8) ?[2][]const u8 {
    const at = std.mem.indexOf(u8, text, sep) orelse return null;
    return .{ text[0..at], text[at + sep.len ..] };
}

const Run = struct { run: u64, attempt: u64 };

/// graff_beta.rs `beta_run`: `v{branch}-beta.{run}.{attempt}` for `branch`.
fn betaRun(tag: []const u8, branch: [4]u64) ?Run {
    if (!std.mem.startsWith(u8, tag, "v")) return null;
    const halves = splitOnce(tag[1..], "-beta.") orelse return null;
    const version = numericVersion(halves[0]) orelse return null;
    if (!std.mem.eql(u64, &version, &branch)) return null;
    const ra = splitOnce(halves[1], ".") orelse return null;
    return .{ .run = parseU64(ra[0]) orelse return null, .attempt = parseU64(ra[1]) orelse return null };
}

pub const BetaKey = struct {
    branch: [4]u64,
    run: u64,
    attempt: u64,

    pub fn order(a: BetaKey, b: BetaKey) std.math.Order {
        const o = std.mem.order(u64, &a.branch, &b.branch);
        if (o != .eq) return o;
        if (a.run != b.run) return std.math.order(a.run, b.run);
        return std.math.order(a.attempt, b.attempt);
    }
};

/// graff_beta.rs `beta_key`.
pub fn betaKey(tag: []const u8) ?BetaKey {
    if (!std.mem.startsWith(u8, tag, "v")) return null;
    const halves = splitOnce(tag[1..], "-beta.") orelse return null;
    const branch = numericVersion(halves[0]) orelse return null;
    const r = betaRun(tag, branch) orelse return null;
    return .{ .branch = branch, .run = r.run, .attempt = r.attempt };
}

/// `Option<T>`'s ordering: `None` sorts first.
fn optAtLeast(a: ?BetaKey, b: ?BetaKey) bool {
    if (b == null) return true;
    if (a == null) return false;
    return a.?.order(b.?) != .lt;
}

/// `current_is_at_least_target`.
pub fn currentIsAtLeastTarget(current: ?Dotted, current_beta: ?[]const u8, target: Dotted, target_beta: ?[]const u8) bool {
    if (target_beta) |tb| {
        if (current_beta) |cb| return optAtLeast(betaKey(cb), betaKey(tb));
        return if (current) |c| c.order(target) != .lt else false;
    }
    return current_beta == null and (if (current) |c| c.order(target) != .lt else false);
}

/// `expected_sha`: the 64-character digest on the line naming exactly `asset`
/// (a leading `*` on the name is binary-mode notation), lowercased.
pub fn expectedSha(sums: []const u8, asset: []const u8) ?[64]u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, whitespace);
        const sha = fields.next() orelse continue;
        const name = std.mem.trimStart(u8, fields.next() orelse continue, "*");
        if (std.mem.eql(u8, name, asset) and sha.len == 64) {
            var out: [64]u8 = undefined;
            _ = std.ascii.lowerString(&out, sha);
            return out;
        }
    }
    return null;
}

/// `asset_name`: codegraff's release asset for this machine.
pub fn assetName() ?[]const u8 {
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return null,
    };
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };
    return "graff-" ++ arch ++ "-" ++ os ++ ".tar.gz";
}

// ── the binaries on disk ───────────────────────────────────────────────────

/// `managed_path`: `~/.harness/bin/graff` (owned), whether or not it exists.
pub fn managedPath(gpa: Allocator, env: *const Environ.Map) Allocator.Error!?[]u8 {
    const home = net.homeDir(env) orelse return null;
    return try std.fs.path.join(gpa, &.{ home, ".harness", "bin", graff_exe });
}

/// `path --version`'s stdout, with HARNESS_BUILD_WAIT_DIR removed and stdin
/// null; null when it can't be spawned. `success` reports a zero exit.
fn runVersion(gpa: Allocator, io: Io, env: *const Environ.Map, path: []const u8) error{Canceled}!?struct { out: []u8, success: bool } {
    if (comptime !std.process.can_spawn) return null;
    var child_env = env.clone(gpa) catch return null;
    defer child_env.deinit();
    _ = child_env.swapRemove("HARNESS_BUILD_WAIT_DIR");
    const res = std.process.run(gpa, io, .{
        .argv = &.{ path, "--version" },
        .environ_map = &child_env,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch |e| {
        if (e == error.Canceled) return error.Canceled;
        return null;
    };
    gpa.free(res.stderr);
    return .{ .out = res.stdout, .success = res.term == .exited and res.term.exited == 0 };
}

/// `version_of`.
pub fn versionOf(gpa: Allocator, io: Io, env: *const Environ.Map, path: []const u8) error{Canceled}!?Dotted {
    const r = (try runVersion(gpa, io, env, path)) orelse return null;
    defer gpa.free(r.out);
    return parseDotted(r.out);
}

/// `installed_beta_tag` (owned): the `v…-beta.N.M` tag the binary reports.
pub fn installedBetaTag(gpa: Allocator, io: Io, env: *const Environ.Map, path: []const u8) Error!?[]u8 {
    if (!net.isFile(io, path)) return null;
    const r = (try runVersion(gpa, io, env, path)) orelse return null;
    defer gpa.free(r.out);
    if (!r.success) return null;
    var words = std.mem.tokenizeAny(u8, r.out, whitespace);
    while (words.next()) |word| {
        const tag = try std.fmt.allocPrint(gpa, "v{s}", .{std.mem.trimStart(u8, word, "v")});
        if (betaKey(tag) != null) return tag;
        gpa.free(tag);
    }
    return null;
}

/// `install_file`: copy beside the target, mark it executable, rename it over
/// the target, so a running `graff acp` keeps its (unlinked) inode.
pub fn installFile(gpa: Allocator, io: Io, source: []const u8, target: []const u8) anyerror!void {
    const dir = std.fs.path.dirname(target).?;
    try Io.Dir.cwd().createDirPath(io, dir);
    var id_buf: [36]u8 = undefined;
    const name = try std.fmt.allocPrint(gpa, ".graff.{s}.tmp", .{net.uuid(io, &id_buf)});
    defer gpa.free(name);
    const staged = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(staged);
    errdefer Io.Dir.cwd().deleteFile(io, staged) catch {};
    try Io.Dir.copyFile(Io.Dir.cwd(), source, Io.Dir.cwd(), staged, io, .{});
    if (!net.is_windows) try Io.Dir.cwd().setFilePermissions(io, staged, .fromMode(0o755), .{});
    try replaceFileWith(gpa, io, staged, target, net.is_windows);
}

/// `replace_file_with`: rename `staged` over `target`. With `move_aside`
/// (Windows, which refuses to replace a running executable but lets it be
/// renamed), the old binary moves to `{name}.old-{uuid}` first and comes back
/// if the swap fails; older moved-aside copies are cleared.
pub fn replaceFileWith(gpa: Allocator, io: Io, staged: []const u8, target: []const u8, move_aside: bool) anyerror!void {
    const cwd = Io.Dir.cwd();
    if (!move_aside or !net.pathExists(io, target)) return Io.Dir.rename(cwd, staged, cwd, target, io);
    const dir_path = std.fs.path.dirname(target).?;
    const name = std.fs.path.basename(target);
    const prefix = try std.fmt.allocPrint(gpa, "{s}.old-", .{name});
    defer gpa.free(prefix);
    if (cwd.openDir(io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io);
        var stale: std.ArrayList([]u8) = .empty;
        defer {
            for (stale.items) |s| gpa.free(s);
            stale.deinit(gpa);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (std.mem.startsWith(u8, e.name, prefix)) try stale.append(gpa, try gpa.dupe(u8, e.name));
        }
        for (stale.items) |s| dir.deleteFile(io, s) catch {};
    } else |_| {}
    var id_buf: [36]u8 = undefined;
    const aside_name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, net.uuid(io, &id_buf) });
    defer gpa.free(aside_name);
    const aside = try std.fs.path.join(gpa, &.{ dir_path, aside_name });
    defer gpa.free(aside);
    try Io.Dir.rename(cwd, target, cwd, aside, io);
    Io.Dir.rename(cwd, staged, cwd, target, io) catch |e| {
        Io.Dir.rename(cwd, aside, cwd, target, io) catch {};
        return e;
    };
    cwd.deleteFile(io, aside) catch {};
}

// ── outcomes ───────────────────────────────────────────────────────────────

/// `UpdateOutcome` (owned strings).
pub const Outcome = union(enum) {
    updated: struct { from: ?[]u8, to: []u8 },
    already_current: []u8,

    pub fn deinit(o: Outcome, gpa: Allocator) void {
        switch (o) {
            .updated => |u| {
                if (u.from) |f| gpa.free(f);
                gpa.free(u.to);
            },
            .already_current => |v| gpa.free(v),
        }
    }
};

fn display(gpa: Allocator, d: Dotted) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{f}", .{d});
}

/// `install_unpacked_release` (without nanocua placement).
pub fn installUnpacked(gpa: Allocator, io: Io, env: *const Environ.Map, binary: []const u8, managed: []const u8, tag: []const u8, beta: bool, allow_channel_switch: bool) Error!net.Result(Outcome) {
    const fetched = (try versionOf(gpa, io, env, binary)) orelse
        return .{ .err = try fail(gpa, .bare, "the downloaded graff didn't run", .{}) };
    if (beta) {
        const got = try installedBetaTag(gpa, io, env, binary);
        defer if (got) |g| gpa.free(g);
        if (got == null or !std.mem.eql(u8, got.?, tag))
            return .{ .err = try fail(gpa, .bare, "downloaded graff version does not match {s}", .{tag}) };
    }
    // Recheck after the download so overlapping manual and automatic updates
    // cannot replace a newer managed copy with an older one.
    const current = try versionOf(gpa, io, env, managed);
    const old_beta = try installedBetaTag(gpa, io, env, managed);
    var old_beta_owned = old_beta != null;
    defer if (old_beta_owned) gpa.free(old_beta.?);
    if (!beta and !allow_channel_switch) if (old_beta) |ob| {
        old_beta_owned = false;
        return .{ .ok = .{ .already_current = ob } };
    };
    if (beta and currentIsAtLeastTarget(current, old_beta, fetched, tag)) {
        if (old_beta) |ob| {
            old_beta_owned = false;
            return .{ .ok = .{ .already_current = ob } };
        }
        return .{ .err = try fail(gpa, .bare, "the installed stable Graff is at least as new as the available beta", .{}) };
    }
    if (!beta and currentIsAtLeastTarget(current, old_beta, fetched, null)) {
        return .{ .ok = .{ .already_current = try display(gpa, current orelse fetched) } };
    }
    installFile(gpa, io, binary, managed) catch |e| return .{ .err = (try net.ioFailure(gpa, e)).rekind(.bare) };
    const from = if (current) |c| try display(gpa, c) else null;
    errdefer if (from) |f| gpa.free(f);
    const to = if (beta) try gpa.dupe(u8, tag) else try display(gpa, fetched);
    return .{ .ok = .{ .updated = .{ .from = from, .to = to } } };
}

// ── release lookup ─────────────────────────────────────────────────────────

fn decodeError(gpa: Allocator, err: anyerror) Allocator.Error!Failure {
    return fail(gpa, .bare, "error decoding response body: {s}", .{@errorName(err)});
}

/// `latest_stable_release`: `/releases/latest`'s tag (owned), which must be
/// `v` plus three or four numbers.
fn latestStableRelease(gpa: Allocator, http: *net.Http) Error!net.Result([]u8) {
    const url = try std.fmt.allocPrint(gpa, "{s}/releases/latest", .{api_base});
    defer gpa.free(url);
    const body = switch (try http.getAll(url, accept_json, max_api_bytes)) {
        .ok => |b| b,
        .err => |f| return .{ .err = f },
    };
    defer gpa.free(body);
    const parsed = std.json.parseFromSlice(struct { tag_name: []const u8 }, gpa, body, .{ .ignore_unknown_fields = true }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .{ .err = try decodeError(gpa, e) };
    };
    defer parsed.deinit();
    const tag = parsed.value.tag_name;
    if (parseDotted(tag) == null or !std.mem.startsWith(u8, tag, "v") or numericVersion(tag[1..]) == null)
        return .{ .err = try fail(gpa, .bare, "CodeGraff release has an invalid stable version tag", .{}) };
    return .{ .ok = try gpa.dupe(u8, tag) };
}

/// graff_beta.rs `latest_branch`.
pub fn latestBranch(refs: []const []const u8) ?[4]u64 {
    var best: ?[4]u64 = null;
    for (refs) |r| {
        if (!std.mem.startsWith(u8, r, "refs/heads/release/v")) continue;
        const v = numericVersion(r["refs/heads/release/v".len..]) orelse continue;
        if (best == null or std.mem.order(u64, &v, &best.?) != .lt) best = v;
    }
    return best;
}

pub const Release = struct {
    tag_name: []const u8,
    prerelease: bool,
    draft: bool,
    published_at: ?[]const u8 = null,
};

/// graff_beta.rs `latest_published_beta`: the published, non-draft
/// prerelease of `branch` with the highest (run, attempt); the last of equals.
pub fn latestPublishedBeta(releases: []const Release, branch: [4]u64) ?[]const u8 {
    var best: ?struct { run: Run, tag: []const u8 } = null;
    for (releases) |r| {
        if (!(r.prerelease and !r.draft and r.published_at != null)) continue;
        const run = betaRun(r.tag_name, branch) orelse continue;
        if (best == null or !runLess(run, best.?.run)) best = .{ .run = run, .tag = r.tag_name };
    }
    return if (best) |b| b.tag else null;
}

fn runLess(a: Run, b: Run) bool {
    if (a.run != b.run) return a.run < b.run;
    return a.attempt < b.attempt;
}

/// graff_beta.rs `latest_tag` (owned).
fn latestBetaTag(gpa: Allocator, http: *net.Http) Error!net.Result([]u8) {
    const refs_url = try std.fmt.allocPrint(gpa, "{s}/git/matching-refs/heads/release/v", .{api_base});
    defer gpa.free(refs_url);
    const refs_body = switch (try http.getAll(refs_url, accept_json, max_api_bytes)) {
        .ok => |b| b,
        .err => |f| return .{ .err = f },
    };
    defer gpa.free(refs_body);
    const GitRef = struct { ref: []const u8 };
    const refs = std.json.parseFromSlice([]GitRef, gpa, refs_body, .{ .ignore_unknown_fields = true }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .{ .err = try decodeError(gpa, e) };
    };
    defer refs.deinit();
    const names = try gpa.alloc([]const u8, refs.value.len);
    defer gpa.free(names);
    for (refs.value, 0..) |r, i| names[i] = r.ref;
    const branch = latestBranch(names) orelse
        return .{ .err = try fail(gpa, .bare, "no numeric Codegraff release branch found", .{}) };
    var newest: ?struct { run: Run, tag: []u8 } = null;
    errdefer if (newest) |n| gpa.free(n.tag);
    var complete = false;
    var page: usize = 1;
    while (page <= 10) : (page += 1) {
        const url = try std.fmt.allocPrint(gpa, "{s}/releases?per_page=100&page={d}", .{ api_base, page });
        defer gpa.free(url);
        const body = switch (try http.getAll(url, accept_json, max_api_bytes)) {
            .ok => |b| b,
            .err => |f| {
                if (newest) |n| gpa.free(n.tag);
                return .{ .err = f };
            },
        };
        defer gpa.free(body);
        const releases = std.json.parseFromSlice([]Release, gpa, body, .{ .ignore_unknown_fields = true }) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            if (newest) |n| gpa.free(n.tag);
            return .{ .err = try decodeError(gpa, e) };
        };
        defer releases.deinit();
        if (latestPublishedBeta(releases.value, branch)) |tag| {
            const run = betaRun(tag, branch).?;
            if (newest == null or runLess(newest.?.run, run)) {
                const copy = try gpa.dupe(u8, tag);
                if (newest) |n| gpa.free(n.tag);
                newest = .{ .run = run, .tag = copy };
            }
        }
        if (releases.value.len < 100) {
            complete = true;
            break;
        }
    }
    if (!complete) {
        if (newest) |n| gpa.free(n.tag);
        return .{ .err = try fail(gpa, .bare, "too many Codegraff releases to select a beta safely", .{}) };
    }
    const n = newest orelse return .{ .err = try fail(gpa, .bare, "the newest Codegraff release branch has no published beta", .{}) };
    return .{ .ok = n.tag };
}

// ── install ────────────────────────────────────────────────────────────────

/// `install_release`: verify the tarball against the release's SHA256SUMS,
/// unpack it with `tar`, and hand its graff to `installUnpacked`.
fn installRelease(gpa: Allocator, io: Io, env: *const Environ.Map, http: *net.Http, tag: []const u8, beta: bool, allow_channel_switch: bool) Error!net.Result(Outcome) {
    update_lock.lock(io) catch return error.Canceled;
    defer update_lock.unlock(io);
    const managed = (try managedPath(gpa, env)) orelse return .{ .err = try fail(gpa, .bare, "no home directory", .{}) };
    defer gpa.free(managed);
    if (!beta and !allow_channel_switch) {
        if (try installedBetaTag(gpa, io, env, managed)) |t| return .{ .ok = .{ .already_current = t } };
    }
    const asset = assetName() orelse return .{ .err = try fail(gpa, .bare, "no graff build for this platform", .{}) };
    const sums_url = try std.fmt.allocPrint(gpa, "{s}/{s}/SHA256SUMS", .{ releases_base, tag });
    defer gpa.free(sums_url);
    const sums = switch (try http.getAll(sums_url, null, max_api_bytes)) {
        .ok => |b| b,
        .err => |f| return .{ .err = f },
    };
    defer gpa.free(sums);
    const expected = expectedSha(sums, asset) orelse
        return .{ .err = try fail(gpa, .bare, "{s} is missing from the release's SHA256SUMS", .{asset}) };

    const asset_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ releases_base, tag, asset });
    defer gpa.free(asset_url);
    const body = switch (try http.get(asset_url, null)) {
        .ok => |b| b,
        .err => |f| return .{ .err = f },
    };
    var tarball: std.ArrayList(u8) = .empty;
    defer tarball.deinit(gpa);
    {
        defer body.destroy();
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = switch (try body.read(&chunk)) {
                .ok => |n| n,
                .err => |f| return .{ .err = f },
            };
            if (n == 0) break;
            if (tarball.items.len +| n > max_tarball_bytes)
                return .{ .err = try fail(gpa, .bare, "graff download is unexpectedly large", .{}) };
            try tarball.appendSlice(gpa, chunk[0..n]);
        }
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball.items, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, &expected))
        return .{ .err = try fail(gpa, .bare, "checksum mismatch for {s} (expected {s}, got {s})", .{ asset, &expected, &actual }) };

    const parent = std.fs.path.dirname(managed).?;
    Io.Dir.cwd().createDirPath(io, parent) catch |e| return .{ .err = (try net.ioFailure(gpa, e)).rekind(.bare) };
    var id_buf: [36]u8 = undefined;
    const work_name = try std.fmt.allocPrint(gpa, ".graff-update.{s}", .{net.uuid(io, &id_buf)});
    defer gpa.free(work_name);
    const work = try std.fs.path.join(gpa, &.{ parent, work_name });
    defer gpa.free(work);
    Io.Dir.cwd().createDirPath(io, work) catch |e| return .{ .err = (try net.ioFailure(gpa, e)).rekind(.bare) };
    defer net.removeTree(io, work);

    const archive = try std.fs.path.join(gpa, &.{ work, asset });
    defer gpa.free(archive);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = archive, .data = tarball.items }) catch |e| return .{ .err = (try net.ioFailure(gpa, e)).rekind(.bare) };
    switch (try untar(gpa, io, env, archive, work)) {
        .ok => |success| if (!success) return .{ .err = try fail(gpa, .bare, "couldn't unpack {s}", .{asset}) },
        .err => |f| return .{ .err = f },
    }
    // Release tarballs nest `graff-<target>/graff`; hand-repacked ones put it
    // at the root.
    const nested = try std.fs.path.join(gpa, &.{ work, asset[0 .. asset.len - ".tar.gz".len], graff_exe });
    defer gpa.free(nested);
    const root = try std.fs.path.join(gpa, &.{ work, graff_exe });
    defer gpa.free(root);
    const binary = if (net.isFile(io, nested)) nested else root;
    if (!net.isFile(io, binary)) return .{ .err = try fail(gpa, .bare, "{s} has no graff binary", .{asset}) };
    const outcome = try installUnpacked(gpa, io, env, binary, managed, tag, beta, allow_channel_switch);
    if (outcome == .ok and outcome.ok == .updated) harness_version.invalidateVersions(io, &.{"graff"});
    return outcome;
}

/// `tar -xzf {archive} -C {dir}`'s success; `tar` from PATH.
fn untar(gpa: Allocator, io: Io, env: *const Environ.Map, archive: []const u8, dir: []const u8) Error!net.Result(bool) {
    if (comptime !std.process.can_spawn) return .{ .err = try fail(gpa, .bare, "unsupported platform", .{}) };
    const agent_proc = @import("agent_proc.zig");
    const found = agent_proc.findExecutable(gpa, io, .{ .name = "tar", .path_env = env.get("PATH"), .home = null }) catch null;
    defer if (found) |f| gpa.free(f);
    var child = std.process.spawn(io, .{
        .argv = &.{ found orelse "tar", "-xzf", archive, "-C", dir },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |e| return .{ .err = (try net.ioFailure(gpa, e)).rekind(.bare) };
    const term = child.wait(io) catch |e| {
        child.kill(io);
        return .{ .err = (try net.ioFailure(gpa, e)).rekind(.bare) };
    };
    return .{ .ok = term == .exited and term.exited == 0 };
}

/// `update_managed`: the latest stable release, verified, into the managed
/// copy (a beta channel switches back to stable). Failures are `anyhow`
/// texts (`Failure.kind == .bare`).
pub fn updateManaged(gpa: Allocator, io: Io) Error!net.Result(Outcome) {
    var env = try net.currentEnv(gpa);
    defer env.deinit();
    var http: net.Http = undefined;
    http.init(gpa, io, &env, user_agent);
    defer http.deinit();
    const tag = switch (try latestStableRelease(gpa, &http)) {
        .ok => |t| t,
        .err => |f| return .{ .err = f },
    };
    defer gpa.free(tag);
    return installRelease(gpa, io, &env, &http, tag, false, true);
}

/// `update_managed_beta`: opt in to the newest published beta of the newest
/// release branch.
pub fn updateManagedBeta(gpa: Allocator, io: Io) Error!net.Result(Outcome) {
    var env = try net.currentEnv(gpa);
    defer env.deinit();
    if (net.getNonEmpty(&env, "GRAFF_EXECUTABLE") != null)
        return .{ .err = try fail(gpa, .bare, "a custom Graff executable is selected; unset GRAFF_EXECUTABLE to use the managed beta", .{}) };
    var http: net.Http = undefined;
    http.init(gpa, io, &env, user_agent);
    defer http.deinit();
    const tag = switch (try latestBetaTag(gpa, &http)) {
        .ok => |t| t,
        .err => |f| return .{ .err = f },
    };
    defer gpa.free(tag);
    return installRelease(gpa, io, &env, &http, tag, true, true);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn dotted(text: []const u8) Dotted {
    return parseDotted(text).?;
}

test "graff dotted versions parse, compare all parts and display like Rust" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualSlices(u64, &.{ 0, 0, 302, 4 }, dotted("v0.0.302.4").slice());
    try testing.expectEqualStrings("0.0.302.4", try std.fmt.bufPrint(&buf, "{f}", .{dotted("v0.0.302.4")}));
    try testing.expectEqualSlices(u64, &.{ 0, 0, 302, 6 }, dotted("v0.0.302.6-beta.26.1").slice());
    const current = dotted("graff 0.0.302.4\n\nWhat's new");
    try testing.expectEqual(std.math.Order.gt, dotted("graff 0.0.302.10").order(current));
    try testing.expectEqual(std.math.Order.gt, dotted("graff 0.0.303.0").order(current));
    try testing.expect(parseDotted("no version here") == null);
    try testing.expect(parseDotted("1.2") == null);
    try testing.expect(parseDotted("1_0.2.3") == null);
    // numeric_version accepts three or four parts.
    try testing.expectEqualSlices(u64, &.{ 0, 0, 303, 0 }, &numericVersion("0.0.303").?);
    try testing.expect(numericVersion("0.0.303.1.2") == null);
    try testing.expect(numericVersion("0.0") == null);
}

test "graff beta branch and release selection are numeric" {
    const branch = latestBranch(&.{ "refs/heads/release/v0.0.302.9", "refs/heads/release/v0.0.302.10", "refs/heads/release/v0.0.303", "refs/heads/release/v0.0.303.0" }).?;
    try testing.expectEqualSlices(u64, &.{ 0, 0, 303, 0 }, &branch);
    const releases = [_]Release{
        .{ .tag_name = "v0.0.303-beta.9.2", .prerelease = true, .draft = false, .published_at = "now" },
        .{ .tag_name = "v0.0.303-beta.10.1", .prerelease = true, .draft = false, .published_at = "now" },
        .{ .tag_name = "v0.0.303-beta.11.1", .prerelease = true, .draft = true, .published_at = "now" },
        .{ .tag_name = "v0.0.303-beta.12.1", .prerelease = true, .draft = false, .published_at = null },
        .{ .tag_name = "v0.0.302.10-beta.99.1", .prerelease = true, .draft = false, .published_at = "now" },
    };
    try testing.expectEqualStrings("v0.0.303-beta.10.1", latestPublishedBeta(&releases, branch).?);
    try testing.expect(betaRun("v0.0.303-beta.10.1-extra", branch) == null);
}

test "graff beta updates never downgrade a stable or a newer beta" {
    const stable = dotted("0.0.302.6");
    const previous = dotted("0.0.302.5");
    const target = "v0.0.302.6-beta.26.1";
    try testing.expect(currentIsAtLeastTarget(stable, null, stable, target));
    try testing.expect(!currentIsAtLeastTarget(previous, null, stable, target));
    try testing.expect(currentIsAtLeastTarget(stable, "v0.0.302.6-beta.27.1", stable, target));
    try testing.expect(!currentIsAtLeastTarget(stable, "v0.0.302.6-beta.25.1", stable, target));
    try testing.expect(!currentIsAtLeastTarget(stable, target, stable, null));
    try testing.expect(!currentIsAtLeastTarget(null, null, stable, null));
}

test "graff checksum lines match the exact asset" {
    const sums = "aa  graff-x86_64-macos.tar.gz\n" ++
        "A80B48C5F8DDF124A5C679C475819A506DFDC5AD8F47B76DB9AACC2A2FFF1268  *graff-aarch64-macos.tar.gz\r\n";
    try testing.expectEqualStrings("a80b48c5f8ddf124a5c679c475819a506dfdc5ad8f47b76db9aacc2a2fff1268", &expectedSha(sums, "graff-aarch64-macos.tar.gz").?);
    try testing.expect(expectedSha(sums, "graff-x86_64-macos.tar.gz") == null);
    try testing.expect(expectedSha(sums, "graff-aarch64-linux.tar.gz") == null);
}

test "graff install replaces atomically, marks executable, and the Windows swap moves the old binary aside" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    try tmp.dir.writeFile(io, .{ .sub_path = "src", .data = "new" });
    const src = try std.fs.path.join(gpa, &.{ base, "src" });
    defer gpa.free(src);
    const target = try std.fs.path.join(gpa, &.{ base, "bin", "graff" });
    defer gpa.free(target);
    try installFile(gpa, io, src, target);
    const text = try tmp.dir.readFileAlloc(io, "bin/graff", gpa, .limited(64));
    defer gpa.free(text);
    try testing.expectEqualStrings("new", text);
    if (!net.is_windows) {
        const st = try tmp.dir.statFile(io, "bin/graff", .{});
        try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
    }
    // The move-aside swap, as Windows runs it.
    try tmp.dir.createDirPath(io, "w");
    try tmp.dir.writeFile(io, .{ .sub_path = "w/graff.exe", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w/graff.exe.old-earlier", .data = "older" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w/staged", .data = "new" });
    const wt = try std.fs.path.join(gpa, &.{ base, "w", "graff.exe" });
    defer gpa.free(wt);
    const ws = try std.fs.path.join(gpa, &.{ base, "w", "staged" });
    defer gpa.free(ws);
    try replaceFileWith(gpa, io, ws, wt, true);
    var dir = try tmp.dir.openDir(io, "w", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var names: usize = 0;
    while (try it.next(io)) |e| {
        names += 1;
        try testing.expectEqualStrings("graff.exe", e.name);
    }
    try testing.expectEqual(@as(usize, 1), names);
    // A failed swap puts the old binary back.
    const missing = try std.fs.path.join(gpa, &.{ base, "w", "not-there" });
    defer gpa.free(missing);
    try testing.expectError(error.FileNotFound, replaceFileWith(gpa, io, missing, wt, true));
    const back = try dir.readFileAlloc(io, "graff.exe", gpa, .limited(64));
    defer gpa.free(back);
    try testing.expectEqualStrings("new", back);
}

/// A synthetic HOME/PATH environment installed as `catalog_core.env_override`.
pub const Rig = struct {
    tmp: testing.TmpDir,
    base: [:0]u8,
    home: []u8,
    env: Environ.Map,

    pub fn init(rig: *Rig) !void {
        const gpa = testing.allocator;
        rig.tmp = testing.tmpDir(.{});
        rig.base = try rig.tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        rig.home = try std.fs.path.join(gpa, &.{ rig.base, "home" });
        try rig.tmp.dir.createDirPath(testing.io, "home");
        rig.env = Environ.Map.init(gpa);
        try rig.env.put("HOME", rig.home);
        try rig.env.put("PATH", "/usr/bin:/bin");
        net.setEnvOverride(&rig.env);
    }

    pub fn deinit(rig: *Rig) void {
        net.setEnvOverride(null);
        rig.env.deinit();
        testing.allocator.free(rig.home);
        testing.allocator.free(rig.base);
        rig.tmp.cleanup();
    }

    pub fn path(rig: *const Rig, sub: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ rig.base, sub });
    }

    pub fn exists(rig: *Rig, sub: []const u8) bool {
        rig.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }
};

/// A release tarball (`graff-<target>/graff`) whose graff prints `version_line`.
fn makeTarball(rig: *Rig, version_line: []const u8) ![]u8 {
    const gpa = testing.allocator;
    const io = testing.io;
    const asset = assetName().?;
    const dir_name = asset[0 .. asset.len - ".tar.gz".len];
    const sub = try std.fmt.allocPrint(gpa, "stage/{s}/{s}", .{ dir_name, graff_exe });
    defer gpa.free(sub);
    try rig.tmp.dir.createDirPath(io, std.fs.path.dirname(sub).?);
    const script = try std.fmt.allocPrint(gpa, "#!/bin/sh\necho '{s}'\n", .{version_line});
    defer gpa.free(script);
    try rig.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = script, .flags = .{ .permissions = .executable_file } });
    const stage = try rig.path("stage");
    defer gpa.free(stage);
    const out = try rig.path("out.tar.gz");
    defer gpa.free(out);
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/tar", "-czf", out, "-C", stage, dir_name },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    });
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    try testing.expect(res.term == .exited and res.term.exited == 0);
    try rig.tmp.dir.deleteTree(io, "stage");
    return rig.tmp.dir.readFileAlloc(io, "out.tar.gz", gpa, .limited(64 * 1024 * 1024));
}

fn sumsFor(gpa: Allocator, tarball: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    return std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ &std.fmt.bytesToHex(digest, .lower), assetName().? });
}

fn freeOutcome(r: Error!net.Result(Outcome)) void {
    const v = r catch return;
    switch (v) {
        .ok => |o| o.deinit(testing.allocator),
        .err => |f| f.deinit(testing.allocator),
    }
}

/// `updateManaged`/`updateManagedBeta` under a 30 s deadline.
fn runGuarded(comptime beta: bool) !net.Result(Outcome) {
    const g = try net.guard(testing.io, .{ .deadline_ms = 30_000 }, if (beta) updateManagedBetaT else updateManagedT, .{}, freeOutcome);
    return switch (g) {
        .done => |r| try r,
        .stopped => error.TestTimeout,
    };
}

fn updateManagedT() Error!net.Result(Outcome) {
    return updateManaged(testing.allocator, testing.io);
}

fn updateManagedBetaT() Error!net.Result(Outcome) {
    return updateManagedBeta(testing.allocator, testing.io);
}

fn pointAt(srv: *net.TestServer, buf_api: []u8, buf_dl: []u8) void {
    api_base = std.fmt.bufPrint(buf_api, "http://127.0.0.1:{d}/api", .{srv.port}) catch unreachable;
    releases_base = std.fmt.bufPrint(buf_dl, "http://127.0.0.1:{d}/dl", .{srv.port}) catch unreachable;
}

fn resetBases() void {
    releases_base = "https://github.com/justrach/codegraff/releases/download";
    api_base = "https://api.github.com/repos/justrach/codegraff";
}

test "graff update_managed downloads, verifies and places the release; a rerun is already current" {
    if (!std.process.can_spawn or net.is_windows or assetName() == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const tarball = try makeTarball(&rig, "graff 0.0.302.5");
    defer gpa.free(tarball);
    const sums = try sumsFor(gpa, tarball);
    defer gpa.free(sums);
    const asset_path = try std.fmt.allocPrint(gpa, "/dl/v0.0.302.5/{s}", .{assetName().?});
    defer gpa.free(asset_path);
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{
        .{ .path = "/api/releases/latest", .body = "{\"tag_name\":\"v0.0.302.5\",\"name\":\"x\"}" },
        .{ .path = "/dl/v0.0.302.5/SHA256SUMS", .body = sums },
        .{ .path = asset_path, .body = tarball },
    });
    defer srv.shutdown();
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    pointAt(&srv, &b1, &b2);
    defer resetBases();

    const first = try runGuarded(false);
    defer freeOutcome(first);
    try testing.expect(first == .ok);
    try testing.expect(first.ok == .updated);
    try testing.expect(first.ok.updated.from == null);
    try testing.expectEqualStrings("0.0.302.5", first.ok.updated.to);
    const placed = try rig.tmp.dir.statFile(testing.io, "home/.harness/bin/graff", .{});
    try testing.expect(@as(u32, @intCast(placed.permissions.toMode())) & 0o111 != 0);
    // No staging leftovers beside it.
    var dir = try rig.tmp.dir.openDir(testing.io, "home/.harness/bin", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |e| try testing.expectEqualStrings("graff", e.name);

    const second = try runGuarded(false);
    defer freeOutcome(second);
    try testing.expectEqualStrings("0.0.302.5", second.ok.already_current);
}

test "graff update_managed rejects a checksum mismatch and places nothing" {
    if (!std.process.can_spawn or net.is_windows or assetName() == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const tarball = try makeTarball(&rig, "graff 0.0.302.5");
    defer gpa.free(tarball);
    const zeros: [64]u8 = @splat('0');
    const bad_sums = try std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ &zeros, assetName().? });
    defer gpa.free(bad_sums);
    const asset_path = try std.fmt.allocPrint(gpa, "/dl/v0.0.302.5/{s}", .{assetName().?});
    defer gpa.free(asset_path);
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{
        .{ .path = "/api/releases/latest", .body = "{\"tag_name\":\"v0.0.302.5\"}" },
        .{ .path = "/dl/v0.0.302.5/SHA256SUMS", .body = bad_sums },
        .{ .path = asset_path, .body = tarball },
    });
    defer srv.shutdown();
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    pointAt(&srv, &b1, &b2);
    defer resetBases();

    const r = try runGuarded(false);
    defer freeOutcome(r);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const want = try std.fmt.allocPrint(gpa, "checksum mismatch for {s} (expected {s}, got {s})", .{ assetName().?, &zeros, &std.fmt.bytesToHex(digest, .lower) });
    defer gpa.free(want);
    try testing.expectEqualStrings(want, r.err.msg);
    try testing.expect(!rig.exists("home/.harness/bin/graff"));
    try testing.expect(!rig.exists("home/.harness/bin"));
}

test "graff update_managed rejects a missing checksum line and an invalid tag" {
    if (!std.process.can_spawn or net.is_windows or assetName() == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{
        .{ .path = "/api/releases/latest", .body = "{\"tag_name\":\"v0.0.302.5\"}" },
        .{ .path = "/dl/v0.0.302.5/SHA256SUMS", .body = "abc  graff-other.tar.gz\n" },
    });
    defer srv.shutdown();
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    pointAt(&srv, &b1, &b2);
    defer resetBases();
    const r = try runGuarded(false);
    defer freeOutcome(r);
    const want = try std.fmt.allocPrint(gpa, "{s} is missing from the release's SHA256SUMS", .{assetName().?});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, r.err.msg);
    try testing.expect(!rig.exists("home/.harness/bin/graff"));

    var srv2: net.TestServer = undefined;
    try srv2.start(testing.io, &.{.{ .path = "/api/releases/latest", .body = "{\"tag_name\":\"0.0.302.5\"}" }});
    defer srv2.shutdown();
    pointAt(&srv2, &b1, &b2);
    const bad = try runGuarded(false);
    defer freeOutcome(bad);
    try testing.expectEqualStrings("CodeGraff release has an invalid stable version tag", bad.err.msg);
}

test "graff update_managed_beta installs the newest published beta and refuses a custom executable" {
    if (!std.process.can_spawn or net.is_windows or assetName() == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const tarball = try makeTarball(&rig, "graff 0.0.303.1-beta.10.1");
    defer gpa.free(tarball);
    const sums = try sumsFor(gpa, tarball);
    defer gpa.free(sums);
    const asset_path = try std.fmt.allocPrint(gpa, "/dl/v0.0.303.1-beta.10.1/{s}", .{assetName().?});
    defer gpa.free(asset_path);
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{
        .{ .path = "/api/git/matching-refs/heads/release/v", .body = "[{\"ref\":\"refs/heads/release/v0.0.302.9\"},{\"ref\":\"refs/heads/release/v0.0.303.1\"},{\"ref\":\"refs/heads/main\"}]" },
        .{ .path = "/api/releases?per_page=100&page=1", .body = "[{\"tag_name\":\"v0.0.303.1-beta.9.1\",\"prerelease\":true,\"draft\":false,\"published_at\":\"x\"},{\"tag_name\":\"v0.0.303.1-beta.10.1\",\"prerelease\":true,\"draft\":false,\"published_at\":\"x\"},{\"tag_name\":\"v0.0.303.1-beta.11.1\",\"prerelease\":true,\"draft\":true,\"published_at\":null}]" },
        .{ .path = "/dl/v0.0.303.1-beta.10.1/SHA256SUMS", .body = sums },
        .{ .path = asset_path, .body = tarball },
    });
    defer srv.shutdown();
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    pointAt(&srv, &b1, &b2);
    defer resetBases();

    const r = try runGuarded(true);
    defer freeOutcome(r);
    try testing.expectEqualStrings("v0.0.303.1-beta.10.1", r.ok.updated.to);
    const managed = try rig.path("home/.harness/bin/graff");
    defer gpa.free(managed);
    const tag = (try installedBetaTag(gpa, testing.io, &rig.env, managed)).?;
    defer gpa.free(tag);
    try testing.expectEqualStrings("v0.0.303.1-beta.10.1", tag);
    // A rerun keeps the installed beta.
    const again = try runGuarded(true);
    defer freeOutcome(again);
    try testing.expectEqualStrings("v0.0.303.1-beta.10.1", again.ok.already_current);

    try rig.env.put("GRAFF_EXECUTABLE", "/custom/graff");
    const refused = try runGuarded(true);
    defer freeOutcome(refused);
    try testing.expectEqualStrings("a custom Graff executable is selected; unset GRAFF_EXECUTABLE to use the managed beta", refused.err.msg);
}
