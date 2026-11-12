//! The browser step of the phone's sign-in: `ASWebAuthenticationSession`
//! (SignInView.swift `AuthSessionCoordinator`), called through the
//! Objective-C runtime. AuthenticationServices is opened at run time, so the
//! app's link line doesn't change. A private browser session, as the Swift
//! app's: a signed-in codegraff.com in Safari isn't reused silently.
//!
//! The completion handler runs on the main thread and stores its answer;
//! the controller takes it from `take` on its next frame.
const std = @import("std");
const builtin = @import("builtin");

pub const available = builtin.os.tag == .ios;

pub const Outcome = union(enum) {
    /// The callback URL (owned by the caller after `take`).
    success: []u8,
    cancelled,
    failure: []u8,
};

var mutex: std.atomic.Mutex = .unlocked;
var result: ?Outcome = null;
var result_gpa: ?std.mem.Allocator = null;
var running = false;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

/// The answer, once the sheet closed; the caller frees its strings.
pub fn take() ?Outcome {
    lock();
    defer mutex.unlock();
    const r = result;
    result = null;
    return r;
}

fn put(o: Outcome) void {
    lock();
    defer mutex.unlock();
    if (result) |old| free(old);
    result = o;
    running = false;
}

pub fn free(o: Outcome) void {
    const gpa = result_gpa orelse return;
    switch (o) {
        .success => |s| gpa.free(s),
        .failure => |s| gpa.free(s),
        .cancelled => {},
    }
}

const impl = if (available) struct {
    const nanoui = @import("nanoui");
    const objc = nanoui.objc;

    extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;

    var session: ?objc.Object = null;
    var provider: ?objc.Object = null;
    const Ctx = struct {};
    var ctx: Ctx = .{};

    fn done(_: *Ctx, url: ?objc.Object, err: ?objc.Object) void {
        const gpa = result_gpa orelse return;
        if (url) |u| {
            const s = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
            put(.{ .success = gpa.dupe(u8, s) catch return put(.cancelled) });
        } else if (err) |e| {
            // ASWebAuthenticationSessionErrorCodeCanceledLogin = 1.
            const domain = objc.fromNSString(objc.msg(?objc.Object, e, "domain", .{}));
            const code = objc.msg(objc.NSInteger, e, "code", .{});
            if (code == 1 and std.mem.indexOf(u8, domain, "WebAuthenticationSession") != null) {
                put(.cancelled);
            } else {
                const why = objc.fromNSString(objc.msg(?objc.Object, e, "localizedDescription", .{}));
                put(.{ .failure = gpa.dupe(u8, if (why.len > 0) why else "Sign-in failed") catch return put(.cancelled) });
            }
        } else {
            put(.{ .failure = gpa.dupe(u8, "Sign-in failed") catch return put(.cancelled) });
        }
        if (session) |s| objc.release(s);
        session = null;
    }

    const DoneBlock = objc.Block(Ctx, &.{ ?objc.Object, ?objc.Object });

    fn presentationAnchor(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) ?objc.Object {
        const app = nanoui.App.shared() orelse return null;
        const top = app.topController() orelse return null;
        const view = objc.msg(?objc.Object, top, "view", .{}) orelse return null;
        return objc.msg(?objc.Object, view, "window", .{});
    }

    fn start(url: []const u8, scheme: []const u8) bool {
        _ = dlopen("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices", 1);
        if (objc_getClass("ASWebAuthenticationSession") == null) return false;
        const pool = objc.Pool.push();
        defer pool.pop();
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return false;
        var block = DoneBlock.init(&ctx, done);
        const s = objc.msg(objc.Object, objc.alloc("ASWebAuthenticationSession"), "initWithURL:callbackURLScheme:completionHandler:", .{
            nsurl, objc.nsString(scheme), @as(*anyopaque, @ptrCast(&block)),
        });
        if (provider == null) {
            const cls = objc.defineClass(.{
                .name = "HarnessWebAuthAnchor",
                .protocols = &.{"ASWebAuthenticationPresentationContextProviding"},
                .methods = &.{.{ .name = "presentationAnchorForWebAuthenticationSession:", .imp = &presentationAnchor, .types = "@@:@" }},
            });
            provider = objc.msg(objc.Object, cls, "new", .{});
        }
        objc.msg(void, s, "setPresentationContextProvider:", .{provider.?});
        objc.msg(void, s, "setPrefersEphemeralWebBrowserSession:", .{objc.YES});
        if (session) |old| {
            objc.msg(void, old, "cancel", .{});
            objc.release(old);
        }
        session = s;
        return objc.msg(objc.BOOL, s, "start", .{});
    }

    fn cancel() void {
        if (session) |s| {
            objc.msg(void, s, "cancel", .{});
        }
    }
} else struct {
    fn start(_: []const u8, _: []const u8) bool {
        return false;
    }
    fn cancel() void {}
};

/// Opens the sign-in sheet on `url`, answering when the browser lands on
/// `scheme://`. False when the system has no such sheet (not iOS).
pub fn start(gpa: std.mem.Allocator, url: []const u8, scheme: []const u8) bool {
    if (!available) return false;
    result_gpa = gpa;
    lock();
    running = true;
    mutex.unlock();
    if (!impl.start(url, scheme)) {
        lock();
        running = false;
        mutex.unlock();
        return false;
    }
    return true;
}

/// Closes the sheet: the sign-in finished elsewhere.
pub fn cancel() void {
    impl.cancel();
}

test "off iOS there is no sheet to start, and nothing to take" {
    if (available) return error.SkipZigTest;
    try std.testing.expect(!start(std.testing.allocator, "https://example.com", "harness"));
    try std.testing.expect(take() == null);
}
