//! Profile (ProfileView.swift): who is signed in, Sign out one tap away,
//! and Delete account… apart at the bottom behind its own confirmation.
//! The confirmation, the refusal and "Deleting account…" are drawn here as
//! the Swift alerts read.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const ma = @import("mobile_auth.zig");
const auth = @import("app_mobile_auth.zig");

/// The Profile's rows, as ProfileView decides them.
pub const Rows = struct {
    /// "Signed in" › "Demo mode", or "Signed in with" › "CodeGraff".
    signed_in_label: []const u8,
    signed_in_value: []const u8,
    can_delete: bool,
};

/// `canDeleteAccount`: only a real CodeGraff sign-in has an account to delete.
pub fn rows(demo: bool, signed_in: bool) Rows {
    if (demo) return .{ .signed_in_label = "Signed in", .signed_in_value = "Demo mode", .can_delete = false };
    return .{ .signed_in_label = "Signed in with", .signed_in_value = "CodeGraff", .can_delete = signed_in };
}

fn sectionHeader(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const h = ui.div(c).row().wFull().px(4).pt(4);
    defer h.end();
    ui.text(c, label, .{ .size = 12.5, .weight = .semibold, .color = k.muted });
}

fn group(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().rounded(14).bg(k.raised.alpha(0.6)).clip();
}

fn row(c: *ui.Context, key: []const u8) ui.Div {
    ui.key(c, key);
    return ui.div(c).row().wFull().h(46).px(14).itemsCenter().justifyBetween().control();
}

/// The sheet's body.
pub fn render(a: *App, c: *ui.Context, k: theme.Colors) void {
    const s = &a.mobile.auth;
    const r = rows(a.mobile.demo, s.engine_state == .signed_in or s.engine_state == .unknown);
    sectionHeader(c, k, "Account");
    {
        const g = group(c, k);
        defer g.end();
        {
            const info = ui.div(c).row().wFull().h(46).px(14).itemsCenter().justifyBetween();
            defer info.end();
            ui.text(c, r.signed_in_label, .{ .size = 15, .color = k.text });
            ui.text(c, r.signed_in_value, .{ .size = 15, .color = k.muted });
        }
        if (a.account.user) |u| {
            _ = ui.div(c).wFull().h(1).bg(k.border.alpha(0.5)).end();
            const info = ui.div(c).row().wFull().h(46).px(14).itemsCenter().justifyBetween();
            defer info.end();
            ui.text(c, u.name orelse "Email", .{ .size = 15, .color = k.text });
            ui.text(c, u.email, .{ .size = 15, .color = k.muted });
        }
        _ = ui.div(c).wFull().h(1).bg(k.border.alpha(0.5)).end();
        {
            const usage = row(c, "profile-usage");
            defer usage.end();
            ui.text(c, "Usage", .{ .size = 15, .color = k.text });
            @import("icons.zig").icon(c, .@"alt-arrow-right", 12, k.faint, 0);
            if (usage.clicked()) @import("view_mobile_settings.zig").openUsage(a);
        }
        _ = ui.div(c).wFull().h(1).bg(k.border.alpha(0.5)).end();
        const out = row(c, "profile-sign-out");
        defer out.end();
        ui.text(c, "Sign out", .{ .size = 15, .color = k.danger });
        if (out.clicked()) {
            auth.signOut(a);
            nanoui.haptics.impact(.medium);
        }
    }
    if (r.can_delete) {
        {
            const g = group(c, k);
            defer g.end();
            const del = row(c, "profile-delete-account");
            defer del.end();
            ui.text(c, "Delete account…", .{ .size = 15, .color = if (s.deleting) k.danger.alpha(0.4) else k.danger });
            if (del.clicked() and !s.deleting) s.confirm_delete = true;
        }
        const f = ui.div(c).row().wFull().px(4);
        defer f.end();
        ui.text(c, ma.delete_footer, .{ .size = 12, .wrap = true, .color = k.muted });
    }
}

/// The confirmation, the refusal and the busy card, over everything.
pub fn overlays(a: *App, c: *ui.Context, k: theme.Colors) void {
    const s = &a.mobile.auth;
    if (!s.confirm_delete and s.delete_err.empty() and !s.deleting) return;
    ui.key(c, "profile-alert-backdrop");
    const backdrop = ui.div(c).column().sizeFull().center().px(36).bg(ui.Color.black.alpha(0.42)).fixed().offset(0, 0).layer(3);
    defer backdrop.end();
    ui.key(c, "profile-alert-card");
    const card = ui.div(c).column().wFull().maxW(300).p(18).gap(14).rounded(20).bg(k.card).border(k.border).borderW(1).itemsCenter().control();
    defer card.end();
    if (s.confirm_delete) {
        alertText(c, k, ma.delete_title, ma.delete_body);
        const buttons = ui.div(c).row().wFull().gap(8);
        defer buttons.end();
        if (alertButton(c, k, "profile-delete-cancel", "Cancel", k.text)) s.confirm_delete = false;
        if (alertButton(c, k, "profile-delete-confirm", "Delete", k.danger)) auth.deleteAccount(a);
    } else if (!s.delete_err.empty()) {
        alertText(c, k, ma.delete_failed_title, s.delete_err.get());
        const buttons = ui.div(c).row().wFull();
        defer buttons.end();
        if (alertButton(c, k, "profile-delete-ok", "OK", k.text)) s.delete_err.clear();
    } else {
        const r = ui.div(c).row().itemsCenter().gap(10);
        defer r.end();
        kit.spinner(c, .{ .size = 18, .color = k.muted });
        ui.text(c, ma.deleting_copy, .{ .size = 15, .color = k.text });
    }
}

fn alertText(c: *ui.Context, k: theme.Colors, title: []const u8, body: []const u8) void {
    ui.text(c, title, .{ .size = 16, .weight = .semibold, .color = k.text });
    ui.text(c, body, .{ .size = 13, .line_height = 18, .wrap = true, .color = k.muted });
}

fn alertButton(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8, color: ui.Color) bool {
    ui.key(c, key);
    const b = ui.div(c).row().grow().h(40).center().rounded(12).bg(k.raised).control();
    defer b.end();
    ui.text(c, label, .{ .size = 15, .weight = .semibold, .color = color });
    return b.clicked();
}

pub fn applyPreview(a: *App, which: []const u8) void {
    const s = &a.mobile.auth;
    const eq = std.mem.eql;
    if (!std.mem.startsWith(u8, which, "profile")) return;
    a.mobile.sheet = .profile;
    // A made-up CodeGraff account, not the demo's, so the delete row shows.
    a.mobile.demo = false;
    s.preview = true;
    s.engine_state = .signed_in;
    if (eq(u8, which, "profile-delete")) s.confirm_delete = true;
    if (eq(u8, which, "profile-deleting")) s.deleting = true;
    if (eq(u8, which, "profile-delete-error")) s.delete_err.set("Your account can't be deleted yet.");
}

const testing = std.testing;

test "profile rows: demo shows Demo mode and no delete; a CodeGraff sign-in can delete" {
    const d = rows(true, true);
    try testing.expectEqualStrings("Demo mode", d.signed_in_value);
    try testing.expect(!d.can_delete);
    const r = rows(false, true);
    try testing.expectEqualStrings("Signed in with", r.signed_in_label);
    try testing.expectEqualStrings("CodeGraff", r.signed_in_value);
    try testing.expect(r.can_delete);
    try testing.expect(!rows(false, false).can_delete);
}
