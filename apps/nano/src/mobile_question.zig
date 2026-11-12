//! What the phone's question panel decides (ComposerView.swift
//! `QuestionPanel`, DuoLaptop.swift `QuickActions.approval`): the page
//! counter, which option shows picked, when Next/Submit can be pressed, and
//! whether a question is a tool approval, answered with Allow, Deny or an
//! agent's "Always" choice. Pure.
const std = @import("std");
const tr = @import("transcript.zig");

/// "2/3", shown only when there is more than one question.
pub fn counter(buf: []u8, page: usize, count: usize) ?[]const u8 {
    if (count <= 1) return null;
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ page + 1, count }) catch null;
}

/// An option row is picked only while nothing is typed (typed text replaces
/// the picks, `optionRow`).
pub fn showsPicked(picked: bool, typed: []const u8) bool {
    return picked and std.mem.trim(u8, typed, " \t\r\n").len == 0;
}

/// `canAdvance`: typed text, or a pick (or a multiline question).
pub fn canAdvance(q: tr.Question, picks: usize, typed: []const u8) bool {
    return q.multiline or picks > 0 or std.mem.trim(u8, typed, " \t\r\n").len > 0;
}

pub fn advanceLabel(last: bool) []const u8 {
    return if (last) "Submit" else "Next";
}

/// The number badge beside an option: the first nine.
pub fn optionBadge(buf: []u8, index: usize) ?[]const u8 {
    if (index >= 9) return null;
    return std.fmt.bufPrint(buf, "{d}", .{index + 1}) catch null;
}

/// A tool approval: the option that allows, the one that denies, and an
/// agent's "Always …" choice when it offers one.
pub const Approval = struct {
    allow: usize,
    deny: usize,
    always: ?usize = null,
};

fn isWord(label: []const u8, words: []const []const u8) bool {
    const t = std.mem.trim(u8, label, " ");
    for (words) |w| if (std.ascii.eqlIgnoreCase(t, w)) return true;
    return false;
}

/// The engine asks for a tool's approval as a single-choice question
/// ("Approve tool", Yes / No; agents may add "Always allow …"). Anything
/// else is an ordinary question for the full panel.
pub fn approval(q: tr.Question) ?Approval {
    if (q.multi_select or q.options.len < 2) return null;
    var allow: ?usize = null;
    var deny: ?usize = null;
    var always: ?usize = null;
    for (q.options, 0..) |o, i| {
        if (isWord(o, &.{ "yes", "allow", "allow once", "approve" })) {
            if (allow == null) allow = i;
        } else if (isWord(o, &.{ "no", "deny", "reject", "reject once", "decline" })) {
            if (deny == null) deny = i;
        } else if (std.ascii.startsWithIgnoreCase(std.mem.trim(u8, o, " "), "always")) {
            if (always == null) always = i;
        } else return null;
    }
    const header_says = std.ascii.eqlIgnoreCase(q.header, "Approve tool");
    if (allow == null or deny == null) return null;
    if (!header_says and always == null and q.options.len != 2) return null;
    return .{ .allow = allow.?, .deny = deny.?, .always = always };
}

/// `QuickActions.approval`: every question single-choice with options, so
/// Approve can answer each with its first.
pub fn quickApprovable(questions: []const tr.Question) bool {
    if (questions.len == 0) return false;
    for (questions) |q| if (q.multi_select or q.options.len == 0) return false;
    return true;
}

const testing = std.testing;

test "the panel's counter, picks and Next/Submit as the Swift QuestionPanel" {
    var b: [8]u8 = undefined;
    try testing.expect(counter(&b, 0, 1) == null);
    try testing.expectEqualStrings("2/3", counter(&b, 1, 3).?);
    try testing.expect(showsPicked(true, ""));
    try testing.expect(!showsPicked(true, " typed "));
    const q: tr.Question = .{ .id = "q", .header = "H", .question = "?", .options = &.{ "A", "B" } };
    try testing.expect(!canAdvance(q, 0, "  "));
    try testing.expect(canAdvance(q, 1, ""));
    try testing.expect(canAdvance(q, 0, "mine"));
    try testing.expectEqualStrings("Submit", advanceLabel(true));
    try testing.expectEqualStrings("Next", advanceLabel(false));
    try testing.expectEqualStrings("9", optionBadge(&b, 8).?);
    try testing.expect(optionBadge(&b, 9) == null);
}

test "approvals: the engine's Yes/No, an agent's Always choice, and ordinary questions" {
    const yes_no: tr.Question = .{ .id = "approve", .header = "Approve tool", .question = "Claude wants to use Bash on `ls`. Allow it?", .options = &.{ "Yes", "No" } };
    const ap = approval(yes_no).?;
    try testing.expectEqual(@as(usize, 0), ap.allow);
    try testing.expectEqual(@as(usize, 1), ap.deny);
    try testing.expect(ap.always == null);

    const with_always: tr.Question = .{ .id = "p", .header = "Permission", .question = "Run `make`?", .options = &.{ "Allow", "Always allow make", "Deny" } };
    const aw = approval(with_always).?;
    try testing.expectEqual(@as(usize, 1), aw.always.?);
    try testing.expectEqual(@as(usize, 2), aw.deny);

    const choice: tr.Question = .{ .id = "t", .header = "Targets", .question = "Which?", .options = &.{ "Simulator", "Device" } };
    try testing.expect(approval(choice) == null);
    const multi: tr.Question = .{ .id = "m", .header = "Approve tool", .question = "?", .options = &.{ "Yes", "No" }, .multi_select = true };
    try testing.expect(approval(multi) == null);

    try testing.expect(quickApprovable(&.{ yes_no, choice }));
    try testing.expect(!quickApprovable(&.{multi}));
    try testing.expect(!quickApprovable(&.{}));
}
