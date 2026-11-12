//! The tests of the settings, actions and workspace-file RPC ports, pulled
//! into `zig build test` by one line in `tests.zig`.
test {
    _ = @import("rpcw_uploads.zig");
}
