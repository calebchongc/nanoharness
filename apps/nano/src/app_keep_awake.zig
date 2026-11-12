//! Keep awake while agents work (Settings › Agents, crates/engine
//! keep_awake.rs): `GetKeepAwake` / `SetKeepAwake` on the device the page
//! shows, replying `{ enabled, supported }`. Where the engine can't hold
//! the sleep assertion (`supported: false`) the setting isn't offered.
const std = @import("std");
const json = std.json;
const rpc = @import("rpc.zig");
const App = @import("app.zig").App;

pub const Reading = struct { enabled: bool, supported: bool };

pub fn read(v: json.Value) ?Reading {
    if (v != .object) return null;
    const e = v.object.get("enabled") orelse return null;
    const s = v.object.get("supported") orelse return null;
    if (e != .bool or s != .bool) return null;
    return .{ .enabled = e.bool, .supported = s.bool };
}

pub const Status = enum { idle, loading, ready, failed };

/// What the card shows: nothing where it can't work.
pub const Shown = enum { hidden, loading, failed, toggle };

pub fn shown(status: Status, supported: bool) Shown {
    return switch (status) {
        .idle, .loading => .loading,
        .failed => .failed,
        .ready => if (supported) .toggle else .hidden,
    };
}

pub const State = struct {
    status: Status = .idle,
    enabled: bool = false,
    supported: bool = false,
    saving: bool = false,
    call: ?u64 = null,
    /// The device it was read for ("" this one).
    device: std.ArrayList(u8) = .empty,
    err_buf: [240]u8 = undefined,
    err_len: usize = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.device.deinit(gpa);
    }

    pub fn errText(s: *const State) []const u8 {
        return s.err_buf[0..s.err_len];
    }
};

fn st(a: *App) *State {
    return &a.ui_gaps.keep_awake;
}

/// Asked for again when the page's device changes.
pub fn ensure(a: *App, device: ?[]const u8) void {
    const s = st(a);
    const want = device orelse "";
    if (s.status != .idle and std.mem.eql(u8, s.device.items, want)) return;
    s.device.clearRetainingCapacity();
    s.device.appendSlice(a.gpa, want) catch return;
    load(a);
}

pub fn load(a: *App) void {
    const s = st(a);
    if (s.call) |id| a.engine.cancel(id);
    s.status = .loading;
    s.saving = false;
    s.call = a.send_(.{ .method = "GetKeepAwake", .params = .{ .targetDeviceId = target(s) } }, .of(App, a, onReply));
    if (s.call == null) fail(a, "Not connected to the engine.");
}

fn target(s: *const State) ?[]const u8 {
    return if (s.device.items.len > 0) s.device.items else null;
}

pub fn set(a: *App, on: bool) void {
    const s = st(a);
    if (s.status != .ready or s.saving) return;
    s.saving = true;
    s.enabled = on;
    s.call = a.send_(.{ .method = "SetKeepAwake", .params = .{ .enabled = on, .targetDeviceId = target(s) } }, .of(App, a, onReply));
    if (s.call == null) {
        s.saving = false;
        s.enabled = !on;
    }
    a.redraw();
}

fn fail(a: *App, why: []const u8) void {
    const s = st(a);
    const n = @min(why.len, s.err_buf.len);
    @memcpy(s.err_buf[0..n], why[0..n]);
    s.err_len = n;
    s.status = .failed;
    a.redraw();
}

fn onReply(a: *App, id: u64, r: rpc.Reply) void {
    const s = st(a);
    if (s.call != id) return;
    s.call = null;
    const saving = s.saving;
    s.saving = false;
    switch (r) {
        .ok => |v| if (read(v)) |x| {
            s.enabled = x.enabled;
            s.supported = x.supported;
            s.status = .ready;
            s.err_len = 0;
        } else fail(a, "The engine sent an unexpected reply."),
        .err => |why| if (saving) {
            // The switch goes back; the reason shows under it.
            s.enabled = !s.enabled;
            const n = @min(why.len, s.err_buf.len);
            @memcpy(s.err_buf[0..n], why[0..n]);
            s.err_len = n;
        } else fail(a, why),
        else => {},
    }
    a.redraw();
}

const testing = std.testing;

test "keep-awake replies read, and the card hides where it can't work" {
    const p = try json.parseFromSlice(json.Value, testing.allocator, "{\"enabled\":true,\"supported\":false}", .{});
    defer p.deinit();
    const r = read(p.value).?;
    try testing.expect(r.enabled and !r.supported);
    try testing.expect(read(.null) == null);
    try testing.expectEqual(Shown.hidden, shown(.ready, false));
    try testing.expectEqual(Shown.toggle, shown(.ready, true));
    try testing.expectEqual(Shown.failed, shown(.failed, true));
    try testing.expectEqual(Shown.loading, shown(.idle, false));
}
