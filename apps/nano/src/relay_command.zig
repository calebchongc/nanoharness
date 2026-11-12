//! `RelayCommand`: another device hands this host one durable command entry
//! (run, steer, interrupt, respondInput, dismissInput) for a chat it hosts.
//! Port of `DocHost::ingest_relayed_command` (`crates/engine/src/doc_host.rs`)
//! and `evaluate_command` (`crates/doc/src/commands.rs`):
//!
//! 1. pending attachment refs must have landed (else a retryable refusal);
//! 2. evaluate: already processed → `duplicate`; past its TTL → `expired`; an
//!    interrupt with a newer pending interrupt, or aimed at a finished turn →
//!    `superseded`; else execute;
//! 3. claim the entry id in the processed ledger BEFORE executing (a claim
//!    lost to a concurrent delivery is `duplicate`), then execute.
//!
//! The reply is `{"outcome": "executed" | "duplicate" | "expired" | "superseded"}`.
//! Execution goes through the engine's existing turn entry point
//! (`QueueCommand`, see `executeCommand`).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const session_doc = @import("session_doc.zig");

pub const Kind = enum { run, steer, interrupt, respond_input, dismiss_input };

const kind_names = std.StaticStringMap(Kind).initComptime(.{
    .{ "run", .run },
    .{ "steer", .steer },
    .{ "interrupt", .interrupt },
    .{ "respondInput", .respond_input },
    .{ "dismissInput", .dismiss_input },
});

const status_names = std.StaticStringMap(void).initComptime(.{
    .{ "pending", {} },  .{ "applied", {} },    .{ "rejected", {} },
    .{ "expired", {} },  .{ "superseded", {} }, .{ "cancelled", {} },
});

/// A `SessionCommandEntry`, borrowing from the parsed JSON.
pub const Entry = struct {
    id: []const u8,
    kind: Kind,
    payload: json.ObjectMap,
    issued_by: []const u8,
    issued_at: i64,
    expires_at: ?i64 = null,
    based_on_turn_id: ?[]const u8 = null,
    status: []const u8,

    pub fn effectiveExpiry(e: Entry) i64 {
        return e.expires_at orelse e.issued_at + session_doc.command_default_ttl_ms;
    }
};

/// Parses an entry with the fields serde requires (`SessionCommandEntry`,
/// `SessionCommandPayload`, `RunRequest`); null when one is missing or mistyped.
pub fn parseEntry(v: json.Value) ?Entry {
    if (v != .object) return null;
    const o = v.object;
    const id = str(o, "id") orelse return null;
    const payload_v = o.get("payload") orelse return null;
    if (payload_v != .object) return null;
    const payload = payload_v.object;
    const kind = kind_names.get(str(payload, "kind") orelse return null) orelse return null;
    switch (kind) {
        .run => {
            const req = payload.get("request") orelse return null;
            if (req != .object) return null;
            _ = str(req.object, "prompt") orelse return null;
            _ = str(req.object, "cwd") orelse return null;
            _ = str(req.object, "sandbox") orelse return null;
            _ = str(payload, "messageId") orelse return null;
        },
        .steer => {
            _ = str(payload, "prompt") orelse return null;
            if (payload.get("messageId")) |m| if (m != .string and m != .null) return null;
        },
        .interrupt => {},
        .respond_input => {
            _ = str(payload, "requestId") orelse return null;
            const answers = payload.get("answers") orelse return null;
            if (answers != .array) return null;
        },
        .dismiss_input => {
            _ = str(payload, "requestId") orelse return null;
        },
    }
    const status = str(o, "status") orelse return null;
    if (status_names.get(status) == null) return null;
    var entry: Entry = .{
        .id = id,
        .kind = kind,
        .payload = payload,
        .issued_by = str(o, "issuedBy") orelse return null,
        .issued_at = int(o, "issuedAt") orelse return null,
        .status = status,
    };
    if (o.get("expiresAt")) |e| switch (e) {
        .integer => |n| entry.expires_at = n,
        .null => {},
        else => return null,
    };
    if (o.get("basedOn")) |b| switch (b) {
        .object => |bo| if (bo.get("turnId")) |t| switch (t) {
            .string => |s| entry.based_on_turn_id = s,
            .null => {},
            else => return null,
        },
        .null => {},
        else => return null,
    };
    return entry;
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

pub const Disposition = enum { skip, expired, superseded, execute };

pub const Context = struct {
    is_processed: bool,
    now_ms: i64,
    /// Another pending interrupt issued later than this one.
    newer_pending_interrupt: bool,
    /// The turn running (or last run): the newest message id.
    current_turn_id: ?[]const u8,
    /// Whether `based_on_turn_id` names a turn that exists in the doc.
    based_on_turn_is_past: bool,
};

/// Rule 3, `evaluate_command`.
pub fn evaluate(entry: Entry, cx: Context) Disposition {
    if (cx.is_processed) return .skip;
    if (cx.now_ms >= entry.effectiveExpiry()) return .expired;
    if (entry.kind == .interrupt) {
        if (cx.newer_pending_interrupt) return .superseded;
        if (entry.based_on_turn_id) |turn| {
            const is_current = if (cx.current_turn_id) |cur| std.mem.eql(u8, cur, turn) else false;
            if (!is_current and cx.based_on_turn_is_past) return .superseded;
        }
    }
    return .execute;
}

pub const pending_ref_prefix = "pending://";

/// Pending attachment refs a command depends on: a run's `request.attachments`,
/// or a steer prompt's `- pending://…` lines (`missing_attachments`).
pub fn pendingRefs(gpa: Allocator, entry: Entry) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    switch (entry.kind) {
        .run => {
            const req = entry.payload.get("request").?.object;
            if (req.get("attachments")) |a| {
                if (a == .array) {
                    for (a.array.items) |item| {
                        if (item == .string and std.mem.startsWith(u8, item.string, pending_ref_prefix)) try out.append(gpa, item.string);
                    }
                }
            }
        },
        .steer => {
            var lines = std.mem.splitScalar(u8, str(entry.payload, "prompt").?, '\n');
            while (lines.next()) |line| {
                const t = std.mem.trimStart(u8, line, " \t");
                if (!std.mem.startsWith(u8, t, "- ")) continue;
                const path = std.mem.trim(u8, t[2..], " \t\r");
                if (std.mem.startsWith(u8, path, pending_ref_prefix)) try out.append(gpa, path);
            }
        },
        else => {},
    }
    return out.toOwnedSlice(gpa);
}

/// Where this engine's `UploadCommit` put `pending://{uploadId}/{fileName}`:
/// `{uploads}/{uploadId}-{basename(fileName)}`. Null for a malformed ref.
pub fn pendingTargetPath(gpa: Allocator, uploads_dir: []const u8, ref: []const u8) Allocator.Error!?[]u8 {
    const rest = if (std.mem.startsWith(u8, ref, pending_ref_prefix)) ref[pending_ref_prefix.len..] else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const upload_id = rest[0..slash];
    const base = std.fs.path.basename(rest[slash + 1 ..]);
    if (upload_id.len == 0 or base.len == 0 or std.mem.indexOfAny(u8, upload_id, "/\\") != null or std.mem.eql(u8, upload_id, "..")) return null;
    return try std.fmt.allocPrint(gpa, "{s}/{s}-{s}", .{ std.mem.trimEnd(u8, uploads_dir, "/"), upload_id, base });
}

fn uploadsDirAlloc(host: *engine_host.EngineHost) Allocator.Error![]u8 {
    return if (host.data_dir) |dd|
        std.fmt.allocPrint(host.gpa, "{s}/uploads", .{std.mem.trimEnd(u8, dd, "/")})
    else
        host.gpa.dupe(u8, "/tmp/harness-zig-live/uploads");
}

fn attachmentsLanded(host: *engine_host.EngineHost, entry: Entry) !bool {
    const gpa = host.gpa;
    const refs = try pendingRefs(gpa, entry);
    defer gpa.free(refs);
    if (refs.len == 0) return true;
    const io = host.io orelse return false;
    const dir = try uploadsDirAlloc(host);
    defer gpa.free(dir);
    for (refs) |ref| {
        const path = (try pendingTargetPath(gpa, dir, ref)) orelse return false;
        defer gpa.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

/// The `RelayCommand` RPC. Caller holds the host mutex, as for every RPC.
pub fn handle(host: *engine_host.EngineHost, params: json.Value) !engine_host.RpcOutcome {
    const gpa = host.gpa;
    if (params != .object) return .{ .err = .{ .bad_params = "expected object" } };
    const chat_v = params.object.get("chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
    if (chat_v != .string) return .{ .err = .{ .bad_params = "missing chatId" } };
    const chat_id = chat_v.string;
    const entry = parseEntry(params.object.get("entry") orelse .null) orelse
        return .{ .err = .{ .bad_params = "invalid entry" } };

    const doc = try host.getOrCreateDoc(chat_id);
    // The sender sequences attachment transfers before the relay; refuse
    // (retryably) rather than run without them.
    if (!try attachmentsLanded(host, entry)) return .{ .err = .{ .exec_error = "attachments not landed yet" } };

    const now = host.nowMs();
    var newer_interrupt = false;
    for (doc.commands.items) |c| {
        if (!std.mem.eql(u8, c.id, entry.id) and std.mem.eql(u8, c.kind, "interrupt") and
            std.mem.eql(u8, c.status, "pending") and c.issued_at > entry.issued_at) newer_interrupt = true;
    }
    const msgs = doc.messages.items;
    var turn_past = false;
    if (entry.based_on_turn_id) |turn| {
        for (msgs) |m| {
            if (std.mem.eql(u8, m.id, turn)) {
                turn_past = true;
                break;
            }
        }
    }
    const disposition = evaluate(entry, .{
        .is_processed = host.store.isCommandProcessed(entry.id),
        .now_ms = now,
        .newer_pending_interrupt = newer_interrupt,
        .current_turn_id = if (msgs.len > 0) msgs[msgs.len - 1].id else null,
        .based_on_turn_is_past = turn_past,
    });
    if (disposition == .skip) return outcome(gpa, "duplicate");
    // Claim BEFORE executing: the ledger is the exactly-once key.
    if (!try host.store.markCommandProcessed(entry.id, now)) return outcome(gpa, "duplicate");
    switch (disposition) {
        .skip => unreachable,
        .expired => return outcome(gpa, "expired"),
        .superseded => return outcome(gpa, "superseded"),
        .execute => {},
    }
    var result = try executeCommand(host, chat_id, entry);
    switch (result) {
        .err => return result,
        .unary_json => |body| gpa.free(body),
        .stream_items_json => |*st| st.deinit(gpa),
    }
    return outcome(gpa, "executed");
}

fn outcome(gpa: Allocator, name: []const u8) !engine_host.RpcOutcome {
    return .{ .unary_json = try std.fmt.allocPrint(gpa, "{{\"outcome\":\"{s}\"}}", .{name}) };
}

/// Runs the command through the engine's turn entry point: `QueueCommand`,
/// whose run, steer, interrupt and answer kinds go to `turn_host.zig`.
fn executeCommand(host: *engine_host.EngineHost, chat_id: []const u8, entry: Entry) !engine_host.RpcOutcome {
    const gpa = host.gpa;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const p = entry.payload;
    switch (entry.kind) {
        .run => try w.print("{{\"kind\":\"run\",\"messageId\":{f},\"request\":{f}}}", .{
            json.fmt(str(p, "messageId").?, .{}),
            json.fmt(p.get("request").?, .{}),
        }),
        // The engine's steer path keys its own dedupe on the message id; a
        // steer without one uses the entry id so distinct steers never collide.
        .steer => try w.print("{{\"kind\":\"steer\",\"messageId\":{f},\"prompt\":{f}}}", .{
            json.fmt(str(p, "messageId") orelse entry.id, .{}),
            json.fmt(str(p, "prompt").?, .{}),
        }),
        .interrupt => try w.writeAll("{\"kind\":\"interrupt\"}"),
        .respond_input => try w.print("{{\"kind\":\"respondInput\",\"requestId\":{f},\"answers\":{f}}}", .{
            json.fmt(str(p, "requestId").?, .{}),
            json.fmt(p.get("answers").?, .{}),
        }),
        .dismiss_input => try w.print("{{\"kind\":\"dismissInput\",\"requestId\":{f}}}", .{json.fmt(str(p, "requestId").?, .{})}),
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: json.ObjectMap = .empty;
    try obj.put(a, "chatId", .{ .string = chat_id });
    try obj.put(a, "command", try json.parseFromSliceLeaky(json.Value, a, aw.written(), .{}));
    return host.handleWithId(0, "QueueCommand", .{ .object = obj });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parsed(text: []const u8) !json.Parsed(json.Value) {
    return json.parseFromSlice(json.Value, testing.allocator, text, .{});
}

test "relay command: entries parse with the fields serde requires" {
    var ok = try parsed(
        \\{"id":"c1","payload":{"kind":"run","messageId":"m1","request":{"prompt":"hi","cwd":"/w","sandbox":"workspaceWrite","model":null}},
        \\ "issuedBy":"dev-b","issuedAt":1000,"status":"pending","basedOn":{"turnId":"t1","frontier":null}}
    );
    defer ok.deinit();
    const e = parseEntry(ok.value).?;
    try testing.expectEqual(Kind.run, e.kind);
    try testing.expectEqualStrings("t1", e.based_on_turn_id.?);
    try testing.expectEqual(@as(i64, 1000 + session_doc.command_default_ttl_ms), e.effectiveExpiry());

    const bad = [_][]const u8{
        \\{"id":"c1","payload":{"kind":"run","messageId":"m1","request":{"prompt":"hi","cwd":"/w"}},"issuedBy":"d","issuedAt":1,"status":"pending"}
        ,
        \\{"id":"c1","payload":{"kind":"steer","prompt":"x"},"issuedBy":"d","issuedAt":1,"status":"done"}
        ,
        \\{"id":"c1","payload":{"kind":"teleport"},"issuedBy":"d","issuedAt":1,"status":"pending"}
        ,
        \\{"id":"c1","payload":{"kind":"interrupt"},"issuedAt":1,"status":"pending"}
        ,
        \\{"id":"c1","payload":{"kind":"respondInput","requestId":"r"},"issuedBy":"d","issuedAt":1,"status":"pending"}
    };
    for (bad) |text| {
        var p = try parsed(text);
        defer p.deinit();
        try testing.expect(parseEntry(p.value) == null);
    }
    var steer = try parsed(
        \\{"id":"c2","payload":{"kind":"steer","prompt":"go","turnOrigin":"human"},"issuedBy":"d","issuedAt":5,"expiresAt":10,"status":"pending"}
    );
    defer steer.deinit();
    const s = parseEntry(steer.value).?;
    try testing.expectEqual(@as(i64, 10), s.effectiveExpiry());
}

test "relay command: evaluate follows evaluate_command" {
    var p = try parsed(
        \\{"id":"i1","payload":{"kind":"interrupt"},"issuedBy":"d","issuedAt":1000,"status":"pending","basedOn":{"turnId":"t-old"}}
    );
    defer p.deinit();
    const intr = parseEntry(p.value).?;
    const base: Context = .{ .is_processed = false, .now_ms = 2000, .newer_pending_interrupt = false, .current_turn_id = "t-now", .based_on_turn_is_past = false };
    try testing.expectEqual(Disposition.execute, evaluate(intr, base));
    var cx = base;
    cx.is_processed = true;
    try testing.expectEqual(Disposition.skip, evaluate(intr, cx));
    cx = base;
    cx.now_ms = 1000 + session_doc.command_default_ttl_ms;
    try testing.expectEqual(Disposition.expired, evaluate(intr, cx));
    cx = base;
    cx.newer_pending_interrupt = true;
    try testing.expectEqual(Disposition.superseded, evaluate(intr, cx));
    cx = base;
    cx.based_on_turn_is_past = true;
    try testing.expectEqual(Disposition.superseded, evaluate(intr, cx));
    cx.current_turn_id = "t-old"; // aimed at the running turn: still live
    try testing.expectEqual(Disposition.execute, evaluate(intr, cx));

    var st = try parsed(
        \\{"id":"s1","payload":{"kind":"steer","prompt":"a"},"issuedBy":"d","issuedAt":1000,"status":"pending"}
    );
    defer st.deinit();
    cx = base;
    cx.newer_pending_interrupt = true;
    try testing.expectEqual(Disposition.execute, evaluate(parseEntry(st.value).?, cx));
}

test "relay command: pending refs and where they land" {
    var p = try parsed(
        \\{"id":"s1","payload":{"kind":"steer","prompt":"look\nAttached images:\n- pending://up-1/shot.png\n- /abs/other.png"},"issuedBy":"d","issuedAt":1,"status":"pending"}
    );
    defer p.deinit();
    const refs = try pendingRefs(testing.allocator, parseEntry(p.value).?);
    defer testing.allocator.free(refs);
    try testing.expectEqual(@as(usize, 1), refs.len);
    const path = (try pendingTargetPath(testing.allocator, "/d/uploads/", refs[0])).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/d/uploads/up-1-shot.png", path);
    try testing.expect((try pendingTargetPath(testing.allocator, "/d", "pending://../x")) == null);
    try testing.expect((try pendingTargetPath(testing.allocator, "/d", "file:///x")) == null);
}

test "relay command: executes once through the engine, then reports duplicate" {
    const gpa = testing.allocator;
    var host = try engine_host.EngineHost.init(gpa, "dev-host", "Host");
    defer host.deinit();
    const now = host.nowMs();
    const run_text = try std.fmt.allocPrint(gpa,
        \\{{"chatId":"chat-r","entry":{{"id":"cmd-1","payload":{{"kind":"run","messageId":"m-1","request":{{"prompt":"from the phone","cwd":".","sandbox":"workspaceWrite"}}}},"issuedBy":"dev-phone","issuedAt":{d},"status":"pending"}}}}
    , .{now});
    defer gpa.free(run_text);
    var params = try parsed(run_text);
    defer params.deinit();

    const first = try handle(&host, params.value);
    try testing.expectEqualStrings("{\"outcome\":\"executed\"}", first.unary_json);
    gpa.free(first.unary_json);
    const doc = host.docs.getPtr("chat-r").?;
    var saw_user = false;
    var saw_reply = false;
    for (doc.messages.items) |m| {
        for (m.parts.items) |part| {
            if (std.mem.indexOf(u8, part.text.items, "from the phone") != null) {
                if (std.mem.eql(u8, m.id, "m-1")) saw_user = true else saw_reply = true;
            }
        }
    }
    try testing.expect(saw_user);
    try testing.expect(saw_reply); // no agent configured: the engine's own acknowledgement

    const again = try handle(&host, params.value);
    try testing.expectEqualStrings("{\"outcome\":\"duplicate\"}", again.unary_json);
    gpa.free(again.unary_json);

    // An expired entry is claimed and reported, never run.
    const old_text = try std.fmt.allocPrint(gpa,
        \\{{"chatId":"chat-r","entry":{{"id":"cmd-old","payload":{{"kind":"steer","prompt":"stale"}},"issuedBy":"dev-phone","issuedAt":{d},"status":"pending"}}}}
    , .{now - session_doc.command_default_ttl_ms - 1});
    defer gpa.free(old_text);
    var old = try parsed(old_text);
    defer old.deinit();
    const expired = try handle(&host, old.value);
    try testing.expectEqualStrings("{\"outcome\":\"expired\"}", expired.unary_json);
    gpa.free(expired.unary_json);
    try testing.expect(host.store.isCommandProcessed("cmd-old"));

    // A bad entry is a parameter error.
    var bad = try parsed("{\"chatId\":\"chat-r\",\"entry\":{\"id\":\"x\"}}");
    defer bad.deinit();
    const refused = try handle(&host, bad.value);
    try testing.expect(refused == .err);

    // A run whose attachment hasn't landed is refused, and stays unclaimed.
    const att_text = try std.fmt.allocPrint(gpa,
        \\{{"chatId":"chat-r","entry":{{"id":"cmd-att","payload":{{"kind":"run","messageId":"m-att","request":{{"prompt":"see","cwd":".","sandbox":"workspaceWrite","attachments":["pending://up-missing/a.png"]}}}},"issuedBy":"dev-phone","issuedAt":{d},"status":"pending"}}}}
    , .{now});
    defer gpa.free(att_text);
    var att = try parsed(att_text);
    defer att.deinit();
    const waiting = try handle(&host, att.value);
    try testing.expectEqualStrings("attachments not landed yet", waiting.err.exec_error);
    try testing.expect(!host.store.isCommandProcessed("cmd-att"));
}
