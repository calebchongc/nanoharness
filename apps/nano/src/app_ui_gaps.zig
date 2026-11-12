//! The state of the screens added for the desktop's missing features, kept
//! in one App field so registering them touches app.zig once: the image
//! preview and annotate, the workspace gate, keep-awake and the composer's
//! `/` menu.
const App = @import("app.zig").App;

pub const State = struct {
    preview: @import("app_image_preview.zig").State = .{},
    notes: @import("app_annotate.zig").Notes = .{},
    gate: @import("app_workspace_gate.zig").State = .{},
    keep_awake: @import("app_keep_awake.zig").State = .{},

    pub fn deinit(s: *State, a: *App) void {
        s.preview.deinit(a);
        s.notes.deinit(a.gpa);
        s.gate.deinit(a.gpa);
        s.keep_awake.deinit(a.gpa);
    }
};
