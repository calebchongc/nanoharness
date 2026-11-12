//! This engine's own updates (`UpdateStatus`, `CheckForUpdates`,
//! `QueueUpdate`, `ApplyUpdate`): the Zig port of `crates/update` as the
//! engine's RPCs use it.
//!
//! How the binary was installed decides the path (`detect_install`): a
//! managed install (`~/.harness/app/<ver>` behind `current`) stages the
//! release tarball, verifies its manifest SHA-256, repoints `current` and
//! restarts; a macOS app bundle only reports (its UI installs); anything else
//! (source builds, copied binaries) is report-only and never checks. Managed
//! and app installs run a background release check: 20 s after start, then
//! hourly on the wall clock (1, 5, 15, 30 min after failures).
//!
//! Network, commands and the restart go through seams (`Http`,
//! `proc_seam.Runner`, `Restarter`) so tests answer from made-up releases
//! and never install or restart anything.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const proc = @import("proc_seam.zig");

pub const check_interval_ms: i64 = 60 * 60 * 1000;
pub const check_backoff_ms = [_]i64{ 60_000, 5 * 60_000, 15 * 60_000, 30 * 60_000 };
pub const check_initial_delay_ms: i64 = 20_000;
pub const idle_recheck_ms: i64 = 5 * 60_000;
pub const launchd_label = "harness.codegraff.app";
pub const github_latest = "https://github.com/justrach/harness/releases/latest/download";

// ---------------------------------------------------------------- pure rules

/// Strictly-newer dotted-numeric compare; unparseable versions never count as newer.
pub fn versionNewer(latest: []const u8, current: []const u8) bool {
    var a: [16]u64 = undefined;
    var b: [16]u64 = undefined;
    const la = parts(latest, &a) orelse return false;
    const lb = parts(current, &b) orelse return false;
    return std.mem.order(u64, la, lb) == .gt;
}

fn parts(v: []const u8, out: *[16]u64) ?[]const u64 {
    const t = std.mem.trimStart(u8, std.mem.trim(u8, v, " \t\r\n"), "v");
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, '.');
    while (it.next()) |p| {
        if (n == out.len) return null;
        out[n] = std.fmt.parseInt(u64, p, 10) catch return null;
        n += 1;
    }
    return if (n == 0) null else out[0..n];
}

pub fn platformKey() struct { os: []const u8, arch: []const u8 } {
    const os: []const u8 = @tagName(builtin.os.tag);
    const arch: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => if (builtin.os.tag == .macos) "arm64" else "aarch64",
        else => @tagName(builtin.cpu.arch),
    };
    return .{ .os = os, .arch = arch };
}

/// `harness-<ver>-<os>-<arch>.tar.gz`.
pub fn headlessArtifactAlloc(gpa: Allocator, version: []const u8) ![]u8 {
    const k = platformKey();
    return std.fmt.allocPrint(gpa, "harness-{s}-{s}-{s}.tar.gz", .{ version, k.os, k.arch });
}

pub fn autoUpdateFrom(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return true, " \t\r\n");
    var buf: [8]u8 = undefined;
    if (v.len > buf.len) return true;
    const low = std.ascii.lowerString(&buf, v);
    for ([_][]const u8{ "0", "false", "no", "off" }) |off| if (std.mem.eql(u8, low, off)) return false;
    return true;
}

pub fn supervisedBy(invocation_id: ?[]const u8, xpc_service: ?[]const u8) bool {
    if (invocation_id) |i| if (i.len > 0) return true;
    return if (xpc_service) |x| std.mem.eql(u8, x, launchd_label) else false;
}

pub fn nextCheckDelayMs(ok: bool, failures: u32) i64 {
    if (ok) return check_interval_ms;
    const step = @min(@as(usize, @max(failures, 1)) - 1, check_backoff_ms.len - 1);
    return check_backoff_ms[step];
}

/// Due on the wall clock; a due time more than an interval ahead means the clock went back.
pub fn checkDue(now_ms: i64, due_ms: i64) bool {
    return now_ms >= due_ms or due_ms - now_ms > check_interval_ms;
}

pub const InstallKind = enum { managed, mac_app, unmanaged };

pub const Install = struct {
    kind: InstallKind,
    /// `app_root` for managed installs, the bundle for app installs.
    path: []const u8 = "",

    pub fn checksReleases(self: Install) bool {
        return self.kind != .unmanaged;
    }
};

/// `detect_install_from`: `is_dev_bundle(bundle)` reads the bundle's identifier.
pub fn detectInstallFrom(exe: []const u8, home: ?[]const u8, os: std.Target.Os.Tag, buf: []u8, ctx: anytype, isDevBundle: fn (@TypeOf(ctx), []const u8) bool) Install {
    if (os != .linux and os != .macos) return .{ .kind = .unmanaged };
    if (home) |h| {
        const root = std.fmt.bufPrint(buf, "{s}/.harness/app", .{std.mem.trimEnd(u8, h, "/")}) catch return .{ .kind = .unmanaged };
        if (std.mem.startsWith(u8, exe, root) and (exe.len == root.len or exe[root.len] == '/')) return .{ .kind = .managed, .path = root };
    }
    var end: usize = exe.len;
    while (std.mem.lastIndexOfScalar(u8, exe[0..end], '/')) |slash| {
        const ancestor = exe[0..slash];
        if (std.mem.endsWith(u8, ancestor, ".app") and std.mem.startsWith(u8, exe[slash..], "/Contents/MacOS/")) {
            if (isDevBundle(ctx, ancestor)) return .{ .kind = .unmanaged };
            return .{ .kind = .mac_app, .path = ancestor };
        }
        end = slash;
    }
    return .{ .kind = .unmanaged };
}

/// The `CFBundleIdentifier` string of an XML Info.plist.
pub fn plistBundleId(text: []const u8) ?[]const u8 {
    const key = "<key>CFBundleIdentifier</key>";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const open = std.mem.indexOf(u8, rest, "<string>") orelse return null;
    const after = rest[open + "<string>".len ..];
    const close = std.mem.indexOf(u8, after, "</string>") orelse return null;
    return std.mem.trim(u8, after[0..close], " \t\r\n");
}

/// `HARNESS_RELEASES_URL` must be an https base URL without credentials, query or fragment.
pub fn validateReleaseOverride(gpa: Allocator, value: []const u8) union(enum) { ok: []u8, err: []const u8 } {
    const v = std.mem.trim(u8, value, " \t\r\n");
    const uri = std.Uri.parse(v) catch return .{ .err = "invalid update feed URL" };
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null) return .{ .err = "update feed must use HTTPS" };
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return .{ .err = "update feed must be a base URL without credentials, query, or fragment" };
    return .{ .ok = gpa.dupe(u8, std.mem.trimEnd(u8, v, "/")) catch return .{ .err = "out of memory" } };
}

// ---------------------------------------------------------------- seams

pub const HttpReply = struct { status: u16, body: []u8 };

pub const Http = struct {
    ctx: ?*anyopaque = null,
    get_fn: *const fn (ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror!HttpReply,

    pub fn get(self: Http, gpa: Allocator, url: []const u8) anyerror!HttpReply {
        return self.get_fn(self.ctx, gpa, url);
    }
};

pub const RestartKind = enum { service, reexec };

pub const Restarter = struct {
    ctx: ?*anyopaque = null,
    /// Called on a background thread after the reply has had time to flush.
    restart_fn: *const fn (ctx: ?*anyopaque, app_root: []const u8) void,
};

// ---------------------------------------------------------------- state

pub const Phase = enum { idle, checking, downloading, waitingForIdle, restarting, failed };
pub const Mode = enum { managed, desktop, manual };

pub const Updater = struct {
    gpa: Allocator,
    io: ?std.Io,
    install: Install,
    automatic: bool,
    edge_url: []const u8,
    current_version: []const u8,
    /// `HARNESS_RELEASES_URL`, when set.
    releases_override: ?[]const u8 = null,
    http: Http,
    runner: proc.Runner,
    restarter: Restarter,
    /// Nothing would be interrupted by a restart now (no live run, no open terminal).
    quiescent_ctx: ?*anyopaque = null,
    quiescent_fn: ?*const fn (ctx: ?*anyopaque) bool = null,

    mutex: std.Io.Mutex = .init,
    latest: ?[]u8 = null,
    available: bool = false,
    checked_at: ?i64 = null,
    err: ?[]u8 = null,
    phase: Phase = .idle,
    requested: bool = false,
    wake_seq: u64 = 0,
    shutting_down: bool = false,
    last_reply_err: ?[]u8 = null,

    pub fn deinit(self: *Updater) void {
        if (self.latest) |l| self.gpa.free(l);
        if (self.err) |e| self.gpa.free(e);
        if (self.last_reply_err) |e| self.gpa.free(e);
    }

    fn lock(self: *Updater) void {
        if (self.io) |io| self.mutex.lockUncancelable(io);
    }

    fn unlock(self: *Updater) void {
        if (self.io) |io| self.mutex.unlock(io);
    }

    pub fn mode(self: *const Updater) Mode {
        return switch (self.install.kind) {
            .managed => .managed,
            .mac_app => .desktop,
            .unmanaged => .manual,
        };
    }

    /// The `UpdateStatus` item (optional fields left out when unset).
    pub fn statusJson(self: *Updater, gpa: Allocator) ![]u8 {
        self.lock();
        defer self.unlock();
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\"currentVersion\":{f}", .{json.fmt(self.current_version, .{})});
        if (self.latest) |l| try w.print(",\"latestVersion\":{f}", .{json.fmt(l, .{})});
        try w.print(",\"updateAvailable\":{}", .{self.available});
        if (self.checked_at) |c| try w.print(",\"checkedAt\":{d}", .{c});
        if (self.err) |e| try w.print(",\"error\":{f}", .{json.fmt(e, .{})});
        try w.print(",\"host\":{{\"mode\":\"{s}\",\"automatic\":{},\"phase\":\"{s}\"}}}}", .{ @tagName(self.mode()), self.automatic, @tagName(self.phase) });
        return aw.toOwnedSlice();
    }

    fn setPhase(self: *Updater, p: Phase) void {
        self.lock();
        defer self.unlock();
        self.phase = p;
    }

    fn failWith(self: *Updater, msg: []u8) void {
        self.lock();
        defer self.unlock();
        if (self.err) |e| self.gpa.free(e);
        self.err = msg;
        self.phase = .failed;
    }

    pub fn checkNow(self: *Updater) void {
        self.lock();
        defer self.unlock();
        self.wake_seq +%= 1;
    }

    /// `QueueUpdate`: one managed-host update; coalesces, never bypasses the idle gate.
    pub fn queueUpdate(self: *Updater) ?[]const u8 {
        if (self.install.kind != .managed) return "this device cannot queue a remote update; update its desktop app or package locally";
        self.lock();
        defer self.unlock();
        if (self.shutting_down) return "the updater is shutting down";
        self.requested = true;
        self.wake_seq +%= 1;
        return null;
    }

    fn releaseBase(self: *const Updater, gpa: Allocator) ![]u8 {
        if (self.releases_override) |o| return gpa.dupe(u8, o);
        if (self.install.kind != .unmanaged) return gpa.dupe(u8, github_latest);
        return std.fmt.allocPrint(gpa, "{s}/releases", .{std.mem.trimEnd(u8, self.edge_url, "/")});
    }

    pub const Manifest = struct {
        version: []const u8,
        /// The artifact's `sha256`, when the manifest lists one.
        files: ?json.ObjectMap = null,

        pub fn sha256For(self: Manifest, file: []const u8) ?[]const u8 {
            const files = self.files orelse return null;
            const meta = files.get(file) orelse return null;
            if (meta != .object) return null;
            const s = meta.object.get("sha256") orelse return null;
            return if (s == .string) s.string else null;
        }
    };

    /// `manifest.json`, falling back to `latest.txt`. Error → message (arena).
    pub fn fetchLatest(self: *Updater, arena: Allocator) !union(enum) { ok: Manifest, err: []const u8 } {
        const base = try self.releaseBase(arena);
        const murl = try std.fmt.allocPrint(arena, "{s}/manifest.json", .{base});
        if (self.http.get(arena, murl)) |r| {
            if (r.status >= 200 and r.status < 300) {
                const v = json.parseFromSliceLeaky(json.Value, arena, r.body, .{}) catch
                    return .{ .err = "parsing manifest.json: invalid JSON" };
                const ver = if (v == .object) v.object.get("version") else null;
                if (ver == null or ver.? != .string) return .{ .err = "parsing manifest.json: missing field `version`" };
                if (std.mem.trim(u8, ver.?.string, " \t\r\n").len == 0) return .{ .err = "manifest.json has an empty version" };
                const files = v.object.get("files");
                return .{ .ok = .{ .version = ver.?.string, .files = if (files) |f| (if (f == .object) f.object else null) else null } };
            }
        } else |_| {}
        const lurl = try std.fmt.allocPrint(arena, "{s}/latest.txt", .{base});
        const r = self.http.get(arena, lurl) catch |e|
            return .{ .err = try std.fmt.allocPrint(arena, "fetching latest.txt: {s}", .{@errorName(e)}) };
        if (r.status < 200 or r.status >= 300)
            return .{ .err = try std.fmt.allocPrint(arena, "fetching latest.txt: HTTP status {d}", .{r.status}) };
        const ver = std.mem.trim(u8, r.body, " \t\r\n");
        if (ver.len == 0) return .{ .err = "latest.txt is empty" };
        return .{ .ok = .{ .version = ver } };
    }

    /// One check; false on failure (retry sooner).
    pub fn checkOnce(self: *Updater, now_ms: i64) !bool {
        self.setPhase(.checking);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        switch (try self.fetchLatest(arena_state.allocator())) {
            .ok => |m| {
                const latest = try self.gpa.dupe(u8, m.version);
                self.lock();
                defer self.unlock();
                if (self.latest) |l| self.gpa.free(l);
                self.latest = latest;
                self.available = versionNewer(m.version, self.current_version);
                self.checked_at = now_ms;
                if (self.err) |e| self.gpa.free(e);
                self.err = null;
                self.phase = .idle;
                return true;
            },
            .err => |e| {
                self.failWith(try self.gpa.dupe(u8, e));
                return false;
            },
        }
    }

    /// Download `file` into `dest`, verifying the manifest's SHA-256 when it has one.
    fn download(self: *Updater, arena: Allocator, io: std.Io, m: Manifest, file: []const u8, dest: []const u8) !?[]const u8 {
        const base = try self.releaseBase(arena);
        const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, file });
        const r = self.http.get(arena, url) catch |e|
            return try std.fmt.allocPrint(arena, "downloading {s}: {s}", .{ url, @errorName(e) });
        if (r.status < 200 or r.status >= 300)
            return try std.fmt.allocPrint(arena, "downloading {s}: HTTP status {d}", .{ url, r.status });
        if (m.sha256For(file)) |expected| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(r.body, &digest, .{});
            const actual = std.fmt.bytesToHex(digest, .lower);
            if (!std.ascii.eqlIgnoreCase(&actual, std.mem.trim(u8, expected, " \t\r\n")))
                return try std.fmt.allocPrint(arena, "checksum mismatch for {s}: expected {s}, got {s}", .{ file, expected, &actual });
        }
        const partial = try std.fmt.allocPrint(arena, "{s}.partial", .{dest});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = r.body }) catch |e|
            return try std.fmt.allocPrint(arena, "creating {s}: {s}", .{ partial, @errorName(e) });
        std.Io.Dir.rename(std.Io.Dir.cwd(), partial, std.Io.Dir.cwd(), dest, io) catch |e|
            return try std.fmt.allocPrint(arena, "moving {s} into place: {s}", .{ dest, @errorName(e) });
        return null;
    }

    /// Download and unpack the headless tarball into `app_root/<ver>` (idempotent).
    pub fn stageHeadless(self: *Updater, arena: Allocator, m: Manifest, app_root: []const u8) !?[]const u8 {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos)
            return try std.fmt.allocPrint(arena, "managed updates are not supported on {s}", .{@tagName(builtin.os.tag)});
        const io = self.io orelse return "updates need file access";
        const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app_root, m.version });
        const dest_bin = try std.fmt.allocPrint(arena, "{s}/harness", .{dest});
        if (exists(io, dest_bin)) return null;
        const file = try headlessArtifactAlloc(arena, m.version);
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const stage = try std.fmt.allocPrint(arena, "{s}/.stage-{s}-{x}", .{ app_root, m.version, rnd });
        std.Io.Dir.cwd().deleteTree(io, stage) catch {};
        std.Io.Dir.cwd().createDirPath(io, stage) catch |e|
            return try std.fmt.allocPrint(arena, "creating {s}: {s}", .{ stage, @errorName(e) });
        defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};
        const tarball = try std.fmt.allocPrint(arena, "{s}/{s}", .{ stage, file });
        if (try self.download(arena, io, m, file, tarball)) |e| return e;
        const unpacked = try std.fmt.allocPrint(arena, "{s}/unpacked", .{stage});
        std.Io.Dir.cwd().createDirPath(io, unpacked) catch |e|
            return try std.fmt.allocPrint(arena, "creating {s}: {s}", .{ unpacked, @errorName(e) });
        var out = try self.runner.run(arena, .{ .argv = &.{ "tar", "-xzf", tarball, "-C", unpacked, "--strip-components=1" }, .timeout_ms = 10 * 60_000 });
        if (!out.ok()) {
            return try std.fmt.allocPrint(arena, "tar -xzf {s} -C {s} --strip-components=1 failed ({s}): {s}", .{
                tarball, unpacked, @tagName(out.term), std.mem.trim(u8, out.stderr, " \t\r\n"),
            });
        }
        const bin = try std.fmt.allocPrint(arena, "{s}/harness", .{unpacked});
        if (!exists(io, bin)) return try std.fmt.allocPrint(arena, "tarball {s} did not contain a harness binary", .{file});
        std.Io.Dir.rename(std.Io.Dir.cwd(), unpacked, std.Io.Dir.cwd(), dest, io) catch |e| {
            if (!exists(io, dest_bin)) return try std.fmt.allocPrint(arena, "moving {s} into place: {s}", .{ dest, @errorName(e) });
        };
        return null;
    }

    /// Atomically repoint `app_root/current` at `app_root/<ver>`.
    pub fn applyHeadless(self: *Updater, arena: Allocator, app_root: []const u8, version: []const u8) !?[]const u8 {
        const io = self.io orelse return "updates need file access";
        const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app_root, version });
        if (!exists(io, try std.fmt.allocPrint(arena, "{s}/harness", .{target})))
            return try std.fmt.allocPrint(arena, "{s} is not a staged install", .{target});
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const tmp = try std.fmt.allocPrint(arena, "{s}/.current-{x}", .{ app_root, rnd });
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        std.Io.Dir.cwd().symLink(io, target, tmp, .{ .is_directory = true }) catch |e|
            return try std.fmt.allocPrint(arena, "creating current symlink: {s}", .{@errorName(e)});
        const current = try std.fmt.allocPrint(arena, "{s}/current", .{app_root});
        std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), current, io) catch |e|
            return try std.fmt.allocPrint(arena, "swapping current symlink: {s}", .{@errorName(e)});
        return null;
    }

    pub const ApplyResult = union(enum) { version: []u8, err: []const u8 };

    /// `ApplyUpdate`: stage and apply the newest release on this device (managed only), then restart.
    pub fn apply(self: *Updater, reply_gpa: Allocator) !ApplyResult {
        if (self.install.kind != .managed)
            return .{ .err = "this install is not update-managed — the desktop app updates from its UI; source builds update via git" };
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const m = switch (try self.fetchLatest(arena)) {
            .ok => |m| m,
            .err => |e| return .{ .err = self.keepErr(e) },
        };
        if (!versionNewer(m.version, self.current_version))
            return .{ .err = self.keepErr(try std.fmt.allocPrint(arena, "already up to date ({s})", .{self.current_version})) };
        if (try self.stageHeadless(arena, m, self.install.path)) |e| return .{ .err = self.keepErr(e) };
        if (try self.applyHeadless(arena, self.install.path, m.version)) |e| return .{ .err = self.keepErr(e) };
        self.restarter.restart_fn(self.restarter.ctx, self.install.path);
        return .{ .version = try reply_gpa.dupe(u8, m.version) };
    }

    fn keepErr(self: *Updater, msg: []const u8) []const u8 {
        const copy = self.gpa.dupe(u8, msg) catch return "out of memory";
        if (self.last_reply_err) |old| self.gpa.free(old);
        self.last_reply_err = copy;
        return copy;
    }

    fn quiescentNow(self: *Updater) bool {
        const f = self.quiescent_fn orelse return true;
        return f(self.quiescent_ctx);
    }

    /// Stage while busy, install only once idle (managed installs, automatic or requested).
    pub fn autoApplyWhenIdle(self: *Updater, sleeper: anytype) !?[]u8 {
        if (self.install.kind != .managed) return try self.gpa.dupe(u8, "not a managed install");
        self.setPhase(.downloading);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const m = switch (try self.fetchLatest(arena)) {
            .ok => |m| m,
            .err => |e| return try self.gpa.dupe(u8, e),
        };
        {
            const latest = try self.gpa.dupe(u8, m.version);
            self.lock();
            if (self.latest) |l| self.gpa.free(l);
            self.latest = latest;
            self.available = versionNewer(m.version, self.current_version);
            self.unlock();
        }
        if (!versionNewer(m.version, self.current_version)) {
            self.lock();
            self.phase = .idle;
            self.requested = false;
            self.unlock();
            return null;
        }
        if (try self.stageHeadless(arena, m, self.install.path)) |e| return try self.gpa.dupe(u8, e);
        while (true) {
            self.setPhase(.waitingForIdle);
            while (!self.quiescentNow()) {
                if (!sleeper.sleep(idle_recheck_ms)) return null;
            }
            if (!sleeper.sleep(800)) return null;
            if (self.quiescentNow()) break;
        }
        if (try self.applyHeadless(arena, self.install.path, m.version)) |e| return try self.gpa.dupe(u8, e);
        self.lock();
        self.phase = .restarting;
        self.requested = false;
        self.unlock();
        self.restarter.restart_fn(self.restarter.ctx, self.install.path);
        return null;
    }
};

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------- RPCs

pub const Reply = union(enum) { ok: []u8, failed: []const u8, bad_params: []const u8 };
pub const Method = enum { status, check, queue, apply };

/// `targetDeviceId` names another device: this engine has no relay link to forward over.
pub fn targetProblem(params: json.Value, local_device: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const t = params.object.get("targetDeviceId") orelse return null;
    if (t != .string) return "invalid type for `targetDeviceId`, expected a string";
    if (std.mem.eql(u8, t.string, local_device)) return null;
    return "target device not connected";
}

pub fn handle(u: *Updater, reply_gpa: Allocator, method: Method) !Reply {
    switch (method) {
        .status => return .{ .ok = try u.statusJson(reply_gpa) },
        .check => {
            u.checkNow();
            return .{ .ok = try reply_gpa.dupe(u8, "{\"ok\":true}") };
        },
        .queue => {
            if (u.queueUpdate()) |e| return .{ .failed = e };
            return .{ .ok = try reply_gpa.dupe(u8, "{\"ok\":true,\"queued\":true}") };
        },
        .apply => switch (try u.apply(reply_gpa)) {
            .err => |e| return .{ .failed = e },
            .version => |v| {
                defer reply_gpa.free(v);
                return .{ .ok = try std.fmt.allocPrint(reply_gpa, "{{\"ok\":true,\"version\":{f}}}", .{json.fmt(v, .{})}) };
            },
        },
    }
}

// ---------------------------------------------------------------- the engine's wiring

/// The engine's watch target for `UpdateStatus` subscribers. The host has no
/// dedicated watch kind for it, so pushes ride the per-client
/// `doc_messages` delivery under a target no chat id can take (chat ids are
/// `[A-Za-z0-9_-]`); cancel and disconnect remove it like any watch.
pub const watch_target = "\x00update-status";

const Engine = struct {
    updater: Updater,
    sys_runner: proc.SystemRunner,
    host: *anyopaque,
    started: bool = false,
};

var engine_state: ?Engine = null;

fn stdGet(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror!HttpReply {
    const io: *std.Io = @ptrCast(@alignCast(ctx.?));
    var client: std.http.Client = .{ .allocator = gpa, .io = io.* };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = "harness-engine-zig" } },
    });
    return .{ .status = @intFromEnum(res.status), .body = try aw.toOwnedSlice() };
}

var engine_io: std.Io = undefined;

/// The engine's updater for `host` (an `*EngineHost`), started once: the
/// release check thread runs for managed and app installs.
pub fn forEngine(comptime Host: type, host: *Host) !*Updater {
    if (engine_state) |*e| return &e.updater;
    const gpa = std.heap.smp_allocator;
    var install: Install = .{ .kind = .unmanaged };
    var exe_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    if (host.io) |io| {
        engine_io = io;
        if (std.process.executablePath(io, &exe_buf)) |n| {
            const found = detectInstallFrom(exe_buf[0..n], proc.getenv("HOME"), builtin.os.tag, &root_buf, io, isDevBundleAt);
            install = .{ .kind = found.kind, .path = try gpa.dupe(u8, found.path) };
        } else |_| {}
    }
    var override: ?[]const u8 = null;
    if (proc.getenv("HARNESS_RELEASES_URL")) |raw| if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
        switch (validateReleaseOverride(gpa, raw)) {
            .ok => |o| override = o,
            .err => {},
        }
    };
    engine_state = .{
        .host = host,
        .sys_runner = .{ .io = engine_io },
        .updater = .{
            .gpa = gpa,
            .io = host.io,
            .install = install,
            .automatic = autoUpdateFrom(proc.getenv("HARNESS_AUTO_UPDATE")),
            .edge_url = try gpa.dupe(u8, host.auth.edge_url orelse ""),
            .current_version = @import("build_info").version,
            .releases_override = override,
            .http = .{ .ctx = &engine_io, .get_fn = stdGet },
            .runner = .{ .run_fn = noSpawn },
            .restarter = .{ .restart_fn = Wiring(Host).restart },
            .quiescent_fn = Wiring(Host).quiescent,
        },
    };
    const e = &engine_state.?;
    e.updater.quiescent_ctx = host;
    e.updater.restarter.ctx = host;
    if (host.io != null) e.updater.runner = e.sys_runner.runner();
    if (host.io != null and install.checksReleases()) {
        _ = host.bg_workers_active.fetchAdd(1, .acq_rel);
        if (std.Thread.spawn(.{}, Wiring(Host).loop, .{host})) |th| {
            th.detach();
            e.started = true;
        } else |_| {
            _ = host.bg_workers_active.fetchSub(1, .acq_rel);
        }
    }
    return &e.updater;
}

fn noSpawn(_: ?*anyopaque, gpa: Allocator, _: proc.Request) Allocator.Error!proc.Output {
    return .{ .term = .spawn_failed, .stdout = try gpa.dupe(u8, ""), .stderr = try gpa.dupe(u8, "") };
}

fn isDevBundleAt(io: std.Io, bundle: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/Contents/Info.plist", .{bundle}) catch return false;
    var tbuf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tbuf);
    const text = std.Io.Dir.cwd().readFileAlloc(io, p, fba.allocator(), .limited(tbuf.len - 1)) catch return false;
    const id = plistBundleId(text) orelse return false;
    return std.mem.endsWith(u8, id, ".dev");
}

fn Wiring(comptime Host: type) type {
    return struct {
        fn stopped(host: *Host) bool {
            const io = host.io.?;
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            return host.stop_requested;
        }

        fn quiescent(ctx: ?*anyopaque) bool {
            const host: *Host = @ptrCast(@alignCast(ctx.?));
            const io = host.io orelse return true;
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            var docs = host.docs.iterator();
            while (docs.next()) |e| if (e.value_ptr.hasActiveWork()) return false;
            var terms = host.terminals.sessions.iterator();
            while (terms.next()) |t| if (!t.value_ptr.exited) return false;
            return true;
        }

        fn publish(host: *Host) void {
            const u = &engine_state.?.updater;
            const body = u.statusJson(host.gpa) catch return;
            defer host.gpa.free(body);
            const io = host.io.?;
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            host.broadcastWatch(.doc_messages, watch_target, body) catch {};
        }

        const Sleeper = struct {
            host: *Host,
            /// Sleep up to `ms`, waking early on `CheckForUpdates`; false once the engine stops.
            pub fn sleep(self: @This(), ms: i64) bool {
                return sleepUntil(self.host, ms, false);
            }
        };

        fn sleepUntil(host: *Host, ms: i64, wake_on_check: bool) bool {
            const u = &engine_state.?.updater;
            const io = host.io.?;
            u.lock();
            const seq = u.wake_seq;
            u.unlock();
            var waited: i64 = 0;
            while (waited < ms) : (waited += 250) {
                std.Io.sleep(io, .fromMilliseconds(250), .awake) catch return false;
                if (stopped(host)) return false;
                if (wake_on_check) {
                    u.lock();
                    const now_seq = u.wake_seq;
                    u.unlock();
                    if (now_seq != seq) return true;
                }
            }
            return true;
        }

        fn loop(host: *Host) void {
            defer _ = host.bg_workers_active.fetchSub(1, .acq_rel);
            const u = &engine_state.?.updater;
            if (!sleepUntil(host, check_initial_delay_ms, true)) return;
            var failures: u32 = 0;
            while (!stopped(host)) {
                var ok = u.checkOnce(host.nowMs()) catch false;
                publish(host);
                u.lock();
                const go = ok and u.available and (u.automatic or u.requested) and u.install.kind == .managed;
                if (ok and !go) u.requested = false;
                u.unlock();
                if (go) {
                    if (u.autoApplyWhenIdle(Sleeper{ .host = host }) catch null) |msg| {
                        u.failWith(msg);
                        ok = false;
                    }
                    publish(host);
                }
                failures = if (ok) 0 else failures +| 1;
                const due = host.nowMs() + nextCheckDelayMs(ok, failures);
                u.lock();
                const seq = u.wake_seq;
                u.unlock();
                while (true) {
                    std.Io.sleep(host.io.?, .fromMilliseconds(250), .awake) catch return;
                    if (stopped(host)) return;
                    if (checkDue(host.nowMs(), due)) break;
                    u.lock();
                    const now_seq = u.wake_seq;
                    u.unlock();
                    if (now_seq != seq) break;
                }
            }
        }

        /// After a short delay (the RPC reply flushes): restart the service, else re-exec.
        fn restart(ctx: ?*anyopaque, app_root: []const u8) void {
            const host: *Host = @ptrCast(@alignCast(ctx.?));
            const root = std.heap.smp_allocator.dupe(u8, app_root) catch return;
            const th = std.Thread.spawn(.{}, restartLater, .{ host, root }) catch {
                std.heap.smp_allocator.free(root);
                return;
            };
            th.detach();
        }

        fn restartLater(host: *Host, app_root: []u8) void {
            defer std.heap.smp_allocator.free(app_root);
            const io = host.io orelse return;
            std.Io.sleep(io, .fromMilliseconds(800), .awake) catch return;
            if (supervisedBy(proc.getenv("INVOCATION_ID"), proc.getenv("XPC_SERVICE_NAME"))) {
                if (restartService(io)) return;
            }
            reexec(host, io, app_root);
        }

        fn restartService(io: std.Io) bool {
            var sys: proc.SystemRunner = .{ .io = io };
            const gpa = std.heap.smp_allocator;
            if (builtin.os.tag == .macos) {
                var id = sys.runner().run(gpa, .{ .argv = &.{ "id", "-u" }, .timeout_ms = 10_000 }) catch return false;
                defer id.deinit(gpa);
                const target = std.fmt.allocPrint(gpa, "gui/{s}/" ++ launchd_label, .{std.mem.trim(u8, id.stdout, " \t\r\n")}) catch return false;
                defer gpa.free(target);
                var out = sys.runner().run(gpa, .{ .argv = &.{ "launchctl", "kickstart", "-k", target }, .timeout_ms = 30_000 }) catch return false;
                defer out.deinit(gpa);
                return out.ok();
            }
            var out = sys.runner().run(gpa, .{ .argv = &.{ "systemctl", "--user", "restart", "harness.service" }, .timeout_ms = 30_000 }) catch return false;
            defer out.deinit(gpa);
            return out.ok();
        }

        /// Replace this process with `app_root/current/harness`, same arguments.
        fn reexec(host: *Host, io: std.Io, app_root: []const u8) void {
            {
                host.mutex.lockUncancelable(io);
                defer host.mutex.unlock(io);
                host.stop_requested = true;
            }
            const gpa = std.heap.smp_allocator;
            var argv: std.ArrayList([]const u8) = .empty;
            const exe = std.fmt.allocPrint(gpa, "{s}/current/harness", .{app_root}) catch return;
            argv.append(gpa, exe) catch return;
            ownArgs(gpa, &argv);
            std.Io.sleep(io, .fromMilliseconds(400), .awake) catch {};
            const failed = std.process.replace(io, .{ .argv = argv.items });
            std.log.err("harness-engine: restarting into the updated release failed: {t}", .{failed});
        }

        fn ownArgs(gpa: Allocator, argv: *std.ArrayList([]const u8)) void {
            if (builtin.os.tag == .macos) {
                const C = struct {
                    extern "c" fn _NSGetArgc() *c_int;
                    extern "c" fn _NSGetArgv() *[*][*:0]u8;
                };
                const argc: usize = @intCast(C._NSGetArgc().*);
                const raw = C._NSGetArgv().*;
                var i: usize = 1;
                while (i < argc) : (i += 1) argv.append(gpa, std.mem.span(raw[i])) catch return;
            } else if (builtin.os.tag == .linux) {
                const io = engine_io;
                const text = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/cmdline", gpa, .limited(1 << 20)) catch return;
                var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\x00"), 0);
                _ = it.next();
                while (it.next()) |a| argv.append(gpa, a) catch return;
            }
        }
    };
}

pub fn toOutcome(comptime Outcome: type, r: Reply) Outcome {
    return switch (r) {
        .ok => |body| .{ .unary_json = body },
        .bad_params => |m| .{ .err = .{ .bad_params = m } },
        .failed => |m| .{ .err = .{ .exec_error = m } },
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "updates: versions compare numerically and garbage never counts as newer" {
    try testing.expect(versionNewer("0.1.10", "0.1.9"));
    try testing.expect(versionNewer("v0.2.0", "0.1.99"));
    try testing.expect(versionNewer("0.1.1", "0.1"));
    try testing.expect(!versionNewer("0.1.9", "0.1.10"));
    try testing.expect(!versionNewer("0.1.9", "0.1.9"));
    try testing.expect(!versionNewer("garbage", "0.1.0"));
    try testing.expect(!versionNewer("", "0.1.0"));
}

test "updates: auto-update and supervision switches" {
    try testing.expect(autoUpdateFrom(null));
    try testing.expect(autoUpdateFrom("1"));
    try testing.expect(!autoUpdateFrom(" OFF "));
    try testing.expect(!autoUpdateFrom("no"));
    try testing.expect(supervisedBy("abc", null));
    try testing.expect(supervisedBy(null, launchd_label));
    try testing.expect(!supervisedBy("", "other"));
    try testing.expectEqual(check_interval_ms, nextCheckDelayMs(true, 0));
    try testing.expectEqual(@as(i64, 60_000), nextCheckDelayMs(false, 1));
    try testing.expectEqual(@as(i64, 30 * 60_000), nextCheckDelayMs(false, 9));
    try testing.expect(checkDue(10, 5));
    try testing.expect(!checkDue(10, 20));
    try testing.expect(checkDue(10, 10 + check_interval_ms + 1));
}

const NotDev = struct {
    fn f(_: void, _: []const u8) bool {
        return false;
    }
    fn dev(_: void, _: []const u8) bool {
        return true;
    }
};

test "updates: install detection" {
    var buf: [256]u8 = undefined;
    const managed = detectInstallFrom("/home/u/.harness/app/0.2.1/harness", "/home/u", .linux, &buf, {}, NotDev.f);
    try testing.expectEqual(InstallKind.managed, managed.kind);
    try testing.expectEqualStrings("/home/u/.harness/app", managed.path);
    const app = detectInstallFrom("/Applications/Harness.app/Contents/MacOS/harness", "/Users/u", .macos, &buf, {}, NotDev.f);
    try testing.expectEqual(InstallKind.mac_app, app.kind);
    try testing.expectEqualStrings("/Applications/Harness.app", app.path);
    try testing.expectEqual(InstallKind.unmanaged, detectInstallFrom("/Applications/Harness.app/Contents/MacOS/harness", null, .macos, &buf, {}, NotDev.dev).kind);
    try testing.expectEqual(InstallKind.unmanaged, detectInstallFrom("/src/zig-out/bin/harness-engine", "/Users/u", .macos, &buf, {}, NotDev.f).kind);
    try testing.expectEqual(InstallKind.unmanaged, detectInstallFrom("C:/Users/u/.harness/app/1/harness", "C:/Users/u", .windows, &buf, {}, NotDev.f).kind);
    try testing.expectEqualStrings("harness.codegraff.app.dev", plistBundleId("<dict><key>CFBundleIdentifier</key>\n  <string>harness.codegraff.app.dev</string></dict>").?);
}

test "updates: release feed override must be a plain https base" {
    const ok = validateReleaseOverride(testing.allocator, " https://releases.example/x/ ");
    defer testing.allocator.free(ok.ok);
    try testing.expectEqualStrings("https://releases.example/x", ok.ok);
    try testing.expectEqualStrings("update feed must use HTTPS", validateReleaseOverride(testing.allocator, "http://releases.example").err);
    try testing.expectEqualStrings("update feed must be a base URL without credentials, query, or fragment", validateReleaseOverride(testing.allocator, "https://releases.example/?a=1").err);
}

/// Made-up releases: url suffix → reply.
const FakeHttp = struct {
    routes: []const struct { suffix: []const u8, status: u16, body: []const u8 },
    calls: usize = 0,

    fn http(self: *FakeHttp) Http {
        return .{ .ctx = self, .get_fn = get };
    }

    fn get(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror!HttpReply {
        const self: *FakeHttp = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        for (self.routes) |r| {
            if (std.mem.endsWith(u8, url, r.suffix)) return .{ .status = r.status, .body = try gpa.dupe(u8, r.body) };
        }
        return .{ .status = 404, .body = try gpa.dupe(u8, "") };
    }
};

const FakeRestart = struct {
    count: usize = 0,
    fn restarter(self: *FakeRestart) Restarter {
        return .{ .ctx = self, .restart_fn = hit };
    }
    fn hit(ctx: ?*anyopaque, _: []const u8) void {
        const self: *FakeRestart = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
    }
};

fn testUpdater(kind: InstallKind, path: []const u8, http: Http, runner: proc.Runner, restart: Restarter, io: ?std.Io) Updater {
    return .{
        .gpa = testing.allocator,
        .io = io,
        .install = .{ .kind = kind, .path = path },
        .automatic = true,
        .edge_url = "https://edge.example",
        .current_version = "0.2.100",
        .http = http,
        .runner = runner,
        .restarter = restart,
    };
}

test "updates: UpdateStatus shapes for each install, and a check fills them in" {
    var fh: FakeHttp = .{ .routes = &.{.{ .suffix = "/releases/latest/download/manifest.json", .status = 200, .body = "{\"version\":\"0.2.101\",\"files\":{}}" }} };
    var fr: FakeRestart = .{};
    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var manual = testUpdater(.unmanaged, "", fh.http(), noop.runner(), fr.restarter(), null);
    defer manual.deinit();
    const s0 = (try handle(&manual, testing.allocator, .status)).ok;
    defer testing.allocator.free(s0);
    try testing.expectEqualStrings("{\"currentVersion\":\"0.2.100\",\"updateAvailable\":false,\"host\":{\"mode\":\"manual\",\"automatic\":true,\"phase\":\"idle\"}}", s0);

    var app = testUpdater(.mac_app, "/Applications/Harness.app", fh.http(), noop.runner(), fr.restarter(), null);
    defer app.deinit();
    try testing.expect(try app.checkOnce(1_790_000_000_000));
    const s1 = (try handle(&app, testing.allocator, .status)).ok;
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("{\"currentVersion\":\"0.2.100\",\"latestVersion\":\"0.2.101\",\"updateAvailable\":true,\"checkedAt\":1790000000000,\"host\":{\"mode\":\"desktop\",\"automatic\":true,\"phase\":\"idle\"}}", s1);

    var down: FakeHttp = .{ .routes = &.{.{ .suffix = "/latest.txt", .status = 503, .body = "" }} };
    var failing = testUpdater(.mac_app, "/A.app", down.http(), noop.runner(), fr.restarter(), null);
    defer failing.deinit();
    try testing.expect(!(try failing.checkOnce(1)));
    const s2 = (try handle(&failing, testing.allocator, .status)).ok;
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("{\"currentVersion\":\"0.2.100\",\"updateAvailable\":false,\"error\":\"fetching latest.txt: HTTP status 503\",\"host\":{\"mode\":\"desktop\",\"automatic\":true,\"phase\":\"failed\"}}", s2);
}

test "updates: the feed falls back to latest.txt and refuses an empty version" {
    var fh: FakeHttp = .{ .routes = &.{.{ .suffix = "/releases/latest.txt", .status = 200, .body = " 0.3.0\n" }} };
    var fr: FakeRestart = .{};
    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var u = testUpdater(.unmanaged, "", fh.http(), noop.runner(), fr.restarter(), null);
    defer u.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("0.3.0", (try u.fetchLatest(arena.allocator())).ok.version);
    var empty: FakeHttp = .{ .routes = &.{.{ .suffix = "/manifest.json", .status = 200, .body = "{\"version\":\" \"}" }} };
    u.http = empty.http();
    try testing.expectEqualStrings("manifest.json has an empty version", (try u.fetchLatest(arena.allocator())).err);
}

test "updates: QueueUpdate and ApplyUpdate refuse installs that aren't managed" {
    var fh: FakeHttp = .{ .routes = &.{} };
    var fr: FakeRestart = .{};
    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var u = testUpdater(.mac_app, "/A.app", fh.http(), noop.runner(), fr.restarter(), null);
    defer u.deinit();
    try testing.expectEqualStrings("this device cannot queue a remote update; update its desktop app or package locally", (try handle(&u, testing.allocator, .queue)).failed);
    try testing.expectEqualStrings("this install is not update-managed — the desktop app updates from its UI; source builds update via git", (try handle(&u, testing.allocator, .apply)).failed);
    try testing.expectEqual(@as(usize, 0), fh.calls);
    const c = (try handle(&u, testing.allocator, .check)).ok;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("{\"ok\":true}", c);

    var m = testUpdater(.managed, "/nowhere", fh.http(), noop.runner(), fr.restarter(), null);
    defer m.deinit();
    const q = (try handle(&m, testing.allocator, .queue)).ok;
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("{\"ok\":true,\"queued\":true}", q);
    try testing.expect(m.requested);
    try testing.expect(m.automatic);
    m.shutting_down = true;
    try testing.expectEqualStrings("the updater is shutting down", (try handle(&m, testing.allocator, .queue)).failed);
}

const TarEffect = struct {
    fn unpack(_: ?*anyopaque, req: proc.Request) void {
        // argv: tar -xzf <tarball> -C <unpacked> --strip-components=1
        var buf: [1024]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/harness", .{req.argv[4]}) catch return;
        std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = "#!/bin/sh\n" }) catch return;
    }
};

test "updates: ApplyUpdate stages the verified tarball, repoints current, and restarts" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const tarball = "made-up tarball bytes";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const artifact = try headlessArtifactAlloc(testing.allocator, "0.2.101");
    defer testing.allocator.free(artifact);
    const manifest = try std.fmt.allocPrint(testing.allocator, "{{\"version\":\"0.2.101\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, &hex });
    defer testing.allocator.free(manifest);
    const suffix = try std.fmt.allocPrint(testing.allocator, "/{s}", .{artifact});
    defer testing.allocator.free(suffix);
    var fh: FakeHttp = .{ .routes = &.{
        .{ .suffix = "/manifest.json", .status = 200, .body = manifest },
        .{ .suffix = suffix, .status = 200, .body = tarball },
    } };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    const r = (try handle(&u, testing.allocator, .apply)).ok;
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"ok\":true,\"version\":\"0.2.101\"}", r);
    try testing.expectEqual(@as(usize, 1), fr.count);
    var lbuf: [4096]u8 = undefined;
    const link = try tmp.dir.readLink(testing.io, "current", &lbuf);
    try testing.expect(std.mem.endsWith(u8, lbuf[0..link], "/0.2.101"));

    // Now current: up to date.
    u.current_version = "0.2.101";
    try testing.expectEqualStrings("already up to date (0.2.101)", (try handle(&u, testing.allocator, .apply)).failed);
}

test "updates: a checksum mismatch never installs" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const artifact = try headlessArtifactAlloc(testing.allocator, "0.2.101");
    defer testing.allocator.free(artifact);
    const manifest = try std.fmt.allocPrint(testing.allocator, "{{\"version\":\"0.2.101\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, "0000000000000000000000000000000000000000000000000000000000000000" });
    defer testing.allocator.free(manifest);
    const suffix = try std.fmt.allocPrint(testing.allocator, "/{s}", .{artifact});
    defer testing.allocator.free(suffix);
    var fh: FakeHttp = .{ .routes = &.{
        .{ .suffix = "/manifest.json", .status = 200, .body = manifest },
        .{ .suffix = suffix, .status = 200, .body = "tampered" },
    } };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    const msg = (try handle(&u, testing.allocator, .apply)).failed;
    try testing.expect(std.mem.startsWith(u8, msg, "checksum mismatch for harness-0.2.101-"));
    try testing.expectEqual(@as(usize, 0), fr.count);
    try testing.expectEqual(@as(usize, 0), tar.calls.items.len);
}

const NoSleep = struct {
    pub fn sleep(_: @This(), _: i64) bool {
        return true;
    }
};

test "updates: a queued update waits for idle, then applies and restarts" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var fh: FakeHttp = .{ .routes = &.{
        .{ .suffix = "/manifest.json", .status = 200, .body = "{\"version\":\"0.2.102\"}" },
        .{ .suffix = ".tar.gz", .status = 200, .body = "bytes" },
    } };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    const Busy = struct {
        var probes: usize = 0;
        fn quiet(_: ?*anyopaque) bool {
            probes += 1;
            return probes > 2;
        }
    };
    u.quiescent_fn = Busy.quiet;
    u.requested = true;
    try testing.expect(try u.checkOnce(5));
    try testing.expectEqual(@as(?[]u8, null), try u.autoApplyWhenIdle(NoSleep{}));
    try testing.expect(Busy.probes >= 3);
    try testing.expectEqual(@as(usize, 1), fr.count);
    try testing.expectEqual(Phase.restarting, u.phase);
    try testing.expect(!u.requested);
}

test "updates: a target device this engine can't reach is refused" {
    const p = try json.parseFromSlice(json.Value, testing.allocator, "{\"targetDeviceId\":\"other\"}", .{});
    defer p.deinit();
    try testing.expectEqualStrings("target device not connected", targetProblem(p.value, "dev-local").?);
    try testing.expectEqual(@as(?[]const u8, null), targetProblem(p.value, "other"));
    try testing.expectEqual(@as(?[]const u8, null), targetProblem(.{ .object = .empty }, "dev-local"));
}
