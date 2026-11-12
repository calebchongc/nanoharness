//! Small shared pieces of the MCP server: JSON value access and building,
//! RFC 3339 times, Unicode-aware string checks, and the sidebar's short id.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const Value = json.Value;
pub const ObjectMap = json.ObjectMap;

pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// A string field, or null when absent, null, or another type.
pub fn str(v: Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn boolean(v: Value, key: []const u8) ?bool {
    const f = get(v, key) orelse return null;
    return if (f == .bool) f.bool else null;
}

pub fn int(v: Value, key: []const u8) ?i64 {
    const f = get(v, key) orelse return null;
    return switch (f) {
        .integer => |n| n,
        .float => |x| if (x == @trunc(x) and @abs(x) < 9.0e15) @intFromFloat(x) else null,
        .number_string => |ns| std.fmt.parseInt(i64, ns, 10) catch null,
        else => null,
    };
}

/// An empty value list, for `array(...) orelse none`.
pub const none: []const Value = &.{};

pub fn array(v: Value, key: []const u8) ?[]const Value {
    const f = get(v, key) orelse return null;
    return if (f == .array) f.array.items else null;
}

/// `field` or JSON null — `serde_json`'s `value["k"].clone()`.
pub fn field(v: Value, key: []const u8) Value {
    return get(v, key) orelse .null;
}

pub fn s(text: []const u8) Value {
    return .{ .string = text };
}

pub fn optS(text: ?[]const u8) Value {
    return if (text) |t| .{ .string = t } else .null;
}

pub fn i(n: i64) Value {
    return .{ .integer = n };
}

pub fn b(x: bool) Value {
    return .{ .bool = x };
}

/// An object under construction: keys keep insertion order, as serde_json
/// with `preserve_order` writes them.
pub const Obj = struct {
    a: Allocator,
    map: ObjectMap = .empty,

    pub fn put(self: *Obj, key: []const u8, v: Value) !void {
        try self.map.put(self.a, key, v);
    }

    pub fn value(self: Obj) Value {
        return .{ .object = self.map };
    }
};

pub fn obj(a: Allocator) Obj {
    return .{ .a = a };
}

pub fn arr(a: Allocator) json.Array {
    return json.Array.init(a);
}

pub fn strArray(a: Allocator, items: []const []const u8) !Value {
    var out = arr(a);
    for (items) |t| try out.append(s(t));
    return .{ .array = out };
}

/// Compact JSON text of `v`, keys in insertion order (serde_json with
/// `preserve_order`).
pub fn stringify(a: Allocator, v: anytype) ![]u8 {
    return json.Stringify.valueAlloc(a, v, .{});
}

pub fn pretty(a: Allocator, v: Value) ![]u8 {
    return json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 });
}

/// Eight-char id prefix, the sidebar's convention (`harness::short`): the
/// first eight characters.
pub fn short(id: []const u8) []const u8 {
    var count: usize = 0;
    var idx: usize = 0;
    while (idx < id.len and count < 8) : (count += 1) {
        idx += std.unicode.utf8ByteSequenceLength(id[idx]) catch 1;
    }
    return id[0..@min(idx, id.len)];
}

/// Unicode scalar count (`str::chars().count()`).
pub fn charCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// `char::is_whitespace` for one code point.
pub fn isUnicodeSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `str::trim()`: Unicode whitespace off both ends.
pub fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
        if (start + n > text.len) break;
        const cp = std.unicode.utf8Decode(text[start .. start + n]) catch break;
        if (!isUnicodeSpace(cp)) break;
        start += n;
    }
    var end: usize = text.len;
    while (end > start) {
        var k = end - 1;
        while (k > start and (text[k] & 0xC0) == 0x80) k -= 1;
        const cp = std.unicode.utf8Decode(text[k..end]) catch break;
        if (!isUnicodeSpace(cp)) break;
        end = k;
    }
    return text[start..end];
}

pub fn isBlank(text: []const u8) bool {
    return trim(text).len == 0;
}

/// ASCII case-insensitive equality (`eq_ignore_ascii_case`).
pub fn eqlIgnoreCase(a: []const u8, c: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, c);
}

/// `{:?}` of a string: Rust's debug quoting (quotes, `\"`, `\\`, `\n`…).
pub fn debugQuote(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0 => try out.appendSlice(a, "\\0"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

// ---- time ----------------------------------------------------------------------

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn digits(text: []const u8, at: usize, n: usize) ?i64 {
    if (at + n > text.len) return null;
    return std.fmt.parseInt(i64, text[at .. at + n], 10) catch null;
}

/// Epoch millis of an RFC 3339 timestamp (`2026-09-01T00:00:00Z`,
/// fractional seconds and numeric offsets accepted).
pub fn parseRfc3339Ms(text: []const u8) ?i64 {
    const y = digits(text, 0, 4) orelse return null;
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != 't' and text[10] != ' ')) return null;
    const mo = digits(text, 5, 2) orelse return null;
    const d = digits(text, 8, 2) orelse return null;
    const h = digits(text, 11, 2) orelse return null;
    const mi = digits(text, 14, 2) orelse return null;
    const sec = digits(text, 17, 2) orelse return null;
    var idx: usize = 19;
    var frac_ms: i64 = 0;
    if (idx < text.len and text[idx] == '.') {
        idx += 1;
        var scale: i64 = 100;
        while (idx < text.len and std.ascii.isDigit(text[idx])) : (idx += 1) {
            frac_ms += @as(i64, text[idx] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    var offset_min: i64 = 0;
    if (idx < text.len and (text[idx] == '+' or text[idx] == '-')) {
        const oh = digits(text, idx + 1, 2) orelse return null;
        const om = digits(text, idx + 4, 2) orelse return null;
        offset_min = oh * 60 + om;
        if (text[idx] == '-') offset_min = -offset_min;
    }
    const days = daysFromCivil(y, mo, d);
    return ((days * 86_400 + h * 3600 + mi * 60 + sec) - offset_min * 60) * 1000 + frac_ms;
}

/// `to_rfc3339_opts(SecondsFormat::Secs, true)`: `2023-11-14T22:13:20Z`.
pub fn isoSecs(buf: *[32]u8, ms: i64) []const u8 {
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86_400);
    const rem = @mod(secs, 86_400);
    const c = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(@max(0, c.y))),            @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
        @as(u64, @intCast(@divFloor(rem, 3600))),    @as(u64, @intCast(@divFloor(@mod(rem, 3600), 60))),
        @as(u64, @intCast(@mod(rem, 60))),
    }) catch "";
}

const testing = std.testing;

test "mcp util: rfc3339 round trip, short ids and unicode trimming" {
    try testing.expectEqual(@as(?i64, 1_700_000_000_000), parseRfc3339Ms("2023-11-14T22:13:20Z"));
    try testing.expectEqual(@as(?i64, 1_700_000_000_123), parseRfc3339Ms("2023-11-14T22:13:20.123Z"));
    try testing.expectEqual(@as(?i64, 1_700_000_000_000), parseRfc3339Ms("2023-11-14T23:13:20+01:00"));
    try testing.expectEqual(@as(?i64, null), parseRfc3339Ms("yesterday"));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2023-11-14T22:13:20Z", isoSecs(&buf, 1_700_000_000_000));
    try testing.expectEqualStrings("abcdefgh", short("abcdefgh-1234"));
    try testing.expectEqualStrings("abc", short("abc"));
    try testing.expectEqualStrings("x y", trim("\u{3000} x y\n\u{a0}"));
    try testing.expect(isBlank(" \n\t"));
    const q = try debugQuote(testing.allocator, "a\"b\n");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("\"a\\\"b\\n\"", q);
}
