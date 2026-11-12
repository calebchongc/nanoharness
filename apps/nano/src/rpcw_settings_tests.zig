//! The tests of the settings, actions and workspace-file RPC ports, pulled
//! into `zig build test` by one line in `tests.zig`.
test {
    _ = @import("rpcw_uploads.zig");
    _ = @import("rpcw_workspace_files.zig");
    _ = @import("rpcw_keep_awake.zig");
    _ = @import("rpcw_settings.zig");
    _ = @import("rpcw_actions.zig");
    _ = @import("rpcw_usage.zig");
    _ = @import("rpcw_search.zig");
}
