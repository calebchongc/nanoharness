//! Settings › Usage: locally recorded model tokens, grouped by the runtime that
//! made each request. This page never calls provider APIs or syncs usage.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Phase = enum { idle, loading, ready, failed };
const sending: u64 = std.math.maxInt(u64);

pub const Row = struct {
    runtime: []const u8,
    model: []const u8,
    input: u64,
    output: u64,
};

pub const Page = struct {
    phase: Phase = .idle,
    call: ?u64 = null,
    arena: ?std.heap.ArenaAllocator = null,
    period_start: []const u8 = "",
    as_of: []const u8 = "",
    rows: []Row = &.{},
    partial: bool = false,
    error_text: []const u8 = "",

    pub fn deinit(p: *Page, gpa: Allocator) void {
        _ = gpa;
        p.clear();
    }

    fn clear(p: *Page) void {
        if (p.arena) |*arena| arena.deinit();
        p.arena = null;
        p.rows = &.{};
        p.period_start = "";
        p.as_of = "";
        p.error_text = "";
        p.partial = false;
    }
};

fn parseNumber(value: ?json.Value) ?u64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .number_string => |n| std.fmt.parseInt(u64, n, 10) catch null,
        else => null,
    };
}

fn parse(a: *App, page: *Page, value: json.Value) bool {
    if (value != .object) return false;
    const obj = value.object;
    const rows_value = obj.get("rows") orelse return false;
    if (rows_value != .array) return false;
    page.clear();
    page.arena = .init(a.gpa);
    const allocator = page.arena.?.allocator();
    const rows = allocator.alloc(Row, rows_value.array.items.len) catch return false;
    var n: usize = 0;
    for (rows_value.array.items) |item| {
        if (item != .object) continue;
        const fields = item.object;
        const runtime = fields.get("runtime") orelse continue;
        const model = fields.get("model") orelse continue;
        if (runtime != .string or model != .string) continue;
        const input = parseNumber(fields.get("inputTokens")) orelse continue;
        const output = parseNumber(fields.get("outputTokens")) orelse continue;
        rows[n] = .{
            .runtime = allocator.dupe(u8, runtime.string) catch return false,
            .model = allocator.dupe(u8, model.string) catch return false,
            .input = input,
            .output = output,
        };
        n += 1;
    }
    page.rows = rows[0..n];
    if (obj.get("periodStart")) |v| {
        if (v == .string) page.period_start = allocator.dupe(u8, v.string) catch "";
    }
    if (obj.get("asOf")) |v| {
        if (v == .string) page.as_of = allocator.dupe(u8, v.string) catch "";
    }
    if (obj.get("partial")) |v| {
        if (v == .bool) page.partial = v.bool;
    }
    return true;
}

fn receive(a: *App, id: u64, reply: rpc.Reply) void {
    const page = &a.view.usage;
    if (page.call == null or (page.call.? != id and page.call.? != sending)) return;
    page.call = null;
    switch (reply) {
        .ok => |value| {
            if (parse(a, page, value)) {
                page.phase = .ready;
            } else {
                page.phase = .failed;
                page.error_text = "The engine returned an unreadable usage summary.";
            }
        },
        .err => {
            page.phase = .failed;
            page.error_text = "Couldn't read local usage. Try refreshing.";
        },
        else => return,
    }
    a.redraw();
}

pub fn load(a: *App, refresh: bool) void {
    const page = &a.view.usage;
    if (page.phase == .loading or (!refresh and page.phase != .idle)) return;
    if (!a.engine.up()) {
        page.phase = .failed;
        page.error_text = "Engine not connected.";
        return;
    }
    page.phase = .loading;
    page.error_text = "";
    page.call = sending;
    const req = requests.localTokenUsage();
    const id = a.engine.call(req.method, req.params, .of(App, a, receive));
    if (page.call == sending) {
        page.call = id;
        if (id == null) {
            page.phase = .failed;
            page.error_text = "Couldn't request local usage. Try refreshing.";
        }
    }
}

fn total(rows: []const Row, runtime: ?[]const u8) u64 {
    var sum: u64 = 0;
    for (rows) |row| {
        if (runtime) |name| if (!std.mem.eql(u8, row.runtime, name)) continue;
        sum +|= row.input +| row.output;
    }
    return sum;
}

fn runtimeColor(runtime: []const u8, k: theme.Colors) ui.Color {
    if (std.mem.eql(u8, runtime, "Harness")) return k.accent;
    if (std.mem.eql(u8, runtime, "Codex")) return k.success;
    if (std.mem.eql(u8, runtime, "AGY")) return k.warning;
    return k.muted;
}

const Runtime = struct { name: []const u8, amount: u64 };

fn pie(c: *ui.Context, rows: []const Row, k: theme.Colors, all: u64) void {
    const size: f32 = 112;
    const center: ui.Point = .{ .x = size / 2, .y = size / 2 };
    const cv = ui.canvas(c, .{ .width = .{ .px = size }, .height = .{ .px = size } });
    cv.ring(center, 38, 12, k.border);
    if (all == 0) return;
    const names = [_][]const u8{ "Harness", "Codex", "AGY", "Other" };
    var segments: [4]Runtime = undefined;
    var count: usize = 0;
    for (names) |name| {
        const value = total(rows, name);
        if (value == 0) continue;
        segments[count] = .{ .name = name, .amount = value };
        count += 1;
    }
    var angle: f32 = -std.math.pi / 2.0;
    for (segments[0..count]) |segment| {
        const fraction = @as(f32, @floatFromInt(segment.amount)) / @as(f32, @floatFromInt(all));
        const steps: usize = @intFromFloat(@max(2, @ceil(72 * fraction)));
        const points = c.alloc().alloc(ui.Point, steps + 1) catch continue;
        for (points, 0..) |*point, index| {
            const theta = angle + std.math.tau * fraction * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(steps));
            point.* = .{ .x = center.x + 38 * @cos(theta), .y = center.y + 38 * @sin(theta) };
        }
        cv.polyline(points, .{ .width = 12, .color = runtimeColor(segment.name, k) });
        angle += std.math.tau * fraction;
    }
}

fn abbreviated(n: u64, buffer: *[24]u8) []const u8 {
    if (n >= 1_000_000_000) return std.fmt.bufPrint(buffer, "{d:.2}B", .{@as(f64, @floatFromInt(n)) / 1_000_000_000.0}) catch "";
    if (n >= 1_000_000) return std.fmt.bufPrint(buffer, "{d:.1}M", .{@as(f64, @floatFromInt(n)) / 1_000_000.0}) catch "";
    if (n >= 1_000) return std.fmt.bufPrint(buffer, "{d:.1}K", .{@as(f64, @floatFromInt(n)) / 1_000.0}) catch "";
    return std.fmt.bufPrint(buffer, "{d}", .{n}) catch "";
}

pub fn pageView(c: *ui.Context, a: *App, k: theme.Colors) void {
    const page = &a.view.usage;
    load(a, false);
    set.header(c, k, "Usage", null);
    set.subtitle(c, k, "This device · Recorded input + output · Not billing. Usage is read from local runtime records; cache is included where the runtime reports it.", true);
    set.space(c, 12);
    {
        const toolbar = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer toolbar.end();
        ui.text(c, if (page.period_start.len > 0) c.print("{s} through {s}", .{ page.period_start, page.as_of }) else "This calendar month", set.st(c, 12, .{ .color = k.muted }));
        ui.spacer(c);
        ui.key(c, "settings-usage-refresh");
        const refresh = kit.pressFeedback(ui.div(c).row().px(11).py(7).gap(6).rounded(8).border(k.border).borderW(1).hover(k.hover).control());
        _ = kit.focusRing(c, refresh, k.accent, 2);
        const refresh_hot = refresh.hovered();
        ui.text(c, if (page.phase == .loading) "Refreshing…" else "Refresh", set.st(c, 12, .{ .weight = .medium, .color = if (refresh_hot) k.text else k.muted }));
        if (refresh.clicked() and page.phase != .loading) load(a, true);
        refresh.end();
    }
    set.space(c, 15);
    switch (page.phase) {
        .idle, .loading => ui.text(c, "Reading this device’s local usage records…", set.st(c, 13, .{ .color = k.muted })),
        .failed => {
            const failure = ui.div(c).column().w(set.inner_w).gap(8);
            defer failure.end();
            ui.text(c, page.error_text, set.st(c, 13, .{ .color = k.warning, .wrap = true }));
            ui.text(c, "Check the local engine connection, then refresh.", set.st(c, 12, .{ .color = k.muted }));
        },
        .ready => {
            if (page.partial) {
                const warning = ui.div(c).column().w(set.inner_w);
                defer warning.end();
                ui.text(c, "Some local sources were unavailable or had unsupported records; totals may be partial.", set.st(c, 12, .{ .color = k.warning, .wrap = true }));
            }
            const sum = total(page.rows, null);
            if (sum == 0) {
                ui.text(c, "No recorded model usage for this month yet.", set.st(c, 13, .{ .color = k.muted }));
                return;
            }
            {
                const chart = ui.div(c).column().w(set.inner_w).h(128).itemsCenter();
                defer chart.end();
                pie(c, page.rows, k, sum);
            }
            const list = ui.div(c).column().w(set.inner_w).gap(6);
            defer list.end();
            var total_buf: [24]u8 = undefined;
            ui.text(c, c.print("Total · {s} tokens", .{abbreviated(sum, &total_buf)}), set.st(c, 12, .{ .weight = .semibold, .color = k.text }));
            ui.text(c, "Model / runtime · input · output · share", set.st(c, 12, .{ .weight = .semibold, .color = k.text }));
            for (page.rows) |row| {
                var input_buf: [24]u8 = undefined;
                var output_buf: [24]u8 = undefined;
                const amount = row.input +| row.output;
                const share: f32 = @as(f32, @floatFromInt(amount)) / @as(f32, @floatFromInt(sum)) * 100;
                ui.text(c, c.print("{s} ({s}) · Input {s} · Output {s} · {d:.1}%", .{
                    row.runtime,
                    row.model,
                    abbreviated(row.input, &input_buf),
                    abbreviated(row.output, &output_buf),
                    share,
                }), set.st(c, 12, .{ .color = k.text, .wrap = true }));
            }
        },
    }
}
