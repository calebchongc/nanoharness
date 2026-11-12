//! What the phone's own edge calls (push registration, crash reports) need
//! from the in-process engine: the edge, the organization, a fresh access
//! token and this device's id, copied under the host's lock as the
//! registry sync does (engine_host.zig `syncFromEdgeRegistryUnlocked`), so
//! the request itself runs outside it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");

pub const Creds = struct {
    /// Without a trailing slash.
    edge: []u8,
    org: []u8,
    token: []u8,
    device: []u8,

    pub fn deinit(c: *Creds, gpa: Allocator) void {
        gpa.free(c.edge);
        gpa.free(c.org);
        gpa.free(c.token);
        gpa.free(c.device);
    }
};

/// The signed-in edge's credentials, or null (signed out, demo, offline).
pub fn snapshot(gpa: Allocator, host: *engine_host.EngineHost) ?Creds {
    const io = host.io orelse return null;
    host.mutex.lockUncancelable(io);
    defer host.mutex.unlock(io);
    if (host.stop_requested or !host.auth.signed_in) return null;
    const edge = host.auth.edge_url orelse return null;
    const org = host.auth.org_id orelse return null;
    const token = host.auth.ensureAccessToken(io, false) orelse return null;
    var dev_buf: [128]u8 = undefined;
    const device = engine_host.sanitizeEdgeDeviceId(&dev_buf, host.device_id);
    return fromParts(gpa, edge, org, token, device) catch null;
}

pub fn fromParts(gpa: Allocator, edge: []const u8, org: []const u8, token: []const u8, device: []const u8) !Creds {
    const e = try gpa.dupe(u8, std.mem.trimEnd(u8, edge, "/"));
    errdefer gpa.free(e);
    const o = try gpa.dupe(u8, org);
    errdefer gpa.free(o);
    const t = try gpa.dupe(u8, token);
    errdefer gpa.free(t);
    return .{ .edge = e, .org = o, .token = t, .device = try gpa.dupe(u8, device) };
}

/// One request to the edge with the snapshot's token; the reply's status,
/// or null when it never answered.
pub fn send(gpa: Allocator, io: std.Io, method: []const u8, url: []const u8, token: []const u8, body: ?[]const u8) ?u16 {
    var reply = auth_host.AuthManager.edgeRequest(gpa, io, method, url, token, body) catch return null;
    defer reply.deinit(gpa);
    return reply.status;
}
