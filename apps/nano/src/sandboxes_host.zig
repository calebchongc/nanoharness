//! Codegraff cloud sandboxes for the engine's RPCs (`CodegraffSandboxes`,
//! `CodegraffCreateSandbox`, `CodegraffCreateTemporarySandbox`,
//! `CodegraffSandboxAction`): the Zig port of
//! `crates/engine/src/codegraff_auth/sandboxes.rs` against the gateway's
//! `/v1/sandboxes`.
//!
//! A Harness cloud sandbox is a persistent `fleet` sandbox; after it exists,
//! `POST /v1/sandboxes/:id/harness {deviceName}` sets Harness up in it (and is
//! repeated once when it fails with `harness_start_failed`). Each sandbox's
//! device name is remembered in `<data>/cloud-sandboxes.json` and joined onto
//! the list. Gateway calls go through `Transport`, so tests answer from a
//! made-up gateway and never reach a paid service.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const proc = @import("proc_seam.zig");

const fleet = "fleet";
const sandbox_name = "Harness cloud";
const auto_stop_minutes: u32 = 30;
const wake_lease_seconds: u32 = auto_stop_minutes * 60;
pub const quick_ms: u64 = 20_000;
pub const boot_ms: u64 = 90_000;
pub const harness_step_ms: u64 = 120_000;
pub const devices_file = "cloud-sandboxes.json";

// ---------------------------------------------------------------- transport

pub const HttpReply = struct {
    /// 0 when nothing was sent (no network, bad URL).
    status: u16,
    body: []u8,
};

pub const Transport = struct {
    ctx: ?*anyopaque = null,
    send_fn: *const fn (ctx: ?*anyopaque, gpa: Allocator, method: []const u8, url: []const u8, bearer: []const u8, body: ?[]const u8, timeout_ms: u64) anyerror!HttpReply,

    pub fn send(self: Transport, gpa: Allocator, method: []const u8, url: []const u8, bearer: []const u8, body: ?[]const u8, timeout_ms: u64) anyerror!HttpReply {
        return self.send_fn(self.ctx, gpa, method, url, bearer, body, timeout_ms);
    }
};

/// One call's context: who is signed in, where the gateway is, where names live.
pub const Ctx = struct {
    gpa: Allocator,
    transport: Transport,
    /// The Codegraff gateway key; null when signed out.
    key: ?[]const u8,
    gateway: []const u8,
    /// `<data>`; the device-name file lives here.
    data_dir: ?[]const u8 = null,
    io: ?std.Io = null,
    /// `HARNESS_CLOUD_SANDBOXES` is not `0`/`false`.
    enabled: bool = true,
    err_slot: *ErrSlot,
};

/// Holds the last error message until the next call (the engine writes it after we return).
pub const ErrSlot = struct {
    gpa: Allocator,
    msg: ?[]u8 = null,

    pub fn set(self: *ErrSlot, msg: []u8) []const u8 {
        if (self.msg) |old| self.gpa.free(old);
        self.msg = msg;
        return msg;
    }

    pub fn deinit(self: *ErrSlot) void {
        if (self.msg) |m| self.gpa.free(m);
        self.msg = null;
    }
};

pub fn enabledFor(flag: ?[]const u8) bool {
    const f = std.mem.trim(u8, flag orelse return true, " \t\r\n");
    return !(std.mem.eql(u8, f, "0") or std.mem.eql(u8, f, "false"));
}

// ---------------------------------------------------------------- model

pub const Sandbox = struct {
    id: []const u8 = "",
    provider: []const u8 = "",
    name: ?[]const u8 = null,
    state: []const u8 = "",
    tier: ?[]const u8 = null,
    expires_at: ?json.Value = null,
    harness: bool = false,
    device_name: ?[]const u8 = null,
    keep_running: ?bool = null,
    renew_error: ?[]const u8 = null,
    cpu: ?f64 = null,
    memory_gib: ?f64 = null,
    disk_gib: ?f64 = null,
    price_per_hour_micro_usd: ?i64 = null,
};

pub const Size = struct {
    id: []const u8,
    cpu: u32,
    memory_gib: u32,
    disk_gib: u32,
    price_per_hour_micro_usd: ?i64,
    default: bool,
};

fn getPath(v: json.Value, path: []const []const u8) ?json.Value {
    var cur = v;
    for (path) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn text(v: json.Value, path: []const []const u8) ?[]const u8 {
    const x = getPath(v, path) orelse return null;
    return if (x == .string) x.string else null;
}

fn number(v: json.Value, key: []const u8) ?f64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    const n: f64 = switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}

fn positive(n: ?f64) ?f64 {
    const x = n orelse return null;
    return if (x > 0) x else null;
}

/// The fleet's own words (`started`, `destroyed`) in the app's words.
pub fn normaliseState(state: ?[]const u8) []const u8 {
    const s = state orelse return "";
    if (std.mem.eql(u8, s, "started")) return "running";
    if (std.mem.eql(u8, s, "destroyed")) return "terminated";
    return s;
}

pub fn parseSandbox(v: json.Value) Sandbox {
    var sb: Sandbox = .{
        .id = text(v, &.{"id"}) orelse "",
        .provider = text(v, &.{"provider"}) orelse "",
        .name = text(v, &.{"name"}),
        .state = normaliseState(text(v, &.{"state"})),
        .tier = text(v, &.{"tier"}),
        .keep_running = if (getPath(v, &.{"keepRunning"})) |k| (if (k == .bool) k.bool else null) else null,
        .harness = if (getPath(v, &.{ "codegraff", "harness" })) |h| (h == .bool and h.bool) else false,
        .cpu = positive(number(v, "cpu")),
        .memory_gib = positive(number(v, "memoryGiB") orelse number(v, "memory")),
        .disk_gib = positive(number(v, "diskGiB") orelse number(v, "disk")),
    };
    if (sb.tier == null) {
        if (text(v, &.{ "labels", "harness-purpose" })) |p| {
            if (std.mem.eql(u8, p, "temporary")) sb.tier = "ephemeral";
        }
    }
    if (v == .object) {
        const ea = v.object.get("expiresAt") orelse v.object.get("expires_at");
        if (ea) |e| if (e != .null) {
            sb.expires_at = e;
        };
    }
    if (text(v, &.{"renewError"})) |r| {
        if (std.mem.trim(u8, r, " \t\r\n").len > 0) sb.renew_error = r;
    }
    if (number(v, "pricePerHourMicroUsd")) |p| {
        if (p >= 0) sb.price_per_hour_micro_usd = @intFromFloat(@round(p));
    }
    return sb;
}

/// The list may be a bare array or wrapped; terminated sandboxes are gone for good.
pub fn parseList(arena: Allocator, v: json.Value) ![]Sandbox {
    const rows: []const json.Value = switch (v) {
        .array => |a| a.items,
        .object => |o| blk: {
            for ([_][]const u8{ "sandboxes", "data", "items" }) |k| {
                if (o.get(k)) |x| if (x == .array) break :blk x.array.items;
            }
            break :blk &.{};
        },
        else => &.{},
    };
    var out: std.ArrayList(Sandbox) = .empty;
    for (rows) |row| {
        const sb = parseSandbox(row);
        if (sb.id.len == 0 or std.mem.eql(u8, sb.state, "terminated")) continue;
        try out.append(arena, sb);
    }
    return out.items;
}

/// The gateway's `{sizes:[...]}`; rows without an id or a machine are dropped; the first is default when none is.
pub fn parseSizes(arena: Allocator, v: json.Value) ![]Size {
    const rows = getPath(v, &.{"sizes"}) orelse return &.{};
    if (rows != .array) return &.{};
    var out: std.ArrayList(Size) = .empty;
    for (rows.array.items) |row| {
        const id_raw = text(row, &.{"id"}) orelse continue;
        const id = std.mem.trim(u8, id_raw, " \t\r\n");
        if (id.len == 0) continue;
        const cpu = whole(row, "cpu") orelse continue;
        const mem = whole(row, "memoryGiB") orelse continue;
        var price: ?i64 = null;
        if (number(row, "pricePerHourMicroUsd")) |p| {
            if (p >= 0) price = @intFromFloat(@round(p));
        }
        try out.append(arena, .{
            .id = id,
            .cpu = cpu,
            .memory_gib = mem,
            .disk_gib = whole(row, "diskGiB") orelse 0,
            .price_per_hour_micro_usd = price,
            .default = if (getPath(row, &.{"default"})) |d| (d == .bool and d.bool) else false,
        });
    }
    if (out.items.len > 0) {
        var any = false;
        for (out.items) |s| any = any or s.default;
        if (!any) out.items[0].default = true;
    }
    return out.items;
}

fn whole(row: json.Value, key: []const u8) ?u32 {
    const n = number(row, key) orelse return null;
    if (!(n > 0 and n < @as(f64, @floatFromInt(std.math.maxInt(u32))))) return null;
    return @intFromFloat(@round(n));
}

pub fn chosenSize(sizes: []const Size, wanted: ?[]const u8) ?Size {
    if (wanted) |w| for (sizes) |s| if (std.mem.eql(u8, s.id, w)) return s;
    for (sizes) |s| if (s.default) return s;
    return null;
}

/// A view without a price borrows the price of the size with the same vCPU and memory.
pub fn fillPrice(sb: *Sandbox, sizes: []const Size) void {
    if (sb.price_per_hour_micro_usd != null or std.mem.eql(u8, sb.provider, "daytona")) return;
    if (sb.tier) |t| if (std.mem.eql(u8, t, "ephemeral")) return;
    const cpu = sb.cpu orelse return;
    const mem = sb.memory_gib orelse return;
    for (sizes) |s| {
        if (@as(f64, @floatFromInt(s.cpu)) == cpu and @as(f64, @floatFromInt(s.memory_gib)) == mem) {
            sb.price_per_hour_micro_usd = s.price_per_hour_micro_usd;
            return;
        }
    }
}

/// A device name the gateway accepts, unique per sandbox (`Harness cloud ab12`).
pub fn deviceNameFor(buf: *[sandbox_name.len + 5]u8, sandbox_id: []const u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, sandbox_id, "cnd_")) sandbox_id[4..] else sandbox_id;
    @memcpy(buf[0..sandbox_name.len], sandbox_name);
    buf[sandbox_name.len] = ' ';
    var n: usize = 0;
    for (rest) |c| {
        if (n == 4) break;
        if (std.ascii.isAlphanumeric(c)) {
            buf[sandbox_name.len + 1 + n] = c;
            n += 1;
        }
    }
    return if (n == 0) sandbox_name else buf[0 .. sandbox_name.len + 1 + n];
}

pub fn urlencodeAlloc(gpa: Allocator, seg: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (seg) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') {
            try out.append(gpa, b);
        } else {
            try out.print(gpa, "%{X:0>2}", .{b});
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- JSON out

fn writeF64(w: *std.Io.Writer, x: f64) !void {
    if (x == @trunc(x) and @abs(x) < 1e15) {
        try w.print("{d}.0", .{@as(i64, @intFromFloat(x))});
    } else {
        try w.print("{d}", .{x});
    }
}

fn writeOptStr(w: *std.Io.Writer, s: ?[]const u8) !void {
    try w.print("{f}", .{json.fmt(s, .{})});
}

fn writeOptF64(w: *std.Io.Writer, x: ?f64) !void {
    if (x) |v| try writeF64(w, v) else try w.writeAll("null");
}

pub fn writeSandbox(w: *std.Io.Writer, sb: Sandbox) !void {
    try w.print("{{\"id\":{f},\"provider\":{f},\"name\":", .{ json.fmt(sb.id, .{}), json.fmt(sb.provider, .{}) });
    try writeOptStr(w, sb.name);
    try w.print(",\"state\":{f},\"tier\":", .{json.fmt(sb.state, .{})});
    try writeOptStr(w, sb.tier);
    try w.writeAll(",\"expiresAt\":");
    if (sb.expires_at) |e| try w.print("{f}", .{json.fmt(e, .{})}) else try w.writeAll("null");
    try w.print(",\"harness\":{},\"deviceName\":", .{sb.harness});
    try writeOptStr(w, sb.device_name);
    try w.print(",\"keepRunning\":{f},\"renewError\":", .{json.fmt(sb.keep_running, .{})});
    try writeOptStr(w, sb.renew_error);
    try w.writeAll(",\"cpu\":");
    try writeOptF64(w, sb.cpu);
    try w.writeAll(",\"memoryGiB\":");
    try writeOptF64(w, sb.memory_gib);
    try w.writeAll(",\"diskGiB\":");
    try writeOptF64(w, sb.disk_gib);
    try w.print(",\"pricePerHourMicroUsd\":{f}}}", .{json.fmt(sb.price_per_hour_micro_usd, .{})});
}

pub fn writeSize(w: *std.Io.Writer, s: Size) !void {
    try w.print("{{\"id\":{f},\"cpu\":{d},\"memoryGiB\":{d},\"diskGiB\":{d},\"pricePerHourMicroUsd\":{f},\"default\":{}}}", .{
        json.fmt(s.id, .{}), s.cpu, s.memory_gib, s.disk_gib, json.fmt(s.price_per_hour_micro_usd, .{}), s.default,
    });
}

// ---------------------------------------------------------------- failures

/// A gateway call that did not succeed.
pub const Failure = struct {
    /// 0 when nothing was sent.
    status: u16,
    body: ?json.Value = null,
    message: ?[]const u8 = null,

    pub fn errorType(self: Failure) ?[]const u8 {
        return text(self.body orelse return null, &.{ "error", "type" });
    }

    /// The gateway's own `error.message` as a sentence, else `fallback`; a few types get app wording.
    pub fn sentence(self: Failure, gpa: Allocator, fallback: []const u8) ![]u8 {
        if (self.errorType()) |t| {
            const known: ?[]const u8 = if (std.mem.eql(u8, t, "insufficient_credits"))
                "Your Codegraff credit is used up. Add credit and try again."
            else if (std.mem.eql(u8, t, "sandbox_not_running"))
                "The sandbox isn't running. Start it first."
            else if (std.mem.eql(u8, t, "insufficient_scope"))
                "This Codegraff sign-in can't manage sandboxes. Sign in again."
            else if (std.mem.eql(u8, t, "harness_cloud_unavailable"))
                "Harness cloud isn't available yet. Try again later."
            else
                null;
            if (known) |k| return gpa.dupe(u8, k);
        }
        const raw = self.message orelse if (self.body) |b| text(b, &.{ "error", "message" }) else null;
        if (raw) |r| {
            const m = std.mem.trim(u8, r, " \t\r\n");
            if (m.len > 0) {
                const body = std.mem.trimEnd(u8, m[1..], ".");
                return std.fmt.allocPrint(gpa, "{c}{s}.", .{ std.ascii.toUpper(m[0]), body });
            }
        }
        if (self.status == 0) return std.fmt.allocPrint(gpa, "{s}.", .{fallback});
        return std.fmt.allocPrint(gpa, "{s} ({d}).", .{ fallback, self.status });
    }
};

/// `validate_secure_url("CodeGraff gateway", ..)`: null when fine, else the reason.
pub fn gatewayProblem(url: []const u8) ?[]const u8 {
    const auth_host = @import("auth_host.zig");
    if (auth_host.isSecureUrl(url)) return null;
    _ = std.Uri.parse(url) catch return "CodeGraff gateway URL is invalid";
    return "CodeGraff gateway must use HTTPS (plain HTTP is allowed only on loopback)";
}

// ---------------------------------------------------------------- client

const Call = union(enum) { ok: json.Value, fail: Failure };

const Client = struct {
    ctx: Ctx,
    arena: Allocator,

    fn call(self: Client, method: []const u8, path: []const u8, body: ?[]const u8, timeout_ms: u64) !Call {
        const key = self.ctx.key orelse return .{ .fail = .{ .status = 0, .message = "Sign in with Codegraff first" } };
        if (gatewayProblem(self.ctx.gateway)) |p| return .{ .fail = .{ .status = 0, .message = p } };
        const url = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ std.mem.trimEnd(u8, self.ctx.gateway, "/"), path });
        const reply = self.ctx.transport.send(self.arena, method, url, key, body, timeout_ms) catch |e| {
            return .{ .fail = .{ .status = 0, .message = try std.fmt.allocPrint(self.arena, "couldn't reach CodeGraff: {s}", .{@errorName(e)}) } };
        };
        if (reply.status == 0) {
            return .{ .fail = .{ .status = 0, .message = try std.fmt.allocPrint(self.arena, "couldn't reach CodeGraff: {s}", .{reply.body}) } };
        }
        const parsed: ?json.Value = json.parseFromSliceLeaky(json.Value, self.arena, reply.body, .{}) catch null;
        if (reply.status >= 200 and reply.status < 300) return .{ .ok = parsed orelse .null };
        return .{ .fail = .{ .status = reply.status, .body = parsed } };
    }

    fn idPath(self: Client, id: []const u8, tail: []const u8) ![]u8 {
        const enc = try urlencodeAlloc(self.arena, id);
        return std.fmt.allocPrint(self.arena, "/v1/sandboxes/{s}{s}", .{ enc, tail });
    }

    fn namesPath(self: Client) ?[]u8 {
        const d = self.ctx.data_dir orelse return null;
        return std.fmt.allocPrint(self.arena, "{s}/" ++ devices_file, .{std.mem.trimEnd(u8, d, "/")}) catch null;
    }

    /// `sandbox id → device name`, as remembered at create time.
    fn deviceNames(self: Client) !std.StringArrayHashMapUnmanaged([]const u8) {
        var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        const io = self.ctx.io orelse return map;
        const p = self.namesPath() orelse return map;
        const raw = std.Io.Dir.cwd().readFileAlloc(io, p, self.arena, .limited(1 << 20)) catch return map;
        const v = json.parseFromSliceLeaky(json.Value, self.arena, raw, .{}) catch return map;
        if (v != .object) return map;
        var it = v.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .string) try map.put(self.arena, e.key_ptr.*, e.value_ptr.string);
        }
        return map;
    }

    fn saveDeviceNames(self: Client, names: *std.StringArrayHashMapUnmanaged([]const u8)) void {
        const io = self.ctx.io orelse return;
        const p = self.namesPath() orelse return;
        const ByKey = struct {
            keys: []const []const u8,
            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, c.keys[a], c.keys[b]) == .lt;
            }
        };
        names.sort(ByKey{ .keys = names.keys() });
        var aw: std.Io.Writer.Allocating = .init(self.arena);
        const w = &aw.writer;
        w.writeAll("{") catch return;
        var first = true;
        var it = names.iterator();
        while (it.next()) |e| {
            w.print("{s}\n  {f}: {f}", .{ if (first) "" else ",", json.fmt(e.key_ptr.*, .{}), json.fmt(e.value_ptr.*, .{}) }) catch return;
            first = false;
        }
        w.writeAll(if (first) "}" else "\n}") catch return;
        const staged = std.fmt.allocPrint(self.arena, "{s}.tmp", .{p}) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staged, .data = aw.written() }) catch return;
        std.Io.Dir.rename(std.Io.Dir.cwd(), staged, std.Io.Dir.cwd(), p, io) catch {};
    }

    fn personalSizes(self: Client) ![]Size {
        return switch (try self.call("GET", "/v1/sandboxes/personal-sizes", null, quick_ms)) {
            .ok => |v| parseSizes(self.arena, v),
            .fail => &.{},
        };
    }

    fn attachHarness(self: Client, id: []const u8, device_name: []const u8) !?Failure {
        const p = try self.idPath(id, "/harness");
        const body = try std.fmt.allocPrint(self.arena, "{{\"deviceName\":{f}}}", .{json.fmt(device_name, .{})});
        const first = try self.call("POST", p, body, harness_step_ms);
        switch (first) {
            .ok => return null,
            .fail => |f| {
                const t = f.errorType() orelse return f;
                if (!std.mem.eql(u8, t, "harness_start_failed")) return f;
                return switch (try self.call("POST", p, body, harness_step_ms)) {
                    .ok => null,
                    .fail => |f2| f2,
                };
            },
        }
    }
};

pub const Reply = union(enum) {
    ok: []u8,
    bad_params: []const u8,
    failed: []const u8,
};

fn failWith(ctx: Ctx, f: Failure, fallback: []const u8) !Reply {
    return .{ .failed = ctx.err_slot.set(try f.sentence(ctx.err_slot.gpa, fallback)) };
}

fn failText(ctx: Ctx, msg: []const u8) !Reply {
    return .{ .failed = ctx.err_slot.set(try ctx.err_slot.gpa.dupe(u8, msg)) };
}

fn render(reply_gpa: Allocator, comptime f: anytype, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(reply_gpa);
    errdefer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

/// `CodegraffSandboxes`: `null` when signed out; `enabled:false` when this build turns them off.
pub fn list(ctx: Ctx, reply_gpa: Allocator) !Reply {
    if (ctx.key == null) return .{ .ok = try reply_gpa.dupe(u8, "null") };
    if (!ctx.enabled) return .{ .ok = try reply_gpa.dupe(u8, "{\"enabled\":false,\"sandboxes\":[],\"sizes\":[]}") };
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const c: Client = .{ .ctx = ctx, .arena = arena_state.allocator() };
    const listed = try c.call("GET", "/v1/sandboxes", null, quick_ms);
    const sizes = try c.personalSizes();
    const value = switch (listed) {
        .ok => |v| v,
        .fail => |f| return failWith(ctx, f, "CodeGraff sandboxes are unavailable"),
    };
    const names = try c.deviceNames();
    const rows = try parseList(c.arena, value);
    for (rows) |*sb| {
        sb.device_name = names.get(sb.id);
        sb.harness = sb.harness or sb.device_name != null;
        fillPrice(sb, sizes);
    }
    return .{ .ok = try render(reply_gpa, writeList, .{ rows, sizes }) };
}

fn writeList(w: *std.Io.Writer, rows: []const Sandbox, sizes: []const Size) !void {
    try w.writeAll("{\"enabled\":true,\"sandboxes\":[");
    for (rows, 0..) |sb, i| {
        if (i > 0) try w.writeByte(',');
        try writeSandbox(w, sb);
    }
    try w.writeAll("],\"sizes\":[");
    for (sizes, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try writeSize(w, s);
    }
    try w.writeAll("]}");
}

/// `CodegraffCreateTemporarySandbox`: a short-lived sandbox; no Harness, no renewal.
pub fn createTemporary(ctx: Ctx, reply_gpa: Allocator) !Reply {
    if (!ctx.enabled) return failText(ctx, "Cloud sandboxes are not available in this build.");
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const c: Client = .{ .ctx = ctx, .arena = arena_state.allocator() };
    const body = "{\"provider\":\"auto\",\"ephemeral\":true,\"name\":\"Temporary sandbox\",\"autoStopMinutes\":30,\"labels\":{\"harness-purpose\":\"temporary\"}}";
    const created = switch (try c.call("POST", "/v1/sandboxes", body, boot_ms)) {
        .ok => |v| v,
        .fail => |f| return failWith(ctx, f, "CodeGraff couldn't create the temporary sandbox"),
    };
    const sb = parseSandbox(created);
    if (sb.id.len == 0) return failText(ctx, "CodeGraff created a sandbox but didn't say which one.");
    return .{ .ok = try render(reply_gpa, writeSandbox, .{sb}) };
}

/// `CodegraffCreateSandbox`: the account's Harness cloud sandbox at `size` (or the default), with Harness set up.
pub fn create(ctx: Ctx, reply_gpa: Allocator, size: ?[]const u8) !Reply {
    if (!ctx.enabled) return failText(ctx, "Cloud sandboxes are not available in this build.");
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const c: Client = .{ .ctx = ctx, .arena = arena_state.allocator() };
    const sizes = try c.personalSizes();
    const chosen = chosenSize(sizes, size);
    var body: std.Io.Writer.Allocating = .init(c.arena);
    try body.writer.print("{{\"provider\":\"{s}\",\"persistent\":true,\"name\":\"{s}\",\"autoStopMinutes\":{d},\"keepRunning\":true", .{ fleet, sandbox_name, auto_stop_minutes });
    if (chosen) |s| {
        try body.writer.print(",\"cpu\":{d},\"memory\":{d}", .{ s.cpu, s.memory_gib });
        if (s.disk_gib > 0) try body.writer.print(",\"disk\":{d}", .{s.disk_gib});
    }
    try body.writer.writeByte('}');
    const created = switch (try c.call("POST", "/v1/sandboxes", body.written(), boot_ms)) {
        .ok => |v| v,
        .fail => |f| return failWith(ctx, f, "CodeGraff couldn't create the sandbox"),
    };
    var sb = parseSandbox(created);
    if (sb.id.len == 0) return failText(ctx, "CodeGraff created a sandbox but didn't say which one.");
    if (chosen) |s| {
        if (sb.cpu == null) sb.cpu = @floatFromInt(s.cpu);
        if (sb.memory_gib == null) sb.memory_gib = @floatFromInt(s.memory_gib);
        if (s.disk_gib > 0 and sb.disk_gib == null) sb.disk_gib = @floatFromInt(s.disk_gib);
        if (sb.price_per_hour_micro_usd == null) sb.price_per_hour_micro_usd = s.price_per_hour_micro_usd;
    }
    var nbuf: [sandbox_name.len + 5]u8 = undefined;
    const device_name = try c.arena.dupe(u8, deviceNameFor(&nbuf, sb.id));
    var names = try c.deviceNames();
    try names.put(c.arena, sb.id, device_name);
    c.saveDeviceNames(&names);
    if (try c.attachHarness(sb.id, device_name)) |f| {
        const why = try f.sentence(c.arena, "setup failed");
        return failText(ctx, try std.fmt.allocPrint(c.arena, "The sandbox was created, but Harness couldn't be set up in it ({s}) Use Start on it to try again.", .{why}));
    }
    sb.state = "running";
    sb.harness = true;
    sb.device_name = device_name;
    return .{ .ok = try render(reply_gpa, writeSandbox, .{sb}) };
}

pub const Action = enum { start, stop, delete, keep_running_on, keep_running_off };

pub const action_map = std.StaticStringMap(Action).initComptime(.{
    .{ "start", .start },
    .{ "stop", .stop },
    .{ "delete", .delete },
    .{ "keep-running-on", .keep_running_on },
    .{ "keep-running-off", .keep_running_off },
});

/// `CodegraffSandboxAction` `{id, action}` → `{ok:true}`.
pub fn action(ctx: Ctx, reply_gpa: Allocator, id: []const u8, act: Action) !Reply {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const c: Client = .{ .ctx = ctx, .arena = arena_state.allocator() };
    switch (act) {
        .start => {
            const current = switch (try c.call("GET", try c.idPath(id, ""), null, quick_ms)) {
                .ok => |v| v,
                .fail => |f| return failWith(ctx, f, "CodeGraff couldn't read the sandbox"),
            };
            if (!std.mem.eql(u8, parseSandbox(current).state, "running")) {
                const body = try std.fmt.allocPrint(c.arena, "{{\"leaseSeconds\":{d},\"keepRunning\":true}}", .{wake_lease_seconds});
                switch (try c.call("POST", try c.idPath(id, "/start"), body, boot_ms)) {
                    .ok => {},
                    .fail => |f| return failWith(ctx, f, "CodeGraff couldn't start the sandbox"),
                }
            }
            var names = try c.deviceNames();
            var nbuf: [sandbox_name.len + 5]u8 = undefined;
            const remembered = names.get(id);
            const device_name = remembered orelse try c.arena.dupe(u8, deviceNameFor(&nbuf, id));
            if (try c.attachHarness(id, device_name)) |f| {
                return failWith(ctx, f, "The sandbox is running but Harness couldn't be set up in it; try Start again");
            }
            if (remembered == null) {
                try names.put(c.arena, id, device_name);
                c.saveDeviceNames(&names);
            }
        },
        .stop => switch (try c.call("POST", try c.idPath(id, "/stop"), null, quick_ms)) {
            .ok => {},
            .fail => |f| return failWith(ctx, f, "CodeGraff couldn't stop the sandbox"),
        },
        .delete => {
            switch (try c.call("DELETE", try c.idPath(id, ""), null, quick_ms)) {
                .ok => {},
                .fail => |f| return failWith(ctx, f, "CodeGraff couldn't delete the sandbox"),
            }
            var names = try c.deviceNames();
            if (names.orderedRemove(id)) c.saveDeviceNames(&names);
        },
        .keep_running_on, .keep_running_off => {
            const body = if (act == .keep_running_on) "{\"enabled\":true}" else "{\"enabled\":false}";
            switch (try c.call("POST", try c.idPath(id, "/keep-running"), body, quick_ms)) {
                .ok => {},
                .fail => |f| return failWith(ctx, f, "CodeGraff couldn't change whether the sandbox keeps running"),
            }
        },
    }
    return .{ .ok = try reply_gpa.dupe(u8, "{\"ok\":true}") };
}

pub const Method = enum { list, create, create_temporary, action };

/// Dispatch one sandbox RPC with the Rust engine's parameter handling.
pub fn handle(ctx: Ctx, reply_gpa: Allocator, method: Method, params: json.Value) !Reply {
    switch (method) {
        .list => return list(ctx, reply_gpa),
        .create_temporary => return createTemporary(ctx, reply_gpa),
        .create => {
            var size: ?[]const u8 = null;
            if (params == .object) {
                if (params.object.get("size")) |v| if (v == .string) {
                    const t = std.mem.trim(u8, v.string, " \t\r\n");
                    if (t.len > 0) size = t;
                };
            }
            return create(ctx, reply_gpa, size);
        },
        .action => {
            const id_v = if (params == .object) params.object.get("id") else null;
            const id = if (id_v) |v| (if (v == .string) v.string else null) else null;
            if (id == null) return .{ .failed = "missing sandbox id" };
            const act_v = if (params == .object) params.object.get("action") else null;
            const act_s = if (act_v) |v| (if (v == .string) v.string else null) else null;
            const act = action_map.get(act_s orelse "") orelse return .{ .failed = "unknown sandbox action" };
            return action(ctx, reply_gpa, id.?, act);
        },
    }
}

pub fn toOutcome(comptime Outcome: type, r: Reply) Outcome {
    return switch (r) {
        .ok => |body| .{ .unary_json = body },
        .bad_params => |m| .{ .err = .{ .bad_params = m } },
        .failed => |m| .{ .err = .{ .exec_error = m } },
    };
}

// ---------------------------------------------------------------- the engine's wiring

var shared_slot: ErrSlot = .{ .gpa = std.heap.smp_allocator };
var shared_io: ?std.Io = null;

fn sendEdge(ctx: ?*anyopaque, gpa: Allocator, method: []const u8, url: []const u8, bearer: []const u8, body: ?[]const u8, timeout_ms: u64) anyerror!HttpReply {
    _ = ctx;
    _ = timeout_ms;
    const io = shared_io orelse return error.NoIo;
    const auth_host = @import("auth_host.zig");
    const r = try auth_host.AuthManager.edgeRequest(gpa, io, method, url, bearer, body);
    return .{ .status = r.status, .body = r.body };
}

/// The engine's context: the CodeGraff key and gateway from the host's auth state.
pub fn engineCtx(io: ?std.Io, key: ?[]const u8, gateway: []const u8, data_dir: ?[]const u8) Ctx {
    shared_io = io;
    const env_key = proc.getenv("CODEGRAFF_API_KEY");
    const k = key orelse if (env_key) |e| (if (std.mem.trim(u8, e, " \t\r\n").len > 0) e else null) else null;
    return .{
        .gpa = std.heap.smp_allocator,
        .transport = .{ .send_fn = sendEdge },
        .key = k,
        .gateway = gateway,
        .data_dir = data_dir,
        .io = io,
        .enabled = enabledFor(proc.getenv("HARNESS_CLOUD_SANDBOXES")),
        .err_slot = &shared_slot,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A made-up gateway: each request takes the first matching route not yet
/// used, else the last match repeats, else 404 `{}`. Every request is recorded.
pub const FakeGateway = struct {
    pub const Route = struct { line: []const u8, status: u16, body: []const u8 };
    pub const Seen = struct { line: []u8, body: ?[]u8 };

    gpa: Allocator,
    routes: []const Route,
    used: [16]bool = @splat(false),
    seen: std.ArrayList(Seen) = .empty,
    base: []const u8 = "https://gateway.test",

    pub fn deinit(self: *FakeGateway) void {
        for (self.seen.items) |s| {
            self.gpa.free(s.line);
            if (s.body) |b| self.gpa.free(b);
        }
        self.seen.deinit(self.gpa);
    }

    pub fn transport(self: *FakeGateway) Transport {
        return .{ .ctx = self, .send_fn = send };
    }

    fn send(ctx: ?*anyopaque, gpa: Allocator, method: []const u8, url: []const u8, bearer: []const u8, body: ?[]const u8, _: u64) anyerror!HttpReply {
        const self: *FakeGateway = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(std.mem.startsWith(u8, url, self.base));
        if (!std.mem.eql(u8, bearer, "cg_sk_test")) return .{ .status = 401, .body = try gpa.dupe(u8, "{}") };
        const line = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ method, url[self.base.len..] });
        try self.seen.append(self.gpa, .{ .line = line, .body = if (body) |b| try self.gpa.dupe(u8, b) else null });
        var pick: ?usize = null;
        var last: ?usize = null;
        for (self.routes, 0..) |r, i| {
            if (!std.mem.eql(u8, r.line, line)) continue;
            last = i;
            if (pick == null and !self.used[i]) pick = i;
        }
        const idx = pick orelse last orelse return .{ .status = 404, .body = try gpa.dupe(u8, "{}") };
        self.used[idx] = true;
        return .{ .status = self.routes[idx].status, .body = try gpa.dupe(u8, self.routes[idx].body) };
    }

    pub fn lines(self: *const FakeGateway, i: usize) []const u8 {
        return self.seen.items[i].line;
    }
};

fn testCtx(gw: *FakeGateway, slot: *ErrSlot, data_dir: ?[]const u8) Ctx {
    return .{
        .gpa = testing.allocator,
        .transport = gw.transport(),
        .key = "cg_sk_test",
        .gateway = gw.base,
        .data_dir = data_dir,
        .io = if (data_dir != null) testing.io else null,
        .err_slot = slot,
    };
}

fn expectJsonEq(expected: []const u8, actual: []const u8) !void {
    const a = try json.parseFromSlice(json.Value, testing.allocator, expected, .{});
    defer a.deinit();
    const b = try json.parseFromSlice(json.Value, testing.allocator, actual, .{});
    defer b.deinit();
    const sa = try json.Stringify.valueAlloc(testing.allocator, a.value, .{});
    defer testing.allocator.free(sa);
    const sb = try json.Stringify.valueAlloc(testing.allocator, b.value, .{});
    defer testing.allocator.free(sb);
    if (!jsonEqual(a.value, b.value)) {
        std.debug.print("expected {s}\n   found {s}\n", .{ sa, sb });
        return error.TestExpectedEqual;
    }
}

fn jsonEqual(a: json.Value, b: json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) {
        const fa: ?f64 = switch (a) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        const fb: ?f64 = switch (b) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        return fa != null and fb != null and fa.? == fb.?;
    }
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const o = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(e.value_ptr.*, o)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn tmpDataDir(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
}

test "sandboxes: every build offers them unless the flag turns them off" {
    try testing.expect(enabledFor(null));
    try testing.expect(enabledFor("1"));
    try testing.expect(enabledFor(""));
    try testing.expect(!enabledFor("0"));
    try testing.expect(!enabledFor(" false "));
}

test "sandboxes: lists use the app's state words and drop destroyed rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started","expiresAt":1790000000,"future":1},
        \\ {"id":"cnd_2","provider":"fleet","state":"destroyed"},{"id":"sb_3","provider":"daytona","state":"terminated"},
        \\ {"id":"cnd_4","state":"paused"},{"id":"cnd_5","state":"starting"}]}
    , .{});
    const rows = try parseList(a, v);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("running", rows[0].state);
    try testing.expectEqualStrings("cnd_4", rows[1].id);
    try testing.expect(rows[0].expires_at != null);
    try testing.expectEqual(@as(usize, 0), (try parseList(a, try json.parseFromSliceLeaky(json.Value, a, "{\"error\":\"nope\"}", .{}))).len);
}

test "sandboxes: sizes parse tolerantly and always have a default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loose = try parseSizes(a, try json.parseFromSliceLeaky(json.Value, a,
        \\{"sizes":[{"id":"","cpu":2,"memoryGiB":4},{"id":"tiny","cpu":"two","memoryGiB":1},
        \\ {"id":"big","cpu":8.0,"memoryGiB":16,"pricePerHourMicroUsd":400000.4},{"id":"huge","cpu":16,"memoryGiB":32}]}
    , .{}));
    try testing.expectEqual(@as(usize, 2), loose.len);
    try testing.expectEqualStrings("big", loose[0].id);
    try testing.expect(loose[0].default and !loose[1].default);
    try testing.expectEqual(@as(?i64, 400000), loose[0].price_per_hour_micro_usd);
    try testing.expectEqual(@as(?i64, null), loose[1].price_per_hour_micro_usd);
}

test "sandboxes: views carry the machine and price, and borrow a size's price" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sizes = try parseSizes(a, try json.parseFromSliceLeaky(json.Value, a,
        \\{"sizes":[{"id":"standard","cpu":2,"memoryGiB":4,"diskGiB":40,"pricePerHourMicroUsd":100000,"default":true},
        \\ {"id":"large","cpu":4,"memoryGiB":8,"diskGiB":40,"pricePerHourMicroUsd":200000}]}
    , .{}));
    var unpriced = parseSandbox(try json.parseFromSliceLeaky(json.Value, a, "{\"id\":\"x\",\"cpu\":4,\"memoryGiB\":8}", .{}));
    fillPrice(&unpriced, sizes);
    try testing.expectEqual(@as(?i64, 200000), unpriced.price_per_hour_micro_usd);
    const odd = parseSandbox(try json.parseFromSliceLeaky(json.Value, a, "{\"id\":\"cnd_1\",\"cpu\":\"2\",\"pricePerHourMicroUsd\":-1}", .{}));
    try testing.expectEqual(@as(?f64, null), odd.cpu);
    try testing.expectEqual(@as(?i64, null), odd.price_per_hour_micro_usd);
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeSandbox(&aw.writer, parseSandbox(try json.parseFromSliceLeaky(json.Value, a, "{\"id\":\"cnd_1\",\"state\":\"started\",\"cpu\":2,\"memoryGiB\":4,\"keepRunning\":true,\"renewError\":\" \"}", .{})));
    try testing.expectEqualStrings(
        "{\"id\":\"cnd_1\",\"provider\":\"\",\"name\":null,\"state\":\"running\",\"tier\":null,\"expiresAt\":null,\"harness\":false,\"deviceName\":null,\"keepRunning\":true,\"renewError\":null,\"cpu\":2.0,\"memoryGiB\":4.0,\"diskGiB\":null,\"pricePerHourMicroUsd\":null}",
        aw.written(),
    );
}

test "sandboxes: signed out lists nothing and never calls the gateway" {
    var gw: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{} };
    defer gw.deinit();
    var slot: ErrSlot = .{ .gpa = testing.allocator };
    defer slot.deinit();
    var ctx = testCtx(&gw, &slot, null);
    ctx.key = null;
    const r = try handle(ctx, testing.allocator, .list, .null);
    defer testing.allocator.free(r.ok);
    try testing.expectEqualStrings("null", r.ok);
    try testing.expectEqual(@as(usize, 0), gw.seen.items.len);
    ctx.key = "cg_sk_test";
    ctx.enabled = false;
    const off = try handle(ctx, testing.allocator, .list, .null);
    defer testing.allocator.free(off.ok);
    try testing.expectEqualStrings("{\"enabled\":false,\"sandboxes\":[],\"sizes\":[]}", off.ok);
    try testing.expectEqualStrings("Cloud sandboxes are not available in this build.", (try handle(ctx, testing.allocator, .create, .null)).failed);
}

test "sandboxes: the list joins the remembered device name, and delete forgets it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDataDir(&tmp);
    defer testing.allocator.free(dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = devices_file, .data = "{\"cnd_1\":\"Harness cloud 0001\"}" });
    var gw: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{
        .{ .line = "GET /v1/sandboxes", .status = 200, .body = "{\"sandboxes\":[{\"id\":\"cnd_1\",\"provider\":\"fleet\",\"state\":\"started\",\"cpu\":2,\"memoryGiB\":4},{\"id\":\"cnd_2\",\"provider\":\"fleet\",\"state\":\"paused\"}]}" },
        .{ .line = "GET /v1/sandboxes/personal-sizes", .status = 200, .body = "{\"sizes\":[{\"id\":\"standard\",\"cpu\":2,\"memoryGiB\":4,\"diskGiB\":40,\"pricePerHourMicroUsd\":100000,\"default\":true}]}" },
        .{ .line = "DELETE /v1/sandboxes/cnd_1", .status = 200, .body = "{}" },
    } };
    defer gw.deinit();
    var slot: ErrSlot = .{ .gpa = testing.allocator };
    defer slot.deinit();
    const ctx = testCtx(&gw, &slot, dir);
    const r = try handle(ctx, testing.allocator, .list, .null);
    defer testing.allocator.free(r.ok);
    try expectJsonEq(
        \\{"enabled":true,"sandboxes":[
        \\ {"id":"cnd_1","provider":"fleet","name":null,"state":"running","tier":null,"expiresAt":null,"harness":true,"deviceName":"Harness cloud 0001","keepRunning":null,"renewError":null,"cpu":2,"memoryGiB":4,"diskGiB":null,"pricePerHourMicroUsd":100000},
        \\ {"id":"cnd_2","provider":"fleet","name":null,"state":"paused","tier":null,"expiresAt":null,"harness":false,"deviceName":null,"keepRunning":null,"renewError":null,"cpu":null,"memoryGiB":null,"diskGiB":null,"pricePerHourMicroUsd":null}],
        \\ "sizes":[{"id":"standard","cpu":2,"memoryGiB":4,"diskGiB":40,"pricePerHourMicroUsd":100000,"default":true}]}
    , r.ok);
    const p = try json.parseFromSlice(json.Value, testing.allocator, "{\"id\":\"cnd_1\",\"action\":\"delete\"}", .{});
    defer p.deinit();
    const d = try handle(ctx, testing.allocator, .action, p.value);
    defer testing.allocator.free(d.ok);
    try testing.expectEqualStrings("{\"ok\":true}", d.ok);
    const left = try tmp.dir.readFileAlloc(testing.io, devices_file, testing.allocator, .limited(4096));
    defer testing.allocator.free(left);
    try testing.expectEqualStrings("{}", left);
}

test "sandboxes: create makes a fleet sandbox and sets Harness up under a unique name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDataDir(&tmp);
    defer testing.allocator.free(dir);
    var gw: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{
        .{ .line = "POST /v1/sandboxes", .status = 201, .body = "{\"id\":\"cnd_ab12cd\",\"provider\":\"fleet\",\"state\":\"started\",\"tier\":\"persistent\",\"expiresAt\":1790000000}" },
        .{ .line = "POST /v1/sandboxes/cnd_ab12cd/harness", .status = 200, .body = "{\"id\":\"cnd_ab12cd\"}" },
    } };
    defer gw.deinit();
    var slot: ErrSlot = .{ .gpa = testing.allocator };
    defer slot.deinit();
    const r = try handle(testCtx(&gw, &slot, dir), testing.allocator, .create, .null);
    defer testing.allocator.free(r.ok);
    try expectJsonEq(
        \\{"id":"cnd_ab12cd","provider":"fleet","name":null,"state":"running","tier":"persistent","expiresAt":1790000000,"harness":true,"deviceName":"Harness cloud ab12","keepRunning":null,"renewError":null,"cpu":null,"memoryGiB":null,"diskGiB":null,"pricePerHourMicroUsd":null}
    , r.ok);
    try testing.expectEqualStrings("GET /v1/sandboxes/personal-sizes", gw.lines(0));
    try testing.expectEqualStrings("{\"deviceName\":\"Harness cloud ab12\"}", gw.seen.items[2].body.?);
    const names = try tmp.dir.readFileAlloc(testing.io, devices_file, testing.allocator, .limited(4096));
    defer testing.allocator.free(names);
    try testing.expect(std.mem.indexOf(u8, names, "\"cnd_ab12cd\": \"Harness cloud ab12\"") != null);
}

test "sandboxes: error replies in the app's words" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDataDir(&tmp);
    defer testing.allocator.free(dir);
    var gw: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{
        .{ .line = "POST /v1/sandboxes", .status = 201, .body = "{\"id\":\"cnd_aa\",\"provider\":\"fleet\",\"state\":\"started\"}" },
        .{ .line = "POST /v1/sandboxes/cnd_aa/harness", .status = 503, .body = "{\"error\":{\"type\":\"harness_cloud_unavailable\",\"message\":\"no pinned build\"}}" },
        .{ .line = "POST /v1/sandboxes/cnd_1/keep-running", .status = 402, .body = "{\"error\":{\"type\":\"insufficient_credits\",\"message\":\"x\"}}" },
        .{ .line = "GET /v1/sandboxes/cnd_2", .status = 200, .body = "{\"state\":\"paused\"}" },
        .{ .line = "POST /v1/sandboxes/cnd_2/start", .status = 200, .body = "{}" },
        .{ .line = "POST /v1/sandboxes/cnd_2/harness", .status = 500, .body = "{}" },
        .{ .line = "GET /v1/sandboxes", .status = 500, .body = "" },
    } };
    defer gw.deinit();
    var slot: ErrSlot = .{ .gpa = testing.allocator };
    defer slot.deinit();
    const ctx = testCtx(&gw, &slot, dir);
    const created = (try handle(ctx, testing.allocator, .create, .null)).failed;
    try testing.expectEqualStrings("The sandbox was created, but Harness couldn't be set up in it (Harness cloud isn't available yet. Try again later.) Use Start on it to try again.", created);

    const keep = try json.parseFromSlice(json.Value, testing.allocator, "{\"id\":\"cnd_1\",\"action\":\"keep-running-on\"}", .{});
    defer keep.deinit();
    try testing.expectEqualStrings("Your Codegraff credit is used up. Add credit and try again.", (try handle(ctx, testing.allocator, .action, keep.value)).failed);

    const start = try json.parseFromSlice(json.Value, testing.allocator, "{\"id\":\"cnd_2\",\"action\":\"start\"}", .{});
    defer start.deinit();
    try testing.expectEqualStrings("The sandbox is running but Harness couldn't be set up in it; try Start again (500).", (try handle(ctx, testing.allocator, .action, start.value)).failed);

    try testing.expectEqualStrings("CodeGraff sandboxes are unavailable (500).", (try handle(ctx, testing.allocator, .list, .null)).failed);

    try testing.expectEqualStrings("missing sandbox id", (try handle(ctx, testing.allocator, .action, .{ .object = .empty })).failed);
    const bad = try json.parseFromSlice(json.Value, testing.allocator, "{\"id\":\"cnd_1\",\"action\":\"explode\"}", .{});
    defer bad.deinit();
    try testing.expectEqualStrings("unknown sandbox action", (try handle(ctx, testing.allocator, .action, bad.value)).failed);

    var no_key = ctx;
    no_key.key = null;
    try testing.expectEqualStrings("Sign in with Codegraff first.", (try handle(no_key, testing.allocator, .create_temporary, .null)).failed);
    var plain = ctx;
    plain.gateway = "http://gateway.example";
    try testing.expectEqualStrings("CodeGraff gateway must use HTTPS (plain HTTP is allowed only on loopback).", (try handle(plain, testing.allocator, .create_temporary, .null)).failed);
}

test "sandboxes: a failed install is retried once, and ids stay one path segment" {
    var gw: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{
        .{ .line = "GET /v1/sandboxes/cnd_1", .status = 200, .body = "{\"id\":\"cnd_1\",\"state\":\"started\"}" },
        .{ .line = "POST /v1/sandboxes/cnd_1/harness", .status = 502, .body = "{\"error\":{\"type\":\"harness_start_failed\",\"message\":\"Harness could not be installed/started in the sandbox.\"}}" },
        .{ .line = "POST /v1/sandboxes/cnd_1/harness", .status = 200, .body = "{\"id\":\"cnd_1\"}" },
        .{ .line = "DELETE /v1/sandboxes/..%2Fx", .status = 200, .body = "{}" },
    } };
    defer gw.deinit();
    var slot: ErrSlot = .{ .gpa = testing.allocator };
    defer slot.deinit();
    const ctx = testCtx(&gw, &slot, null);
    const start = try json.parseFromSlice(json.Value, testing.allocator, "{\"id\":\"cnd_1\",\"action\":\"start\"}", .{});
    defer start.deinit();
    const r = try handle(ctx, testing.allocator, .action, start.value);
    defer testing.allocator.free(r.ok);
    try testing.expectEqual(@as(usize, 3), gw.seen.items.len);
    try testing.expectEqualStrings("POST /v1/sandboxes/cnd_1/harness", gw.lines(2));
    const del = try json.parseFromSlice(json.Value, testing.allocator, "{\"id\":\"../x\",\"action\":\"delete\"}", .{});
    defer del.deinit();
    const d = try handle(ctx, testing.allocator, .action, del.value);
    defer testing.allocator.free(d.ok);
    try testing.expectEqualStrings("DELETE /v1/sandboxes/..%2Fx", gw.lines(3));
}

// ---- apps/parity/vectors/cloud-sandbox.json: the shared contract ----

const vectors_dir = @import("parity_options").vectors_dir;

fn loadVector(a: Allocator) !json.Value {
    const path = try std.fs.path.join(a, &.{ vectors_dir, "cloud-sandbox.json" });
    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(4 << 20));
    return json.parseFromSliceLeaky(json.Value, a, raw, .{});
}

fn fill(a: Allocator, s: []const u8, id: []const u8, name: []const u8) ![]u8 {
    const one = try std.mem.replaceOwned(u8, a, s, "{id}", id);
    return std.mem.replaceOwned(u8, a, one, "{deviceName}", name);
}

fn expectPlan(a: Allocator, gw: *const FakeGateway, from: usize, plan: json.Value, id: []const u8, name: []const u8) !usize {
    for (plan.array.items, 0..) |step, i| {
        const seen = gw.seen.items[from + i];
        const want_line = try std.fmt.allocPrint(a, "{s} {s}", .{ step.object.get("method").?.string, try fill(a, step.object.get("path").?.string, id, name) });
        try testing.expectEqualStrings(want_line, seen.line);
        if (step.object.get("body")) |b| {
            const want_body = try fill(a, try json.Stringify.valueAlloc(a, b, .{}), id, name);
            try expectJsonEq(want_body, seen.body.?);
        } else try testing.expect(seen.body == null);
    }
    return from + plan.array.items.len;
}

test "sandboxes: the shared vector's state words, device names and error sentences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try loadVector(a);
    var it = v.object.get("stateWords").?.object.iterator();
    while (it.next()) |e| try testing.expectEqualStrings(e.value_ptr.string, normaliseState(e.key_ptr.*));
    for (v.object.get("hiddenStates").?.array.items) |h| {
        const row = try std.fmt.allocPrint(a, "[{{\"id\":\"x\",\"state\":{f}}}]", .{json.fmt(h.string, .{})});
        try testing.expectEqual(@as(usize, 0), (try parseList(a, try json.parseFromSliceLeaky(json.Value, a, row, .{}))).len);
    }
    for (v.object.get("deviceNames").?.array.items) |c| {
        var buf: [sandbox_name.len + 5]u8 = undefined;
        try testing.expectEqualStrings(c.object.get("name").?.string, deviceNameFor(&buf, c.object.get("id").?.string));
    }
    for (v.object.get("errors").?.array.items) |c| {
        const status: u16 = @intCast(c.object.get("status").?.integer);
        const msg: ?[]const u8 = if (c.object.get("message").? == .string) c.object.get("message").?.string else null;
        const typ = c.object.get("type").?;
        var f: Failure = .{ .status = status };
        if (status == 0) {
            f.message = msg;
        } else if (typ == .string or msg != null) {
            const body = try std.fmt.allocPrint(a, "{{\"error\":{{\"type\":{f},\"message\":{f}}}}}", .{ json.fmt(typ, .{}), json.fmt(msg, .{}) });
            f.body = try json.parseFromSliceLeaky(json.Value, a, body, .{});
        }
        try testing.expectEqualStrings(c.object.get("sentence").?.string, try f.sentence(a, c.object.get("fallback").?.string));
    }
}

test "sandboxes: the engine makes exactly the calls the shared plans name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try loadVector(a);
    const plans = v.object.get("plans").?.object;
    const id = "cnd_ab12cd34ef56";
    const name = "Harness cloud ab12";
    const sizes_body = try json.Stringify.valueAlloc(a, v.object.get("personalSizes").?, .{});
    const names_file = "{\"cnd_ab12cd34ef56\":\"Harness cloud ab12\"}";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDataDir(&tmp);
    defer testing.allocator.free(dir);
    var slot: ErrSlot = .{ .gpa = testing.allocator };
    defer slot.deinit();

    var gw: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{
        .{ .line = "POST /v1/sandboxes", .status = 201, .body = "{\"id\":\"cnd_ab12cd34ef56\",\"provider\":\"fleet\",\"state\":\"started\"}" },
        .{ .line = "POST /v1/sandboxes/cnd_ab12cd34ef56/harness", .status = 200, .body = "{}" },
        .{ .line = "GET /v1/sandboxes/cnd_ab12cd34ef56", .status = 200, .body = "{\"id\":\"cnd_ab12cd34ef56\",\"state\":\"paused\"}" },
        .{ .line = "GET /v1/sandboxes/cnd_ab12cd34ef56", .status = 200, .body = "{\"id\":\"cnd_ab12cd34ef56\",\"state\":\"started\"}" },
        .{ .line = "POST /v1/sandboxes/cnd_ab12cd34ef56/start", .status = 200, .body = "{}" },
        .{ .line = "POST /v1/sandboxes/cnd_ab12cd34ef56/stop", .status = 200, .body = "{}" },
        .{ .line = "DELETE /v1/sandboxes/cnd_ab12cd34ef56", .status = 200, .body = "{}" },
        .{ .line = "POST /v1/sandboxes/cnd_ab12cd34ef56/keep-running", .status = 200, .body = "{\"id\":\"cnd_ab12cd34ef56\",\"state\":\"started\"}" },
    } };
    defer gw.deinit();
    const ctx = testCtx(&gw, &slot, dir);
    var at: usize = 0;

    const r1 = try handle(ctx, testing.allocator, .create, .null);
    testing.allocator.free(r1.ok);
    at = try expectPlan(a, &gw, at, plans.get("create").?, id, name);

    for ([_][]const u8{ "startWhenPaused", "startWhenRunning" }) |label| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = devices_file, .data = names_file });
        const p = try json.parseFromSliceLeaky(json.Value, a, "{\"id\":\"cnd_ab12cd34ef56\",\"action\":\"start\"}", .{});
        const r = try handle(ctx, testing.allocator, .action, p);
        testing.allocator.free(r.ok);
        at = try expectPlan(a, &gw, at, plans.get(label).?, id, name);
    }
    for ([_][2][]const u8{ .{ "stop", "stop" }, .{ "delete", "delete" }, .{ "keep-running-on", "keepRunningOn" }, .{ "keep-running-off", "keepRunningOff" } }) |pair| {
        const params = try std.fmt.allocPrint(a, "{{\"id\":\"cnd_ab12cd34ef56\",\"action\":\"{s}\"}}", .{pair[0]});
        const r = try handle(ctx, testing.allocator, .action, try json.parseFromSliceLeaky(json.Value, a, params, .{}));
        testing.allocator.free(r.ok);
        at = try expectPlan(a, &gw, at, plans.get(pair[1]).?, id, name);
    }

    var sized: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{
        .{ .line = "GET /v1/sandboxes/personal-sizes", .status = 200, .body = sizes_body },
        .{ .line = "POST /v1/sandboxes", .status = 201, .body = "{\"id\":\"cnd_ab12cd34ef56\",\"provider\":\"fleet\",\"state\":\"started\"}" },
        .{ .line = "POST /v1/sandboxes/cnd_ab12cd34ef56/harness", .status = 200, .body = "{}" },
    } };
    defer sized.deinit();
    const r2 = try handle(testCtx(&sized, &slot, dir), testing.allocator, .create, try json.parseFromSliceLeaky(json.Value, a, "{\"size\":\" large \"}", .{}));
    defer testing.allocator.free(r2.ok);
    _ = try expectPlan(a, &sized, 0, plans.get("createLarge").?, id, name);
    try testing.expect(std.mem.indexOf(u8, r2.ok, "\"pricePerHourMicroUsd\":200000") != null);

    var temp: FakeGateway = .{ .gpa = testing.allocator, .routes = &.{
        .{ .line = "POST /v1/sandboxes", .status = 201, .body = "{\"id\":\"temp_1\",\"provider\":\"daytona\",\"state\":\"started\",\"cpu\":2,\"memory\":4,\"labels\":{\"harness-purpose\":\"temporary\"}}" },
    } };
    defer temp.deinit();
    const r3 = try handle(testCtx(&temp, &slot, null), testing.allocator, .create_temporary, .null);
    defer testing.allocator.free(r3.ok);
    _ = try expectPlan(a, &temp, 0, plans.get("createTemporary").?, "", "");
    try testing.expect(std.mem.indexOf(u8, r3.ok, "\"tier\":\"ephemeral\"") != null);
    try testing.expect(std.mem.indexOf(u8, r3.ok, "\"harness\":false") != null);

    for (plans.get("neverCalled").?.array.items) |never| {
        for (gw.seen.items) |s| try testing.expect(std.mem.indexOf(u8, s.line, never.string) == null);
    }
}

