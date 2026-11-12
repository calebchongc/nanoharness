//! Bots (`crates/mcp/src/tools/bots.rs`, codegraff ADR 0333): a graff Bot is
//! a standing role kept in a project's `.graff/bots/<name>/`. graff owns the
//! store and every prompt's wording; these tools read both through
//! `graff bot … --json` and start each run as an ordinary graff chat. The
//! person's own bots (ADR 0334) live in the engine and run in their
//! standing chat through `BotsState`/`RunBot`.
const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const u = @import("util.zig");
const tools = @import("tools.zig");
const peer = @import("peer.zig");
const Ctx = tools.Ctx;
const Value = json.Value;

/// Every command reads or rewrites a few small files; none runs a model.
const bot_timeout_ms: i64 = 20_000;

pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "list_bots") or std.mem.eql(u8, name, "run_bot") or std.mem.eql(u8, name, "run_due_bots");
}

/// Runs `graff bot <args>` in a project folder and returns what it printed.
pub const BotCli = struct {
    ptr: *anyopaque,
    bot_fn: *const fn (ptr: *anyopaque, a: Allocator, folder: []const u8, args: []const []const u8) anyerror!Result,

    pub const Result = union(enum) { ok: []const u8, err: []const u8 };

    pub fn bot(b: BotCli, a: Allocator, folder: []const u8, args: []const []const u8) !Result {
        return b.bot_fn(b.ptr, a, folder, args);
    }
};

/// Whether a graff's help text lists the `bot` command.
pub fn helpListsBots(help: []const u8) bool {
    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t\r"), "graff bot ")) return true;
    }
    return false;
}

/// The graff Harness runs chats with.
pub const GraffBots = struct {
    io: Io,
    graff: []const u8,
    /// A graff from before bots reads `bot list` as a prompt and would spend
    /// a model call on it, so the help text is checked first. Only a yes is
    /// kept: graff can be updated while this server runs.
    has_bots: std.atomic.Value(bool) = .init(false),

    pub fn cli(self: *GraffBots) BotCli {
        return .{ .ptr = self, .bot_fn = botFn };
    }

    fn run(self: *GraffBots, a: Allocator, folder: []const u8, args: []const []const u8) !union(enum) { out: peer.RunOutput, err: []const u8 } {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, self.graff);
        try argv.appendSlice(a, args);
        return switch (try peer.runCli(a, self.io, argv.items, folder, null, bot_timeout_ms)) {
            .out => |o| .{ .out = o },
            .failed => |why| if (std.mem.eql(u8, why, "timeout"))
                .{ .err = try std.fmt.allocPrint(a, "graff {s} timed out after 20s", .{try std.mem.join(a, " ", args)}) }
            else
                .{ .err = try std.fmt.allocPrint(a, "could not run {s}", .{self.graff}) },
        };
    }

    fn botFn(ptr: *anyopaque, a: Allocator, folder: []const u8, args: []const []const u8) anyerror!BotCli.Result {
        const self: *GraffBots = @ptrCast(@alignCast(ptr));
        if (!self.has_bots.load(.monotonic)) {
            const help = switch (try self.run(a, folder, &.{"--help"})) {
                .out => |o| o,
                .err => |m| return .{ .err = m },
            };
            if (!helpListsBots(help.stdout)) return .{ .err = "this graff has no `graff bot` command; update graff to use bots" };
            self.has_bots.store(true, .monotonic);
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, "bot");
        try argv.appendSlice(a, args);
        const o = switch (try self.run(a, folder, argv.items)) {
            .out => |o| o,
            .err => |m| return .{ .err = m },
        };
        const stdout = u.trim(o.stdout);
        if (!o.ok) {
            const stderr = u.trim(o.stderr);
            return .{ .err = if (stdout.len > 0) stdout else if (stderr.len > 0) stderr else o.term };
        }
        return .{ .ok = stdout };
    }
};

fn botCall(c: *Ctx, folder: []const u8, args: []const []const u8) ![]const u8 {
    return switch (try c.t.bots.bot(c.a, folder, args)) {
        .ok => |out| out,
        .err => |m| c.failMsg(m),
    };
}

/// `serde_json::from_str::<Vec<T>>` with the fields `T` requires.
fn rows(c: *Ctx, command: []const u8, stdout: []const u8, required_strings: []const []const u8) ![]const Value {
    const parsed = json.parseFromSliceLeaky(Value, c.a, stdout, .{ .allocate = .alloc_always }) catch
        return c.fail("graff bot {s} did not print the JSON this Harness reads", .{command});
    if (parsed != .array) return c.fail("graff bot {s} did not print the JSON this Harness reads", .{command});
    for (parsed.array.items) |row| {
        for (required_strings) |k| {
            if (u.str(row, k) == null) return c.fail("graff bot {s} did not print the JSON this Harness reads", .{command});
        }
    }
    return parsed.array.items;
}

const bot_fields = [_][]const u8{ "name", "job" };
const routine_fields = [_][]const u8{ "bot", "id", "instruction", "when", "message" };
const due_fields = [_][]const u8{ "bot", "id", "instruction", "system", "message" };

/// A bot's standing text and the turn, as the one message that starts a chat.
pub fn firstMessage(a: Allocator, system: []const u8, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\n\n{s}", .{ u.trim(system), u.trim(message) });
}

pub fn call(c: *Ctx, name: []const u8, args: Value) !Value {
    if (std.mem.eql(u8, name, "list_bots")) return listBots(c, args);
    if (std.mem.eql(u8, name, "run_bot")) return runBot(c, args);
    if (std.mem.eql(u8, name, "run_due_bots")) return runDueBots(c, args);
    return c.fail("unknown tool: {s}", .{name});
}

/// The project whose bots a call is about; it must be hosted here.
fn botSpace(c: *Ctx, args: Value) !Value {
    const space = if (tools.given(args, "project")) |key| try c.resolveSpace(key) else blk: {
        const chat_id = c.t.origin.chat_id orelse return c.failMsg("name the project: this server is not speaking for a chat");
        const chat = try c.resolveChat(chat_id);
        const space_id = u.str(chat, "spaceId") orelse return c.failMsg("this chat has no project; name one (see list_projects)");
        break :blk try c.resolveSpace(space_id);
    };
    if (!std.mem.eql(u8, u.str(space, "deviceId") orelse "", try c.localDeviceId())) {
        return c.fail("bots are files in the project folder, and {s} is hosted on another device; ask a chat on that device", .{tools.displayName(space)});
    }
    return space;
}

fn botsIn(c: *Ctx, space: Value) ![]const Value {
    return rows(c, "list", try botCall(c, u.str(space, "path") orelse "", &.{ "list", "--json" }), &bot_fields);
}

/// The person's own bots; none from an engine without them.
fn ownBots(c: *Ctx) ![]const Value {
    return switch (try c.t.engine.call(c.a, "BotsState", "{}")) {
        .ok => |state| u.array(state, "bots") orelse u.none,
        .err => &.{},
    };
}

const project_fields = [_]tools.Field{.{ .name = "project", .kind = .opt_string }};

fn listBots(c: *Ctx, args: Value) !Value {
    try tools.decode(c, args, "ProjectArgs", &project_fields, false);
    const a = c.a;
    const yours: []const Value = if (tools.given(args, "project") == null) try ownBots(c) else &.{};
    const space = botSpace(c, args) catch |err| switch (err) {
        // No project to look in, but the person's own bots need none.
        error.ToolFailed => if (yours.len > 0) {
            var r = u.obj(a);
            var ys = u.arr(a);
            try ys.appendSlice(yours);
            try r.put("yours", .{ .array = ys });
            return r.value();
        } else return err,
        else => return err,
    };
    const folder = u.str(space, "path") orelse "";
    const all_bots = try botsIn(c, space);
    const routines = try rows(c, "routine list", try botCall(c, folder, &.{ "routine", "list", "--json" }), &routine_fields);
    const due = try rows(c, "due", try botCall(c, folder, &.{ "due", "--json" }), &due_fields);
    var listed = u.arr(a);
    for (all_bots) |bot| {
        const bot_name = u.str(bot, "name").?;
        var rs = u.arr(a);
        for (routines) |r| {
            if (!std.mem.eql(u8, u.str(r, "bot").?, bot_name)) continue;
            const is_due = for (due) |d| {
                if (std.mem.eql(u8, u.str(d, "bot").?, u.str(r, "bot").?) and std.mem.eql(u8, u.str(d, "id").?, u.str(r, "id").?)) break true;
            } else false;
            var o = u.obj(a);
            try o.put("id", u.field(r, "id"));
            try o.put("instruction", u.field(r, "instruction"));
            try o.put("when", u.field(r, "when"));
            try o.put("paused", u.b(u.boolean(r, "paused") orelse false));
            try o.put("done", u.b(u.boolean(r, "done") orelse false));
            try o.put("runs", u.i(u.int(r, "runs") orelse 0));
            try o.put("due", u.b(is_due));
            try rs.append(o.value());
        }
        const model = u.str(bot, "model") orelse "";
        var o = u.obj(a);
        try o.put("name", u.s(bot_name));
        try o.put("job", u.field(bot, "job"));
        try o.put("model", if (model.len > 0) u.s(model) else .null);
        try o.put("skipsApprovals", u.b(u.boolean(bot, "yolo") orelse false));
        try o.put("routines", .{ .array = rs });
        try listed.append(o.value());
    }
    var r = u.obj(a);
    try r.put("project", try tools.projectValue(a, space));
    try r.put("bots", .{ .array = listed });
    if (yours.len > 0) {
        var ys = u.arr(a);
        try ys.appendSlice(yours);
        try r.put("yours", .{ .array = ys });
    }
    if (all_bots.len == 0) try r.put("note", u.s("No bots in this project yet. Create one in its folder: graff bot create NAME \"the one job it holds\""));
    return r.value();
}

fn runBot(c: *Ctx, args: Value) !Value {
    try tools.decode(c, args, "RunArgs", &.{
        .{ .name = "project", .kind = .opt_string },
        .{ .name = "bot", .kind = .string, .required = true },
        .{ .name = "message", .kind = .opt_string },
        .{ .name = "routine", .kind = .opt_string },
        .{ .name = "wait", .kind = .bool_default },
        .{ .name = "timeout_secs", .kind = .opt_u64 },
    }, false);
    const a = c.a;
    const name = u.trim(tools.argStr(args, "bot").?);
    const message = tools.given(args, "message");
    const routine = tools.given(args, "routine");
    // One of the person's own bots, when no project is named: the engine
    // puts the turn into that bot's standing chat.
    if (tools.given(args, "project") == null) {
        const own = try ownBots(c);
        const is_own = for (own) |bot| {
            if (std.mem.eql(u8, u.str(bot, "name") orelse "\x00", name)) break true;
        } else false;
        if (is_own) {
            var p = u.obj(a);
            try p.put("bot", u.s(name));
            if (message != null and routine == null) {
                try p.put("message", u.s(message.?));
            } else if (message == null and routine != null) {
                try p.put("routine", u.s(routine.?));
            } else return c.failMsg("pass message or routine, one of them");
            var ran = try c.call("RunBot", p.value());
            if (ran == .null) ran = u.obj(a).value();
            if (ran == .object) try ran.object.put(a, "standingChat", u.b(true));
            return ran;
        }
    }
    const space = try botSpace(c, args);
    const folder = u.str(space, "path") orelse "";
    const all_bots = try botsIn(c, space);
    const bot = for (all_bots) |b| {
        if (std.mem.eql(u8, u.str(b, "name").?, name)) break b;
    } else {
        var known: std.ArrayList(u8) = .empty;
        for (all_bots, 0..) |b, k| {
            if (k > 0) try known.appendSlice(a, ", ");
            try known.appendSlice(a, u.str(b, "name").?);
        }
        return c.fail("no bot named {s} in {s}; it has: {s}", .{ try u.debugQuote(a, name), tools.displayName(space), if (known.items.len == 0) "none" else known.items });
    };
    var title: []const u8 = undefined;
    var turn: []const u8 = undefined;
    if (message != null and routine == null) {
        title = u.str(bot, "name").?;
        turn = message.?;
    } else if (message == null and routine != null) {
        const id = routine.?;
        const routines = try rows(c, "routine list", try botCall(c, folder, &.{ "routine", "list", name, "--json" }), &routine_fields);
        const found = for (routines) |r| {
            if (std.mem.eql(u8, u.str(r, "bot").?, name) and std.mem.eql(u8, u.str(r, "id").?, id)) break r;
        } else return c.fail("{s} has no routine {s} (see list_bots)", .{ name, try u.debugQuote(a, id) });
        title = try std.fmt.allocPrint(a, "{s}: {s}", .{ name, id });
        turn = u.str(found, "message").?;
    } else return c.failMsg("pass message or routine, one of them");
    const system = try botCall(c, folder, &.{ "prompt", name });
    return startBotChat(c, space, bot, title, system, turn, tools.argBool(args, "wait") orelse false, tools.argUint(args, "timeout_secs"));
}

fn runDueBots(c: *Ctx, args: Value) !Value {
    try tools.decode(c, args, "ProjectArgs", &project_fields, false);
    const a = c.a;
    const space = try botSpace(c, args);
    const folder = u.str(space, "path") orelse "";
    const all_bots = try botsIn(c, space);
    // From here each row is claimed: graff has moved it to its next slot.
    const due = try rows(c, "due", try botCall(c, folder, &.{ "due", "--claim", "--json" }), &due_fields);
    var started = u.arr(a);
    var failed = u.arr(a);
    for (due) |row| {
        const bot_name = u.str(row, "bot").?;
        const routine_id = u.str(row, "id").?;
        const bot: ?Value = for (all_bots) |b| {
            if (std.mem.eql(u8, u.str(b, "name").?, bot_name)) break b;
        } else null;
        var probe: Ctx = .{ .t = c.t, .a = a };
        const run: ?Value = if (bot) |b|
            startBotChat(&probe, space, b, try std.fmt.allocPrint(a, "{s}: {s}", .{ bot_name, routine_id }), u.str(row, "system").?, u.str(row, "message").?, false, null) catch |err| switch (err) {
                error.ToolFailed => null,
                else => return err,
            }
        else blk: {
            probe.msg = "its bot is gone";
            break :blk null;
        };
        if (run) |chat| {
            var o = u.obj(a);
            try o.put("bot", u.s(bot_name));
            try o.put("routine", u.s(routine_id));
            try o.put("instruction", u.field(row, "instruction"));
            try o.put("chatId", u.field(chat, "chatId"));
            try started.append(o.value());
        } else {
            var o = u.obj(a);
            try o.put("bot", u.s(bot_name));
            try o.put("routine", u.s(routine_id));
            try o.put("error", u.s(probe.msg));
            try failed.append(o.value());
        }
    }
    var r = u.obj(a);
    const any_failed = failed.items.len > 0;
    try r.put("started", .{ .array = started });
    if (any_failed) {
        try r.put("failed", .{ .array = failed });
        try r.put("note", u.s("A failed routine was already moved to its next slot. Run it now with run_bot and its routine id."));
    } else if (due.len == 0) {
        try r.put("note", u.s("Nothing is due."));
    }
    return r.value();
}

fn startBotChat(c: *Ctx, space: Value, bot: Value, title: []const u8, system: []const u8, message: []const u8, wait: bool, timeout_secs: ?u64) !Value {
    const a = c.a;
    // The bot's model is a graff model name; one this device does not offer
    // would refuse the run, so the chat takes graff's default instead.
    const bot_model = u.str(bot, "model") orelse "";
    var probe: Ctx = .{ .t = c.t, .a = a };
    const offered: []const Value = probe.models("graff") catch |err| switch (err) {
        error.ToolFailed => &.{},
        else => return err,
    };
    const known = offered.len == 0 or for (offered) |m| {
        if (std.mem.eql(u8, u.str(m, "id") orelse "", bot_model)) break true;
    } else false;
    const model: ?[]const u8 = if (bot_model.len > 0 and known) bot_model else null;
    var created = try tools.createChat(c, .{
        .project = u.str(space, "id"),
        .harness = "graff",
        .model = model,
        .title = title,
        .prompt = try firstMessage(a, system, message),
        .wait = wait,
        .timeout_secs = timeout_secs,
    });
    try created.object.put(a, "bot", u.field(bot, "name"));
    if (bot_model.len > 0 and !known) try created.object.put(a, "modelIgnored", u.s(bot_model));
    return created;
}

const testing = std.testing;

test "mcp bots: a graff without the bot command is told apart by its help" {
    try testing.expect(helpListsBots("Usage:\n  graff [prompt]\n  graff bot create NAME JOB\n"));
    try testing.expect(!helpListsBots("Usage:\n  graff [prompt]\n  graff peer send\n"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("standing text\n\ndo the job", try firstMessage(arena.allocator(), "  standing text\n", "\ndo the job "));
}

test "mcp bots: the real CLI checks graff's help first and reports a missing command" {
    if (comptime !std.process.can_spawn) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `/bin/echo --help` prints `--help`: no `graff bot` line.
    var gb: GraffBots = .{ .io = testing.io, .graff = "/bin/echo" };
    const r = try gb.cli().bot(a, ".", &.{ "list", "--json" });
    try testing.expectEqualStrings("this graff has no `graff bot` command; update graff to use bots", r.err);
    var missing: GraffBots = .{ .io = testing.io, .graff = "/nonexistent/graff" };
    const m = try missing.cli().bot(a, ".", &.{ "list", "--json" });
    try testing.expectEqualStrings("could not run /nonexistent/graff", m.err);
}
