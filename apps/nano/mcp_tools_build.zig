//! The MCP server's tool catalog, `protocol/mcp-tools.json` (the one shared
//! copy), as a module the server embeds: `@import("mcp_tools_json").json`.
const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("../../protocol/mcp-tools.json"), "mcp-tools.json");
    const root = files.add("mcp_tools_json.zig",
        \\//! The MCP tool catalog, as JSON (protocol/mcp-tools.json).
        \\pub const json = @embedFile("mcp-tools.json");
        \\
    );
    return b.createModule(.{ .root_source_file = root });
}
