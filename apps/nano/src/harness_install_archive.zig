//! Managed installs of ACP agents distributed as pinned zip archives (the
//! Antigravity server), ported from `crates/harness/src/archive_install.rs`
//! (`ensure_installed`, `download`, `extract_zip`, `archive_entry_path`,
//! `mark_executables`, `installed_entry`), the parts of
//! `crates/harness/src/adapter_install.rs` it uses (`adapters_root`,
//! `OK_MARKER`, `install_lock`), and `crates/harness/src/acp/mod.rs`
//! (`antigravity_archive`, `can_install`, `install_harness`).
//!
//! Integrity is Rust's: the archive's SHA-512 must equal the pin before it is
//! unpacked; extraction happens in a `.tmp-*` sibling that is renamed into
//! `~/.harness/adapters/<name>/<version>` only after the entry resolves and
//! the `.harness-install-ok` marker (holding the pin's digest) is written.
//!
//! The pins mirror `rpcw_executables.zig`'s `antigravityArchive` (which has
//! no URLs); they are re-declared here so this file stays std-only.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const net = @import("harness_install_net.zig");

const Failure = net.Failure;
const Error = net.Error;
const fail = net.fail;

/// `ArchivePin`: where to fetch the archive, which file inside runs the
/// agent, and the archive's SHA-512 (lowercase hex).
pub const ArchivePin = struct {
    name: []const u8,
    version: []const u8,
    url: []const u8,
    /// Path of the executable relative to the archive root.
    entry: []const u8,
    sha512: []const u8,
};

/// `antigravity_archive`: Google's builds as the ACP registry lists them;
/// null on platforms without one.
pub fn antigravityArchive() ?ArchivePin {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    const p: struct { url: []const u8, entry: []const u8, sha: []const u8 } = if (os == .macos and arch == .aarch64) .{
        .url = "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.2.1-darwin-arm64.zip",
        .entry = "agy_acp_server.par",
        .sha = "c0049b1f423ffdf0e6a79a6caa104a27b6368522b1eb2c67d9eeed1424af2a07898a66b475b0824a734a0bdd01264473a7d67d1550357a8607fb136507b0afae",
    } else if (os == .linux and arch == .x86_64) .{
        .url = "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-1.2.1-linux-x86_64.zip",
        .entry = "agy_acp_server.par",
        .sha = "dd9b778479dbfc753661d63ff66a3235e7249e8451af12adc11d26509172de1ff50452c3af57684009bb944314bd587b2be200bab17df743a2706ce4067d6731",
    } else if (os == .linux and arch == .aarch64) .{
        .url = "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-1.2.1-linux-arm64.zip",
        .entry = "agy_acp_server.par",
        .sha = "d907f928609ff2232bfeeec9177fe925d3e02e1773295cfb30097e5c4e134758021bff916ba5ae2e2e2ff81d374564349f268f92a4577bc88370537011473e29",
    } else if (os == .windows and arch == .x86_64) .{
        .url = "https://dl.google.com/agy-extensions/releases/windows/agy-acp-server-1.2.1-windows-x86_64.zip",
        .entry = "agy_acp_server.exe",
        .sha = "515c0af1d00164ca3a608f4ef04caa4ef8045ffa94a3ef2405c9b43c87c7a74c9f71a232c81917353dc3f2d49b69230f935d2ebfa28f7ee021b5aa088f3fa554",
    } else if (os == .windows and arch == .aarch64) .{
        .url = "https://dl.google.com/agy-extensions/releases/windows/agy-acp-server-1.2.1-windows-arm64.zip",
        .entry = "agy_acp_server.exe",
        .sha = "ae3f4c2d2255c03d4d9548e10a760a107c41c99e4c6c710bd82758791e4fd497b75bdef0cd2cfd7fdff1a5bb2fee7afd81f5d043da92ab52dce5505dd2aa58b3",
    } else return null;
    return .{ .name = "antigravity-acp", .version = "1.2.1", .url = p.url, .entry = p.entry, .sha512 = p.sha };
}

pub const ok_marker = ".harness-install-ok";
/// `STALL_TIMEOUT`: only a stalled stream fails a long download; tests shorten it.
pub var stall_timeout_ms: u64 = 60_000;
const max_archive_bytes: u64 = 768 * 1024 * 1024;
const max_extracted_bytes: u64 = 2 * 1024 * 1024 * 1024;
const max_archive_entries: u64 = 4_096;

/// `install_lock`: one managed install at a time per process.
var install_lock: Io.Mutex = .init;

// ── locations ──────────────────────────────────────────────────────────────

fn firstExisting(io: Io, candidates: []const []u8) []u8 {
    for (candidates) |c| if (net.pathExists(io, c)) return c;
    return candidates[0];
}

/// `adapters_root` (owned): `$HARNESS_ADAPTERS_DIR`, `$HARNESS_DATA_DIR/adapters`,
/// then `%LOCALAPPDATA%/Harness/adapters` on Windows or
/// `~/.harness/adapters` (`~/.harnesser` when only that exists) elsewhere.
pub fn adaptersRoot(gpa: Allocator, io: Io, env: *const Environ.Map) Allocator.Error!?[]u8 {
    if (net.getNonEmpty(env, "HARNESS_ADAPTERS_DIR")) |d| return try gpa.dupe(u8, d);
    if (net.getNonEmpty(env, "HARNESS_DATA_DIR")) |d| return try std.fs.path.join(gpa, &.{ d, "adapters" });
    if (net.is_windows) {
        const local = if (net.getNonEmpty(env, "LOCALAPPDATA")) |l|
            try gpa.dupe(u8, l)
        else if (net.getNonEmpty(env, "USERPROFILE")) |h|
            try std.fs.path.join(gpa, &.{ h, "AppData", "Local" })
        else
            return null;
        defer gpa.free(local);
        const a = try std.fs.path.join(gpa, &.{ local, "Harness" });
        defer gpa.free(a);
        const b = try std.fs.path.join(gpa, &.{ local, "Harnesser" });
        defer gpa.free(b);
        return try std.fs.path.join(gpa, &.{ firstExisting(io, &.{ a, b }), "adapters" });
    }
    const home = net.getNonEmpty(env, "HOME") orelse return null;
    const a = try std.fs.path.join(gpa, &.{ home, ".harness" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ home, ".harnesser" });
    defer gpa.free(b);
    return try std.fs.path.join(gpa, &.{ firstExisting(io, &.{ a, b }), "adapters" });
}

fn installDir(gpa: Allocator, io: Io, env: *const Environ.Map, pin: ArchivePin) Allocator.Error!?[]u8 {
    const root = (try adaptersRoot(gpa, io, env)) orelse return null;
    defer gpa.free(root);
    return try std.fs.path.join(gpa, &.{ root, pin.name, pin.version });
}

/// `installed_entry` (owned): the entry of a completed install, whose marker
/// holds the pin's digest; null when absent.
pub fn installedEntry(gpa: Allocator, io: Io, env: *const Environ.Map, pin: ArchivePin) Allocator.Error!?[]u8 {
    const dir = (try installDir(gpa, io, env, pin)) orelse return null;
    defer gpa.free(dir);
    const marker = try std.fs.path.join(gpa, &.{ dir, ok_marker });
    defer gpa.free(marker);
    const text = Io.Dir.cwd().readFileAlloc(io, marker, gpa, .limited(64 * 1024)) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    defer gpa.free(text);
    if (!std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), pin.sha512)) return null;
    const entry = try std.fs.path.join(gpa, &.{ dir, pin.entry });
    if (net.isFile(io, entry)) return entry;
    gpa.free(entry);
    return null;
}

// ── install ────────────────────────────────────────────────────────────────

/// `acp::install_harness`: only Antigravity has an archive; a platform
/// without a pin is `NotInstalled`.
pub fn installHarness(gpa: Allocator, io: Io, is_antigravity: bool, pin: ?ArchivePin) Error!?Failure {
    const p = (if (is_antigravity) pin else null) orelse
        return try fail(gpa, .not_installed, "Set ANTIGRAVITY_ACP_EXECUTABLE to an installed ACP server", .{});
    return switch (try ensureInstalled(gpa, io, p, "Antigravity")) {
        .ok => |entry| blk: {
            gpa.free(entry);
            break :blk null;
        },
        .err => |f| f,
    };
}

/// `ensure_installed`: the entry path (owned) of a verified install,
/// downloading and unpacking the pinned archive once.
pub fn ensureInstalled(gpa: Allocator, io: Io, pin: ArchivePin, display_name: []const u8) Error!net.Result([]u8) {
    var env = try net.currentEnv(gpa);
    defer env.deinit();
    if (try installedEntry(gpa, io, &env, pin)) |e| return .{ .ok = e };
    install_lock.lock(io) catch return error.Canceled;
    defer install_lock.unlock(io);
    if (try installedEntry(gpa, io, &env, pin)) |e| return .{ .ok = e };

    const root = (try adaptersRoot(gpa, io, &env)) orelse
        return .{ .err = try fail(gpa, .install, "cannot locate an adapters directory (HOME is unset)", .{}) };
    defer gpa.free(root);
    const final_dir = try std.fs.path.join(gpa, &.{ root, pin.name, pin.version });
    defer gpa.free(final_dir);
    const tmp_name = try std.fmt.allocPrint(gpa, ".tmp-{s}-{s}-{d}", .{ pin.name, pin.version, net.processId() });
    defer gpa.free(tmp_name);
    const tmp_dir = try std.fs.path.join(gpa, &.{ root, tmp_name });
    defer gpa.free(tmp_dir);
    const cwd = Io.Dir.cwd();
    net.removeTree(io, tmp_dir);
    cwd.createDirPath(io, tmp_dir) catch |e| return .{ .err = try net.ioFailure(gpa, e) };
    if (downloadAndExtract(gpa, io, &env, pin, tmp_dir, display_name)) |maybe| {
        if (maybe) |f| {
            net.removeTree(io, tmp_dir);
            return .{ .err = f };
        }
    } else |e| {
        net.removeTree(io, tmp_dir);
        return e;
    }
    const marker = try std.fs.path.join(gpa, &.{ tmp_dir, ok_marker });
    defer gpa.free(marker);
    const marker_text = try std.fmt.allocPrint(gpa, "{s}\n", .{pin.sha512});
    defer gpa.free(marker_text);
    cwd.writeFile(io, .{ .sub_path = marker, .data = marker_text }) catch |e| return .{ .err = try net.ioFailure(gpa, e) };
    if (std.fs.path.dirname(final_dir)) |parent| cwd.createDirPath(io, parent) catch |e| return .{ .err = try net.ioFailure(gpa, e) };
    Io.Dir.rename(cwd, tmp_dir, cwd, final_dir, io) catch {
        if (try installedEntry(gpa, io, &env, pin)) |e| {
            gpa.free(e);
            net.removeTree(io, tmp_dir);
        } else {
            net.removeTree(io, final_dir);
            Io.Dir.rename(cwd, tmp_dir, cwd, final_dir, io) catch |e| return .{ .err = try net.ioFailure(gpa, e) };
        }
    };
    if (try installedEntry(gpa, io, &env, pin)) |e| return .{ .ok = e };
    return .{ .err = try fail(gpa, .install, "install of the {s} ACP server {s} finished but {s} did not resolve", .{ display_name, pin.version, pin.entry }) };
}

fn downloadAndExtract(gpa: Allocator, io: Io, env: *const Environ.Map, pin: ArchivePin, dir: []const u8, display_name: []const u8) Error!?Failure {
    const archive = try std.fs.path.join(gpa, &.{ dir, "download.zip" });
    defer gpa.free(archive);
    if (try download(gpa, io, env, pin, archive, display_name)) |f| return f;
    if (try extractZip(gpa, io, archive, dir)) |f| return f;
    Io.Dir.cwd().deleteFile(io, archive) catch {};
    const entry = try std.fs.path.join(gpa, &.{ dir, pin.entry });
    defer gpa.free(entry);
    if (!net.isFile(io, entry))
        return try fail(gpa, .install, "the {s} archive ({s}) has no {s}", .{ display_name, pin.url, pin.entry });
    markExecutables(io, dir) catch |e| return try net.ioFailure(gpa, e);
    return null;
}

fn downloadFailed(gpa: Allocator, display_name: []const u8, url: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!Failure {
    const detail = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(detail);
    return fail(gpa, .install, "download of the {s} ACP server ({s}) failed: {s}", .{ display_name, url, detail });
}

/// The body copy that a stall stops: chunks go to the file and the digest.
const Copy = struct {
    gpa: Allocator,
    io: Io,
    body: *net.Http.Body,
    file: Io.File,
    digest: std.crypto.hash.sha2.Sha512 = .init(.{}),
    received: u64 = 0,
    progress: std.atomic.Value(i64),
    /// Set by the task: `limit` (too large), a body error, or a write error.
    outcome: union(enum) { ok, too_large, body: Failure, write: anyerror } = .ok,

    fn run(c: *Copy) Error!void {
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = switch (try c.body.read(&chunk)) {
                .ok => |n| n,
                .err => |f| {
                    c.outcome = .{ .body = f };
                    return;
                },
            };
            if (n == 0) return;
            c.progress.store(net.nowNs(c.io), .release);
            c.received +|= n;
            if (c.received > max_archive_bytes) {
                c.outcome = .too_large;
                return;
            }
            c.digest.update(chunk[0..n]);
            c.file.writeStreamingAll(c.io, chunk[0..n]) catch |e| {
                if (e == error.Canceled) return error.Canceled;
                c.outcome = .{ .write = e };
                return;
            };
        }
    }

    fn discard(_: Error!void) void {}
};

/// `download`: stream the archive to `dest`, hashing it; only a stall of
/// `stall_timeout_ms` between chunks fails a slow download.
fn download(gpa: Allocator, io: Io, env: *const Environ.Map, pin: ArchivePin, dest: []const u8, display_name: []const u8) Error!?Failure {
    const url = pin.url;
    var http: net.Http = undefined;
    http.init(gpa, io, env, null);
    defer http.deinit();
    const body = switch (try http.get(url, null)) {
        .ok => |b| b,
        .err => |f| {
            defer f.deinit(gpa);
            return try downloadFailed(gpa, display_name, url, "{s}", .{f.msg});
        },
    };
    defer body.destroy();
    if (body.content_length) |len| if (len > max_archive_bytes)
        return try downloadFailed(gpa, display_name, url, "server reported an archive larger than the {d} MiB limit", .{max_archive_bytes / (1024 * 1024)});
    const file = Io.Dir.cwd().createFile(io, dest, .{}) catch |e| return try net.ioFailure(gpa, e);
    defer file.close(io);
    var copy: Copy = .{ .gpa = gpa, .io = io, .body = body, .file = file, .progress = .init(net.nowNs(io)) };
    defer if (copy.outcome == .body) copy.outcome.body.deinit(gpa);
    const g = try net.guard(io, .{ .progress = &copy.progress, .stall_ms = stall_timeout_ms }, Copy.run, .{&copy}, Copy.discard);
    switch (g) {
        .done => |r| try r,
        .stopped => return try downloadFailed(gpa, display_name, url, "no data for {d}s — check your network", .{stall_timeout_ms / 1000}),
    }
    switch (copy.outcome) {
        .ok => {},
        .too_large => return try downloadFailed(gpa, display_name, url, "archive exceeded the {d} MiB limit", .{max_archive_bytes / (1024 * 1024)}),
        .body => |f| return try downloadFailed(gpa, display_name, url, "{s}", .{f.msg}),
        .write => |e| return try net.ioFailure(gpa, e),
    }
    var digest: [64]u8 = undefined;
    copy.digest.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, pin.sha512))
        return try downloadFailed(gpa, display_name, url, "SHA-512 mismatch (expected {s}, got {s})", .{ pin.sha512, &actual });
    return null;
}

// ── zip extraction ─────────────────────────────────────────────────────────

/// The zip crate's `enclosed_name`: no NUL, not absolute, and never climbing
/// above the root with `..`. The name itself is kept as written.
pub fn enclosedName(name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return null;
    if (std.fs.path.isAbsolute(name)) return null;
    if (net.is_windows and (std.mem.indexOfScalar(u8, name, ':') != null)) return null;
    var depth: usize = 0;
    var it = std.mem.tokenizeAny(u8, name, if (net.is_windows) "/\\" else "/");
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (depth == 0) return null;
            depth -= 1;
        } else depth += 1;
    }
    return name;
}

/// The zip crate's `unix_mode`: Unix-made entries carry it in the high half of
/// the external attributes; DOS-made ones are plain files or directories.
pub fn unixMode(version_made_by: u16, external_attributes: u32) ?u32 {
    if (external_attributes == 0) return null;
    return switch (version_made_by >> 8) {
        3 => external_attributes >> 16,
        0 => if (external_attributes & 0x10 != 0) 0o040775 else 0o100664,
        else => null,
    };
}

/// `archive_entry_path` (owned): `dest/name`, refusing unsafe names, links
/// and special files.
pub fn archiveEntryPath(gpa: Allocator, dest: []const u8, enclosed: ?[]const u8, unix_mode: ?u32) Allocator.Error!net.Result([]u8) {
    const name = enclosed orelse return .{ .err = try fail(gpa, .install, "archive contains an unsafe entry path", .{}) };
    if (unix_mode) |mode| {
        const kind = mode & 0o170000;
        if (!(kind == 0 or kind == 0o040000 or kind == 0o100000))
            return .{ .err = try fail(gpa, .install, "archive entry {s} is a link or special file", .{name}) };
    }
    return .{ .ok = try std.fs.path.join(gpa, &.{ dest, name }) };
}

fn invalidZip(gpa: Allocator, err: anyerror) Error!Failure {
    if (err == error.Canceled) return error.Canceled;
    return fail(gpa, .install, "invalid zip archive: {s}", .{@errorName(err)});
}

/// `extract_zip`: every entry of `archive` under `dest`, within the entry-count
/// and expanded-size limits, each entry's data checked against its declared
/// size and CRC-32.
pub fn extractZip(gpa: Allocator, io: Io, archive: []const u8, dest: []const u8) Error!?Failure {
    const file = Io.Dir.cwd().openFile(io, archive, .{}) catch |e| return try net.ioFailure(gpa, e);
    defer file.close(io);
    var rbuf: [16 * 1024]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    var iter = std.zip.Iterator.init(&fr) catch |e| return try invalidZip(gpa, e);
    if (iter.cd_record_count > max_archive_entries)
        return try fail(gpa, .install, "archive has {d} entries, exceeding the {d} entry limit", .{ iter.cd_record_count, max_archive_entries });
    const archive_resolved = try std.fs.path.resolve(gpa, &.{archive});
    defer gpa.free(archive_resolved);
    var extracted: u64 = 0;
    var index: u64 = 0;
    while (true) : (index += 1) {
        const entry = (iter.next() catch |e| {
            if (e == error.Canceled) return error.Canceled;
            return try fail(gpa, .install, "could not read archive entry {d}: {s}", .{ index, @errorName(e) });
        }) orelse break;
        switch (entry.compression_method) {
            .store, .deflate => {},
            else => return try fail(gpa, .install, "could not read archive entry {d}: UnsupportedCompressionMethod", .{index}),
        }
        extracted = std.math.add(u64, extracted, entry.uncompressed_size) catch
            return try fail(gpa, .install, "archive's extracted size overflows its limit", .{});
        if (extracted > max_extracted_bytes)
            return try fail(gpa, .install, "archive expands beyond the {d} MiB limit", .{max_extracted_bytes / (1024 * 1024)});
        // The central-directory record again, for the name and attributes the
        // iterator does not expose.
        fr.seekTo(entry.header_zip_offset) catch |e| return try net.ioFailure(gpa, e);
        const cd = fr.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little) catch |e|
            return try fail(gpa, .install, "could not read archive entry {d}: {s}", .{ index, @errorName(e) });
        const name = try gpa.alloc(u8, cd.filename_len);
        defer gpa.free(name);
        fr.interface.readSliceAll(name) catch |e|
            return try fail(gpa, .install, "could not read archive entry {d}: {s}", .{ index, @errorName(e) });
        const output = switch (try archiveEntryPath(gpa, dest, enclosedName(name), unixMode(cd.version_made_by, cd.external_file_attributes))) {
            .ok => |p| p,
            .err => |f| return f,
        };
        defer gpa.free(output);
        const resolved = try std.fs.path.resolve(gpa, &.{output});
        defer gpa.free(resolved);
        if (std.mem.eql(u8, resolved, archive_resolved))
            return try fail(gpa, .install, "archive attempts to overwrite its download file", .{});
        const cwd = Io.Dir.cwd();
        if (name.len > 0 and name[name.len - 1] == '/') {
            cwd.createDirPath(io, output) catch |e| return try net.ioFailure(gpa, e);
            continue;
        }
        if (std.fs.path.dirname(output)) |parent| cwd.createDirPath(io, parent) catch |e| return try net.ioFailure(gpa, e);
        const out = cwd.createFile(io, output, .{}) catch |e| return try net.ioFailure(gpa, e);
        defer out.close(io);
        if (try copyEntry(gpa, io, &fr, entry, out, output)) |f| return f;
    }
    return null;
}

/// One entry's data into `out`; its size and CRC-32 must match the record.
fn copyEntry(gpa: Allocator, io: Io, fr: *Io.File.Reader, entry: std.zip.Iterator.Entry, out: Io.File, output: []const u8) Error!?Failure {
    fr.seekTo(entry.file_offset) catch |e| return try net.ioFailure(gpa, e);
    const local = fr.interface.takeStruct(std.zip.LocalFileHeader, .little) catch |e| return try net.ioFailure(gpa, e);
    if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig))
        return try fail(gpa, .install, "invalid zip archive: bad local file header", .{});
    fr.seekTo(entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len) catch |e| return try net.ioFailure(gpa, e);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = undefined;
    var limited_buf: [4096]u8 = undefined;
    var limited = fr.interface.limited(.limited64(entry.compressed_size), &limited_buf);
    const src: *Io.Reader = switch (entry.compression_method) {
        .store => &limited.interface,
        else => blk: {
            inflate = .init(&limited.interface, .raw, &window);
            break :blk &inflate.reader;
        },
    };
    var crc: std.hash.Crc32 = .init();
    var copied: u64 = 0;
    var chunk: [64 * 1024]u8 = undefined;
    // Read one byte past the declared size so an over-long entry shows.
    while (copied <= entry.uncompressed_size) {
        const want: usize = @intCast(@min(chunk.len, entry.uncompressed_size + 1 - copied));
        const n = src.readSliceShort(chunk[0..want]) catch |e| return try net.ioFailure(gpa, e);
        if (n == 0) break;
        crc.update(chunk[0..n]);
        copied += n;
        out.writeStreamingAll(io, chunk[0..n]) catch |e| return try net.ioFailure(gpa, e);
    }
    if (copied != entry.uncompressed_size)
        return try fail(gpa, .install, "archive entry {s} extracted {d} bytes but declared {d}", .{ output, copied, entry.uncompressed_size });
    if (crc.final() != entry.crc32) return try fail(gpa, .io, "Invalid checksum", .{});
    return null;
}

/// `mark_executables`: archives built off-Unix can lose the executable bit,
/// and the entry spawns sibling helpers, so every top-level file gets 0o755 added.
fn markExecutables(io: Io, dir_path: []const u8) anyerror!void {
    if (net.is_windows) return;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const st = try dir.statFile(io, e.name, .{});
        const mode: u32 = @intCast(st.permissions.toMode());
        try dir.setFilePermissions(io, e.name, .fromMode(@intCast(mode | 0o755)), .{});
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A stored (uncompressed) zip of `files`; `mode` 0 writes DOS attributes.
pub fn testZip(gpa: Allocator, files: []const struct { name: []const u8, data: []const u8, mode: u32 = 0o100644 }) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var cd: std.ArrayList(u8) = .empty;
    defer cd.deinit(gpa);
    for (files) |f| {
        const offset: u32 = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(f.data);
        var lh: [30]u8 = undefined;
        std.mem.writeInt(u32, lh[0..4], 0x04034b50, .little);
        std.mem.writeInt(u16, lh[4..6], 20, .little);
        std.mem.writeInt(u16, lh[6..8], 0, .little);
        std.mem.writeInt(u16, lh[8..10], 0, .little);
        std.mem.writeInt(u16, lh[10..12], 0, .little);
        std.mem.writeInt(u16, lh[12..14], 0, .little);
        std.mem.writeInt(u32, lh[14..18], crc, .little);
        std.mem.writeInt(u32, lh[18..22], @intCast(f.data.len), .little);
        std.mem.writeInt(u32, lh[22..26], @intCast(f.data.len), .little);
        std.mem.writeInt(u16, lh[26..28], @intCast(f.name.len), .little);
        std.mem.writeInt(u16, lh[28..30], 0, .little);
        try out.appendSlice(gpa, &lh);
        try out.appendSlice(gpa, f.name);
        try out.appendSlice(gpa, f.data);
        var ch: [46]u8 = undefined;
        std.mem.writeInt(u32, ch[0..4], 0x02014b50, .little);
        std.mem.writeInt(u16, ch[4..6], (3 << 8) | 20, .little);
        @memcpy(ch[6..30], lh[4..28]);
        std.mem.writeInt(u16, ch[30..32], 0, .little);
        std.mem.writeInt(u16, ch[32..34], 0, .little);
        std.mem.writeInt(u16, ch[34..36], 0, .little);
        std.mem.writeInt(u16, ch[36..38], 0, .little);
        std.mem.writeInt(u32, ch[38..42], f.mode << 16, .little);
        std.mem.writeInt(u32, ch[42..46], offset, .little);
        try cd.appendSlice(gpa, &ch);
        try cd.appendSlice(gpa, f.name);
    }
    const cd_offset: u32 = @intCast(out.items.len);
    try out.appendSlice(gpa, cd.items);
    var eocd: [22]u8 = @splat(0);
    std.mem.writeInt(u32, eocd[0..4], 0x06054b50, .little);
    std.mem.writeInt(u16, eocd[8..10], @intCast(files.len), .little);
    std.mem.writeInt(u16, eocd[10..12], @intCast(files.len), .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd.items.len), .little);
    std.mem.writeInt(u32, eocd[16..20], cd_offset, .little);
    try out.appendSlice(gpa, &eocd);
    return out.toOwnedSlice(gpa);
}

pub fn sha512Hex(data: []const u8) [128]u8 {
    var d: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// HARNESS_ADAPTERS_DIR (and HOME) under a temporary directory.
const Rig = struct {
    tmp: testing.TmpDir,
    base: [:0]u8,
    env: Environ.Map,

    fn init(rig: *Rig) !void {
        const gpa = testing.allocator;
        rig.tmp = testing.tmpDir(.{});
        rig.base = try rig.tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        rig.env = Environ.Map.init(gpa);
        const adapters = try std.fs.path.join(gpa, &.{ rig.base, "adapters" });
        defer gpa.free(adapters);
        try rig.env.put("HARNESS_ADAPTERS_DIR", adapters);
        try rig.env.put("HOME", rig.base);
        net.setEnvOverride(&rig.env);
    }

    fn deinit(rig: *Rig) void {
        net.setEnvOverride(null);
        rig.env.deinit();
        testing.allocator.free(rig.base);
        rig.tmp.cleanup();
    }

    fn exists(rig: *Rig, sub: []const u8) bool {
        rig.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    /// Entries directly under `adapters/` (the `.tmp-*` dirs show here).
    fn adapterEntries(rig: *Rig) !usize {
        var dir = rig.tmp.dir.openDir(testing.io, "adapters", .{ .iterate = true }) catch return 0;
        defer dir.close(testing.io);
        var it = dir.iterate();
        var n: usize = 0;
        while (try it.next(testing.io)) |_| n += 1;
        return n;
    }
};

const InstallState = struct { pin: ArchivePin, result: ?(Error!net.Result([]u8)) = null };

fn installTask(s: *InstallState) void {
    s.result = ensureInstalled(testing.allocator, testing.io, s.pin, "Test");
}

fn noop(_: void) void {}

/// `ensureInstalled` under a 30 s deadline; the result's text, or null on success.
fn installGuarded(pin: ArchivePin) !?[]u8 {
    var s: InstallState = .{ .pin = pin };
    const g = try net.guard(testing.io, .{ .deadline_ms = 30_000 }, installTask, .{&s}, noop);
    if (g == .stopped) {
        if (s.result) |r| if (r) |v| switch (v) {
            .ok => |p| testing.allocator.free(p),
            .err => |f| f.deinit(testing.allocator),
        } else |_| {};
        return error.TestTimeout;
    }
    switch (try s.result.?) {
        .ok => |p| {
            testing.allocator.free(p);
            return null;
        },
        .err => |f| {
            defer f.deinit(testing.allocator);
            return try f.display(testing.allocator);
        },
    }
}

test "archive entries reject traversal, absolute names, links and special files" {
    const gpa = testing.allocator;
    try testing.expect(enclosedName("../x") == null);
    try testing.expect(enclosedName("a/../../x") == null);
    try testing.expect(enclosedName("/etc/passwd") == null);
    try testing.expect(enclosedName("a\x00b") == null);
    try testing.expectEqualStrings("a/../b", enclosedName("a/../b").?);
    const unsafe = try archiveEntryPath(gpa, "/safe/root", null, 0o100644);
    defer unsafe.err.deinit(gpa);
    try testing.expectEqualStrings("archive contains an unsafe entry path", unsafe.err.msg);
    const link = try archiveEntryPath(gpa, "/safe/root", "link", 0o120777);
    defer link.err.deinit(gpa);
    try testing.expectEqualStrings("archive entry link is a link or special file", link.err.msg);
    const dev = try archiveEntryPath(gpa, "/safe/root", "device", 0o020666);
    defer dev.err.deinit(gpa);
    const ok = try archiveEntryPath(gpa, "/safe/root", "bin/server", 0o100755);
    defer gpa.free(ok.ok);
    try testing.expectEqualStrings("/safe/root/bin/server", ok.ok);
    try testing.expectEqual(@as(?u32, null), unixMode(20, 0));
    try testing.expectEqual(@as(?u32, 0o120777), unixMode(3 << 8, 0o120777 << 16));
    try testing.expectEqual(@as(?u32, 0o040775), unixMode(0, 0x10));
}

test "archive extraction writes files, marks them executable, and rejects corrupt archives and links" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const zip = try testZip(gpa, &.{ .{ .name = "server.par", .data = "#!/bin/sh\n" }, .{ .name = "lib/", .data = "", .mode = 0o040755 }, .{ .name = "lib/helper", .data = "bin" } });
    defer gpa.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle.zip", .data = zip });
    const archive = try std.fs.path.join(gpa, &.{ base, "bundle.zip" });
    defer gpa.free(archive);
    const dest = try std.fs.path.join(gpa, &.{ base, "out" });
    defer gpa.free(dest);
    try tmp.dir.createDirPath(io, "out");
    try testing.expect((try extractZip(gpa, io, archive, dest)) == null);
    try markExecutables(io, dest);
    const helper = try tmp.dir.readFileAlloc(io, "out/lib/helper", gpa, .limited(64));
    defer gpa.free(helper);
    try testing.expectEqualStrings("bin", helper);
    if (!net.is_windows) {
        const st = try tmp.dir.statFile(io, "out/server.par", .{});
        try testing.expectEqual(@as(u32, 0o111), @as(u32, @intCast(st.permissions.toMode())) & 0o111);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "broken.zip", .data = "not a zip" });
    const broken = try std.fs.path.join(gpa, &.{ base, "broken.zip" });
    defer gpa.free(broken);
    const f = (try extractZip(gpa, io, broken, dest)).?;
    defer f.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, f.msg, "invalid zip archive: "));

    const linked = try testZip(gpa, &.{.{ .name = "evil", .data = "/etc/passwd", .mode = 0o120777 }});
    defer gpa.free(linked);
    try tmp.dir.writeFile(io, .{ .sub_path = "linked.zip", .data = linked });
    const linked_path = try std.fs.path.join(gpa, &.{ base, "linked.zip" });
    defer gpa.free(linked_path);
    const lf = (try extractZip(gpa, io, linked_path, dest)).?;
    defer lf.deinit(gpa);
    try testing.expectEqualStrings("archive entry evil is a link or special file", lf.msg);
    try testing.expect(!net.pathExists(io, "out/evil"));

    const sneaky = try testZip(gpa, &.{.{ .name = "../escape", .data = "x" }});
    defer gpa.free(sneaky);
    try tmp.dir.writeFile(io, .{ .sub_path = "sneaky.zip", .data = sneaky });
    const sneaky_path = try std.fs.path.join(gpa, &.{ base, "sneaky.zip" });
    defer gpa.free(sneaky_path);
    const sf = (try extractZip(gpa, io, sneaky_path, dest)).?;
    defer sf.deinit(gpa);
    try testing.expectEqualStrings("archive contains an unsafe entry path", sf.msg);
}

test "archive install verifies the pinned SHA-512, places the entry with its marker, and is idempotent" {
    if (net.is_windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const zip = try testZip(gpa, &.{ .{ .name = "agy_acp_server.par", .data = "#!/bin/sh\necho acp\n" }, .{ .name = "helper", .data = "h" } });
    defer gpa.free(zip);
    const sha = sha512Hex(zip);
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{.{ .path = "/agy.zip", .body = zip }});
    const url = try srv.url(gpa, "/agy.zip");
    defer gpa.free(url);
    const pin: ArchivePin = .{ .name = "test-acp", .version = "9.9.9", .url = url, .entry = "agy_acp_server.par", .sha512 = &sha };
    try testing.expect((try installGuarded(pin)) == null);
    srv.shutdown();
    const marker = try rig.tmp.dir.readFileAlloc(testing.io, "adapters/test-acp/9.9.9/.harness-install-ok", gpa, .limited(1024));
    defer gpa.free(marker);
    const want = try std.fmt.allocPrint(gpa, "{s}\n", .{&sha});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, marker);
    const st = try rig.tmp.dir.statFile(testing.io, "adapters/test-acp/9.9.9/agy_acp_server.par", .{});
    try testing.expect(@as(u32, @intCast(st.permissions.toMode())) & 0o111 != 0);
    try testing.expect(!rig.exists("adapters/test-acp/9.9.9/download.zip"));
    try testing.expectEqual(@as(usize, 1), try rig.adapterEntries());
    // The verified marker makes another install idempotent with the server gone.
    try testing.expect((try installGuarded(pin)) == null);
    const entry = (try installedEntry(gpa, testing.io, &rig.env, pin)).?;
    defer gpa.free(entry);
    try testing.expect(std.mem.endsWith(u8, entry, "test-acp/9.9.9/agy_acp_server.par"));
}

test "archive install rejects a checksum mismatch and leaves nothing behind" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const zip = try testZip(gpa, &.{.{ .name = "agy_acp_server.par", .data = "#!/bin/sh\n" }});
    defer gpa.free(zip);
    const wrong = sha512Hex("something else");
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{.{ .path = "/agy.zip", .body = zip }});
    defer srv.shutdown();
    const url = try srv.url(gpa, "/agy.zip");
    defer gpa.free(url);
    const pin: ArchivePin = .{ .name = "test-acp", .version = "1.0.0", .url = url, .entry = "agy_acp_server.par", .sha512 = &wrong };
    const msg = (try installGuarded(pin)).?;
    defer gpa.free(msg);
    const want = try std.fmt.allocPrint(gpa, "adapter install failed: download of the Test ACP server ({s}) failed: SHA-512 mismatch (expected {s}, got {s})", .{ url, &wrong, &sha512Hex(zip) });
    defer gpa.free(want);
    try testing.expectEqualStrings(want, msg);
    try testing.expect(!rig.exists("adapters/test-acp"));
    try testing.expectEqual(@as(usize, 0), try rig.adapterEntries());
}

test "archive install fails a stalled download and a missing entry" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const zip = try testZip(gpa, &.{.{ .name = "other", .data = "x" }});
    defer gpa.free(zip);
    const sha = sha512Hex(zip);
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{
        .{ .path = "/stall.zip", .body = zip, .stall_after = 4, .stall_ms = 10_000 },
        .{ .path = "/noentry.zip", .body = zip },
    });
    defer srv.shutdown();
    stall_timeout_ms = 1000;
    defer stall_timeout_ms = 60_000;
    const stall_url = try srv.url(gpa, "/stall.zip");
    defer gpa.free(stall_url);
    const started = net.nowNs(testing.io);
    const msg = (try installGuarded(.{ .name = "t", .version = "1", .url = stall_url, .entry = "other", .sha512 = &sha })).?;
    defer gpa.free(msg);
    const want = try std.fmt.allocPrint(gpa, "adapter install failed: download of the Test ACP server ({s}) failed: no data for 1s — check your network", .{stall_url});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, msg);
    try testing.expect(net.nowNs(testing.io) - started < 8 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 0), try rig.adapterEntries());

    const url = try srv.url(gpa, "/noentry.zip");
    defer gpa.free(url);
    const missing = (try installGuarded(.{ .name = "t", .version = "1", .url = url, .entry = "agy_acp_server.par", .sha512 = &sha })).?;
    defer gpa.free(missing);
    const want2 = try std.fmt.allocPrint(gpa, "adapter install failed: the Test archive ({s}) has no agy_acp_server.par", .{url});
    defer gpa.free(want2);
    try testing.expectEqualStrings(want2, missing);
}

test "archive install_harness without a pin is NotInstalled" {
    const gpa = testing.allocator;
    const f = (try installHarness(gpa, testing.io, true, null)).?;
    defer f.deinit(gpa);
    const t = try f.display(gpa);
    defer gpa.free(t);
    try testing.expectEqualStrings("harness binary not found: Set ANTIGRAVITY_ACP_EXECUTABLE to an installed ACP server", t);
}
