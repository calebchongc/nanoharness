//! Headless investigation only. All application implementation is v0.2.213.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const sidebar = @import("view_sidebar.zig");

fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}
fn setChats(h: *Harness, projectless: bool) !void {
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
    h.t.settle(0.1);
}
fn topLabel(h: *Harness, label: []const u8) bool {
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |t| if (std.mem.eql(u8, t.str, label) and node.rect.y < 42 and node.rect.x >= h.a.view.sidebar_width) return true,
        else => {},
    };
    return false;
}
fn closedCount(h: *Harness) usize { return h.a.tabs.closed.items.len; }
fn openIndependent(h: *Harness, id: []const u8, first: bool) void {
    if (!first) h.a.newWorkspaceSession();
    h.a.openChat(id, null);
}

test "issue47 Cmd3 creates same-project and projectless local groups without CmdD" {
    for ([_]bool{ true, false }) |projectless| {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        try setChats(&h, projectless);
        const visible = sidebar.visibleSessionIds(&h.t.ctx, &h.a);
        try testing.expect(visible.len >= 5);
        const target = try testing.allocator.dupe(u8, visible[2]);
        defer testing.allocator.free(target);
        var chosen: [4][]const u8 = undefined;
        var count: usize = 0;
        for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |id| {
            if (std.mem.eql(u8, id, target)) continue;
            chosen[count] = id;
            openIndependent(&h, id, count == 0);
            count += 1;
            if (count == 4) break;
        }
        h.a.showTab(0);
        h.t.settle(0.2);
        try testing.expectEqual(@as(usize, 4), h.a.tabs.items.items.len);
        try testing.expect(h.a.tabs.find(target) == null);
        try testing.expectEqualStrings(target, sidebar.visibleSessionIds(&h.t.ctx, &h.a)[2]);
        const neighbor_title = h.a.findChat(chosen[1]).?.title.?;
        try testing.expect(topLabel(&h, neighbor_title));
        const closed_before = closedCount(&h);
        if (projectless) try h.t.screenshot("../../../issue-artifacts/issue47-native-before.png");
        h.press((@import("nanoui").ui.Shortcut{ .key = '3', .cmd = true }).native());
        try testing.expectEqualStrings(target, h.a.selected.?);
        try testing.expectEqual(@as(usize, 4), h.a.tabs.items.items.len);
        const layout = h.a.tabs.layout().?;
        try testing.expectEqual(@as(usize, 1), layout.panes.items.len);
        try testing.expectEqual(@as(usize, 2), layout.groups[layout.focus].count());
        try testing.expect(!topLabel(&h, neighbor_title));
        try testing.expectEqual(closed_before, closedCount(&h));
        if (projectless) try h.t.screenshot("../../../issue-artifacts/issue47-native-after.png");
        for (chosen) |id| {
            try testing.expect(h.a.tabs.find(id) != null);
            try testing.expect(!h.a.findChat(id).?.archived);
        }
        std.debug.print("issue47 {s}: real Cmd-3; workspaces 4->4; panes=1; local tabs 1->2; other workspace header visible->hidden; no close/archive\n", .{if (projectless) "projectless" else "same-project"});
    }
}

test "issue47 Cmd3 preserves already-open independent workspaces" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try setChats(&h, true);
    const visible = sidebar.visibleSessionIds(&h.t.ctx, &h.a);
    const target = try testing.allocator.dupe(u8, visible[2]);
    defer testing.allocator.free(target);
    const source: []const u8 = if (std.mem.eql(u8, target, "a")) "b" else "a";
    openIndependent(&h, source, true);
    openIndependent(&h, target, false);
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |id| {
        if (std.mem.eql(u8, id, source) or std.mem.eql(u8, id, target)) continue;
        openIndependent(&h, id, false);
        if (h.a.tabs.items.items.len == 4) break;
    }
    h.a.showTab(0);
    h.t.settle(0.2);
    const target_at = h.a.tabs.find(target).?.tab;
    h.press((@import("nanoui").ui.Shortcut{ .key = '3', .cmd = true }).native());
    try testing.expectEqualStrings(target, h.a.selected.?);
    try testing.expectEqual(target_at, h.a.tabs.active);
    try testing.expectEqual(@as(usize, 4), h.a.tabs.items.items.len);
    if (h.a.tabs.layout()) |layout| try testing.expectEqual(@as(usize, 1), layout.groups[layout.focus].count());
    try testing.expect(topLabel(&h, h.a.findChat(source).?.title.?));
    std.debug.print("issue47 already-open: real Cmd-3 preserves four independent workspaces; no grouping; other workspace header remains visible\n", .{});
}
