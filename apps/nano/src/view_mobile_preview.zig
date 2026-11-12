//! A screen pinned for an offscreen capture: `HARNESS_MOBILE_SCREEN=<name>`
//! with `HARNESS_MOBILE_DEMO=1` (the in-process demo engine and its made-up
//! data). Without the demo it does nothing, so a real account never shows a
//! pinned screen.
const std = @import("std");
const App = @import("app.zig").App;

pub fn apply(a: *App, which: []const u8) void {
    const env = a.env orelse return;
    const demo = env.get("HARNESS_MOBILE_DEMO") orelse return;
    if (!std.mem.eql(u8, demo, "1")) return;
    @import("view_mobile_signin.zig").applyPreview(a, which);
    @import("view_mobile_profile.zig").applyPreview(a, which);
}
