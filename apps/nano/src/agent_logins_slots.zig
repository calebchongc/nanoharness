//! Saved logins for the agent-accounts registry: a port of the config, slot
//! storage and credential-file parsing in `crates/engine/src/agent_accounts.rs`.
//!
//! One slot per account: `{data_dir}/agent-accounts/{harness}/{slotId}.json`,
//! written atomically and owner-only (they hold live tokens), listed in
//! creation order (`createdAt`, never `savedAt`, so switching never reorders).
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const util = @import("agent_logins_util.zig");
const catalog_core = @import("catalog_core.zig");
const Harness = util.Harness;

/// `AgentAccountsConfig`.
pub const Config = struct {
    data_dir: []const u8,
    claude_config_dir: []const u8,
    claude_config_file: []const u8,
    codex_home: []const u8,
    cursor_sdk_auth_file: []const u8,
    graff_home: []const u8,

    /// `AgentAccountsConfig::detect` from `env` (allocated in `a`):
    /// `CLAUDE_CONFIG_DIR` relocates the Claude dir and its `.claude.json`,
    /// `CODEX_HOME` the Codex home.
    pub fn detect(a: Allocator, io: Io, data_dir: []const u8, env: *const Environ.Map) !Config {
        const home = try catalog_core.homeOrCwd(a, io, env);
        const claude_dir: ?[]const u8 = if (env.get("CLAUDE_CONFIG_DIR")) |d| (if (d.len > 0) d else null) else null;
        const codex: ?[]const u8 = if (env.get("CODEX_HOME")) |d| (if (d.len > 0) d else null) else null;
        return .{
            .data_dir = try a.dupe(u8, data_dir),
            .claude_config_dir = if (claude_dir) |d| try a.dupe(u8, d) else try std.fs.path.join(a, &.{ home, ".claude" }),
            .claude_config_file = try std.fs.path.join(a, &.{ claude_dir orelse home, ".claude.json" }),
            .codex_home = if (codex) |d| try a.dupe(u8, d) else try std.fs.path.join(a, &.{ home, ".codex" }),
            .cursor_sdk_auth_file = try std.fs.path.join(a, &.{ home, ".cursor", "sdk", "auth.json" }),
            .graff_home = home,
        };
    }

    pub fn clone(c: Config, a: Allocator) !Config {
        return .{
            .data_dir = try a.dupe(u8, c.data_dir),
            .claude_config_dir = try a.dupe(u8, c.claude_config_dir),
            .claude_config_file = try a.dupe(u8, c.claude_config_file),
            .codex_home = try a.dupe(u8, c.codex_home),
            .cursor_sdk_auth_file = try a.dupe(u8, c.cursor_sdk_auth_file),
            .graff_home = try a.dupe(u8, c.graff_home),
        };
    }

    pub fn free(c: Config, a: Allocator) void {
        a.free(c.data_dir);
        a.free(c.claude_config_dir);
        a.free(c.claude_config_file);
        a.free(c.codex_home);
        a.free(c.cursor_sdk_auth_file);
        a.free(c.graff_home);
    }

    pub fn claudeCredsFile(c: Config, a: Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ c.claude_config_dir, ".credentials.json" });
    }

    pub fn codexAuthFile(c: Config, a: Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ c.codex_home, "auth.json" });
    }

    pub fn rootDir(c: Config, a: Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ c.data_dir, "agent-accounts" });
    }
};

/// `AgentAuthKind`.
pub const AuthKind = enum {
    oauth,
    api_key,

    pub fn wire(k: AuthKind) []const u8 {
        return if (k == .oauth) "oauth" else "api-key";
    }
};

/// `SlotProfile`.
pub const Profile = struct {
    email: []const u8,
    display_name: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    auth_kind: AuthKind,
};

/// `Slot`: one saved login.
pub const Slot = struct {
    id: []const u8,
    harness: Harness,
    account_key: []const u8,
    profile: Profile,
    credentials: json.Value,
    claude_config: ?json.Value = null,
    saved_at: i64,
    created_at: ?i64 = null,

    pub fn sortKey(s: Slot) i64 {
        return s.created_at orelse s.saved_at;
    }
};

/// `Detected`: a live login before it is persisted (`credentials` null =
/// a login exists but its secret could not be read).
pub const Detected = struct {
    account_key: []const u8,
    profile: Profile,
    credentials: ?json.Value,
    claude_config: ?json.Value = null,
};

// ── files ──────────────────────────────────────────────────────────────────

/// `read_json`: the file parsed, only when it is a JSON object.
pub fn readJson(a: Allocator, io: Io, path: []const u8) ?json.Value {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch return null;
    return util.parseJsonObject(a, text);
}

pub fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn processId() u64 {
    if (comptime builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    if (comptime builtin.link_libc) return @intCast(std.c.getpid());
    if (comptime builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    return 0;
}

/// `Path::with_extension(format!("tmp-{pid}"))`.
pub fn tmpPath(a: Allocator, path: []const u8) ![]u8 {
    const base_start = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| i + 1 else 0;
    const base = path[base_start..];
    const stem_len = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| (if (d > 0) d else base.len) else base.len;
    return std.fmt.allocPrint(a, "{s}.tmp-{d}", .{ path[0 .. base_start + stem_len], processId() });
}

/// `write_file_atomic`: a same-dir temp file renamed over `path`; `secret`
/// creates it owner-only (0600) from birth.
pub fn writeFileAtomic(a: Allocator, io: Io, path: []const u8, bytes: []const u8, secret: bool) !void {
    const tmp = try tmpPath(a, path);
    {
        const perms: Io.File.Permissions = if (comptime builtin.os.tag != .windows and @hasDecl(Io.File.Permissions, "fromMode"))
            (if (secret) .fromMode(0o600) else .default_file)
        else
            .default_file;
        const f = try Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true, .permissions = perms });
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

/// `remove_if_exists`.
pub fn removeIfExists(io: Io, path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

/// `slots_dir` (created).
pub fn slotsDir(a: Allocator, io: Io, cfg: Config, harness: Harness) ![]u8 {
    const dir = try std.fs.path.join(a, &.{ try cfg.rootDir(a), harness.slug() });
    try Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// The startup sweep: reclaim `.login-*` throwaway homes a crashed process left.
pub fn sweepLoginDirs(a: Allocator, io: Io, cfg: Config) void {
    const root = cfg.rootDir(a) catch return;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (std.mem.startsWith(u8, e.name, ".login-")) names.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    for (names.items) |n| dir.deleteTree(io, n) catch {};
}

// ── slot JSON (serde's shape and strictness) ───────────────────────────────

fn optStr(o: json.ObjectMap, key: []const u8) error{Invalid}!?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => error.Invalid,
    };
}

fn reqStr(o: json.ObjectMap, key: []const u8) error{Invalid}![]const u8 {
    return (try optStr(o, key)) orelse error.Invalid;
}

fn optI64(o: json.ObjectMap, key: []const u8) error{Invalid}!?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .integer => |n| n,
        else => error.Invalid,
    };
}

/// A slot file, or null when serde would reject it.
pub fn parseSlot(a: Allocator, text: []const u8) ?Slot {
    const v = util.parseJson(a, text) orelse return null;
    return slotFromValue(v) catch null;
}

fn slotFromValue(v: json.Value) error{Invalid}!Slot {
    if (v != .object) return error.Invalid;
    const o = v.object;
    const p = o.get("profile") orelse return error.Invalid;
    if (p != .object) return error.Invalid;
    const kind_text = try reqStr(p.object, "authKind");
    const kind: AuthKind = if (std.mem.eql(u8, kind_text, "oauth")) .oauth else if (std.mem.eql(u8, kind_text, "api-key")) .api_key else return error.Invalid;
    const h = Harness.parse(try reqStr(o, "harness")) orelse return error.Invalid;
    const creds = o.get("credentials") orelse return error.Invalid;
    const cc = o.get("claudeConfig");
    return .{
        .id = try reqStr(o, "id"),
        .harness = h,
        .account_key = try reqStr(o, "accountKey"),
        .profile = .{
            .email = try reqStr(p.object, "email"),
            .display_name = try optStr(p.object, "displayName"),
            .organization = try optStr(p.object, "organization"),
            .plan = try optStr(p.object, "plan"),
            .auth_kind = kind,
        },
        .credentials = creds,
        .claude_config = if (cc) |x| (if (x == .null) null else x) else null,
        .saved_at = (try optI64(o, "savedAt")) orelse return error.Invalid,
        .created_at = try optI64(o, "createdAt"),
    };
}

/// `serde_json::to_string_pretty(&slot)`.
pub fn slotJson(a: Allocator, s: Slot) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    var j: json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try j.beginObject();
    try j.objectField("id");
    try j.write(s.id);
    try j.objectField("harness");
    try j.write(s.harness.slug());
    try j.objectField("accountKey");
    try j.write(s.account_key);
    try j.objectField("profile");
    try j.beginObject();
    try j.objectField("email");
    try j.write(s.profile.email);
    if (s.profile.display_name) |x| {
        try j.objectField("displayName");
        try j.write(x);
    }
    if (s.profile.organization) |x| {
        try j.objectField("organization");
        try j.write(x);
    }
    if (s.profile.plan) |x| {
        try j.objectField("plan");
        try j.write(x);
    }
    try j.objectField("authKind");
    try j.write(s.profile.auth_kind.wire());
    try j.endObject();
    try j.objectField("credentials");
    try j.write(s.credentials);
    if (s.claude_config) |cc| {
        try j.objectField("claudeConfig");
        try j.write(cc);
    }
    try j.objectField("savedAt");
    try j.write(s.saved_at);
    if (s.created_at) |c| {
        try j.objectField("createdAt");
        try j.write(c);
    }
    try j.endObject();
    return aw.toOwnedSlice();
}

/// `read_slots`: every parseable slot, in creation order (id breaks ties).
pub fn readSlots(a: Allocator, io: Io, cfg: Config, harness: Harness) []Slot {
    const dir_path = slotsDir(a, io, cfg, harness) catch return &.{};
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var slots: std.ArrayList(Slot) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".json") or e.name.len <= ".json".len) continue;
        const text = dir.readFileAlloc(io, e.name, a, .limited(16 * 1024 * 1024)) catch continue;
        const s = parseSlot(a, text) orelse continue;
        slots.append(a, s) catch break;
    }
    std.mem.sort(Slot, slots.items, {}, struct {
        fn lt(_: void, x: Slot, y: Slot) bool {
            if (x.sortKey() != y.sortKey()) return x.sortKey() < y.sortKey();
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lt);
    return slots.items;
}

/// `write_slot`: keeps the first `createdAt`; a brand-new slot is stamped
/// strictly after every sibling.
pub fn writeSlot(a: Allocator, io: Io, cfg: Config, slot: Slot) !void {
    const dir = try slotsDir(a, io, cfg, slot.harness);
    const name = try std.fmt.allocPrint(a, "{s}.json", .{slot.id});
    const file = try std.fs.path.join(a, &.{ dir, name });
    var full = slot;
    const existing: ?Slot = if (Io.Dir.cwd().readFileAlloc(io, file, a, .limited(16 * 1024 * 1024))) |t| parseSlot(a, t) else |_| null;
    if (existing) |e| {
        full.created_at = e.created_at orelse e.saved_at;
    } else if (slot.created_at == null) {
        var newest: ?i64 = null;
        for (readSlots(a, io, cfg, slot.harness)) |s| newest = if (newest) |n| @max(n, s.sortKey()) else s.sortKey();
        const floor = if (newest) |n| n + 1 else slot.saved_at;
        full.created_at = @max(floor, slot.saved_at);
    }
    try writeFileAtomic(a, io, file, try slotJson(a, full), true);
}

// ── credential files ───────────────────────────────────────────────────────

/// `parse_codex_auth`: a ChatGPT OAuth login (identity from the `id_token`)
/// or a raw `OPENAI_API_KEY`.
pub fn parseCodexAuth(a: Allocator, auth: json.Value) !?Detected {
    if (util.get(auth, "tokens")) |t| if (util.get(t, "id_token")) |idt| if (idt == .string) {
        const claims = util.jwtClaims(a, idt.string) orelse util.newObject();
        const oa = util.get(claims, "https://api.openai.com/auth") orelse json.Value.null;
        const email = util.strField(claims, "email") orelse return null;
        return .{
            .account_key = util.strField(oa, "chatgpt_account_id") orelse email,
            .profile = .{
                .email = email,
                .display_name = util.strField(claims, "name"),
                .plan = try util.codexPlan(a, util.strField(oa, "chatgpt_plan_type")),
                .auth_kind = .oauth,
            },
            .credentials = auth,
        };
    };
    const key = util.strField(auth, "OPENAI_API_KEY") orelse return null;
    return .{
        .account_key = try util.apiKeyAccountKey(a, key),
        .profile = .{
            .email = try std.fmt.allocPrint(a, "API key \u{00B7}\u{2026}{s}", .{util.lastChars(key, 4)}),
            .plan = "API key",
            .auth_kind = .api_key,
        },
        .credentials = auth,
    };
}

/// `parse_cursor_auth`: the Cursor SDK's `StoredSdkCredentials`.
pub fn parseCursorAuth(a: Allocator, auth: json.Value, now_ms: i64) !?Detected {
    const key = util.strField(auth, "apiKey") orelse return null;
    const email = util.strField(auth, "email");
    const expires = util.asI64(util.get(auth, "apiKeyExpiresAtMs"));
    const valid_ms: i64 = 8_210_266_876_799_999; // chrono's max representable millis
    return .{
        .account_key = email orelse try util.apiKeyAccountKey(a, key),
        .profile = .{
            .email = email orelse try std.fmt.allocPrint(a, "API key \u{00B7}\u{2026}{s}", .{util.lastChars(key, 4)}),
            .plan = if (expires) |ms| (if (ms >= -valid_ms and ms <= valid_ms) try util.cursorKeyLabel(a, ms, now_ms) else null) else null,
            .auth_kind = .oauth,
        },
        .credentials = auth,
    };
}

/// `cursor_key_usable`: a key, and not past its expiry.
pub fn cursorKeyUsable(auth: json.Value, now_ms: i64) bool {
    if (util.strField(auth, "apiKey") == null) return false;
    const ms = util.asI64(util.get(auth, "apiKeyExpiresAtMs")) orelse return true;
    return ms > now_ms;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "agent_logins_slots: slot files round-trip in serde's shape and keep creation order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const cfg: Config = .{ .data_dir = base, .claude_config_dir = base, .claude_config_file = base, .codex_home = base, .cursor_sdk_auth_file = base, .graff_home = base };
    const creds = util.parseJson(a, "{\"tokens\":{\"access_token\":\"fixture\"}}").?;
    const one: Slot = .{ .id = "bbbbbbbbbbbbbbbb", .harness = .codex, .account_key = "k1", .profile = .{ .email = "one@example.invalid", .auth_kind = .oauth }, .credentials = creds, .saved_at = 100 };
    const two: Slot = .{ .id = "aaaaaaaaaaaaaaaa", .harness = .codex, .account_key = "k2", .profile = .{ .email = "two@example.invalid", .plan = "ChatGPT Plus", .auth_kind = .oauth }, .credentials = creds, .saved_at = 100 };
    try writeSlot(a, io, cfg, one);
    try writeSlot(a, io, cfg, two);
    // Re-snapshotting bumps savedAt, never the order.
    var again = one;
    again.saved_at = 999;
    try writeSlot(a, io, cfg, again);
    const slots = readSlots(a, io, cfg, .codex);
    try testing.expectEqual(@as(usize, 2), slots.len);
    try testing.expectEqualStrings("k1", slots[0].account_key);
    try testing.expectEqual(@as(i64, 100), slots[0].created_at.?);
    try testing.expectEqual(@as(i64, 999), slots[0].saved_at);
    try testing.expectEqual(@as(i64, 101), slots[1].created_at.?);
    const text = try slotJson(a, slots[1]);
    try testing.expect(std.mem.startsWith(u8, text, "{\n  \"id\": \"aaaaaaaaaaaaaaaa\",\n  \"harness\": \"codex\",\n  \"accountKey\": \"k2\",\n  \"profile\": {\n    \"email\": \"two@example.invalid\",\n    \"plan\": \"ChatGPT Plus\",\n    \"authKind\": \"oauth\"\n  },"));
    if (builtin.os.tag != .windows) {
        const path = try std.fs.path.join(a, &.{ base, "agent-accounts", "codex", "aaaaaaaaaaaaaaaa.json" });
        const st = try Io.Dir.cwd().statFile(io, path, .{});
        try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
    }
    // A malformed file skips that slot only.
    const bad = try std.fs.path.join(a, &.{ base, "agent-accounts", "codex", "cccccccccccccccc.json" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bad, .data = "{\"id\":\"c\",\"harness\":\"nope\"}" });
    try testing.expectEqual(@as(usize, 2), readSlots(a, io, cfg, .codex).len);
    try testing.expect(parseSlot(a, "{\"id\":\"x\",\"harness\":\"codex\",\"accountKey\":\"k\",\"profile\":{\"email\":\"e\",\"authKind\":\"oauth\"},\"credentials\":{},\"savedAt\":1.5}") == null);
    try testing.expectEqualStrings("auth.tmp-", (try tmpPath(a, "/x/auth.json"))["/x/".len..][0..9]);
    try testing.expectEqualStrings("/x/.claude.tmp-", (try tmpPath(a, "/x/.claude.json"))[0..15]);
}

test "agent_logins_slots: codex and cursor credential files parse like Rust" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b64: [512]u8 = undefined;
    const payload = std.base64.url_safe_no_pad.Encoder.encode(&b64, "{\"email\":\"dev@example.invalid\",\"name\":\"Dev\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-1\",\"chatgpt_plan_type\":\"pro\"}}");
    const auth = util.parseJson(a, try std.fmt.allocPrint(a, "{{\"tokens\":{{\"id_token\":\"h.{s}.s\",\"access_token\":\"fixture\"}}}}", .{payload})).?;
    const d = (try parseCodexAuth(a, auth)).?;
    try testing.expectEqualStrings("acct-1", d.account_key);
    try testing.expectEqualStrings("ChatGPT Pro", d.profile.plan.?);
    try testing.expectEqualStrings("Dev", d.profile.display_name.?);
    const key = (try parseCodexAuth(a, util.parseJson(a, "{\"OPENAI_API_KEY\":\"sk-fixture-9876\"}").?)).?;
    try testing.expect(std.mem.startsWith(u8, key.account_key, "api-key:") and key.account_key.len == 20);
    try testing.expectEqualStrings("API key \u{00B7}\u{2026}9876", key.profile.email);
    try testing.expectEqual(AuthKind.api_key, key.profile.auth_kind);
    try testing.expect((try parseCodexAuth(a, util.parseJson(a, "{\"tokens\":{\"id_token\":\"garbage\"}}").?)) == null);

    const now: i64 = 1794334000000;
    const cur = (try parseCursorAuth(a, util.parseJson(a, "{\"apiKey\":\"cur-fixture\",\"email\":\"dev@example.invalid\",\"apiKeyExpiresAtMs\":1799884800000}").?, now)).?;
    try testing.expectEqualStrings("dev@example.invalid", cur.account_key);
    try testing.expectEqualStrings("Key expires Jan 14", cur.profile.plan.?);
    const expired = util.parseJson(a, "{\"apiKey\":\"cur-fixture\",\"apiKeyExpiresAtMs\":1}").?;
    try testing.expectEqualStrings("Key expired", (try parseCursorAuth(a, expired, now)).?.profile.plan.?);
    try testing.expect(!cursorKeyUsable(expired, now));
    try testing.expect(cursorKeyUsable(util.parseJson(a, "{\"apiKey\":\"k\"}").?, now));
    try testing.expect((try parseCursorAuth(a, util.parseJson(a, "{\"email\":\"x\"}").?, now)) == null);
}
