//! The client side of the device relay: one RPC to another device of the same
//! account through the edge's device room (`/device/{id}/ws?role=client`,
//! `edge/src/device-room.ts`), as the Rust engine's peer links do
//! (`LinkCache::client`, `crates/engine/src/doc_host.rs` `relay_command` and
//! `deliver_attachments`).
//!
//! `forward` is the engine's routing rule, checked before a method runs here:
//! - a unary call whose `targetDeviceId` is another device runs on that device
//!   (an attachment's `UploadChunk`/`UploadCommit` lands on the chat's host);
//! - a `QueueCommand` for a chat another device hosts goes to that host as
//!   `RelayCommand` with a durable entry (`SessionCommandEntry`), `cmd-` and
//!   the caller's message id, so the host's processed ledger runs it once.
//! Rust also writes the command into the chat's synced doc; this engine has no
//! Loro codec, so the relay is its only road to the host. Without an edge or a
//! bearer nothing is forwarded and the method runs here, as before.
const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const frame = @import("device_frame.zig");
const wss = @import("wss.zig");

pub const call_timeout_ms: u64 = 20_000;

pub const Reply = union(enum) {
    /// The `ok` value's JSON.
    ok: []u8,
    /// The host's `err` text, or the relay's error code (`host_offline`, ...).
    err: []u8,

    pub fn deinit(self: Reply, gpa: Allocator) void {
        switch (self) {
            inline else => |s| gpa.free(s),
        }
    }
};

/// Sends `{"id":1,"method":method,"params":params_json}` to `device` and waits
/// for its answer: stream items are skipped, a relay control frame is an error.
pub fn call(gpa: Allocator, io: Io, edge_url: []const u8, token: []const u8, device: []const u8, method: []const u8, params_json: []const u8) !Reply {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const conn_id = std.fmt.bytesToHex(rnd, .lower);
    const url = try frame.deviceRoomWsUrl(gpa, edge_url, device, "client", &conn_id, token);
    defer gpa.free(url);
    const conn = try wss.connectUrl(gpa, io, url, .{ .connect_timeout_ms = 10_000, .lease_ms = call_timeout_ms });
    defer conn.deinit();
    defer conn.close(1000);
    const line = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"method\":{f},\"params\":{s}}}", .{ json.fmt(method, .{}), params_json });
    defer gpa.free(line);
    const bytes = try frame.encode(gpa, .{ .s = "rpc", .k = frame.rpc_kind }, line);
    defer gpa.free(bytes);
    try conn.sendBinary(bytes);

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    while (true) {
        if (try conn.readMessage(&msg) != .binary) continue;
        var f = frame.decode(gpa, msg.items) catch continue;
        defer f.deinit();
        if (std.mem.eql(u8, f.header.k, frame.relay_kind)) {
            var p = json.parseFromSlice(json.Value, gpa, f.payload, .{}) catch return .{ .err = try gpa.dupe(u8, "relay error") };
            defer p.deinit();
            const code = if (p.value == .object) p.value.object.get("error") else null;
            return .{ .err = try gpa.dupe(u8, if (code) |c| (if (c == .string) c.string else "relay error") else "relay error") };
        }
        if (!std.mem.eql(u8, f.header.k, frame.rpc_kind)) continue;
        var p = json.parseFromSlice(json.Value, gpa, f.payload, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const id = p.value.object.get("id") orelse continue;
        if (id != .integer or id.integer != 1) continue;
        if (p.value.object.get("ok")) |ok| return .{ .ok = try std.fmt.allocPrint(gpa, "{f}", .{json.fmt(ok, .{})}) };
        if (p.value.object.get("err")) |e| return .{ .err = if (e == .string) try gpa.dupe(u8, e.string) else try std.fmt.allocPrint(gpa, "{f}", .{json.fmt(e, .{})}) };
    }
}

/// The method's `targetDeviceId` when it names another device and the call
/// can be answered in one reply (streams stay local).
fn remoteTarget(host: *const engine_host.EngineHost, method: []const u8, params: json.Value) ?[]const u8 {
    if (params != .object) return null;
    const v = params.object.get("targetDeviceId") orelse return null;
    if (v != .string or v.string.len == 0 or std.mem.eql(u8, v.string, host.device_id)) return null;
    if (std.mem.startsWith(u8, method, "Watch") or std.mem.eql(u8, method, "UpdateStatus") or std.mem.eql(u8, method, "SubscribeTerminal")) return null;
    return v.string;
}

/// The device hosting `chat_id` when it is another one.
fn remoteChatHost(host: *const engine_host.EngineHost, chat_id: []const u8) ?[]const u8 {
    for (host.chats.items) |c| if (std.mem.eql(u8, c.id, chat_id)) {
        return if (c.device_id.len > 0 and !std.mem.eql(u8, c.device_id, host.device_id)) c.device_id else null;
    };
    return null;
}

/// The host's refusal text, kept until the next forwarded call fails (the
/// RPC error borrows it). Written under the engine lock.
var err_buf: [256]u8 = undefined;

/// Runs `method` on the device it belongs to, or returns null to run it here.
pub fn forward(host: *engine_host.EngineHost, method: []const u8, params: json.Value) !?engine_host.RpcOutcome {
    const io = host.io orelse return null;
    const edge = host.auth.edge_url orelse return null;
    if (!host.auth.signed_in) return null;
    var arena_state = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var target: []const u8 = undefined;
    var out_method: []const u8 = method;
    var out_params: []const u8 = undefined;
    var command_id: ?[]const u8 = null;
    if (remoteTarget(host, method, params)) |t| {
        target = t;
        out_params = try std.fmt.allocPrint(arena, "{f}", .{json.fmt(params, .{})});
    } else if (std.mem.eql(u8, method, "QueueCommand") and params == .object) {
        const chat = params.object.get("chatId") orelse return null;
        if (chat != .string) return null;
        target = remoteChatHost(host, chat.string) orelse return null;
        const cmd = params.object.get("command") orelse return null;
        if (cmd != .object) return null;
        const mid = cmd.object.get("messageId");
        command_id = if (mid != null and mid.? == .string) mid.?.string else try std.fmt.allocPrint(arena, "cmd-{s}-{d}", .{ host.device_id, host.nowMs() });
        out_method = "RelayCommand";
        // The entry's own id, apart from the message id: the host claims it
        // in its processed ledger, then runs the message under its own id.
        const entry_id = try std.fmt.allocPrint(arena, "cmd-{s}", .{command_id.?});
        out_params = try std.fmt.allocPrint(arena, "{{\"chatId\":{f},\"entry\":{{\"id\":{f},\"payload\":{f},\"issuedBy\":{f},\"issuedAt\":{d},\"status\":\"pending\"}}}}", .{
            json.fmt(chat.string, .{}), json.fmt(entry_id, .{}), json.fmt(cmd, .{}), json.fmt(host.device_id, .{}), host.nowMs(),
        });
    } else return null;

    const token = try arena.dupe(u8, host.auth.ensureAccessToken(io, false) orelse return null);
    const edge_copy = try arena.dupe(u8, edge);
    const target_copy = try arena.dupe(u8, target);
    const released = host.releaseForLongCall();
    const reply = call(host.gpa, io, edge_copy, token, target_copy, out_method, out_params);
    host.retakeAfterLongCall(released);
    const r = reply catch |e| return fail(try std.fmt.bufPrint(&err_buf, "could not reach device {s}: {t}", .{ target_copy, e }));
    defer r.deinit(host.gpa);
    switch (r) {
        .err => |m| return fail(std.fmt.bufPrint(&err_buf, "device {s}: {s}", .{ target_copy, m }) catch "the device refused the call"),
        .ok => |body| return .{ .unary_json = if (command_id) |id|
            try std.fmt.allocPrint(host.gpa, "{{\"commandId\":{f}}}", .{json.fmt(id, .{})})
        else
            try host.gpa.dupe(u8, body) },
    }
}

fn fail(msg: []const u8) engine_host.RpcOutcome {
    return .{ .err = .{ .exec_error = msg } };
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const fake_room = @import("fake_device_room.zig");
const relay_engine = @import("relay_engine.zig");

fn handleJson(host: *engine_host.EngineHost, method: []const u8, params: []const u8) !engine_host.RpcOutcome {
    var p = try json.parseFromSlice(json.Value, testing.allocator, params, .{});
    defer p.deinit();
    return host.handle(method, p.value);
}

test "relay dial: a run for a chat another device hosts runs on that host, and an upload lands there" {
    if (comptime !std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const room = try fake_room.Room.start(gpa, io);
    defer room.stop();
    const edge = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{room.port});
    defer gpa.free(edge);
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const dir = try std.fmt.allocPrint(gpa, "/tmp/harness-nano-relay-dial-{x}", .{&rnd});
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Device A hosts the chat behind the relay.
    var a = try engine_host.EngineHost.init(gpa, "dev-host", "Host");
    defer a.deinit();
    a.io = io;
    try a.setDataDir(dir);
    try a.auth.configureCodegraff(edge, null, null, null);
    try a.auth.signInWithKey("user-1");
    gpa.free((try handleJson(&a, "Mutate", "{\"op\":\"createChat\",\"chatId\":\"chat-r\",\"config\":{\"harness\":\"mock\"}}")).unary_json);
    const relay = (try relay_engine.startWith(gpa, io, &a, .{ .jitter_max_ms = 0 })).?;
    defer relay.stop();
    try room.waitForHost("dev-host", 10_000);

    // Device B knows the chat's row (synced from the registry: host dev-host).
    var b = try engine_host.EngineHost.init(gpa, "dev-b", "Second");
    defer b.deinit();
    b.io = io;
    try b.auth.configureCodegraff(edge, null, null, null);
    try b.auth.signInWithKey("user-1");
    {
        const made = try handleJson(&b, "Mutate", "{\"op\":\"createChat\",\"chatId\":\"chat-r\",\"config\":{\"harness\":\"mock\"}}");
        gpa.free(made.unary_json);
        for (b.chats.items) |*c| if (std.mem.eql(u8, c.id, "chat-r")) {
            gpa.free(c.device_id);
            c.device_id = try gpa.dupe(u8, "dev-host");
        };
    }

    // An attachment for the host goes to the host.
    {
        const chunk = try handleJson(&b, "UploadChunk", "{\"uploadId\":\"up-1\",\"seq\":0,\"data\":\"c3ludGhldGlj\",\"targetDeviceId\":\"dev-host\"}");
        defer gpa.free(chunk.unary_json);
        const commit = try handleJson(&b, "UploadCommit", "{\"uploadId\":\"up-1\",\"fileName\":\"note.txt\",\"targetDeviceId\":\"dev-host\"}");
        defer gpa.free(commit.unary_json);
        var p = try json.parseFromSlice(json.Value, gpa, commit.unary_json, .{});
        defer p.deinit();
        const path = p.value.object.get("path").?.string;
        try testing.expect(std.mem.startsWith(u8, path, dir));
        const got = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64));
        defer gpa.free(got);
        try testing.expectEqualStrings("synthetic", got);
    }

    const run_params = try std.fmt.allocPrint(gpa, "{{\"chatId\":\"chat-r\",\"command\":{{\"kind\":\"run\",\"messageId\":\"m-b-1\",\"request\":{{\"prompt\":\"from the second device\",\"harness\":\"mock\",\"cwd\":\"{s}\",\"sandbox\":\"workspace-write\"}}}}}}", .{dir});
    defer gpa.free(run_params);
    const out = try handleJson(&b, "QueueCommand", run_params);
    defer gpa.free(out.unary_json);
    try testing.expectEqualStrings("{\"commandId\":\"m-b-1\"}", out.unary_json);

    // The prompt is in the host's doc, not in B's (A's turn has finished).
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 20) {
        if (waited > 200 and @import("turn_host.zig").liveCount(io, &a) == 0) break;
        try Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    a.mutex.lockUncancelable(io);
    var in_a = false;
    for (a.docs.getPtr("chat-r").?.messages.items) |m| {
        for (m.parts.items) |pt| {
            if (std.mem.indexOf(u8, pt.text.items, "from the second device") != null) in_a = true;
        }
    }
    a.mutex.unlock(io);
    try testing.expect(in_a);
    if (b.docs.getPtr("chat-r")) |doc| try testing.expectEqual(@as(usize, 0), doc.messages.items.len);
}

test "relay dial: no edge, no forwarding" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-x", "X");
    defer host.deinit();
    host.io = testing.io;
    var p = try json.parseFromSlice(json.Value, testing.allocator, "{\"targetDeviceId\":\"dev-other\",\"uploadId\":\"u\"}", .{});
    defer p.deinit();
    try testing.expect((try forward(&host, "UploadCommit", p.value)) == null);
}
