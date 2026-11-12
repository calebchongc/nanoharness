//! Retained Loro over chat2's existing HTTPS pull/push transport. No wire
//! changes. Network I/O is outside the engine lock; document/ABI operations
//! and atomic SQLite snapshot+cursor commits are serialized under it.
const std = @import("std");
const json = std.json;
const Host = @import("engine_host.zig").EngineHost;
const auth = @import("auth_host.zig");
const wire = @import("chat2_wire.zig");
const Client = @import("chat2_client.zig").Chat2RoomClient;
const loro = @import("loro.zig");
const Job = struct { batch: []const u8, bytes: []const u8 };

pub fn sync(host: *Host, io: std.Io) !void {
    if (!loro.enabled) return;
    var arena = std.heap.ArenaAllocator.init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    var edge: []const u8 = undefined;
    var token: []const u8 = undefined;
    var device: []const u8 = undefined;
    var generation: u64 = 0;
    {
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (host.stop_requested or !host.auth.signed_in or host.auth.edge_url == null) return;
        edge = try a.dupe(u8, host.auth.edge_url.?);
        token = try a.dupe(u8, host.auth.ensureAccessToken(io, false) orelse return);
        device = try a.dupe(u8, host.device_id);
        generation = host.auth.generation;
        for (host.chats.items) |chat| try ids.append(a, try a.dupe(u8, chat.id));
    }
    for (ids.items) |cid| {
        if (host.stop_requested) return;
        syncOne(host, io, a, edge, token, device, generation, cid) catch |err| {
            std.log.warn("chat2 Loro sync failed: {s}", .{@errorName(err)});
        };
    }
}

fn authorized(host: *Host, generation: u64) bool {
    return !host.stop_requested and host.auth.signed_in and host.auth.generation == generation;
}

fn request(host: *Host, io: std.Io, method: []const u8, url: []const u8, token: []const u8, headers: []const @import("http_zig").Header, body: ?[]const u8) !auth.AuthManager.EdgeReply {
    return auth.AuthManager.edgeRequestTimed(&host.auth.h2_pool, host.gpa, io, method, url, token, headers, body, 5_000);
}

fn save(host: *Host, cid: []const u8) !void {
    const doc = try host.getOrCreateDoc(cid);
    const bytes = try doc.exportPersisted(host.gpa);
    defer host.gpa.free(bytes);
    try host.store.saveSnapshot(cid, bytes, host.nowMs());
}

fn syncOne(host: *Host, io: std.Io, a: std.mem.Allocator, edge: []const u8, token: []const u8, device: []const u8, generation: u64, cid: []const u8) !void {
    const enc = try auth.urlEncodeAlloc(a, cid);
    const dev = try auth.urlEncodeAlloc(a, device);
    const base = try std.fmt.allocPrint(a, "{s}/chat2/{s}", .{ std.mem.trimEnd(u8, edge, "/"), enc });
    var jobs: std.ArrayList(Job) = .empty;
    {
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (!authorized(host, generation)) return;
        const doc = try host.getOrCreateDoc(cid);
        const update = try doc.outgoingLoroUpdate(a);
        if (update.len > 0) {
            if (update.len > 1024 * 1024 - 4096) return error.LoroUpdateTooLarge;
            var rnd: [16]u8 = undefined;
            io.random(&rnd);
            const batch = try std.fmt.allocPrint(a, "nano-{s}", .{std.fmt.bytesToHex(rnd, .lower)});
            // Queue DURABLY before clearing the local unsent frontier. A crash
            // between these writes can duplicate ops, never lose them.
            try host.store.enqueueChatUpdate(cid, batch, update);
            try doc.outgoingLoroQueued();
            try save(host, cid);
        }
        for (host.store.outbox.items) |item| {
            if (std.mem.eql(u8, item.doc_id, cid) and !item.needs_checkpoint) {
                if (!@import("session_doc.zig").isRustLoroBlob(item.bytes)) return error.LegacyOutboxNeedsMigration;
                try jobs.append(a, .{ .batch = try a.dupe(u8, item.batch_id), .bytes = try a.dupe(u8, item.bytes) });
            }
        }
    }
    for (jobs.items) |job| {
        const batch = try auth.urlEncodeAlloc(a, job.batch);
        const url = try std.fmt.allocPrint(a, "{s}/rows?device={s}&batchId={s}", .{ base, dev, batch });
        var reply = try request(host, io, "POST", url, token, &.{.{ .name = "content-type", .value = "application/octet-stream" }}, job.bytes);
        defer reply.deinit(host.gpa);
        if (reply.status != 200) return error.LoroPushRefused;
        var hdr = try json.parseFromSlice(json.Value, a, reply.body, .{});
        defer hdr.deinit();
        const frame = try wire.encodeValue(a, wire.FrameType.ack, hdr.value, "");
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (!authorized(host, generation)) return;
        const doc = try host.getOrCreateDoc(cid);
        var client = Client{ .gpa = host.gpa, .doc_id = cid, .doc = doc, .store = &host.store };
        _ = try client.handleServerFrame(frame, host.nowMs());
    }

    var server_head: u64 = 0;
    var checkpoint_seq: u64 = 0;
    // A checkpoint repair changes the requested cursor; bounded loops prevent
    // a corrupt/missing dependency cycle from holding the background worker.
    for (0..3) |_| {
        var cursor: u64 = 0;
        {
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            if (!authorized(host, generation)) return;
            cursor = host.store.snapshotCursor(cid) orelse 0;
        }
        const url = try std.fmt.allocPrint(a, "{s}/rows?after={d}", .{ base, cursor });
        var reply = try request(host, io, "GET", url, token, &.{}, null);
        defer reply.deinit(host.gpa);
        if (reply.status != 200) return error.LoroRowsRefused;
        var pos: usize = 0;
        var observed = cursor;
        var repair = false;
        while (pos < reply.body.len) {
            if (reply.body.len - pos < 4) return error.TruncatedChat2Frame;
            const len = std.mem.readInt(u32, reply.body[pos..][0..4], .little);
            pos += 4;
            if (len > reply.body.len - pos) return error.TruncatedChat2Frame;
            const bytes = reply.body[pos..][0..len];
            pos += len;
            var decoded = wire.decode(a, bytes) orelse return error.InvalidChat2Frame;
            defer decoded.deinit(a);
            if (decoded.kind == wire.FrameType.state) {
                const h = decoded.header_parsed.value.object;
                server_head = @intCast(h.get("headSeq").?.integer);
                checkpoint_seq = @intCast(h.get("checkpointSeq").?.integer);
                var needs_checkpoint = false;
                {
                    host.mutex.lockUncancelable(io);
                    defer host.mutex.unlock(io);
                    if (!authorized(host, generation)) return;
                    const doc = try host.getOrCreateDoc(cid);
                    var client = Client{ .gpa = host.gpa, .doc_id = cid, .doc = doc, .store = &host.store };
                    const outcome = try client.handleServerFrame(bytes, host.nowMs());
                    needs_checkpoint = outcome.catch_up_plan == .checkpoint_then_rows;
                    if (outcome.catch_up_plan == .rows_only) {
                        const after = outcome.catch_up_plan.rows_only.after;
                        if (after != (host.store.snapshotCursor(cid) orelse 0)) {
                            // Verified VV containment permits skipping a pruned
                            // prefix; an ahead-of-server cursor resets instead.
                            const state = try doc.exportPersisted(a);
                            try host.store.saveSnapshotWithCursor(cid, state, after, 2, host.nowMs());
                            repair = true;
                        }
                    }
                }
                if (needs_checkpoint) {
                    const cp_url = try std.fmt.allocPrint(a, "{s}/checkpoint", .{base});
                    var cp = try request(host, io, "GET", cp_url, token, &.{}, null);
                    defer cp.deinit(host.gpa);
                    if (cp.status != 200) return error.LoroCheckpointRefused;
                    host.mutex.lockUncancelable(io);
                    defer host.mutex.unlock(io);
                    if (!authorized(host, generation)) return;
                    const doc = try host.getOrCreateDoc(cid);
                    doc.importSnapshot(cp.body) catch |err| {
                        if (err == error.PendingDependencies) try save(host, cid);
                        return err;
                    };
                    if (try doc.hasPendingLoro()) return error.PendingDependencies;
                    const state = try doc.exportPersisted(a);
                    try host.store.saveSnapshotWithCursor(cid, state, checkpoint_seq, 2, host.nowMs());
                    const transcript = try doc.toResetFrameJson(a);
                    try host.broadcastWatch(.doc_messages, cid, transcript);
                    const queue = try doc.toQueueFrameJson(a);
                    try host.broadcastWatch(.queue, cid, queue);
                    repair = true;
                    break;
                }
            } else if (decoded.kind == wire.FrameType.row) {
                host.mutex.lockUncancelable(io);
                defer host.mutex.unlock(io);
                if (!authorized(host, generation)) return;
                const doc = try host.getOrCreateDoc(cid);
                var client = Client{ .gpa = host.gpa, .doc_id = cid, .doc = doc, .store = &host.store, .received_cursor = observed };
                _ = client.handleServerFrame(bytes, host.nowMs()) catch |err| {
                    if (err == error.PendingDependencies) {
                        // Keep reading contiguous transport rows: a later row
                        // may carry the missing prerequisite. Applied cursor
                        // remains held until ALL parked imports resolve.
                        observed = client.received_cursor orelse observed;
                        repair = true;
                        continue;
                    }
                    return err;
                };
                observed = client.received_cursor orelse observed;
                const frame = try doc.toResetFrameJson(a);
                try host.broadcastWatch(.doc_messages, cid, frame);
                const queue = try doc.toQueueFrameJson(a);
                try host.broadcastWatch(.queue, cid, queue);
            }
        }
        if (!repair) break;
    }
    // Only the designated host drains durable document commands. Native run/
    // steer already mark the processed ledger BEFORE execution; replay cannot
    // run the same id again, including after a process restart.
    {
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (!authorized(host, generation)) return;
        try executeCommands(host, cid, a);
    }
    // A verified, caught-up host can compact. Never cover pending causal
    // imports, unacknowledged updates, or local operations not yet queued.
    var snapshot: ?[]u8 = null;
    var frontier: ?[]u8 = null;
    var covered: u64 = 0;
    {
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (!authorized(host, generation)) return;
        var owner = false;
        for (host.chats.items) |chat| if (std.mem.eql(u8, chat.id, cid)) {
            owner = std.mem.eql(u8, chat.device_id, host.device_id);
            break;
        };
        const doc = try host.getOrCreateDoc(cid);
        covered = host.store.snapshotCursor(cid) orelse 0;
        if (owner and covered == server_head and covered >= checkpoint_seq + 4 and !host.store.hasPendingChatUpdates(cid) and !(try doc.hasPendingLoro())) {
            const unsent = try doc.outgoingLoroUpdate(a);
            if (unsent.len == 0) {
                snapshot = try doc.exportSnapshot(a);
                frontier = try doc.exportFrontier(a);
            }
        }
    }
    if (snapshot) |bytes| {
        const b64 = std.base64.standard.Encoder;
        const encoded = try a.alloc(u8, b64.calcSize(frontier.?.len));
        _ = b64.encode(encoded, frontier.?);
        const url = try std.fmt.allocPrint(a, "{s}/checkpoint?seqCovered={d}", .{ base, covered });
        var cp = try request(host, io, "POST", url, token, &.{ .{ .name = "x-chat2-frontier", .value = encoded }, .{ .name = "content-type", .value = "application/octet-stream" } }, bytes);
        defer cp.deinit(host.gpa);
        if (cp.status != 200) return error.LoroCheckpointPublishRefused;
    }
}

fn executeCommands(host: *Host, cid: []const u8, a: std.mem.Allocator) !void {
    var owner = false;
    for (host.chats.items) |chat| if (std.mem.eql(u8, chat.id, cid)) {
        owner = std.mem.eql(u8, chat.device_id, host.device_id);
        break;
    };
    if (!owner) return;
    const doc = try host.getOrCreateDoc(cid);
    // Rust evaluates the retained command rules and preserves expiry/basedOn.
    const core = doc.loro_doc orelse return;
    const now = try std.fmt.allocPrint(a, "{d}", .{host.nowMs()});
    const commands = try core.bytes(a, 14, now);
    var parsed = try json.parseFromSlice(json.Value, a, commands, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |entry| {
        const co = entry.object;
        const id = co.get("id").?.string;
        if (host.store.isCommandProcessed(id)) {
            try (try host.getOrCreateDoc(cid)).setCommandStatus(id, "applied");
            try save(host, cid);
            continue;
        }
        const disposition = co.get("disposition").?.string;
        if (!std.mem.eql(u8, disposition, "execute")) {
            if (std.mem.eql(u8, disposition, "expired") or std.mem.eql(u8, disposition, "superseded")) {
                try (try host.getOrCreateDoc(cid)).setCommandStatus(id, disposition);
                try save(host, cid);
            }
            continue;
        }
        const payload = co.get("payload").?;
        const kind = payload.object.get("kind").?.string;
        if (!std.mem.eql(u8, kind, "run") and !std.mem.eql(u8, kind, "steer")) {
            _ = try host.store.markCommandProcessed(id, host.nowMs());
        }
        const params_text = try std.fmt.allocPrint(a, "{{\"chatId\":{f},\"command\":{f}}}", .{ json.fmt(cid, .{}), json.fmt(payload, .{}) });
        var params = try json.parseFromSlice(json.Value, a, params_text, .{});
        defer params.deinit();
        const outcome = try host.handle("QueueCommand", params.value);
        switch (outcome) {
            .unary_json => |bytes| host.gpa.free(bytes),
            .err => return error.LoroCommandRejected,
            else => return error.UnexpectedCommandReply,
        }
        _ = try host.store.markCommandProcessed(id, host.nowMs());
        try (try host.getOrCreateDoc(cid)).setCommandStatus(id, "applied");
        // Persist outcome/current document before another replay observes it.
        try save(host, cid);
    }
}
