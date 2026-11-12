//! The agent set-up surface's tests (model catalogs, skills, installers,
//! agent logins, the browse link), gathered so `tests.zig` lists them once.
test {
    _ = @import("harness_version.zig");
    _ = @import("catalog_core.zig");
    _ = @import("catalog_claude.zig");
    _ = @import("catalog_codex.zig");
    _ = @import("catalog_cursor.zig");
    _ = @import("catalog_pi.zig");
    _ = @import("catalog_opencode.zig");
    _ = @import("catalog_acp.zig");
    _ = @import("catalog_graff.zig");
    _ = @import("catalog_devin.zig");
    _ = @import("rpc_models.zig");
    _ = @import("agent_logins.zig");
    _ = @import("rpc_logins.zig");
    _ = @import("harness_install.zig");
    _ = @import("rpc_install.zig");
    _ = @import("skills_discovery.zig");
    _ = @import("skills_commands.zig");
    _ = @import("rpc_skills.zig");
}
