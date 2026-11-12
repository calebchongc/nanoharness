//! `CodegraffGithubRunners`, ported from `crates/engine/src/rpc.rs`
//! (`methods::CODEGRAFF_GITHUB_RUNNERS`) and
//! `crates/engine/src/codegraff_auth/github_runners.rs` (`github_runners`,
//! `GithubRunners` and its parts, `lenient`, `lenient_vec`, `id_text`,
//! `whole`, `micro`), with `sandboxes.rs` `sandbox_call`.
//!
//! The account's GitHub CI runners from the gateway's `GET /v1/github/runners`
//! with the signed-in Codegraff key and a 20 s deadline. Signed out is `null`;
//! a gateway without runners (404/501) is `{available: false, …}`. Every field
//! is read leniently — a missing or mistyped value takes its default and an
//! unreadable list item is dropped — and the reply is written back in
//! `GithubRunners`' own shape, so a gateway that reshapes a field never breaks
//! the page.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");
const codegraff = @import("rpcw_codegraff.zig");

const RpcOutcome = common.RpcOutcome;
const Writer = std.Io.Writer;

const list_path = "/v1/github/runners";
/// `QUICK`.
pub const timeout_ms: u32 = 20_000;

fn get(v: json.Value, key: []const u8) json.Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

fn writeKey(w: *Writer, first: *bool, key: []const u8) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.print("\"{s}\":", .{key});
}

/// `String` (lenient): text, else `""`.
fn text(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    try w.print("{f}", .{json.fmt(if (v == .string) v.string else "", .{})});
}

/// `Option<String>` (lenient): text, else `null`.
fn optText(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    if (v == .string) try w.print("{f}", .{json.fmt(v.string, .{})}) else try w.writeAll("null");
}

/// `bool` (lenient).
fn flag(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    try w.writeAll(if (v == .bool and v.bool) "true" else "false");
}

/// A number as `f64`, as serde reads one (integers too).
fn asF64(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// serde_json's `f64`: integral values keep a `.0`.
fn writeF64(w: *Writer, f: f64) !void {
    if (@floor(f) == f and @abs(f) < 1e16) {
        try w.print("{d}.0", .{@as(i64, @intFromFloat(f))});
    } else {
        try w.print("{d}", .{f});
    }
}

/// `Option<f64>` (lenient): a number, else `null`.
fn optFloat(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    if (asF64(v)) |f| try writeF64(w, f) else try w.writeAll("null");
}

/// `Option<u32>` (lenient): a whole number in range, else `null`.
fn optU32(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) try w.print("{d}", .{v.integer}) else try w.writeAll("null");
}

/// `whole`: a number, or numeric text, rounded when finite and below 9e15.
pub fn whole(v: json.Value) ?i64 {
    const f: f64 = switch (v) {
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch return null,
        else => asF64(v) orelse return null,
    };
    if (!std.math.isFinite(f) or @abs(f) >= 9.0e15) return null;
    return @intFromFloat(@round(f));
}

/// `micro` / `id_number`.
fn optWhole(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    if (whole(v)) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
}

/// `Option<Value>` (lenient): any value, `null` as `null`.
fn optValue(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    try w.print("{f}", .{json.fmt(v, .{})});
}

/// `id_text`: trimmed text, a number's digits, anything else empty.
fn idText(w: *Writer, first: *bool, key: []const u8, v: json.Value) !void {
    try writeKey(w, first, key);
    switch (v) {
        .string => |s| try w.print("{f}", .{json.fmt(std.mem.trim(u8, s, " \t\r\n"), .{})}),
        .integer => |i| try w.print("\"{d}\"", .{i}),
        .number_string => |s| try w.print("{f}", .{json.fmt(s, .{})}),
        .float => |f| {
            var buf: [64]u8 = undefined;
            var bw: Writer = .fixed(&buf);
            try writeF64(&bw, f);
            try w.print("{f}", .{json.fmt(bw.buffered(), .{})});
        },
        else => try w.writeAll("\"\""),
    }
}

/// `lenient_vec`: the items that read as the struct (objects); others dropped.
fn list(w: *Writer, first: *bool, key: []const u8, v: json.Value, comptime item: fn (*Writer, json.Value) Writer.Error!void) !void {
    try writeKey(w, first, key);
    try w.writeByte('[');
    if (v == .array) {
        var n: usize = 0;
        for (v.array.items) |it| {
            if (it != .object) continue;
            if (n > 0) try w.writeByte(',');
            try item(w, it);
            n += 1;
        }
    }
    try w.writeByte(']');
}

fn repo(w: *Writer, v: json.Value) Writer.Error!void {
    var f = true;
    try w.writeByte('{');
    try text(w, &f, "fullName", get(v, "fullName"));
    try flag(w, &f, "enabled", get(v, "enabled"));
    try optText(w, &f, "defaultSize", get(v, "defaultSize"));
    try flag(w, &f, "private", get(v, "private"));
    try w.writeByte('}');
}

fn installation(w: *Writer, v: json.Value) Writer.Error!void {
    var f = true;
    try w.writeByte('{');
    try idText(w, &f, "installationId", get(v, "installationId"));
    try text(w, &f, "account", get(v, "account"));
    try optText(w, &f, "accountType", get(v, "accountType"));
    try flag(w, &f, "suspended", get(v, "suspended"));
    try optWhole(w, &f, "monthlyBudgetMicroUsd", get(v, "monthlyBudgetMicroUsd"));
    try optWhole(w, &f, "untrustedBudgetMicroUsd", get(v, "untrustedBudgetMicroUsd"));
    try optWhole(w, &f, "usedThisMonthMicroUsd", get(v, "usedThisMonthMicroUsd"));
    try optU32(w, &f, "maxConcurrent", get(v, "maxConcurrent"));
    try list(w, &f, "repos", get(v, "repos"), repo);
    try w.writeByte('}');
}

fn job(w: *Writer, v: json.Value) Writer.Error!void {
    var f = true;
    try w.writeByte('{');
    try text(w, &f, "repo", get(v, "repo"));
    try optWhole(w, &f, "runId", get(v, "runId"));
    try optWhole(w, &f, "jobId", get(v, "jobId"));
    try optText(w, &f, "workflow", get(v, "workflow"));
    try optText(w, &f, "jobName", get(v, "jobName"));
    try optText(w, &f, "tier", get(v, "tier"));
    try optText(w, &f, "size", get(v, "size"));
    try text(w, &f, "state", get(v, "state"));
    try optValue(w, &f, "queuedAt", get(v, "queuedAt"));
    try optValue(w, &f, "startedAt", get(v, "startedAt"));
    try optValue(w, &f, "completedAt", get(v, "completedAt"));
    try optFloat(w, &f, "durationSeconds", get(v, "durationSeconds"));
    try optWhole(w, &f, "costMicroUsd", get(v, "costMicroUsd"));
    try optText(w, &f, "conclusion", get(v, "conclusion"));
    try optText(w, &f, "htmlUrl", get(v, "htmlUrl"));
    try w.writeByte('}');
}

fn size(w: *Writer, v: json.Value) Writer.Error!void {
    var f = true;
    try w.writeByte('{');
    try text(w, &f, "key", get(v, "key"));
    try optFloat(w, &f, "cpu", get(v, "cpu"));
    try optFloat(w, &f, "memoryGiB", get(v, "memoryGiB"));
    try optFloat(w, &f, "diskGiB", get(v, "diskGiB"));
    try optWhole(w, &f, "pricePerHourMicroUsd", get(v, "pricePerHourMicroUsd"));
    try w.writeByte('}');
}

/// The list a gateway answered, written as `GithubRunners` with
/// `available: true` and an install link only when it is HTTPS. A body that
/// isn't an object reads as all defaults. Pure.
pub fn runnersJson(gpa: Allocator, body: json.Value) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    const v: json.Value = if (body == .object) body else .null;
    var f = true;
    try w.writeByte('{');
    try writeKey(w, &f, "available");
    try w.writeAll("true");
    try flag(w, &f, "enabled", get(v, "enabled"));
    const url = get(v, "installUrl");
    try optText(w, &f, "installUrl", if (url == .string and std.mem.startsWith(u8, url.string, "https://")) url else .null);
    try list(w, &f, "installations", get(v, "installations"), installation);
    try list(w, &f, "recentJobs", get(v, "recentJobs"), job);
    try list(w, &f, "sizes", get(v, "sizes"), size);
    try w.writeByte('}');
    return aw.toOwnedSlice();
}

/// `GithubRunners::default()`: a gateway without runners.
pub const unavailable = "{\"available\":false,\"enabled\":false,\"installUrl\":null,\"installations\":[],\"recentJobs\":[],\"sizes\":[]}";

const fallback = "GitHub CI is unavailable right now";

/// `CodegraffGithubRunners` → `GithubRunners`, or `null` when signed out.
pub fn githubRunners(host: *engine_host.EngineHost) !RpcOutcome {
    const gpa = host.gpa;
    const key = host.auth.codegraff_api_key orelse return .{ .unary_json = try gpa.dupe(u8, "null") };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `sandbox_call`'s local failures are status 0 with their own words.
    if (codegraff.validateSecureUrl("CodeGraff gateway", host.auth.codegraff_gateway)) |m| {
        return common.failedMsg((codegraff.Failure{ .status = 0, .message = try arena.dupe(u8, m) }).sentence(fallback));
    }
    const io = host.io orelse return common.failedMsg((codegraff.Failure{ .status = 0, .message = "couldn't reach CodeGraff: no I/O" }).sentence(fallback));
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ host.auth.codegraff_gateway, list_path });
    const key_owned = try arena.dupe(u8, key);
    var reply = auth_host.AuthManager.edgeRequestTimed(&host.auth.h2_pool, gpa, io, "GET", url, key_owned, &.{}, null, timeout_ms) catch |e| {
        const m = try std.fmt.allocPrint(arena, "couldn't reach CodeGraff: {s}", .{@errorName(e)});
        return common.failedMsg((codegraff.Failure{ .status = 0, .message = m }).sentence(fallback));
    };
    defer reply.deinit(gpa);
    const body: ?json.Value = json.parseFromSliceLeaky(json.Value, arena, reply.body, .{}) catch null;
    if (reply.status >= 200 and reply.status < 300) return .{ .unary_json = try runnersJson(gpa, body orelse .null) };
    if (codegraff.missingRoute(reply.status)) return .{ .unary_json = try gpa.dupe(u8, unavailable) };
    return common.failedMsg((codegraff.Failure{ .status = reply.status, .body = body }).sentence(fallback));
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const rooms = @import("rpcw_rooms.zig");

const listed =
    \\{"enabled": true,
    \\ "installUrl": "https://github.com/apps/codegraff/installations/new",
    \\ "installations": [{
    \\   "installationId": 4242, "account": "octo-org", "accountType": "Organization",
    \\   "suspended": false, "monthlyBudgetMicroUsd": 50000000,
    \\   "untrustedBudgetMicroUsd": "5000000", "usedThisMonthMicroUsd": 1250000.4,
    \\   "maxConcurrent": 3,
    \\   "repos": [
    \\     {"fullName": "octo-org/app", "enabled": true, "defaultSize": "standard", "private": true},
    \\     {"fullName": "octo-org/docs", "enabled": false, "defaultSize": null, "private": false},
    \\     "not a repo"
    \\   ],
    \\   "future": {"field": 1}}],
    \\ "recentJobs": [{
    \\   "repo": "octo-org/app", "runId": 77, "jobId": "88", "workflow": "CI", "jobName": "test",
    \\   "tier": "trusted", "size": "standard", "state": "completed",
    \\   "queuedAt": "2026-10-22T10:00:00Z", "durationSeconds": 180,
    \\   "costMicroUsd": 5000, "conclusion": "success"}],
    \\ "sizes": [{"key": "standard", "cpu": 2, "memoryGiB": 4.5, "diskGiB": 40, "pricePerHourMicroUsd": 100000}]}
;

test "rpcw_github_runners runnersJson reads every field leniently into GithubRunners' shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(), listed, .{});
    const out = try runnersJson(testing.allocator, v);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"available\":true,\"enabled\":true,\"installUrl\":\"https://github.com/apps/codegraff/installations/new\"," ++
            "\"installations\":[{\"installationId\":\"4242\",\"account\":\"octo-org\",\"accountType\":\"Organization\",\"suspended\":false," ++
            "\"monthlyBudgetMicroUsd\":50000000,\"untrustedBudgetMicroUsd\":5000000,\"usedThisMonthMicroUsd\":1250000,\"maxConcurrent\":3," ++
            "\"repos\":[{\"fullName\":\"octo-org/app\",\"enabled\":true,\"defaultSize\":\"standard\",\"private\":true}," ++
            "{\"fullName\":\"octo-org/docs\",\"enabled\":false,\"defaultSize\":null,\"private\":false}]}]," ++
            "\"recentJobs\":[{\"repo\":\"octo-org/app\",\"runId\":77,\"jobId\":88,\"workflow\":\"CI\",\"jobName\":\"test\",\"tier\":\"trusted\",\"size\":\"standard\"," ++
            "\"state\":\"completed\",\"queuedAt\":\"2026-10-22T10:00:00Z\",\"startedAt\":null,\"completedAt\":null,\"durationSeconds\":180.0,\"costMicroUsd\":5000," ++
            "\"conclusion\":\"success\",\"htmlUrl\":null}]," ++
            "\"sizes\":[{\"key\":\"standard\",\"cpu\":2.0,\"memoryGiB\":4.5,\"diskGiB\":40.0,\"pricePerHourMicroUsd\":100000}]}",
        out,
    );
    // Mistyped values take their defaults; an insecure install link is dropped.
    const odd = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"enabled\":\"yes\",\"installUrl\":\"http://x.test\",\"installations\":{},\"sizes\":[{\"key\":7,\"cpu\":\"2\",\"pricePerHourMicroUsd\":\"x\"}]}", .{});
    const out2 = try runnersJson(testing.allocator, odd);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("{\"available\":true,\"enabled\":false,\"installUrl\":null,\"installations\":[],\"recentJobs\":[],\"sizes\":[{\"key\":\"\",\"cpu\":null,\"memoryGiB\":null,\"diskGiB\":null,\"pricePerHourMicroUsd\":null}]}", out2);
    try testing.expectEqual(@as(?i64, null), whole(.{ .float = 9.5e15 }));
}

fn gatewayFx() !*rooms.Fx {
    const f = try rooms.Fx.init(false);
    testing.allocator.free(f.host.auth.codegraff_gateway);
    f.host.auth.codegraff_gateway = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{f.edge.port});
    if (f.host.auth.codegraff_api_key) |k| testing.allocator.free(k);
    f.host.auth.codegraff_api_key = try testing.allocator.dupe(u8, "cg-synthetic-key");
    return f;
}

test "rpcw_github_runners CodegraffGithubRunners lists with the key and reads 404 as unavailable" {
    const f = try gatewayFx();
    defer f.deinit();
    f.edge.body = "{\"enabled\":false}";
    const ok = try rooms.okJson(try f.callMethod("CodegraffGithubRunners", "null"));
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("{\"available\":true,\"enabled\":false,\"installUrl\":null,\"installations\":[],\"recentJobs\":[],\"sizes\":[]}", ok);
    const last = f.edge.lastRequest();
    try testing.expect(std.mem.startsWith(u8, last, "GET /v1/github/runners HTTP/1.1\n"));
    try testing.expect(std.mem.indexOf(u8, last, "Bearer cg-synthetic-key") != null);

    f.edge.status = 404;
    f.edge.body = "{\"error\":{\"message\":\"Not found\"}}";
    const missing = try rooms.okJson(try f.callMethod("CodegraffGithubRunners", "null"));
    defer testing.allocator.free(missing);
    try testing.expectEqualStrings(unavailable, missing);
}

test "rpcw_github_runners CodegraffGithubRunners errors and signed-out" {
    const f = try gatewayFx();
    defer f.deinit();
    f.edge.status = 500;
    f.edge.body = "";
    try rooms.expectErr(try f.callMethod("CodegraffGithubRunners", "null"), .exec_error, "GitHub CI is unavailable right now (500).");
    f.edge.status = 403;
    f.edge.body = "{\"error\":{\"type\":\"insufficient_scope\",\"message\":\"x\"}}";
    try rooms.expectErr(try f.callMethod("CodegraffGithubRunners", "null"), .exec_error, "This Codegraff sign-in can't manage sandboxes. Sign in again.");
    testing.allocator.free(f.host.auth.codegraff_gateway);
    f.host.auth.codegraff_gateway = try testing.allocator.dupe(u8, "http://gateway.example.invalid");
    try rooms.expectErr(try f.callMethod("CodegraffGithubRunners", "null"), .exec_error, "CodeGraff gateway must use HTTPS (plain HTTP is allowed only on loopback).");

    // Signed out lists nothing and never calls the gateway.
    const hits = f.edge.hits.load(.acquire);
    testing.allocator.free(f.host.auth.codegraff_api_key.?);
    f.host.auth.codegraff_api_key = null;
    const out = try rooms.okJson(try f.callMethod("CodegraffGithubRunners", "null"));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("null", out);
    try testing.expectEqual(hits, f.edge.hits.load(.acquire));
}
