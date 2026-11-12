//! What the iOS app starts before UIKit does (main.zig, iOS only): the
//! notification delegate and push registration (ios_push.zig), and MetricKit
//! crash and hang reports (ios_crash_reports.zig).
//!
//! `HARNESS_IOS_SELFTEST=keychain` (Simulator checks, demo data only) runs
//! the Keychain session store against the real Keychain with a synthetic
//! session and prints `selftest keychain: ok` or the step that failed;
//! `HARNESS_IOS_SELFTEST=push-prompt` asks for notifications as the
//! person's yes does (the system's prompt shows).
const std = @import("std");
const App = @import("app.zig").App;
const EmbeddedHost = @import("ios_host.zig").EmbeddedHost;
const session_store = @import("session_store.zig");

/// The Simulator reads an app's entitlements from this section, as Xcode
/// links them (`-sectcreate __TEXT __entitlements`); its Keychain needs the
/// application identifier there. Empty, and left out, for a device.
const simulated = @import("ios_build").simulated_entitlements;
const simulated_bytes: [simulated.len]u8 = simulated[0..simulated.len].*;
comptime {
    if (simulated.len > 0) @export(&simulated_bytes, .{ .name = "harness_simulated_entitlements", .section = "__TEXT,__entitlements" });
}

pub fn start(gpa: std.mem.Allocator, io: std.Io, a: *App, embedded: *EmbeddedHost, demo: bool) void {
    // Referenced, so the linker's dead stripping keeps the section.
    if (simulated.len > 0) std.mem.doNotOptimizeAway(&simulated_bytes);
    @import("ios_push.zig").runtime.install(gpa, io, a, &embedded.host, demo);
    const env = a.env orelse return;
    if (env.get("HARNESS_IOS_SELFTEST")) |what| {
        // The system's notification prompt, as the person's "yes" brings it.
        if (std.mem.eql(u8, what, "push-prompt")) @import("nanoui").objc.dispatchAfter(2 * std.time.ns_per_s, null, askForNotifications);
        if (std.mem.eql(u8, what, "keychain")) {
            const result = keychainSelfTest(gpa, io, env.get("HOME") orelse return);
            std.debug.print("selftest keychain: {s}\n", .{result});
        }
    }
}

fn askForNotifications(_: ?*anyopaque) callconv(.c) void {
    @import("ios_push.zig").runtime.requestPermission();
}

/// The session store's whole path on the real Keychain: a synthetic
/// session.json moved in and deleted, read back, then cleared. Never touches
/// a sign-in that is already there.
fn keychainSelfTest(gpa: std.mem.Allocator, io: std.Io, home: []const u8) []const u8 {
    const secure = session_store.keychain.secure();
    switch (secure.read(gpa, session_store.session_account)) {
        .found => |v| {
            gpa.free(v);
            return "skipped (a session is already kept)";
        },
        .unavailable => return "failed: the Keychain can't be read",
        .missing => {},
    }
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/tmp/selftest-session.json", .{home}) catch return "failed: path";
    const body = "{\"refreshToken\":\"rt-selftest-synthetic\",\"orgId\":\"org-selftest\"}";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch return "failed: writing the synthetic file";
    const got = session_store.load(gpa, io, secure, path) orelse return "failed: load returned nothing";
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, body)) return "failed: load returned another body";
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return "failed: the file wasn't deleted after the move" else |_| {}
    switch (secure.read(gpa, session_store.session_account)) {
        .found => |v| {
            defer gpa.free(v);
            if (!std.mem.eql(u8, v, body)) return "failed: the Keychain holds another body";
        },
        else => return "failed: the Keychain didn't keep the session",
    }
    if (!session_store.save(io, secure, path, "{\"refreshToken\":\"rt-selftest-rotated\"}")) return "failed: update refused";
    session_store.clear(io, secure, path);
    switch (secure.read(gpa, session_store.session_account)) {
        .missing => {},
        .found => |v| {
            gpa.free(v);
            return "failed: clear left the item";
        },
        .unavailable => return "failed: unreadable after clear",
    }
    return "ok";
}
