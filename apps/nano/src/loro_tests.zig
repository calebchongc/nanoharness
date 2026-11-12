//! Genuine retained-Rust fixtures; not JSON tails or simulated Loro bytes.
const std = @import("std");
const t = std.testing;
const sd = @import("session_doc.zig");
const store_mod = @import("docs_store.zig");
const wire = @import("chat2_wire.zig");
const Client = @import("chat2_client.zig").Chat2RoomClient;
const baseline = @embedFile("fixtures/loro-baseline.bin");
const increment = @embedFile("fixtures/loro-incremental.bin");

test "retained Loro: ABI constructor failure frees native allocations" {
    if (!@import("loro.zig").enabled) return error.SkipZigTest;
    try t.expectError(error.LoroCreateFailed, sd.SessionDoc.init(t.allocator, "invalid-\xff", "synthetic-device"));
}

test "retained Loro: genuine Rust snapshot and incremental change existing entries beyond the tail" {
    if (!@import("loro.zig").enabled) return error.SkipZigTest;
    var doc = try sd.SessionDoc.init(t.allocator, "synthetic-loro-fixture", "synthetic-zig");
    defer doc.deinit();
    try doc.importSnapshot(baseline);
    try t.expectEqual(@as(usize, 131), doc.messages.items.len);
    try t.expectEqualStrings("rust-0", doc.messages.items[0].id);
    try t.expectEqualStrings("rust-65", doc.messages.items[65].id);
    try t.expectEqualStrings("thought 🦀", doc.messages.items[130].parts.items[0].text.items);
    try t.expectEqualStrings("tool", doc.messages.items[130].parts.items[1].kind);
    try doc.importSnapshot(increment);
    try doc.importSnapshot(increment);
    try t.expectEqual(@as(usize, 131), doc.messages.items.len);
    try t.expectEqualStrings("answer grows 🚀", doc.messages.items[130].parts.items[2].text.items);
    try t.expectEqualStrings("complete", doc.messages.items[130].status.?);
    try t.expectEqualStrings("edited offline by Rust", doc.queue.items[0].text);
    try t.expectEqualStrings("applied", doc.commands.items[0].status);
    try t.expect(doc.frontierContained(t.allocator, @embedFile("fixtures/loro-final-vv.bin")));
    const snap = try doc.exportSnapshot(t.allocator);
    defer t.allocator.free(snap);
    try t.expect(sd.isRustLoroBlob(snap));
    try t.expectError(error.LegacySnapshotNeedsMigration, doc.importSnapshot("HZD1{}"));
}

test "retained Loro: unresolved row persists with held cursor across SQLite restart" {
    if (!@import("loro.zig").enabled) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const dbpath = try std.fmt.allocPrintSentinel(t.allocator, "{s}/docs.sqlite", .{path}, 0);
    defer t.allocator.free(dbpath);
    var store = try store_mod.DocsStore.openSqlite(t.allocator, dbpath);
    var doc = try sd.SessionDoc.init(t.allocator, "synthetic-loro-fixture", "synthetic-zig");
    var client = Client{ .gpa = t.allocator, .doc_id = doc.chat_id, .doc = &doc, .store = &store };
    var hdr = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"seq\":1}", .{});
    defer hdr.deinit();
    const frame = try wire.encodeValue(t.allocator, wire.FrameType.row, hdr.value, increment);
    defer t.allocator.free(frame);
    try t.expectError(error.PendingDependencies, client.handleServerFrame(frame, 1000));
    try t.expectEqual(@as(?u64, 0), store.snapshotCursor(doc.chat_id));
    try t.expect(try doc.hasPendingLoro());
    doc.deinit();
    store.deinit();
    store = try store_mod.DocsStore.openSqlite(t.allocator, dbpath);
    defer store.deinit();
    doc = try sd.SessionDoc.init(t.allocator, "synthetic-loro-fixture", "synthetic-zig-restarted");
    defer doc.deinit();
    try doc.importSnapshot(store.loadSnapshot(doc.chat_id).?);
    try t.expect(try doc.hasPendingLoro());
    try t.expectEqual(@as(?u64, 0), store.snapshotCursor(doc.chat_id));
    client = .{ .gpa = t.allocator, .doc_id = doc.chat_id, .doc = &doc, .store = &store };
    // The held cursor causes B to replay after restart. Its prerequisite A
    // can be a LATER transport row; do not park forever at the same B row.
    try t.expectError(error.PendingDependencies, client.handleServerFrame(frame, 1100));
    // A no-op row must not let an unrelated ACK/cursor certify pending B.
    var empty_hdr = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"seq\":2}", .{});
    defer empty_hdr.deinit();
    const empty = try wire.encodeValue(t.allocator, wire.FrameType.row, empty_hdr.value, "");
    defer t.allocator.free(empty);
    try t.expectError(error.PendingDependencies, client.handleServerFrame(empty, 1150));
    try t.expectEqual(@as(?u64, 0), store.snapshotCursor(doc.chat_id));
    var h2 = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"seq\":3}", .{});
    defer h2.deinit();
    const prerequisite = try wire.encodeValue(t.allocator, wire.FrameType.row, h2.value, baseline);
    defer t.allocator.free(prerequisite);
    _ = try client.handleServerFrame(prerequisite, 1200);
    try t.expect(!(try doc.hasPendingLoro()));
    try t.expectEqual(@as(?u64, 3), store.snapshotCursor(doc.chat_id));
    try t.expectEqualStrings("answer grows 🚀", doc.messages.items[130].parts.items[2].text.items);
}
