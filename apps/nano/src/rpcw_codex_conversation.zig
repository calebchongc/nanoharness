//! `CodexConversationPreview` and `CodexConversationImport`, ported from
//! `crates/engine/src/rpc.rs` and `crates/engine/src/external_history/`
//! (`ExternalHistory::codex_preview`/`import_codex`, `usable_cwd`,
//! `validated_cwd`, `codex_warnings`, and `codex.rs` `reference_id`,
//! `resolve`, `head`).
//!
//! A pasted `codex://threads/<id>` link (or bare id) names one local Codex
//! thread. The preview reads it without starting Codex or creating a chat; the
//! import writes it as a chat with `ExternalHistoryImport`'s importer, or
//! reopens an earlier import of it.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const history = @import("rpcw_history.zig");
const importer = @import("rpcw_history_import.zig");
const engine_host = @import("engine_host.zig");
const session_doc = @import("session_doc.zig");

const RpcOutcome = common.RpcOutcome;

const head_lines: usize = 400;
/// `SEED_CONVERSATION_BYTES`.
const seed_conversation_bytes: usize = 60_000;

pub const bad_reference = "Paste a Codex conversation link (codex://threads/<conversation-id>) or its conversation ID.";
pub const not_hyphenated = "The Codex conversation ID must be a hyphenated UUID.";
pub const not_found = "That Codex conversation was not found on this device. Open Harness on the computer that holds the conversation, or check the Codex conversation link.";
pub const cwd_unavailable = "The working folder is unavailable. Choose an existing folder on this device before continuing.";
pub const other_folder = "That conversation is already imported with a different working folder. Open it in Harness and change its working folder before continuing.";
pub const nothing_readable = "That Codex conversation has no readable text or tool history to import.";

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// `uuid::Uuid::parse_str` → its 32 hex digits, or null.
fn uuidDigits(text: []const u8, out: *[32]u8) bool {
    var t = text;
    if (std.ascii.startsWithIgnoreCase(t, "urn:uuid:")) t = t["urn:uuid:".len..];
    if (t.len == 38 and t[0] == '{' and t[37] == '}') t = t[1..37];
    if (t.len == 32) {
        if (!isHex(t)) return false;
        @memcpy(out, t);
        return true;
    }
    if (t.len != 36) return false;
    var n: usize = 0;
    for (t, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
            continue;
        }
        if (!std.ascii.isHex(c)) return false;
        out[n] = c;
        n += 1;
    }
    return true;
}

/// `reference_id`: the canonical (lowercase, hyphenated) id a link or id names.
pub fn referenceId(reference: []const u8, out: *[36]u8) union(enum) { ok: []const u8, bad: []const u8 } {
    const r = std.mem.trim(u8, reference, " \t\r\n\x0b\x0c");
    const id = if (std.mem.startsWith(u8, r, "codex://threads/")) blk: {
        const rest = r["codex://threads/".len..];
        const end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
        const path = rest[0..end];
        break :blk if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    } else r;
    var digits: [32]u8 = undefined;
    if (!uuidDigits(id, &digits)) return .{ .bad = bad_reference };
    var n: usize = 0;
    for (out, 0..) |*c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            c.* = '-';
        } else {
            c.* = std.ascii.toLower(digits[n]);
            n += 1;
        }
    }
    if (!std.ascii.eqlIgnoreCase(out, id)) return .{ .bad = not_hyphenated };
    return .{ .ok = out };
}

fn field(v: json.Value, key: []const u8) json.Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

fn str(v: json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key);
    return if (f == .string) f.string else null;
}

/// `rollout_files`: every `*.jsonl` under `dir`, recursively.
fn rolloutFiles(arena: Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try rolloutFiles(arena, io, path, out),
            .file => if (std.mem.endsWith(u8, entry.name, ".jsonl") and entry.name.len > ".jsonl".len) try out.append(arena, path),
            else => {},
        }
    }
}

/// `head_lines`: the first 400 parsed lines (malformed ones skipped).
const Head = struct {
    lines: *importer.Lines,
    jl: importer.JsonLines,
    n: usize = 0,

    fn next(self: *Head) ?json.Value {
        if (self.n >= head_lines) return null;
        const v = self.jl.next() orelse return null;
        self.n += 1;
        return v;
    }
};

fn openHead(arena: Allocator, io: std.Io, path: []const u8) !Head {
    const lines = try importer.Lines.open(arena, io, path);
    return .{ .lines = lines, .jl = .{ .lines = lines, .arena = arena } };
}

/// `head(path, None)`'s title: the first real prompt, one line (90), when the
/// thread is not a sub-agent's and has an id.
fn codexTitle(arena: Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    var h = openHead(arena, io, path) catch return null;
    defer h.lines.close(arena);
    var id: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    while (h.next()) |line| {
        const kind = str(line, "type") orelse "";
        const p = field(line, "payload");
        if (std.mem.eql(u8, kind, "session_meta")) {
            if (field(field(p, "source"), "subagent") == .object) return null;
            id = str(p, "id");
        } else if (std.mem.eql(u8, kind, "response_item") and prompt == null and
            std.mem.eql(u8, str(p, "type") orelse "", "message") and std.mem.eql(u8, str(p, "role") orelse "", "user"))
        {
            const text = (try importer.blocksText(arena, field(p, "content"), false, false)) orelse "";
            if (!history.isScaffolding(text)) prompt = text;
        }
        if (id != null and prompt != null) break;
    }
    if (id == null) return null;
    const title = try history.oneLine(arena, prompt orelse return null, 90);
    if ((std.unicode.utf8CountCodepoints(title) catch title.len) < 2) return null;
    return title;
}

/// `file_times`: (first write, last write, size).
fn fileTimes(arena: Allocator, io: std.Io, path: []const u8) struct { i64, i64, u64 } {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ 0, 0, 0 };
    const modified: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
    var created: i64 = 0;
    if (comptime builtin.os.tag == .macos and builtin.link_libc) {
        if (arena.dupeSentinel(u8, path, 0)) |z| {
            var cst: std.c.Stat = undefined;
            if (std.c.stat(z, &cst) == 0) {
                const b = cst.birthtime();
                created = @as(i64, @intCast(b.sec)) * 1000 + @divTrunc(@as(i64, @intCast(b.nsec)), std.time.ns_per_ms);
            }
        } else |_| {}
    }
    created = @min(created, modified);
    return .{ if (created == 0) modified else created, modified, st.size };
}

pub const Resolved = struct { session: history.Session, archived: bool };

/// `codex::resolve`: the one rollout (live first, then archived) whose name
/// ends with the id and whose `session_meta` names it.
pub fn resolve(arena: Allocator, io: std.Io, codex_home: []const u8, id: []const u8) !union(enum) { ok: Resolved, failed: []const u8 } {
    const exact = try std.fmt.allocPrint(arena, "{s}.jsonl", .{id});
    const suffix = try std.fmt.allocPrint(arena, "-{s}.jsonl", .{id});
    for ([_]struct { []const u8, bool }{ .{ "sessions", false }, .{ "archived_sessions", true } }) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        try rolloutFiles(arena, io, try std.fs.path.join(arena, &.{ codex_home, where[0] }), &files);
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        for (files.items) |path| {
            const name = try std.ascii.allocLowerString(arena, std.fs.path.basename(path));
            if (!std.mem.eql(u8, name, exact) and !std.mem.endsWith(u8, name, suffix)) continue;
            var h = openHead(arena, io, path) catch |e|
                return .{ .failed = try std.fmt.allocPrint(arena, "The local Codex conversation could not be read: {s}", .{importer.ioMessage(e)}) };
            defer h.lines.close(arena);
            var metadata: ?struct { cwd: ?[]const u8 } = null;
            while (h.next()) |line| {
                if (!std.mem.eql(u8, str(line, "type") orelse "", "session_meta")) continue;
                const p = field(line, "payload");
                if (field(field(p, "source"), "subagent") == .object) break;
                if (str(p, "id")) |native| if (std.ascii.eqlIgnoreCase(native, id)) {
                    metadata = .{ .cwd = str(p, "cwd") };
                };
                break;
            }
            const meta = metadata orelse continue;
            const title = (try codexTitle(arena, io, path)) orelse "Codex conversation";
            const times = fileTimes(arena, io, path);
            return .{ .ok = .{
                .session = .{
                    .source = .codex,
                    .id = try arena.dupe(u8, id),
                    .path = try arena.dupe(u8, path),
                    .cwd = if (meta.cwd) |c| try arena.dupe(u8, c) else null,
                    .title = try arena.dupe(u8, title),
                    .started_at = times[0],
                    .updated_at = times[1],
                    .size = times[2],
                },
                .archived = where[1],
            } };
        }
    }
    return .{ .failed = not_found };
}

/// `usable_cwd`: an absolute path to a folder that exists.
fn usableCwd(io: std.Io, cwd: ?[]const u8) bool {
    const c = cwd orelse return false;
    return std.fs.path.isAbsolute(c) and common.isDir(io, c);
}

/// `codex_warnings`.
fn writeWarnings(w: *std.Io.Writer, cwd_available: bool, shortened: bool, already: bool) !void {
    try w.writeAll("[\"Imports text messages and brief tool results. Images, attachments, and full tool output are not included.\"");
    if (shortened) try w.writeAll(",\"The initial request and most recent conversation will be used to continue; some earlier content will be omitted.\"");
    if (!cwd_available) try w.writeAll(",\"The original working folder is unavailable. Choose an existing working folder before continuing.\"");
    if (already) try w.writeAll(",\"This conversation is already in Harness. Continuing uses its current Harness history.\"");
    try w.writeByte(']');
}

fn codexHome(arena: Allocator) ![]const u8 {
    if (common.getenvNonEmpty("CODEX_HOME")) |d| return d;
    return std.fs.path.join(arena, &.{ common.homeDir() orelse "/", ".codex" });
}

fn findChat(host: *engine_host.EngineHost, id: []const u8) ?*engine_host.ChatRecord {
    for (host.chats.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

const Ref = union(enum) { ok: []const u8, err: RpcOutcome };

fn referenceParam(params: json.Value, out: *[36]u8) Ref {
    const o = common.obj(params) orelse return .{ .err = .{ .err = .{ .bad_params = "invalid type: expected struct Params" } } };
    const v = o.get("reference") orelse return .{ .err = .{ .err = .{ .bad_params = "missing field `reference`" } } };
    if (v != .string) return .{ .err = .{ .err = .{ .bad_params = "invalid type: expected a string for `reference`" } } };
    return switch (referenceId(v.string, out)) {
        .ok => |id| .{ .ok = id },
        .bad => |m| .{ .err = common.failedMsg(m) },
    };
}

/// `CodexConversationPreview { reference }`.
pub fn preview(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    var id_buf: [36]u8 = undefined;
    const id = switch (referenceParam(params, &id_buf)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    const io = host.io orelse return common.failed("conversation import unavailable", .{});
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try codexHome(arena);
    const chat_id = try std.fmt.allocPrint(arena, "ext-codex-{s}", .{id});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (findChat(host, chat_id)) |chat| {
        var count: usize = 0;
        if (host.store.loadSnapshot(chat_id)) |bytes| {
            var doc = try session_doc.SessionDoc.init(gpa, chat_id, host.device_id);
            defer doc.deinit();
            if (doc.importSnapshot(bytes)) |_| {
                count = doc.messages.items.len;
            } else |_| {}
        }
        const available = usableCwd(io, chat.cwd);
        const archived = switch (try resolve(arena, io, home, id)) {
            .ok => |r| r.archived,
            .failed => false,
        };
        const updated = if (chat.last_message_at_ms > 0) chat.last_message_at_ms else chat.created_at_ms;
        try w.print("{{\"id\":{f},\"title\":{f},\"cwd\":{f},\"cwdAvailable\":{},\"updatedAt\":{d},\"archived\":{},\"messageCount\":{d},\"lastMessage\":{f},\"alreadyImported\":true,\"chatId\":{f},\"warnings\":", .{
            json.fmt(id, .{}),                  json.fmt(chat.title orelse "Codex conversation", .{}), json.fmt(chat.cwd, .{}),
            available,                           updated,                                               archived,
            count,                               json.fmt(chat.preview, .{}),                           json.fmt(chat_id, .{}),
        });
        try writeWarnings(w, available, false, true);
        try w.writeByte('}');
        return .{ .unary_json = try aw.toOwnedSlice() };
    }

    const resolved = switch (try resolve(arena, io, home, id)) {
        .ok => |r| r,
        .failed => |m| return common.failedMsg(m),
    };
    const s = resolved.session;
    var err: importer.LoadError = .{ .message = "" };
    const t = importer.load(arena, io, s, &err) catch |e|
        return common.failed("{s}", .{if (e == error.LoadFailed) err.message else @errorName(e)});
    if (t.msgs.items.len == 0) return common.failedMsg(nothing_readable);
    var text_bytes: usize = 0;
    var last: ?[]const u8 = null;
    for (t.msgs.items) |m| for (m.blocks.items) |b| switch (b) {
        .text => |tx| {
            text_bytes += tx.len;
            last = tx;
        },
        .tool => |tool| text_bytes += if (tool.output) |o| o.len else 0,
    };
    const last_line: ?[]const u8 = if (last) |l| try history.oneLine(arena, l, 320) else null;
    const available = usableCwd(io, s.cwd);
    try w.print("{{\"id\":{f},\"title\":{f},\"cwd\":{f},\"cwdAvailable\":{},\"updatedAt\":{d},\"archived\":{},\"messageCount\":{d},\"lastMessage\":{f},\"alreadyImported\":false,\"chatId\":null,\"warnings\":", .{
        json.fmt(id, .{}),  json.fmt(s.title, .{}), json.fmt(s.cwd, .{}),
        available,           s.updated_at,            resolved.archived,
        t.msgs.items.len,    json.fmt(last_line, .{}),
    });
    try writeWarnings(w, available, text_bytes > seed_conversation_bytes, false);
    try w.writeByte('}');
    return .{ .unary_json = try aw.toOwnedSlice() };
}

/// `CodexConversationImport { reference, cwd? }` → `{chatId, alreadyImported}`.
pub fn import(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    var id_buf: [36]u8 = undefined;
    const id = switch (referenceParam(params, &id_buf)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    const cwd: ?[]const u8 = blk: {
        const v = params.object.get("cwd") orelse break :blk null;
        break :blk switch (v) {
            .null => null,
            .string => |s| s,
            else => return .{ .err = .{ .bad_params = "invalid type: expected a string for `cwd`" } },
        };
    };
    const io = host.io orelse return common.failed("conversation import unavailable", .{});
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const chat_id = try std.fmt.allocPrint(arena, "ext-codex-{s}", .{id});

    if (findChat(host, chat_id)) |chat| {
        if (cwd) |selected| {
            if (!usableCwd(io, selected)) return common.failedMsg(cwd_unavailable);
            const existing = if (chat.cwd) |c| common.canonicalize(arena, io, c) else null;
            const chosen = common.canonicalize(arena, io, selected);
            const same = if (existing) |e| (if (chosen) |c| std.mem.eql(u8, e, c) else false) else chosen == null;
            if (!same) return common.failedMsg(other_folder);
        }
        if (!usableCwd(io, chat.cwd)) return common.failedMsg(cwd_unavailable);
        return .{ .unary_json = try std.fmt.allocPrint(gpa, "{{\"chatId\":{f},\"alreadyImported\":true}}", .{json.fmt(chat_id, .{})}) };
    }

    var resolved = switch (try resolve(arena, io, try codexHome(arena), id)) {
        .ok => |r| r,
        .failed => |m| return common.failedMsg(m),
    };
    const chosen = cwd orelse resolved.session.cwd;
    if (!usableCwd(io, chosen)) return common.failedMsg(cwd_unavailable);
    resolved.session.cwd = @constCast(chosen.?);
    var err: importer.LoadError = .{ .message = "" };
    const imported = importer.importOne(host, io, resolved.session, &err, arena) catch |e|
        return common.failed("{s}", .{if (e == error.LoadFailed) err.message else @errorName(e)});
    host.saveRegistryCacheFile();
    host.wakeBgSync();
    const ch_json = try host.chatsJson();
    defer gpa.free(ch_json);
    try host.broadcastWatch(.chats, null, ch_json);
    return .{ .unary_json = try std.fmt.allocPrint(gpa, "{{\"chatId\":{f},\"alreadyImported\":false}}", .{json.fmt(imported, .{})}) };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const thread_id = "12345678-1234-4123-8123-123456789abc";

test "rpcw_codex_conversation referenceId accepts codex links and hyphenated ids only" {
    var buf: [36]u8 = undefined;
    try testing.expectEqualStrings(thread_id, referenceId("codex://threads/" ++ thread_id, &buf).ok);
    try testing.expectEqualStrings(thread_id, referenceId("  codex://threads/12345678-1234-4123-8123-123456789ABC/?x=1#y ", &buf).ok);
    try testing.expectEqualStrings(thread_id, referenceId(thread_id, &buf).ok);
    try testing.expectEqualStrings(not_hyphenated, referenceId("123456781234412381231234567890ab", &buf).bad);
    try testing.expectEqualStrings(not_hyphenated, referenceId("{" ++ thread_id ++ "}", &buf).bad);
    try testing.expectEqualStrings(bad_reference, referenceId("https://chatgpt.com/codex/tasks/" ++ thread_id, &buf).bad);
    try testing.expectEqualStrings(bad_reference, referenceId("/Users/synthetic/.codex/sessions/x.jsonl", &buf).bad);
}

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    env: common.TestEnv,
    host: engine_host.EngineHost,

    fn init() !*Fx {
        const gpa = testing.allocator;
        const f = try gpa.create(Fx);
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, testing.io, &f.tmp);
        f.env = try common.TestEnv.init(gpa, f.base);
        f.env.install();
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = testing.io;
        try f.tmp.dir.createDirPath(testing.io, "work");
        return f;
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        f.host.deinit();
        f.env.deinit();
        gpa.free(f.base);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    fn rollout(f: *Fx, sub: []const u8, cwd: []const u8) !void {
        const body = try std.fmt.allocPrint(testing.allocator,
            \\{{"type":"session_meta","payload":{{"id":"{s}","cwd":{f}}}}}
            \\{{"type":"response_item","timestamp":"2026-11-01T08:00:01Z","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"add retries"}}]}}}}
            \\{{"type":"response_item","timestamp":"2026-11-01T08:00:02Z","payload":{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"Retries added."}}]}}}}
            \\
        , .{ thread_id, json.fmt(cwd, .{}) });
        defer testing.allocator.free(body);
        if (std.fs.path.dirname(sub)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = body });
    }

    fn call(f: *Fx, method: []const u8, params_text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        return f.host.handle(method, p.value);
    }

    fn work(f: *Fx) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ f.base, "work" });
    }
};

test "rpcw_codex_conversation preview reads an archived thread without importing it" {
    const f = try Fx.init();
    defer f.deinit();
    const work = try f.work();
    defer testing.allocator.free(work);
    try f.rollout(".codex/archived_sessions/2026/11/01/rollout-2026-11-01T08-00-00-" ++ thread_id ++ ".jsonl", work);
    const out = try f.call("CodexConversationPreview", "{\"reference\":\"codex://threads/" ++ thread_id ++ "\"}");
    defer testing.allocator.free(out.unary_json);
    var p = try json.parseFromSlice(json.Value, testing.allocator, out.unary_json, .{});
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings(thread_id, o.get("id").?.string);
    try testing.expectEqualStrings("add retries", o.get("title").?.string);
    try testing.expectEqualStrings(work, o.get("cwd").?.string);
    try testing.expect(o.get("cwdAvailable").?.bool and o.get("archived").?.bool);
    try testing.expectEqual(@as(i64, 2), o.get("messageCount").?.integer);
    try testing.expectEqualStrings("Retries added.", o.get("lastMessage").?.string);
    try testing.expect(!o.get("alreadyImported").?.bool and o.get("chatId").? == .null);
    try testing.expectEqual(@as(usize, 1), o.get("warnings").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), f.host.chats.items.len);
}

test "rpcw_codex_conversation import creates the chat once and checks the working folder" {
    const f = try Fx.init();
    defer f.deinit();
    const work = try f.work();
    defer testing.allocator.free(work);
    try f.rollout(".codex/sessions/2026/11/01/rollout-a-" ++ thread_id ++ ".jsonl", "/gone/synthetic-folder");

    // The recorded folder is gone: the import needs one that exists.
    try testing.expectEqualStrings(cwd_unavailable, (try f.call("CodexConversationImport", "{\"reference\":\"" ++ thread_id ++ "\"}")).err.exec_error);
    const params = try std.fmt.allocPrint(testing.allocator, "{{\"reference\":\"{s}\",\"cwd\":{f}}}", .{ thread_id, json.fmt(work, .{}) });
    defer testing.allocator.free(params);
    const first = try f.call("CodexConversationImport", params);
    defer testing.allocator.free(first.unary_json);
    try testing.expectEqualStrings("{\"chatId\":\"ext-codex-" ++ thread_id ++ "\",\"alreadyImported\":false}", first.unary_json);
    const chat = findChat(&f.host, "ext-codex-" ++ thread_id).?;
    try testing.expectEqualStrings(work, chat.cwd.?);

    const again = try f.call("CodexConversationImport", params);
    defer testing.allocator.free(again.unary_json);
    try testing.expectEqualStrings("{\"chatId\":\"ext-codex-" ++ thread_id ++ "\",\"alreadyImported\":true}", again.unary_json);
    try testing.expectEqual(@as(usize, 1), f.host.chats.items.len);
    const other = try std.fmt.allocPrint(testing.allocator, "{{\"reference\":\"{s}\",\"cwd\":{f}}}", .{ thread_id, json.fmt(f.base, .{}) });
    defer testing.allocator.free(other);
    try testing.expectEqualStrings(other_folder, (try f.call("CodexConversationImport", other)).err.exec_error);

    // The preview now describes the Harness chat.
    const pv = try f.call("CodexConversationPreview", "{\"reference\":\"" ++ thread_id ++ "\"}");
    defer testing.allocator.free(pv.unary_json);
    try testing.expect(std.mem.indexOf(u8, pv.unary_json, "\"alreadyImported\":true,\"chatId\":\"ext-codex-" ++ thread_id ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, pv.unary_json, "\"messageCount\":2,") != null);
    try testing.expect(std.mem.indexOf(u8, pv.unary_json, "This conversation is already in Harness.") != null);
}

test "rpcw_codex_conversation refuses unknown threads, sub-agent threads and bad references" {
    const f = try Fx.init();
    defer f.deinit();
    try testing.expectEqualStrings(not_found, (try f.call("CodexConversationPreview", "{\"reference\":\"" ++ thread_id ++ "\"}")).err.exec_error);
    try f.tmp.dir.createDirPath(testing.io, ".codex/sessions/x");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = ".codex/sessions/x/rollout-" ++ thread_id ++ ".jsonl", .data = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"" ++ thread_id ++ "\",\"source\":{\"subagent\":{\"review\":true}}}}\n" });
    try testing.expectEqualStrings(not_found, (try f.call("CodexConversationImport", "{\"reference\":\"" ++ thread_id ++ "\"}")).err.exec_error);
    try testing.expectEqualStrings(bad_reference, (try f.call("CodexConversationPreview", "{\"reference\":\"not a thread\"}")).err.exec_error);
    try testing.expectEqualStrings("missing field `reference`", (try f.call("CodexConversationImport", "{}")).err.bad_params);
}
