//! Annotate's editor over the image preview (docs/annotate.md): Text and
//! Rectangle (the default), four colours (red first), Undo and Redo, then
//! Cancel and Done, centred beneath the image; narrow windows stack the
//! tools over the actions. A drawn box gets a numbered pin and an "Add a
//! note…" popover under it (above it near the bottom edge).
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const gk = @import("view_gaps_kit.zig");
const App = @import("app.zig").App;
const annotate = @import("annotate.zig");
const app = @import("app_annotate.zig");
const rules = @import("image_preview_rules.zig");
const ipv = @import("view_image_preview.zig");

/// Image pixels to points: x0 + px · zoom; `chrome` scales strokes, pins
/// and text (1 on screen; image pixels per point when flattening).
pub const Map = struct { x0: f32, y0: f32, zoom: f32, chrome: f32 };

pub fn swatch(k: theme.Colors, s: annotate.Swatch) ui.Color {
    return k.ansi[s.ansi()];
}

/// Readable on the swatch: of the theme's text and background, the one
/// further from the swatch's lightness.
fn onSwatch(k: theme.Colors, s: annotate.Swatch) ui.Color {
    const bg = @import("view_gaps_kit.zig").solid(k).shell;
    const sw = luminance(swatch(k, s));
    return if (@abs(luminance(k.text) - sw) >= @abs(luminance(bg) - sw)) k.text else bg;
}

fn luminance(c: ui.Color) f32 {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// The marks, and a box being dragged; relative to the enclosing box.
pub fn marks(c: *ui.Context, k: theme.Colors, ann: *const annotate.Annotations, m: Map, drawing: ?app.Drag) void {
    const ch = m.chrome;
    for (ann.marks.items, 0..) |*mk, i| {
        const col = swatch(k, mk.color);
        const x = m.x0 + mk.x * m.zoom;
        const y = m.y0 + mk.y * m.zoom;
        switch (mk.kind) {
            .box => {
                const sel = ann.selected == i;
                var b = ui.div(c).absolute().offset(x, y).size(@max(1, mk.w * m.zoom), @max(1, mk.h * m.zoom)).border(col).borderW((if (sel) @as(f32, 3) else 2) * ch).rounded(3 * ch);
                if (sel) b = b.bg(col.alpha(0.08));
                b.end();
                const d = 20 * ch;
                const pin = ui.div(c).absolute().offset(x - d / 2, y - d / 2).size(d, d).roundedFull().circular().bg(col).center();
                defer pin.end();
                const n = ann.pin(i) orelse 0;
                ui.text(c, c.print("{d}", .{n}), .{ .size = 11 * ch, .line_height = 13 * ch, .weight = .semibold, .color = onSwatch(k, mk.color) });
            },
            .text => {
                const t = ui.div(c).absolute().offset(x, y).px(6 * ch).py(3 * ch).rounded(4 * ch).bg(col);
                defer t.end();
                ui.text(c, mk.note(), .{ .size = 13 * ch, .line_height = 18 * ch, .weight = .medium, .color = onSwatch(k, mk.color) });
            },
        }
    }
    const dr = drawing orelse return;
    const x = m.x0 + @min(dr.x0, dr.x1) * m.zoom;
    const y = m.y0 + @min(dr.y0, dr.y1) * m.zoom;
    ui.div(c).absolute().offset(x, y).size(@abs(dr.x1 - dr.x0) * m.zoom, @abs(dr.y1 - dr.y0) * m.zoom).border(swatch(k, ann.color)).borderW(2 * ch).rounded(3 * ch).end();
}

/// The toolbar's height: one row, or two stacked on a narrow window.
pub fn toolbarHeight(w: f32) f32 {
    return if (narrow(w)) 28 * 2 + 8 else 28;
}

pub fn narrow(w: f32) bool {
    return w < 720;
}

fn geometry(vp: ipv.Viewport, sh: ipv.Shown, a: *App) struct { zoom: f32, pan: rules.Point, view: rules.Size } {
    const view: rules.Size = .{ .w = vp.w, .h = vp.h };
    const zoom = a.ui_gaps.preview.zoom.effective(sh.size, view);
    return .{ .zoom = zoom, .pan = rules.clampPan(a.ui_gaps.preview.zoom.pan, sh.size, zoom, view), .view = view };
}

/// The image pixel under the pointer, kept on the picture.
fn pixelAt(c: *ui.Context, vp: ipv.Viewport, sh: ipv.Shown, a: *App) rules.Point {
    const g = geometry(vp, sh, a);
    const p = rules.toImage(.{ .x = c.input.mouse.x - vp.x, .y = c.input.mouse.y - vp.y }, sh.size, g.zoom, g.pan, g.view);
    return .{ .x = std.math.clamp(p.x, 0, sh.size.w), .y = std.math.clamp(p.y, 0, sh.size.h) };
}

/// Presses on the picture: select a box or its pin, else draw a box (the
/// Rectangle tool) or place text (the Text tool).
pub fn pointer(c: *ui.Context, a: *App, vp: ipv.Viewport, sh: ipv.Shown) void {
    const e = app.editor(a) orelse return;
    const m = c.input.mouse;
    const inside = m.x >= vp.x and m.x < vp.x + vp.w and m.y >= vp.y and m.y < vp.y + vp.h;
    const g = geometry(vp, sh, a);
    if (c.input.pressed and inside and !overField(c, a, vp, sh)) {
        const p = pixelAt(c, vp, sh, a);
        if (e.marks.hit(p.x, p.y, 6 / g.zoom)) |at| {
            app.openNote(a, at);
        } else switch (e.marks.tool) {
            .rect => {
                _ = app.commitOpen(a);
                e.marks.selected = null;
                e.drawing = .{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y };
            },
            .text => {
                _ = app.commitOpen(a);
                e.marks.selected = null;
                e.text_at = .{ .x = p.x, .y = p.y };
                e.text.clear();
                e.focus_field = true;
            },
        }
        c.changed = true;
    }
    if (e.drawing) |*d| {
        const p = pixelAt(c, vp, sh, a);
        d.x1 = p.x;
        d.y1 = p.y;
        c.cursor = .crosshair;
        if (c.input.released or !c.input.down) {
            const drawn = d.*;
            e.drawing = null;
            // A click is not a box: 4 points at least, either way.
            if (@abs(drawn.x1 - drawn.x0) * g.zoom >= 4 and @abs(drawn.y1 - drawn.y0) * g.zoom >= 4) {
                if (e.marks.addBox(a.gpa, drawn.x0, drawn.y0, drawn.x1, drawn.y1)) |at| app.openNote(a, at) else |_| {
                    e.err = "No more marks fit on this image.";
                }
            }
            c.changed = true;
        }
    }
}

/// The open note or text field's rect in window points, if any.
fn fieldRect(a: *App, vp: ipv.Viewport, sh: ipv.Shown) ?ui.Rect {
    const e = app.editor(a) orelse return null;
    const g = geometry(vp, sh, a);
    if (e.note_at) |at| {
        if (at >= e.marks.marks.items.len) return null;
        const mk = e.marks.marks.items[at];
        const tl = rules.toView(.{ .x = mk.x, .y = mk.y }, sh.size, g.zoom, g.pan, g.view);
        const br = rules.toView(.{ .x = mk.x + mk.w, .y = mk.y + mk.h }, sh.size, g.zoom, g.pan, g.view);
        const w: f32 = 280;
        const h: f32 = 40;
        const x = std.math.clamp(vp.x + tl.x, vp.x, vp.x + vp.w - w);
        const below = vp.y + br.y + 10;
        const y = if (below + h > vp.y + vp.h) @max(vp.y, vp.y + tl.y - 10 - h - 10) else below;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
    if (e.text_at) |p| {
        const at = rules.toView(.{ .x = p.x, .y = p.y }, sh.size, g.zoom, g.pan, g.view);
        return .{ .x = std.math.clamp(vp.x + at.x, vp.x, vp.x + vp.w - 220), .y = std.math.clamp(vp.y + at.y, vp.y, vp.y + vp.h - 34), .w = 220, .h = 34 };
    }
    return null;
}

fn overField(c: *ui.Context, a: *App, vp: ipv.Viewport, sh: ipv.Shown) bool {
    const r = fieldRect(a, vp, sh) orelse return false;
    return r.contains(c.input.mouse);
}

/// The note popover or text field, and the toolbar.
pub fn editor(c: *ui.Context, a: *App, k: theme.Colors, vp: ipv.Viewport, sh: ipv.Shown) void {
    const e = app.editor(a) orelse return;
    if (fieldRect(a, vp, sh)) |r| {
        const note = e.note_at != null;
        ui.key(c, if (note) "annotate-note" else "annotate-text");
        const pop = ui.div(c).absolute().offset(r.x, r.y).size(r.w, r.h).row().px(10).gap(6).itemsCenter().rounded(10).bg(gk.solid(k).composer).border(k.border_strong).borderW(1);
        defer pop.end();
        _ = pop.interaction();
        const field_id = c.peekId(null);
        if (e.focus_field) {
            c.focus = field_id;
            e.focus_field = false;
            c.changed = true;
        }
        const res = ui.textField(c, if (note) &e.note else &e.text, .{
            .placeholder = if (note) "Add a note…" else "Type text…",
            .width = .fill,
            .bare = true,
            .size = 13,
            .caret_color = k.accent,
            .placeholder_color = k.muted,
        });
        if (res.submitted) _ = app.commitOpen(a);
        if (note) {
            ui.key(c, "annotate-note-delete");
            if (gk.button(c, k, "", .{ .look = .quiet, .square = true, .h = 24, .icon = .close })) if (e.note_at) |at| {
                e.note_at = null;
                e.note.clear();
                e.marks.remove(a.gpa, at) catch {};
                a.redraw();
            };
        }
    }
    toolbar(c, a, k, vp, sh);
}

fn toolbar(c: *ui.Context, a: *App, k: theme.Colors, vp: ipv.Viewport, sh: ipv.Shown) void {
    const e = app.editor(a) orelse return;
    const stack = narrow(c.size.w);
    const bar = ui.div(c).absolute().offset(0, vp.y + vp.h + 12).w(c.size.w).column().itemsCenter().gap(8);
    defer bar.end();
    {
        const tools = ui.div(c).row().gap(6).itemsCenter().p(4).rounded(12).bg(gk.solid(k).composer).border(k.border).borderW(1);
        defer tools.end();
        ui.key(c, "annotate-tool-text");
        if (gk.button(c, k, "Text", .{ .on = e.marks.tool == .text, .look = .quiet })) e.marks.tool = .text;
        ui.key(c, "annotate-tool-rect");
        if (gk.button(c, k, "Rectangle", .{ .on = e.marks.tool == .rect, .look = .quiet })) e.marks.tool = .rect;
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 18 }, .background = k.border }, .none, null);
        for (annotate.Swatch.all) |sw| {
            ui.key(c, c.print("annotate-color-{s}", .{sw.label()}));
            if (swatchButton(c, k, sw, e.marks.color == sw)) e.marks.pickColor(a.gpa, sw) catch {};
        }
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 18 }, .background = k.border }, .none, null);
        ui.key(c, "annotate-undo");
        if (gk.button(c, k, "Undo", .{ .look = .quiet, .disabled = !e.marks.canUndo() })) e.marks.undo(a.gpa) catch {};
        ui.key(c, "annotate-redo");
        if (gk.button(c, k, "Redo", .{ .look = .quiet, .disabled = !e.marks.canRedo() })) e.marks.redo(a.gpa) catch {};
        if (!stack) actions(c, a, k, sh);
    }
    if (stack) {
        const r = ui.div(c).row().gap(8);
        defer r.end();
        actions(c, a, k, sh);
    }
    if (e.err.len > 0) ui.text(c, e.err, .{ .size = 12, .line_height = 18, .color = k.danger_muted });
}

fn actions(c: *ui.Context, a: *App, k: theme.Colors, sh: ipv.Shown) void {
    ui.key(c, "annotate-cancel");
    if (gk.button(c, k, "Cancel", .{})) return app.cancel(a);
    ui.key(c, "annotate-done");
    if (gk.button(c, k, "Done", .{ .look = .primary })) app.done(a, k, sh.size.w, sh.size.h);
}

fn swatchButton(c: *ui.Context, k: theme.Colors, sw: annotate.Swatch, on: bool) bool {
    const b = ui.div(c).row().size(26, 26).center().roundedFull().circular().borderW(if (on) 2 else 1).border(if (on) k.text else .transparent).control();
    const it = c.interact(b.index, .{ .focusable = true });
    if (it.focused) _ = b.border(k.accent).borderW(2);
    defer b.end();
    _ = c.leaf(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .radius = 8, .background = swatch(k, sw) }, .none, null);
    return it.clicked;
}

/// Annotate's keys: Escape commits an open note or leaves annotate;
/// Backspace or Delete removes the selection; ⌘Z undoes, ⇧⌘Z redoes.
pub fn keys(c: *ui.Context, a: *App) bool {
    const e = app.editor(a) orelse return false;
    const S = ui.Shortcut;
    const field_open = e.note_at != null or e.text_at != null;
    if (c.shortcut(.{ .key = S.escape })) {
        if (!app.commitOpen(a)) app.cancel(a);
        return true;
    }
    // Return commits the open note or text.
    if (field_open and c.shortcut(.{ .key = S.enter })) {
        _ = app.commitOpen(a);
        return true;
    }
    if (c.shortcut(.{ .key = 'z', .cmd = true, .shift = true }) or c.shortcut(.{ .key = 'z', .ctrl = true, .shift = true })) {
        _ = app.commitOpen(a);
        e.marks.redo(a.gpa) catch {};
        a.redraw();
        return true;
    }
    if (c.shortcut(.{ .key = 'z', .cmd = true }) or c.shortcut(.{ .key = 'z', .ctrl = true })) {
        _ = app.commitOpen(a);
        e.marks.undo(a.gpa) catch {};
        a.redraw();
        return true;
    }
    if (!field_open) if (e.marks.selected) |at| {
        if (c.shortcut(.{ .key = S.backspace }) or c.shortcut(.{ .key = S.forward_delete }) or c.input.key == .backspace or c.input.key == .delete) {
            c.input.key = null;
            e.marks.remove(a.gpa, at) catch {};
            a.redraw();
            return true;
        }
    };
    // The open field takes typing and Return; nothing else acts meanwhile.
    return true;
}

test "the toolbar stacks on a narrow window" {
    try std.testing.expectEqual(@as(f32, 28), toolbarHeight(1200));
    try std.testing.expectEqual(@as(f32, 64), toolbarHeight(600));
}
