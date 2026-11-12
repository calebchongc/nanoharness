//! The device-room relay frame codec, as pure functions (no I/O).
//!
//! A frame is `uleb128(header byte length) || UTF-8 JSON header || payload`,
//! header `{s, k, to?, from?}`. This is the encoding `crates/rpc/src/device_room.rs`
//! and the edge's `DeviceRoom` (`edge/src/device-room.ts`) speak; both run the
//! shared vectors in `protocol/device-frame-vectors.json`, and so does this file.
//!
//! - client → relay: the relay stamps `from = connId` and forwards to the host;
//! - host → relay: carries `to = connId`; the relay strips routing keys;
//! - relay control frames use kind `" relay"` (leading space) with payload
//!   `{"error": code}`; nudge frames use kind `"nudge"` with `{chatId, token?}`.
//!
//! Also here: the device-room WebSocket URL and the bearer-header rule the
//! Rust dialer applies to it (`crates/sync/src/dial.rs`, `bearer_from_query`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// Relay-emitted control frames. Byte-matches the relay's `RELAY_KIND`.
pub const relay_kind = " relay";
pub const nudge_kind = "nudge";
pub const nudge_ack_kind = "nudgeAck";
/// The RPC stream: both `s` and `k` are `"rpc"`.
pub const rpc_kind = "rpc";
/// App-level end-to-end liveness probe; the host echoes it to its sender.
pub const echo_kind = "echo";

pub const host_offline = "host_offline";
pub const host_closed = "host_closed";
pub const client_gone = "client_gone";
pub const client_closed = "client_closed";

pub const Header = struct {
    /// Stream id, unique per (connId, logical stream).
    s: []const u8,
    /// Stream kind: "rpc", "term", ... (opaque to the relay).
    k: []const u8,
    /// Routing: host → client target.
    to: ?[]const u8 = null,
    /// Routing: client → host origin (stamped by the relay).
    from: ?[]const u8 = null,
};

pub const DecodeError = error{
    TruncatedLength,
    LengthOverflow,
    TruncatedHeader,
    BadHeader,
} || Allocator.Error;

/// A decoded frame. `header` strings live in `arena`; `payload` borrows the
/// input bytes.
pub const Frame = struct {
    arena: std.heap.ArenaAllocator,
    header: Header,
    payload: []const u8,

    pub fn deinit(self: *Frame) void {
        self.arena.deinit();
    }
};

/// Writes `s` as a JSON string the way `JSON.stringify` and `serde_json` do:
/// `"` `\` and C0 controls escaped (`\b \f \n \r \t`, else `\u00xx` lowercase),
/// everything else (including `/`, DEL and non-ASCII) raw.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0c => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (esc == null and c >= 0x20) continue;
        try w.writeAll(s[start..i]);
        if (esc) |e| {
            try w.writeAll(e);
        } else {
            const digits = "0123456789abcdef";
            try w.writeAll("\\u00");
            try w.writeByte(digits[c >> 4]);
            try w.writeByte(digits[c & 0xf]);
        }
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

/// The compact header JSON, keys in `s, k, to, from` order, absent keys omitted.
pub fn writeHeaderJson(w: *std.Io.Writer, h: Header) std.Io.Writer.Error!void {
    try w.writeAll("{\"s\":");
    try writeJsonString(w, h.s);
    try w.writeAll(",\"k\":");
    try writeJsonString(w, h.k);
    if (h.to) |to| {
        try w.writeAll(",\"to\":");
        try writeJsonString(w, to);
    }
    if (h.from) |from| {
        try w.writeAll(",\"from\":");
        try writeJsonString(w, from);
    }
    try w.writeByte('}');
}

pub fn writeUleb128(w: *std.Io.Writer, value: usize) std.Io.Writer.Error!void {
    var n = value;
    while (true) {
        var byte: u8 = @intCast(n & 0x7f);
        n >>= 7;
        if (n != 0) byte |= 0x80;
        try w.writeByte(byte);
        if (n == 0) break;
    }
}

pub const EncodeError = error{InvalidUtf8} || Allocator.Error;

/// `uleb128(header_len) || header JSON || payload`, caller-owned.
pub fn encode(gpa: Allocator, h: Header, payload: []const u8) EncodeError![]u8 {
    inline for (.{ "s", "k" }) |field| {
        if (!std.unicode.utf8ValidateSlice(@field(h, field))) return error.InvalidUtf8;
    }
    inline for (.{ "to", "from" }) |field| {
        if (@field(h, field)) |v| if (!std.unicode.utf8ValidateSlice(v)) return error.InvalidUtf8;
    }
    var header_json: std.Io.Writer.Allocating = .init(gpa);
    defer header_json.deinit();
    writeHeaderJson(&header_json.writer, h) catch return error.OutOfMemory;
    const hj = header_json.written();

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, hj.len + payload.len + 5);
    errdefer out.deinit();
    writeUleb128(&out.writer, hj.len) catch return error.OutOfMemory;
    out.writer.writeAll(hj) catch return error.OutOfMemory;
    out.writer.writeAll(payload) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Reads the header length prefix: `.{ len, bytes consumed }`. Rejects a
/// prefix that would shift past 32 bits, as the Rust decoder does.
pub fn readUleb128(bytes: []const u8) error{ TruncatedLength, LengthOverflow }!struct { usize, usize } {
    var len: u64 = 0;
    var shift: u32 = 0;
    var offset: usize = 0;
    while (true) {
        if (offset >= bytes.len) return error.TruncatedLength;
        const byte = bytes[offset];
        offset += 1;
        if (shift >= 32) return error.LengthOverflow;
        len |= @as(u64, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return .{ std.math.cast(usize, len) orelse return error.LengthOverflow, offset };
}

/// Decodes a frame. The header must be a JSON object with string `s` and `k`
/// (and string-or-null `to`/`from`); unknown keys are ignored.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Frame {
    const len, const offset = try readUleb128(bytes);
    if (len > bytes.len - offset) return error.TruncatedHeader;
    const header_bytes = bytes[offset .. offset + len];
    if (!std.unicode.utf8ValidateSlice(header_bytes)) return error.BadHeader;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const value = json.parseFromSliceLeaky(json.Value, a, header_bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadHeader,
    };
    if (value != .object) return error.BadHeader;
    const obj = value.object;
    const s = obj.get("s") orelse return error.BadHeader;
    const k = obj.get("k") orelse return error.BadHeader;
    if (s != .string or k != .string) return error.BadHeader;
    return .{
        .arena = arena,
        .header = .{
            .s = s.string,
            .k = k.string,
            .to = try optionalString(obj, "to"),
            .from = try optionalString(obj, "from"),
        },
        .payload = bytes[offset + len ..],
    };
}

fn optionalString(obj: json.ObjectMap, key: []const u8) error{BadHeader}!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => error.BadHeader,
    };
}

/// The code of a relay control payload `{"error": code}`, or null.
pub fn relayErrorCode(gpa: Allocator, payload: []const u8) ?[]u8 {
    var parsed = json.parseFromSlice(json.Value, gpa, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("error") orelse return null;
    if (v != .string) return null;
    return gpa.dupe(u8, v.string) catch null;
}

/// `{edge}/device/{device}/ws?role={role}[&connId={c}]&token={token}`, with the
/// first `http` of the edge URL rewritten to `ws` (`device_room_ws_url`).
pub fn deviceRoomWsUrl(
    gpa: Allocator,
    edge_url: []const u8,
    device_id: []const u8,
    role: []const u8,
    conn_id: ?[]const u8,
    token: []const u8,
) Allocator.Error![]u8 {
    var base: std.Io.Writer.Allocating = .init(gpa);
    defer base.deinit();
    if (std.mem.indexOf(u8, edge_url, "http")) |at| {
        base.writer.print("{s}ws{s}", .{ edge_url[0..at], edge_url[at + 4 ..] }) catch return error.OutOfMemory;
    } else {
        base.writer.writeAll(edge_url) catch return error.OutOfMemory;
    }
    const trimmed = std.mem.trimEnd(u8, base.written(), "/");
    if (conn_id) |c| {
        return std.fmt.allocPrint(gpa, "{s}/device/{s}/ws?role={s}&connId={s}&token={s}", .{ trimmed, device_id, role, c, token });
    }
    return std.fmt.allocPrint(gpa, "{s}/device/{s}/ws?role={s}&token={s}", .{ trimmed, device_id, role, token });
}

/// A request target with the `token` query parameter moved out: a URL reaches
/// request logs and a header does not (`bearer_from_query`).
pub const BearerSplit = struct {
    /// Path plus the remaining query (no `token`).
    target: []u8,
    /// The percent-decoded token, or null when the URL has none (or it is empty).
    token: ?[]u8,

    pub fn deinit(self: *BearerSplit, gpa: Allocator) void {
        gpa.free(self.target);
        if (self.token) |t| gpa.free(t);
    }
};

/// Splits a request target (`/path?query`) into the target without its first
/// `token=` pair and that token, percent-decoded as the edge reads it. Later
/// `token=` pairs and empty pairs are dropped, like the Rust dialer.
pub fn bearerFromTarget(gpa: Allocator, path_and_query: []const u8) Allocator.Error!BearerSplit {
    const q = std.mem.indexOfScalar(u8, path_and_query, '?') orelse
        return .{ .target = try gpa.dupe(u8, path_and_query), .token = null };
    const path = path_and_query[0..q];
    const query = path_and_query[q + 1 ..];
    var token_raw: ?[]const u8 = null;
    var kept: std.Io.Writer.Allocating = .init(gpa);
    defer kept.deinit();
    var any_kept = false;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "token=")) {
            if (token_raw == null) token_raw = pair["token=".len..];
            continue;
        }
        if (pair.len == 0) continue;
        if (any_kept) kept.writer.writeByte('&') catch return error.OutOfMemory;
        kept.writer.writeAll(pair) catch return error.OutOfMemory;
        any_kept = true;
    }
    if (token_raw == null) return .{ .target = try gpa.dupe(u8, path_and_query), .token = null };
    const target = if (any_kept)
        try std.fmt.allocPrint(gpa, "{s}?{s}", .{ path, kept.written() })
    else
        try gpa.dupe(u8, path);
    errdefer gpa.free(target);
    const decoded = try percentDecode(gpa, token_raw.?);
    if (decoded.len == 0) {
        gpa.free(decoded);
        return .{ .target = target, .token = null };
    }
    return .{ .target = target, .token = decoded };
}

/// `%XX` → byte, `+` → space, malformed escapes kept literally.
pub fn percentDecode(gpa: Allocator, value: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, value.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '%' and i + 2 < value.len) {
            const hi = std.fmt.charToDigit(value[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(value[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                out.appendAssumeCapacity(hi.? * 16 + lo.?);
                i += 3;
                continue;
            }
            out.appendAssumeCapacity('%');
        } else if (c == '+') {
            out.appendAssumeCapacity(' ');
        } else {
            out.appendAssumeCapacity(c);
        }
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Shared vectors: protocol/device-frame-vectors.json
// ---------------------------------------------------------------------------

const testing = std.testing;

fn hexAlloc(gpa: Allocator, hex: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn headerFromJson(v: json.Value) !Header {
    const o = v.object;
    return .{
        .s = o.get("s").?.string,
        .k = o.get("k").?.string,
        .to = if (o.get("to")) |t| t.string else null,
        .from = if (o.get("from")) |f| f.string else null,
    };
}

fn expectHeader(expected: Header, actual: Header) !void {
    try testing.expectEqualStrings(expected.s, actual.s);
    try testing.expectEqualStrings(expected.k, actual.k);
    try testing.expectEqual(expected.to == null, actual.to == null);
    if (expected.to) |t| try testing.expectEqualStrings(t, actual.to.?);
    try testing.expectEqual(expected.from == null, actual.from == null);
    if (expected.from) |f| try testing.expectEqualStrings(f, actual.from.?);
}

/// Read from the repository at test time (`protocol/README.md`: don't copy it).
fn loadVectors(gpa: Allocator) !json.Parsed(json.Value) {
    const protocol_dir = @import("parity_options").protocol_dir; // protocol/desktop
    const path = try std.fs.path.join(gpa, &.{ protocol_dir, "..", "device-frame-vectors.json" });
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    return json.parseFromSlice(json.Value, gpa, bytes, .{ .allocate = .alloc_always });
}

test "device frame vectors: kinds and relay error codes" {
    const gpa = testing.allocator;
    var vectors = try loadVectors(gpa);
    defer vectors.deinit();
    const kinds = vectors.value.object.get("kinds").?.object;
    try testing.expectEqualStrings(relay_kind, kinds.get("relay").?.string);
    try testing.expectEqualStrings(rpc_kind, kinds.get("rpc").?.string);
    try testing.expectEqualStrings(nudge_kind, kinds.get("nudge").?.string);
    try testing.expectEqualStrings(nudge_ack_kind, kinds.get("nudgeAck").?.string);
    try testing.expectEqualStrings(echo_kind, kinds.get("echo").?.string);
    const codes = vectors.value.object.get("relayErrors").?.array.items;
    const ours = [_][]const u8{ host_offline, host_closed, client_gone, client_closed };
    try testing.expectEqual(ours.len, codes.len);
    for (ours, codes) |o, c| try testing.expectEqualStrings(o, c.string);
}

test "device frame vectors: encode exact bytes and read them back" {
    const gpa = testing.allocator;
    var vectors = try loadVectors(gpa);
    defer vectors.deinit();
    const cases = vectors.value.object.get("encode").?.array.items;
    try testing.expect(cases.len > 0);
    for (cases) |c| {
        const o = c.object;
        const h = try headerFromJson(o.get("header").?);
        const payload = try hexAlloc(gpa, o.get("payloadHex").?.string);
        defer gpa.free(payload);
        const expected = try hexAlloc(gpa, o.get("bytesHex").?.string);
        defer gpa.free(expected);
        const got = try encode(gpa, h, payload);
        defer gpa.free(got);
        testing.expectEqualSlices(u8, expected, got) catch |err| {
            std.debug.print("encode case failed: {s}\n", .{o.get("name").?.string});
            return err;
        };
        var frame = try decode(gpa, got);
        defer frame.deinit();
        try expectHeader(h, frame.header);
        try testing.expectEqualSlices(u8, payload, frame.payload);
    }
}

test "device frame vectors: decoders reject and accept the same inputs" {
    const gpa = testing.allocator;
    var vectors = try loadVectors(gpa);
    defer vectors.deinit();
    for (vectors.value.object.get("decodeRejects").?.array.items) |c| {
        // `typedOnly` cases are rejected by typed decoders (Rust, Zig) and
        // passed through by the relay, which treats the header as opaque.
        const bytes = try hexAlloc(gpa, c.object.get("bytesHex").?.string);
        defer gpa.free(bytes);
        if (decode(gpa, bytes)) |frame_ok| {
            var frame = frame_ok;
            frame.deinit();
            std.debug.print("decode accepted a reject case: {s}\n", .{c.object.get("name").?.string});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    for (vectors.value.object.get("decodeAccepts").?.array.items) |c| {
        const o = c.object;
        const bytes = try hexAlloc(gpa, o.get("bytesHex").?.string);
        defer gpa.free(bytes);
        const payload = try hexAlloc(gpa, o.get("payloadHex").?.string);
        defer gpa.free(payload);
        var frame = try decode(gpa, bytes);
        defer frame.deinit();
        try expectHeader(try headerFromJson(o.get("header").?), frame.header);
        try testing.expectEqualSlices(u8, payload, frame.payload);
    }
}

test "device frame vectors: relay error codes, URLs and the bearer header" {
    const gpa = testing.allocator;
    var vectors = try loadVectors(gpa);
    defer vectors.deinit();
    const root = vectors.value.object;
    for (root.get("relayErrorCode").?.array.items) |c| {
        const o = c.object;
        const got = relayErrorCode(gpa, o.get("payload").?.string);
        defer if (got) |g| gpa.free(g);
        switch (o.get("code").?) {
            .null => try testing.expect(got == null),
            .string => |want| try testing.expectEqualStrings(want, got.?),
            else => return error.TestUnexpectedResult,
        }
    }
    for (root.get("wsUrl").?.array.items) |c| {
        const o = c.object;
        const conn: ?[]const u8 = if (o.get("connId").? == .string) o.get("connId").?.string else null;
        const url = try deviceRoomWsUrl(gpa, o.get("edgeUrl").?.string, o.get("deviceId").?.string, o.get("role").?.string, conn, o.get("token").?.string);
        defer gpa.free(url);
        try testing.expectEqualStrings(o.get("url").?.string, url);
    }
    try testing.expectEqualStrings("&nudgeAck=1", root.get("hostUrlSuffix").?.string);
    for (root.get("bearerFromQuery").?.array.items) |c| {
        const o = c.object;
        const url = o.get("url").?.string;
        const scheme_end = std.mem.indexOf(u8, url, "://").? + 3;
        const path_start = std.mem.indexOfScalarPos(u8, url, scheme_end, '/').?;
        var split = try bearerFromTarget(gpa, url[path_start..]);
        defer split.deinit(gpa);
        try testing.expectEqualStrings(o.get("target").?.string, split.target);
        switch (o.get("authorization").?) {
            .null => try testing.expect(split.token == null),
            .string => |want| {
                const got = try std.fmt.allocPrint(gpa, "Bearer {s}", .{split.token.?});
                defer gpa.free(got);
                try testing.expectEqualStrings(want, got);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "device frame: encode refuses a header that is not UTF-8" {
    try testing.expectError(error.InvalidUtf8, encode(testing.allocator, .{ .s = "\xff", .k = "rpc" }, ""));
}
