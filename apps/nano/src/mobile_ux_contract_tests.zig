//! The Zig phone app's runner for `apps/parity/ux-contract.json`: as
//! ParityTests.swift and ParityTest.kt do for theirs, each string of a group
//! the Zig app has ported must appear as a quoted literal in its own source
//! tree (`apps/nano/src`), so a reworded label or a copy never ported fails
//! here. Groups not ported to the Zig app yet are listed, not skipped
//! silently; porting one moves it into `ported`.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const opts = @import("parity_options");

/// The groups whose screens the Zig phone app has.
const ported = [_][]const u8{"settings"};
/// Not yet: the queue panel (queuePanel), the queue editor's protected edits (composer), Home's
/// controls (home), Bring your agent (onboarding), connectivity and chat
/// mode.
const not_yet = [_][]const u8{ "queuePanel", "composer", "home", "onboarding", "connectivity", "chatMode" };

/// Every `.zig` file's text under `src`, joined.
fn sources(arena: std.mem.Allocator) ![]const u8 {
    const src = try std.fs.path.join(arena, &.{ opts.nano_dir, "src" });
    var dir = try std.Io.Dir.cwd().openDir(testing.io, src, .{ .iterate = true });
    defer dir.close(testing.io);
    var out: std.ArrayList(u8) = .empty;
    var it = dir.iterate();
    while (try it.next(testing.io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        // This runner's own file would satisfy every check.
        if (std.mem.eql(u8, e.name, "mobile_ux_contract_tests.zig")) continue;
        const text = try dir.readFileAlloc(testing.io, e.name, arena, .limited(8 << 20));
        try out.appendSlice(arena, text);
    }
    return out.items;
}

test "mobile parity: ux-contract.json strings the Zig app shows are its literals" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path = try std.fs.path.join(a, &.{ opts.vectors_dir, "..", "ux-contract.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20));
    const v = try json.parseFromSliceLeaky(json.Value, a, text, .{});
    const groups = v.object.get("strings").?.object;
    // Every group is either ported or listed as not yet.
    var it = groups.iterator();
    while (it.next()) |g| {
        const known = for (ported ++ not_yet) |n| {
            if (std.mem.eql(u8, n, g.key_ptr.*)) break true;
        } else false;
        if (!known) std.debug.print("ux-contract group not listed: {s}\n", .{g.key_ptr.*});
        try testing.expect(known);
    }
    const src = try sources(a);
    var missing: usize = 0;
    for (ported) |name| {
        for (groups.get(name).?.array.items) |s| {
            const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{s.string});
            if (std.mem.indexOf(u8, src, quoted) == null) {
                std.debug.print("ux-contract {s}: no literal {s}\n", .{ name, quoted });
                missing += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}
