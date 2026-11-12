//! The agent's question in the composer's place (ComposerView.swift
//! `QuestionPanel`): every question in turn, its header and "1/3", the
//! question, its options (numbered, picked as the Swift rows are), "Or type
//! your own answer", Back and Next/Submit, answered through the engine's
//! `respondInput`; "Cancel question" sends `dismissInput`. A tool approval
//! (the engine's "Approve tool" Yes/No, or an agent's Allow / Always / Deny)
//! is a card of its own with those buttons.
//!
//! The panel is the app's wizard (app_question.zig): the composer's text is
//! the page's typed answer, set aside and brought back around the question.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const mg = @import("mobile_glass.zig");
const mq = @import("mobile_question.zig");

const badges = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };

/// Room the panel takes above the safe area, for the transcript's padding.
pub fn height(a: *const App) f32 {
    const w = a.wizard orelse return 0;
    if (a.mobile.question_h > 0) return a.mobile.question_h + 16;
    if (w.questions.len == 1 and mq.approval(w.questions[0]) != null) return 170;
    return 380;
}

/// Keeps the card's laid-out height for the next frame's placement; the
/// frame lays out again when it changed.
fn measure(a: *App, c: *ui.Context, index: u32) void {
    c.node(index).layout_dependent = true;
    if (c.rects.get(c.node(index).id)) |r| a.mobile.question_h = r.h;
}

pub fn active(a: *const App) bool {
    return a.wizard != null;
}

fn nowMs(a: *const App) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(a.io).nanoseconds, std.time.ns_per_ms));
}

/// Draws the panel; the caller keeps the composer away meanwhile.
pub fn panel(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    const wz = if (a.wizard) |*x| x else return;
    // Submit, Back and Cancel close or turn the wizard `wz` points into, so
    // a button's action waits until the panel is drawn (view_question.zig).
    var act: enum { none, advance, back, dismiss } = .none;
    defer switch (act) {
        .none => {},
        .advance => a.wizardAdvance(),
        .back => a.wizardBack(),
        .dismiss => a.wizardDismiss(),
    };
    const closing = struct {
        fn mark(app: *App, req: []const u8) void {
            app.mobile.markAnswered(req, nowMs(app));
        }
    };

    if (wz.questions.len == 1) if (mq.approval(wz.questions[0])) |ap| {
        const q = wz.questions[0];
        ui.key(c, "ios-approval-card");
        const card = mg.styleGlassDiv(c, ui.div(c).column().wFull().p(16).gap(12), .question_panel, rt, ui.Color.transparent, null);
        defer card.end();
        measure(a, c, card.index);
        {
            const h = ui.div(c).row().wFull().itemsCenter().gap(8);
            defer h.end();
            icons.icon(c, .@"key-minimalistic", 14, k.warning, 0);
            ui.text(c, "APPROVE TOOL", .{ .size = 10.5, .weight = .medium, .color = k.muted.alpha(0.6) });
        }
        ui.text(c, q.question, .{ .size = 15, .weight = .medium, .line_height = 21, .wrap = true, .color = k.text });
        const row = ui.div(c).row().wFull().gap(8);
        defer row.end();
        var chosen: ?usize = null;
        if (approvalButton(c, k, "ios-approval-deny", "Deny", false)) chosen = ap.deny;
        if (ap.always) |i| if (approvalButton(c, k, "ios-approval-always", q.options[i], false)) {
            chosen = i;
        };
        if (approvalButton(c, k, "ios-approval-allow", "Allow", true)) chosen = ap.allow;
        if (chosen) |i| {
            closing.mark(a, wz.request_id);
            a.composer.set("");
            a.wizardPick(i);
            act = .advance;
            nanoui.haptics.notify(if (i == ap.deny) .warning else .success);
        }
        return;
    };

    const q = wz.question();
    const typed = a.composer.text();
    ui.key(c, "ios-question-panel");
    const card = mg.styleGlassDiv(c, ui.div(c).column().wFull().p(16).gap(12), .question_panel, rt, ui.Color.transparent, null);
    defer card.end();
    measure(a, c, card.index);
    {
        // Header, question and options scroll inside 300 points.
        ui.key(c, "ios-question-prompt");
        const sc = ui.div(c).column().wFull().maxH(300).gap(12).scrollY();
        defer sc.end();
        {
            const h = ui.div(c).row().wFull().itemsCenter().justifyBetween();
            defer h.end();
            ui.text(c, upper(c, q.header), .{ .size = 10.5, .weight = .medium, .color = k.muted.alpha(0.6) });
            if (wz.questions.len > 1) {
                const tag = ui.div(c).row().px(6).h(20).itemsCenter().rounded(6).bg(k.text.alpha(0.06));
                defer tag.end();
                ui.text(c, counterText(c, wz.page, wz.questions.len), .{ .size = 10, .color = k.muted });
            }
        }
        ui.text(c, q.question, .{ .size = 15, .weight = .medium, .line_height = 21, .wrap = true, .color = k.text });
        if (q.multi_select) ui.text(c, "Select one or more options.", .{ .size = 12, .color = k.muted });
        const opts = ui.div(c).column().wFull().gap(4);
        defer opts.end();
        for (q.options, 0..) |opt, i| {
            const picked = mq.showsPicked(wz.picked(i), typed);
            ui.keyInt(c, 0x7175_0000 + i);
            const r = ui.div(c).row().wFull().px(14).py(10).gap(10).itemsCenter().rounded(12)
                .bg(k.text.alpha(if (picked) 0.09 else 0.025)).border(if (picked) k.text.alpha(0.16) else ui.Color.transparent).borderW(1).control();
            defer r.end();
            {
                const l = ui.div(c).column().grow();
                defer l.end();
                ui.text(c, opt, .{ .size = 13.5, .weight = .medium, .wrap = true, .color = k.text });
            }
            if (i < badges.len) {
                const b = ui.div(c).row().size(22, 22).center().rounded(6).bg(k.text.alpha(0.06));
                defer b.end();
                ui.text(c, badges[i], .{ .size = 11, .color = k.muted });
            }
            if (r.clicked()) {
                // Typed text gives way to a pick (`pick`).
                if (typed.len > 0) a.composer.set("");
                a.wizardPick(i);
                nanoui.haptics.selection();
            }
        }
    }
    {
        _ = ui.div(c).wFull().h(1).bg(k.text.alpha(0.06)).end();
        ui.key(c, "ios-question-typed");
        _ = ui.textField(c, &a.composer, .{
            .placeholder = "Or type your own answer",
            .placeholder_color = k.faint,
            .width = .fill,
            .bare = true,
            .size = 13,
            .line_height = 20,
        });
    }
    const can = mq.canAdvance(q, wz.picks[wz.page].items.len, typed);
    const foot = ui.div(c).row().wFull().itemsCenter().gap(14);
    defer foot.end();
    {
        ui.key(c, "ios-question-cancel");
        const x = ui.div(c).row().py(6).control();
        defer x.end();
        ui.text(c, "Cancel question", .{ .size = 13, .weight = .medium, .color = k.muted });
        if (x.clicked()) {
            closing.mark(a, wz.request_id);
            act = .dismiss;
        }
    }
    if (wz.page > 0) {
        ui.key(c, "ios-question-back");
        const b = ui.div(c).row().py(6).control();
        defer b.end();
        ui.text(c, "Back", .{ .size = 13, .weight = .medium, .color = k.muted });
        if (b.clicked()) act = .back;
    }
    _ = ui.div(c).grow().end();
    ui.key(c, "ios-question-advance");
    const next = ui.div(c).row().px(16).h(34).center().roundedFull().circular().bg(if (can) k.text else k.text.alpha(0.4)).control();
    defer next.end();
    ui.text(c, mq.advanceLabel(wz.last()), .{ .size = 13, .weight = .medium, .color = k.background });
    if (next.clicked() and can) {
        if (wz.last()) closing.mark(a, wz.request_id);
        act = .advance;
        nanoui.haptics.impact(.light);
    }
}

fn approvalButton(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8, primary: bool) bool {
    ui.key(c, key);
    const b = ui.div(c).row().grow().h(40).px(10).center().roundedFull().circular().bg(if (primary) k.text else k.text.alpha(0.08)).control();
    defer b.end();
    ui.text(c, label, .{ .size = 13.5, .weight = .semibold, .truncate = .ellipsis, .color = if (primary) k.background else k.text });
    return b.clicked();
}

/// The header in capitals, as the Swift panel shows it.
fn upper(c: *ui.Context, s: []const u8) []const u8 {
    for (s) |ch| {
        if (std.ascii.isLower(ch)) break;
    } else return s;
    const out = c.alloc().alloc(u8, s.len) catch return s;
    return std.ascii.upperString(out, s);
}

const counters = blk: {
    @setEvalBranchQuota(200_000);
    var t: [9][9][]const u8 = undefined;
    for (0..9) |p| for (0..9) |n| {
        t[p][n] = std.fmt.comptimePrint("{d}/{d}", .{ p + 1, n + 1 });
    };
    break :blk t;
};

fn counterText(c: *ui.Context, page: usize, count: usize) []const u8 {
    if (page < 9 and count <= 9 and count > 0) return counters[page][count - 1];
    var b: [16]u8 = undefined;
    const s = mq.counter(&b, page, count) orelse return "";
    return c.print("{s}", .{s});
}

const testing = std.testing;

test "the counter table reads as the rule writes it" {
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings(mq.counter(&b, 1, 3).?, counters[1][2]);
    try testing.expectEqualStrings("9/9", counters[8][8]);
}

fn testApp(t: *ui.Tester, a: *App, questions_json: []const u8) !void {
    theme.registerFonts();
    a.* = .init(testing.allocator, testing.io, 1);
    a.offscreen = true;
    a.mobile_preview = true;
    a.new_harness = try testing.allocator.dupe(u8, "graff");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{"ok":true},"AuthStatus":{"$items":[{"state":"signedIn","user":{"id":"u","email":"sam@example.com","name":null}}]}}
    , .{});
    a.engine.state = .connected;
    a.selected = try testing.allocator.dupe(u8, "chat-q");
    const reset = try std.fmt.allocPrint(testing.allocator,
        \\{{"reset":[{{"id":"m1","role":"assistant","parts":[{{"kind":"input","id":"p1","requestId":"req-1","resolved":false,"questions":{s}}}]}}]}}
    , .{questions_json});
    defer testing.allocator.free(reset);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reset, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
    try t.init(testing.allocator, .init(a, @import("view_mobile.zig").view), .{ .width = 402, .height = 874 });
    t.frame();
    t.frame();
}

fn sentWith(a: *const App, needle: []const u8) bool {
    for (a.engine.sent.items) |f| if (std.mem.indexOf(u8, f, needle) != null) return true;
    return false;
}

test "question panel: every question in turn, typed text replaces picks, answered with respondInput" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try testApp(&t, &a,
        \\[{"id":"q1","header":"Targets","question":"Which targets?","options":["Simulator","Device"]},
        \\ {"id":"q2","header":"Notes","question":"Anything else?","options":["No"]}]
    );
    defer a.deinit();
    defer t.deinit();
    try testing.expect(t.hasText("TARGETS"));
    try testing.expect(t.hasText("1/2"));
    try testing.expect(t.hasText("Which targets?"));
    try testing.expect(t.hasText("Or type your own answer"));
    try testing.expect(!t.hasText("Message Harness…"));
    try t.clickText("Device");
    t.advance(0.3);
    t.frame();
    try testing.expect(t.hasText("2/2"));
    try testing.expect(t.hasText("Submit"));
    try t.clickText("Or type your own answer");
    t.frame();
    t.typeText("ship it");
    t.frame();
    try t.clickText("Submit");
    t.frame();
    t.frame();
    try testing.expect(sentWith(&a, "\"kind\":\"respondInput\""));
    try testing.expect(sentWith(&a, "\"labels\":[\"Device\"]"));
    try testing.expect(sentWith(&a, "\"labels\":[\"ship it\"]"));
    try testing.expect(a.wizard == null);
    try testing.expect(a.mobile.question_closed_at_ms != null);
}

test "approval card: Allow answers Yes, Cancel question dismisses" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try testApp(&t, &a,
        \\[{"id":"approve","header":"Approve tool","question":"Claude wants to use Bash on `ls`. Allow it?","options":["Yes","No"]}]
    );
    defer a.deinit();
    defer t.deinit();
    try testing.expect(t.hasText("APPROVE TOOL"));
    try testing.expect(t.hasText("Deny"));
    try t.clickText("Allow");
    t.frame();
    try testing.expect(sentWith(&a, "\"labels\":[\"Yes\"]"));
    try testing.expect(a.wizard == null);
}

test "question panel: Cancel question sends dismissInput" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try testApp(&t, &a,
        \\[{"id":"q1","header":"Pick","question":"Which one?","options":["A","B"],"multiSelect":true}]
    );
    defer a.deinit();
    defer t.deinit();
    try testing.expect(t.hasText("Select one or more options."));
    try t.clickText("Cancel question");
    t.frame();
    try testing.expect(sentWith(&a, "\"kind\":\"dismissInput\""));
}
