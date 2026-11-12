//! Session notifications on iOS, as the Swift app has them
//! (apps/ios PushNotifications.swift): a run finished, a session waiting on
//! you, a run failed. The edge decides and sends them over APNs; the phone
//! asks for permission (only when the person says yes, never at launch),
//! hands the edge its token and choices, stays quiet while the app is open,
//! and opens the chat a tapped notification is about.
//!
//! The rules are pure functions (tested in this file); `runtime` is the iOS
//! side, through the Objective-C runtime as nanoui makes its other system
//! calls. The settings and onboarding screens call `runtime.setEnabled`,
//! `runtime.setKind` and `runtime.requestPermission`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ── Rules ────────────────────────────────────────────────────────────────

pub const Kind = enum {
    done,
    input,
    failed,

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .done => "Run finished",
            .input => "Waiting on your input",
            .failed => "Run failed",
        };
    }
};

/// The person's choices, kept in NSUserDefaults under the Swift app's keys;
/// each is on unless turned off.
pub const Prefs = struct {
    enabled: bool = true,
    done: bool = true,
    input: bool = true,
    failed: bool = true,

    pub fn on(p: Prefs, k: Kind) bool {
        return switch (k) {
            .done => p.done,
            .input => p.input,
            .failed => p.failed,
        };
    }
};

pub const enabled_key = "notifications.enabled";

pub fn kindKey(k: Kind) [:0]const u8 {
    return switch (k) {
        .done => "notifications.done",
        .input => "notifications.input",
        .failed => "notifications.failed",
    };
}

/// UNAuthorizationStatus.
pub const Status = enum(isize) { not_determined = 0, denied = 1, authorized = 2, provisional = 3, ephemeral = 4, _ };

pub fn allowed(s: Status) bool {
    return s == .authorized or s == .provisional or s == .ephemeral;
}

/// UNAuthorizationOptions: badge | sound | alert.
pub const permission_options: usize = (1 << 0) | (1 << 1) | (1 << 2);
/// UNNotificationPresentationOptions while the app is open: none, the list
/// and the chat already show it.
pub const in_app_presentation: usize = 0;

/// Signed in, or launched signed in: register again if the system already
/// allows notifications (tokens change between launches; the edge keeps
/// the latest). Never asks: the prompt only follows a yes.
pub fn registerAtSignIn(s: Status) bool {
    return allowed(s);
}

pub const PermissionAction = enum { ask, register, none };

/// The person said yes (onboarding's "Notify me", or the Notifications
/// screen opened with notifications on): ask once; after that it's the
/// Settings app's call.
pub fn permissionAction(s: Status) PermissionAction {
    if (s == .not_determined) return .ask;
    return if (allowed(s)) .register else .none;
}

/// Opening the Notifications screen with them on is the person asking.
pub fn askOnScreen(enabled: bool, demo: bool, s: Status) bool {
    return enabled and !demo and s == .not_determined;
}

pub const SyncAction = enum { register, unregister, none };

/// What to tell the edge now: this phone's token and choices, that it wants
/// nothing (turned off here), or nothing yet (no token, demo, signed out).
pub fn syncAction(demo: bool, signed_in: bool, enabled: bool, have_token: bool) SyncAction {
    if (demo or !signed_in) return .none;
    if (!enabled) return .unregister;
    return if (have_token) .register else .none;
}

/// The token as the edge takes it: the APNs bytes in lowercase hex.
pub fn tokenHex(bytes: []const u8, out: []u8) []const u8 {
    const digits = "0123456789abcdef";
    const n = @min(bytes.len, out.len / 2);
    for (bytes[0..n], 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 15];
    }
    return out[0 .. 2 * n];
}

/// Which APNs this build's tokens belong to: the Simulator's and
/// development-signed builds (their profile says so) are sandbox; App
/// Store and TestFlight builds carry no such line and are production.
pub fn apnsEnvironment(simulator: bool, profile: ?[]const u8) []const u8 {
    if (simulator) return "sandbox";
    const text = profile orelse return "production";
    const key = "<key>aps-environment</key>";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, key)) |at| {
        var i = at + key.len;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (std.mem.startsWith(u8, text[i..], "<string>development</string>")) return "sandbox";
        from = i;
    }
    return "production";
}

/// POST /registry/{org}/push-target?device= (DELETE to unregister).
pub fn targetUrl(gpa: Allocator, edge: []const u8, org: []const u8, device: []const u8) ![]u8 {
    const auth_host = @import("auth_host.zig");
    const enc_org = try auth_host.urlEncodeAlloc(gpa, org);
    defer gpa.free(enc_org);
    const enc_dev = try auth_host.urlEncodeAlloc(gpa, device);
    defer gpa.free(enc_dev);
    return std.fmt.allocPrint(gpa, "{s}/registry/{s}/push-target?device={s}", .{ std.mem.trimEnd(u8, edge, "/"), enc_org, enc_dev });
}

/// The registration the edge stores: `PushRegistration` in the Swift app.
pub fn registrationBody(gpa: Allocator, token: []const u8, environment: []const u8, p: Prefs) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"token\":{f},\"environment\":{f},\"prefs\":{{\"done\":{},\"input\":{},\"failed\":{}}}}}", .{
        std.json.fmt(token, .{}),
        std.json.fmt(environment, .{}),
        p.done,
        p.input,
        p.failed,
    });
}

/// The chat a tapped notification is about (`userInfo["chatId"]`).
pub fn tapChat(chat_id: ?[]const u8) ?[]const u8 {
    const id = chat_id orelse return null;
    return if (id.len > 0) id else null;
}

pub const RouteAction = enum { open, wait };
/// How long a tapped chat waits for the chat list (a cold launch) before
/// it opens anyway.
pub const route_attempts: u32 = 20;

/// A tapped chat opens once the app is signed in and knows the chat, or,
/// signed in, after `route_attempts` ticks whatever the list says.
pub fn routeAction(signed_in: bool, chat_known: bool, attempts: u32) RouteAction {
    if (!signed_in) return .wait;
    return if (chat_known or attempts >= route_attempts) .open else .wait;
}

// ── iOS ──────────────────────────────────────────────────────────────────

/// UIKit and UserNotifications through the Objective-C runtime. Only iOS
/// builds reference it (ios_ship.zig).
pub const runtime = struct {
    const nanoui = @import("nanoui");
    const objc = nanoui.objc;
    const App = @import("app.zig").App;
    const engine_host = @import("engine_host.zig");
    const ios_edge = @import("ios_edge.zig");

    extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;
    extern "c" fn class_addMethod(cls: objc.Class, name: objc.SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

    var gpa: Allocator = undefined;
    var io: std.Io = undefined;
    var app: ?*App = null;
    var host: ?*engine_host.EngineHost = null;
    var demo = false;
    var simulator = false;
    var was_signed_in = false;
    /// This phone's APNs token, hex (main thread).
    var token_buf: [256]u8 = undefined;
    var token: ?[]const u8 = null;
    var pending_chat_buf: [256]u8 = undefined;
    var pending_chat: ?[]const u8 = null;
    var pending_attempts: u32 = 0;
    var delegate_methods_added = false;
    var device_buf: [128]u8 = undefined;
    var device: []const u8 = "";
    var environment: []const u8 = "production";
    var notification_delegate: ?objc.Object = null;

    /// Before `app.run`: the notification center's delegate is set before
    /// launch finishes, so a tap that launched the app is routed too.
    pub fn install(allocator: Allocator, rio: std.Io, a: *App, h: *engine_host.EngineHost, is_demo: bool) void {
        gpa = allocator;
        io = rio;
        app = a;
        host = h;
        demo = is_demo;
        simulator = builtin.target.abi == .simulator;
        device = engine_host.sanitizeEdgeDeviceId(&device_buf, h.device_id);
        environment = apnsEnvironment(simulator, readProfile());
        const cls = objc.defineClass(.{
            .name = "HarnessNotificationDelegate",
            .protocols = &.{"UNUserNotificationCenterDelegate"},
            .methods = &.{
                .{ .name = "userNotificationCenter:willPresentNotification:withCompletionHandler:", .imp = &willPresent, .types = "v@:@@@?" },
                .{ .name = "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", .imp = &didReceive, .types = "v@:@@@?" },
            },
        });
        const obj = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
        notification_delegate = obj; // kept: the center holds it weakly
        objc.msg(void, center(), "setDelegate:", .{obj});
        objc.dispatchAfter(std.time.ns_per_s, null, tick);
    }

    fn center() objc.Object {
        return objc.msg(objc.Object, objc.class("UNUserNotificationCenter"), "currentNotificationCenter", .{});
    }

    fn sharedApplication() objc.Object {
        return objc.msg(objc.Object, objc.class("UIApplication"), "sharedApplication", .{});
    }

    /// `embedded.mobileprovision`'s bytes (a device build's), for the APNs
    /// environment; null in the Simulator and App Store builds.
    fn readProfile() ?[]const u8 {
        const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
        const dir = objc.fromNSString(objc.msg(?objc.Object, bundle, "bundlePath", .{}));
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/embedded.mobileprovision", .{dir}) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
    }

    // ── Choices ──

    fn defaults() objc.Object {
        return objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    }

    fn flag(key: [:0]const u8) bool {
        const d = defaults();
        if (objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString(key)}) == null) return true;
        return objc.msg(bool, d, "boolForKey:", .{objc.nsString(key)});
    }

    pub fn prefs() Prefs {
        return .{ .enabled = flag(enabled_key), .done = flag(kindKey(.done)), .input = flag(kindKey(.input)), .failed = flag(kindKey(.failed)) };
    }

    pub fn setEnabled(on: bool) void {
        objc.msg(void, defaults(), "setBool:forKey:", .{ on, objc.nsString(enabled_key) });
        sync();
    }

    pub fn setKind(k: Kind, on: bool) void {
        objc.msg(void, defaults(), "setBool:forKey:", .{ on, objc.nsString(kindKey(k)) });
        sync();
    }

    // ── Signed in, signed out ──

    fn signedIn() bool {
        const h = host orelse return false;
        return @atomicLoad(bool, &h.auth.signed_in, .monotonic);
    }

    /// Each second on the main thread: sign-in changes, and a tapped chat
    /// waiting for the app to know it.
    fn tick(_: ?*anyopaque) callconv(.c) void {
        const now = signedIn();
        if (now and !was_signed_in) whenAllowed(registerNow);
        if (!now and was_signed_in) {
            token = null;
            objc.msg(void, sharedApplication(), "unregisterForRemoteNotifications", .{});
        }
        was_signed_in = now;
        routePending();
        objc.dispatchAfter(std.time.ns_per_s, null, tick);
    }

    const SettingsCtx = struct { then: *const fn (?*anyopaque) callconv(.c) void };
    var settings_ctx: SettingsCtx = .{ .then = registerNow };

    /// Calls `then` on the main thread if the system allows notifications.
    fn whenAllowed(then: *const fn (?*anyopaque) callconv(.c) void) void {
        settings_ctx = .{ .then = then };
        const B = objc.Block(SettingsCtx, &.{objc.Object});
        var block = B.init(&settings_ctx, onSettings);
        objc.msg(void, center(), "getNotificationSettingsWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
    }

    fn onSettings(ctx: *SettingsCtx, settings: objc.Object) void {
        const status: Status = @enumFromInt(objc.msg(isize, settings, "authorizationStatus", .{}));
        if (registerAtSignIn(status)) objc.dispatchMain(null, ctx.then);
    }

    fn registerNow(_: ?*anyopaque) callconv(.c) void {
        addAppDelegateMethods();
        objc.msg(void, sharedApplication(), "registerForRemoteNotifications", .{});
    }

    /// nanoui's app delegate class is made when UIKit starts: the token's
    /// callbacks are added to it then, before the first registration.
    fn addAppDelegateMethods() void {
        if (delegate_methods_added) return;
        const delegate = objc.msg(?objc.Object, sharedApplication(), "delegate", .{}) orelse return;
        const cls = objc.msg(objc.Class, delegate, "class", .{});
        _ = class_addMethod(cls, objc.sel("application:didRegisterForRemoteNotificationsWithDeviceToken:"), @ptrCast(&didRegister), "v@:@@");
        _ = class_addMethod(cls, objc.sel("application:didFailToRegisterForRemoteNotificationsWithError:"), @ptrCast(&didFail), "v@:@@");
        delegate_methods_added = true;
    }

    fn didRegister(_: objc.Object, _: objc.SEL, _: objc.Object, data: objc.Object) callconv(.c) void {
        const len = objc.msg(usize, data, "length", .{});
        const bytes = objc.msg([*]const u8, data, "bytes", .{});
        token = tokenHex(bytes[0..len], &token_buf);
        sync();
    }

    fn didFail(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) void {
        std.log.warn("push registration failed", .{});
    }

    // ── Asking ──

    const AskCtx = struct { pad: u8 = 0 };
    var ask_ctx: AskCtx = .{};

    /// The person said yes: ask the system once, then register if allowed.
    pub fn requestPermission() void {
        const B = objc.Block(AskCtx, &.{objc.Object});
        var block = B.init(&ask_ctx, onAskSettings);
        objc.msg(void, center(), "getNotificationSettingsWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
    }

    fn onAskSettings(_: *AskCtx, settings: objc.Object) void {
        const status: Status = @enumFromInt(objc.msg(isize, settings, "authorizationStatus", .{}));
        switch (permissionAction(status)) {
            .none => {},
            .register => objc.dispatchMain(null, registerNow),
            .ask => {
                const B = objc.Block(AskCtx, &.{ bool, ?objc.Object });
                var block = B.init(&ask_ctx, onAnswer);
                objc.msg(void, center(), "requestAuthorizationWithOptions:completionHandler:", .{ permission_options, @as(*anyopaque, @ptrCast(&block)) });
            },
        }
    }

    fn onAnswer(_: *AskCtx, granted: bool, _: ?objc.Object) void {
        if (granted) objc.dispatchMain(null, registerNow);
    }

    // ── Telling the edge ──

    const Job = struct { url_method: []const u8, body: ?[]u8 };

    /// Tells the edge what this phone wants now, off the main thread.
    pub fn sync() void {
        const p = prefs();
        const action = syncAction(demo, signedIn(), p.enabled, token != null);
        const body: ?[]u8 = switch (action) {
            .none => return,
            .register => registrationBody(gpa, token.?, environment, p) catch return,
            .unregister => null,
        };
        const job = gpa.create(Job) catch {
            if (body) |b| gpa.free(b);
            return;
        };
        job.* = .{ .url_method = if (action == .register) "POST" else "DELETE", .body = body };
        const th = std.Thread.spawn(.{}, send, .{job}) catch {
            if (body) |b| gpa.free(b);
            gpa.destroy(job);
            return;
        };
        th.detach();
    }

    fn send(job: *Job) void {
        defer {
            if (job.body) |b| gpa.free(b);
            gpa.destroy(job);
        }
        const h = host orelse return;
        var creds = ios_edge.snapshot(gpa, h) orelse return;
        defer creds.deinit(gpa);
        const url = targetUrl(gpa, creds.edge, creds.org, creds.device) catch return;
        defer gpa.free(url);
        const status = ios_edge.send(gpa, io, job.url_method, url, creds.token, job.body);
        if (status == null or status.? < 200 or status.? >= 300) std.log.warn("push target sync failed", .{});
    }

    /// auth_host's sign-out, while the sign-in still works: this phone stops
    /// getting the account's notifications.
    pub fn signingOut(auth: anytype, rio: ?std.Io) void {
        if (host == null or demo) return;
        const sio = rio orelse return;
        if (!auth.signed_in) return;
        const edge = auth.edge_url orelse return;
        const org = auth.org_id orelse return;
        const tok = auth.ensureAccessToken(sio, false) orelse return;
        const url = targetUrl(gpa, edge, org, device) catch return;
        const tok_copy = gpa.dupe(u8, tok) catch {
            gpa.free(url);
            return;
        };
        const th = std.Thread.spawn(.{}, sendDelete, .{ url, tok_copy }) catch {
            gpa.free(url);
            gpa.free(tok_copy);
            return;
        };
        th.detach();
    }

    fn sendDelete(url: []u8, tok: []u8) void {
        defer gpa.free(url);
        defer gpa.free(tok);
        _ = ios_edge.send(gpa, io, "DELETE", url, tok, null);
    }

    // ── Delivery ──

    const BlockHeader = extern struct { isa: ?*anyopaque, flags: i32, reserved: i32, invoke: *const anyopaque };

    /// Calls a completion handler UIKit passed in: `void (^)(void)`.
    fn callBlock0(block: *anyopaque) void {
        const header: *const BlockHeader = @ptrCast(@alignCast(block));
        const f: *const fn (*anyopaque) callconv(.c) void = @ptrCast(@alignCast(header.invoke));
        f(block);
    }

    /// `void (^)(NSUInteger)`.
    fn callBlockUsize(block: *anyopaque, value: usize) void {
        const header: *const BlockHeader = @ptrCast(@alignCast(block));
        const f: *const fn (*anyopaque, usize) callconv(.c) void = @ptrCast(@alignCast(header.invoke));
        f(block, value);
    }

    /// In the app: no banner.
    fn willPresent(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, handler: *anyopaque) callconv(.c) void {
        std.log.warn("push: in-app notification, no banner", .{});
        callBlockUsize(handler, in_app_presentation);
    }

    /// Tapped: that chat, now or once the app can show it.
    fn didReceive(_: objc.Object, _: objc.SEL, _: objc.Object, response: objc.Object, handler: *anyopaque) callconv(.c) void {
        const notification = objc.msg(objc.Object, response, "notification", .{});
        const request = objc.msg(objc.Object, notification, "request", .{});
        const content = objc.msg(objc.Object, request, "content", .{});
        const info = objc.msg(?objc.Object, content, "userInfo", .{});
        const value: ?objc.Object = if (info) |d| objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString("chatId")}) else null;
        const is_string = if (value) |v| objc.msg(bool, v, "isKindOfClass:", .{objc.class("NSString")}) else false;
        if (tapChat(if (is_string) objc.fromNSString(value) else null)) |chat| {
            const n = @min(chat.len, pending_chat_buf.len);
            @memcpy(pending_chat_buf[0..n], chat[0..n]);
            pending_chat = pending_chat_buf[0..n];
            pending_attempts = 0;
            routePending();
        }
        callBlock0(handler);
    }

    fn routePending() void {
        const chat = pending_chat orelse return;
        const a = app orelse return;
        const known = a.findChat(chat) != null;
        switch (routeAction(signedIn(), known, pending_attempts)) {
            .wait => pending_attempts += 1,
            .open => {
                pending_chat = null;
                const space = if (a.findChat(chat)) |c| c.space_id else null;
                a.mobile.tail_cap = @import("ios_scroll.zig").default_tail_cap;
                a.mobile.stick_to_bottom = true;
                a.openChat(chat, space);
                a.redraw();
            },
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the prompt only follows a yes; launch and sign-in only re-register" {
    try testing.expect(!registerAtSignIn(.not_determined));
    try testing.expect(!registerAtSignIn(.denied));
    try testing.expect(registerAtSignIn(.authorized));
    try testing.expect(registerAtSignIn(.provisional));
    try testing.expect(registerAtSignIn(.ephemeral));
    try testing.expectEqual(PermissionAction.ask, permissionAction(.not_determined));
    try testing.expectEqual(PermissionAction.register, permissionAction(.authorized));
    try testing.expectEqual(PermissionAction.none, permissionAction(.denied));
    try testing.expect(askOnScreen(true, false, .not_determined));
    try testing.expect(!askOnScreen(false, false, .not_determined));
    try testing.expect(!askOnScreen(true, true, .not_determined));
    try testing.expect(!askOnScreen(true, false, .denied));
    try testing.expectEqual(@as(usize, 7), permission_options);
    try testing.expectEqual(@as(usize, 0), in_app_presentation);
}

test "syncAction: register with a token, unregister when turned off, nothing in demo or signed out" {
    try testing.expectEqual(SyncAction.register, syncAction(false, true, true, true));
    try testing.expectEqual(SyncAction.none, syncAction(false, true, true, false));
    try testing.expectEqual(SyncAction.unregister, syncAction(false, true, false, true));
    try testing.expectEqual(SyncAction.unregister, syncAction(false, true, false, false));
    try testing.expectEqual(SyncAction.none, syncAction(true, true, true, true));
    try testing.expectEqual(SyncAction.none, syncAction(false, false, true, true));
}

test "the registration request: endpoint, payload, token hex" {
    const gpa = testing.allocator;
    const url = try targetUrl(gpa, "https://edge.example.com/", "org synth", "dev-1");
    defer gpa.free(url);
    try testing.expectEqualStrings("https://edge.example.com/registry/org%20synth/push-target?device=dev-1", url);

    var hex_buf: [64]u8 = undefined;
    const hex = tokenHex(&.{ 0x00, 0x0f, 0xa0, 0xff }, &hex_buf);
    try testing.expectEqualStrings("000fa0ff", hex);

    const body = try registrationBody(gpa, hex, "sandbox", .{ .input = false });
    defer gpa.free(body);
    try testing.expectEqualStrings("{\"token\":\"000fa0ff\",\"environment\":\"sandbox\",\"prefs\":{\"done\":true,\"input\":false,\"failed\":true}}", body);
    try testing.expectEqualStrings("notifications.input", kindKey(.input));
    try testing.expect(!(Prefs{ .failed = false }).on(.failed));
}

test "the APNs environment: Simulator sandbox, development profile sandbox, otherwise production" {
    try testing.expectEqualStrings("sandbox", apnsEnvironment(true, null));
    try testing.expectEqualStrings("production", apnsEnvironment(false, null));
    try testing.expectEqualStrings("sandbox", apnsEnvironment(false, "\x30\x80<plist><dict><key>aps-environment</key>\n\t\t<string>development</string></dict>"));
    try testing.expectEqualStrings("production", apnsEnvironment(false, "<key>aps-environment</key><string>production</string>"));
    try testing.expectEqualStrings("production", apnsEnvironment(false, "<key>get-task-allow</key><true/>"));
}

test "a tapped notification opens its chat once the app can show it" {
    try testing.expectEqualStrings("chat-synth", tapChat("chat-synth").?);
    try testing.expectEqual(@as(?[]const u8, null), tapChat(""));
    try testing.expectEqual(@as(?[]const u8, null), tapChat(null));
    try testing.expectEqual(RouteAction.wait, routeAction(false, true, 100));
    try testing.expectEqual(RouteAction.open, routeAction(true, true, 0));
    try testing.expectEqual(RouteAction.wait, routeAction(true, false, route_attempts - 1));
    try testing.expectEqual(RouteAction.open, routeAction(true, false, route_attempts));
}
