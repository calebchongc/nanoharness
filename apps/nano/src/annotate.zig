//! Image annotation's model (docs/annotate.md): boxes with numbered pins and
//! a note each, free text marks, four colours, selection, and an undo/redo
//! stack. Marks are plain values (their note inline), so the stacks hold
//! copies and nothing is allocated while drawing.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tool = enum { text, rect };

/// Red is the default, then blue, green and yellow.
pub const Swatch = enum {
    red,
    blue,
    green,
    yellow,

    pub const all = [_]Swatch{ .red, .blue, .green, .yellow };

    pub fn label(s: Swatch) []const u8 {
        return switch (s) {
            .red => "Red",
            .blue => "Blue",
            .green => "Green",
            .yellow => "Yellow",
        };
    }

    /// The theme's terminal palette slot that is this hue.
    pub fn ansi(s: Swatch) usize {
        return switch (s) {
            .red => 1,
            .blue => 4,
            .green => 2,
            .yellow => 3,
        };
    }
};

pub const note_cap = 240;
/// The most marks one image takes, and the undo depth kept.
pub const max_marks = 64;
pub const max_history = 200;

pub const Kind = enum { box, text };

pub const Mark = struct {
    kind: Kind,
    /// In image pixels; a text mark's box is where its text starts.
    x: f32,
    y: f32,
    w: f32 = 0,
    h: f32 = 0,
    color: Swatch = .red,
    note_buf: [note_cap]u8 = undefined,
    note_len: u16 = 0,

    pub fn note(m: *const Mark) []const u8 {
        return m.note_buf[0..m.note_len];
    }

    pub fn setNote(m: *Mark, s: []const u8) void {
        var n = @min(s.len, note_cap);
        // Never cut a character in half.
        while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(m.note_buf[0..n], s[0..n]);
        m.note_len = @intCast(n);
    }
};

const Op = struct {
    kind: enum { add, remove, change },
    at: usize,
    before: Mark,
    after: Mark,
};

pub const Annotations = struct {
    marks: std.ArrayList(Mark) = .empty,
    undo_stack: std.ArrayList(Op) = .empty,
    redo_stack: std.ArrayList(Op) = .empty,
    selected: ?usize = null,
    tool: Tool = .rect,
    color: Swatch = .red,

    pub fn deinit(s: *Annotations, gpa: Allocator) void {
        s.marks.deinit(gpa);
        s.undo_stack.deinit(gpa);
        s.redo_stack.deinit(gpa);
        s.* = .{};
    }

    fn record(s: *Annotations, gpa: Allocator, op: Op) !void {
        if (s.undo_stack.items.len >= max_history) _ = s.undo_stack.orderedRemove(0);
        try s.undo_stack.append(gpa, op);
        s.redo_stack.clearRetainingCapacity();
    }

    /// A box dragged from (x0, y0) to (x1, y1), in any direction; selected.
    pub fn addBox(s: *Annotations, gpa: Allocator, x0: f32, y0: f32, x1: f32, y1: f32) !usize {
        if (s.marks.items.len >= max_marks) return error.TooManyMarks;
        const m: Mark = .{ .kind = .box, .x = @min(x0, x1), .y = @min(y0, y1), .w = @abs(x1 - x0), .h = @abs(y1 - y0), .color = s.color };
        try s.marks.append(gpa, m);
        const at = s.marks.items.len - 1;
        s.record(gpa, .{ .kind = .add, .at = at, .before = m, .after = m }) catch {
            _ = s.marks.pop();
            return error.OutOfMemory;
        };
        s.selected = at;
        return at;
    }

    /// Text placed at (x, y). An empty text mark is dropped.
    pub fn addText(s: *Annotations, gpa: Allocator, x: f32, y: f32, text: []const u8) !?usize {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return null;
        if (s.marks.items.len >= max_marks) return error.TooManyMarks;
        var m: Mark = .{ .kind = .text, .x = x, .y = y, .color = s.color };
        m.setNote(t);
        try s.marks.append(gpa, m);
        const at = s.marks.items.len - 1;
        s.record(gpa, .{ .kind = .add, .at = at, .before = m, .after = m }) catch {
            _ = s.marks.pop();
            return error.OutOfMemory;
        };
        return at;
    }

    fn change(s: *Annotations, gpa: Allocator, at: usize, after: Mark) !void {
        const before = s.marks.items[at];
        try s.record(gpa, .{ .kind = .change, .at = at, .before = before, .after = after });
        s.marks.items[at] = after;
    }

    /// A box's note, committed (Enter).
    pub fn setNote(s: *Annotations, gpa: Allocator, at: usize, text: []const u8) !void {
        if (at >= s.marks.items.len) return;
        var m = s.marks.items[at];
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.eql(u8, m.note(), t)) return;
        m.setNote(t);
        try s.change(gpa, at, m);
    }

    /// Picking a colour recolours the selection, and is the next marks'.
    pub fn pickColor(s: *Annotations, gpa: Allocator, color: Swatch) !void {
        s.color = color;
        const at = s.selected orelse return;
        if (at >= s.marks.items.len or s.marks.items[at].color == color) return;
        var m = s.marks.items[at];
        m.color = color;
        try s.change(gpa, at, m);
    }

    pub fn remove(s: *Annotations, gpa: Allocator, at: usize) !void {
        if (at >= s.marks.items.len) return;
        const m = s.marks.items[at];
        try s.record(gpa, .{ .kind = .remove, .at = at, .before = m, .after = m });
        _ = s.marks.orderedRemove(at);
        s.selected = null;
    }

    pub fn canUndo(s: *const Annotations) bool {
        return s.undo_stack.items.len > 0;
    }

    pub fn canRedo(s: *const Annotations) bool {
        return s.redo_stack.items.len > 0;
    }

    pub fn undo(s: *Annotations, gpa: Allocator) !void {
        const op = s.undo_stack.pop() orelse return;
        try s.redo_stack.append(gpa, op);
        s.unapply(op, false);
    }

    pub fn redo(s: *Annotations, gpa: Allocator) !void {
        const op = s.redo_stack.pop() orelse return;
        try s.undo_stack.append(gpa, op);
        s.unapply(op, true);
    }

    /// `forward`: do `op` again; else take it back. Capacity for an insert
    /// is always there: the mark was in the list before.
    fn unapply(s: *Annotations, op: Op, forward: bool) void {
        s.selected = null;
        const insert = (op.kind == .add) == forward;
        switch (op.kind) {
            .add, .remove => if (insert) {
                s.marks.insertAssumeCapacity(@min(op.at, s.marks.items.len), op.before);
            } else if (op.at < s.marks.items.len) {
                _ = s.marks.orderedRemove(op.at);
            },
            .change => if (op.at < s.marks.items.len) {
                s.marks.items[op.at] = if (forward) op.after else op.before;
            },
        }
    }

    /// A box's pin number: boxes count in drawing order.
    pub fn pin(s: *const Annotations, at: usize) ?usize {
        if (at >= s.marks.items.len or s.marks.items[at].kind != .box) return null;
        var n: usize = 0;
        for (s.marks.items[0 .. at + 1]) |m| {
            if (m.kind == .box) n += 1;
        }
        return n;
    }

    /// The topmost box whose edge or pin is at (x, y), `slop` image pixels
    /// either way; a press inside a box selects it too.
    pub fn hit(s: *const Annotations, x: f32, y: f32, slop: f32) ?usize {
        var i = s.marks.items.len;
        while (i > 0) {
            i -= 1;
            const m = s.marks.items[i];
            if (m.kind != .box) continue;
            const inside = x >= m.x - slop and x <= m.x + m.w + slop and y >= m.y - slop and y <= m.y + m.h + slop;
            const on_pin = @abs(x - m.x) <= slop * 2 and @abs(y - m.y) <= slop * 2;
            if (inside or on_pin) return i;
        }
        return null;
    }

    pub fn isEmpty(s: *const Annotations) bool {
        return s.marks.items.len == 0;
    }

    /// The notes block the prompt carries (`apps/parity/vectors/annotations.json`).
    pub fn promptBlock(s: *const Annotations, arena: Allocator, file_name: []const u8) !?[]const u8 {
        const mp = @import("mobile_parity.zig");
        const list = try arena.alloc(mp.AnnotationMark, s.marks.items.len);
        for (s.marks.items, list) |*m, *out| out.* = switch (m.kind) {
            .box => .{ .box = .{ .x = m.x, .y = m.y, .w = m.w, .h = m.h, .text = m.note() } },
            .text => .{ .text = .{ .x = m.x, .y = m.y, .text = m.note() } },
        };
        return mp.annotationPromptBlock(arena, file_name, list);
    }
};

/// "NAME-annotated.png" for `name`, its extension dropped.
pub fn annotatedName(buf: []u8, name: []const u8) []const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[0..dot] else name;
    const base = if (std.mem.endsWith(u8, stem, "-annotated")) stem[0 .. stem.len - "-annotated".len] else stem;
    return std.fmt.bufPrint(buf, "{s}-annotated.png", .{if (base.len > 0) base else "image"}) catch "image-annotated.png";
}

const testing = std.testing;

test "boxes normalise, select and number in drawing order; text marks have no pin" {
    var s: Annotations = .{};
    defer s.deinit(testing.allocator);
    const a = try s.addBox(testing.allocator, 50, 60, 10, 20);
    try testing.expectEqual(@as(f32, 10), s.marks.items[a].x);
    try testing.expectEqual(@as(f32, 40), s.marks.items[a].w);
    try testing.expectEqual(@as(?usize, a), s.selected);
    const t = (try s.addText(testing.allocator, 5, 5, "hello")).?;
    const b = try s.addBox(testing.allocator, 100, 100, 120, 130);
    try testing.expectEqual(@as(?usize, 1), s.pin(a));
    try testing.expectEqual(@as(?usize, null), s.pin(t));
    try testing.expectEqual(@as(?usize, 2), s.pin(b));
    try testing.expectEqual(@as(?usize, null), try s.addText(testing.allocator, 1, 1, "   "));
}

test "undo and redo walk every kind of change back and forth" {
    const gpa = testing.allocator;
    var s: Annotations = .{};
    defer s.deinit(gpa);
    const a = try s.addBox(gpa, 0, 0, 10, 10);
    try s.setNote(gpa, a, "  make this primary ");
    try testing.expectEqualStrings("make this primary", s.marks.items[a].note());
    try s.pickColor(gpa, .blue);
    try testing.expectEqual(Swatch.blue, s.marks.items[a].color);
    try s.remove(gpa, a);
    try testing.expectEqual(@as(usize, 0), s.marks.items.len);
    try s.undo(gpa);
    try testing.expectEqual(Swatch.blue, s.marks.items[0].color);
    try s.undo(gpa);
    try testing.expectEqual(Swatch.red, s.marks.items[0].color);
    try s.undo(gpa);
    try testing.expectEqualStrings("", s.marks.items[0].note());
    try s.undo(gpa);
    try testing.expect(s.isEmpty());
    try testing.expect(!s.canUndo());
    try s.redo(gpa);
    try s.redo(gpa);
    try testing.expectEqualStrings("make this primary", s.marks.items[0].note());
    // A new change drops what could be redone.
    _ = try s.addBox(gpa, 1, 1, 2, 2);
    try testing.expect(!s.canRedo());
}

test "hits find the topmost box by its body or pin" {
    var s: Annotations = .{};
    defer s.deinit(testing.allocator);
    _ = try s.addBox(testing.allocator, 0, 0, 100, 100);
    _ = try s.addBox(testing.allocator, 50, 50, 150, 150);
    try testing.expectEqual(@as(?usize, 1), s.hit(60, 60, 2));
    try testing.expectEqual(@as(?usize, 0), s.hit(10, 10, 2));
    try testing.expectEqual(@as(?usize, null), s.hit(400, 400, 2));
}

test "the prompt block and the flattened name match the parity format" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    var s: Annotations = .{};
    defer s.deinit(testing.allocator);
    try testing.expect((try s.promptBlock(ar.allocator(), "x-annotated.png")) == null);
    _ = try s.addText(testing.allocator, 500, 30, "say \"hi\"");
    const b = try s.addBox(testing.allocator, 40, 400, 240, 460);
    try s.setNote(testing.allocator, b, "move up");
    try testing.expectEqualStrings(
        "Annotations on a-annotated.png (boxes are x,y,w,h in image pixels):\n1. [box 40,400,200,60] move up\nText on the image:\n- [text 500,30] \"say 'hi'\"",
        (try s.promptBlock(ar.allocator(), "a-annotated.png")).?,
    );
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("billing-annotated.png", annotatedName(&buf, "billing.jpg"));
    try testing.expectEqualStrings("billing-annotated.png", annotatedName(&buf, "billing-annotated.png"));
    try testing.expectEqualStrings("image-annotated.png", annotatedName(&buf, ".png"));
}

test "a note is cut at the cap without splitting a character" {
    var m: Mark = .{ .kind = .box, .x = 0, .y = 0 };
    var long: [note_cap + 4]u8 = undefined;
    @memset(&long, 'a');
    long[note_cap - 1] = 0xC3;
    long[note_cap] = 0xA9;
    m.setNote(&long);
    try testing.expectEqual(@as(usize, note_cap - 1), m.note().len);
}
