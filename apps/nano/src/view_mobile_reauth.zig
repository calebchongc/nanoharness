//! An agent's sign-in ran out mid-chat: the error row's controls
//! (TranscriptView.swift `reauthControls`) and the sheet that reconnects it
//! on the chat's computer (AgentReauthenticationSheet.swift). The recovery
//! itself is the app's (app_reauth.zig: StartAgentLogin, PollAgentLogin,
//! CancelAgentLogin aimed at the chat's host); the step shown is
//! reauth_recovery.zig's `cardStep`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const tr = @import("transcript.zig");
const rr = @import("reauth_recovery.zig");
const driver = @import("app_reauth.zig");
const Text = @import("app_mobile_auth.zig").Text;

/// The row whose sheet is open.
pub const Open = struct {
    chat: Text(96) = .{},
    row: Text(192) = .{},
    provider: rr.Provider = .chatgpt_new,
};

/// What an error row offers under its chip (`reauthControls`).
pub const Controls = enum {
    /// An earlier row (the chat moved on), nothing.
    none,
    /// "Continue with ChatGPT" / "Reconnect ChatGPT": opens the sheet.
    sign_in,
    /// "ChatGPT reconnected on …" with Resume conversation.
    reconnected_resume,
    /// "ChatGPT reconnected on …" alone.
    reconnected,
};

pub fn controls(step: rr.CardStep) Controls {
    return switch (step) {
        .earlier => .none,
        .reconnected => |rs| if (rs == .ready) .reconnected_resume else .reconnected,
        .offer, .starting, .waiting, .failed => .sign_in,
    };
}

pub fn signInLabel(p: rr.Provider) []const u8 {
    return if (p == .chatgpt_new) "Continue with ChatGPT" else "Reconnect ChatGPT";
}

pub fn retryLabel(p: rr.Provider) []const u8 {
    return if (p == .chatgpt_new) "Continue with ChatGPT" else "Try again";
}

/// The chat's computer by name (the sheet's `hostName`).
fn hostName(a: *const App, chat_id: []const u8) []const u8 {
    const chat = a.findChat(chat_id) orelse return "the chat's computer";
    const host = chat.device_id orelse return "the chat's computer";
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, host)) return d.name;
    return "the chat's computer";
}

fn hostOf(a: *const App, chat_id: []const u8) []const u8 {
    const chat = a.findChat(chat_id) orelse return "";
    return chat.device_id orelse "";
}

fn stepFor(a: *App, chat_id: []const u8, row_id: []const u8, provider: rr.Provider, later: bool) rr.CardStep {
    const chat = a.findChat(chat_id);
    return rr.cardStep(&a.reauth.rec, .{ .host = hostOf(a, chat_id), .provider = provider }, .{ .chat_id = chat_id, .row_id = row_id }, later, if (chat) |ch| driver.running(a, ch) else false, if (chat) |ch| driver.hasConfig(ch) else false);
}

/// Under an error part with a typed sign-in route.
pub fn rowControls(a: *App, c: *ui.Context, k: theme.Colors, entry: *const tr.Entry, p: *const tr.Part, e_idx: usize) void {
    const provider = p.reauth orelse return;
    const chat_id = a.selected orelse return;
    const row_id = c.print("{s}#{s}", .{ entry.id, p.id });
    const entries = a.transcript.entries.items;
    const later = for (entries[@min(e_idx + 1, entries.len)..]) |x| {
        if (x.role == .user) break true;
    } else false;
    const step = stepFor(a, chat_id, row_id, provider, later);
    const host = hostName(a, chat_id);
    switch (controls(step)) {
        .none => {},
        .sign_in => {
            ui.key(c, c.print("ios-reauth-{s}", .{row_id}));
            const b = ui.div(c).row().px(14).h(34).itemsCenter().roundedFull().circular().bg(k.text.alpha(0.08)).control();
            defer b.end();
            ui.text(c, signInLabel(provider), .{ .size = 14, .weight = .medium, .color = k.text });
            if (b.clicked()) open(a, chat_id, row_id, provider);
        },
        .reconnected, .reconnected_resume => |which| {
            const r = ui.div(c).row().itemsCenter().gap(6);
            {
                defer r.end();
                icons.icon(c, .check, 14, k.muted, 0);
                ui.text(c, c.print("ChatGPT reconnected on {s}", .{host}), .{ .size = 14, .weight = .medium, .color = k.muted });
            }
            if (which == .reconnected_resume) {
                ui.key(c, c.print("ios-reauth-resume-{s}", .{row_id}));
                const b = ui.div(c).row().px(14).h(34).itemsCenter().roundedFull().circular().bg(k.text.alpha(0.08)).control();
                defer b.end();
                ui.text(c, "Resume conversation", .{ .size = 14, .weight = .medium, .color = k.text });
                if (b.clicked()) driver.action(a, chat_id, row_id, provider, .@"resume");
            }
        },
    }
}

/// Opens the sheet and starts (or attaches to) the sign-in on the host, as
/// the Swift sheet's `.task` does.
pub fn open(a: *App, chat_id: []const u8, row_id: []const u8, provider: rr.Provider) void {
    const o = &a.mobile.reauth;
    o.chat.set(chat_id);
    o.row.set(row_id);
    o.provider = provider;
    a.mobile.sheet = .reauth;
    driver.action(a, chat_id, row_id, provider, .reconnect);
}

/// The sheet's body.
pub fn sheet(a: *App, c: *ui.Context, k: theme.Colors) void {
    const o = &a.mobile.reauth;
    const chat_id = o.chat.get();
    const row_id = o.row.get();
    const host = hostName(a, chat_id);
    const step = stepFor(a, chat_id, row_id, o.provider, false);
    const body = ui.div(c).column().wFull().gap(14).maxH(520).scrollY();
    defer body.end();
    para(c, k, c.print("Credentials will be saved on {s}, where this session runs. This does not sign you out of Harness.", .{host}), true);
    var done = false;
    switch (step) {
        .offer, .starting, .earlier => waiting(c, k, "Starting sign-in on the execution device…"),
        .waiting => |w| {
            if (w.code) |code| {
                ui.text(c, "Approve sign-in on your iPhone", .{ .size = 16, .weight = .medium, .color = k.text });
                para(c, k, c.print("Open the sign-in page and enter this code to approve access for {s}. Only approve a sign-in you started.", .{host}), true);
                ui.text(c, code, .{ .size = 22, .weight = .semibold, .mono = true, .color = k.text });
                {
                    const row = ui.div(c).row().gap(8);
                    defer row.end();
                    if (button(c, k, "agent-reauth-copy", "Copy code", false)) nanoui.clipboard.writeText(code);
                    if (w.url.len > 0) if (button(c, k, "agent-reauth-open", "Open ChatGPT sign-in", true)) {
                        _ = nanoui.shell.openUrl(w.url);
                    };
                }
                waiting(c, k, w.message orelse "Waiting for approval and host sign-in…");
            } else {
                ui.text(c, c.print("Complete sign-in on {s}", .{host}), .{ .size = 16, .weight = .medium, .color = k.text });
                para(c, k, c.print("This execution device uses desktop sign-in. Complete it in the browser on {s}; its local callback cannot finish in this phone's browser.", .{host}), true);
                waiting(c, k, w.message orelse "Waiting for desktop sign-in…");
            }
            para(c, k, c.print("Credentials are saved on {s}, not your iPhone. Sign-in will not resend or replay the failed message.", .{host}), true);
        },
        .failed => |msg| {
            para(c, k, msg, false);
            if (button(c, k, "agent-reauth-retry", retryLabel(o.provider), true)) driver.action(a, chat_id, row_id, o.provider, .retry);
        },
        .reconnected => |rs| {
            done = true;
            {
                const r = ui.div(c).row().itemsCenter().gap(6);
                defer r.end();
                icons.icon(c, .check, 15, k.success, 0);
                ui.text(c, c.print("ChatGPT reconnected on {s}", .{host}), .{ .size = 15, .weight = .medium, .color = k.text });
            }
            para(c, k, "Nothing was resent. Resume the conversation when you're ready, or go back and send something new.", true);
            if (rs == .ready) {
                if (button(c, k, "agent-reauth-resume", "Resume conversation", true)) {
                    driver.action(a, chat_id, row_id, o.provider, .@"resume");
                    a.mobile.sheet = .none;
                }
                if (button(c, k, "agent-reauth-return", "Return to session", false)) a.mobile.sheet = .none;
            } else if (button(c, k, "agent-reauth-return", "Return to session", true)) a.mobile.sheet = .none;
        },
    }
    if (!done) {
        ui.text(c, rr.account_security_note, .{ .size = 12, .wrap = true, .color = k.muted });
        if (button(c, k, "agent-reauth-cancel", "Cancel", false)) {
            driver.action(a, chat_id, row_id, o.provider, .cancel);
            a.mobile.sheet = .none;
        }
    }
}

fn para(c: *ui.Context, k: theme.Colors, s: []const u8, muted: bool) void {
    ui.text(c, s, .{ .size = 14, .line_height = 20, .wrap = true, .color = if (muted) k.muted else k.danger });
}

fn waiting(c: *ui.Context, k: theme.Colors, s: []const u8) void {
    const r = ui.div(c).row().itemsCenter().gap(10);
    defer r.end();
    kit.spinner(c, .{ .size = 16, .color = k.muted });
    ui.text(c, s, .{ .size = 14, .wrap = true, .color = k.text });
}

fn button(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8, primary: bool) bool {
    ui.key(c, key);
    const b = ui.div(c).row().px(16).h(40).center().roundedFull().circular().bg(if (primary) k.text else k.text.alpha(0.08)).control();
    defer b.end();
    ui.text(c, label, .{ .size = 14, .weight = .semibold, .color = if (primary) k.background else k.text });
    return b.clicked();
}

const testing = std.testing;

test "reauth rows: earlier rows offer nothing, open ones sign in, resolved ones resume when they can" {
    try testing.expectEqual(Controls.none, controls(.earlier));
    try testing.expectEqual(Controls.sign_in, controls(.offer));
    try testing.expectEqual(Controls.sign_in, controls(.{ .failed = "x" }));
    try testing.expectEqual(Controls.reconnected_resume, controls(.{ .reconnected = .ready }));
    try testing.expectEqual(Controls.reconnected, controls(.{ .reconnected = .busy }));
    try testing.expectEqual(Controls.reconnected, controls(.{ .reconnected = .sent }));
    try testing.expectEqualStrings("Continue with ChatGPT", signInLabel(.chatgpt_new));
    try testing.expectEqualStrings("Reconnect ChatGPT", signInLabel(.codex));
    try testing.expectEqualStrings("Try again", retryLabel(.codex));
}

test "reauth sheet: Reconnect starts the sign-in on the chat's computer, shows the code, and resolves when the host says done" {
    theme.registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.mobile_preview = true;
    a.new_harness = try testing.allocator.dupe(u8, "graff");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"AuthStatus":{"$items":[{"state":"signedIn","user":{"id":"u","email":"sam@example.com","name":null}}]},
        \\ "StartAgentLogin":{"loginId":"login-1","url":"https://auth.openai.com/codex/device","mode":"device-code","code":"ABCD-1234"},
        \\ "PollAgentLogin":{"status":"done"}}
    , .{});
    a.engine.state = .connected;
    {
        const v = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"chat-r","deviceId":"dev-box","title":"Synthetic reauth","archived":false,"cwd":"/w","config":{"harness":"codex","model":"gpt-5.4"}}]
        , .{});
        defer v.deinit();
        try a.chats.replace(v.value);
        const d = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"dev-box","name":"Build Box"}]
        , .{});
        defer d.deinit();
        try a.devices.replace(d.value);
    }
    a.selected = try testing.allocator.dupe(u8, "chat-r");
    {
        const v = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[{"id":"u1","role":"user","parts":[{"kind":"text","id":"t1","text":"Run the tests"}]},
            \\ {"id":"m1","role":"assistant","parts":[{"kind":"error","id":"e1","message":"Codex needs you to sign in again.","reauth":"codex"}]}]}
        , .{});
        defer v.deinit();
        try a.transcript.apply(v.value);
    }
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view_mobile.zig").view), .{ .width = 402, .height = 874 });
    defer t.deinit();
    t.frame();
    t.frame();
    try testing.expect(t.hasText("Reconnect ChatGPT"));
    try t.clickText("Reconnect ChatGPT");
    t.frame();
    t.frame();
    try testing.expectEqual(@import("view_mobile.zig").Sheet.reauth, a.mobile.sheet);
    try testing.expect(t.hasText("Approve sign-in on your iPhone"));
    try testing.expect(t.hasText("ABCD-1234"));
    // The host is polled every 1.5 s; its Done resolves the row.
    t.advance(2);
    t.frame();
    t.frame();
    t.frame();
    try testing.expect(t.containsText("ChatGPT reconnected on Build Box"));
    try testing.expect(t.hasText("Resume conversation"));
    var sent_poll = false;
    for (a.engine.sent.items) |f| if (std.mem.indexOf(u8, f, "PollAgentLogin") != null and std.mem.indexOf(u8, f, "dev-box") != null) {
        sent_poll = true;
    };
    try testing.expect(sent_poll);
}
