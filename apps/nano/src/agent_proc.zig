//! Agent child processes for the engine's harness adapters
//! (`crates/harness/src/{process,executable,shell_env}.rs`, `lib.rs`).
//!
//! An `AgentProc` is one agent CLI started with piped stdio in its own process
//! group, so an interrupt or shutdown signals every process the agent started
//! (npm wrappers, shells). stdout is read line by line on the turn's thread;
//! stderr is drained on its own thread into a short tail for crash messages;
//! stdin writes are serialized so the turn thread and RPC threads (answers,
//! steering, interrupts) can both write.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const Environ = std.process.Environ;

pub const SpawnError = error{
    /// The executable does not exist (`HarnessError::NotInstalled`).
    NotInstalled,
    /// The working directory does not exist.
    MissingCwd,
    UnsupportedPlatform,
} || Allocator.Error || std.process.SpawnError;

/// The environment variables Rust strips from every agent child
/// (`process/owned.rs`), so an agent launched from inside another agent's
/// session doesn't believe it is nested.
pub const stripped_env = [_][]const u8{ "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION" };

/// The last few stderr lines (`StderrTail`: 6 lines, 700 bytes each, 1400 total).
pub const StderrTail = struct {
    const keep_lines = 6;
    const keep_bytes = 700;

    lines: [keep_lines][keep_bytes]u8 = undefined,
    lens: [keep_lines]usize = @splat(0),
    count: usize = 0,
    head: usize = 0,

    pub fn push(self: *StderrTail, raw: []const u8) void {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) return;
        var n = @min(line.len, keep_bytes);
        while (n < line.len and n > 0 and (line[n] & 0xC0) == 0x80) n -= 1;
        var slot: usize = undefined;
        if (self.count == keep_lines) {
            slot = self.head;
            self.head = (self.head + 1) % keep_lines;
        } else {
            slot = (self.head + self.count) % keep_lines;
            self.count += 1;
        }
        @memcpy(self.lines[slot][0..n], line[0..n]);
        self.lens[slot] = n;
    }

    /// The tail joined by `\n`, cut to its last 1400 bytes; null when empty.
    pub fn snapshot(self: *const StderrTail, gpa: Allocator) !?[]u8 {
        if (self.count == 0) return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (0..self.count) |i| {
            const idx = (self.head + i) % keep_lines;
            if (i > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, self.lines[idx][0..self.lens[idx]]);
        }
        const cap = keep_bytes * 2;
        if (out.items.len > cap) {
            var start = out.items.len - cap;
            while (start < out.items.len and (out.items[start] & 0xC0) == 0x80) start += 1;
            const tail = try gpa.dupe(u8, out.items[start..]);
            out.deinit(gpa);
            return tail;
        }
        return try out.toOwnedSlice(gpa);
    }
};

/// `redact_secrets` (`lib.rs`): credentials after `bearer `, `basic `, `sk-`,
/// `ghp_`, `xox`, `api_key=` become `[REDACTED]`.
pub fn redactSecrets(gpa: Allocator, text: []const u8) ![]u8 {
    const markers = [_][]const u8{ "bearer ", "basic ", "sk-", "ghp_", "xox", "api_key=" };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var offset: usize = 0;
    while (true) {
        var best: ?struct { at: usize, marker: []const u8 } = null;
        for (markers) |m| {
            if (indexOfIgnoreCase(text[offset..], m)) |rel| {
                const at = offset + rel;
                if (best == null or at < best.?.at) best = .{ .at = at, .marker = m };
            }
        }
        const b = best orelse break;
        const last = b.marker[b.marker.len - 1];
        var cred = if (last == ' ' or last == '=') b.at + b.marker.len else b.at;
        while (cred < text.len and (std.ascii.isWhitespace(text[cred]) or text[cred] == '"' or text[cred] == '\'')) cred += 1;
        var end = cred;
        while (end < text.len) : (end += 1) {
            const c = text[end];
            if (std.ascii.isWhitespace(c) or c == '"' or c == '\'' or c == ',' or c == ';' or c == '&' or c == '<' or c == '>') break;
        }
        try out.appendSlice(gpa, text[offset..cred]);
        try out.appendSlice(gpa, "[REDACTED]");
        offset = @max(end, b.at + b.marker.len);
    }
    try out.appendSlice(gpa, text[offset..]);
    return out.toOwnedSlice(gpa);
}

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// `describe_exit` (`lib.rs`).
pub fn describeExit(buf: []u8, term: ?std.process.Child.Term) []const u8 {
    const t = term orelse return "still running";
    return switch (t) {
        .exited => |code| std.fmt.bufPrint(buf, "exit code {d}", .{code}) catch "unknown exit",
        .signal => |sig| std.fmt.bufPrint(buf, "killed by signal {d}", .{@backingInt(sig)}) catch "unknown exit",
        else => "unknown exit",
    };
}

/// `crash_message` (`lib.rs`): `"{name} exited unexpectedly ({status}): {tail}"`.
pub fn crashMessage(gpa: Allocator, name: []const u8, term: ?std.process.Child.Term, tail: ?[]const u8) ![]u8 {
    var sbuf: [48]u8 = undefined;
    const status = describeExit(&sbuf, term);
    if (tail) |t| {
        const clean = try redactSecrets(gpa, t);
        defer gpa.free(clean);
        return std.fmt.allocPrint(gpa, "{s} exited unexpectedly ({s}): {s}", .{ name, status, clean });
    }
    return std.fmt.allocPrint(gpa, "{s} exited unexpectedly ({s})", .{ name, status });
}

// ---------------------------------------------------------------------------
// Executable lookup (`executable.rs` `find_on_paths`)
// ---------------------------------------------------------------------------

/// Where to look for an agent CLI, in Rust's order: `$PATH`, the login shell's
/// PATH, the adapter's extra paths (absolute files, `~/` expanded), then the
/// Node version-manager bin dirs.
pub const Search = struct {
    name: []const u8,
    path_env: ?[]const u8,
    login_path: ?[]const u8 = null,
    home: ?[]const u8,
    /// Absolute or `~/`-relative file paths.
    extra: []const []const u8 = &.{},
    fnm_dir: ?[]const u8 = null,
};

/// The candidate file paths for `s`, in search order (pure: touches no files).
pub fn candidatePaths(gpa: Allocator, s: Search) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    for ([_]?[]const u8{ s.path_env, s.login_path }) |maybe| {
        const p = maybe orelse continue;
        var it = std.mem.splitScalar(u8, p, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            try list.append(gpa, try std.fs.path.join(gpa, &.{ dir, s.name }));
        }
    }
    for (s.extra) |e| {
        if (std.mem.startsWith(u8, e, "~/")) {
            const home = s.home orelse continue;
            try list.append(gpa, try std.fs.path.join(gpa, &.{ home, e[2..] }));
        } else {
            try list.append(gpa, try gpa.dupe(u8, e));
        }
    }
    if (s.home) |home| {
        if (s.fnm_dir) |f| try list.append(gpa, try std.fs.path.join(gpa, &.{ f, "aliases/default/bin", s.name }));
        const node_dirs = [_][]const u8{
            ".local/share/fnm/aliases/default/bin",
            "Library/Application Support/fnm/aliases/default/bin",
            ".fnm/aliases/default/bin",
            ".volta/bin",
            ".bun/bin",
            "Library/pnpm",
            ".local/share/pnpm",
        };
        for (node_dirs) |d| try list.append(gpa, try std.fs.path.join(gpa, &.{ home, d, s.name }));
    }
    // Dedupe, keeping the first occurrence.
    var i: usize = 0;
    while (i < list.items.len) {
        var dup = false;
        for (list.items[0..i]) |prev| if (std.mem.eql(u8, prev, list.items[i])) {
            dup = true;
            break;
        };
        if (dup) {
            gpa.free(list.orderedRemove(i));
        } else i += 1;
    }
    return list;
}

fn isRunnable(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    if (builtin.os.tag == .windows) return true;
    return (@as(u32, @intCast(st.permissions.toMode())) & 0o111) != 0;
}

/// The first runnable candidate, or null. nvm's `versions/node/*/bin` dirs are
/// appended newest-first after the fixed candidates.
pub fn findExecutable(gpa: Allocator, io: Io, s: Search) !?[]u8 {
    var list = try candidatePaths(gpa, s);
    defer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    for (list.items) |p| if (isRunnable(io, p)) return try gpa.dupe(u8, p);
    if (s.home) |home| {
        const nvm = try std.fs.path.join(gpa, &.{ home, ".nvm/versions/node" });
        defer gpa.free(nvm);
        var dir = Io.Dir.cwd().openDir(io, nvm, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |e| try names.append(gpa, try gpa.dupe(u8, e.name));
        std.mem.sort([]u8, names.items, {}, struct {
            fn gt(_: void, a: []u8, b: []u8) bool {
                return semverGreater(a, b);
            }
        }.gt);
        for (names.items) |n| {
            const p = try std.fs.path.join(gpa, &.{ nvm, n, "bin", s.name });
            if (isRunnable(io, p)) return p;
            gpa.free(p);
        }
    }
    return null;
}

fn semverGreater(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, std.mem.trimStart(u8, a, "v"), ".-");
    var ib = std.mem.tokenizeAny(u8, std.mem.trimStart(u8, b, "v"), ".-");
    while (true) {
        const xa = ia.next();
        const xb = ib.next();
        if (xa == null and xb == null) return false;
        const na = std.fmt.parseInt(u64, xa orelse "0", 10) catch 0;
        const nb = std.fmt.parseInt(u64, xb orelse "0", 10) catch 0;
        if (na != nb) return na > nb;
    }
}

// ---------------------------------------------------------------------------
// Login shell PATH (`shell_env.rs`), captured once per process.
// ---------------------------------------------------------------------------

var login_path_mutex: Io.Mutex = .init;
var login_path_done: bool = false;
var login_path_value: ?[]u8 = null;

/// The PATH the user's login shell reports, cached for the process
/// (`$SHELL -l -i -c` between markers; 5 s budget). Null when unavailable.
pub fn loginShellPath(gpa: Allocator, io: Io, env: *const Environ.Map) ?[]const u8 {
    if (builtin.os.tag == .windows or !std.process.can_spawn) return null;
    login_path_mutex.lockUncancelable(io);
    defer login_path_mutex.unlock(io);
    if (login_path_done) return login_path_value;
    login_path_done = true;
    if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) return null;
    const shell = env.get("SHELL") orelse "/bin/zsh";
    const script = "printf '__HARNESS_SHELL_ENV_BEGIN__%s__HARNESS_SHELL_ENV_END__' \"$PATH\"";
    const proc = AgentProc.spawn(std.heap.page_allocator, io, &.{ shell, "-l", "-i", "-c", script }, null, env, .{ .stdin = false }) catch return null;
    defer proc.destroy();
    proc.armDeadline(5000);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    while (out.items.len < 2 * 1024 * 1024) {
        const line = proc.readLine() catch break;
        const l = line orelse break;
        out.appendSlice(gpa, l) catch break;
        out.append(gpa, '\n') catch break;
    }
    proc.terminate();
    _ = proc.wait();
    const begin = "__HARNESS_SHELL_ENV_BEGIN__";
    const end_m = "__HARNESS_SHELL_ENV_END__";
    const b = std.mem.indexOf(u8, out.items, begin) orelse return null;
    const rest = out.items[b + begin.len ..];
    const e = std.mem.indexOf(u8, rest, end_m) orelse return null;
    if (e == 0) return null;
    login_path_value = std.heap.page_allocator.dupe(u8, rest[0..e]) catch null;
    return login_path_value;
}

/// `compose_path`: the executable's dir, then `$PATH`, then the login PATH,
/// deduplicated. Caller owns the result.
pub fn composeChildPath(gpa: Allocator, exe: []const u8, path_env: ?[]const u8, login_path: ?[]const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    if (std.fs.path.dirname(exe)) |d| if (d.len > 0) try parts.append(gpa, d);
    for ([_]?[]const u8{ path_env, login_path }) |maybe| {
        const p = maybe orelse continue;
        var it = std.mem.splitScalar(u8, p, ':');
        while (it.next()) |dir| if (dir.len > 0) try parts.append(gpa, dir);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts.items, 0..) |p, i| {
        var seen = false;
        for (parts.items[0..i]) |q| if (std.mem.eql(u8, p, q)) {
            seen = true;
            break;
        };
        if (seen) continue;
        if (out.items.len > 0) try out.append(gpa, ':');
        try out.appendSlice(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

/// The engine process's own environment as a map (libc `environ`).
pub fn currentEnv(gpa: Allocator) !Environ.Map {
    var map = Environ.Map.init(gpa);
    errdefer map.deinit();
    if (comptime builtin.link_libc and builtin.os.tag != .windows) {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const s = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
            if (eq == 0) continue;
            try map.put(s[0..eq], s[eq + 1 ..]);
        }
    }
    return map;
}

// ---------------------------------------------------------------------------
// The child process
// ---------------------------------------------------------------------------

pub const SpawnOpts = struct {
    stdin: bool = true,
    stdout: bool = true,
};

pub const AgentProc = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    pid: posix.pid_t,
    write_mutex: Io.Mutex = .init,
    stdin_open: bool,
    stderr_thread: ?std.Thread = null,
    stderr_mutex: Io.Mutex = .init,
    tail: StderrTail = .{},
    /// stdout line assembly (owned by the reading thread).
    buf: std.ArrayList(u8) = .empty,
    line: std.ArrayList(u8) = .empty,
    scan: usize = 0,
    eof: bool = false,
    /// Set when the child's stderr reached end of stream (it exited, or
    /// closed stderr): a non-blocking "is it gone?" for servers.
    stderr_closed: std.atomic.Value(bool) = .init(false),
    /// Set once `wait` reaped the child; signals are no longer sent.
    reaped: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,
    /// Watchdog deadlines on the awake clock (ns), 0 = none: SIGTERM the
    /// group at `term_at`, SIGKILL it at `kill_at`.
    term_at: std.atomic.Value(i64) = .init(0),
    kill_at: std.atomic.Value(i64) = .init(0),
    watchdog: ?std.Thread = null,
    watchdog_stop: std.atomic.Value(bool) = .init(false),

    /// Start `argv` in `cwd` with `env` (null = inherit). The child leads its
    /// own process group. Errors: `NotInstalled` when argv[0] doesn't exist,
    /// `MissingCwd` when `cwd` doesn't.
    pub fn spawn(gpa: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, env: ?*const Environ.Map, opts: SpawnOpts) SpawnError!*AgentProc {
        if (comptime !std.process.can_spawn) return error.UnsupportedPlatform;
        if (cwd) |c| if (c.len > 0) {
            Io.Dir.cwd().access(io, c, .{}) catch return error.MissingCwd;
        };
        if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
            Io.Dir.cwd().access(io, argv[0], .{}) catch return error.NotInstalled;
        }
        const self = try gpa.create(AgentProc);
        errdefer gpa.destroy(self);
        const child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (cwd) |c| (if (c.len > 0) .{ .path = c } else .inherit) else .inherit,
            .environ_map = env,
            .stdin = if (opts.stdin) .pipe else .ignore,
            .stdout = if (opts.stdout) .pipe else .ignore,
            .stderr = .pipe,
            .pgid = 0,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.NotInstalled,
            else => return err,
        };
        self.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .pid = child.id.?,
            .stdin_open = opts.stdin,
        };
        self.stderr_thread = std.Thread.spawn(.{}, drainStderr, .{self}) catch null;
        return self;
    }

    fn drainStderr(self: *AgentProc) void {
        const f = self.child.stderr orelse return;
        var chunk: [4096]u8 = undefined;
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(self.gpa);
        while (true) {
            const n = f.readStreaming(self.io, &.{&chunk}) catch break;
            if (n == 0) continue;
            pending.appendSlice(self.gpa, chunk[0..n]) catch break;
            while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
                self.stderr_mutex.lockUncancelable(self.io);
                self.tail.push(pending.items[0..nl]);
                self.stderr_mutex.unlock(self.io);
                pending.replaceRangeAssumeCapacity(0, nl + 1, &.{});
            }
            if (pending.items.len > 64 * 1024) pending.clearRetainingCapacity();
        }
        if (pending.items.len > 0) {
            self.stderr_mutex.lockUncancelable(self.io);
            self.tail.push(pending.items);
            self.stderr_mutex.unlock(self.io);
        }
        self.stderr_closed.store(true, .release);
    }

    /// The stderr tail so far (owned), or null.
    pub fn stderrTail(self: *AgentProc, gpa: Allocator) ?[]u8 {
        self.stderr_mutex.lockUncancelable(self.io);
        defer self.stderr_mutex.unlock(self.io);
        return self.tail.snapshot(gpa) catch null;
    }

    /// Write `bytes` and a trailing newline to stdin (serialized across threads).
    pub fn writeLine(self: *AgentProc, bytes: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.stdin_open) return error.StdinClosed;
        const f = self.child.stdin orelse return error.StdinClosed;
        f.writeStreamingAll(self.io, bytes) catch return error.StdinClosed;
        if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') f.writeStreamingAll(self.io, "\n") catch return error.StdinClosed;
    }

    pub fn closeStdin(self: *AgentProc) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.stdin_open) return;
        self.stdin_open = false;
        if (self.child.stdin) |f| f.close(self.io);
        self.child.stdin = null;
    }

    /// The next stdout line without its newline, valid until the next call;
    /// null at end of stream. Lines of any length are assembled.
    pub fn readLine(self: *AgentProc) !?[]const u8 {
        const f = self.child.stdout orelse return null;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buf.items, self.scan, '\n')) |nl| {
                self.line.clearRetainingCapacity();
                try self.line.appendSlice(self.gpa, self.buf.items[0..nl]);
                self.buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
                self.scan = 0;
                return std.mem.trimEnd(u8, self.line.items, "\r");
            }
            self.scan = self.buf.items.len;
            if (self.eof) {
                if (self.buf.items.len == 0) return null;
                self.line.clearRetainingCapacity();
                try self.line.appendSlice(self.gpa, self.buf.items);
                self.buf.clearRetainingCapacity();
                self.scan = 0;
                return self.line.items;
            }
            try self.buf.ensureUnusedCapacity(self.gpa, 16 * 1024);
            const dst = self.buf.unusedCapacitySlice();
            const n = f.readStreaming(self.io, &.{dst}) catch |err| switch (err) {
                error.EndOfStream => {
                    self.eof = true;
                    continue;
                },
                else => {
                    self.eof = true;
                    continue;
                },
            };
            self.buf.items.len += n;
        }
    }

    /// Signal the whole process group (no-op once reaped).
    pub fn signal(self: *AgentProc, sig: posix.SIG) void {
        if (self.reaped.load(.acquire)) return;
        posix.kill(-self.pid, sig) catch {
            posix.kill(self.pid, sig) catch {};
        };
    }

    /// SIGKILL the group immediately.
    pub fn terminate(self: *AgentProc) void {
        self.signal(.KILL);
    }

    fn nowNs(self: *AgentProc) i64 {
        return @intCast(Io.Clock.awake.now(self.io).nanoseconds);
    }

    fn lowerTo(v: *std.atomic.Value(i64), at: i64) void {
        var cur = v.load(.acquire);
        while (cur == 0 or at < cur) {
            cur = v.cmpxchgWeak(cur, at, .acq_rel, .acquire) orelse break;
        }
    }

    /// SIGKILL the group `ms` from now unless the child was reaped first.
    /// A later call moves the deadline earlier, never later.
    pub fn armDeadline(self: *AgentProc, ms: u32) void {
        lowerTo(&self.kill_at, self.nowNs() + @as(i64, ms) * std.time.ns_per_ms);
        self.startWatchdog();
    }

    /// `shutdown_child` without blocking: SIGTERM the group `term_ms` from
    /// now and SIGKILL it `kill_ms` from now.
    pub fn escalate(self: *AgentProc, term_ms: u32, kill_ms: u32) void {
        const now = self.nowNs();
        lowerTo(&self.term_at, now + @as(i64, term_ms) * std.time.ns_per_ms);
        lowerTo(&self.kill_at, now + @as(i64, kill_ms) * std.time.ns_per_ms);
        self.startWatchdog();
    }

    /// Drop pending TERM/KILL deadlines (a handshake finished in time).
    pub fn clearDeadline(self: *AgentProc) void {
        self.term_at.store(0, .release);
        self.kill_at.store(0, .release);
    }

    fn startWatchdog(self: *AgentProc) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.watchdog == null and !self.reaped.load(.acquire)) {
            self.watchdog = std.Thread.spawn(.{}, watch, .{self}) catch null;
        }
    }

    fn watch(self: *AgentProc) void {
        var termed = false;
        while (!self.watchdog_stop.load(.acquire)) {
            const now = self.nowNs();
            const t = self.term_at.load(.acquire);
            if (!termed and t != 0 and now >= t) {
                self.signal(.TERM);
                termed = true;
            }
            const k = self.kill_at.load(.acquire);
            if (k != 0 and now >= k) {
                self.signal(.KILL);
                return;
            }
            Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
        }
    }

    /// Reap the child (blocking) and join the helper threads; idempotent.
    pub fn wait(self: *AgentProc) ?std.process.Child.Term {
        if (self.reaped.load(.acquire)) return self.term;
        self.closeStdin();
        self.term = self.child.wait(self.io) catch null;
        self.reaped.store(true, .release);
        if (self.stderr_thread) |t| t.join();
        self.stderr_thread = null;
        self.watchdog_stop.store(true, .release);
        self.write_mutex.lockUncancelable(self.io);
        const wd = self.watchdog;
        self.watchdog = null;
        self.write_mutex.unlock(self.io);
        if (wd) |t| t.join();
        return self.term;
    }

    /// Kill (if still running), reap and free.
    pub fn destroy(self: *AgentProc) void {
        if (!self.reaped.load(.acquire)) {
            self.signal(.KILL);
            _ = self.wait();
        }
        self.buf.deinit(self.gpa);
        self.line.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "agent_proc: stderr tail keeps the last six lines and crash message redacts" {
    var t: StderrTail = .{};
    for (0..8) |i| {
        var b: [32]u8 = undefined;
        t.push(std.fmt.bufPrint(&b, "line {d}", .{i}) catch unreachable);
    }
    t.push("auth failed: Bearer secret-token");
    const snap = (try t.snapshot(testing.allocator)).?;
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.startsWith(u8, snap, "line 3\n"));
    const msg = try crashMessage(testing.allocator, "claude", .{ .exited = 2 }, snap);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.startsWith(u8, msg, "claude exited unexpectedly (exit code 2): line 3"));
    try testing.expect(std.mem.endsWith(u8, msg, "Bearer [REDACTED]"));
    const bare = try crashMessage(testing.allocator, "pi", null, null);
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("pi exited unexpectedly (still running)", bare);
}

test "agent_proc: redact matches Rust's vectors" {
    const raw = "request failed: Bearer secret-one Basic secret-two sk-private ghp-private ghp_private xoxp-private api_key=private&code=401 café";
    const clean = try redactSecrets(testing.allocator, raw);
    defer testing.allocator.free(clean);
    try testing.expectEqualStrings("request failed: Bearer [REDACTED] Basic [REDACTED] [REDACTED] ghp-private [REDACTED] [REDACTED] api_key=[REDACTED]&code=401 café", clean);
}

test "agent_proc: candidate paths follow PATH, login PATH, extras, node dirs" {
    var list = try candidatePaths(testing.allocator, .{
        .name = "claude",
        .path_env = "/usr/bin:/bin:/usr/bin",
        .login_path = "/opt/x/bin",
        .home = "/h",
        .extra = &.{ "~/.claude/local/claude", "/opt/homebrew/bin/claude" },
    });
    defer {
        for (list.items) |p| testing.allocator.free(p);
        list.deinit(testing.allocator);
    }
    try testing.expectEqualStrings("/usr/bin/claude", list.items[0]);
    try testing.expectEqualStrings("/bin/claude", list.items[1]);
    try testing.expectEqualStrings("/opt/x/bin/claude", list.items[2]);
    try testing.expectEqualStrings("/h/.claude/local/claude", list.items[3]);
    try testing.expectEqualStrings("/opt/homebrew/bin/claude", list.items[4]);
    try testing.expectEqualStrings("/h/.local/share/fnm/aliases/default/bin/claude", list.items[5]);
}

test "agent_proc: composed child PATH puts the exe dir first and dedupes" {
    const p = try composeChildPath(testing.allocator, "/opt/a/bin/claude", "/usr/bin:/opt/a/bin", "/usr/bin:/x");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/opt/a/bin:/usr/bin:/x", p);
}

test "agent_proc: missing binary and missing cwd are reported, a slow child is killed by its deadline" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    try testing.expectError(error.NotInstalled, AgentProc.spawn(testing.allocator, io, &.{"/nonexistent/harness-agent-xyz"}, null, null, .{}));
    try testing.expectError(error.MissingCwd, AgentProc.spawn(testing.allocator, io, &.{"/bin/sh"}, "/nonexistent/dir-xyz", null, .{}));

    const p = try AgentProc.spawn(testing.allocator, io, &.{ "/bin/sh", "-c", "echo hello; echo oops >&2; sleep 30" }, null, null, .{});
    defer p.destroy();
    p.armDeadline(3000);
    const l = (try p.readLine()).?;
    try testing.expectEqualStrings("hello", l);
    p.terminate();
    try testing.expect((try p.readLine()) == null);
    const term = p.wait();
    try testing.expect(term != null and term.? == .signal);
    const tail = p.stderrTail(testing.allocator);
    defer if (tail) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("oops", tail.?);
}
