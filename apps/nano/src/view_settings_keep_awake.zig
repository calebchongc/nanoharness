//! Settings › Agents' "Keep awake while agents work" card (app_keep_awake.zig).
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const set = @import("view_settings.zig");
const page = @import("view_settings_agents.zig");
const gk = @import("view_gaps_kit.zig");
const App = @import("app.zig").App;
const ka = @import("app_keep_awake.zig");

pub fn card(c: *ui.Context, a: *App, k: theme.Colors) void {
    // With no engine the page is its waiting page alone.
    if (!a.engine.up()) return;
    ka.ensure(a, a.view.agents.target);
    const s = &a.ui_gaps.keep_awake;
    const shown = ka.shown(s.status, s.supported);
    if (shown == .hidden) return;
    const w = page.cardInner();
    const cd = page.card(c, k, 20);
    defer cd.end();
    const in = ui.div(c).column().wFull().p(16).gap(2);
    defer in.end();
    {
        const r = ui.div(c).row().w(w).itemsCenter().gap(12);
        defer r.end();
        {
            const t = ui.div(c).column().grow().w(0);
            defer t.end();
            page.title(c, k, "Keep awake while agents work", w - 60);
        }
        if (shown == .toggle) {
            ui.key(c, "keep-awake-toggle");
            const sw = ui.div(c).row().control();
            const it = c.interact(sw.index, .{ .focusable = !s.saving });
            if (it.focused) _ = sw.border(k.accent).borderW(1.5).rounded(10);
            defer sw.end();
            const by_pointer = page.toggle(c, k, s.enabled, !s.saving);
            if ((by_pointer or it.clicked) and !s.saving) ka.set(a, !s.enabled);
        }
    }
    page.subtitleIn(c, k, "The computer won't go to sleep while any chat is working, and can sleep again once they're all done. The display can still turn off, and closing a laptop's lid still puts it to sleep.", w);
    switch (shown) {
        .loading => {
            set.space(c, 6);
            ui.text(c, "Checking this computer…", set.st(c, 12, .{ .color = k.muted }));
        },
        .failed => {
            set.space(c, 6);
            const col = ui.div(c).column().w(w).gap(8);
            defer col.end();
            ui.text(c, s.errText(), set.st(c, 12, .{ .wrap = true, .color = k.danger_muted }));
            ui.key(c, "keep-awake-retry");
            if (gk.button(c, k, "Retry", .{ .icon = .refresh })) ka.load(a);
        },
        .toggle => if (s.err_len > 0) {
            set.space(c, 6);
            const col = ui.div(c).column().w(w);
            defer col.end();
            ui.text(c, s.errText(), set.st(c, 12, .{ .wrap = true, .color = k.danger_muted }));
        },
        .hidden => {},
    }
}
