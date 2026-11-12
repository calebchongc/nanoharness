//! The Zig iOS app's own screens and rules (view_mobile_*.zig and the
//! rules they call), gathered so tests.zig names them once.
test {
    _ = @import("mobile_auth.zig");
    _ = @import("mobile_auth_engine_tests.zig");
    _ = @import("ios_web_auth.zig");
    _ = @import("app_mobile_auth.zig");
    _ = @import("view_mobile_signin.zig");
    _ = @import("view_mobile_profile.zig");
    _ = @import("mobile_question.zig");
    _ = @import("view_mobile_question.zig");
    _ = @import("view_mobile_reauth.zig");
    _ = @import("mobile_attach.zig");
    _ = @import("ios_photos.zig");
    _ = @import("view_mobile_attach.zig");
    _ = @import("mobile_settings.zig");
    _ = @import("view_mobile_settings.zig");
    _ = @import("view_mobile_onboarding.zig");
    _ = @import("mobile_ux_contract_tests.zig");
}
