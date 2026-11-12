//! The built-in theme catalogs (`themes.json`, desktop; `ios_themes.json`,
//! mobile) are checked-in inputs, edited directly: no generator runs at
//! build time. `firstProblem` is what keeps a hand edit honest: every
//! variant named once, in its family, light or dark, with every role the
//! app derives colours from, each a `#rrggbb` or `#rrggbbaa` colour.
const std = @import("std");
const json = std.json;

pub const Problem = struct { variant: []const u8, what: []const u8 };

const sections = [_][]const u8{ "colors", "accent", "terminal", "syntax" };

fn isHexColor(s: []const u8) bool {
    if ((s.len != 7 and s.len != 9) or s[0] != '#') return false;
    for (s[1..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The first string under `v` that isn't a colour, if any.
fn firstNonColor(v: json.Value) ?[]const u8 {
    switch (v) {
        .string => |s| return if (isHexColor(s)) null else s,
        .array => |list| for (list.items) |x| if (firstNonColor(x)) |bad| return bad,
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| if (firstNonColor(e.value_ptr.*)) |bad| return bad;
        },
        else => return "(not a colour string)",
    }
    return null;
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// The first thing wrong with catalog `text`, or null; strings in `arena`.
pub fn firstProblem(arena: std.mem.Allocator, text: []const u8) !?Problem {
    const doc = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return .{ .variant = "", .what = "not JSON" };
    if (doc != .object) return .{ .variant = "", .what = "not an object" };
    const families = doc.object.get("families") orelse return .{ .variant = "", .what = "no families" };
    if (families != .array or families.array.items.len == 0) return .{ .variant = "", .what = "no families" };
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (families.array.items) |f| {
        if (f != .object) return .{ .variant = "", .what = "family is not an object" };
        const family_id = str(f.object, "id") orelse return .{ .variant = "", .what = "family without id" };
        const variants = f.object.get("variants") orelse return .{ .variant = family_id, .what = "family without variants" };
        if (variants != .array or variants.array.items.len == 0) return .{ .variant = family_id, .what = "family without variants" };
        for (variants.array.items) |v| {
            if (v != .object) return .{ .variant = family_id, .what = "variant is not an object" };
            const o = v.object;
            const id = str(o, "id") orelse return .{ .variant = family_id, .what = "variant without id" };
            if (id.len == 0) return .{ .variant = family_id, .what = "variant without id" };
            const gop = try seen.getOrPut(arena, id);
            if (gop.found_existing) return .{ .variant = id, .what = "id listed twice" };
            if (!std.mem.eql(u8, str(o, "familyId") orelse @as([]const u8, ""), family_id)) return .{ .variant = id, .what = "familyId is not its family's id" };
            if ((str(o, "name") orelse @as([]const u8, "")).len == 0) return .{ .variant = id, .what = "no name" };
            const appearance = str(o, "appearance") orelse @as([]const u8, "");
            if (!std.mem.eql(u8, appearance, "light") and !std.mem.eql(u8, appearance, "dark")) return .{ .variant = id, .what = "appearance is neither light nor dark" };
            for (sections) |name| {
                const section = o.get(name) orelse return .{ .variant = id, .what = name };
                if (section != .object) return .{ .variant = id, .what = name };
                if (firstNonColor(section)) |_| return .{ .variant = id, .what = name };
            }
        }
    }
    return null;
}

/// Variants in catalog `text` (0 when it doesn't parse).
pub fn variantCount(arena: std.mem.Allocator, text: []const u8) usize {
    const doc = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return 0;
    var n: usize = 0;
    for (doc.object.get("families").?.array.items) |f| n += f.object.get("variants").?.array.items.len;
    return n;
}

const testing = std.testing;

test "the checked-in desktop and mobile theme catalogs are whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ @import("themes_json").json, @import("ios_themes_json").json }) |text| {
        if (try firstProblem(a, text)) |p| {
            std.debug.print("theme catalog: {s}: {s}\n", .{ p.variant, p.what });
            return error.BrokenCatalog;
        }
    }
    try testing.expectEqual(@as(usize, 35), variantCount(a, @import("themes_json").json));
    try testing.expectEqual(@as(usize, 31), variantCount(a, @import("ios_themes_json").json));
    // Every desktop variant reaches the app: none dropped while deriving roles.
    try testing.expect(@import("themes.zig").all().len >= 35);
}

test "a hand-edited catalog with a mistake is refused, naming the variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok_variant =
        \\{"id":"x-dark","familyId":"x","name":"X Dark","appearance":"dark","colors":{"text":"#ffffff"},"accent":{"primary":"#112233","glyph":["#000000","#ffffffff"]},"terminal":{"ansi":["#000000"]},"syntax":{"comment":"#808080"}}
    ;
    try testing.expectEqual(@as(?Problem, null), try firstProblem(a, "{\"families\":[{\"id\":\"x\",\"variants\":[" ++ ok_variant ++ "]}]}"));
    const twice = try firstProblem(a, "{\"families\":[{\"id\":\"x\",\"variants\":[" ++ ok_variant ++ "," ++ ok_variant ++ "]}]}");
    try testing.expectEqualStrings("x-dark", twice.?.variant);
    try testing.expectEqualStrings("id listed twice", twice.?.what);
    const wrong_family = try firstProblem(a, "{\"families\":[{\"id\":\"y\",\"variants\":[" ++ ok_variant ++ "]}]}");
    try testing.expectEqualStrings("familyId is not its family's id", wrong_family.?.what);
    const bad_color = try firstProblem(a,
        \\{"families":[{"id":"x","variants":[{"id":"x-dark","familyId":"x","name":"X","appearance":"dark","colors":{"text":"white"},"accent":{},"terminal":{},"syntax":{}}]}]}
    );
    try testing.expectEqualStrings("colors", bad_color.?.what);
    const no_syntax = try firstProblem(a,
        \\{"families":[{"id":"x","variants":[{"id":"x-dark","familyId":"x","name":"X","appearance":"dim","colors":{},"accent":{},"terminal":{}}]}]}
    );
    try testing.expectEqualStrings("appearance is neither light nor dark", no_syntax.?.what);
    try testing.expectEqualStrings("not JSON", (try firstProblem(a, "{")).?.what);
}
