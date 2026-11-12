//! The phone's sign-in, as AppModel.swift runs it: `startSignIn` opens the
//! browser step on the engine's random PKCE authorize URL, the
//! `harness://callback` it returns is checked (`handleSignInCallback`) and
//! completed through the engine (`CompleteSignIn`), then the organizations
//! are listed and one chosen (`signIn`, `selectOrg`). Sign out and account
//! deletion go through the engine too. The rules are mobile_auth.zig's.
//!
//! What's kept lives in fixed buffers: the screens draw it every frame
//! without allocating.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const App = @import("app.zig").App;
const ma = @import("mobile_auth.zig");
const mp = @import("mobile_parity.zig");
const web = @import("ios_web_auth.zig");

/// A string kept without allocating, cut at its capacity.
pub fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        const Self = @This();
        pub fn set(t: *Self, s: []const u8) void {
            const k = @min(s.len, n);
            @memcpy(t.buf[0..k], s[0..k]);
            t.len = k;
        }
        pub fn get(t: *const Self) []const u8 {
            return t.buf[0..t.len];
        }
        pub fn clear(t: *Self) void {
            t.len = 0;
        }
        pub fn empty(t: *const Self) bool {
            return t.len == 0;
        }
    };
}

pub const max_orgs = 12;

pub const OrgRow = struct {
    organization_id: Text(96) = .{},
    name: Text(96) = .{},
};

pub const State = struct {
    w_auth: ?u64 = null,
    /// A watch the engine refused is asked again from then (seconds, `App.now`).
    retry_at: f64 = 0,
    engine_state: ma.EngineState = .unknown,
    /// `signInBusy`: from the button until an organization is chosen.
    busy: bool = false,
    /// A code exchange is under way: the sheet's own cancel doesn't reset it.
    exchanging: bool = false,
    listing: bool = false,
    err: Text(320) = .{},
    /// The sign-in under way: its OAuth state and when it started.
    pending_state: Text(96) = .{},
    started_ms: i64 = 0,
    orgs: [max_orgs]OrgRow = @splat(.{}),
    org_count: usize = 0,
    /// The picker waits for a choice.
    picking: bool = false,
    org_busy: bool = false,
    org_err: Text(200) = .{},

    // Profile: deletion.
    confirm_delete: bool = false,
    deleting: bool = false,
    delete_err: Text(320) = .{},
    /// A screen pinned for an offscreen capture (`HARNESS_MOBILE_SCREEN`
    /// with `--demo`): the engine's account doesn't move it.
    preview: bool = false,

    pub fn screen(s: *const State) ma.Screen {
        return ma.screen(s.engine_state, s.busy, s.picking and s.org_count > 0);
    }

    pub fn orgList(s: *const State) []const OrgRow {
        return s.orgs[0..s.org_count];
    }
};

fn st(a: *App) *State {
    return &a.mobile.auth;
}

fn nowMs(a: *const App) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(a.io).nanoseconds, std.time.ns_per_ms));
}

/// Each frame, from the gate: the account watched, and the browser
/// sheet's answer taken when it came.
pub fn poll(a: *App) void {
    const s = st(a);
    if (s.w_auth == null and a.engine.up() and a.now >= s.retry_at) {
        s.w_auth = a.send_(requests.none("AuthStatus"), .of(App, a, onAuth));
    }
    if (web.take()) |outcome| {
        defer web.free(outcome);
        switch (outcome) {
            .success => |url| deliverCallback(a, url),
            .cancelled => if (!s.exchanging) {
                s.busy = false;
            },
            .failure => |why| if (!s.exchanging) {
                s.busy = false;
                s.err.set(why);
            },
        }
        a.redraw();
    }
}

fn onAuth(a: *App, _: u64, r: rpc.Reply) void {
    const s = st(a);
    switch (r) {
        .item => |v| {
            if (s.preview) return;
            const state = if (v == .object) (if (v.object.get("state")) |sv| (if (sv == .string) sv.string else "") else "") else "";
            s.engine_state = ma.engineState(state);
            switch (s.engine_state) {
                // Org-less (a browser sign-in on the Mac lands here): list them.
                .needs_organization => if (!s.listing and !s.picking) {
                    s.busy = true;
                    listOrgs(a);
                },
                .signed_in => if (!s.listing and !s.picking and !s.exchanging) {
                    s.busy = false;
                    s.err.clear();
                },
                .signed_out => {
                    s.picking = false;
                    s.org_count = 0;
                },
                .unknown => {},
            }
        },
        .done => s.w_auth = null,
        .err => {
            s.w_auth = null;
            s.retry_at = a.now + 2;
        },
        .ok => {},
    }
    a.redraw();
}

/// "Log in to Harness".
pub fn start(a: *App) void {
    const s = st(a);
    if (s.busy) return;
    s.busy = true;
    s.err.clear();
    a.call("SignIn", .{ .mobile = web.available }, .of(App, a, onStarted));
    a.redraw();
}

fn onStarted(a: *App, _: u64, r: rpc.Reply) void {
    const s = st(a);
    switch (r) {
        .ok => |v| {
            const url = if (v == .object) (if (v.object.get("url")) |u| (if (u == .string) u.string else "") else "") else "";
            if (url.len == 0) {
                // An engine without a sign-in to run (signed in already).
                s.busy = false;
                return a.redraw();
            }
            var sb: [128]u8 = undefined;
            s.pending_state.set(ma.queryParam(&sb, url, "state") orelse "");
            s.started_ms = nowMs(a);
            if (web.available) {
                if (!web.start(a.gpa, url, ma.callback_scheme)) {
                    s.busy = false;
                    s.err.set("Sign-in failed");
                }
            } else if (!nanoui.shell.openUrl(url)) {
                // The Mac preview: the engine's loopback listener takes the
                // browser's answer, and `AuthStatus` says when it's done.
                s.busy = false;
                s.err.set("Sign-in failed");
            }
        },
        .err => |e| {
            s.busy = false;
            s.err.set(e);
        },
        else => {},
    }
    a.redraw();
}

/// A `harness://callback` from the browser step (`handleSignInCallback`).
pub fn deliverCallback(a: *App, url: []const u8) void {
    const s = st(a);
    var code_buf: [512]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    switch (ma.readCallback(&code_buf, &reason_buf, url, s.pending_state.get(), s.started_ms, nowMs(a))) {
        .failed => |f| {
            if (f.err == .denied) {
                var mb: [320]u8 = undefined;
                s.err.set(ma.deniedMessage(&mb, f.reason));
            } else s.err.set(f.err.message());
            if (ma.callbackEndsSignIn(f.err)) {
                s.pending_state.clear();
                s.busy = false;
            }
        },
        .code => |code| {
            var joined_buf: [640]u8 = undefined;
            const joined = ma.completeCode(&joined_buf, s.pending_state.get(), code) orelse return;
            s.pending_state.clear();
            s.exchanging = true;
            s.busy = true;
            s.err.clear();
            a.call("CompleteSignIn", .{ .code = joined }, .of(App, a, onCompleted));
        },
    }
    a.redraw();
}

fn onCompleted(a: *App, _: u64, r: rpc.Reply) void {
    const s = st(a);
    switch (r) {
        .ok => listOrgs(a),
        .err => |e| {
            s.exchanging = false;
            s.busy = false;
            s.err.set(e);
        },
        else => {},
    }
    a.redraw();
}

fn listOrgs(a: *App) void {
    st(a).listing = true;
    a.request(requests.none("ListOrgs"), .of(App, a, onOrgs));
}

fn onOrgs(a: *App, _: u64, r: rpc.Reply) void {
    const s = st(a);
    s.listing = false;
    switch (r) {
        .ok => |v| {
            var arena: std.heap.ArenaAllocator = .init(a.gpa);
            defer arena.deinit();
            const orgs = ma.parseOrgs(arena.allocator(), v) catch &.{};
            s.org_count = @min(orgs.len, max_orgs);
            for (orgs[0..s.org_count], 0..) |o, i| {
                s.orgs[i].organization_id.set(o.organization_id);
                s.orgs[i].name.set(o.name);
            }
            switch (ma.orgPlan(s.org_count)) {
                .select => |i| selectOrg(a, i),
                .pick => {
                    s.picking = true;
                    s.exchanging = false;
                },
                .none => {
                    s.exchanging = false;
                    s.busy = false;
                    s.err.set(ma.no_orgs_copy);
                    signOut(a);
                },
            }
        },
        .err => |e| {
            s.exchanging = false;
            s.busy = false;
            s.err.set(e);
        },
        else => {},
    }
    a.redraw();
}

/// A row of "Choose an organization".
pub fn selectOrg(a: *App, index: usize) void {
    const s = st(a);
    if (index >= s.org_count or s.org_busy) return;
    s.org_busy = true;
    s.org_err.clear();
    a.call("SelectOrg", .{ .organizationId = s.orgs[index].organization_id.get() }, .of(App, a, onSelected));
    a.redraw();
}

fn onSelected(a: *App, _: u64, r: rpc.Reply) void {
    const s = st(a);
    s.org_busy = false;
    switch (r) {
        .ok => {
            s.picking = false;
            s.org_count = 0;
            s.exchanging = false;
            s.busy = false;
            s.engine_state = .signed_in;
        },
        .err => |e| if (s.picking) s.org_err.set(e) else {
            s.exchanging = false;
            s.busy = false;
            s.err.set(e);
        },
        else => {},
    }
    a.redraw();
}

/// "Cancel" while the browser step is open, and "Back" from the picker
/// (which signs out, as the Swift picker's does).
pub fn cancel(a: *App) void {
    const s = st(a);
    web.cancel();
    if (s.picking) return signOut(a);
    s.busy = false;
    s.exchanging = false;
    s.pending_state.clear();
    a.redraw();
}

pub fn signOut(a: *App) void {
    const s = st(a);
    s.picking = false;
    s.org_count = 0;
    s.busy = false;
    s.exchanging = false;
    a.request(requests.none("SignOut"), .of(App, a, onSignedOut));
    a.redraw();
}

fn onSignedOut(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => {
            st(a).engine_state = .signed_out;
            a.mobile.sheet = .none;
            a.select(null, null);
        },
        .err => |e| st(a).err.set(e),
        else => {},
    }
    a.redraw();
}

/// "Delete" in the confirmation.
pub fn deleteAccount(a: *App) void {
    const s = st(a);
    if (s.deleting) return;
    s.confirm_delete = false;
    s.deleting = true;
    s.delete_err.clear();
    a.request(requests.none("DeleteAccount"), .of(App, a, onDeleted));
    a.redraw();
}

/// What `DeleteAccount` answered: deleted, or the message to show.
pub fn deletionReply(v: json.Value) union(enum) { deleted, refused: []const u8 } {
    if (v != .object) return .{ .refused = mp.account_unreachable_copy };
    if (v.object.get("deleted")) |d| if (d == .bool and d.bool) return .deleted;
    const m = v.object.get("message") orelse return .{ .refused = mp.account_unreachable_copy };
    return .{ .refused = if (m == .string and m.string.len > 0) m.string else mp.account_unreachable_copy };
}

fn onDeleted(a: *App, _: u64, r: rpc.Reply) void {
    const s = st(a);
    s.deleting = false;
    switch (r) {
        .ok => |v| switch (deletionReply(v)) {
            .deleted => {
                s.engine_state = .signed_out;
                a.mobile.sheet = .none;
                a.select(null, null);
            },
            .refused => |m| s.delete_err.set(m),
        },
        .err => s.delete_err.set(mp.account_unreachable_copy),
        else => {},
    }
    a.redraw();
}

const testing = std.testing;

test "deletion replies read as the Swift app shows them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ok = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"deleted\":true}", .{});
    try testing.expect(deletionReply(ok) == .deleted);
    const no = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"deleted\":false,\"message\":\"Your account can't be deleted yet.\"}", .{});
    try testing.expectEqualStrings("Your account can't be deleted yet.", deletionReply(no).refused);
    try testing.expectEqualStrings(mp.account_unreachable_copy, deletionReply(.null).refused);
}

test "Text keeps a copy and cuts at its size" {
    var t: Text(4) = .{};
    t.set("abcdef");
    try testing.expectEqualStrings("abcd", t.get());
    t.clear();
    try testing.expect(t.empty());
}
