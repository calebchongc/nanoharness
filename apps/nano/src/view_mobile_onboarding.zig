//! First-run setup on the phone (OnboardingView.swift): which agent, how
//! hard it thinks, how much it may do without asking, whether to ping you,
//! then a ready page. Shown after a first sign-in and from Settings ›
//! Replay setup. Its state is the app's setup (view_setup.zig `Setup`):
//! finishing sets the new chat's agent, model, effort, notifications and
//! starter there. The extras and the autonomy belong to a computer, so the
//! phone writes them on the first one that runs agents (online first),
//! with `targetDeviceId`, not on itself.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const rpc = @import("rpc.zig");
const rules = @import("rules.zig");
const setup = @import("view_setup.zig");
const ms = @import("mobile_settings.zig");
const agent = @import("app_agent.zig");

pub const Step = enum(u3) { agent, effort, autonomy, notify, ready };

pub fn stepTitle(s: Step) []const u8 {
    return switch (s) {
        .agent => "Which agent starts your sessions?",
        .effort => "How hard should it think?",
        .autonomy => "How much can it do without asking?",
        .notify => "Ping you when it needs you?",
        .ready => "Your first agent is ready",
    };
}

pub fn stepSubtitle(s: Step) ?[]const u8 {
    return switch (s) {
        .agent => "Graff is already connected through your CodeGraff sign-in. Add Claude Code or Codex too if you use them.",
        .effort => "Your default for new Graff sessions. Change it per message from the composer.",
        else => null,
    };
}

pub fn nextLabel(s: Step, notify: bool) []const u8 {
    return switch (s) {
        .notify => if (notify) "Turn on" else "Next",
        .ready => "Start a session",
        else => "Next",
    };
}

const counters = [_][]const u8{ "1/4", "2/4", "3/4", "4/4" };

/// "n/4": the ready page counts as the fourth.
pub fn counter(s: Step) []const u8 {
    return counters[@min(@intFromEnum(s), 3)];
}

pub fn active(a: *const App) bool {
    return a.view.setup != null;
}

fn nowMs(a: *const App) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(a.io).nanoseconds, std.time.ns_per_ms));
}

/// The computer the setup's per-computer answers go to.
fn host(a: *const App) ?struct { id: []const u8, name: []const u8 } {
    var hosts: [32]ms.Host = undefined;
    const n = @min(a.devices.items.len, hosts.len);
    for (a.devices.items[0..n], 0..) |d, i| hosts[i] = .{ .platform = d.platform, .last_seen_ms = d.last_seen_ms, .own = if (a.device_id) |me| std.mem.eql(u8, me, d.id) else false };
    var order: [1]usize = undefined;
    if (ms.hostOrder(&order, hosts[0..n], nowMs(a)) == 0) return null;
    const d = a.devices.items[order[0]];
    return .{ .id = d.id, .name = d.name };
}

/// Opens it at the first question (a first sign-in, or Replay setup).
pub fn start(a: *App) void {
    a.view.setup = .{};
    agent.ensureModels(a, "graff");
    if (host(a)) |h| {
        if (a.engine.call("GetAutonomy", .{ .targetDeviceId = h.id }, .of(App, a, onAutonomy))) |id| a.view.setup.?.autonomy_call = id;
    }
    a.redraw();
}

fn onAutonomy(a: *App, _: u64, r: rpc.Reply) void {
    const s = if (a.view.setup) |*x| x else return;
    s.autonomy_call = null;
    if (r == .ok) if (setup.readAutonomy(r.ok)) |v| if (v.chosen) {
        s.autonomy = v.autonomy;
    };
    a.redraw();
}

fn onWritten(a: *App, _: u64, r: rpc.Reply) void {
    if (r == .err) if (a.view.setup) |*s| {
        s.err = "Couldn't reach your computer. Try again, or skip and set it in Settings.";
    };
    a.redraw();
}

const extras = [_][]const u8{ "claude-code", "codex" };
const extra_names = [_][]const u8{ "Claude Code", "OpenAI Codex" };
const levels_fallback = [_][]const u8{ "low", "medium", "high" };

fn graffModels(a: *const App) []const @import("workspace.zig").Model {
    if (!std.mem.eql(u8, a.models_for, "graff")) return &.{};
    return a.models.items[0..@min(3, a.models.items.len)];
}

fn ladder(a: *const App, s: *const setup.Setup) []const []const u8 {
    const m = graffModels(a);
    if (m.len > 0 and m[@min(s.model, m.len - 1)].levels.len > 0) return m[@min(s.model, m.len - 1)].levels;
    return &levels_fallback;
}

fn levelAt(a: *const App, s: *const setup.Setup) ?usize {
    const l = ladder(a, s);
    if (s.level) |i| return @min(i, l.len - 1);
    const d = rules.defaultReasoning(l) orelse return null;
    for (l, 0..) |x, i| if (std.mem.eql(u8, x, d)) return i;
    return null;
}

fn next(a: *App) void {
    const s = if (a.view.setup) |*x| x else return;
    s.err = null;
    const step: Step = @enumFromInt(@min(s.step, 4));
    const h = host(a);
    switch (step) {
        .agent => if (h) |hh| for (extras, 0..) |id, i| if (s.extras_on[i] != s.extras_was[i]) {
            s.extras_was[i] = s.extras_on[i];
            _ = a.engine.call("SetHarnessEnabled", .{ .harness = id, .enabled = s.extras_on[i], .targetDeviceId = hh.id }, .of(App, a, onWritten));
        },
        .autonomy => if (h) |hh| {
            _ = a.engine.call("SetAutonomy", .{ .autonomy = s.autonomy.wire(), .targetDeviceId = hh.id }, .of(App, a, onWritten));
        },
        .ready => return setup.finish(a, false),
        else => {},
    }
    s.step += 1;
    a.redraw();
}

fn choice(c: *ui.Context, k: theme.Colors, id: u64, title: []const u8, detail: ?[]const u8, picked: bool) bool {
    ui.keyInt(c, id);
    const r = ui.div(c).row().wFull().px(16).py(14).gap(12).itemsCenter().rounded(16)
        .bg(if (picked) k.text.alpha(0.08) else k.text.alpha(0.03)).border(if (picked) k.text.alpha(0.3) else k.border.alpha(0.6)).borderW(1).control();
    defer r.end();
    {
        const col = ui.div(c).column().grow().gap(3);
        defer col.end();
        ui.text(c, title, .{ .size = 15.5, .weight = .semibold, .color = k.text });
        if (detail) |d| ui.text(c, d, .{ .size = 13, .line_height = 18, .wrap = true, .color = k.muted });
    }
    icons.icon(c, if (picked) .check else .plus, 15, if (picked) k.text else k.faint, 0);
    return r.clicked();
}

/// Drawn over the app while the setup is open; true when it was.
pub fn render(a: *App, c: *ui.Context, k: theme.Colors) bool {
    const s = if (a.view.setup) |*x| x else return false;
    const step: Step = @enumFromInt(@min(s.step, 4));
    const root = ui.div(c).column().sizeFull().bg(k.background).pt(c.safe_area.top + 12).pb(@max(c.safe_area.bottom, 16)).px(22).gap(18).fixed().offset(0, 0).layer(3);
    defer root.end();
    {
        const top = ui.div(c).row().wFull().h(36).itemsCenter().justifyBetween();
        defer top.end();
        if (s.step > 0) {
            ui.key(c, "setup-back");
            const b = ui.div(c).row().size(36, 36).center().control();
            defer b.end();
            icons.icon(c, .@"alt-arrow-left", 16, k.text, 0);
            if (b.clicked()) s.step -= 1;
        } else _ = ui.div(c).size(36, 36).end();
        ui.text(c, counter(step), .{ .size = 13, .color = k.muted });
    }
    {
        const head = ui.div(c).column().wFull().gap(8);
        defer head.end();
        ui.text(c, stepTitle(step), .{ .size = 26, .weight = .semibold, .line_height = 31, .wrap = true, .color = k.text });
        const sub: ?[]const u8 = if (step == .ready) (if (host(a)) |h| c.print("Graff is live on {s}.", .{h.name}) else "Graff is ready.") else stepSubtitle(step);
        if (sub) |t| ui.text(c, t, .{ .size = 15, .line_height = 21, .wrap = true, .color = k.muted });
    }
    {
        ui.key(c, "setup-body");
        const body = ui.div(c).column().wFull().grow().gap(10).scrollY();
        defer body.end();
        switch (step) {
            .agent => {
                _ = choice(c, k, 0x7367_0001, "Graff", "Connected with your CodeGraff account", true);
                ui.text(c, "OPTIONAL EXTRAS", .{ .size = 11, .weight = .semibold, .color = k.muted });
                for (extra_names, 0..) |name, i| {
                    if (choice(c, k, 0x7367_0010 + @as(u64, i), name, null, s.extras_on[i])) s.extras_on[i] = !s.extras_on[i];
                }
            },
            .effort => {
                const models = graffModels(a);
                if (models.len > 0) {
                    ui.text(c, "Graff models from your CodeGraff account", .{ .size = 12.5, .color = k.muted });
                    for (models, 0..) |m, i| {
                        if (choice(c, k, 0x7367_0100 + @as(u64, i), m.label, null, i == @min(s.model, models.len - 1))) {
                            s.model = i;
                            s.level = null;
                        }
                    }
                }
                const l = ladder(a, s);
                const at = levelAt(a, s);
                for (l, 0..) |lvl, i| {
                    if (choice(c, k, 0x7367_0200 + @as(u64, i), rules.reasoningLabel(lvl), levelBlurb(lvl), at != null and at.? == i)) s.level = i;
                }
            },
            .autonomy => {
                for (setup.Autonomy.all, 0..) |x, i| {
                    if (choice(c, k, 0x7367_0300 + @as(u64, i), x.label(), x.blurb(), s.autonomy == x)) s.autonomy = x;
                }
            },
            .notify => {
                if (choice(c, k, 0x7367_0400, "Yes", null, s.notify)) s.notify = true;
                if (choice(c, k, 0x7367_0401, "No", null, !s.notify)) s.notify = false;
            },
            .ready => {
                const models = graffModels(a);
                const l = ladder(a, s);
                const at = levelAt(a, s);
                const rows = [_][2][]const u8{
                    .{ "Agent", "Graff" },
                    .{ "Model", if (models.len > 0) models[@min(s.model, models.len - 1)].label else "Graff default" },
                    .{ "Thinking", if (at) |i| rules.reasoningLabel(l[i]) else "Default" },
                    .{ "Access", s.autonomy.label() },
                };
                const g = ui.div(c).column().wFull().rounded(16).bg(k.text.alpha(0.04)).p(4);
                defer g.end();
                for (rows) |r| {
                    const row = ui.div(c).row().wFull().h(42).px(12).itemsCenter().justifyBetween();
                    defer row.end();
                    ui.text(c, r[0], .{ .size = 14.5, .color = k.muted });
                    ui.text(c, r[1], .{ .size = 14.5, .weight = .medium, .color = k.text });
                }
            },
        }
        if (s.err) |e| ui.text(c, e, .{ .size = 13, .wrap = true, .color = k.danger });
    }
    {
        ui.key(c, "setup-next");
        const b = ui.div(c).row().wFull().h(50).center().gap(6).rounded(16).bg(k.text).control();
        defer b.end();
        ui.text(c, nextLabel(step, s.notify), .{ .size = 15.5, .weight = .semibold, .color = k.background });
        if (step != .ready) icons.icon(c, .@"alt-arrow-right", 13, k.background, 0);
        if (b.clicked()) next(a);
    }
    {
        const foot = ui.div(c).row().wFull().justifyBetween().itemsCenter();
        defer foot.end();
        ui.text(c, "Change any of this in Settings", .{ .size = 12.5, .color = k.faint });
        if (step != .ready) {
            ui.key(c, "setup-skip");
            const sk = ui.div(c).row().py(4).control();
            defer sk.end();
            ui.text(c, "Skip setup", .{ .size = 13, .weight = .medium, .color = k.muted });
            if (sk.clicked()) setup.finish(a, true);
        }
    }
    return true;
}

fn levelBlurb(level: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, level, "none") or eql(u8, level, "minimal")) return "Answers straight away.";
    if (eql(u8, level, "low")) return "Quick answers and light edits.";
    if (eql(u8, level, "medium")) return "Balanced for everyday changes.";
    if (eql(u8, level, "high")) return "Thinks before it edits. The default for real work.";
    if (eql(u8, level, "xhigh")) return "Takes its time on hard problems.";
    return "The most thinking it does. Slower, for the hardest work.";
}

pub fn applyPreview(a: *App, which: []const u8) void {
    if (!std.mem.startsWith(u8, which, "setup-")) return;
    const n = std.fmt.parseInt(u3, which["setup-".len..], 10) catch return;
    a.view.setup = .{ .step = @min(n, 4) };
}

const testing = std.testing;

test "setup pages: titles, counters and the Next label as the Swift setup has them" {
    try testing.expectEqualStrings("How much can it do without asking?", stepTitle(.autonomy));
    try testing.expectEqualStrings("1/4", counter(.agent));
    try testing.expectEqualStrings("4/4", counter(.ready));
    try testing.expectEqualStrings("Turn on", nextLabel(.notify, true));
    try testing.expectEqualStrings("Next", nextLabel(.notify, false));
    try testing.expectEqualStrings("Start a session", nextLabel(.ready, true));
    try testing.expect(stepSubtitle(.notify) == null);
}

test "setup: the autonomy answer goes to your computer, not the phone, and finishing closes it" {
    theme.registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.mobile_preview = true;
    a.new_harness = try testing.allocator.dupe(u8, "graff");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"AuthStatus":{"$items":[{"state":"signedIn","user":{"id":"u","email":"sam@example.com","name":null}}]},
        \\ "GetAutonomy":{"autonomy":"full-access","chosen":false},"SetAutonomy":{"autonomy":"read-only","chosen":true},
        \\ "SetHarnessEnabled":[]}
    , .{});
    a.engine.state = .connected;
    {
        const d = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"dev-box","name":"Build Box","platform":"macos"}]
        , .{});
        defer d.deinit();
        try a.devices.replace(d.value);
    }
    start(&a);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view_mobile.zig").view), .{ .width = 402, .height = 874 });
    defer t.deinit();
    t.frame();
    try testing.expect(t.hasText("Which agent starts your sessions?"));
    try t.clickText("Next");
    t.frame();
    try testing.expect(t.hasText("How hard should it think?"));
    try t.clickText("Next");
    t.frame();
    try t.clickText("Read only");
    t.frame();
    try t.clickText("Next");
    t.frame();
    try testing.expect(t.hasText("Ping you when it needs you?"));
    var sent = false;
    for (a.engine.sent.items) |f| if (std.mem.indexOf(u8, f, "\"SetAutonomy\"") != null and std.mem.indexOf(u8, f, "read-only") != null and std.mem.indexOf(u8, f, "dev-box") != null) {
        sent = true;
    };
    try testing.expect(sent);
    try t.clickText("Turn on");
    t.frame();
    try testing.expect(t.hasText("Graff is live on Build Box."));
    try t.clickText("Start a session");
    t.frame();
    try testing.expect(a.view.setup == null);
    try testing.expect(a.settings.get(.notifications_enabled));
}
