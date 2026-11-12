//! The composer's `/` menu over the pill (app_slash.zig): each entry's
//! name and description, what it is (a Harness action, the agent's command
//! or a skill), the selection ↑/↓ moves, Return or Tab picks, Escape
//! dismisses. While the catalogs load or fail, the workspace's own actions
//! still show, with a line saying so.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const App = @import("app.zig").App;
const menu = @import("slash_menu.zig");
const slash = @import("app_slash.zig");

/// The trigger at the composer's caret, while the composer has the keys
/// and nothing else is using it.
pub fn active(c: *ui.Context, a: *App) ?menu.Trigger {
    if (a.view.composer_id == 0 or c.focus != a.view.composer_id) return null;
    if (a.wizard != null or a.picker != .none or a.view.write_open or a.view.settings_open) return null;
    const t = menu.trigger(a.composer.text(), a.view.composer_caret) orelse {
        a.ui_gaps.slash.dismissed = null;
        return null;
    };
    if (a.ui_gaps.slash.dismissed) |at| if (at == t.start) return null;
    return t;
}

pub fn keys(c: *ui.Context, a: *App) bool {
    const t = active(c, a) orelse return false;
    const s = &a.ui_gaps.slash;
    const S = ui.Shortcut;
    if (c.shortcut(.{ .key = S.escape })) {
        s.dismissed = t.start;
        a.redraw();
        return true;
    }
    if (c.shortcut(.{ .key = S.down })) {
        s.selected = menu.move(s.selected, s.match_count, 1);
        a.redraw();
        return true;
    }
    if (c.shortcut(.{ .key = S.up })) {
        s.selected = menu.move(s.selected, s.match_count, -1);
        a.redraw();
        return true;
    }
    if (s.match_count > 0 and (c.shortcut(.{ .key = S.enter }) or c.shortcut(.{ .key = S.tab }))) {
        slash.pick(a, c.alloc(), t, s.selected);
        return true;
    }
    return false;
}

const row_h: f32 = 34;
const max_rows: usize = 8;

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const t = active(c, a) orelse return;
    const anchor = a.view.composer_anchor orelse return;
    slash.ensure(a);
    slash.refresh(a, t.query);
    const s = &a.ui_gaps.slash;
    const loading = s.cmd.status == .loading or s.skill.status == .loading;
    const failed = s.cmd.status == .failed or s.skill.status == .failed;
    const shown = @min(s.match_count, max_rows);
    const status_h: f32 = if (loading or failed) 28 else 0;
    const empty_h: f32 = if (s.match_count == 0) 40 else 0;
    const h = @as(f32, @floatFromInt(shown)) * row_h + status_h + empty_h + 10;
    const w = anchor.w;
    ui.key(c, "slash-menu");
    const card = kit.shadowLg(ui.div(c).fixed().offset(anchor.x, @max(8, anchor.y - h - 6)).w(w).layer(5).column().p(5)
        .bg(k.composer).border(k.border).borderW(1).rounded(12));
    defer card.end();
    _ = card.interaction();
    // Keep the selection in the window of rows shown.
    const first = if (s.selected >= max_rows) s.selected + 1 - max_rows else 0;
    for (first..first + shown) |i| {
        if (i >= s.match_count) break;
        const it = s.items.items[s.matches[i]];
        ui.key(c, c.print("slash-{d}-{s}", .{ @intFromEnum(it.source), it.name }));
        var r = ui.div(c).row().wFull().h(row_h).px(10).gap(10).itemsCenter().rounded(8).control();
        r = if (i == s.selected) r.bg(k.selected) else r.hover(k.hover);
        defer r.end();
        const name = c.print("/{s}", .{it.name});
        const name_w = @min(c.text.width(name, .{ .size = 13, .mono = true }) + 2, w * 0.45);
        kit.ellipsisText(c, name, .{ .size = 13, .line_height = 18, .mono = true, .color = k.text }, name_w);
        kit.ellipsisText(c, it.description, .{ .size = 12.5, .line_height = 18, .color = k.muted }, @max(40, w - name_w - 10 - 20 - 90));
        ui.spacer(c);
        ui.text(c, switch (it.source) {
            .workspace => "Harness",
            .command => "Command",
            .skill => "Skill",
        }, .{ .size = 11, .line_height = 16, .color = k.faint });
        if (r.clicked()) slash.pick(a, c.alloc(), t, i);
    }
    if (s.match_count == 0) {
        const e = ui.div(c).row().wFull().h(40).px(10).itemsCenter();
        defer e.end();
        ui.text(c, if (t.query.len > 0) "No matching commands" else "No commands", .{ .size = 13, .line_height = 18, .color = k.muted });
    }
    if (loading or failed) {
        const st = ui.div(c).row().wFull().h(28).px(10).gap(8).itemsCenter();
        defer st.end();
        if (loading) {
            kit.snake(c, k);
            ui.text(c, "Loading the agent's commands and skills…", .{ .size = 11.5, .line_height = 16, .color = k.faint });
        } else {
            const why = if (s.cmd.status == .failed) s.cmd.errText() else s.skill.errText();
            kit.ellipsisText(c, c.print("Couldn't load the agent's commands: {s}", .{why}), .{ .size = 11.5, .line_height = 16, .color = k.danger_muted }, w - 30);
        }
    }
}
