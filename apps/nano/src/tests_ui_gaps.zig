//! The desktop's added screens: their rules and state.
test {
    _ = @import("image_preview_rules.zig");
    _ = @import("annotate.zig");
    _ = @import("app_image_preview.zig");
    _ = @import("app_annotate.zig");
    _ = @import("view_image_preview.zig");
    _ = @import("view_annotate.zig");
    _ = @import("app_workspace_gate.zig");
    _ = @import("view_workspace_gate.zig");
    _ = @import("app_keep_awake.zig");
    _ = @import("view_settings_keep_awake.zig");
    _ = @import("slash_menu.zig");
    _ = @import("app_slash.zig");
    _ = @import("view_slash_menu.zig");
}
