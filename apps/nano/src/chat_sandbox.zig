//! A chat's `config.sandbox` (`harness_proto::SandboxLevel`, kebab-case on the
//! wire), as `harness_proto::ChatConfig` carries it: read from `createChat` /
//! `setChatConfig` and from synced chat rows, and written back wherever the
//! Rust engine writes the chat's config (the chat list, the edge chat row and
//! the registry cache).
//!
//! What a run may do is still the device's autonomy, as in Rust
//! (`Autonomy::apply` in `Sessions::dispatch` overrides any sandbox a request
//! or row names); the chat keeps the sandbox it was created with so every
//! reader of its config sees it.
const std = @import("std");
const json = std.json;

pub const Sandbox = enum {
    read_only,
    workspace_write,
    danger_full_access,

    pub fn wire(self: Sandbox) []const u8 {
        return switch (self) {
            .read_only => "read-only",
            .workspace_write => "workspace-write",
            .danger_full_access => "danger-full-access",
        };
    }

    pub fn parse(text: []const u8) ?Sandbox {
        inline for (.{ Sandbox.read_only, Sandbox.workspace_write, Sandbox.danger_full_access }) |s| {
            if (std.mem.eql(u8, text, s.wire())) return s;
        }
        return null;
    }
};

pub const Parsed = union(enum) {
    absent,
    ok: Sandbox,
    /// serde's refusal of the value.
    bad: []const u8,
};

const unknown_variant = "unknown variant, expected one of `read-only`, `workspace-write`, `danger-full-access`";

/// `config.sandbox` from a client's config object.
pub fn fromConfig(cfg: json.ObjectMap) Parsed {
    const v = cfg.get("sandbox") orelse return .absent;
    if (v == .null) return .absent;
    if (v != .string) return .{ .bad = "invalid type: expected a string for `sandbox`" };
    return if (Sandbox.parse(v.string)) |s| .{ .ok = s } else .{ .bad = unknown_variant };
}

/// `config.sandbox` from a synced or cached chat row: anything unreadable
/// counts as absent, as the row reader treats its other optional fields.
pub fn fromRow(cfg: ?json.ObjectMap) ?Sandbox {
    const c = cfg orelse return null;
    return switch (fromConfig(c)) {
        .ok => |s| s,
        else => null,
    };
}

/// The `,"sandbox":"…"` member a config object gains, or nothing when the
/// chat has none recorded.
pub fn member(s: ?Sandbox) []const u8 {
    const v = s orelse return "";
    return switch (v) {
        .read_only => ",\"sandbox\":\"read-only\"",
        .workspace_write => ",\"sandbox\":\"workspace-write\"",
        .danger_full_access => ",\"sandbox\":\"danger-full-access\"",
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const engine_host = @import("engine_host.zig");

test "chat_sandbox parses the three levels and refuses others" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ?Sandbox }{
        .{ "{\"sandbox\":\"read-only\"}", .read_only },
        .{ "{\"sandbox\":\"workspace-write\"}", .workspace_write },
        .{ "{\"sandbox\":\"danger-full-access\"}", .danger_full_access },
    };
    for (cases) |c| {
        const v = try json.parseFromSliceLeaky(json.Value, a, c[0], .{});
        try testing.expectEqual(c[1].?, fromConfig(v.object).ok);
        try testing.expectEqual(c[1], fromRow(v.object));
    }
    const absent = try json.parseFromSliceLeaky(json.Value, a, "{\"harness\":\"mock\"}", .{});
    try testing.expect(fromConfig(absent.object) == .absent);
    const bad = try json.parseFromSliceLeaky(json.Value, a, "{\"sandbox\":\"yolo\"}", .{});
    try testing.expectEqualStrings(unknown_variant, fromConfig(bad.object).bad);
    try testing.expect(fromRow(bad.object) == null);
    const wrong_type = try json.parseFromSliceLeaky(json.Value, a, "{\"sandbox\":3}", .{});
    try testing.expect(fromConfig(wrong_type.object) == .bad);
    try testing.expectEqualStrings("", member(null));
    try testing.expectEqualStrings(",\"sandbox\":\"read-only\"", member(.read_only));
}

fn mutate(host: *engine_host.EngineHost, params_text: []const u8) !engine_host.RpcOutcome {
    var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
    defer p.deinit();
    return host.handle("Mutate", p.value);
}

fn chatConfigSandbox(host: *engine_host.EngineHost, chat_id: []const u8) !?[]const u8 {
    const list = try host.chatsJson();
    defer testing.allocator.free(list);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, list, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |row| {
        const id = row.object.get("id").?.string;
        if (!std.mem.eql(u8, id, chat_id)) continue;
        const cfg = row.object.get("config") orelse return null;
        const s = cfg.object.get("sandbox") orelse return null;
        return Sandbox.parse(s.string).?.wire();
    }
    return error.ChatMissing;
}

test "chat_sandbox createChat keeps config.sandbox and the chat list returns it" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    const created = try mutate(&host, "{\"op\":\"createChat\",\"chatId\":\"chat-ro\",\"config\":{\"harness\":\"mock\",\"modelOptions\":{},\"sandbox\":\"read-only\"}}");
    testing.allocator.free(created.unary_json);
    try testing.expectEqualStrings("read-only", (try chatConfigSandbox(&host, "chat-ro")).?);

    // setChatConfig with a new sandbox replaces it; one without keeps it.
    const set1 = try mutate(&host, "{\"op\":\"setChatConfig\",\"chatId\":\"chat-ro\",\"config\":{\"harness\":\"mock\",\"reasoning\":\"low\"}}");
    testing.allocator.free(set1.unary_json);
    try testing.expectEqualStrings("read-only", (try chatConfigSandbox(&host, "chat-ro")).?);
    const set2 = try mutate(&host, "{\"op\":\"setChatConfig\",\"chatId\":\"chat-ro\",\"config\":{\"harness\":\"mock\",\"sandbox\":\"danger-full-access\"}}");
    testing.allocator.free(set2.unary_json);
    try testing.expectEqualStrings("danger-full-access", (try chatConfigSandbox(&host, "chat-ro")).?);

    // A chat created without one has none to report.
    const plain = try mutate(&host, "{\"op\":\"createChat\",\"chatId\":\"chat-plain\",\"config\":{\"harness\":\"mock\"}}");
    testing.allocator.free(plain.unary_json);
    try testing.expect((try chatConfigSandbox(&host, "chat-plain")) == null);
}

test "chat_sandbox createChat and setChatConfig refuse an unknown sandbox" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    const bad = try mutate(&host, "{\"op\":\"createChat\",\"chatId\":\"chat-x\",\"config\":{\"harness\":\"mock\",\"sandbox\":\"everything\"}}");
    try testing.expectEqualStrings(unknown_variant, bad.err.bad_params);
    try testing.expectError(error.ChatMissing, chatConfigSandbox(&host, "chat-x"));
    const created = try mutate(&host, "{\"op\":\"createChat\",\"chatId\":\"chat-y\",\"config\":{\"harness\":\"mock\",\"sandbox\":\"workspace-write\"}}");
    testing.allocator.free(created.unary_json);
    const bad_set = try mutate(&host, "{\"op\":\"setChatConfig\",\"chatId\":\"chat-y\",\"config\":{\"harness\":\"mock\",\"sandbox\":7}}");
    try testing.expectEqualStrings("invalid type: expected a string for `sandbox`", bad_set.err.bad_params);
    try testing.expectEqualStrings("workspace-write", (try chatConfigSandbox(&host, "chat-y")).?);
}

test "chat_sandbox the edge chat row carries config.sandbox and a synced row brings it back" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-synthetic", "Synthetic");
    defer host.deinit();
    const created = try mutate(&host, "{\"op\":\"createChat\",\"chatId\":\"chat-edge-ro\",\"config\":{\"harness\":\"mock\",\"sandbox\":\"read-only\"}}");
    testing.allocator.free(created.unary_json);
    var found = false;
    for (host.pending_registry_ops.items) |op| {
        if (std.mem.indexOf(u8, op, "\"kind\":\"chats\"") == null) continue;
        if (std.mem.indexOf(u8, op, "\"chat-edge-ro\"") == null) continue;
        try testing.expect(std.mem.indexOf(u8, op, "\"reasoning\":\"high\",\"sandbox\":\"read-only\"}") != null);
        found = true;
    }
    try testing.expect(found);

    const rows =
        \\{"seq":3,"rows":[{"kind":"chats","id":"chat-peer-ws","deleted":false,"fields":{"id":"chat-peer-ws","deviceId":"dev-peer","title":"Synthetic peer chat","archived":false,"createdAt":1794333000000,"config":{"harness":"codex","model":null,"reasoning":null,"sandbox":"workspace-write"}}}]}
    ;
    _ = host.applyRegistryResponseJson("org-synthetic", rows, false);
    try testing.expectEqualStrings("workspace-write", (try chatConfigSandbox(&host, "chat-peer-ws")).?);
}
