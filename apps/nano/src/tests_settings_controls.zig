//! Settings offers only controls that do what they say, each once. Synthetic
//! data only (the tab-strip Harness's made-up chats); no account or host data.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const view = @import("view_settings.zig");
const settings = @import("settings.zig");
const shortcuts = @import("shortcuts.zig");
const Section = settings.Section;

fn snap(h: *Harness, name: []const u8) !void {
    if (std.c.getenv("NANO_SETTINGS_SNAP_DIR")) |path| {
        var buf: [1024]u8 = undefined;
        try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(path), name }));
    }
}

/// Opens Settings on `section`, the window tall enough that a long page is
/// laid out whole.
fn openOn(h: *Harness, section: Section, height: f32) void {
    h.a.settings.setSection(section);
    view.open(&h.a);
    h.t.resize(1200, height);
    h.t.settle(0.3);
}

test "settings controls: reduce motion resolves System, On and Off against the system" {
    const RM = settings.ReduceMotion;
    // The six choice × system combinations.
    try testing.expect(!RM.system.resolve(false));
    try testing.expect(RM.system.resolve(true));
    try testing.expect(RM.on.resolve(false));
    try testing.expect(RM.on.resolve(true));
    try testing.expect(!RM.off.resolve(false));
    try testing.expect(!RM.off.resolve(true));
    // As saved; anything else (or nothing) follows the system.
    try testing.expectEqual(RM.system, RM.fromKey(null));
    try testing.expectEqual(RM.on, RM.fromKey("on"));
    try testing.expectEqual(RM.off, RM.fromKey("off"));
    try testing.expectEqual(RM.system, RM.fromKey("sometimes"));
    const appearance = @import("view_settings_appearance.zig");
    try testing.expectEqualStrings("Following the system, which currently allows motion.", appearance.reduceMotionCaption(.system, false));
    try testing.expectEqualStrings("Following the system, which currently asks for less motion.", appearance.reduceMotionCaption(.system, true));
}

test "settings controls: reduce motion On and Off override what the system asks for" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    // The system allows motion; On holds every transition still.
    h.t.ctx.reduce_motion = false;
    h.t.ctx.reduced_motion = false;
    h.a.settings.setText("reduceMotion", "on");
    h.a.redraw();
    h.t.settle(0.2);
    try testing.expect(h.t.ctx.reduce_motion);
    try testing.expect(h.t.ctx.reduced_motion);
    // Off lets motion play.
    h.a.settings.setText("reduceMotion", "off");
    h.a.redraw();
    h.t.settle(0.2);
    try testing.expect(!h.t.ctx.reduce_motion);
    try testing.expect(!h.t.ctx.reduced_motion);
    try testing.expectEqual(@as(?bool, false), h.t.ctx.reduce_motion_override);
}

test "settings controls: reduce motion System follows the system again, and the caption says what it asks" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    // The system asks for less motion; Off overrode it, System hands it back.
    h.t.ctx.system_reduce_motion = true;
    h.a.settings.setText("reduceMotion", "off");
    h.a.redraw();
    h.t.settle(0.2);
    try testing.expect(!h.t.ctx.reduced_motion);
    h.a.settings.setText("reduceMotion", "system");
    openOn(&h, .appearance, 5200);
    try testing.expect(h.t.ctx.reduce_motion);
    try testing.expect(h.t.ctx.reduced_motion);
    try testing.expectEqual(@as(?bool, null), h.t.ctx.reduce_motion_override);
    try testing.expect(h.t.hasText("Following the system, which currently asks for less motion."));
    h.t.ctx.system_reduce_motion = false;
    h.a.redraw();
    h.t.settle(0.2);
    try testing.expect(h.t.hasText("Following the system, which currently allows motion."));
    // The page's own chips set it: "On" on the Reduce motion row.
    const title = h.t.findText("Reduce motion") orelse return error.MissingReduceMotionRow;
    const on = for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "On") and @abs(node.rect.y - title.y) < 40) break node.rect,
        else => {},
    } else return error.MissingReduceMotionOn;
    h.t.click(on.x + on.w / 2, on.y + on.h / 2);
    h.t.settle(0.2);
    try testing.expectEqual(settings.ReduceMotion.on, h.a.settings.reduceMotion());
    try testing.expect(h.t.ctx.reduced_motion);
    try testing.expect(h.t.hasText("Animations skip straight to their final state."));
}
