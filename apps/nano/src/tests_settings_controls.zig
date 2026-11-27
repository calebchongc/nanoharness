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

test "settings controls: settings catalogue and search no longer offer the Appshots page" {
    for (Section.all) |s| try testing.expect(!std.mem.eql(u8, s.label(), "Appshots"));
    var buf: [Section.all.len]Section = undefined;
    try testing.expectEqual(@as(usize, 0), view.matches("screenshot capture", &buf).len);
    try testing.expectEqual(@as(usize, 0), view.matches("appshots", &buf).len);

    // A file saved while the page existed still loads: its section falls
    // back, and its Appshots choices are kept as they were.
    var store: settings.Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer store.deinit();
    store.apply(
        \\{"settingsSection":"appshots","appshotsEnabled":true,"appshotSoundEnabled":false,"appshotDestination":"new-session","soundEnabled":false}
    );
    try testing.expect(!std.mem.eql(u8, store.section.key(), "appshots"));
    try testing.expect(store.get(.appshots_enabled));
    try testing.expect(!store.get(.appshot_sound_enabled));
    try testing.expectEqualStrings("new-session", store.text("appshotDestination").?);
    try testing.expect(!store.get(.sound_enabled));

    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    openOn(&h, .devices, 1100);
    try testing.expect(h.t.hasText("Usage"));
    try testing.expect(!h.t.hasText("Appshots"));
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

test "settings controls: appearance offers no pause-in-background switch that nothing reads" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    openOn(&h, .appearance, 5200);
    try testing.expect(h.t.hasText("Reduce motion"));
    try testing.expect(!h.t.hasText("Pause animations in background"));
}

/// Settings › Agents' Screen Recording card alone, with the grant given.
const ScreenCard = struct {
    fn draw(a: *@import("app.zig").App, c: *ui.Context) void {
        const prev = view.inner_w;
        defer view.inner_w = prev;
        view.inner_w = 720;
        const root = ui.div(c).column().w(view.inner_w).p(16);
        defer root.end();
        @import("view_settings_agents_cards.zig").screenAccessFor(c, a, @import("theme.zig").colors(false), false);
    }
};

test "settings controls: screen recording offers no restart button that only says it cannot restart" {
    @import("theme.zig").registerFonts();
    var a: @import("app.zig").App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, ScreenCard.draw), .{ .width = 760, .height = 220 });
    defer t.deinit();
    t.settle(0.2);
    try testing.expect(t.hasText("Allow"));
    // After asking: System Settings, and words to quit and reopen.
    a.view.agents.screen_requested = true;
    a.redraw();
    t.settle(0.2);
    if (std.c.getenv("NANO_SETTINGS_SNAP_DIR")) |path| {
        var buf: [1024]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&buf, "{s}/screen-recording.png", .{std.mem.span(path)}));
    }
    try testing.expect(t.hasText("Screen Recording"));
    try testing.expect(t.hasText("Open System Settings"));
    try testing.expect(!t.hasText("Restart Harness"));
    try testing.expect(t.containsText("quit and reopen Harness"));
}
