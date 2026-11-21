//! Drops from other apps onto the macOS surface: a drag's place while it
//! moves over the view, and the drop's links (local files resolved to native
//! paths, other links as URLs) and text, for one frame (`surface_events.zig`
//! registers them).
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");
const Surface = @import("surface.zig").Surface;

fn surfaceOf(obj: objc.Object) ?*Surface {
    return objc.getZig(Surface, obj);
}

/// Where a drag is, in view points.
fn dragPoint(s: *Surface, info: objc.Object) types.Point {
    return s.toView(objc.msg(objc.CGPoint, info, "draggingLocation", .{}));
}

/// A drag from another app moves over the view: a copy where a box takes drops.
pub fn draggingUpdated(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    const s = surfaceOf(obj) orelse return 0;
    const tok = s.token();
    const p = dragPoint(s, info);
    s.ctx.input.drag_over = p;
    s.frame();
    if (!Surface.alive(tok)) return 0;
    return if (s.ctx.acceptsDropAt(p)) 1 else 0; // NSDragOperationCopy
}

pub fn draggingExited(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.ctx.input.drag_over = null;
    s.frame();
}

/// Normalizes a dropped NSURL at the AppKit boundary before discarding the
/// NSURL object. Local file URLs (including macOS file-reference URLs like
/// `file:///.file/id=...`) resolve through Foundation `filePathURL` to a native
/// POSIX path; remote file URLs, non-file URLs, percent-encoded NULs, and
/// unresolvable file references keep `absoluteString` so downstream intake can
/// reject them with an accurate error category.
pub fn serializeDroppedUrl(a: std.mem.Allocator, url: objc.Object) ?[]const u8 {
    const abs = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    if (objc.msg(objc.BOOL, url, "isFileURL", .{})) {
        const host = objc.fromNSString(objc.msg(?objc.Object, url, "host", .{}));
        const is_local = host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost");
        if (is_local and std.mem.indexOf(u8, abs, "%00") == null) {
            if (objc.msg(?objc.Object, url, "filePathURL", .{})) |resolved| {
                const path = objc.fromNSString(objc.msg(?objc.Object, resolved, "path", .{}));
                if (path.len > 0) return a.dupe(u8, path) catch null;
            }
        }
    }
    if (abs.len == 0) return null;
    return a.dupe(u8, abs) catch null;
}

/// Extracts dropped URLs / resolved local file paths from an AppKit
/// NSPasteboard for one frame.
pub fn readPasteboardUrls(a: std.mem.Allocator, pb: objc.Object) [][]const u8 {
    const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    var urls: std.ArrayList([]const u8) = .empty;
    if (objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, @as(?objc.Object, null) })) |arr| {
        const n = objc.msg(objc.NSUInteger, arr, "count", .{});
        for (0..n) |i| {
            const url = objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            const str = serializeDroppedUrl(a, url) orelse continue;
            urls.append(a, str) catch {};
        }
    }
    return urls.items;
}

/// The drop: its links (files as file URLs) and text, for one frame.
pub fn performDragOperation(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.BOOL {
    const s = surfaceOf(obj) orelse return objc.NO;
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const p = dragPoint(s, info);
    const pb = objc.msg(objc.Object, info, "draggingPasteboard", .{});
    const urls = readPasteboardUrls(a, pb);
    const text = a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")}))) catch "";
    s.ctx.input.drag_over = null;
    s.ctx.input.drop = .{ .point = p, .urls = urls, .text = text };
    const tok = s.token();
    s.frame();
    if (!Surface.alive(tok)) return objc.NO;
    s.ctx.input.drop = null;
    return if (s.ctx.acceptsDropAt(p)) objc.YES else objc.NO;
}

test "readPasteboardUrls resolves local file-reference NSURLs and preserves remote or unresolved URLs" {
    const testing = std.testing;
    const pool = objc.Pool.push();
    defer pool.pop();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sample #✓.txt", .data = "synthetic" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "deleted.txt", .data = "gone" });
    const rel_valid = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/sample #✓.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_valid);
    const abs_valid = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel_valid, testing.allocator);
    defer testing.allocator.free(abs_valid);
    const rel_deleted = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/deleted.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_deleted);
    const abs_deleted = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel_deleted, testing.allocator);
    defer testing.allocator.free(abs_deleted);

    const valid_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(abs_valid)});
    const valid_ref = objc.msg(?objc.Object, valid_url, "fileReferenceURL", .{}) orelse return error.MissingFileReferenceUrl;
    const deleted_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(abs_deleted)});
    const deleted_ref = objc.msg(?objc.Object, deleted_url, "fileReferenceURL", .{}) orelse return error.MissingFileReferenceUrl;
    try tmp.dir.deleteFile(testing.io, "deleted.txt");

    const remote_file = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString("file://remote/tmp/a.png")}) orelse return error.InvalidUrl;
    const web_url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString("https://example.invalid/a.png")}) orelse return error.InvalidUrl;

    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    defer objc.msg(void, pb, "releaseGlobally", .{});
    const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, 4)});
    objc.msg(void, list, "addObject:", .{valid_ref});
    objc.msg(void, list, "addObject:", .{deleted_ref});
    objc.msg(void, list, "addObject:", .{remote_file});
    objc.msg(void, list, "addObject:", .{web_url});
    try testing.expect(objc.msg(objc.BOOL, pb, "writeObjects:", .{list}));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const urls = readPasteboardUrls(arena.allocator(), pb);
    try testing.expectEqual(@as(usize, 4), urls.len);
    try testing.expectEqualStrings(abs_valid, urls[0]);
    try testing.expect(std.mem.startsWith(u8, urls[1], "file:///.file/id="));
    try testing.expectEqualStrings("file://remote/tmp/a.png", urls[2]);
    try testing.expectEqualStrings("https://example.invalid/a.png", urls[3]);
}
