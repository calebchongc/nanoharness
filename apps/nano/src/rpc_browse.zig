//! `BrowseLinkStatus`, `BrowseLinkPair` and `BrowseLinkDisconnect`, ported
//! from `crates/engine/src/rpc.rs` (`BROWSE_LINK_*`) onto `browse_link.zig`
//! (`BrowseLink::shared(data_dir)`).
//!
//! Status may ask a paired browse for its scopes (up to 3 s) and Pair makes
//! one loopback request to browse, so neither touches engine state beyond the
//! data dir: both can run outside the host lock.
const std = @import("std");
const json = std.json;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const core = @import("catalog_core.zig");
const browse = @import("browse_link.zig");

const RpcOutcome = common.RpcOutcome;

pub const Method = enum { status, pair, disconnect };

pub fn handle(host: *engine_host.EngineHost, method: Method) !RpcOutcome {
    const gpa = host.gpa;
    const io = host.io orelse return common.failed("browse link needs I/O", .{});
    const data_dir = try gpa.dupe(u8, host.data_dir orelse return common.failed("browse link needs a data dir", .{}));
    defer gpa.free(data_dir);
    core.env_override = common.env_override;
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    // Status asks browse (3 s); pairing waits on it: not under the engine lock.
    const released = host.releaseForLongCall();
    defer host.retakeAfterLongCall(released);
    return switch (method) {
        .status => .{ .unary_json = try browse.status(gpa, io, data_dir, &env) },
        .disconnect => .{ .unary_json = try browse.disconnect(gpa, io, data_dir, &env) },
        .pair => switch (try browse.pair(gpa, io, data_dir, &env)) {
            .json => |body| .{ .unary_json = body },
            .failed => |msg| blk: {
                defer gpa.free(msg);
                break :blk common.failed("{s}", .{msg});
            },
        },
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const keystore = @import("browse_link_keystore.zig");

test "rpc_browse answers status, refuses pairing without browse, and disconnects" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try common.tmpPath(gpa, io, &tmp);
    defer gpa.free(base);
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "data");
    const home = try std.fs.path.join(gpa, &.{ base, "home" });
    defer gpa.free(home);
    const data = try std.fs.path.join(gpa, &.{ base, "data" });
    defer gpa.free(data);
    const connect = try std.fs.path.join(gpa, &.{ base, "no-browse", "connect.json" });
    defer gpa.free(connect);
    var env = try common.TestEnv.init(gpa, home);
    defer env.deinit();
    try env.map.put("HARNESS_BROWSE_CONNECT", connect);
    env.install();
    defer core.env_override = null;
    var mem: keystore.MemoryKeyStore = .{};
    keystore.override = mem.keyStore();
    defer keystore.override = null;

    var host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
    defer host.deinit();
    // Without I/O or a data dir there is no link to answer for.
    const no_io = try host.handle("BrowseLinkStatus", .{ .object = .empty });
    try testing.expect(no_io == .err and no_io.err == .exec_error);
    host.io = io;
    try host.setDataDir(data);

    const st = try host.handle("BrowseLinkStatus", .{ .object = .empty });
    defer gpa.free(st.unary_json);
    var parsed = try json.parseFromSlice(json.Value, gpa, st.unary_json, .{});
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("browseRunning").?.bool);
    try testing.expect(!parsed.value.object.get("paired").?.bool);

    const pr = try host.handle("BrowseLinkPair", .{ .object = .empty });
    switch (pr) {
        .err => |e| try testing.expect(e == .exec_error and e.exec_error.len > 0),
        .unary_json => |b| {
            gpa.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }

    const dc = try host.handle("BrowseLinkDisconnect", .{ .object = .empty });
    defer gpa.free(dc.unary_json);
    try testing.expectEqualStrings("{\"ok\":true}", dc.unary_json);
}
