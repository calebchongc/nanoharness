//! Binds the device relay (`device_relay.zig`) to the engine: remote clients
//! reach the same JSON-RPC dispatch a local socket does
//! (`engine_main.dispatchClientLineWithArena`), with every method available,
//! as `EngineCore::start_host_relay` serves the full `EngineRpc` to relay
//! clients. The edge's owner check on the room is the gate.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const engine_main = @import("engine_main.zig");
const device_relay = @import("device_relay.zig");
const wss = @import("wss.zig");

pub const Options = struct {
    trust: wss.Trust = .system,
    ping_interval_ms: u64 = 10_000,
    silence_lease_ms: u64 = 25_000,
    jitter_max_ms: u64 = 2_000,
};

/// Starts hosting this device's room when an edge is configured (signed-in
/// state is checked on every dial). Null without an edge. Stop with `stop`.
pub fn start(gpa: Allocator, io: Io, host: *engine_host.EngineHost) ?*device_relay.HostRelay {
    return startWith(gpa, io, host, .{}) catch |err| {
        std.log.warn("device-room: host relay not started: {t}", .{err});
        return null;
    };
}

pub fn startWith(gpa: Allocator, io: Io, host: *engine_host.EngineHost, options: Options) !?*device_relay.HostRelay {
    host.mutex.lockUncancelable(io);
    const edge = if (host.auth.edge_url) |e| try gpa.dupe(u8, e) else null;
    host.mutex.unlock(io);
    const edge_url = edge orelse return null;
    defer gpa.free(edge_url);
    return try device_relay.HostRelay.start(gpa, io, .{
        .edge_url = edge_url,
        .device_id = host.device_id,
        .trust = options.trust,
        .ping_interval_ms = options.ping_interval_ms,
        .silence_lease_ms = options.silence_lease_ms,
        .jitter_max_ms = options.jitter_max_ms,
    }, service(host));
}

pub fn service(host: *engine_host.EngineHost) device_relay.Service {
    return .{ .ctx = host, .serve = serve, .closed = closed, .nudge = nudge, .token = token };
}

fn serve(ctx: *anyopaque, conn: *device_relay.VirtualConn, text: []const u8) void {
    const host: *engine_host.EngineHost = @ptrCast(@alignCast(ctx));
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    // ndjson: a client may batch several frames in one message.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        defer _ = arena.reset(.{ .retain_with_limit = 64 * 1024 });
        engine_main.dispatchClientLineWithArena(host.gpa, arena.allocator(), host, conn.writer(), line) catch |err| {
            std.log.debug("device-room: remote call failed: {t}", .{err});
        };
        if (host.stop_requested) return;
    }
}

fn closed(ctx: *anyopaque, conn: *device_relay.VirtualConn) void {
    const host: *engine_host.EngineHost = @ptrCast(@alignCast(ctx));
    host.removeClientWatches(conn.writer());
}

/// Rust admits a nudge into a durable wake queue that later opens the chat
/// and drains its pending commands. This engine has neither the queue nor a
/// drain of commands synced into a chat's doc, so it admits nothing: the
/// nudge stays unACKed and the room redelivers it, as Rust does when
/// admission fails. It does pull the registry now, so the chat's row lands.
fn nudge(ctx: *anyopaque, chat_id: []const u8) bool {
    const host: *engine_host.EngineHost = @ptrCast(@alignCast(ctx));
    std.log.info("device-room: nudge for {s}: no durable wake queue; not acknowledged", .{chat_id});
    host.wakeBgSync();
    return false;
}

fn token(ctx: *anyopaque, gpa: Allocator) device_relay.Token {
    const host: *engine_host.EngineHost = @ptrCast(@alignCast(ctx));
    const io = host.io orelse return .signed_out;
    host.mutex.lockUncancelable(io);
    defer host.mutex.unlock(io);
    if (!host.auth.signed_in or host.auth.edge_url == null) return .signed_out;
    const tok = host.auth.ensureAccessToken(io, false) orelse return .signed_out;
    if (tok.len == 0) return .signed_out;
    return .{ .ok = gpa.dupe(u8, tok) catch return .unavailable };
}

// ---------------------------------------------------------------------------
// Two-engine test: a host engine behind the relay, a second device calling it
// ---------------------------------------------------------------------------

const testing = std.testing;
const testkit = @import("wss_testkit.zig");
const fake_room = @import("fake_device_room.zig");
const frame = @import("device_frame.zig");
const json = std.json;

/// A mock ACP agent: answers initialize and session/new, then replies to the
/// prompt with "mock agent heard: <prompt>" and ends the turn.
const mock_agent_script =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"method":"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}' ;;
    \\    *'"method":"session/new"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"mock-session"}}' ;;
    \\    *'"method":"session/prompt"'*)
    \\      text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
    \\      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"mock-session\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"mock agent heard: $text\"}}}}"
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
    \\      exit 0 ;;
    \\  esac
    \\done
    \\
;

/// The second device: a client socket into the room speaking RPC frames.
const ClientDevice = struct {
    gpa: Allocator,
    conn: *wss.Conn,
    msg: std.ArrayList(u8) = .empty,

    fn call(self: *ClientDevice, line: []const u8) !void {
        const bytes = try frame.encode(self.gpa, .{ .s = "rpc", .k = "rpc" }, line);
        defer self.gpa.free(bytes);
        try self.conn.sendBinary(bytes);
    }

    /// The next relay frame's payload (caller frees) and kind.
    fn next(self: *ClientDevice) !struct { kind: []u8, payload: []u8 } {
        while (true) {
            const op = try self.conn.readMessage(&self.msg);
            if (op != .binary) continue;
            var f = try frame.decode(self.gpa, self.msg.items);
            defer f.deinit();
            return .{ .kind = try self.gpa.dupe(u8, f.header.k), .payload = try self.gpa.dupe(u8, f.payload) };
        }
    }

    /// Reads RPC frames until one contains `needle`; returns it (caller frees).
    fn waitFor(self: *ClientDevice, needle: []const u8) ![]u8 {
        while (true) {
            const n = try self.next();
            self.gpa.free(n.kind);
            if (std.mem.indexOf(u8, n.payload, needle) != null) return n.payload;
            self.gpa.free(n.payload);
        }
    }

    fn deinit(self: *ClientDevice) void {
        self.msg.deinit(self.gpa);
        self.conn.deinit();
    }
};

test "relay two engines: a prompt from another device runs on the host and the reply comes back" {
    if (comptime !std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 60_000);
    defer deadline.finish();

    // Scratch directory: the mock agent and the turn's working directory.
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const dir = try std.fmt.allocPrint(gpa, "/tmp/harness-nano-relay-e2e-{x}", .{&rnd});
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const agent_path = try std.fmt.allocPrint(gpa, "{s}/mock-agent", .{dir});
    defer gpa.free(agent_path);
    {
        const f = try Io.Dir.cwd().createFile(io, agent_path, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, mock_agent_script);
    }

    // The relay: an in-process stand-in for the edge's DeviceRoom.
    const room = try fake_room.Room.start(gpa, io);
    defer room.stop();
    const edge = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{room.port});
    defer gpa.free(edge);

    // Engine one hosts the chat; its agent is the mock script.
    var host = try engine_host.EngineHost.init(gpa, "dev-host", "Host");
    defer host.deinit();
    host.io = io;
    host.graff_exe = agent_path;
    try host.auth.configureCodegraff(edge, null, null, null);
    try host.auth.signInWithKey("user-1");
    const relay = (try startWith(gpa, io, &host, .{ .jitter_max_ms = 0 })).?;
    defer relay.stop();
    try room.waitForHost("dev-host", 10_000);

    // The second device joins the same room as a client.
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/device/dev-host/ws?role=client&connId=phone-1&token=user-1", .{room.port});
    defer gpa.free(url);
    var phone: ClientDevice = .{ .gpa = gpa, .conn = try wss.connectUrl(gpa, io, url, .{ .connect_timeout_ms = 5_000, .lease_ms = 20_000 }) };
    defer phone.deinit();

    // Watch the chat, then send the prompt.
    try phone.call("{\"id\":1,\"method\":\"WatchDocMessages\",\"params\":{\"chatId\":\"chat-e2e\"}}");
    const first = try phone.waitFor("\"id\":1");
    gpa.free(first);
    const run = try std.fmt.allocPrint(gpa, "{{\"id\":2,\"method\":\"QueueCommand\",\"params\":{{\"chatId\":\"chat-e2e\",\"command\":{{\"kind\":\"run\",\"messageId\":\"m-phone-1\",\"request\":{{\"prompt\":\"hello from the phone\",\"cwd\":\"{s}\"}}}}}}}}", .{dir});
    defer gpa.free(run);
    try phone.call(run);

    // The agent's reply streams back to the watcher over the relay.
    const reply = try phone.waitFor("mock agent heard: hello from the phone");
    defer gpa.free(reply);
    try testing.expect(std.mem.startsWith(u8, reply, "{\"id\":1,\"item\":"));
    const ack = try phone.waitFor("\"id\":2,");
    defer gpa.free(ack);
    try testing.expectEqualStrings("{\"id\":2,\"ok\":{\"queued\":true}}", ack);

    // Another engine's durable delivery: RelayCommand, exactly once.
    const now = host.nowMs();
    const relayed = try std.fmt.allocPrint(gpa,
        \\{{"id":3,"method":"RelayCommand","params":{{"chatId":"chat-e2e","entry":{{"id":"cmd-steer-1","payload":{{"kind":"steer","prompt":"also check the tests","messageId":"m-steer-1"}},"issuedBy":"dev-laptop","issuedAt":{d},"status":"pending"}}}}}}
    , .{now});
    defer gpa.free(relayed);
    try phone.call(relayed);
    const executed = try phone.waitFor("\"id\":3,");
    defer gpa.free(executed);
    try testing.expectEqualStrings("{\"id\":3,\"ok\":{\"outcome\":\"executed\"}}", executed);
    const relayed_again = try std.mem.replaceOwned(u8, gpa, relayed, "\"id\":3", "\"id\":4");
    defer gpa.free(relayed_again);
    try phone.call(relayed_again);
    const dup = try phone.waitFor("\"id\":4,");
    defer gpa.free(dup);
    try testing.expectEqualStrings("{\"id\":4,\"ok\":{\"outcome\":\"duplicate\"}}", dup);

    // Interrupt through the relay too.
    const intr = try std.fmt.allocPrint(gpa,
        \\{{"id":5,"method":"RelayCommand","params":{{"chatId":"chat-e2e","entry":{{"id":"cmd-int-1","payload":{{"kind":"interrupt"}},"issuedBy":"dev-laptop","issuedAt":{d},"status":"pending"}}}}}}
    , .{now});
    defer gpa.free(intr);
    try phone.call(intr);
    const intr_ok = try phone.waitFor("\"id\":5,");
    defer gpa.free(intr_ok);
    try testing.expectEqualStrings("{\"id\":5,\"ok\":{\"outcome\":\"executed\"}}", intr_ok);

    // Queue edits from the other device land in the host's queue.
    try phone.call("{\"id\":6,\"method\":\"QueueMessage\",\"params\":{\"chatId\":\"chat-e2e\",\"text\":\"next: write docs\",\"id\":\"q-1\"}}");
    const queued = try phone.waitFor("\"id\":6,");
    defer gpa.free(queued);
    try testing.expectEqualStrings("{\"id\":6,\"ok\":{\"id\":\"q-1\"}}", queued);
    try phone.call("{\"id\":7,\"method\":\"UpdateQueuedMessage\",\"params\":{\"chatId\":\"chat-e2e\",\"id\":\"q-1\",\"text\":\"next: write the docs\"}}");
    const updated = try phone.waitFor("\"id\":7,");
    defer gpa.free(updated);
    try testing.expectEqualStrings("{\"id\":7,\"ok\":{\"changed\":true}}", updated);

    // What the host now holds.
    host.mutex.lockUncancelable(io);
    defer host.mutex.unlock(io);
    const doc = host.docs.getPtr("chat-e2e").?;
    var texts: std.ArrayList(u8) = .empty;
    defer texts.deinit(gpa);
    for (doc.messages.items) |m| {
        for (m.parts.items) |p| {
            try texts.appendSlice(gpa, p.text.items);
            try texts.append(gpa, '|');
        }
    }
    try testing.expect(std.mem.indexOf(u8, texts.items, "hello from the phone") != null);
    try testing.expect(std.mem.indexOf(u8, texts.items, "mock agent heard: hello from the phone") != null);
    try testing.expect(std.mem.indexOf(u8, texts.items, "also check the tests") != null);
    try testing.expectEqualStrings("next: write the docs", doc.queue.items[0].text);
}

test "relay two engines: a client of a room with no host is told host_offline" {
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline = try testkit.Deadline.start(io, 20_000);
    defer deadline.finish();
    const room = try fake_room.Room.start(gpa, io);
    defer room.stop();
    // The owner claims the room first (a host that then goes away).
    {
        const host_url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/device/dev-x/ws?role=host&token=user-1", .{room.port});
        defer gpa.free(host_url);
        const h = try wss.connectUrl(gpa, io, host_url, .{ .connect_timeout_ms = 5_000 });
        h.close(1000);
        h.deinit();
    }
    try room.waitForNoHost("dev-x", 5_000);
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/device/dev-x/ws?role=client&connId=c1&token=user-1", .{room.port});
    defer gpa.free(url);
    var phone: ClientDevice = .{ .gpa = gpa, .conn = try wss.connectUrl(gpa, io, url, .{ .connect_timeout_ms = 5_000, .lease_ms = 10_000 }) };
    defer phone.deinit();
    try phone.call("{\"id\":1,\"method\":\"EngineInfo\"}");
    const n = try phone.next();
    defer gpa.free(n.kind);
    defer gpa.free(n.payload);
    try testing.expectEqualStrings(frame.relay_kind, n.kind);
    try testing.expectEqualStrings("{\"error\":\"host_offline\"}", n.payload);
}
