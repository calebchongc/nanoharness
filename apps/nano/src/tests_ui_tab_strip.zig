//! Synthetic regressions for the current desktop workspace lane. No engine,
//! account data, builds, private journals or live sessions are involved.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const strip = @import("view_tab_strip.zig");
const chrome = @import("panel_chrome.zig");
const testing = std.testing;

pub const Harness = struct {
    a: App,
    t: ui.Tester,

    pub fn init(h: *Harness, dark: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.device_id = try testing.allocator.dupe(u8, "local");
        try replace(&h.a.devices,
            \\[{"id":"local","name":"Studio"},{"id":"remote","name":"Build box"}]
        );
        try replace(&h.a.spaces,
            \\[{"id":"local-project","deviceId":"local","path":"/synthetic/fieldnotes"},
            \\ {"id":"remote-project","deviceId":"remote","path":"/synthetic/remote-project"}]
        );
        try replace(&h.a.chats,
            \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
            \\ {"id":"b","deviceId":"remote","title":"Beta","spaceId":"remote-project","archived":false}]
        );
        h.a.openChat("a", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = dark });
        h.t.settle(1);
    }
    pub fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
    pub fn press(h: *Harness, key: ui.Shortcut) void {
        _ = h.t.shortcut(key);
        h.t.settle(1);
    }
    fn topText(h: *Harness, text: []const u8) ?ui.Rect {
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, text) and node.rect.y < chrome.header_height and node.rect.x >= h.a.view.sidebar_width) return node.rect,
            else => {},
        };
        return null;
    }
};
fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}

test "question tab attention remains visible with hidden sidebar without selecting the question chat" {
    for (0..3) |mode| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.view.sidebar_open = false;
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[{"id":"synthetic-ask","role":"assistant","parts":[{"kind":"input","requestId":"synthetic-question","resolved":false,"questions":[{"id":"choice","header":"Plan","question":"Choose a synthetic plan","options":["Keep it","Simplify it"]}]}]}]}
        , .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        @import("app_question.zig").syncWizard(&h.a);
        if (mode == 1) h.a.newTab();
        if (mode == 2) h.a.splitPane(.horizontal);
        const selected = if (h.a.selected) |id| try testing.allocator.dupe(u8, id) else null;
        defer if (selected) |id| testing.allocator.free(id);
        h.t.settle(1);
        var markers: usize = 0;
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, "?") and node.rect.y < 42) {
                markers += 1;
            },
            else => {},
        };
        try testing.expect(markers > 0);
        try testing.expectEqual(@as(f32, 0), h.a.view.sidebar_width);
        if (selected) |id| try testing.expectEqualStrings(id, h.a.selected.?) else try testing.expect(h.a.selected == null);
        if (mode != 0) try testing.expect(!h.t.hasText("Cancel question"));
    }
}

test "workspace tab labels do not cover the conversation with hover tooltips" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        for (0..3) |scene| {
            if (scene == 1) h.a.openChatInTab("b");
            if (scene == 2) @import("app_git.zig").open(&h.a, .github);
            h.t.settle(0.2);
            const title = h.topText(if (scene == 2) "GitHub" else "Alpha") orelse return error.MissingTabTitle;
            h.t.moveTo(title.x + title.w / 2, title.y + title.h / 2);
            h.t.advance(0.8);
            if (std.c.getenv("NANO_TAB_HOVER_SNAP_DIR")) |path| {
                var buf: [1024]u8 = undefined;
                try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/tab-{s}-{d}.png", .{ std.mem.span(path), if (dark) "dark" else "light", scene }));
            }
            try testing.expect(h.t.tooltipText() == null);
        }
    }
}

test "saved GPUI tabs reopen in order with their active chat" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.apply(
        \\{"openTabs":["b","missing","a"],"lastChatId":"a","syntheticKeep":17}
    );
    h.a.tabs.setCurrent(null);
    h.a.select(null, null);
    h.a.tabs_ready = false;
    h.a.restoreTabs();
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("b", h.a.tabs.items.items[0].?);
    try testing.expectEqualStrings("a", h.a.tabs.items.items[1].?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.active);
    try testing.expectEqualStrings("a", h.a.selected.?);
    // Publishing mirrors GPUI's keys without replacing unrelated settings.
    h.a.rememberTabs();
    try testing.expectEqual(@as(usize, 2), h.a.settings.open_tabs.items.len);
    try testing.expectEqualStrings("b", h.a.settings.open_tabs.items[0]);
    try testing.expectEqualStrings("a", h.a.settings.open_tabs.items[1]);
    try testing.expectEqualStrings("a", h.a.settings.text("lastChatId").?);
}

test "a legacy saved active chat reopens when openTabs has no rows" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.apply(
        \\{"lastChatId":"b"}
    );
    h.a.tabs.setCurrent(null);
    h.a.select(null, null);
    h.a.tabs_ready = false;
    h.a.restoreTabs();
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("b", h.a.tabs.current().?);
    try testing.expectEqualStrings("b", h.a.selected.?);
}

test "unified strip: one panel has top folder tabs and a 42px content boundary" {
    for ([_]bool{ true, false }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        const title = h.topText("Alpha") orelse return error.MissingTopTab;
        try testing.expect(title.y >= 5 and title.y + title.h <= 37);
        try testing.expectEqual(@as(f32, 42), h.a.view.chrome.y);
        try testing.expectEqual(@as(f32, 730), h.a.view.chrome.height);
        try testing.expect(!h.a.view.chrome.strip);
        const computer = h.topText(@import("strip_device.zig").localLabel()) orelse return error.MissingDeviceLabel;
        try testing.expect(computer.x > 1000 - @import("window_chrome.zig").trailing);
        try testing.expect(computer.x + computer.w <= 1200 - @import("window_chrome.zig").trailing);
        var surface = false;
        for (h.t.ctx.nodes.items) |node| {
            if (node.style.radius == 10 and @abs(node.rect.y - 42) < 0.1 and node.rect.x >= h.a.view.sidebar_width) surface = true;
        }
        try testing.expect(surface);
    }
}

test "unified strip: split slots own both titles without a second peer header" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    const alpha = h.topText("Alpha") orelse return error.MissingFirstSlot;
    const draft = h.topText("New tab") orelse return error.MissingSecondSlot;
    try testing.expect(draft.x > alpha.x);
    try testing.expect(h.a.view.chrome.strip);
    const expected = chrome.paneSpan(h.a.view.chrome.chat_width, 0.5, 2, true);
    try testing.expect(expected > 220);
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "Alpha") and node.rect.x >= h.a.view.sidebar_width and node.rect.y >= 42) return error.DuplicatePeerHeader,
        else => {},
    };
}

test "unified strip: Cmd T opens a new top-level tab and restores the split draft on close" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.composer.set("A parked synthetic prompt");
    h.press(.{ .key = 't', .cmd = true });
    try testing.expect(!h.a.view.open_chooser.open);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.showTab(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqualStrings("A parked synthetic prompt", h.a.composer.text());
    h.a.showTab(1);
    h.a.closeFocused();
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqualStrings("a", h.a.tabs.layout().?.panes.items[0].?);
    try testing.expectEqualStrings("A parked synthetic prompt", h.a.composer.text());
}

test "unified strip: a first split preserves other top-level tabs independently" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.openChat("b", null);
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.groups[0].count());
    h.a.openChat("a", null);
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
}

test "unified strip: sidebar new session parks an independent workspace without changing panel tabs" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.composer.set("Left panel draft");
    h.a.splitPane(.horizontal);
    h.a.pickDraftDevice("remote");
    h.a.composer.set("Right panel draft");
    const original = h.a.tabs.active;
    h.a.newWorkspaceSession();
    try testing.expectEqual(@as(usize, 3), h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    h.a.composer.set("Independent workspace draft");
    const independent = h.a.tabs.active;
    h.a.showTab(original);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.groups[0].count());
    try testing.expectEqualStrings("Right panel draft", h.a.composer.text());
    h.a.focusPane(0);
    try testing.expectEqualStrings("Left panel draft", h.a.composer.text());
    h.a.showTab(independent);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("Independent workspace draft", h.a.composer.text());
}

test "unified strip: expansion keeps all slots and slot shortcuts change the expanded panel" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expectEqual(@as(usize, 1), h.a.view.strip.expanded.?.chat);
    try testing.expect(h.topText("Alpha") != null and h.topText("New tab") != null);
    h.press(.{ .key = '1', .cmd = true, .alt = true });
    try testing.expectEqual(@as(usize, 0), h.a.view.strip.expanded.?.chat);
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expect(h.a.view.strip.expanded == null);
}

test "unified strip: parked draft metadata names its own folder and computer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.select(null, "remote-project");
    h.a.splitPane(.horizontal);
    h.a.select(null, "local-project");
    h.t.settle(1);
    try testing.expectEqualStrings("Build box", strip.deviceLabel(&h.a, strip.device(&h.a, .{ .chat = 0 })));
    try testing.expectEqualStrings("remote-project", strip.folder(&h.a, .{ .chat = 0 }).?.name);
    try testing.expectEqualStrings("fieldnotes", strip.folder(&h.a, .{ .chat = 1 }).?.name);
    strip.queue(&h.a, .{ .folder = .{ .panel = .{ .chat = 1 }, .index = null } });
    h.t.settle(1);
    try testing.expect(h.a.new_no_project);
    try testing.expectEqualStrings("No project", strip.folder(&h.a, .{ .chat = 1 }).?.name);
}

test "unified strip: hidden errors take precedence over streaming without stealing focus" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    h.a.addChatTab(false);
    h.a.openChat("b", null);
    try replace(&h.a.sessions,
        \\[{"chatId":"a","status":"errored"},{"chatId":"b","status":"working"}]
    );
    const k = @import("theme.zig").colors(true);
    try testing.expectEqualDeep(k.danger, strip.attention(&h.a, .{ .chat = 0 }, k).?);
    try testing.expectEqualStrings("b", h.a.selected.?);
    strip.nextAttention(&h.a);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "unified strip: panel menus work with keyboard and close without losing the split" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    strip.open(&h.a, .panel, .{ .chat = 1 }, .{ .x = 760, .y = 5, .w = 100, .h = 32 });
    h.t.settle(1);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(h.a.view.strip.menu == null);
    // New tab from the menu starts in the shared computer/folder sheet.
    try testing.expect(h.a.view.open_chooser.open);
    h.press(.{ .key = ui.Shortcut.enter });
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.groups[1].count());
}

test "closing the only tab moves on to a new chat" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.set(.archive_on_close_chosen, true);
    h.a.closeTabArchiving(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.tabs.current() == null);
    h.a.composer.set("Keep this draft on repeated close");
    h.a.closeByShortcut();
    h.t.settle(1);
    try testing.expectEqualStrings("Keep this draft on repeated close", h.a.composer.text());
    h.a.closeFocused();
    h.t.settle(1);
    try testing.expectEqualStrings("Keep this draft on repeated close", h.a.composer.text());
}

test "closing the tab you are on goes back to the one before it" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try replace(&h.a.chats,
        \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
        \\ {"id":"b","deviceId":"remote","title":"Beta","spaceId":"remote-project","archived":false},
        \\ {"id":"c","deviceId":"local","title":"Gamma","spaceId":"local-project","archived":false}]
    );
    h.a.newTab();
    h.a.openChat("b", null);
    h.a.newTab();
    h.a.openChat("c", null);
    // Visit c -> a -> b, then close b: should return to a, not neighbour c.
    h.a.showTab(2);
    h.a.showTab(0);
    h.a.showTab(1);
    h.a.closeTab(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
    // After a restart (clearShown), closing the active tab falls back to its neighbour.
    h.a.showTab(1);
    h.a.newTab();
    h.a.openChat("b", null);
    // Tabs are now [a, c, b] with b (index 2) active; switch to c (index 1) and clearShown.
    h.a.showTab(1);
    h.a.tabs.clearShown();
    h.a.closeTab(1);
    try testing.expectEqualStrings("b", h.a.selected.?);
}

test "strip slot close button closes a tab and then its panel" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    // Add a second tab in the right pane (pane 1).
    h.a.addChatTab(false);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.groups[1].count());
    const slot_title = h.topText("New tab") orelse return error.MissingRightSlot;
    h.t.moveTo(slot_title.x + 8, slot_title.y + 4);
    h.t.settle(1);
    // Click the slot's ✕ button on the right edge of the second slot.
    var close_rect: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.y < chrome.header_height and node.rect.x > slot_title.x and @abs(node.rect.w - 18) < 0.5 and @abs(node.rect.h - 18) < 0.5) {
            if (close_rect == null or node.rect.x > close_rect.?.x) close_rect = node.rect;
        }
    }
    const r = close_rect orelse return error.MissingSlotCloseButton;
    h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(1);
    // First click closes the active tab in pane 1, leaving 1 tab in pane 1.
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.groups[1].count());
    // Second click on the same slot's ✕ closes the last tab and removes pane 1.
    h.t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(1);
    h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "Cmd+[ and Cmd+] step single-pane panel tabs and retain loaded transcripts in one pass" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try replace(&h.a.chats,
        \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
        \\ {"id":"c","deviceId":"local","title":"Gamma","spaceId":"local-project","archived":false}]
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic prompt"}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    const entries_ptr = h.a.transcript.entries.items.ptr;
    try h.a.tabs.isolateWorkspace();
    h.a.addChatTab(true);
    h.a.tabs.setCurrent("c");
    h.a.select("c", "local-project");
    h.t.settle(1);
    try testing.expectEqualStrings("c", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.groups[0].count());
    _ = h.t.shortcut(.{ .key = '[', .cmd = true });
    try testing.expectEqual(@as(u8, 1), h.t.ctx.stats.passes);
    try testing.expectEqual(@as(usize, 0), h.t.ctx.scroll_moved.count());
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(entries_ptr, h.a.transcript.entries.items.ptr);
    _ = h.t.shortcut(.{ .key = ']', .cmd = true });
    try testing.expectEqual(@as(u8, 1), h.t.ctx.stats.passes);
    try testing.expectEqual(@as(usize, 0), h.t.ctx.scroll_moved.count());
    try testing.expectEqualStrings("c", h.a.selected.?);
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    try testing.expectEqual(@as(u8, 1), h.t.ctx.stats.passes);
}

test "streaming turn with detail lines and mermaid diagram stays visible and updates prompt cache percent" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("b", "local-project");
    try replace(&h.a.sessions,
        \\[{"chatId":"b","status":"working","startedAt":1700000000000}]
    );
    const apply = struct {
        fn run(t: *@import("transcript.zig").Transcript, s: []const u8) !void {
            var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
            defer p.deinit();
            try t.apply(p.value);
        }
    }.run;
    try apply(&h.a.transcript,
        \\{"reset":[
        \\  {"id":"u1","role":"user","parts":[{"id":"p1","kind":"text","text":"hey there"}]},
        \\  {"id":"a1","role":"assistant","status":"completed","parts":[{"id":"p2","kind":"text","text":"Hey! What can I help you with today?"}]},
        \\  {"id":"u2","role":"user","parts":[{"id":"p3","kind":"text","text":"can you show it as a mermaid diagram"}]},
        \\  {"id":"a2","role":"assistant","status":"streaming","parts":[
        \\    {"id":"r1","kind":"reasoning","text":"Exploring the repository layout and runtime flow before drawing the diagram for the user."},
        \\    {"id":"tc1","kind":"tool_call","tool":"Bash","status":"running","input":"{\"description\":\"Inspect workspace crates and directories across the repository\"}"}
        \\  ]}
        \\],"contextUsage":{"tokens":10000,"window":1000000,"savings":{"handleBytes":0,"compactedTokens":0,"cacheReadTokens":6000}}}
    );
    h.t.settle(2);
    // Detail lines in working-trailer must wrap at pane width, keeping messages visible in the viewport.
    try testing.expect(h.t.hasText("can you show it as a mermaid diagram"));
    const prompt_rect = h.t.findText("can you show it as a mermaid diagram") orelse return error.MissingPrompt;
    try testing.expect(prompt_rect.y >= 0 and prompt_rect.y < 760);
    const cw = @import("context_window.zig");
    try testing.expectEqual(@as(?u64, 60), cw.promptCachePercent(
        h.a.transcript.tokens,
        h.a.transcript.savings,
        h.a.transcript.turn_cache_read_tokens,
        h.a.transcript.turn_input_tokens,
    ));

    // Stream a Mermaid diagram reply and an updated cacheReadTokens delta (14,400 new cached out of 16,000 input = 90%).
    try apply(&h.a.transcript,
        \\{"upsert":[
        \\  {"entry":{"id":"a2","role":"assistant","status":"completed","parts":[
        \\    {"id":"m1","kind":"text","text":"Here is the diagram:\n\n```mermaid\ngraph TD\n  ROOT[\"harness/ (repo root)\"] --> APPS[\"apps/\"]\n  APPS --> NANO[\"nano/ — nanoui desktop\"]\n```"}
        \\  ]}}
        \\],"contextUsage":{"tokens":16000,"window":1000000,"savings":{"handleBytes":0,"compactedTokens":0,"cacheReadTokens":20400}}}
    );
    h.t.settle(2);
    try testing.expect(h.t.hasText("apps/"));
    try testing.expectEqual(@as(?u64, 90), cw.promptCachePercent(
        h.a.transcript.tokens,
        h.a.transcript.savings,
        h.a.transcript.turn_cache_read_tokens,
        h.a.transcript.turn_input_tokens,
    ));
}

test "session hierarchy nests all tabs under the session in sidebar and shows side-by-side tab pills in top strip" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    // Split the first session ("Alpha" | "Beta"), then press Cmd+T to open a brand new canvas ("New tab").
    h.a.splitPane(.horizontal);
    h.a.openChat("b", null);
    h.press(.{ .key = 't', .cmd = true });
    try testing.expect(!h.a.view.open_chooser.open);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    // Top strip on the new canvas shows the split session ("Beta", "2 split panes") AND the new tab ("New tab")!
    try testing.expect(h.topText("Beta") != null);
    try testing.expect(h.topText("2 split panes") != null);
    try testing.expect(h.topText("New tab") != null);
    // Sidebar shows Session 0 with its 2 split panes ("Alpha", "Beta") nested underneath it, plus Session 1 ("New session").
    var side_alpha = false;
    var side_beta = false;
    var side_new = false;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (node.rect.x < h.a.view.sidebar_width and node.rect.y < 260) {
            if (std.mem.eql(u8, tx.str, "Alpha")) side_alpha = true;
            if (std.mem.eql(u8, tx.str, "Beta")) side_beta = true;
            if (std.mem.eql(u8, tx.str, "New session")) side_new = true;
        },
        else => {},
    };
    try testing.expect(side_alpha and side_beta and side_new);
    // Once the empty workspace becomes an ordinary single-chat workspace for a listed conversation,
    // it must still appear in the open-workspaces list above the project groups.
    try replace(&h.a.chats,
        \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
        \\ {"id":"b","deviceId":"remote","title":"Beta","spaceId":"remote-project","archived":false},
        \\ {"id":"c","deviceId":"local","title":"Gamma","spaceId":"local-project","archived":false}]
    );
    h.a.openChat("c", "local-project");
    h.t.settle(1);
    const project_group = h.t.findText("fieldnotes") orelse return error.NoProjectGroup;
    var side_gamma_open_ws = false;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (node.rect.x < h.a.view.sidebar_width and node.rect.y < project_group.y) {
            if (std.mem.eql(u8, tx.str, "Gamma")) side_gamma_open_ws = true;
        },
        else => {},
    };
    try testing.expect(side_gamma_open_ws);
}

test "overflowing titlebar tabs never slice trailing tab title into fragments (#3)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try replace(&h.a.chats,
        \\[{"id":"t0","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
        \\ {"id":"t1","deviceId":"local","title":"Beta","spaceId":"local-project","archived":false},
        \\ {"id":"t2","deviceId":"local","title":"Gamma","spaceId":"local-project","archived":false},
        \\ {"id":"t3","deviceId":"local","title":"Delta","spaceId":"local-project","archived":false},
        \\ {"id":"t4","deviceId":"local","title":"Echo","spaceId":"local-project","archived":false},
        \\ {"id":"t5","deviceId":"local","title":"Foxtrot","spaceId":"local-project","archived":false},
        \\ {"id":"t6","deviceId":"local","title":"Grove","spaceId":"local-project","archived":false},
        \\ {"id":"t7","deviceId":"local","title":"Harbor","spaceId":"local-project","archived":false,"branch":"validation"}]
    );
    const ids = [_][]const u8{ "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7" };
    h.a.openChat(ids[0], "local-project");
    for (ids[1..]) |id| {
        h.a.newTab();
        h.a.openChat(id, "local-project");
    }
    h.a.view.sidebar_open = false;
    h.a.view.sidebar_width = 0;
    h.a.dark = false;
    h.a.updates.graff_kind = .updated;
    const ver = "0.302.74.74";
    @memcpy(h.a.updates.graff_to[0..ver.len], ver);
    h.a.updates.graff_to_len = ver.len;
    for ([_]usize{ 0, 7 }) |sel| {
        h.a.showTab(sel);
        for ([_]f32{ 1200, 1220, 1240 }) |w| {
            h.t.resize(w, 780);
            h.t.settle(1);
            for (h.t.ctx.nodes.items) |node| {
                if (node.content != .text) continue;
                if (node.rect.y > 40) continue;
                const str = node.content.text.str;
                const is_title = for ([_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Echo", "Foxtrot", "Grove", "Harbor" }) |name| {
                    if (std.mem.eql(u8, str, name)) break true;
                } else false;
                if (!is_title) continue;
                var left = node.rect.x;
                var right = node.rect.x + node.rect.w;
                var p = node.parent;
                while (p < h.t.ctx.nodes.items.len) {
                    const anc = h.t.ctx.node(p);
                    if (anc.style.clip) {
                        left = @max(left, anc.rect.x);
                        right = @min(right, anc.rect.x + anc.rect.w);
                    }
                    if (anc.parent == p) break;
                    p = anc.parent;
                }
                const visible = @max(0, right - left);
                try testing.expect(visible == 0 or visible + 0.5 >= node.rect.w);
            }
            const tab_names = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Echo", "Foxtrot", "Grove", "Harbor" };
            const want = tab_names[sel];
            try testing.expect(h.topText(want) != null);
        }
    }
}

test "github tab identity inactive cap differs from selected cap in compact layout (#4)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.dark = false;
    h.t.resize(750, 850);
    const gh = @import("app_github_repository.zig");
    @import("app_git.zig").open(&h.a, .github);
    h.t.settle(1);
    try testing.expect(gh.surface(&h.a));
    const slotBg = struct {
        fn find(ctx: *ui.Context, label: []const u8) ?ui.Color {
            for (ctx.nodes.items) |node| {
                if (node.content == .text and std.mem.indexOf(u8, node.content.text.str, label) != null and node.rect.y < 42) {
                    var p = node.parent;
                    while (p < ctx.nodes.items.len) {
                        const anc = ctx.node(p);
                        if (anc.style.background != null and anc.rect.h >= 24 and anc.rect.y < 42) return anc.style.background;
                        if (anc.parent == p) break;
                        p = anc.parent;
                    }
                }
            }
            return null;
        }
    }.find;
    const active_bg = slotBg(&h.t.ctx, "GitHub") orelse return error.MissingActiveGitHubTab;
    h.a.view.strip.focused = .{ .chat = 0 };
    h.t.settle(1);
    const inactive_bg = slotBg(&h.t.ctx, "GitHub") orelse return error.MissingInactiveGitHubTab;
    try testing.expect(!std.meta.eql(active_bg, inactive_bg));
}

test "overflow tab window keeps selected tab background aligned with displayed active tab (#36)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.dark = false;
    try replace(&h.a.chats,
        \\[{"id":"t0","deviceId":"local","title":"Cedar Notes","spaceId":"local-project","archived":false},
        \\ {"id":"t1","deviceId":"local","title":"Maple Draft","spaceId":"local-project","archived":false},
        \\ {"id":"t2","deviceId":"local","title":"Birch Plan","spaceId":"local-project","archived":false},
        \\ {"id":"t3","deviceId":"local","title":"Alder Audit","spaceId":"local-project","archived":false},
        \\ {"id":"t4","deviceId":"local","title":"Pine Spec","spaceId":"local-project","archived":false}]
    );

    const checkAlignment = struct {
        fn run(h_ptr: *Harness) !void {
            h_ptr.a.view.strip.active_tab_anchor = null;
            h_ptr.t.frame();
            h_ptr.t.frame();
            const tab = h_ptr.a.view.strip.active_tab_anchor orelse return error.MissingActiveTabAnchor;
            const sel = @import("view_tab_strip_render.zig").selectedBounds(&h_ptr.a) orelse return error.MissingSelectedBounds;
            const body_x = h_ptr.a.view.sidebar_width + h_ptr.a.view.chrome.leading;
            try testing.expectApproxEqAbs(tab.x, body_x + sel.left, 0.5);
            try testing.expectApproxEqAbs(tab.x + tab.w, body_x + sel.right, 0.5);
        }
    }.run;

    // 1. Exact #36 reproduction: 2 tabs in a narrow single-slot Developer-mode lane showing "+1".
    h.a.openChat("t0", "local-project");
    h.a.newTab();
    h.a.openChat("t1", "local-project");
    h.a.view.sidebar_open = true;
    h.a.view.sidebar_width = h.a.settings.sidebarWidth();
    h.a.showTab(1);
    h.t.resize(740, 520);
    h.t.settle(2);
    if (std.c.getenv("NANO_TAB_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/overflow-tab-cap-light.png", .{std.mem.span(dir)})) |path| {
            h.t.screenshot(path) catch {};
        } else |_| {}
    }
    try testing.expect(h.topText("+1") != null);
    try checkAlignment(&h);

    // Switch back to first tab in the same narrow single-slot lane.
    h.a.showTab(0);
    h.t.settle(2);
    try checkAlignment(&h);

    // 2. Ultra-narrow single-slot lane where slot_w shrinks below tabWidth, with trailing update pill.
    h.a.updates.graff_kind = .updated;
    const ver = "0.302.74.75";
    @memcpy(h.a.updates.graff_to[0..ver.len], ver);
    h.a.updates.graff_to_len = ver.len;
    h.a.showTab(1);
    h.t.resize(620, 520);
    h.t.settle(2);
    try checkAlignment(&h);

    // 3. Multi-tab overflow (5 tabs) across first, middle, and last selection, sidebar closed and open.
    for ([_][]const u8{ "t2", "t3", "t4" }) |id| {
        h.a.newTab();
        h.a.openChat(id, "local-project");
    }
    for ([_]bool{ false, true }) |sidebar_open| {
        h.a.view.sidebar_open = sidebar_open;
        h.a.view.sidebar_width = if (sidebar_open) h.a.settings.sidebarWidth() else 0;
        for ([_]f32{ 760, 920 }) |w| {
            h.t.resize(w, 520);
            for ([_]usize{ 0, 2, 4 }) |sel_ix| {
                h.a.showTab(sel_ix);
                h.t.settle(2);
                try checkAlignment(&h);
            }
        }
    }
}

test "singleWindow pure layout matches visible slot for first, last, and narrow single-slot tabs (#36)" {
    const render = @import("view_tab_strip_render.zig");
    // Issue #36 example: 350pt lane, 2 tabs, add_room=27 -> visible_count=1, slot_w=167.5.
    const w0 = render.singleWindow(350, 2, 0, 27);
    const w1 = render.singleWindow(350, 2, 1, 27);
    try testing.expectEqual(@as(usize, 0), w0.win_start);
    try testing.expectEqual(@as(usize, 1), w0.win_end);
    try testing.expectEqual(@as(usize, 1), w0.hidden_count);
    try testing.expectApproxEqAbs(@as(f32, 0), w0.selected_left, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 167.5), w0.selected_right, 0.01);

    try testing.expectEqual(@as(usize, 1), w1.win_start);
    try testing.expectEqual(@as(usize, 2), w1.win_end);
    try testing.expectEqual(@as(usize, 1), w1.hidden_count);
    try testing.expectApproxEqAbs(@as(f32, 0), w1.selected_left, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 167.5), w1.selected_right, 0.01);

    // Narrow single-slot lane where slot_w shrinks below tabWidth (112).
    const narrow = render.singleWindow(154, 2, 1, 27);
    try testing.expectEqual(@as(usize, 1), narrow.win_start);
    try testing.expectEqual(@as(usize, 2), narrow.win_end);
    try testing.expectApproxEqAbs(@as(f32, 90), narrow.slot_w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), narrow.selected_left, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 90), narrow.selected_right, 0.01);
}

fn issue47SetChats(h: *Harness, projectless: bool) !void {
    try replace(&h.a.chats, if (projectless)
        \\[{"id":"a","deviceId":"local","title":"Alpha","archived":false},
        \\ {"id":"b","deviceId":"local","title":"Beta","archived":false},
        \\ {"id":"c","deviceId":"local","title":"Gamma","archived":false},
        \\ {"id":"d","deviceId":"local","title":"Delta","archived":false},
        \\ {"id":"e","deviceId":"local","title":"Epsilon","archived":false},
        \\ {"id":"f","deviceId":"local","title":"Zeta","archived":false}]
    else
        \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
        \\ {"id":"b","deviceId":"local","title":"Beta","spaceId":"local-project","archived":false},
        \\ {"id":"c","deviceId":"local","title":"Gamma","spaceId":"local-project","archived":false},
        \\ {"id":"d","deviceId":"local","title":"Delta","spaceId":"local-project","archived":false},
        \\ {"id":"e","deviceId":"local","title":"Epsilon","spaceId":"local-project","archived":false},
        \\ {"id":"f","deviceId":"local","title":"Zeta","spaceId":"local-project","archived":false}]
    );
    h.a.settings.setText("sidebarLastActivity", "all");
    h.a.settings.applyUiMode(.developer);
    h.t.settle(0.2);
}

fn issue47OpenIndependent(h: *Harness, id: []const u8, first: bool) void {
    if (!first) h.a.newWorkspaceSession();
    h.a.openChat(id, null);
}

fn issue47OverflowRect(h: *Harness) ?ui.Rect {
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (tx.str.len >= 2 and tx.str[0] == '+' and node.rect.y < chrome.header_height and node.rect.x >= h.a.view.sidebar_width) return node.rect,
        else => {},
    };
    return null;
}

fn issue47MenuText(h: *Harness, text: []const u8) ?ui.Rect {
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, text) and node.rect.y >= chrome.header_height and node.rect.x >= h.a.view.sidebar_width) return node.rect,
        else => {},
    };
    return null;
}

fn issue47Snap(h: *Harness, name: []const u8) !void {
    const dir = std.c.getenv("NANO_ISSUE47_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
    try h.t.screenshot(path);
}

test "issue #47: Cmd-3 opens unopened projectless and same-project chats as independent workspaces without grouping" {
    const sidebar = @import("view_sidebar.zig");
    for ([_]bool{ true, false }) |projectless| {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        try issue47SetChats(&h, projectless);
        const visible = sidebar.visibleSessionIds(&h.t.ctx, &h.a);
        try testing.expect(visible.len >= 5);
        const target = try testing.allocator.dupe(u8, visible[2]);
        defer testing.allocator.free(target);
        var chosen: [4][]const u8 = undefined;
        var n: usize = 0;
        for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |id| {
            if (std.mem.eql(u8, id, target)) continue;
            chosen[n] = id;
            issue47OpenIndependent(&h, id, n == 0);
            n += 1;
            if (n == 4) break;
        }
        h.a.showTab(0);
        h.t.settle(0.2);
        const closed_before = h.a.tabs.closed.items.len;
        const neighbor_title = h.a.findChat(chosen[1]).?.title.?;
        try testing.expect(h.topText(neighbor_title) != null);

        h.press((ui.Shortcut{ .key = '3', .cmd = true }).native());
        if (projectless) try issue47Snap(&h, "cmd3-no-unintended-group");

        try testing.expectEqualStrings(target, h.a.selected.?);
        // Must open in its own independent top-level workspace, never grouping into an existing pane.
        try testing.expectEqual(@as(usize, 5), h.a.tabs.items.items.len);
        try testing.expect(h.a.tabs.layout() == null);
        // Other workspaces remain reachable in the top bar (visible cap or overflow menu).
        try testing.expect(h.topText(neighbor_title) != null or issue47OverflowRect(&h) != null);
        try testing.expectEqual(closed_before, h.a.tabs.closed.items.len);
        for (chosen) |id| {
            try testing.expect(h.a.tabs.find(id) != null);
            try testing.expect(!h.a.findChat(id).?.archived);
        }
    }
}

test "issue #47: entering an existing multi-tab workspace via Cmd-3 or click keeps all workspaces reachable, including reverse and narrow overflow" {
    const sidebar = @import("view_sidebar.zig");
    for ([_]bool{ true, false }) |via_cmd3| {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        try issue47SetChats(&h, false);
        const visible = sidebar.visibleSessionIds(&h.t.ctx, &h.a);
        try testing.expect(visible.len >= 5);
        const target = try testing.allocator.dupe(u8, visible[2]);
        defer testing.allocator.free(target);
        // Pick 4 other chats: ws0, ws1, ws2=[target, companion], ws3.
        var others: [4][]const u8 = undefined;
        var oi: usize = 0;
        for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |id| {
            if (std.mem.eql(u8, id, target)) continue;
            others[oi] = id;
            oi += 1;
            if (oi == 4) break;
        }
        issue47OpenIndependent(&h, others[0], true);
        issue47OpenIndependent(&h, others[1], false);
        // Workspace 2: explicitly grouped 1-pane, 2-tab workspace ([target, others[3]]).
        issue47OpenIndependent(&h, target, false);
        try h.a.tabs.isolateWorkspace();
        h.a.addChatTab(true);
        h.a.tabs.setCurrent(others[3]);
        h.a.select(others[3], "local-project");
        h.a.showPaneTab(0);
        // Workspace 3: fourth independent workspace.
        issue47OpenIndependent(&h, others[2], false);
        h.a.showTab(0);
        h.t.settle(0.2);

        try testing.expectEqual(@as(usize, 4), h.a.tabs.items.items.len);
        const closed_before = h.a.tabs.closed.items.len;
        const ws0_title = h.a.findChat(others[0]).?.title.?;
        const ws1_title = h.a.findChat(others[1]).?.title.?;
        const target_title = h.a.findChat(target).?.title.?;
        const companion_title = h.a.findChat(others[3]).?.title.?;
        const ws3_title = h.a.findChat(others[2]).?.title.?;

        if (via_cmd3) {
            h.press((ui.Shortcut{ .key = '3', .cmd = true }).native());
        } else {
            const cap = h.topText(target_title) orelse return error.MissingMultiTabWorkspaceCap;
            h.t.click(cap.x + cap.w / 2, cap.y + cap.h / 2);
            h.t.settle(0.2);
        }
        if (via_cmd3) try issue47Snap(&h, "multitab-workspace-nav");

        try testing.expectEqualStrings(target, h.a.selected.?);
        try testing.expectEqual(@as(usize, 2), h.a.tabs.active);
        try testing.expectEqual(@as(usize, 4), h.a.tabs.items.items.len);
        try testing.expectEqual(closed_before, h.a.tabs.closed.items.len);

        // Neighbor workspaces remain visibly reachable in the top bar (and any overflowed workspace via `+N`).
        try testing.expect(h.topText(ws0_title) != null);
        try testing.expect(h.topText(ws1_title) != null);
        try testing.expect(h.topText(target_title) != null);
        try testing.expect(h.topText(ws3_title) != null or issue47OverflowRect(&h) != null);

        // The active workspace's local tabs remain reachable from the top bar switcher.
        const local_badge = h.topText("2") orelse return error.MissingLocalTabSwitcher;
        h.t.click(local_badge.x + local_badge.w / 2, local_badge.y + local_badge.h / 2);
        h.t.settle(0.2);
        try testing.expectEqual(strip.Menu.panel, h.a.view.strip.menu.?);
        const companion_row = issue47MenuText(&h, companion_title) orelse return error.MissingPanelMenuRow;
        h.t.click(companion_row.x + companion_row.w / 2, companion_row.y + companion_row.h / 2);
        h.t.settle(0.2);
        try testing.expectEqualStrings(others[3], h.a.selected.?);
        try testing.expectEqual(@as(usize, 2), h.a.tabs.active);
        // Switching local tab inside ws2 still keeps all other workspaces visible!
        try testing.expect(h.topText(ws0_title) != null);

        // Narrow window overflow keeps all 4 workspaces reachable via the `+N` history menu.
        h.t.resize(760, 560);
        h.t.settle(0.2);
        const overflow = issue47OverflowRect(&h) orelse return error.MissingNarrowOverflow;
        h.t.click(overflow.x + overflow.w / 2, overflow.y + overflow.h / 2);
        h.t.settle(0.2);
        try testing.expectEqual(strip.Menu.history, h.a.view.strip.menu.?);
        const ws0_menu_row = issue47MenuText(&h, ws0_title) orelse return error.MissingHistoryWs0;
        try testing.expect(issue47MenuText(&h, ws1_title) != null);
        try testing.expect(issue47MenuText(&h, ws3_title) != null);
        // Reverse transition back to ws0 via visible navigation.
        h.t.click(ws0_menu_row.x + ws0_menu_row.w / 2, ws0_menu_row.y + ws0_menu_row.h / 2);
        h.t.settle(0.2);
        try testing.expectEqualStrings(others[0], h.a.selected.?);
        try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
        try testing.expectEqual(closed_before, h.a.tabs.closed.items.len);
        for ([_][]const u8{ others[0], others[1], target, others[3], others[2] }) |id| {
            try testing.expect(h.a.tabs.find(id) != null);
            try testing.expect(!h.a.findChat(id).?.archived);
        }
    }
}

test "issue #47: Cmd-3 to an already-open independent workspace activates it without grouping" {
    const sidebar = @import("view_sidebar.zig");
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try issue47SetChats(&h, true);
    const visible = sidebar.visibleSessionIds(&h.t.ctx, &h.a);
    const target = try testing.allocator.dupe(u8, visible[2]);
    defer testing.allocator.free(target);
    const source: []const u8 = if (std.mem.eql(u8, target, "a")) "b" else "a";
    issue47OpenIndependent(&h, source, true);
    issue47OpenIndependent(&h, target, false);
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |id| {
        if (std.mem.eql(u8, id, source) or std.mem.eql(u8, id, target)) continue;
        issue47OpenIndependent(&h, id, false);
        if (h.a.tabs.items.items.len == 4) break;
    }
    h.a.showTab(0);
    h.t.settle(0.2);
    const target_at = h.a.tabs.find(target).?.tab;
    h.press((ui.Shortcut{ .key = '3', .cmd = true }).native());
    try testing.expectEqualStrings(target, h.a.selected.?);
    try testing.expectEqual(target_at, h.a.tabs.active);
    try testing.expectEqual(@as(usize, 4), h.a.tabs.items.items.len);
    if (h.a.tabs.layout()) |layout| try testing.expectEqual(@as(usize, 1), layout.groups[layout.focus].count());
    try testing.expect(h.topText(h.a.findChat(source).?.title.?) != null);
}
