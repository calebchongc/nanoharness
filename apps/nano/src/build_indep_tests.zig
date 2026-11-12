//! The build stands on Zig alone: the version's source, the engine contract
//! vector, the checked-in theme catalogs and the zero-Rust gate.
const std = @import("std");

/// `MAJOR.MINOR.PATCH`, each a number: what build.zig.zon's `.version` must
/// be for the app, the engine and both bundles to report it.
pub fn isReleaseVersion(v: []const u8) bool {
    var parts = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n == 3;
}

const testing = std.testing;

test {
    _ = @import("build_rules.zig");
    _ = @import("engine_contract.zig");
    _ = @import("no_rust_gate.zig");
    _ = @import("theme_catalog_check.zig");
}

test "isReleaseVersion takes three numbers and nothing else" {
    try testing.expect(isReleaseVersion("0.2.186"));
    try testing.expect(isReleaseVersion("10.0.0"));
    try testing.expect(!isReleaseVersion("0.2"));
    try testing.expect(!isReleaseVersion("0.2.186-beta"));
    try testing.expect(!isReleaseVersion("0..1"));
    try testing.expect(!isReleaseVersion(""));
}

test "the build's version comes from build.zig.zon, a real release number" {
    const version = @import("build_info").version;
    try testing.expect(isReleaseVersion(version));
    // Not the placeholder a missing source used to fall back to.
    try testing.expect(!std.mem.eql(u8, version, "0.0.0"));
    try testing.expect(!std.mem.eql(u8, version, "0.0.1"));
}

test "the README builds, runs and tests with the Zig engine, never the Rust one" {
    const gpa = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, @import("parity_options").nano_dir, .{});
    defer dir.close(io);
    const text = try dir.readFileAlloc(io, "README.md", gpa, .limited(1 << 20));
    defer gpa.free(text);
    // Everything before the optional GPUI comparison is the Zig-only path.
    const optional = std.mem.indexOf(u8, text, "## Checking it against the GPUI app (optional, needs Rust)") orelse return error.MissingOptionalSection;
    const zig_only = text[0..optional];
    for ([_][]const u8{ "harness headless", "cargo ", "MacOS/harness ", "crates/rpc", "the Rust runner sends" }) |stale| {
        if (std.mem.indexOf(u8, zig_only, stale)) |at| {
            std.debug.print("README still says \"{s}\" at byte {d}\n", .{ stale, at });
            return error.StaleRustInstruction;
        }
    }
    try testing.expect(std.mem.indexOf(u8, zig_only, "harness-engine headless") != null);
    try testing.expect(std.mem.indexOf(u8, zig_only, "zig build no-rust") != null);
}
