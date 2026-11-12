//! macOS Keychain access for Claude Code's credentials, exactly as Rust's
//! `mod keychain` (`crates/engine/src/agent_accounts.rs`) does it: by running
//! `security` (no Security.framework link). The item is the generic password
//! with service `Claude Code-credentials`, account = `$USER`. Reads are
//! two-step (an existence probe that needs no authorization, then `-w` for
//! the secret) so a denial is told apart from "not logged in"; writes are
//! `add-generic-password -U`. Every call is bounded at 15 s: an unanswered
//! consent dialog blocks `security` indefinitely.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const proc = @import("agent_logins_proc.zig");
const util = @import("agent_logins_util.zig");

pub const service = "Claude Code-credentials";

/// The `security` program (Rust: `security` resolved through PATH). Tests
/// point it at a fake script; in test builds it defaults to a path that
/// does not exist, so no test can ever reach the real Keychain.
pub var security_bin: []const u8 = if (builtin.is_test) "/nonexistent/harness-test-security" else "security";

pub var exec_timeout_ms: u64 = 15_000;

pub const Exec = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

fn exec(a: Allocator, io: Io, args: []const []const u8) Exec {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(a, security_bin) catch return .{ .ok = false, .stdout = "", .stderr = "security timed out" };
    argv.appendSlice(a, args) catch return .{ .ok = false, .stdout = "", .stderr = "security timed out" };
    const cap = proc.runCapture(a, io, argv.items, null, exec_timeout_ms) catch
        return .{ .ok = false, .stdout = "", .stderr = "security timed out" };
    if (cap.timed_out) return .{ .ok = false, .stdout = "", .stderr = "security timed out" };
    return .{ .ok = cap.success(), .stdout = cap.stdout, .stderr = cap.stderr };
}

pub const Read = struct {
    credentials: ?json.Value = null,
    warning: ?[]const u8 = null,
};

pub const denied_warning = "A Claude Code login exists, but macOS Keychain denied access to it — approve the prompt (choose \u{201C}Always Allow\u{201D}) and refresh to enable switching.";

/// `read_credentials`.
pub fn readCredentials(a: Allocator, io: Io, user: []const u8) Read {
    if (!exec(a, io, &.{ "find-generic-password", "-s", service }).ok) return .{};
    const r = exec(a, io, &.{ "find-generic-password", "-a", user, "-s", service, "-w" });
    if (!r.ok) return .{ .warning = denied_warning };
    const v = util.parseJson(a, std.mem.trim(u8, r.stdout, &std.ascii.whitespace)) orelse
        return .{ .warning = "The Claude Code Keychain entry could not be parsed." };
    return .{ .credentials = v };
}

/// `has_item`: the item exists (no secret is read).
pub fn hasItem(a: Allocator, io: Io) bool {
    return exec(a, io, &.{ "find-generic-password", "-s", service }).ok;
}

/// `write_credentials`: null on success, else Rust's error text.
pub fn writeCredentials(a: Allocator, io: Io, user: []const u8, text: []const u8) !?[]const u8 {
    const r = exec(a, io, &.{ "add-generic-password", "-U", "-a", user, "-s", service, "-w", text });
    if (r.ok) return null;
    const e = std.mem.trim(u8, r.stderr, &std.ascii.whitespace);
    return try std.fmt.allocPrint(a, "Keychain write failed: {s}", .{if (e.len == 0) "unknown error" else e});
}
