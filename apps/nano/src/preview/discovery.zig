//! This user's listening sockets and the processes that own them
//! (`crates/preview/src/discovery.rs`). On macOS: `lsof` and `ps`, with
//! ancestry from `proc_pidinfo`; on Linux: `/proc`. Elsewhere: none.
//!
//! Every outside source goes through `Sys` so tests feed recorded, made-up
//! `lsof`/`ps` output and a made-up `/proc` tree instead of the machine's.
const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("catalog.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;
const Listener = catalog.Listener;
const Address = catalog.Address;

pub const Sys = struct {
    ctx: ?*anyopaque = null,
    /// Stdout of `argv` (owned), or null when it couldn't run.
    run: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: Io, argv: []const []const u8) ?[]u8 = runProcess,
    parent_of: *const fn (ctx: ?*anyopaque, pid: u32) ?u32 = parentOfNative,
    canonicalize: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: Io, path: []const u8) ?[]u8 = canonicalizeNative,
    self_pid: u32,
    uid: u32,
    proc_root: []const u8 = "/proc",
    os: std.Target.Os.Tag = builtin.os.tag,

    pub fn native() Sys {
        if (comptime builtin.os.tag == .windows) return .{ .self_pid = 0, .uid = 0 };
        return .{ .self_pid = @intCast(std.c.getpid()), .uid = @intCast(std.c.geteuid()) };
    }
};

fn runProcess(_: ?*anyopaque, gpa: Allocator, io: Io, argv: []const []const u8) ?[]u8 {
    if (comptime !std.process.can_spawn) return null;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    env.put("LC_ALL", "C") catch return null;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = &env,
    }) catch return null;
    var buf: [16384]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        out.appendSlice(gpa, chunk[0..n]) catch break;
        if (out.items.len > 8 * 1024 * 1024) break;
    }
    _ = child.wait(io) catch {};
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

fn canonicalizeNative(_: ?*anyopaque, gpa: Allocator, io: Io, path: []const u8) ?[]u8 {
    const z = Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch return null;
    defer gpa.free(z);
    return gpa.dupe(u8, z) catch null;
}

const darwin = struct {
    /// `struct proc_bsdinfo` (136 bytes); `pbi_ppid` is the fifth `uint32_t`.
    const bsdinfo_size = 136;
    const PROC_PIDTBSDINFO = 3;
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
};

fn parentOfNative(_: ?*anyopaque, pid: u32) ?u32 {
    if (comptime builtin.os.tag != .macos) return null;
    var info: [darwin.bsdinfo_size]u8 align(8) = undefined;
    const read = darwin.proc_pidinfo(@intCast(pid), darwin.PROC_PIDTBSDINFO, 0, &info, darwin.bsdinfo_size);
    if (read != darwin.bsdinfo_size) return null;
    return std.mem.readInt(u32, info[16..20], .little);
}

// ---------------------------------------------------------------- shared

fn markDescendants(found: []Listener, parents: *const std.AutoHashMapUnmanaged(u32, u32), owner: u32) void {
    for (found) |*l| {
        var pid = l.pid;
        for (0..128) |_| {
            if (pid == owner) {
                l.harness_owned = true;
                break;
            }
            const parent = parents.get(pid) orelse break;
            if (parent == pid or parent == 0) break;
            pid = parent;
        }
    }
}

/// Listeners of this user's processes; everything is allocated in `a` (an arena).
pub fn listeners(a: Allocator, io: Io, sys: Sys) []Listener {
    return switch (sys.os) {
        .macos => listenersMac(a, io, sys) catch &.{},
        .linux => listenersLinux(a, io, sys) catch &.{},
        else => &.{},
    };
}

/// Whether `pid` is still the process observed with `started_at`.
pub fn sameProcess(a: Allocator, io: Io, sys: Sys, pid: u32, started_at: u64) bool {
    switch (sys.os) {
        .macos => {
            var pbuf: [16]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "{d}", .{pid}) catch return false;
            const out = sys.run(sys.ctx, a, io, &.{ "/bin/ps", "-o", "lstart=", "-p", p }) orelse return false;
            defer a.free(out);
            var parts: [5][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
            while (it.next()) |t| {
                if (n == 5) break;
                parts[n] = t;
                n += 1;
            }
            return n == 5 and parseLstart(parts) == started_at;
        },
        .linux => {
            const path = std.fmt.allocPrint(a, "{s}/{d}/stat", .{ sys.proc_root, pid }) catch return false;
            defer a.free(path);
            const stat = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch return false;
            defer a.free(stat);
            const clock = linuxClock(a, io, sys);
            const parsed = parseLinuxStat(stat) orelse return false;
            return linuxStartedAt(parsed.start_ticks, clock) == started_at;
        },
        else => return false,
    }
}

// ---------------------------------------------------------------- macOS

const tm_c = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = -1,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};
extern "c" fn mktime(tm: *tm_c) i64;

/// `ps lstart=` tokens ("Thu Sep 11 16:14:42 2026", local time) to ms since the epoch.
pub fn parseLstart(parts: [5][]const u8) u64 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const days = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    var day_ok = false;
    for (days) |d| {
        if (std.mem.eql(u8, d, parts[0])) day_ok = true;
    }
    if (!day_ok) return 0;
    var mon: ?c_int = null;
    for (months, 0..) |m, i| {
        if (std.mem.eql(u8, m, parts[1])) mon = @intCast(i);
    }
    const mday = std.fmt.parseInt(c_int, parts[2], 10) catch return 0;
    var hms = std.mem.splitScalar(u8, parts[3], ':');
    const h = std.fmt.parseInt(c_int, hms.next() orelse return 0, 10) catch return 0;
    const mi = std.fmt.parseInt(c_int, hms.next() orelse return 0, 10) catch return 0;
    const s = std.fmt.parseInt(c_int, hms.next() orelse return 0, 10) catch return 0;
    const year = std.fmt.parseInt(c_int, parts[4], 10) catch return 0;
    if (mon == null or mday < 1 or mday > 31 or h > 23 or mi > 59 or s > 60) return 0;
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return 0;
    var tm: tm_c = .{ .tm_sec = s, .tm_min = mi, .tm_hour = h, .tm_mday = mday, .tm_mon = mon.?, .tm_year = year - 1900 };
    const t = mktime(&tm);
    if (t < 0) return 0;
    return @as(u64, @intCast(t)) * 1000;
}

/// `lsof -F0pn` fields: `(pid, name)` per `n` field, after its `p` field.
pub const LsofField = struct { pid: u32, name: []const u8 };

pub fn parseLsofFields(a: Allocator, out: []const u8) ![]LsofField {
    var values: std.ArrayList(LsofField) = .empty;
    var pid: u32 = 0;
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |raw| {
        const field = std.mem.trimStart(u8, raw, "\n");
        if (field.len == 0) continue;
        switch (field[0]) {
            'p' => pid = std.fmt.parseInt(u32, field[1..], 10) catch 0,
            'n' => try values.append(a, .{ .pid = pid, .name = try a.dupe(u8, field[1..]) }),
            else => {},
        }
    }
    return values.toOwnedSlice(a);
}

/// `127.0.0.1:5173`, `[::1]:5173` (loopback only), or `*:5173` (both families).
pub fn lsofAddresses(name: []const u8, out: *[2]Address) []Address {
    if (std.mem.startsWith(u8, name, "*:")) {
        const port = std.fmt.parseInt(u16, name[2..], 10) catch return out[0..0];
        out[0] = .loopback4(port);
        out[1] = .loopback6(port);
        return out[0..2];
    }
    const ip = net.IpAddress.parseLiteral(name) catch return out[0..0];
    switch (ip) {
        .ip4 => |v4| {
            if (v4.bytes[0] != 127) return out[0..0];
            var a: Address = .{ .port = v4.port };
            @memcpy(a.ip[0..4], &v4.bytes);
            out[0] = a;
        },
        .ip6 => |v6| {
            if (!std.mem.eql(u8, &v6.bytes, &Address.loopback6(0).ip)) return out[0..0];
            out[0] = .{ .v6 = true, .ip = v6.bytes, .port = v6.port };
        },
    }
    return out[0..1];
}

fn listenersMac(a: Allocator, io: Io, sys: Sys) ![]Listener {
    var ubuf: [16]u8 = undefined;
    const uid = try std.fmt.bufPrint(&ubuf, "{d}", .{sys.uid});
    const sockets_out = sys.run(sys.ctx, a, io, &.{ "/usr/sbin/lsof", "-nP", "-a", "-u", uid, "-iTCP", "-sTCP:LISTEN", "-F0pn" }) orelse return &.{};
    const sockets = try parseLsofFields(a, sockets_out);
    if (sockets.len == 0) return &.{};
    var pids: std.ArrayList(u32) = .empty;
    for (sockets) |s| try pids.append(a, s.pid);
    std.mem.sort(u32, pids.items, {}, std.sort.asc(u32));
    var uniq: std.ArrayList(u32) = .empty;
    for (pids.items) |p| if (uniq.items.len == 0 or uniq.items[uniq.items.len - 1] != p) try uniq.append(a, p);
    var list: std.ArrayList(u8) = .empty;
    for (uniq.items, 0..) |p, i| try list.print(a, "{s}{d}", .{ if (i == 0) "" else ",", p });

    var cwds: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    if (sys.run(sys.ctx, a, io, &.{ "/usr/sbin/lsof", "-nP", "-a", "-p", list.items, "-d", "cwd", "-F0pn" })) |out| {
        for (try parseLsofFields(a, out)) |f| try cwds.put(a, f.pid, f.name);
    }
    const Proc = struct { parent: u32, started_at: u64, args: []const []const u8 };
    var procs: std.AutoHashMapUnmanaged(u32, Proc) = .empty;
    if (sys.run(sys.ctx, a, io, &.{ "/bin/ps", "-o", "pid=,ppid=,lstart=,command=", "-p", list.items })) |out| {
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            var parts: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, line, " \t\r");
            while (it.next()) |t| try parts.append(a, t);
            if (parts.items.len < 8) continue;
            const pid = std.fmt.parseInt(u32, parts.items[0], 10) catch continue;
            const parent = std.fmt.parseInt(u32, parts.items[1], 10) catch continue;
            try procs.put(a, pid, .{
                .parent = parent,
                .started_at = parseLstart(parts.items[2..7].*),
                .args = parts.items[7..],
            });
        }
    }
    var result: std.ArrayList(Listener) = .empty;
    for (sockets) |s| {
        const raw_cwd = cwds.get(s.pid) orelse continue;
        const cwd = sys.canonicalize(sys.ctx, a, io, raw_cwd) orelse continue;
        const proc = procs.get(s.pid) orelse continue;
        var abuf: [2]Address = undefined;
        for (lsofAddresses(s.name, &abuf)) |addr| {
            try result.append(a, .{ .pid = s.pid, .parent = proc.parent, .cwd = cwd, .args = proc.args, .started_at = proc.started_at, .address = addr });
        }
    }
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (uniq.items) |start| {
        var pid = start;
        for (0..128) |_| {
            if (pid <= 1 or parents.contains(pid)) break;
            const parent = sys.parent_of(sys.ctx, pid) orelse break;
            try parents.put(a, pid, parent);
            pid = parent;
        }
    }
    markDescendants(result.items, &parents, sys.self_pid);
    return result.items;
}

// ---------------------------------------------------------------- Linux

const LinuxClock = struct { boot: u64, ticks: u64 };

fn linuxClock(a: Allocator, io: Io, sys: Sys) LinuxClock {
    // USER_HZ, what `sysconf(_SC_CLK_TCK)` reports on Linux.
    const ticks: u64 = 100;
    const path = std.fmt.allocPrint(a, "{s}/stat", .{sys.proc_root}) catch return .{ .boot = 0, .ticks = ticks };
    defer a.free(path);
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch return .{ .boot = 0, .ticks = ticks };
    defer a.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "btime ")) {
            return .{ .boot = std.fmt.parseInt(u64, std.mem.trim(u8, line[6..], " \r"), 10) catch 0, .ticks = ticks };
        }
    }
    return .{ .boot = 0, .ticks = ticks };
}

const LinuxStat = struct { parent: u32, start_ticks: u64 };

pub fn parseLinuxStat(stat: []const u8) ?LinuxStat {
    const close = std.mem.lastIndexOf(u8, stat, ") ") orelse return null;
    var it = std.mem.tokenizeAny(u8, stat[close + 2 ..], " \n");
    var i: usize = 0;
    var parent: ?u32 = null;
    var start: u64 = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == 1) parent = std.fmt.parseInt(u32, f, 10) catch return null;
        if (i == 19) start = std.fmt.parseInt(u64, f, 10) catch 0;
    }
    return .{ .parent = parent orelse return null, .start_ticks = start };
}

fn linuxStartedAt(start_ticks: u64, clock: LinuxClock) u64 {
    return clock.boot * 1000 + start_ticks * 1000 / @max(clock.ticks, 1);
}

/// `/proc/net/tcp{,6}` local address; loopback or unspecified only, the
/// unspecified one reached through its family's loopback.
pub fn procAddress(value: []const u8, ipv6: bool) ?Address {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const host = value[0..colon];
    const port = std.fmt.parseInt(u16, value[colon + 1 ..], 16) catch return null;
    var a: Address = .{ .v6 = ipv6, .port = port };
    if (ipv6) {
        if (host.len != 32) return null;
        for (0..4) |i| {
            const word = std.fmt.parseInt(u32, host[i * 8 .. i * 8 + 8], 16) catch return null;
            std.mem.writeInt(u32, a.ip[i * 4 ..][0..4], word, .little);
        }
        const unspecified = std.mem.allEqual(u8, &a.ip, 0);
        const loop = std.mem.allEqual(u8, a.ip[0..15], 0) and a.ip[15] == 1;
        if (!unspecified and !loop) return null;
        if (unspecified) return .loopback6(port);
    } else {
        const word = std.fmt.parseInt(u32, host, 16) catch return null;
        std.mem.writeInt(u32, a.ip[0..4], word, .little);
        const unspecified = std.mem.allEqual(u8, a.ip[0..4], 0);
        if (!unspecified and a.ip[0] != 127) return null;
        if (unspecified) return .loopback4(port);
    }
    return a;
}

fn effectiveUid(status: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var it = std.mem.tokenizeAny(u8, line[4..], " \t");
        _ = it.next() orelse return null;
        return std.fmt.parseInt(u32, it.next() orelse return null, 10) catch null;
    }
    return null;
}

fn readLinkAlloc(a: Allocator, io: Io, path: []const u8) ?[]u8 {
    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().readLink(io, path, &buf) catch return null;
    return a.dupe(u8, buf[0..n]) catch null;
}

fn listenersLinux(a: Allocator, io: Io, sys: Sys) ![]Listener {
    var sockets: std.StringHashMapUnmanaged(Address) = .empty;
    for ([_]struct { []const u8, bool }{ .{ "net/tcp", false }, .{ "net/tcp6", true } }) |f| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ sys.proc_root, f[0] });
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var parts: [12][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, line, " \t");
            while (it.next()) |t| {
                if (n == parts.len) break;
                parts[n] = t;
                n += 1;
            }
            if (n <= 9 or !std.mem.eql(u8, parts[3], "0A")) continue;
            if (procAddress(parts[1], f[1])) |addr| try sockets.put(a, parts[9], addr);
        }
    }
    const clock = linuxClock(a, io, sys);
    var result: std.ArrayList(Listener) = .empty;
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var dir = Io.Dir.cwd().openDir(io, sys.proc_root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var dit = dir.iterate();
    while (dit.next(io) catch null) |entry| {
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const base = try std.fmt.allocPrint(a, "{s}/{d}", .{ sys.proc_root, pid });
        const status = Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/status", .{base}), a, .limited(64 * 1024)) catch continue;
        const uid = effectiveUid(status) orelse continue;
        if (uid != sys.uid) continue;
        const stat_text = Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/stat", .{base}), a, .limited(64 * 1024)) catch continue;
        const stat = parseLinuxStat(stat_text) orelse continue;
        try parents.put(a, pid, stat.parent);
        const cwd = readLinkAlloc(a, io, try std.fmt.allocPrint(a, "{s}/cwd", .{base})) orelse continue;
        const cmdline = Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/cmdline", .{base}), a, .limited(256 * 1024)) catch "";
        var args: std.ArrayList([]const u8) = .empty;
        var ait = std.mem.tokenizeScalar(u8, cmdline, 0);
        while (ait.next()) |arg| try args.append(a, arg);
        const fd_path = try std.fmt.allocPrint(a, "{s}/fd", .{base});
        var fds = Io.Dir.cwd().openDir(io, fd_path, .{ .iterate = true }) catch continue;
        defer fds.close(io);
        var fit = fds.iterate();
        while (fit.next(io) catch null) |fd| {
            const link = readLinkAlloc(a, io, try std.fmt.allocPrint(a, "{s}/{s}", .{ fd_path, fd.name })) orelse continue;
            if (!std.mem.startsWith(u8, link, "socket:[") or !std.mem.endsWith(u8, link, "]")) continue;
            const addr = sockets.get(link[8 .. link.len - 1]) orelse continue;
            try result.append(a, .{
                .pid = pid,
                .parent = stat.parent,
                .cwd = cwd,
                .args = args.items,
                .started_at = linuxStartedAt(stat.start_ticks, clock),
                .address = addr,
            });
        }
    }
    markDescendants(result.items, &parents, sys.self_pid);
    const Less = struct {
        fn f(_: void, x: Listener, y: Listener) bool {
            const o = x.address.order(y.address);
            if (o != .eq) return o == .lt;
            return x.pid < y.pid;
        }
    };
    std.mem.sort(Listener, result.items, {}, Less.f);
    var out: std.ArrayList(Listener) = .empty;
    for (result.items) |l| {
        if (out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            if (last.pid == l.pid and last.address.eql(l.address)) continue;
        }
        try out.append(a, l);
    }
    return out.items;
}

// ---------------------------------------------------------------- probes

/// Whether `handle` has something to read within `ms`.
pub fn readable(handle: net.Socket.Handle, ms: i32) bool {
    if (comptime builtin.os.tag == .windows) {
        const WsaPollFd = extern struct { fd: net.Socket.Handle, events: i16, revents: i16 };
        const ws = struct {
            extern "ws2_32" fn WSAPoll(fdarray: [*]WsaPollFd, fds: u32, timeout: c_int) callconv(.winapi) c_int;
        };
        var fds = [_]WsaPollFd{.{ .fd = handle, .events = 0x0100, .revents = 0 }};
        return ws.WSAPoll(&fds, 1, ms) > 0;
    }
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, ms) catch return false;
    return n > 0;
}

pub fn nowMs(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// A bounded `HEAD /` (800 ms) that accepts any valid HTTP status line,
/// authentication and application errors included.
pub fn isHttp(io: Io, address: Address) bool {
    const ip = address.toIp();
    const s = ip.connect(io, .{ .mode = .stream }) catch return false;
    defer s.close(io);
    const deadline = nowMs(io) + 800;
    var req_buf: [128]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "HEAD / HTTP/1.1\r\nHost: localhost:{d}\r\nConnection: close\r\n\r\n", .{address.port}) catch return false;
    var wb: [128]u8 = undefined;
    var w = s.writer(io, &wb);
    w.interface.writeAll(req) catch return false;
    w.interface.flush() catch return false;
    var prefix: [12]u8 = undefined;
    var n: usize = 0;
    while (n < prefix.len) {
        const left = deadline - nowMs(io);
        if (left <= 0 or !readable(s.socket.handle, @intCast(left))) return false;
        var bufs = [_][]u8{prefix[n..]};
        const got = (s.readWithControl(io, &bufs, &.{}) catch return false).data_len;
        if (got == 0) return false;
        n += got;
    }
    const version = prefix[0..9];
    if (!std.mem.eql(u8, version, "HTTP/1.1 ") and !std.mem.eql(u8, version, "HTTP/1.0 ")) return false;
    const status = std.fmt.parseInt(u16, prefix[9..12], 10) catch return false;
    return status >= 100 and status < 600;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Recorded = struct {
    outputs: []const struct { prefix: []const u8, out: []const u8 },
    fn run(ctx: ?*anyopaque, gpa: Allocator, _: Io, argv: []const []const u8) ?[]u8 {
        const self: *const Recorded = @ptrCast(@alignCast(ctx.?));
        var joined: [512]u8 = undefined;
        var n: usize = 0;
        for (argv, 0..) |arg, i| {
            if (i > 0) {
                joined[n] = ' ';
                n += 1;
            }
            @memcpy(joined[n..][0..arg.len], arg);
            n += arg.len;
        }
        for (self.outputs) |o| {
            if (std.mem.startsWith(u8, joined[0..n], o.prefix)) return gpa.dupe(u8, o.out) catch null;
        }
        return null;
    }
    fn parent(_: ?*anyopaque, pid: u32) ?u32 {
        return switch (pid) {
            4242 => 4000,
            4000 => 900,
            4300 => 1,
            else => null,
        };
    }
    fn canon(_: ?*anyopaque, gpa: Allocator, _: Io, path: []const u8) ?[]u8 {
        if (std.mem.indexOf(u8, path, "gone") != null) return null;
        return gpa.dupe(u8, path) catch null;
    }
};

test "macOS discovery joins recorded lsof and ps output into loopback listeners" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec: Recorded = .{ .outputs = &.{
        .{ .prefix = "/usr/sbin/lsof -nP -a -u 501", .out = "p4242\x00f12\x00n*:5173\x00\np4300\x00f9\x00n127.0.0.1:3000\x00f10\x00n192.168.1.4:3001\x00\np4400\x00f3\x00n[::1]:8080\x00\n" },
        .{ .prefix = "/usr/sbin/lsof -nP -a -p 4242,4300,4400 -d cwd", .out = "p4242\x00fcwd\x00n/work/my-app\x00\np4300\x00fcwd\x00n/work/my-app/api\x00\np4400\x00fcwd\x00n/work/gone\x00\n" },
        .{ .prefix = "/bin/ps -o pid=,ppid=,lstart=,command= -p 4242,4300,4400", .out = " 4242  4000 Thu Sep 11 16:14:42 2026     node /work/my-app/node_modules/.bin/vite --port 5173\n 4300     1 Thu Sep 11 16:15:00 2026     node api.js\n 4400 1 Thu Sep 11 16:16:00 2026 python3 -m http.server\n" },
    } };
    const sys: Sys = .{ .ctx = @constCast(&rec), .run = Recorded.run, .parent_of = Recorded.parent, .canonicalize = Recorded.canon, .self_pid = 900, .uid = 501, .os = .macos };
    const found = listeners(arena.allocator(), testing.io, sys);
    // *:5173 becomes both loopbacks; the LAN-only socket and the vanished cwd drop out.
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqual(@as(u32, 4242), found[0].pid);
    try testing.expect(!found[0].address.v6 and found[1].address.v6);
    try testing.expectEqualStrings("/work/my-app", found[0].cwd);
    try testing.expectEqualStrings("vite", catalog.fileStem(found[0].args[1]).?);
    try testing.expect(found[0].harness_owned);
    try testing.expect(!found[2].harness_owned);
    try testing.expectEqual(@as(u16, 3000), found[2].address.port);
    try testing.expectEqual(found[0].started_at + 18_000, found[2].started_at);
}

test "lstart parses to whole seconds and rejects nonsense" {
    const a = parseLstart(.{ "Thu", "Sep", "11", "16:14:42", "2026" });
    const b = parseLstart(.{ "Thu", "Sep", "11", "16:14:43", "2026" });
    try testing.expect(a > 0);
    try testing.expectEqual(a + 1000, b);
    try testing.expectEqual(@as(u64, 0), parseLstart(.{ "Xyz", "Sep", "11", "16:14:42", "2026" }));
    try testing.expectEqual(@as(u64, 0), parseLstart(.{ "Thu", "Sept", "11", "16:14:42", "2026" }));
}

test "same process compares ps start time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec: Recorded = .{ .outputs = &.{.{ .prefix = "/bin/ps -o lstart= -p 77", .out = "Thu Sep 11 16:14:42 2026\n" }} };
    const sys: Sys = .{ .ctx = @constCast(&rec), .run = Recorded.run, .self_pid = 1, .uid = 501, .os = .macos };
    const t = parseLstart(.{ "Thu", "Sep", "11", "16:14:42", "2026" });
    try testing.expect(sameProcess(arena.allocator(), testing.io, sys, 77, t));
    try testing.expect(!sameProcess(arena.allocator(), testing.io, sys, 77, t + 1000));
    try testing.expect(!sameProcess(arena.allocator(), testing.io, sys, 78, t));
}

test "proc addresses accept only loopback-reachable listeners" {
    const v4 = procAddress("0100007F:1435", false).?;
    try testing.expect(v4.eql(Address.loopback4(5173)));
    const v6 = procAddress("00000000000000000000000001000000:1435", true).?;
    try testing.expect(v6.eql(Address.loopback6(5173)));
    try testing.expect(procAddress("00000000:1F90", false).?.eql(Address.loopback4(8080)));
    try testing.expect(procAddress("0101A8C0:1435", false) == null);
    try testing.expect(procAddress("malformed:00", true) == null);
}

test "Linux discovery reads a made-up /proc tree" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const d = tmp.dir;
    try d.createDirPath(io, "proc/net");
    try d.createDirPath(io, "proc/321/fd");
    try d.createDirPath(io, "proc/322/fd");
    try d.createDirPath(io, "work/app");
    try d.writeFile(io, .{ .sub_path = "proc/stat", .data = "cpu 1 2 3\nbtime 1790000000\n" });
    try d.writeFile(io, .{ .sub_path = "proc/net/tcp", .data = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 9001 1 0 100 0 0 10 0\n   1: 0401A8C0:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 9002 1 0 100 0 0 10 0\n" });
    try d.writeFile(io, .{ .sub_path = "proc/net/tcp6", .data = "  sl  local_address\n" });
    try d.writeFile(io, .{ .sub_path = "proc/321/status", .data = "Name:\tnode\nUid:\t501\t501\t501\t501\n" });
    try d.writeFile(io, .{ .sub_path = "proc/321/stat", .data = "321 (node (dev)) S 300 321 321 0 -1 4194304 1 0 0 0 0 0 0 0 20 0 1 0 5000 1 1\n" });
    try d.writeFile(io, .{ .sub_path = "proc/321/cmdline", .data = "node\x00vite.js\x00" });
    try d.writeFile(io, .{ .sub_path = "proc/322/status", .data = "Uid:\t0\t0\t0\t0\n" });
    try d.writeFile(io, .{ .sub_path = "proc/322/stat", .data = "322 (x) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 1\n" });
    const root = try d.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cwd_target = try std.fs.path.join(testing.allocator, &.{ root, "work/app" });
    defer testing.allocator.free(cwd_target);
    try d.symLink(io, cwd_target, "proc/321/cwd", .{});
    try d.symLink(io, "socket:[9001]", "proc/321/fd/7", .{});
    try d.symLink(io, "socket:[9002]", "proc/321/fd/8", .{});
    try d.symLink(io, "/dev/null", "proc/321/fd/0", .{});
    const proc_root = try std.fs.path.join(testing.allocator, &.{ root, "proc" });
    defer testing.allocator.free(proc_root);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sys: Sys = .{ .self_pid = 300, .uid = 501, .proc_root = proc_root, .os = .linux };
    const found = listeners(arena.allocator(), io, sys);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 321), found[0].pid);
    try testing.expectEqual(@as(u16, 5173), found[0].address.port);
    try testing.expectEqualStrings(cwd_target, found[0].cwd);
    try testing.expectEqualStrings("vite.js", found[0].args[1]);
    try testing.expect(found[0].harness_owned);
    try testing.expectEqual(@as(u64, 1790000000 * 1000 + 50_000), found[0].started_at);
    try testing.expect(sameProcess(arena.allocator(), io, sys, 321, found[0].started_at));
    try testing.expect(!sameProcess(arena.allocator(), io, sys, 321, found[0].started_at + 10));
}

test "an http probe needs an http status line" {
    const io = testing.io;
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    const Srv = struct {
        fn run(s: *net.Server) void {
            for ([_][]const u8{ "SSH-2.0-test\r\n", "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n" }) |reply| {
                const c = s.accept(testing.io) catch return;
                defer c.close(testing.io);
                if (readable(c.socket.handle, 2000)) {
                    var buf: [512]u8 = undefined;
                    var bufs = [_][]u8{&buf};
                    _ = c.readWithControl(testing.io, &bufs, &.{}) catch {};
                }
                var wb: [128]u8 = undefined;
                var w = c.writer(testing.io, &wb);
                w.interface.writeAll(reply) catch {};
                w.interface.flush() catch {};
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Srv.run, .{&server});
    defer t.join();
    try testing.expect(!isHttp(io, .loopback4(port)));
    try testing.expect(isHttp(io, .loopback4(port)));
}
