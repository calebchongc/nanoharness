//! The host end of the device relay: one outbound WebSocket to this device's
//! room on the edge (`/device/{id}/ws?role=host`), serving the engine's RPCs
//! to every remote client the room forwards (port of `HostRelay` in
//! `crates/rpc/src/device_room.rs`).
//!
//! - Each distinct client `connId` becomes a virtual connection: its RPC
//!   lines go to the service on the connection's own thread, and whatever the
//!   service writes back (WebSocket server frames, the same bytes a local
//!   socket would get) is re-wrapped as `{s:"rpc",k:"rpc",to:connId}` frames.
//! - Relay control frames (`" relay"`) tear down the named client's
//!   connection; `echo` frames go straight back to their sender; `nudge`
//!   frames go to the service and are acknowledged (`nudgeAck`, same payload)
//!   only when it reports durable admission and the nudge carries a token.
//! - Text `"ping"` every 10 s (answered by the room's auto-response); no
//!   inbound byte for 25 s drops the socket.
//! - The supervisor never gives up: quiet while signed out, reconnecting with
//!   the Rust backoff (250 ms after a session ends or a healthy one fails,
//!   doubling to `retry` after quick failures, plus up to 2 s of jitter).
//!   A newer host joining closes this socket with 4409; this host backs off
//!   and rejoins like any other dropped session.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const wss = @import("wss.zig");
const frame = @import("device_frame.zig");
const ws = @import("ws.zig");

pub const Token = union(enum) {
    /// A bearer the caller owns (freed by the relay).
    ok: []u8,
    signed_out,
    /// A token service that's down doesn't revoke the session; retry with backoff.
    unavailable,
};

/// What the relay serves. All callbacks may run on relay threads.
pub const Service = struct {
    ctx: *anyopaque,
    /// One RPC payload (ndjson, one or more lines) from `conn`. Replies and
    /// stream items are written to `conn.writer()` as WebSocket server frames.
    serve: *const fn (ctx: *anyopaque, conn: *VirtualConn, text: []const u8) void,
    /// `conn` is going away: release anything bound to its writer.
    closed: *const fn (ctx: *anyopaque, conn: *VirtualConn) void,
    /// A nudge for `chat_id`; true once durably admitted (then it is ACKed).
    nudge: *const fn (ctx: *anyopaque, chat_id: []const u8) bool,
    /// A fresh bearer, consulted on every dial.
    token: *const fn (ctx: *anyopaque, gpa: Allocator) Token,
};

pub const Config = struct {
    /// `http(s)://…`; rewritten to `ws(s)` for the socket.
    edge_url: []const u8,
    device_id: []const u8,
    /// Reconnect delay ceiling (`HostRelayConfig::retry`).
    retry_ms: u64 = 5_000,
    ping_interval_ms: u64 = 10_000,
    silence_lease_ms: u64 = 25_000,
    /// A session at least this long counts as healthy; its failure doesn't escalate.
    healthy_session_ms: u64 = 30_000,
    rejoin_min_ms: u64 = 250,
    jitter_max_ms: u64 = 2_000,
    connect_timeout_ms: u64 = wss.default_connect_timeout_ms,
    trust: wss.Trust = .system,
    /// Per-connection inbound backlog; a client past it is dropped.
    inbox_cap_bytes: usize = 64 * 1024 * 1024,
    /// Outbound backlog for the whole socket; past it the session is dropped.
    outbox_cap_bytes: usize = 64 * 1024 * 1024,
};

/// Delay before the next dial (pure; the supervisor's backoff rule).
pub const Outcome = enum { ended, failed, signed_out, token_unavailable };

pub fn nextDelayMs(cfg: Config, prev_delay_ms: u64, outcome: Outcome, session_ms: u64) u64 {
    return switch (outcome) {
        .ended => cfg.rejoin_min_ms,
        .failed => if (session_ms >= cfg.healthy_session_ms) cfg.rejoin_min_ms else @min(prev_delay_ms * 2, cfg.retry_ms),
        .signed_out => cfg.retry_ms,
        .token_unavailable => @min(prev_delay_ms * 2, cfg.retry_ms),
    };
}

fn nowMs(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// One remote client of the engine, as the service sees it.
pub const VirtualConn = struct {
    relay: *HostRelay,
    gen: u64,
    conn_id: []u8,
    /// The engine writes WebSocket server frames here.
    out: Io.Writer,
    out_lock: Io.Mutex = .init,
    /// Unparsed bytes of a frame still being written.
    pending: std.ArrayList(u8) = .empty,
    inbox: std.ArrayList([]u8) = .empty,
    inbox_bytes: usize = 0,
    inbox_lock: Io.Mutex = .init,
    inbox_cond: Io.Condition = .init,
    closed: std.atomic.Value(bool) = .init(false),
    wbuf: [16 * 1024]u8 = undefined,

    pub fn writer(self: *VirtualConn) *Io.Writer {
        return &self.out;
    }

    pub fn connId(self: *const VirtualConn) []const u8 {
        return self.conn_id;
    }

    fn create(relay: *HostRelay, gen: u64, conn_id: []const u8) !*VirtualConn {
        const gpa = relay.gpa;
        const self = try gpa.create(VirtualConn);
        errdefer gpa.destroy(self);
        self.* = .{
            .relay = relay,
            .gen = gen,
            .conn_id = try gpa.dupe(u8, conn_id),
            .out = undefined,
        };
        self.out = .{ .vtable = &.{ .drain = drain }, .buffer = &self.wbuf };
        return self;
    }

    fn destroy(self: *VirtualConn) void {
        const gpa = self.relay.gpa;
        for (self.inbox.items) |t| gpa.free(t);
        self.inbox.deinit(gpa);
        self.pending.deinit(gpa);
        gpa.free(self.conn_id);
        gpa.destroy(self);
    }

    /// Queues one inbound payload; false when the backlog is past its cap.
    fn push(self: *VirtualConn, text: []const u8) bool {
        const io = self.relay.io;
        const gpa = self.relay.gpa;
        self.inbox_lock.lockUncancelable(io);
        defer self.inbox_lock.unlock(io);
        if (self.inbox_bytes + text.len > self.relay.cfg.inbox_cap_bytes) return false;
        const copy = gpa.dupe(u8, text) catch return false;
        self.inbox.append(gpa, copy) catch {
            gpa.free(copy);
            return false;
        };
        self.inbox_bytes += text.len;
        self.inbox_cond.signal(io);
        return true;
    }

    fn close(self: *VirtualConn) void {
        const io = self.relay.io;
        self.inbox_lock.lockUncancelable(io);
        defer self.inbox_lock.unlock(io);
        self.closed.store(true, .release);
        self.inbox_cond.broadcast(io);
    }

    /// Serves queued payloads in order until closed, then releases the
    /// connection (the thread owns it from here).
    fn run(self: *VirtualConn) void {
        const relay = self.relay;
        const io = relay.io;
        const gpa = relay.gpa;
        while (true) {
            self.inbox_lock.lockUncancelable(io);
            while (self.inbox.items.len == 0 and !self.closed.load(.acquire)) {
                self.inbox_cond.waitUncancelable(io, &self.inbox_lock);
            }
            if (self.closed.load(.acquire)) {
                self.inbox_lock.unlock(io);
                break;
            }
            const text = self.inbox.orderedRemove(0);
            self.inbox_bytes -= text.len;
            self.inbox_lock.unlock(io);
            defer gpa.free(text);
            relay.service.serve(relay.service.ctx, self, text);
        }
        relay.service.closed(relay.service.ctx, self);
        self.destroy();
        relay.release();
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *VirtualConn = @alignCast(@fieldParentPtr("out", w));
        const io = self.relay.io;
        const gpa = self.relay.gpa;
        self.out_lock.lockUncancelable(io);
        defer self.out_lock.unlock(io);
        var consumed: usize = 0;
        const keep = !self.closed.load(.acquire);
        if (keep) self.pending.appendSlice(gpa, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        for (data[0 .. data.len - 1]) |part| {
            if (keep) self.pending.appendSlice(gpa, part) catch return error.WriteFailed;
            consumed += part.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            if (keep) self.pending.appendSlice(gpa, last) catch return error.WriteFailed;
            consumed += last.len;
        }
        if (keep) self.forwardFrames();
        return consumed;
    }

    /// Re-wraps each complete WebSocket frame in `pending` as a relay frame.
    fn forwardFrames(self: *VirtualConn) void {
        var off: usize = 0;
        const buf = self.pending.items;
        while (true) {
            const parsed = parseServerFrame(buf[off..]) orelse break;
            if (parsed.op == .text or parsed.op == .binary) {
                self.relay.sendRpc(self.gen, self.conn_id, parsed.payload);
            }
            off += parsed.total;
        }
        if (off > 0) {
            std.mem.copyForwards(u8, buf[0 .. buf.len - off], buf[off..]);
            self.pending.shrinkRetainingCapacity(buf.len - off);
        }
    }
};

const ParsedFrame = struct { op: ws.Opcode, payload: []const u8, total: usize };

/// One complete unmasked server frame at the start of `buf`, or null.
fn parseServerFrame(buf: []const u8) ?ParsedFrame {
    if (buf.len < 2) return null;
    const op: ws.Opcode = @enumFromInt(@as(u4, @truncate(buf[0] & 0x0f)));
    var len: u64 = buf[1] & 0x7f;
    var hdr: usize = 2;
    if (len == 126) {
        if (buf.len < 4) return null;
        len = std.mem.readInt(u16, buf[2..4], .big);
        hdr = 4;
    } else if (len == 127) {
        if (buf.len < 10) return null;
        len = std.mem.readInt(u64, buf[2..10], .big);
        hdr = 10;
    }
    if (buf.len - hdr < len) return null;
    const n: usize = @intCast(len);
    return .{ .op = op, .payload = buf[hdr .. hdr + n], .total = hdr + n };
}

/// Frames waiting for the socket writer.
const Outbox = struct {
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    items: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    closed: bool = true,
    gen: u64 = 0,
};

pub const HostRelay = struct {
    gpa: Allocator,
    io: Io,
    cfg: Config,
    service: Service,
    edge_url: []u8,
    device_id: []u8,
    /// The owner's reference plus one per live virtual connection.
    refs: std.atomic.Value(u32) = .init(1),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Bumped by `wake` (sign-in, token change, network back).
    wake_seq: std.atomic.Value(u64) = .init(0),
    supervisor: ?std.Thread = null,
    outbox: Outbox = .{},
    /// The live socket, while a session runs (guarded by `sock_lock`).
    sock: ?*wss.Conn = null,
    sock_lock: Io.Mutex = .init,
    conns: std.StringHashMapUnmanaged(*VirtualConn) = .empty,
    /// Counters for tests and status.
    sessions_started: std.atomic.Value(u32) = .init(0),
    nudges_acked: std.atomic.Value(u32) = .init(0),
    last_close_code: std.atomic.Value(u16) = .init(0),

    pub fn start(gpa: Allocator, io: Io, cfg: Config, service: Service) !*HostRelay {
        const self = try gpa.create(HostRelay);
        errdefer gpa.destroy(self);
        const edge = try gpa.dupe(u8, cfg.edge_url);
        errdefer gpa.free(edge);
        const dev = try gpa.dupe(u8, cfg.device_id);
        errdefer gpa.free(dev);
        self.* = .{ .gpa = gpa, .io = io, .cfg = cfg, .service = service, .edge_url = edge, .device_id = dev };
        self.cfg.edge_url = edge;
        self.cfg.device_id = dev;
        self.supervisor = try std.Thread.spawn(.{}, supervise, .{self});
        return self;
    }

    /// Ends the session and the supervisor. Virtual connections still inside
    /// a request finish it on their own threads; the last one frees the relay.
    pub fn stop(self: *HostRelay) void {
        self.stopping.store(true, .release);
        self.shutSocket();
        if (self.supervisor) |t| t.join();
        self.supervisor = null;
        // Give connections a moment to finish; one still inside a long
        // request (a turn) frees the relay itself when it ends.
        const until = nowMs(self.io) + stop_grace_ms;
        while (self.refs.load(.acquire) > 1 and nowMs(self.io) < until) {
            Io.sleep(self.io, .fromMilliseconds(5), .awake) catch break;
        }
        self.release();
    }

    const stop_grace_ms = 2_000;

    /// Redial now instead of waiting out the backoff (credentials changed,
    /// the machine woke, the network came back).
    pub fn wake(self: *HostRelay) void {
        _ = self.wake_seq.fetchAdd(1, .acq_rel);
    }

    fn release(self: *HostRelay) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.outbox.items.deinit(self.gpa);
        self.conns.deinit(self.gpa);
        self.gpa.free(self.edge_url);
        self.gpa.free(self.device_id);
        self.gpa.destroy(self);
    }

    fn shutSocket(self: *HostRelay) void {
        self.sock_lock.lockUncancelable(self.io);
        defer self.sock_lock.unlock(self.io);
        if (self.sock) |s| s.shutdown();
    }

    fn jitterMs(self: *HostRelay) u64 {
        if (self.cfg.jitter_max_ms == 0) return 0;
        var b: [8]u8 = undefined;
        self.io.random(&b);
        return std.mem.readInt(u64, &b, .little) % self.cfg.jitter_max_ms;
    }

    fn supervise(self: *HostRelay) void {
        var delay = self.cfg.rejoin_min_ms;
        while (!self.stopping.load(.acquire)) {
            switch (self.service.token(self.service.ctx, self.gpa)) {
                .ok => |token| {
                    const started = nowMs(self.io);
                    const ok = self.session(token);
                    self.gpa.free(token);
                    const elapsed: u64 = @intCast(@max(0, nowMs(self.io) - started));
                    if (ok) {
                        std.log.info("device-room: host session ended; reconnecting", .{});
                    } else {
                        std.log.warn("device-room: host session failed", .{});
                    }
                    delay = nextDelayMs(self.cfg, delay, if (ok) .ended else .failed, elapsed);
                },
                .signed_out => delay = nextDelayMs(self.cfg, delay, .signed_out, 0),
                .unavailable => {
                    std.log.warn("device-room: token unavailable; retrying", .{});
                    delay = nextDelayMs(self.cfg, delay, .token_unavailable, 0);
                },
            }
            // Only wakes during this wait cut it short.
            const seen = self.wake_seq.load(.acquire);
            const until = nowMs(self.io) + @as(i64, @intCast(delay + self.jitterMs()));
            while (!self.stopping.load(.acquire) and nowMs(self.io) < until) {
                if (self.wake_seq.load(.acquire) != seen) {
                    delay = self.cfg.rejoin_min_ms;
                    break;
                }
                Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
            }
        }
    }

    /// One relay session: connect as host and serve until the socket drops.
    /// False when the room was unreachable (the dial failed).
    fn session(self: *HostRelay, token: []const u8) bool {
        const gpa = self.gpa;
        const base = frame.deviceRoomWsUrl(gpa, self.edge_url, self.device_id, "host", null, token) catch return false;
        defer gpa.free(base);
        const url = std.mem.concat(gpa, u8, &.{ base, "&nudgeAck=1" }) catch return false;
        defer gpa.free(url);
        const conn = wss.connectUrl(gpa, self.io, url, .{
            .connect_timeout_ms = self.cfg.connect_timeout_ms,
            .lease_ms = self.cfg.silence_lease_ms,
            .trust = self.cfg.trust,
        }) catch |err| {
            std.log.warn("device-room: unreachable: {t}", .{err});
            return false;
        };
        std.log.info("device-room: host connected", .{});
        _ = self.sessions_started.fetchAdd(1, .acq_rel);

        self.sock_lock.lockUncancelable(self.io);
        self.sock = conn;
        const stop_now = self.stopping.load(.acquire);
        self.sock_lock.unlock(self.io);
        if (stop_now) conn.shutdown();

        const gen = self.openOutbox();
        var writer_thread = std.Thread.spawn(.{}, writeLoop, .{ self, conn }) catch null;
        var pinger_thread = std.Thread.spawn(.{}, pingLoop, .{ self, conn, gen }) catch null;
        if (writer_thread == null or pinger_thread == null) conn.shutdown();

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        while (true) {
            const op = conn.readMessage(&msg) catch |err| {
                if (err == error.PeerClosed) {
                    if (conn.peer_close_code) |code| self.last_close_code.store(code, .release);
                }
                break;
            };
            if (op != .binary) continue; // the room's text "pong"
            self.handleFrame(gen, msg.items);
        }

        conn.shutdown();
        self.closeOutbox();
        if (writer_thread) |*t| t.join();
        if (pinger_thread) |*t| t.join();
        self.dropAllConns();
        self.sock_lock.lockUncancelable(self.io);
        self.sock = null;
        self.sock_lock.unlock(self.io);
        conn.deinit();
        return true;
    }

    fn pingLoop(self: *HostRelay, conn: *wss.Conn, gen: u64) void {
        var next = nowMs(self.io) + @as(i64, @intCast(self.cfg.ping_interval_ms));
        while (self.sessionLive(gen)) {
            Io.sleep(self.io, .fromMilliseconds(10), .awake) catch return;
            if (nowMs(self.io) < next) continue;
            next = nowMs(self.io) + @as(i64, @intCast(self.cfg.ping_interval_ms));
            conn.sendText("ping") catch {
                conn.shutdown();
                return;
            };
        }
    }

    fn sessionLive(self: *HostRelay, gen: u64) bool {
        self.outbox.lock.lockUncancelable(self.io);
        defer self.outbox.lock.unlock(self.io);
        return !self.outbox.closed and self.outbox.gen == gen;
    }

    fn openOutbox(self: *HostRelay) u64 {
        const ob = &self.outbox;
        ob.lock.lockUncancelable(self.io);
        defer ob.lock.unlock(self.io);
        ob.gen += 1;
        ob.closed = false;
        return ob.gen;
    }

    fn closeOutbox(self: *HostRelay) void {
        const ob = &self.outbox;
        ob.lock.lockUncancelable(self.io);
        defer ob.lock.unlock(self.io);
        ob.closed = true;
        for (ob.items.items) |f| self.gpa.free(f);
        ob.items.clearRetainingCapacity();
        ob.bytes = 0;
        ob.cond.broadcast(self.io);
    }

    /// Queues an encoded frame for this session; dropped for an old session.
    fn enqueue(self: *HostRelay, gen: u64, bytes: []u8) void {
        const ob = &self.outbox;
        ob.lock.lockUncancelable(self.io);
        defer ob.lock.unlock(self.io);
        if (ob.closed or ob.gen != gen) {
            self.gpa.free(bytes);
            return;
        }
        if (ob.bytes + bytes.len > self.cfg.outbox_cap_bytes) {
            // A socket this far behind is stalled; drop the session (its
            // clients see host_closed and retry) rather than block the engine.
            self.gpa.free(bytes);
            std.log.warn("device-room: outbound backlog past cap; dropping session", .{});
            self.shutSocket();
            return;
        }
        ob.items.append(self.gpa, bytes) catch {
            self.gpa.free(bytes);
            self.shutSocket();
            return;
        };
        ob.bytes += bytes.len;
        ob.cond.signal(self.io);
    }

    fn writeLoop(self: *HostRelay, conn: *wss.Conn) void {
        const ob = &self.outbox;
        while (true) {
            ob.lock.lockUncancelable(self.io);
            while (ob.items.items.len == 0 and !ob.closed) ob.cond.waitUncancelable(self.io, &ob.lock);
            if (ob.closed) {
                ob.lock.unlock(self.io);
                return;
            }
            const bytes = ob.items.orderedRemove(0);
            ob.bytes -= bytes.len;
            ob.lock.unlock(self.io);
            defer self.gpa.free(bytes);
            conn.sendBinary(bytes) catch {
                conn.shutdown();
                return;
            };
        }
    }

    /// Wraps an RPC reply for `conn_id` and queues it.
    fn sendRpc(self: *HostRelay, gen: u64, conn_id: []const u8, payload: []const u8) void {
        const bytes = frame.encode(self.gpa, .{ .s = frame.rpc_kind, .k = frame.rpc_kind, .to = conn_id }, payload) catch return;
        self.enqueue(gen, bytes);
    }

    fn handleFrame(self: *HostRelay, gen: u64, bytes: []const u8) void {
        var f = frame.decode(self.gpa, bytes) catch {
            std.log.warn("device-room: malformed frame; skipping", .{});
            return;
        };
        defer f.deinit();
        const h = f.header;
        if (std.mem.eql(u8, h.k, frame.relay_kind)) {
            // A client went away (`client_closed` carries `from`; a bounced
            // `client_gone` carries `to`): tear down that connection.
            if (h.from orelse h.to) |conn_id| self.dropConn(conn_id);
            return;
        }
        if (std.mem.eql(u8, h.k, frame.echo_kind)) {
            if (h.from) |from| {
                const reply = frame.encode(self.gpa, .{ .s = frame.echo_kind, .k = frame.echo_kind, .to = from }, f.payload) catch return;
                self.enqueue(gen, reply);
            }
            return;
        }
        if (std.mem.eql(u8, h.k, frame.nudge_kind) and h.from == null) {
            self.handleNudge(gen, f.payload);
            return;
        }
        if (!std.mem.eql(u8, h.k, frame.rpc_kind)) return; // future stream kinds (term, tunnel)
        const from = h.from orelse return;
        const vc = self.conns.get(from) orelse blk: {
            const created = VirtualConn.create(self, gen, from) catch return;
            self.conns.put(self.gpa, created.conn_id, created) catch {
                created.destroy();
                return;
            };
            _ = self.refs.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, VirtualConn.run, .{created}) catch {
                _ = self.conns.remove(created.conn_id);
                created.destroy();
                _ = self.refs.fetchSub(1, .acq_rel);
                return;
            };
            t.detach();
            break :blk created;
        };
        if (!vc.push(f.payload)) {
            std.log.warn("device-room: client backlog past cap; dropping its connection", .{});
            self.dropConn(from);
        }
    }

    fn handleNudge(self: *HostRelay, gen: u64, payload: []const u8) void {
        var parsed = json.parseFromSlice(json.Value, self.gpa, payload, .{}) catch {
            std.log.warn("device-room: malformed nudge; ignoring", .{});
            return;
        };
        defer parsed.deinit();
        const obj = if (parsed.value == .object) parsed.value.object else {
            std.log.warn("device-room: malformed nudge; ignoring", .{});
            return;
        };
        const chat = obj.get("chatId") orelse {
            std.log.warn("device-room: malformed nudge; ignoring", .{});
            return;
        };
        if (chat != .string) return;
        const has_token = if (obj.get("token")) |t| t == .string else false;
        // Acknowledge durable admission, never mere receipt. Old edges send
        // no token and need no ACK.
        if (self.service.nudge(self.service.ctx, chat.string) and has_token) {
            const ack = frame.encode(self.gpa, .{ .s = chat.string, .k = frame.nudge_ack_kind }, payload) catch return;
            self.enqueue(gen, ack);
            _ = self.nudges_acked.fetchAdd(1, .acq_rel);
        }
    }

    fn dropConn(self: *HostRelay, conn_id: []const u8) void {
        const kv = self.conns.fetchRemove(conn_id) orelse return;
        kv.value.close();
    }

    fn dropAllConns(self: *HostRelay) void {
        var it = self.conns.valueIterator();
        while (it.next()) |vc| vc.*.close();
        self.conns.clearRetainingCapacity();
    }

};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const testkit = @import("wss_testkit.zig");

test "device relay: reconnect backoff follows the Rust host" {
    const cfg: Config = .{ .edge_url = "", .device_id = "" };
    try testing.expectEqual(@as(u64, 250), nextDelayMs(cfg, 4_000, .ended, 1));
    try testing.expectEqual(@as(u64, 500), nextDelayMs(cfg, 250, .failed, 1_000));
    try testing.expectEqual(@as(u64, 5_000), nextDelayMs(cfg, 4_000, .failed, 1_000));
    try testing.expectEqual(@as(u64, 250), nextDelayMs(cfg, 4_000, .failed, 30_000));
    try testing.expectEqual(@as(u64, 5_000), nextDelayMs(cfg, 250, .signed_out, 0));
    try testing.expectEqual(@as(u64, 1_000), nextDelayMs(cfg, 500, .token_unavailable, 0));
}

test "device relay: server frames written by the engine re-wrap as relay frames" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const ws_server = @import("ws_server.zig");
    try ws_server.writeServerFrame(&w, .text, "{\"id\":1,\"ok\":{}}");
    const xs: [200]u8 = @splat('x');
    try ws_server.writeServerFrame(&w, .text, &xs);
    const bytes = w.buffered();
    const a = parseServerFrame(bytes).?;
    try testing.expectEqualStrings("{\"id\":1,\"ok\":{}}", a.payload);
    const b = parseServerFrame(bytes[a.total..]).?;
    try testing.expectEqual(@as(usize, 200), b.payload.len);
    try testing.expect(parseServerFrame(bytes[a.total .. a.total + 3]) == null);
}

/// A service whose RPC answers `{"id":N,"ok":{"echo":<line>}}` per line.
const EchoService = struct {
    nudges: std.atomic.Value(u32) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    admit: bool = true,
    token_text: []const u8 = "test-user",

    fn service(self: *EchoService) Service {
        return .{ .ctx = self, .serve = serve, .closed = closed, .nudge = nudge, .token = token };
    }

    fn serve(_: *anyopaque, conn: *VirtualConn, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var parsed = json.parseFromSlice(json.Value, testing.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const id = parsed.value.object.get("id").?.integer;
            var tmp: [512]u8 = undefined;
            const reply = std.fmt.bufPrint(&tmp, "{{\"id\":{d},\"ok\":{{\"conn\":\"{s}\"}}}}", .{ id, conn.connId() }) catch continue;
            @import("ws_server.zig").writeServerFrame(conn.writer(), .text, reply) catch {};
            conn.writer().flush() catch {};
        }
    }

    fn closed(ctx: *anyopaque, _: *VirtualConn) void {
        const self: *EchoService = @ptrCast(@alignCast(ctx));
        _ = self.closes.fetchAdd(1, .acq_rel);
    }

    fn nudge(ctx: *anyopaque, _: []const u8) bool {
        const self: *EchoService = @ptrCast(@alignCast(ctx));
        _ = self.nudges.fetchAdd(1, .acq_rel);
        return self.admit;
    }

    fn token(ctx: *anyopaque, gpa: Allocator) Token {
        const self: *EchoService = @ptrCast(@alignCast(ctx));
        return .{ .ok = gpa.dupe(u8, self.token_text) catch return .unavailable };
    }
};

fn sendFrame(peer: *testkit.Peer, h: frame.Header, payload: []const u8) !void {
    const bytes = try frame.encode(peer.gpa, h, payload);
    defer peer.gpa.free(bytes);
    try peer.writeFrame(.binary, bytes);
}

/// Reads binary relay frames, skipping the host's text pings.
fn readRelayFrame(peer: *testkit.Peer) !frame.Frame {
    while (true) {
        const m = try peer.readMessage();
        if (m.op == .text) {
            peer.gpa.free(m.payload);
            continue;
        }
        // The frame borrows its payload from the bytes; keep them with it.
        defer peer.gpa.free(m.payload);
        var f = try frame.decode(peer.gpa, m.payload);
        const payload = try f.arena.allocator().dupe(u8, f.payload);
        f.payload = payload;
        return f;
    }
}

test "device relay: host dial, RPC per connId, echo, nudge ACK and client teardown" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 30_000);
    defer deadline.finish();

    const Room = struct {
        fn run(peer: *testkit.Peer) anyerror!void {
            // The host's dial: role=host with nudgeAck, token as a bearer header.
            try testing.expectEqualStrings("/device/dev-a/ws?role=host&nudgeAck=1", peer.request_target);
            try testing.expectEqualStrings("Bearer test-user", peer.authorization.?);
            // Two clients call; each gets its own answer, routed back by `to`.
            try sendFrame(peer, .{ .s = "rpc", .k = "rpc", .from = "c1" }, "{\"id\":1,\"method\":\"X\"}\n");
            try sendFrame(peer, .{ .s = "rpc", .k = "rpc", .from = "c2" }, "{\"id\":7,\"method\":\"X\"}");
            var seen_c1 = false;
            var seen_c2 = false;
            while (!(seen_c1 and seen_c2)) {
                var f = try readRelayFrame(peer);
                defer f.deinit();
                try testing.expectEqualStrings("rpc", f.header.k);
                if (std.mem.eql(u8, f.header.to.?, "c1")) {
                    try testing.expectEqualStrings("{\"id\":1,\"ok\":{\"conn\":\"c1\"}}", f.payload);
                    seen_c1 = true;
                } else {
                    try testing.expectEqualStrings("c2", f.header.to.?);
                    try testing.expectEqualStrings("{\"id\":7,\"ok\":{\"conn\":\"c2\"}}", f.payload);
                    seen_c2 = true;
                }
            }
            // Echo goes straight back to its sender with the same payload.
            try sendFrame(peer, .{ .s = "echo", .k = "echo", .from = "c1" }, "e1");
            {
                var f = try readRelayFrame(peer);
                defer f.deinit();
                try testing.expectEqualStrings("echo", f.header.k);
                try testing.expectEqualStrings("c1", f.header.to.?);
                try testing.expectEqualStrings("e1", f.payload);
            }
            // A nudge with a token is ACKed with the same payload.
            const nudge_payload = "{\"chatId\":\"chat-1\",\"token\":\"t-1\"}";
            try sendFrame(peer, .{ .s = "chat-1", .k = "nudge" }, nudge_payload);
            {
                var f = try readRelayFrame(peer);
                defer f.deinit();
                try testing.expectEqualStrings("nudgeAck", f.header.k);
                try testing.expectEqualStrings("chat-1", f.header.s);
                try testing.expectEqualStrings(nudge_payload, f.payload);
            }
            // client_closed tears down c1's connection; c2 keeps working.
            try sendFrame(peer, .{ .s = "", .k = " relay", .from = "c1" }, "{\"error\":\"client_closed\"}");
            try sendFrame(peer, .{ .s = "rpc", .k = "rpc", .from = "c2" }, "{\"id\":8}");
            {
                var f = try readRelayFrame(peer);
                defer f.deinit();
                try testing.expectEqualStrings("c2", f.header.to.?);
                try testing.expectEqualStrings("{\"id\":8,\"ok\":{\"conn\":\"c2\"}}", f.payload);
            }
            // A malformed frame is skipped, not fatal.
            try peer.writeFrame(.binary, &.{0x85});
            try sendFrame(peer, .{ .s = "rpc", .k = "rpc", .from = "c2" }, "{\"id\":9}");
            {
                var f = try readRelayFrame(peer);
                defer f.deinit();
                try testing.expectEqualStrings("{\"id\":9,\"ok\":{\"conn\":\"c2\"}}", f.payload);
            }
        }
    };
    const room = try testkit.Server.start(gpa, io, Room.run);
    defer room.stop();

    var svc: EchoService = .{};
    const edge = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{room.port});
    defer gpa.free(edge);
    const relay = try HostRelay.start(gpa, io, .{ .edge_url = edge, .device_id = "dev-a", .jitter_max_ms = 0 }, svc.service());
    errdefer relay.stop();
    try room.join();
    // c1 was torn down by client_closed.
    while (svc.closes.load(.acquire) < 1) Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    try testing.expectEqual(@as(u32, 1), relay.nudges_acked.load(.acquire));
    relay.stop();
    try testing.expectEqual(@as(u32, 1), svc.nudges.load(.acquire));
    try testing.expectEqual(@as(u32, 2), svc.closes.load(.acquire));
}

test "device relay: a nudge without admission is not ACKed" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 30_000);
    defer deadline.finish();
    const Room = struct {
        fn run(peer: *testkit.Peer) anyerror!void {
            try sendFrame(peer, .{ .s = "chat-1", .k = "nudge" }, "{\"chatId\":\"chat-1\",\"token\":\"t-1\"}");
            // Then an echo: the next frame back must be the echo, not an ACK.
            try sendFrame(peer, .{ .s = "echo", .k = "echo", .from = "c1" }, "");
            var f = try readRelayFrame(peer);
            defer f.deinit();
            try testing.expectEqualStrings("echo", f.header.k);
        }
    };
    const room = try testkit.Server.start(gpa, io, Room.run);
    defer room.stop();
    var svc: EchoService = .{ .admit = false };
    const edge = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{room.port});
    defer gpa.free(edge);
    const relay = try HostRelay.start(gpa, io, .{ .edge_url = edge, .device_id = "dev-a", .jitter_max_ms = 0 }, svc.service());
    errdefer relay.stop();
    try room.join();
    try testing.expectEqual(@as(u32, 0), relay.nudges_acked.load(.acquire));
    relay.stop();
    try testing.expectEqual(@as(u32, 1), svc.nudges.load(.acquire));
}

test "device relay: pings on the interval, and a dropped socket (4409) is redialed" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 30_000);
    defer deadline.finish();
    const Room = struct {
        var sessions: std.atomic.Value(u32) = .init(0);
        fn run(peer: *testkit.Peer) anyerror!void {
            const n = sessions.fetchAdd(1, .acq_rel);
            if (n == 0) {
                // The host's keepalive is a text "ping".
                const m = try peer.readMessage();
                defer peer.gpa.free(m.payload);
                try testing.expectEqual(ws.Opcode.text, m.op);
                try testing.expectEqualStrings("ping", m.payload);
                try peer.writeFrame(.text, "pong");
                // Superseded by a newer host.
                try peer.writeFrame(.close, &.{ 0x11, 0x39 });
                if (peer.readFrame()) |echo| {
                    var e = echo;
                    e.deinit();
                } else |_| {}
                return;
            }
            // The redial: still serves RPC.
            try sendFrame(peer, .{ .s = "rpc", .k = "rpc", .from = "c9" }, "{\"id\":3}");
            var f = try readRelayFrame(peer);
            defer f.deinit();
            try testing.expectEqualStrings("{\"id\":3,\"ok\":{\"conn\":\"c9\"}}", f.payload);
        }
    };
    const room = try testkit.Server.startMany(gpa, io, Room.run, 2);
    defer room.stop();
    var svc: EchoService = .{};
    const edge = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{room.port});
    defer gpa.free(edge);
    const t0 = nowMs(io);
    const relay = try HostRelay.start(gpa, io, .{
        .edge_url = edge,
        .device_id = "dev-a",
        .ping_interval_ms = 100,
        .jitter_max_ms = 0,
    }, svc.service());
    errdefer relay.stop();
    try room.join();
    const elapsed = nowMs(io) - t0;
    try testing.expectEqual(@as(u16, 4409), relay.last_close_code.load(.acquire));
    try testing.expect(relay.sessions_started.load(.acquire) >= 2);
    relay.stop();
    // Ping after ~100 ms, rejoin after 250 ms: well under the 5 s retry ceiling.
    try testing.expect(elapsed < 4_000);
}

test "device relay: a silent room trips the lease and the host redials" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 30_000);
    defer deadline.finish();
    const Room = struct {
        var sessions: std.atomic.Value(u32) = .init(0);
        fn run(peer: *testkit.Peer) anyerror!void {
            if (sessions.fetchAdd(1, .acq_rel) == 0) {
                // Read (pings) but never answer: the host must give up on us.
                while (true) {
                    const m = peer.readMessage() catch return;
                    peer.gpa.free(m.payload);
                }
            }
            // The redial is live: it answers RPC.
            try sendFrame(peer, .{ .s = "rpc", .k = "rpc", .from = "c1" }, "{\"id\":1}");
            var f = try readRelayFrame(peer);
            f.deinit();
        }
    };
    const room = try testkit.Server.startMany(gpa, io, Room.run, 2);
    defer room.stop();
    var svc: EchoService = .{};
    const edge = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{room.port});
    defer gpa.free(edge);
    const relay = try HostRelay.start(gpa, io, .{
        .edge_url = edge,
        .device_id = "dev-a",
        .ping_interval_ms = 50,
        .silence_lease_ms = 300,
        .jitter_max_ms = 0,
    }, svc.service());
    errdefer relay.stop();
    try room.join();
    try testing.expect(relay.sessions_started.load(.acquire) >= 2);
    relay.stop();
}

test "device relay: signed out means no dial" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 15_000);
    defer deadline.finish();
    const Out = struct {
        fn token(_: *anyopaque, _: Allocator) Token {
            return .signed_out;
        }
    };
    var svc: EchoService = .{};
    var service = svc.service();
    service.token = Out.token;
    const mute = try testkit.MuteServer.start(io);
    defer mute.stop();
    const edge = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{mute.port});
    defer gpa.free(edge);
    const relay = try HostRelay.start(gpa, io, .{ .edge_url = edge, .device_id = "dev-a", .retry_ms = 50 }, service);
    errdefer relay.stop();
    Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    try testing.expectEqual(@as(u32, 0), relay.sessions_started.load(.acquire));
    relay.stop();
}
