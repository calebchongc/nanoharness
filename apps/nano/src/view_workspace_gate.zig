//! The workspace gate over the whole window, and the switcher as a dialog
//! (app_workspace_gate.zig): the memberships to open, a name and "Create
//! workspace", and "Use a different account". Loading, failure (with the
//! engine's words and Retry), an empty list and a filled one each show.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const gk = @import("view_gaps_kit.zig");
const App = @import("app.zig").App;
const gate = @import("app_workspace_gate.zig");

const card_w: f32 = 440;

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (gate.current(a) != .hidden) {
        // The composer underneath doesn't keep the keys.
        if (a.view.composer_id != 0 and c.focus == a.view.composer_id) c.focus = 0;
        a.view.focus_composer = false;
    }
    switch (gate.current(a)) {
        .hidden => {},
        .gate => {
            ui.key(c, "workspace-gate");
            const root = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(9).bg(gk.solid(k).shell).center();
            defer root.end();
            _ = root.interaction();
            body(c, a, k, false);
        },
        .switcher => {
            ui.key(c, "workspace-switcher");
            const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(7).bg(k.shell.alpha(0.6)).center();
            defer scrim.end();
            const it = scrim.interaction();
            body(c, a, k, true);
            if (it.clicked and c.hot == it.id) gate.closeSwitcher(a);
        },
    }
}

fn body(c: *ui.Context, a: *App, k: theme.Colors, switcher: bool) void {
    const s = &a.ui_gaps.gate;
    const card = kit.shadowLg(ui.div(c).w(card_w).column().p(24).gap(14).rounded(16).bg(gk.solid(k).composer).border(k.border).borderW(1));
    defer card.end();
    _ = card.interaction();
    {
        const head = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer head.end();
        {
            const t = ui.div(c).column().grow().w(0).gap(4);
            defer t.end();
            ui.text(c, if (switcher) "Switch workspace" else "Create your workspace", .{ .size = 20, .line_height = 28, .weight = .semibold, .color = k.text });
            if (a.account.user) |u| ui.text(c, c.print("Signed in as {s}", .{u.email}), .{ .size = 12.5, .line_height = 18, .color = k.muted });
        }
        if (switcher) {
            ui.key(c, "workspace-switcher-close");
            if (gk.button(c, k, "", .{ .look = .quiet, .square = true, .icon = .close })) gate.closeSwitcher(a);
        }
    }
    // The memberships.
    switch (s.status) {
        .idle, .loading => {
            const r = ui.div(c).row().gap(8).itemsCenter().py(6);
            defer r.end();
            kit.snake(c, k);
            ui.text(c, "Loading your workspaces…", .{ .size = 13, .line_height = 19, .color = k.muted });
        },
        .failed => {
            const r = ui.div(c).column().wFull().gap(8).p(12).rounded(10).bg(k.danger.alpha(0.06)).border(k.danger.alpha(0.2)).borderW(1);
            defer r.end();
            ui.text(c, if (s.err_kind == .list) s.errText() else "Couldn't load your workspaces.", .{ .size = 12.5, .line_height = 18, .wrap = true, .color = k.danger_muted });
            ui.key(c, "workspace-gate-retry");
            if (gk.button(c, k, "Retry", .{ .icon = .refresh })) gate.load(a);
        },
        .ready => if (s.orgs.items.len > 0) {
            ui.text(c, "Your workspaces", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.muted });
            const list = ui.div(c).column().wFull().gap(2);
            defer list.end();
            for (s.orgs.items, 0..) |org, i| {
                ui.key(c, c.print("workspace-org-{s}", .{org.organization_id}));
                const here = std.mem.eql(u8, s.org_id.items, org.organization_id);
                const row = gk.row(c, k, here);
                defer row.div.end();
                {
                    const badge = ui.div(c).row().size(24, 24).center().rounded(6).bg(k.ink(0.08));
                    defer badge.end();
                    ui.text(c, c.print("{c}", .{std.ascii.toUpper(if (org.name.len > 0) org.name[0] else '?')}), .{ .size = 12, .line_height = 16, .weight = .semibold, .color = k.text });
                }
                kit.ellipsisText(c, org.name, .{ .size = 13.5, .line_height = 20, .color = k.text }, card_w - 48 - 120);
                ui.spacer(c);
                if (s.busy == .selecting and s.busy_org == i) {
                    ui.text(c, "Opening…", .{ .size = 12, .line_height = 18, .color = k.muted });
                } else if (here) {
                    icons.icon(c, .check, 14, k.success, 0);
                } else icons.icon(c, .@"alt-arrow-right", 12, k.faint, 0);
                if (row.pressed and !here) gate.select(a, i);
            }
        } else {
            ui.text(c, "You aren't in a workspace yet. Name one to start.", .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
        },
    }
    // A new one.
    {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        ui.text(c, "New workspace", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.muted });
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        {
            const field = ui.div(c).row().grow().w(0).h(34).px(10).itemsCenter().rounded(8).bg(k.card).border(k.border).borderW(1);
            defer field.end();
            const id = c.peekId(null);
            if (s.focus_name) {
                c.focus = id;
                s.focus_name = false;
            }
            const res = ui.textField(c, &s.name, .{ .placeholder = "Workspace name", .width = .fill, .bare = true, .size = 13, .caret_color = k.accent, .placeholder_color = k.muted });
            if (res.submitted) gate.create(a);
        }
        ui.key(c, "workspace-gate-create");
        if (gk.button(c, k, if (s.busy == .creating) "Creating…" else "Create workspace", .{ .look = .primary, .h = 34, .disabled = s.busy != .none })) gate.create(a);
    }
    if (s.err_kind == .action) {
        ui.text(c, s.errText(), .{ .size = 12.5, .line_height = 18, .wrap = true, .color = k.danger_muted });
    }
    if (!switcher) {
        ui.key(c, "workspace-gate-sign-out");
        if (gk.button(c, k, "Use a different account", .{ .look = .quiet, .icon = .@"logout-2" })) gate.signOut(a);
    }
}

/// The gate has every key (Tab moves between its controls); the switcher
/// closes with Escape.
pub fn keys(c: *ui.Context, a: *App) bool {
    switch (gate.current(a)) {
        .hidden => return false,
        .gate => {
            // Return in the name field creates it.
            if (c.focused_text != null and c.shortcut(.{ .key = ui.Shortcut.enter })) gate.create(a);
            return true;
        },
        .switcher => {
            if (c.shortcut(.{ .key = ui.Shortcut.escape })) gate.closeSwitcher(a);
            if (c.focused_text != null and c.shortcut(.{ .key = ui.Shortcut.enter })) gate.create(a);
            return true;
        },
    }
}
