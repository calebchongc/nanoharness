//! The image preview over the window (docs/image-preview.md): the picture
//! fitted, zoomed with a pinch or Ctrl + wheel about the pointer, panned by
//! dragging or scrolling, the chat's other images before and after it,
//! Copy, Reveal in Finder for a file on this computer, and Annotate
//! (view_annotate.zig). Escape or a plain click on the backdrop closes it.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const gk = @import("view_gaps_kit.zig");
const App = @import("app.zig").App;
const rules = @import("image_preview_rules.zig");
const preview = @import("app_image_preview.zig");
const annotate_app = @import("app_annotate.zig");
const annotate_view = @import("view_annotate.zig");

const header_h: f32 = 56;
const side: f32 = 24;

/// Where the picture may go, in window points.
pub const Viewport = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn viewport(c: *ui.Context, annotating: bool) Viewport {
    // The same room below either way: the image keeps its place when
    // annotate starts (unless a narrow window stacks the toolbar).
    const foot: f32 = if (annotating) @max(84, annotate_view.toolbarHeight(c.size.w) + 24) else 84;
    return .{ .x = side, .y = header_h, .w = @max(0, c.size.w - 2 * side), .h = @max(0, c.size.h - header_h - foot) };
}

/// The picture's key: new content gets a new one.
fn imageKey(c: *ui.Context, e: *const preview.Entry, bytes: []const u8) []const u8 {
    return c.print("preview:{s}:{d}:{x}", .{ e.name, bytes.len, std.hash.Wyhash.hash(0, bytes[0..@min(bytes.len, 4096)]) });
}

/// What the picture is, once its header is read.
pub const Shown = struct { key: []const u8, bytes: []const u8, size: rules.Size };

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.ui_gaps.preview;
    if (!s.open) return;
    preview.settleFrame(a);
    // The composer underneath doesn't keep the keys: Return mustn't send.
    if (a.view.composer_id != 0 and c.focus == a.view.composer_id) c.focus = 0;
    a.view.focus_composer = false;
    const e = preview.current(a) orelse return preview.close(a);
    const editing = s.editor != null;
    const vp = viewport(c, editing);
    ui.key(c, "image-preview");
    const root = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(8).bg(gk.solid(k).shell).wheel();
    defer root.end();
    c.wants_wheel = true;
    const root_it = root.interaction();

    var shown: ?Shown = null;
    var refusal: ?[]const u8 = null;
    switch (preview.bytesOf(a, e)) {
        .loading => {},
        .failed => |why| refusal = why,
        .ready => |bytes| {
            const key = imageKey(c, e, bytes);
            if (ui.imageSize(c, key, bytes)) |size| {
                const sz: rules.Size = .{ .w = size.w, .h = size.h };
                refusal = rules.decodeRefusal(sz.w, sz.h);
                if (refusal == null) shown = .{ .key = key, .bytes = bytes, .size = sz };
            } else refusal = "This image couldn't be decoded.";
        },
    }

    // The picture, in a clipped box the size of the viewport.
    {
        ui.key(c, "image-preview-viewport");
        const box = ui.div(c).absolute().offset(vp.x, vp.y).size(vp.w, vp.h).clip();
        defer box.end();
        const view: rules.Size = .{ .w = vp.w, .h = vp.h };
        if (shown) |sh| {
            const zoom = s.zoom.effective(sh.size, view);
            const pl = rules.place(sh.size, zoom, s.zoom.pan, view);
            {
                ui.key(c, "image-preview-picture");
                const pic = ui.div(c).absolute().offset(pl.x, pl.y).size(pl.w, pl.h);
                defer pic.end();
                _ = pic.interaction();
                _ = ui.image(c, .{ .key = sh.key, .source = .{ .encoded = sh.bytes }, .box = .{ .w = pl.w, .h = pl.h }, .part = pl.part, .radius = 0 });
            }
            if (s.editor) |*ed| {
                ed.zoom = zoom;
                const pan = rules.clampPan(s.zoom.pan, sh.size, zoom, view);
                const x0 = (vp.w - sh.size.w * zoom) / 2 + pan.x;
                const y0 = (vp.h - sh.size.h * zoom) / 2 + pan.y;
                annotate_view.marks(c, k, &ed.marks, .{ .x0 = x0, .y0 = y0, .zoom = zoom, .chrome = 1 }, ed.drawing);
            }
        } else {
            const msg = ui.div(c).column().size(vp.w, vp.h).center().gap(10);
            defer msg.end();
            if (refusal) |why| {
                icons.icon(c, .@"danger-triangle", 20, k.danger_muted, 0);
                const t = ui.div(c).column().maxW(@min(420, vp.w)).itemsCenter();
                defer t.end();
                ui.text(c, why, .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
            } else {
                kit.snake(c, k);
                ui.text(c, "Loading image…", .{ .size = 13, .line_height = 19, .color = k.muted });
            }
        }
    }

    if (shown) |sh| pointer(c, a, vp, sh);
    header(c, a, k, e, shown, vp);
    if (!editing) stepButtons(c, a, k, vp);
    if (editing) {
        if (shown) |sh| annotate_view.editor(c, a, k, vp, sh);
    } else footer(c, a, k, e, shown, vp);

    // A plain click on the backdrop closes it; a drag released there doesn't.
    if (root_it.clicked and !editing and c.hot == root_it.id) {
        const moved = if (s.drag) |d| d.moved else false;
        if (!moved) preview.close(a);
    }
    if (c.input.released and !editing) s.drag = null;
}

/// Pinch and Ctrl + wheel zoom about the pointer, the wheel or a drag pan;
/// in annotate the pointer draws instead (view_annotate.zig).
fn pointer(c: *ui.Context, a: *App, vp: Viewport, sh: Shown) void {
    const s = &a.ui_gaps.preview;
    const m = c.input.mouse;
    const inside = m.x >= vp.x and m.x < vp.x + vp.w and m.y >= vp.y and m.y < vp.y + vp.h;
    const view: rules.Size = .{ .w = vp.w, .h = vp.h };
    const at: rules.Point = .{ .x = m.x - vp.x, .y = m.y - vp.y };
    if (inside and c.input.zoom != 1) {
        s.zoom = rules.zoomAbout(s.zoom, c.input.zoom, at, sh.size, view);
        c.changed = true;
    }
    if (inside and (c.input.scroll.x != 0 or c.input.scroll.y != 0)) {
        if (c.input.ctrl) {
            if (c.input.scroll.y != 0) s.zoom = rules.zoomAbout(s.zoom, rules.wheelFactor(c.input.scroll.y, c.input.precise), at, sh.size, view);
        } else {
            s.zoom = rules.panBy(s.zoom, .{ .x = c.input.scroll.x, .y = c.input.scroll.y }, sh.size, view);
        }
        c.changed = true;
    }
    if (s.editor != null) return annotate_view.pointer(c, a, vp, sh);
    if (c.input.pressed and inside) {
        const zoom = s.zoom.effective(sh.size, view);
        s.drag = .{ .from = .{ .x = m.x, .y = m.y }, .pan = rules.clampPan(s.zoom.pan, sh.size, zoom, view) };
    }
    if (s.drag) |*d| if (c.input.down) {
        const dx = m.x - d.from.x;
        const dy = m.y - d.from.y;
        if (@abs(dx) > 3 or @abs(dy) > 3) d.moved = true;
        if (d.moved) {
            const zoom = s.zoom.effective(sh.size, view);
            s.zoom = .{ .zoom = s.zoom.zoom, .pan = rules.clampPan(.{ .x = d.pan.x + dx, .y = d.pan.y + dy }, sh.size, zoom, view) };
            c.cursor = .closed_hand;
            c.changed = true;
        }
    };
}

fn zoomBy(a: *App, c: *ui.Context, factor: f32, vp: Viewport, size: rules.Size) void {
    const s = &a.ui_gaps.preview;
    s.zoom = rules.zoomAbout(s.zoom, factor, .{ .x = vp.w / 2, .y = vp.h / 2 }, size, .{ .w = vp.w, .h = vp.h });
    c.changed = true;
    a.redraw();
}

fn header(c: *ui.Context, a: *App, k: theme.Colors, e: *const preview.Entry, shown: ?Shown, vp: Viewport) void {
    const s = &a.ui_gaps.preview;
    // Clear of the window's traffic lights.
    const bar = ui.div(c).absolute().offset(96, 12).size(c.size.w - 96 - side, 32).row().gap(8).itemsCenter();
    defer bar.end();
    {
        const t = ui.div(c).row().grow().w(0).gap(10).itemsCenter().clip();
        defer t.end();
        kit.ellipsisText(c, e.name, .{ .size = 13, .line_height = 19, .weight = .medium, .color = k.text }, @max(80, c.size.w * 0.3));
        const pos = c.alloc().alloc(u8, 24) catch return;
        const p = rules.position(pos, s.index, s.entries.items.len);
        if (p.len > 0) ui.text(c, p, .{ .size = 12, .line_height = 18, .color = k.muted });
        if (shown) |sh| {
            const pct = c.alloc().alloc(u8, 16) catch return;
            ui.text(c, rules.percent(pct, s.zoom.effective(sh.size, .{ .w = vp.w, .h = vp.h })), .{ .size = 12, .line_height = 18, .color = k.faint });
        }
        if (s.notice.len > 0) ui.text(c, s.notice, .{ .size = 12, .line_height = 18, .color = k.success_muted });
    }
    if (shown) |sh| {
        ui.key(c, "image-preview-zoom-out");
        if (gk.button(c, k, "−", .{ .look = .quiet, .square = true })) zoomBy(a, c, 1 / rules.key_step, vp, sh.size);
        ui.key(c, "image-preview-fit");
        if (gk.button(c, k, if (s.zoom.zoom == null) "Actual size" else "Fit", .{ .look = .quiet })) {
            s.zoom = if (s.zoom.zoom == null) .{ .zoom = 1 } else .{};
            a.redraw();
        }
        ui.key(c, "image-preview-zoom-in");
        if (gk.button(c, k, "+", .{ .look = .quiet, .square = true })) zoomBy(a, c, rules.key_step, vp, sh.size);
        ui.key(c, "image-preview-copy");
        if (gk.button(c, k, "Copy", .{ .look = .quiet, .icon = .copy })) preview.copy(a);
    }
    var buf: [4096]u8 = undefined;
    if (preview.localPath(a, e, &buf) != null) {
        ui.key(c, "image-preview-reveal");
        if (gk.button(c, k, "Reveal in Finder", .{ .look = .quiet, .icon = .folder })) preview.reveal(a);
    }
    ui.key(c, "image-preview-close");
    if (gk.button(c, k, "", .{ .look = .quiet, .square = true, .icon = .close })) preview.close(a);
}

fn stepButtons(c: *ui.Context, a: *App, k: theme.Colors, vp: Viewport) void {
    const s = &a.ui_gaps.preview;
    const y = vp.y + vp.h / 2 - 18;
    if (rules.step(s.index, s.entries.items.len, false) != null) {
        ui.key(c, "image-preview-prev");
        const b = ui.div(c).absolute().offset(vp.x + 8, y);
        defer b.end();
        if (gk.button(c, k, "", .{ .square = true, .h = 36, .icon = .@"alt-arrow-left" })) preview.stepBy(a, false);
    }
    if (rules.step(s.index, s.entries.items.len, true) != null) {
        ui.key(c, "image-preview-next");
        const b = ui.div(c).absolute().offset(vp.x + vp.w - 44, y);
        defer b.end();
        if (gk.button(c, k, "", .{ .square = true, .h = 36, .icon = .@"alt-arrow-right" })) preview.stepBy(a, true);
    }
}

/// On macOS, Annotate is centred beneath the image and its file name.
fn footer(c: *ui.Context, a: *App, k: theme.Colors, e: *const preview.Entry, shown: ?Shown, vp: Viewport) void {
    const f = ui.div(c).absolute().offset(0, vp.y + vp.h + 10).w(c.size.w).column().itemsCenter().gap(8);
    defer f.end();
    kit.ellipsisText(c, e.name, .{ .size = 12, .line_height = 18, .color = k.muted }, @max(80, c.size.w - 2 * side));
    if (shown != null and annotatable(e.name)) {
        ui.key(c, "image-preview-annotate");
        if (gk.button(c, k, "Annotate", .{ .icon = .pen })) annotate_app.start(a);
    }
}

/// Raster pictures annotate; an SVG is drawn, not edited.
pub fn annotatable(name: []const u8) bool {
    return !std.ascii.endsWithIgnoreCase(name, ".svg");
}

/// While open it has the keys: Escape closes (or leaves annotate), ←/→
/// step, ⌘= / ⌘- / ⌘0 zoom, ⌘C copies.
pub fn keys(c: *ui.Context, a: *App) bool {
    const s = &a.ui_gaps.preview;
    if (!s.open) return false;
    if (s.editor != null) return annotate_view.keys(c, a);
    const S = ui.Shortcut;
    if (c.shortcut(.{ .key = S.escape })) {
        preview.close(a);
    } else if (c.shortcut(.{ .key = S.left })) {
        preview.stepBy(a, false);
    } else if (c.shortcut(.{ .key = S.right })) {
        preview.stepBy(a, true);
    } else if (c.shortcut(.{ .key = 'c', .cmd = true })) {
        preview.copy(a);
    } else if (c.shortcut(.{ .key = '0', .cmd = true })) {
        s.zoom = .{};
        a.redraw();
    } else {
        const in = c.shortcut(.{ .key = '=', .cmd = true }) or c.shortcut(.{ .key = '+', .cmd = true }) or c.shortcut(.{ .key = '+', .cmd = true, .shift = true });
        const out = !in and c.shortcut(.{ .key = '-', .cmd = true });
        if (in or out) if (preview.current(a)) |e| if (preview.bytesOf(a, e) == .ready) {
            const bytes = preview.bytesOf(a, e).ready;
            if (ui.imageSize(c, imageKey(c, e, bytes), bytes)) |size| zoomBy(a, c, if (in) rules.key_step else 1 / rules.key_step, viewport(c, false), .{ .w = size.w, .h = size.h });
        };
    }
    return true;
}

/// A 56-point tile for an agent's image in the transcript; a click opens
/// the preview at it.
pub fn partTile(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, name: []const u8, path: []const u8) void {
    const images = @import("app_attachment_images.zig");
    const tiles = @import("view_composer_attachments.zig");
    const image = if (path.len > 0) images.get(a, chat_id, path) else null;
    const bytes: []const u8 = if (image) |loaded| images.tileBytes(loaded) else "";
    const tile = ui.div(c).column().w(56).gap(2).control();
    defer tile.end();
    const it = c.interact(tile.index, .{ .focusable = path.len > 0 });
    {
        const thumb = ui.div(c).row().size(56, 56).center().rounded(8).border(if (it.focused) k.accent else k.border).bg(k.hover).clip();
        defer thumb.end();
        tiles.picture(c, k, c.print("{s}:{s}", .{ chat_id orelse "", path }), name, bytes);
    }
    kit.ellipsisText(c, name, .{ .size = 10, .line_height = 12, .color = k.muted }, 56);
    if (it.clicked and path.len > 0) preview.openFromTranscript(a, chat_id, path);
}

test "SVGs preview but don't annotate" {
    try std.testing.expect(annotatable("shot.PNG"));
    try std.testing.expect(!annotatable("logo.SVG"));
}
