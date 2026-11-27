//! Controls that say what they do, once: every visible control acts as its
//! label says, the same action has one name and one place, and nothing is
//! drawn live that does nothing. Driven headlessly on made-up chats,
//! projects and computers (the shared tab-strip fixture).
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const shortcuts = @import("shortcuts.zig");
const strip = @import("view_tab_strip.zig");
const palette = @import("view_palette.zig");
const pal = @import("palette.zig");
const custom: ui.Shortcut = .{ .key = 'y', .cmd = true, .alt = true };
const mac = @import("builtin").os.tag == .macos;
const none = std.math.maxInt(u32);

fn bind(h: *Harness, key: []const u8, combo: []const u8) !void {
    for (shortcuts.all) |entry| if (entry.slot == null and std.mem.eql(u8, entry.key, key)) {
        h.a.settings.setCombo(entry, combo);
        return;
    };
    return error.ShortcutNotFound;
}

fn center(r: ui.Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

/// The tooltip shown after resting on `r` past every delay the app uses.
fn tipAt(h: *Harness, r: ui.Rect) ?[]const u8 {
    h.t.moveTo(1, 700);
    h.t.advance(0.1);
    const p = center(r);
    h.t.moveTo(p[0], p[1]);
    h.t.advance(0.7);
    return h.t.tooltipText();
}

/// The first accessible button whose name starts with `prefix`.
fn button(h: *Harness, prefix: []const u8) ?ui.A11yItem {
    for (h.t.ctx.a11y_items.items) |item| if (std.mem.startsWith(u8, item.label, prefix)) return item;
    return null;
}

fn rectOf(h: *Harness, item: ui.A11yItem) ui.Rect {
    return h.t.ctx.nodes.items[item.node_index].rect;
}

fn isIcon(node: anytype, comptime name: []const u8) bool {
    return switch (node.content) {
        .image => |im| im.source == .encoded and std.mem.eql(u8, im.source.encoded, @import("icons_svg").get(name)),
        else => false,
    };
}

/// Icons `name` drawn under the node at `root` (or anywhere, `none`).
fn iconsUnder(h: *Harness, root: u32, comptime name: []const u8) usize {
    var n: usize = 0;
    for (h.t.ctx.nodes.items, 0..) |node, i| {
        if (!isIcon(node, name)) continue;
        if (root == none) {
            n += 1;
            continue;
        }
        var at: u32 = @intCast(i);
        while (at != none) : (at = h.t.ctx.nodes.items[at].parent) if (at == root) {
            n += 1;
            break;
        };
    }
    return n;
}

/// The nearest ancestor of icon `name` sized `w`×`h`, below `min_y`.
fn iconBox(h: *Harness, comptime name: []const u8, w: f32, hh: f32, min_y: f32) ?u32 {
    var found: ?u32 = null;
    for (h.t.ctx.nodes.items, 0..) |node, i| {
        if (!isIcon(node, name)) continue;
        var at: u32 = @intCast(i);
        while (at != none) : (at = h.t.ctx.nodes.items[at].parent) {
            const box = h.t.ctx.nodes.items[at];
            if (box.rect.w == w and box.rect.h == hh and box.rect.y >= min_y) {
                found = at;
                break;
            }
        }
    }
    return found;
}

fn addRun(h: *Harness) !void {
    try h.a.actions.runs.append(testing.allocator, .{
        .name = try testing.allocator.dupe(u8, "Synthetic build"),
        .log = .{ .gpa = testing.allocator, .palette = h.a.ansi },
    });
}

// ---- Chrome and shortcuts ----

test "control audit: Cmd J toggles the terminal and action-runs dock, as its button and palette row do" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try addRun(&h);
    h.press(.{ .key = 'j', .cmd = true });
    try testing.expect(h.a.actions.dock_open);
    try testing.expect(!h.a.panels.host_open);
    h.press(.{ .key = 'j', .cmd = true });
    try testing.expect(!h.a.actions.dock_open);
    // The palette's "Toggle terminal" is the same action.
    palette.activate(&h.a, .toggle_terminal);
    h.t.settle(1);
    try testing.expect(h.a.actions.dock_open);
    try testing.expect(!h.a.panels.host_open);
}

test "control audit: with no runs the dock button is disabled and Cmd J says why instead of lighting up" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.developer);
    h.t.settle(1);
    const dock = button(&h, "Toggle terminal") orelse return error.MissingDockButton;
    try testing.expect(!dock.enabled);
    const tip = tipAt(&h, rectOf(&h, dock)) orelse return error.MissingDockTooltip;
    try testing.expect(std.mem.indexOf(u8, tip, "No terminal or action runs") != null);
    h.press(.{ .key = 'j', .cmd = true });
    try testing.expect(!h.a.actions.dock_open);
    try testing.expect(!h.a.panels.host_open);
    try testing.expect(h.a.noticeText() != null);
    // With a run it is a live toggle again.
    try addRun(&h);
    h.t.settle(1);
    const live = button(&h, "Toggle terminal") orelse return error.MissingDockButton;
    try testing.expect(live.enabled);
}

test "control audit: the title bar's open-tabs control names what it opens and is not the Chat history clock" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.settle(1);
    const tabs = button(&h, "Open tabs") orelse return error.MissingOpenTabsControl;
    try testing.expectEqualStrings("Open tabs", tipAt(&h, rectOf(&h, tabs)) orelse return error.MissingTooltip);
    try testing.expectEqual(@as(usize, 0), iconsUnder(&h, tabs.node_index, "clock-circle"));
}

test "control audit: Move panel up points up" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.vertical);
    h.t.settle(1);
    strip.open(&h.a, .panel, .{ .chat = 1 }, .{ .x = 600, .y = 400, .w = 80, .h = 20 });
    h.t.settle(1);
    var row: ?u32 = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |t| if (std.mem.startsWith(u8, t.str, "Move pan") and std.mem.endsWith(u8, t.str, " up")) {
            row = node.parent;
        },
        else => {},
    };
    const r = row orelse return error.MissingMoveUpRow;
    try testing.expectEqual(@as(usize, 1), iconsUnder(&h, r, "alt-arrow-up"));
    try testing.expectEqual(@as(usize, 0), iconsUnder(&h, r, "alt-arrow-down"));
}

test "control audit: the mode pill and Design Canvas button describe what a click does now" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.a.settings.applyUiMode(.design);
    @import("app_panels.zig").openDesignCanvas(&h.a);
    h.t.settle(1);
    for (h.t.ctx.a11y_items.items) |item| try testing.expect(std.mem.indexOf(u8, item.label, "Zen / Developer") == null);
    _ = button(&h, "Switch to Zen mode") orelse return error.MissingModePill;
    _ = button(&h, "Close Design Canvas") orelse return error.MissingCanvasClose;
    try testing.expect(button(&h, "Open Design Canvas") == null);
    @import("app_panels.zig").closeDesignCanvas(&h.a);
    h.t.settle(1);
    _ = button(&h, "Open Design Canvas") orelse return error.MissingCanvasOpen;
    h.a.settings.applyUiMode(.zen);
    h.t.settle(1);
    _ = button(&h, "Switch to Developer mode") orelse return error.MissingModePill;
}

test "control audit: the side panel, files panel, command palette and pane zoom keep one name" {
    try testing.expectEqualStrings("Toggle side panel", pal.Entry.label(.toggle_side_panel).?);
    try testing.expectEqualStrings("Toggle files panel", pal.Entry.label(.toggle_files).?);
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.developer);
    h.t.settle(1);
    _ = button(&h, "Toggle files panel") orelse return error.MissingFilesToggle;
    try testing.expect(button(&h, "Toggle file explorer") == null);
    // The tab overview's palette button.
    @import("view_tab_overview.zig").open(&h.a);
    h.t.settle(1);
    const k = h.t.findText(if (mac) "\u{2318}K" else "Ctrl+K") orelse return error.MissingPaletteButton;
    const tip = tipAt(&h, k) orelse return error.MissingPaletteTooltip;
    try testing.expect(std.mem.startsWith(u8, tip, "Command palette"));
    @import("view_tab_overview.zig").close(&h.a);
    // The pane menu's zoom row.
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    strip.open(&h.a, .panel, .{ .chat = 0 }, .{ .x = 400, .y = 400, .w = 80, .h = 20 });
    h.t.settle(1);
    try testing.expect(h.t.hasText("Zoom pane"));
    try testing.expect(!h.t.hasText("Expand panel"));
}

test "control audit: the tab overview shows the user's split binding and the platform's keys" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try bind(&h, "splitTerminal", "mod-alt-y");
    @import("view_tab_overview.zig").open(&h.a);
    h.t.settle(1);
    try testing.expect(h.t.hasText(if (mac) "⌥⌘Y" else "Ctrl+Alt+Y"));
    try testing.expect(!h.t.hasText("⌘D"));
    try testing.expect(!h.t.hasText("⌘Del"));
}
