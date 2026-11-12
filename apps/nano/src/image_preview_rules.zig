//! The image preview's rules (docs/image-preview.md), as pure functions:
//! the initial fit, the zoom range, zooming about the pointer, clamping
//! the pan, what part of the picture a viewport shows, stepping through a
//! chat's images, and the chunked `ReadWorkspaceImage` transfer's checks.
const std = @import("std");

/// "Zoom normally spans 1%–3200%".
pub const min_zoom: f32 = 0.01;
pub const max_zoom: f32 = 32;
/// Layout dimensions are capped at 131072 logical points.
pub const max_layout: f32 = 131072;
/// `MAX_WORKSPACE_IMAGE_BYTES` and `WORKSPACE_IMAGE_CHUNK_BYTES`.
pub const max_image_bytes: usize = 8 * 1024 * 1024;
pub const chunk_bytes: usize = 384 * 1024;
/// Raster decoding limits each side to 4096 pixels.
pub const max_side: u32 = 4096;
/// The complete read must finish in 30 seconds.
pub const read_deadline_s: f64 = 30;
/// One keyboard zoom step (⌘= / ⌘-).
pub const key_step: f32 = 1.25;

pub const Size = struct { w: f32, h: f32 };
pub const Point = struct { x: f32 = 0, y: f32 = 0 };

/// Points per image pixel that fit the picture in the viewport, keeping
/// its proportions and never upscaling a small one.
pub fn fitZoom(img: Size, view: Size) f32 {
    if (img.w <= 0 or img.h <= 0 or view.w <= 0 or view.h <= 0) return 1;
    return @min(1, @min(view.w / img.w, view.h / img.h));
}

/// The smallest zoom allowed: 1%, or less when that's what fits a huge
/// picture.
pub fn floorZoom(fit: f32) f32 {
    return @min(min_zoom, fit);
}

/// `z` within the range, and within the layout cap for this picture.
pub fn clampZoom(z: f32, img: Size, fit: f32) f32 {
    const longest = @max(img.w, img.h, 1);
    const cap = @min(max_zoom, max_layout / longest);
    return std.math.clamp(z, floorZoom(fit), @max(cap, floorZoom(fit)));
}

/// The pan (the picture's centre from the viewport's, in points) kept so
/// the picture's edges never come inside the viewport while it overflows,
/// and centred along an axis it doesn't fill.
pub fn clampPan(pan: Point, img: Size, zoom: f32, view: Size) Point {
    const dw = img.w * zoom;
    const dh = img.h * zoom;
    const mx = @max(0, (dw - view.w) / 2);
    const my = @max(0, (dh - view.h) / 2);
    return .{ .x = std.math.clamp(pan.x, -mx, mx), .y = std.math.clamp(pan.y, -my, my) };
}

/// A zoom and pan, or the fit (zoom null), which follows the viewport.
pub const Zoom = struct {
    zoom: ?f32 = null,
    pan: Point = .{},

    pub fn effective(z: Zoom, img: Size, view: Size) f32 {
        const fit = fitZoom(img, view);
        return if (z.zoom) |v| clampZoom(v, img, fit) else fit;
    }
};

/// Zoom by `factor` about `at` (viewport coordinates): the image point
/// under the pointer stays under it.
pub fn zoomAbout(z: Zoom, factor: f32, at: Point, img: Size, view: Size) Zoom {
    const old = z.effective(img, view);
    const new = clampZoom(old * factor, img, fitZoom(img, view));
    const pan = clampPan(z.pan, img, old, view);
    const x0 = (view.w - img.w * old) / 2 + pan.x;
    const y0 = (view.h - img.h * old) / 2 + pan.y;
    const ix = (at.x - x0) / old;
    const iy = (at.y - y0) / old;
    const nx0 = at.x - ix * new;
    const ny0 = at.y - iy * new;
    const next_pan: Point = .{ .x = nx0 - (view.w - img.w * new) / 2, .y = ny0 - (view.h - img.h * new) / 2 };
    return .{ .zoom = new, .pan = clampPan(next_pan, img, new, view) };
}

/// A drag or an unmodified scroll moves the picture by `d` points.
pub fn panBy(z: Zoom, d: Point, img: Size, view: Size) Zoom {
    const zoom = z.effective(img, view);
    const p = clampPan(.{ .x = z.pan.x + d.x, .y = z.pan.y + d.y }, img, zoom, view);
    return .{ .zoom = z.zoom, .pan = p };
}

/// Ctrl + wheel: up (positive `dy`) zooms in, down zooms out.
pub fn wheelFactor(dy: f32, precise: bool) f32 {
    const per: f32 = if (precise) 0.01 else 0.1;
    return std.math.clamp(@exp(dy * per), 0.5, 2);
}

/// Where the visible part of the picture goes in the viewport, and which
/// part (0 to 1: left, top, right, bottom) it is.
pub const Placement = struct { x: f32, y: f32, w: f32, h: f32, part: [4]f32 };

pub fn place(img: Size, zoom: f32, pan_in: Point, view: Size) Placement {
    const dw = img.w * zoom;
    const dh = img.h * zoom;
    const pan = clampPan(pan_in, img, zoom, view);
    const x0 = (view.w - dw) / 2 + pan.x;
    const y0 = (view.h - dh) / 2 + pan.y;
    const vx = @max(x0, 0);
    const vy = @max(y0, 0);
    const vw = @max(0, @min(x0 + dw, view.w) - vx);
    const vh = @max(0, @min(y0 + dh, view.h) - vy);
    const sdw = @max(dw, 1e-6);
    const sdh = @max(dh, 1e-6);
    return .{ .x = vx, .y = vy, .w = vw, .h = vh, .part = .{ (vx - x0) / sdw, (vy - y0) / sdh, (vx - x0 + vw) / sdw, (vy - y0 + vh) / sdh } };
}

/// A viewport point as image pixels, for annotation.
pub fn toImage(at: Point, img: Size, zoom: f32, pan_in: Point, view: Size) Point {
    const pan = clampPan(pan_in, img, zoom, view);
    const x0 = (view.w - img.w * zoom) / 2 + pan.x;
    const y0 = (view.h - img.h * zoom) / 2 + pan.y;
    return .{ .x = (at.x - x0) / zoom, .y = (at.y - y0) / zoom };
}

/// The image pixel `p` in viewport points.
pub fn toView(p: Point, img: Size, zoom: f32, pan_in: Point, view: Size) Point {
    const pan = clampPan(pan_in, img, zoom, view);
    const x0 = (view.w - img.w * zoom) / 2 + pan.x;
    const y0 = (view.h - img.h * zoom) / 2 + pan.y;
    return .{ .x = x0 + p.x * zoom, .y = y0 + p.y * zoom };
}

/// The neighbour of `index` among `count` images in transcript order: the
/// next (`forward`) or previous one, none past either end.
pub fn step(index: usize, count: usize, forward: bool) ?usize {
    if (count == 0 or index >= count) return null;
    if (forward) return if (index + 1 < count) index + 1 else null;
    return if (index > 0) index - 1 else null;
}

/// "3 of 7".
pub fn position(buf: []u8, index: usize, count: usize) []const u8 {
    if (count <= 1) return "";
    return std.fmt.bufPrint(buf, "{d} of {d}", .{ index + 1, count }) catch "";
}

/// "125%".
pub fn percent(buf: []u8, zoom: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}%", .{@as(u32, @intFromFloat(@round(zoom * 100)))}) catch "";
}

/// Each surface keeps at most 64 MiB of decoded image.
pub const max_retained: usize = 64 * 1024 * 1024;

/// Why a picture of `w` by `h` pixels can't be shown, or null when it can:
/// 4096 pixels a side, 64 MiB decoded.
pub fn decodeRefusal(w: f32, h: f32) ?[]const u8 {
    if (w <= 0 or h <= 0) return "This image couldn't be decoded.";
    if (w > @as(f32, @floatFromInt(max_side)) or h > @as(f32, @floatFromInt(max_side))) return "This image is larger than 4096 pixels on a side and can't be previewed.";
    if (w * h * 4 > @as(f32, @floatFromInt(max_retained))) return "This image needs more than 64 MB of memory and can't be previewed.";
    return null;
}

test "decoding refuses pictures past the side and memory limits" {
    try testing.expect(decodeRefusal(4096, 4096) == null);
    try testing.expect(decodeRefusal(4097, 10) != null);
    try testing.expect(decodeRefusal(0, 10) != null);
}

/// One `WorkspaceImageChunk`, as read.
pub const Chunk = struct {
    checkout_id: []const u8,
    content_hash: []const u8,
    mime_type: []const u8,
    data_len: usize,
    next_offset: usize,
    size: usize,
    done: bool,
};

/// What came before: the transfer's identity, fixed by its first chunk.
pub const Transfer = struct {
    checkout_id: [128]u8 = undefined,
    checkout_len: usize = 0,
    hash: [128]u8 = undefined,
    hash_len: usize = 0,
    mime: [64]u8 = undefined,
    mime_len: usize = 0,
    size: usize = 0,
    offset: usize = 0,
    started: bool = false,
};

pub const ChunkError = error{ EmptyIdentity, NotAnImage, TooLarge, ChunkTooLarge, ChangedDuringRead, BadOffset, BadCompletion, IdentityTooLong };

/// Checks a chunk against the transfer so far and advances it: stable
/// checkout, hash, MIME type and size; at most 8 MiB in 384 KiB chunks;
/// offsets that only move forward; `done` exactly at the end.
pub fn acceptChunk(t: *Transfer, ch: Chunk) ChunkError!void {
    if (ch.checkout_id.len == 0 or ch.content_hash.len == 0) return error.EmptyIdentity;
    if (!std.mem.startsWith(u8, ch.mime_type, "image/")) return error.NotAnImage;
    if (ch.size == 0 or ch.size > max_image_bytes) return error.TooLarge;
    if (ch.data_len > std.base64.standard.Encoder.calcSize(chunk_bytes)) return error.ChunkTooLarge;
    if (!t.started) {
        if (ch.checkout_id.len > t.checkout_id.len or ch.content_hash.len > t.hash.len or ch.mime_type.len > t.mime.len) return error.IdentityTooLong;
        @memcpy(t.checkout_id[0..ch.checkout_id.len], ch.checkout_id);
        t.checkout_len = ch.checkout_id.len;
        @memcpy(t.hash[0..ch.content_hash.len], ch.content_hash);
        t.hash_len = ch.content_hash.len;
        @memcpy(t.mime[0..ch.mime_type.len], ch.mime_type);
        t.mime_len = ch.mime_type.len;
        t.size = ch.size;
        t.started = true;
    } else if (!std.mem.eql(u8, ch.checkout_id, t.checkout_id[0..t.checkout_len]) or
        !std.mem.eql(u8, ch.content_hash, t.hash[0..t.hash_len]) or
        !std.mem.eql(u8, ch.mime_type, t.mime[0..t.mime_len]) or ch.size != t.size)
    {
        return error.ChangedDuringRead;
    }
    if (ch.next_offset <= t.offset or ch.next_offset > t.size) return error.BadOffset;
    if (ch.done != (ch.next_offset == t.size)) return error.BadCompletion;
    t.offset = ch.next_offset;
}

/// What the surface says for a failed read.
pub fn chunkMessage(e: ChunkError) []const u8 {
    return switch (e) {
        error.TooLarge => "This image is larger than 8 MB and can't be previewed.",
        error.ChangedDuringRead => "The image changed while it was loading. Open it again.",
        error.NotAnImage => "This file isn't an image Harness can preview.",
        else => "The image couldn't be read.",
    };
}

const testing = std.testing;

test "the fit keeps proportions and never upscales" {
    try testing.expectEqual(@as(f32, 1), fitZoom(.{ .w = 100, .h = 50 }, .{ .w = 800, .h = 600 }));
    try testing.expectEqual(@as(f32, 0.5), fitZoom(.{ .w = 1600, .h = 400 }, .{ .w = 800, .h = 600 }));
    try testing.expectEqual(@as(f32, 0.25), fitZoom(.{ .w = 400, .h = 2400 }, .{ .w = 800, .h = 600 }));
}

test "zoom spans 1% to 3200%, lower only to fit a huge picture, capped by the layout limit" {
    const img: Size = .{ .w = 1000, .h = 1000 };
    try testing.expectEqual(@as(f32, 0.01), clampZoom(0.0001, img, 0.5));
    try testing.expectEqual(@as(f32, 32), clampZoom(100, img, 0.5));
    // A picture whose fit is under 1% may go as low as its fit.
    try testing.expectEqual(@as(f32, 0.004), clampZoom(0.001, img, 0.004));
    // 131072 points at most along the longest side.
    try testing.expectEqual(@as(f32, 131072.0 / 8192.0), clampZoom(32, .{ .w = 8192, .h = 10 }, 0.1));
}

test "zooming keeps the point under the pointer, and the pan stays inside" {
    const img: Size = .{ .w = 400, .h = 300 };
    const view: Size = .{ .w = 800, .h = 600 };
    const at: Point = .{ .x = 300, .y = 200 };
    const before = toImage(at, img, 1, .{}, view);
    const z = zoomAbout(.{}, 4, at, img, view);
    try testing.expectEqual(@as(f32, 4), z.zoom.?);
    const after = toImage(at, img, 4, z.pan, view);
    try testing.expectApproxEqAbs(before.x, after.x, 0.01);
    try testing.expectApproxEqAbs(before.y, after.y, 0.01);
    // Panning past the edge stops at the edge.
    const far = panBy(z, .{ .x = 10_000, .y = -10_000 }, img, view);
    try testing.expectEqual(@as(f32, (1600 - 800) / 2), far.pan.x);
    try testing.expectEqual(@as(f32, -(1200 - 600) / 2), far.pan.y);
    const big = panBy(.{ .zoom = 4 }, .{ .x = 10_000 }, img, view);
    try testing.expectEqual(@as(f32, (1600 - 800) / 2), big.pan.x);
}

test "the placement shows the visible part, and a small picture whole and centred" {
    const small = place(.{ .w = 100, .h = 50 }, 1, .{}, .{ .w = 300, .h = 150 });
    try testing.expectEqual(@as(f32, 100), small.x);
    try testing.expectEqual(@as(f32, 50), small.y);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 1 }, &small.part);
    const big = place(.{ .w = 400, .h = 400 }, 2, .{ .x = 200, .y = 0 }, .{ .w = 400, .h = 400 });
    try testing.expectEqual(@as(f32, 0), big.x);
    try testing.expectEqual(@as(f32, 400), big.w);
    // Panned right as far as it goes: the left half shows, its middle rows.
    try testing.expectApproxEqAbs(@as(f32, 0), big.part[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), big.part[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), big.part[1], 1e-4);
}

test "a manual zoom keeps its scale when the window resizes; the fit follows" {
    const img: Size = .{ .w = 2000, .h = 1000 };
    const fit: Zoom = .{};
    try testing.expectEqual(@as(f32, 0.5), fit.effective(img, .{ .w = 1000, .h = 800 }));
    try testing.expectEqual(@as(f32, 0.25), fit.effective(img, .{ .w = 500, .h = 800 }));
    const manual: Zoom = .{ .zoom = 1.5 };
    try testing.expectEqual(@as(f32, 1.5), manual.effective(img, .{ .w = 500, .h = 800 }));
}

test "ctrl-wheel up zooms in, down zooms out, bounded per event" {
    try testing.expect(wheelFactor(3, false) > 1);
    try testing.expect(wheelFactor(-3, false) < 1);
    try testing.expectEqual(@as(f32, 2), wheelFactor(1000, false));
    try testing.expectEqual(@as(f32, 0.5), wheelFactor(-1000, true));
}

test "next and previous follow transcript order and stop at the ends" {
    try testing.expectEqual(@as(?usize, 1), step(0, 3, true));
    try testing.expectEqual(@as(?usize, null), step(2, 3, true));
    try testing.expectEqual(@as(?usize, null), step(0, 3, false));
    try testing.expectEqual(@as(?usize, 1), step(2, 3, false));
    try testing.expectEqual(@as(?usize, null), step(0, 0, true));
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings("2 of 3", position(&b, 1, 3));
    try testing.expectEqualStrings("", position(&b, 0, 1));
    try testing.expectEqualStrings("125%", percent(&b, 1.25));
}

test "a workspace image transfer rejects what the docs reject" {
    var t: Transfer = .{};
    const first: Chunk = .{ .checkout_id = "co", .content_hash = "h1", .mime_type = "image/png", .data_len = 10, .next_offset = 384 * 1024, .size = 500 * 1024, .done = false };
    try acceptChunk(&t, first);
    // Same length, other content: refused.
    var changed = first;
    changed.content_hash = "h2";
    changed.next_offset = 500 * 1024;
    changed.done = true;
    try testing.expectError(error.ChangedDuringRead, acceptChunk(&t, changed));
    // An offset that doesn't move forward.
    var stuck = first;
    try testing.expectError(error.BadOffset, acceptChunk(&t, stuck));
    // Done before the end, or not done at it.
    stuck.next_offset = 400 * 1024;
    stuck.done = true;
    try testing.expectError(error.BadCompletion, acceptChunk(&t, stuck));
    var last = first;
    last.next_offset = 500 * 1024;
    last.done = true;
    try acceptChunk(&t, last);
    var fresh: Transfer = .{};
    var empty = first;
    empty.checkout_id = "";
    try testing.expectError(error.EmptyIdentity, acceptChunk(&fresh, empty));
    var huge = first;
    huge.size = 9 * 1024 * 1024;
    try testing.expectError(error.TooLarge, acceptChunk(&fresh, huge));
    var fat = first;
    fat.data_len = std.base64.standard.Encoder.calcSize(chunk_bytes) + 1;
    try testing.expectError(error.ChunkTooLarge, acceptChunk(&fresh, fat));
    var text = first;
    text.mime_type = "text/plain";
    try testing.expectError(error.NotAnImage, acceptChunk(&fresh, text));
}
