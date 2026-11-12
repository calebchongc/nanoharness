//! `FetchToolBlob`, ported from `crates/engine/src/rpc.rs`
//! (`methods::FETCH_TOOL_BLOB`) and `crates/engine/src/doc_host.rs`
//! (`DocHost::fetch_tool_blob`, `encode_part_segment`).
//!
//! A long tool output or diff lives on the edge as a sidecar blob; the
//! transcript keeps only its ref (`{chatId}/{partId}` or `…​.diff`). The UI's
//! "Show full output" asks the engine for it, which fetches
//! `GET {edge}/blob/{chat}/{part}` with the session's bearer.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");
const rooms = @import("rpcw_rooms.zig");

const RpcOutcome = common.RpcOutcome;

/// The shape `apply_sidecar_refs` writes; anything else is a forged ref. Pure.
pub fn validRef(blob_ref: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, blob_ref, '/') orelse return false;
    const chat = blob_ref[0..slash];
    const part = blob_ref[slash + 1 ..];
    if (chat.len == 0 or chat.len > 128) return false;
    for (chat) |b| if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '-')) return false;
    if (part.len == 0 or part.len > 200) return false;
    for (part) |b| if (!(std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "._:#~-", b) != null)) return false;
    return true;
}

/// `encode_part_segment`: RFC 3986 unreserved bytes pass, the rest `%XX`
/// (so a `#` in a part id isn't read as a fragment).
pub fn encodePart(w: *std.Io.Writer, part: []const u8) !void {
    for (part) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') {
            try w.writeByte(b);
        } else {
            try w.print("%{X:0>2}", .{b});
        }
    }
}

/// `{edge}/blob/{chat}/{encoded part}` for a valid ref. Pure.
pub fn blobUrl(gpa: Allocator, edge_url: []const u8, blob_ref: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, blob_ref, '/').?;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print("{s}/blob/{s}/", .{ std.mem.trimEnd(u8, edge_url, "/"), blob_ref[0..slash] });
    try encodePart(&aw.writer, blob_ref[slash + 1 ..]);
    return aw.toOwnedSlice();
}

/// `res.text()`: the body as UTF-8, invalid sequences replaced by U+FFFD.
pub fn lossyUtf8(gpa: Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return gpa.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + n])) {
            try out.appendSlice(gpa, bytes[i .. i + n]);
            i += n;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `FetchToolBlob { blobRef }` → `{"text": …}`.
pub fn fetchToolBlob(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return .{ .err = .{ .bad_params = "invalid type: expected struct FetchToolBlobParams" } };
    const ref_v = o.get("blobRef") orelse return .{ .err = .{ .bad_params = "missing field `blobRef`" } };
    if (ref_v != .string) return .{ .err = .{ .bad_params = "invalid type: expected a string for `blobRef`" } };
    const blob_ref = ref_v.string;
    if (!validRef(blob_ref)) return common.failed("bad blob ref: {s}", .{blob_ref});
    const edge_url = host.auth.edge_url orelse return common.failed("offline: no edge configured", .{});
    const io = host.io orelse return common.failed("offline: no edge configured", .{});
    if (!host.auth.signed_in) return common.failed("signed out", .{});
    const bearer = host.auth.ensureAccessToken(io, false) orelse return common.failed("signed out", .{});

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bearer_owned = try arena.dupe(u8, bearer);
    const edge_owned = try arena.dupe(u8, edge_url);
    const url = try blobUrl(arena, edge_owned, blob_ref);

    var reply = auth_host.AuthManager.edgeRequestPooled(&host.auth.h2_pool, gpa, io, "GET", url, bearer_owned, &.{}, null) catch |e|
        return common.failed("sidecar fetch failed: {s}", .{rooms.describeTransportError(edge_owned, e)});
    defer reply.deinit(gpa);
    if (reply.status < 200 or reply.status >= 300) return common.failed("sidecar fetch: HTTP {d}", .{reply.status});
    const text = try lossyUtf8(arena, reply.body);
    return .{ .unary_json = try std.fmt.allocPrint(gpa, "{{\"text\":{f}}}", .{json.fmt(text, .{})}) };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "rpcw_tool_blob validRef accepts what apply_sidecar_refs writes and nothing else" {
    for ([_][]const u8{ "chat-1/part_2", "c/p.diff", "chat_A-9/tool:call#3~x.diff" }) |ok| try testing.expect(validRef(ok));
    var long_chat_buf: [131]u8 = @splat('c');
    long_chat_buf[129] = '/';
    long_chat_buf[130] = 'p';
    const long_chat: []const u8 = &long_chat_buf;
    var long_part_buf: [203]u8 = @splat('p');
    long_part_buf[0] = 'c';
    long_part_buf[1] = '/';
    const long_part: []const u8 = &long_part_buf;
    try testing.expect(validRef(long_chat[1..]) and validRef(long_part[0 .. long_part.len - 1]));
    for ([_][]const u8{ "", "nochat", "/p", "c/", "c/p/q", "c.d/p", "../etc/passwd", "c/p?x", "c/p q", long_chat, long_part }) |bad| {
        try testing.expect(!validRef(bad));
    }
}

test "rpcw_tool_blob blobUrl percent-encodes the part segment" {
    const url = try blobUrl(testing.allocator, "https://edge.example.test/", "chat-1/tool:call#3.diff");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://edge.example.test/blob/chat-1/tool%3Acall%233.diff", url);
}

test "rpcw_tool_blob lossyUtf8 keeps valid text and replaces broken bytes" {
    const a = try lossyUtf8(testing.allocator, "héllo");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("héllo", a);
    const b = try lossyUtf8(testing.allocator, "ok\xffend\xc3");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("ok\u{FFFD}end\u{FFFD}", b);
}

test "rpcw_tool_blob FetchToolBlob fetches the sidecar with the bearer and answers its text" {
    const f = try rooms.Fx.init(true);
    defer f.deinit();
    f.edge.body = "line 1\nline \"2\"\n";
    const ok = try f.callMethod("FetchToolBlob", "{\"blobRef\":\"chat-syn/part#7.diff\"}");
    defer testing.allocator.free(ok.unary_json);
    try testing.expectEqualStrings("{\"text\":\"line 1\\nline \\\"2\\\"\\n\"}", ok.unary_json);
    const last = f.edge.lastRequest();
    try testing.expect(std.mem.startsWith(u8, last, "GET /blob/chat-syn/part%237.diff HTTP/1.1\n"));
    try testing.expect(std.mem.indexOf(u8, last, "Bearer synthetic-access-token") != null);
}

test "rpcw_tool_blob FetchToolBlob errors: bad params, forged refs, HTTP failures, offline" {
    const f = try rooms.Fx.init(true);
    defer f.deinit();
    try rooms.expectErr(try f.callMethod("FetchToolBlob", "{}"), .bad_params, "missing field `blobRef`");
    try rooms.expectErr(try f.callMethod("FetchToolBlob", "{\"blobRef\":\"../x\"}"), .exec_error, "bad blob ref: ../x");
    try testing.expectEqual(@as(u32, 0), f.edge.hits.load(.acquire));
    f.edge.status = 404;
    f.edge.body = "{\"error\":\"not_found\"}";
    try rooms.expectErr(try f.callMethod("FetchToolBlob", "{\"blobRef\":\"chat-syn/p1\"}"), .exec_error, "sidecar fetch: HTTP 404");
    f.host.auth.signed_in = false;
    try rooms.expectErr(try f.callMethod("FetchToolBlob", "{\"blobRef\":\"chat-syn/p1\"}"), .exec_error, "signed out");
    testing.allocator.free(f.host.auth.edge_url.?);
    f.host.auth.edge_url = null;
    try rooms.expectErr(try f.callMethod("FetchToolBlob", "{\"blobRef\":\"chat-syn/p1\"}"), .exec_error, "offline: no edge configured");
}
