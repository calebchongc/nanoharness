//! Test root for the git, checkout and terminal RPC ports (`rpcg_*.zig`):
//! `tests.zig` imports this one file.
test {
    _ = @import("rpcg_git.zig");
    _ = @import("rpcg_diff.zig");
    _ = @import("rpcg_watch.zig");
    _ = @import("rpcg_rpc.zig");
    _ = @import("rpcg_rpc_tests.zig");
    _ = @import("rpcg_terminals.zig");
    _ = @import("rpcg_terminals_tests.zig");
}
