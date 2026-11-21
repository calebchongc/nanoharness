//! Project actions stay reachable after the unified strip replaced titlebar controls.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, unavailable: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"p","deviceId":"synthetic","path":"/synthetic/project"}]
        , .{});
        defer spaces.deinit();
        try h.a.spaces.replace(spaces.value);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"c","spaceId":"p","deviceId":"synthetic","title":"Synthetic actions"}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("c", null);
        h.a.actions.status = if (unavailable) .unavailable else .ready;
        h.a.actions.error_text = "Synthetic action failure";
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(0.3);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

fn countSent(a: *const App, method: []const u8) !usize {
    var n: usize = 0;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const m = parsed.value.object.get("method").?.string;
        if (std.mem.eql(u8, m, method)) n += 1;
    }
    return n;
}

fn setScene(a: *App, body: []const u8) !void {
    if (a.engine.scene) |*s| s.deinit();
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa, body, .{});
    a.engine.state = .connected;
}

fn pump(h: *Harness) void {
    _ = h.a.engine.pump();
    h.t.settle(0.3);
}

test "project actions unavailable control stays reachable below the unified strip" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const anchor = h.a.actions.anchor orelse return error.MissingActionsToolbar;
    try testing.expect(anchor.y >= 42 and anchor.y + anchor.h <= 79);
    h.t.click(anchor.x + anchor.w / 2, anchor.y + anchor.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Synthetic action failure"));
    try testing.expect(h.t.hasText("Retry"));
}

test "project actions toolbar opens the real action editor" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const add = h.t.findText("Add action") orelse return error.MissingActionsToolbar;
    try testing.expect(add.y >= 42 and add.y < 79);
    try h.t.clickText("Add action");
    h.t.settle(0.3);
    try testing.expect(h.a.actions.editor != null);
}

test "project actions recover on reconnect after a disconnected restore gap (#45)" {
    var h: Harness = undefined;
    @import("theme.zig").registerFonts();
    h.a = .init(testing.allocator, testing.io, 1);
    h.a.offscreen = true;
    h.a.dark = true;
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"p","deviceId":"synthetic","path":"/synthetic/project"}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"c","spaceId":"p","deviceId":"synthetic","title":"Synthetic actions"}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.settings.apply(
        \\{"openTabs":["c"],"lastChatId":"c"}
    );
    try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer h.deinit();

    // Simulate a transient disconnect gap while WatchChats restores the saved tab.
    h.a.engine.state = .disconnected;
    h.a.engine.scene = null;
    h.a.restoreTabs();
    @import("app_panels.zig").chatsArrived(&h.a);
    h.t.settle(0.3);
    try testing.expectEqualStrings("c", h.a.selected.?);
    const poisoned_during_gap = h.a.actions.status == .unavailable;

    // Reconnect with the same chat still selected (app_panels.chatChanged early-returns).
    try setScene(&h.a,
        \\{"EngineInfo":{"deviceId":"synthetic"},"EngineReady":{},"ListHarnesses":{"harnesses":[]},"ListModels":{"models":[]},
        \\ "ListProjectActions":{"actions":[{"id":"act-1","name":"Test","command":"echo ok","icon":"test","runOnWorktreeCreate":false}]}}
    );
    App.stateChanged(&h.a, .connected);
    @import("app_panels.zig").chatsArrived(&h.a);
    pump(&h);
    if (h.a.actions.status == .unavailable) {
        if (h.a.actions.anchor) |anchor| {
            h.t.click(anchor.x + anchor.w / 2, anchor.y + anchor.h / 2);
            h.t.settle(0.3);
        }
        h.snap("actions-45-before");
    } else {
        h.snap("actions-45-after");
    }

    try testing.expect(!poisoned_during_gap);

    try testing.expectEqual(@import("app_actions.zig").Status.ready, h.a.actions.status);
    try testing.expect(h.a.actions.error_text == null);
    try testing.expectEqual(@as(usize, 1), h.a.actions.list.len);
    try testing.expectEqualStrings("Test", h.a.actions.list[0].name);
    try testing.expectEqual(@as(usize, 1), try countSent(&h.a, "ListProjectActions"));
    try testing.expect(h.t.hasText("Test"));
}

test "project actions reconnect retries an unavailable snapshot and clears stale error text (#45)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    if (h.a.actions.space) |old| h.a.gpa.free(old);
    h.a.actions.space = try h.a.gpa.dupe(u8, "p");
    h.a.actions.error_text = "not connected";

    try setScene(&h.a,
        \\{"EngineInfo":{"deviceId":"synthetic"},"EngineReady":{},"ListHarnesses":{"harnesses":[]},"ListModels":{"models":[]},
        \\ "ListProjectActions":{"actions":[{"id":"act-1","name":"Test","command":"echo ok","icon":"test","runOnWorktreeCreate":false}]}}
    );
    App.stateChanged(&h.a, .connected);
    pump(&h);

    try testing.expectEqual(@import("app_actions.zig").Status.ready, h.a.actions.status);
    try testing.expect(h.a.actions.error_text == null);
    try testing.expectEqual(@as(usize, 1), h.a.actions.list.len);
    try testing.expectEqualStrings("Test", h.a.actions.list[0].name);
    try testing.expectEqual(@as(usize, 1), try countSent(&h.a, "ListProjectActions"));
}

test "project actions preserve real server errors without retrying every frame and still allow manual Retry (#45)" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.actions.status = .idle;
    h.a.actions.error_text = null;

    try setScene(&h.a,
        \\{"EngineInfo":{"deviceId":"synthetic"},"EngineReady":{},"ListHarnesses":{"harnesses":[]},"ListModels":{"models":[]},
        \\ "ListProjectActions":{"$seq":[{"$err":"project config invalid"},{"actions":[{"id":"act-1","name":"Test","command":"echo ok","icon":"test","runOnWorktreeCreate":false}]}]}}
    );
    App.stateChanged(&h.a, .connected);
    pump(&h);

    try testing.expectEqual(@import("app_actions.zig").Status.unavailable, h.a.actions.status);
    try testing.expectEqualStrings("project config invalid", h.a.actions.error_text.?);
    try testing.expectEqual(@as(usize, 1), try countSent(&h.a, "ListProjectActions"));

    h.t.settle(0.5);
    _ = h.a.engine.pump();
    h.t.settle(0.5);
    try testing.expectEqual(@as(usize, 1), try countSent(&h.a, "ListProjectActions"));

    const anchor = h.a.actions.anchor orelse return error.MissingActionsToolbar;
    h.t.click(anchor.x + anchor.w / 2, anchor.y + anchor.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("project config invalid"));
    try testing.expect(h.t.hasText("Retry"));
    try h.t.clickText("Retry");
    pump(&h);

    try testing.expectEqual(@as(usize, 2), try countSent(&h.a, "ListProjectActions"));
    try testing.expectEqual(@import("app_actions.zig").Status.ready, h.a.actions.status);
    try testing.expect(h.a.actions.error_text == null);
    try testing.expect(h.t.hasText("Test"));
}
