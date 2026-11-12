//! The phone's Settings rules and copy (SettingsView.swift and the pages it
//! opens: NotificationsView, AutonomyView, CompactionView, UsageView):
//! which computers a per-computer setting can be read from, the compaction
//! choices and their labels, the notification kinds and their footer, how
//! money reads, and what a failed read says. Pure.
const std = @import("std");
const mp = @import("mobile_parity.zig");

/// The desktop's three kinds (`PushNotifications.Kind`), each stored as a
/// preference: the push registration that would send them is not this
/// app's yet.
pub const NotifyKind = enum {
    done,
    input,
    failed,

    pub fn title(k: NotifyKind) []const u8 {
        return switch (k) {
            .done => "Run finished",
            .input => "Waiting on your input",
            .failed => "Run failed",
        };
    }

    /// The settings key the choice is kept under (on unless turned off).
    pub fn key(k: NotifyKind) []const u8 {
        return switch (k) {
            .done => "mobileNotifyRunFinished",
            .input => "mobileNotifyWaitingOnInput",
            .failed => "mobileNotifyRunFailed",
        };
    }
};

/// NotificationsView's footer.
pub fn notificationsFooter(demo: bool, denied: bool) []const u8 {
    if (demo) return "Demo mode sends no notifications.";
    if (denied) return "Notifications are turned off for Harness in iOS Settings.";
    return "A run finished, a session waiting on you, or a run failed, from any of your computers. Quiet while Harness is open.";
}

pub const attach_sound_footer = "A short sound when an image lands in the message box, like Harness on your computer.";

/// CompactionView's choices; null is graff's default.
pub const compact_choices = [_]?u8{ null, 50, 60, 70, 75, 85, 90 };

pub fn compactLabel(buf: []u8, pct: ?u8) []const u8 {
    const p = pct orelse return "Default (80%)";
    return std.fmt.bufPrint(buf, "{d}%", .{p}) catch "?";
}

pub const compact_footer = "Graff compacts a conversation once it fills this much of the model's context window. Lower keeps each request smaller and cheaper; higher keeps more of the conversation word for word. Applies to Graff chats started after the change. To change one chat, type /compact-at 70 in it.";
pub const autonomy_footer = "Applies to every agent on this computer, starting with each session's next message. Read only and Workspace ask you on this phone before anything outside what they allow. Full access is how Harness has always run.";
pub const keep_awake_footer = "The computer won't go to sleep while any chat is working, and can sleep again once they're all done. The display can still turn off, and closing a laptop's lid still puts it to sleep.";

/// `formatMicroUSD`: six decimals under a cent, four under a dollar, else two.
pub fn formatMicroUsd(buf: []u8, amount: i64) []const u8 {
    const dollars = @as(f64, @floatFromInt(amount)) / 1_000_000.0;
    const mag = @abs(dollars);
    return (if (mag < 0.01)
        std.fmt.bufPrint(buf, "${d:.6}", .{dollars})
    else if (mag < 1)
        std.fmt.bufPrint(buf, "${d:.4}", .{dollars})
    else
        std.fmt.bufPrint(buf, "${d:.2}", .{dollars})) catch "$?";
}

/// What a failed per-computer read says (`loadState`).
pub fn failedCopy(buf: []u8, computer: []const u8, err: []const u8) []const u8 {
    if (std.mem.indexOf(u8, err, "unknown method") != null)
        return std.fmt.bufPrint(buf, "Update Harness on {s} to change this from your phone.", .{computer}) catch err;
    return std.fmt.bufPrint(buf, "Couldn't reach {s}: {s}", .{ computer, err }) catch err;
}

/// A computer that can run agents (`canHostSessions`): not a phone.
pub fn canHost(platform: []const u8) bool {
    const phones = [_][]const u8{ "ios", "android", "ipados" };
    for (phones) |p| if (std.ascii.eqlIgnoreCase(platform, p)) return false;
    return true;
}

/// `own`: this phone's own row, never a host.
pub const Host = struct { platform: []const u8, last_seen_ms: i64, own: bool = false };

/// Hosts first online, then the rest, each group in its own order
/// (`hosts`). Writes indexes into `out`; returns how many.
pub fn hostOrder(out: []usize, devices: []const Host, now_ms: i64) usize {
    var n: usize = 0;
    for ([_]bool{ true, false }) |want_online| {
        for (devices, 0..) |d, i| {
            if (d.own or !canHost(d.platform)) continue;
            const seen: ?i64 = if (d.last_seen_ms > 0) d.last_seen_ms else null;
            const online = mp.presenceStatus(now_ms, seen, true, null, seen) == .online;
            if (online != want_online or n >= out.len) continue;
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

/// "0.2.190 (190)" for About's Version row; the build is the version's last part.
pub fn versionLine(buf: []u8, version: []const u8) []const u8 {
    const build = if (std.mem.lastIndexOfScalar(u8, version, '.')) |i| version[i + 1 ..] else version;
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ version, build }) catch version;
}

/// Split view's choices as the Swift picker names them (`PhoneSplit.label`).
pub const split_labels = [_][]const u8{ "Auto", "Side by side", "Off" };

pub const privacy_url = "https://codegraff.com/privacy#harness";
pub const support_url = "https://codegraff.com/support";
pub const support_email_url = "mailto:rach@codegraff.com";

const testing = std.testing;

test "settings copy and choices as the Swift pages have them" {
    var b: [128]u8 = undefined;
    try testing.expectEqualStrings("Default (80%)", compactLabel(&b, null));
    try testing.expectEqualStrings("75%", compactLabel(&b, 75));
    try testing.expectEqual(@as(usize, 7), compact_choices.len);
    try testing.expectEqualStrings("Demo mode sends no notifications.", notificationsFooter(true, false));
    try testing.expectEqualStrings("Notifications are turned off for Harness in iOS Settings.", notificationsFooter(false, true));
    try testing.expectEqualStrings("Waiting on your input", NotifyKind.input.title());
    try testing.expectEqualStrings("$12.50", formatMicroUsd(&b, 12_500_000));
    try testing.expectEqualStrings("$0.2500", formatMicroUsd(&b, 250_000));
    try testing.expectEqualStrings("$0.000500", formatMicroUsd(&b, 500));
    try testing.expectEqualStrings("Update Harness on Build Box to change this from your phone.", failedCopy(&b, "Build Box", "unknown method: GetAutonomy"));
    try testing.expectEqualStrings("Couldn't reach Build Box: timed out", failedCopy(&b, "Build Box", "timed out"));
    try testing.expectEqualStrings("0.2.190 (190)", versionLine(&b, "0.2.190"));
}

test "per-computer settings read from computers, online ones first" {
    const now: i64 = 10_000_000;
    const devs = [_]Host{
        .{ .platform = "macos", .last_seen_ms = now - 3_600_000 },
        .{ .platform = "ios", .last_seen_ms = now },
        .{ .platform = "linux", .last_seen_ms = now - 1_000 },
        .{ .platform = "", .last_seen_ms = now, .own = true },
    };
    var out: [4]usize = undefined;
    const n = hostOrder(&out, &devs, now);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 2), out[0]);
    try testing.expectEqual(@as(usize, 0), out[1]);
}
