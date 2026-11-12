//! `LocalImportStatus` and `ImportLocalWorkspace`, ported from
//! `crates/engine/src/rpc.rs` (`methods::LOCAL_IMPORT_STATUS`,
//! `methods::IMPORT_LOCAL_WORKSPACE`, `local_importer`) and
//! `crates/engine/src/local_import.rs` (`LocalImporter::status`/`run`,
//! `open_source`, the `local-import.json` marker).
//!
//! The one-time import carries a signed-out device's local profile
//! (`{data}/profiles/local/docs.sqlite3`) into the synced workspace after
//! sign-in. Its source is the local profile's registry replica (doc
//! `registry1`) and chat docs, which the Rust engine wrote as Loro documents.
//! This engine keeps no separate local profile and has no Loro reader (the
//! session-doc and registry formats stay as they are), so:
//!
//! - no local profile, or one with no registry replica: exactly Rust's
//!   answer (nothing available; `start` then `summary`, all zero);
//! - a registry replica: refused with an error, as Rust refuses one it
//!   cannot decode, rather than reporting "nothing to import".
//!
//! `importedBefore` reads the marker as Rust does (one entry per org and
//! user; an unparsable file is moved aside to `local-import.json.corrupt`).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");

const RpcOutcome = common.RpcOutcome;

pub const marker_file = "local-import.json";
/// `harness_doc::REGISTRY_DOC_ID`.
pub const registry_doc_id = "registry1";
pub const unreadable_registry = "the local profile's registry is a Loro document, which this engine cannot read";

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_OPEN_READONLY: c_int = 0x1;
extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(db: *sqlite3) c_int;
extern "c" fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
extern "c" fn sqlite3_bind_text(stmt: *sqlite3_stmt, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern "c" fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;

pub const Source = union(enum) {
    /// No local profile, or no registry replica in it.
    none,
    /// A registry replica this engine cannot decode.
    unreadable,
    /// The local profile's store would not open (`store: …`).
    failed: []const u8,
};

/// `open_source`, reading the store read-only.
pub fn openSource(gpa: Allocator, io: std.Io, data_dir: []const u8) !Source {
    const path = try std.fs.path.join(gpa, &.{ data_dir, "profiles", "local", "docs.sqlite3" });
    defer gpa.free(path);
    if (!common.isFile(io, path)) return .none;
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);
    var db: ?*sqlite3 = null;
    if (sqlite3_open_v2(path_z, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        defer if (db) |d| {
            _ = sqlite3_close(d);
        };
        return .{ .failed = common.errText("store: {s}", .{if (db) |d| std.mem.span(sqlite3_errmsg(d)) else "open failed"}) };
    }
    defer _ = sqlite3_close(db.?);
    const sql = "SELECT 1 FROM snapshots WHERE doc_id = ?1";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db.?, sql.ptr, sql.len, &stmt, null) != SQLITE_OK) {
        return .{ .failed = common.errText("store: {s}", .{std.mem.span(sqlite3_errmsg(db.?))}) };
    }
    defer _ = sqlite3_finalize(stmt.?);
    _ = sqlite3_bind_text(stmt.?, 1, registry_doc_id.ptr, registry_doc_id.len, null);
    return if (sqlite3_step(stmt.?) == SQLITE_ROW) .unreadable else .none;
}

/// `imported_before`: the marker holds an entry for this org and user.
/// A marker that does not parse is moved aside, as `load_marker_locked` does.
pub fn importedBefore(gpa: Allocator, io: std.Io, data_dir: []const u8, org_id: []const u8, user_id: []const u8) !bool {
    const path = try std.fs.path.join(gpa, &.{ data_dir, marker_file });
    defer gpa.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch return false;
    defer gpa.free(raw);
    var parsed = json.parseFromSlice(json.Value, gpa, raw, .{}) catch {
        moveAside(gpa, io, path);
        return false;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        moveAside(gpa, io, path);
        return false;
    }
    const imports = parsed.value.object.get("imports") orelse return false;
    if (imports != .array) {
        moveAside(gpa, io, path);
        return false;
    }
    for (imports.array.items) |e| {
        if (e != .object) continue;
        const o = common.str(e.object, "orgId") orelse continue;
        const u = common.str(e.object, "userId") orelse continue;
        if (std.mem.eql(u8, o, org_id) and std.mem.eql(u8, u, user_id)) return true;
    }
    return false;
}

fn moveAside(gpa: Allocator, io: std.Io, path: []const u8) void {
    const aside = std.fmt.allocPrint(gpa, "{s}.corrupt", .{path}) catch return;
    defer gpa.free(aside);
    std.Io.Dir.rename(std.Io.Dir.cwd(), path, std.Io.Dir.cwd(), aside, io) catch {};
}

const Ctx = struct { io: std.Io, data_dir: []const u8, org_id: []const u8, user_id: []const u8 };

/// `local_importer()`: only a synced workspace carries one.
fn context(host: *engine_host.EngineHost) ?Ctx {
    if (!std.mem.eql(u8, host.workspace_scope, "synced")) return null;
    const io = host.io orelse return null;
    const data_dir = host.data_dir orelse return null;
    return .{ .io = io, .data_dir = data_dir, .org_id = host.auth.org_id orelse "", .user_id = host.auth.user_id };
}

const no_importer = "local import requires a synced workspace";

/// `LocalImportStatus` → `{availableChats, availableSpaces, importedBefore}`.
pub fn localImportStatus(host: *engine_host.EngineHost) !RpcOutcome {
    const gpa = host.gpa;
    const ctx = context(host) orelse return common.failed(no_importer, .{});
    const before = try importedBefore(gpa, ctx.io, ctx.data_dir, ctx.org_id, ctx.user_id);
    switch (try openSource(gpa, ctx.io, ctx.data_dir)) {
        .none => return .{ .unary_json = try std.fmt.allocPrint(gpa, "{{\"availableChats\":0,\"availableSpaces\":0,\"importedBefore\":{}}}", .{before}) },
        .unreadable => return common.failed("doc: {s}", .{unreadable_registry}),
        .failed => |m| return common.failedMsg(m),
    }
}

const zero_summary_head = "{\"kind\":\"summary\",\"importedChats\":0,\"importedSpaces\":0,\"skippedChats\":0,\"skippedSpaces\":0,\"journalsCopied\":0,\"ledgerRowsMerged\":0,\"errors\":[";

/// `ImportLocalWorkspace` → a stream of `ImportEvent`s ending in `summary`.
pub fn importLocalWorkspace(host: *engine_host.EngineHost) !RpcOutcome {
    const gpa = host.gpa;
    const ctx = context(host) orelse return common.failed(no_importer, .{});
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |it| gpa.free(it);
        items.deinit(gpa);
    }
    switch (try openSource(gpa, ctx.io, ctx.data_dir)) {
        .none => {
            try items.append(gpa, try gpa.dupe(u8, "{\"kind\":\"start\",\"chats\":0,\"spaces\":0}"));
            try items.append(gpa, try gpa.dupe(u8, zero_summary_head ++ "]}"));
        },
        // `importer.run` failed: a lone summary carrying the error.
        .unreadable => try items.append(gpa, try std.fmt.allocPrint(gpa, "{s}{f}]}}", .{ zero_summary_head, json.fmt("doc: " ++ unreadable_registry, .{}) })),
        .failed => |m| try items.append(gpa, try std.fmt.allocPrint(gpa, "{s}{f}]}}", .{ zero_summary_head, json.fmt(m, .{}) })),
    }
    return .{ .stream_items_json = .{ .items = try items.toOwnedSlice(gpa) } };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const docs_store = @import("docs_store.zig");

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    host: engine_host.EngineHost,

    fn init() !*Fx {
        const gpa = testing.allocator;
        const f = try gpa.create(Fx);
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, testing.io, &f.tmp);
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = testing.io;
        f.host.data_dir = try gpa.dupe(u8, f.base);
        f.host.workspace_scope = "synced";
        return f;
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        f.host.deinit();
        gpa.free(f.base);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    /// A local profile store, with `registry` as its registry replica if given.
    fn localProfile(f: *Fx, registry: ?[]const u8) !void {
        try f.tmp.dir.createDirPath(testing.io, "profiles/local");
        const path = try std.fs.path.joinZ(testing.allocator, &.{ f.base, "profiles", "local", "docs.sqlite3" });
        defer testing.allocator.free(path);
        var store = try docs_store.DocsStore.openSqlite(testing.allocator, path);
        defer store.deinit();
        try store.saveSnapshot("chat-local-1", "HZD1{}", 1);
        if (registry) |r| try store.saveSnapshot(registry_doc_id, r, 1);
    }

    fn status(f: *Fx) !RpcOutcome {
        return f.host.handle("LocalImportStatus", .null);
    }

    fn run(f: *Fx) !RpcOutcome {
        return f.host.handle("ImportLocalWorkspace", .null);
    }
};

fn expectItems(outcome: RpcOutcome, expected: []const []const u8) !void {
    var s = outcome.stream_items_json;
    defer s.deinit(testing.allocator);
    try testing.expectEqual(expected.len, s.items.len);
    for (expected, s.items) |e, got| try testing.expectEqualStrings(e, got);
}

test "rpcw_local_import with no local profile: nothing available and an all-zero run" {
    const f = try Fx.init();
    defer f.deinit();
    const st = try f.status();
    defer testing.allocator.free(st.unary_json);
    try testing.expectEqualStrings("{\"availableChats\":0,\"availableSpaces\":0,\"importedBefore\":false}", st.unary_json);
    try expectItems(try f.run(), &.{
        "{\"kind\":\"start\",\"chats\":0,\"spaces\":0}",
        "{\"kind\":\"summary\",\"importedChats\":0,\"importedSpaces\":0,\"skippedChats\":0,\"skippedSpaces\":0,\"journalsCopied\":0,\"ledgerRowsMerged\":0,\"errors\":[]}",
    });
    // A local store with no registry replica has nothing rowed either.
    try f.localProfile(null);
    const st2 = try f.status();
    defer testing.allocator.free(st2.unary_json);
    try testing.expectEqualStrings("{\"availableChats\":0,\"availableSpaces\":0,\"importedBefore\":false}", st2.unary_json);
}

test "rpcw_local_import importedBefore follows the marker for this org and user" {
    const f = try Fx.init();
    defer f.deinit();
    const org = f.host.auth.org_id.?;
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"imports\":[{{\"orgId\":\"org-other\",\"userId\":{f},\"importedAtMs\":1,\"importedChats\":1,\"importedSpaces\":0}},{{\"orgId\":{f},\"userId\":{f},\"importedAtMs\":2,\"importedChats\":3,\"importedSpaces\":1}}]}}", .{ json.fmt(f.host.auth.user_id, .{}), json.fmt(org, .{}), json.fmt(f.host.auth.user_id, .{}) });
    defer testing.allocator.free(body);
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = marker_file, .data = body });
    const st = try f.status();
    defer testing.allocator.free(st.unary_json);
    try testing.expectEqualStrings("{\"availableChats\":0,\"availableSpaces\":0,\"importedBefore\":true}", st.unary_json);

    // An unparsable marker is moved aside and counts as no import.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = marker_file, .data = "{not json" });
    const st2 = try f.status();
    defer testing.allocator.free(st2.unary_json);
    try testing.expectEqualStrings("{\"availableChats\":0,\"availableSpaces\":0,\"importedBefore\":false}", st2.unary_json);
    const marker = try std.fs.path.join(testing.allocator, &.{ f.base, marker_file });
    defer testing.allocator.free(marker);
    try testing.expect(!common.isFile(testing.io, marker));
    const aside = try std.fs.path.join(testing.allocator, &.{ f.base, marker_file ++ ".corrupt" });
    defer testing.allocator.free(aside);
    try testing.expect(common.isFile(testing.io, aside));
}

test "rpcw_local_import refuses a registry replica it cannot read, and a local workspace" {
    const f = try Fx.init();
    defer f.deinit();
    try f.localProfile("loro\x00synthetic-registry-bytes");
    const st = try f.status();
    try testing.expectEqualStrings("doc: " ++ unreadable_registry, st.err.exec_error);
    try expectItems(try f.run(), &.{
        "{\"kind\":\"summary\",\"importedChats\":0,\"importedSpaces\":0,\"skippedChats\":0,\"skippedSpaces\":0,\"journalsCopied\":0,\"ledgerRowsMerged\":0,\"errors\":[\"doc: " ++ unreadable_registry ++ "\"]}",
    });

    f.host.workspace_scope = "local";
    try testing.expectEqualStrings(no_importer, (try f.status()).err.exec_error);
    try testing.expectEqualStrings(no_importer, (try f.run()).err.exec_error);
}
