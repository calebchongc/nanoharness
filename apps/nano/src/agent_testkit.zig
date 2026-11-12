//! Test rig for adapter turns: an `EngineHost` with a chat on the harness
//! under test, a mock agent script written into a fresh temp dir, and an
//! isolated environment (PATH, HOME, the agent's executable override). Every
//! wait has a deadline; on timeout the turn is interrupted and its process
//! group killed, so a misbehaving mock can't hang the suite.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const engine_host = @import("engine_host.zig");
const turn_host = @import("turn_host.zig");
const agent_turn = @import("agent_turn.zig");

pub const Rig = struct {
    gpa: Allocator,
    io: Io,
    host: *engine_host.EngineHost,
    env: std.process.Environ.Map,
    dir: []u8,
    script: []u8,

    pub const Options = struct {
        harness: []const u8,
        /// The env var naming the agent executable (`CLAUDE_CODE_EXECUTABLE`, …).
        override_var: []const u8,
        script: []const u8,
        autonomy: []const u8 = "workspace",
        /// Point the override at a path that doesn't exist.
        missing_binary: bool = false,
    };

    pub fn create(opts: Options) !*Rig {
        const gpa = testing.allocator;
        const io = testing.io;
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const dir = try std.fmt.allocPrint(gpa, "/tmp/harness-zig-adapter-{x}", .{rnd});
        errdefer gpa.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
        const script = try std.fmt.allocPrint(gpa, "{s}/agent.sh", .{dir});
        errdefer gpa.free(script);
        {
            var f = try Io.Dir.cwd().createFile(io, script, .{ .permissions = .fromMode(0o755) });
            defer f.close(io);
            try f.writeStreamingAll(io, opts.script);
        }
        var env = std.process.Environ.Map.init(gpa);
        errdefer env.deinit();
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("HOME", dir);
        try env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        try env.put(opts.override_var, if (opts.missing_binary) "/nonexistent/harness-agent-mock" else script);

        const host = try gpa.create(engine_host.EngineHost);
        errdefer gpa.destroy(host);
        host.* = try engine_host.EngineHost.init(gpa, "dev-test", "Test Mac");
        host.io = io;
        const auton = try gpa.dupe(u8, opts.autonomy);
        gpa.free(host.autonomy_level);
        host.autonomy_level = auton;

        const rig = try gpa.create(Rig);
        rig.* = .{ .gpa = gpa, .io = io, .host = host, .env = env, .dir = dir, .script = script };
        turn_host.env_override = &rig.env;
        const body = try std.fmt.allocPrint(gpa, "{{\"op\":\"createChat\",\"chatId\":\"chat-1\",\"config\":{{\"harness\":{f}}}}}", .{json.fmt(opts.harness, .{})});
        defer gpa.free(body);
        try rig.call("Mutate", body);
        return rig;
    }

    pub fn destroy(self: *Rig) void {
        self.killAll();
        _ = agent_turn.waitAllExited(self.io, 5000);
        self.host.deinit();
        self.gpa.destroy(self.host);
        turn_host.env_override = null;
        Io.Dir.cwd().deleteTree(self.io, self.dir) catch {};
        self.env.deinit();
        self.gpa.free(self.script);
        self.gpa.free(self.dir);
        self.gpa.destroy(self);
    }

    /// Call an RPC under the engine lock, like the socket dispatcher.
    pub fn call(self: *Rig, method: []const u8, body: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const params = try json.parseFromSliceLeaky(json.Value, arena.allocator(), body, .{});
        self.host.mutex.lockUncancelable(self.io);
        defer self.host.mutex.unlock(self.io);
        var out = try self.host.handle(method, params);
        switch (out) {
            .unary_json => |b| self.gpa.free(b),
            .stream_items_json => |*s| s.deinit(self.gpa),
            else => {},
        }
    }

    pub fn command(self: *Rig, cmd_json: []const u8) !void {
        const body = try std.fmt.allocPrint(self.gpa, "{{\"chatId\":\"chat-1\",\"command\":{s}}}", .{cmd_json});
        defer self.gpa.free(body);
        try self.call("QueueCommand", body);
    }

    pub fn run(self: *Rig, msg_id: []const u8, prompt: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.gpa, "{{\"kind\":\"run\",\"messageId\":{f},\"request\":{{\"prompt\":{f},\"cwd\":{f}}}}}", .{ json.fmt(msg_id, .{}), json.fmt(prompt, .{}), json.fmt(self.dir, .{}) });
        defer self.gpa.free(cmd);
        try self.command(cmd);
    }

    /// The chat's transcript JSON (owned).
    pub fn docJson(self: *Rig) ![]u8 {
        self.host.mutex.lockUncancelable(self.io);
        defer self.host.mutex.unlock(self.io);
        const doc = try self.host.getOrCreateDoc("chat-1");
        return doc.toResetFrameJson(self.gpa);
    }

    pub fn chatSessionId(self: *Rig) ?[]const u8 {
        self.host.mutex.lockUncancelable(self.io);
        defer self.host.mutex.unlock(self.io);
        for (self.host.chats.items) |c| if (std.mem.eql(u8, c.id, "chat-1")) return c.harness_session_id;
        return null;
    }

    fn killAll(self: *Rig) void {
        if (turn_host.liveTurn(self.io, self.host, "chat-1")) |t| {
            defer t.release();
            t.interrupted.store(true, .release);
            t.mu.lockUncancelable(self.io);
            if (t.proc) |p| p.terminate();
            t.mu.unlock(self.io);
        }
    }

    /// Wait until the transcript contains `needle`.
    pub fn waitFor(self: *Rig, needle: []const u8, ms: u32) !void {
        var waited: u32 = 0;
        while (waited < ms) : (waited += 10) {
            const j = try self.docJson();
            defer self.gpa.free(j);
            if (std.mem.indexOf(u8, j, needle) != null) return;
            try Io.sleep(self.io, .fromMilliseconds(10), .awake);
        }
        self.killAll();
        const j = try self.docJson();
        defer self.gpa.free(j);
        std.debug.print("timed out waiting for {s} in {s}\n", .{ needle, j });
        return error.TestTimeout;
    }

    /// Wait until no turn is live and every turn thread has exited.
    pub fn waitIdle(self: *Rig, ms: u32) !void {
        var waited: u32 = 0;
        while (waited < ms) : (waited += 10) {
            if (turn_host.liveCount(self.io, self.host) == 0 and agent_turn.active_threads.load(.acquire) == 0) return;
            try Io.sleep(self.io, .fromMilliseconds(10), .awake);
        }
        self.killAll();
        _ = agent_turn.waitAllExited(self.io, 5000);
        return error.TestTimeout;
    }

    /// The first open input part's request id in the transcript (owned).
    pub fn openRequestId(self: *Rig) !?[]u8 {
        const j = try self.docJson();
        defer self.gpa.free(j);
        var parsed = try json.parseFromSlice(json.Value, self.gpa, j, .{});
        defer parsed.deinit();
        for (parsed.value.object.get("reset").?.array.items) |m| {
            for (m.object.get("parts").?.array.items) |p| {
                const kind = agent_turn.getStr(p, "kind") orelse continue;
                if (!std.mem.eql(u8, kind, "input")) continue;
                if (agent_turn.getBool(p, "resolved") orelse false) continue;
                return try self.gpa.dupe(u8, agent_turn.getStr(p, "requestId").?);
            }
        }
        return null;
    }

    pub fn readFile(self: *Rig, name: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.dir, name });
        defer self.gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1 << 20));
    }

    /// Wait until a question is open.
    pub fn waitQuestion(self: *Rig, ms: u32) !void {
        var waited: u32 = 0;
        while (waited < ms) : (waited += 10) {
            if (try self.openRequestId()) |rid| {
                self.gpa.free(rid);
                return;
            }
            try Io.sleep(self.io, .fromMilliseconds(10), .awake);
        }
        self.killAll();
        return error.TestTimeout;
    }

    /// Answer the open question with `label`.
    pub fn answerOpen(self: *Rig, question_id: []const u8, label: []const u8) !void {
        const rid = (try self.openRequestId()) orelse return error.NoOpenQuestion;
        defer self.gpa.free(rid);
        const cmd = try std.fmt.allocPrint(self.gpa, "{{\"kind\":\"respondInput\",\"requestId\":{f},\"answers\":[{{\"questionId\":{f},\"labels\":[{f}]}}]}}", .{ json.fmt(rid, .{}), json.fmt(question_id, .{}), json.fmt(label, .{}) });
        defer self.gpa.free(cmd);
        try self.command(cmd);
    }
};
