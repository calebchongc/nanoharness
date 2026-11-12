//! Keep the computer awake while agents work, ported from
//! `crates/engine/src/keep_awake.rs`. While the setting is on and any chat
//! running on this device is working, the engine holds a "prevent idle system
//! sleep" power assertion (what `caffeinate -i` does) and drops it the moment
//! every chat goes idle. A chat waiting on a question does not count.
//!
//! Like Rust, only macOS can hold the assertion (`SUPPORTED`); elsewhere
//! `SetKeepAwake { enabled: true }` fails and nothing is taken.
//!
//! Rust follows the sessions and the setting from a task; here `follow` runs
//! whenever the sessions are broadcast or the setting changes, and `release`
//! when the engine shuts down. The assertion itself goes through `backend`, a
//! seam: test builds start with a fake that only counts, so no test ever
//! takes a real power assertion.
const std = @import("std");
const builtin = @import("builtin");
const engine_host = @import("engine_host.zig");

/// `keep_awake::SUPPORTED`.
pub const supported = builtin.os.tag == .macos;

pub const Backend = struct {
    acquire: *const fn () ?u32,
    release: *const fn (u32) void,
};

/// How the assertion is taken. Tests swap in their own.
pub var backend: Backend = if (builtin.is_test) fake_backend else platform_backend;

/// The held assertion, if any. The engine has one host per process and
/// calls `follow` under its lock.
var held: ?u32 = null;

pub fn isHeld() bool {
    return held != null;
}

/// `agents_working`: any chat this device runs whose status is working.
pub fn agentsWorking(host: *const engine_host.EngineHost) bool {
    for (host.chats.items) |c| {
        if (!std.mem.eql(u8, c.device_id, host.device_id)) continue;
        const status = c.activity_status orelse continue;
        if (std.mem.eql(u8, status, "working")) return true;
    }
    return false;
}

/// One step of Rust's watcher loop: take the assertion when the setting and
/// the sessions both want it, drop it when either stops. A failed take is
/// retried on the next change.
pub fn follow(host: *const engine_host.EngineHost) void {
    const want = host.keep_awake_enabled and agentsWorking(host);
    if (want and held == null) {
        held = backend.acquire();
    } else if (!want) {
        release();
    }
}

/// Drop a held assertion (engine shutdown, the setting off, every chat idle).
pub fn release() void {
    if (held) |id| {
        held = null;
        backend.release(id);
    }
}

// ── backends ───────────────────────────────────────────────────────────────

pub const fake_backend: Backend = .{ .acquire = Fake.acquire, .release = Fake.release };

/// Counts takes and releases; never touches the power manager.
pub const Fake = struct {
    pub var holding: usize = 0;
    pub var attempts: usize = 0;
    pub var fail_next: bool = false;
    var next_id: u32 = 1;

    fn acquire() ?u32 {
        attempts += 1;
        if (fail_next) {
            fail_next = false;
            return null;
        }
        holding += 1;
        next_id += 1;
        return next_id;
    }

    fn release(_: u32) void {
        holding -= 1;
    }

    pub fn reset() void {
        holding = 0;
        attempts = 0;
        fail_next = false;
    }
};

const platform_backend: Backend = if (builtin.os.tag == .macos)
    .{ .acquire = MacOs.acquire, .release = MacOs.release }
else
    .{ .acquire = Unsupported.acquire, .release = Unsupported.release };

const Unsupported = struct {
    fn acquire() ?u32 {
        return null;
    }
    fn release(_: u32) void {}
};

/// IOKit's `IOPMAssertionCreateWithName`, loaded at run time so the engine
/// links no extra framework.
const MacOs = struct {
    const CFStringRef = ?*anyopaque;
    const CreateString = *const fn (?*anyopaque, [*:0]const u8, u32) callconv(.c) CFStringRef;
    const Release = *const fn (?*anyopaque) callconv(.c) void;
    const AssertionCreate = *const fn (CFStringRef, u32, CFStringRef, *u32) callconv(.c) i32;
    const AssertionRelease = *const fn (u32) callconv(.c) i32;

    const k_cf_string_encoding_utf8: u32 = 0x0800_0100;
    const assertion_level_on: u32 = 255;

    const Fns = struct {
        create_string: CreateString,
        cf_release: Release,
        create: AssertionCreate,
        release: AssertionRelease,
    };

    fn load() ?Fns {
        if (comptime builtin.os.tag != .macos) return null;
        const cf = std.c.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", .{ .NOW = true }) orelse return null;
        const iokit = std.c.dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", .{ .NOW = true }) orelse return null;
        return .{
            .create_string = @ptrCast(std.c.dlsym(cf, "CFStringCreateWithCString") orelse return null),
            .cf_release = @ptrCast(std.c.dlsym(cf, "CFRelease") orelse return null),
            .create = @ptrCast(std.c.dlsym(iokit, "IOPMAssertionCreateWithName") orelse return null),
            .release = @ptrCast(std.c.dlsym(iokit, "IOPMAssertionRelease") orelse return null),
        };
    }

    fn acquire() ?u32 {
        const f = load() orelse {
            std.log.warn("keep-awake power assertion failed: IOKit is unavailable", .{});
            return null;
        };
        const kind = f.create_string(null, "PreventUserIdleSystemSleep", k_cf_string_encoding_utf8);
        defer if (kind != null) f.cf_release(kind);
        const name = f.create_string(null, "Harness: agents are working", k_cf_string_encoding_utf8);
        defer if (name != null) f.cf_release(name);
        if (kind == null or name == null) return null;
        var id: u32 = 0;
        const status = f.create(kind, assertion_level_on, name, &id);
        if (status != 0) {
            std.log.warn("keep-awake power assertion failed (status {d})", .{status});
            return null;
        }
        std.log.info("keeping the Mac awake while agents work", .{});
        return id;
    }

    fn release(id: u32) void {
        const f = load() orelse return;
        _ = f.release(id);
        std.log.info("agents idle; the Mac may sleep again", .{});
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn setStatus(host: *engine_host.EngineHost, chat_id: []const u8, status: ?[]const u8) !void {
    for (host.chats.items) |*c| {
        if (!std.mem.eql(u8, c.id, chat_id)) continue;
        if (c.activity_status) |old| host.gpa.free(old);
        c.activity_status = if (status) |s| try host.gpa.dupe(u8, s) else null;
    }
}

test "rpcw_keep_awake holds one assertion only while the setting is on and a local chat works" {
    const gpa = testing.allocator;
    Fake.reset();
    defer Fake.reset();
    var host = try engine_host.EngineHost.init(gpa, "dev-awake", "Synthetic");
    defer host.deinit();
    defer release();
    var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"op\":\"createChat\",\"chatId\":\"c1\",\"config\":{\"harness\":\"mock\"}}", .{});
    defer p.deinit();
    const r = try host.handle("Mutate", p.value);
    if (r == .unary_json) gpa.free(r.unary_json);

    try setStatus(&host, "c1", "working");
    host.keep_awake_enabled = false;
    follow(&host);
    try testing.expectEqual(@as(usize, 0), Fake.holding); // off by default

    host.keep_awake_enabled = true;
    follow(&host);
    try testing.expectEqual(@as(usize, 1), Fake.holding);
    follow(&host);
    try testing.expectEqual(@as(usize, 1), Fake.attempts); // one assertion covers it

    try setStatus(&host, "c1", "awaitingInput");
    follow(&host);
    try testing.expectEqual(@as(usize, 0), Fake.holding); // a question doesn't count

    try setStatus(&host, "c1", "working");
    follow(&host);
    try testing.expectEqual(@as(usize, 1), Fake.holding);
    host.keep_awake_enabled = false;
    follow(&host);
    try testing.expectEqual(@as(usize, 0), Fake.holding);

    // A failed take retries on the next change.
    host.keep_awake_enabled = true;
    Fake.fail_next = true;
    follow(&host);
    try testing.expectEqual(@as(usize, 0), Fake.holding);
    follow(&host);
    try testing.expectEqual(@as(usize, 1), Fake.holding);

    // A chat that another device runs doesn't keep this one awake.
    for (host.chats.items) |*c| {
        gpa.free(c.device_id);
        c.device_id = try gpa.dupe(u8, "dev-other");
    }
    follow(&host);
    try testing.expectEqual(@as(usize, 0), Fake.holding);
}
