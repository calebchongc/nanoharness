//! The photo library for the composer's attach button: PHPickerViewController
//! (ThemedPhotosPicker.swift: images only, eight at most), called through
//! the Objective-C runtime. PhotosUI is opened at run time, so the app's
//! link line doesn't change; the picker needs no photo-library permission.
//!
//! Each picked image's bytes arrive on a background thread: pictures the
//! engine serves as they are (png/jpg/gif/webp) are kept, anything else
//! (HEIC) is re-encoded as JPEG at 0.9, as `StagedAttachment.stage` does.
//! The composer takes them from `take` on its next frame.
const std = @import("std");
const builtin = @import("builtin");
const ma = @import("mobile_attach.zig");

pub const available = builtin.os.tag == .ios;

/// What arrived since the last `take`: owned by `std.heap.c_allocator`.
pub const Batch = struct {
    images: std.ArrayList([]u8) = .empty,
    failed: usize = 0,

    pub fn deinit(b: *Batch) void {
        for (b.images.items) |i| std.heap.c_allocator.free(i);
        b.images.deinit(std.heap.c_allocator);
        b.* = .{};
    }
};

var mutex: std.atomic.Mutex = .unlocked;
var pending: Batch = .{};

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

/// The images (and failures) picked since last asked; null when none.
pub fn take() ?Batch {
    lock();
    defer mutex.unlock();
    if (pending.images.items.len == 0 and pending.failed == 0) return null;
    const b = pending;
    pending = .{};
    return b;
}

fn add(bytes: ?[]u8) void {
    lock();
    defer mutex.unlock();
    if (bytes) |b| {
        pending.images.append(std.heap.c_allocator, b) catch {
            std.heap.c_allocator.free(b);
            pending.failed += 1;
        };
    } else pending.failed += 1;
}

/// Picked bytes as they upload: kept, or JPEG from a decoder; null when
/// unsupported or over 24 MB. `transcode` decodes and re-encodes.
pub fn prepare(data: []const u8, transcode: *const fn ([]const u8) ?[]u8) ?[]u8 {
    switch (ma.plan(data)) {
        .too_large => return null,
        .keep => return std.heap.c_allocator.dupe(u8, data) catch null,
        .transcode => {
            const jpeg = transcode(data) orelse return null;
            if (jpeg.len > ma.max_bytes or ma.sniff(jpeg) == null) {
                std.heap.c_allocator.free(jpeg);
                return null;
            }
            return jpeg;
        },
    }
}

const impl = if (available) struct {
    const nanoui = @import("nanoui");
    const objc = nanoui.objc;

    extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
    extern "c" fn UIImageJPEGRepresentation(image: objc.Object, quality: objc.CGFloat) ?objc.Object;

    const Ctx = struct {};
    var ctx: Ctx = .{};
    var delegate: ?objc.Object = null;

    fn bytesOf(data: objc.Object) []const u8 {
        const len = objc.msg(objc.NSUInteger, data, "length", .{});
        const p = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return &.{};
        return p[0..len];
    }

    fn jpeg(data: []const u8) ?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const ns = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ @as(*const anyopaque, data.ptr), @as(objc.NSUInteger, data.len) });
        const image = objc.msg(?objc.Object, objc.class("UIImage"), "imageWithData:", .{ns}) orelse return null;
        const out = UIImageJPEGRepresentation(image, 0.9) orelse return null;
        return std.heap.c_allocator.dupe(u8, bytesOf(out)) catch null;
    }

    fn loaded(_: *Ctx, data: ?objc.Object, _: ?objc.Object) void {
        const d = data orelse return add(null);
        add(prepare(bytesOf(d), jpeg));
    }

    const LoadBlock = objc.Block(Ctx, &.{ ?objc.Object, ?objc.Object });

    fn finished(_: objc.Object, _: objc.SEL, picker: objc.Object, results: objc.Object) callconv(.c) void {
        objc.msg(void, picker, "dismissViewControllerAnimated:completion:", .{ objc.YES, @as(?*anyopaque, null) });
        const n = objc.msg(objc.NSUInteger, results, "count", .{});
        for (0..@min(n, ma.max_pick)) |i| {
            const r = objc.msg(objc.Object, results, "objectAtIndex:", .{i});
            const provider = objc.msg(objc.Object, r, "itemProvider", .{});
            var block = LoadBlock.init(&ctx, loaded);
            _ = objc.msg(?objc.Object, provider, "loadDataRepresentationForTypeIdentifier:completionHandler:", .{
                objc.nsString("public.image"), @as(*anyopaque, @ptrCast(&block)),
            });
        }
    }

    fn open() bool {
        _ = dlopen("/System/Library/Frameworks/PhotosUI.framework/PhotosUI", 1);
        if (objc_getClass("PHPickerViewController") == null) return false;
        const app = nanoui.App.shared() orelse return false;
        const top = app.topController() orelse return false;
        const pool = objc.Pool.push();
        defer pool.pop();
        const cfg = objc.msg(objc.Object, objc.alloc("PHPickerConfiguration"), "init", .{});
        defer objc.release(cfg);
        objc.msg(void, cfg, "setSelectionLimit:", .{@as(objc.NSInteger, ma.max_pick)});
        objc.msg(void, cfg, "setFilter:", .{objc.msg(objc.Object, objc.class("PHPickerFilter"), "imagesFilter", .{})});
        const picker = objc.msg(objc.Object, objc.alloc("PHPickerViewController"), "initWithConfiguration:", .{cfg});
        defer objc.release(picker);
        if (delegate == null) {
            const cls = objc.defineClass(.{
                .name = "HarnessPhotoPickerDelegate",
                .protocols = &.{"PHPickerViewControllerDelegate"},
                .methods = &.{.{ .name = "picker:didFinishPicking:", .imp = &finished, .types = "v@:@@" }},
            });
            // Kept for the app's life: the picker holds its delegate weakly.
            delegate = objc.msg(objc.Object, cls, "new", .{});
        }
        objc.msg(void, picker, "setDelegate:", .{delegate.?});
        objc.msg(void, top, "presentViewController:animated:completion:", .{ picker, objc.YES, @as(?*anyopaque, null) });
        return true;
    }

    /// The clipboard holds a picture (UIPasteboard `hasImages`, which
    /// doesn't read it, so no paste banner).
    fn clipboardHasImage() bool {
        const pb = objc.msg(objc.Object, objc.class("UIPasteboard"), "generalPasteboard", .{});
        return objc.msg(objc.BOOL, pb, "hasImages", .{});
    }
} else struct {
    fn open() bool {
        return false;
    }
    fn clipboardHasImage() bool {
        return true;
    }
};

/// Re-encodes a picture the system can decode as JPEG (0.9); null off iOS.
pub fn transcodeJpeg(data: []const u8) ?[]u8 {
    if (!available) return null;
    return impl.jpeg(data);
}

/// Shows the photo library; false where there is none (not iOS).
pub fn open() bool {
    if (!available) return false;
    return impl.open();
}

/// Whether "Paste image" has something to paste (always offered off iOS,
/// where checking would read the clipboard).
pub fn clipboardHasImage() bool {
    return impl.clipboardHasImage();
}

const testing = std.testing;

fn fakeJpeg(_: []const u8) ?[]u8 {
    const out = std.heap.c_allocator.alloc(u8, 12) catch return null;
    @memcpy(out, &[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0 });
    return out;
}

fn noDecoder(_: []const u8) ?[]u8 {
    return null;
}

test "picked bytes: kept, transcoded to JPEG, or refused" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0 };
    const kept = prepare(&png, noDecoder).?;
    defer std.heap.c_allocator.free(kept);
    try testing.expectEqualSlices(u8, &png, kept);
    const heic = "\x00\x00\x00\x18ftypheic";
    const j = prepare(heic, fakeJpeg).?;
    defer std.heap.c_allocator.free(j);
    try testing.expectEqual(ma.Ext.jpg, ma.sniff(j).?);
    try testing.expect(prepare(heic, noDecoder) == null);
    add(null);
    var b = take().?;
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.failed);
    try testing.expect(take() == null);
}
