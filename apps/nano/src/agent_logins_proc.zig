//! Login children for the agent-accounts registry: Rust's `wire_login_child`
//! (`crates/engine/src/agent_accounts.rs`) plus the one-shot `output()` runs
//! (`security`, `graff login claude-agent`).
//!
//! A `LoginChild` runs in its own process group with stdout and stderr
//! accumulated into one buffer (the sign-in URL can land on either stream)
//! and a waiter thread that records the exit. Threads are detached and hold a
//! reference each, so cancelling never blocks on a child's pipes; the shared
//! state is freed when the last reference goes.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const Environ = std.process.Environ;
const agent_proc = @import("agent_proc.zig");
const catalog_core = @import("catalog_core.zig");

const is_windows = builtin.os.tag == .windows;
const max_output = 1024 * 1024;

/// How a login child ended: `code` null = killed by a signal.
pub const Exit = struct { code: ?i32 };

pub const SpawnError = error{ NotFound, SpawnFailed, OutOfMemory };

pub const LoginChild = struct {
    /// Thread-safe, process-lifetime allocator (threads may outlive callers).
    gpa: Allocator,
    io: Io,
    refs: std.atomic.Value(u32) = .init(1),
    mutex: Io.Mutex = .init,
    output: std.ArrayList(u8) = .empty,
    stdout_buf: std.ArrayList(u8) = .empty,
    stderr_buf: std.ArrayList(u8) = .empty,
    exit: ?Exit = null,
    eofs: std.atomic.Value(u8) = .init(0),
    reaped: std.atomic.Value(bool) = .init(false),
    proc: std.process.Child,
    id: std.process.Child.Id,
    stdin_mutex: Io.Mutex = .init,
    stdin: ?Io.File = null,

    /// Start `argv` (env null = inherit) with stdout/stderr piped, stdin piped
    /// when `stdin_pipe`, in its own process group.
    pub fn spawn(io: Io, argv: []const []const u8, env: ?*const Environ.Map, stdin_pipe: bool) SpawnError!*LoginChild {
        if (comptime !std.process.can_spawn) return error.SpawnFailed;
        const gpa = catalog_core.long_gpa;
        if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
            Io.Dir.cwd().access(io, argv[0], .{}) catch return error.NotFound;
        }
        const self = try gpa.create(LoginChild);
        errdefer gpa.destroy(self);
        var proc = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = env,
            .stdin = if (stdin_pipe) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (is_windows) null else 0,
        }) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.SpawnFailed,
        };
        const out_file = proc.stdout.?;
        const err_file = proc.stderr.?;
        const in_file = proc.stdin;
        proc.stdout = null;
        proc.stderr = null;
        proc.stdin = null;
        self.* = .{ .gpa = gpa, .io = io, .proc = proc, .id = proc.id.?, .stdin = in_file };
        self.refs.store(4, .release);
        if (std.Thread.spawn(.{}, readPipe, .{ self, out_file, true })) |t| t.detach() else |_| {
            out_file.close(io);
            self.markEof();
            _ = self.refs.fetchSub(1, .acq_rel);
        }
        if (std.Thread.spawn(.{}, readPipe, .{ self, err_file, false })) |t| t.detach() else |_| {
            err_file.close(io);
            self.markEof();
            _ = self.refs.fetchSub(1, .acq_rel);
        }
        if (std.Thread.spawn(.{}, waiter, .{self})) |t| t.detach() else |_| {
            self.kill();
            waiter(self);
        }
        return self;
    }

    fn markEof(self: *LoginChild) void {
        _ = self.eofs.fetchAdd(1, .acq_rel);
    }

    fn readPipe(self: *LoginChild, file: Io.File, is_stdout: bool) void {
        defer self.release();
        defer self.markEof();
        defer file.close(self.io);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = file.readStreaming(self.io, &.{&chunk}) catch break;
            if (n == 0) continue;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.output.items.len < max_output) self.output.appendSlice(self.gpa, chunk[0..n]) catch {};
            const own = if (is_stdout) &self.stdout_buf else &self.stderr_buf;
            if (own.items.len < max_output) own.appendSlice(self.gpa, chunk[0..n]) catch {};
        }
    }

    fn waiter(self: *LoginChild) void {
        defer self.release();
        const term = self.proc.wait(self.io) catch null;
        self.reaped.store(true, .release);
        // Let the readers catch up with what the child wrote before exiting
        // (Rust's monitor sees the exit up to 200 ms late, after the reads).
        var waited: u32 = 0;
        while (self.eofs.load(.acquire) < 2 and waited < 1000) : (waited += 10) {
            Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
        }
        const code: ?i32 = if (term) |t| switch (t) {
            .exited => |c| @intCast(c),
            else => null,
        } else null;
        self.mutex.lockUncancelable(self.io);
        self.exit = .{ .code = code };
        self.mutex.unlock(self.io);
    }

    pub fn retain(self: *LoginChild) *LoginChild {
        _ = self.refs.fetchAdd(1, .acq_rel);
        return self;
    }

    pub fn release(self: *LoginChild) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.stdin) |f| f.close(self.io);
        self.output.deinit(self.gpa);
        self.stdout_buf.deinit(self.gpa);
        self.stderr_buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// SIGKILL the child's process group (no-op once reaped).
    pub fn kill(self: *LoginChild) void {
        if (self.reaped.load(.acquire)) return;
        if (comptime is_windows) {
            _ = std.os.windows.ntdll.NtTerminateProcess(self.id, @fromBackingInt(@intCast(@as(u32, 1))));
        } else {
            posix.kill(-self.id, .KILL) catch {
                posix.kill(self.id, .KILL) catch {};
            };
        }
    }

    /// Null while running.
    pub fn exitStatus(self: *LoginChild) ?Exit {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.exit;
    }

    /// Both streams so far, in arrival order (owned by `a`).
    pub fn outputDupe(self: *LoginChild, a: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return a.dupe(u8, self.output.items);
    }

    pub fn streamDupe(self: *LoginChild, a: Allocator, stdout: bool) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return a.dupe(u8, if (stdout) self.stdout_buf.items else self.stderr_buf.items);
    }

    /// Write `bytes` to stdin once and close it. `error.NoStdin` when it was
    /// already used (or never piped).
    pub fn writeStdinOnce(self: *LoginChild, bytes: []const u8) !void {
        self.stdin_mutex.lockUncancelable(self.io);
        const f = self.stdin orelse {
            self.stdin_mutex.unlock(self.io);
            return error.NoStdin;
        };
        self.stdin = null;
        self.stdin_mutex.unlock(self.io);
        defer f.close(self.io);
        try f.writeStreamingAll(self.io, bytes);
    }

    pub fn hasStdin(self: *LoginChild) bool {
        self.stdin_mutex.lockUncancelable(self.io);
        defer self.stdin_mutex.unlock(self.io);
        return self.stdin != null;
    }

    /// Wait until the child exited (true) or `timeout_ms` passed (false).
    pub fn waitExit(self: *LoginChild, timeout_ms: u64) bool {
        var waited: u64 = 0;
        while (true) {
            if (self.exitStatus() != null) return true;
            if (waited >= timeout_ms) return false;
            Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return self.exitStatus() != null;
            waited += 20;
        }
    }
};

/// A finished one-shot run (`Command::output` under a timeout).
pub const Captured = struct {
    timed_out: bool = false,
    code: ?i32 = null,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    pub fn success(c: Captured) bool {
        return !c.timed_out and c.code != null and c.code.? == 0;
    }
};

/// Run `argv` to completion within `timeout_ms` (killed past it).
pub fn runCapture(a: Allocator, io: Io, argv: []const []const u8, env: ?*const Environ.Map, timeout_ms: u64) SpawnError!Captured {
    const child = try LoginChild.spawn(io, argv, env, false);
    defer child.release();
    if (!child.waitExit(timeout_ms)) {
        child.kill();
        return .{ .timed_out = true };
    }
    return .{
        .code = child.exitStatus().?.code,
        .stdout = try child.streamDupe(a, true),
        .stderr = try child.streamDupe(a, false),
    };
}

/// The environment a login child gets: the engine's own (`catalog_core`
/// seam), minus the nested-agent markers and `HARNESS_BUILD_WAIT_DIR`, with
/// PATH composed as `compose_child_path[_with_prefix]`: the optional prefix,
/// the executable's dir, `$PATH`, then the login shell's PATH.
pub fn childEnv(a: Allocator, io: Io, exe: []const u8, prefix: ?[]const u8) !Environ.Map {
    var env = try catalog_core.currentEnv(a);
    errdefer env.deinit();
    _ = env.swapRemove("HARNESS_BUILD_WAIT_DIR");
    for (agent_proc.stripped_env) |k| _ = env.swapRemove(k);
    const login = agent_proc.loginShellPath(a, io, &env);
    const composed = try agent_proc.composeChildPath(a, exe, env.get("PATH"), login);
    if (prefix) |p| {
        var parts: std.ArrayList(u8) = .empty;
        try parts.appendSlice(a, p);
        var it = std.mem.splitScalar(u8, composed, ':');
        while (it.next()) |d| {
            if (d.len == 0 or std.mem.eql(u8, d, p)) continue;
            try parts.append(a, ':');
            try parts.appendSlice(a, d);
        }
        try env.put("PATH", parts.items);
    } else {
        try env.put("PATH", composed);
    }
    return env;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "agent_logins_proc: both streams accumulate, exit is recorded, kill reaches the group" {
    if (!std.process.can_spawn or is_windows) return error.SkipZigTest;
    const io = testing.io;
    const c = try LoginChild.spawn(io, &.{ "/bin/sh", "-c", "echo out; echo err >&2; exit 3" }, null, false);
    defer c.release();
    try testing.expect(c.waitExit(10_000));
    try testing.expectEqual(@as(?i32, 3), c.exitStatus().?.code);
    const out = try c.outputDupe(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "out\n") != null and std.mem.indexOf(u8, out, "err\n") != null);

    const slow = try LoginChild.spawn(io, &.{ "/bin/sh", "-c", "sleep 30 & wait" }, null, false);
    defer slow.release();
    try testing.expect(!slow.waitExit(100));
    slow.kill();
    try testing.expect(slow.waitExit(10_000));
    try testing.expectEqual(@as(?i32, null), slow.exitStatus().?.code);

    try testing.expectError(error.NotFound, LoginChild.spawn(io, &.{"/nonexistent/harness-login-xyz"}, null, false));
}

test "agent_logins_proc: stdin is written once, captures time out" {
    if (!std.process.can_spawn or is_windows) return error.SkipZigTest;
    const io = testing.io;
    const c = try LoginChild.spawn(io, &.{ "/bin/sh", "-c", "read code; echo \"got $code\"" }, null, true);
    defer c.release();
    try c.writeStdinOnce("abc\n");
    try testing.expectError(error.NoStdin, c.writeStdinOnce("again\n"));
    try testing.expect(c.waitExit(10_000));
    const out = try c.outputDupe(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("got abc\n", out);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cap = try runCapture(arena.allocator(), io, &.{ "/bin/sh", "-c", "echo hi; echo no >&2" }, null, 10_000);
    try testing.expect(cap.success());
    try testing.expectEqualStrings("hi\n", cap.stdout);
    try testing.expectEqualStrings("no\n", cap.stderr);
    const slow = try runCapture(arena.allocator(), io, &.{ "/bin/sh", "-c", "sleep 30" }, null, 200);
    try testing.expect(slow.timed_out);
}
