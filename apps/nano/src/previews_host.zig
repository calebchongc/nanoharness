//! `WatchPreviews`: the engine-owned preview service (`crates/preview/src/service.rs`)
//! and the RPC handler of `crates/engine/src/rpc.rs`.
//!
//! The first watch starts the service for its engine: the loopback proxy on
//! port 7331 (retried every two seconds while another application has it,
//! with the error in the snapshot) and a scanner that every two seconds joins
//! this device's chat folders to listening HTTP servers, then pushes each
//! watcher its chat's snapshot when it changed. A watcher sees the services
//! of the chat's own device whose project is the chat's current folder, so
//! changing the checkout changes the list. The engine has no peer transport,
//! so another device's chat gets `remote: true` and no services.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const engine_host = @import("engine_host.zig");
const streams = @import("engine_streams.zig");
const catalog_mod = @import("preview_catalog.zig");
const discovery = @import("preview_discovery.zig");
const proxy_mod = @import("preview_proxy.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;
const Catalog = catalog_mod.Catalog;

const token = "\x00stream:previews";

pub const Config = struct {
    port: u16 = catalog_mod.proxy_port_default,
    sys: discovery.Sys,
    verify: proxy_mod.Verify,
    scan_interval_ms: i64 = 2_000,
    bind_retry_ms: i64 = 2_000,

    pub fn native() Config {
        return .{ .sys = .native(), .verify = proxy_mod.nativeVerify() };
    }
};

const Subscriber = struct {
    sub: streams.Sub,
    chat_id: []u8,
    last: []u8,
};

pub const Service = struct {
    gpa: Allocator,
    io: Io,
    host: *EngineHost,
    config: Config,
    cat: *Catalog,
    memory: catalog_mod.ProbeMemory = .{},
    proxy: proxy_mod.Proxy,
    stop_flag: std.atomic.Value(bool) = .init(false),
    scanner: ?std.Thread = null,
    binder: ?std.Thread = null,
    /// Guarded by `host.mutex`.
    subs: std.ArrayList(Subscriber) = .empty,

    fn stopping(s: *Service) bool {
        return s.stop_flag.load(.acquire);
    }

    /// Sleep `ms` in short steps; false once the service or engine stops.
    fn pause(s: *Service, ms: i64) bool {
        var left = ms;
        while (left > 0) {
            if (s.stopping() or s.host.stop_requested) return false;
            const step = @min(left, 50);
            Io.sleep(s.io, .fromMilliseconds(step), .awake) catch return false;
            left -= step;
        }
        return !(s.stopping() or s.host.stop_requested);
    }

    fn bindLoop(s: *Service) void {
        while (!s.stopping()) {
            if (s.proxy.bind(s.config.port)) |port| {
                s.cat.setProxyStatus(port, null);
                s.proxy.start() catch {};
                return;
            } else |e| {
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Local previews could not listen on port 7331: {s}", .{bindErrorText(e)}) catch "Local previews could not listen on port 7331";
                s.cat.setProxyStatus(catalog_mod.proxy_port_default, msg);
            }
            if (!s.pause(s.config.bind_retry_ms)) return;
        }
    }

    fn scanLoop(s: *Service) void {
        while (true) {
            s.scanOnce() catch {};
            s.pushUpdates();
            if (!s.pause(s.config.scan_interval_ms)) return;
        }
    }

    fn scanOnce(s: *Service) !void {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // This device's chat folders.
        var raw_roots: std.ArrayList([]const u8) = .empty;
        streams.lock(s.host);
        for (s.host.chats.items) |c| {
            if (!std.mem.eql(u8, c.device_id, s.host.device_id)) continue;
            if (c.cwd) |cwd| raw_roots.append(a, a.dupe(u8, cwd) catch continue) catch {};
        }
        streams.unlock(s.host);
        var roots: std.ArrayList([]const u8) = .empty;
        for (raw_roots.items) |r| {
            const canon = s.config.sys.canonicalize(s.config.sys.ctx, a, s.io, r) orelse continue;
            var dup = false;
            for (roots.items) |x| {
                if (std.mem.eql(u8, x, canon)) dup = true;
            }
            if (!dup) try roots.append(a, canon);
        }
        // Deepest project first.
        const Deeper = struct {
            fn f(_: void, x: []const u8, y: []const u8) bool {
                return catalog_mod.pathComponents(x) > catalog_mod.pathComponents(y);
            }
        };
        std.mem.sort([]const u8, roots.items, {}, Deeper.f);

        var candidates: std.ArrayList(catalog_mod.Observation) = .empty;
        if (roots.items.len > 0) {
            const proxy_port = s.cat.proxyPort();
            for (discovery.listeners(a, s.io, s.config.sys)) |l| {
                if (l.address.port == catalog_mod.proxy_port_default or l.address.port == proxy_port) continue;
                if (l.pid == s.config.sys.self_pid) continue;
                for (roots.items) |root| {
                    if (l.belongsTo(root)) {
                        try candidates.append(a, .{ .root = root, .listener = l });
                        break;
                    }
                }
            }
        }
        const plans = try a.alloc(catalog_mod.ProbeMemory.Plan, candidates.items.len);
        s.memory.plan(candidates.items, discovery.nowMs(s.io), plans);
        var servers: std.ArrayList(catalog_mod.Observation) = .empty;
        var to_probe: std.ArrayList(usize) = .empty;
        for (plans, 0..) |p, i| switch (p) {
            .known => try servers.append(a, candidates.items[i]),
            .probe => try to_probe.append(a, i),
            .skip => {},
        };
        // Probe up to twelve at a time.
        const results = try a.alloc(bool, to_probe.items.len);
        var start: usize = 0;
        while (start < to_probe.items.len) : (start += 12) {
            const end = @min(start + 12, to_probe.items.len);
            var threads: [12]?std.Thread = @splat(null);
            for (start..end) |k| {
                const addr = candidates.items[to_probe.items[k]].listener.address;
                threads[k - start] = std.Thread.spawn(.{}, probeInto, .{ s.io, addr, &results[k] }) catch blk: {
                    results[k] = discovery.isHttp(s.io, addr);
                    break :blk null;
                };
            }
            for (threads[0 .. end - start]) |t| if (t) |th| th.join();
        }
        const now = discovery.nowMs(s.io);
        for (to_probe.items, 0..) |ci, k| {
            const l = candidates.items[ci].listener;
            try s.memory.record(s.gpa, l, results[k], now);
            if (results[k]) try servers.append(a, candidates.items[ci]);
        }
        try s.cat.replaceLocal(servers.items);
    }

    fn probeInto(io: Io, addr: catalog_mod.Address, out: *bool) void {
        out.* = discovery.isHttp(io, addr);
    }

    /// Each watcher gets its chat's snapshot when it differs from the last one sent.
    fn pushUpdates(s: *Service) void {
        streams.lock(s.host);
        defer streams.unlock(s.host);
        var i: usize = s.subs.items.len;
        while (i > 0) {
            i -= 1;
            const sub = &s.subs.items[i];
            if (!streams.aliveLocked(s.host, sub.sub)) {
                s.dropSub(i);
                continue;
            }
            const view = viewForChat(s, sub.chat_id) catch continue;
            if (std.mem.eql(u8, view, sub.last)) {
                s.gpa.free(view);
                continue;
            }
            s.gpa.free(sub.last);
            sub.last = view;
            if (!streams.sendLocked(s.host, sub.sub, view)) s.dropSub(i);
        }
    }

    fn dropSub(s: *Service, i: usize) void {
        const sub = s.subs.swapRemove(i);
        s.gpa.free(sub.chat_id);
        s.gpa.free(sub.last);
    }
};

fn bindErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.AddressInUse => "Address already in use",
        error.AccessDenied => "Permission denied",
        error.AddressUnavailable => "Can't assign requested address",
        else => @errorName(e),
    };
}

/// The snapshot for one chat (caller holds `host.mutex`).
fn viewForChat(s: *Service, chat_id: []const u8) ![]u8 {
    var chat: ?*const engine_host.ChatRecord = null;
    for (s.host.chats.items) |*c| {
        if (std.mem.eql(u8, c.id, chat_id)) chat = c;
    }
    const device: []const u8 = if (chat) |c| c.device_id else "";
    const remote = !std.mem.eql(u8, device, s.host.device_id);
    var canon: ?[]u8 = null;
    defer if (canon) |c| s.gpa.free(c);
    const cwd: ?[]const u8 = if (chat) |c| (if (c.cwd) |raw| blk: {
        if (remote) break :blk raw;
        canon = s.config.sys.canonicalize(s.config.sys.ctx, s.gpa, s.io, raw);
        break :blk canon orelse raw;
    } else null) else null;
    const name: ?[]const u8 = if (cwd) |c| std.fs.path.basename(std.mem.trimEnd(u8, c, "/")) else null;
    return s.cat.viewJson(s.gpa, device, cwd, if (name) |n| (if (n.len == 0) null else n) else null, remote);
}

// ---------------------------------------------------------------- registry

var registry: std.ArrayList(*Service) = .empty;
var registry_lock: std.atomic.Value(bool) = .init(false);

fn lockRegistry() void {
    while (registry_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockRegistry() void {
    registry_lock.store(false, .release);
}

fn find(host: *EngineHost) ?*Service {
    lockRegistry();
    defer unlockRegistry();
    for (registry.items) |s| if (s.host == host) return s;
    return null;
}

/// Start the preview service for `host` (once). Needs the engine's `io` and
/// data directory (for `previews.json`).
pub fn ensureWith(host: *EngineHost, config: Config) !*Service {
    if (find(host)) |s| return s;
    const io = host.io orelse return error.Unavailable;
    const dir = host.data_dir orelse return error.Unavailable;
    const gpa = host.gpa;
    const file = try std.fs.path.join(host.gpa, &.{ dir, "previews.json" });
    defer host.gpa.free(file);
    const cat = try Catalog.open(gpa, io, file, host.device_id, host.device_name);
    errdefer cat.deinit();
    const s = try gpa.create(Service);
    errdefer gpa.destroy(s);
    s.* = .{
        .gpa = gpa,
        .io = io,
        .host = host,
        .config = config,
        .cat = cat,
        .proxy = .{ .gpa = gpa, .io = io, .catalog = cat, .verify = config.verify },
    };
    {
        lockRegistry();
        defer unlockRegistry();
        try registry.append(gpa, s);
    }
    s.binder = std.Thread.spawn(.{}, Service.bindLoop, .{s}) catch null;
    s.scanner = std.Thread.spawn(.{}, Service.scanLoop, .{s}) catch null;
    return s;
}

/// Stop `host`'s preview service: threads, proxy, watchers. Call without
/// holding `host.mutex`.
pub fn shutdown(host: *EngineHost) void {
    const s = blk: {
        lockRegistry();
        defer unlockRegistry();
        for (registry.items, 0..) |x, i| {
            if (x.host != host) continue;
            _ = registry.swapRemove(i);
            if (registry.items.len == 0) registry.clearAndFree(x.gpa);
            break :blk x;
        }
        return;
    };
    s.stop_flag.store(true, .release);
    if (s.binder) |t| t.join();
    if (s.scanner) |t| t.join();
    s.proxy.stop();
    streams.lock(host);
    while (s.subs.items.len > 0) s.dropSub(0);
    s.subs.deinit(s.gpa);
    streams.unlock(host);
    s.memory.deinit(s.gpa);
    s.cat.deinit();
    s.gpa.destroy(s);
}

/// `WatchPreviews {chatId}`. Called from the dispatcher with `host.mutex` held.
pub fn watch(host: *EngineHost, call_id: u64, params: json.Value) !RpcOutcome {
    if (params != .object) return .{ .err = .{ .bad_params = "expected object" } };
    const chat_v = params.object.get("chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
    if (chat_v != .string) return .{ .err = .{ .bad_params = "missing chatId" } };
    const chat_id = chat_v.string;
    var found = false;
    for (host.chats.items) |c| {
        if (std.mem.eql(u8, c.id, chat_id)) found = true;
    }
    if (!found) return .{ .err = .{ .exec_error = "Project session not found" } };
    const s = ensureWith(host, .native()) catch return .{ .err = .{ .exec_error = "Preview discovery unavailable" } };
    const first = try viewForChat(s, chat_id);
    errdefer s.gpa.free(first);
    if (call_id != 0) {
        const sub = try streams.open(host, call_id, token);
        const chat_copy = try s.gpa.dupe(u8, chat_id);
        errdefer s.gpa.free(chat_copy);
        const last = try s.gpa.dupe(u8, first);
        errdefer s.gpa.free(last);
        try s.subs.append(s.gpa, .{ .sub = sub, .chat_id = chat_copy, .last = last });
    }
    return streams.firstItem(host.gpa, first);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const net = Io.net;

const Recorded = struct {
    lsof: []const u8,
    cwds: []const u8,
    ps: []const u8,
    fn run(ctx: ?*anyopaque, gpa: Allocator, _: Io, argv: []const []const u8) ?[]u8 {
        const self: *const Recorded = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, argv[0], "/bin/ps")) {
            if (std.mem.eql(u8, argv[2], "lstart=")) return gpa.dupe(u8, "Thu Sep 11 16:14:42 2026\n") catch null;
            return gpa.dupe(u8, self.ps) catch null;
        }
        for (argv) |arg| if (std.mem.eql(u8, arg, "cwd")) return gpa.dupe(u8, self.cwds) catch null;
        return gpa.dupe(u8, self.lsof) catch null;
    }
    fn noParent(_: ?*anyopaque, _: u32) ?u32 {
        return null;
    }
    fn verifyAlways(_: ?*anyopaque, _: Allocator, _: Io, _: u32, _: u64) bool {
        return true;
    }
};

fn httpServer(server: *net.Server, stop: *std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        if (!discovery.readable(server.socket.handle, 50)) continue;
        const c = server.accept(testing.io) catch continue;
        defer c.close(testing.io);
        if (discovery.readable(c.socket.handle, 1000)) {
            var buf: [1024]u8 = undefined;
            var bufs = [_][]u8{&buf};
            _ = c.readWithControl(testing.io, &bufs, &.{}) catch {};
        }
        var w = c.writer(testing.io, &.{});
        w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch {};
    }
}

fn pushedContaining(host: *EngineHost, sub_id: u64, needle: []const u8) bool {
    const deadline = discovery.nowMs(testing.io) + 4000;
    while (discovery.nowMs(testing.io) < deadline) {
        streams.lock(host);
        for (host.pushed_frames.items) |f| {
            if (f.sub_id == sub_id and std.mem.indexOf(u8, f.item_json, needle) != null) {
                streams.unlock(host);
                return true;
            }
        }
        streams.unlock(host);
        Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
    }
    return false;
}

fn mutate(host: *EngineHost, a: Allocator, text: []const u8) !void {
    const v = try json.parseFromSliceLeaky(json.Value, a, text, .{});
    streams.lock(host);
    defer streams.unlock(host);
    var r = try host.handle("Mutate", v);
    switch (r) {
        .unary_json => |b| host.gpa.free(b),
        .stream_items_json => |*st| st.deinit(host.gpa),
        .err => return error.MutateFailed,
    }
}

test "WatchPreviews streams the chat's discovered services and follows its folder" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "app");
    try tmp.dir.createDirPath(io, "other");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const app = try std.fs.path.join(a, &.{ root, "app" });
    const other = try std.fs.path.join(a, &.{ root, "other" });

    // A made-up dev server on an ephemeral port that answers HTTP.
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    var stop_srv: std.atomic.Value(bool) = .init(false);
    const srv = try std.Thread.spawn(.{}, httpServer, .{ &server, &stop_srv });
    defer {
        stop_srv.store(true, .release);
        srv.join();
    }

    const rec: Recorded = .{
        .lsof = try std.fmt.allocPrint(a, "p4242\x00f12\x00n127.0.0.1:{d}\x00\n", .{port}),
        .cwds = try std.fmt.allocPrint(a, "p4242\x00fcwd\x00n{s}\x00\n", .{app}),
        .ps = "4242 4000 Thu Sep 11 16:14:42 2026 node node_modules/.bin/vite\n",
    };
    var sys = discovery.Sys.native();
    sys.ctx = @constCast(&rec);
    sys.run = Recorded.run;
    sys.parent_of = Recorded.noParent;
    sys.os = .macos;
    sys.self_pid = 1;

    var host = try EngineHost.init(gpa, "dev-a", "Mac");
    defer host.deinit();
    host.io = io;
    try host.setDataDir(root);
    defer shutdown(&host);
    const s = try ensureWith(&host, .{ .port = 0, .sys = sys, .verify = .{ .func = Recorded.verifyAlways }, .scan_interval_ms = 50 });

    try mutate(&host, a, try std.fmt.allocPrint(a, "{{\"op\":\"createChat\",\"chatId\":\"chat-p\",\"cwd\":{f},\"config\":{{\"harness\":\"mock\"}}}}", .{json.fmt(app, .{})}));

    // Error replies.
    {
        streams.lock(&host);
        defer streams.unlock(&host);
        var r1 = try host.handleWithId(3, "WatchPreviews", try json.parseFromSliceLeaky(json.Value, a, "{}", .{}));
        try testing.expectEqualStrings("missing chatId", r1.err.bad_params);
        var r2 = try host.handleWithId(3, "WatchPreviews", try json.parseFromSliceLeaky(json.Value, a, "{\"chatId\":\"nope\"}", .{}));
        try testing.expectEqualStrings("Project session not found", r2.err.exec_error);
        _ = &r1;
        _ = &r2;
    }
    {
        streams.lock(&host);
        defer streams.unlock(&host);
        var r = try host.handleWithId(5, "WatchPreviews", try json.parseFromSliceLeaky(json.Value, a, "{\"chatId\":\"chat-p\"}", .{}));
        defer r.stream_items_json.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), r.stream_items_json.items.len);
        try testing.expect(std.mem.indexOf(u8, r.stream_items_json.items[0], "\"projectName\":\"app\"") != null);
        try testing.expect(std.mem.indexOf(u8, r.stream_items_json.items[0], "\"remote\":false") != null);
    }
    try testing.expect(pushedContaining(&host, 5, "\"hostname\":\"mac.app.localhost\""));
    const proxy_port = s.cat.proxyPort();
    try testing.expect(proxy_port != 0 and proxy_port != catalog_mod.proxy_port_default);

    // The proxy serves the discovered name.
    {
        const pa = try net.IpAddress.parseIp4("127.0.0.1", proxy_port);
        const c = try pa.connect(io, .{ .mode = .stream });
        defer c.close(io);
        var w = c.writer(io, &.{});
        var req: [256]u8 = undefined;
        try w.interface.writeAll(try std.fmt.bufPrint(&req, "GET / HTTP/1.1\r\nHost: mac.app.localhost:{d}\r\n\r\n", .{proxy_port}));
        var buf: [512]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\nok") == null and discovery.readable(c.socket.handle, 3000)) {
            var bufs = [_][]u8{buf[n..]};
            const got = (c.readWithControl(io, &bufs, &.{}) catch break).data_len;
            if (got == 0) break;
            n += got;
        }
        try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
    }

    // Changing the chat's folder changes its list.
    try mutate(&host, a, try std.fmt.allocPrint(a, "{{\"op\":\"setChatCwd\",\"chatId\":\"chat-p\",\"cwd\":{f}}}", .{json.fmt(other, .{})}));
    try testing.expect(pushedContaining(&host, 5, "{\"services\":[],\"proxyPort\""));
    try testing.expect(pushedContaining(&host, 5, "\"projectName\":\"other\""));

    // Cancelled: the watcher is dropped on the next pass.
    {
        streams.lock(&host);
        host.cancelWatch(5);
        streams.unlock(&host);
    }
    const deadline = discovery.nowMs(io) + 3000;
    while (discovery.nowMs(io) < deadline) {
        streams.lock(&host);
        const left = s.subs.items.len;
        streams.unlock(&host);
        if (left == 0) break;
        Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    try testing.expectEqual(@as(usize, 0), s.subs.items.len);
}

test "WatchPreviews without a data directory is unavailable" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var host = try EngineHost.init(gpa, "dev-a", "Mac");
    defer host.deinit();
    try mutate(&host, arena.allocator(), "{\"op\":\"createChat\",\"chatId\":\"c1\",\"config\":{\"harness\":\"mock\"}}");
    var r = try host.handleWithId(2, "WatchPreviews", try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"chatId\":\"c1\"}", .{}));
    _ = &r;
    try testing.expectEqualStrings("Preview discovery unavailable", r.err.exec_error);
}

test "a busy preview port becomes the snapshot's error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var taken = try addr.listen(io, .{});
    defer taken.deinit(io);
    var host = try EngineHost.init(gpa, "dev-a", "Mac");
    defer host.deinit();
    host.io = io;
    try host.setDataDir(root);
    defer shutdown(&host);
    var sys = discovery.Sys.native();
    sys.os = .windows; // no discovery in this test
    const s = try ensureWith(&host, .{ .port = taken.socket.address.getPort(), .sys = sys, .verify = .{ .func = Recorded.verifyAlways }, .bind_retry_ms = 50 });
    const deadline = discovery.nowMs(io) + 3000;
    while (discovery.nowMs(io) < deadline and s.cat.changeSeq() == 0) Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    const view = try s.cat.viewJson(gpa, "dev-a", null, null, false);
    defer gpa.free(view);
    try testing.expectEqualStrings("{\"services\":[],\"proxyPort\":7331,\"error\":\"Local previews could not listen on port 7331: Address already in use\",\"projectName\":null,\"remote\":false}", view);
}
