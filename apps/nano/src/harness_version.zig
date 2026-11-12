//! Agent CLI versions, ported from `crates/harness/src/executable.rs`:
//! `parse_version` (semver words in `--version` output, plus graff's
//! four-part `0.0.302.4` and git-describe forms), `version_order`,
//! `newest_candidate` (the PATH-preferred binary unless a later candidate
//! answers with a newer version), and `binary_version`'s per-identity probe
//! cache with `invalidate_versions`.
//!
//! The choice rule is `chooseNewest`, a pure function over already-probed
//! candidates; `newestCandidate` feeds it real probes. Std-only.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

// ── semver ───────────────────────────────────────────────────────────────

/// A parsed `semver::Version`. Slices point into the text it was parsed from
/// (or the caller's own buffer, for four-part versions).
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    pre: []const u8 = "",
    build: []const u8 = "",

    /// `Version::to_string`.
    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        if (v.pre.len > 0) try w.print("-{s}", .{v.pre});
        if (v.build.len > 0) try w.print("+{s}", .{v.build});
    }

    /// `cmp_precedence`: build metadata never orders.
    pub fn precedence(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        if (a.pre.len == 0 and b.pre.len == 0) return .eq;
        if (a.pre.len == 0) return .gt;
        if (b.pre.len == 0) return .lt;
        var ia = std.mem.splitScalar(u8, a.pre, '.');
        var ib = std.mem.splitScalar(u8, b.pre, '.');
        while (true) {
            const xa = ia.next();
            const xb = ib.next();
            if (xa == null and xb == null) return .eq;
            if (xa == null) return .lt;
            if (xb == null) return .gt;
            const na = numeric(xa.?);
            const nb = numeric(xb.?);
            const o: std.math.Order = if (na != null and nb != null)
                std.math.order(na.?, nb.?)
            else if (na != null)
                .lt
            else if (nb != null)
                .gt
            else
                std.mem.order(u8, xa.?, xb.?);
            if (o != .eq) return o;
        }
    }
};

fn numeric(ident: []const u8) ?u64 {
    if (ident.len == 0) return null;
    for (ident) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, ident, 10) catch null;
}

fn parseNumber(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    if (text.len > 1 and text[0] == '0') return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn validIdents(text: []const u8, numeric_no_leading_zero: bool) bool {
    if (text.len == 0) return false;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |ident| {
        if (ident.len == 0) return false;
        for (ident) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
        if (numeric_no_leading_zero and numeric(ident) != null and ident.len > 1 and ident[0] == '0') return false;
    }
    return true;
}

/// `semver::Version::parse` (strict: no `v`, no leading zeros).
pub fn parseSemver(text: []const u8) ?Version {
    var rest = text;
    var build: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        build = rest[plus + 1 ..];
        rest = rest[0..plus];
        if (!validIdents(build, false)) return null;
    }
    var pre: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        pre = rest[dash + 1 ..];
        rest = rest[0..dash];
        if (!validIdents(pre, true)) return null;
    }
    var it = std.mem.splitScalar(u8, rest, '.');
    const major = parseNumber(it.next() orelse return null) orelse return null;
    const minor = parseNumber(it.next() orelse return null) orelse return null;
    const patch = parseNumber(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return .{ .major = major, .minor = minor, .patch = patch, .pre = pre, .build = build };
}

/// A version whose build metadata may need its own storage (four-part forms).
pub const Parsed = struct {
    version: Version,
    build_buf: [128]u8 = undefined,

    pub fn get(self: *const Parsed) Version {
        return self.version;
    }
};

/// `four_part_version`: `0.0.302.4` → `0.0.302+4`; git-describe
/// `0.0.302.5-14-g3b4a0fca` → `0.0.302+5.post.14.g3b4a0fca`; a beta
/// `0.0.302.5-beta.14.1` keeps its prerelease: `0.0.302-beta.14.1+5`.
/// `out` receives the build metadata; the returned version borrows it.
pub fn fourPartVersion(word: []const u8, out: []u8) ?Version {
    // `splitn(4, '.')`: three dots at least; the tail is everything after.
    if (std.mem.count(u8, word, ".") < 3) return null;
    var parts = std.mem.splitScalar(u8, word, '.');
    const major = parts.next().?;
    const minor = parts.next().?;
    const patch = parts.next().?;
    const tail = parts.rest();
    var digits: usize = 0;
    while (digits < tail.len and std.ascii.isDigit(tail[digits])) digits += 1;
    if (digits == 0) return null;
    const fourth = tail[0..digits];
    const suffix = tail[digits..];
    var tag_suffix = suffix;
    var described: ?struct { distance: []const u8, hash: []const u8 } = null;
    if (std.mem.lastIndexOf(u8, suffix, "-g")) |g| {
        const prefix = suffix[0..g];
        const hash = suffix[g + 2 ..];
        if (std.mem.lastIndexOfScalar(u8, prefix, '-')) |d| {
            const distance = prefix[d + 1 ..];
            var all_digits = distance.len > 0;
            for (distance) |c| if (!std.ascii.isDigit(c)) {
                all_digits = false;
            };
            if (all_digits and hash.len > 0) {
                described = .{ .distance = distance, .hash = hash };
                tag_suffix = prefix[0..d];
            }
        }
    }
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "{s}.{s}.{s}{s}", .{ major, minor, patch, tag_suffix }) catch return null;
    var v = parseSemver(head) orelse return null;
    // `pre` borrows `head_buf`: move it into `out` after the build.
    const build = if (described) |d|
        std.fmt.bufPrint(out, "{s}.post.{s}.g{s}", .{ fourth, d.distance, d.hash }) catch return null
    else
        std.fmt.bufPrint(out, "{s}", .{fourth}) catch return null;
    if (!validIdents(build, false)) return null;
    if (v.pre.len > 0) {
        if (build.len + v.pre.len > out.len) return null;
        const pre_dst = out[build.len .. build.len + v.pre.len];
        @memcpy(pre_dst, v.pre);
        v.pre = pre_dst;
    }
    v.build = build;
    return v;
}

/// `parse_version`: the first word of the output (trimmed of `(`, `)`, `,`
/// and leading `v`s) that parses as semver or a four-part version. The
/// result borrows `bytes` or `out`.
pub fn parseVersion(bytes: []const u8, out: []u8) ?Version {
    var words = std.mem.tokenizeAny(u8, bytes, " \t\r\n\x0b\x0c");
    while (words.next()) |raw| {
        var word = std.mem.trim(u8, raw, "(),");
        word = std.mem.trimStart(u8, word, "v");
        if (parseSemver(word)) |v| return v;
        if (fourPartVersion(word, out)) |v| return v;
    }
    return null;
}

fn fourthComponent(v: Version) u64 {
    var parts = std.mem.splitScalar(u8, v.build, '.');
    const first = parts.next() orelse return 0;
    return std.fmt.parseInt(u64, first, 10) catch 0;
}

fn postTagDistance(v: Version) u64 {
    var parts = std.mem.splitScalar(u8, v.build, '.');
    _ = parts.next();
    const tag = parts.next() orelse return 0;
    if (!std.mem.eql(u8, tag, "post")) return 0;
    const n = parts.next() orelse return 0;
    return std.fmt.parseInt(u64, n, 10) catch 0;
}

/// `version_order(exe, next, current)`: graff's fourth component and
/// post-tag distance break ties between equal `major.minor.patch`.
pub fn versionOrder(exe: []const u8, next: Version, current: Version) std.math.Order {
    if (std.mem.eql(u8, exe, "graff") and next.major == current.major and next.minor == current.minor and next.patch == current.patch) {
        const o = std.math.order(fourthComponent(next), fourthComponent(current));
        if (o != .eq) return o;
        const p = next.precedence(current);
        if (p != .eq) return p;
        return std.math.order(postTagDistance(next), postTagDistance(current));
    }
    return next.precedence(current);
}

// ── the choice rule ────────────────────────────────────────────────────────

/// What a `--version` probe of one candidate gave.
pub const Probe = union(enum) {
    /// The probe outlasted its budget; the binary may still be fine.
    timed_out,
    /// It ran but printed no version (or failed).
    none,
    version: Version,
};

pub const Candidate = struct {
    path: []const u8,
    /// The canonical path (`canonicalize()` or the path itself): duplicates
    /// by canonical path are dropped, the first kept.
    canonical: []const u8,
    probe: Probe,
};

/// `newest_candidate`'s rule, pure: the index of the binary to launch among
/// runnable candidates in search order, or null when there are none.
/// The first (PATH-preferred) candidate wins unless a later one reports a
/// strictly newer version; a first candidate whose probe timed out wins
/// outright (a freshly updated CLI can outlast its first probe).
pub fn chooseNewest(exe: []const u8, candidates: []const Candidate) ?usize {
    if (candidates.len == 0) return null;
    var best: usize = 0;
    var unique: usize = 0;
    for (candidates, 0..) |c, i| {
        if (!seenBefore(candidates, i)) unique += 1;
        _ = c;
    }
    if (unique <= 1) return best;
    var version: ?Version = switch (candidates[0].probe) {
        .timed_out => return best,
        .none => null,
        .version => |v| v,
    };
    for (candidates[1..], 1..) |c, i| {
        if (seenBefore(candidates, i)) continue;
        const next: ?Version = switch (c.probe) {
            .version => |v| v,
            else => null,
        };
        if (next) |n| {
            if (version == null or versionOrder(exe, n, version.?) == .gt) {
                best = i;
                version = n;
            }
        }
    }
    return best;
}

fn seenBefore(candidates: []const Candidate, i: usize) bool {
    for (candidates[0..i]) |prev| {
        if (std.mem.eql(u8, prev.canonical, candidates[i].canonical)) return true;
    }
    return false;
}

// ── graff's install paths (`acp::graff_install_paths`, `graff_bundle`) ─────

/// `graff_bundle::bundled()` without the existence check: the graff shipped
/// inside the app bundle, `<exe>/../../Resources/bin/graff` (from
/// `Contents/MacOS/<exe>`). `exe` is the canonical path of the running binary.
pub fn bundledGraffCandidate(gpa: Allocator, exe: []const u8) !?[]u8 {
    const macos_dir = std.fs.path.dirname(exe) orelse return null;
    const contents = std.fs.path.dirname(macos_dir) orelse return null;
    return try std.fs.path.join(gpa, &.{ contents, "Resources", "bin", "graff" });
}

/// `graff_install_paths()`, pure: the extra places graff is looked for after
/// PATH, in order — the app-managed copy (`~/.harness/bin/graff`, only when
/// it is a file), the bundled copy (only when it is a file), `~/.local/bin`,
/// then Homebrew and `/usr/local`. A newer graff on PATH still wins through
/// `chooseNewest`. Caller frees each path and the list.
pub fn graffInstallPaths(gpa: Allocator, home: ?[]const u8, managed_is_file: bool, bundled_file: ?[]const u8, system_prefix: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    if (home) |h| if (managed_is_file) try out.append(gpa, try std.fs.path.join(gpa, &.{ h, ".harness", "bin", "graff" }));
    if (bundled_file) |b| try out.append(gpa, try gpa.dupe(u8, b));
    if (home) |h| try out.append(gpa, try std.fs.path.join(gpa, &.{ h, ".local", "bin", "graff" }));
    try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}/opt/homebrew/bin/graff", .{system_prefix}));
    try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}/usr/local/bin/graff", .{system_prefix}));
    return out;
}

/// `graff_bundle::bundled()`: the bundled graff next to this process's
/// executable, when it is a file. Owned.
pub fn bundledGraff(gpa: Allocator, io: Io) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch return null;
    const exe_z = Io.Dir.cwd().realPathFileAlloc(io, buf[0..n], gpa) catch return null;
    defer gpa.free(exe_z);
    const cand = (bundledGraffCandidate(gpa, exe_z) catch return null) orelse return null;
    const st = Io.Dir.cwd().statFile(io, cand, .{}) catch {
        gpa.free(cand);
        return null;
    };
    if (st.kind != .file) {
        gpa.free(cand);
        return null;
    }
    return cand;
}

// ── probing (`binary_version`, `probe_binary_version`) ─────────────────────

const Entry = struct {
    canonical: []u8,
    mtime_ns: i96,
    size: u64,
    /// The `--version` output kept so `version` slices stay valid.
    output: ?[]u8,
    version: ?Version,
    build_buf: [128]u8,
    aliases: std.ArrayList([]u8),
};

var cache_mutex: Io.Mutex = .init;
var cache: std.ArrayList(*Entry) = .empty;
const cache_gpa = std.heap.page_allocator;

/// The stem of `path` (`file_stem`).
fn fileStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| if (dot > 0) return base[0..dot];
    return base;
}

/// `binary_version(path)` written into `out` as `Version::to_string`, or
/// null (no version, unreadable or timed out). Probes once per
/// (canonical path, mtime, size); timeouts are retried next call.
pub fn binaryVersionString(io: Io, path: []const u8, out: []u8) ?[]const u8 {
    const res = probeBinaryVersion(io, path, out);
    return switch (res) {
        .version => |s| s,
        else => null,
    };
}

pub const VersionProbe = union(enum) { timed_out, none, version: []const u8 };

/// `probe_binary_version`; the version is formatted into `out`.
pub fn probeBinaryVersion(io: Io, path: []const u8, out: []u8) VersionProbe {
    const canonical_z = Io.Dir.cwd().realPathFileAlloc(io, path, cache_gpa) catch return .none;
    defer cache_gpa.free(canonical_z);
    const canonical: []const u8 = canonical_z;
    const st = Io.Dir.cwd().statFile(io, canonical, .{}) catch return .none;
    const alias = fileStem(path);

    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    for (cache.items) |e| {
        if (std.mem.eql(u8, e.canonical, canonical) and e.mtime_ns == st.mtime.nanoseconds and e.size == st.size) {
            addAlias(e, alias);
            return formatProbe(e.version, out);
        }
    }
    var output: ?[]u8 = null;
    const status = runVersion(io, path, &output);
    if (status == .timed_out) {
        if (output) |o| cache_gpa.free(o);
        return .timed_out;
    }
    const e = cache_gpa.create(Entry) catch {
        if (output) |o| cache_gpa.free(o);
        return .none;
    };
    e.* = .{
        .canonical = cache_gpa.dupe(u8, canonical) catch {
            cache_gpa.destroy(e);
            if (output) |o| cache_gpa.free(o);
            return .none;
        },
        .mtime_ns = st.mtime.nanoseconds,
        .size = st.size,
        .output = output,
        .version = null,
        .build_buf = undefined,
        .aliases = .empty,
    };
    if (status == .ok) if (output) |o| {
        e.version = parseVersion(o, &e.build_buf);
    };
    // Replace any older entry for the same path.
    var i: usize = 0;
    while (i < cache.items.len) {
        if (std.mem.eql(u8, cache.items[i].canonical, canonical)) {
            freeEntry(cache.orderedRemove(i));
        } else i += 1;
    }
    addAlias(e, alias);
    cache.append(cache_gpa, e) catch {
        freeEntry(e);
        return .none;
    };
    return formatProbe(e.version, out);
}

fn formatProbe(v: ?Version, out: []u8) VersionProbe {
    const version = v orelse return .none;
    const s = std.fmt.bufPrint(out, "{f}", .{version}) catch return .none;
    return .{ .version = s };
}

fn addAlias(e: *Entry, alias: []const u8) void {
    for (e.aliases.items) |a| if (std.mem.eql(u8, a, alias)) return;
    const copy = cache_gpa.dupe(u8, alias) catch return;
    e.aliases.append(cache_gpa, copy) catch cache_gpa.free(copy);
}

fn freeEntry(e: *Entry) void {
    cache_gpa.free(e.canonical);
    if (e.output) |o| cache_gpa.free(o);
    for (e.aliases.items) |a| cache_gpa.free(a);
    e.aliases.deinit(cache_gpa);
    cache_gpa.destroy(e);
}

/// `invalidate_versions(names)`: forget every probe a name was seen under.
pub fn invalidateVersions(io: Io, names: []const []const u8) void {
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    var i: usize = 0;
    outer: while (i < cache.items.len) {
        for (cache.items[i].aliases.items) |a| for (names) |n| if (std.mem.eql(u8, a, n)) {
            freeEntry(cache.orderedRemove(i));
            continue :outer;
        };
        i += 1;
    }
}

const RunStatus = enum { ok, failed, timed_out };

/// `path --version` with a 2 s budget; stdout then stderr, each followed by
/// a space, at most 64 KiB each.
fn runVersion(io: Io, path: []const u8, output: *?[]u8) RunStatus {
    if (comptime !std.process.can_spawn) return .failed;
    const deadline: Io.Timeout = .{ .deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(2000), .clock = .awake }) };
    const res = std.process.run(cache_gpa, io, .{
        .argv = &.{ path, "--version" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = deadline,
    }) catch |e| return switch (e) {
        error.Timeout => .timed_out,
        else => .failed,
    };
    defer cache_gpa.free(res.stdout);
    defer cache_gpa.free(res.stderr);
    if (!(res.term == .exited and res.term.exited == 0)) return .failed;
    const joined = std.fmt.allocPrint(cache_gpa, "{s} {s} ", .{ res.stdout, res.stderr }) catch return .failed;
    output.* = joined;
    return .ok;
}

/// `newest_candidate(exe, candidates)` over real files: runnable candidate
/// paths in search order → the one to launch (owned), or null.
pub fn newestCandidate(gpa: Allocator, io: Io, exe: []const u8, paths: []const []const u8) !?[]u8 {
    if (paths.len == 0) return null;
    var canon: std.ArrayList([]u8) = .empty;
    defer {
        for (canon.items) |c| gpa.free(c);
        canon.deinit(gpa);
    }
    var bufs = try gpa.alloc([96]u8, paths.len);
    defer gpa.free(bufs);
    var cands = try gpa.alloc(Candidate, paths.len);
    defer gpa.free(cands);
    var parsed_bufs = try gpa.alloc([128]u8, paths.len);
    defer gpa.free(parsed_bufs);
    for (paths, 0..) |p, i| {
        const c: []u8 = if (Io.Dir.cwd().realPathFileAlloc(io, p, gpa)) |z| blk: {
            defer gpa.free(z);
            break :blk try gpa.dupe(u8, z);
        } else |_| try gpa.dupe(u8, p);
        try canon.append(gpa, c);
        cands[i] = .{ .path = p, .canonical = c, .probe = .none };
    }
    // Probe lazily in the same order Rust does: the first, then each later
    // unique candidate (only when there is more than one).
    var unique: usize = 0;
    for (0..paths.len) |i| {
        if (!seenBefore(cands, i)) unique += 1;
    }
    if (unique > 1) {
        for (0..paths.len) |i| {
            if (seenBefore(cands, i)) continue;
            cands[i].probe = switch (probeBinaryVersion(io, paths[i], &bufs[i])) {
                .timed_out => .timed_out,
                .none => .none,
                .version => |s| if (parseVersion(s, &parsed_bufs[i])) |v| .{ .version = v } else .none,
            };
            if (i == 0 and cands[0].probe == .timed_out) break;
        }
    }
    const idx = chooseNewest(exe, cands) orelse return null;
    return try gpa.dupe(u8, paths[idx]);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn sv(text: []const u8) Version {
    return parseSemver(text).?;
}

test "harness_version parses semver strictly and orders by precedence" {
    try testing.expect(parseSemver("1.2.3") != null);
    try testing.expect(parseSemver("01.2.3") == null);
    try testing.expect(parseSemver("1.2") == null);
    try testing.expect(parseSemver("1.2.3.4") == null);
    try testing.expect(parseSemver("1.2.3-") == null);
    try testing.expectEqual(std.math.Order.lt, sv("1.0.0-alpha").precedence(sv("1.0.0")));
    try testing.expectEqual(std.math.Order.lt, sv("1.0.0-alpha.1").precedence(sv("1.0.0-alpha.beta")));
    try testing.expectEqual(std.math.Order.lt, sv("1.0.0-beta.2").precedence(sv("1.0.0-beta.11")));
    try testing.expectEqual(std.math.Order.eq, sv("1.0.0+a").precedence(sv("1.0.0+b")));
    try testing.expectEqual(std.math.Order.gt, sv("0.110.0").precedence(sv("0.99.0")));
}

test "harness_version reads versions out of --version output like parse_version" {
    var buf: [128]u8 = undefined;
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("2.1.3", try std.fmt.bufPrint(&out, "{f}", .{parseVersion("claude 2.1.3 (Claude Code)", &buf).?}));
    try testing.expectEqualStrings("0.110.0", try std.fmt.bufPrint(&out, "{f}", .{parseVersion("codex-cli v0.110.0\n", &buf).?}));
    try testing.expectEqualStrings("1.0.0", try std.fmt.bufPrint(&out, "{f}", .{parseVersion("tool (1.0.0),", &buf).?}));
    try testing.expectEqualStrings("0.0.302+4", try std.fmt.bufPrint(&out, "{f}", .{parseVersion("graff 0.0.302.4", &buf).?}));
    try testing.expectEqualStrings("0.0.302+5.post.14.g3b4a0fca", try std.fmt.bufPrint(&out, "{f}", .{parseVersion("graff v0.0.302.5-14-g3b4a0fca", &buf).?}));
    try testing.expectEqualStrings("0.0.302-beta.14.1+5", try std.fmt.bufPrint(&out, "{f}", .{parseVersion("graff v0.0.302.5-beta.14.1", &buf).?}));
    try testing.expect(parseVersion("no version here", &buf) == null);
    try testing.expect(parseVersion("", &buf) == null);
}

test "harness_version graff ordering uses the fourth component, then tag, then distance" {
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const old = parseVersion("0.0.302.4", &b1).?;
    const new = parseVersion("0.0.302.5", &b2).?;
    try testing.expectEqual(std.math.Order.gt, versionOrder("graff", new, old));
    // Other CLIs ignore build metadata: a tie keeps the current.
    try testing.expectEqual(std.math.Order.eq, versionOrder("codex", new, old));
    var b3: [128]u8 = undefined;
    var b4: [128]u8 = undefined;
    const dev = parseVersion("v0.0.302.5-14-g3b4a0fca", &b3).?;
    const beta = parseVersion("v0.0.302.5-beta.14.1", &b4).?;
    try testing.expectEqual(std.math.Order.gt, versionOrder("graff", dev, new));
    try testing.expectEqual(std.math.Order.lt, versionOrder("graff", beta, new));
}

test "harness_version chooseNewest keeps the PATH-preferred binary unless a later one is newer" {
    const a = Candidate{ .path = "/a/codex", .canonical = "/a/codex", .probe = .{ .version = sv("0.99.0") } };
    const b = Candidate{ .path = "/b/codex", .canonical = "/b/codex", .probe = .{ .version = sv("0.110.0") } };
    const b_alias = Candidate{ .path = "/alias", .canonical = "/b/codex", .probe = .{ .version = sv("9.0.0") } };
    try testing.expectEqual(@as(?usize, null), chooseNewest("codex", &.{}));
    try testing.expectEqual(@as(?usize, 1), chooseNewest("codex", &.{ a, b, b_alias }));
    try testing.expectEqual(@as(?usize, 0), chooseNewest("codex", &.{ b, a }));
    // Equal versions keep the first.
    const a2 = Candidate{ .path = "/c/codex", .canonical = "/c/codex", .probe = .{ .version = sv("0.99.0") } };
    try testing.expectEqual(@as(?usize, 0), chooseNewest("codex", &.{ a, a2 }));
    // A first probe that timed out wins outright.
    const slow = Candidate{ .path = "/s/codex", .canonical = "/s/codex", .probe = .timed_out };
    try testing.expectEqual(@as(?usize, 0), chooseNewest("codex", &.{ slow, b }));
    // A first candidate with no version loses to any later version.
    const mute = Candidate{ .path = "/m/codex", .canonical = "/m/codex", .probe = .none };
    try testing.expectEqual(@as(?usize, 1), chooseNewest("codex", &.{ mute, a }));
    // A later candidate with no version never wins.
    try testing.expectEqual(@as(?usize, 0), chooseNewest("codex", &.{ a, mute }));
}

test "harness_version graff install paths put managed and bundled copies first" {
    const gpa = testing.allocator;
    const b = (try bundledGraffCandidate(gpa, "/Applications/Harness.app/Contents/MacOS/harness")).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("/Applications/Harness.app/Contents/Resources/bin/graff", b);
    var all = try graffInstallPaths(gpa, "/h", true, b, "");
    defer {
        for (all.items) |p| gpa.free(p);
        all.deinit(gpa);
    }
    const want = [_][]const u8{ "/h/.harness/bin/graff", b, "/h/.local/bin/graff", "/opt/homebrew/bin/graff", "/usr/local/bin/graff" };
    try testing.expectEqual(want.len, all.items.len);
    for (want, all.items) |w, got| try testing.expectEqualStrings(w, got);
    var bare = try graffInstallPaths(gpa, "/h", false, null, "/p");
    defer {
        for (bare.items) |p| gpa.free(p);
        bare.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 3), bare.items.len);
    try testing.expectEqualStrings("/p/opt/homebrew/bin/graff", bare.items[1]);
}

fn writeScript(io: Io, dir: Io.Dir, sub: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub, .data = body, .flags = .{ .permissions = .executable_file } });
}

test "harness_version newestCandidate probes real binaries once and invalidates by name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base_z);
    const base: []const u8 = base_z;
    const one = try std.fs.path.join(gpa, &.{ base, "one", "hvtest-codex" });
    defer gpa.free(one);
    const two = try std.fs.path.join(gpa, &.{ base, "two", "hvtest-codex" });
    defer gpa.free(two);
    const calls = try std.fs.path.join(gpa, &.{ base, "calls" });
    defer gpa.free(calls);
    const body2 = try std.fmt.allocPrint(gpa, "#!/bin/sh\necho codex-cli 0.110.0\necho x >> '{s}'\n", .{calls});
    defer gpa.free(body2);
    try writeScript(io, tmp.dir, "one/hvtest-codex", "#!/bin/sh\necho codex-cli 0.99.0\n");
    try writeScript(io, tmp.dir, "two/hvtest-codex", body2);
    for (0..3) |_| {
        const got = (try newestCandidate(gpa, io, "codex", &.{ one, two })).?;
        defer gpa.free(got);
        try testing.expectEqualStrings(two, got);
    }
    const text = try tmp.dir.readFileAlloc(io, "calls", gpa, .limited(1024));
    defer gpa.free(text);
    try testing.expectEqualStrings("x\n", text);
    // Stderr versions count too.
    try writeScript(io, tmp.dir, "three/hvtest-other", "#!/bin/sh\necho other 3.0.0 >&2\n");
    const three = try std.fs.path.join(gpa, &.{ base, "three", "hvtest-other" });
    defer gpa.free(three);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("3.0.0", binaryVersionString(io, three, &out).?);
    // A failing binary has no version; one that hangs times out (not cached).
    try writeScript(io, tmp.dir, "bad/hvtest-bad", "#!/bin/sh\necho 1.0.0\nexit 2\n");
    const bad = try std.fs.path.join(gpa, &.{ base, "bad", "hvtest-bad" });
    defer gpa.free(bad);
    try testing.expect(binaryVersionString(io, bad, &out) == null);
    try writeScript(io, tmp.dir, "slow/hvtest-slow", "#!/bin/sh\nsleep 5\necho 1.0.0\n");
    const slow = try std.fs.path.join(gpa, &.{ base, "slow", "hvtest-slow" });
    defer gpa.free(slow);
    try testing.expect(probeBinaryVersion(io, slow, &out) == .timed_out);
    // invalidate_versions forgets a cached probe.
    try writeScript(io, tmp.dir, "inv/hvtest-inv", "#!/bin/sh\ncat \"$(dirname \"$0\")/v\"\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "inv/v", .data = "1.0.0" });
    const inv = try std.fs.path.join(gpa, &.{ base, "inv", "hvtest-inv" });
    defer gpa.free(inv);
    try testing.expectEqualStrings("1.0.0", binaryVersionString(io, inv, &out).?);
    try tmp.dir.writeFile(io, .{ .sub_path = "inv/v", .data = "2.0.0" });
    try testing.expectEqualStrings("1.0.0", binaryVersionString(io, inv, &out).?);
    invalidateVersions(io, &.{"hvtest-inv"});
    try testing.expectEqualStrings("2.0.0", binaryVersionString(io, inv, &out).?);
}
