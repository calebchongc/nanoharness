//! The image preview's state (docs/image-preview.md): the images of the
//! chat it was opened from, in transcript order, the one shown, its zoom
//! and pan, and how its bytes arrive. Sent attachments and agents' images
//! use the host-jailed attachment read-back (`app_attachment_images.zig`);
//! files in the chat's checkout go through `ReadWorkspaceImage` only, in
//! checked chunks, never the UI's own filesystem.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const rpc = @import("rpc.zig");
const App = @import("app.zig").App;
const rules = @import("image_preview_rules.zig");
const attachments = @import("app_attachments.zig");
const images = @import("app_attachment_images.zig");
const refs = @import("attachment_refs.zig");
const Allocator = std.mem.Allocator;

pub const Source = union(enum) {
    /// A sent attachment or an agent's published image, by its host.
    attachment: struct { device: []u8, path: []u8 },
    /// A file in a chat's checkout (Files, the changes pane, a tool's file).
    workspace: struct { chat: []u8, path: []u8, device: ?[]u8 },
    /// A composer attachment, not sent yet.
    staged: [36]u8,
};

pub const Entry = struct {
    source: Source,
    name: []u8,

    fn deinit(e: Entry, a: *App) void {
        switch (e.source) {
            .attachment => |s| {
                a.retireSlice(s.device);
                a.retireSlice(s.path);
            },
            .workspace => |s| {
                a.retireSlice(s.chat);
                a.retireSlice(s.path);
                if (s.device) |d| a.retireSlice(d);
            },
            .staged => {},
        }
        a.retireSlice(e.name);
    }
};

/// Where it was opened from: Done in annotate replaces a composer
/// attachment, else stages a new one.
pub const Origin = enum { chat, composer, files };

/// A workspace image's transfer.
pub const Load = struct {
    app: *App = undefined,
    status: enum { idle, loading, ready, failed } = .idle,
    message: []const u8 = "",
    /// The engine's own words for a failure, kept for the surface.
    message_buf: [300]u8 = undefined,
    request: ?u64 = null,
    checkout: std.ArrayList(u8) = .empty,
    transfer: rules.Transfer = .{},
    encoded: std.ArrayList(u8) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    started: f64 = 0,
    /// Which entry it is for; a reply for another is dropped.
    generation: u64 = 0,

    fn deinit(l: *Load, gpa: Allocator) void {
        l.checkout.deinit(gpa);
        l.encoded.deinit(gpa);
        l.bytes.deinit(gpa);
    }
};

/// Copies go here; tests and scenes give their own (never the system's).
pub const CopySink = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (?*anyopaque, []const u8) bool,
};

pub const State = struct {
    open: bool = false,
    origin: Origin = .chat,
    entries: std.ArrayList(Entry) = .empty,
    index: usize = 0,
    zoom: rules.Zoom = .{},
    /// A drag under way: where it began, and the pan then.
    drag: ?struct { from: rules.Point, pan: rules.Point, moved: bool = false } = null,
    load: Load = .{},
    /// "Copied", or why not, for a moment.
    notice: []const u8 = "",
    notice_until: f64 = 0,
    copy_sink: ?CopySink = null,
    /// The bytes of the frame before last, still borrowed by a drawn image.
    retired_bytes: std.ArrayList(std.ArrayList(u8)) = .empty,
    /// Annotate, while it's on (view_annotate.zig).
    editor: ?@import("app_annotate.zig").Editor = null,
    generation: u64 = 0,

    pub fn deinit(s: *State, a: *App) void {
        for (s.entries.items) |e| e.deinit(a);
        s.entries.deinit(a.gpa);
        s.load.deinit(a.gpa);
        for (s.retired_bytes.items) |*b| b.deinit(a.gpa);
        s.retired_bytes.deinit(a.gpa);
        if (s.editor) |*ed| ed.deinit(a.gpa);
    }
};

fn st(a: *App) *State {
    return &a.ui_gaps.preview;
}

pub fn isOpen(a: *const App) bool {
    return a.ui_gaps.preview.open;
}

pub fn current(a: *App) ?*Entry {
    const s = st(a);
    if (!s.open or s.index >= s.entries.items.len) return null;
    return &s.entries.items[s.index];
}

fn clearEntries(a: *App) void {
    const s = st(a);
    for (s.entries.items) |e| e.deinit(a);
    s.entries.clearRetainingCapacity();
}

fn begin(a: *App, origin: Origin) void {
    const s = st(a);
    clearEntries(a);
    s.origin = origin;
    s.index = 0;
    s.zoom = .{};
    s.drag = null;
    s.notice = "";
    if (s.editor) |*ed| ed.deinit(a.gpa);
    s.editor = null;
}

fn show(a: *App) void {
    const s = st(a);
    if (s.entries.items.len == 0) return;
    s.open = true;
    selectIndex(a, @min(s.index, s.entries.items.len - 1));
}

/// The transcript a chat shows: the open one's, or a split pane's.
fn transcriptOf(a: *App, chat_id: []const u8) ?*@import("transcript.zig").Transcript {
    if (a.selected) |id| if (std.mem.eql(u8, id, chat_id)) return &a.transcript;
    for (a.peers.items) |*p| if (std.mem.eql(u8, p.id, chat_id)) return &p.transcript;
    return null;
}

/// Every image the chat shows, in transcript order: each prompt's
/// attachments, then each agent image.
pub fn collect(gpa: Allocator, t: *const @import("transcript.zig").Transcript, out: *std.ArrayList([]const u8)) !void {
    for (t.entries.items) |*e| for (e.parts.items) |*p| switch (p.kind) {
        .text => if (e.role == .user) {
            const parsed = refs.parse(gpa, p.text.items) catch continue;
            defer refs.deinit(gpa, parsed);
            for (parsed.paths) |path| if (attachments.isImageName(path)) {
                // Borrowed from the transcript, which outlives the call.
                const at = std.mem.indexOf(u8, p.text.items, path) orelse continue;
                try out.append(gpa, p.text.items[at .. at + path.len]);
            };
        },
        .image => if (p.path.len > 0) try out.append(gpa, p.path),
        else => {},
    };
}

fn addAttachment(a: *App, device: []const u8, path: []const u8) !void {
    const dev = try a.gpa.dupe(u8, device);
    errdefer a.gpa.free(dev);
    const ref = try a.gpa.dupe(u8, path);
    errdefer a.gpa.free(ref);
    const name = try a.gpa.dupe(u8, attachments.displayName(path));
    errdefer a.gpa.free(name);
    try st(a).entries.append(a.gpa, .{ .source = .{ .attachment = .{ .device = dev, .path = ref } }, .name = name });
}

/// A sent attachment or agent image clicked in `chat_id`'s transcript:
/// the chat's images, that one shown.
pub fn openFromTranscript(a: *App, chat_id: ?[]const u8, path: []const u8) void {
    const id = chat_id orelse return;
    const chat = a.findChat(id) orelse return;
    const device = chat.device_id orelse return;
    begin(a, .chat);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(a.gpa);
    if (transcriptOf(a, id)) |t| collect(a.gpa, t, &paths) catch {};
    var found = false;
    for (paths.items) |p| {
        if (!found and std.mem.eql(u8, p, path)) {
            st(a).index = st(a).entries.items.len;
            found = true;
        }
        addAttachment(a, device, p) catch return;
    }
    if (!found) {
        st(a).index = st(a).entries.items.len;
        addAttachment(a, device, path) catch return;
    }
    show(a);
}

/// A composer thumbnail clicked: the draft's images, that one shown.
pub fn openStaged(a: *App, item: *const attachments.Item) void {
    begin(a, .composer);
    for (a.attachments.items.items) |it| if (it.active(a) and attachments.isImageName(it.name)) {
        if (it == item) st(a).index = st(a).entries.items.len;
        const name = a.gpa.dupe(u8, it.name) catch return;
        st(a).entries.append(a.gpa, .{ .source = .{ .staged = it.id }, .name = name }) catch {
            a.gpa.free(name);
            return;
        };
    };
    show(a);
}

/// A file in the open chat's checkout: shown when it's an image (true).
pub fn openWorkspace(a: *App, path: []const u8) bool {
    if (!attachments.isImageName(path)) return false;
    const chat_id = a.selected orelse return false;
    begin(a, .files);
    const chat = a.gpa.dupe(u8, chat_id) catch return false;
    const ref = a.gpa.dupe(u8, path) catch {
        a.gpa.free(chat);
        return false;
    };
    const host = if (a.findChat(chat_id)) |ch| ch.device_id else null;
    const remote = if (host) |h| (if (a.device_id) |mine| !std.mem.eql(u8, h, mine) else true) else false;
    const device: ?[]u8 = if (remote) a.gpa.dupe(u8, host.?) catch null else null;
    const name = a.gpa.dupe(u8, std.fs.path.basename(path)) catch {
        a.gpa.free(chat);
        a.gpa.free(ref);
        return false;
    };
    st(a).entries.append(a.gpa, .{ .source = .{ .workspace = .{ .chat = chat, .path = ref, .device = device } }, .name = name }) catch return false;
    show(a);
    return true;
}

pub fn close(a: *App) void {
    const s = st(a);
    if (!s.open) return;
    if (s.load.request) |id| a.engine.cancel(id);
    s.load.request = null;
    s.open = false;
    if (s.editor) |*ed| ed.deinit(a.gpa);
    s.editor = null;
    clearEntries(a);
    // Escape or a click restores the keys to the composer.
    a.view.focus_composer = true;
    a.redraw();
}

pub fn stepBy(a: *App, forward: bool) void {
    const s = st(a);
    if (s.editor != null) return;
    const to = rules.step(s.index, s.entries.items.len, forward) orelse return;
    selectIndex(a, to);
}

fn selectIndex(a: *App, ix: usize) void {
    const s = st(a);
    s.index = ix;
    s.zoom = .{};
    s.drag = null;
    s.generation +%= 1;
    if (s.load.request) |id| a.engine.cancel(id);
    s.load.request = null;
    retireLoadBytes(a);
    s.load.status = .idle;
    if (current(a)) |e| if (e.source == .workspace) startWorkspace(a);
    a.redraw();
}

/// The loaded bytes may still be in a drawn frame: kept one more frame.
fn retireLoadBytes(a: *App) void {
    const s = st(a);
    if (s.load.bytes.items.len > 0) {
        s.retired_bytes.append(a.gpa, s.load.bytes) catch s.load.bytes.deinit(a.gpa);
        s.load.bytes = .empty;
    }
    s.load.encoded.clearAndFree(a.gpa);
    s.load.checkout.clearRetainingCapacity();
    s.load.transfer = .{};
}

/// At each frame's start: bytes no frame borrows any more go, a read past
/// its deadline fails, a notice past its time clears.
pub fn settleFrame(a: *App) void {
    const s = st(a);
    // Retired during the frame before; nothing drawn borrows them now.
    for (s.retired_bytes.items) |*b| b.deinit(a.gpa);
    s.retired_bytes.clearRetainingCapacity();
    if (s.load.status == .loading and a.now - s.load.started > rules.read_deadline_s) {
        fail(a, "The image took too long to load.");
    }
    if (s.notice.len > 0 and a.now >= s.notice_until) s.notice = "";
}

fn startWorkspace(a: *App) void {
    const s = st(a);
    const e = current(a) orelse return;
    const w = e.source.workspace;
    s.load.app = a;
    s.load.status = .loading;
    s.load.message = "";
    s.load.started = a.now;
    s.load.generation = s.generation;
    if (!a.engine.up()) return fail(a, "Not connected to the engine.");
    // A checkout id first: the read refuses an empty one.
    s.load.request = a.send_(.{ .method = "ReadWorkspaceFile", .params = .{ .chatId = w.chat, .path = w.path, .targetDeviceId = w.device } }, .of(Load, &s.load, onCheckout));
    if (s.load.request == null) fail(a, "The image couldn't be requested.");
}

fn fail(a: *App, why: []const u8) void {
    const s = st(a);
    if (s.load.request) |id| a.engine.cancel(id);
    s.load.request = null;
    s.load.status = .failed;
    s.load.message = why;
    retireLoadBytes(a);
    a.redraw();
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn uint(o: std.json.ObjectMap, key: []const u8) ?usize {
    const v = o.get(key) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}

/// The engine's own words for a failure, kept for the surface.
fn errText(a: *App, why: []const u8) []const u8 {
    const l = &st(a).load;
    const n = @min(why.len, l.message_buf.len);
    @memcpy(l.message_buf[0..n], why[0..n]);
    return l.message_buf[0..n];
}

fn onCheckout(l: *Load, id: u64, r: rpc.Reply) void {
    const a = l.app;
    if (l.request != id) return;
    l.request = null;
    const v = switch (r) {
        .ok => |v| v,
        .err => |why| {
            const msg = errText(a, why);
            st(a).load.status = .failed;
            st(a).load.message = msg;
            return a.redraw();
        },
        else => return,
    };
    const checkout = if (v == .object) str(v.object, "checkoutId") else null;
    if (checkout == null or checkout.?.len == 0) return fail(a, "This file's checkout couldn't be identified.");
    l.checkout.appendSlice(a.gpa, checkout.?) catch return fail(a, "Out of memory.");
    next(a);
}

fn next(a: *App) void {
    const s = st(a);
    const e = current(a) orelse return;
    const w = e.source.workspace;
    const hash: ?[]const u8 = if (s.load.transfer.started) s.load.transfer.hash[0..s.load.transfer.hash_len] else null;
    s.load.request = a.send_(.{ .method = "ReadWorkspaceImage", .params = .{
        .chatId = w.chat,
        .path = w.path,
        .expectedCheckoutId = s.load.checkout.items,
        .offset = s.load.transfer.offset,
        .expectedContentHash = hash,
        .targetDeviceId = w.device,
    } }, .of(Load, &s.load, onChunk));
    if (s.load.request == null) fail(a, "The image couldn't be requested.");
}

fn onChunk(l: *Load, id: u64, r: rpc.Reply) void {
    const a = l.app;
    if (l.request != id) return;
    l.request = null;
    const v = switch (r) {
        .ok => |v| v,
        .err => |why| {
            const msg = errText(a, why);
            st(a).load.status = .failed;
            st(a).load.message = msg;
            return a.redraw();
        },
        else => return,
    };
    if (v != .object) return fail(a, "The image couldn't be read.");
    const o = v.object;
    const data = str(o, "data") orelse return fail(a, "The image couldn't be read.");
    const done = if (o.get("done")) |d| d == .bool and d.bool else false;
    rules.acceptChunk(&l.transfer, .{
        .checkout_id = str(o, "checkoutId") orelse "",
        .content_hash = str(o, "contentHash") orelse "",
        .mime_type = str(o, "mimeType") orelse "",
        .data_len = data.len,
        .next_offset = uint(o, "nextOffset") orelse 0,
        .size = uint(o, "size") orelse 0,
        .done = done,
    }) catch |err| return fail(a, rules.chunkMessage(err));
    l.encoded.appendSlice(a.gpa, data) catch return fail(a, "Out of memory.");
    if (!done) return next(a);
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(l.encoded.items) catch return fail(a, "The image couldn't be read.");
    if (size != l.transfer.size) return fail(a, "The image couldn't be read.");
    l.bytes.resize(a.gpa, size) catch return fail(a, "Out of memory.");
    decoder.decode(l.bytes.items, l.encoded.items) catch return fail(a, "The image couldn't be read.");
    l.encoded.clearAndFree(a.gpa);
    l.status = .ready;
    a.redraw();
}

pub const Bytes = union(enum) { loading, failed: []const u8, ready: []const u8 };

/// The shown entry's bytes, or why there are none yet.
pub fn bytesOf(a: *App, e: *const Entry) Bytes {
    switch (e.source) {
        .attachment => |s| {
            const image = images.getDevice(a, s.device, s.path) orelse
                return if (a.engine.up()) .{ .failed = "This image isn't available." } else .loading;
            return switch (image.status) {
                .loading => .loading,
                .failed => .{ .failed = "The image couldn't be loaded from its device." },
                .ready => .{ .ready = image.bytes.items },
            };
        },
        .staged => |id| {
            for (a.attachments.items.items) |it| if (std.mem.eql(u8, &it.id, &id) and !it.removed) {
                const b = it.preview();
                return if (b.len > 0) .{ .ready = b } else .loading;
            };
            return .{ .failed = "This attachment was removed." };
        },
        .workspace => {
            const l = &st(a).load;
            return switch (l.status) {
                .idle, .loading => .loading,
                .failed => .{ .failed = l.message },
                .ready => .{ .ready = l.bytes.items },
            };
        },
    }
}

/// A local checkout file's full path, for Reveal in Finder; null where the
/// file isn't on this computer (another device, an attachment's store).
pub fn localPath(a: *App, e: *const Entry, buf: []u8) ?[]const u8 {
    const w = switch (e.source) {
        .workspace => |w| w,
        else => return null,
    };
    if (w.device != null) return null;
    const chat = a.findChat(w.chat) orelse return null;
    const cwd = chat.cwd orelse return null;
    if (cwd.len == 0 or cwd[0] != '/') return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, cwd, "/"), w.path }) catch null;
}

pub fn reveal(a: *App) void {
    const e = current(a) orelse return;
    var buf: [4096]u8 = undefined;
    const path = localPath(a, e, &buf) orelse return;
    if (a.offscreen) return note(a, "Shown in Finder");
    if (comptime builtin.os.tag == .macos) nanoui.shell.showInFolder(path);
}

fn note(a: *App, text: []const u8) void {
    const s = st(a);
    s.notice = text;
    s.notice_until = a.now + 1.6;
    a.redraw();
}

/// Copies the picture shown (its own bytes, as an image).
pub fn copy(a: *App) void {
    const e = current(a) orelse return;
    const b = switch (bytesOf(a, e)) {
        .ready => |b| b,
        else => return,
    };
    const ok = if (st(a).copy_sink) |sink| sink.write(sink.ctx, b) else if (a.offscreen) true else systemCopy(b);
    note(a, if (ok) "Copied" else "Couldn't copy the image");
}

fn systemCopy(bytes: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) });
    const alloc = objc.msg(objc.Object, objc.class("NSImage"), "alloc", .{});
    const image = objc.msg(?objc.Object, alloc, "initWithData:", .{data}) orelse return false;
    defer objc.msg(void, image, "release", .{});
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    const arr = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{image});
    return objc.msg(objc.BOOL, pb, "writeObjects:", .{arr});
}

const testing = std.testing;

test "a chat's images are collected in transcript order, attachments and agent images alike" {
    const gpa = testing.allocator;
    var t: @import("transcript.zig").Transcript = .{ .gpa = gpa };
    defer t.deinit();
    const doc =
        \\{"reset":[
        \\ {"id":"u1","role":"user","parts":[{"id":"p1","kind":"text","text":"look\n\nAttached images (local files — open them to view):\n- /up/a.png\n- /up/notes.txt"}]},
        \\ {"id":"a1","role":"assistant","parts":[{"id":"p2","kind":"image","name":"chart.png","path":"/up/chart.png"}]},
        \\ {"id":"u2","role":"user","parts":[{"id":"p3","kind":"text","text":"and\n\nAttached images (local files — open them to view):\n- /up/b.jpg"}]}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, doc, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    try collect(gpa, &t, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("/up/a.png", out.items[0]);
    try testing.expectEqualStrings("/up/chart.png", out.items[1]);
    try testing.expectEqualStrings("/up/b.jpg", out.items[2]);
}
