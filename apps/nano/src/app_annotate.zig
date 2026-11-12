//! Annotate's flow (docs/annotate.md): the editor's state over the image
//! preview, flattening the marks into `NAME-annotated.png` on Done, and the
//! notes each annotated attachment adds to the prompt on send.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const annotate = @import("annotate.zig");
const attachments = @import("app_attachments.zig");
const preview = @import("app_image_preview.zig");
const Allocator = std.mem.Allocator;

/// A box being dragged, in image pixels.
pub const Drag = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

pub const Editor = struct {
    marks: annotate.Annotations = .{},
    drawing: ?Drag = null,
    /// The box whose "Add a note…" popover is open, and its field.
    note_at: ?usize = null,
    note: ui.TextBuffer = .{},
    /// Where a text mark being typed goes (image pixels), and its field.
    text_at: ?struct { x: f32, y: f32 } = null,
    text: ui.TextBuffer = .{},
    /// The field to focus when next drawn.
    focus_field: bool = false,
    /// Points per image pixel while editing: marks keep their screen size
    /// in the flattened file.
    zoom: f32 = 1,
    err: []const u8 = "",

    pub fn deinit(e: *Editor, gpa: Allocator) void {
        e.marks.deinit(gpa);
        @import("text_buffer.zig").deinit(&e.note);
        @import("text_buffer.zig").deinit(&e.text);
    }
};

/// An annotated attachment's notes block, by the composer item's id.
pub const Note = struct { id: [36]u8, block: []u8 };

pub const Notes = struct {
    items: std.ArrayList(Note) = .empty,

    pub fn deinit(n: *Notes, gpa: Allocator) void {
        for (n.items.items) |x| gpa.free(x.block);
        n.items.deinit(gpa);
    }
};

fn notes(a: *App) *Notes {
    return &a.ui_gaps.notes;
}

/// Whether the composer item `id` was annotated (its thumbnail's pen).
pub fn annotated(a: *const App, id: []const u8) bool {
    for (a.ui_gaps.notes.items.items) |x| if (std.mem.eql(u8, &x.id, id)) return true;
    return false;
}

/// The notes of the draft's annotated attachments, in their order, for the
/// prompt. Notes of attachments no longer there are dropped.
pub fn appendNotes(a: *App, w: *std.Io.Writer) !void {
    prune(a);
    for (a.attachments.items.items) |item| if (item.active(a)) {
        for (notes(a).items.items) |x| if (std.mem.eql(u8, &x.id, &item.id)) {
            try w.writeAll("\n\n");
            try w.writeAll(x.block);
        };
    };
}

fn prune(a: *App) void {
    const list = &notes(a).items;
    var i: usize = 0;
    while (i < list.items.len) {
        const keep = for (a.attachments.items.items) |item| {
            if (!item.removed and std.mem.eql(u8, &item.id, &list.items[i].id)) break true;
        } else false;
        if (keep) i += 1 else a.gpa.free(list.orderedRemove(i).block);
    }
}

pub fn editor(a: *App) ?*Editor {
    return if (a.ui_gaps.preview.editor) |*e| e else null;
}

/// Annotate, on the image shown.
pub fn start(a: *App) void {
    const s = &a.ui_gaps.preview;
    if (s.editor != null or preview.current(a) == null) return;
    s.editor = .{};
    // The image keeps its place; drawing needs it still.
    s.drag = null;
    a.redraw();
}

/// Cancel discards everything.
pub fn cancel(a: *App) void {
    const s = &a.ui_gaps.preview;
    if (s.editor) |*e| e.deinit(a.gpa);
    s.editor = null;
    a.redraw();
}

/// Commits an open note or text mark; true if there was one.
pub fn commitOpen(a: *App) bool {
    const e = editor(a) orelse return false;
    if (e.note_at) |at| {
        e.marks.setNote(a.gpa, at, e.note.text()) catch {};
        e.note_at = null;
        e.note.clear();
        a.redraw();
        return true;
    }
    if (e.text_at) |p| {
        _ = e.marks.addText(a.gpa, p.x, p.y, e.text.text()) catch {};
        e.text_at = null;
        e.text.clear();
        a.redraw();
        return true;
    }
    return false;
}

/// Opens the note popover for box `at`.
pub fn openNote(a: *App, at: usize) void {
    const e = editor(a) orelse return;
    _ = commitOpen(a);
    if (at >= e.marks.marks.items.len) return;
    e.marks.selected = at;
    e.note_at = at;
    e.note.set(e.marks.marks.items[at].note());
    e.focus_field = true;
    a.redraw();
}

/// Done: the marks flattened into a new PNG, staged in the composer
/// (replacing the original when it came from there), with its notes.
pub fn done(a: *App, k: theme.Colors, img_w: f32, img_h: f32) void {
    _ = commitOpen(a);
    const e = editor(a) orelse return;
    const entry = preview.current(a) orelse return;
    const bytes = switch (preview.bytesOf(a, entry)) {
        .ready => |b| b,
        else => return,
    };
    if (e.marks.isEmpty()) return cancel(a);
    var name_buf: [512]u8 = undefined;
    const name = annotate.annotatedName(&name_buf, entry.name);
    const png = flatten(a.gpa, bytes, img_w, img_h, &e.marks, 1 / @max(e.zoom, 0.0001), k) catch {
        e.err = "Couldn't flatten the annotations.";
        return a.redraw();
    };
    defer a.gpa.free(png);
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const block = (e.marks.promptBlock(arena.allocator(), name) catch null) orelse "";
    const block_copy = a.gpa.dupe(u8, block) catch return;
    // From the composer it replaces the original attachment.
    if (a.ui_gaps.preview.origin == .composer) if (entry.source == .staged) {
        for (a.attachments.items.items) |item| if (std.mem.eql(u8, &item.id, &entry.source.staged) and !item.removed) item.remove();
    };
    attachments.stage(a, name, png) catch {
        a.gpa.free(block_copy);
        e.err = "Couldn't attach the annotated image (24 MB maximum).";
        return a.redraw();
    };
    const items = a.attachments.items.items;
    if (block_copy.len > 0 and items.len > 0) {
        notes(a).items.append(a.gpa, .{ .id = items[items.len - 1].id, .block = block_copy }) catch a.gpa.free(block_copy);
    } else a.gpa.free(block_copy);
    preview.close(a);
}

const Flat = struct {
    bytes: []const u8,
    w: f32,
    h: f32,
    marks: *const annotate.Annotations,
    chrome: f32,
    k: theme.Colors,

    fn view(f: *Flat, c: *ui.Context) void {
        const root = ui.div(c).sizeFull();
        defer root.end();
        _ = ui.image(c, .{ .key = "annotate-flatten", .source = .{ .encoded = f.bytes }, .box = .{ .w = f.w, .h = f.h }, .radius = 0 });
        @import("view_annotate.zig").marks(c, f.k, f.marks, .{ .x0 = 0, .y0 = 0, .zoom = 1, .chrome = f.chrome }, null);
    }
};

/// The image with its marks drawn at `chrome` image pixels per screen
/// point, as a PNG: drawn offscreen by nanoui's own renderer, on this
/// thread (the doc's stated limit).
pub fn flatten(gpa: Allocator, bytes: []const u8, img_w: f32, img_h: f32, marks: *const annotate.Annotations, chrome: f32, k: theme.Colors) ![]u8 {
    var f: Flat = .{ .bytes = bytes, .w = img_w, .h = img_h, .marks = marks, .chrome = chrome, .k = k };
    var th = theme.ui(k.dark);
    th.background = .transparent;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f, Flat.view), .{ .width = img_w, .height = img_h, .scale = 1, .dark = k.dark, .theme = th });
    defer t.deinit();
    t.settle(0.5);
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    return ui.png.encode(gpa, px);
}

const testing = std.testing;

test "flattening keeps the image's size and paints the marks over it" {
    theme.registerFonts();
    const gpa = testing.allocator;
    // A 40 by 30 white picture, made here.
    const white = try gpa.alloc(u8, 40 * 30 * 4);
    defer gpa.free(white);
    @memset(white, 255);
    const src = try ui.png.encode(gpa, .{ .bytes = white, .width = 40, .height = 30 });
    defer gpa.free(src);
    var s: annotate.Annotations = .{};
    defer s.deinit(gpa);
    _ = try s.addBox(gpa, 5, 5, 35, 25);
    const k = theme.colors(false);
    const out = try flatten(gpa, src, 40, 30, &s, 1, k);
    defer gpa.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "\x89PNG"));
    // IHDR: width then height, big-endian.
    try testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, out[16..20], .big));
    try testing.expectEqual(@as(u32, 30), std.mem.readInt(u32, out[20..24], .big));
}
