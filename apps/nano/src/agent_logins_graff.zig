//! graff's own provider sign-ins as the login registry drives them: a port
//! of `crates/engine/src/graff_logins.rs` (everything but `list`/`sign_out`,
//! which `agent_accounts_host.zig` already serves for `ListGraffLogins`).
//!
//! graff keeps each sign-in as one file under the home it runs with; `graff
//! login` exits 0 even when it refuses, so a sign-in counts only when that
//! file changed, or graff printed its `✓` line.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const util = @import("agent_logins_util.zig");

/// `GRAFF_LOGIN_PROVIDERS` ids.
pub const providers = [_][]const u8{ "xai", "kimi", "zai", "chatgpt-new", "anthropic", "claude-agent" };

/// The scope a ChatGPT sign-in needs before requests can run on the plan.
pub const chatgpt_plan_scope = "chatgpt.tokens.use.direct";
/// `CHATGPT_PLAN_CONFIRMATION`.
pub const chatgpt_plan_confirmation = "You're using your ChatGPT plan";
/// `CHATGPT_PLAN_OFF`.
pub const chatgpt_plan_off = "Signed in to ChatGPT, but plan usage is off. Continue with ChatGPT again and allow plan usage, or use an API key.";

pub fn isProvider(id: []const u8) bool {
    for (providers) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

/// `credential_path`: null for an id graff does not sign into itself.
pub fn credentialPath(a: Allocator, io: Io, home: []const u8, provider: []const u8, env: *const Environ.Map) !?[]u8 {
    if (!isProvider(provider)) return null;
    if (std.mem.eql(u8, provider, "chatgpt-new")) return try std.fs.path.join(a, &.{ home, ".graff", "credentials", "chatgpt-new.json" });
    if (std.mem.eql(u8, provider, "anthropic")) return try anthropicCredentialsPath(a, io, home, env);
    if (std.mem.eql(u8, provider, "claude-agent")) return try std.fs.path.join(a, &.{ home, ".graff", "credentials", "claude-agent.json" });
    const dot = try std.fmt.allocPrint(a, ".{s}", .{provider});
    return try std.fs.path.join(a, &.{ home, dot, "credentials", "graff-oauth.json" });
}

/// `anthropic_credentials_path`.
pub fn anthropicCredentialsPath(a: Allocator, io: Io, home: []const u8, env: *const Environ.Map) ![]u8 {
    const set = struct {
        fn f(e: *const Environ.Map, name: []const u8) ?[]const u8 {
            const v = e.get(name) orelse return null;
            return if (v.len > 0) v else null;
        }
    }.f;
    const dir: []const u8 = if (set(env, "ANTHROPIC_CONFIG_DIR")) |d|
        d
    else if (builtin.os.tag == .windows)
        try std.fs.path.join(a, &.{ set(env, "APPDATA") orelse home, "Anthropic" })
    else if (set(env, "XDG_CONFIG_HOME")) |x|
        try std.fs.path.join(a, &.{ x, "anthropic" })
    else
        try std.fs.path.join(a, &.{ home, ".config", "anthropic" });
    var profile: []const u8 = "default";
    if (set(env, "ANTHROPIC_PROFILE")) |p| {
        profile = p;
    } else {
        const active = try std.fs.path.join(a, &.{ dir, "active_config" });
        if (Io.Dir.cwd().readFileAlloc(io, active, a, .limited(64 * 1024))) |text| {
            const t = std.mem.trim(u8, text, &std.ascii.whitespace);
            if (t.len > 0) profile = t;
        } else |_| {}
    }
    const file = try std.fmt.allocPrint(a, "{s}.json", .{profile});
    return std.fs.path.join(a, &.{ dir, "credentials", file });
}

/// `ChatgptRecord`: what graff's ChatGPT record says (no token values).
pub const ChatgptRecord = struct {
    account: ?[]const u8 = null,
    registered: bool = false,
    signed_in: bool = false,
    plan_usage: bool = false,
};

/// `parse_chatgpt_record` (serde's field types are enforced: a wrong type is no record).
pub fn parseChatgptRecord(a: Allocator, bytes: []const u8) ?ChatgptRecord {
    const v = util.parseJson(a, bytes) orelse return null;
    if (v != .object) return null;
    const o = v.object;
    var email: []const u8 = "";
    var client_id: []const u8 = "";
    if (o.get("email")) |e| {
        if (e != .string) return null;
        email = e.string;
    }
    if (o.get("client_id")) |c| {
        if (c != .string) return null;
        client_id = c.string;
    }
    var signed_in = false;
    if (o.get("access_token")) |t| switch (t) {
        .null => {},
        .string => |s| signed_in = s.len > 0,
        else => return null,
    };
    var plan = false;
    if (o.get("scopes")) |s| {
        if (s != .array) return null;
        for (s.array.items) |x| {
            if (x != .string) return null;
            if (std.mem.eql(u8, x.string, chatgpt_plan_scope)) plan = true;
        }
    }
    return .{
        .account = if (email.len > 0) email else null,
        .registered = client_id.len > 0,
        .signed_in = signed_in,
        .plan_usage = signed_in and plan,
    };
}

/// `chatgpt_record`: graff's ChatGPT record under `home`, if readable.
pub fn chatgptRecord(a: Allocator, io: Io, home: []const u8, env: *const Environ.Map) ?ChatgptRecord {
    const path = (credentialPath(a, io, home, "chatgpt-new", env) catch return null) orelse return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)) catch return null;
    return parseChatgptRecord(a, bytes);
}

/// `credential_stamp`: the credential file's modified time (ns), if any.
pub fn credentialStamp(a: Allocator, io: Io, home: []const u8, provider: []const u8, env: *const Environ.Map) ?i96 {
    const path = (credentialPath(a, io, home, provider, env) catch return null) orelse return null;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.mtime.nanoseconds;
}

const noop_script = "#!/bin/sh\nexit 0\n";

/// Write `noop_script` at `path` (0755) unless it is already there.
pub fn ensureNoopScript(a: Allocator, io: Io, path: []const u8) bool {
    if (Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024))) |cur| {
        if (std.mem.eql(u8, cur, noop_script)) return true;
    } else |_| {}
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = noop_script }) catch return false;
    if (comptime @hasDecl(Io.File.Permissions, "fromMode")) {
        Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o755), .{}) catch return false;
    }
    return true;
}

/// `no_open_dir`: `{root}/.noop-open` holding no-op `open` and `xdg-open`
/// (Unix only; null elsewhere). Idempotent.
pub fn noOpenDir(a: Allocator, io: Io, root: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows) return null;
    const dir = std.fs.path.join(a, &.{ root, ".noop-open" }) catch return null;
    Io.Dir.cwd().createDirPath(io, dir) catch return null;
    for ([_][]const u8{ "open", "xdg-open" }) |name| {
        const p = std.fs.path.join(a, &.{ dir, name }) catch return null;
        if (!ensureNoopScript(a, io, p)) return null;
    }
    return dir;
}

// ── output scanning ────────────────────────────────────────────────────────

/// `strip_ansi` (graff's): ESC, then everything through the next ASCII letter.
pub fn stripAnsi(a: Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            i += 1;
            while (i < line.len) {
                const c = line[i];
                i += 1;
                if (std.ascii.isAlphabetic(c)) break;
            }
        } else {
            try out.append(a, line[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

const LineIter = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    fn next(self: *LineIter) ?[]const u8 {
        const l = self.it.next() orelse return null;
        return std.mem.trimEnd(u8, l, "\r");
    }
};

/// Rust `str::lines`: split on `\n`, drop a trailing empty piece and `\r`.
fn lines(output: []const u8) LineIter {
    const body = if (std.mem.endsWith(u8, output, "\n")) output[0 .. output.len - 1] else output;
    return .{ .it = std.mem.splitScalar(u8, body, '\n') };
}

fn isWs(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

const ws = " \t\r\n\x0b\x0c";

/// `scan_login_url`: the page after "open this URL" / "Open this URL" /
/// "visit:", only once its line is complete.
pub fn scanLoginUrl(output: []const u8) ?[]const u8 {
    var at: ?usize = null;
    for ([_][]const u8{ "open this URL", "Open this URL", "visit:" }) |m| {
        if (std.mem.indexOf(u8, output, m)) |i| at = if (at) |cur| @min(cur, i) else i;
    }
    const after = output[at orelse return null ..];
    const rest = after[std.mem.indexOf(u8, after, "https://") orelse return null ..];
    var end: usize = 0;
    while (end < rest.len and !isWs(rest[end])) end += 1;
    if (end == rest.len) return null;
    return rest[0..end];
}

/// `scan_device_code`: the code after "confirm the code:", once its line ends.
pub fn scanDeviceCode(output: []const u8) ?[]const u8 {
    const marker = "confirm the code:";
    const i = std.mem.indexOf(u8, output, marker) orelse return null;
    const rest = output[i + marker.len ..];
    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
    const code = std.mem.trim(u8, rest[0..nl], ws);
    return if (code.len > 0) code else null;
}

/// `scan_failure`: graff's last `✗` line.
pub fn scanFailure(a: Allocator, output: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var it = lines(output);
    while (it.next()) |raw| {
        const line = try stripAnsi(a, raw);
        const t = std.mem.trimStart(u8, line, ws);
        if (!std.mem.startsWith(u8, t, "✗")) continue;
        const msg = std.mem.trim(u8, t["✗".len..], ws);
        if (msg.len > 0) found = msg;
    }
    return found;
}

/// `claude_code_signed_out`.
pub fn claudeCodeSignedOut(a: Allocator, output: []const u8) !bool {
    const m = (try scanFailure(a, output)) orelse return false;
    return std.mem.startsWith(u8, m, "Claude Code is not signed in");
}

/// `saw_success`: any line (ANSI stripped) starting with `✓`.
pub fn sawSuccess(a: Allocator, output: []const u8) !bool {
    var it = lines(output);
    while (it.next()) |raw| {
        const line = try stripAnsi(a, raw);
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, ws), "✓")) return true;
    }
    return false;
}

fn chatgptLine(a: Allocator, output: []const u8, needle: []const u8) !bool {
    var it = lines(output);
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, try stripAnsi(a, raw), ws);
        if (std.mem.startsWith(u8, line, "✓ signed in to ChatGPT as ") and std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

/// `chatgpt_plan_granted`.
pub fn chatgptPlanGranted(a: Allocator, output: []const u8) !bool {
    return chatgptLine(a, output, "; plan usage is on.");
}

/// `chatgpt_plan_denied`.
pub fn chatgptPlanDenied(a: Allocator, output: []const u8) !bool {
    return chatgptLine(a, output, "but plan usage was not allowed");
}

/// `failure_message`: the `✗` line, else the last non-empty line, else a sentence.
pub fn failureMessage(a: Allocator, output: []const u8) ![]const u8 {
    if (try scanFailure(a, output)) |m| return m;
    var last: ?[]const u8 = null;
    var it = lines(output);
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, try stripAnsi(a, raw), ws);
        if (t.len > 0) last = t;
    }
    return last orelse "The sign-in did not finish.";
}

// ── the relayed ChatGPT sign-in ────────────────────────────────────────────

/// A parsed absolute URL (the parts `reqwest::Url` comparisons use).
pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    /// Explicit, non-default port (WHATWG `port()`).
    port: ?u16,
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,

    pub fn portOrDefault(u: Url) ?u16 {
        if (u.port) |p| return p;
        if (std.mem.eql(u8, u.scheme, "http")) return 80;
        if (std.mem.eql(u8, u.scheme, "https")) return 443;
        return null;
    }

    /// `scheme://host[:port]path` (no query or fragment).
    pub fn base(u: Url, a: Allocator) ![]u8 {
        if (u.port) |p| return std.fmt.allocPrint(a, "{s}://{s}:{d}{s}", .{ u.scheme, u.host, p, u.path });
        return std.fmt.allocPrint(a, "{s}://{s}{s}", .{ u.scheme, u.host, u.path });
    }

    pub fn parse(a: Allocator, text: []const u8) ?Url {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const scheme = std.ascii.allocLowerString(a, text[0..colon]) catch return null;
        if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return null;
        for (scheme) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
        var rest = text[colon + 1 ..];
        if (!std.mem.startsWith(u8, rest, "//")) return null;
        rest = rest[2..];
        var frag: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '#')) |h| {
            frag = rest[h + 1 ..];
            rest = rest[0..h];
        }
        var query: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
            query = rest[q + 1 ..];
            rest = rest[0..q];
        }
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        var authority = rest[0..slash];
        const path = if (slash < rest.len) rest[slash..] else "/";
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        var host = authority;
        var port: ?u16 = null;
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| if (std.mem.indexOfScalar(u8, authority[c..], ']') == null) {
            host = authority[0..c];
            const p = authority[c + 1 ..];
            if (p.len > 0) port = std.fmt.parseInt(u16, p, 10) catch return null;
        };
        if (host.len == 0) return null;
        for (host) |c| if (c <= ' ' or c == '<' or c == '>' or c == '\\' or c == '^' or c == '|' or c == '%') return null;
        const lower_host = std.ascii.allocLowerString(a, host) catch return null;
        var u: Url = .{ .scheme = scheme, .host = lower_host, .port = port, .path = path, .query = query, .fragment = frag };
        if (u.port != null and u.portOrDefault() != null) {
            const d: u16 = if (std.mem.eql(u8, scheme, "http")) 80 else if (std.mem.eql(u8, scheme, "https")) 443 else 0;
            if (u.port.? == d) u.port = null;
        }
        return u;
    }
};

pub const Pair = struct { key: []const u8, value: []const u8 };

/// `query_pairs`: application/x-www-form-urlencoded decoding.
pub fn queryPairs(a: Allocator, query: ?[]const u8) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    const q = query orelse return out.toOwnedSlice(a);
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=');
        const k = if (eq) |e| part[0..e] else part;
        const v = if (eq) |e| part[e + 1 ..] else "";
        try out.append(a, .{ .key = try formDecode(a, k), .value = try formDecode(a, v) });
    }
    return out.toOwnedSlice(a);
}

fn formDecode(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            try out.append(a, ' ');
        } else if (c == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
            try out.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable);
            i += 2;
        } else {
            try out.append(a, c);
        }
    }
    return out.toOwnedSlice(a);
}

fn formEncode(out: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '*' or c == '-' or c == '.' or c == '_') {
            try out.append(a, c);
        } else if (c == ' ') {
            try out.append(a, '+');
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
}

/// `ChatgptRelay`: OpenAI's authorize page plus the loopback redirect and
/// `state` a completed sign-in must come back with.
pub const ChatgptRelay = struct {
    url: []const u8,
    redirect: Url,
    state: []const u8,

    pub fn clone(r: ChatgptRelay, a: Allocator) !ChatgptRelay {
        return .{
            .url = try a.dupe(u8, r.url),
            .redirect = .{
                .scheme = try a.dupe(u8, r.redirect.scheme),
                .host = try a.dupe(u8, r.redirect.host),
                .port = r.redirect.port,
                .path = try a.dupe(u8, r.redirect.path),
                .query = null,
                .fragment = null,
            },
            .state = try a.dupe(u8, r.state),
        };
    }

    pub fn free(r: ChatgptRelay, a: Allocator) void {
        a.free(r.url);
        a.free(r.redirect.scheme);
        a.free(r.redirect.host);
        a.free(r.redirect.path);
        a.free(r.state);
    }
};

/// `scan_chatgpt_relay`: only OpenAI's page with a `127.0.0.1` redirect,
/// once graff says it is waiting.
pub fn scanChatgptRelay(a: Allocator, output: []const u8) !?ChatgptRelay {
    if (std.mem.indexOf(u8, output, "waiting for the sign-in on ") == null) return null;
    const start = std.mem.indexOf(u8, output, "https://auth.openai.com/") orelse return null;
    const rest = output[start..];
    var end: usize = 0;
    while (end < rest.len and !isWs(rest[end])) end += 1;
    if (end == rest.len) return null;
    const url = rest[0..end];
    const parsed = Url.parse(a, url) orelse return null;
    if (!std.mem.eql(u8, parsed.scheme, "https") or !std.mem.eql(u8, parsed.host, "auth.openai.com")) return null;
    const pairs = try queryPairs(a, parsed.query);
    var redirect_raw: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    for (pairs) |p| {
        if (redirect_raw == null and std.mem.eql(u8, p.key, "redirect_uri")) redirect_raw = p.value;
        if (state == null and std.mem.eql(u8, p.key, "state")) state = p.value;
    }
    const redirect = Url.parse(a, redirect_raw orelse return null) orelse return null;
    const st = state orelse return null;
    if (st.len == 0) return null;
    const loopback = std.mem.eql(u8, redirect.scheme, "http") and std.mem.eql(u8, redirect.host, "127.0.0.1") and
        redirect.port != null and redirect.query == null and redirect.fragment == null;
    if (!loopback) return null;
    return .{ .url = url, .redirect = redirect, .state = st };
}

pub const not_it = "That isn't the address ChatGPT sent you to. Sign in again.";
pub const older_attempt = "That sign-in belongs to an older attempt. Sign in again.";

pub const Callback = union(enum) { ok: []u8, err: []const u8 };

/// `relayed_callback`: the redirect to deliver, built from the expected
/// redirect (never the caller's host, port or path).
pub fn relayedCallback(a: Allocator, relay: ChatgptRelay, landed: []const u8) !Callback {
    const l = Url.parse(a, std.mem.trim(u8, landed, ws)) orelse return .{ .err = not_it };
    const same = std.mem.eql(u8, l.scheme, relay.redirect.scheme) and std.mem.eql(u8, l.host, relay.redirect.host) and
        l.portOrDefault() == relay.redirect.portOrDefault() and std.mem.eql(u8, l.path, relay.redirect.path);
    if (!same) return .{ .err = not_it };
    const pairs = try queryPairs(a, l.query);
    var states: usize = 0;
    var state_ok = true;
    var has_outcome = false;
    for (pairs) |p| {
        if (std.mem.eql(u8, p.key, "state")) {
            states += 1;
            if (!std.mem.eql(u8, p.value, relay.state)) state_ok = false;
        }
        if (std.mem.eql(u8, p.key, "code") or std.mem.eql(u8, p.key, "error")) has_outcome = true;
    }
    if (states != 1 or !state_ok) return .{ .err = older_attempt };
    if (!has_outcome) return .{ .err = not_it };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try relay.redirect.base(a));
    try out.append(a, '?');
    for (pairs, 0..) |p, i| {
        if (i > 0) try out.append(a, '&');
        try formEncode(&out, a, p.key);
        try out.append(a, '=');
        try formEncode(&out, a, p.value);
    }
    return .{ .ok = try out.toOwnedSlice(a) };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const xai_out = "\nTo log in to Grok (xAI), open this URL (browser should open automatically):\n\n  https://accounts.x.ai/device?user_code=ABCD-1234\n\nand confirm the code:  ABCD-1234\n\nwaiting for authorization…\n";
const zai_out = "\nTo log in to Z.AI Coding Plan, open this URL (browser should open automatically):\n\n  https://chat.z.ai/cli/authorize?flow=f1\n\nwaiting for authorization…\n";
pub const chatgpt_out = "\nSign in with ChatGPT (your browser should open it):\n\nhttps://auth.openai.com/api/accounts/authorize?client_id=dynamic_agent_client&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&scope=openid%20profile&state=st4te&nonce=n&code_challenge=c&code_challenge_method=S256\n\nwaiting for the sign-in on http://127.0.0.1:1455/auth/callback …\n";

test "agent_logins_graff: links, codes, failures and success markers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://accounts.x.ai/device?user_code=ABCD-1234", scanLoginUrl(xai_out).?);
    try testing.expectEqualStrings("ABCD-1234", scanDeviceCode(xai_out).?);
    try testing.expectEqualStrings("https://chat.z.ai/cli/authorize?flow=f1", scanLoginUrl(zai_out).?);
    try testing.expect(scanDeviceCode(zai_out) == null);
    try testing.expectEqualStrings("https://platform.example/oauth?x=1", scanLoginUrl("If it doesn't open, visit:\n\n  https://platform.example/oauth?x=1\n").?);
    try testing.expect(scanLoginUrl("\nTo log in, open this URL (…):\n\n  https://accounts.x.a") == null);
    try testing.expect(scanDeviceCode("\nand confirm the code:  ABC") == null);
    try testing.expect(scanLoginUrl("see https://example.com/docs\nnothing else\n") == null);
    try testing.expectEqualStrings("nope", (try scanFailure(a, "\x1b[31m✗\x1b[0m nope\n")).?);
    try testing.expect((try scanFailure(a, xai_out)) == null);
    try testing.expect(try sawSuccess(a, "\x1b[32m✓\x1b[0m logged into Z.AI — wrote …\n"));
    try testing.expect(!try sawSuccess(a, xai_out));
    try testing.expectEqualStrings("nope", try failureMessage(a, "✗ nope\n"));
    try testing.expectEqualStrings("last words", try failureMessage(a, "boom\nlast words\n\n"));
    try testing.expectEqualStrings("The sign-in did not finish.", try failureMessage(a, ""));
    try testing.expect(try claudeCodeSignedOut(a, "✗ Claude Code is not signed in. Run claude.\n"));
    try testing.expect(try chatgptPlanGranted(a, "✓ signed in to ChatGPT as fixture; plan usage is on.\n"));
    try testing.expect(!try chatgptPlanGranted(a, "✓ signed in to ChatGPT as fixture\n"));
    try testing.expect(try chatgptPlanDenied(a, "✓ signed in to ChatGPT as a@b.c, but plan usage was not allowed. Again.\n"));
}

test "agent_logins_graff: chatgpt record and credential paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const granted = parseChatgptRecord(a, "{\"email\":\"a@b.c\",\"client_id\":\"oaiapp_1\",\"access_token\":\"t\",\"scopes\":[\"chatgpt.tokens.use.direct\",\"email\"]}").?;
    try testing.expect(granted.registered and granted.signed_in and granted.plan_usage);
    try testing.expectEqualStrings("a@b.c", granted.account.?);
    const out = parseChatgptRecord(a, "{\"email\":\"a@b.c\",\"client_id\":\"oaiapp_1\",\"access_token\":\"\",\"scopes\":[]}").?;
    try testing.expect(out.registered and !out.signed_in and !out.plan_usage);
    try testing.expect(!parseChatgptRecord(a, "{\"access_token\":\"\",\"scopes\":[\"chatgpt.tokens.use.direct\"]}").?.plan_usage);
    try testing.expect(parseChatgptRecord(a, "not json") == null);
    var env = Environ.Map.init(a);
    try testing.expectEqualStrings("/h/.xai/credentials/graff-oauth.json", (try credentialPath(a, testing.io, "/h", "xai", &env)).?);
    try testing.expectEqualStrings("/h/.graff/credentials/chatgpt-new.json", (try credentialPath(a, testing.io, "/h", "chatgpt-new", &env)).?);
    try testing.expectEqualStrings("/h/.config/anthropic/credentials/default.json", (try credentialPath(a, testing.io, "/h", "anthropic", &env)).?);
    try env.put("ANTHROPIC_CONFIG_DIR", "/cfg");
    try env.put("ANTHROPIC_PROFILE", "ci");
    try testing.expectEqualStrings("/cfg/credentials/ci.json", (try credentialPath(a, testing.io, "/h", "anthropic", &env)).?);
    for ([_][]const u8{ "", "codex", "codegraff", "../xai", "xai/../../etc" }) |bad| {
        try testing.expect((try credentialPath(a, testing.io, "/h", bad, &env)) == null);
    }
}

test "agent_logins_graff: relay reads the page once graff listens and only reaches its loopback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const relay = (try scanChatgptRelay(a, chatgpt_out)).?;
    try testing.expect(std.mem.startsWith(u8, relay.url, "https://auth.openai.com/api/accounts/authorize?"));
    try testing.expectEqualStrings("http://127.0.0.1:1455/auth/callback", try relay.redirect.base(a));
    try testing.expectEqualStrings("st4te", relay.state);
    const printed = chatgpt_out[0..std.mem.indexOf(u8, chatgpt_out, "waiting").?];
    try testing.expect((try scanChatgptRelay(a, printed)) == null);
    const bads = [_][2][]const u8{
        .{ "auth.openai.com/api", "auth.openai.com.evil.test/api" },
        .{ "https://auth.openai.com", "http://auth.openai.com" },
        .{ "127.0.0.1%3A1455", "evil.test%3A1455" },
        .{ "127.0.0.1%3A1455", "127.0.0.1" },
        .{ "state=st4te&", "" },
    };
    for (bads) |b| {
        const bad = try std.mem.replaceOwned(u8, a, chatgpt_out, b[0], b[1]);
        try testing.expect((try scanChatgptRelay(a, bad)) == null);
    }
    const ok = try relayedCallback(a, relay, " http://127.0.0.1:1455/auth/callback?code=abc&state=st4te&client_id=issued \n");
    try testing.expectEqualStrings("http://127.0.0.1:1455/auth/callback?code=abc&state=st4te&client_id=issued", ok.ok);
    try testing.expect((try relayedCallback(a, relay, "http://127.0.0.1:1455/auth/callback?error=access_denied&state=st4te")) == .ok);
    const rejects = [_][]const u8{
        "http://127.0.0.1:1455/auth/callback?code=abc&state=other",
        "http://127.0.0.1:1455/auth/callback?code=abc",
        "http://127.0.0.1:1455/auth/callback?code=abc&state=st4te&state=x",
        "http://127.0.0.1:1455/auth/callback?state=st4te",
        "http://127.0.0.1:1456/auth/callback?code=abc&state=st4te",
        "http://127.0.0.1:1455/admin?code=abc&state=st4te",
        "http://localhost:1455/auth/callback?code=abc&state=st4te",
        "https://127.0.0.1:1455/auth/callback?code=abc&state=st4te",
        "http://evil.test:1455/auth/callback?code=abc&state=st4te",
        "not a url",
    };
    for (rejects) |r| try testing.expect((try relayedCallback(a, relay, r)) == .err);
}
