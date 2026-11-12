//! The pure rules of simulator streaming (`crates/engine/src/simulators`):
//! simulator ids, the allowlist seam, typed input → the helper's HID socket
//! messages (with the US-keyboard key table of `keys.rs`), the MJPEG part
//! parser of `mjpeg.rs`, viewer frame pacing, and `simctl list` parsing.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const max_text_chars: usize = 500;
pub const default_viewer_fps: u32 = 15;
/// What the helper makes (`hub::SOURCE_FPS`); a viewer's cap is clamped to it.
pub const source_fps: u32 = 20;
pub const max_frame_bytes: usize = 8 * 1024 * 1024;

pub const op_touch: u8 = 3;
pub const op_button: u8 = 4;
pub const op_key: u8 = 6;

/// CoreSimulator UDIDs only; nothing else reaches a URL or a command line.
pub fn checkId(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !std.ascii.isHex(c)) return false;
    }
    return true;
}

/// `HARNESS_SIMULATOR_ALLOWLIST`: comma-separated UDIDs, compared uppercase.
pub fn allowed(allowlist: ?[]const u8, id: []const u8) bool {
    const list = allowlist orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len > 0 and std.ascii.eqlIgnoreCase(t, id)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- keys

const left_shift: u16 = 225;

pub const KeyPress = struct { down: bool, usage: u16 };

/// (usage, shift) on a US keyboard, USB HID keyboard page 0x07.
pub fn keyUsage(c: u21) ?struct { u16, bool } {
    if (c >= 'a' and c <= 'z') return .{ @intCast(4 + (c - 'a')), false };
    if (c >= 'A' and c <= 'Z') return .{ @intCast(4 + (c - 'A')), true };
    switch (c) {
        '\n' => return .{ 40, false },
        '\t' => return .{ 43, false },
        ' ' => return .{ 44, false },
        else => {},
    }
    if (std.mem.indexOfScalar(u8, "1234567890", if (c < 128) @intCast(c) else 0)) |i| return .{ @intCast(30 + i), false };
    if (std.mem.indexOfScalar(u8, "!@#$%^&*()", if (c < 128) @intCast(c) else 0)) |i| return .{ @intCast(30 + i), true };
    const punctuation = [_]struct { u8, u8, u16 }{
        .{ '-', '_', 45 }, .{ '=', '+', 46 },  .{ '[', '{', 47 }, .{ ']', '}', 48 },
        .{ '\\', '|', 49 }, .{ ';', ':', 51 }, .{ '\'', '"', 52 }, .{ '`', '~', 53 },
        .{ ',', '<', 54 }, .{ '.', '>', 55 },  .{ '/', '?', 56 },
    };
    for (punctuation) |p| {
        if (c == p[0]) return .{ p[2], false };
        if (c == p[1]) return .{ p[2], true };
    }
    return null;
}

/// Named keys a viewer sends on their own.
pub fn namedKey(key: []const u8) ?u16 {
    const table = [_]struct { []const u8, u16 }{
        .{ "enter", 40 }, .{ "escape", 41 }, .{ "backspace", 42 }, .{ "tab", 43 },
        .{ "right", 79 }, .{ "left", 80 },   .{ "down", 81 },      .{ "up", 82 },
    };
    for (table) |t| if (std.mem.eql(u8, t[0], key)) return t[1];
    return null;
}

// ---------------------------------------------------------------- input

/// `SimulatorInput`, from its wire shape (`{"kind": "touch" | "button" | "text" | "key", ...}`):
/// the HID messages (opcode byte + JSON) in order, or the reason it can't be sent.
pub const Messages = struct {
    list: std.ArrayList([]u8) = .empty,
    err: ?[]u8 = null,

    pub fn deinit(m: *Messages, gpa: Allocator) void {
        for (m.list.items) |x| gpa.free(x);
        m.list.deinit(gpa);
        if (m.err) |e| gpa.free(e);
    }
};

fn hid(gpa: Allocator, op: u8, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(gpa, "{c}" ++ fmt, .{op} ++ args);
}

/// serde_json's float text: whole numbers keep `.0`.
fn writeFloat(buf: []u8, v: f64) []const u8 {
    if (@floor(v) == v and @abs(v) < 1e16) return std.fmt.bufPrint(buf, "{d}.0", .{v}) catch "0.0";
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0.0";
}

pub fn hidMessages(gpa: Allocator, input: json.Value) !Messages {
    var m: Messages = .{};
    errdefer m.deinit(gpa);
    const fail = struct {
        fn f(g: Allocator, out: *Messages, comptime fmt: []const u8, args: anytype) !Messages {
            out.err = try std.fmt.allocPrint(g, fmt, args);
            return out.*;
        }
    }.f;
    if (input != .object) return fail(gpa, &m, "invalid input", .{});
    const o = input.object;
    const kind = if (o.get("kind")) |k| (if (k == .string) k.string else "") else "";
    if (std.mem.eql(u8, kind, "touch")) {
        const phase = if (o.get("phase")) |p| (if (p == .string) p.string else "") else "";
        if (!std.mem.eql(u8, phase, "begin") and !std.mem.eql(u8, phase, "move") and !std.mem.eql(u8, phase, "end"))
            return fail(gpa, &m, "unknown variant `{s}`, expected one of `begin`, `move`, `end`", .{phase});
        const x = numberOf(o.get("x")) orelse return fail(gpa, &m, "missing field `x`", .{});
        const y = numberOf(o.get("y")) orelse return fail(gpa, &m, "missing field `y`", .{});
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return fail(gpa, &m, "touch outside the screen", .{});
        var xb: [64]u8 = undefined;
        var yb: [64]u8 = undefined;
        try m.list.append(gpa, try hid(gpa, op_touch, "{{\"type\":\"{s}\",\"x\":{s},\"y\":{s}}}", .{
            phase, writeFloat(&xb, std.math.clamp(x, 0.0, 1.0)), writeFloat(&yb, std.math.clamp(y, 0.0, 1.0)),
        }));
    } else if (std.mem.eql(u8, kind, "button")) {
        const b = if (o.get("button")) |v| (if (v == .string) v.string else "") else "";
        // Home is a named button; the rest are consumer-page HID usages.
        const body: []const u8 = if (std.mem.eql(u8, b, "home"))
            "{\"button\":\"home\"}"
        else if (std.mem.eql(u8, b, "lock"))
            "{\"button\":\"power\",\"page\":12,\"usage\":48}"
        else if (std.mem.eql(u8, b, "volumeUp"))
            "{\"button\":\"volume-up\",\"page\":12,\"usage\":233}"
        else if (std.mem.eql(u8, b, "volumeDown"))
            "{\"button\":\"volume-down\",\"page\":12,\"usage\":234}"
        else
            return fail(gpa, &m, "unknown variant `{s}`, expected one of `home`, `lock`, `volumeUp`, `volumeDown`", .{b});
        try m.list.append(gpa, try hid(gpa, op_button, "{s}", .{body}));
    } else if (std.mem.eql(u8, kind, "text")) {
        const text = if (o.get("text")) |v| (if (v == .string) v.string else null) else null;
        const t = text orelse return fail(gpa, &m, "missing field `text`", .{});
        const view = std.unicode.Utf8View.init(t) catch return fail(gpa, &m, "invalid text", .{});
        if ((std.unicode.utf8CountCodepoints(t) catch t.len) > max_text_chars)
            return fail(gpa, &m, "send at most {d} characters at a time", .{max_text_chars});
        var it = view.iterator();
        while (it.nextCodepoint()) |c| {
            if (c == '\r') continue;
            const u = keyUsage(c) orelse {
                var cb: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &cb) catch 0;
                return fail(gpa, &m, "'{s}' can't be typed on a US keyboard", .{cb[0..n]});
            };
            if (u[1]) try m.list.append(gpa, try hid(gpa, op_key, "{{\"type\":\"down\",\"usage\":{d}}}", .{left_shift}));
            try m.list.append(gpa, try hid(gpa, op_key, "{{\"type\":\"down\",\"usage\":{d}}}", .{u[0]}));
            try m.list.append(gpa, try hid(gpa, op_key, "{{\"type\":\"up\",\"usage\":{d}}}", .{u[0]}));
            if (u[1]) try m.list.append(gpa, try hid(gpa, op_key, "{{\"type\":\"up\",\"usage\":{d}}}", .{left_shift}));
        }
    } else if (std.mem.eql(u8, kind, "key")) {
        const key = if (o.get("key")) |v| (if (v == .string) v.string else "") else "";
        const usage = namedKey(key) orelse return fail(gpa, &m, "unknown key \"{s}\"", .{key});
        try m.list.append(gpa, try hid(gpa, op_key, "{{\"type\":\"down\",\"usage\":{d}}}", .{usage}));
        try m.list.append(gpa, try hid(gpa, op_key, "{{\"type\":\"up\",\"usage\":{d}}}", .{usage}));
    } else {
        return fail(gpa, &m, "unknown variant `{s}`, expected one of `touch`, `button`, `text`, `key`", .{kind});
    }
    return m;
}

fn numberOf(v: ?json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------- MJPEG

/// `multipart/x-mixed-replace` JPEG parts with `Content-Length`, split into frames.
pub const MjpegParser = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(p: *MjpegParser, gpa: Allocator) void {
        p.buf.deinit(gpa);
    }

    /// Feed a chunk; the newest frame it completed (owned), if any.
    pub fn push(p: *MjpegParser, gpa: Allocator, chunk: []const u8) error{ BadPart, OutOfMemory }!?[]u8 {
        try p.buf.appendSlice(gpa, chunk);
        var newest: ?[]u8 = null;
        errdefer if (newest) |n| gpa.free(n);
        while (true) {
            const header_end = std.mem.indexOf(u8, p.buf.items, "\r\n\r\n") orelse {
                if (p.buf.items.len > 64 * 1024 and std.mem.indexOf(u8, p.buf.items, "Content-Length") == null) return error.BadPart;
                break;
            };
            const length = contentLength(p.buf.items[0..header_end]) orelse return error.BadPart;
            if (length > max_frame_bytes) return error.BadPart;
            const body_start = header_end + 4;
            if (p.buf.items.len < body_start + length) break;
            if (newest) |n| gpa.free(n);
            newest = try gpa.dupe(u8, p.buf.items[body_start .. body_start + length]);
            const rest = p.buf.items.len - (body_start + length);
            std.mem.copyForwards(u8, p.buf.items[0..rest], p.buf.items[body_start + length ..]);
            p.buf.shrinkRetainingCapacity(rest);
        }
        return newest;
    }

    fn contentLength(header: []const u8) ?usize {
        var lines = std.mem.splitScalar(u8, header, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch null;
        }
        return null;
    }
};

/// Milliseconds between a viewer's frames: its cap (default 15), within 1..20 a second.
pub fn viewerGapMs(max_fps: ?u32) i64 {
    const fps = std.math.clamp(max_fps orelse default_viewer_fps, 1, source_fps);
    return @divTrunc(1000, @as(i64, fps));
}

// ---------------------------------------------------------------- simctl

pub const Device = struct { id: []const u8, name: []const u8, runtime: []const u8, booted: bool };

/// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`; other platforms → null.
pub fn iosRuntime(a: Allocator, key: []const u8) !?[]const u8 {
    const last = key[(std.mem.lastIndexOfScalar(u8, key, '.') orelse return null) + 1 ..];
    if (!std.mem.startsWith(u8, last, "iOS-")) return null;
    const v = try a.dupe(u8, last[4..]);
    std.mem.replaceScalar(u8, v, '-', '.');
    return try std.fmt.allocPrint(a, "iOS {s}", .{v});
}

/// `simctl list devices available -j`: the iOS devices with well-formed ids
/// (uppercased), booted first, then newest runtime, then by name. In `a`.
pub fn parseDevices(a: Allocator, text: []const u8) ![]Device {
    const parsed = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch return error.BadDeviceList;
    if (parsed != .object) return error.BadDeviceList;
    const devices = parsed.object.get("devices") orelse return error.BadDeviceList;
    if (devices != .object) return error.BadDeviceList;
    var out: std.ArrayList(Device) = .empty;
    var it = devices.object.iterator();
    while (it.next()) |e| {
        const runtime = (try iosRuntime(a, e.key_ptr.*)) orelse continue;
        if (e.value_ptr.* != .array) return error.BadDeviceList;
        for (e.value_ptr.array.items) |d| {
            if (d != .object) return error.BadDeviceList;
            const udid = d.object.get("udid") orelse return error.BadDeviceList;
            const name = d.object.get("name") orelse return error.BadDeviceList;
            const state = d.object.get("state") orelse return error.BadDeviceList;
            if (udid != .string or name != .string or state != .string) return error.BadDeviceList;
            if (!checkId(udid.string)) continue;
            const id = try a.dupe(u8, udid.string);
            for (id) |*c| c.* = std.ascii.toUpper(c.*);
            try out.append(a, .{ .id = id, .name = name.string, .runtime = runtime, .booted = std.mem.eql(u8, state.string, "Booted") });
        }
    }
    const Less = struct {
        fn version(r: []const u8, nums: *[4]u32) usize {
            var n: usize = 0;
            var parts = std.mem.splitScalar(u8, std.mem.trimStart(u8, r, "iOS "), '.');
            while (parts.next()) |p| {
                if (n == nums.len) break;
                nums[n] = std.fmt.parseInt(u32, p, 10) catch continue;
                n += 1;
            }
            return n;
        }
        fn f(_: void, x: Device, y: Device) bool {
            if (x.booted != y.booted) return x.booted;
            var xa: [4]u32 = undefined;
            var ya: [4]u32 = undefined;
            const xo = std.mem.order(u32, xa[0..version(x.runtime, &xa)], ya[0..version(y.runtime, &ya)]);
            if (xo != .eq) return xo == .gt;
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    };
    std.mem.sort(Device, out.items, {}, Less.f);
    return out.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn messagesFor(text: []const u8) !Messages {
    const v = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer v.deinit();
    return hidMessages(testing.allocator, v.value);
}

fn expectMessages(text: []const u8, want: []const []const u8) !void {
    var m = try messagesFor(text);
    defer m.deinit(testing.allocator);
    if (m.err) |e| {
        std.debug.print("unexpected error: {s}\n", .{e});
        return error.TestUnexpectedError;
    }
    try testing.expectEqual(want.len, m.list.items.len);
    for (want, m.list.items) |w, g| try testing.expectEqualStrings(w, g);
}

fn expectRefused(text: []const u8, want: []const u8) !void {
    var m = try messagesFor(text);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings(want, m.err orelse return error.TestExpectedError);
}

test "simulator input becomes the helper's opcode and JSON" {
    try expectMessages("{\"kind\":\"touch\",\"phase\":\"begin\",\"x\":1.4,\"y\":0.25}", &.{"\x03{\"type\":\"begin\",\"x\":1.0,\"y\":0.25}"});
    try expectMessages("{\"kind\":\"touch\",\"phase\":\"move\",\"x\":-0.5,\"y\":0.5}", &.{"\x03{\"type\":\"move\",\"x\":0.0,\"y\":0.5}"});
    try expectMessages("{\"kind\":\"button\",\"button\":\"home\"}", &.{"\x04{\"button\":\"home\"}"});
    try expectMessages("{\"kind\":\"button\",\"button\":\"lock\"}", &.{"\x04{\"button\":\"power\",\"page\":12,\"usage\":48}"});
    try expectMessages("{\"kind\":\"button\",\"button\":\"volumeUp\"}", &.{"\x04{\"button\":\"volume-up\",\"page\":12,\"usage\":233}"});
    try expectMessages("{\"kind\":\"text\",\"text\":\"a\"}", &.{ "\x06{\"type\":\"down\",\"usage\":4}", "\x06{\"type\":\"up\",\"usage\":4}" });
    try expectMessages("{\"kind\":\"key\",\"key\":\"enter\"}", &.{ "\x06{\"type\":\"down\",\"usage\":40}", "\x06{\"type\":\"up\",\"usage\":40}" });
    try expectRefused("{\"kind\":\"key\",\"key\":\"f13\"}", "unknown key \"f13\"");
    try expectRefused("{\"kind\":\"text\",\"text\":\"h\u{e9}\"}", "'\u{e9}' can't be typed on a US keyboard");
    try expectRefused("{\"kind\":\"exec\",\"cmd\":\"ls\"}", "unknown variant `exec`, expected one of `touch`, `button`, `text`, `key`");
    const long: [max_text_chars + 1]u8 = @splat('a');
    const req = try std.fmt.allocPrint(testing.allocator, "{{\"kind\":\"text\",\"text\":\"{s}\"}}", .{&long});
    defer testing.allocator.free(req);
    try expectRefused(req, "send at most 500 characters at a time");
}

test "US keyboard table: shift where needed, CR dropped" {
    try expectMessages("{\"kind\":\"text\",\"text\":\"Z\"}", &.{ "\x06{\"type\":\"down\",\"usage\":225}", "\x06{\"type\":\"down\",\"usage\":29}", "\x06{\"type\":\"up\",\"usage\":29}", "\x06{\"type\":\"up\",\"usage\":225}" });
    try expectMessages("{\"kind\":\"text\",\"text\":\"0\"}", &.{ "\x06{\"type\":\"down\",\"usage\":39}", "\x06{\"type\":\"up\",\"usage\":39}" });
    try expectMessages("{\"kind\":\"text\",\"text\":\"?\"}", &.{ "\x06{\"type\":\"down\",\"usage\":225}", "\x06{\"type\":\"down\",\"usage\":56}", "\x06{\"type\":\"up\",\"usage\":56}", "\x06{\"type\":\"up\",\"usage\":225}" });
    try expectMessages("{\"kind\":\"text\",\"text\":\"\\r\\n\"}", &.{ "\x06{\"type\":\"down\",\"usage\":40}", "\x06{\"type\":\"up\",\"usage\":40}" });
    try testing.expectEqual(@as(?u16, 82), namedKey("up"));
}

test "only UDIDs pass; the allowlist compares uppercase" {
    try testing.expect(checkId("6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1"));
    for ([_][]const u8{ "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A", "../../etc/passwd", "6BBA9FD8_EFAD-45B7-B9FC-30715804D2A1", "6BBA9FD8-EFAD-45B7-B9FC-30715804D2AG" }) |id| try testing.expect(!checkId(id));
    try testing.expect(allowed(null, "X"));
    try testing.expect(allowed(" 6bba9fd8-efad-45b7-b9fc-30715804d2a1 ,x", "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1"));
    try testing.expect(!allowed("11111111-2222-3333-4444-555555555555", "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1"));
}

fn part(a: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {d}\r\n\r\n{s}\r\n", .{ body.len, body });
}

test "MJPEG frames split across chunks come out whole, newest first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stream = try std.mem.concat(a, u8, &.{ try part(a, "\xff\xd8one\xff\xd9"), try part(a, "\xff\xd8second\xff\xd9"), try part(a, "\xff\xd8three\xff\xd9") });
    var p: MjpegParser = .{};
    defer p.deinit(testing.allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < stream.len) : (i += 7) {
        if (try p.push(testing.allocator, stream[i..@min(i + 7, stream.len)])) |f| {
            defer testing.allocator.free(f);
            try seen.append(a, try a.dupe(u8, f));
        }
    }
    try testing.expectEqual(@as(usize, 3), seen.items.len);
    try testing.expectEqualStrings("\xff\xd8three\xff\xd9", seen.items[2]);
    var bad: MjpegParser = .{};
    defer bad.deinit(testing.allocator);
    try testing.expectError(error.BadPart, bad.push(testing.allocator, "--frame\r\nContent-Type: image/jpeg\r\n\r\nxx"));
    var huge: MjpegParser = .{};
    defer huge.deinit(testing.allocator);
    const h = try std.fmt.allocPrint(a, "--frame\r\nContent-Length: {d}\r\n\r\n", .{max_frame_bytes + 1});
    try testing.expectError(error.BadPart, huge.push(testing.allocator, h));
}

test "viewer pacing clamps to 1..20 frames a second" {
    try testing.expectEqual(@as(i64, 66), viewerGapMs(null));
    try testing.expectEqual(@as(i64, 50), viewerGapMs(60));
    try testing.expectEqual(@as(i64, 1000), viewerGapMs(0));
    try testing.expectEqual(@as(i64, 166), viewerGapMs(6));
}

test "simctl's list becomes iOS devices, booted first, newest runtime next" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list =
        \\{"devices":{
        \\ "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[{"udid":"11111111-2222-3333-4444-555555555555","name":"Phone B","state":"Shutdown"}],
        \\ "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"6bba9fd8-efad-45b7-b9fc-30715804d2a1","name":"Phone A","state":"Shutdown"},
        \\   {"udid":"bad id","name":"Broken","state":"Booted"}],
        \\ "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"22222222-2222-3333-4444-555555555555","name":"Watch","state":"Booted"}],
        \\ "com.apple.CoreSimulator.SimRuntime.iOS-25-0":[{"udid":"33333333-2222-3333-4444-555555555555","name":"Old","state":"Booted"}]
        \\}}
    ;
    const d = try parseDevices(arena.allocator(), list);
    try testing.expectEqual(@as(usize, 3), d.len);
    try testing.expectEqualStrings("Old", d[0].name);
    try testing.expect(d[0].booted);
    try testing.expectEqualStrings("6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1", d[1].id);
    try testing.expectEqualStrings("iOS 27.0", d[1].runtime);
    try testing.expectEqualStrings("iOS 26.2", d[2].runtime);
    try testing.expectError(error.BadDeviceList, parseDevices(arena.allocator(), "{}"));
}
