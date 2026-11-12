//! The account gate: the sign-in screen (SignInView.swift: the harness mark,
//! one button, the privacy and help links), its busy and error states, and
//! "Choose an organization" (OrgPickerView). Signed in, the gate draws
//! nothing and the app shows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const mg = @import("mobile_glass.zig");
const ma = @import("mobile_auth.zig");
const auth = @import("app_mobile_auth.zig");

/// Draws the gate's screen when one is due; true when it did.
pub fn gate(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) bool {
    auth.poll(a);
    switch (a.mobile.auth.screen()) {
        .signed_in => return false,
        .signed_out, .signing_in => signInScreen(a, c, k),
        .picking_org => orgPicker(a, c, k, rt),
    }
    return true;
}

fn signInScreen(a: *App, c: *ui.Context, k: theme.Colors) void {
    const s = &a.mobile.auth;
    const busy = s.busy;
    const root = ui.div(c).column().sizeFull().bg(k.background).itemsCenter().justifyCenter().px(32);
    defer root.end();
    const col = ui.div(c).column().wFull().maxW(480).itemsCenter().gap(32);
    defer col.end();
    {
        const head = ui.div(c).column().itemsCenter().gap(24);
        defer head.end();
        icons.icon(c, .@"graff-mark", 72, k.text, 0);
        const words = ui.div(c).column().itemsCenter().gap(6);
        defer words.end();
        ui.text(c, "Harness", .{ .size = 28, .weight = .semibold, .color = k.text });
        ui.text(c, "Your coding agents, from anywhere", .{ .size = 15, .color = k.muted });
    }
    const actions = ui.div(c).column().wFull().itemsCenter().gap(12);
    defer actions.end();
    {
        ui.key(c, "ios-signin-btn");
        const btn = ui.div(c).row().wFull().h(50).center().gap(10).rounded(16).bg(if (busy) k.text.alpha(0.6) else k.text).control();
        defer btn.end();
        if (busy) {
            kit.spinner(c, .{ .size = 18, .color = k.background });
        } else {
            ui.text(c, "Log in to Harness", .{ .size = 15, .weight = .semibold, .color = k.background });
        }
        if (btn.clicked() and !busy) {
            auth.start(a);
            nanoui.haptics.impact(.light);
        }
    }
    if (busy and !s.exchanging) {
        ui.key(c, "ios-signin-cancel");
        const cancel = ui.div(c).row().px(12).py(6).control();
        defer cancel.end();
        ui.text(c, "Cancel", .{ .size = 13, .color = k.muted });
        if (cancel.clicked()) auth.cancel(a);
    }
    if (!s.err.empty()) {
        ui.text(c, s.err.get(), .{ .size = 13, .wrap = true, .color = k.danger });
    }
    const links = ui.div(c).row().gap(20);
    defer links.end();
    link(c, "ios-signin-privacy", "Privacy policy", ma.privacy_url, k);
    link(c, "ios-signin-help", "Help", ma.support_url, k);
}

fn link(c: *ui.Context, key: []const u8, label: []const u8, url: []const u8, k: theme.Colors) void {
    ui.key(c, key);
    const l = ui.div(c).row().py(4).control();
    defer l.end();
    ui.text(c, label, .{ .size = 13, .color = k.muted });
    if (l.clicked()) _ = nanoui.shell.openUrl(url);
}

fn orgPicker(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    const s = &a.mobile.auth;
    const root = ui.div(c).column().sizeFull().bg(k.background).itemsCenter().justifyCenter().p(24);
    defer root.end();
    const col = ui.div(c).column().wFull().maxW(480).itemsCenter().gap(20);
    defer col.end();
    ui.text(c, "Choose an organization", .{ .size = 16, .weight = .semibold, .color = k.text });
    {
        const rows = ui.div(c).column().wFull().gap(8);
        defer rows.end();
        for (s.orgList(), 0..) |*o, i| {
            var kb: [32]u8 = undefined;
            ui.key(c, std.fmt.bufPrint(&kb, "ios-org-{d}", .{i}) catch "ios-org");
            const row = mg.styleGlassDiv(c, ui.div(c).row().wFull().h(48).px(16).itemsCenter().justifyBetween().control(), .org_picker_row, rt, ui.Color.transparent, null);
            defer row.end();
            ui.text(c, o.name.get(), .{ .size = 14, .weight = .medium, .color = k.text });
            if (s.org_busy) kit.spinner(c, .{ .size = 12, .color = k.faint }) else icons.icon(c, .@"alt-arrow-right", 12, k.faint, 0);
            if (row.clicked() and !s.org_busy) auth.selectOrg(a, i);
        }
    }
    if (!s.org_err.empty()) ui.text(c, s.org_err.get(), .{ .size = 12, .wrap = true, .color = k.danger });
    ui.key(c, "ios-org-back");
    const back = ui.div(c).row().px(12).py(6).control();
    defer back.end();
    ui.text(c, "Back", .{ .size = 13, .color = k.muted });
    if (back.clicked()) auth.signOut(a);
}

/// Pins a screen for an offscreen capture with made-up data
/// (`HARNESS_MOBILE_SCREEN`, with `--demo` only).
pub fn applyPreview(a: *App, which: []const u8) void {
    const s = &a.mobile.auth;
    const eq = std.mem.eql;
    if (eq(u8, which, "signin")) {
        s.preview = true;
        s.engine_state = .signed_out;
    } else if (eq(u8, which, "signin-busy")) {
        s.preview = true;
        s.engine_state = .signed_out;
        s.busy = true;
    } else if (eq(u8, which, "signin-error")) {
        s.preview = true;
        s.engine_state = .signed_out;
        s.err.set(ma.CallbackError.expired.message());
    } else if (eq(u8, which, "orgs")) {
        s.preview = true;
        s.engine_state = .needs_organization;
        s.busy = true;
        s.picking = true;
        const names = [_][]const u8{ "Sample Studio", "Personal" };
        for (names, 0..) |n, i| {
            s.orgs[i].name.set(n);
            s.orgs[i].organization_id.set(n);
        }
        s.org_count = names.len;
    }
}

const testing = std.testing;

test "the gate shows sign-in, busy, error and the picker, and nothing once signed in" {
    var s: auth.State = .{};
    s.engine_state = .signed_out;
    try testing.expectEqual(ma.Screen.signed_out, s.screen());
    s.busy = true;
    try testing.expectEqual(ma.Screen.signing_in, s.screen());
    s.picking = true;
    try testing.expectEqual(ma.Screen.signing_in, s.screen());
    s.org_count = 2;
    try testing.expectEqual(ma.Screen.picking_org, s.screen());
    s = .{};
    s.engine_state = .signed_in;
    try testing.expectEqual(ma.Screen.signed_in, s.screen());
}
