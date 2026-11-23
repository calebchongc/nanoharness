//! Local Usage Settings: synthetic data only; no host records, provider calls
//! or screenshots of personal activity.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const view = @import("view_settings.zig");
const Section = @import("settings.zig").Section;
const catalog = @import("settings_catalog.zig");

fn fixture(h: *Harness) !void {
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"LocalTokenUsage":{"periodStart":"Nov 1, 2026","asOf":"Nov 22, 2026","partial":false,"rows":[
        \\ {"runtime":"Harness","model":"sample-model-a","inputTokens":1200000,"outputTokens":320000},
        \\ {"runtime":"Codex","model":"sample-model-a","inputTokens":50000,"outputTokens":20000},
        \\ {"runtime":"AGY","model":"sample-model-b","inputTokens":90000,"outputTokens":10000}]}}
    , .{});
    h.a.engine.state = .connected;
}

fn screenshot(h: *Harness, filename: []const u8) !void {
    const dir = std.c.getenv("NANO_SETTINGS_SNAP_DIR") orelse return;
    var path: [1024]u8 = undefined;
    try h.t.screenshot(try std.fmt.bufPrint(&path, "{s}/{s}.png", .{ std.mem.span(dir), filename }));
}

test "settings usage discovers and renders local tokens by runtime in both themes" {
    for ([_]bool{ true, false }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        try fixture(&h);
        view.open(&h.a);
        h.a.settings.setSection(.appearance);
        h.t.settle(0.2);
        if (dark) try screenshot(&h, "usage-before-dark");
        h.t.typeText("token counts");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("Usage"));
        try h.t.clickText("Usage");
        h.t.settle(0.2);
        try testing.expectEqual(Section.usage, h.a.settings.section);
        var row_visible = false;
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.indexOf(u8, tx.str, "Harness (sample-model-a)") != null) {
                row_visible = node.rect.x >= 0 and node.rect.y >= 0 and
                    node.rect.x + node.rect.w <= 1200 and node.rect.y + node.rect.h <= 780 and node.rect.w > 0;
            },
            else => {},
        };
        try testing.expect(row_visible);
        try testing.expect(h.t.containsText("Harness (sample-model-a)"));
        try testing.expect(h.t.containsText("Codex (sample-model-a)"));
        try testing.expect(h.t.containsText("AGY (sample-model-b)"));
        try testing.expect(h.t.containsText("Input 1.2M"));
        try testing.expect(h.t.containsText("Output 320.0K"));
        try testing.expect(h.t.containsText("This device · Recorded input + output · Not billing."));
        try testing.expect(!h.a.view.usage.partial);
        if (dark) try screenshot(&h, "usage-after-dark") else try screenshot(&h, "usage-after-light");
        try h.t.clickText("Refresh");
        h.t.settle(0.2);
        try testing.expect(h.t.containsText("Codex (sample-model-a)"));
        h.t.resize(900, 520);
        h.t.settle(0.1);
        try testing.expect(h.t.containsText("Codex (sample-model-a)"));
    }
}

test "settings usage labels partial sources and keeps empty-month copy explicit" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"LocalTokenUsage":{"periodStart":"Nov 1, 2026","asOf":"Nov 22, 2026","partial":true,"rows":[]}}
    , .{});
    h.a.engine.state = .connected;
    h.a.settings.setSection(.usage);
    view.open(&h.a);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("No recorded model usage for this month yet."));
    try testing.expect(h.t.hasText("Some local sources were unavailable or had unsupported records; totals may be partial."));
}

test "settings usage search matches local runtime and token-count terms" {
    try testing.expect(catalog.matches(.usage, "local usage"));
    try testing.expect(catalog.matches(.usage, "Codex token counts"));
    try testing.expect(!catalog.matches(.appearance, "Codex token counts"));
}
