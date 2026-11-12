//! Flatten session-doc entries into agent-readable messages
//! (`crates/mcp/src/transcript.rs`), and pick a wait's replies
//! (`crates/mcp/src/turn_replies.rs`).
//!
//! An assistant message is a list of parts (text, thinking, tool chips,
//! input requests, errors), and long turns split into continuation entries.
//! An agent reading another chat wants prose plus one line per tool call.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const u = @import("util.zig");
const Value = json.Value;

pub const Options = struct {
    /// Model thinking. Off by default: long, rarely what a coordinator needs.
    include_reasoning: bool = false,
    include_tools: bool = true,
};

pub const Message = struct {
    id: []const u8,
    role: []const u8,
    created_at: i64,
    device_id: []const u8,
    status: ?[]const u8,
    text: std.ArrayList(u8) = .empty,
    reasoning: ?std.ArrayList(u8) = null,
    tools: std.ArrayList([]const u8) = .empty,
    pending_input: ?Value = null,
    errors: std.ArrayList([]const u8) = .empty,

    pub fn isRole(m: Message, role: []const u8) bool {
        return std.mem.eql(u8, m.role, role);
    }

    /// `RenderedMessage` as serde writes it (camelCase, empties skipped).
    pub fn toValue(m: Message, a: Allocator) !Value {
        var o = u.obj(a);
        try o.put("id", u.s(m.id));
        try o.put("role", u.s(m.role));
        try o.put("createdAt", u.i(m.created_at));
        const iso = try a.create([32]u8);
        try o.put("createdAtIso", u.s(u.isoSecs(iso, m.created_at)));
        try o.put("deviceId", u.s(m.device_id));
        if (m.status) |st| try o.put("status", u.s(st));
        try o.put("text", u.s(m.text.items));
        if (m.reasoning) |r| try o.put("reasoning", u.s(r.items));
        if (m.tools.items.len > 0) try o.put("tools", try u.strArray(a, m.tools.items));
        if (m.pending_input) |p| try o.put("pendingInput", p);
        if (m.errors.items.len > 0) try o.put("errors", try u.strArray(a, m.errors.items));
        return o.value();
    }
};

pub fn toValues(a: Allocator, messages: []const Message) !Value {
    var out = u.arr(a);
    for (messages) |m| try out.append(try m.toValue(a));
    return .{ .array = out };
}

/// Render entries in order, folding continuation entries into the message
/// they continue.
pub fn render(a: Allocator, entries: []const Value, options: Options) ![]Message {
    var rendered: std.ArrayList(Message) = .empty;
    for (entries) |entry| {
        const message = try renderOne(a, entry, options);
        if (u.str(entry, "continuationOf")) |parent_id| {
            var folded = false;
            for (rendered.items) |*parent| {
                if (std.mem.eql(u8, parent.id, parent_id)) {
                    try foldInto(a, parent, message);
                    folded = true;
                    break;
                }
            }
            if (folded) continue;
        }
        // A continuation whose parent is not in the window stands alone.
        try rendered.append(a, message);
    }
    return rendered.items;
}

fn foldInto(a: Allocator, parent: *Message, child: Message) !void {
    if (child.text.items.len > 0) {
        if (parent.text.items.len > 0) try parent.text.appendSlice(a, "\n\n");
        try parent.text.appendSlice(a, child.text.items);
    }
    if (child.reasoning) |more| {
        if (parent.reasoning) |*existing| {
            try existing.appendSlice(a, "\n\n");
            try existing.appendSlice(a, more.items);
        } else parent.reasoning = more;
    }
    try parent.tools.appendSlice(a, child.tools.items);
    try parent.errors.appendSlice(a, child.errors.items);
    if (child.pending_input != null) parent.pending_input = child.pending_input;
    // The continuation carries the live status of the turn.
    if (child.status != null) parent.status = child.status;
}

fn renderOne(a: Allocator, entry: Value, options: Options) !Message {
    var m: Message = .{
        .id = u.str(entry, "id") orelse "",
        .role = u.str(entry, "role") orelse "",
        .created_at = u.int(entry, "createdAt") orelse 0,
        .device_id = u.str(entry, "deviceId") orelse "",
        .status = u.str(entry, "status"),
    };
    var reasoning: std.ArrayList(u8) = .empty;
    var has_reasoning = false;
    for (u.array(entry, "parts") orelse u.none) |part| {
        const kind = u.str(part, "kind") orelse continue;
        if (std.mem.eql(u8, kind, "text")) {
            const text = u.str(part, "text") orelse "";
            if (!u.isBlank(text)) {
                if (m.text.items.len > 0) try m.text.appendSlice(a, "\n\n");
                try m.text.appendSlice(a, text);
            }
        } else if (std.mem.eql(u8, kind, "image")) {
            try m.tools.append(a, try std.fmt.allocPrint(a, "image: {s}", .{u.str(part, "name") orelse ""}));
        } else if (std.mem.eql(u8, kind, "visual")) {
            try m.tools.append(a, try std.fmt.allocPrint(a, "visual: {s}", .{u.str(part, "title") orelse ""}));
        } else if (std.mem.eql(u8, kind, "reasoning")) {
            const text = u.str(part, "text") orelse u.str(part, "reasoning") orelse "";
            if (options.include_reasoning and !u.isBlank(text)) {
                if (has_reasoning) try reasoning.appendSlice(a, "\n\n");
                try reasoning.appendSlice(a, text);
                has_reasoning = true;
            }
        } else if (std.mem.eql(u8, kind, "tool")) {
            if (options.include_tools) {
                try m.tools.append(a, try toolLine(
                    a,
                    u.field(part, "call"),
                    u.boolean(part, "isError") orelse false,
                    u.boolean(part, "resolved") orelse false,
                    u.str(part, "output"),
                ));
            }
        } else if (std.mem.eql(u8, kind, "input")) {
            if (!(u.boolean(part, "resolved") orelse false)) {
                var p = u.obj(a);
                try p.put("requestId", u.field(part, "requestId"));
                try p.put("questions", u.get(part, "questions") orelse .{ .array = u.arr(a) });
                m.pending_input = p.value();
            }
        } else if (std.mem.eql(u8, kind, "delegation")) {
            if (options.include_tools) try m.tools.append(a, try delegationCaption(a, u.field(part, "info")));
        } else if (std.mem.eql(u8, kind, "error")) {
            try m.errors.append(a, u.str(part, "message") orelse "");
        }
    }
    if (has_reasoning) m.reasoning = reasoning;
    return m;
}

/// `DelegationInfo::caption`.
fn delegationCaption(a: Allocator, info: Value) ![]const u8 {
    const context_bytes = u.int(info, "contextBytes") orelse 0;
    const context = if (context_bytes == 0)
        "Delegated task: no reference context supplied."
    else
        try std.fmt.allocPrint(a, "Delegated context: {d} bytes supplied → {d} bytes used ({s}).", .{
            context_bytes,
            u.int(info, "usedBytes") orelse 0,
            if (u.boolean(info, "summarized") orelse false) "summarized" else "not summarized",
        });
    const accounting = if (u.boolean(info, "usageReported") orelse false)
        "Usage reported by the task runner; no settled charge supplied in this metadata."
    else
        u.str(info, "usageUnavailableReason") orelse
            "Per-task usage and settled charge are unavailable; check your provider's account usage.";
    return std.fmt.allocPrint(a, "{s}\n\nUsage/cost: {s}", .{ context, accounting });
}

/// `kind: subject → first output line`, capped.
fn toolLine(a: Allocator, call: Value, is_error: bool, resolved: bool, output: ?[]const u8) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    const kind = u.str(call, "kind") orelse "unknown";
    const eq = std.mem.eql;
    if (eq(u8, kind, "exec")) {
        try line.print(a, "exec: {s}", .{try clip(a, u.str(call, "command") orelse "", 160)});
    } else if (eq(u8, kind, "readFile")) {
        try line.print(a, "read: {s}", .{u.str(call, "path") orelse ""});
    } else if (eq(u8, kind, "writeFile")) {
        try line.print(a, "write: {s}", .{u.str(call, "path") orelse ""});
    } else if (eq(u8, kind, "editFile")) {
        try line.print(a, "edit: {s}", .{u.str(call, "path") orelse ""});
    } else if (eq(u8, kind, "applyPatch")) {
        if (u.str(call, "path")) |p| try line.print(a, "patch: {s}", .{p}) else try line.appendSlice(a, "patch");
    } else if (eq(u8, kind, "search")) {
        const pattern = u.str(call, "pattern") orelse "";
        if (u.str(call, "path")) |p| try line.print(a, "search: {s} in {s}", .{ pattern, p }) else try line.print(a, "search: {s}", .{pattern});
    } else if (eq(u8, kind, "glob")) {
        try line.print(a, "glob: {s}", .{u.str(call, "pattern") orelse ""});
    } else if (eq(u8, kind, "webFetch")) {
        try line.print(a, "fetch: {s}", .{u.str(call, "url") orelse ""});
    } else if (eq(u8, kind, "webSearch")) {
        try line.print(a, "web search: {s}", .{u.str(call, "query") orelse ""});
    } else if (eq(u8, kind, "todo")) {
        const items = u.array(call, "items") orelse u.none;
        var done: usize = 0;
        for (items) |it| {
            if (u.boolean(it, "done") orelse false) done += 1;
        }
        try line.print(a, "todo: {d}/{d} done", .{ done, items.len });
    } else if (eq(u8, kind, "mcp")) {
        try line.print(a, "mcp: {s}/{s}", .{ u.str(call, "server") orelse "", u.str(call, "tool") orelse "" });
    } else {
        try line.appendSlice(a, u.str(call, "name") orelse kind);
    }
    if (output) |raw| {
        const trimmed = u.trim(raw);
        if (trimmed.len > 0) {
            const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
            var first = trimmed[0..nl];
            if (first.len > 0 and first[first.len - 1] == '\r') first = first[0 .. first.len - 1];
            try line.appendSlice(a, " → ");
            try line.appendSlice(a, try clip(a, first, 200));
        }
    }
    if (is_error) {
        try line.appendSlice(a, " (error)");
    } else if (!resolved) {
        try line.appendSlice(a, " (running)");
    }
    return line.items;
}

/// The first `max` characters, with `…` when cut.
fn clip(a: Allocator, text: []const u8, max: usize) ![]const u8 {
    var idx: usize = 0;
    var n: usize = 0;
    while (idx < text.len and n < max) : (n += 1) {
        idx += std.unicode.utf8ByteSequenceLength(text[idx]) catch 1;
    }
    idx = @min(idx, text.len);
    if (idx >= text.len) return text;
    return std.fmt.allocPrint(a, "{s}…", .{text[0..idx]});
}

pub fn lastPendingInput(messages: []const Message) ?Value {
    var k = messages.len;
    while (k > 0) {
        k -= 1;
        if (messages[k].pending_input) |p| return p;
    }
    return null;
}

// ---- turn replies ----------------------------------------------------------------

const reply_text_cap: usize = 16 * 1024;
const reply_tools_cap: usize = 40;
pub const replies_truncated_note = "Long replies were trimmed to their end; get_chat returns the full transcript.";

pub const Replies = struct { replies: []Message, truncated: bool };

/// The assistant replies of the turn a wait is about (#1415): entries from
/// the turn's start (the send, with 2 s of clock slack, or the newest user
/// message), else the newest assistant entry alone; each trimmed to its end.
pub fn turnReplies(a: Allocator, entries: []const Value, since_ms: i64) !Replies {
    const start: i64 = if (since_ms > 0) since_ms -| 2_000 else blk: {
        var k = entries.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, u.str(entries[k], "role") orelse "", "user")) break :blk u.int(entries[k], "createdAt") orelse 0;
        }
        break :blk std.math.minInt(i64);
    };
    var window: std.ArrayList(Value) = .empty;
    for (entries) |e| {
        if ((u.int(e, "createdAt") orelse 0) >= start) try window.append(a, e);
    }
    var replies: std.ArrayList(Message) = .empty;
    for (try render(a, window.items, .{})) |m| {
        if (m.isRole("assistant")) try replies.append(a, m);
    }
    if (replies.items.len == 0) {
        var k = entries.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, u.str(entries[k], "role") orelse "", "assistant")) {
                try replies.appendSlice(a, try render(a, entries[k .. k + 1], .{}));
                break;
            }
        }
    }
    var truncated = false;
    for (replies.items) |*r| {
        if (try trimReply(a, r)) truncated = true;
    }
    return .{ .replies = replies.items, .truncated = truncated };
}

/// Keep the end of a long reply: the last 16 KiB of text and 40 tool lines.
fn trimReply(a: Allocator, reply: *Message) !bool {
    var trimmed = false;
    if (reply.text.items.len > reply_text_cap) {
        var cut = reply.text.items.len - reply_text_cap;
        while (cut < reply.text.items.len and (reply.text.items[cut] & 0xC0) == 0x80) cut += 1;
        var next: std.ArrayList(u8) = .empty;
        try next.appendSlice(a, "…");
        try next.appendSlice(a, reply.text.items[cut..]);
        reply.text = next;
        trimmed = true;
    }
    if (reply.tools.items.len > reply_tools_cap) {
        const drop = reply.tools.items.len - reply_tools_cap;
        var next: std.ArrayList([]const u8) = .empty;
        try next.append(a, try std.fmt.allocPrint(a, "… {d} earlier tool calls", .{drop}));
        try next.appendSlice(a, reply.tools.items[drop..]);
        reply.tools = next;
        trimmed = true;
    }
    return trimmed;
}

// ---- tests ----------------------------------------------------------------------

const testing = std.testing;

fn parse(a: Allocator, text: []const u8) !Value {
    return json.parseFromSliceLeaky(Value, a, text, .{});
}

test "mcp transcript: visual parts render as a short summary, never their source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try parse(a,
        \\[{"id":"a","role":"assistant","createdAt":1700000000000,"deviceId":"dev-a","status":"complete",
        \\  "parts":[{"kind":"visual","id":"v","title":"Overview","script":"private native source"}]}]
    );
    const rendered = try render(a, entries.array.items, .{});
    try testing.expectEqualStrings("", rendered[0].text.items);
    try testing.expectEqualStrings("visual: Overview", rendered[0].tools.items[0]);
    const out = try u.stringify(a, try toValues(a, rendered));
    try testing.expect(std.mem.indexOf(u8, out, "private native source") == null);
}

test "mcp transcript: folds text, tools and pending input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try parse(a,
        \\[{"id":"u1","role":"user","createdAt":1700000000000,"deviceId":"dev-a","status":"complete",
        \\  "parts":[{"kind":"text","id":"t","text":"hello"}]},
        \\ {"id":"a1","role":"assistant","createdAt":1700000000000,"deviceId":"dev-a","status":"complete",
        \\  "parts":[{"kind":"reasoning","id":"r","text":"thinking"},
        \\           {"kind":"tool","id":"x","call":{"kind":"exec","command":"cargo test"},"isError":false,"resolved":true,"output":"ok\nmore"},
        \\           {"kind":"text","id":"t2","text":"done"},
        \\           {"kind":"input","id":"i","requestId":"req-1","questions":[],"resolved":false}]}]
    );
    const rendered = try render(a, entries.array.items, .{});
    try testing.expectEqual(@as(usize, 2), rendered.len);
    try testing.expectEqualStrings("hello", rendered[0].text.items);
    try testing.expectEqualStrings("done", rendered[1].text.items);
    try testing.expectEqualStrings("exec: cargo test → ok", rendered[1].tools.items[0]);
    try testing.expect(rendered[1].reasoning == null);
    try testing.expectEqualStrings("req-1", u.str(rendered[1].pending_input.?, "requestId").?);
    const v = try rendered[1].toValue(a);
    try testing.expectEqualStrings("2023-11-14T22:13:20Z", u.str(v, "createdAtIso").?);
    const with_reasoning = try render(a, entries.array.items, .{ .include_reasoning = true, .include_tools = false });
    try testing.expectEqualStrings("thinking", with_reasoning[1].reasoning.?.items);
    try testing.expectEqual(@as(usize, 0), with_reasoning[1].tools.items.len);
}

test "mcp transcript: continuations fold into their parent and carry its status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try parse(a,
        \\[{"id":"a1","role":"assistant","createdAt":1,"deviceId":"d","status":"complete","parts":[{"kind":"text","id":"t","text":"first half"}]},
        \\ {"id":"a1-cont","role":"assistant","createdAt":2,"deviceId":"d","status":"streaming","continuationOf":"a1","parts":[{"kind":"text","id":"t","text":"second half"}]}]
    );
    const rendered = try render(a, entries.array.items, .{});
    try testing.expectEqual(@as(usize, 1), rendered.len);
    try testing.expectEqualStrings("first half\n\nsecond half", rendered[0].text.items);
    try testing.expectEqualStrings("streaming", rendered[0].status.?);
}

test "mcp turn replies: the current turn, not a folded history; trimmed to the end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try parse(a,
        \\[{"id":"u1","role":"user","createdAt":1000,"deviceId":"d","parts":[{"kind":"text","id":"p","text":"first task"}]},
        \\ {"id":"a1","role":"assistant","createdAt":1100,"deviceId":"d","parts":[{"kind":"text","id":"p","text":"old work"}]},
        \\ {"id":"u2","role":"user","createdAt":9000,"deviceId":"d","parts":[{"kind":"text","id":"p","text":"second task"}]},
        \\ {"id":"a2","role":"assistant","createdAt":9100,"deviceId":"d","continuationOf":"a1","parts":[{"kind":"text","id":"p","text":"new work"}]},
        \\ {"id":"a3","role":"assistant","createdAt":9200,"deviceId":"d","continuationOf":"a2","parts":[{"kind":"text","id":"p","text":"new work, continued"}]}]
    );
    const r = try turnReplies(a, entries.array.items, 0);
    try testing.expectEqual(@as(usize, 1), r.replies.len);
    try testing.expectEqualStrings("new work\n\nnew work, continued", r.replies[0].text.items);
    try testing.expect(!r.truncated);

    const sends = try parse(a,
        \\[{"id":"a1","role":"assistant","createdAt":1000,"deviceId":"d","parts":[{"kind":"text","id":"p","text":"before the send"}]},
        \\ {"id":"a2","role":"assistant","createdAt":20500,"deviceId":"d","continuationOf":"a1","parts":[{"kind":"text","id":"p","text":"after the send"}]}]
    );
    try testing.expectEqualStrings("after the send", (try turnReplies(a, sends.array.items, 20_000)).replies[0].text.items);
    try testing.expectEqualStrings("after the send", (try turnReplies(a, sends.array.items, 30_000)).replies[0].text.items);

    const long = try a.alloc(u8, reply_text_cap * 2 + 7);
    @memset(long, 'x');
    @memcpy(long[long.len - 7 ..], "THE END");
    const long_entries = try parse(a, try std.fmt.allocPrint(a,
        \\[{{"id":"u","role":"user","createdAt":1,"deviceId":"d","parts":[{{"kind":"text","id":"p","text":"go"}}]}},
        \\ {{"id":"a","role":"assistant","createdAt":2,"deviceId":"d","parts":[{{"kind":"text","id":"p","text":"{s}"}}]}}]
    , .{long}));
    const lr = try turnReplies(a, long_entries.array.items, 0);
    try testing.expect(lr.truncated);
    try testing.expect(std.mem.endsWith(u8, lr.replies[0].text.items, "THE END"));
    try testing.expect(lr.replies[0].text.items.len <= reply_text_cap + 4);

    var many = lr.replies[0];
    many.tools = .empty;
    for (0..reply_tools_cap + 10) |k| try many.tools.append(a, try std.fmt.allocPrint(a, "tool {d}", .{k}));
    try testing.expect(try trimReply(a, &many));
    try testing.expectEqual(reply_tools_cap + 1, many.tools.items.len);
    try testing.expectEqualStrings("… 10 earlier tool calls", many.tools.items[0]);
}
