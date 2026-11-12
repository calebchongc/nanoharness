//! The phone's attachment rules (Composer/Attachments.swift
//! `StagedAttachment`, ThemedPhotosPicker.swift): pictures only, png / jpg /
//! gif / webp kept as they are and anything else a decoder reads turned into
//! JPEG, 24 MB at most, eight per pick, named `photo-<id8>.<ext>`, and the
//! line shown for the ones that couldn't be attached. Pure.
const std = @import("std");

/// `maxAttachmentBytes` (the desktop's `max_bytes` too).
pub const max_bytes: usize = 24 * 1024 * 1024;
/// The photo picker's `maxSelectionCount`.
pub const max_pick: usize = 8;

pub const Ext = enum {
    png,
    jpg,
    gif,
    webp,

    pub fn name(e: Ext) []const u8 {
        return @tagName(e);
    }
};

/// `sniffExtension`: magic bytes for the formats both ends serve.
pub fn sniff(data: []const u8) ?Ext {
    if (data.len < 12) return null;
    const b = data[0..12];
    if (b[0] == 0x89 and b[1] == 0x50 and b[2] == 0x4E and b[3] == 0x47) return .png;
    if (b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF) return .jpg;
    if (b[0] == 0x47 and b[1] == 0x49 and b[2] == 0x46 and b[3] == 0x38) return .gif;
    if (b[0] == 0x52 and b[1] == 0x49 and b[2] == 0x46 and b[3] == 0x46 and
        b[8] == 0x57 and b[9] == 0x45 and b[10] == 0x42 and b[11] == 0x50) return .webp;
    return null;
}

/// What staging does with picked bytes.
pub const Plan = union(enum) {
    /// Upload as they are, with this extension.
    keep: Ext,
    /// Decode and re-encode as JPEG (HEIC camera shots, mainly), then check again.
    transcode,
    /// Over 24 MB: not attached.
    too_large,
};

pub fn plan(data: []const u8) Plan {
    if (data.len > max_bytes) return .too_large;
    if (sniff(data)) |e| return .{ .keep = e };
    return .transcode;
}

/// `photo-<first 8 of the id>.<ext>`.
pub fn stagedName(buf: []u8, id: []const u8, ext: Ext) []const u8 {
    return std.fmt.bufPrint(buf, "photo-{s}.{s}", .{ id[0..@min(8, id.len)], ext.name() }) catch "photo.jpg";
}

/// `failureMessage`: nil when all were attached.
pub fn failureMessage(buf: []u8, failed: usize) ?[]const u8 {
    return switch (failed) {
        0 => null,
        1 => "One image couldn't be attached (unsupported or over 24 MB).",
        else => std.fmt.bufPrint(buf, "{d} images couldn't be attached (unsupported or over 24 MB).", .{failed}) catch null,
    };
}

const testing = std.testing;

test "attachments: sniffed formats stay, others transcode, 24 MB at most" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0 };
    const jpg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const gif = "GIF89a\x00\x00\x00\x00\x00\x00";
    const webp = "RIFF\x00\x00\x00\x00WEBP";
    const heic = "\x00\x00\x00\x18ftypheic";
    try testing.expectEqual(Ext.png, sniff(&png).?);
    try testing.expectEqual(Ext.jpg, sniff(&jpg).?);
    try testing.expectEqual(Ext.gif, sniff(gif).?);
    try testing.expectEqual(Ext.webp, sniff(webp).?);
    try testing.expect(sniff(heic) == null);
    try testing.expect(sniff("short") == null);
    try testing.expectEqual(Ext.png, plan(&png).keep);
    try testing.expect(plan(heic) == .transcode);

    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("photo-1a2b3c4d.webp", stagedName(&b, "1a2b3c4d-5e6f", .webp));
    try testing.expect(failureMessage(&b, 0) == null);
    try testing.expectEqualStrings("One image couldn't be attached (unsupported or over 24 MB).", failureMessage(&b, 1).?);
    try testing.expectEqualStrings("3 images couldn't be attached (unsupported or over 24 MB).", failureMessage(&b, 3).?);
}

test "attachments: an oversized pick is refused before anything is decoded" {
    const big = try testing.allocator.alloc(u8, max_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 0);
    big[0] = 0x89;
    try testing.expect(plan(big) == .too_large);
}
