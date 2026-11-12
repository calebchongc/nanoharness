//! The iOS shipping rules' tests: bundle and signing, the Keychain session
//! store, push registration, and crash report upload.
const std = @import("std");
const testing = std.testing;
const session_store = @import("session_store.zig");
const auth_host = @import("auth_host.zig");

test {
    _ = @import("ios_build_rules.zig");
    _ = session_store;
    _ = @import("ios_push.zig");
}

test "auth_host restores, migrates and signs out through the session store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/session.json", .{dir});
    defer testing.allocator.free(path);

    var mem: session_store.MemoryStore = .{ .gpa = testing.allocator };
    defer mem.deinit();
    const saved = session_store.testing_store;
    defer session_store.testing_store = saved;
    session_store.testing_store = mem.secure();

    // An earlier build's file: read once, moved into the store, deleted.
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "{\"refreshToken\":\"rt-synthetic\",\"user\":{\"id\":\"u-synth\",\"email\":\"ada@example.com\",\"name\":\"Ada\"},\"orgId\":\"org-synth\"}",
    });
    var auth = try auth_host.AuthManager.init(testing.allocator);
    defer auth.deinit();
    try auth.configureCodegraff("https://edge.invalid", "client-synth", null, dir);
    try testing.expect(auth.loadPersistedSession(testing.io));
    try testing.expectEqualStrings("org-synth", auth.org_id.?);
    try testing.expectEqualStrings("rt-synthetic", auth.refresh_token.?);
    try testing.expect(mem.get(session_store.session_account) != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));

    // The next launch restores from the store alone.
    var again = try auth_host.AuthManager.init(testing.allocator);
    defer again.deinit();
    try again.configureCodegraff("https://edge.invalid", "client-synth", null, dir);
    try testing.expect(again.loadPersistedSession(testing.io));
    try testing.expectEqualStrings("ada@example.com", again.email);

    // Signing out empties it.
    again.signOutWithIo(testing.io);
    try testing.expect(mem.get(session_store.session_account) == null);
}
