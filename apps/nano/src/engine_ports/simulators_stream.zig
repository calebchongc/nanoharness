//! `WatchSimulatorScreen` and `SimulatorInput` (`crates/engine/src/simulators`:
//! `mod.rs` streaming and input, `hub.rs` running the helper).
//!
//! The helper is the pinned `expo-device-hub` that `SetUpSimulators` installs
//! under `<data dir>/tools`, served by Harness's own host script on the
//! user's Node: loopback only, a bearer token minted per run, its own process
//! group, gone when its stdin closes, its pid and start time in a pid file so
//! the next engine stops an orphan without signalling a reused pid. With
//! nobody watching for a minute it stops.
//!
//! One pump per simulator reads the helper's MJPEG route and is shared by
//! every viewer; each viewer gets the newest frame (`{seq, jpeg}`, base64) at
//! most `maxFps` times a second, so a slow viewer skips frames. The pump stops
//! with its last viewer; a pump that can't reach the stream retries five
//! times, then ends its viewers' streams. Input is translated into the
//! helper's HID socket messages (`simulator_input.zig`) on one WebSocket per
//! simulator. Ids must be UDIDs of iOS Simulators `simctl` lists right now.
//!
//! Devices and the helper sit behind `Backend`, so tests use a fixed device
//! list and an in-process helper on an ephemeral port.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;
const engine_host = @import("../engine_host.zig");
const streams = @import("engine_streams.zig");
const rules = @import("simulator_input.zig");
const ws = @import("../ws.zig");
const discovery = @import("preview_discovery.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

pub const unsupported = "iOS Simulators need a Mac with Xcode.";
pub const not_set_up = "Simulator streaming isn't set up on this computer.";
pub const node_missing = "Node.js wasn't found on this computer. Install Node.js 20 or newer, then try again.";
const token_name = "\x00stream:simulator";
const package = "expo-device-hub";
const version = "0.12.0";
const host_script_name = "harness-sim-host.mjs";
const host_script_text = @embedFile("simulator_helper/harness-sim-host.mjs");
const package_lock = @embedFile("simulator_helper/package-lock.json");
const ready_prefix = "HARNESS_SIM_HOST ";
const stream_settings = "{\"maxDimension\":960,\"mjpegQuality\":0.6,\"mjpegFps\":20}";
const pump_retries: u32 = 5;
const key_gap_ms: i64 = 6;
const poll_ms: i32 = 25;

pub const Endpoint = struct {
    port: u16,
    token: [64]u8,
};

pub const DeviceList = union(enum) { ok: []const rules.Device, err: []const u8 };
pub const EndpointResult = union(enum) { ok: Endpoint, err: []const u8 };

/// Where devices and the helper come from.
pub const Backend = struct {
    ctx: ?*anyopaque,
    supported: bool,
    /// iOS devices `simctl` lists now, in `a`; an error's text also in `a`.
    devices: *const fn (ctx: ?*anyopaque, a: Allocator, io: Io) DeviceList,
    /// The running helper, started if it isn't; an error's text in `a`.
    endpoint: *const fn (ctx: ?*anyopaque, a: Allocator, io: Io) EndpointResult,
    /// Stop the helper (idle or shutdown).
    stop: *const fn (ctx: ?*anyopaque) void,
};

pub const Config = struct {
    backend: Backend,
    allowlist: ?[]const u8 = null,
    idle_stop_ms: i64 = 60_000,
    retry_base_ms: i64 = 500,
};

const Viewer = struct {
    sub: streams.Sub,
    gap_ms: i64,
    last_sent_ms: i64 = 0,
    sent_seq: u64 = 0,
};

/// One simulator's frames. `viewers`, `latest` and `seq` are guarded by `host.mutex`.
const Pump = struct {
    svc: *Service,
    id: [36]u8,
    endpoint: Endpoint,
    viewers: std.ArrayList(Viewer) = .empty,
    latest: ?[]u8 = null,
    seq: u64 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn stopping(p: *Pump) bool {
        return p.stop.load(.acquire) or p.svc.stop_flag.load(.acquire);
    }

    /// Send the newest frame to each viewer whose gap has passed; drop gone
    /// viewers. False once nobody watches. Caller holds `host.mutex`.
    fn serveLocked(p: *Pump, now: i64) bool {
        const host = p.svc.host;
        var i: usize = p.viewers.items.len;
        while (i > 0) {
            i -= 1;
            const v = &p.viewers.items[i];
            if (!streams.aliveLocked(host, v.sub)) {
                _ = p.viewers.swapRemove(i);
                continue;
            }
            const frame = p.latest orelse continue;
            if (v.sent_seq >= p.seq or now - v.last_sent_ms < v.gap_ms) continue;
            if (!streams.sendLocked(host, v.sub, frame)) {
                _ = p.viewers.swapRemove(i);
                continue;
            }
            v.sent_seq = p.seq;
            v.last_sent_ms = now;
        }
        return p.viewers.items.len > 0;
    }

    fn run(p: *Pump) void {
        const svc = p.svc;
        var failures: u32 = 0;
        while (failures <= pump_retries and !p.stopping()) {
            switch (p.stream()) {
                .viewers_gone => break,
                .frames => failures = 0,
                .failed => {},
            }
            failures += 1;
            if (!p.wait(svc.config.retry_base_ms * failures)) break;
        }
        // End what's left: the viewers' streams, then the pump's entry.
        streams.lock(svc.host);
        for (p.viewers.items) |v| streams.doneLocked(svc.host, v.sub);
        p.viewers.clearRetainingCapacity();
        for (svc.pumps.items, 0..) |x, i| {
            if (x != p) continue;
            _ = svc.pumps.swapRemove(i);
            break;
        }
        svc.finished.append(svc.gpa, p) catch {};
        svc.last_used_ms = discovery.nowMs(svc.io);
        streams.unlock(svc.host);
    }

    /// Sleep `ms`, serving viewers; false once nobody watches or it stops.
    fn wait(p: *Pump, ms: i64) bool {
        const until = discovery.nowMs(p.svc.io) + ms;
        while (!p.stopping()) {
            if (!p.tick()) return false;
            if (discovery.nowMs(p.svc.io) >= until) return true;
            Io.sleep(p.svc.io, .fromMilliseconds(poll_ms), .awake) catch return false;
        }
        return false;
    }

    fn tick(p: *Pump) bool {
        streams.lock(p.svc.host);
        defer streams.unlock(p.svc.host);
        return p.serveLocked(discovery.nowMs(p.svc.io));
    }

    const Outcome = enum { viewers_gone, frames, failed };

    /// One connection to the helper's MJPEG route, read until it ends.
    fn stream(p: *Pump) Outcome {
        const svc = p.svc;
        const gpa = svc.gpa;
        const io = svc.io;
        const addr = net.IpAddress.parseIp4("127.0.0.1", p.endpoint.port) catch return .failed;
        const s = addr.connect(io, .{ .mode = .stream }) catch return .failed;
        defer s.close(io);
        var req_buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "GET /sim/helper/{s}/stream.mjpeg HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: Bearer {s}\r\nAccept: */*\r\n\r\n", .{ &p.id, p.endpoint.port, &p.endpoint.token }) catch return .failed;
        var w = s.writer(io, &.{});
        w.interface.writeAll(req) catch return .failed;
        w.interface.flush() catch return .failed;

        var reader: BodyReader = .{ .p = p, .s = s };
        defer reader.deinit(gpa);
        const head = reader.readHead() catch |e| return if (e == error.ViewersGone) .viewers_gone else .failed;
        if (head.status < 200 or head.status >= 300) return .failed;
        reader.chunked = head.chunked;
        var parser: rules.MjpegParser = .{};
        defer parser.deinit(gpa);
        var got_frames = false;
        var chunk: [32 * 1024]u8 = undefined;
        while (true) {
            const n = reader.readBody(&chunk) catch |e| return if (e == error.ViewersGone) .viewers_gone else if (got_frames) .frames else .failed;
            if (n == 0) return if (got_frames) .frames else .failed;
            const frame = parser.push(gpa, chunk[0..n]) catch return if (got_frames) .frames else .failed;
            const jpeg = frame orelse continue;
            defer gpa.free(jpeg);
            got_frames = true;
            const watched = p.publish(jpeg) catch return .failed;
            if (!watched or p.stopping()) return .viewers_gone;
        }
    }

    /// Store the newest frame and serve it; false once nobody watches.
    fn publish(p: *Pump, jpeg: []const u8) !bool {
        const gpa = p.svc.gpa;
        const enc = std.base64.standard.Encoder;
        const b64 = try gpa.alloc(u8, enc.calcSize(jpeg.len));
        defer gpa.free(b64);
        _ = enc.encode(b64, jpeg);
        streams.lock(p.svc.host);
        defer streams.unlock(p.svc.host);
        const item = try std.fmt.allocPrint(gpa, "{{\"seq\":{d},\"jpeg\":\"{s}\"}}", .{ p.seq + 1, b64 });
        if (p.latest) |old| gpa.free(old);
        p.latest = item;
        p.seq += 1;
        return p.serveLocked(discovery.nowMs(p.svc.io));
    }
};

/// An HTTP/1.1 response read off a socket, serving viewers between reads.
const BodyReader = struct {
    p: *Pump,
    s: net.Stream,
    buf: [32 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    chunked: bool = false,
    chunk_left: u64 = 0,
    done: bool = false,

    fn deinit(_: *BodyReader, _: Allocator) void {}

    fn fill(r: *BodyReader) !bool {
        if (r.start == r.end) {
            r.start = 0;
            r.end = 0;
        }
        if (r.end == r.buf.len) {
            std.mem.copyForwards(u8, &r.buf, r.buf[r.start..r.end]);
            r.end -= r.start;
            r.start = 0;
            if (r.end == r.buf.len) return error.TooLarge;
        }
        while (true) {
            if (r.p.stopping()) return error.ViewersGone;
            if (discovery.readable(r.s.socket.handle, poll_ms)) break;
            if (!r.p.tick()) return error.ViewersGone;
        }
        var bufs = [_][]u8{r.buf[r.end..]};
        const n = (r.s.readWithControl(r.p.svc.io, &bufs, &.{}) catch return false).data_len;
        r.end += n;
        return n > 0;
    }

    const Head = struct { status: u16, chunked: bool };

    fn readHead(r: *BodyReader) !Head {
        while (true) {
            if (std.mem.indexOf(u8, r.buf[r.start..r.end], "\r\n\r\n")) |i| {
                const head = r.buf[r.start .. r.start + i];
                r.start += i + 4;
                if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return error.BadResponse;
                const status = std.fmt.parseInt(u16, head[9..12], 10) catch return error.BadResponse;
                var chunked = false;
                var lines = std.mem.splitSequence(u8, head, "\r\n");
                while (lines.next()) |line| {
                    const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "transfer-encoding") and
                        std.mem.indexOf(u8, line[colon + 1 ..], "chunked") != null) chunked = true;
                }
                return .{ .status = status, .chunked = chunked };
            }
            if (!try r.fill()) return error.Closed;
        }
    }

    /// Body bytes (de-chunked); 0 at the end.
    fn readBody(r: *BodyReader, out: []u8) !usize {
        if (r.done) return 0;
        if (!r.chunked) {
            if (r.start == r.end and !try r.fill()) return 0;
            const n = @min(out.len, r.end - r.start);
            @memcpy(out[0..n], r.buf[r.start .. r.start + n]);
            r.start += n;
            return n;
        }
        while (r.chunk_left == 0) {
            const line_end = while (true) {
                if (std.mem.indexOf(u8, r.buf[r.start..r.end], "\r\n")) |i| break i;
                if (!try r.fill()) return 0;
            };
            const line = r.buf[r.start .. r.start + line_end];
            r.start += line_end + 2;
            if (line.len == 0) continue; // the CRLF after a chunk's data
            const size_text = line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len];
            const size = std.fmt.parseInt(u64, std.mem.trim(u8, size_text, " "), 16) catch return error.BadChunk;
            if (size == 0) {
                r.done = true;
                return 0;
            }
            r.chunk_left = size;
        }
        if (r.start == r.end and !try r.fill()) return 0;
        const n: usize = @intCast(@min(@as(u64, out.len), @min(r.chunk_left, r.end - r.start)));
        @memcpy(out[0..n], r.buf[r.start .. r.start + n]);
        r.start += n;
        r.chunk_left -= n;
        return n;
    }
};

const InputSocket = struct {
    id: [36]u8,
    port: u16,
    s: net.Stream,
};

pub const Service = struct {
    gpa: Allocator,
    io: Io,
    host: *EngineHost,
    config: Config,
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// Guarded by `host.mutex`.
    pumps: std.ArrayList(*Pump) = .empty,
    finished: std.ArrayList(*Pump) = .empty,
    last_used_ms: i64 = 0,
    /// Input sockets, one per simulator; held across a whole send.
    input_mutex: Io.Mutex = .init,
    inputs: std.ArrayList(InputSocket) = .empty,
    watchdog: ?std.Thread = null,
    watchdog_running: std.atomic.Value(bool) = .init(false),

    fn findPump(s: *Service, id: []const u8) ?*Pump {
        for (s.pumps.items) |p| if (std.mem.eql(u8, &p.id, id) and !p.stop.load(.acquire)) return p;
        return null;
    }

    /// Join pumps that ended. Caller holds `host.mutex`.
    fn reapLocked(s: *Service) void {
        while (s.finished.pop()) |p| {
            if (p.thread) |t| t.join();
            p.viewers.deinit(s.gpa);
            if (p.latest) |l| s.gpa.free(l);
            s.gpa.destroy(p);
        }
    }

    fn touchLocked(s: *Service) void {
        s.last_used_ms = discovery.nowMs(s.io);
    }

    /// A well-formed, admitted id on a host with simulators; else the refusal.
    fn usable(s: *Service, a: Allocator, id: []const u8) !?[]const u8 {
        if (!s.config.backend.supported) return unsupported;
        if (!rules.checkId(id)) return try std.fmt.allocPrint(a, "not a simulator id: {f}", .{json.fmt(id, .{})});
        if (!rules.allowed(s.config.allowlist, id)) return try std.fmt.allocPrint(a, "no iOS Simulator {s} on this computer", .{id});
        return null;
    }

    /// The id names an iOS Simulator `simctl` lists right now (and the allowlist admits).
    fn known(s: *Service, a: Allocator, id: []const u8) !?[]const u8 {
        switch (s.config.backend.devices(s.config.backend.ctx, a, s.io)) {
            .err => |e| return e,
            .ok => |devices| {
                for (devices) |d| {
                    if (std.ascii.eqlIgnoreCase(d.id, id) and rules.allowed(s.config.allowlist, d.id)) return null;
                }
                return try std.fmt.allocPrint(a, "no iOS Simulator {s} on this computer", .{id});
            },
        }
    }

    fn startWatchdog(s: *Service) void {
        if (s.watchdog_running.swap(true, .acq_rel)) return;
        if (s.watchdog) |t| t.join();
        s.watchdog = std.Thread.spawn(.{}, watchdogRun, .{s}) catch blk: {
            s.watchdog_running.store(false, .release);
            break :blk null;
        };
    }

    /// Stops the helper once nobody has used it for a while.
    fn watchdogRun(s: *Service) void {
        defer s.watchdog_running.store(false, .release);
        const check = std.math.clamp(@divTrunc(s.config.idle_stop_ms, 4), 50, 15_000);
        while (!s.stop_flag.load(.acquire)) {
            var left = check;
            while (left > 0 and !s.stop_flag.load(.acquire)) : (left -= 25) Io.sleep(s.io, .fromMilliseconds(25), .awake) catch return;
            if (s.stop_flag.load(.acquire)) return;
            streams.lock(s.host);
            const idle = s.pumps.items.len == 0 and discovery.nowMs(s.io) - s.last_used_ms >= s.config.idle_stop_ms;
            streams.unlock(s.host);
            if (!idle) continue;
            s.input_mutex.lockUncancelable(s.io);
            s.closeInputs();
            s.input_mutex.unlock(s.io);
            s.config.backend.stop(s.config.backend.ctx);
            return;
        }
    }

    fn closeInputs(s: *Service) void {
        for (s.inputs.items) |x| x.s.close(s.io);
        s.inputs.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------- registry

var registry: std.ArrayList(*Service) = .empty;
var registry_lock: std.atomic.Value(bool) = .init(false);

fn lockRegistry() void {
    while (registry_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockRegistry() void {
    registry_lock.store(false, .release);
}

/// The service for `host`, created with `config` (or the native one) on first use.
pub fn serviceFor(host: *EngineHost, config: ?Config) !*Service {
    lockRegistry();
    defer unlockRegistry();
    for (registry.items) |s| if (s.host == host) return s;
    const io = host.io orelse return error.Unavailable;
    const cfg = config orelse try Native.config(host);
    const s = try host.gpa.create(Service);
    errdefer host.gpa.destroy(s);
    s.* = .{ .gpa = host.gpa, .io = io, .host = host, .config = cfg };
    try registry.append(host.gpa, s);
    return s;
}

/// Stop pumps, input sockets, the watchdog and the helper. Call without `host.mutex`.
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
    // Pumps see the flag within a poll; a stuck one is left (and leaks) rather than hang.
    const deadline = discovery.nowMs(s.io) + 10_000;
    while (discovery.nowMs(s.io) < deadline) {
        streams.lock(host);
        const any = s.pumps.items.len > 0;
        streams.unlock(host);
        if (!any) break;
        Io.sleep(s.io, .fromMilliseconds(10), .awake) catch {};
    }
    streams.lock(host);
    if (s.pumps.items.len > 0) {
        streams.unlock(host);
        return;
    }
    s.reapLocked();
    s.pumps.deinit(s.gpa);
    s.finished.deinit(s.gpa);
    streams.unlock(host);
    if (s.watchdog) |t| t.join();
    s.input_mutex.lockUncancelable(s.io);
    s.closeInputs();
    s.inputs.deinit(s.gpa);
    s.input_mutex.unlock(s.io);
    s.config.backend.stop(s.config.backend.ctx);
    if (s.config.backend.ctx) |ctx| {
        if (s.config.backend.devices == &Native.devices) Native.destroy(ctx);
    }
    s.gpa.destroy(s);
}

// ---------------------------------------------------------------- RPCs

fn failed(host: *EngineHost, msg: []const u8) !RpcOutcome {
    // Dynamic texts must outlive the reply; keep them on the host's error buffer.
    return .{ .err = .{ .exec_error = try errorText(host, msg) } };
}

/// Error texts built at runtime live until the next one (the dispatcher writes
/// the reply before another call can run on this host).
var error_buf: [512]u8 = undefined;
fn errorText(_: *EngineHost, msg: []const u8) ![]const u8 {
    if (msg.ptr == unsupported.ptr or msg.ptr == not_set_up.ptr or msg.ptr == node_missing.ptr) return msg;
    const n = @min(msg.len, error_buf.len);
    @memcpy(error_buf[0..n], msg[0..n]);
    return error_buf[0..n];
}

fn simulatorId(params: json.Value) ?[]const u8 {
    if (params != .object) return null;
    const v = params.object.get("simulatorId") orelse return null;
    return if (v == .string) v.string else null;
}

/// `WatchSimulatorScreen {simulatorId, maxFps?}`. Called with `host.mutex` held.
pub fn watchScreen(host: *EngineHost, call_id: u64, params: json.Value) !RpcOutcome {
    const raw_id = simulatorId(params) orelse return .{ .err = .{ .bad_params = "missing field `simulatorId`" } };
    const max_fps: ?u32 = if (params.object.get("maxFps")) |v| switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return .{ .err = .{ .bad_params = "invalid value for `maxFps`" } },
        .null => null,
        else => return .{ .err = .{ .bad_params = "invalid type for `maxFps`" } },
    } else null;
    const s = serviceFor(host, null) catch return failed(host, unsupported);
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (try s.usable(a, raw_id)) |m| return failed(host, m);
    var id: [36]u8 = undefined;
    for (raw_id, 0..) |c, i| id[i] = std.ascii.toUpper(c);
    s.reapLocked();
    s.touchLocked();

    const pump = s.findPump(&id) orelse blk: {
        // simctl and the helper's start can take a while: not under the engine's lock.
        streams.unlock(host);
        const known = s.known(a, &id);
        const endpoint: EndpointResult = if (known) |k| (if (k) |m| .{ .err = m } else s.config.backend.endpoint(s.config.backend.ctx, a, s.io)) else |_| .{ .err = "out of memory" };
        streams.lock(host);
        const ep = switch (endpoint) {
            .err => |m| return failed(host, m),
            .ok => |e| e,
        };
        if (s.findPump(&id)) |p| break :blk p;
        const p = try s.gpa.create(Pump);
        p.* = .{ .svc = s, .id = id, .endpoint = ep };
        try s.pumps.append(s.gpa, p);
        s.startWatchdog();
        p.thread = std.Thread.spawn(.{}, Pump.run, .{p}) catch |e| {
            _ = s.pumps.pop();
            s.gpa.destroy(p);
            return e;
        };
        break :blk p;
    };
    const now = discovery.nowMs(s.io);
    var viewer: Viewer = .{ .sub = undefined, .gap_ms = rules.viewerGapMs(max_fps) };
    var items: [][]u8 = try host.gpa.alloc([]u8, 0);
    if (pump.latest) |frame| {
        host.gpa.free(items);
        items = try host.gpa.alloc([]u8, 1);
        items[0] = host.gpa.dupe(u8, frame) catch |e| {
            host.gpa.free(items);
            return e;
        };
        viewer.sent_seq = pump.seq;
        viewer.last_sent_ms = now;
    }
    if (call_id != 0) {
        viewer.sub = try streams.open(host, call_id, token_name);
        try pump.viewers.append(s.gpa, viewer);
    }
    return .{ .stream_items_json = .{ .checked = false, .items = items } };
}

/// `SimulatorInput {simulatorId, input}` → `{ok: true}`. Called with `host.mutex` held.
pub fn input(host: *EngineHost, params: json.Value) !RpcOutcome {
    const raw_id = simulatorId(params) orelse return .{ .err = .{ .bad_params = "missing field `simulatorId`" } };
    const input_v = params.object.get("input") orelse return .{ .err = .{ .bad_params = "missing field `input`" } };
    const s = serviceFor(host, null) catch return failed(host, unsupported);
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (try s.usable(a, raw_id)) |m| return failed(host, m);
    var id: [36]u8 = undefined;
    for (raw_id, 0..) |c, i| id[i] = std.ascii.toUpper(c);
    var msgs = try rules.hidMessages(host.gpa, input_v);
    defer msgs.deinit(host.gpa);
    if (msgs.err) |e| return failed(host, e);
    s.touchLocked();

    // The sends (with their key gaps) run outside the engine's lock.
    streams.unlock(host);
    const result = sendInput(s, a, &id, msgs.list.items);
    streams.lock(host);
    s.touchLocked();
    if (result) |m| return failed(host, m);
    return .{ .unary_json = try host.gpa.dupe(u8, "{\"ok\":true}") };
}

fn sendInput(s: *Service, a: Allocator, id: *const [36]u8, messages: []const []const u8) ?[]const u8 {
    s.input_mutex.lockUncancelable(s.io);
    defer s.input_mutex.unlock(s.io);
    var have = false;
    for (s.inputs.items) |x| {
        if (std.mem.eql(u8, &x.id, id)) have = true;
    }
    if (!have) {
        if (s.known(a, id) catch return "out of memory") |m| return m;
    }
    const ep = switch (s.config.backend.endpoint(s.config.backend.ctx, a, s.io)) {
        .err => |m| return m,
        .ok => |e| e,
    };
    streams.lock(s.host);
    s.startWatchdog();
    streams.unlock(s.host);
    // A socket opened against a helper run that has since stopped goes.
    var i: usize = 0;
    while (i < s.inputs.items.len) {
        const x = s.inputs.items[i];
        if (std.mem.eql(u8, &x.id, id) and x.port != ep.port) {
            x.s.close(s.io);
            _ = s.inputs.swapRemove(i);
        } else i += 1;
    }
    for (0..2) |attempt| {
        const idx = for (s.inputs.items, 0..) |x, k| {
            if (std.mem.eql(u8, &x.id, id)) break k;
        } else blk: {
            const sock = connectInput(s.io, ep, id) catch |e| return std.fmt.allocPrint(a, "connecting to the simulator: {s}", .{@errorName(e)}) catch "connecting to the simulator";
            s.inputs.append(s.gpa, .{ .id = id.*, .port = ep.port, .s = sock }) catch {
                sock.close(s.io);
                return "out of memory";
            };
            break :blk s.inputs.items.len - 1;
        };
        const sock = s.inputs.items[idx].s;
        const sent = sendAll(s.io, sock, messages);
        if (sent) |_| return null else |e| {
            sock.close(s.io);
            _ = s.inputs.swapRemove(idx);
            if (attempt == 1) return std.fmt.allocPrint(a, "sending input: {s}", .{@errorName(e)}) catch "sending input";
        }
    }
    return null;
}

fn sendAll(io: Io, s: net.Stream, messages: []const []const u8) !void {
    for (messages, 0..) |m, i| {
        if (i > 0) Io.sleep(io, .fromMilliseconds(key_gap_ms), .awake) catch {};
        // The helper sends screen config frames; nothing here needs them.
        while (discovery.readable(s.socket.handle, 0)) {
            var junk: [4096]u8 = undefined;
            var bufs = [_][]u8{&junk};
            const n = (try s.readWithControl(io, &bufs, &.{})).data_len;
            if (n == 0) return error.ConnectionClosed;
        }
        var mask: [4]u8 = undefined;
        io.random(&mask);
        var w = s.writer(io, &.{});
        try ws.writeFrame(&w.interface, .binary, m, mask);
        try w.interface.flush();
    }
}

/// The helper's HID socket for one simulator, with the run's bearer token.
fn connectInput(io: Io, ep: Endpoint, id: *const [36]u8) !net.Stream {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", ep.port);
    const s = try addr.connect(io, .{ .mode = .stream });
    errdefer s.close(io);
    var key_raw: [16]u8 = undefined;
    io.random(&key_raw);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_raw);
    var req: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&req, "GET /sim/helper/ws?device={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {s}\r\n\r\n", .{ id, ep.port, &key, &ep.token });
    var w = s.writer(io, &.{});
    try w.interface.writeAll(text);
    try w.interface.flush();
    // The 101 head, byte by byte so no frame after it is consumed.
    var head: [2048]u8 = undefined;
    var n: usize = 0;
    const deadline = discovery.nowMs(io) + 5_000;
    while (!std.mem.endsWith(u8, head[0..n], "\r\n\r\n")) {
        if (n == head.len) return error.HandshakeFailed;
        const left = deadline - discovery.nowMs(io);
        if (left <= 0 or !discovery.readable(s.socket.handle, @intCast(left))) return error.HandshakeFailed;
        var bufs = [_][]u8{head[n .. n + 1]};
        const got = (try s.readWithControl(io, &bufs, &.{})).data_len;
        if (got == 0) return error.HandshakeFailed;
        n += got;
    }
    if (std.mem.indexOf(u8, head[0..n], " 101 ") == null) return error.HandshakeFailed;
    return s;
}

// ---------------------------------------------------------------- the real helper

/// `simctl` for devices and the installed helper on this Mac.
pub const Native = struct {
    gpa: Allocator,
    io: Io,
    tools_dir: []u8,
    mutex: Io.Mutex = .init,
    hub: ?*Hub = null,

    fn config(host: *EngineHost) !Config {
        const io = host.io orelse return error.Unavailable;
        const data = host.data_dir orelse return error.Unavailable;
        const n = try host.gpa.create(Native);
        n.* = .{ .gpa = host.gpa, .io = io, .tools_dir = try std.fs.path.join(host.gpa, &.{ data, "tools" }) };
        const allow: ?[]const u8 = if (comptime builtin.os.tag == .windows) null else if (std.c.getenv("HARNESS_SIMULATOR_ALLOWLIST")) |v| std.mem.span(v) else null;
        return .{
            .backend = .{ .ctx = n, .supported = builtin.os.tag == .macos, .devices = devices, .endpoint = endpoint, .stop = stopHub },
            .allowlist = allow,
        };
    }

    fn destroy(ctx: *anyopaque) void {
        const n: *Native = @ptrCast(@alignCast(ctx));
        n.gpa.free(n.tools_dir);
        n.gpa.destroy(n);
    }

    fn devices(_: ?*anyopaque, a: Allocator, io: Io) DeviceList {
        if (comptime builtin.os.tag != .macos) return .{ .err = unsupported };
        const out = simctl(a, io, &.{ "list", "devices", "available", "-j" }, 20_000);
        const text = switch (out) {
            .err => |e| return .{ .err = e },
            .ok => |t| t,
        };
        const list = rules.parseDevices(a, text) catch |e|
            return .{ .err = std.fmt.allocPrint(a, "reading simctl's device list: {s}", .{@errorName(e)}) catch "reading simctl's device list" };
        return .{ .ok = list };
    }

    fn endpoint(ctx: ?*anyopaque, a: Allocator, io: Io) EndpointResult {
        const n: *Native = @ptrCast(@alignCast(ctx.?));
        n.mutex.lockUncancelable(io);
        defer n.mutex.unlock(io);
        if (n.hub) |h| {
            if (h.alive()) return .{ .ok = h.endpoint };
            h.stop();
            n.hub = null;
        }
        Io.Dir.cwd().createDirPath(io, n.tools_dir) catch |e| return .{ .err = @errorName(e) };
        var dev_buf: [256]u8 = undefined;
        const dev = developerDir(a, io, &dev_buf);
        const node = findTool(a, io, "node") orelse return .{ .err = node_missing };
        const h = Hub.start(n.gpa, io, a, .{ .tools_dir = n.tools_dir, .node = node, .script_text = host_script_text, .developer_dir = dev }) catch |e| return .{ .err = hubError(a, e) };
        switch (h) {
            .err => |m| return .{ .err = m },
            .ok => |hub| {
                n.hub = hub;
                return .{ .ok = hub.endpoint };
            },
        }
    }

    fn stopHub(ctx: ?*anyopaque) void {
        const n: *Native = @ptrCast(@alignCast(ctx.?));
        n.mutex.lockUncancelable(n.io);
        defer n.mutex.unlock(n.io);
        if (n.hub) |h| h.stop();
        n.hub = null;
    }
};

fn hubError(a: Allocator, e: anyerror) []const u8 {
    return std.fmt.allocPrint(a, "starting the streaming helper: {s}", .{@errorName(e)}) catch "starting the streaming helper";
}

/// The PATH to run Node with: this process's, then the usual install spots.
fn toolPath(a: Allocator) ![]u8 {
    const own: []const u8 = if (comptime builtin.os.tag == .windows) "" else if (std.c.getenv("PATH")) |p| std.mem.span(p) else "";
    return std.fmt.allocPrint(a, "{s}{s}/opt/homebrew/bin:/usr/local/bin", .{ own, if (own.len > 0) ":" else "" });
}

fn findTool(a: Allocator, io: Io, name: []const u8) ?[]const u8 {
    const path = toolPath(a) catch return null;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const candidate = std.fs.path.join(a, &.{ dir, name }) catch return null;
        const st = Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (st.kind == .file) return candidate;
    }
    return null;
}

/// Xcode's developer dir when `xcode-select` points at the Command Line Tools.
fn developerDir(a: Allocator, io: Io, buf: []u8) ?[]const u8 {
    _ = buf;
    if (comptime builtin.os.tag != .macos) return null;
    if (std.c.getenv("DEVELOPER_DIR") != null) return null;
    switch (runCapture(a, io, &.{ "/usr/bin/xcrun", "--find", "simctl" }, null, 10_000)) {
        .ok => |r| if (r.code == 0) return null,
        .err => {},
    }
    const xcode = "/Applications/Xcode.app/Contents/Developer";
    const st = Io.Dir.cwd().statFile(io, xcode ++ "/usr/bin/simctl", .{}) catch return null;
    return if (st.kind == .file) xcode else null;
}

const Captured = struct { code: u8, stdout: []u8, stderr: []u8 };
const CaptureResult = union(enum) { ok: Captured, err: []const u8 };

/// Run `argv` with `extra` env vars, killing it after `timeout_ms`.
fn runCapture(a: Allocator, io: Io, argv: []const []const u8, extra: ?[2][]const u8, timeout_ms: i64) CaptureResult {
    if (comptime !std.process.can_spawn) return .{ .err = "spawn unsupported" };
    var env = currentEnv(a) catch return .{ .err = "out of memory" };
    defer env.deinit();
    if (extra) |kv| env.put(kv[0], kv[1]) catch return .{ .err = "out of memory" };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .environ_map = &env }) catch return .{ .err = "spawn failed" };
    const Killer = struct {
        fn run(pid: std.posix.pid_t, done: *std.atomic.Value(bool), io2: Io, ms: i64) void {
            var left = ms;
            while (left > 0 and !done.load(.acquire)) : (left -= 20) Io.sleep(io2, .fromMilliseconds(20), .awake) catch return;
            if (!done.load(.acquire)) std.posix.kill(pid, .KILL) catch {};
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const killer = std.Thread.spawn(.{}, Killer.run, .{ child.id.?, &done, io, timeout_ms }) catch null;
    const started = discovery.nowMs(io);
    const out = readAllFile(a, io, child.stdout.?);
    const errs = readAllFile(a, io, child.stderr.?);
    const term = child.wait(io) catch {
        done.store(true, .release);
        if (killer) |k| k.join();
        return .{ .err = "wait failed" };
    };
    done.store(true, .release);
    if (killer) |k| k.join();
    if (discovery.nowMs(io) - started >= timeout_ms) return .{ .err = "timed out" };
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .ok = .{ .code = code, .stdout = out, .stderr = errs } };
}

fn readAllFile(a: Allocator, io: Io, f: Io.File) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        out.appendSlice(a, chunk[0..n]) catch break;
        if (out.items.len > 16 * 1024 * 1024) break;
    }
    return out.items;
}

fn currentEnv(a: Allocator) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(a);
    errdefer env.deinit();
    if (comptime builtin.os.tag == .windows) return env;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const kv = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        try env.put(kv[0..eq], kv[eq + 1 ..]);
    }
    return env;
}

/// `xcrun simctl <args>`; callers pass literals and checked UDIDs only.
fn simctl(a: Allocator, io: Io, args: []const []const u8, timeout_ms: i64) union(enum) { ok: []const u8, err: []const u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "/usr/bin/xcrun", "simctl" }) catch return .{ .err = "out of memory" };
    argv.appendSlice(a, args) catch return .{ .err = "out of memory" };
    var dev_buf: [256]u8 = undefined;
    const extra: ?[2][]const u8 = if (developerDir(a, io, &dev_buf)) |d| .{ "DEVELOPER_DIR", d } else null;
    switch (runCapture(a, io, argv.items, extra, timeout_ms)) {
        .err => |e| {
            if (std.mem.eql(u8, e, "timed out")) return .{ .err = std.fmt.allocPrint(a, "simctl {s} timed out", .{args[0]}) catch "simctl timed out" };
            return .{ .err = "Xcode wasn't found on this computer." };
        },
        .ok => |r| {
            if (r.code == 0) return .{ .ok = r.stdout };
            const stderr = std.mem.trim(u8, r.stderr, " \t\r\n");
            if (std.mem.indexOf(u8, stderr, "unable to find utility") != null)
                return .{ .err = "Xcode wasn't found on this computer. Install Xcode, or select it with xcode-select." };
            return .{ .err = stderr };
        },
    }
}

/// The SHA-256 of the shipped lockfile; part of the install's sentinel.
pub fn sentinelText(buf: *[96]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(package_lock, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buf, "{s}\n{s}\n", .{ version, &hex }) catch unreachable;
}

/// A running host. `stop` closes its stdin (it exits on its own), then kills
/// its process group if it lingers.
pub const Hub = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    pid: std.posix.pid_t,
    pid_file: []u8,
    endpoint: Endpoint,
    exited: std.atomic.Value(bool) = .init(false),
    drain: ?std.Thread = null,
    log: Io.File,

    pub const Options = struct {
        tools_dir: []const u8,
        node: []const u8,
        script_text: []const u8,
        developer_dir: ?[]const u8 = null,
        ready_timeout_ms: i64 = 30_000,
    };

    pub const Started = union(enum) { ok: *Hub, err: []const u8 };

    /// Start the host when the helper is installed; record its pid; wait for
    /// its ready line. Error texts are allocated in `a`.
    pub fn start(gpa: Allocator, io: Io, a: Allocator, o: Options) !Started {
        const install = try std.fs.path.join(a, &.{ o.tools_dir, package, version });
        const middleware = try std.fs.path.join(a, &.{ install, "node_modules", package, "vendor", "serve-sim", "dist", "middleware.js" });
        var sbuf: [96]u8 = undefined;
        const sentinel: []const u8 = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ install, ".install-complete" }), a, .limited(4096)) catch "";
        const mw = Io.Dir.cwd().statFile(io, middleware, .{}) catch null;
        if (!std.mem.eql(u8, sentinel, sentinelText(&sbuf)) or mw == null or mw.?.kind != .file) return .{ .err = not_set_up };

        const pid_file = try std.fs.path.join(gpa, &.{ o.tools_dir, "simulator-hub.pid" });
        errdefer gpa.free(pid_file);
        const script = try std.fs.path.join(a, &.{ install, host_script_name });
        stopStale(a, io, pid_file, script);
        Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = o.script_text }) catch |e|
            return .{ .err = try std.fmt.allocPrint(a, "writing the streaming host: {s}", .{@errorName(e)}) };
        const log_path = try std.fs.path.join(a, &.{ o.tools_dir, "simulator-hub.log" });
        const log = Io.Dir.cwd().createFile(io, log_path, .{}) catch |e|
            return .{ .err = try std.fmt.allocPrint(a, "opening the streaming helper's log: {s}", .{@errorName(e)}) };
        errdefer log.close(io);

        var raw: [32]u8 = undefined;
        io.random(&raw);
        const token = std.fmt.bytesToHex(raw, .lower);
        var env = try currentEnv(a);
        defer env.deinit();
        try env.put("HARNESS_SIM_TOKEN", &token);
        try env.put("HARNESS_SIM_STREAM", stream_settings);
        try env.put("PATH", try toolPath(a));
        if (o.developer_dir) |d| try env.put("DEVELOPER_DIR", d);
        const child = std.process.spawn(io, .{
            .argv = &.{ o.node, script, middleware },
            .cwd = .{ .path = install },
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .{ .file = log },
            .pgid = 0,
        }) catch |e| return .{ .err = try std.fmt.allocPrint(a, "starting the streaming helper: {s}", .{@errorName(e)}) };
        const pid = child.id.?;
        const h = try gpa.create(Hub);
        h.* = .{ .gpa = gpa, .io = io, .child = child, .pid = pid, .pid_file = pid_file, .endpoint = .{ .port = 0, .token = token }, .log = log };
        if (processStart(a, io, pid)) |started| {
            var pbuf: [64]u8 = undefined;
            Io.Dir.cwd().writeFile(io, .{ .sub_path = pid_file, .data = std.fmt.bufPrint(&pbuf, "{d} {d}\n", .{ pid, started }) catch "" }) catch {};
        }
        // The ready line, logging anything else the helper prints first.
        const out = h.child.stdout.?;
        const deadline = discovery.nowMs(io) + o.ready_timeout_ms;
        var line: std.ArrayList(u8) = .empty;
        const port: ?u16 = while (true) {
            const left = deadline - discovery.nowMs(io);
            if (left <= 0) {
                h.stop();
                return .{ .err = "the streaming helper didn't start in time" };
            }
            if (!fileReadable(out, @intCast(@min(left, 100)))) continue;
            var b: [1]u8 = undefined;
            var bufs = [_][]u8{&b};
            const n = out.readStreaming(io, &bufs) catch 0;
            if (n == 0) break null;
            if (b[0] != '\n') {
                try line.append(a, b[0]);
                continue;
            }
            if (std.mem.startsWith(u8, line.items, ready_prefix)) {
                const v = json.parseFromSliceLeaky(json.Value, a, line.items[ready_prefix.len..], .{}) catch break null;
                const pv = if (v == .object) v.object.get("port") else null;
                break if (pv) |x| (if (x == .integer and x.integer > 0 and x.integer <= 65535) @intCast(x.integer) else null) else null;
            }
            log.writeStreamingAll(io, line.items) catch {};
            log.writeStreamingAll(io, "\n") catch {};
            line.clearRetainingCapacity();
        };
        const p = port orelse {
            h.stop();
            return .{ .err = try std.fmt.allocPrint(a, "the streaming helper exited at startup (see {s})", .{log_path}) };
        };
        h.endpoint.port = p;
        // Keep draining stdout into the log so the helper never blocks on a full pipe.
        h.drain = std.Thread.spawn(.{}, drainRun, .{h}) catch null;
        return .{ .ok = h };
    }

    fn drainRun(h: *Hub) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            var bufs = [_][]u8{&buf};
            const n = h.child.stdout.?.readStreaming(h.io, &bufs) catch break;
            if (n == 0) break;
            h.log.writeStreamingAll(h.io, buf[0..n]) catch {};
        }
    }

    pub fn alive(h: *Hub) bool {
        if (h.exited.load(.acquire)) return false;
        if (comptime builtin.os.tag == .windows) return true;
        // Signal 0: the process (or its unreaped zombie) still exists; a zombie means it exited.
        return processStart(std.heap.page_allocator, h.io, h.pid) != null;
    }

    /// Close stdin; after a 2 s grace, kill the group; reap; forget the pid file.
    pub fn stop(h: *Hub) void {
        if (h.child.stdin) |f| {
            f.close(h.io);
            h.child.stdin = null;
        }
        const Waiter = struct {
            fn run(hub: *Hub) void {
                _ = hub.child.wait(hub.io) catch {};
                hub.exited.store(true, .release);
            }
        };
        const w = std.Thread.spawn(.{}, Waiter.run, .{h}) catch null;
        var left: i64 = 2_000;
        while (left > 0 and !h.exited.load(.acquire)) : (left -= 20) Io.sleep(h.io, .fromMilliseconds(20), .awake) catch break;
        if (!h.exited.load(.acquire) and comptime builtin.os.tag != .windows) std.posix.kill(-h.pid, .KILL) catch {};
        if (w) |t| t.join() else {
            _ = h.child.wait(h.io) catch {};
        }
        if (h.drain) |t| t.join();
        h.log.close(h.io);
        Io.Dir.cwd().deleteFile(h.io, h.pid_file) catch {};
        h.gpa.free(h.pid_file);
        h.gpa.destroy(h);
    }
};

fn fileReadable(f: Io.File, ms: i32) bool {
    if (comptime builtin.os.tag == .windows) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = f.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, ms) catch return false;
    return n > 0;
}

/// The process's start time in the platform's own unit (µs since the epoch
/// on macOS, clock ticks since boot on Linux), if it is running.
fn processStart(a: Allocator, io: Io, pid: std.posix.pid_t) ?u64 {
    if (pid <= 1) return null;
    switch (builtin.os.tag) {
        .macos => {
            const C = struct {
                extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
            };
            var info: [136]u8 align(8) = undefined;
            if (C.proc_pidinfo(pid, 3, 0, &info, 136) != 136) return null;
            // A zombie (exited, unreaped) has status SZOMB (5).
            if (std.mem.readInt(u32, info[4..8], .little) == 5) return null;
            const sec = std.mem.readInt(u64, info[120..128], .little);
            const usec = std.mem.readInt(u64, info[128..136], .little);
            return sec * 1_000_000 + usec;
        },
        .linux => {
            var pbuf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&pbuf, "/proc/{d}/stat", .{pid}) catch return null;
            const stat = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch return null;
            defer a.free(stat);
            const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
            var it = std.mem.tokenizeAny(u8, stat[close + 1 ..], " \n");
            var i: usize = 0;
            while (it.next()) |f| : (i += 1) {
                if (i == 0 and f.len > 0 and f[0] == 'Z') return null;
                if (i == 19) return std.fmt.parseInt(u64, f, 10) catch null;
            }
            return null;
        },
        else => return null,
    }
}

/// True only while `pid` is still the recorded host: the same start time,
/// and a command line running this install's host script.
fn isRecordedHost(a: Allocator, io: Io, pid: std.posix.pid_t, started: u64, script: []const u8) bool {
    const now = processStart(a, io, pid) orelse return false;
    if (now != started) return false;
    var pbuf: [16]u8 = undefined;
    const ps = runCapture(a, io, &.{ "/bin/ps", "-o", "command=", "-p", std.fmt.bufPrint(&pbuf, "{d}", .{pid}) catch return false }, null, 5_000);
    return switch (ps) {
        .ok => |r| std.mem.indexOf(u8, std.mem.trim(u8, r.stdout, " \n"), script) != null,
        .err => false,
    };
}

fn signalGroup(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    if (pid <= 1 or comptime builtin.os.tag == .windows) return;
    const C = struct {
        extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;
    };
    if (C.getpgid(pid) == pid) std.posix.kill(-pid, sig) catch {} else std.posix.kill(pid, sig) catch {};
}

/// An engine killed without cleanup may leave its host running; stop it, but
/// only if the recorded pid still names that host.
pub fn stopStale(a: Allocator, io: Io, pid_file: []const u8, script: []const u8) void {
    const text = Io.Dir.cwd().readFileAlloc(io, pid_file, a, .limited(256)) catch return;
    Io.Dir.cwd().deleteFile(io, pid_file) catch {};
    var parts = std.mem.tokenizeAny(u8, text, " \n");
    const pid = std.fmt.parseInt(std.posix.pid_t, parts.next() orelse return, 10) catch return;
    const started = std.fmt.parseInt(u64, parts.next() orelse return, 10) catch return;
    if (!isRecordedHost(a, io, pid, started, script)) return;
    signalGroup(pid, .TERM);
    for (0..20) |_| {
        Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        if (!isRecordedHost(a, io, pid, started, script)) return;
    }
    signalGroup(pid, .KILL);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ws_server = @import("../ws_server.zig");

const sim = "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1";
const other = "11111111-2222-3333-4444-555555555555";

/// A made-up helper on an ephemeral port: the MJPEG route streams numbered
/// frames every 10 ms (chunked); the HID route records binary messages.
const FakeHelper = struct {
    server: net.Server = undefined,
    port: u16 = 0,
    token: [64]u8 = @splat('t'),
    stop: std.atomic.Value(bool) = .init(false),
    accept_thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    threads: std.ArrayList(std.Thread) = .empty,
    streams_opened: std.atomic.Value(u32) = .init(0),
    streams_active: std.atomic.Value(u32) = .init(0),
    sockets_opened: std.atomic.Value(u32) = .init(0),
    received: std.ArrayList([]u8) = .empty,

    fn begin(f: *FakeHelper) !void {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        f.server = try addr.listen(testing.io, .{});
        f.port = f.server.socket.address.getPort();
        f.accept_thread = try std.Thread.spawn(.{}, acceptRun, .{f});
    }

    fn end(f: *FakeHelper) void {
        f.stop.store(true, .release);
        if (f.accept_thread) |t| t.join();
        for (f.threads.items) |t| t.join();
        f.threads.deinit(testing.allocator);
        for (f.received.items) |r| testing.allocator.free(r);
        f.received.deinit(testing.allocator);
        f.server.deinit(testing.io);
    }

    fn acceptRun(f: *FakeHelper) void {
        while (!f.stop.load(.acquire)) {
            if (!discovery.readable(f.server.socket.handle, 20)) continue;
            const c = f.server.accept(testing.io) catch continue;
            const t = std.Thread.spawn(.{}, serve, .{ f, c }) catch {
                c.close(testing.io);
                continue;
            };
            f.mutex.lockUncancelable(testing.io);
            f.threads.append(testing.allocator, t) catch {};
            f.mutex.unlock(testing.io);
        }
    }

    fn serve(f: *FakeHelper, c: net.Stream) void {
        defer c.close(testing.io);
        var buf: [4096]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null) {
            if (!discovery.readable(c.socket.handle, 2000)) return;
            var bufs = [_][]u8{buf[n .. n + 1]};
            const got = (c.readWithControl(testing.io, &bufs, &.{}) catch return).data_len;
            if (got == 0) return;
            n += got;
        }
        const head = buf[0..n];
        var w = c.writer(testing.io, &.{});
        var bearer: [96]u8 = undefined;
        const authorized = std.mem.indexOf(u8, head, std.fmt.bufPrint(&bearer, "Authorization: Bearer {s}", .{&f.token}) catch return) != null;
        if (std.mem.startsWith(u8, head, "GET /sim/helper/" ++ sim ++ "/stream.mjpeg ")) {
            if (!authorized) {
                w.interface.writeAll("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n") catch {};
                return;
            }
            _ = f.streams_opened.fetchAdd(1, .acq_rel);
            _ = f.streams_active.fetchAdd(1, .acq_rel);
            defer _ = f.streams_active.fetchSub(1, .acq_rel);
            w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nTransfer-Encoding: chunked\r\n\r\n") catch return;
            var i: usize = 0;
            while (!f.stop.load(.acquire)) : (i += 1) {
                var body: [64]u8 = undefined;
                const jpeg = std.fmt.bufPrint(&body, "\xff\xd8frame-{d}\xff\xd9", .{i}) catch return;
                var part: [256]u8 = undefined;
                const p = std.fmt.bufPrint(&part, "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {d}\r\n\r\n{s}\r\n", .{ jpeg.len, jpeg }) catch return;
                w.interface.print("{x}\r\n{s}\r\n", .{ p.len, p }) catch return;
                w.interface.flush() catch return;
                // The client went away: stop.
                if (discovery.readable(c.socket.handle, 10)) {
                    var junk: [64]u8 = undefined;
                    var jb = [_][]u8{&junk};
                    const got = (c.readWithControl(testing.io, &jb, &.{}) catch return).data_len;
                    if (got == 0) return;
                }
            }
        } else if (std.mem.startsWith(u8, head, "GET /sim/helper/ws?device=" ++ sim ++ " ")) {
            if (!authorized) {
                w.interface.writeAll("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n") catch {};
                return;
            }
            const key_at = std.mem.indexOf(u8, head, "Sec-WebSocket-Key: ") orelse return;
            const key_end = std.mem.indexOfPos(u8, head, key_at, "\r\n") orelse return;
            var accept: [28]u8 = undefined;
            ws_server.computeAcceptKey(head[key_at + 19 .. key_end], &accept);
            w.interface.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&accept}) catch return;
            _ = f.sockets_opened.fetchAdd(1, .acq_rel);
            // A screen config frame the engine ignores.
            ws_server.writeServerFrame(&w.interface, .text, "{\"screen\":{\"width\":390}}") catch return;
            w.interface.flush() catch return;
            var rbuf: [8192]u8 = undefined;
            var r = c.reader(testing.io, &rbuf);
            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(testing.allocator);
            while (!f.stop.load(.acquire)) {
                if (r.interface.bufferedLen() == 0 and !discovery.readable(c.socket.handle, 20)) continue;
                const op = ws.readMessageFrom(testing.allocator, &r.interface, &msg, {}, struct {
                    fn noPong(_: void, _: []const u8) void {}
                }.noPong) catch return;
                if (op != .binary) continue;
                f.mutex.lockUncancelable(testing.io);
                f.received.append(testing.allocator, testing.allocator.dupe(u8, msg.items) catch "") catch {};
                f.mutex.unlock(testing.io);
            }
        } else {
            w.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") catch {};
        }
    }
};

const FakeBackend = struct {
    helper: *FakeHelper,
    token: [64]u8,
    stops: u32 = 0,

    fn devices(_: ?*anyopaque, a: Allocator, _: Io) DeviceList {
        const list = a.alloc(rules.Device, 2) catch return .{ .err = "out of memory" };
        list[0] = .{ .id = sim, .name = "Test A", .runtime = "iOS 27.0", .booted = true };
        list[1] = .{ .id = other, .name = "Test B", .runtime = "iOS 27.0", .booted = true };
        return .{ .ok = list };
    }

    fn endpoint(ctx: ?*anyopaque, _: Allocator, _: Io) EndpointResult {
        const b: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        return .{ .ok = .{ .port = b.helper.port, .token = b.token } };
    }

    fn stop(ctx: ?*anyopaque) void {
        const b: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        b.stops += 1;
    }

    fn config(b: *FakeBackend, allowlist: ?[]const u8) Config {
        return .{
            .backend = .{ .ctx = b, .supported = true, .devices = devices, .endpoint = endpoint, .stop = stop },
            .allowlist = allowlist,
            .idle_stop_ms = 200,
            .retry_base_ms = 10,
        };
    }
};

const Rig = struct {
    helper: FakeHelper = .{},
    backend: FakeBackend = undefined,
    host: EngineHost = undefined,
    out: Io.Writer.Allocating = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn begin(r: *Rig, token: ?[64]u8, allowlist: ?[]const u8) !void {
        try r.helper.begin();
        r.backend = .{ .helper = &r.helper, .token = token orelse r.helper.token };
        r.host = try EngineHost.init(testing.allocator, "dev-a", "Mac");
        r.host.io = testing.io;
        r.out = .init(testing.allocator);
        r.arena = .init(testing.allocator);
        _ = try serviceFor(&r.host, r.backend.config(allowlist));
    }

    fn end(r: *Rig) void {
        shutdown(&r.host);
        r.helper.end();
        r.out.deinit();
        r.host.deinit();
        r.arena.deinit();
    }

    /// One call on a socket whose frames land in `out`.
    fn call(r: *Rig, id: u64, method: []const u8, params: []const u8) !RpcOutcome {
        const v = try json.parseFromSliceLeaky(json.Value, r.arena.allocator(), params, .{});
        streams.lock(&r.host);
        defer streams.unlock(&r.host);
        r.host.live_ws_writer = &r.out.writer;
        defer r.host.live_ws_writer = null;
        return r.host.handleWithId(id, method, v);
    }

    fn expectErr(r: *Rig, method: []const u8, params: []const u8, want: []const u8) !void {
        var o = try r.call(1, method, params);
        switch (o) {
            .err => |e| try testing.expectEqualStrings(want, switch (e) {
                .bad_params => |m| m,
                .exec_error => |m| m,
                .unknown_method => |m| m,
            }),
            .unary_json => |b| {
                testing.allocator.free(b);
                return error.UnexpectedSuccess;
            },
            .stream_items_json => |*st| {
                st.deinit(testing.allocator);
                return error.UnexpectedSuccess;
            },
        }
    }

    /// Occurrences of `needle` in what the socket got.
    fn count(r: *Rig, needle: []const u8) usize {
        streams.lock(&r.host);
        defer streams.unlock(&r.host);
        return std.mem.count(u8, r.out.written(), needle);
    }

    fn waitFor(r: *Rig, needle: []const u8, n: usize) bool {
        const deadline = discovery.nowMs(testing.io) + 4000;
        while (discovery.nowMs(testing.io) < deadline) {
            if (r.count(needle) >= n) return true;
            Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
        }
        return false;
    }

    fn pumps(r: *Rig) usize {
        const s = serviceFor(&r.host, null) catch return 0;
        streams.lock(&r.host);
        defer streams.unlock(&r.host);
        return s.pumps.items.len;
    }
};

test "viewers share one pump, each at its own rate; it stops with the last viewer" {
    var r: Rig = .{};
    try r.begin(null, null);
    defer r.end();
    var a = try r.call(11, "WatchSimulatorScreen", "{\"simulatorId\":\"6bba9fd8-efad-45b7-b9fc-30715804d2a1\"}");
    a.stream_items_json.deinit(testing.allocator);
    try testing.expect(r.waitFor("{\"id\":11,\"item\":{\"seq\":", 3));
    var b = try r.call(12, "WatchSimulatorScreen", "{\"simulatorId\":\"" ++ sim ++ "\",\"maxFps\":1}");
    // A viewer joining a running pump gets the newest frame right away.
    try testing.expectEqual(@as(usize, 1), b.stream_items_json.items.len);
    try testing.expect(std.mem.startsWith(u8, b.stream_items_json.items[0], "{\"seq\":"));
    b.stream_items_json.deinit(testing.allocator);
    try testing.expect(r.waitFor("{\"id\":11,\"item\":{\"seq\":", 8));
    try testing.expectEqual(@as(u32, 1), r.helper.streams_opened.load(.acquire));
    // A 1 fps viewer gets far fewer frames than a 15 fps one.
    try testing.expect(r.count("{\"id\":12,\"item\":") <= 2);
    // Frames are `{seq, jpeg}`, base64 JPEG bytes ("\xff\xd8frame-" → "/9hmcmFtZS").
    try testing.expect(r.count("\"jpeg\":\"/9hmcmFtZS") >= 8);
    {
        streams.lock(&r.host);
        r.host.cancelWatch(11);
        r.host.cancelWatch(12);
        streams.unlock(&r.host);
    }
    const deadline = discovery.nowMs(testing.io) + 4000;
    while (discovery.nowMs(testing.io) < deadline and (r.pumps() > 0 or r.helper.streams_active.load(.acquire) > 0))
        Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    try testing.expectEqual(@as(usize, 0), r.pumps());
    try testing.expectEqual(@as(u32, 0), r.helper.streams_active.load(.acquire));
}

test "a pump the helper refuses ends its viewers' streams" {
    var r: Rig = .{};
    const wrong: [64]u8 = @splat('w');
    try r.begin(wrong, null);
    defer r.end();
    var o = try r.call(21, "WatchSimulatorScreen", "{\"simulatorId\":\"" ++ sim ++ "\"}");
    o.stream_items_json.deinit(testing.allocator);
    try testing.expect(r.waitFor("{\"id\":21,\"done\":true}", 1));
    try testing.expectEqual(@as(usize, 0), r.count("\"item\""));
}

test "WatchSimulatorScreen and SimulatorInput refuse what they may not touch" {
    var r: Rig = .{};
    try r.begin(null, other);
    defer r.end();
    try r.expectErr("WatchSimulatorScreen", "{}", "missing field `simulatorId`");
    try r.expectErr("WatchSimulatorScreen", "{\"simulatorId\":\"../../etc\"}", "not a simulator id: \"../../etc\"");
    try r.expectErr("WatchSimulatorScreen", "{\"simulatorId\":\"" ++ sim ++ "\"}", "no iOS Simulator " ++ sim ++ " on this computer");
    try r.expectErr("SimulatorInput", "{\"simulatorId\":\"" ++ sim ++ "\",\"input\":{\"kind\":\"key\",\"key\":\"enter\"}}", "no iOS Simulator " ++ sim ++ " on this computer");
    try r.expectErr("SimulatorInput", "{\"simulatorId\":\"" ++ other ++ "\"}", "missing field `input`");
    try r.expectErr("SimulatorInput", "{\"simulatorId\":\"" ++ other ++ "\",\"input\":{\"kind\":\"key\",\"key\":\"f13\"}}", "unknown key \"f13\"");
    // Listed by nobody: a well-formed id that simctl doesn't know.
    var r2: Rig = .{};
    try r2.begin(null, null);
    defer r2.end();
    try r2.expectErr("WatchSimulatorScreen", "{\"simulatorId\":\"AAAAAAAA-2222-3333-4444-555555555555\"}", "no iOS Simulator AAAAAAAA-2222-3333-4444-555555555555 on this computer");
    r2.backend.helper = &r2.helper;
    const s = try serviceFor(&r2.host, null);
    s.config.backend.supported = false;
    try r2.expectErr("SimulatorInput", "{\"simulatorId\":\"" ++ sim ++ "\",\"input\":{\"kind\":\"key\",\"key\":\"up\"}}", unsupported);
}

test "SimulatorInput sends HID messages over one socket per simulator" {
    var r: Rig = .{};
    try r.begin(null, null);
    defer r.end();
    var o1 = try r.call(31, "SimulatorInput", "{\"simulatorId\":\"" ++ sim ++ "\",\"input\":{\"kind\":\"text\",\"text\":\"Hi\"}}");
    defer testing.allocator.free(o1.unary_json);
    try testing.expectEqualStrings("{\"ok\":true}", o1.unary_json);
    var o2 = try r.call(32, "SimulatorInput", "{\"simulatorId\":\"" ++ sim ++ "\",\"input\":{\"kind\":\"touch\",\"phase\":\"end\",\"x\":0.5,\"y\":2}}");
    defer testing.allocator.free(o2.unary_json);
    _ = &o1;
    _ = &o2;
    const want = [_][]const u8{
        "\x06{\"type\":\"down\",\"usage\":225}", "\x06{\"type\":\"down\",\"usage\":11}", "\x06{\"type\":\"up\",\"usage\":11}", "\x06{\"type\":\"up\",\"usage\":225}",
        "\x06{\"type\":\"down\",\"usage\":12}",  "\x06{\"type\":\"up\",\"usage\":12}",   "\x03{\"type\":\"end\",\"x\":0.5,\"y\":1.0}",
    };
    const deadline = discovery.nowMs(testing.io) + 3000;
    while (discovery.nowMs(testing.io) < deadline) {
        r.helper.mutex.lockUncancelable(testing.io);
        const got = r.helper.received.items.len;
        r.helper.mutex.unlock(testing.io);
        if (got >= want.len) break;
        Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    r.helper.mutex.lockUncancelable(testing.io);
    defer r.helper.mutex.unlock(testing.io);
    try testing.expectEqual(want.len, r.helper.received.items.len);
    for (want, r.helper.received.items) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(@as(u32, 1), r.helper.sockets_opened.load(.acquire));
}

fn writeInstall(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "tools/" ++ package ++ "/" ++ version ++ "/node_modules/" ++ package ++ "/vendor/serve-sim/dist");
    try tmp.dir.writeFile(io, .{ .sub_path = "tools/" ++ package ++ "/" ++ version ++ "/node_modules/" ++ package ++ "/vendor/serve-sim/dist/middleware.js", .data = "export {}" });
    var sbuf: [96]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "tools/" ++ package ++ "/" ++ version ++ "/.install-complete", .data = sentinelText(&sbuf) });
}

/// Stands in for Node running the host script: checks the token, prints a
/// line of noise and the ready line, and exits when stdin closes.
const fake_host =
    \\[ ${#HARNESS_SIM_TOKEN} -ge 32 ] || exit 2
    \\case "$HARNESS_SIM_STREAM" in *mjpegFps*) ;; *) exit 3 ;; esac
    \\echo 'helper noise'
    \\echo 'HARNESS_SIM_HOST {"port":4321}'
    \\cat > /dev/null
;

test "the helper host starts when installed, reports its port, and stops with its stdin" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const tools = try std.fs.path.join(a, &.{ root, "tools" });
    try tmp.dir.createDirPath(testing.io, "tools");
    const opts: Hub.Options = .{ .tools_dir = tools, .node = "/bin/sh", .script_text = fake_host, .ready_timeout_ms = 5_000 };
    switch (try Hub.start(testing.allocator, testing.io, a, opts)) {
        .err => |m| try testing.expectEqualStrings(not_set_up, m),
        .ok => return error.TestUnexpectedResult,
    }
    try writeInstall(&tmp);
    const h = switch (try Hub.start(testing.allocator, testing.io, a, opts)) {
        .err => |m| {
            std.debug.print("start failed: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
        .ok => |h| h,
    };
    try testing.expectEqual(@as(u16, 4321), h.endpoint.port);
    try testing.expect(h.alive());
    const pid_text = try tmp.dir.readFileAlloc(testing.io, "tools/simulator-hub.pid", a, .limited(64));
    try testing.expect(std.mem.startsWith(u8, pid_text, try std.fmt.allocPrint(a, "{d} ", .{h.pid})));
    const pid = h.pid;
    h.stop();
    try testing.expect(processStart(a, testing.io, pid) == null);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "tools/simulator-hub.pid", .{}));
    const log = try tmp.dir.readFileAlloc(testing.io, "tools/simulator-hub.log", a, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, log, "helper noise") != null);
}

test "a stale pid file never stops an unrelated process" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const script = try std.fs.path.join(a, &.{ root, host_script_name });
    const pid_file = try std.fs.path.join(a, &.{ root, "simulator-hub.pid" });

    var unrelated = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer {
        std.posix.kill(unrelated.id.?, .KILL) catch {};
        _ = unrelated.wait(io) catch {};
    }
    // `; :` keeps sh from exec'ing sleep, so the script stays in its command line.
    var host = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30; :", script }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    var host_reaped = false;
    defer if (!host_reaped) {
        std.posix.kill(host.id.?, .KILL) catch {};
        _ = host.wait(io) catch {};
    };
    Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    const u_start = processStart(a, io, unrelated.id.?).?;
    const h_start = processStart(a, io, host.id.?).?;

    try tmp.dir.writeFile(io, .{ .sub_path = "simulator-hub.pid", .data = try std.fmt.allocPrint(a, "{d} {d}\n", .{ unrelated.id.?, u_start }) });
    stopStale(a, io, pid_file, script);
    try testing.expect(processStart(a, io, unrelated.id.?) != null);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "simulator-hub.pid", .{}));

    try tmp.dir.writeFile(io, .{ .sub_path = "simulator-hub.pid", .data = try std.fmt.allocPrint(a, "{d} {d}\n", .{ host.id.?, h_start + 1 }) });
    stopStale(a, io, pid_file, script);
    try testing.expect(processStart(a, io, host.id.?) != null);

    for ([_][]const u8{ "1 0\n", "not a pid" }) |junk| {
        try tmp.dir.writeFile(io, .{ .sub_path = "simulator-hub.pid", .data = junk });
        stopStale(a, io, pid_file, script);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "simulator-hub.pid", .data = try std.fmt.allocPrint(a, "{d} {d}\n", .{ host.id.?, h_start }) });
    stopStale(a, io, pid_file, script);
    const term = try host.wait(io);
    host_reaped = true;
    try testing.expect(term != .exited or term.exited != 0);
}
