//! `ShowImage` (and the chat checks `ShowVisual` shares): publish a workspace
//! raster image into a chat's live run (`crates/engine/src/rpc.rs`,
//! `SessionManager::show_image`, `Uploads::import_generated_image`).
//!
//! Only this device's chats, only while the chat's run is live: the doc's
//! streaming assistant message is the run, and the image becomes an `image`
//! part on it (`MessagePart::Image {id, path, name, mimeType}`). The file must
//! resolve inside the run's folder, be at most 24 MiB, and start with a PNG,
//! JPEG, WebP or GIF signature; it is copied into `<data dir>/uploads` under a
//! name derived from the chat, run and request id, so a retried request
//! publishes once. The original path never reaches the transcript.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const engine_host = @import("../engine_host.zig");
const session_doc = @import("../session_doc.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

pub const attach_error = "show_image could not attach the file; use a supported raster image inside the active workspace (maximum 24 MiB)";
pub const max_image_bytes: u64 = 24 * 1024 * 1024;

pub const Raster = struct { ext: []const u8, mime: []const u8 };

pub fn rasterSignature(bytes: []const u8) ?Raster {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .{ .ext = "png", .mime = "image/png" };
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .{ .ext = "jpg", .mime = "image/jpeg" };
    if (std.mem.startsWith(u8, bytes, "RIFF") and bytes.len >= 12 and std.mem.eql(u8, bytes[8..12], "WEBP")) return .{ .ext = "webp", .mime = "image/webp" };
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .{ .ext = "gif", .mime = "image/gif" };
    return null;
}

/// ASCII letters, digits, `-` and `_`; 1 to 128 bytes.
pub fn validRequestId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn bad(msg: []const u8) RpcOutcome {
    return .{ .err = .{ .bad_params = msg } };
}

fn failed(msg: []const u8) RpcOutcome {
    return .{ .err = .{ .exec_error = msg } };
}

/// serde `deny_unknown_fields` + required strings: the message for the first problem.
pub fn checkFields(obj: json.ObjectMap, required: []const []const u8, optional: []const []const u8) ?[]const u8 {
    var it = obj.iterator();
    while (it.next()) |e| {
        var known = false;
        for (required) |r| {
            if (std.mem.eql(u8, r, e.key_ptr.*)) known = true;
        }
        for (optional) |o| {
            if (std.mem.eql(u8, o, e.key_ptr.*)) known = true;
        }
        if (!known) return "unknown field";
    }
    for (required) |r| {
        const v = obj.get(r) orelse return @import("../rpcw_common.zig").errText("missing field `{s}`", .{r});
        if (v != .string) return "invalid type: expected a string";
    }
    for (optional) |o| if (obj.get(o)) |v| if (v != .string and v != .null) return "invalid type: expected a string";
    return null;
}

/// The chat, when it exists on this device; otherwise the reply to return.
pub fn localChat(host: *EngineHost, chat_id: []const u8) union(enum) { ok: *engine_host.ChatRecord, err: RpcOutcome } {
    for (host.chats.items) |*c| {
        if (!std.mem.eql(u8, c.id, chat_id)) continue;
        if (!std.mem.eql(u8, c.device_id, host.device_id)) return .{ .err = bad("chat belongs to another device") };
        return .{ .ok = c };
    }
    return .{ .err = bad("chat not found") };
}

/// The live run: the chat's newest streaming assistant message.
pub fn activeRunMessage(doc: *const session_doc.SessionDoc) ?[]const u8 {
    var i = doc.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = doc.messages.items[i];
        if (m.isStreaming() and std.mem.eql(u8, m.role, "assistant")) return m.id;
    }
    return null;
}

/// The folder the run works in: the chat's folder, else its space's.
pub fn runCwd(host: *EngineHost, chat: *const engine_host.ChatRecord) ?[]const u8 {
    if (chat.cwd) |c| if (c.len > 0) return c;
    const sid = chat.space_id orelse return null;
    for (host.spaces.items) |s| if (std.mem.eql(u8, s.id, sid)) return s.path;
    return null;
}

pub fn findPart(doc: *session_doc.SessionDoc, msg_id: []const u8, part_id: []const u8) ?*session_doc.PartItem {
    const mi = doc.findMessageIdx(msg_id) orelse return null;
    for (doc.messages.items[mi].parts.items) |*p| if (std.mem.eql(u8, p.id, part_id)) return p;
    return null;
}

/// Add a typed part (its fields as one JSON object) to the run's message,
/// push it to watchers and persist the chat.
pub fn attachPart(host: *EngineHost, chat_id: []const u8, doc: *session_doc.SessionDoc, msg_id: []const u8, part_id: []const u8, kind: []const u8, fields_json: []const u8) !void {
    _ = try doc.appendPartDelta(msg_id, part_id, kind, "");
    const part = findPart(doc, msg_id, part_id) orelse return error.PartMissing;
    const copy = try doc.gpa.dupe(u8, fields_json);
    if (part.call_json) |old| {
        doc.live_payload_bytes -|= old.len;
        doc.gpa.free(old);
    }
    part.call_json = copy;
    doc.live_payload_bytes += copy.len;

    const frame = try doc.toUpsertEntryFrameJson(host.gpa, msg_id);
    defer host.gpa.free(frame);
    host.broadcastWatch(.doc_messages, chat_id, frame) catch {};
    const snap = try doc.exportPersisted(host.gpa);
    defer host.gpa.free(snap);
    try host.store.saveSnapshot(chat_id, snap, host.nowMs());
    host.markChatTailDirty(chat_id);
}

// ---------------------------------------------------------------- import

pub const Imported = struct { path: []u8, ext: []const u8, mime: []const u8, size: u64 };

fn under(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return false;
    return root[root.len - 1] == std.fs.path.sep or path[root.len] == std.fs.path.sep;
}

fn sameFile(a: Io.File.Stat, b: Io.File.Stat) bool {
    return a.kind == .file and b.kind == .file and a.inode == b.inode and a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

/// Copy `source` (absolute, resolving inside `root`) into `uploads_dir` as
/// `<sha256(stable_key)>-generated.<ext>`. Any change to the source while it
/// is copied (replacement, growth, a same-size write) rejects the attempt.
pub fn importImage(gpa: Allocator, io: Io, source: []const u8, root_raw: []const u8, uploads_dir: []const u8, stable_key: []const u8) !Imported {
    if (!std.fs.path.isAbsolute(source)) return error.InvalidSource;
    const cwd = Io.Dir.cwd();
    const root = try cwd.realPathFileAlloc(io, root_raw, gpa);
    defer gpa.free(root);
    const canonical = try cwd.realPathFileAlloc(io, source, gpa);
    defer gpa.free(canonical);
    if (!under(canonical, root)) return error.OutsideRoot;

    var input = try cwd.openFile(io, canonical, .{});
    defer input.close(io);
    const before = try input.stat(io);
    if (before.kind != .file or before.size > max_image_bytes) return error.TooLargeOrNotFile;
    var header: [12]u8 = undefined;
    var bufs = [_][]u8{&header};
    const count = input.readStreaming(io, &bufs) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => return e,
    };
    const raster = rasterSignature(header[0..count]) orelse return error.NotRaster;

    try cwd.createDirPath(io, uploads_dir);
    const uploads_root = try cwd.realPathFileAlloc(io, uploads_dir, gpa);
    defer gpa.free(uploads_root);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(stable_key, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const destination = try std.fmt.allocPrint(gpa, "{s}{c}{s}-generated.{s}", .{ uploads_root, std.fs.path.sep, &hex, raster.ext });
    errdefer gpa.free(destination);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const temporary = try std.fmt.allocPrint(gpa, "{s}{c}.{s}.{x}.tmp", .{ uploads_root, std.fs.path.sep, hex[0..16], std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(temporary);
    var out = try cwd.createFile(io, temporary, .{});
    var published = false;
    defer if (!published) cwd.deleteFile(io, temporary) catch {};
    {
        defer out.close(io);
        try out.writeStreamingAll(io, header[0..count]);
        var copied: u64 = count;
        var chunk: [64 * 1024]u8 = undefined;
        while (copied <= max_image_bytes) {
            var cb = [_][]u8{chunk[0..@min(chunk.len, max_image_bytes + 1 - copied)]};
            const n = input.readStreaming(io, &cb) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => return e,
            };
            if (n == 0) break;
            try out.writeStreamingAll(io, chunk[0..n]);
            copied += n;
        }
        const after_handle = try input.stat(io);
        const again = cwd.realPathFileAlloc(io, source, gpa) catch return error.InvalidSource;
        defer gpa.free(again);
        const after_path = try cwd.statFile(io, canonical, .{});
        if (copied != before.size or copied > max_image_bytes) return error.SizeChanged;
        if (!sameFile(before, after_handle) or !std.mem.eql(u8, again, canonical) or !sameFile(before, after_path))
            return error.SourceChanged;
        try out.sync(io);
        try Io.Dir.rename(cwd, temporary, cwd, destination, io);
        published = true;
        return .{ .path = destination, .ext = raster.ext, .mime = raster.mime, .size = copied };
    }
}

// ---------------------------------------------------------------- ShowImage

/// `ShowImage {chatId, id, path, caption?}` → `{attached, id, name, mimeType}`.
pub fn showImage(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (params != .object) return bad("expected object");
    const obj = params.object;
    if (checkFields(obj, &.{ "chatId", "id", "path" }, &.{"caption"})) |m| return bad(m);
    const chat_id = obj.get("chatId").?.string;
    const req_id = obj.get("id").?.string;
    const path = obj.get("path").?.string;
    const caption: ?[]const u8 = if (obj.get("caption")) |c| (if (c == .string) c.string else null) else null;

    const chat = switch (localChat(host, chat_id)) {
        .ok => |c| c,
        .err => |e| return e,
    };
    if (!validRequestId(req_id)) return failed("show_image id is invalid");
    if (std.mem.trim(u8, path, " \t\r\n").len == 0 or (std.unicode.utf8CountCodepoints(path) catch path.len) > 4096) return failed(attach_error);
    if (caption) |c| if ((std.unicode.utf8CountCodepoints(c) catch c.len) > 200) return failed(attach_error);

    const doc = try host.getOrCreateDoc(chat_id);
    const run_msg = activeRunMessage(doc) orelse return failed("No active run accepts images for this chat");
    const part_id = try std.fmt.allocPrint(host.gpa, "show-image:{s}", .{req_id});
    defer host.gpa.free(part_id);

    // A retried request resolves to the image it already published.
    if (findPart(doc, run_msg, part_id)) |existing| {
        const cj = existing.call_json orelse return failed(attach_error);
        if (!std.mem.eql(u8, existing.kind, "image")) return failed(attach_error);
        const parsed = json.parseFromSlice(json.Value, host.gpa, cj, .{}) catch return failed(attach_error);
        defer parsed.deinit();
        const name = if (parsed.value.object.get("name")) |v| v.string else "";
        const mime = if (parsed.value.object.get("mimeType")) |v| v.string else "";
        return reply(host.gpa, part_id, name, mime);
    }

    const io = host.io orelse return failed("Image intake is not configured");
    const data_dir = host.data_dir orelse return failed("Image intake is not configured");
    const cwd = runCwd(host, chat) orelse return failed(attach_error);
    const source = if (std.fs.path.isAbsolute(path))
        try host.gpa.dupe(u8, path)
    else
        try std.fs.path.join(host.gpa, &.{ cwd, path });
    defer host.gpa.free(source);
    const uploads = try std.fs.path.join(host.gpa, &.{ data_dir, "uploads" });
    defer host.gpa.free(uploads);
    const stable_key = try std.fmt.allocPrint(host.gpa, "{s}\x00{s}\x00{s}", .{ chat_id, run_msg, req_id });
    defer host.gpa.free(stable_key);
    const image = importImage(host.gpa, io, source, cwd, uploads, stable_key) catch return failed(attach_error);
    defer host.gpa.free(image.path);

    var name_buf: [16]u8 = undefined;
    const trimmed_caption = if (caption) |c| std.mem.trim(u8, c, " \t\r\n") else "";
    const ext_name = if (trimmed_caption.len > 0)
        trimmed_caption
    else
        std.fmt.bufPrint(&name_buf, "generated.{s}", .{image.ext}) catch unreachable;

    const fields = try std.fmt.allocPrint(host.gpa, "{{\"path\":{f},\"name\":{f},\"mimeType\":{f}}}", .{
        json.fmt(image.path, .{}), json.fmt(ext_name, .{}), json.fmt(image.mime, .{}),
    });
    defer host.gpa.free(fields);
    attachPart(host, chat_id, doc, run_msg, part_id, "image", fields) catch return failed(attach_error);
    return reply(host.gpa, part_id, ext_name, image.mime);
}

fn reply(gpa: Allocator, part_id: []const u8, name: []const u8, mime: []const u8) !RpcOutcome {
    return .{ .unary_json = try std.fmt.allocPrint(gpa, "{{\"attached\":true,\"id\":{f},\"name\":{f},\"mimeType\":{f}}}", .{
        json.fmt(part_id, .{}), json.fmt(name, .{}), json.fmt(mime, .{}),
    }) };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

pub const TestChat = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,
    ws: []const u8,
    host: EngineHost,

    /// A host with a data dir, a chat whose folder is `<tmp>/ws`, and a live run.
    pub fn init(self: *TestChat) !void {
        self.arena = .init(testing.allocator);
        const a = self.arena.allocator();
        self.tmp = testing.tmpDir(.{});
        try self.tmp.dir.createDirPath(testing.io, "ws/sub");
        try self.tmp.dir.createDirPath(testing.io, "data");
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        self.ws = try std.fs.path.join(a, &.{ self.root, "ws" });
        self.host = try EngineHost.init(testing.allocator, "dev-a", "Mac");
        self.host.io = testing.io;
        try self.host.setDataDir(try std.fs.path.join(a, &.{ self.root, "data" }));
        try self.call("Mutate", try std.fmt.allocPrint(a, "{{\"op\":\"createChat\",\"chatId\":\"chat-1\",\"cwd\":{f},\"config\":{{\"harness\":\"mock\"}}}}", .{json.fmt(self.ws, .{})}));
    }

    pub fn deinit(self: *TestChat) void {
        self.host.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
    }

    pub fn startRun(self: *TestChat) !void {
        const doc = try self.host.getOrCreateDoc("chat-1");
        try doc.beginAssistantMessage("asst-1", 1);
    }

    fn call(self: *TestChat, method: []const u8, text: []const u8) !void {
        var r = try self.handle(method, text);
        switch (r) {
            .unary_json => |b| testing.allocator.free(b),
            .stream_items_json => |*st| st.deinit(testing.allocator),
            .err => return error.CallFailed,
        }
    }

    pub fn handle(self: *TestChat, method: []const u8, text: []const u8) !RpcOutcome {
        const v = try json.parseFromSliceLeaky(json.Value, self.arena.allocator(), text, .{});
        return self.host.handleWithId(1, method, v);
    }

    pub fn expectErr(self: *TestChat, method: []const u8, text: []const u8, want: []const u8) !void {
        const r = try self.handle(method, text);
        switch (r) {
            .err => |e| try testing.expectEqualStrings(want, switch (e) {
                .bad_params => |m| m,
                .exec_error => |m| m,
                .unknown_method => |m| m,
            }),
            .unary_json => |b| {
                defer testing.allocator.free(b);
                std.debug.print("unexpected success: {s}\n", .{b});
                return error.UnexpectedSuccess;
            },
            .stream_items_json => return error.UnexpectedSuccess,
        }
    }

    pub fn resetFrame(self: *TestChat) ![]u8 {
        const doc = try self.host.getOrCreateDoc("chat-1");
        return doc.toResetFrameJson(testing.allocator);
    }
};

const png = "\x89PNG\r\n\x1a\nmade-up pixels";

test "ShowImage copies a workspace raster into uploads and attaches it to the live run" {
    var t: TestChat = undefined;
    try t.init();
    defer t.deinit();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/sub/chart.bin", .data = png });
    try t.expectErr("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"img-1\",\"path\":\"sub/chart.bin\"}", "No active run accepts images for this chat");
    try t.startRun();

    const r = try t.handle("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"img-1\",\"path\":\"sub/chart.bin\",\"caption\":\"  Weekly chart \"}");
    defer testing.allocator.free(r.unary_json);
    try testing.expectEqualStrings("{\"attached\":true,\"id\":\"show-image:img-1\",\"name\":\"Weekly chart\",\"mimeType\":\"image/png\"}", r.unary_json);

    const frame = try t.resetFrame();
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "{\"id\":\"show-image:img-1\",\"kind\":\"image\",\"path\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "-generated.png\",\"name\":\"Weekly chart\",\"mimeType\":\"image/png\"}") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "chart.bin") == null);

    // The copy holds the same bytes; the original stays.
    var it = (try t.tmp.dir.openDir(testing.io, "data/uploads", .{ .iterate = true }));
    defer it.close(testing.io);
    var walker = it.iterate();
    var files: usize = 0;
    while (try walker.next(testing.io)) |e| {
        files += 1;
        try testing.expect(std.mem.endsWith(u8, e.name, "-generated.png"));
        const bytes = try it.readFileAlloc(testing.io, e.name, testing.allocator, .limited(1024));
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings(png, bytes);
    }
    try testing.expectEqual(@as(usize, 1), files);

    // A retry publishes once and answers the same.
    const again = try t.handle("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"img-1\",\"path\":\"sub/chart.bin\",\"caption\":\"  Weekly chart \"}");
    defer testing.allocator.free(again.unary_json);
    try testing.expectEqualStrings(r.unary_json, again.unary_json);

    // The part survives a snapshot round trip.
    const doc = try t.host.getOrCreateDoc("chat-1");
    const snap = try doc.exportSnapshot(testing.allocator);
    defer testing.allocator.free(snap);
    var copy = try session_doc.SessionDoc.init(testing.allocator, "chat-1", "dev-a");
    defer copy.deinit();
    try copy.importSnapshot(snap);
    const frame2 = try copy.toResetFrameJson(testing.allocator);
    defer testing.allocator.free(frame2);
    try testing.expectEqualStrings(frame, frame2);

    // No caption: the generic name for the sniffed type.
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/photo.png", .data = "\xff\xd8\xffjpeg-bytes" });
    const jr = try t.handle("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"img-2\",\"path\":\"photo.png\"}");
    defer testing.allocator.free(jr.unary_json);
    try testing.expectEqualStrings("{\"attached\":true,\"id\":\"show-image:img-2\",\"name\":\"generated.jpg\",\"mimeType\":\"image/jpeg\"}", jr.unary_json);
}

test "ShowImage refuses bad params, other chats and files it may not publish" {
    var t: TestChat = undefined;
    try t.init();
    defer t.deinit();
    try t.startRun();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/notes.txt", .data = "plain text" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.png", .data = png });
    try t.tmp.dir.symLink(testing.io, "../outside.png", "ws/link.png", .{});
    {
        const big = try testing.allocator.alloc(u8, max_image_bytes + 1);
        defer testing.allocator.free(big);
        @memset(big, 0);
        @memcpy(big[0..8], png[0..8]);
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/big.png", .data = big });
    }
    try t.expectErr("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"x\"}", "missing field `path`");
    try t.expectErr("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"x\",\"path\":\"a.png\",\"extra\":1}", "unknown field");
    try t.expectErr("ShowImage", "{\"chatId\":\"nope\",\"id\":\"x\",\"path\":\"a.png\"}", "chat not found");
    try t.expectErr("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"bad id!\",\"path\":\"a.png\"}", "show_image id is invalid");
    try t.expectErr("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"x\",\"path\":\"   \"}", attach_error);
    const many_c: [201]u8 = @splat('c');
    const long_caption = "{\"chatId\":\"chat-1\",\"id\":\"x\",\"path\":\"a.png\",\"caption\":\"" ++ many_c ++ "\"}";
    try t.expectErr("ShowImage", long_caption, attach_error);
    for ([_][]const u8{ "notes.txt", "missing.png", "link.png", "big.png", "../outside.png" }) |p| {
        const req = try std.fmt.allocPrint(t.arena.allocator(), "{{\"chatId\":\"chat-1\",\"id\":\"x\",\"path\":{f}}}", .{json.fmt(p, .{})});
        try t.expectErr("ShowImage", req, attach_error);
    }
    // Another device's chat.
    const dev = t.host.chats.items[0].device_id;
    t.host.chats.items[0].device_id = try testing.allocator.dupe(u8, "dev-b");
    testing.allocator.free(dev);
    try t.expectErr("ShowImage", "{\"chatId\":\"chat-1\",\"id\":\"x\",\"path\":\"a.png\"}", "chat belongs to another device");
}
