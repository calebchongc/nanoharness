//! The composer's `/` menu's rules (docs/harness-skill-completion.md): where
//! a trigger is, the workspace's own actions and how a provider command of
//! the same name renames them, the entries the catalogs add, and filtering.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Action = enum { model, new, @"resume", settings, diff, files, rename, stop };

pub const WorkspaceAction = struct { action: Action, name: []const u8, description: []const u8, needs_chat: bool };

/// The table's actions. `/terminal` is left out until the desktop has a
/// terminal tab to open.
pub const actions = [_]WorkspaceAction{
    .{ .action = .model, .name = "model", .description = "Choose agent, model, and reasoning", .needs_chat = false },
    .{ .action = .new, .name = "new", .description = "Start a new conversation", .needs_chat = false },
    .{ .action = .@"resume", .name = "resume", .description = "Search and open conversations", .needs_chat = false },
    .{ .action = .settings, .name = "settings", .description = "Open Harness settings", .needs_chat = false },
    .{ .action = .diff, .name = "diff", .description = "Open a changes tab", .needs_chat = true },
    .{ .action = .files, .name = "files", .description = "Open project files", .needs_chat = true },
    .{ .action = .rename, .name = "rename", .description = "Open the conversation rename dialog", .needs_chat = true },
    .{ .action = .stop, .name = "stop", .description = "Interrupt the current run", .needs_chat = true },
};

pub const Source = enum { workspace, command, skill };

pub const Item = struct {
    /// What follows the slash ("harness:model" when a provider owns "model").
    name: []const u8,
    description: []const u8,
    source: Source,
    action: ?Action = null,
};

pub const Trigger = struct {
    /// The slash's offset, and the caret's.
    start: usize,
    end: usize,
    query: []const u8,
};

fn nameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':' or ch == '.' or ch >= 0x80;
}

/// A `/word` being typed at the caret, at any word boundary of any line;
/// code (inline or fenced), URLs and paths stay literal.
pub fn trigger(text: []const u8, caret_in: usize) ?Trigger {
    const caret = @min(caret_in, text.len);
    var start = caret;
    while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) start -= 1;
    if (start >= caret or text[start] != '/') return null;
    for (text[start + 1 .. caret]) |ch| if (!nameChar(ch)) return null;
    // The rest of the word, after the caret, is part of it: a path's tail.
    if (caret < text.len and !std.ascii.isWhitespace(text[caret])) return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], '\n')) |n| n + 1 else 0;
    if (std.mem.count(u8, text[line_start..start], "`") % 2 == 1) return null;
    var fenced = false;
    var it = std.mem.splitScalar(u8, text[0..line_start], '\n');
    while (it.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) fenced = !fenced;
    }
    if (fenced) return null;
    return .{ .start = start, .end = caret, .query = text[start + 1 .. caret] };
}

pub const Command = struct { name: []const u8, description: []const u8 };
pub const Skill = struct { name: []const u8, description: []const u8, enabled: bool, command: ?[]const u8 = null };

/// Every entry, in order: provider commands, skills, then the workspace's
/// actions (only those that need a conversation when there is one). A
/// provider command keeps its name; the action takes a `harness:` prefix.
pub fn build(gpa: Allocator, out: *std.ArrayList(Item), name_buf: *std.ArrayList(u8), commands: []const Command, skills: []const Skill, in_chat: bool) !void {
    out.clearRetainingCapacity();
    name_buf.clearRetainingCapacity();
    // Prefixed names live in one buffer: reserve it all so slices stay put.
    try name_buf.ensureTotalCapacity(gpa, actions.len * 32);
    for (commands) |cmd| if (cmd.name.len > 0) try out.append(gpa, .{ .name = cmd.name, .description = cmd.description, .source = .command });
    for (skills) |sk| if (sk.enabled and sk.name.len > 0) {
        const name = sk.command orelse sk.name;
        const dup = for (out.items) |it| {
            if (std.mem.eql(u8, it.name, name)) break true;
        } else false;
        if (!dup) try out.append(gpa, .{ .name = name, .description = sk.description, .source = .skill });
    };
    for (actions) |act| {
        if (act.needs_chat and !in_chat) continue;
        const taken = for (out.items) |it| {
            if (std.mem.eql(u8, it.name, act.name)) break true;
        } else false;
        var name: []const u8 = act.name;
        if (taken) {
            const at = name_buf.items.len;
            name_buf.appendSliceAssumeCapacity("harness:");
            name_buf.appendSliceAssumeCapacity(act.name);
            name = name_buf.items[at..];
        }
        try out.append(gpa, .{ .name = name, .description = act.description, .source = .workspace, .action = act.action });
    }
}

/// The entries matching `query`, best first: names that start with it,
/// then names that contain it, then descriptions that do; case-insensitive,
/// otherwise in catalog order. Returns how many indices were written.
pub fn filter(items: []const Item, query: []const u8, out: []usize) usize {
    var n: usize = 0;
    for (0..3) |rank| for (items, 0..) |it, i| {
        if (n >= out.len) return n;
        const r = rankOf(it, query) orelse continue;
        if (r == rank) {
            out[n] = i;
            n += 1;
        }
    };
    return n;
}

fn rankOf(it: Item, q: []const u8) ?usize {
    if (q.len == 0) return 0;
    if (startsWithIgnoreCase(it.name, q)) return 0;
    if (containsIgnoreCase(it.name, q)) return 1;
    if (containsIgnoreCase(it.description, q)) return 2;
    return null;
}

fn containsIgnoreCase(s: []const u8, p: []const u8) bool {
    if (p.len > s.len) return false;
    for (0..s.len - p.len + 1) |i| if (std.ascii.eqlIgnoreCase(s[i .. i + p.len], p)) return true;
    return false;
}

fn startsWithIgnoreCase(s: []const u8, p: []const u8) bool {
    return s.len >= p.len and std.ascii.eqlIgnoreCase(s[0..p.len], p);
}

/// The selection moved by `by`, wrapping.
pub fn move(selected: usize, count: usize, by: i32) usize {
    if (count == 0) return 0;
    const n: i64 = @intCast(count);
    return @intCast(@mod(@as(i64, @intCast(@min(selected, count - 1))) + by, n));
}

const testing = std.testing;

test "a trigger is a /word at a word boundary, not code, a URL or a path" {
    try testing.expectEqualStrings("mo", trigger("/mo", 3).?.query);
    try testing.expectEqualStrings("", trigger("hi /", 4).?.query);
    try testing.expectEqual(@as(usize, 6), trigger("line\n /co", 9).?.start);
    try testing.expect(trigger("a/b", 3) == null);
    try testing.expect(trigger("https://x", 9) == null);
    try testing.expect(trigger("/usr/bin", 8) == null);
    try testing.expect(trigger("see `/mo", 8) == null);
    try testing.expect(trigger("```\n/mo", 7) == null);
    try testing.expect(trigger("```\nx\n```\n/mo", 13) != null);
    // The caret inside a longer word: not a completion.
    try testing.expect(trigger("/model", 3) == null);
    try testing.expect(trigger("plain", 5) == null);
}

test "workspace actions, provider commands and skills; a provider's name wins" {
    const gpa = testing.allocator;
    var out: std.ArrayList(Item) = .empty;
    defer out.deinit(gpa);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    const cmds = [_]Command{ .{ .name = "compact", .description = "Compact conversation history" }, .{ .name = "model", .description = "Provider model" } };
    const skills = [_]Skill{ .{ .name = "review", .description = "Review a diff", .enabled = true }, .{ .name = "off", .description = "", .enabled = false }, .{ .name = "compact", .description = "dup", .enabled = true } };
    try build(gpa, &out, &names, &cmds, &skills, false);
    // Two commands, one skill (the disabled and duplicate ones left out),
    // and the four actions a draft offers.
    try testing.expectEqual(@as(usize, 2 + 1 + 4), out.items.len);
    try testing.expectEqualStrings("model", out.items[1].name);
    try testing.expectEqual(Source.command, out.items[1].source);
    try testing.expectEqualStrings("harness:model", out.items[3].name);
    try testing.expectEqual(@as(?Action, .model), out.items[3].action);
    try build(gpa, &out, &names, &.{}, &.{}, true);
    try testing.expectEqual(actions.len, out.items.len);
    try testing.expectEqualStrings("model", out.items[0].name);
}

test "filtering ranks prefix, then name, then description matches" {
    const items = [_]Item{
        .{ .name = "review", .description = "Look at the model's diff", .source = .skill },
        .{ .name = "harness:model", .description = "Choose", .source = .workspace },
        .{ .name = "model", .description = "Provider", .source = .command },
        .{ .name = "new", .description = "Start", .source = .workspace },
    };
    var out: [8]usize = undefined;
    const n = filter(&items, "MOD", &out);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, out[0..n]);
    try testing.expectEqual(@as(usize, 4), filter(&items, "", &out));
    try testing.expectEqual(@as(usize, 0), filter(&items, "zzz", &out));
    try testing.expectEqual(@as(usize, 0), move(3, 4, 1));
    try testing.expectEqual(@as(usize, 3), move(0, 4, -1));
}
