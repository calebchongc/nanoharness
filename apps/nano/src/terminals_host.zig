//! PTY terminals owned by this device (`crates/engine/src/terminals.rs`).
//!
//! `open` spawns the user's login shell (`$SHELL -l`, else `/bin/zsh` on
//! macOS and `/bin/bash` elsewhere) on a fresh pseudo-terminal in its own
//! session and process group, with the engine's environment plus `TERM`,
//! `COLORTERM`, `TERM_PROGRAM` and any host-resolved overrides. A reader
//! thread batches output every `session_doc.terminal_output_batch_ms` into
//! `{type:"data", seq, data:<base64>}` events kept in a 1 MiB replay window,
//! and ends with `{type:"exit", seq, exitCode}`. Live shells survive their
//! subscribers; closing a terminal (or stopping the engine) hangs up and then
//! kills its whole process group. Exited sessions linger 30 minutes so a
//! returning viewer still sees the tail and the exit status.
//!
//! Locking: every call below runs with the manager's guard held (the engine's
//! `host.mutex`, attached with `attach`); reader threads take it to record
//! and publish an event, and never while reading the PTY. `close` never waits
//! for a reader thread (it may be waiting for the guard); the thread finishes
//! the kill and is joined later.
//!
//! macOS and Linux only. Windows (ConPTY) is not built: `open` says so.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const session_doc = @import("session_doc.zig");

pub const max_terminals: usize = 32;
pub const max_input_bytes: usize = 64 * 1024;
pub const max_replay_bytes: usize = 1024 * 1024;
pub const exited_ttl_ms: i64 = 30 * 60 * 1000;
pub const output_batch_ms: i64 = @intCast(session_doc.terminal_output_batch_ms);

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;
pub const windows_unavailable = "terminals are not available on Windows in this build";

pub const winsize = extern struct {
    ws_row: c_ushort,
    ws_col: c_ushort,
    ws_xpixel: c_ushort = 0,
    ws_ypixel: c_ushort = 0,
};

const C = struct {
    extern "c" fn posix_openpt(flags: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
    extern "c" fn signal(sig: c_int, handler: usize) usize;
    /// libc's real prototype: the request is an `unsigned long`.
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn getsid(pid: c_int) c_int;
    extern "c" fn tcgetpgrp(fd: c_int) c_int;
};

const Darwin = struct {
    extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
};

/// `TIOCSWINSZ` / `TIOCSCTTY` (Darwin's values are not in `std.c.T`).
const tiocswinsz: c_ulong = if (builtin.os.tag == .macos) 0x80087467 else if (supported) std.c.T.IOCSWINSZ else 0;
const tiocsctty: c_ulong = if (builtin.os.tag == .macos) 0x20007461 else if (supported) std.c.T.IOCSCTTY else 0;

pub fn Result(comptime T: type) type {
    return union(enum) { ok: T, failed: []const u8 };
}

/// Called with the guard held after an event is recorded.
pub const Sink = struct {
    ctx: *anyopaque,
    event: *const fn (ctx: *anyopaque, terminal_id: []const u8, event_json: []const u8, exit: bool) void,
};

const StoredEvent = struct { seq: u64, json: []u8, cost: usize };

/// One live or exited terminal. Heap-allocated so its reader thread can hold
/// it while the session map changes; freed only after that thread is joined.
pub const Live = struct {
    mgr: *TerminalManager,
    id: []u8,
    cwd: []u8,
    shell_name: []u8,
    pid: c_int = -1,
    master_fd: c_int = -1,
    replay: std.ArrayList(StoredEvent) = .empty,
    replay_head: usize = 0,
    replay_bytes: usize = 0,
    seq: u64 = 0,
    exited: bool = false,
    last_active_ms: i64 = 0,
    script_path: ?[]u8 = null,
    closing: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    thread_done: std.atomic.Value(bool) = .init(false),

    fn destroy(l: *Live, gpa: Allocator, io: ?std.Io) void {
        if (l.thread) |t| t.join();
        if (comptime supported) {
            if (l.master_fd >= 0) _ = std.c.close(l.master_fd);
        }
        if (l.script_path) |p| {
            if (io) |i| std.Io.Dir.cwd().deleteFile(i, p) catch {};
            gpa.free(p);
        }
        for (l.replay.items[l.replay_head..]) |e| gpa.free(e.json);
        l.replay.deinit(gpa);
        gpa.free(l.id);
        gpa.free(l.cwd);
        gpa.free(l.shell_name);
        gpa.destroy(l);
    }

    /// Stamp a seq, keep the event in the bounded replay window and hand it
    /// to the sink. Guard held.
    fn emit(l: *Live, comptime kind: enum { data, exit }, payload: anytype) !void {
        const gpa = l.mgr.gpa;
        l.seq += 1;
        l.last_active_ms = l.mgr.nowMs();
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        var cost: usize = 16;
        switch (kind) {
            .data => {
                const enc = std.base64.standard.Encoder;
                const b64 = try gpa.alloc(u8, enc.calcSize(payload.len));
                defer gpa.free(b64);
                _ = enc.encode(b64, payload);
                cost = b64.len;
                try aw.writer.print("{{\"type\":\"data\",\"seq\":{d},\"data\":\"{s}\"}}", .{ l.seq, b64 });
            },
            .exit => try aw.writer.print("{{\"type\":\"exit\",\"seq\":{d},\"exitCode\":{d}}}", .{ l.seq, payload }),
        }
        const ev_json = try aw.toOwnedSlice();
        errdefer gpa.free(ev_json);
        try l.replay.append(gpa, .{ .seq = l.seq, .json = ev_json, .cost = cost });
        l.replay_bytes += cost;
        while (l.replay_bytes > max_replay_bytes and l.replay.items.len - l.replay_head > 1) {
            const dropped = l.replay.items[l.replay_head];
            l.replay_bytes -= dropped.cost;
            gpa.free(dropped.json);
            l.replay_head += 1;
        }
        if (l.replay_head > 256 and l.replay_head * 2 > l.replay.items.len) {
            const live_items = l.replay.items[l.replay_head..];
            std.mem.copyForwards(StoredEvent, l.replay.items[0..live_items.len], live_items);
            l.replay.items.len = live_items.len;
            l.replay_head = 0;
        }
        if (kind == .exit) {
            l.exited = true;
            // The action script lives only as long as its shell.
            if (l.script_path) |sp| {
                if (l.mgr.io) |i| std.Io.Dir.cwd().deleteFile(i, sp) catch {};
                gpa.free(sp);
                l.script_path = null;
            }
            if (l.mgr.sessions.getPtr(l.id)) |s| {
                if (s.live == l) s.exited = true;
            }
        }
        if (l.mgr.sink) |s| s.event(s.ctx, l.id, ev_json, kind == .exit);
    }
};

/// The map's value: the terminal and whether its shell has exited (read by
/// the updater's quiescence check).
pub const TerminalSession = struct {
    live: *Live,
    exited: bool = false,
};

pub const OpenOptions = struct {
    cwd: []const u8,
    cols: u16,
    rows: u16,
    /// Explicit shell (tests use `/bin/sh`); default the user's.
    shell: ?[]const u8 = null,
    /// `-l`: a login shell, the user's real PATH and profile.
    login: bool = true,
    /// Host-resolved environment overrides.
    env: []const [2][]const u8 = &.{},
    /// Run this exact command first (project Actions): written to a private
    /// script the shell sources, so only a short line crosses the PTY.
    command: ?[]const u8 = null,
};

pub const Opened = struct { id: []const u8, cwd: []const u8, shell: []const u8 };

pub const Replay = struct {
    items: [][]u8,
    exited: bool,
};

pub const TerminalManager = struct {
    gpa: Allocator,
    sessions: std.StringHashMapUnmanaged(TerminalSession) = .empty,
    /// Closed terminals whose reader thread is still finishing the kill.
    retired: std.ArrayList(*Live) = .empty,
    io: ?std.Io = null,
    guard: ?*std.Io.Mutex = null,
    sink: ?Sink = null,

    pub fn init(gpa: Allocator) TerminalManager {
        return .{ .gpa = gpa };
    }

    /// Give the manager the engine's I/O, the lock its callers hold, and
    /// where events go. Idempotent.
    pub fn attach(self: *TerminalManager, io: std.Io, guard: *std.Io.Mutex, sink: ?Sink) void {
        self.io = io;
        self.guard = guard;
        self.sink = sink;
    }

    fn nowMs(self: *const TerminalManager) i64 {
        const io = self.io orelse return 0;
        return @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    }

    /// Engine shutdown: hang up every shell, kill its process group, join
    /// every reader. Called without the guard held.
    pub fn deinit(self: *TerminalManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            const l = e.value_ptr.live;
            l.closing.store(true, .release);
            hangUp(l);
        }
        for (self.retired.items) |l| l.closing.store(true, .release);
        // Join every reader before freeing anything a reader may still read.
        it = self.sessions.iterator();
        while (it.next()) |e| {
            const l = e.value_ptr.live;
            if (l.thread) |t| t.join();
            l.thread = null;
        }
        for (self.retired.items) |l| {
            if (l.thread) |t| t.join();
            l.thread = null;
        }
        it = self.sessions.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.live.destroy(self.gpa, self.io);
        }
        self.sessions.deinit(self.gpa);
        for (self.retired.items) |l| l.destroy(self.gpa, self.io);
        self.retired.deinit(self.gpa);
    }

    /// Join and free closed terminals whose readers finished, and drop
    /// exited sessions nobody looked at for `exited_ttl_ms`.
    fn sweep(self: *TerminalManager) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            const l = self.retired.items[i];
            if (l.thread_done.load(.acquire)) {
                _ = self.retired.swapRemove(i);
                l.destroy(self.gpa, self.io);
                continue;
            }
            i += 1;
        }
        const now = self.nowMs();
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.gpa);
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            const l = e.value_ptr.live;
            if (l.exited and l.thread_done.load(.acquire) and now - l.last_active_ms > exited_ttl_ms) {
                expired.append(self.gpa, e.key_ptr.*) catch break;
            }
        }
        for (expired.items) |k| {
            const kv = self.sessions.fetchRemove(k) orelse continue;
            self.gpa.free(kv.key);
            kv.value.live.destroy(self.gpa, self.io);
        }
    }

    fn find(self: *TerminalManager, id: []const u8) ?*Live {
        const s = self.sessions.get(id) orelse return null;
        s.live.last_active_ms = self.nowMs();
        return s.live;
    }

    /// Open a shell in `opts.cwd` (`Terminals::open_session`).
    pub fn open(self: *TerminalManager, opts: OpenOptions) !Result(Opened) {
        if (comptime builtin.os.tag == .windows) return .{ .failed = windows_unavailable };
        if (comptime !supported) return .{ .failed = "could not open a pty: terminals are not available on this platform" };
        const io = self.io orelse return .{ .failed = "could not open a pty: the engine has no I/O" };
        self.sweep();
        if (self.sessions.count() >= max_terminals) return .{ .failed = common.errText("Too many open terminals (maximum {d})", .{max_terminals}) };
        if (!common.isDir(io, opts.cwd)) return .{ .failed = "Session working directory is unavailable" };
        return spawnSession(self, io, opts);
    }

    /// Replay after `after_seq` (bounded window), and whether the shell has
    /// exited (then the stream ends after the replay).
    pub fn replay(self: *TerminalManager, gpa: Allocator, id: []const u8, after_seq: u64) !Result(Replay) {
        self.sweep();
        const l = self.find(id) orelse return .{ .failed = "Terminal not found" };
        var items: std.ArrayList([]u8) = .empty;
        errdefer {
            for (items.items) |it| gpa.free(it);
            items.deinit(gpa);
        }
        for (l.replay.items[l.replay_head..]) |e| {
            if (e.seq > after_seq) try items.append(gpa, try gpa.dupe(u8, e.json));
        }
        return .{ .ok = .{ .items = try items.toOwnedSlice(gpa), .exited = l.exited } };
    }

    /// Input bytes: base64 (as `data` events are), with a raw UTF-8 fallback.
    pub fn write(self: *TerminalManager, id: []const u8, data: []const u8) !Result(void) {
        const dec = std.base64.standard.Decoder;
        var decoded: ?[]u8 = null;
        defer if (decoded) |b| self.gpa.free(b);
        if (dec.calcSizeForSlice(data)) |n| {
            const buf = try self.gpa.alloc(u8, n);
            if (dec.decode(buf, data)) |_| {
                decoded = buf;
            } else |_| self.gpa.free(buf);
        } else |_| {}
        return self.writeBytes(id, decoded orelse data);
    }

    /// Trusted host-side bytes, written as they are.
    pub fn writeBytes(self: *TerminalManager, id: []const u8, bytes: []const u8) Result(void) {
        if (bytes.len > max_input_bytes) return .{ .failed = "Terminal input is too large" };
        const l = self.find(id) orelse return .{ .failed = "Terminal not found" };
        if (l.exited or l.master_fd < 0) return .{ .failed = "Terminal has exited" };
        if (comptime !supported) return .{ .failed = "Terminal has exited" };
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(l.master_fd, bytes[off..].ptr, bytes.len - off);
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .INTR or e == .AGAIN) continue;
                return .{ .failed = common.errText("Terminal write failed: {s}", .{@tagName(e)}) };
            }
            off += @intCast(n);
        }
        return .{ .ok = {} };
    }

    pub fn resize(self: *TerminalManager, id: []const u8, cols: u16, rows: u16) Result(void) {
        const l = self.find(id) orelse return .{ .failed = "Terminal not found" };
        if (l.exited or l.master_fd < 0) return .{ .ok = {} };
        if (comptime !supported) return .{ .ok = {} };
        const ws = clampSize(cols, rows);
        if (C.ioctl(l.master_fd, tiocswinsz, &ws) != 0) {
            return .{ .failed = common.errText("Terminal resize failed: {s}", .{@tagName(std.posix.errno(@as(c_int, -1)))}) };
        }
        return .{ .ok = {} };
    }

    /// Kill the shell (if still running) and drop the session and its replay.
    pub fn close(self: *TerminalManager, id: []const u8) !Result(void) {
        self.sweep();
        const kv = self.sessions.fetchRemove(id) orelse return .{ .failed = "Terminal not found" };
        self.gpa.free(kv.key);
        const l = kv.value.live;
        l.closing.store(true, .release);
        if (!l.exited) hangUp(l);
        if (l.thread_done.load(.acquire)) {
            l.destroy(self.gpa, self.io);
        } else {
            try self.retired.append(self.gpa, l);
        }
        return .{ .ok = {} };
    }
};

fn clampSize(cols: u16, rows: u16) winsize {
    return .{ .ws_col = std.math.clamp(cols, 2, 500), .ws_row = std.math.clamp(rows, 1, 300) };
}

/// SIGHUP to the shell's process group and the terminal's foreground job.
/// Cheap: runs under the lock; the reader thread then sweeps the session.
fn hangUp(l: *Live) void {
    if (comptime !supported) return;
    if (l.pid <= 0) return;
    _ = std.c.kill(-l.pid, .HUP);
    const fg = C.tcgetpgrp(l.master_fd);
    if (fg > 0 and fg != l.pid) _ = std.c.kill(-fg, .HUP);
}

/// Every process in the shell's session (it is the session leader, so the
/// session id is its pid): its own group, the foreground job and background
/// jobs in groups of their own.
fn signalSession(gpa: Allocator, io: std.Io, l: *Live, sig: std.c.SIG) void {
    if (comptime !supported) return;
    if (l.pid <= 0) return;
    _ = std.c.kill(-l.pid, sig);
    const fg = C.tcgetpgrp(l.master_fd);
    if (fg > 0 and fg != l.pid) _ = std.c.kill(-fg, sig);
    const pids = listPids(gpa, io) catch return;
    defer gpa.free(pids);
    for (pids) |p| {
        if (p <= 1 or p == l.pid) continue;
        if (C.getsid(p) == l.pid) _ = std.c.kill(p, sig);
    }
}

fn listPids(gpa: Allocator, io: std.Io) ![]c_int {
    if (comptime builtin.os.tag == .macos) {
        const n = Darwin.proc_listallpids(null, 0);
        if (n <= 0) return error.NoProcessList;
        const cap: usize = @intCast(n + 256);
        const buf = try gpa.alloc(c_int, cap);
        errdefer gpa.free(buf);
        const got = Darwin.proc_listallpids(buf.ptr, @intCast(cap * @sizeOf(c_int)));
        if (got <= 0) return error.NoProcessList;
        return gpa.realloc(buf, @min(cap, @as(usize, @intCast(got))));
    }
    var list: std.ArrayList(c_int) = .empty;
    errdefer list.deinit(gpa);
    var dir = try std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const pid = std.fmt.parseInt(c_int, e.name, 10) catch continue;
        try list.append(gpa, pid);
    }
    return list.toOwnedSlice(gpa);
}

/// `$SHELL`, else the platform default.
pub fn selectedShell() []const u8 {
    if (common.getenv("SHELL")) |s| {
        if (std.mem.trim(u8, s, " \t\r\n").len > 0) return s;
    }
    return if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash";
}

fn newId(io: std.Io, buf: *[36]u8) []const u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
}

fn spawnSession(self: *TerminalManager, io: std.Io, opts: OpenOptions) !Result(Opened) {
    if (comptime !supported) unreachable;
    const gpa = self.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shell = opts.shell orelse selectedShell();
    const shell_name = std.fs.path.basename(shell);

    // A command runs from a private script the shell sources.
    var script_path: ?[]u8 = null;
    // Every failure (an error or a reported one) removes the script.
    defer if (script_path) |p| {
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
        gpa.free(p);
    };
    var bootstrap: ?[]const u8 = null;
    if (opts.command) |command| {
        const fish = std.mem.eql(u8, shell_name, "fish");
        const tmp = common.getenvNonEmpty("TMPDIR") orelse "/tmp";
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const name = try std.fmt.allocPrint(arena, "harness-action-{s}{s}", .{ std.fmt.bytesToHex(rnd, .lower), if (fish) ".fish" else ".sh" });
        const path = try std.fs.path.join(gpa, &.{ tmp, name });
        script_path = path;
        const path_z = try arena.dupeSentinel(u8, path, 0);
        const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c_uint, 0o600));
        if (fd < 0) return .{ .failed = common.errText("could not write the action script: {s}", .{@tagName(std.posix.errno(fd))}) };
        defer _ = std.c.close(fd);
        var off: usize = 0;
        while (off < command.len) {
            const n = std.c.write(fd, command[off..].ptr, command.len - off);
            if (n <= 0) return .{ .failed = "could not write the action script" };
            off += @intCast(n);
        }
        bootstrap = if (fish) "source \"$HARNESS_ACTION_SCRIPT\"\r" else ". \"$HARNESS_ACTION_SCRIPT\"\r";
    }

    // Everything the child needs is built before `fork`.
    var env = try @import("rpcg_diff.zig").currentEnvMap(arena);
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "Harness");
    for (opts.env) |kv| try env.put(kv[0], kv[1]);
    if (script_path) |p| try env.put("HARNESS_ACTION_SCRIPT", p);
    const envp = try arena.allocSentinel(?[*:0]const u8, env.count(), null);
    {
        var it = env.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            envp[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }, 0)).ptr;
        }
    }
    const shell_z = try arena.dupeSentinel(u8, shell, 0);
    const argv = try arena.allocSentinel(?[*:0]const u8, if (opts.login) 2 else 1, null);
    argv[0] = shell_z.ptr;
    if (opts.login) argv[1] = "-l";
    const cwd_z = try arena.dupeSentinel(u8, opts.cwd, 0);

    // The pseudo-terminal pair.
    const o_rdwr_noctty: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
    const master = C.posix_openpt(@bitCast(@as(u32, @bitCast(o_rdwr_noctty))));
    if (master < 0) return .{ .failed = common.errText("could not open a pty: {s}", .{@tagName(std.posix.errno(master))}) };
    var master_owned = true;
    defer if (master_owned) {
        _ = std.c.close(master);
    };
    if (C.grantpt(master) != 0 or C.unlockpt(master) != 0) return .{ .failed = common.errText("could not open a pty: {s}", .{@tagName(std.posix.errno(@as(c_int, -1)))}) };
    _ = std.c.fcntl(master, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    const slave_name = blk: {
        // `ptsname` uses a static buffer: copy it before anything else runs.
        pty_name_mutex.lockUncancelable(io);
        defer pty_name_mutex.unlock(io);
        const p = C.ptsname(master) orelse return .{ .failed = "could not open a pty: no slave name" };
        break :blk try arena.dupeSentinel(u8, std.mem.span(p), 0);
    };
    const slave = std.c.open(slave_name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return .{ .failed = common.errText("could not open a pty: {s}", .{@tagName(std.posix.errno(slave))}) };
    defer _ = std.c.close(slave);
    _ = std.c.fcntl(slave, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    const ws = clampSize(opts.cols, opts.rows);
    _ = C.ioctl(slave, tiocswinsz, &ws);

    // A close-on-exec pipe tells the parent whether `execve` failed.
    var err_pipe: [2]c_int = undefined;
    if (std.c.pipe(&err_pipe) != 0) return .{ .failed = "could not spawn the shell: no pipe" };
    _ = std.c.fcntl(err_pipe[0], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    _ = std.c.fcntl(err_pipe[1], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(err_pipe[0]);
        _ = std.c.close(err_pipe[1]);
        return .{ .failed = common.errText("could not spawn {s}: {s}", .{ shell_name, @tagName(std.posix.errno(pid)) }) };
    }
    if (pid == 0) childExec(slave, master, err_pipe[1], cwd_z, shell_z, argv, envp);

    _ = std.c.close(err_pipe[1]);
    var child_errno: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const n = std.c.read(err_pipe[0], child_errno[got..].ptr, 4 - got);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        got += @intCast(n);
    }
    _ = std.c.close(err_pipe[0]);
    if (got == 4) {
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        const code = std.mem.readInt(i32, &child_errno, .little);
        const name = if (code == -1) "the working directory is unavailable" else @tagName(@as(std.posix.E, @fromBackingInt(@intCast(code))));
        return .{ .failed = common.errText("could not spawn {s}: {s}", .{ shell_name, name }) };
    }

    var id_buf: [36]u8 = undefined;
    const id = newId(io, &id_buf);
    const l = try gpa.create(Live);
    errdefer gpa.destroy(l);
    l.* = .{
        .mgr = self,
        .id = try gpa.dupe(u8, id),
        .cwd = try gpa.dupe(u8, opts.cwd),
        .shell_name = try gpa.dupe(u8, shell_name),
        .pid = pid,
        .master_fd = master,
        .last_active_ms = self.nowMs(),
        .script_path = script_path,
    };
    master_owned = false;
    script_path = null;
    const key = try gpa.dupe(u8, id);
    try self.sessions.put(gpa, key, .{ .live = l });
    l.thread = std.Thread.spawn(.{}, readerMain, .{ l, io }) catch |e| {
        _ = self.sessions.remove(id);
        gpa.free(key);
        l.closing.store(true, .release);
        _ = std.c.kill(-pid, .KILL);
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        l.thread_done.store(true, .release);
        l.destroy(gpa, io);
        return .{ .failed = common.errText("pty reader thread: {s}", .{@errorName(e)}) };
    };

    if (bootstrap) |b| switch (self.writeBytes(id, b)) {
        .ok => {},
        .failed => |m| {
            _ = try self.close(id);
            return .{ .failed = m };
        },
    };
    return .{ .ok = .{ .id = l.id, .cwd = l.cwd, .shell = l.shell_name } };
}

var pty_name_mutex: std.Io.Mutex = .init;

/// In the forked child: only async-signal-safe calls from here to `execve`.
fn childExec(slave: c_int, master: c_int, err_fd: c_int, cwd: [*:0]const u8, shell: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    if (comptime !supported) unreachable;
    _ = std.c.setsid();
    _ = C.ioctl(slave, tiocsctty, @as(c_int, 0));
    _ = std.c.dup2(slave, 0);
    _ = std.c.dup2(slave, 1);
    _ = std.c.dup2(slave, 2);
    _ = std.c.close(master);
    // The engine ignores SIGPIPE; a shell must start with default handlers.
    inline for (.{ "HUP", "INT", "QUIT", "PIPE", "TERM", "ALRM", "CHLD", "TSTP", "TTIN", "TTOU", "USR1", "USR2" }) |name| {
        _ = C.signal(@intCast(@backingInt(@field(std.c.SIG, name))), 0);
    }
    // Nothing else of the engine's crosses into the shell.
    var fd: c_int = 3;
    while (fd < 1024) : (fd += 1) {
        if (fd != err_fd) _ = std.c.close(fd);
    }
    if (std.c.chdir(cwd) != 0) reportAndExit(err_fd, -1);
    _ = std.c.execve(shell, argv, envp);
    reportAndExit(err_fd, @intCast(@backingInt(std.posix.errno(@as(c_int, -1)))));
}

fn reportAndExit(err_fd: c_int, code: i32) noreturn {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, code, .little);
    _ = std.c.write(err_fd, &buf, 4);
    std.c._exit(127);
}

/// `waitpid(WNOHANG)`: the exit code once the shell is gone (a signal reads
/// as 1, as portable-pty reports it).
fn reap(pid: c_int, block: bool) ?i32 {
    if (comptime !supported) return -1;
    var status: c_int = 0;
    while (true) {
        const r = std.c.waitpid(pid, &status, if (block) 0 else std.c.W.NOHANG);
        if (r == pid) break;
        if (r < 0 and std.posix.errno(r) == .INTR) continue;
        if (r < 0) return -1; // already reaped or not ours
        return null;
    }
    const s: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(s)) return std.c.W.EXITSTATUS(s);
    return 1;
}

fn readerMain(l: *Live, io: std.Io) void {
    if (comptime !supported) return;
    defer l.thread_done.store(true, .release);
    const mgr = l.mgr;
    var buf: [64 * 1024]u8 = undefined;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(mgr.gpa);
    var batch_start: i64 = 0;
    var exit_code: ?i32 = null;

    const now = struct {
        fn f(i: std.Io) i64 {
            return @intCast(std.Io.Clock.awake.now(i).toMilliseconds());
        }
    }.f;

    while (!l.closing.load(.acquire)) {
        const timeout: c_int = if (pending.items.len > 0)
            @intCast(@max(0, output_batch_ms - (now(io) - batch_start)))
        else
            100;
        var fds = [_]std.c.pollfd{.{ .fd = l.master_fd, .events = std.c.POLL.IN, .revents = 0 }};
        const pr = std.c.poll(&fds, 1, timeout);
        var eof = false;
        if (pr > 0) {
            const n = std.c.read(l.master_fd, &buf, buf.len);
            if (n > 0) {
                if (pending.items.len == 0) batch_start = now(io);
                pending.appendSlice(mgr.gpa, buf[0..@intCast(n)]) catch {};
            } else if (n == 0) {
                eof = true;
            } else switch (std.posix.errno(n)) {
                .INTR, .AGAIN => {},
                else => eof = true, // EIO once the last slave fd closes (Linux)
            }
        }
        if (pending.items.len > 0 and (eof or now(io) - batch_start >= output_batch_ms)) {
            publishData(l, io, pending.items);
            pending.clearRetainingCapacity();
        }
        if (eof) break;
        if (pr == 0 and pending.items.len == 0) {
            // Idle: the shell may be gone while a background child keeps the
            // PTY open. Drain what is buffered, then finish.
            if (reap(l.pid, false)) |code| {
                exit_code = code;
                drain(l, io, &buf, &pending);
                break;
            }
        }
    }

    if (l.closing.load(.acquire)) {
        // Closed: finish the kill nobody waits for, emit nothing. The shell
        // stays unreaped until the end so its pid (the session id) can't be
        // reused while the session is swept.
        if (exit_code == null) {
            signalSession(mgr.gpa, io, l, .HUP);
            std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
            signalSession(mgr.gpa, io, l, .KILL);
            _ = reap(l.pid, true);
        }
        return;
    }
    if (pending.items.len > 0) publishData(l, io, pending.items);
    while (exit_code == null) {
        if (l.closing.load(.acquire)) {
            signalSession(mgr.gpa, io, l, .KILL);
            _ = reap(l.pid, true);
            return;
        }
        exit_code = reap(l.pid, false);
        if (exit_code == null) std.Io.sleep(io, .fromMilliseconds(25), .awake) catch break;
    }
    const guard = mgr.guard orelse return;
    guard.lockUncancelable(io);
    defer guard.unlock(io);
    if (l.closing.load(.acquire)) return;
    l.emit(.exit, exit_code orelse -1) catch {};
}

fn drain(l: *Live, io: std.Io, buf: *[64 * 1024]u8, pending: *std.ArrayList(u8)) void {
    _ = io;
    while (true) {
        var fds = [_]std.c.pollfd{.{ .fd = l.master_fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 0) <= 0) return;
        const n = std.c.read(l.master_fd, buf, buf.len);
        if (n <= 0) return;
        pending.appendSlice(l.mgr.gpa, buf[0..@intCast(n)]) catch return;
    }
}

fn publishData(l: *Live, io: std.Io, bytes: []const u8) void {
    const guard = l.mgr.guard orelse return;
    guard.lockUncancelable(io);
    defer guard.unlock(io);
    if (l.closing.load(.acquire)) return;
    l.emit(.data, bytes) catch {};
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const TestSink = struct {
    events: std.ArrayList([]u8) = .empty,
    exits: usize = 0,

    fn on(ctx: *anyopaque, _: []const u8, event_json: []const u8, exit: bool) void {
        const s: *TestSink = @ptrCast(@alignCast(ctx));
        s.events.append(testing.allocator, testing.allocator.dupe(u8, event_json) catch return) catch {};
        if (exit) s.exits += 1;
    }

    fn deinit(s: *TestSink) void {
        for (s.events.items) |e| testing.allocator.free(e);
        s.events.deinit(testing.allocator);
    }

    /// Every data event's bytes so far, decoded.
    fn output(s: *TestSink, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s.events.items) |e| {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, e, .{});
            if (!std.mem.eql(u8, parsed.object.get("type").?.string, "data")) continue;
            const b64 = parsed.object.get("data").?.string;
            const dec = std.base64.standard.Decoder;
            const bytes = try a.alloc(u8, try dec.calcSizeForSlice(b64));
            try dec.decode(bytes, b64);
            try out.appendSlice(a, bytes);
        }
        return out.items;
    }
};

const TestTerms = struct {
    mgr: TerminalManager,
    guard: std.Io.Mutex = .init,
    sink: TestSink = .{},
    tmp: testing.TmpDir,
    dir: []u8,
    env: common.TestEnv,

    fn init() !*TestTerms {
        const t = try testing.allocator.create(TestTerms);
        t.* = .{ .mgr = TerminalManager.init(testing.allocator), .tmp = testing.tmpDir(.{}), .dir = undefined, .env = undefined };
        t.dir = try common.tmpPath(testing.allocator, testing.io, &t.tmp);
        t.env = try common.TestEnv.init(testing.allocator, t.dir);
        t.env.install();
        t.mgr.attach(testing.io, &t.guard, .{ .ctx = &t.sink, .event = TestSink.on });
        return t;
    }

    fn deinit(t: *TestTerms) void {
        t.mgr.deinit();
        t.sink.deinit();
        t.env.deinit();
        testing.allocator.free(t.dir);
        t.tmp.cleanup();
        testing.allocator.destroy(t);
    }

    fn lock(t: *TestTerms) void {
        t.guard.lockUncancelable(testing.io);
    }

    fn unlock(t: *TestTerms) void {
        t.guard.unlock(testing.io);
    }

    /// Wait (with a deadline) until the decoded output contains `needle`.
    fn waitOutput(t: *TestTerms, needle: []const u8) !void {
        var waited: usize = 0;
        while (waited < 10_000) : (waited += 20) {
            {
                t.lock();
                defer t.unlock();
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                if (std.mem.indexOf(u8, try t.sink.output(arena.allocator()), needle) != null) return;
            }
            try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
        }
        t.lock();
        defer t.unlock();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        std.debug.print("terminal output so far: {f}\n", .{std.json.fmt(try t.sink.output(arena.allocator()), .{})});
        return error.TerminalOutputNeverArrived;
    }

    fn waitExit(t: *TestTerms) !void {
        var waited: usize = 0;
        while (waited < 10_000) : (waited += 20) {
            {
                t.lock();
                defer t.unlock();
                if (t.sink.exits > 0) return;
            }
            try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
        }
        return error.TerminalNeverExited;
    }
};

fn processAlive(pid: c_int) bool {
    if (comptime !supported) return false;
    return std.c.kill(pid, @fromBackingInt(@intCast(0))) == 0;
}

test "terminals_host runs /bin/sh on a PTY: output, input, resize, exit and replay" {
    if (comptime !supported) return;
    const t = try TestTerms.init();
    defer t.deinit();
    t.lock();
    const opened = switch (try t.mgr.open(.{ .cwd = t.dir, .cols = 100, .rows = 30, .shell = "/bin/sh", .login = false })) {
        .ok => |o| o,
        .failed => |m| {
            t.unlock();
            std.debug.print("open failed: {s}\n", .{m});
            return error.OpenFailed;
        },
    };
    const id = try testing.allocator.dupe(u8, opened.id);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("sh", opened.shell);
    try testing.expectEqual(@as(usize, 36), id.len);
    // Input reaches the shell; its own output comes back (not the keystrokes appended by us).
    try testing.expect(t.mgr.writeBytes(id, "stty size; printf 'TERM=%s\\n' \"$TERM\"; pwd\n") == .ok);
    t.unlock();
    try t.waitOutput("30 100");
    try t.waitOutput("TERM=xterm-256color");
    try t.waitOutput(t.dir);

    t.lock();
    try testing.expect(t.mgr.resize(id, 120, 40) == .ok);
    // base64 input, as the client sends it.
    try testing.expect((try t.mgr.write(id, "c3R0eSBzaXplCg==")) == .ok);
    t.unlock();
    try t.waitOutput("40 120");

    t.lock();
    try testing.expect((try t.mgr.write(id, "exit 7\n")) == .ok);
    t.unlock();
    try t.waitExit();

    t.lock();
    defer t.unlock();
    const last = t.sink.events.items[t.sink.events.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, last, "\"type\":\"exit\"") != null);
    try testing.expect(std.mem.indexOf(u8, last, "\"exitCode\":7") != null);
    try testing.expect(t.mgr.sessions.get(id).?.exited);
    // Replay after a seq; writing to an exited shell fails.
    const all = (try t.mgr.replay(testing.allocator, id, 0)).ok;
    defer {
        for (all.items) |x| testing.allocator.free(x);
        testing.allocator.free(all.items);
    }
    try testing.expect(all.exited);
    try testing.expectEqual(t.sink.events.items.len, all.items.len);
    const tail = (try t.mgr.replay(testing.allocator, id, all.items.len - 1)).ok;
    defer {
        for (tail.items) |x| testing.allocator.free(x);
        testing.allocator.free(tail.items);
    }
    try testing.expectEqual(@as(usize, 1), tail.items.len);
    try testing.expectEqualStrings("Terminal has exited", t.mgr.writeBytes(id, "x").failed);
    try testing.expect(t.mgr.resize(id, 80, 24) == .ok);
    try testing.expect((try t.mgr.close(id)) == .ok);
    try testing.expectEqualStrings("Terminal not found", (try t.mgr.close(id)).failed);
}

test "terminals_host close kills the shell's whole process group" {
    if (comptime !supported) return;
    const t = try TestTerms.init();
    defer t.deinit();
    t.lock();
    const opened = (try t.mgr.open(.{ .cwd = t.dir, .cols = 80, .rows = 24, .shell = "/bin/sh", .login = false })).ok;
    const id = try testing.allocator.dupe(u8, opened.id);
    defer testing.allocator.free(id);
    // A background child in the same group that ignores SIGHUP.
    try testing.expect(t.mgr.writeBytes(id, "trap '' HUP; sleep 60 & bgpid=$(jobs -p); echo \"B\"\"G=$bgpid\"\n") == .ok);
    t.unlock();
    try t.waitOutput("BG=");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    t.lock();
    const out = try t.sink.output(arena.allocator());
    const shell_pid = t.mgr.sessions.get(id).?.live.pid;
    t.unlock();
    const at = std.mem.indexOf(u8, out, "BG=").? + 3;
    var end = at;
    while (end < out.len and std.ascii.isDigit(out[end])) end += 1;
    const bg: c_int = try std.fmt.parseInt(c_int, out[at..end], 10);
    try testing.expect(processAlive(bg));

    t.lock();
    try testing.expect((try t.mgr.close(id)) == .ok);
    t.unlock();
    var waited: usize = 0;
    while (waited < 5_000 and (processAlive(bg) or processAlive(shell_pid))) : (waited += 25) {
        try std.Io.sleep(testing.io, .fromMilliseconds(25), .awake);
    }
    try testing.expect(!processAlive(bg));
    try testing.expect(!processAlive(shell_pid));
    // No event follows a close.
    t.lock();
    defer t.unlock();
    try testing.expectEqual(@as(usize, 0), t.sink.exits);
}

test "terminals_host refuses a missing folder, an unknown terminal, oversized input and runs a command script" {
    if (comptime !supported) return;
    const t = try TestTerms.init();
    defer t.deinit();
    t.lock();
    defer t.unlock();
    try testing.expectEqualStrings("Session working directory is unavailable", (try t.mgr.open(.{ .cwd = "/nonexistent-synthetic-folder", .cols = 80, .rows = 24, .shell = "/bin/sh" })).failed);
    try testing.expect(std.mem.startsWith(u8, (try t.mgr.open(.{ .cwd = t.dir, .cols = 80, .rows = 24, .shell = "/nonexistent/shell" })).failed, "could not spawn shell: "));
    try testing.expectEqualStrings("Terminal not found", t.mgr.writeBytes("nope", "x").failed);
    try testing.expectEqualStrings("Terminal not found", t.mgr.resize("nope", 1, 1).failed);
    try testing.expectEqualStrings("Terminal not found", (try t.mgr.replay(testing.allocator, "nope", 0)).failed);
    const big = try testing.allocator.alloc(u8, max_input_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expectEqualStrings("Terminal input is too large", t.mgr.writeBytes("nope", big).failed);

    const opened = (try t.mgr.open(.{ .cwd = t.dir, .cols = 80, .rows = 24, .shell = "/bin/sh", .login = false, .env = &.{.{ "HARNESS_PROJECT_ROOT", "/synthetic/root" }}, .command = "printf 'ROOT=%s\\n' \"$HARNESS_PROJECT_ROOT\"; exit 3" })).ok;
    const script = try testing.allocator.dupe(u8, opened.id);
    defer testing.allocator.free(script);
    t.unlock();
    try t.waitOutput("ROOT=/synthetic/root");
    try t.waitExit();
    t.lock();
    // The private script is gone with its shell.
    try testing.expect(t.mgr.sessions.get(script).?.live.script_path == null);
    try testing.expect((try t.mgr.close(script)) == .ok);
}
