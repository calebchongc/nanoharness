//! `SignOutGraffLogin`, ported from `crates/engine/src/agent_accounts.rs`
//! (`sign_out_graff_login`, `graff_logout`), `crates/engine/src/graff_logins.rs`
//! (`credential_path`, `anthropic_credentials_path`, `sign_out`,
//! `chatgpt_record`, `failure_message`) and
//! `crates/harness/src/acp/graff_login.rs` (`logout_command`).
//!
//! Most of graff's sign-ins are a credential file to remove. ChatGPT signs
//! out through `graff logout chatgpt-new`, which revokes the session and keeps
//! graff's app registration. The reply is the fresh provider list.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const exes = @import("rpcw_executables.zig");
const engine_host = @import("engine_host.zig");

const RpcOutcome = common.RpcOutcome;

/// `GRAFF_LOGIN_PROVIDERS` ids.
pub const providers = [_][]const u8{ "xai", "kimi", "zai", "chatgpt-new", "anthropic", "claude-agent" };

/// `anthropic_credentials_path` (Unix): the `ant` CLI's profile credentials.
fn anthropicCredentialsPath(gpa: Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = if (common.getenvNonEmpty("ANTHROPIC_CONFIG_DIR")) |d|
        try gpa.dupe(u8, d)
    else if (common.getenvNonEmpty("XDG_CONFIG_HOME")) |x|
        try std.fs.path.join(gpa, &.{ x, "anthropic" })
    else
        try std.fs.path.join(gpa, &.{ home, ".config", "anthropic" });
    defer gpa.free(dir);
    var profile_owned: ?[]u8 = null;
    defer if (profile_owned) |p| gpa.free(p);
    const profile: []const u8 = if (common.getenvNonEmpty("ANTHROPIC_PROFILE")) |p| p else blk: {
        const active = try std.fs.path.join(gpa, &.{ dir, "active_config" });
        defer gpa.free(active);
        const text = std.Io.Dir.cwd().readFileAlloc(io, active, gpa, .limited(4096)) catch break :blk "default";
        defer gpa.free(text);
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) break :blk "default";
        profile_owned = try gpa.dupe(u8, t);
        break :blk profile_owned.?;
    };
    const file = try std.fmt.allocPrint(gpa, "{s}.json", .{profile});
    defer gpa.free(file);
    return std.fs.path.join(gpa, &.{ dir, "credentials", file });
}

/// `credential_path`: `None` for an id graff does not sign in to.
pub fn credentialPath(gpa: Allocator, io: std.Io, home: []const u8, provider: []const u8) !?[]u8 {
    for (providers) |p| {
        if (!std.mem.eql(u8, p, provider)) continue;
        if (std.mem.eql(u8, provider, "chatgpt-new")) return try std.fs.path.join(gpa, &.{ home, ".graff", "credentials", "chatgpt-new.json" });
        if (std.mem.eql(u8, provider, "anthropic")) return try anthropicCredentialsPath(gpa, io, home);
        if (std.mem.eql(u8, provider, "claude-agent")) return try std.fs.path.join(gpa, &.{ home, ".graff", "credentials", "claude-agent.json" });
        const dot = try std.fmt.allocPrint(gpa, ".{s}", .{provider});
        defer gpa.free(dot);
        return try std.fs.path.join(gpa, &.{ home, dot, "credentials", "graff-oauth.json" });
    }
    return null;
}

/// `strip_ansi`: drop `ESC [ … <letter>` sequences.
fn stripAnsi(buf: []u8, line: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == 0x1b) {
            i += 1;
            while (i < line.len and !std.ascii.isAlphabetic(line[i])) i += 1;
            continue;
        }
        if (n < buf.len) {
            buf[n] = line[i];
            n += 1;
        }
    }
    return buf[0..n];
}

/// `failure_message`: graff's last `✗ …` line, else its last non-empty line.
pub fn failureMessage(output: []const u8) []const u8 {
    var buf: [1024]u8 = undefined;
    var last_line: ?[]const u8 = null;
    var it = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = stripAnsi(&buf, std.mem.trimEnd(u8, raw, "\r"));
        const lead = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, lead, "✗")) {
            const msg = std.mem.trim(u8, lead["✗".len..], " \t");
            if (msg.len > 0) return common.errText("{s}", .{msg});
        }
    }
    it = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, stripAnsi(&buf, raw), " \t\r");
        if (line.len > 0) {
            last_line = common.errText("{s}", .{line});
            break;
        }
    }
    return last_line orelse "The sign-in did not finish.";
}

/// `chatgpt_record(..).is_none_or(|r| !r.signed_in)`.
fn chatgptSignedOut(gpa: Allocator, io: std.Io, home: []const u8) !bool {
    const path = try std.fs.path.join(gpa, &.{ home, ".graff", "credentials", "chatgpt-new.json" });
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return true;
    defer gpa.free(text);
    var parsed = json.parseFromSlice(json.Value, gpa, text, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    const tok = parsed.value.object.get("access_token") orelse return true;
    return switch (tok) {
        .string => |s| s.len == 0,
        .null => true,
        // Not a string: the record does not parse, so there is none.
        else => true,
    };
}

/// `graff_logout`: `graff logout chatgpt-new` with graff's home, 30 s at most.
fn graffLogout(gpa: Allocator, io: std.Io, home: []const u8, provider: []const u8) !?[]const u8 {
    const program = (try exes.resolveCli(gpa, io, .graff)) orelse return "The `graff` CLI was not found on this device.";
    defer gpa.free(program);
    const home_arg = try std.fmt.allocPrint(gpa, "HOME={s}", .{home});
    defer gpa.free(home_arg);
    var res = common.run(gpa, io, &.{ "/usr/bin/env", "NO_COLOR=1", home_arg, program, "logout", provider }, null, 30_000) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimedOut => return "graff did not finish signing out.",
        else => return common.errText("Could not run graff logout: {s}", .{@errorName(e)}),
    };
    defer res.deinit(gpa);
    const text = try std.mem.concat(gpa, u8, &.{ res.stdout, res.stderr });
    defer gpa.free(text);
    if (res.success() and try chatgptSignedOut(gpa, io, home)) return null;
    return common.errText("Could not sign out of ChatGPT: {s}", .{failureMessage(text)});
}

/// `SignOutGraffLogin { provider }` → the provider list.
pub fn signOutGraffLogin(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct SignOutGraffLoginParams", .{});
    const pv = o.get("provider") orelse return common.badParams("missing field `provider`", .{});
    if (pv != .string) return common.badParams("invalid type: expected a string for `provider`", .{});
    const provider = pv.string;
    const io = host.io orelse return common.failed("Could not sign out of {s}: no I/O", .{provider});
    // graff's home is this device's home (`AgentAccountsConfig::graff_home`).
    const home = host.agent_accounts.home_dir orelse common.homeDir() orelse "/";

    if (std.mem.eql(u8, provider, "chatgpt-new")) {
        if (try graffLogout(gpa, io, home, provider)) |m| return common.failedMsg(m);
    } else {
        const path = (try credentialPath(gpa, io, home, provider)) orelse
            return common.failed("Could not sign out of {s}: graff has no sign-in for {s}", .{ provider, provider });
        defer gpa.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return common.failed("Could not sign out of {s}: {s}", .{ provider, @errorName(e) }),
        };
    }
    return .{ .unary_json = try host.agent_accounts.listGraffLoginsJson(io) };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const fake_graff =
    \\#!/bin/sh
    \\# Synthetic graff logout: clears the record's token, or fails.
    \\[ "$1" = logout ] || exit 9
    \\if [ -f "$HOME/fail" ]; then printf '\033[31m✗ network down\033[0m\nmore\n'; exit 1; fi
    \\printf '{"email":"synthetic@example.invalid","client_id":"c1","access_token":""}' > "$HOME/.graff/credentials/chatgpt-new.json"
    \\echo "✓ signed out"
    \\
;

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    env: common.TestEnv,
    host: engine_host.EngineHost,

    fn init(with_graff: bool) !*Fx {
        const gpa = testing.allocator;
        const io = testing.io;
        const f = try gpa.create(Fx);
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, io, &f.tmp);
        f.env = try common.TestEnv.init(gpa, f.base);
        try f.env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
        const path = try std.fmt.allocPrint(gpa, "{s}/bin:/usr/bin:/bin", .{f.base});
        defer gpa.free(path);
        try f.env.map.put("PATH", path);
        try f.tmp.dir.createDirPath(io, "bin");
        try f.tmp.dir.createDirPath(io, ".graff/credentials");
        if (with_graff) try f.tmp.dir.writeFile(io, .{ .sub_path = "bin/graff", .data = fake_graff, .flags = .{ .permissions = .executable_file } });
        f.env.install();
        exes.system_prefix = f.base;
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = io;
        try f.host.agent_accounts.configureSyntheticHome(f.base);
        return f;
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        f.host.deinit();
        f.env.deinit();
        exes.system_prefix = "";
        gpa.free(f.base);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    fn call(f: *Fx, params_text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        return f.host.handle("SignOutGraffLogin", p.value);
    }

    fn write(f: *Fx, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn exists(f: *Fx, sub: []const u8) bool {
        _ = f.tmp.dir.statFile(testing.io, sub, .{}) catch return false;
        return true;
    }
};

fn signedIn(reply: []const u8, id: []const u8) !bool {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, reply, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |r| {
        if (std.mem.eql(u8, r.object.get("id").?.string, id)) return r.object.get("signedIn").?.bool;
    }
    return error.ProviderMissing;
}

fn expectFailed(outcome: RpcOutcome, bad: bool, expected: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .exec_error => |m| {
                try testing.expect(!bad);
                try testing.expectEqualStrings(expected, m);
            },
            .bad_params => |m| {
                try testing.expect(bad);
                try testing.expectEqualStrings(expected, m);
            },
            else => return error.UnexpectedErrorKind,
        },
        .unary_json => |b| {
            std.debug.print("unexpected success: {s}\n", .{b});
            testing.allocator.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

test "rpcw_graff_logins SignOutGraffLogin removes a provider's credential file" {
    const f = try Fx.init(false);
    defer f.deinit();
    try f.write(".xai/credentials/graff-oauth.json", "{\"token\":\"synthetic\"}");
    try f.write(".kimi/credentials/graff-oauth.json", "{\"token\":\"synthetic\"}");
    try f.write(".config/anthropic/credentials/default.json", "{\"account_email\":\"synthetic@example.invalid\"}");

    const out = try f.call("{\"provider\":\"xai\"}");
    defer testing.allocator.free(out.unary_json);
    try testing.expect(!f.exists(".xai/credentials/graff-oauth.json"));
    try testing.expect(!try signedIn(out.unary_json, "xai"));
    try testing.expect(try signedIn(out.unary_json, "kimi"));

    // Already signed out is success.
    const again = try f.call("{\"provider\":\"xai\"}");
    testing.allocator.free(again.unary_json);

    const ant = try f.call("{\"provider\":\"anthropic\"}");
    testing.allocator.free(ant.unary_json);
    try testing.expect(!f.exists(".config/anthropic/credentials/default.json"));

    try expectFailed(try f.call("{\"provider\":\"openai\"}"), false, "Could not sign out of openai: graff has no sign-in for openai");
    try expectFailed(try f.call("{}"), true, "missing field `provider`");
}

test "rpcw_graff_logins SignOutGraffLogin signs ChatGPT out through graff logout" {
    const f = try Fx.init(true);
    defer f.deinit();
    try f.write(".graff/credentials/chatgpt-new.json", "{\"email\":\"synthetic@example.invalid\",\"client_id\":\"c1\",\"access_token\":\"tok\"}");
    const out = try f.call("{\"provider\":\"chatgpt-new\"}");
    defer testing.allocator.free(out.unary_json);
    try testing.expect(!try signedIn(out.unary_json, "chatgpt-new"));
    // The registration is kept: the record is still there.
    try testing.expect(f.exists(".graff/credentials/chatgpt-new.json"));

    try f.write(".graff/credentials/chatgpt-new.json", "{\"access_token\":\"tok\"}");
    try f.write("fail", "1");
    try expectFailed(try f.call("{\"provider\":\"chatgpt-new\"}"), false, "Could not sign out of ChatGPT: network down");
}

test "rpcw_graff_logins SignOutGraffLogin for ChatGPT needs graff" {
    const f = try Fx.init(false);
    defer f.deinit();
    try expectFailed(try f.call("{\"provider\":\"chatgpt-new\"}"), false, "The `graff` CLI was not found on this device.");
}

test "rpcw_graff_logins failure messages prefer graff's ✗ line" {
    try testing.expectEqualStrings("bad code", failureMessage("start\n\x1b[31m✗ bad code\x1b[0m\ntrailing\n"));
    try testing.expectEqualStrings("trailing", failureMessage("start\ntrailing\n\n"));
    try testing.expectEqualStrings("The sign-in did not finish.", failureMessage("\n \n"));
}
