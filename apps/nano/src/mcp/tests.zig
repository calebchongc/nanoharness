//! MCP tool tests (`crates/mcp/src/tools.rs` tests, ported).
//!
//! Chat, listing and publishing tools run against an in-process Zig
//! `EngineHost` holding made-up spaces and chats. Where the Zig engine
//! cannot produce a state yet (room replies from the edge, the person's own
//! bots), a scripted engine stands in, as the Rust tests' `World` does.
//! Nothing here dials a socket other than a closed loopback port.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const engine_host = @import("../engine_host.zig");
const mcp = @import("../mcp_server.zig");
const tools = @import("tools.zig");
const link = @import("engine_link.zig");
const peer = @import("peer.zig");
const bots = @import("bots.zig");
const rpcw_common = @import("../rpcw_common.zig");
const rpcw_executables = @import("../rpcw_executables.zig");
const turn_host = @import("../turn_host.zig");
const u = @import("util.zig");
const Value = json.Value;

const host_now: i64 = 1794271500000; // EngineHost's clock without an Io.

// ---- fakes ---------------------------------------------------------------------------

const FakePeer = struct {
    sends: std.ArrayList([3][]const u8) = .empty,
    fail: ?[]const u8 = null,
    a: Allocator,

    fn peerSend(self: *FakePeer) peer.PeerSend {
        return .{ .ptr = self, .send_fn = send };
    }

    fn send(ptr: *anyopaque, _: Allocator, from: []const u8, to: []const u8, text: []const u8) anyerror!peer.PeerSend.SendResult {
        const self: *FakePeer = @ptrCast(@alignCast(ptr));
        try self.sends.append(self.a, .{ try self.a.dupe(u8, from), try self.a.dupe(u8, to), try self.a.dupe(u8, text) });
        if (self.fail) |f| return .{ .err = f };
        return .{ .ok = "delivered to peer inbox" };
    }
};

const FakeBots = struct {
    a: Allocator,
    calls: std.ArrayList([]const u8) = .empty,
    /// `args joined by space` → stdout; missing → `unknown command`.
    outputs: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn cli(self: *FakeBots) bots.BotCli {
        return .{ .ptr = self, .bot_fn = run };
    }

    fn set(self: *FakeBots, args: []const u8, out: []const u8) !void {
        try self.outputs.put(self.a, args, out);
    }

    fn run(ptr: *anyopaque, a: Allocator, folder: []const u8, args: []const []const u8) anyerror!bots.BotCli.Result {
        const self: *FakeBots = @ptrCast(@alignCast(ptr));
        const joined = try std.mem.join(self.a, " ", args);
        try self.calls.append(self.a, try std.fmt.allocPrint(self.a, "{s}: {s}", .{ folder, joined }));
        if (self.outputs.get(joined)) |out| return .{ .ok = try a.dupe(u8, out) };
        return .{ .err = "unknown command" };
    }
};

/// Logs every call it forwards, so tests see what reached the engine.
const Recorder = struct {
    inner: link.Engine,
    a: Allocator,
    log: std.ArrayList([2][]const u8) = .empty,

    fn engine(self: *Recorder) link.Engine {
        return .{ .ptr = self, .vtable = &.{ .call = callFn, .subscribe = subFn } };
    }

    fn callFn(ptr: *anyopaque, a: Allocator, method: []const u8, params: []const u8) anyerror!link.Result {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.log.append(self.a, .{ try self.a.dupe(u8, method), try self.a.dupe(u8, params) });
        return self.inner.call(a, method, params);
    }

    fn subFn(ptr: *anyopaque, a: Allocator, method: []const u8, params: []const u8) anyerror!link.Subscribed {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        return self.inner.subscribe(a, method, params);
    }

    /// Params of the last call to `method`, parsed.
    fn last(self: *Recorder, method: []const u8) ?Value {
        var k = self.log.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, self.log.items[k][0], method))
                return json.parseFromSliceLeaky(Value, self.a, self.log.items[k][1], .{}) catch null;
        }
        return null;
    }

    fn count(self: *Recorder, method: []const u8) usize {
        var n: usize = 0;
        for (self.log.items) |e| {
            if (std.mem.eql(u8, e[0], method)) n += 1;
        }
        return n;
    }
};

/// A scripted engine (the Rust tests' `World`): fixed replies by method.
const World = struct {
    a: Allocator,
    sessions: []const u8 = "[]",
    queue_items: []const u8 = "[]",
    extra_chats: []const u8 = "",
    own_bots: ?[]const u8 = null,
    room_post_body: []const u8 =
        \\{"message":{"seq":3,"hop":1},"deliver":[
        \\  {"member":"alpha","memberKind":"harness_chat","memberRef":"chat-alpha-1","deviceId":"dev-local"},
        \\  {"member":"claude@laptop","memberKind":"graff","memberRef":null,"deviceId":"laptop"}],
        \\ "unreadFrom":{"alpha":1},"redacted":{"email":1},"stripped":0}
    ,
    room_post_status: i64 = 200,
    /// The transcript `WatchDocMessages` resets to; null: a greeting.
    doc_reset: ?[]const u8 = null,
    /// Replies the edge gives, by HTTP method and path suffix; checked
    /// before the defaults below.
    room_replies: []const RoomReply = &.{},
    writes: std.ArrayList([2][]const u8) = .empty,

    const RoomReply = struct { method: []const u8, path_end: []const u8, status: i64, body: []const u8 };

    fn engine(self: *World) link.Engine {
        return .{ .ptr = self, .vtable = &.{ .call = callFn, .subscribe = subFn } };
    }

    fn reply(self: *World, a: Allocator, method: []const u8, params: Value) !link.Result {
        _ = self;
        const eq = std.mem.eql;
        const text: []const u8 = if (eq(u8, method, "LocalDevice"))
            "{\"deviceId\":\"dev-local\"}"
        else if (eq(u8, method, "EngineInfo"))
            "{\"deviceId\":\"dev-local\",\"workspaceScope\":\"local\"}"
        else if (eq(u8, method, "ListHarnesses"))
            \\[{"id":"claude-code","name":"Claude Code","supportsSteering":true,"steeringMode":"step-boundary","reasoningLevels":[],"installed":true,"enabled":true},
            \\ {"id":"codex","name":"Codex","supportsSteering":true,"steeringMode":"turn-boundary","reasoningLevels":[],"installed":false,"enabled":true},
            \\ {"id":"graff","name":"graff","supportsSteering":true,"steeringMode":"turn-boundary","reasoningLevels":[],"installed":true,"enabled":true}]
        else if (eq(u8, method, "ListModels"))
            "[{\"id\":\"opus\",\"label\":\"Opus\"},{\"id\":\"sonnet\",\"label\":\"Sonnet\"}]"
        else if (eq(u8, method, "ShowImage") and eq(u8, u.str(params, "path") orelse "", "bad.png"))
            return .{ .err = "ShowImage: no active run accepts images" }
        else
            return .{ .err = try std.fmt.allocPrint(a, "{s}: unknown method: {s}", .{ method, method }) };
        return .{ .ok = try json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) };
    }

    fn callFn(ptr: *anyopaque, a: Allocator, method: []const u8, params_json: []const u8) anyerror!link.Result {
        const self: *World = @ptrCast(@alignCast(ptr));
        const eq = std.mem.eql;
        const params = try json.parseFromSliceLeaky(Value, a, params_json, .{ .allocate = .alloc_always });
        if (eq(u8, method, "Mutate") or eq(u8, method, "QueueCommand") or eq(u8, method, "QueueMessage") or eq(u8, method, "RunBot") or eq(u8, method, "ShowImage")) {
            try self.writes.append(self.a, .{ try self.a.dupe(u8, method), try self.a.dupe(u8, params_json) });
        }
        if (eq(u8, method, "Mutate") or eq(u8, method, "QueueCommand") or eq(u8, method, "QueueMessage"))
            return .{ .ok = try json.parseFromSliceLeaky(Value, a, "{\"commandId\":\"cmd-1\",\"id\":\"q-1\"}", .{}) };
        if (eq(u8, method, "BotsState")) {
            const own = self.own_bots orelse return .{ .err = "BotsState: unknown method: BotsState" };
            return .{ .ok = try json.parseFromSliceLeaky(Value, a, own, .{ .allocate = .alloc_always }) };
        }
        if (eq(u8, method, "RunBot")) {
            var o = u.obj(a);
            try o.put("chatId", u.s("chat-standing"));
            try o.put("bot", u.field(params, "bot"));
            return .{ .ok = o.value() };
        }
        if (eq(u8, method, "RoomRequest")) return self.room(a, params, params_json);
        return self.reply(a, method, params);
    }

    fn room(self: *World, a: Allocator, params: Value, params_json: []const u8) !link.Result {
        const eq = std.mem.eql;
        const m = u.str(params, "method") orelse "";
        const path = u.str(params, "path") orelse "";
        for (self.room_replies) |r| {
            if (!eq(u8, m, r.method) or !std.mem.endsWith(u8, path, r.path_end)) continue;
            if (eq(u8, m, "POST")) try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            var o = u.obj(a);
            try o.put("status", u.i(r.status));
            try o.put("body", try json.parseFromSliceLeaky(Value, a, r.body, .{ .allocate = .alloc_always }));
            return .{ .ok = o.value() };
        }
        var status: i64 = 200;
        const body: []const u8 = if (eq(u8, m, "GET") and eq(u8, path, "rooms"))
            "{\"rooms\":[{\"id\":\"room_0123456789abcdef01234567\",\"name\":\"build\"}]}"
        else if (eq(u8, m, "GET") and std.mem.endsWith(u8, path, "/state"))
            \\{"members":[{"member":"beta","memberRef":"chat-beta-2","deviceId":"dev-local","readSeq":4},
            \\            {"member":"alpha","memberRef":"chat-alpha-1","deviceId":"dev-local","readSeq":0}]}
        else if (eq(u8, m, "GET") and std.mem.endsWith(u8, path, "/messages"))
            "{\"messages\":[{\"seq\":5,\"member\":\"alpha\",\"body\":\"hi\"}],\"lastSeq\":5}"
        else if (eq(u8, m, "GET") and eq(u8, path, "rooms/inbox"))
            "{\"items\":[{\"room\":\"build\",\"seq\":5}]}"
        else if (eq(u8, m, "POST") and std.mem.endsWith(u8, path, "/post")) blk: {
            try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            status = self.room_post_status;
            break :blk self.room_post_body;
        } else if (eq(u8, m, "POST") and eq(u8, path, "rooms")) blk: {
            try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            break :blk "{\"room\":{\"id\":\"room_new\",\"name\":\"plan\"}}";
        } else if (eq(u8, m, "POST")) blk: {
            try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            break :blk "{\"ok\":true,\"member\":\"gamma\"}";
        } else blk: {
            status = 404;
            break :blk "{\"error\":\"not_found\"}";
        };
        var o = u.obj(a);
        try o.put("status", u.i(status));
        try o.put("body", try json.parseFromSliceLeaky(Value, a, body, .{ .allocate = .alloc_always }));
        return .{ .ok = o.value() };
    }

    fn snapshotText(self: *World, a: Allocator, method: []const u8, params: Value) ![]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, method, "WatchDevices")) return "[{\"id\":\"dev-local\",\"name\":\"Laptop\",\"platform\":\"linux\",\"lastSeenAt\":null}]";
        if (eq(u8, method, "WatchSpaces")) return "[{\"id\":\"space-1\",\"deviceId\":\"dev-local\",\"path\":\"/repo/comet\",\"gitDetected\":true,\"createdAt\":\"2026-09-01T00:00:00Z\"}]";
        if (eq(u8, method, "WatchChats")) return std.fmt.allocPrint(a,
            \\[{{"id":"chat-alpha-1","deviceId":"dev-local","title":"Alpha","archived":false,"spaceId":"space-1",
            \\  "config":{{"harness":"claude-code","model":"opus","reasoning":null,"sandbox":"workspace-write"}},"createdAt":"2026-09-01T00:00:00Z"}},
            \\ {{"id":"chat-beta-2","deviceId":"dev-local","title":"Beta","archived":false,"spaceId":"space-1","createdAt":"2026-09-02T00:00:00Z"}},
            \\ {{"id":"chat-gamma-3","deviceId":"dev-local","title":"Gamma","archived":true,"spaceId":"space-1","createdAt":"2026-08-30T00:00:00Z"}}{s}]
        , .{self.extra_chats});
        if (eq(u8, method, "WatchSessions")) return self.sessions;
        if (eq(u8, method, "WatchQueue")) return std.fmt.allocPrint(a, "{{\"items\":{s}}}", .{self.queue_items});
        if (eq(u8, method, "WatchDocMessages")) {
            _ = params;
            if (self.doc_reset) |reset| return std.fmt.allocPrint(a, "{{\"reset\":{s}}}", .{reset});
            return
            \\{"reset":[{"id":"u1","role":"user","createdAt":1,"deviceId":"dev-local","parts":[{"kind":"text","id":"t","text":"hi"}]},
            \\          {"id":"a1","role":"assistant","createdAt":2,"deviceId":"dev-local","status":"complete","parts":[{"kind":"text","id":"t","text":"hello back"}]}]}
            ;
        }
        return error.UnknownWatch;
    }

    const Sub = struct { item: ?[]const u8, a: Allocator };

    fn subFn(ptr: *anyopaque, a: Allocator, method: []const u8, params_json: []const u8) anyerror!link.Subscribed {
        const self: *World = @ptrCast(@alignCast(ptr));
        const params = try json.parseFromSliceLeaky(Value, a, params_json, .{});
        const text = self.snapshotText(a, method, params) catch return .{ .err = try std.fmt.allocPrint(a, "{s}: unknown method: {s}", .{ method, method }) };
        const s = try self.a.create(Sub);
        s.* = .{ .item = text, .a = self.a };
        return .{ .sub = .{ .ptr = s, .vtable = &.{ .next = subNext, .close = subClose } } };
    }

    fn subNext(ptr: *anyopaque, a: Allocator, _: i64) anyerror!link.Next {
        const s: *Sub = @ptrCast(@alignCast(ptr));
        const text = s.item orelse return .timeout;
        s.item = null;
        return .{ .item = try json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) };
    }

    fn subClose(_: *anyopaque) void {}
};

// ---- fixtures -------------------------------------------------------------------------

/// A Claude Code CLI stand-in (stream-json over stdio): one text reply that
/// quotes the prompt, then a successful result. A prompt starting `ask:`
/// first asks to run a tool and quotes the answer (`allowed`/`denied`).
const mock_claude =
    \\#!/bin/sh
    \\IFS= read -r first
    \\p=$(printf '%s' "$first" | /usr/bin/sed 's/.*"content":"\([^"]*\)".*/\1/')
    \\echo '{"type":"system","subtype":"init","session_id":"sess-mcp","model":"m"}'
    \\case "$p" in
    \\  ask:*)
    \\    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}'
    \\    echo '{"type":"control_request","request_id":"cr1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}'
    \\    IFS= read -r resp
    \\    case "$resp" in *'"behavior":"allow"'*) ok=allowed;; *) ok=denied;; esac
    \\    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","is_error":false}]}}'
    \\    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Reply to: '"$p"' ('"$ok"')"}}}'
    \\    ;;
    \\  *) echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Reply to: '"$p"'"}}}' ;;
    \\esac
    \\echo '{"type":"result","subtype":"success","session_id":"sess-mcp"}'
    \\
;

/// An in-process engine with made-up spaces and chats, and the tools over it.
const HostFixture = struct {
    arena: std.heap.ArenaAllocator,
    host: engine_host.EngineHost,
    /// The host's environment: a made-up HOME and a PATH holding only the
    /// stand-in agent CLIs below, so `ListHarnesses` probes and any turn
    /// the host starts see these and never the machine's own agents.
    tmp: testing.TmpDir = undefined,
    env: rpcw_common.TestEnv = undefined,
    /// The temp folder's absolute path; turns run in its `home`.
    base: []const u8 = "",
    host_link: link.HostEngine = undefined,
    rec: Recorder = undefined,
    peer: FakePeer = undefined,
    bots: FakeBots = undefined,
    t: tools.Tools = undefined,

    fn create(origin: tools.Origin) !*HostFixture {
        const gpa = testing.allocator;
        const f = try gpa.create(HostFixture);
        f.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .host = try engine_host.EngineHost.init(gpa, "dev-local", "Laptop") };
        const a = f.arena.allocator();
        try f.isolate();
        f.host_link = .{ .host = &f.host };
        f.rec = .{ .inner = f.host_link.engine(), .a = a };
        f.peer = .{ .a = a };
        f.bots = .{ .a = a };
        f.t = .{
            .io = testing.io,
            .engine = f.rec.engine(),
            .origin = origin,
            .peer = f.peer.peerSend(),
            .relay = .{ .io = testing.io, .dir = null },
            .bots = f.bots.cli(),
            .git = null,
            .fixed_now_ms = host_now,
        };
        try f.setup(
            \\{"op":"createSpace","spaceId":"space-1","path":"/repo/comet","gitDetected":true}
        );
        try f.setup(
            \\{"op":"createSpace","spaceId":"space-2","path":"/repo/comet-ios","name":"iOS","gitDetected":true}
        );
        try f.setup(
            \\{"op":"createChat","chatId":"chat-alpha-1","spaceId":"space-1","title":"Alpha","config":{"harness":"claude-code","model":"opus"}}
        );
        try f.setup(
            \\{"op":"createChat","chatId":"chat-beta-2","spaceId":"space-1","title":"Beta","config":{"harness":"graff"}}
        );
        try f.setup(
            \\{"op":"createChat","chatId":"chat-gamma-3","spaceId":"space-2","title":"Gamma","config":{"harness":"codex"}}
        );
        try f.setup(
            \\{"op":"setChatArchived","chatId":"chat-gamma-3","archived":true}
        );
        f.chat("chat-alpha-1").last_message_at_ms = host_now - 60_000;
        f.chat("chat-beta-2").last_message_at_ms = host_now - 30_000;
        f.rec.log.clearRetainingCapacity();
        return f;
    }

    fn destroy(f: *HostFixture) void {
        const gpa = testing.allocator;
        f.host.deinit();
        turn_host.env_override = null;
        rpcw_executables.system_prefix = "";
        f.env.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
        gpa.destroy(f);
    }

    /// Stand-in agent CLIs on a synthetic PATH: `claude` is a mock Claude
    /// Code that answers `Reply to: <prompt>`; codex and graff exit with an
    /// error if a turn ever starts one (graff turns don't: the host has no
    /// configured graff binary and acknowledges in place).
    fn isolate(f: *HostFixture) !void {
        const io = testing.io;
        const a = f.arena.allocator();
        f.tmp = testing.tmpDir(.{});
        const base = try rpcw_common.tmpPath(a, io, &f.tmp);
        f.base = base;
        try f.tmp.dir.createDirPath(io, "bin");
        try f.tmp.dir.createDirPath(io, "home");
        try f.tmp.dir.createDirPath(io, "data");
        for ([_][]const u8{ "bin/codex", "bin/graff" }) |sub| {
            try f.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "#!/bin/sh\necho 'synthetic stand-in agent' >&2\nexit 1\n", .flags = .{ .permissions = .executable_file } });
        }
        try f.tmp.dir.writeFile(io, .{ .sub_path = "bin/claude", .data = mock_claude, .flags = .{ .permissions = .executable_file } });
        f.env = try rpcw_common.TestEnv.init(testing.allocator, try std.fs.path.join(a, &.{ base, "home" }));
        try f.env.map.put("PATH", try std.fs.path.join(a, &.{ base, "bin" }));
        try f.env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
        try f.env.map.put("HARNESS_DISABLE_SHELL_ENV", "1");
        f.env.install();
        turn_host.env_override = &f.env.map;
        rpcw_executables.system_prefix = base;
        f.host.io = testing.io;
        try f.host.setDataDir(try std.fs.path.join(a, &.{ base, "data" }));
    }

    fn setup(f: *HostFixture, mutate: []const u8) !void {
        const r = try f.host_link.engine().call(f.arena.allocator(), "Mutate", mutate);
        if (r == .err) return error.SetupFailed;
    }

    /// Wait for every turn the host started to finish (5 s deadline).
    fn settle(f: *HostFixture) !void {
        var waited: u32 = 0;
        while (turn_host.liveCount(testing.io, &f.host) != 0) : (waited += 10) {
            if (waited >= 5000) return error.TurnDidNotFinish;
            try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
        }
    }

    fn chat(f: *HostFixture, id: []const u8) *engine_host.ChatRecord {
        for (f.host.chats.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        unreachable;
    }

    fn setStatus(f: *HostFixture, id: []const u8, status: []const u8, updated_ms: i64) !void {
        const c = f.chat(id);
        if (c.activity_status) |old| f.host.gpa.free(old);
        c.activity_status = try f.host.gpa.dupe(u8, status);
        c.activity_updated_at_ms = updated_ms;
    }

    fn call(f: *HostFixture, name: []const u8, args: []const u8) !tools.Outcome {
        const a = f.arena.allocator();
        return f.t.call(a, name, try json.parseFromSliceLeaky(Value, a, args, .{}));
    }
};

const WorldFixture = struct {
    arena: std.heap.ArenaAllocator,
    world: World = undefined,
    peer: FakePeer = undefined,
    bots: FakeBots = undefined,
    t: tools.Tools = undefined,

    fn create(origin: tools.Origin) !*WorldFixture {
        const gpa = testing.allocator;
        const f = try gpa.create(WorldFixture);
        f.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        const a = f.arena.allocator();
        f.world = .{ .a = a };
        f.peer = .{ .a = a };
        f.bots = .{ .a = a };
        f.t = .{
            .io = testing.io,
            .engine = f.world.engine(),
            .origin = origin,
            .peer = f.peer.peerSend(),
            .relay = .{ .io = testing.io, .dir = null },
            .bots = f.bots.cli(),
            .git = null,
            .fixed_now_ms = host_now,
        };
        return f;
    }

    fn destroy(f: *WorldFixture) void {
        f.arena.deinit();
        testing.allocator.destroy(f);
    }

    fn call(f: *WorldFixture, name: []const u8, args: []const u8) !tools.Outcome {
        const a = f.arena.allocator();
        return f.t.call(a, name, try json.parseFromSliceLeaky(Value, a, args, .{}));
    }

    fn lastWrite(f: *WorldFixture, method: []const u8) ?Value {
        var k = f.world.writes.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, f.world.writes.items[k][0], method))
                return json.parseFromSliceLeaky(Value, f.arena.allocator(), f.world.writes.items[k][1], .{}) catch null;
        }
        return null;
    }
};

fn ok(o: tools.Outcome) !Value {
    return switch (o) {
        .ok => |v| v,
        .err => |m| {
            std.debug.print("unexpected tool error: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectErr(o: tools.Outcome, want: []const u8) !void {
    switch (o) {
        .ok => return error.TestExpectedError,
        .err => |m| try testing.expectEqualStrings(want, m),
    }
}

fn expectErrStarts(o: tools.Outcome, want: []const u8) !void {
    switch (o) {
        .ok => return error.TestExpectedError,
        .err => |m| if (!std.mem.startsWith(u8, m, want)) {
            std.debug.print("error was: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

fn sval(v: Value, path: []const []const u8) ?[]const u8 {
    var cur = v;
    for (path) |p| cur = u.get(cur, p) orelse return null;
    return if (cur == .string) cur.string else null;
}

// ---- protocol --------------------------------------------------------------------------

/// `protocol/mcp-tools.json`, read from the repository at test time.
fn sharedCatalog(a: Allocator) ![]const Value {
    const protocol_dir = @import("parity_options").protocol_dir;
    const path = try std.fs.path.join(a, &.{ protocol_dir, "..", "mcp-tools.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20));
    return (try json.parseFromSliceLeaky(Value, a, text, .{})).array.items;
}

test "mcp catalog: tools/list serves protocol/mcp-tools.json exactly: names, order, descriptions and input schemas" {
    const f = try WorldFixture.create(.{ .chat_id = "chat-beta-2" });
    defer f.destroy();
    const a = f.arena.allocator();
    const shared = try sharedCatalog(a);
    try testing.expectEqual(@as(usize, 31), shared.len);
    for (shared) |t| {
        // Exactly these keys, so nothing else could be served.
        try testing.expectEqual(@as(usize, 3), t.object.count());
        try testing.expect(u.str(t, "name") != null and u.str(t, "description") != null);
        try testing.expect(u.get(t, "inputSchema").? == .object);
    }
    // The embedded copy is the file, byte for byte.
    const protocol_dir = @import("parity_options").protocol_dir;
    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(a, &.{ protocol_dir, "..", "mcp-tools.json" }), a, .limited(1 << 20));
    try testing.expectEqualStrings(raw, tools.catalog_json);

    // From a chat: every tool, in the file's order, each exactly as written.
    const served = u.array(u.get(try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(1), "tools/list", .null), .{}), "result").?, "tools").?;
    try testing.expectEqual(shared.len, served.len);
    for (shared, served) |want, got| try testing.expectEqualStrings(try u.stringify(a, want), try u.stringify(a, got));
    // From a terminal: the same, without the two that publish into a chat.
    f.t.origin = .{};
    const plain = u.array(u.get(try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(2), "tools/list", .null), .{}), "result").?, "tools").?;
    var k: usize = 0;
    for (shared) |want| {
        const name = u.str(want, "name").?;
        if (std.mem.eql(u8, name, "show_image") or std.mem.eql(u8, name, "show_visual")) continue;
        try testing.expectEqualStrings(try u.stringify(a, want), try u.stringify(a, plain[k]));
        k += 1;
    }
    try testing.expectEqual(plain.len, k);
}

test "mcp catalog: the shared catalog is the Rust server's tool list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try json.parseFromSliceLeaky(Value, a, tools.catalog_json, .{});
    const want = [_][]const u8{
        "whoami",         "list_devices", "list_projects", "list_harnesses", "list_models",   "list_chats",     "get_chat",
        "create_chat",    "read_chat",    "send_message",  "wait_for_turn",  "interrupt_chat", "dismiss_input", "respond_to_input",
        "rename_chat",    "archive_chat", "show_visual",   "show_image",     "list_rooms",    "create_room",    "join_room",
        "leave_room",     "post_room",    "release_claim", "read_room",      "room_inbox",    "archive_room",   "destroy_room",
        "list_bots",      "run_bot",      "run_due_bots",
    };
    try testing.expectEqual(want.len, all.array.items.len);
    for (all.array.items, want) |t, name| {
        try testing.expectEqualStrings(name, u.str(t, "name").?);
        try testing.expect(u.str(t, "description").?.len > 10);
        try testing.expectEqualStrings("object", sval(t, &.{ "inputSchema", "type" }).?);
        try testing.expect(tools.Tools.has(name));
    }
    try testing.expect(!tools.Tools.has("render_visual"));
    // Spot checks against the Rust schemas.
    const rename = all.array.items[14];
    try testing.expectEqual(@as(usize, 2), u.array(u.get(rename, "inputSchema").?, "required").?.len);
    const image = all.array.items[17];
    try testing.expect(u.boolean(u.get(image, "inputSchema").?, "additionalProperties").? == false);
    try testing.expect(std.mem.indexOf(u8, tools.catalog_json, "secret_detected (rewrite it without the value)") != null);
}

test "mcp protocol: initialize, ping, list, and protocol errors match the Rust server" {
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    const a = f.arena.allocator();
    const init_line = try mcp.handleRequest(&f.t, a, u.i(1), "initialize", try json.parseFromSliceLeaky(Value, a, "{\"protocolVersion\":\"2025-03-26\"}", .{}));
    const init_v = try json.parseFromSliceLeaky(Value, a, init_line, .{});
    try testing.expectEqualStrings("2025-03-26", sval(init_v, &.{ "result", "protocolVersion" }).?);
    try testing.expectEqualStrings("harness", sval(init_v, &.{ "result", "serverInfo", "name" }).?);
    try testing.expect(u.boolean(u.get(u.get(u.get(init_v, "result").?, "capabilities").?, "tools").?, "listChanged").? == false);
    try testing.expect(std.mem.startsWith(u8, sval(init_v, &.{ "result", "instructions" }).?, "Harness runs coding agents"));
    const newest = try mcp.handleRequest(&f.t, a, u.i(2), "initialize", try json.parseFromSliceLeaky(Value, a, "{\"protocolVersion\":\"1999-01-01\"}", .{}));
    try testing.expect(std.mem.indexOf(u8, newest, "\"protocolVersion\":\"2025-06-18\"") != null);

    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}", try mcp.handleRequest(&f.t, a, u.i(3), "ping", .null));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"result\":{\"resources\":[]}}", try mcp.handleRequest(&f.t, a, u.s("r"), "resources/list", .null));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"unknown method: nope\"}}", try mcp.handleRequest(&f.t, a, u.i(4), "nope", .null));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32602,\"message\":\"tools/call needs a tool name\"}}", try mcp.handleRequest(&f.t, a, u.i(5), "tools/call", .null));
    const unknown = try mcp.handleRequest(&f.t, a, u.i(6), "tools/call", try json.parseFromSliceLeaky(Value, a, "{\"name\":\"render_visual\"}", .{}));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32602,\"message\":\"unknown tool: render_visual\"}}", unknown);

    // Without an origin chat, show_image/show_visual are hidden.
    const listed = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(7), "tools/list", .null), .{});
    try testing.expectEqual(@as(usize, 29), u.array(u.get(listed, "result").?, "tools").?.len);
    f.t.origin = .{ .chat_id = "chat-beta-2" };
    const listed2 = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(8), "tools/list", .null), .{});
    try testing.expectEqual(@as(usize, 31), u.array(u.get(listed2, "result").?, "tools").?.len);

    // A tool error is a result with isError, never a protocol error.
    const failed = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(9), "tools/call", try json.parseFromSliceLeaky(Value, a, "{\"name\":\"get_chat\",\"arguments\":{\"chat\":\"nope\"}}", .{})), .{});
    try testing.expect(u.boolean(u.get(failed, "result").?, "isError").?);
    try testing.expect(u.get(u.get(failed, "result").?, "structuredContent") == null);
    // A success carries pretty text and the object as structuredContent.
    const good = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(10), "tools/call", try json.parseFromSliceLeaky(Value, a, "{\"name\":\"list_harnesses\"}", .{})), .{});
    const res = u.get(good, "result").?;
    try testing.expect(!u.boolean(res, "isError").?);
    try testing.expect(std.mem.startsWith(u8, u.str(u.array(res, "content").?[0], "text").?, "{\n  \"harnesses\": ["));
    try testing.expect(u.get(u.get(res, "structuredContent").?, "harnesses") != null);

    switch (try mcp.route(a, "not json")) {
        .reply => |line| try testing.expect(std.mem.startsWith(u8, line, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error: ")),
        else => return error.TestUnexpectedResult,
    }
    switch (try mcp.route(a, "[1]")) {
        .reply => |line| try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"expected a JSON-RPC object\"}}", line),
        else => return error.TestUnexpectedResult,
    }
    switch (try mcp.route(a, "{\"jsonrpc\":\"2.0\"}")) {
        .reply => |line| try testing.expect(std.mem.indexOf(u8, line, "missing method") != null),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect((try mcp.route(a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == .none);
    try testing.expect((try mcp.route(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")) == .none);
    try testing.expect((try mcp.route(a, "  ")) == .none);
}

test "mcp protocol: config reads the port and origin from the environment" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(@as(u16, 27664), mcp.Config.fromEnv(&env).ipc_port);
    try env.put("HARNESS_IPC_PORT", "27990");
    try env.put("HARNESS_CHAT_ID", "  chat-1 \n");
    try env.put("HARNESS_DEVICE_ID", "");
    const cfg = mcp.Config.fromEnv(&env);
    try testing.expectEqual(@as(u16, 27990), cfg.ipc_port);
    try testing.expectEqualStrings("chat-1", cfg.origin.chat_id.?);
    try testing.expect(cfg.origin.device_id == null);
}

test "mcp protocol: stdio serving answers concurrently and finishes in-flight requests at EOF" {
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    var input = std.Io.Reader.fixed(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
            "\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"whoami\"}}\n" ++
            "garbage\n",
    );
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var server: mcp.Server = .{ .gpa = testing.allocator, .io = testing.io, .tools = f.t, .out = &out.writer };
    try server.serve(&input);
    const written = out.written();
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, written, "\n"));
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":1,\"result\":{\"protocolVersion\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":2,\"result\":{\"content\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "-32700") != null);
}

/// The id-sorted lines `serve` wrote, each parsed.
fn servedLines(a: Allocator, written: []const u8) ![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var it = std.mem.splitScalar(u8, written, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try out.append(a, try json.parseFromSliceLeaky(Value, a, line, .{}));
    }
    std.mem.sort(Value, out.items, {}, struct {
        fn lt(_: void, x: Value, y: Value) bool {
            return (u.int(x, "id") orelse -1) < (u.int(y, "id") orelse -1);
        }
    }.lt);
    return out.items;
}

test "mcp protocol: a 1 MiB request line is answered; a line over the cap is refused and serving goes on" {
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    const gpa = testing.allocator;
    const a = f.arena.allocator();
    // A 1 MiB argument, then a line one byte over the 16 MiB cap, then a ping.
    const pad = try a.alloc(u8, 1024 * 1024);
    @memset(pad, 'p');
    const over = try a.alloc(u8, mcp.max_line_bytes + 1);
    @memset(over, 'x');
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try input.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"list_models\",\"arguments\":{{\"harness\":\"claude-code\",\"pad\":\"{s}\"}}}}}}\n", .{pad});
    try input.appendSlice(gpa, over);
    try input.appendSlice(gpa, "\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}");
    // Through a 64 KiB buffer, as stdin is read.
    var small: [64 * 1024]u8 = undefined;
    var stdin_like = std.testing.Reader.init(&small, &.{.{ .buffer = input.items }});
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server: mcp.Server = .{ .gpa = gpa, .io = testing.io, .tools = f.t, .out = &out.writer };
    try server.serve(&stdin_like.interface);
    const lines = try servedLines(a, out.written());
    try testing.expectEqual(@as(usize, 3), lines.len);
    // The refusal has no id; it sorts first.
    try testing.expect(u.get(lines[0], "id").? == .null);
    try testing.expectEqual(@as(i64, -32600), u.int(u.get(lines[0], "error").?, "code").?);
    try testing.expectEqualStrings("request line longer than 16777216 bytes", sval(lines[0], &.{ "error", "message" }).?);
    try testing.expectEqual(@as(i64, 1), u.int(lines[1], "id").?);
    try testing.expectEqualStrings("claude-code", sval(lines[1], &.{ "result", "structuredContent", "harness" }).?);
    try testing.expectEqual(@as(i64, 3), u.int(lines[2], "id").?);
    try testing.expect(u.get(lines[2], "result") != null);
}

/// Stdin that hands over one line at a time, each only after every
/// earlier request was answered, and notes how many were still in flight.
const PacedInput = struct {
    interface: std.Io.Reader,
    lines: []const []const u8,
    next: usize = 0,
    offset: usize = 0,
    server: *mcp.Server = undefined,
    out: *std.Io.Writer.Allocating = undefined,
    max_in_flight_between: usize = 0,
    waited_too_long: bool = false,

    fn init(buffer: []u8, lines: []const []const u8) PacedInput {
        return .{ .lines = lines, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn answered(self: *PacedInput) usize {
        self.server.out_lock.lockUncancelable(testing.io);
        defer self.server.out_lock.unlock(testing.io);
        return std.mem.count(u8, self.out.written(), "\n");
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PacedInput = @alignCast(@fieldParentPtr("interface", r));
        if (self.next == self.lines.len) return error.EndOfStream;
        if (self.offset == 0 and self.next > 0) {
            var waited: u32 = 0;
            while (self.answered() < self.next) : (waited += 5) {
                if (waited >= 5000) {
                    self.waited_too_long = true;
                    return error.EndOfStream;
                }
                std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
            }
            // A worker retires right after writing its reply.
            if (@hasDecl(mcp.Server, "inFlight")) {
                var retired: u32 = 0;
                while (self.server.inFlight() != 0) : (retired += 5) {
                    if (retired >= 2000) {
                        self.max_in_flight_between = @max(self.max_in_flight_between, self.server.inFlight());
                        break;
                    }
                    std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
                }
            }
        }
        const line = self.lines[self.next];
        const n = try w.write(limit.sliceConst(line[self.offset..]));
        self.offset += n;
        if (self.offset == line.len) {
            self.next += 1;
            self.offset = 0;
        }
        return n;
    }
};

test "mcp protocol: a finished request leaves no thread or record behind during a long session" {
    // Serving keeps a count of requests in flight, not a list of threads
    // that only EOF would join.
    try testing.expect(!@hasField(mcp.Server, "workers"));
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    const a = f.arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    for (0..25) |k| try lines.append(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"ping\"}}\n", .{k + 1}));
    var buf: [256]u8 = undefined;
    var input = PacedInput.init(&buf, lines.items);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var server: mcp.Server = .{ .gpa = testing.allocator, .io = testing.io, .tools = f.t, .out = &out.writer };
    input.server = &server;
    input.out = &out;
    try server.serve(&input.interface);
    try testing.expect(!input.waited_too_long);
    try testing.expectEqual(@as(usize, 25), std.mem.count(u8, out.written(), "\n"));
    try testing.expectEqual(@as(usize, 0), input.max_in_flight_between);
    if (@hasDecl(mcp.Server, "inFlight")) try testing.expectEqual(@as(usize, 0), server.inFlight());
}

test "mcp protocol: line reading keeps a line of exactly the cap and refuses one byte more" {
    const gpa = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    var small: [2]u8 = undefined;
    var r = std.testing.Reader.init(&small, &.{.{ .buffer = "abcd\nabcde\nab\r\n\nlast" }});
    try testing.expectEqualStrings("abcd", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expect((try mcp.nextLine(&r.interface, &buf, 4)) == .too_long);
    try testing.expectEqualStrings("ab\r", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expectEqualStrings("", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expectEqualStrings("last", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expect((try mcp.nextLine(&r.interface, &buf, 4)) == .end);
    // An over-cap line the input ends inside.
    var tail = std.Io.Reader.fixed("abcdefgh");
    try testing.expect((try mcp.nextLine(&tail, &buf, 4)) == .too_long);
    try testing.expect((try mcp.nextLine(&tail, &buf, 4)) == .end);
}

// ---- chat tools against the in-process engine ---------------------------------------------

test "mcp whoami: speaks for the origin chat, or says it has none" {
    const f = try HostFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer f.destroy();
    const v = try ok(try f.call("whoami", "{}"));
    try testing.expectEqualStrings("chat-beta-2", sval(v, &.{ "chat", "id" }).?);
    try testing.expectEqualStrings("comet", sval(v, &.{ "chat", "project", "name" }).?);
    try testing.expectEqualStrings("dev-local", u.str(v, "localDeviceId").?);
    try testing.expectEqualStrings("dev-local", u.str(v, "originDeviceId").?);
    try testing.expectEqualStrings(f.host.workspace_scope, u.str(v, "workspaceScope").?);
    try testing.expect(std.mem.startsWith(u8, u.str(v, "note").?, "Messages you send are attributed"));

    f.t.origin = .{ .chat_id = "chat-unknown" };
    const lost = try ok(try f.call("whoami", "{}"));
    try testing.expectEqualStrings("chat-unknown", sval(lost, &.{ "chat", "id" }).?);
    try testing.expect(u.get(u.get(lost, "chat").?, "title") == null);

    f.t.origin = .{};
    const term = try ok(try f.call("whoami", "{}"));
    try testing.expect(u.get(term, "chat").? == .null);
    try testing.expectEqualStrings("Not running inside a chat: messages are sent without attribution.", u.str(term, "note").?);

    // No engine listening: the Rust client's wording.
    var ws_link = link.WsEngine.init(testing.allocator, testing.io, 1);
    defer ws_link.deinit();
    f.t.engine = ws_link.engine();
    try expectErrStarts(try f.call("whoami", "{}"), "no Harness engine listening at ws://127.0.0.1:1 (");
}

test "mcp listing: devices, projects, harnesses and models" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    const devs = try ok(try f.call("list_devices", "{}"));
    const d0 = u.array(devs, "devices").?[0];
    try testing.expectEqualStrings("dev-local", u.str(d0, "id").?);
    try testing.expectEqualStrings("Laptop", u.str(d0, "name").?);
    try testing.expect(u.boolean(d0, "local").?);

    const projects = u.array(try ok(try f.call("list_projects", "{}")), "projects").?;
    try testing.expectEqual(@as(usize, 2), projects.len);
    try testing.expectEqualStrings("comet", u.str(projects[0], "name").?);
    try testing.expectEqualStrings("iOS", u.str(projects[1], "name").?);
    try testing.expectEqualStrings("Laptop", u.str(projects[0], "deviceName").?);
    try testing.expect(u.boolean(projects[0], "git").?);

    const hs = u.array(try ok(try f.call("list_harnesses", "{}")), "harnesses").?;
    var saw_mock = false;
    for (hs) |h| if (std.mem.eql(u8, u.str(h, "id").?, "mock")) {
        saw_mock = true;
        try testing.expect(!u.boolean(h, "available").?);
    };
    try testing.expect(saw_mock);
    try testing.expect(u.boolean(hs[0], "steersMidTurn").?);

    const models = try ok(try f.call("list_models", "{\"harness\":\" claude-code \"}"));
    try testing.expectEqualStrings("claude-code", u.str(models, "harness").?);
    try testing.expect(u.array(models, "models").?.len > 0);
    try expectErr(try f.call("list_models", "{\"harness\":\"emacs\"}"), "unknown harness: \"emacs\"");
    try expectErr(try f.call("list_models", "{}"), "invalid arguments: missing field `harness`");
    try expectErr(try f.call("list_models", "{\"harness\":3}"), "invalid arguments: invalid type: integer `3`, expected a string");
}

test "mcp list_chats: filters, archive visibility, parent, order and limit" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    const all = try ok(try f.call("list_chats", "{}"));
    try testing.expectEqual(@as(i64, 2), u.int(all, "total").?);
    const rows = u.array(all, "chats").?;
    // Newest activity first: Beta then Alpha.
    try testing.expectEqualStrings("chat-beta-2", u.str(rows[0], "id").?);
    try testing.expectEqualStrings("idle", u.str(rows[0], "status").?);
    try testing.expectEqualStrings("/repo/comet", u.str(rows[1], "cwd").?);
    try testing.expectEqualStrings("claude-code", u.str(rows[1], "harness").?);
    try testing.expectEqualStrings("opus", u.str(rows[1], "model").?);

    try testing.expectEqual(@as(i64, 3), u.int(try ok(try f.call("list_chats", "{\"include_archived\":true}")), "total").?);
    try testing.expectEqual(@as(i64, 1), u.int(try ok(try f.call("list_chats", "{\"include_archived\":true,\"project\":\"ios\"}")), "total").?);
    try testing.expectEqual(@as(i64, 2), u.int(try ok(try f.call("list_chats", "{\"device\":\"laptop\"}")), "total").?);
    const limited = try ok(try f.call("list_chats", "{\"limit\":1}"));
    try testing.expectEqual(@as(i64, 2), u.int(limited, "total").?);
    try testing.expectEqual(@as(usize, 1), u.array(limited, "chats").?.len);

    f.chat("chat-beta-2").parent_chat_id = try f.host.gpa.dupe(u8, "chat-alpha-1");
    const kids = try ok(try f.call("list_chats", "{\"parent\":\"Alpha\"}"));
    try testing.expectEqual(@as(i64, 1), u.int(kids, "total").?);

    try expectErr(try f.call("list_chats", "{\"project\":\"GitHub\"}"), "no project matches \"GitHub\" (id, path, or name); try list_projects");
    try expectErr(try f.call("list_chats", "{\"device\":\"phone\"}"), "no device matches \"phone\"; known: Laptop (dev-local)");
    try expectErr(try f.call("list_chats", "{\"limit\":-1}"), "invalid arguments: invalid value: integer `-1`, expected usize");
    try expectErr(try f.call("list_chats", "{\"include_archived\":null}"), "invalid arguments: invalid type: null, expected a boolean");
}

test "mcp resolution: id, prefix, title; project by id, path, name or suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    var c: tools.Ctx = .{ .t = &f.t, .a = a };
    const chats = (try json.parseFromSliceLeaky(Value, a,
        \\[{"id":"aaaa1111-1","title":"Fix login"},{"id":"aaaa2222-2","title":"Fix Login"},{"id":"bbbb3333-3","title":"Docs"}]
    , .{})).array.items;
    try testing.expectEqualStrings("bbbb3333-3", u.str(try tools.resolveChatIn(&c, chats, "bbbb3333-3"), "id").?);
    try testing.expectEqualStrings("bbbb3333-3", u.str(try tools.resolveChatIn(&c, chats, "bbbb"), "id").?);
    try testing.expectEqualStrings("bbbb3333-3", u.str(try tools.resolveChatIn(&c, chats, "docs"), "id").?);
    try testing.expectError(error.ToolFailed, tools.resolveChatIn(&c, chats, "aaaa"));
    try testing.expectEqualStrings("2 chats start with \"aaaa\"; be more specific: aaaa1111, aaaa2222", c.msg);
    try testing.expectError(error.ToolFailed, tools.resolveChatIn(&c, chats, "fix login"));
    try testing.expectEqualStrings("2 chats are titled \"fix login\"; use an id: aaaa1111, aaaa2222", c.msg);
    try testing.expectError(error.ToolFailed, tools.resolveChatIn(&c, chats, "zzz"));
    try testing.expectEqualStrings("no chat matches \"zzz\" (id, id prefix, or exact title); try list_chats", c.msg);

    const spaces = (try json.parseFromSliceLeaky(Value, a,
        \\[{"id":"s1","path":"/home/u/GitHub/comet"},{"id":"s2","path":"/home/u/GitHub/comet-ios","name":"iOS"}]
    , .{})).array.items;
    try testing.expectEqualStrings("s2", u.str(try tools.resolveSpaceIn(&c, spaces, "s2"), "id").?);
    try testing.expectEqualStrings("s1", u.str(try tools.resolveSpaceIn(&c, spaces, "/home/u/GitHub/comet"), "id").?);
    try testing.expectEqualStrings("s2", u.str(try tools.resolveSpaceIn(&c, spaces, "ios"), "id").?);
    try testing.expectEqualStrings("s2", u.str(try tools.resolveSpaceIn(&c, spaces, "comet-ios"), "id").?);
    try testing.expectEqualStrings("s1", u.str(try tools.resolveSpaceIn(&c, spaces, "comet"), "id").?);
    try testing.expectError(error.ToolFailed, tools.resolveSpaceIn(&c, spaces, "GitHub"));
    try testing.expectEqualStrings("2 projects match \"GitHub\"; use an id: /home/u/GitHub/comet (s1), /home/u/GitHub/comet-ios (s2)", c.msg);
    try testing.expectError(error.ToolFailed, tools.resolveSpaceIn(&c, spaces, ""));
    try testing.expectEqualStrings("project is required", c.msg);
    try testing.expectError(error.ToolFailed, c.resolveChat("  "));
    try testing.expectEqualStrings("chat is required", c.msg);
}

test "mcp get_chat and read_chat: metadata, transcript window and pending input" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    // Two turns through the engine's own command path.
    for ([_][]const u8{ "first task", "second task" }) |prompt| {
        const cmd = try std.fmt.allocPrint(f.arena.allocator(), "{{\"chatId\":\"chat-alpha-1\",\"command\":{{\"kind\":\"run\",\"messageId\":\"m-{s}\",\"request\":{{\"prompt\":\"{s}\",\"cwd\":\"{s}/home\"}}}}}}", .{ prompt[0..5], prompt, f.base });
        _ = try f.host_link.engine().call(f.arena.allocator(), "QueueCommand", cmd);
        try f.settle();
    }
    const got = try ok(try f.call("get_chat", "{\"chat\":\"alpha\"}"));
    try testing.expectEqualStrings("chat-alpha-1", u.str(got, "id").?);
    try testing.expectEqual(@as(i64, 4), u.int(got, "messageCount").?);
    try testing.expect(u.get(got, "pendingInput").? == .null);
    try testing.expectEqualStrings("assistant", sval(got, &.{ "lastMessage", "role" }).?);
    try testing.expectEqualStrings("Reply to: second task", sval(got, &.{ "lastMessage", "text" }).?);

    const page = try ok(try f.call("read_chat", "{\"chat\":\"chat-alpha\",\"limit\":2,\"offset\":1}"));
    try testing.expectEqual(@as(i64, 4), u.int(page, "total").?);
    try testing.expectEqual(@as(i64, 2), u.int(page, "returned").?);
    try testing.expectEqual(@as(i64, 1), u.int(page, "olderRemaining").?);
    try testing.expectEqual(@as(i64, 1), u.int(page, "newerSkipped").?);
    const msgs = u.array(page, "messages").?;
    try testing.expectEqualStrings("Reply to: first task", u.str(msgs[0], "text").?);
    try testing.expectEqualStrings("second task", u.str(msgs[1], "text").?);

    try expectErr(try f.call("get_chat", "{\"chat\":\"chat-\"}"), "3 chats start with \"chat-\"; be more specific: chat-alp, chat-bet, chat-gam");
    try expectErr(try f.call("get_chat", "{}"), "invalid arguments: missing field `chat`");
    try expectErr(try f.call("get_chat", "[]"), "invalid arguments: invalid type: sequence, expected struct ChatArgs");
    try expectErr(try f.call("read_chat", "{\"chat\":\"Alpha\",\"offset\":\"2\"}"), "invalid arguments: invalid type: string \"2\", expected usize");
}

test "mcp create_chat: writes the row, records the parent, validates harness, model, reasoning and sandbox" {
    const f = try HostFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer f.destroy();
    const v = try ok(try f.call("create_chat", "{\"project\":\"comet\",\"harness\":\"claude-code\",\"model\":\"claude-opus-5-5\",\"reasoning\":\"high\",\"title\":\"  Spawned  \",\"branch\":\"feat\"}"));
    const new_id = u.str(v, "chatId").?;
    try testing.expectEqual(@as(usize, 36), new_id.len);
    try testing.expectEqualStrings("chat-beta-2", u.str(v, "parentChatId").?);
    try testing.expectEqualStrings("comet", sval(v, &.{ "project", "name" }).?);
    try testing.expectEqualStrings("  Spawned  ", u.str(v, "title").?);
    const create = f.rec.log.items[f.rec.log.items.len - 2];
    try testing.expectEqualStrings("Mutate", create[0]);
    const cp = try json.parseFromSliceLeaky(Value, f.arena.allocator(), create[1], .{});
    try testing.expectEqualStrings("createChat", u.str(cp, "op").?);
    try testing.expectEqualStrings("chat-beta-2", u.str(cp, "parentChatId").?);
    try testing.expectEqualStrings("space-1", u.str(cp, "spaceId").?);
    try testing.expectEqualStrings("feat", u.str(cp, "branch").?);
    try testing.expectEqualStrings("workspace-write", sval(cp, &.{ "config", "sandbox" }).?);
    try testing.expectEqualStrings("Spawned", u.str(f.rec.last("Mutate").?, "title").?);
    // The engine has the row now, with its parent and host device.
    const stored = try ok(try f.call("get_chat", try std.fmt.allocPrint(f.arena.allocator(), "{{\"chat\":\"{s}\"}}", .{new_id})));
    try testing.expectEqualStrings("Spawned", u.str(stored, "title").?);
    try testing.expectEqualStrings("chat-beta-2", u.str(stored, "parentChatId").?);
    try testing.expectEqualStrings("dev-local", u.str(stored, "deviceId").?);
    try testing.expectEqualStrings("chat-beta-2", f.chat(new_id).parent_chat_id.?);
    // Listed among the parent's children.
    const kids = u.array(try ok(try f.call("list_chats", "{\"parent\":\"Beta\"}")), "chats").?;
    try testing.expectEqual(@as(usize, 1), kids.len);
    try testing.expectEqualStrings(new_id, u.str(kids[0], "id").?);

    // A first prompt runs right away; from a chat, the wait is a snapshot.
    const run = try ok(try f.call("create_chat", "{\"device\":\"Laptop\",\"harness\":\"graff\",\"prompt\":\"say hi\",\"wait\":true}"));
    try testing.expectEqualStrings("run", sval(run, &.{ "sent", "delivery" }).?);
    try testing.expectEqualStrings("idle", sval(run, &.{ "sent", "chatStatusAtSend" }).?);
    const queued = f.rec.last("QueueCommand").?;
    try testing.expectEqualStrings("peer", sval(queued, &.{ "command", "request", "turnOrigin" }).?);
    try testing.expectEqualStrings("~", sval(queued, &.{ "command", "request", "cwd" }).?);
    try testing.expect(u.get(run, "turn") != null);

    try expectErr(try f.call("create_chat", "{\"harness\":\"emacs\"}"), "unknown harness: \"emacs\"");
    try expectErr(try f.call("create_chat", "{\"harness\":\"mock\"}"), "harness mock is not available on this device (see list_harnesses)");
    try expectErrStarts(try f.call("create_chat", "{\"harness\":\"claude-code\",\"model\":\"gpt-9\"}"), "model \"gpt-9\" is not offered by ClaudeCode; available: ");
    try expectErr(try f.call("create_chat", "{\"reasoning\":\"loud\"}"), "unknown reasoning level: \"loud\"");
    try expectErr(try f.call("create_chat", "{\"sandbox\":\"none\"}"), "unknown sandbox: \"none\"");
    try expectErr(try f.call("create_chat", "{\"project\":\"nowhere\"}"), "no project matches \"nowhere\" (id, path, or name); try list_projects");
    try expectErr(try f.call("create_chat", "{\"parent\":\"nobody\"}"), "no chat matches \"nobody\" (id, id prefix, or exact title); try list_chats");
    try expectErr(try f.call("create_chat", "{\"wait\":\"yes\"}"), "invalid arguments: invalid type: string \"yes\", expected a boolean");
}

test "mcp send_message: runs an idle chat, attributes the sender, refuses self, archived and queued repeats" {
    const f = try HostFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer f.destroy();
    const v = try ok(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"  review the diff  \"}"));
    try testing.expectEqualStrings("chat-alpha-1", u.str(v, "chatId").?);
    try testing.expectEqualStrings("run", sval(v, &.{ "sent", "delivery" }).?);
    const cmd = f.rec.last("QueueCommand").?;
    const prompt = sval(cmd, &.{ "command", "request", "prompt" }).?;
    try testing.expect(std.mem.startsWith(u8, prompt, "[Message from Harness chat Beta (chat-bet). Sender chat: chat-beta-2. Relay depth: 1/4."));
    try testing.expect(std.mem.endsWith(u8, prompt, "]\n\nreview the diff"));
    try testing.expectEqualStrings("/repo/comet", sval(cmd, &.{ "command", "request", "cwd" }).?);
    try testing.expectEqualStrings("opus", sval(cmd, &.{ "command", "request", "model" }).?);
    try testing.expectEqualStrings("claude-code", sval(cmd, &.{ "command", "request", "harness" }).?);

    try expectErr(try f.call("send_message", "{\"chat\":\"Beta\",\"text\":\"hi\"}"), "refusing to send a message to your own chat (chat-bet)");
    try expectErr(try f.call("send_message", "{\"chat\":\"Gamma\",\"text\":\"hi\"}"), "no message was sent to chat chat-gam: " ++ tools.archived_refusal);
    try expectErr(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"  \"}"), "text is empty");
    try expectErr(try f.call("send_message", "{\"chat\":\"Alpha\"}"), "invalid arguments: missing field `text`");
    try expectErr(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"x\",\"mode\":\"shout\"}"), "unknown mode \"shout\"; expected auto, run, steer, or queue");

    // Our earlier message still queued there: no pile-up.
    _ = try ok(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"held\",\"mode\":\"queue\"}"));
    const queued = f.rec.last("QueueMessage").?;
    try testing.expect(u.boolean(queued, "holdForTurnEnd").?);
    try testing.expectEqualStrings("peer", u.str(queued, "turnOrigin").?);
    try testing.expectEqualStrings("chat-beta-2", u.str(queued, "peerChatId").?);
    try expectErrStarts(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"again\"}"), "your earlier message is still queued in chat chat-alp; no new message was sent.");
}

test "mcp send_message: steering, queueing and the waiting-for-an-answer refusal follow the live status" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    // claude-code steers mid-turn.
    try f.setStatus("chat-alpha-1", "working", host_now - 1_000);
    const steer = try ok(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"also check tests\"}"));
    try testing.expectEqualStrings("steer", sval(steer, &.{ "sent", "delivery" }).?);
    try testing.expectEqualStrings("working", sval(steer, &.{ "sent", "chatStatusAtSend" }).?);
    // Without an origin, the text goes as written.
    try testing.expectEqualStrings("also check tests", sval(f.rec.last("QueueCommand").?, &.{ "command", "prompt" }).?);
    // No turn was live, so the engine ran the steer as a turn.
    try f.settle();

    // A stale working row reads as idle: it runs.
    try f.setStatus("chat-alpha-1", "working", host_now - 60_000);
    const stale = try ok(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"still there?\"}"));
    try testing.expectEqualStrings("run", sval(stale, &.{ "sent", "delivery" }).?);
    try testing.expectEqualStrings("working (stale — host may be offline)", sval(stale, &.{ "sent", "chatStatusAtSend" }).?);
    try f.settle();

    try f.setStatus("chat-alpha-1", "awaitingInput", host_now - 1_000);
    try expectErr(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"hi\"}"), "chat chat-alp is waiting for an answer; use respond_to_input (or mode 'queue' to hold this message for after the turn)");
    const held = try ok(try f.call("send_message", "{\"chat\":\"Alpha\",\"text\":\"hi\",\"mode\":\"queue\"}"));
    try testing.expectEqualStrings("queue", sval(held, &.{ "sent", "delivery" }).?);
    try testing.expect(u.str(u.get(held, "sent").?, "id").?.len > 0);
}

test "mcp send_message: a working graff chat here gets peer-inbox mail, falling back to the queue" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    try f.setStatus("chat-beta-2", "working", host_now - 1_000);
    f.chat("chat-beta-2").harness_session_id = try f.host.gpa.dupe(u8, "acp-session-9");
    // The Zig engine lists graff as steering mid-turn (`step-boundary`), so a
    // working graff chat is steered, not sent peer-inbox mail.
    const steered = try ok(try f.call("send_message", "{\"chat\":\"Beta\",\"text\":\"ping\"}"));
    try testing.expectEqualStrings("steer", sval(steered, &.{ "sent", "delivery" }).?);
    try testing.expectEqual(@as(usize, 0), f.peer.sends.items.len);

    // With the row's device (as the Rust engine reports it), the inbox is used.
    const w = try WorldFixture.create(.{});
    defer w.destroy();
    w.world.extra_chats = ",{\"id\":\"chat-delta-4\",\"deviceId\":\"dev-local\",\"title\":\"Delta\",\"archived\":false,\"harnessSessionId\":\"acp-9\",\"config\":{\"harness\":\"graff\",\"sandbox\":\"workspace-write\"},\"createdAt\":\"2026-09-03T00:00:00Z\"}";
    w.world.sessions = "[{\"chatId\":\"chat-delta-4\",\"deviceId\":\"dev-local\",\"status\":\"working\",\"updatedAt\":\"2026-11-10T00:04:58Z\"}]";
    w.t.fixed_now_ms = u.parseRfc3339Ms("2026-11-10T00:05:00Z").?;
    const sent = try ok(try w.call("send_message", "{\"chat\":\"Delta\",\"text\":\"ping\"}"));
    try testing.expectEqualStrings("peer", sval(sent, &.{ "sent", "delivery" }).?);
    try testing.expectEqualStrings("acp-9", sval(sent, &.{ "sent", "id" }).?);
    try testing.expectEqualStrings("delivered to peer inbox", sval(sent, &.{ "sent", "detail" }).?);
    try testing.expectEqualStrings("harness", w.peer.sends.items[0][0]);
    try testing.expectEqualStrings("ping", w.peer.sends.items[0][2]);

    w.peer.fail = "graff peer send failed: no such session";
    const fell = try ok(try w.call("send_message", "{\"chat\":\"Delta\",\"text\":\"ping\"}"));
    try testing.expectEqualStrings("queue", sval(fell, &.{ "sent", "delivery" }).?);
    try testing.expectEqualStrings("q-1", sval(fell, &.{ "sent", "id" }).?);
    try testing.expectEqualStrings("graff peer send failed: no such session", sval(fell, &.{ "sent", "peerFallback" }).?);

    // From a chat, the hop is recorded first; a ledger that cannot record
    // turns into the fallback, never a silent send.
    w.peer.fail = null;
    w.t.origin = .{ .chat_id = "chat-beta-2", .device_id = "dev-local" };
    const unrecorded = try ok(try w.call("send_message", "{\"chat\":\"Delta\",\"text\":\"ping\"}"));
    try testing.expectEqualStrings("relay depth not recorded: no home directory for the relay ledger", sval(unrecorded, &.{ "sent", "peerFallback" }).?);
}

test "mcp wait_for_turn: idle answers at once; a chat caller gets a snapshot with the end-your-turn note" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    const idle = try ok(try f.call("wait_for_turn", "{\"chat\":\"Beta\",\"timeout_secs\":5}"));
    try testing.expectEqualStrings("completed", sval(idle, &.{ "turn", "outcome" }).?);
    try testing.expect(!u.boolean(u.get(idle, "turn").?, "timedOut").?);

    try f.setStatus("chat-beta-2", "working", host_now - 1_000);
    // In-process, nothing changes while the caller waits: the deadline passes.
    const busy = try ok(try f.call("wait_for_turn", "{\"chat\":\"Beta\",\"timeout_secs\":1}"));
    try testing.expectEqualStrings("timedOut", sval(busy, &.{ "turn", "outcome" }).?);
    try testing.expect(u.get(u.get(busy, "turn").?, "note") == null);

    f.t.origin = .{ .chat_id = "chat-alpha-1" };
    const snap = try ok(try f.call("wait_for_turn", "{\"chat\":\"Beta\"}"));
    try testing.expectEqualStrings("timedOut", sval(snap, &.{ "turn", "outcome" }).?);
    try testing.expectEqualStrings(tools.chat_wait_note, sval(snap, &.{ "turn", "note" }).?);
    try expectErr(try f.call("wait_for_turn", "{\"chat\":\"Beta\",\"timeout_secs\":-5}"), "invalid arguments: invalid value: integer `-5`, expected u64");
}

test "mcp wait rules: a send in flight waits for the turn past its baseline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = struct {
        fn row(al: Allocator, text: []const u8) !Value {
            return json.parseFromSliceLeaky(Value, al, text, .{});
        }
    }.row;
    const base = try p(a, "{\"status\":\"idle\",\"updatedAt\":\"2026-11-10T00:00:00Z\",\"lastCompletedTurn\":\"t1\"}");
    const same = try p(a, "{\"status\":\"idle\",\"updatedAt\":\"2026-11-10T00:00:00Z\",\"lastCompletedTurn\":\"t1\"}");
    const working = try p(a, "{\"status\":\"working\",\"updatedAt\":\"2026-11-10T00:00:05Z\",\"lastCompletedTurn\":\"t1\"}");
    const done = try p(a, "{\"status\":\"idle\",\"updatedAt\":\"2026-11-10T00:00:09Z\",\"lastCompletedTurn\":\"t2\"}");
    const asking = try p(a, "{\"status\":\"awaitingInput\",\"updatedAt\":\"2026-11-10T00:00:09Z\",\"lastCompletedTurn\":\"t1\"}");

    // Snapshots (a chat caller's zero timeout).
    try testing.expectEqual(tools.TurnOutcome.completed, tools.snapshotOutcome(null, null, false));
    try testing.expectEqual(tools.TurnOutcome.timedOut, tools.snapshotOutcome(null, null, true));
    try testing.expectEqual(tools.TurnOutcome.timedOut, tools.snapshotOutcome(same, base, true));
    try testing.expectEqual(tools.TurnOutcome.completed, tools.snapshotOutcome(done, base, true));
    try testing.expectEqual(tools.TurnOutcome.awaitingInput, tools.snapshotOutcome(asking, base, true));
    try testing.expectEqual(tools.TurnOutcome.completed, tools.snapshotOutcome(same, null, false));
    try testing.expectEqual(tools.TurnOutcome.timedOut, tools.snapshotOutcome(working, null, false));

    // The stream: an unchanged idle row keeps waiting; working then idle ends.
    var w: tools.TurnWatch = .{ .baseline = base, .expect_turn = true };
    try testing.expectEqual(@as(?tools.TurnOutcome, null), w.observe(null));
    try testing.expectEqual(@as(?tools.TurnOutcome, null), w.observe(same));
    try testing.expectEqual(@as(?tools.TurnOutcome, null), w.observe(working));
    try testing.expectEqual(@as(?tools.TurnOutcome, .completed), w.observe(same));
    var w2: tools.TurnWatch = .{ .baseline = base, .expect_turn = true };
    try testing.expectEqual(@as(?tools.TurnOutcome, .completed), w2.observe(done));
    var w3: tools.TurnWatch = .{ .baseline = null, .expect_turn = false };
    try testing.expectEqual(@as(?tools.TurnOutcome, .completed), w3.observe(null));
    var w4: tools.TurnWatch = .{ .baseline = base, .expect_turn = true };
    try testing.expectEqual(@as(?tools.TurnOutcome, .awaitingInput), w4.observe(asking));
}

test "mcp wait rules: a completion marker counts as a string or a number, and a coalesced watch that never shows working completes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = struct {
        fn row(al: Allocator, marker: []const u8, at: []const u8) !Value {
            return json.parseFromSliceLeaky(Value, al, try std.fmt.allocPrint(al, "{{\"status\":\"idle\",\"updatedAt\":\"2026-11-10T00:00:{s}Z\",\"lastCompletedTurn\":{s}}}", .{ at, marker }), .{});
        }
    }.row;
    // Each encoding: the baseline, the same marker again, and the next turn's
    // marker arriving straight away (the working rows coalesced away).
    const cases = [_][3][]const u8{
        .{ "\"asst-1\"", "\"asst-1\"", "\"asst-2\"" },
        .{ "7", "7", "8" },
    };
    for (cases) |c| {
        const base = try p(a, c[0], "00");
        const same = try p(a, c[1], "00");
        const next = try p(a, c[2], "09");
        // The stream.
        var w: tools.TurnWatch = .{ .baseline = base, .expect_turn = true };
        try testing.expectEqual(@as(?tools.TurnOutcome, null), w.observe(same));
        try testing.expectEqual(@as(?tools.TurnOutcome, .completed), w.observe(next));
        try testing.expect(!w.saw_working);
        // A first send (no baseline row): a marker at all is a finished turn.
        var first: tools.TurnWatch = .{ .baseline = null, .expect_turn = true };
        try testing.expectEqual(@as(?tools.TurnOutcome, .completed), first.observe(next));
        // The zero-timeout snapshot.
        try testing.expectEqual(tools.TurnOutcome.completed, tools.snapshotOutcome(next, base, true));
        try testing.expectEqual(tools.TurnOutcome.timedOut, tools.snapshotOutcome(same, base, true));
        if (@hasDecl(tools, "turnMarker")) try testing.expect(tools.turnMarker(next) != null);
    }
    // Raw values: a string never equals the number it spells, and null is
    // the same as no marker.
    var mixed: tools.TurnWatch = .{ .baseline = try p(a, "\"7\"", "00"), .expect_turn = true };
    try testing.expectEqual(@as(?tools.TurnOutcome, .completed), mixed.observe(try p(a, "7", "00")));
    const none = try json.parseFromSliceLeaky(Value, a, "{\"status\":\"idle\",\"updatedAt\":\"2026-11-10T00:00:00Z\"}", .{});
    var nulls: tools.TurnWatch = .{ .baseline = none, .expect_turn = true };
    try testing.expectEqual(@as(?tools.TurnOutcome, null), nulls.observe(try p(a, "null", "00")));
    if (@hasDecl(tools, "turnMarker")) try testing.expect(tools.turnMarker(try p(a, "null", "00")) == null);
}

test "mcp commands: interrupt, respond, dismiss, rename and archive reach the engine" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    const stop = try ok(try f.call("interrupt_chat", "{\"chat\":\"Alpha\"}"));
    try testing.expectEqualStrings("chat-alpha-1", u.str(stop, "chatId").?);
    try testing.expectEqualStrings("interrupt", sval(f.rec.last("QueueCommand").?, &.{ "command", "kind" }).?);
    try expectErr(try f.call("interrupt_chat", "{\"chat\":\"nobody\"}"), "no chat matches \"nobody\" (id, id prefix, or exact title); try list_chats");

    try expectErr(try f.call("respond_to_input", "{\"chat\":\"Alpha\",\"answers\":[]}"), "chat chat-alp has no pending question");
    try expectErr(try f.call("respond_to_input", "{\"chat\":\"Alpha\",\"request_id\":\"req-1\"}"), "answers is empty");
    try expectErr(try f.call("respond_to_input", "{\"chat\":\"Alpha\",\"answers\":[{\"question_id\":\"q\"}]}"), "invalid arguments: missing field `labels`");
    const answered = try ok(try f.call("respond_to_input", "{\"chat\":\"Alpha\",\"request_id\":\"req-1\",\"answers\":[{\"question_id\":\"q1\",\"labels\":[\"Yes\"]}]}"));
    try testing.expectEqualStrings("req-1", u.str(answered, "requestId").?);
    const resp = f.rec.last("QueueCommand").?;
    try testing.expectEqualStrings("respondInput", sval(resp, &.{ "command", "kind" }).?);
    try testing.expectEqualStrings("q1", u.str(u.array(u.get(resp, "command").?, "answers").?[0], "questionId").?);

    try expectErr(try f.call("dismiss_input", "{\"chat\":\"Alpha\",\"answers\":[{\"question_id\":\"q\",\"labels\":[]}]}"), "dismiss_input never accepts answers");
    try expectErr(try f.call("dismiss_input", "{\"chat\":\"Alpha\"}"), "chat chat-alp has no pending question");
    const dismissed = try ok(try f.call("dismiss_input", "{\"chat\":\"Alpha\",\"request_id\":\"req-2\"}"));
    try testing.expectEqualStrings("req-2", u.str(dismissed, "requestId").?);
    try testing.expectEqualStrings("dismissInput", sval(f.rec.last("QueueCommand").?, &.{ "command", "kind" }).?);

    const renamed = try ok(try f.call("rename_chat", "{\"chat\":\"Alpha\",\"title\":\"  Login fix \"}"));
    try testing.expectEqualStrings("Alpha", u.str(renamed, "previousTitle").?);
    try testing.expectEqualStrings("Login fix", u.str(renamed, "title").?);
    try testing.expectEqualStrings("Login fix", f.chat("chat-alpha-1").title.?);
    try expectErr(try f.call("rename_chat", "{\"chat\":\"Login fix\",\"title\":\" \"}"), "rename_chat needs a nonblank title");
    try expectErr(try f.call("rename_chat", "{\"chat\":\"Login fix\"}"), "invalid arguments: missing field `title`");

    const archived = try ok(try f.call("archive_chat", "{\"chat\":\"Beta\"}"));
    try testing.expect(u.boolean(archived, "archived").?);
    try testing.expect(f.chat("chat-beta-2").archived);
    const restored = try ok(try f.call("archive_chat", "{\"chat\":\"Beta\",\"archived\":false}"));
    try testing.expect(!u.boolean(restored, "archived").?);
    try testing.expect(!f.chat("chat-beta-2").archived);
    try expectErr(try f.call("archive_chat", "{\"chat\":\"zzz\"}"), "no chat matches \"zzz\" (id, id prefix, or exact title); try list_chats");
}

test "mcp respond_to_input: the current pending question is found in the transcript" {
    const w = try WorldFixture.create(.{});
    defer w.destroy();
    // An older answered question, then the one still open.
    w.world.doc_reset =
        \\[{"id":"u1","role":"user","createdAt":1,"deviceId":"dev-local","parts":[{"kind":"text","id":"t","text":"ship it"}]},
        \\ {"id":"a1","role":"assistant","createdAt":2,"deviceId":"dev-local","status":"streaming","parts":[
        \\   {"kind":"input","id":"i1","requestId":"req-old","questions":[{"id":"q0","prompt":"Start?"}],"resolved":true},
        \\   {"kind":"input","id":"i2","requestId":"req-7","questions":[{"id":"q1","prompt":"Push to main?"}],"resolved":false}]}]
    ;
    try testing.expectEqualStrings("req-7", sval(try ok(try w.call("get_chat", "{\"chat\":\"Alpha\"}")), &.{ "pendingInput", "requestId" }).?);
    const answered = try ok(try w.call("respond_to_input", "{\"chat\":\"Alpha\",\"answers\":[{\"question_id\":\"q1\",\"labels\":[\"Yes\"]}]}"));
    try testing.expectEqualStrings("req-7", u.str(answered, "requestId").?);
    const sent = w.lastWrite("QueueCommand").?;
    try testing.expectEqualStrings("chat-alpha-1", u.str(sent, "chatId").?);
    try testing.expectEqualStrings("respondInput", sval(sent, &.{ "command", "kind" }).?);
    try testing.expectEqualStrings("req-7", sval(sent, &.{ "command", "requestId" }).?);
    const ans = u.array(u.get(sent, "command").?, "answers").?;
    try testing.expectEqualStrings("q1", u.str(ans[0], "questionId").?);
    try testing.expectEqualStrings("Yes", u.array(ans[0], "labels").?[0].string);
    const dismissed = try ok(try w.call("dismiss_input", "{\"chat\":\"Alpha\"}"));
    try testing.expectEqualStrings("req-7", u.str(dismissed, "requestId").?);
    try testing.expectEqualStrings("req-7", sval(w.lastWrite("QueueCommand").?, &.{ "command", "requestId" }).?);
    // Once answered, nothing is pending.
    w.world.doc_reset =
        \\[{"id":"a1","role":"assistant","createdAt":2,"deviceId":"dev-local","status":"complete","parts":[
        \\   {"kind":"input","id":"i2","requestId":"req-7","questions":[{"id":"q1","prompt":"Push to main?"}],"resolved":true}]}]
    ;
    try expectErr(try w.call("respond_to_input", "{\"chat\":\"Alpha\",\"answers\":[{\"question_id\":\"q1\",\"labels\":[\"Yes\"]}]}"), "chat chat-alp has no pending question");
}

// ---- publishing -------------------------------------------------------------------------

test "mcp show_image and show_visual: origin chat only, bounded, minted ids, engine errors surface" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    try expectErr(try f.call("show_image", "{\"path\":\"shot.png\"}"), "show_image needs a chat context: this server is not running inside a chat");
    try expectErr(try f.call("show_visual", "{\"title\":\"t\",\"script\":\"return function() end\"}"), "show_visual needs a chat context: this server is not running inside a chat");
    // Args are checked first, and unknown fields cannot pick another chat.
    try expectErr(try f.call("show_image", "{\"path\":\"a.png\",\"chat\":\"Alpha\"}"), "invalid arguments: unknown field `chat`, expected `path` or `caption`");
    try expectErr(try f.call("show_visual", "{\"title\":\"t\",\"script\":\"s\",\"id\":\"x\"}"), "invalid arguments: unknown field `id`, expected `title` or `script`");

    f.t.origin = .{ .chat_id = "chat-alpha-1" };
    const img = try ok(try f.call("show_image", "{\"path\":\"shots/after.png\",\"caption\":\"After\"}"));
    try testing.expect(u.boolean(img, "attached").?);
    const sent = f.rec.last("ShowImage").?;
    try testing.expectEqualStrings("chat-alpha-1", u.str(sent, "chatId").?);
    try testing.expectEqual(@as(usize, 36), u.str(sent, "id").?.len);
    try testing.expectEqualStrings(u.str(sent, "id").?, u.str(img, "id").?);
    try testing.expectEqualStrings("After", u.str(sent, "caption").?);
    try expectErr(try f.call("show_image", "{\"path\":\"   \"}"), "show_image path must be 1-4096 characters");
    const x201 = try repeat(f.arena.allocator(), "x", 201);
    const long_caption = try std.fmt.allocPrint(f.arena.allocator(), "{{\"path\":\"a.png\",\"caption\":\"{s}\"}}", .{x201});
    try expectErr(try f.call("show_image", long_caption), "show_image caption is limited to 200 characters");

    const vis = try ok(try f.call("show_visual", "{\"title\":\"Overview\",\"script\":\"return function() return ui.text('hi') end\"}"));
    try testing.expect(u.boolean(vis, "attached").?);
    try testing.expectEqualStrings("return function() return ui.text('hi') end", u.str(f.rec.last("ShowVisual").?, "script").?);
    try expectErr(try f.call("show_visual", "{\"title\":\" \",\"script\":\"x\"}"), "visual title must be nonblank and at most 200 characters");
    try expectErr(try f.call("show_visual", "{\"title\":\"t\",\"script\":\"\\n\\t\"}"), "visual script must be nonblank and at most 64 KiB of UTF-8");
    try testing.expect(tools.validateVisual(try repeat(f.arena.allocator(), "界", 200), try repeat(f.arena.allocator(), "é", 32768)) == null);
    try testing.expect(tools.validateVisual(try repeat(f.arena.allocator(), "界", 201), "x") != null);
    try testing.expect(tools.validateVisual("title", try repeat(f.arena.allocator(), "é", 32769)) != null);

    const w = try WorldFixture.create(.{ .chat_id = "chat-alpha-1" });
    defer w.destroy();
    try expectErr(try w.call("show_image", "{\"path\":\"bad.png\"}"), "ShowImage: no active run accepts images");
}

// ---- rooms -------------------------------------------------------------------------------

test "mcp post_room: queues framed peer mail for mentioned chats and reports redactions" {
    const w = try WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    const v = try ok(try w.call("post_room", "{\"room\":\"build\",\"text\":\"@alpha the build is green\",\"kind\":\"message\"}"));
    try testing.expectEqual(@as(i64, 3), u.int(v, "seq").?);
    const woken = u.array(v, "woken").?;
    try testing.expectEqual(@as(usize, 1), woken.len);
    try testing.expectEqualStrings("alpha", u.str(woken[0], "member").?);
    try testing.expect(u.boolean(woken[0], "queued").?);
    try testing.expectEqual(@as(i64, 1), u.int(u.get(v, "redacted").?, "email").?);
    try testing.expectEqual(@as(i64, 0), u.int(v, "stripped").?);
    const post = w.lastWrite("RoomRequest").?;
    try testing.expectEqualStrings("room/room_0123456789abcdef01234567/post", u.str(post, "path").?);
    try testing.expectEqualStrings("beta", sval(post, &.{ "body", "member" }).?);
    try testing.expect(!u.boolean(u.get(post, "body").?, "fromUser").?);
    try testing.expectEqual(@as(usize, 32), sval(post, &.{ "body", "clientId" }).?.len);
    const queued = w.lastWrite("QueueMessage").?;
    try testing.expectEqualStrings("chat-alpha-1", u.str(queued, "chatId").?);
    const text = u.str(queued, "text").?;
    try testing.expect(peer.isRoomDelivery(w.arena.allocator(), text));
    try testing.expect(std.mem.indexOf(u8, text, "[room message from beta · room build #3 · agent, advisory]: @alpha the build is green") != null);

    // The room's refusals come back readable, and are not retried.
    w.world.room_post_status = 422;
    w.world.room_post_body = "{\"error\":\"secret_detected\",\"message\":\"the post contains a credential\"}";
    const before = w.world.writes.items.len;
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"token=abc\"}"), "room request failed (422): secret_detected: the post contains a credential");
    try testing.expectEqual(before + 1, w.world.writes.items.len);
    w.world.room_post_body = "{\"error\":\"not_a_member\"}";
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"hi\"}"), "room request failed (422): not_a_member");
    try expectErr(try w.call("post_room", "{\"room\":\"Build\",\"text\":\"hi\"}"), "no room named \"Build\" that you can see (names are exact and case-sensitive; the room may have been destroyed, or you aren't in it — see list_rooms)");
    try expectErr(try w.call("post_room", "{\"room\":\"build\"}"), "invalid arguments: missing field `text`");
}

test "mcp rooms: list, create, join, read, inbox, release, archive, destroy and leave" {
    const w = try WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    const listed = try ok(try w.call("list_rooms", "{}"));
    try testing.expectEqualStrings("beta", u.str(listed, "you").?);
    try testing.expectEqual(@as(usize, 1), u.array(listed, "rooms").?.len);

    const created = try ok(try w.call("create_room", "{\"name\":\"plan\",\"members\":[\"Alpha\"]}"));
    try testing.expectEqualStrings("room_new", sval(created, &.{ "room", "id" }).?);
    try testing.expectEqualStrings("gamma", u.array(created, "added").?[0].string);
    try expectErr(try w.call("create_room", "{\"name\":\"plan\",\"project\":true}"), "this chat's checkout has no origin remote to bind the room to");

    const read = try ok(try w.call("read_room", "{\"room\":\"room_0123456789abcdef01234567\"}"));
    try testing.expectEqualStrings("build", u.str(read, "room").?);
    try testing.expectEqual(@as(i64, 5), u.int(read, "lastSeq").?);

    const inbox = try ok(try w.call("room_inbox", "{}"));
    try testing.expectEqual(@as(usize, 1), u.array(inbox, "items").?.len);

    _ = try ok(try w.call("release_claim", "{\"room\":\"build\",\"claim_key\":\"task-1\"}"));
    try testing.expectEqualStrings("task-1", sval(w.lastWrite("RoomRequest").?, &.{ "body", "claimKey" }).?);
    try expectErr(try w.call("release_claim", "{\"room\":\"build\"}"), "invalid arguments: missing field `claim_key`");
    _ = try ok(try w.call("archive_room", "{\"room\":\"build\"}"));
    try testing.expect(u.boolean(u.get(w.lastWrite("RoomRequest").?, "body").?, "archived").?);
    _ = try ok(try w.call("destroy_room", "{\"room\":\"build\"}"));
    try testing.expectEqualStrings("room/room_0123456789abcdef01234567/destroy", u.str(w.lastWrite("RoomRequest").?, "path").?);
    _ = try ok(try w.call("join_room", "{\"room\":\"build\"}"));
    _ = try ok(try w.call("leave_room", "{\"room\":\"room_unknown\"}"));
    try testing.expectEqualStrings("room/room_unknown/leave", u.str(w.lastWrite("RoomRequest").?, "path").?);

    w.t.origin = .{};
    try expectErr(try w.call("list_rooms", "{}"), "room tools speak for a Harness chat; this server has no HARNESS_CHAT_ID");
    try expectErr(try w.call("room_inbox", "{}"), "room tools speak for a Harness chat; this server has no HARNESS_CHAT_ID");
}

test "mcp rooms: the edge's refusals read as errors, and a reply that is not an object is never a success" {
    const w = try WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    // The edge's own replies (`edge/src/index.ts`: `{error, message}` with
    // the RoomError status): a credential in a post, a claim someone else
    // holds, and a destroy by a member who is not an owner.
    w.world.room_replies = &.{
        .{ .method = "POST", .path_end = "/post", .status = 422, .body = "{\"error\":\"secret_detected\",\"message\":\"the post looks like it contains a credential (api key)\"}" },
        .{ .method = "POST", .path_end = "/release", .status = 409, .body = "{\"error\":\"claim_held\",\"message\":\"task-1 is held or done by someone else\"}" },
        .{ .method = "POST", .path_end = "/destroy", .status = 403, .body = "{\"error\":\"owner_only\",\"message\":\"owner_only\"}" },
    };
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"key=sk-synthetic\"}"), "room request failed (422): secret_detected: the post looks like it contains a credential (api key)");
    try expectErr(try w.call("release_claim", "{\"room\":\"build\",\"claim_key\":\"task-1\"}"), "room request failed (409): claim_held: task-1 is held or done by someone else");
    try expectErr(try w.call("destroy_room", "{\"room\":\"build\"}"), "room request failed (403): owner_only");
    // A refused post queued nothing for anyone.
    try testing.expect(w.lastWrite("QueueMessage") == null);

    // A 2xx whose body is not an object: every room tool fails rather than
    // answering nulls, and a post never reports seq 0 as sent.
    w.world.room_replies = &.{
        .{ .method = "GET", .path_end = "rooms", .status = 200, .body = "\"ok\"" },
    };
    try expectErr(try w.call("list_rooms", "{}"), "room request failed (200): the room's reply is not a JSON object");
    try expectErr(try w.call("read_room", "{\"room\":\"build\"}"), "room request failed (200): the room's reply is not a JSON object");
    w.world.room_replies = &.{
        .{ .method = "POST", .path_end = "/post", .status = 200, .body = "[]" },
        .{ .method = "GET", .path_end = "rooms/inbox", .status = 204, .body = "null" },
    };
    const before = w.world.writes.items.len;
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"@alpha done\"}"), "room request failed (200): the room's reply is not a JSON object");
    // Not retried (the room answered), and nobody was woken.
    try testing.expectEqual(before + 1, w.world.writes.items.len);
    try testing.expect(w.lastWrite("QueueMessage") == null);
    try expectErr(try w.call("room_inbox", "{}"), "room request failed (204): the room's reply is not a JSON object");
    // The edge's real success replies still read through.
    w.world.room_replies = &.{};
    try testing.expectEqual(@as(i64, 3), u.int(try ok(try w.call("post_room", "{\"room\":\"build\",\"text\":\"@alpha done\"}")), "seq").?);
}

test "mcp rooms: the Zig engine's RoomRequest reply is passed through as it is" {
    const f = try HostFixture.create(.{ .chat_id = "chat-beta-2" });
    defer f.destroy();
    // The engine forwards to a made-up loopback edge and hands its reply back.
    var edge: @import("../rpcw_rooms.zig").FakeEdge = .{};
    try edge.start();
    defer edge.shutdown();
    f.host.auth.edge_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{edge.port});
    f.host.auth.access_token = try testing.allocator.dupe(u8, "synthetic-access-token");
    f.host.auth.signed_in = true;
    edge.body = "{\"rooms\":[]}";
    const listed = try ok(try f.call("list_rooms", "{}"));
    try testing.expectEqual(@as(usize, 0), u.get(listed, "rooms").?.array.items.len);
    try expectErrStarts(try f.call("read_room", "{\"room\":\"build\"}"), "no room named \"build\" that you can see");
    edge.status = 403;
    edge.body = "{\"error\":\"not_a_member\"}";
    try expectErrStarts(try f.call("list_rooms", "{}"), "room request failed (403): not_a_member");
}

// ---- bots --------------------------------------------------------------------------------------

const bots_list =
    \\[{"name":"triage","job":"Sort new issues","model":"","yolo":false},{"name":"notes","job":"Draft release notes","model":"gpt-9","yolo":true}]
;
const routines_list =
    \\[{"bot":"triage","id":"r1","instruction":"sweep","when":"every 6h","paused":false,"done":false,"runs":2,"message":"[routine r1] sweep"},
    \\ {"bot":"notes","id":"r2","instruction":"draft","when":"daily","paused":true,"done":false,"runs":0,"message":"[routine r2] draft"}]
;
const due_list =
    \\[{"bot":"triage","id":"r1","instruction":"sweep","system":"You are triage.","message":"[routine r1] sweep"}]
;

test "mcp list_bots: each bot's routines and which are due" {
    const f = try HostFixture.create(.{ .chat_id = "chat-alpha-1" });
    defer f.destroy();
    try f.bots.set("list --json", bots_list);
    try f.bots.set("routine list --json", routines_list);
    try f.bots.set("due --json", due_list);
    const v = try ok(try f.call("list_bots", "{}"));
    try testing.expectEqualStrings("comet", sval(v, &.{ "project", "name" }).?);
    const listed = u.array(v, "bots").?;
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expect(u.get(listed[0], "model").? == .null);
    try testing.expect(u.boolean(u.array(listed[0], "routines").?[0], "due").?);
    try testing.expect(!u.boolean(u.array(listed[1], "routines").?[0], "due").?);
    try testing.expect(u.boolean(listed[1], "skipsApprovals").?);
    try testing.expectEqualStrings("/repo/comet: list --json", f.bots.calls.items[0]);

    f.t.origin = .{};
    try expectErr(try f.call("list_bots", "{}"), "name the project: this server is not speaking for a chat");
    try f.bots.set("list --json", "not json");
    try expectErr(try f.call("list_bots", "{\"project\":\"comet\"}"), "graff bot list did not print the JSON this Harness reads");
    // A project hosted elsewhere.
    try f.setup("{\"op\":\"createSpace\",\"spaceId\":\"space-far\",\"deviceId\":\"dev-far\",\"path\":\"/far/repo\"}");
    try expectErr(try f.call("list_bots", "{\"project\":\"space-far\"}"), "bots are files in the project folder, and repo is hosted on another device; ask a chat on that device");
}

test "mcp list_bots: rows are type-checked as the Rust structs declare them" {
    const f = try HostFixture.create(.{ .chat_id = "chat-alpha-1" });
    defer f.destroy();
    try f.bots.set("due --json", "[]");
    try f.bots.set("routine list --json", "[]");
    const refused = "graff bot list did not print the JSON this Harness reads";
    // `model: String` and `yolo: bool` default when absent, never when null
    // or another type.
    for ([_][]const u8{
        "[{\"name\":\"t\",\"job\":\"j\",\"model\":null}]",
        "[{\"name\":\"t\",\"job\":\"j\",\"model\":7}]",
        "[{\"name\":\"t\",\"job\":\"j\",\"yolo\":\"yes\"}]",
        "[{\"name\":\"t\",\"job\":\"j\",\"yolo\":null}]",
        "[\"t\"]",
    }) |out| {
        try f.bots.set("list --json", out);
        try expectErr(try f.call("list_bots", "{}"), refused);
    }
    try f.bots.set("list --json", "[{\"name\":\"t\",\"job\":\"j\"}]");
    // `runs: u32`.
    for ([_][]const u8{ "\"2\"", "-1", "4294967296", "1.5", "null" }) |runs| {
        try f.bots.set("routine list --json", try std.fmt.allocPrint(f.arena.allocator(), "[{{\"bot\":\"t\",\"id\":\"r\",\"instruction\":\"i\",\"when\":\"daily\",\"message\":\"m\",\"runs\":{s}}}]", .{runs}));
        try expectErr(try f.call("list_bots", "{}"), "graff bot routine list did not print the JSON this Harness reads");
    }
    try f.bots.set("routine list --json", "[{\"bot\":\"t\",\"id\":\"r\",\"instruction\":\"i\",\"when\":\"daily\",\"message\":\"m\",\"runs\":4294967295}]");
    const v = try ok(try f.call("list_bots", "{}"));
    const bot = u.array(v, "bots").?[0];
    try testing.expect(u.get(bot, "model").? == .null);
    try testing.expect(!u.boolean(bot, "skipsApprovals").?);
    try testing.expectEqual(@as(i64, 4294967295), u.int(u.array(bot, "routines").?[0], "runs").?);
}

test "mcp times: chrono's AutoSi form, to the nanosecond" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "2026-11-10T00:00:01Z", "2026-11-10T00:00:01Z" },
        .{ "2026-11-10T00:00:01.000Z", "2026-11-10T00:00:01Z" },
        .{ "2026-11-10T00:00:01.5Z", "2026-11-10T00:00:01.500Z" },
        .{ "2026-11-10T00:00:01.120Z", "2026-11-10T00:00:01.120Z" },
        .{ "2026-11-10T00:00:01.123456Z", "2026-11-10T00:00:01.123456Z" },
        .{ "2026-11-10T00:00:01.000001Z", "2026-11-10T00:00:01.000001Z" },
        .{ "2026-11-10T00:00:01.123456789Z", "2026-11-10T00:00:01.123456789Z" },
        .{ "2026-11-10T00:00:01.1234567891Z", "2026-11-10T00:00:01.123456789Z" },
        .{ "2026-11-10T08:00:01.25+08:00", "2026-11-10T00:00:01.250Z" },
        .{ "not a time", "not a time" },
    };
    for (cases) |c| {
        var o = u.obj(a);
        try o.put("at", u.s(c[0]));
        try testing.expectEqualStrings(c[1], (try tools.timeValue(a, o.value(), "at")).string);
    }
    try testing.expect((try tools.timeValue(a, u.obj(a).value(), "at")) == .null);
}

test "mcp run_bot and run_due_bots: graff chats that open with the bot's standing text" {
    const f = try HostFixture.create(.{ .chat_id = "chat-alpha-1" });
    defer f.destroy();
    try f.bots.set("list --json", bots_list);
    try f.bots.set("routine list triage --json", routines_list);
    try f.bots.set("prompt triage", "You are triage.");
    try f.bots.set("prompt notes", "You write notes.");
    const ran = try ok(try f.call("run_bot", "{\"bot\":\"triage\",\"message\":\"look at #12\"}"));
    try testing.expectEqualStrings("triage", u.str(ran, "bot").?);
    try testing.expectEqualStrings("graff", u.str(ran, "harness").?);
    try testing.expectEqualStrings("triage", u.str(ran, "title").?);
    try testing.expectEqualStrings("You are triage.\n\nlook at #12", sval(f.rec.last("QueueCommand").?, &.{ "command", "request", "prompt" }).?);

    const routine = try ok(try f.call("run_bot", "{\"bot\":\"triage\",\"routine\":\"r1\"}"));
    try testing.expectEqualStrings("triage: r1", u.str(routine, "title").?);
    // The stand-in graff lists no models (its catalog probe fails), so the
    // bot's model cannot be checked and is kept, as Rust keeps it.
    const notes = try ok(try f.call("run_bot", "{\"bot\":\"notes\",\"message\":\"go\"}"));
    try testing.expect(u.get(notes, "modelIgnored") == null);

    try expectErr(try f.call("run_bot", "{\"bot\":\"triage\"}"), "pass message or routine, one of them");
    try expectErr(try f.call("run_bot", "{\"bot\":\"triage\",\"message\":\"a\",\"routine\":\"r1\"}"), "pass message or routine, one of them");
    try expectErr(try f.call("run_bot", "{\"bot\":\"ghost\",\"message\":\"a\"}"), "no bot named \"ghost\" in comet; it has: triage, notes");
    try expectErr(try f.call("run_bot", "{\"bot\":\"triage\",\"routine\":\"r9\"}"), "triage has no routine \"r9\" (see list_bots)");
    try expectErr(try f.call("run_bot", "{\"message\":\"a\"}"), "invalid arguments: missing field `bot`");

    try f.bots.set("due --claim --json", due_list ++ "");
    const due = try ok(try f.call("run_due_bots", "{}"));
    const started = u.array(due, "started").?;
    try testing.expectEqual(@as(usize, 1), started.len);
    try testing.expectEqualStrings("r1", u.str(started[0], "routine").?);
    try testing.expect(u.get(due, "failed") == null);
    try f.bots.set("due --claim --json",
        \\[{"bot":"gone","id":"r7","instruction":"x","system":"s","message":"m"}]
    );
    const failed = try ok(try f.call("run_due_bots", "{}"));
    try testing.expectEqualStrings("its bot is gone", u.str(u.array(failed, "failed").?[0], "error").?);
    try testing.expect(std.mem.startsWith(u8, u.str(failed, "note").?, "A failed routine was already moved"));
    try f.bots.set("due --claim --json", "[]");
    try testing.expectEqualStrings("Nothing is due.", u.str(try ok(try f.call("run_due_bots", "{}")), "note").?);
}

test "mcp bots: the person's own bots run in their standing chat through the engine" {
    const w = try WorldFixture.create(.{});
    defer w.destroy();
    w.world.own_bots = "{\"bots\":[{\"name\":\"scout\",\"job\":\"Watch CI\"}]}";
    const listed = try ok(try w.call("list_bots", "{}"));
    try testing.expectEqualStrings("scout", u.str(u.array(listed, "yours").?[0], "name").?);
    try testing.expect(u.get(listed, "bots") == null);
    const ran = try ok(try w.call("run_bot", "{\"bot\":\"scout\",\"message\":\"check main\"}"));
    try testing.expectEqualStrings("chat-standing", u.str(ran, "chatId").?);
    try testing.expect(u.boolean(ran, "standingChat").?);
    try testing.expectEqualStrings("check main", u.str(w.lastWrite("RunBot").?, "message").?);
    try expectErr(try w.call("run_bot", "{\"bot\":\"scout\"}"), "pass message or routine, one of them");
    // Without own bots and without a project, the project error stands.
    w.world.own_bots = null;
    try expectErr(try w.call("list_bots", "{}"), "name the project: this server is not speaking for a chat");
}

fn repeat(a: Allocator, unit: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, unit.len * n);
    for (0..n) |k| @memcpy(out[k * unit.len ..][0..unit.len], unit);
    return out;
}

// ---- waits against the in-process engine's asynchronous turns ---------------------------

fn replyTexts(a: Allocator, turn: Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (u.array(turn, "replies") orelse u.none) |r| {
        try out.appendSlice(a, u.str(r, "text") orelse "");
        try out.append(a, '\n');
    }
    return out.items;
}

test "mcp waits: create_chat and send_message wait for the engine's turn, and answers reach the running turn" {
    const f = try HostFixture.create(.{});
    defer f.destroy();
    const a = f.arena.allocator();
    try f.setup(try std.fmt.allocPrint(a, "{{\"op\":\"createSpace\",\"spaceId\":\"space-real\",\"path\":\"{s}/home\",\"name\":\"real\"}}", .{f.base}));
    _ = try f.host_link.engine().call(a, "SetAutonomy", "{\"autonomy\":\"workspace\"}"); // a level that asks (the default, full access, doesn't)

    // create_chat with a prompt and wait: the turn runs on its own thread and
    // the wait sees it complete.
    const created = try ok(try f.call("create_chat", "{\"project\":\"space-real\",\"harness\":\"claude-code\",\"parent\":\"chat-beta-2\",\"prompt\":\"hello there\",\"wait\":true,\"timeout_secs\":20}"));
    const turn1 = u.get(created, "turn").?;
    try testing.expectEqualStrings("completed", u.str(turn1, "outcome").?);
    try testing.expect(!u.boolean(turn1, "timedOut").?);
    try testing.expect(std.mem.indexOf(u8, try replyTexts(a, turn1), "Reply to: hello there") != null);
    const new_id = u.str(created, "chatId").?;

    // The engine kept the host device and the parent.
    const got = try ok(try f.call("get_chat", try std.fmt.allocPrint(a, "{{\"chat\":\"{s}\"}}", .{new_id})));
    try testing.expectEqualStrings("dev-local", u.str(got, "deviceId").?);
    try testing.expectEqualStrings("chat-beta-2", u.str(got, "parentChatId").?);

    // The session row names the device and the completed turn.
    const rows = try f.host_link.engine().call(a, "WatchSessions", "{}");
    var marker: ?[]const u8 = null;
    for (rows.ok.array.items) |row| if (std.mem.eql(u8, u.str(row, "chatId").?, new_id)) {
        try testing.expectEqualStrings("dev-local", u.str(row, "deviceId").?);
        try testing.expectEqualStrings("idle", u.str(row, "status").?);
        marker = u.str(row, "lastCompletedTurn");
    };
    try testing.expect(marker != null);

    // send_message with wait: a second turn, past the first marker.
    const sent = try ok(try f.call("send_message", try std.fmt.allocPrint(a, "{{\"chat\":\"{s}\",\"text\":\"second\",\"wait\":true,\"timeout_secs\":20}}", .{new_id})));
    try testing.expectEqualStrings("run", sval(sent, &.{ "sent", "delivery" }).?);
    try testing.expect(u.str(u.get(sent, "sent").?, "id").?.len > 0);
    const turn2 = u.get(sent, "turn").?;
    try testing.expectEqualStrings("completed", u.str(turn2, "outcome").?);
    try testing.expect(std.mem.indexOf(u8, try replyTexts(a, turn2), "Reply to: second") != null);

    // A turn that asks: the wait stops at the question, the answer goes to
    // the running turn (not a new one), and the turn then completes.
    const asked = try ok(try f.call("send_message", try std.fmt.allocPrint(a, "{{\"chat\":\"{s}\",\"text\":\"ask: first\",\"wait\":true,\"timeout_secs\":20}}", .{new_id})));
    const turn3 = u.get(asked, "turn").?;
    try testing.expectEqualStrings("awaitingInput", u.str(turn3, "outcome").?);
    const pending = u.get(turn3, "pendingInput").?;
    try testing.expect(pending != .null);
    const qs = u.array(pending, "questions").?;
    const answer = try std.fmt.allocPrint(a, "{{\"chat\":\"{s}\",\"answers\":[{{\"question_id\":\"{s}\",\"labels\":[\"Yes\"]}}]}}", .{ new_id, u.str(qs[0], "id").? });
    const responded = try ok(try f.call("respond_to_input", answer));
    try testing.expect(u.str(responded, "commandId").?.len > 0);
    const done = try ok(try f.call("wait_for_turn", try std.fmt.allocPrint(a, "{{\"chat\":\"{s}\",\"timeout_secs\":20}}", .{new_id})));
    const turn4 = u.get(done, "turn").?;
    try testing.expectEqualStrings("completed", u.str(turn4, "outcome").?);
    const all = try ok(try f.call("read_chat", try std.fmt.allocPrint(a, "{{\"chat\":\"{s}\"}}", .{new_id})));
    var saw_allowed = false;
    for (u.array(all, "messages").?) |m| {
        if (std.mem.indexOf(u8, u.str(m, "text") orelse "", "Reply to: ask: first (allowed)") != null) saw_allowed = true;
    }
    try testing.expect(saw_allowed);
    // Three user turns, one each: the answer did not start a fourth.
    try testing.expectEqual(@as(i64, 6), u.int(all, "total").?);
}

