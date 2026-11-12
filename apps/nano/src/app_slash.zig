//! The `/` menu's catalogs and choices (slash_menu.zig for the rules): the
//! agent's commands (`ListCommands`) and skills (`ListSkills`) for the chat
//! or draft's project, asked once per agent and project; picking one.
const std = @import("std");
const json = std.json;
const rpc = @import("rpc.zig");
const App = @import("app.zig").App;
const menu = @import("slash_menu.zig");
const Allocator = std.mem.Allocator;

pub const Status = enum { idle, loading, ready, failed };

pub const Catalog = struct {
    status: Status = .idle,
    call: ?u64 = null,
    err_buf: [240]u8 = undefined,
    err_len: usize = 0,

    pub fn errText(c: *const Catalog) []const u8 {
        return c.err_buf[0..c.err_len];
    }
};

pub const State = struct {
    /// "harness\x00chat\x00space": what the catalogs are for.
    key: std.ArrayList(u8) = .empty,
    arena: ?std.heap.ArenaAllocator = null,
    commands: std.ArrayList(menu.Command) = .empty,
    skills: std.ArrayList(menu.Skill) = .empty,
    cmd: Catalog = .{},
    skill: Catalog = .{},
    items: std.ArrayList(menu.Item) = .empty,
    names: std.ArrayList(u8) = .empty,
    matches: [64]usize = undefined,
    match_count: usize = 0,
    selected: usize = 0,
    /// The trigger Escape dismissed (its slash's offset), until it changes.
    dismissed: ?usize = null,
    /// The query the selection was for: a new one starts at the top.
    query_hash: u64 = 0,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.key.deinit(gpa);
        if (s.arena) |*ar| ar.deinit();
        s.commands.deinit(gpa);
        s.skills.deinit(gpa);
        s.items.deinit(gpa);
        s.names.deinit(gpa);
    }
};

fn st(a: *App) *State {
    return &a.ui_gaps.slash;
}

const Target = struct { harness: []const u8, chat: ?[]const u8, space: ?[]const u8 };

fn targetOf(a: *App) Target {
    const t = a.target();
    const space: ?[]const u8 = if (a.selected == null) (if (a.newChatSpace()) |sp| sp.id else null) else null;
    return .{ .harness = t.harness, .chat = a.selected, .space = space };
}

/// The catalogs for the composer's agent and project, asked when they
/// aren't the ones held.
pub fn ensure(a: *App) void {
    const s = st(a);
    const t = targetOf(a);
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\x00{s}\x00{s}", .{ t.harness, t.chat orelse "", t.space orelse "" }) catch return;
    if (std.mem.eql(u8, key, s.key.items) and s.cmd.status != .idle) return;
    s.key.clearRetainingCapacity();
    s.key.appendSlice(a.gpa, key) catch return;
    s.commands.clearRetainingCapacity();
    s.skills.clearRetainingCapacity();
    if (s.arena) |*ar| _ = ar.reset(.retain_capacity) else s.arena = .init(a.gpa);
    ask(a, &s.cmd, "ListCommands", t, onCommands);
    ask(a, &s.skill, "ListSkills", t, onSkills);
}

fn ask(a: *App, cat: *Catalog, method: []const u8, t: Target, comptime h: fn (*App, u64, rpc.Reply) void) void {
    if (cat.call) |id| a.engine.cancel(id);
    cat.status = .loading;
    cat.call = a.send_(.{ .method = method, .params = .{ .harness = t.harness, .chatId = t.chat, .spaceId = t.space } }, .of(App, a, h));
    if (cat.call == null) failed(cat, "Not connected to the engine.");
}

fn failed(cat: *Catalog, why: []const u8) void {
    const n = @min(why.len, cat.err_buf.len);
    @memcpy(cat.err_buf[0..n], why[0..n]);
    cat.err_len = n;
    cat.status = .failed;
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `ListCommands`' reply: `[{ name, description, inputHint? }]`.
pub fn parseCommands(arena: Allocator, gpa: Allocator, v: json.Value, out: *std.ArrayList(menu.Command)) !void {
    if (v != .array) return error.UnexpectedReply;
    for (v.array.items) |x| {
        if (x != .object) return error.UnexpectedReply;
        const name = str(x.object, "name") orelse return error.UnexpectedReply;
        try out.append(gpa, .{ .name = try arena.dupe(u8, name), .description = try arena.dupe(u8, str(x.object, "description") orelse "") });
    }
}

/// `ListSkills`' reply: `[{ name, path, description, enabled, command? }]`.
pub fn parseSkills(arena: Allocator, gpa: Allocator, v: json.Value, out: *std.ArrayList(menu.Skill)) !void {
    if (v != .array) return error.UnexpectedReply;
    for (v.array.items) |x| {
        if (x != .object) return error.UnexpectedReply;
        const name = str(x.object, "name") orelse return error.UnexpectedReply;
        const enabled = if (x.object.get("enabled")) |e| e == .bool and e.bool else true;
        var command: ?[]const u8 = null;
        if (x.object.get("command")) |cmd| if (cmd == .object) if (str(cmd.object, "name")) |n| {
            command = try arena.dupe(u8, n);
        };
        try out.append(gpa, .{ .name = try arena.dupe(u8, name), .description = try arena.dupe(u8, str(x.object, "description") orelse ""), .enabled = enabled, .command = command });
    }
}

fn onCommands(a: *App, id: u64, r: rpc.Reply) void {
    const s = st(a);
    if (s.cmd.call != id) return;
    s.cmd.call = null;
    switch (r) {
        .ok => |v| {
            parseCommands(s.arena.?.allocator(), a.gpa, v, &s.commands) catch {
                s.commands.clearRetainingCapacity();
                return failed(&s.cmd, "The engine sent an unexpected list of commands.");
            };
            s.cmd.status = .ready;
        },
        .err => |why| failed(&s.cmd, why),
        else => {},
    }
    a.redraw();
}

fn onSkills(a: *App, id: u64, r: rpc.Reply) void {
    const s = st(a);
    if (s.skill.call != id) return;
    s.skill.call = null;
    switch (r) {
        .ok => |v| {
            parseSkills(s.arena.?.allocator(), a.gpa, v, &s.skills) catch {
                s.skills.clearRetainingCapacity();
                return failed(&s.skill, "The engine sent an unexpected list of skills.");
            };
            s.skill.status = .ready;
        },
        .err => |why| failed(&s.skill, why),
        else => {},
    }
    a.redraw();
}

/// The entries and the ones matching `query`, ready to draw.
pub fn refresh(a: *App, query: []const u8) void {
    const s = st(a);
    menu.build(a.gpa, &s.items, &s.names, s.commands.items, s.skills.items, a.selected != null) catch return;
    s.match_count = menu.filter(s.items.items, query, &s.matches);
    const h = std.hash.Wyhash.hash(0, query);
    if (h != s.query_hash) {
        s.query_hash = h;
        s.selected = 0;
    }
    if (s.selected >= s.match_count) s.selected = if (s.match_count > 0) s.match_count - 1 else 0;
}

/// Picks entry `ix` of the matches for the trigger `t`: a workspace action
/// takes only its trigger out and runs; a command or skill is written in
/// its place, followed by a space.
pub fn pick(a: *App, scratch: Allocator, t: menu.Trigger, ix: usize) void {
    const s = st(a);
    if (ix >= s.match_count) return;
    const item = s.items.items[s.matches[ix]];
    const text = a.composer.text();
    const end = @min(t.end, text.len);
    const insert: []const u8 = if (item.action != null) "" else std.fmt.allocPrint(scratch, "/{s} ", .{item.name}) catch return;
    const next = std.mem.concat(scratch, u8, &.{ text[0..t.start], insert, text[end..] }) catch return;
    a.composer.set(next);
    a.composer.want_caret = t.start + insert.len;
    s.dismissed = null;
    if (item.action) |act| run(a, act);
    a.view.focus_composer = true;
    a.redraw();
}

fn run(a: *App, act: menu.Action) void {
    switch (act) {
        .model => {
            a.picker = .model;
            @import("view_picker.zig").opened(a);
        },
        .new => a.newTab(),
        .@"resume" => @import("view_palette.zig").toggle(a, .replace_current),
        .settings => @import("view_settings.zig").open(a),
        .diff => @import("app_panels.zig").addDiffsTab(a),
        .files => if (!a.panels.files_open) @import("app_files.zig").toggle(a),
        .rename => if (a.selected) |id| if (a.findChat(id)) |ch| @import("view_chat_menu.zig").startRename(a, ch),
        .stop => a.interrupt(),
    }
}

const testing = std.testing;

test "catalog replies parse; a malformed one is an error" {
    const gpa = testing.allocator;
    var ar: std.heap.ArenaAllocator = .init(gpa);
    defer ar.deinit();
    var cmds: std.ArrayList(menu.Command) = .empty;
    defer cmds.deinit(gpa);
    const c = try json.parseFromSlice(json.Value, gpa, "[{\"name\":\"compact\",\"description\":\"Compact conversation history\"}]", .{});
    defer c.deinit();
    try parseCommands(ar.allocator(), gpa, c.value, &cmds);
    try testing.expectEqualStrings("compact", cmds.items[0].name);
    var skills: std.ArrayList(menu.Skill) = .empty;
    defer skills.deinit(gpa);
    const sk = try json.parseFromSlice(json.Value, gpa, "[{\"name\":\"review\",\"path\":\"/s\",\"description\":\"d\",\"enabled\":false,\"command\":{\"name\":\"skill:review\",\"harness\":\"pi\"}}]", .{});
    defer sk.deinit();
    try parseSkills(ar.allocator(), gpa, sk.value, &skills);
    try testing.expect(!skills.items[0].enabled);
    try testing.expectEqualStrings("skill:review", skills.items[0].command.?);
    const bad = try json.parseFromSlice(json.Value, gpa, "{\"commands\":[]}", .{});
    defer bad.deinit();
    try testing.expectError(error.UnexpectedReply, parseCommands(ar.allocator(), gpa, bad.value, &cmds));
}
