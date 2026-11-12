//! Tests of the preview, visual and simulator-streaming ports.
test {
    _ = @import("engine_streams.zig");
    _ = @import("preview_catalog.zig");
    _ = @import("preview_discovery.zig");
    _ = @import("preview_proxy.zig");
    _ = @import("previews_host.zig");
    _ = @import("show_media_host.zig");
    _ = @import("visual_sandbox.zig");
    _ = @import("show_visual_host.zig");
}
