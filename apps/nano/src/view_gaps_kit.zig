//! Controls the new screens share: buttons the keyboard reaches (Tab moves
//! to them, Return or Space presses them, a ring shows which has the
//! keys), drawn only with the theme's tokens.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");

/// The theme's own colours without the window's glass: a surface that
/// covers the window must not show what's under it.
pub fn solid(k: theme.Colors) theme.Colors {
    var o = theme.colors(k.dark);
    o.accent = k.accent;
    return o;
}

pub const Look = enum { plain, primary, quiet, danger };

pub const Button = struct {
    look: Look = .plain,
    /// Shown as picked (a tool, a colour).
    on: bool = false,
    disabled: bool = false,
    icon: ?icons.Name = null,
    /// A label-less, square button.
    square: bool = false,
    h: f32 = 28,
    size: f32 = 12.5,
};

/// A button; true when pressed by the pointer or the keyboard.
pub fn button(c: *ui.Context, k: theme.Colors, label: []const u8, o: Button) bool {
    var b = ui.div(c).row().h(o.h).gap(6).itemsCenter().justifyCenter().rounded(8).control().borderW(1);
    b = if (o.square) b.w(o.h) else b.px(if (o.look == .quiet) 8 else 12);
    b = switch (o.look) {
        .primary => b.bg(k.solid).border(k.solid),
        .danger => b.bg(k.danger.alpha(0.1)).border(k.danger.alpha(0.3)),
        .quiet => b.border(.transparent),
        .plain => b.bg(k.card).border(k.border),
    };
    if (o.on) b = b.bg(k.selected).border(k.border_strong);
    if (o.disabled) b = b.opacity(0.4) else if (o.look != .primary and !o.on) b = b.hover(k.hover);
    const it = c.interact(b.index, .{ .focusable = !o.disabled });
    if (it.focused) b = b.border(k.accent).borderW(1.5);
    defer b.end();
    const fg = switch (o.look) {
        .primary => k.on_solid,
        .danger => k.danger_muted,
        else => if (o.on) k.text else k.text.alpha(0.88),
    };
    if (o.icon) |name| icons.icon(c, name, 14, fg, 0);
    if (label.len > 0 and (!o.square or o.icon == null)) ui.text(c, label, .{ .size = o.size, .line_height = o.size * 1.5, .weight = if (o.look == .primary) .medium else .regular, .color = fg });
    return it.clicked and !o.disabled;
}

/// A whole row the keyboard reaches; the caller fills and ends it. Read
/// `pressed` after building the row's content.
pub const Row = struct {
    div: ui.Div,
    pressed: bool,
    focused: bool,
};

pub fn row(c: *ui.Context, k: theme.Colors, selected: bool) Row {
    var d = ui.div(c).row().wFull().px(10).py(7).gap(10).itemsCenter().rounded(8).control().borderW(1).border(.transparent);
    if (selected) d = d.bg(k.selected) else d = d.hover(k.hover);
    const it = c.interact(d.index, .{ .focusable = true });
    if (it.focused) d = d.border(k.accent).borderW(1.5);
    return .{ .div = d, .pressed = it.clicked, .focused = it.focused };
}
