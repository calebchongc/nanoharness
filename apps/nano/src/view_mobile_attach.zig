//! The composer's attach button and staged pictures. The button opens
//! Photo Library (iOS), Files, and Paste Image when the clipboard holds
//! one; each picture is staged by the Swift app's rules (mobile_attach.zig:
//! png / jpg / gif / webp kept, others re-encoded as JPEG, 24 MB at most)
//! and uploads through the app's own host-routed transport
//! (app_attachments.zig: UploadChunk / UploadCommit to the chat's
//! computer), so a send carries the same "Attached images" trailer the
//! desktop's does. Staged pictures show above the composer with remove,
//! and retry when an upload failed.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const mg = @import("mobile_glass.zig");
const ma = @import("mobile_attach.zig");
const photos = @import("ios_photos.zig");
const attachments = @import("app_attachments.zig");
const Text = @import("app_mobile_auth.zig").Text;

pub const State = struct {
    menu: bool = false,
    err: Text(160) = .{},
};

/// The menu's rows, as offered here.
pub const Choice = enum { photo_library, files, paste_image };

pub fn choices(buf: *[3]Choice, photos_available: bool, clipboard_image: bool) []const Choice {
    var n: usize = 0;
    if (photos_available) {
        buf[n] = .photo_library;
        n += 1;
    }
    buf[n] = .files;
    n += 1;
    if (clipboard_image) {
        buf[n] = .paste_image;
        n += 1;
    }
    return buf[0..n];
}

pub fn label(ch: Choice) []const u8 {
    return switch (ch) {
        .photo_library => "Photo Library",
        .files => "Files",
        .paste_image => "Paste Image",
    };
}

fn icon(ch: Choice) icons.Name {
    return switch (ch) {
        .photo_library => .@"file-image",
        .files => .document,
        .paste_image => .copy,
    };
}

/// Each frame: pictures the photo library delivered are staged.
pub fn poll(a: *App) void {
    var batch = photos.take() orelse return;
    defer batch.deinit();
    var failed = batch.failed;
    for (batch.images.items) |bytes| {
        if (!stageImage(a, bytes)) failed += 1;
    }
    report(a, failed);
}

fn report(a: *App, failed: usize) void {
    var b: [160]u8 = undefined;
    if (ma.failureMessage(&b, failed)) |m| a.mobile.attach.err.set(m) else a.mobile.attach.err.clear();
    a.redraw();
}

/// Stages one picture already prepared (`ios_photos.prepare`): named as the
/// Swift app names it, uploaded to the chat's computer.
pub fn stageImage(a: *App, bytes: []const u8) bool {
    const ext = ma.sniff(bytes) orelse return false;
    var idb: [36]u8 = undefined;
    const id = @import("ids.zig").uuid(a.io, &idb);
    var nb: [48]u8 = undefined;
    attachments.stage(a, ma.stagedName(&nb, id, ext), bytes) catch return false;
    return true;
}

/// HEIC and the like become JPEG on iOS; off iOS there is no system
/// decoder, so only the formats that upload as they are.
const transcode = photos.transcodeJpeg;

fn pickFiles(a: *App) void {
    if (a.offscreen) return;
    const paths = (nanoui.dialog.open(a.gpa, .{ .title = "Attach photos", .button = "Attach", .multiple = true, .extensions = if (photos.available) &.{ "png", "jpg", "jpeg", "gif", "webp", "heic", "heif" } else &.{ "png", "jpg", "jpeg", "gif", "webp" } }) catch return) orelse return;
    defer nanoui.dialog.freePaths(a.gpa, paths);
    var failed: usize = 0;
    for (paths) |path| {
        const raw = std.Io.Dir.cwd().readFileAlloc(a.io, path, a.gpa, .limited(ma.max_bytes + 1)) catch {
            failed += 1;
            continue;
        };
        defer a.gpa.free(raw);
        const ready = photos.prepare(raw, transcode) orelse {
            failed += 1;
            continue;
        };
        defer std.heap.c_allocator.free(ready);
        if (!stageImage(a, ready)) failed += 1;
    }
    report(a, failed);
}

fn pasteImage(a: *App) void {
    if (a.offscreen) return;
    const png = (nanoui.clipboard.readImage(a.gpa) catch null) orelse {
        a.mobile.attach.err.set("The clipboard has no image.");
        return a.redraw();
    };
    defer a.gpa.free(png);
    const ready = photos.prepare(png, transcode) orelse return report(a, 1);
    defer std.heap.c_allocator.free(ready);
    report(a, if (stageImage(a, ready)) 0 else 1);
}

fn choose(a: *App, ch: Choice) void {
    a.mobile.attach.menu = false;
    a.mobile.attach.err.clear();
    switch (ch) {
        .photo_library => if (!photos.open()) a.mobile.attach.err.set("Couldn't open the photo library."),
        .files => pickFiles(a),
        .paste_image => pasteImage(a),
    }
}

/// The `+` in the composer ("Attach photos").
pub fn button(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    if (mg.circleButton(c, "ios-composer-attach", .composer_attach_circle, .plus, k.text, rt, if (a.mobile.attach.menu) k.accent.alpha(0.18) else null).clicked) {
        a.mobile.attach.menu = !a.mobile.attach.menu;
    }
}

/// The menu (above the composer) and the staged pictures; drawn in the
/// bottom stack before the composer.
pub fn above(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    poll(a);
    if (a.mobile.attach.menu) {
        ui.key(c, "ios-attach-menu");
        const m = mg.styleGlassDiv(c, ui.div(c).column().w(220).p(6).gap(2), .org_picker_row, rt, ui.Color.transparent, null);
        defer m.end();
        var buf: [3]Choice = undefined;
        for (choices(&buf, photos.available, photos.clipboardHasImage())) |ch| {
            ui.keyInt(c, 0x6174_7400 + @as(u64, @intFromEnum(ch)));
            const r = ui.div(c).row().wFull().h(44).px(12).gap(10).itemsCenter().rounded(12).control();
            defer r.end();
            icons.icon(c, icon(ch), 16, k.text, 0);
            ui.text(c, label(ch), .{ .size = 15, .color = k.text });
            if (r.clicked()) choose(a, ch);
        }
    }
    if (!a.mobile.attach.err.empty()) {
        ui.text(c, a.mobile.attach.err.get(), .{ .size = 12.5, .wrap = true, .color = k.danger });
    }
    if (attachments.count(a) == 0) return;
    ui.key(c, "ios-attach-strip");
    const st: ui.Style = .{ .width = .fill, .height = .{ .px = 64 }, .direction = .row, .align_items = .center, .gap = 8, .scroll_x = true, .scroll_bar = false, .clip = true };
    _ = c.open(st, null);
    defer ui.end(c);
    for (a.attachments.items.items) |item| if (item.active(a)) {
        ui.key(c, &item.id);
        const tile = ui.div(c).row().size(56, 56).center().rounded(12).border(if (item.status == .failed) k.danger else k.border).borderW(1).bg(k.raised).clip().control();
        defer tile.end();
        @import("view_composer_attachments.zig").picture(c, k, &item.id, item.name, item.preview());
        if (item.status == .uploading or item.status == .staged) {
            const s = ui.div(c).row().absolute().offset(4, 36).size(16, 16).center();
            defer s.end();
            kit.spinner(c, .{ .size = 14, .color = k.muted });
        } else if (item.status == .failed) {
            const s = ui.div(c).row().absolute().offset(18, 18).size(20, 20).center().roundedFull().bg(k.card);
            defer s.end();
            icons.icon(c, .refresh, 13, k.danger, 0);
        }
        if (item.status == .failed and tile.clicked()) item.start();
        const rm = ui.div(c).row().absolute().offset(36, 2).size(18, 18).center().roundedFull().bg(k.card.alpha(0.9)).control();
        defer rm.end();
        icons.icon(c, .close, 10, k.text, 0);
        if (rm.clicked()) {
            item.remove();
            c.changed = true;
        }
    };
}

const testing = std.testing;

test "the attach menu offers the photo library on iOS, files always, paste only with an image" {
    var buf: [3]Choice = undefined;
    const ios = choices(&buf, true, false);
    try testing.expectEqual(@as(usize, 2), ios.len);
    try testing.expectEqual(Choice.photo_library, ios[0]);
    try testing.expectEqual(Choice.files, ios[1]);
    const mac = choices(&buf, false, true);
    try testing.expectEqual(Choice.files, mac[0]);
    try testing.expectEqual(Choice.paste_image, mac[1]);
    try testing.expectEqualStrings("Paste Image", label(.paste_image));
}

test "a picked picture is staged under the Swift name, uploads to the chat's computer, and rides the send" {
    theme.registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.mobile_preview = true;
    a.new_harness = try testing.allocator.dupe(u8, "graff");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"AuthStatus":{"$items":[{"state":"signedIn","user":{"id":"u","email":"sam@example.com","name":null}}]},
        \\ "UploadChunk":{"ok":true},"UploadCommit":{"path":"/uploads/photo-synthetic.png"},"QueueCommand":{"ok":true}}
    , .{});
    a.engine.state = .connected;
    a.selected = try testing.allocator.dupe(u8, "chat-a");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view_mobile.zig").view), .{ .width = 402, .height = 874 });
    defer t.deinit();
    t.frame();
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0 };
    try testing.expect(stageImage(&a, &png));
    const heic = "\x00\x00\x00\x18ftypheic";
    try testing.expect(!stageImage(&a, heic));
    for (0..6) |_| t.frame();
    try testing.expectEqual(@as(usize, 1), attachments.count(&a));
    const item = a.attachments.items.items[0];
    try testing.expect(std.mem.startsWith(u8, item.name, "photo-") and std.mem.endsWith(u8, item.name, ".png"));
    try testing.expectEqual(.ready, item.status);
    report(&a, 1);
    t.frame();
    try testing.expect(t.hasText("One image couldn't be attached (unsupported or over 24 MB)."));
    a.send();
    for (0..3) |_| t.frame();
    var trailer = false;
    for (a.engine.sent.items) |f| if (std.mem.indexOf(u8, f, "Attached images") != null and std.mem.indexOf(u8, f, "/uploads/photo-synthetic.png") != null) {
        trailer = true;
    };
    try testing.expect(trailer);
}
