//! Pure helpers for the agent-accounts login registry (`agent_logins.zig`),
//! ported from `crates/engine/src/agent_accounts.rs` (helpers section),
//! `crates/engine/src/device_login.rs` and the wire types in
//! `crates/proto/src/entities.rs` (`AgentUsageWindow`, `AgentLoginStart`).
//!
//! Nothing here touches files, processes or the network.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Writer = std.Io.Writer;

// ── harness ids ────────────────────────────────────────────────────────────

/// `harness_proto::HarnessId` (kebab-case on the wire).
pub const Harness = enum {
    claude_code,
    codex,
    cursor,
    devin,
    grok,
    hermes,
    graff,
    pi,
    opencode,
    antigravity,
    exo,
    mock,

    const slugs = [_][]const u8{ "claude-code", "codex", "cursor", "devin", "grok", "hermes", "graff", "pi", "opencode", "antigravity", "exo", "mock" };
    const debug_names = [_][]const u8{ "ClaudeCode", "Codex", "Cursor", "Devin", "Grok", "Hermes", "Graff", "Pi", "Opencode", "Antigravity", "Exo", "Mock" };

    /// `harness_slug` (also the serde name).
    pub fn slug(h: Harness) []const u8 {
        return slugs[@backingInt(h)];
    }

    /// Rust's `{:?}` of the variant (used in "not supported for {other:?}").
    pub fn debugName(h: Harness) []const u8 {
        return debug_names[@backingInt(h)];
    }

    pub fn parse(text: []const u8) ?Harness {
        for (slugs, 0..) |s, i| if (std.mem.eql(u8, s, text)) return @fromBackingInt(@intCast(i));
        return null;
    }
};

/// serde's text for an unknown `HarnessId` variant.
pub fn unknownVariantText(a: Allocator, variant: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "unknown variant `{s}`, expected one of ", .{variant});
    for (Harness.slugs, 0..) |s, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "`{s}`", .{s});
    }
    return out.toOwnedSlice(a);
}

/// serde's `Unexpected` rendering of a JSON value ("integer `5`", "string \"x\"").
pub fn unexpectedText(a: Allocator, v: json.Value) ![]u8 {
    return switch (v) {
        .null => a.dupe(u8, "null"),
        .bool => |b| std.fmt.allocPrint(a, "boolean `{}`", .{b}),
        .integer => |n| std.fmt.allocPrint(a, "integer `{d}`", .{n}),
        .float => |f| std.fmt.allocPrint(a, "floating point `{d}`", .{f}),
        .number_string => |s| std.fmt.allocPrint(a, "number `{s}`", .{s}),
        .string => |s| std.fmt.allocPrint(a, "string \"{s}\"", .{s}),
        .array => a.dupe(u8, "sequence"),
        .object => a.dupe(u8, "map"),
    };
}

// ── identity ───────────────────────────────────────────────────────────────

pub fn hexLower(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out[0 .. bytes.len * 2];
}

/// `slot_id_for`: the first 16 hex chars of sha256("{slug}:{account_key}").
pub fn slotIdFor(harness: Harness, account_key: []const u8) [16]u8 {
    var h = Sha256.init(.{});
    h.update(harness.slug());
    h.update(":");
    h.update(account_key);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    var hex: [64]u8 = undefined;
    _ = hexLower(&hex, &digest);
    return hex[0..16].*;
}

/// `forget`'s guard: exactly 16 lowercase hex digits.
pub fn isSlotId(id: []const u8) bool {
    if (id.len != 16) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// `"api-key:{first 12 hex of sha256(key)}"`.
pub fn apiKeyAccountKey(a: Allocator, api_key: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(api_key, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = hexLower(&hex, &digest);
    return std.fmt.allocPrint(a, "api-key:{s}", .{hex[0..12]});
}

/// The last `n` chars (Unicode scalars) of `s`.
pub fn lastChars(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i: usize = s.len;
    while (i > 0 and count < n) {
        i -= 1;
        while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
        count += 1;
    }
    return s[i..];
}

/// `reauth_route`.
pub fn reauthRoute(a: Allocator, harness: []const u8, remote: bool, account: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ harness, if (remote) "device" else "browser", account });
}

// ── plan labels ────────────────────────────────────────────────────────────

/// `claude_plan`: "Max 20×" from the org type and rate-limit tier.
pub fn claudePlan(a: Allocator, org_type: ?[]const u8, tier: ?[]const u8) !?[]u8 {
    const t = org_type orelse return null;
    const base: []const u8 = if (std.mem.eql(u8, t, "claude_max"))
        "Max"
    else if (std.mem.eql(u8, t, "claude_pro"))
        "Pro"
    else if (std.mem.eql(u8, t, "claude_team"))
        "Team"
    else if (std.mem.eql(u8, t, "claude_enterprise"))
        "Enterprise"
    else
        return null;
    if (tier) |tr| if (std.mem.endsWith(u8, tr, "x")) {
        const stem = tr[0 .. tr.len - 1];
        var start = stem.len;
        while (start > 0 and std.ascii.isDigit(stem[start - 1])) start -= 1;
        const digits = stem[start..];
        if (digits.len > 0 and start > 0 and stem[start - 1] == '_') {
            return try std.fmt.allocPrint(a, "{s} {s}\u{00D7}", .{ base, digits });
        }
    };
    return try a.dupe(u8, base);
}

/// `codex_plan`: "ChatGPT " + the plan with its first letter uppercased.
pub fn codexPlan(a: Allocator, plan: ?[]const u8) !?[]u8 {
    const p = plan orelse return null;
    if (p.len == 0) return null;
    const out = try std.fmt.allocPrint(a, "ChatGPT {s}", .{p});
    out[8] = std.ascii.toUpper(out[8]);
    return out;
}

/// `codex_window_label`.
pub fn codexWindowLabel(span_seconds: i64) []const u8 {
    const day: i64 = 86_400;
    if (span_seconds >= 28 * day) return "Month";
    if (span_seconds >= 5 * day) return "Week";
    return "Session";
}

/// `urlencode` (encodeURIComponent's unreserved set).
pub fn urlencode(a: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-_.!~*'()", b) != null) {
            try out.append(a, b);
        } else {
            try out.print(a, "%{X:0>2}", .{b});
        }
    }
    return out.toOwnedSlice(a);
}

// ── JSON access ────────────────────────────────────────────────────────────

pub fn get(v: json.Value, key: []const u8) ?json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// `str_field`: a non-empty string field.
pub fn strField(v: json.Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return switch (f) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// serde_json `as_i64`.
pub fn asI64(v: ?json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// serde_json `as_f64`.
pub fn asF64(v: ?json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn parseJson(a: Allocator, text: []const u8) ?json.Value {
    return json.parseFromSliceLeaky(json.Value, a, text, .{ .allocate = .alloc_always, .duplicate_field_behavior = .use_last }) catch null;
}

/// `read_json`'s filter: parsed and an object.
pub fn parseJsonObject(a: Allocator, text: []const u8) ?json.Value {
    const v = parseJson(a, text) orelse return null;
    return if (v == .object) v else null;
}

/// Compact JSON (`Value::to_string`).
pub fn stringify(a: Allocator, v: json.Value) ![]u8 {
    return json.Stringify.valueAlloc(a, v, .{});
}

/// Pretty JSON (`to_string_pretty`, two-space indent).
pub fn stringifyPretty(a: Allocator, v: json.Value) ![]u8 {
    return json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 });
}

pub fn newObject() json.Value {
    return .{ .object = json.ObjectMap.empty };
}

pub fn strValue(s: ?[]const u8) json.Value {
    return if (s) |x| .{ .string = x } else .null;
}

/// Deep copy into `a` (so a value outlives the arena it was parsed in).
pub fn cloneValue(a: Allocator, v: json.Value) !json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = json.Array.init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try cloneValue(a, x));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out = json.ObjectMap.empty;
            var it = o.iterator();
            while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

/// serde_json `Value` equality (object order-insensitive).
pub fn valueEql(x: json.Value, y: json.Value) bool {
    switch (x) {
        .null => return y == .null,
        .bool => |b| return y == .bool and y.bool == b,
        .integer, .float, .number_string => {
            const fx = asF64(x) orelse return false;
            const fy = asF64(y) orelse return false;
            return fx == fy and std.meta.activeTag(x) == std.meta.activeTag(y);
        },
        .string => |s| return y == .string and std.mem.eql(u8, s, y.string),
        .array => |arr| {
            if (y != .array or y.array.items.len != arr.items.len) return false;
            for (arr.items, y.array.items) |p, q| if (!valueEql(p, q)) return false;
            return true;
        },
        .object => |o| {
            if (y != .object or y.object.count() != o.count()) return false;
            var it = o.iterator();
            while (it.next()) |e| {
                const other = y.object.get(e.key_ptr.*) orelse return false;
                if (!valueEql(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

/// `jwt_claims`: decode the payload without verifying (URL-safe no-pad, else standard).
pub fn jwtClaims(a: Allocator, jwt: []const u8) ?json.Value {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next() orelse return null;
    const payload = it.next() orelse return null;
    const bytes = decodeB64(a, std.base64.url_safe_no_pad.Decoder, payload) orelse
        decodeB64(a, std.base64.standard.Decoder, payload) orelse return null;
    return parseJson(a, bytes);
}

fn decodeB64(a: Allocator, dec: std.base64.Base64Decoder, text: []const u8) ?[]u8 {
    const n = dec.calcSizeForSlice(text) catch return null;
    const buf = a.alloc(u8, n) catch return null;
    dec.decode(buf, text) catch return null;
    return buf;
}

/// `compose_claude_credentials`: the slot's login with the live
/// machine-shared keys (`CLAUDE_SHARED_CREDENTIAL_KEYS`).
pub const claude_shared_credential_keys = [_][]const u8{ "mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp", "mcpXaaIdpConfig", "pluginSecrets" };

fn isSharedKey(key: []const u8) bool {
    for (claude_shared_credential_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

pub fn composeClaudeCredentials(a: Allocator, target: json.Value, live: ?json.Value) !json.Value {
    const l = live orelse return target;
    if (l != .object or target != .object) return target;
    if (target.object.get("claudeAiOauth") == null) return target;
    var out = json.ObjectMap.empty;
    var it = target.object.iterator();
    while (it.next()) |e| if (!isSharedKey(e.key_ptr.*)) try out.put(a, e.key_ptr.*, e.value_ptr.*);
    for (claude_shared_credential_keys) |k| if (l.object.get(k)) |v| try out.put(a, k, v);
    return .{ .object = out };
}

/// `with_claude_ai_oauth`: replace `claudeAiOauth`, keeping sibling keys.
pub fn withClaudeAiOauth(a: Allocator, credentials: json.Value, oauth: json.Value) !json.Value {
    var out = json.ObjectMap.empty;
    if (credentials == .object) {
        var it = credentials.object.iterator();
        while (it.next()) |e| try out.put(a, e.key_ptr.*, e.value_ptr.*);
    }
    try out.put(a, "claudeAiOauth", oauth);
    return .{ .object = out };
}

// ── time (chrono's UTC rendering) ──────────────────────────────────────────

/// A UTC instant: seconds since the epoch plus nanoseconds.
pub const Time = struct {
    secs: i64,
    nanos: u32 = 0,

    pub fn fromMillis(ms: i64) Time {
        return .{ .secs = @divFloor(ms, 1000), .nanos = @intCast(@mod(ms, 1000) * 1_000_000) };
    }

    /// chrono `DateTime<Utc>` serde form: `2026-11-17T08:00:00Z`, the
    /// fraction only when non-zero (3, 6 or 9 digits).
    pub fn format(t: Time, buf: *[40]u8) []const u8 {
        const days = @divFloor(t.secs, 86_400);
        const rem: u64 = @intCast(@mod(t.secs, 86_400));
        const c = civilFromDays(days);
        var w: Writer = .fixed(buf);
        w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@max(0, c.year))), c.month, c.day, rem / 3600, (rem / 60) % 60, rem % 60 }) catch {};
        if (t.nanos != 0) {
            if (t.nanos % 1_000_000 == 0) {
                w.print(".{d:0>3}", .{t.nanos / 1_000_000}) catch {};
            } else if (t.nanos % 1000 == 0) {
                w.print(".{d:0>6}", .{t.nanos / 1000}) catch {};
            } else {
                w.print(".{d:0>9}", .{t.nanos}) catch {};
            }
        }
        w.writeAll("Z") catch {};
        return w.buffered();
    }
};

pub const Civil = struct { year: i64, month: u8, day: u8 };

pub fn civilFromDays(days_in: i64) Civil {
    const z = days_in + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (m <= 2) y + 1 else y, .month = @intCast(m), .day = @intCast(d) };
}

pub fn daysFromCivil(year_in: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// chrono `DateTime::parse_from_rfc3339`, converted to UTC.
pub fn parseRfc3339(s: []const u8) ?Time {
    if (s.len < 20) return null;
    const year = parseDigits(s[0..4]) orelse return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const month = parseDigits(s[5..7]) orelse return null;
    const day = parseDigits(s[8..10]) orelse return null;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return null;
    const hour = parseDigits(s[11..13]) orelse return null;
    if (s[13] != ':' or s[16] != ':') return null;
    const minute = parseDigits(s[14..16]) orelse return null;
    var second = parseDigits(s[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, @intCast(month))) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    var i: usize = 19;
    var nanos: u32 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        var scale: u32 = 100_000_000;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            nanos += (s[i] - '0') * scale;
            scale /= 10;
        }
        if (i == start) return null;
    }
    if (i >= s.len) return null;
    var offset: i64 = 0;
    switch (s[i]) {
        'Z', 'z' => i += 1,
        '+', '-' => {
            if (s.len < i + 6 or s[i + 3] != ':') return null;
            const oh = parseDigits(s[i + 1 .. i + 3]) orelse return null;
            const om = parseDigits(s[i + 4 .. i + 6]) orelse return null;
            if (oh > 23 or om > 59) return null;
            offset = (oh * 60 + om) * 60;
            if (s[i] == '-') offset = -offset;
            i += 6;
        },
        else => return null,
    }
    if (i != s.len) return null;
    if (second == 60) {
        second = 59;
        nanos += 1_000_000_000;
    }
    const days = daysFromCivil(year, @intCast(month), @intCast(day));
    var secs = days * 86_400 + hour * 3600 + minute * 60 + second - offset;
    if (nanos >= 1_000_000_000) {
        nanos -= 1_000_000_000;
        secs += 1;
    }
    return .{ .secs = secs, .nanos = nanos };
}

fn parseDigits(s: []const u8) ?i64 {
    var n: i64 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn daysInMonth(year: i64, month: u8) i64 {
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    const table = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return table[month - 1];
}

/// `parse_when`: unix seconds (an integer) or an RFC 3339 string.
pub fn parseWhen(v: ?json.Value) ?Time {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| .{ .secs = n },
        .string => |s| parseRfc3339(s),
        else => null,
    };
}

/// `json_ms`: unix millis as a number or an int64 string.
pub fn jsonMs(v: ?json.Value) ?Time {
    const x = v orelse return null;
    const ms: i64 = switch (x) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return null,
        else => return null,
    };
    return Time.fromMillis(ms);
}

const month_abbr = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// `parse_cursor_auth`'s plan chip: "Key expired" / "Key expires %b %-d".
pub fn cursorKeyLabel(a: Allocator, expires_ms: i64, now_ms: i64) ![]u8 {
    if (expires_ms < now_ms) return a.dupe(u8, "Key expired");
    const c = civilFromDays(@divFloor(@divFloor(expires_ms, 1000), 86_400));
    return std.fmt.allocPrint(a, "Key expires {s} {d}", .{ month_abbr[c.month - 1], c.day });
}

// ── usage ──────────────────────────────────────────────────────────────────

/// `AgentUsageWindow`.
pub const UsageWindow = struct {
    label: []const u8,
    used_fraction: f32,
    resets_at: ?Time,
};

/// `UsageSnapshot`: windows plus a live plan label.
pub const UsageSnapshot = struct {
    windows: []const UsageWindow,
    plan_label: ?[]const u8 = null,
};

/// `claude_usage_windows`.
pub fn claudeUsageWindows(a: Allocator, body: json.Value) !?UsageSnapshot {
    var windows: std.ArrayList(UsageWindow) = .empty;
    const pairs = [_][2][]const u8{ .{ "five_hour", "Session" }, .{ "seven_day", "Week" } };
    for (pairs) |p| {
        const w = get(body, p[0]) orelse continue;
        const util = asF64(get(w, "utilization")) orelse continue;
        try windows.append(a, .{ .label = p[1], .used_fraction = @floatCast(util / 100.0), .resets_at = parseWhen(get(w, "resets_at")) });
    }
    if (windows.items.len == 0) return null;
    return .{ .windows = try windows.toOwnedSlice(a) };
}

/// The body half of `codex_usage`.
pub fn codexUsage(a: Allocator, body: json.Value) !?UsageSnapshot {
    const rl = get(body, "rate_limit") orelse return null;
    var windows: std.ArrayList(UsageWindow) = .empty;
    for ([_][]const u8{ "primary_window", "secondary_window" }) |key| {
        const w = get(rl, key) orelse continue;
        const used = asF64(get(w, "used_percent")) orelse continue;
        const span = asI64(get(w, "limit_window_seconds")) orelse 0;
        try windows.append(a, .{ .label = codexWindowLabel(span), .used_fraction = @floatCast(used / 100.0), .resets_at = parseWhen(get(w, "reset_at")) });
    }
    if (windows.items.len == 0) return null;
    return .{ .windows = try windows.toOwnedSlice(a), .plan_label = try codexPlan(a, strField(body, "plan_type")) };
}

/// `cursor_usage_window`: spend over limit, absent/zero limit is unusable.
pub fn cursorUsageWindow(body: json.Value) ?UsageWindow {
    const plan = get(body, "planUsage") orelse return null;
    const limit = asF64(get(plan, "limit")) orelse return null;
    if (limit <= 0) return null;
    const used = asF64(get(plan, "totalSpend")) orelse 0;
    return .{ .label = "Month", .used_fraction = @floatCast(used / limit), .resets_at = jsonMs(get(body, "billingCycleEnd")) };
}

// ── login output scanning ──────────────────────────────────────────────────

fn isWs(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

/// `scan_openai_url`: from `https://auth.openai.com/` to the next whitespace.
pub fn scanOpenaiUrl(output: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, output, "https://auth.openai.com/") orelse return null;
    const rest = output[start..];
    var end: usize = 0;
    while (end < rest.len and !isWs(rest[end])) end += 1;
    return rest[0..end];
}

/// `scan_shim_event`: the first JSONL frame whose `ev` is `ev`.
pub fn scanShimEvent(a: Allocator, output: []const u8, ev: []const u8) ?json.Value {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        const v = parseJson(a, line) orelse continue;
        const e = get(v, "ev") orelse continue;
        if (e == .string and std.mem.eql(u8, e.string, ev)) return v;
    }
    return null;
}

pub fn scanCursorUrl(a: Allocator, output: []const u8) ?[]const u8 {
    return strField(scanShimEvent(a, output, "auth-url") orelse return null, "url");
}

pub fn scanShimFatal(a: Allocator, output: []const u8) ?[]const u8 {
    return strField(scanShimEvent(a, output, "fatal") orelse return null, "message");
}

/// The poll's failure text for a spawned login: the shim's fatal message,
/// else the last line of the trimmed output, else "sign-in failed".
pub fn spawnedFailureText(a: Allocator, output: []const u8) []const u8 {
    if (scanShimFatal(a, output)) |m| return m;
    const t = std.mem.trim(u8, output, " \t\r\n");
    if (t.len == 0) return "sign-in failed";
    var last: []const u8 = t;
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |l| last = l;
    return std.mem.trimEnd(u8, last, "\r");
}

// ── device authorization (`device_login.rs`) ──────────────────────────────

pub const codex_device_url = "https://auth.openai.com/codex/device";

/// `AgentLoginStart::is_safe_device_code` (mode is DeviceCode by construction).
pub fn isSafeDeviceCode(login_id: []const u8, url: []const u8, code: []const u8) bool {
    if (login_id.len == 0 or !std.mem.eql(u8, url, codex_device_url)) return false;
    if (code.len < 4 or code.len > 32) return false;
    for (code) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    return true;
}

/// `device_login::strip_ansi`: drop `ESC [ … final-byte` sequences (and a
/// lone ESC plus the char after it).
pub fn stripAnsiDevice(a: Allocator, output: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < output.len) {
        const c = output[i];
        if (c == 0x1b) {
            i += 1;
            if (i < output.len) {
                const n = output[i];
                i += utf8Len(n);
                if (n == '[') {
                    while (i < output.len) {
                        const d = output[i];
                        i += utf8Len(d);
                        if (d >= '@' and d <= '~') break;
                    }
                }
            }
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn utf8Len(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

/// `device_login::codex_prompt`: the one-time code under Codex's documented
/// prompt, only from complete lines; null unless the pair is safe.
pub fn codexDeviceCode(a: Allocator, login_id: []const u8, output: []const u8) !?[]const u8 {
    const clean = try stripAnsiDevice(a, output);
    const last_nl = std.mem.lastIndexOfScalar(u8, clean, '\n') orelse return null;
    const complete = clean[0 .. last_nl + 1];
    var url_seen = false;
    var code_expected = false;
    var it = std.mem.splitScalar(u8, complete, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw, "\r"), &std.ascii.whitespace);
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, codex_device_url)) {
            url_seen = true;
        } else if (url_seen and std.mem.startsWith(u8, line, "2. Enter this one-time code")) {
            code_expected = true;
        } else if (code_expected) {
            return if (isSafeDeviceCode(login_id, codex_device_url, line)) line else null;
        }
    }
    return null;
}

// ── wire JSON ──────────────────────────────────────────────────────────────

/// `AgentLoginMode` (kebab-case).
pub const LoginMode = enum {
    paste_code,
    browser,
    host_browser,
    device_code,
    relay_browser,

    pub fn wire(m: LoginMode) []const u8 {
        return switch (m) {
            .paste_code => "paste-code",
            .browser => "browser",
            .host_browser => "host-browser",
            .device_code => "device-code",
            .relay_browser => "relay-browser",
        };
    }
};

/// `AgentLoginStart`.
pub const LoginStart = struct {
    login_id: []const u8,
    url: []const u8,
    mode: LoginMode,
    code: ?[]const u8 = null,

    pub fn clone(s: LoginStart, a: Allocator) !LoginStart {
        return .{ .login_id = try a.dupe(u8, s.login_id), .url = try a.dupe(u8, s.url), .mode = s.mode, .code = if (s.code) |c| try a.dupe(u8, c) else null };
    }

    pub fn free(s: LoginStart, a: Allocator) void {
        a.free(s.login_id);
        a.free(s.url);
        if (s.code) |c| a.free(c);
    }

    pub fn toJson(s: LoginStart, a: Allocator) ![]u8 {
        var aw: Writer.Allocating = .init(a);
        var j: json.Stringify = .{ .writer = &aw.writer };
        try j.beginObject();
        try j.objectField("loginId");
        try j.write(s.login_id);
        try j.objectField("url");
        try j.write(s.url);
        try j.objectField("mode");
        try j.write(s.mode.wire());
        if (s.code) |c| {
            try j.objectField("code");
            try j.write(c);
        }
        try j.endObject();
        return aw.toOwnedSlice();
    }
};

/// `AgentLoginStatus` (camelCase).
pub const LoginStatus = enum { pending, done, @"error" };

/// `AgentLoginPoll`.
pub const LoginPoll = struct {
    status: LoginStatus,
    message: ?[]const u8 = null,
    url: ?[]const u8 = null,

    pub fn toJson(p: LoginPoll, a: Allocator) ![]u8 {
        var aw: Writer.Allocating = .init(a);
        var j: json.Stringify = .{ .writer = &aw.writer };
        try j.beginObject();
        try j.objectField("status");
        try j.write(@tagName(p.status));
        if (p.message) |m| {
            try j.objectField("message");
            try j.write(m);
        }
        if (p.url) |u| {
            try j.objectField("url");
            try j.write(u);
        }
        try j.endObject();
        return aw.toOwnedSlice();
    }
};

/// Write an `AgentUsageWindow` object.
pub fn writeWindow(j: *json.Stringify, w: UsageWindow) !void {
    try j.beginObject();
    try j.objectField("label");
    try j.write(w.label);
    try j.objectField("usedFraction");
    try j.print("{d}", .{w.used_fraction});
    try j.objectField("resetsAt");
    if (w.resets_at) |t| {
        var buf: [40]u8 = undefined;
        try j.write(t.format(&buf));
    } else try j.write(null);
    try j.endObject();
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "agent_logins_util: plan labels, window labels and slot ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Max 20\u{00D7}", (try claudePlan(a, "claude_max", "default_claude_max_20x")).?);
    try testing.expectEqualStrings("Pro", (try claudePlan(a, "claude_pro", null)).?);
    try testing.expectEqualStrings("Team", (try claudePlan(a, "claude_team", "weird")).?);
    try testing.expectEqualStrings("Max", (try claudePlan(a, "claude_max", "20x")).?);
    try testing.expect((try claudePlan(a, "free", null)) == null);
    try testing.expectEqualStrings("ChatGPT Plus", (try codexPlan(a, "plus")).?);
    try testing.expect((try codexPlan(a, "")) == null);
    try testing.expectEqualStrings("Month", codexWindowLabel(2_592_000));
    try testing.expectEqualStrings("Week", codexWindowLabel(604_800));
    try testing.expectEqualStrings("Session", codexWindowLabel(18_000));
    const id = slotIdFor(.codex, "acct-1");
    try testing.expect(isSlotId(&id));
    try testing.expect(!std.mem.eql(u8, &id, &slotIdFor(.cursor, "acct-1")));
    try testing.expect(!isSlotId("../../etc/passwd"));
    try testing.expect(!isSlotId("ABCDEF0123456789"));
    try testing.expectEqualStrings("…1234", lastChars("sk-…1234", 5)[0..]);
}

test "agent_logins_util: urlencode matches encodeURIComponent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https%3A%2F%2Fconsole.example%2Fcb", try urlencode(a, "https://console.example/cb"));
    try testing.expectEqualStrings("a%20b%3Ac", try urlencode(a, "a b:c"));
    try testing.expectEqualStrings("-_.!~*'()", try urlencode(a, "-_.!~*'()"));
}

test "agent_logins_util: chrono time rendering and rfc3339 parsing" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2026-11-17T08:00:00Z", parseRfc3339("2026-11-17T08:00:00.000Z").?.format(&buf));
    try testing.expectEqualStrings("2026-11-17T06:30:00.250Z", parseRfc3339("2026-11-17T08:00:00.25+01:30").?.format(&buf));
    try testing.expectEqualStrings("2026-11-18T00:00:00Z", (Time{ .secs = 1794960000 }).format(&buf));
    try testing.expectEqualStrings("2026-11-17T00:00:00.000001Z", (Time{ .secs = 1794873600, .nanos = 1000 }).format(&buf));
    try testing.expect(parseRfc3339("2026-13-01T00:00:00Z") == null);
    try testing.expect(parseRfc3339("not a date") == null);
    try testing.expect(parseWhen(.{ .float = 1.5 }) == null);
    try testing.expectEqualStrings("2026-11-17T00:00:00Z", jsonMs(.{ .string = "1794873600000" }).?.format(&buf));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Key expires Jan 14", try cursorKeyLabel(arena.allocator(), 1799884800000, 1794334000000));
    try testing.expectEqualStrings("Key expired", try cursorKeyLabel(arena.allocator(), 1, 1794334000000));
}

test "agent_logins_util: usage bodies map like the Rust parsers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const claude = (try claudeUsageWindows(a, parseJson(a, "{\"five_hour\":{\"utilization\":50,\"resets_at\":\"2026-11-17T08:00:00Z\"},\"seven_day\":{\"utilization\":12.5}}").?)).?;
    try testing.expectEqual(@as(usize, 2), claude.windows.len);
    try testing.expectEqualStrings("Session", claude.windows[0].label);
    try testing.expectEqual(@as(f32, 0.5), claude.windows[0].used_fraction);
    try testing.expect(claude.windows[1].resets_at == null);
    try testing.expect((try claudeUsageWindows(a, parseJson(a, "{\"five_hour\":null}").?)) == null);
    const codex = (try codexUsage(a, parseJson(a, "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":10,\"limit_window_seconds\":18000,\"reset_at\":1794960000},\"secondary_window\":{\"used_percent\":40,\"limit_window_seconds\":604800}}}").?)).?;
    try testing.expectEqualStrings("Session", codex.windows[0].label);
    try testing.expectEqualStrings("Week", codex.windows[1].label);
    try testing.expectEqualStrings("ChatGPT Plus", codex.plan_label.?);
    const cur = cursorUsageWindow(parseJson(a, "{\"billingCycleEnd\":\"1794873600000\",\"planUsage\":{\"totalSpend\":1440,\"limit\":2000,\"totalPercentUsed\":11.5}}").?).?;
    try testing.expectApproxEqAbs(@as(f32, 0.72), cur.used_fraction, 0.0001);
    try testing.expect(cursorUsageWindow(parseJson(a, "{\"planUsage\":{\"totalSpend\":5}}").?) == null);
    try testing.expectEqual(@as(f32, 0), cursorUsageWindow(parseJson(a, "{\"planUsage\":{\"limit\":2000}}").?).?.used_fraction);
}

test "agent_logins_util: shim and openai url scanning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = "noise\n{\"ev\":\"auth-url\",\"url\":\"https://cursor.example/login?x=1\"}\n{\"ev\":\"fatal\",\"message\":\"login timed out\"}\n";
    try testing.expectEqualStrings("https://cursor.example/login?x=1", scanCursorUrl(a, out).?);
    try testing.expectEqualStrings("login timed out", scanShimFatal(a, out).?);
    try testing.expectEqualStrings("login timed out", spawnedFailureText(a, out));
    try testing.expectEqualStrings("last words", spawnedFailureText(a, "boom\nlast words\n\n"));
    try testing.expectEqualStrings("sign-in failed", spawnedFailureText(a, "  \n"));
    try testing.expectEqualStrings("https://auth.openai.com/oauth/authorize?x=1", scanOpenaiUrl("open https://auth.openai.com/oauth/authorize?x=1 now").?);
    try testing.expect(scanOpenaiUrl("https://example.com/") == null);
}

test "agent_logins_util: device code prompt requires a complete safe pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prompt = "1. Open this link in your browser and sign in to your account\n  \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m\n\n2. Enter this one-time code (expires in 15 minutes)\n  \x1b[94mABCD-EFGH\x1b[0m\n";
    try testing.expectEqualStrings("ABCD-EFGH", (try codexDeviceCode(a, "fixture", prompt)).?);
    const swapped = try std.mem.replaceOwned(u8, a, prompt, "/codex/device", "/authorize?token=fixture");
    try testing.expect((try codexDeviceCode(a, "fixture", swapped)) == null);
    const bad = try std.mem.replaceOwned(u8, a, prompt, "ABCD-EFGH", "token_with_underscores");
    try testing.expect((try codexDeviceCode(a, "fixture", bad)) == null);
    try testing.expect((try codexDeviceCode(a, "fixture", std.mem.trimEnd(u8, prompt, "\n"))) == null);
    try testing.expect(!isSafeDeviceCode("", codex_device_url, "ABCD-EFGH"));
}

test "agent_logins_util: claude credential splice keeps live shared keys and slot login" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target = parseJson(a, "{\"claudeAiOauth\":{\"accessToken\":\"slot\"},\"mcpOAuth\":{\"stale\":true},\"trustedDeviceToken\":\"t\"}").?;
    const live = parseJson(a, "{\"claudeAiOauth\":{\"accessToken\":\"live\"},\"mcpOAuth\":{\"fresh\":true},\"pluginSecrets\":{\"p\":1}}").?;
    const out = try composeClaudeCredentials(a, target, live);
    try testing.expectEqualStrings("{\"claudeAiOauth\":{\"accessToken\":\"slot\"},\"trustedDeviceToken\":\"t\",\"mcpOAuth\":{\"fresh\":true},\"pluginSecrets\":{\"p\":1}}", try stringify(a, out));
    // A shared key the live blob no longer holds is not resurrected.
    const no_mcp = try composeClaudeCredentials(a, target, parseJson(a, "{\"claudeAiOauth\":{}}").?);
    try testing.expect(no_mcp.object.get("mcpOAuth") == null);
    // Passthrough without live JSON or without a Claude login.
    try testing.expect(valueEql(try composeClaudeCredentials(a, target, null), target));
    const plain = parseJson(a, "{\"other\":1}").?;
    try testing.expect(valueEql(try composeClaudeCredentials(a, plain, live), plain));
    const swapped = try withClaudeAiOauth(a, target, parseJson(a, "{\"accessToken\":\"new\"}").?);
    try testing.expect(swapped.object.get("mcpOAuth") != null);
    try testing.expectEqualStrings("new", strField(swapped.object.get("claudeAiOauth").?, "accessToken").?);
}

test "agent_logins_util: serde texts and reauth routes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(std.mem.startsWith(u8, try unknownVariantText(a, "nope"), "unknown variant `nope`, expected one of `claude-code`, `codex`"));
    try testing.expectEqualStrings("integer `5`", try unexpectedText(a, .{ .integer = 5 }));
    try testing.expectEqualStrings("string \"x\"", try unexpectedText(a, .{ .string = "x" }));
    try testing.expectEqualStrings("codex:device:account-a", try reauthRoute(a, "codex", true, "account-a"));
    try testing.expect(!std.mem.eql(u8, try reauthRoute(a, "codex", true, "a"), try reauthRoute(a, "codex", false, "a")));
    try testing.expectEqualStrings("Opencode", Harness.opencode.debugName());
    try testing.expectEqual(Harness.claude_code, Harness.parse("claude-code").?);
}
