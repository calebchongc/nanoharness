//! Synthetic remaining-copy regressions imported from Harness PR #798.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const CopySurface = enum { browser, saved_browser, code, mermaid, notice };

const CopyFixture = struct {
    a: App,
    browser: @import("app_browser.zig").Browser,
    surface: CopySurface,
    browser_override: ?*@import("app_browser.zig").Browser = null,

    fn draw(s: *CopyFixture, c: *ui.Context) void {
        const k = @import("theme.zig").colors(false);
        c.theme = @import("theme.zig").ui(false);
        const box = ui.div(c).column().sizeFull().p(12).bg(k.shell);
        defer box.end();
        switch (s.surface) {
            .browser, .saved_browser => @import("view_browser.zig").draw(c, &s.a, k, s.browser_override orelse &s.browser),
            .code => @import("view_markdown.zig").withLinks(c, k, "```text\nSynthetic code\n```", &s.a, "synthetic"),
            .mermaid => @import("view_markdown.zig").withLinks(c, k, "```mermaid\ngraph LR\n A --> B\n```", &s.a, "synthetic"),
            .notice => @import("view_transcript.zig").noticeChip(c, &s.a.view.copy_feedback, k, "Error", "Synthetic error").end(),
        }
    }
};

fn lastCopyImage(t: *ui.Tester) !usize {
    for (t.ctx.a11y_items.items) |item| {
        if (std.mem.eql(u8, item.label, "Copy address")) {
            const r = t.ctx.node(item.node_index).rect;
            for (t.ctx.nodes.items, 0..) |node, i| {
                if (node.content == .image and node.rect.x >= r.x and node.rect.x < r.x + r.w and node.rect.y >= r.y and node.rect.y < r.y + r.h) return i;
            }
        }
    }
    var found: ?usize = null;
    for (t.ctx.nodes.items, 0..) |node, i| {
        if (node.content == .image and node.rect.w <= 16 and node.rect.h <= 16) found = i;
    }
    return found orelse error.CopyIconNotFound;
}

fn surfaceCopyFeedback(surface: CopySurface, reduced_motion: bool) !void {
    @import("theme.zig").registerFonts();
    var s: CopyFixture = .{ .a = .init(testing.allocator, testing.io, 1), .browser = undefined, .surface = surface };
    defer s.a.deinit();
    s.browser = .{ .app = &s.a, .parent = &.{} };
    s.a.offscreen = true;
    s.browser.address.set("https://example.com/preview");
    if (surface == .saved_browser) {
        s.browser.saved_view = @import("saved_view.zig").View.init(.html, "0123456789abcdef0123456789abcdef");
        s.browser.address.set("graff-view://html/0123456789abcdef0123456789abcdef");
    }
    defer testing.allocator.free(s.browser.url);
    defer @import("text_buffer.zig").deinit(&s.browser.address);
    defer @import("text_buffer.zig").deinit(&s.browser.notice);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, CopyFixture.draw), .{ .width = 600, .height = 220, .dark = false });
    defer t.deinit();
    t.ctx.reduced_motion = reduced_motion;
    t.settle(0.2);
    const ix = try lastCopyImage(&t);
    const before = t.ctx.nodes.items[ix].content.image;
    const r = t.ctx.nodes.items[ix].rect;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    t.frame();
    try testing.expectEqualStrings(switch (surface) {
        .browser => "https://example.com/preview",
        .saved_browser => "graff-view://html/0123456789abcdef0123456789abcdef",
        .code => "Synthetic code",
        .mermaid => "graph LR\n A --> B",
        .notice => "Synthetic error",
    }, t.clipboard.items);
    if (!reduced_motion) if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&buf, "{s}/{s}-copy-clicked.png", .{ std.mem.span(dir), @tagName(surface) }));
    };
    const copied = t.ctx.nodes.items[try lastCopyImage(&t)].content.image;
    try testing.expect(!std.meta.eql(before, copied));
    try testing.expectEqual(r, t.ctx.nodes.items[try lastCopyImage(&t)].rect);
    t.advance(0.8);
    try testing.expect(std.meta.eql(copied, t.ctx.nodes.items[try lastCopyImage(&t)].content.image));
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    t.advance(0.5);
    try testing.expect(std.meta.eql(copied, t.ctx.nodes.items[try lastCopyImage(&t)].content.image));
    t.advance(0.8);
    try testing.expect(std.meta.eql(before, t.ctx.nodes.items[try lastCopyImage(&t)].content.image));
    if (surface == .browser) {
        t.click(r.x + r.w / 2, r.y + r.h / 2);
        t.frame();
        // A different browser at the same chrome slot must not inherit the
        // first browser's tick, even when both addresses are identical.
        var other: @import("app_browser.zig").Browser = .{ .app = &s.a, .parent = &.{} };
        other.address.set(s.browser.address.text());
        defer @import("text_buffer.zig").deinit(&other.address);
        s.browser_override = &other;
        t.frame();
        try testing.expect(std.meta.eql(before, t.ctx.nodes.items[try lastCopyImage(&t)].content.image));
        s.browser_override = null;
        t.frame();
        try testing.expect(std.meta.eql(copied, t.ctx.nodes.items[try lastCopyImage(&t)].content.image));
        // Navigating must not show the old address's confirmation on the new one.
        s.browser.address.set("https://example.com/other");
        t.frame();
        try testing.expect(std.meta.eql(before, t.ctx.nodes.items[try lastCopyImage(&t)].content.image));
        s.browser.address.clear();
        t.frame();
        const empty = t.ctx.nodes.items[try lastCopyImage(&t)].content.image;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
        t.frame();
        try testing.expectEqualStrings("https://example.com/preview", t.clipboard.items);
        try testing.expect(std.meta.eql(empty, t.ctx.nodes.items[try lastCopyImage(&t)].content.image));
    }
}

test "browser copy feedback changes to a tick and resets" {
    try surfaceCopyFeedback(.browser, false);
    try surfaceCopyFeedback(.browser, true);
    try surfaceCopyFeedback(.saved_browser, false);
}

test "code block copy feedback changes to a tick and resets" {
    try surfaceCopyFeedback(.code, false);
    try surfaceCopyFeedback(.code, true);
    try surfaceCopyFeedback(.mermaid, false);
}

test "notice copy feedback changes to a tick and resets" {
    try surfaceCopyFeedback(.notice, false);
    try surfaceCopyFeedback(.notice, true);
}

const SharedCopyFixture = struct {
    feedback: @import("view_kit.zig").CopyFeedback = .{},
    activations: [3]usize = .{ 0, 0, 0 },

    fn draw(s: *@This(), c: *ui.Context) void {
        const row = ui.div(c).row().p(16).gap(12);
        defer row.end();
        const k = @import("theme.zig").colors(false);
        for ([_][]const u8{ "Copy first", "Copy second", "Copy disabled" }, 0..) |label, i| {
            ui.key(c, label);
            if (@import("view_kit.zig").copyButton(c, k, &s.feedback, .{ .label = label, .disabled = i == 2 })) {
                s.activations[i] += 1;
                c.clipboard.write(c.clipboard.ctx, "  synthetic\ttext\n\n");
            }
        }
    }
};

fn copyControl(t: *ui.Tester, label: []const u8) !u32 {
    for (t.ctx.a11y_items.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return item.node_index;
    }
    return error.CopyControlMissing;
}

test "shared copy feedback retains keyboard accessibility disabled ownership and exact bytes" {
    for ([_]bool{ false, true }) |reduced_motion| {
        var s: SharedCopyFixture = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, SharedCopyFixture.draw), .{ .width = 200, .height = 80 });
        defer t.deinit();
        t.ctx.reduced_motion = reduced_motion;
        const first = t.ctx.node(try copyControl(&t, "Copy first")).id;
        const second = t.ctx.node(try copyControl(&t, "Copy second")).id;
        const disabled = t.ctx.node(try copyControl(&t, "Copy disabled")).id;
        const target = t.ctx.node(try copyControl(&t, "Copy first")).rect;
        t.key(.tab);
        t.key(.enter);
        try testing.expectEqualDeep([_]usize{ 1, 0, 0 }, s.activations);
        try testing.expectEqualStrings("  synthetic\ttext\n\n", t.clipboard.items);
        try testing.expect(s.feedback.active(first, t.ctx.time));
        try testing.expectEqual(target, t.ctx.node(try copyControl(&t, "Copy first")).rect);
        t.ctx.a11yPress(second);
        t.frame();
        try testing.expectEqualDeep([_]usize{ 1, 1, 0 }, s.activations);
        try testing.expect(!s.feedback.active(first, t.ctx.time));
        try testing.expect(s.feedback.active(second, t.ctx.time));
        t.ctx.a11yPress(disabled);
        t.ctx.focus = disabled;
        t.key(.enter);
        t.frame();
        try testing.expectEqualDeep([_]usize{ 1, 1, 0 }, s.activations);
        try testing.expect(s.feedback.active(second, t.ctx.time));
        t.advance(1.3);
        try testing.expect(!s.feedback.active(second, t.ctx.time));
    }
}
