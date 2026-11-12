//! Test-only stand-in for the edge's `DeviceRoom` (`edge/src/device-room.ts`),
//! on 127.0.0.1, with the same routing rules:
//! - dev auth: the bearer is the user id; the first host claims the room and
//!   later joins by another user get 403;
//! - a new host closes the previous one with 4409;
//! - client frames go to the host stamped `from = connId`, or bounce
//!   `host_offline` when there is no host;
//! - host frames route by `to` (routing keys stripped), or bounce
//!   `client_gone` to the host; `nudgeAck` frames retire a nudge;
//! - a client closing sends the host `client_closed`; the host closing sends
//!   every client `host_closed`;
//! - text "ping" is answered "pong" (the room's auto-response).
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const testkit = @import("wss_testkit.zig");
const frame = @import("device_frame.zig");

const Member = struct {
    peer: *testkit.Peer,
    host: bool,
    conn_id: []u8,
    device: []u8,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub const Room = struct {
    gpa: Allocator,
    io: Io,
    listener: net.Server,
    port: u16,
    lock: Io.Mutex = .init,
    owners: std.StringHashMapUnmanaged([]u8) = .empty,
    members: std.ArrayList(*Member) = .empty,
    accept_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    acked: std.atomic.Value(u32) = .init(0),
    /// Set when the accept loop has returned.
    accept_exited: Io.Event = .unset,

    pub fn start(gpa: Allocator, io: Io) !*Room {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        var listener = try addr.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        const r = try gpa.create(Room);
        r.* = .{ .gpa = gpa, .io = io, .listener = listener, .port = listener.socket.address.getPort() };
        r.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{r});
        return r;
    }

    pub fn stop(r: *Room) void {
        r.stopping.store(true, .release);
        // A listening socket's shutdown does not wake `accept` on macOS.
        if (r.accept_thread) |t| @import("test_server_stop.zig").stopAcceptLoop(r.io, r.port, &r.accept_exited, t);
        r.accept_thread = null;
        r.lock.lockUncancelable(r.io);
        for (r.members.items) |m| m.peer.shutdown();
        r.lock.unlock(r.io);
        // Member threads remove themselves; wait for each.
        while (true) {
            r.lock.lockUncancelable(r.io);
            const m = r.members.pop();
            r.lock.unlock(r.io);
            const member = m orelse break;
            if (member.thread) |t| t.join();
            r.freeMember(member);
        }
        var it = r.owners.iterator();
        while (it.next()) |e| {
            r.gpa.free(e.key_ptr.*);
            r.gpa.free(e.value_ptr.*);
        }
        r.owners.deinit(r.gpa);
        r.members.deinit(r.gpa);
        r.listener.deinit(r.io);
        r.gpa.destroy(r);
    }

    fn freeMember(r: *Room, m: *Member) void {
        m.peer.stream.close(r.io);
        m.peer.deinit();
        r.gpa.destroy(m.peer);
        r.gpa.free(m.conn_id);
        r.gpa.free(m.device);
        r.gpa.destroy(m);
    }

    pub fn hostOf(r: *Room, device: []const u8) ?*Member {
        for (r.members.items) |m| {
            if (m.host and !m.done.load(.acquire) and std.mem.eql(u8, m.device, device)) return m;
        }
        return null;
    }

    pub fn waitForHost(r: *Room, device: []const u8, ms: i64) !void {
        const end = Io.Clock.awake.now(r.io).toMilliseconds() + ms;
        while (Io.Clock.awake.now(r.io).toMilliseconds() < end) {
            r.lock.lockUncancelable(r.io);
            const found = r.hostOf(device) != null;
            r.lock.unlock(r.io);
            if (found) return;
            Io.sleep(r.io, .fromMilliseconds(5), .awake) catch {};
        }
        return error.Timeout;
    }

    pub fn waitForNoHost(r: *Room, device: []const u8, ms: i64) !void {
        const end = Io.Clock.awake.now(r.io).toMilliseconds() + ms;
        while (Io.Clock.awake.now(r.io).toMilliseconds() < end) {
            r.lock.lockUncancelable(r.io);
            const found = r.hostOf(device) != null;
            r.lock.unlock(r.io);
            if (!found) return;
            Io.sleep(r.io, .fromMilliseconds(5), .awake) catch {};
        }
        return error.Timeout;
    }

    /// Delivers a durable nudge `{chatId, token}` to the device's host.
    pub fn nudge(r: *Room, device: []const u8, chat_id: []const u8, token: []const u8) !void {
        const payload = try std.fmt.allocPrint(r.gpa, "{{\"chatId\":\"{s}\",\"token\":\"{s}\"}}", .{ chat_id, token });
        defer r.gpa.free(payload);
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        const host = r.hostOf(device) orelse return error.NoHost;
        deliver(r.gpa, host, .{ .s = chat_id, .k = frame.nudge_kind }, payload);
    }

    fn acceptLoop(r: *Room) void {
        defer r.accept_exited.set(r.io);
        while (!r.stopping.load(.acquire)) {
            const stream = r.listener.accept(r.io) catch return;
            r.join(stream) catch stream.close(r.io);
        }
    }

    fn join(r: *Room, stream: net.Stream) !void {
        const peer = try r.gpa.create(testkit.Peer);
        errdefer r.gpa.destroy(peer);
        peer.* = .{ .gpa = r.gpa, .io = r.io, .stream = stream, .rd = undefined, .wr = undefined };
        peer.rd = net.Stream.Reader.init(stream, r.io, &peer.rbuf);
        peer.wr = net.Stream.Writer.init(stream, r.io, &peer.wbuf);
        errdefer peer.deinit();

        // Read the request before answering: the owner check can refuse it.
        const req = try peer.readRequest();
        const target = peer.request_target;
        if (!std.mem.startsWith(u8, target, "/device/")) return error.BadRequest;
        const rest = target["/device/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadRequest;
        const device = rest[0..slash];
        const query = if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest[q + 1 ..] else "";
        const role_host = std.mem.indexOf(u8, query, "role=host") != null;
        var conn_id: []const u8 = "";
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "connId=")) conn_id = pair["connId=".len..];
        }
        const user = if (peer.authorization) |a| (if (std.mem.startsWith(u8, a, "Bearer ")) a["Bearer ".len..] else "") else "";
        if (user.len == 0) return refuse(peer, req, 401);

        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        const owner = r.owners.get(device);
        if (role_host) {
            if (owner) |o| {
                if (!std.mem.eql(u8, o, user)) return refuse(peer, req, 403);
            } else {
                try r.owners.put(r.gpa, try r.gpa.dupe(u8, device), try r.gpa.dupe(u8, user));
            }
        } else if (owner == null or !std.mem.eql(u8, owner.?, user)) {
            return refuse(peer, req, 403);
        }
        try peer.answer(req, 101);

        const m = try r.gpa.create(Member);
        m.* = .{
            .peer = peer,
            .host = role_host,
            .conn_id = try r.gpa.dupe(u8, if (conn_id.len > 0) conn_id else "anon"),
            .device = try r.gpa.dupe(u8, device),
        };
        if (role_host) {
            // One live host: close any predecessor (backend restart).
            for (r.members.items) |old| {
                if (old.host and std.mem.eql(u8, old.device, device) and !old.done.load(.acquire)) {
                    old.peer.writeFrame(.close, &.{ 0x11, 0x39 }) catch {};
                    old.peer.shutdown();
                }
            }
        }
        try r.members.append(r.gpa, m);
        m.thread = try std.Thread.spawn(.{}, memberLoop, .{ r, m });
    }

    fn memberLoop(r: *Room, m: *Member) void {
        defer {
            r.lock.lockUncancelable(r.io);
            m.done.store(true, .release);
            r.left(m);
            r.lock.unlock(r.io);
            m.peer.shutdown();
        }
        while (true) {
            const msg = m.peer.readMessage() catch return;
            defer r.gpa.free(msg.payload);
            if (msg.op == .text) {
                if (std.mem.eql(u8, msg.payload, "ping")) m.peer.writeFrame(.text, "pong") catch return;
                continue;
            }
            var f = frame.decode(r.gpa, msg.payload) catch {
                m.peer.writeFrame(.close, &.{ 0x03, 0xea }) catch {};
                return;
            };
            defer f.deinit();
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            if (!m.host) {
                const host = r.hostOf(m.device) orelse {
                    deliver(r.gpa, m, .{ .s = f.header.s, .k = frame.relay_kind }, "{\"error\":\"host_offline\"}");
                    continue;
                };
                deliver(r.gpa, host, .{ .s = f.header.s, .k = f.header.k, .from = m.conn_id }, f.payload);
                continue;
            }
            if (std.mem.eql(u8, f.header.k, frame.nudge_ack_kind)) {
                _ = r.acked.fetchAdd(1, .acq_rel);
                continue;
            }
            const to = f.header.to orelse continue;
            const target = r.clientOf(m.device, to) orelse {
                deliver(r.gpa, m, .{ .s = f.header.s, .k = frame.relay_kind, .to = to }, "{\"error\":\"client_gone\"}");
                continue;
            };
            deliver(r.gpa, target, .{ .s = f.header.s, .k = f.header.k }, f.payload);
        }
    }

    fn clientOf(r: *Room, device: []const u8, conn_id: []const u8) ?*Member {
        for (r.members.items) |m| {
            if (!m.host and !m.done.load(.acquire) and std.mem.eql(u8, m.device, device) and std.mem.eql(u8, m.conn_id, conn_id)) return m;
        }
        return null;
    }

    /// Caller holds `lock`.
    fn left(r: *Room, m: *Member) void {
        if (!m.host) {
            if (r.hostOf(m.device)) |host| deliver(r.gpa, host, .{ .s = "", .k = frame.relay_kind, .from = m.conn_id }, "{\"error\":\"client_closed\"}");
            return;
        }
        if (r.hostOf(m.device) != null) return; // a successor already took over
        for (r.members.items) |c| {
            if (!c.host and !c.done.load(.acquire) and std.mem.eql(u8, c.device, m.device)) {
                deliver(r.gpa, c, .{ .s = "", .k = frame.relay_kind }, "{\"error\":\"host_closed\"}");
            }
        }
    }
};

fn refuse(peer: *testkit.Peer, req: testkit.Peer.Request, status: u16) !void {
    try peer.answer(req, status);
    return error.Refused;
}

fn deliver(gpa: Allocator, to: *Member, h: frame.Header, payload: []const u8) void {
    const bytes = frame.encode(gpa, h, payload) catch return;
    defer gpa.free(bytes);
    to.peer.writeFrame(.binary, bytes) catch {};
}
