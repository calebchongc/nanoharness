//! Settings (SettingsView.swift): Appearance › Theme, Notifications,
//! Agents › Autonomy and Graff compaction (read and written on one of your
//! computers, as the desktop's Settings does), Replay setup, your
//! computers, Layout (Zen / Developer, Split view), Diagnostics ›
//! Performance, and About. Notification choices are stored as preferences
//! only: the push registration that would act on them is not this app's.
//! Usage lives in Profile, as in the Swift app.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const icons = @import("icons.zig");
const mg = @import("mobile_glass.zig");
const rpc = @import("rpc.zig");
const ios_scroll = @import("ios_scroll.zig");
const ms = @import("mobile_settings.zig");
const mp = @import("mobile_parity.zig");
const setup = @import("view_setup.zig");
const accounts = @import("accounts.zig");
const Text = @import("app_mobile_auth.zig").Text;

pub const Page = enum { root, appearance, notifications, autonomy, compaction, usage, performance };

pub fn pageTitle(p: Page) []const u8 {
    return switch (p) {
        .root => "Settings",
        .appearance => "Theme",
        .notifications => "Notifications",
        .autonomy => "Autonomy",
        .compaction => "Graff compaction",
        .usage => "Usage",
        .performance => "Performance",
    };
}

/// A per-computer value read over the engine: loading, loaded, or why not.
pub fn Slot(comptime T: type) type {
    return struct {
        call: ?u64 = null,
        value: ?T = null,
        err: Text(200) = .{},
        loading: bool = false,
        saving: bool = false,
    };
}

pub const KeepAwake = struct { enabled: bool, supported: bool };

pub const UsageView = struct {
    email: Text(96) = .{},
    tier: Text(32) = .{},
    credits: i64 = 0,
    spend30: i64 = 0,
    requests30: i64 = 0,
    signed_in: bool = false,
};

pub const State = struct {
    page: Page = .root,
    /// The computer picked for per-computer settings (index into the host order).
    host: usize = 0,
    autonomy: Slot(setup.Autonomy) = .{},
    compact: Slot(?u8) = .{},
    keep_awake: Slot(KeepAwake) = .{},
    usage: Slot(UsageView) = .{},
};

fn st(a: *App) *State {
    return &a.mobile.settings_ui;
}

fn nowMs(a: *const App) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(a.io).nanoseconds, std.time.ns_per_ms));
}

/// The computer per-computer settings read from: its id and name.
fn hostOf(a: *App) ?struct { id: []const u8, name: []const u8 } {
    var hosts: [32]ms.Host = undefined;
    const n = @min(a.devices.items.len, hosts.len);
    for (a.devices.items[0..n], 0..) |d, i| hosts[i] = .{ .platform = d.platform, .last_seen_ms = d.last_seen_ms, .own = if (a.device_id) |me| std.mem.eql(u8, me, d.id) else false };
    var order: [32]usize = undefined;
    const k = ms.hostOrder(&order, hosts[0..n], nowMs(a));
    if (k == 0) return null;
    const d = a.devices.items[order[@min(st(a).host, k - 1)]];
    return .{ .id = d.id, .name = d.name };
}

fn isHost(a: *const App, d: @import("workspace.zig").Device) bool {
    if (a.device_id) |me| if (std.mem.eql(u8, me, d.id)) return false;
    return ms.canHost(d.platform);
}

fn hostCount(a: *App) usize {
    var n: usize = 0;
    for (a.devices.items) |d| if (isHost(a, d)) {
        n += 1;
    };
    return n;
}

// ── loading ──────────────────────────────────────────────────────────

fn open(a: *App, p: Page) void {
    st(a).page = p;
    load(a, p);
}

fn load(a: *App, p: Page) void {
    const s = st(a);
    const h = hostOf(a) orelse return;
    switch (p) {
        .autonomy => {
            s.autonomy.loading = true;
            s.autonomy.err.clear();
            s.autonomy.call = a.engine.call("GetAutonomy", .{ .targetDeviceId = h.id }, .of(App, a, onAutonomy));
            s.keep_awake.call = a.engine.call("GetKeepAwake", .{ .targetDeviceId = h.id }, .of(App, a, onKeepAwake));
        },
        .compaction => {
            s.compact.loading = true;
            s.compact.err.clear();
            s.compact.call = a.engine.call("GetGraffCompactAt", .{ .targetDeviceId = h.id }, .of(App, a, onCompact));
        },
        .usage => {
            s.usage.loading = true;
            s.usage.err.clear();
            s.usage.call = a.engine.call("CodegraffUsage", .{ .targetDeviceId = h.id }, .of(App, a, onUsage));
        },
        else => {},
    }
}

fn failed(a: *App, slot_err: anytype, e: []const u8) void {
    var b: [200]u8 = undefined;
    const name = if (hostOf(a)) |h| h.name else "your computer";
    slot_err.set(ms.failedCopy(&b, name, e));
}

fn onAutonomy(a: *App, _: u64, r: rpc.Reply) void {
    const s = &st(a).autonomy;
    s.loading = false;
    s.saving = false;
    switch (r) {
        .ok => |v| if (setup.readAutonomy(v)) |x| {
            s.value = x.autonomy;
        } else failed(a, &s.err, "Unexpected reply"),
        .err => |e| failed(a, &s.err, e),
        else => {},
    }
    a.redraw();
}

fn onKeepAwake(a: *App, _: u64, r: rpc.Reply) void {
    const s = &st(a).keep_awake;
    s.saving = false;
    switch (r) {
        .ok => |v| if (v == .object) {
            const en = v.object.get("enabled");
            const sup = v.object.get("supported");
            s.value = .{ .enabled = en != null and en.? == .bool and en.?.bool, .supported = sup != null and sup.? == .bool and sup.?.bool };
        },
        // Older engines don't have it: the row stays hidden.
        else => s.value = null,
    }
    a.redraw();
}

fn onCompact(a: *App, _: u64, r: rpc.Reply) void {
    const s = &st(a).compact;
    s.loading = false;
    s.saving = false;
    switch (r) {
        .ok => |v| switch (v) {
            .null => s.value = @as(?u8, null),
            .integer => |n| s.value = @as(?u8, std.math.cast(u8, n)),
            else => failed(a, &s.err, "Unexpected reply"),
        },
        .err => |e| failed(a, &s.err, e),
        else => {},
    }
    a.redraw();
}

fn onUsage(a: *App, _: u64, r: rpc.Reply) void {
    const s = &st(a).usage;
    s.loading = false;
    switch (r) {
        .ok => |v| {
            var arena: std.heap.ArenaAllocator = .init(a.gpa);
            defer arena.deinit();
            var u: UsageView = .{};
            if (accounts.parseUsage(arena.allocator(), v) catch null) |got| {
                u.signed_in = true;
                u.email.set(got.email);
                u.tier.set(got.tier);
                u.credits = got.credits_micro_usd;
                u.spend30 = got.spend_30d_micro_usd;
                u.requests30 = got.requests_30d;
            }
            s.value = u;
        },
        .err => |e| failed(a, &s.err, e),
        else => {},
    }
    a.redraw();
}

// ── drawing ──────────────────────────────────────────────────────────

fn header(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const h = ui.div(c).row().wFull().px(4).pt(6);
    defer h.end();
    ui.text(c, label, .{ .size = 12.5, .weight = .semibold, .color = k.muted });
}

fn footer(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const f = ui.div(c).row().wFull().px(4);
    defer f.end();
    ui.text(c, text, .{ .size = 12, .line_height = 16, .wrap = true, .color = k.muted });
}

fn group(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().rounded(14).bg(k.raised.alpha(0.6)).clip();
}

fn sep(c: *ui.Context, k: theme.Colors) void {
    _ = ui.div(c).wFull().h(1).bg(k.border.alpha(0.5)).end();
}

/// A row that opens a page: label, value, chevron.
fn link(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8, value: []const u8) bool {
    ui.key(c, key);
    const r = ui.div(c).row().wFull().h(46).px(14).gap(8).itemsCenter().control();
    defer r.end();
    ui.text(c, label, .{ .size = 15, .color = k.text });
    _ = ui.div(c).grow().end();
    if (value.len > 0) ui.text(c, value, .{ .size = 15, .truncate = .ellipsis, .color = k.muted });
    icons.icon(c, .@"alt-arrow-right", 12, k.faint, 0);
    return r.clicked();
}

fn toggleRow(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8, on: bool) bool {
    ui.key(c, key);
    const r = ui.div(c).row().wFull().h(46).px(14).itemsCenter().justifyBetween().control();
    defer r.end();
    ui.text(c, label, .{ .size = 15, .color = k.text });
    {
        const track = ui.div(c).row().w(46).h(28).p(2).roundedFull().circular().bg(if (on) k.success else k.text.alpha(0.16));
        defer track.end();
        if (on) _ = ui.div(c).grow().end();
        _ = ui.div(c).size(24, 24).roundedFull().circular().bg(ui.Color.white).end();
    }
    return r.clicked();
}

/// A choice in an inline picker: label, optional blurb, check when picked.
fn choiceRow(c: *ui.Context, k: theme.Colors, id: u64, label: []const u8, blurb: ?[]const u8, picked: bool) bool {
    ui.keyInt(c, id);
    const r = ui.div(c).row().wFull().px(14).py(11).gap(8).itemsCenter().control();
    defer r.end();
    {
        const col = ui.div(c).column().grow().gap(2);
        defer col.end();
        ui.text(c, label, .{ .size = 15, .color = k.text });
        if (blurb) |b| ui.text(c, b, .{ .size = 12.5, .wrap = true, .color = k.muted });
    }
    if (picked) icons.icon(c, .check, 15, k.accent, 0);
    return r.clicked();
}

fn segmented(c: *ui.Context, k: theme.Colors, key: []const u8, labels: []const []const u8, picked: usize) ?usize {
    ui.key(c, key);
    const r = ui.div(c).row().wFull().p(3).gap(3).rounded(10).bg(k.text.alpha(0.06));
    defer r.end();
    var out: ?usize = null;
    for (labels, 0..) |l, i| {
        ui.keyInt(c, 0x7365_6700 + @as(u64, i));
        const seg = ui.div(c).row().grow().h(32).center().rounded(8).bg(if (i == picked) k.card else ui.Color.transparent).control();
        defer seg.end();
        ui.text(c, l, .{ .size = 13.5, .weight = if (i == picked) .semibold else .regular, .color = k.text });
        if (seg.clicked()) out = i;
    }
    return out;
}

fn loadingRow(c: *ui.Context, k: theme.Colors) void {
    const r = ui.div(c).row().wFull().h(46).px(14).gap(10).itemsCenter();
    defer r.end();
    kit.spinner(c, .{ .size = 14, .color = k.muted });
    ui.text(c, "Loading…", .{ .size = 15, .color = k.muted });
}

fn messageRow(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const r = ui.div(c).row().wFull().px(14).py(12);
    defer r.end();
    ui.text(c, text, .{ .size = 14, .wrap = true, .color = k.muted });
}

fn noHosts(c: *ui.Context, k: theme.Colors, what: []const u8) void {
    const g = group(c, k);
    defer g.end();
    messageRow(c, k, what);
}

/// The computer picker for per-computer pages (shown with more than one).
fn hostPicker(a: *App, c: *ui.Context, k: theme.Colors, page: Page) void {
    if (hostCount(a) < 2) return;
    const h = hostOf(a) orelse return;
    header(c, k, "Computer");
    const g = group(c, k);
    defer g.end();
    if (link(c, k, "settings-host", "Computer", h.name)) {
        st(a).host = (st(a).host + 1) % hostCount(a);
        load(a, page);
    }
}

pub fn title(a: *const App) []const u8 {
    return pageTitle(a.mobile.settings_ui.page);
}

pub fn render(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    const s = st(a);
    if (s.page != .root) {
        ui.key(c, "settings-back");
        const b = ui.div(c).row().gap(4).itemsCenter().py(2).control();
        defer b.end();
        icons.icon(c, .@"alt-arrow-left", 13, k.accent, 0);
        ui.text(c, "Settings", .{ .size = 14, .color = k.accent });
        if (b.clicked()) s.page = .root;
    }
    ui.key(c, "ios-settings-scroll");
    const sc = ui.div(c).column().wFull().maxH(@max(320, c.size.h - c.safe_area.top - 160)).gap(8).scrollY();
    defer sc.end();
    switch (s.page) {
        .root => root(a, c, k, rt),
        .appearance => appearance(a, c, k),
        .notifications => notifications(a, c, k),
        .autonomy => autonomy(a, c, k),
        .compaction => compaction(a, c, k),
        .usage => usage(a, c, k),
        .performance => performance(a, c, k),
    }
}

fn themeName(a: *const App) []const u8 {
    if (a.mobile.theme_override_id) |tid| if (themes.findMobile(tid)) |v| return v.name;
    return "System";
}

fn root(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    _ = rt;
    header(c, k, "Appearance");
    {
        const g = group(c, k);
        defer g.end();
        if (link(c, k, "settings-appearance", "Theme", themeName(a))) open(a, .appearance);
    }
    header(c, k, "Notifications");
    {
        const g = group(c, k);
        defer g.end();
        if (link(c, k, "settings-notifications", "Session notifications", "")) open(a, .notifications);
    }
    header(c, k, "Agents");
    {
        const g = group(c, k);
        defer g.end();
        if (link(c, k, "settings-autonomy", "Autonomy", "")) open(a, .autonomy);
        sep(c, k);
        if (link(c, k, "settings-compaction", "Graff compaction", "")) open(a, .compaction);
        sep(c, k);
        ui.key(c, "settings-replay-setup");
        const r = ui.div(c).row().wFull().h(46).px(14).itemsCenter().control();
        defer r.end();
        ui.text(c, "Replay setup", .{ .size = 15, .color = k.text });
        if (r.clicked()) {
            a.mobile.sheet = .none;
            @import("view_mobile_onboarding.zig").start(a);
        }
    }
    header(c, k, "Computers");
    {
        const g = group(c, k);
        defer g.end();
        var any = false;
        const now = nowMs(a);
        for (a.devices.items, 0..) |d, i| {
            if (!isHost(a, d)) continue;
            if (any) sep(c, k);
            any = true;
            ui.keyInt(c, 0x6465_7600 + @as(u64, i));
            const r = ui.div(c).row().wFull().h(46).px(14).gap(10).itemsCenter();
            defer r.end();
            const seen: ?i64 = if (d.last_seen_ms > 0) d.last_seen_ms else null;
            const on = mp.presenceStatus(now, seen, true, null, seen) == .online;
            icons.icon(c, .laptop, 15, k.muted, 0);
            ui.text(c, d.name, .{ .size = 15, .color = k.text });
            _ = ui.div(c).grow().end();
            _ = ui.div(c).size(7, 7).roundedFull().circular().bg(if (on) k.success else k.faint).end();
            ui.text(c, if (on) "Online" else "Offline", .{ .size = 13, .color = k.muted });
        }
        if (!any) messageRow(c, k, "Agents run on your computers. Open Harness on one and sign in.");
    }
    header(c, k, "Layout");
    {
        const g = group(c, k);
        defer g.end();
        const box = ui.div(c).column().wFull().p(10).gap(10);
        defer box.end();
        if (segmented(c, k, "settings-ui-mode", &.{ "Zen", "Developer" }, if (a.mobile.zen_mode) 0 else 1)) |i| a.mobile.zen_mode = i == 0;
        ui.text(c, "Split view", .{ .size = 13, .color = k.muted });
        const modes = [_]ios_scroll.SplitMode{ .auto, .on, .off };
        const picked: usize = for (modes, 0..) |m, i| {
            if (m == a.mobile.split_mode) break i;
        } else 0;
        if (segmented(c, k, "settings-phone-split", &ms.split_labels, picked)) |i| a.mobile.split_mode = modes[i];
    }
    footer(c, k, "Switch everything at once with Zen (all off) or Developer (all on).");
    header(c, k, "Diagnostics");
    {
        const g = group(c, k);
        defer g.end();
        if (link(c, k, "settings-performance", "Performance", "")) open(a, .performance);
    }
    header(c, k, "About");
    {
        const g = group(c, k);
        defer g.end();
        {
            const r = ui.div(c).row().wFull().h(46).px(14).itemsCenter().justifyBetween();
            defer r.end();
            ui.text(c, "Version", .{ .size = 15, .color = k.text });
            ui.text(c, version_line, .{ .size = 15, .color = k.muted });
        }
        inline for (.{ .{ "settings-privacy", "Privacy policy", ms.privacy_url }, .{ "settings-help", "Help and feedback", ms.support_url }, .{ "settings-email", "Email support", ms.support_email_url } }) |l| {
            sep(c, k);
            ui.key(c, l[0]);
            const r = ui.div(c).row().wFull().h(46).px(14).itemsCenter().control();
            defer r.end();
            ui.text(c, l[1], .{ .size = 15, .color = k.accent });
            if (r.clicked()) _ = nanoui.shell.openUrl(l[2]);
        }
    }
}

const version_line = blk: {
    const v = @import("build_info").version;
    const build = if (std.mem.lastIndexOfScalar(u8, v, '.')) |i| v[i + 1 ..] else v;
    break :blk v ++ " (" ++ build ++ ")";
};

fn appearance(a: *App, c: *ui.Context, k: theme.Colors) void {
    const all = themes.mobileAll();
    const g = group(c, k);
    defer g.end();
    for (all, 0..) |v, i| {
        if (i > 0) sep(c, k);
        const active = if (a.mobile.theme_override_id) |tid| std.mem.eql(u8, tid, v.id) else false;
        ui.keyInt(c, 0x7468_6d00 + @as(u64, i));
        const r = ui.div(c).row().wFull().h(44).px(14).gap(10).itemsCenter().control();
        defer r.end();
        _ = ui.div(c).size(16, 16).roundedFull().circular().bg(v.colors.accent).border(v.colors.border).borderW(1).end();
        ui.text(c, v.name, .{ .size = 15, .weight = if (active) .semibold else .regular, .color = k.text });
        _ = ui.div(c).grow().end();
        ui.text(c, if (v.dark) "Dark" else "Light", .{ .size = 13, .color = k.faint });
        if (active) icons.icon(c, .check, 14, k.accent, 0);
        if (r.clicked()) {
            a.mobile.setThemeOverride(a.gpa, v.id);
            a.dark = v.dark;
            nanoui.haptics.selection();
        }
    }
}

/// A kind's stored choice: on unless turned off.
pub fn kindOn(a: *const App, kind: ms.NotifyKind) bool {
    return (a.settings.number(kind.key()) orelse 1) != 0;
}

fn notifications(a: *App, c: *ui.Context, k: theme.Colors) void {
    const enabled = a.settings.get(.notifications_enabled);
    {
        const g = group(c, k);
        defer g.end();
        if (toggleRow(c, k, "settings-notifications-enabled", "Session notifications", enabled)) a.settings.set(.notifications_enabled, !enabled);
    }
    footer(c, k, ms.notificationsFooter(a.mobile.demo, false));
    if (enabled) {
        header(c, k, "Notify me when");
        const g = group(c, k);
        defer g.end();
        for (std.enums.values(ms.NotifyKind), 0..) |kind, i| {
            if (i > 0) sep(c, k);
            const on = kindOn(a, kind);
            if (toggleRow(c, k, kind.key(), kind.title(), on)) a.settings.setNumber(kind.key(), if (on) 0 else 1);
        }
    }
    header(c, k, "Sounds");
    {
        const g = group(c, k);
        defer g.end();
        const on = a.settings.get(.attach_sound_enabled);
        if (toggleRow(c, k, "settings-attach-sound", "Attaching files", on)) a.settings.set(.attach_sound_enabled, !on);
    }
    footer(c, k, ms.attach_sound_footer);
}

fn autonomy(a: *App, c: *ui.Context, k: theme.Colors) void {
    const s = st(a);
    if (hostOf(a) == null) return noHosts(c, k, "Agents run on your computers. Open Harness on one and sign in.");
    hostPicker(a, c, k, .autonomy);
    header(c, k, "Without asking, agents may");
    {
        const g = group(c, k);
        defer g.end();
        if (!s.autonomy.err.empty()) {
            messageRow(c, k, s.autonomy.err.get());
        } else if (s.autonomy.value) |cur| {
            for (setup.Autonomy.all, 0..) |x, i| {
                if (i > 0) sep(c, k);
                if (choiceRow(c, k, 0x6175_7400 + @as(u64, i), x.label(), x.blurb(), x == cur) and !s.autonomy.saving and x != cur) {
                    const h = hostOf(a).?;
                    s.autonomy.saving = true;
                    s.autonomy.value = x;
                    s.autonomy.call = a.engine.call("SetAutonomy", .{ .autonomy = x.wire(), .targetDeviceId = h.id }, .of(App, a, onAutonomy));
                }
            }
        } else loadingRow(c, k);
    }
    footer(c, k, ms.autonomy_footer);
    if (s.keep_awake.value) |ka| if (ka.supported) {
        {
            const g = group(c, k);
            defer g.end();
            if (toggleRow(c, k, "keep-awake-toggle", "Keep awake while agents work", ka.enabled) and !s.keep_awake.saving) {
                const h = hostOf(a).?;
                s.keep_awake.saving = true;
                s.keep_awake.value = .{ .enabled = !ka.enabled, .supported = true };
                s.keep_awake.call = a.engine.call("SetKeepAwake", .{ .enabled = !ka.enabled, .targetDeviceId = h.id }, .of(App, a, onKeepAwake));
            }
        }
        footer(c, k, ms.keep_awake_footer);
    };
}

fn compaction(a: *App, c: *ui.Context, k: theme.Colors) void {
    const s = st(a);
    if (hostOf(a) == null) return noHosts(c, k, "Graff runs on your computers. Open Harness on one and sign in.");
    hostPicker(a, c, k, .compaction);
    header(c, k, "Compact context at");
    {
        const g = group(c, k);
        defer g.end();
        if (!s.compact.err.empty()) {
            messageRow(c, k, s.compact.err.get());
        } else if (s.compact.value) |cur| {
            for (ms.compact_choices, 0..) |choice, i| {
                if (i > 0) sep(c, k);
                var b: [16]u8 = undefined;
                const label = c.print("{s}", .{ms.compactLabel(&b, choice)});
                const picked = std.meta.eql(choice, cur);
                if (choiceRow(c, k, 0x636d_7000 + @as(u64, i), label, null, picked) and !picked and !s.compact.saving) {
                    const h = hostOf(a).?;
                    s.compact.saving = true;
                    s.compact.value = choice;
                    s.compact.call = a.engine.call("SetGraffCompactAt", .{ .pct = choice, .targetDeviceId = h.id }, .of(App, a, onCompact));
                }
            }
        } else loadingRow(c, k);
    }
    footer(c, k, ms.compact_footer);
}

fn usage(a: *App, c: *ui.Context, k: theme.Colors) void {
    const s = st(a);
    if (hostOf(a) == null) return noHosts(c, k, "Usage comes from the computers that run your agents. Open Harness on one and sign in.");
    hostPicker(a, c, k, .usage);
    header(c, k, "CodeGraff");
    const g = group(c, k);
    defer g.end();
    if (!s.usage.err.empty()) {
        var b: [240]u8 = undefined;
        return messageRow(c, k, std.fmt.bufPrint(&b, "Couldn't load usage: {s}", .{s.usage.err.get()}) catch s.usage.err.get());
    }
    const u = s.usage.value orelse return loadingRow(c, k);
    if (!u.signed_in) return messageRow(c, k, "This computer isn't signed in to CodeGraff.");
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const rows = [_][2][]const u8{
        .{ "Account", u.email.get() },
        .{ "Plan", u.tier.get() },
        .{ "Credits available", ms.formatMicroUsd(&b1, u.credits) },
        .{ "Spent in 30 days", ms.formatMicroUsd(&b2, u.spend30) },
        .{ "Requests in 30 days", c.print("{d}", .{u.requests30}) },
    };
    for (rows, 0..) |r, i| {
        if (i > 0) sep(c, k);
        const row = ui.div(c).row().wFull().h(46).px(14).itemsCenter().justifyBetween();
        defer row.end();
        ui.text(c, r[0], .{ .size = 15, .color = k.text });
        ui.text(c, c.print("{s}", .{r[1]}), .{ .size = 15, .color = k.muted });
    }
}

fn performance(a: *App, c: *ui.Context, k: theme.Colors) void {
    const sum = a.mobile.telemetry.summarize();
    const g = group(c, k);
    defer g.end();
    const box = ui.div(c).column().wFull().p(14).gap(6);
    defer box.end();
    ui.text(c, if (sum.meetsPerfContract()) "Within the 120 Hz budget" else "Warming up", .{ .size = 15, .weight = .semibold, .color = if (sum.meetsPerfContract()) k.success else k.warning });
    ui.text(c, c.print("p50 {d:.2} ms  ·  p95 {d:.2} ms  ·  {d:.0} fps", .{ sum.p50_work_ms, sum.p95_work_ms, sum.est_fps }), .{ .size = 13, .mono = true, .wrap = true, .color = k.muted });
    ui.text(c, c.print("Scroll frames {d}  ·  peak {d:.0} pt/s", .{ sum.scroll_frames, sum.peak_velocity_pt_s }), .{ .size = 13, .mono = true, .wrap = true, .color = k.faint });
}

/// Opens Profile's Usage page (Profile › Usage).
pub fn openUsage(a: *App) void {
    a.mobile.sheet = .settings;
    open(a, .usage);
}

pub fn applyPreview(a: *App, which: []const u8) void {
    const eq = std.mem.eql;
    const pages = .{ .{ "settings", Page.root }, .{ "settings-notifications", Page.notifications }, .{ "settings-autonomy", Page.autonomy }, .{ "settings-compaction", Page.compaction }, .{ "settings-usage", Page.usage } };
    inline for (pages) |p| if (eq(u8, which, p[0])) {
        a.mobile.sheet = .settings;
        st(a).page = p[1];
        // The demo's computers aren't reachable: made-up values.
        switch (p[1]) {
            .autonomy => {
                st(a).autonomy.value = .workspace;
                st(a).keep_awake.value = .{ .enabled = true, .supported = true };
            },
            .compaction => st(a).compact.value = @as(?u8, 75),
            .usage => {
                var u: UsageView = .{ .signed_in = true, .credits = 18_250_000, .spend30 = 6_400_000, .requests30 = 1284 };
                u.email.set("sam@example.com");
                u.tier.set("Pro");
                st(a).usage.value = u;
            },
            else => {},
        }
    };
}

const testing = std.testing;

test "settings pages: titles, and a kind is on until turned off" {
    try testing.expectEqualStrings("Graff compaction", pageTitle(.compaction));
    try testing.expectEqualStrings("Settings", pageTitle(.root));
    try testing.expectEqualStrings("0.", version_line[0..2]);
}

test "settings: Autonomy reads and writes the chosen computer's level" {
    theme.registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.mobile_preview = true;
    a.new_harness = try testing.allocator.dupe(u8, "graff");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"AuthStatus":{"$items":[{"state":"signedIn","user":{"id":"u","email":"sam@example.com","name":null}}]},
        \\ "GetAutonomy":{"autonomy":"full-access","chosen":true},
        \\ "SetAutonomy":{"autonomy":"read-only","chosen":true},
        \\ "GetKeepAwake":{"enabled":false,"supported":true}}
    , .{});
    a.engine.state = .connected;
    {
        const d = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"dev-box","name":"Build Box","platform":"macos"},{"id":"dev-phone","name":"Phone","platform":"ios"}]
        , .{});
        defer d.deinit();
        try a.devices.replace(d.value);
    }
    a.mobile.sheet = .settings;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view_mobile.zig").view), .{ .width = 402, .height = 874 });
    defer t.deinit();
    t.frame();
    try testing.expect(t.hasText("Build Box"));
    try testing.expect(!t.hasText("Phone"));
    try t.clickText("Autonomy");
    t.frame();
    t.frame();
    try testing.expect(t.hasText("Without asking, agents may"));
    try testing.expect(t.hasText("Keep awake while agents work"));
    try t.clickText("Read only");
    t.frame();
    t.frame();
    try testing.expectEqual(setup.Autonomy.read_only, st(&a).autonomy.value.?);
    var sent = false;
    for (a.engine.sent.items) |f| if (std.mem.indexOf(u8, f, "\"SetAutonomy\"") != null and std.mem.indexOf(u8, f, "\"read-only\"") != null and std.mem.indexOf(u8, f, "dev-box") != null) {
        sent = true;
    };
    try testing.expect(sent);
}
