//! Shared pieces of the `InstallHarness` port (`harness_install*.zig`):
//!
//! - `Failure`: a `HarnessError` (its kind and message) and its `Display`.
//! - `Cancel`: the install's `CancellationToken`.
//! - `guard`: tokio's `select!` of cancel / deadline / work, plus the
//!   per-chunk stall timeout `archive_install.rs` puts on a download. The
//!   work runs as an `Io.concurrent` task; stopping it cancels the task, so
//!   its next I/O returns `error.Canceled` and it unwinds (Rust drops the
//!   future).
//! - `Http`: `reqwest`'s GET over `std.http.Client`, with reqwest's error
//!   texts (`error_for_status`, request and body errors).
//! - `TestServer`: an in-process loopback HTTP server for the tests.
//!
//! Std-only (plus `catalog_core.zig` for the environment seam).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const catalog_core = @import("catalog_core.zig");

pub const is_windows = builtin.os.tag == .windows;

// ── failures ───────────────────────────────────────────────────────────────

/// Which `HarnessError` variant a failure is, for its `Display`.
pub const Kind = enum {
    /// `HarnessError::Install`: "adapter install failed: {0}".
    install,
    /// `HarnessError::NotInstalled`: "harness binary not found: {0}".
    not_installed,
    /// `HarnessError::Io`: "io: {0}".
    io,
    /// An `anyhow` error or an `RpcError::Failed` text: the message alone.
    bare,
};

pub const Failure = struct {
    kind: Kind,
    /// Owned.
    msg: []u8,

    pub fn deinit(f: Failure, gpa: Allocator) void {
        gpa.free(f.msg);
    }

    /// `HarnessError`'s `to_string()` (owned).
    pub fn display(f: Failure, gpa: Allocator) Allocator.Error![]u8 {
        const prefix = switch (f.kind) {
            .install => "adapter install failed: ",
            .not_installed => "harness binary not found: ",
            .io => "io: ",
            .bare => "",
        };
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, f.msg });
    }

    /// The same message as another kind (`HarnessError::Install(format!("{err:#}"))`).
    pub fn rekind(f: Failure, kind: Kind) Failure {
        return .{ .kind = kind, .msg = f.msg };
    }
};

pub fn fail(gpa: Allocator, kind: Kind, comptime fmt: []const u8, args: anytype) Allocator.Error!Failure {
    return .{ .kind = kind, .msg = try std.fmt.allocPrint(gpa, fmt, args) };
}

/// Every fallible step here: out of memory, or the task was cancelled.
pub const Error = error{ OutOfMemory, Canceled };

pub fn Result(comptime T: type) type {
    return union(enum) { ok: T, err: Failure };
}

/// `std::io::Error`'s display for the errors installs hit.
pub fn ioText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied, error.PermissionDenied => "Permission denied (os error 13)",
        error.PathAlreadyExists => "File exists (os error 17)",
        error.NoSpaceLeft => "No space left on device (os error 28)",
        error.NotDir => "Not a directory (os error 20)",
        error.IsDir => "Is a directory (os error 21)",
        error.DirNotEmpty => "Directory not empty (os error 66)",
        error.ReadOnlyFileSystem => "Read-only file system (os error 30)",
        error.NameTooLong => "File name too long (os error 63)",
        else => @errorName(err),
    };
}

/// A `HarnessError::Io` failure for `err`, or `error.Canceled` when the
/// task was cancelled (cancellation is never a message).
pub fn ioFailure(gpa: Allocator, err: anyerror) Error!Failure {
    if (err == error.Canceled) return error.Canceled;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return fail(gpa, .io, "{s}", .{ioText(err)});
}

// ── cancellation ───────────────────────────────────────────────────────────

/// The install's `CancellationToken`.
pub const Cancel = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *Cancel) void {
        self.flag.store(true, .release);
    }

    pub fn isCancelled(self: *const Cancel) bool {
        return self.flag.load(.acquire);
    }
};

pub fn nowNs(io: Io) i64 {
    return @intCast(Io.Clock.awake.now(io).nanoseconds);
}

pub const Stop = enum { cancelled, timed_out, stalled };

pub const Guard = struct {
    cancel: ?*const Cancel = null,
    /// Whole-task deadline from now.
    deadline_ms: ?u64 = null,
    /// Last progress (awake-clock ns) the task stamps; with `stall_ms`, no
    /// progress for that long stops the task.
    progress: ?*const std.atomic.Value(i64) = null,
    stall_ms: u64 = 0,
};

fn ReturnOf(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

pub fn Guarded(comptime T: type) type {
    return union(enum) { done: T, stopped: Stop };
}

/// Run `func(args)` as a concurrent task until it finishes, or stop it on
/// cancel (checked first, as `biased;`), the deadline, or a stall. A
/// stopped task is cancelled and awaited; `free` releases whatever it
/// returned. When this caller is itself cancelled, the task is cancelled
/// too and `error.Canceled` propagates.
pub fn guard(
    io: Io,
    g: Guard,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
    comptime free: fn (ReturnOf(func)) void,
) error{Canceled}!Guarded(ReturnOf(func)) {
    const R = ReturnOf(func);
    const Args = @TypeOf(args);
    if (g.cancel) |c| if (c.isCancelled()) return .{ .stopped = .cancelled };
    const Wrap = struct {
        fn run(done: *std.atomic.Value(bool), a: Args) R {
            defer done.store(true, .release);
            return @call(.auto, func, a);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    var future = io.concurrent(Wrap.run, .{ &done, args }) catch {
        // No concurrency on this Io: run in place, unguarded.
        return .{ .done = @call(.auto, func, args) };
    };
    const start = nowNs(io);
    while (true) {
        if (done.load(.acquire)) return .{ .done = future.await(io) };
        const now = nowNs(io);
        const stop: ?Stop = blk: {
            if (g.cancel) |c| if (c.isCancelled()) break :blk .cancelled;
            if (g.deadline_ms) |ms| if (now - start >= @as(i64, @intCast(ms)) * std.time.ns_per_ms) break :blk .timed_out;
            if (g.progress) |p| if (g.stall_ms > 0 and now - p.load(.acquire) >= @as(i64, @intCast(g.stall_ms)) * std.time.ns_per_ms) break :blk .stalled;
            break :blk null;
        };
        if (stop) |s| {
            free(future.cancel(io));
            return .{ .stopped = s };
        }
        io.sleep(.fromMilliseconds(10), .awake) catch {
            free(future.cancel(io));
            return error.Canceled;
        };
    }
}

// ── environment ────────────────────────────────────────────────────────────

/// The environment the install sees (owned; `catalog_core.env_override` in tests).
pub fn currentEnv(gpa: Allocator) Allocator.Error!Environ.Map {
    return catalog_core.currentEnv(gpa) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Replace the environment installs see (tests); null restores the process's.
pub fn setEnvOverride(map: ?*const Environ.Map) void {
    catalog_core.env_override = map;
}

/// `executable::home_dir`: HOME, or USERPROFILE on Windows, when non-empty.
pub fn homeDir(env: *const Environ.Map) ?[]const u8 {
    if (env.get("HOME")) |h| if (h.len > 0) return h;
    if (is_windows) if (env.get("USERPROFILE")) |h| if (h.len > 0) return h;
    return null;
}

pub fn getNonEmpty(env: *const Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len > 0) v else null;
}

/// This process's id (`std::process::id()`).
pub fn processId() i64 {
    if (comptime is_windows) return @intCast(std.os.windows.GetCurrentProcessId());
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) return std.os.linux.getpid();
    return @intCast(std.c.getpid());
}

/// A random v4 UUID in its hyphenated form (`uuid::Uuid::new_v4()`).
pub fn uuid(io: Io, out: *[36]u8) []const u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    _ = std.fmt.bufPrint(out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return out;
}

pub fn pathExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Deletes `path` and everything under it, ignoring errors and cancellation
/// (`let _ = remove_dir_all(..)`).
pub fn removeTree(io: Io, path: []const u8) void {
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    Io.Dir.cwd().deleteTree(io, path) catch {};
}

// ── HTTP (reqwest's GET) ───────────────────────────────────────────────────

/// Connect attempts per request when the connect times out. reqwest makes
/// one; tests raise it because loopback SYNs are occasionally dropped on a
/// loaded machine (a first connect then fails with ETIMEDOUT).
pub var connect_attempts: u8 = if (builtin.is_test) 3 else 1;

pub const Http = struct {
    gpa: Allocator,
    client: std.http.Client,
    arena: std.heap.ArenaAllocator,
    /// Null sends none, as a reqwest client without `.user_agent(..)`.
    user_agent: ?[]const u8,

    /// One client per install, like Rust's `reqwest::Client::builder()`;
    /// HTTP(S)_PROXY from `env` apply, as reqwest's system proxies do.
    pub fn init(self: *Http, gpa: Allocator, io: Io, env: *const Environ.Map, user_agent: ?[]const u8) void {
        self.* = .{
            .gpa = gpa,
            .client = .{ .allocator = gpa, .io = io },
            .arena = .init(gpa),
            .user_agent = user_agent,
        };
        self.client.initDefaultProxies(self.arena.allocator(), env) catch {};
    }

    pub fn deinit(self: *Http) void {
        self.client.deinit();
        self.arena.deinit();
    }

    /// A response whose head arrived with a success status.
    pub const Body = struct {
        gpa: Allocator,
        url: []u8,
        req: std.http.Client.Request,
        resp: std.http.Client.Response,
        reader: *Io.Reader,
        content_length: ?u64,
        redirect_buf: [8 * 1024]u8 = undefined,
        transfer_buf: [64]u8 = undefined,
        accept: [1]std.http.Header = undefined,

        pub fn destroy(b: *Body) void {
            b.req.deinit();
            b.gpa.free(b.url);
            b.gpa.destroy(b);
        }

        /// Up to `buf.len` bytes; 0 at the end of the body.
        pub fn read(b: *Body, buf: []u8) Error!Result(usize) {
            const n = b.reader.readSliceShort(buf) catch {
                const cause: anyerror = if (b.resp.bodyErr()) |e| e else connError(&b.req);
                if (cause == error.Canceled) return error.Canceled;
                return .{ .err = try fail(b.gpa, .bare, "error decoding response body: {s}", .{@errorName(cause)}) };
            };
            return .{ .ok = n };
        }

        /// The whole body (reqwest's `.text()` / `.bytes()`), at most `max` bytes.
        pub fn readAll(b: *Body, gpa: Allocator, max: usize) Error!Result([]u8) {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var chunk: [16 * 1024]u8 = undefined;
            while (true) {
                const n = switch (try b.read(&chunk)) {
                    .ok => |n| n,
                    .err => |f| {
                        out.deinit(gpa);
                        return .{ .err = f };
                    },
                };
                if (n == 0) break;
                if (out.items.len + n > max) {
                    out.deinit(gpa);
                    return .{ .err = try fail(gpa, .bare, "error decoding response body: response is larger than {d} bytes", .{max}) };
                }
                try out.appendSlice(gpa, chunk[0..n]);
            }
            return .{ .ok = try out.toOwnedSlice(gpa) };
        }
    };

    fn connError(req: *std.http.Client.Request) anyerror {
        const c = req.connection orelse return error.ConnectionClosed;
        return c.getReadError() orelse error.ConnectionClosed;
    }

    /// `client.get(url).header(ACCEPT, accept).send().await?.error_for_status()?`.
    /// Errors carry reqwest's texts.
    pub fn get(self: *Http, url: []const u8, accept: ?[]const u8) Error!Result(*Body) {
        const gpa = self.gpa;
        const b = try gpa.create(Body);
        b.* = .{ .gpa = gpa, .url = undefined, .req = undefined, .resp = undefined, .reader = undefined, .content_length = null };
        b.url = gpa.dupe(u8, url) catch |e| {
            gpa.destroy(b);
            return e;
        };
        const uri = std.Uri.parse(b.url) catch |e| {
            defer {
                gpa.free(b.url);
                gpa.destroy(b);
            }
            return .{ .err = try fail(gpa, .bare, "builder error: {s}", .{@errorName(e)}) };
        };
        var extra: []const std.http.Header = &.{};
        if (accept) |a| {
            b.accept[0] = .{ .name = "accept", .value = a };
            extra = b.accept[0..1];
        }
        var attempt: u8 = 1;
        b.req = while (true) : (attempt += 1) {
            break self.client.request(.GET, uri, .{
                .headers = .{
                    .user_agent = if (self.user_agent) |ua| .{ .override = ua } else .omit,
                    .accept_encoding = .omit,
                },
                .extra_headers = extra,
                .keep_alive = false,
            }) catch |e| {
                if (e == error.Timeout and attempt < connect_attempts) continue;
                defer {
                    gpa.free(b.url);
                    gpa.destroy(b);
                }
                if (e == error.Canceled) return error.Canceled;
                return .{ .err = try sendError(gpa, url, e) };
            };
        };
        errdefer b.req.deinit();
        b.req.sendBodiless() catch {
            const cause = connError(&b.req);
            defer b.destroy();
            if (cause == error.Canceled) return error.Canceled;
            return .{ .err = try sendError(gpa, url, cause) };
        };
        b.resp = b.req.receiveHead(&b.redirect_buf) catch |e| {
            const cause: anyerror = if (e == error.ReadFailed) connError(&b.req) else e;
            defer b.destroy();
            if (cause == error.Canceled) return error.Canceled;
            return .{ .err = try sendError(gpa, url, cause) };
        };
        const status = b.resp.head.status;
        const code = @backingInt(status);
        if (code >= 400 and code < 600) {
            defer b.destroy();
            return .{ .err = try fail(gpa, .bare, "HTTP status {s} error ({d} {s}) for url ({s})", .{
                if (code < 500) "client" else "server",
                code,
                status.phrase() orelse "<unknown status code>",
                url,
            }) };
        }
        if (b.resp.head.content_encoding != .identity) {
            defer b.destroy();
            return .{ .err = try fail(gpa, .bare, "error decoding response body: unsupported content encoding", .{}) };
        }
        b.content_length = b.resp.head.content_length;
        b.reader = b.resp.reader(&b.transfer_buf);
        return .{ .ok = b };
    }

    fn sendError(gpa: Allocator, url: []const u8, cause: anyerror) Allocator.Error!Failure {
        return fail(gpa, .bare, "error sending request for url ({s}): {s}", .{ url, @errorName(cause) });
    }

    /// GET and read the whole body (at most `max` bytes).
    pub fn getAll(self: *Http, url: []const u8, accept: ?[]const u8, max: usize) Error!Result([]u8) {
        const b = switch (try self.get(url, accept)) {
            .ok => |b| b,
            .err => |f| return .{ .err = f },
        };
        defer b.destroy();
        return b.readAll(self.gpa, max);
    }
};

// ── a loopback HTTP server for tests ───────────────────────────────────────

/// Serves fixed routes on 127.0.0.1 (one request per connection). A route
/// may send part of its body and then stall until the server stops, or for
/// `stall_ms` at most, to model a dead link.
pub const TestServer = struct {
    pub const Route = struct {
        /// Request target, query included.
        path: []const u8,
        status: u16 = 200,
        body: []const u8 = "",
        /// Send this many body bytes, then stall.
        stall_after: ?usize = null,
        stall_ms: u64 = 5000,
    };

    io: Io,
    server: Io.net.Server,
    routes: []const Route,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    mu: Io.Mutex = .init,
    hits: std.ArrayList([]u8) = .empty,
    workers: std.ArrayList(std.Thread) = .empty,
    thread: ?std.Thread = null,

    pub fn start(self: *TestServer, io: Io, routes: []const Route) !void {
        const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{ .io = io, .server = try addr.listen(io, .{ .reuse_address = true }), .routes = routes, .port = 0 };
        self.port = self.server.socket.address.ip4.port;
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        // On a loaded machine the first connect to a fresh loopback listener
        // can time out; take that hit here, retried, before the test's own.
        const self_addr = try Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
        for (0..3) |_| {
            if (self_addr.connect(io, .{ .mode = .stream })) |c| {
                c.close(io);
                break;
            } else |_| {}
        }
    }

    /// `http://127.0.0.1:{port}{suffix}` (owned).
    pub fn url(self: *const TestServer, gpa: Allocator, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ self.port, suffix });
    }

    pub fn shutdown(self: *TestServer) void {
        // The accept loop polls the stop flag, so stopping needs no wake-up
        // connection (loopback connects can stall on a loaded machine).
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.mu.lockUncancelable(self.io);
        const workers = self.workers.items;
        self.mu.unlock(self.io);
        for (workers) |t| t.join();
        self.workers.deinit(std.heap.page_allocator);
        self.server.deinit(self.io);
        for (self.hits.items) |h| std.heap.page_allocator.free(h);
        self.hits.deinit(std.heap.page_allocator);
    }

    /// How many requests asked for `path`.
    pub fn hitCount(self: *TestServer, path: []const u8) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var n: usize = 0;
        for (self.hits.items) |h| if (std.mem.eql(u8, h, path)) {
            n += 1;
        };
        return n;
    }

    fn acceptLoop(self: *TestServer) void {
        while (!self.stop.load(.acquire)) {
            if (comptime !is_windows) {
                var fds = [_]std.posix.pollfd{.{ .fd = self.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                const ready = std.posix.poll(&fds, 20) catch return;
                if (ready == 0) continue;
            }
            const conn = self.server.accept(self.io) catch return;
            if (self.stop.load(.acquire)) {
                conn.close(self.io);
                return;
            }
            const t = std.Thread.spawn(.{}, serve, .{ self, conn }) catch {
                conn.close(self.io);
                continue;
            };
            self.mu.lockUncancelable(self.io);
            self.workers.append(std.heap.page_allocator, t) catch t.detach();
            self.mu.unlock(self.io);
        }
    }

    fn serve(self: *TestServer, conn: Io.net.Stream) void {
        defer conn.close(self.io);
        var rbuf: [8192]u8 = undefined;
        var r = conn.reader(self.io, &rbuf);
        const line = (r.interface.takeDelimiter('\n') catch null) orelse return;
        var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        _ = it.next();
        const target_tmp = it.next() orelse "";
        var target_buf: [1024]u8 = undefined;
        const target = target_buf[0..@min(target_tmp.len, target_buf.len)];
        @memcpy(target, target_tmp[0..target.len]);
        while (r.interface.takeDelimiter('\n') catch null) |h| {
            if (std.mem.trimEnd(u8, h, "\r").len == 0) break;
        }
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (std.heap.page_allocator.dupe(u8, target)) |copy| {
                self.hits.append(std.heap.page_allocator, copy) catch std.heap.page_allocator.free(copy);
            } else |_| {}
        }
        var route: Route = .{ .path = target, .status = 404, .body = "not found" };
        for (self.routes) |rt| if (std.mem.eql(u8, rt.path, target)) {
            route = rt;
            break;
        };
        var wbuf: [4096]u8 = undefined;
        var w = conn.writer(self.io, &wbuf);
        const reason = (std.http.Status.phrase(@fromBackingInt(@intCast(route.status)))) orelse "Unknown";
        w.interface.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n", .{ route.status, reason, route.body.len }) catch return;
        const send = if (route.stall_after) |n| route.body[0..@min(n, route.body.len)] else route.body;
        w.interface.writeAll(send) catch return;
        w.interface.flush() catch return;
        if (route.stall_after != null) {
            var waited: u64 = 0;
            while (waited < route.stall_ms and !self.stop.load(.acquire)) : (waited += 10) {
                self.io.sleep(.fromMilliseconds(10), .awake) catch return;
            }
            return;
        }
        // Let the client close first: TIME_WAIT then stays on its side, and a
        // reused ephemeral port never meets a server-side TIME_WAIT (whose
        // dropped SYNs stall a later connect for seconds, or time it out).
        if (comptime is_windows) return;
        var waited: u64 = 0;
        while (waited < 2000 and !self.stop.load(.acquire)) : (waited += 20) {
            var fds = [_]std.posix.pollfd{.{ .fd = conn.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 20) catch return;
            if (ready == 0) continue;
            var sink: [512]u8 = undefined;
            const got = std.posix.read(conn.socket.handle, &sink) catch return;
            if (got == 0) return;
        }
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "harness_install_net failures display like HarnessError" {
    const gpa = testing.allocator;
    const f = try fail(gpa, .install, "installation {s}", .{"cancelled"});
    defer f.deinit(gpa);
    const t = try f.display(gpa);
    defer gpa.free(t);
    try testing.expectEqualStrings("adapter install failed: installation cancelled", t);
    const n = try fail(gpa, .not_installed, "x", .{});
    defer n.deinit(gpa);
    const nt = try n.display(gpa);
    defer gpa.free(nt);
    try testing.expectEqualStrings("harness binary not found: x", nt);
}

fn slowWork(io: Io, ms: u64) Error!u32 {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return error.Canceled;
    return 7;
}

fn freeNothing(_: Error!u32) void {}

test "harness_install_net guard finishes, cancels, times out and stalls" {
    const io = testing.io;
    var cancel: Cancel = .{};
    // Finishes.
    const a = try guard(io, .{ .cancel = &cancel, .deadline_ms = 5000 }, slowWork, .{ io, 1 }, freeNothing);
    try testing.expectEqual(@as(u32, 7), try a.done);
    // Times out (and the task is cancelled, not waited out).
    const started = nowNs(io);
    const b = try guard(io, .{ .cancel = &cancel, .deadline_ms = 50 }, slowWork, .{ io, 10_000 }, freeNothing);
    try testing.expectEqual(Stop.timed_out, b.stopped);
    try testing.expect(nowNs(io) - started < 5 * std.time.ns_per_s);
    // A stall: progress never advances.
    var progress: std.atomic.Value(i64) = .init(nowNs(io));
    const c = try guard(io, .{ .progress = &progress, .stall_ms = 50, .deadline_ms = 5000 }, slowWork, .{ io, 10_000 }, freeNothing);
    try testing.expectEqual(Stop.stalled, c.stopped);
    // Pre-cancelled: never starts.
    cancel.cancel();
    const d = try guard(io, .{ .cancel = &cancel, .deadline_ms = 5000 }, slowWork, .{ io, 10_000 }, freeNothing);
    try testing.expectEqual(Stop.cancelled, d.stopped);
}

test "harness_install_net GET reports reqwest's status and body texts against a loopback server" {
    const gpa = testing.allocator;
    const io = testing.io;
    var srv: TestServer = undefined;
    try srv.start(io, &.{
        .{ .path = "/ok", .body = "hello" },
        .{ .path = "/missing", .status = 404, .body = "nope" },
    });
    defer srv.shutdown();
    var env = Environ.Map.init(gpa);
    defer env.deinit();
    var h: Http = undefined;
    h.init(gpa, io, &env, "harness-test");
    defer h.deinit();
    const ok_url = try srv.url(gpa, "/ok");
    defer gpa.free(ok_url);
    const body = try h.getAll(ok_url, "application/json", 1024);
    defer gpa.free(body.ok);
    try testing.expectEqualStrings("hello", body.ok);
    const missing = try srv.url(gpa, "/missing");
    defer gpa.free(missing);
    const r = try h.getAll(missing, null, 1024);
    defer r.err.deinit(gpa);
    const want = try std.fmt.allocPrint(gpa, "HTTP status client error (404 Not Found) for url ({s})", .{missing});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, r.err.msg);
}
