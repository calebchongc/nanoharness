//! The engine's contract as data (`engine_contract.json`): every RPC method
//! the reference engine serves, the `Mutate` ops, queued-edit actions,
//! session-command kinds and queue delivery gates, and the doc-host, doc and
//! sync-budget constants. The Zig engine's parity tests (engine_host.zig)
//! assert against this vector, so they build and run with no Rust source in
//! the checkout. Change the vector and the engine together, on purpose.
const std = @import("std");

pub const json_text = @embedFile("engine_contract.json");

pub const Contract = struct {
    comment: []const u8,
    rpcMethods: []const []const u8,
    mutateOps: []const []const u8,
    finishQueuedMessageEditActions: []const []const u8,
    sessionCommandKinds: []const []const u8,
    queueDeliveryGates: []const []const u8,
    docHost: struct {
        warmDocCap: usize,
        docResidentFloorBytes: usize,
        residentBytesPerSnapshotByte: usize,
        activeSyncCap: usize,
        queueEditLeaseMs: i64,
        syncAdmissionBatch: usize,
    },
    docConstants: struct {
        docLruByteBudget: usize,
        sessionSchemaVersion: u32,
        msgInlineMax: usize,
        retainDays: u32,
        compactLogBytes: usize,
        softCeilingBytes: usize,
        streamCommitMs: u64,
        doFlushMs: u64,
        tailMessageCount: usize,
        terminalOutputBatchMs: u64,
        commandDefaultTtlMs: i64,
    },
    syncBudget: struct {
        maxWaiters: usize,
        dialPacingMs: i64,
        fdExhaustedPauseMs: i64,
    },
};

/// The vector, its strings in `arena` (an unknown or missing field fails).
pub fn load(arena: std.mem.Allocator) !Contract {
    return std.json.parseFromSliceLeaky(Contract, arena, json_text, .{});
}

/// The first name listed twice, if any.
pub fn firstDuplicate(names: []const []const u8) ?[]const u8 {
    for (names, 0..) |name, i| {
        for (names[i + 1 ..]) |other| if (std.mem.eql(u8, name, other)) return name;
    }
    return null;
}

/// `reviewRequired` as `review_required`, into `buf`: the wire's camelCase
/// name as the Zig enum tag it maps to. Null when `buf` is too small.
pub fn camelToSnake(buf: []u8, camel: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (camel) |c| {
        if (std.ascii.isUpper(c)) {
            if (n + 2 > buf.len) return null;
            if (n > 0) {
                buf[n] = '_';
                n += 1;
            }
            buf[n] = std.ascii.toLower(c);
        } else {
            if (n + 1 > buf.len) return null;
            buf[n] = c;
        }
        n += 1;
    }
    return buf[0..n];
}

const testing = std.testing;

test "the engine contract vector parses, each list without repeats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try load(arena.allocator());
    try testing.expectEqual(@as(usize, 158), c.rpcMethods.len);
    try testing.expectEqual(@as(usize, 17), c.mutateOps.len);
    try testing.expectEqual(@as(usize, 4), c.finishQueuedMessageEditActions.len);
    try testing.expectEqual(@as(usize, 5), c.sessionCommandKinds.len);
    try testing.expectEqual(@as(usize, 2), c.queueDeliveryGates.len);
    for ([_][]const []const u8{ c.rpcMethods, c.mutateOps, c.finishQueuedMessageEditActions, c.sessionCommandKinds, c.queueDeliveryGates }) |list|
        try testing.expectEqual(@as(?[]const u8, null), firstDuplicate(list));
}

test "firstDuplicate finds a repeat and nothing in a clean list" {
    try testing.expectEqualStrings("b", firstDuplicate(&.{ "a", "b", "c", "b" }).?);
    try testing.expectEqual(@as(?[]const u8, null), firstDuplicate(&.{ "a", "b", "c" }));
    try testing.expectEqual(@as(?[]const u8, null), firstDuplicate(&.{}));
}

test "camelToSnake maps wire names to enum tags" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("review_required", camelToSnake(&buf, "reviewRequired").?);
    try testing.expectEqualStrings("editing", camelToSnake(&buf, "editing").?);
    try testing.expectEqualStrings("release_unchanged", camelToSnake(&buf, "releaseUnchanged").?);
    var tiny: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), camelToSnake(&tiny, "reviewRequired"));
}
