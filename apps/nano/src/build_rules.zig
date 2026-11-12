//! Rules build.zig follows, kept here so the tests can call them
//! (build.zig imports this file; so does src/build_indep_tests.zig).
const std = @import("std");

/// Whether `os` links the platform's own libsqlite3 (Apple platforms ship
/// one in the SDK) or compiles SQLite from the pinned amalgamation, the lazy
/// `sqlite` dependency in build.zig.zon, as a cross build for Linux or
/// Windows has no system library to link.
pub fn sqliteFromSource(os: std.Target.Os.Tag) bool {
    return !os.isDarwin();
}

/// Defines SQLite is compiled with: no extension loading (no libdl, and
/// docs_store loads none), threads serialized as the system library's are.
pub const sqlite_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_OMIT_LOAD_EXTENSION=1",
    "-DSQLITE_DQS=0",
};

/// The mode http-zig is built in. Small on Apple platforms (the app's own
/// HTTPS only). Elsewhere nanoui imports http-zig itself, in the app's mode,
/// and the app must ask for the same instance: two would put one file in two
/// modules ("file exists in modules 'http_zig' and 'http_zig0'").
pub fn httpZigOptimize(optimize: std.builtin.Optimize, os: std.Target.Os.Tag) std.builtin.Optimize {
    if (optimize == .debug or !os.isDarwin()) return optimize;
    return .small;
}

const testing = std.testing;

test "SQLite comes from the SDK on Apple platforms and from source elsewhere" {
    try testing.expect(!sqliteFromSource(.macos));
    try testing.expect(!sqliteFromSource(.ios));
    try testing.expect(sqliteFromSource(.linux));
    try testing.expect(sqliteFromSource(.windows));
}

test "http-zig shares nanoui's instance off Apple platforms, small on them" {
    try testing.expectEqual(std.builtin.Optimize.small, httpZigOptimize(.safe, .macos));
    try testing.expectEqual(std.builtin.Optimize.small, httpZigOptimize(.fast, .ios));
    try testing.expectEqual(std.builtin.Optimize.debug, httpZigOptimize(.debug, .macos));
    try testing.expectEqual(std.builtin.Optimize.safe, httpZigOptimize(.safe, .linux));
    try testing.expectEqual(std.builtin.Optimize.safe, httpZigOptimize(.safe, .windows));
}
