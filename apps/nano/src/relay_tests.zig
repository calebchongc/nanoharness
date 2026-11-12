//! Test roots for the device relay (one import line in `tests.zig`).
test {
    _ = @import("device_frame.zig");
    _ = @import("wss.zig");
    _ = @import("device_relay.zig");
    _ = @import("relay_command.zig");
    _ = @import("relay_engine.zig");
}
