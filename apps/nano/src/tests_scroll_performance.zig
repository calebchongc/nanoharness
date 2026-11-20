//! Shape and cost of production transcript scrolling, entirely offscreen.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Fixture = struct {
    a: App,
    fn draw(f: *@This(), c: *ui.Context) void {
        f.a.markdown_cache.beginFrame();
        _ = @import("view_transcript.zig").entries(c, &f.a, @import("theme.zig").colors(true), &f.a.transcript, c.size.w, false, 0);
    }
    fn init(f: *@This(), force_full: bool) !void {
        f.a = .init(testing.allocator, testing.io, 1);
        f.a.offscreen = force_full;
        f.a.dark = true;
        f.a.openChat("synthetic-scroll", null);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try text.appendSlice(testing.allocator, "{\"reset\":[");
        for (0..160) |i| {
            if (i > 0) try text.appendSlice(testing.allocator, ",");
            try text.print(testing.allocator,
                \\{{"id":"reply-{d}","role":"assistant","status":"complete","parts":[{{"id":"text","kind":"text","text":"## Synthetic answer {d}\n\nA measured transcript should keep its content and stable scroll position. **Native Markdown** still supports selection and copy.\n\n- Reuse measured row heights\n- Preserve the viewport\n- Keep actual visible content mounted\n\nAnother paragraph of synthetic explanation, deliberately repeated in a long conversation."}}]}}
            , .{ i, i });
        }
        try text.appendSlice(testing.allocator, "]}");
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text.items, .{});
        defer parsed.deinit();
        try f.a.transcript.apply(parsed.value);
    }
};
const Sample = struct { nodes: usize, ms: f64, retained: bool, scroll: f32, max: f32, pixels: u64 };
const Scenario = enum { wheel, jump, resize };
fn sample(force_full: bool, scenario: Scenario) !Sample {
    var f: Fixture = undefined;
    try f.init(force_full);
    defer f.a.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.draw), .{ .width = 1000, .height = 700, .dark = true });
    defer t.deinit();
    t.frame();
    t.frame();
    const box = for (t.ctx.nodes.items) |node| {
        if (node.style.scroll and node.rect.h > 500) break node.id;
    } else return error.NoTranscriptViewport;
    // A real wheel path, not a benchmark that only writes an offset.
    t.scroll(500, 350, 24);
    t.scroll(500, 350, 24);
    const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    for (0..24) |_| t.scroll(500, 350, 4);
    const elapsed = std.Io.Clock.awake.now(testing.io).toNanoseconds() - start;
    switch (scenario) {
        .wheel => {},
        // One frame must mount the destination, not a blank spacer there.
        .jump => t.scroll(500, 350, 10_000),
        .resize => {
            t.size.w = 760;
            t.frame();
            t.frame();
        },
    }
    const pixels = try t.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
    if (std.c.getenv("NANO_SCROLL_SNAP_DIR")) |raw| {
        var path: [1024]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&path, "{s}/{s}-{s}.png", .{ std.mem.span(raw), if (force_full) "full" else "live", @tagName(scenario) }));
    }
    return .{
        .nodes = t.ctx.nodes.items.len,
        .ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / 24,
        .retained = t.ctx.stats.retained,
        .scroll = t.ctx.scroll.get(box).?,
        .max = t.ctx.scroll_max.get(box).?,
        .pixels = std.hash.Wyhash.hash(0, pixels.bytes),
    };
}

test "transcript scroll cost tracks the viewport instead of all warmed history" {
    @import("theme.zig").registerFonts();
    const full = try sample(true, .wheel);
    const live = try sample(false, .wheel);
    std.debug.print("\nSynthetic transcript scroll: full={d:.2}ms/{d} nodes, live={d:.2}ms/{d} nodes, retain={}\n", .{ full.ms, full.nodes, live.ms, live.nodes, live.retained });
    // Generous ratios, not a flaky wall-clock 8.33ms assertion on CI.
    try testing.expect(live.nodes * 5 < full.nodes);
    try testing.expect(live.ms * 3 < full.ms);
    try testing.expectApproxEqAbs(full.max, live.max, 1);
    try testing.expectApproxEqAbs(full.scroll, live.scroll, 1);
    try testing.expectEqual(full.pixels, live.pixels);
}

test "transcript scroll culling yields to native text selection and copy" {
    @import("theme.zig").registerFonts();
    var f: Fixture = undefined;
    try f.init(false);
    defer f.a.deinit();
    f.a.view.sidebar_open = false;
    var t: ui.Tester = undefined;
    // Selection ownership belongs to the production shell's pre-tree input
    // dispatch, not the entries-only timing fixture.
    try t.init(testing.allocator, .init(&f.a, @import("view.zig").view), .{ .width = 1000, .height = 700, .dark = true });
    defer t.deinit();
    t.frame();
    t.frame();
    const culled = t.ctx.nodes.items.len;
    const rect = for (t.ctx.nodes.items) |node| {
        if (node.content == .text and node.content.text.str.len > 40 and node.rect.y > 24 and node.rect.y + node.rect.h < 650 and node.rect.w > 150) break node.rect;
    } else return error.NoVisibleSelectableParagraph;
    t.drag(rect.x + 3, rect.y + 8, rect.x + 120, rect.y + 8);
    try testing.expect(t.ctx.selection.anchor != null);
    t.frame();
    try testing.expect(t.ctx.nodes.items.len < culled * 2);
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expect(t.clipboard.items.len > 0);
}

test "selection peer activation preserves the historical viewport (#22)" {
    @import("theme.zig").registerFonts();
    for ([_]@import("tabs.zig").Axis{ .horizontal, .vertical }) |axis| {
        var f: Fixture = undefined;
        try f.init(false);
        defer f.a.deinit();
        f.a.view.sidebar_open = false;
        f.a.splitPane(axis);
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&f.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        defer t.deinit();
        t.settle(1);
        try testing.expect(f.a.peer("synthetic-scroll") != null);
        const box = std.hash.Wyhash.hash(0x5452_414e_5343_5250, "synthetic-scroll");
        const scroll_x: f32 = if (axis == .horizontal) 250 else 500;
        const scroll_y: f32 = if (axis == .horizontal) 350 else 200;
        t.scroll(scroll_x, scroll_y, 18_000);
        t.settle(0.2);
        const before = t.ctx.scroll.get(box).?;
        const box_rect = t.ctx.rects.get(box) orelse return error.MissingBoxRect;
        const r = for (t.ctx.nodes.items) |n| {
            if (n.content == .text and n.content.text.str.len > 40 and
                n.rect.x >= box_rect.x and n.rect.x + n.rect.w <= box_rect.x + box_rect.w and
                n.rect.y > box_rect.y + 12 and
                n.rect.y + n.rect.h < box_rect.y + box_rect.h - 40 and n.rect.w > 150)
                break n.rect;
        } else return error.NoVisibleSelectableParagraph;
        t.down(r.x + 3, r.y + 8);
        t.move(r.x + 120, r.y + 8);
        t.up();
        t.settle(0.2);
        if (axis == .horizontal) {
            if (std.c.getenv("NANO_SEL_JUMP_SNAP")) |raw| {
                try t.screenshot(std.mem.span(raw));
            }
        }
        try testing.expect(!t.ctx.input.down);
        try testing.expect(!t.ctx.selection.dragging);
        try testing.expect(t.ctx.selection.anchor != null);
        try testing.expectApproxEqAbs(before, t.ctx.scroll.get(box).?, 32);
        _ = t.shortcut(.{ .key = 'c', .cmd = true });
        try testing.expect(t.clipboard.items.len > 0);
    }
}

test "completed selection keeps transcript scrolling viewport-proportional and retains copy (#22)" {
    @import("theme.zig").registerFonts();
    var f: Fixture = undefined;
    try f.init(false);
    defer f.a.deinit();
    f.a.view.sidebar_open = false;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f.a, @import("view.zig").view), .{ .width = 1000, .height = 700, .dark = true });
    defer t.deinit();
    t.settle(0.5);
    t.scroll(500, 350, 12_000);
    t.settle(0.2);
    const ordinary_nodes = t.ctx.nodes.items.len;

    // Select across two visible paragraphs / blocks inside the transcript.
    var first_rect: ?ui.Rect = null;
    var second_rect: ?ui.Rect = null;
    for (t.ctx.nodes.items) |node| {
        if (node.content == .text and node.content.text.str.len > 20 and node.rect.y > 60 and node.rect.y + node.rect.h < 600 and node.rect.w > 100) {
            if (first_rect == null) {
                first_rect = node.rect;
            } else if (node.rect.y > first_rect.?.y + first_rect.?.h + 2) {
                second_rect = node.rect;
                break;
            }
        }
    }
    const r0 = first_rect orelse return error.NoVisibleSelectableParagraph;
    const r1 = second_rect orelse return error.NoSecondSelectableParagraph;
    t.drag(r0.x + 3, r0.y + 8, r1.x + 100, r1.y + 8);
    t.settle(0.2);
    try testing.expect(t.ctx.selection.anchor != null);
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    const expected_copy = try testing.allocator.dupe(u8, t.clipboard.items);
    defer testing.allocator.free(expected_copy);
    try testing.expect(expected_copy.len > 20);
    try testing.expect(std.mem.indexOfScalar(u8, expected_copy, '\n') != null);

    // Wheel far away from the selected paragraphs with the selection still active.
    for (0..12) |_| {
        t.scroll(500, 350, -400);
    }
    t.settle(0.2);
    const selected_nodes = t.ctx.nodes.items.len;
    try testing.expect(selected_nodes < ordinary_nodes * 2);

    // Copy must still return the exact offscreen selected text across paragraphs.
    t.clipboard.clearRetainingCapacity();
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(expected_copy, t.clipboard.items);
}

test "transcript scroll spacers preserve the destination pixels after a large jump and width change" {
    @import("theme.zig").registerFonts();
    for ([_]Scenario{ .jump, .resize }) |scenario| {
        const full = try sample(true, scenario);
        const live = try sample(false, scenario);
        try testing.expectApproxEqAbs(full.max, live.max, 1);
        try testing.expectApproxEqAbs(full.scroll, live.scroll, 1);
        try testing.expectEqual(full.pixels, live.pixels);
    }
}

test "active mouse-down and drag on math-heavy history stay viewport-proportional without eager offscreen SVG decoding (#38)" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = false;
    a.dark = true;
    a.openChat("synthetic-math-stall", null);
    a.view.sidebar_open = false;

    const count: usize = 400;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.appendSlice(testing.allocator, "{\"reset\":[");
    for (0..count) |i| {
        if (i > 0) try json.appendSlice(testing.allocator, ",");
        try json.print(testing.allocator,
            \\{{"id":"reply-{d}","role":"assistant","status":"complete","parts":[{{"id":"text","kind":"text","text":"## Synthetic answer {d}\n\nA synthetic equation $\\frac{{x_{{{d}}}+1}}{{y_{{{d}}}+2}}$ inside an ordinary paragraph, with enough text for native selection.\n\nAnother synthetic paragraph for selecting without moving the viewport."}}]}}
        , .{ i, i, i, i });
    }
    try json.appendSlice(testing.allocator, "]}");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json.items, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1000, .height = 700, .dark = true });
    defer t.deinit();
    t.settle(0.5);
    t.scroll(500, 350, 12_000);
    t.settle(0.2);

    const ordinary_nodes = t.ctx.nodes.items.len;
    const ordinary_decoded = t.text.images.decoded.count();
    const ordinary_build_ms = t.ctx.stats.build_ms;

    // Locate two visible plain paragraphs to drag across.
    var first_rect: ?ui.Rect = null;
    var second_rect: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| {
        if (n.content == .text and n.content.text.str.len > 40 and n.rect.y > 60 and n.rect.y + n.rect.h < 600 and n.rect.w > 150) {
            if (first_rect == null) {
                first_rect = n.rect;
            } else if (n.rect.y > first_rect.?.y + first_rect.?.h + 2) {
                second_rect = n.rect;
                break;
            }
        }
    }
    const r0 = first_rect orelse return error.NoVisibleSelectableParagraph;
    const r1 = second_rect orelse return error.NoSecondSelectableParagraph;

    // 1. Mouse-down must stay viewport-proportional, single-pass, and never decode offscreen SVGs.
    t.down(r0.x + 3, r0.y + 8);
    const down_nodes = t.ctx.nodes.items.len;
    const down_passes = t.ctx.stats.passes;
    const down_decoded = t.text.images.decoded.count();
    const down_build_ms = t.ctx.stats.build_ms;
    std.debug.print(
        "\n#38 rows={d} ordinary_nodes={d} ordinary_ms={d:.3} down_nodes={d} down_passes={d} down_ms={d:.3} decoded_before={d} decoded_after={d}\n",
        .{ count, ordinary_nodes, ordinary_build_ms, down_nodes, down_passes, down_build_ms, ordinary_decoded, down_decoded },
    );
    try testing.expect(down_nodes < ordinary_nodes * 2);
    try testing.expect(down_passes <= 2);
    try testing.expect(down_decoded <= ordinary_decoded + 24);

    // 2. Dragging across paragraphs stays proportional to visible + selected rows.
    t.move(r1.x + 110, r1.y + 8);
    const drag_nodes = t.ctx.nodes.items.len;
    try testing.expect(t.ctx.selection.dragging);
    try testing.expect(drag_nodes < ordinary_nodes * 2);

    // 3. Scrolling while still dragging extends into newly visible rows without mounting full history.
    t.scroll(500, 350, -300);
    t.move(r1.x + 120, r1.y + 8);
    try testing.expect(t.ctx.nodes.items.len < ordinary_nodes * 3);

    // 4. Releasing retains exact Copy, even after scrolling far away from the selection.
    t.up();
    t.settle(0.2);
    try testing.expect(t.ctx.selection.anchor != null);
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    const expected_copy = try testing.allocator.dupe(u8, t.clipboard.items);
    defer testing.allocator.free(expected_copy);
    try testing.expect(expected_copy.len > 20);
    try testing.expect(std.mem.indexOfScalar(u8, expected_copy, '\n') != null);

    for (0..10) |_| t.scroll(500, 350, -400);
    t.settle(0.2);
    try testing.expect(t.ctx.nodes.items.len < ordinary_nodes * 2);
    t.clipboard.clearRetainingCapacity();
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(expected_copy, t.clipboard.items);

    // 5. Second press after settling also stays viewport-proportional and bounded.
    const r2 = for (t.ctx.nodes.items) |n| {
        if (n.content == .text and n.content.text.str.len > 40 and n.rect.y > 60 and n.rect.y + n.rect.h < 600 and n.rect.w > 150) break n.rect;
    } else return error.NoVisibleSelectableParagraph;
    t.down(r2.x + 3, r2.y + 8);
    try testing.expect(t.ctx.nodes.items.len < ordinary_nodes * 2);
    try testing.expect(t.ctx.stats.passes <= 2);
    t.up();
}
