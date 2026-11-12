//! The workspace gate and switcher (docs/PARITY.md 1.2, `GatePhase::OrgGate`):
//! signed in to a synced workspace with no organization chosen, the window
//! asks for one ("Create your workspace", the existing memberships, "Use a
//! different account"); signed in, the account menu's "Switch workspace…"
//! opens the same list. It calls `ListOrgs`, `SelectOrg` and `CreateOrg`
//! and shows their errors as they come: an error is never an empty list.
const std = @import("std");
const json = std.json;
const ui = @import("nanoui").ui;
const rpc = @import("rpc.zig");
const App = @import("app.zig").App;
const account = @import("app_account.zig");
const Allocator = std.mem.Allocator;

/// The `AuthStatus` stream's state.
pub const Auth = enum { unknown, signed_out, needs_org, signed_in };

pub fn readAuth(v: json.Value) Auth {
    if (v != .object) return .unknown;
    const s = v.object.get("state") orelse return .unknown;
    if (s != .string) return .unknown;
    if (std.mem.eql(u8, s.string, "signedOut")) return .signed_out;
    if (std.mem.eql(u8, s.string, "needsOrganization")) return .needs_org;
    if (std.mem.eql(u8, s.string, "signedIn")) return .signed_in;
    return .unknown;
}

pub const Phase = enum { hidden, gate, switcher };

/// What shows (`gate_phase`'s OrgGate, and the switcher): a local or
/// development workspace has no organizations; a synced one with none
/// chosen is gated; the switcher only for someone signed in to one.
pub fn phase(scope: ?account.Scope, auth: Auth, switcher_open: bool) Phase {
    if (scope) |s| if (s != .synced) return .hidden;
    if (auth == .needs_org) return .gate;
    if (switcher_open and auth == .signed_in) return .switcher;
    return .hidden;
}

pub const Org = struct { id: []u8, organization_id: []u8, name: []u8 };

/// `ListOrgs`' reply, `{ orgs: [{ id, organizationId, name }] }`. Anything
/// else is an error, not an empty list.
pub fn parseOrgs(gpa: Allocator, v: json.Value, out: *std.ArrayList(Org)) !void {
    if (v != .object) return error.UnexpectedReply;
    const list = v.object.get("orgs") orelse return error.UnexpectedReply;
    if (list != .array) return error.UnexpectedReply;
    for (list.array.items) |o| {
        if (o != .object) return error.UnexpectedReply;
        const org_id = str(o.object, "organizationId") orelse return error.UnexpectedReply;
        const name = str(o.object, "name") orelse org_id;
        const id = try gpa.dupe(u8, str(o.object, "id") orelse org_id);
        errdefer gpa.free(id);
        const oid = try gpa.dupe(u8, org_id);
        errdefer gpa.free(oid);
        const nm = try gpa.dupe(u8, name);
        errdefer gpa.free(nm);
        try out.append(gpa, .{ .id = id, .organization_id = oid, .name = nm });
    }
}

/// Why `name` can't be a new workspace's name, or null when it can.
pub fn nameProblem(name: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, name, " \t\r\n");
    if (t.len == 0) return "Give the workspace a name.";
    if (t.len > 64) return "Keep the name under 64 characters.";
    return null;
}

pub const ErrKind = enum { none, list, action };

pub const State = struct {
    auth: Auth = .unknown,
    /// The organization signed in to, from `AuthStatus` (owned).
    org_id: std.ArrayList(u8) = .empty,
    switcher: bool = false,
    status: enum { idle, loading, ready, failed } = .idle,
    orgs: std.ArrayList(Org) = .empty,
    list_call: ?u64 = null,
    /// The pending action and the organization it's for.
    busy: enum { none, selecting, creating, signing_out } = .none,
    busy_org: usize = 0,
    action_call: ?u64 = null,
    name: ui.TextBuffer = .{},
    focus_name: bool = false,
    err_buf: [300]u8 = undefined,
    err_len: usize = 0,
    /// What failed: the list, or an action.
    err_kind: ErrKind = .none,
    retired: std.ArrayList(Org) = .empty,

    pub fn deinit(s: *State, gpa: Allocator) void {
        freeOrgs(gpa, &s.orgs);
        freeOrgs(gpa, &s.retired);
        s.org_id.deinit(gpa);
        @import("text_buffer.zig").deinit(&s.name);
    }

    pub fn errText(s: *const State) []const u8 {
        return s.err_buf[0..s.err_len];
    }
};

fn freeOrgs(gpa: Allocator, list: *std.ArrayList(Org)) void {
    for (list.items) |o| {
        gpa.free(o.id);
        gpa.free(o.organization_id);
        gpa.free(o.name);
    }
    list.deinit(gpa);
}

fn st(a: *App) *State {
    return &a.ui_gaps.gate;
}

pub fn current(a: *const App) Phase {
    const s = &a.ui_gaps.gate;
    return phase(a.account.scope, s.auth, s.switcher);
}

fn setErr(a: *App, kind: ErrKind, prefix: []const u8, why: []const u8) void {
    const s = st(a);
    const out = std.fmt.bufPrint(&s.err_buf, "{s}{s}", .{ prefix, why }) catch s.err_buf[0..0];
    s.err_len = out.len;
    s.err_kind = kind;
}

/// From the account's `AuthStatus` stream: the state, and the gate's list
/// asked for as it appears.
pub fn authItem(a: *App, v: json.Value) void {
    const s = st(a);
    const was = s.auth;
    s.auth = readAuth(v);
    s.org_id.clearRetainingCapacity();
    if (v == .object) if (str(v.object, "orgId")) |id| s.org_id.appendSlice(a.gpa, id) catch {};
    if (s.auth == .needs_org and was != .needs_org) load(a);
    if (s.auth != .signed_in) s.switcher = false;
}

/// "Switch workspace…" from the account menu.
pub fn openSwitcher(a: *App) void {
    const s = st(a);
    s.switcher = true;
    a.view.account_menu = false;
    load(a);
    a.redraw();
}

pub fn closeSwitcher(a: *App) void {
    const s = st(a);
    if (!s.switcher) return;
    s.switcher = false;
    s.err_kind = .none;
    a.view.focus_composer = true;
    a.redraw();
}

pub fn load(a: *App) void {
    const s = st(a);
    if (s.list_call) |id| a.engine.cancel(id);
    s.status = .loading;
    s.err_kind = .none;
    s.list_call = a.send_(.{ .method = "ListOrgs", .params = .{} }, .of(App, a, onOrgs));
    if (s.list_call == null) {
        s.status = .failed;
        setErr(a, .list, "", "Not connected to the engine.");
    }
    a.redraw();
}

fn onOrgs(a: *App, id: u64, r: rpc.Reply) void {
    const s = st(a);
    if (s.list_call != id) return;
    s.list_call = null;
    switch (r) {
        .ok => |v| {
            // The old rows may be in this frame: freed with the state.
            s.retired.appendSlice(a.gpa, s.orgs.items) catch freeOrgs(a.gpa, &s.orgs);
            s.orgs.clearRetainingCapacity();
            parseOrgs(a.gpa, v, &s.orgs) catch {
                s.status = .failed;
                setErr(a, .list, "", "The engine sent an unexpected reply to ListOrgs.");
                return a.redraw();
            };
            s.status = .ready;
            if (s.orgs.items.len == 0) s.focus_name = true;
        },
        .err => |why| {
            s.status = .failed;
            setErr(a, .list, "Couldn't load your workspaces: ", why);
        },
        else => {},
    }
    a.redraw();
}

pub fn select(a: *App, ix: usize) void {
    const s = st(a);
    if (s.busy != .none or ix >= s.orgs.items.len) return;
    s.busy = .selecting;
    s.busy_org = ix;
    s.err_kind = .none;
    s.action_call = a.send_(.{ .method = "SelectOrg", .params = .{ .organizationId = s.orgs.items[ix].organization_id } }, .of(App, a, onDone));
    if (s.action_call == null) {
        s.busy = .none;
        setErr(a, .action, "", "Not connected to the engine.");
    }
    a.redraw();
}

pub fn create(a: *App) void {
    const s = st(a);
    if (s.busy != .none) return;
    const name = std.mem.trim(u8, s.name.text(), " \t\r\n");
    if (nameProblem(name)) |why| {
        setErr(a, .action, "", why);
        return a.redraw();
    }
    s.busy = .creating;
    s.err_kind = .none;
    s.action_call = a.send_(.{ .method = "CreateOrg", .params = .{ .name = name } }, .of(App, a, onDone));
    if (s.action_call == null) {
        s.busy = .none;
        setErr(a, .action, "", "Not connected to the engine.");
    }
    a.redraw();
}

fn onDone(a: *App, id: u64, r: rpc.Reply) void {
    const s = st(a);
    if (s.action_call != id) return;
    s.action_call = null;
    const what = s.busy;
    s.busy = .none;
    switch (r) {
        .ok => {
            // The engine took it: in, until its stream says otherwise.
            s.auth = .signed_in;
            s.switcher = false;
            s.name.clear();
            a.view.focus_composer = true;
        },
        .err => |why| setErr(a, .action, if (what == .creating) "Couldn't create the workspace: " else "Couldn't open that workspace: ", why),
        else => {},
    }
    a.redraw();
}

/// "Use a different account": signs out of this one.
pub fn signOut(a: *App) void {
    account.signOut(a);
    st(a).switcher = false;
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

const testing = std.testing;

test "the gate shows for a synced workspace with no organization, never for a local one" {
    try testing.expectEqual(Phase.gate, phase(.synced, .needs_org, false));
    try testing.expectEqual(Phase.gate, phase(null, .needs_org, true));
    try testing.expectEqual(Phase.hidden, phase(.local, .needs_org, false));
    try testing.expectEqual(Phase.hidden, phase(.development, .needs_org, true));
    try testing.expectEqual(Phase.hidden, phase(.synced, .signed_in, false));
    try testing.expectEqual(Phase.switcher, phase(.synced, .signed_in, true));
    try testing.expectEqual(Phase.hidden, phase(.synced, .signed_out, true));
}

test "AuthStatus states read as the canonical wire shape" {
    var o: json.ObjectMap = .empty;
    defer o.deinit(testing.allocator);
    try o.put(testing.allocator, "state", .{ .string = "needsOrganization" });
    try testing.expectEqual(Auth.needs_org, readAuth(.{ .object = o }));
    try o.put(testing.allocator, "state", .{ .string = "signedIn" });
    try testing.expectEqual(Auth.signed_in, readAuth(.{ .object = o }));
    try testing.expectEqual(Auth.unknown, readAuth(.null));
}

test "ListOrgs' reply parses; anything else is an error, not an empty list" {
    const gpa = testing.allocator;
    var list: std.ArrayList(Org) = .empty;
    defer freeOrgs(gpa, &list);
    const good = try json.parseFromSlice(json.Value, gpa, "{\"orgs\":[{\"id\":\"m1\",\"organizationId\":\"o1\",\"name\":\"Acme\"}]}", .{});
    defer good.deinit();
    try parseOrgs(gpa, good.value, &list);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("o1", list.items[0].organization_id);
    try testing.expectEqualStrings("Acme", list.items[0].name);
    const empty = try json.parseFromSlice(json.Value, gpa, "{\"orgs\":[]}", .{});
    defer empty.deinit();
    try parseOrgs(gpa, empty.value, &list);
    for ([_][]const u8{ "{}", "[]", "{\"ok\":true}", "{\"orgs\":[{\"name\":\"x\"}]}" }) |bad| {
        const p = try json.parseFromSlice(json.Value, gpa, bad, .{});
        defer p.deinit();
        try testing.expectError(error.UnexpectedReply, parseOrgs(gpa, p.value, &list));
    }
}

test "a new workspace needs a name of reasonable length" {
    try testing.expect(nameProblem("  ") != null);
    try testing.expect(nameProblem("Acme") == null);
    const long: [65]u8 = @splat('a');
    try testing.expect(nameProblem(&long) != null);
}
