//! Shared plumbing for the workspace-side RPC ports (`rpcw_*.zig`): environment
//! lookup with a test override, a deadline-bounded child process runner, the
//! engine's `git` wrapper (`crates/engine/src/repos.rs` `Repos::git`), and
//! formatted error replies.
//!
//! Error text: `RpcOutcome.err` slices are never freed by the transport, so a
//! formatted message lives in a per-thread buffer that stays valid until the
//! next formatted error on the same thread (the reply is written first).
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");

pub const RpcOutcome = engine_host.RpcOutcome;

/// Tests point the engine at a synthetic environment (HOME, PATH, overrides,
/// `GIT_CONFIG_GLOBAL`). When set, children get exactly this environment too.
pub var env_override: ?*const std.process.Environ.Map = null;

/// `std::env::var_os(name)`; the test override replaces the whole environment.
pub fn getenv(name: []const u8) ?[]const u8 {
    if (env_override) |map| return map.get(name);
    if (comptime !builtin.link_libc) return null;
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(raw);
}

/// `getenv` with Rust's `.filter(|s| !s.is_empty())`.
pub fn getenvNonEmpty(name: []const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// `crate::executable::home_dir` / `repos::home_dir`: HOME, then USERPROFILE.
pub fn homeDir() ?[]const u8 {
    return getenvNonEmpty("HOME") orelse getenvNonEmpty("USERPROFILE");
}

/// The home graff runs with on this device (`AgentAccountsConfig::graff_home`):
/// its sign-ins, MCP config and caches. The engine's configured home, else HOME.
pub fn graffHome(host: anytype) []const u8 {
    return host.agent_accounts.home_dir orelse homeDir() orelse "/";
}

threadlocal var err_buf: [4096]u8 = undefined;

/// `RpcError::Failed(format!(..))`.
pub fn failed(comptime fmt: []const u8, args: anytype) RpcOutcome {
    return .{ .err = .{ .exec_error = errText(fmt, args) } };
}

/// `RpcError::Failed(msg)` for a static string or one `errText` already made.
pub fn failedMsg(msg: []const u8) RpcOutcome {
    return .{ .err = .{ .exec_error = msg } };
}

/// `RpcError::BadParams(..)`.
pub fn badParams(comptime fmt: []const u8, args: anytype) RpcOutcome {
    return .{ .err = .{ .bad_params = errText(fmt, args) } };
}

pub fn errText(comptime fmt: []const u8, args: anytype) []const u8 {
    // Arguments may themselves live in `err_buf`: format aside, then copy.
    var tmp: [err_buf.len]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, fmt, args) catch blk: {
        const tail = "…";
        @memcpy(tmp[tmp.len - tail.len ..], tail);
        break :blk tmp[0..];
    };
    @memcpy(err_buf[0..text.len], text);
    return err_buf[0..text.len];
}

pub fn obj(params: json.Value) ?json.ObjectMap {
    return if (params == .object) params.object else null;
}

pub fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn boolField(o: json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

pub const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *RunResult, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    pub fn success(self: RunResult) bool {
        return self.term == .exited and self.term.exited == 0;
    }
};

pub const RunError = error{ SpawnFailed, TimedOut, OutputTooLarge, OutOfMemory };

/// Run `argv` to completion, killing it when `timeout_ms` passes. stdin is null.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ms: i64,
) RunError!RunResult {
    if (comptime !std.process.can_spawn) return error.SpawnFailed;
    const deadline: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(timeout_ms),
        .clock = .awake,
    }) };
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env_override,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = deadline,
    }) catch |e| return switch (e) {
        error.Timeout => error.TimedOut,
        error.StreamTooLong => error.OutputTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.SpawnFailed,
    };
    return .{ .term = res.term, .stdout = res.stdout, .stderr = res.stderr };
}

/// Git calls never hang a request: a wedged hook or mount fails it instead.
pub const git_timeout_ms: i64 = 120_000;

/// `Repos::git`: trimmed stdout on success, otherwise git's own message
/// (`git: <stderr>`) or `git <cmd> failed (<status>)`.
pub const GitResult = union(enum) {
    ok: []u8,
    failed: []const u8,

    pub fn deinit(self: GitResult, gpa: Allocator) void {
        switch (self) {
            .ok => |o| gpa.free(o),
            .failed => {},
        }
    }
};

pub fn git(gpa: Allocator, io: std.Io, args: []const []const u8, cwd: ?[]const u8) !GitResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);
    var res = run(gpa, io, argv.items, cwd, git_timeout_ms) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimedOut => return .{ .failed = errText("git {s} timed out", .{if (args.len > 0) args[0] else "?"}) },
        else => return .{ .failed = errText("git spawn failed: {s}", .{@errorName(e)}) },
    };
    defer gpa.free(res.stderr);
    if (!res.success()) {
        defer gpa.free(res.stdout);
        const message = std.mem.trim(u8, res.stderr, " \t\r\n");
        if (message.len == 0) {
            return .{ .failed = switch (res.term) {
                .exited => |code| errText("git {s} failed (exit status: {d})", .{ if (args.len > 0) args[0] else "?", code }),
                else => errText("git {s} failed (signal)", .{if (args.len > 0) args[0] else "?"}),
            } };
        }
        return .{ .failed = errText("git: {s}", .{message}) };
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    const out = try gpa.dupe(u8, trimmed);
    gpa.free(res.stdout);
    return .{ .ok = out };
}

/// `git` for probes whose failure only matters as a boolean.
pub fn gitOk(gpa: Allocator, io: std.Io, args: []const []const u8, cwd: ?[]const u8) bool {
    const r = git(gpa, io, args, cwd) catch return false;
    defer r.deinit(gpa);
    return r == .ok;
}

/// `std::fs::canonicalize`.
pub fn canonicalize(gpa: Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const z = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch return null;
    defer gpa.free(z);
    return gpa.dupe(u8, z) catch null;
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

pub fn isFile(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

pub fn isDir(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Unix `runnable`: a file (symlinks followed) with any execute bit.
pub fn isRunnable(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    if (comptime builtin.os.tag == .windows) return true;
    return st.permissions.toMode() & 0o111 != 0;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A synthetic environment for tests: HOME under a temp dir, a fixed PATH and
/// a git configuration isolated from the machine's.
pub const TestEnv = struct {
    map: std.process.Environ.Map,

    pub fn init(gpa: Allocator, home: []const u8) !TestEnv {
        var map: std.process.Environ.Map = .init(gpa);
        errdefer map.deinit();
        try map.put("HOME", home);
        try map.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
        try map.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try map.put("GIT_CONFIG_NOSYSTEM", "1");
        try map.put("GIT_AUTHOR_NAME", "Synthetic");
        try map.put("GIT_AUTHOR_EMAIL", "synthetic@example.invalid");
        try map.put("GIT_COMMITTER_NAME", "Synthetic");
        try map.put("GIT_COMMITTER_EMAIL", "synthetic@example.invalid");
        try map.put("LANG", "C");
        return .{ .map = map };
    }

    pub fn install(self: *TestEnv) void {
        env_override = &self.map;
    }

    pub fn deinit(self: *TestEnv) void {
        if (env_override == &self.map) env_override = null;
        self.map.deinit();
    }
};

/// Absolute path of a `testing.tmpDir`.
pub fn tmpPath(gpa: Allocator, io: std.Io, tmp: *testing.TmpDir) ![]u8 {
    const z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}

test "rpcw_common git reports git's own error text and trims stdout" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpPath(gpa, io, &tmp);
    defer gpa.free(base);
    var env = try TestEnv.init(gpa, base);
    defer env.deinit();
    env.install();

    try testing.expectEqualStrings("C", getenv("LANG").?);
    try testing.expectEqualStrings(base, homeDir().?);
    try testing.expect(getenv("HARNESS_SURELY_UNSET_VARIABLE") == null);

    const init_r = try git(gpa, io, &.{ "init", "-q", "-b", "main", "repo" }, base);
    defer init_r.deinit(gpa);
    try testing.expect(init_r == .ok);
    const repo = try std.fs.path.join(gpa, &.{ base, "repo" });
    defer gpa.free(repo);

    const bad = try git(gpa, io, &.{ "rev-parse", "--verify", "nope^{commit}" }, repo);
    try testing.expect(bad == .failed);
    try testing.expect(std.mem.startsWith(u8, bad.failed, "git: "));

    const top = try git(gpa, io, &.{ "rev-parse", "--show-toplevel" }, repo);
    defer top.deinit(gpa);
    try testing.expect(top == .ok);
    try testing.expect(!std.mem.endsWith(u8, top.ok, "\n"));
}

test "rpcw_common run kills a child that outlives its deadline" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testing.expectError(error.TimedOut, run(gpa, io, &.{ "/bin/sh", "-c", "sleep 30" }, null, 200));
    var ok = try run(gpa, io, &.{ "/bin/sh", "-c", "printf hi; exit 3" }, null, 5_000);
    defer ok.deinit(gpa);
    try testing.expectEqualStrings("hi", ok.stdout);
    try testing.expect(!ok.success());
}
