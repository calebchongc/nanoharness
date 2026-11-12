//! The phone's sign-in rules, as the Swift app has them
//! (apps/ios/Harness/Views/SignInView.swift, Auth/PendingSignIn.swift,
//! App/AppModel.swift `startSignIn`, `handleSignInCallback`, `signIn`):
//! which screen shows, what a `harness://callback` answers, and what the
//! organization list leads to. Pure: the screens and the controller
//! (app_mobile_auth.zig) call these.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const privacy_url = "https://codegraff.com/privacy#harness";
pub const support_url = "https://codegraff.com/support";
pub const callback_scheme = "harness";

/// How long a started sign-in waits for its callback (`PendingSignIn.lifetime`).
pub const pending_lifetime_ms: i64 = 30 * 60 * 1000;

/// The redirect the edge sends the phone's browser step to
/// (`Endpoints.redirectURI`), on whichever edge is configured.
pub fn redirectUri(buf: []u8, edge_url: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/auth/ios/callback", .{std.mem.trimEnd(u8, edge_url, "/")}) catch "";
}

/// Which screen the account gate shows (`AppModel.Phase`, with the busy
/// state the sign-in screen draws).
pub const Screen = enum { signed_out, signing_in, picking_org, signed_in };

/// The engine's `AuthStatus` state, read.
pub const EngineState = enum { unknown, signed_out, needs_organization, signed_in };

pub fn engineState(state: []const u8) EngineState {
    if (std.mem.eql(u8, state, "signedIn")) return .signed_in;
    if (std.mem.eql(u8, state, "needsOrganization")) return .needs_organization;
    if (std.mem.eql(u8, state, "signedOut")) return .signed_out;
    return .unknown;
}

/// The gate's screen. A sign-in under way keeps its screen until the
/// organization is chosen, as `signInBusy` does; an org list waiting for a
/// choice shows the picker. A state not known yet (no `AuthStatus` item)
/// keeps the app as it was rather than flashing the sign-in screen.
pub fn screen(state: EngineState, busy: bool, orgs_waiting: bool) Screen {
    if (orgs_waiting) return .picking_org;
    if (busy) return .signing_in;
    return switch (state) {
        .signed_in, .unknown => .signed_in,
        .signed_out => .signed_out,
        // Org-less: the controller lists the organizations; until then it is busy.
        .needs_organization => .signing_in,
    };
}

/// Why a callback didn't finish the sign-in (`PendingSignIn.CallbackError`).
pub const CallbackError = enum {
    denied,
    missing_code,
    state_mismatch,
    expired,
    not_callback,

    /// The Swift app's message; `denied` is formatted with its reason by `deniedMessage`.
    pub fn message(e: CallbackError) []const u8 {
        return switch (e) {
            .denied => "Sign-in was not completed.",
            .missing_code => "The sign-in link was missing its code. Try again.",
            .state_mismatch => "That sign-in link belongs to a different attempt. Start sign-in again.",
            .expired => "That sign-in took too long. Start sign-in again.",
            .not_callback => "Sign-in failed",
        };
    }
};

pub fn deniedMessage(buf: []u8, reason: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Sign-in was not completed ({s}).", .{reason}) catch CallbackError.denied.message();
}

/// `harness://callback?...` (`PendingSignIn.isCallback`).
pub fn isCallback(url: []const u8) bool {
    const prefix = callback_scheme ++ "://callback";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return false;
    const rest = url[prefix.len..];
    return rest.len == 0 or rest[0] == '?' or rest[0] == '/' or rest[0] == '#';
}

/// A query parameter, percent-decoded into `buf`. Null when absent.
pub fn queryParam(buf: []u8, url: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var end = url.len;
    if (std.mem.indexOfScalarPos(u8, url, q, '#')) |h| end = h;
    var it = std.mem.splitScalar(u8, url[q + 1 .. end], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
        return percentDecode(buf, raw);
    }
    return null;
}

fn percentDecode(buf: []u8, raw: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (n += 1) {
        if (n >= buf.len) return null;
        if (raw[i] == '%' and i + 2 < raw.len) {
            buf[n] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else if (raw[i] == '+') {
            buf[n] = ' ';
            i += 1;
        } else {
            buf[n] = raw[i];
            i += 1;
        }
    }
    return buf[0..n];
}

pub const Callback = union(enum) {
    /// The authorization code, in the caller's buffer.
    code: []const u8,
    failed: struct { err: CallbackError, reason: []const u8 = "" },
};

/// What a callback URL answers for the sign-in started at `started_ms` with
/// `state` (`PendingSignIn.code(from:)`): the checks run in the Swift
/// order, error first, then state, then age, then the code.
pub fn readCallback(code_buf: []u8, reason_buf: []u8, url: []const u8, state: []const u8, started_ms: i64, now_ms: i64) Callback {
    if (!isCallback(url)) return .{ .failed = .{ .err = .not_callback } };
    if (queryParam(reason_buf, url, "error")) |err_v| {
        var desc_buf: [256]u8 = undefined;
        const reason = queryParam(&desc_buf, url, "error_description") orelse err_v;
        const n = @min(reason.len, reason_buf.len);
        std.mem.copyForwards(u8, reason_buf[0..n], reason[0..n]);
        return .{ .failed = .{ .err = .denied, .reason = reason_buf[0..n] } };
    }
    var st_buf: [256]u8 = undefined;
    const got_state = queryParam(&st_buf, url, "state") orelse "";
    if (state.len == 0 or !std.mem.eql(u8, got_state, state)) return .{ .failed = .{ .err = .state_mismatch } };
    if (now_ms - started_ms > pending_lifetime_ms) return .{ .failed = .{ .err = .expired } };
    const code = queryParam(code_buf, url, "code") orelse "";
    if (code.len == 0) return .{ .failed = .{ .err = .missing_code } };
    return .{ .code = code };
}

/// What a failed callback does to the sign-in under way (`handleSignInCallback`):
/// someone else's link keeps waiting for ours; anything else ends it.
pub fn callbackEndsSignIn(err: CallbackError) bool {
    return err != .state_mismatch;
}

/// `CompleteSignIn`'s code: the state and the code, joined by a dot.
pub fn completeCode(buf: []u8, state: []const u8, code: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ state, code }) catch null;
}

pub const Org = struct {
    id: []const u8,
    organization_id: []const u8,
    name: []const u8,
};

/// `ListOrgs`' reply (`{"orgs":[...]}` or a bare array).
pub fn parseOrgs(arena: Allocator, v: json.Value) ![]Org {
    const items: []const json.Value = switch (v) {
        .object => |o| if (o.get("orgs")) |ov| (if (ov == .array) ov.array.items else &.{}) else &.{},
        .array => |a| a.items,
        else => &.{},
    };
    var out: std.ArrayList(Org) = .empty;
    for (items) |it| {
        if (it != .object) continue;
        const oid = str(it.object, "organizationId") orelse str(it.object, "id") orelse continue;
        if (oid.len == 0) continue;
        try out.append(arena, .{
            .id = try arena.dupe(u8, str(it.object, "id") orelse oid),
            .organization_id = try arena.dupe(u8, oid),
            .name = try arena.dupe(u8, str(it.object, "name") orelse oid),
        });
    }
    return out.items;
}

/// What the org list leads to (`AppModel.signIn`): one org is chosen
/// straight away, none is an error, several open the picker.
pub const OrgPlan = union(enum) {
    select: usize,
    pick,
    none,
};

pub fn orgPlan(count: usize) OrgPlan {
    if (count == 1) return .{ .select = 0 };
    if (count == 0) return .none;
    return .pick;
}

/// The Swift app's error for an account with no organization
/// (`AuthError.http(403, ...)`).
pub const no_orgs_copy = "Auth failed (403): No organizations for this account";

/// Account deletion copy (ProfileView.swift).
pub const delete_title = "Delete your account?";
pub const delete_body = "This permanently deletes your CodeGraff account and everything Harness keeps for it: chats, sessions, devices, and the agent rooms you made. Your posts in other people's rooms lose their text. This can't be undone.";
pub const delete_footer = "Permanently deletes your CodeGraff account and everything Harness keeps for it.";
pub const delete_failed_title = "Account not deleted";
pub const deleting_copy = "Deleting account…";

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

const testing = std.testing;

test "the gate's screen follows the engine's state and the sign-in under way" {
    try testing.expectEqual(Screen.signed_out, screen(.signed_out, false, false));
    try testing.expectEqual(Screen.signing_in, screen(.signed_out, true, false));
    try testing.expectEqual(Screen.signing_in, screen(.needs_organization, false, false));
    try testing.expectEqual(Screen.picking_org, screen(.needs_organization, true, true));
    try testing.expectEqual(Screen.signed_in, screen(.signed_in, false, false));
    try testing.expectEqual(Screen.signed_in, screen(.unknown, false, false));
    try testing.expectEqual(EngineState.needs_organization, engineState("needsOrganization"));
    try testing.expectEqual(EngineState.unknown, engineState("weird"));
}

test "a harness://callback answers only its own sign-in, once, within 30 minutes" {
    var cb: [256]u8 = undefined;
    var rb: [256]u8 = undefined;
    const t0: i64 = 1_000_000;
    const ok = readCallback(&cb, &rb, "harness://callback?code=c%2D1&state=S1", "S1", t0, t0 + 5_000);
    try testing.expectEqualStrings("c-1", ok.code);

    const other = readCallback(&cb, &rb, "harness://callback?code=c&state=S2", "S1", t0, t0);
    try testing.expectEqual(CallbackError.state_mismatch, other.failed.err);
    try testing.expect(!callbackEndsSignIn(other.failed.err));

    const late = readCallback(&cb, &rb, "harness://callback?code=c&state=S1", "S1", t0, t0 + pending_lifetime_ms + 1);
    try testing.expectEqual(CallbackError.expired, late.failed.err);

    const empty = readCallback(&cb, &rb, "harness://callback?state=S1", "S1", t0, t0);
    try testing.expectEqual(CallbackError.missing_code, empty.failed.err);

    const denied = readCallback(&cb, &rb, "harness://callback?error=access_denied&error_description=User+cancelled&state=S1", "S1", t0, t0);
    try testing.expectEqual(CallbackError.denied, denied.failed.err);
    var mb: [128]u8 = undefined;
    try testing.expectEqualStrings("Sign-in was not completed (User cancelled).", deniedMessage(&mb, denied.failed.reason));
    try testing.expect(callbackEndsSignIn(.denied));

    try testing.expectEqual(CallbackError.not_callback, readCallback(&cb, &rb, "https://evil.example/callback?code=c&state=S1", "S1", t0, t0).failed.err);
    try testing.expect(isCallback("harness://callback"));
    try testing.expect(!isCallback("harness://callbackx?code=1"));
}

test "orgs: one is chosen, none is an error, several are picked from" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(),
        \\{"orgs":[{"id":"om_1","organizationId":"org_1","name":"Acme"},{"id":"om_2","organizationId":"org_2","name":"Personal"},{"name":"broken"}]}
    , .{});
    const orgs = try parseOrgs(arena.allocator(), v);
    try testing.expectEqual(@as(usize, 2), orgs.len);
    try testing.expectEqualStrings("org_2", orgs[1].organization_id);
    try testing.expectEqualStrings("Acme", orgs[0].name);
    try testing.expect(orgPlan(orgs.len) == .pick);
    try testing.expectEqual(@as(usize, 0), orgPlan(1).select);
    try testing.expect(orgPlan(0) == .none);
    var rb: [96]u8 = undefined;
    try testing.expectEqualStrings("https://edge.codegraff.com/auth/ios/callback", redirectUri(&rb, "https://edge.codegraff.com/"));
    var cb: [64]u8 = undefined;
    try testing.expectEqualStrings("S.c", completeCode(&cb, "S", "c").?);
}
