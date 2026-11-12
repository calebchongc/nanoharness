//! Tests for `agent_logins.zig`: synthetic homes in a temp dir, mock
//! `codex`/`graff`/shim scripts through `catalog_core.resolve_cli`, a fake
//! `security`, and an in-process loopback HTTP server for Claude's, Codex's
//! and Cursor's endpoints. Nothing here reads the real HOME or the network.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const al = @import("agent_logins.zig");
const util = @import("agent_logins_util.zig");
const slots = @import("agent_logins_slots.zig");
const keychain = @import("agent_logins_keychain.zig");
const catalog_core = @import("catalog_core.zig");

const posix_only = builtin.os.tag != .windows and std.process.can_spawn;

// ── CLI resolution seam ────────────────────────────────────────────────────

var test_codex: ?[]const u8 = null;
var test_graff: ?[]const u8 = null;

fn testResolve(gpa: Allocator, _: Io, id: []const u8) anyerror!?[]u8 {
    const p = if (std.mem.eql(u8, id, "codex")) test_codex else if (std.mem.eql(u8, id, "graff")) test_graff else null;
    return if (p) |x| try gpa.dupe(u8, x) else null;
}

var test_shim: ?[]const u8 = null;

fn testShim(a: Allocator, _: Io) anyerror!al.ShimLaunch {
    return .{ .exe = try a.dupe(u8, test_shim orelse return error.CursorSdkShimUnavailable) };
}

// ── loopback HTTP server ───────────────────────────────────────────────────

const Route = struct {
    needle: []const u8,
    status: u16 = 200,
    body: []const u8 = "{}",
    /// A file created when the route is hit.
    touch: ?[]const u8 = null,
};

const Server = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    routes: []const Route,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    log: std.ArrayList(u8) = .empty,
    hits: [16]u32 = @splat(0),
    thread: ?std.Thread = null,

    fn start(io: Io, routes: []const Route) !*Server {
        const self = try std.heap.smp_allocator.create(Server);
        const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .io = io, .listener = try addr.listen(io, .{ .reuse_address = true }), .port = 0, .routes = routes };
        self.port = self.listener.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn deinit(self: *Server) void {
        self.stop.store(true, .release);
        if (Io.net.IpAddress.parse("127.0.0.1", self.port)) |wake| {
            if (wake.connect(self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.listener.deinit(self.io);
        self.log.deinit(std.heap.smp_allocator);
        std.heap.smp_allocator.destroy(self);
    }

    fn base(self: *Server, a: Allocator) []const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    fn hitCount(self: *Server, i: usize) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.hits[i];
    }

    fn logged(self: *Server, a: Allocator) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return a.dupe(u8, self.log.items) catch unreachable;
    }

    fn run(self: *Server) void {
        while (!self.stop.load(.acquire)) {
            var stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            if (self.stop.load(.acquire)) return;
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var reader = stream.reader(self.io, &rbuf);
            var writer = stream.writer(self.io, &wbuf);
            const line_raw = reader.interface.takeDelimiterInclusive('\n') catch continue;
            var line_buf: [2048]u8 = undefined;
            const line = line_buf[0..@min(line_raw.len, line_buf.len)];
            @memcpy(line, line_raw[0..line.len]);
            var content_len: usize = 0;
            var headers: [4096]u8 = undefined;
            var hlen: usize = 0;
            while (true) {
                const h = reader.interface.takeDelimiterInclusive('\n') catch break;
                const t = std.mem.trimEnd(u8, h, "\r\n");
                if (t.len == 0) break;
                if (hlen + t.len + 1 < headers.len) {
                    @memcpy(headers[hlen .. hlen + t.len], t);
                    headers[hlen + t.len] = '\n';
                    hlen += t.len + 1;
                }
                if (std.ascii.startsWithIgnoreCase(t, "content-length:")) content_len = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " "), 10) catch 0;
            }
            var body_buf: [8192]u8 = undefined;
            const body = body_buf[0..@min(content_len, body_buf.len)];
            reader.interface.readSliceAll(body) catch {};
            var route: Route = .{ .needle = "", .status = 404, .body = "{}" };
            self.mutex.lockUncancelable(self.io);
            for (self.routes, 0..) |r, i| if (std.mem.indexOf(u8, line, r.needle) != null) {
                route = r;
                self.hits[i] += 1;
                break;
            };
            self.log.appendSlice(std.heap.smp_allocator, line) catch {};
            self.log.appendSlice(std.heap.smp_allocator, headers[0..hlen]) catch {};
            self.log.appendSlice(std.heap.smp_allocator, body) catch {};
            self.log.appendSlice(std.heap.smp_allocator, "\n--\n") catch {};
            self.mutex.unlock(self.io);
            if (route.touch) |p| Io.Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = "1" }) catch {};
            writer.interface.print("HTTP/1.1 {d} X\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ route.status, route.body.len, route.body }) catch continue;
            writer.interface.flush() catch continue;
        }
    }
};

// ── the rig ────────────────────────────────────────────────────────────────

const Out = struct { tag: std.meta.Tag(al.Reply), text: []const u8 };

const Rig = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    home: []const u8,
    env: std.process.Environ.Map,
    reg: *al.Registry,

    fn create() !*Rig {
        const io = testing.io;
        const self = try testing.allocator.create(Rig);
        self.tmp = testing.tmpDir(.{});
        self.arena = .init(testing.allocator);
        const ar = self.arena.allocator();
        self.base = try self.tmp.dir.realPathFileAlloc(io, ".", ar);
        self.home = try std.fs.path.join(ar, &.{ self.base, "home" });
        try Io.Dir.cwd().createDirPath(io, self.home);
        try Io.Dir.cwd().createDirPath(io, try self.path("bin"));
        self.env = .init(ar);
        try self.env.put("HOME", self.home);
        try self.env.put("PATH", "/usr/bin:/bin");
        try self.env.put("USER", "fixture-user");
        try self.env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        catalog_core.env_override = &self.env;
        catalog_core.resolve_cli = testResolve;
        al.resolve_cursor_shim = testShim;
        test_codex = null;
        test_graff = null;
        test_shim = null;
        self.reg = try al.Registry.initWithConfig(testing.allocator, io, .{
            .data_dir = try self.path("data"),
            .claude_config_dir = try self.path("home/.claude"),
            .claude_config_file = try self.path("home/.claude.json"),
            .codex_home = try self.path("home/.codex"),
            .cursor_sdk_auth_file = try self.path("home/.cursor/sdk/auth.json"),
            .graff_home = self.home,
        });
        return self;
    }

    fn destroy(self: *Rig) void {
        self.reg.deinit();
        catalog_core.env_override = null;
        test_codex = null;
        test_graff = null;
        test_shim = null;
        const guard = "http://127.0.0.1:9";
        al.claude_token_url = guard ++ "/v1/oauth/token";
        al.claude_profile_url = guard ++ "/api/oauth/profile";
        al.claude_usage_url = guard ++ "/api/oauth/usage";
        al.codex_usage_url = guard ++ "/backend-api/wham/usage";
        al.flow_ttl_ms = 15 * 60 * 1000;
        keychain.security_bin = "/nonexistent/harness-test-security";
        self.tmp.cleanup();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    fn al_(self: *Rig) Allocator {
        return self.arena.allocator();
    }

    fn path(self: *Rig, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.al_(), &.{ self.base, rel });
    }

    fn write(self: *Rig, rel: []const u8, data: []const u8) !void {
        const p = try self.path(rel);
        if (std.fs.path.dirname(p)) |d| try Io.Dir.cwd().createDirPath(testing.io, d);
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = data });
    }

    fn read(self: *Rig, rel: []const u8) ?[]const u8 {
        return Io.Dir.cwd().readFileAlloc(testing.io, self.path(rel) catch return null, self.al_(), .limited(1 << 20)) catch null;
    }

    fn exists(self: *Rig, rel: []const u8) bool {
        return slots.exists(testing.io, self.path(rel) catch return false);
    }

    fn script(self: *Rig, name: []const u8, body: []const u8) ![]const u8 {
        const rel = try std.fmt.allocPrint(self.al_(), "bin/{s}", .{name});
        try self.write(rel, body);
        const p = try self.path(rel);
        try Io.Dir.cwd().setFilePermissions(testing.io, p, .fromMode(0o755), .{});
        return p;
    }

    fn take(self: *Rig, r: al.Reply) Out {
        defer r.deinit(testing.allocator);
        return .{ .tag = std.meta.activeTag(r), .text = self.al_().dupe(u8, r.text()) catch unreachable };
    }

    fn call(self: *Rig, method: []const u8, params: []const u8) !Out {
        const v = try json.parseFromSliceLeaky(json.Value, self.al_(), params, .{});
        return self.take(self.reg.handle(method, v).?);
    }

    fn ok(self: *Rig, method: []const u8, params: []const u8) !json.Value {
        const o = try self.call(method, params);
        if (o.tag != .ok) {
            std.debug.print("{s} {s} -> {s}: {s}\n", .{ method, params, @tagName(o.tag), o.text });
            return error.TestUnexpectedResult;
        }
        return json.parseFromSliceLeaky(json.Value, self.al_(), o.text, .{});
    }

    fn failed(self: *Rig, method: []const u8, params: []const u8, expected: []const u8) !void {
        const o = try self.call(method, params);
        testing.expectEqual(std.meta.Tag(al.Reply).failed, o.tag) catch |e| {
            std.debug.print("{s} -> {s}\n", .{ method, o.text });
            return e;
        };
        try testing.expectEqualStrings(expected, o.text);
    }

    fn badParams(self: *Rig, method: []const u8, params: []const u8, expected: []const u8) !void {
        const o = try self.call(method, params);
        try testing.expectEqual(std.meta.Tag(al.Reply).bad_params, o.tag);
        try testing.expectEqualStrings(expected, o.text);
    }

    /// Poll until not pending (bounded).
    fn pollDone(self: *Rig, login_id: []const u8) !json.Value {
        const params = try std.fmt.allocPrint(self.al_(), "{{\"loginId\":\"{s}\"}}", .{login_id});
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const v = try self.ok("PollAgentLogin", params);
            if (!std.mem.eql(u8, v.object.get("status").?.string, "pending")) return v;
            Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
        }
        return error.Timeout;
    }
};

fn jwt(a: Allocator, payload: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(payload.len));
    return std.fmt.allocPrint(a, "h.{s}.s", .{enc.encode(buf, payload)});
}

fn codexAuth(a: Allocator, account: []const u8, email: []const u8, access: []const u8) ![]const u8 {
    const claims = try std.fmt.allocPrint(a, "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_plan_type\":\"plus\"}}}}", .{ email, account });
    return std.fmt.allocPrint(a, "{{\"tokens\":{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"account_id\":\"{s}\"}}}}", .{ try jwt(a, claims), access, account });
}

fn accountsOf(v: json.Value) []json.Value {
    return v.object.get("accounts").?.array.items;
}

fn str(v: json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

fn idFor(h: util.Harness, key: []const u8) [16]u8 {
    return util.slotIdFor(h, key);
}

// ── list ───────────────────────────────────────────────────────────────────

test "agent_logins: snapshot detects all three CLIs, saves slots, and forced usage reads the endpoints" {
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    const routes = [_]Route{
        .{ .needle = "/api/oauth/usage", .body = "{\"five_hour\":null,\"seven_day\":{\"utilization\":22.0,\"resets_at\":\"2026-11-17T08:00:00.000Z\"}}" },
        .{ .needle = "/wham/usage", .body = "{\"plan_type\":\"pro\",\"rate_limit\":{\"primary_window\":{\"used_percent\":75,\"limit_window_seconds\":604800,\"reset_at\":1794960000}}}" },
        .{ .needle = "/auth/exchange_user_api_key", .body = "{\"accessToken\":\"cursor-session-fixture\"}" },
        .{ .needle = "GetCurrentPeriodUsage", .body = "{\"billingCycleEnd\":\"1794873600000\",\"planUsage\":{\"totalSpend\":1000,\"limit\":2000}}" },
    };
    const srv = try Server.start(testing.io, &routes);
    defer srv.deinit();
    al.claude_usage_url = try std.fmt.allocPrint(a, "{s}/api/oauth/usage", .{srv.base(a)});
    al.codex_usage_url = try std.fmt.allocPrint(a, "{s}/backend-api/wham/usage", .{srv.base(a)});

    try rig.write("home/.claude.json", "{\"oauthAccount\":{\"accountUuid\":\"u-claude\",\"emailAddress\":\"ada@example.invalid\",\"organizationType\":\"claude_max\",\"organizationRateLimitTier\":\"default_claude_max_20x\"},\"userID\":\"uid-fixture\"}");
    try rig.write("home/.claude/.credentials.json", "{\"claudeAiOauth\":{\"accessToken\":\"claude-access-fixture\",\"refreshToken\":\"claude-refresh-fixture\"}}");
    try rig.write("home/.codex/auth.json", try codexAuth(a, "acct-1", "ada@example.invalid", "codex-access-fixture"));
    try rig.write("home/.cursor/sdk/auth.json", try std.fmt.allocPrint(a, "{{\"apiKey\":\"cursor-key-fixture\",\"email\":\"ada@example.invalid\",\"apiKeyExpiresAtMs\":32503680000000,\"backendUrl\":\"{s}/\"}}", .{srv.base(a)}));

    const quiet = try rig.ok("ListAgentAccounts", "{}");
    const accs = accountsOf(quiet);
    try testing.expectEqual(@as(usize, 3), accs.len);
    try testing.expectEqualStrings("claude-code", str(accs[0], "harness"));
    try testing.expectEqualStrings("Max 20\u{00D7}", str(accs[0], "planLabel"));
    try testing.expectEqualStrings(&idFor(.claude_code, "u-claude"), str(accs[0], "id"));
    try testing.expect(accs[0].object.get("active").?.bool and accs[0].object.get("switchable").?.bool);
    try testing.expectEqual(@as(usize, 0), accs[0].object.get("usageWindows").?.array.items.len);
    try testing.expectEqualStrings("ChatGPT Plus", str(accs[1], "planLabel"));
    try testing.expectEqualStrings("Key expires Jan 1", str(accs[2], "planLabel"));
    try testing.expectEqual(@as(u32, 0), srv.hitCount(0));
    // The Claude slot carries the identity merged back on a swap.
    const slot = slots.parseSlot(a, rig.read(try std.fmt.allocPrint(a, "data/agent-accounts/claude-code/{s}.json", .{&idFor(.claude_code, "u-claude")})).?).?;
    try testing.expectEqualStrings("uid-fixture", util.strField(slot.claude_config.?, "userID").?);

    const forced = try rig.ok("ListAgentAccounts", "{\"forceUsage\":true}");
    const f = accountsOf(forced);
    const cw = f[0].object.get("usageWindows").?.array.items;
    try testing.expectEqual(@as(usize, 1), cw.len);
    try testing.expectEqualStrings("Week", str(cw[0], "label"));
    try testing.expectEqualStrings("2026-11-17T08:00:00Z", str(cw[0], "resetsAt"));
    try testing.expectEqualStrings("ChatGPT Pro", str(f[1], "planLabel"));
    try testing.expectEqualStrings("2026-11-18T00:00:00Z", str(f[1].object.get("usageWindows").?.array.items[0], "resetsAt"));
    const cur = f[2].object.get("usageWindows").?.array.items[0];
    try testing.expectEqualStrings("Month", str(cur, "label"));
    try testing.expectEqual(@as(f64, 0.5), cur.object.get("usedFraction").?.float);
    const log = srv.logged(a);
    try testing.expect(std.mem.indexOf(u8, log, "authorization: Bearer claude-access-fixture") != null or std.mem.indexOf(u8, log, "Authorization: Bearer claude-access-fixture") != null);
    try testing.expect(std.mem.indexOf(u8, log, "anthropic-beta: oauth-2025-04-20") != null);
    try testing.expect(std.mem.indexOf(u8, log, "chatgpt-account-id: acct-1") != null);
    try testing.expect(std.mem.indexOf(u8, log, "Connect-Protocol-Version: 1") != null);

    // Cached for 60 s: a quiet list shows the windows without a request.
    const hits = srv.hitCount(0);
    const cached = try rig.ok("ListAgentAccounts", "{\"forceUsage\":null}");
    try testing.expectEqual(@as(usize, 1), accountsOf(cached)[0].object.get("usageWindows").?.array.items.len);
    try testing.expectEqual(hits, srv.hitCount(0));

    // An expired Cursor key is called out.
    try rig.write("home/.cursor/sdk/auth.json", "{\"apiKey\":\"cursor-key-fixture\",\"email\":\"ada@example.invalid\",\"apiKeyExpiresAtMs\":1}");
    const warned = try rig.ok("ListAgentAccounts", "{}");
    const w = warned.object.get("warnings").?.array.items;
    try testing.expectEqual(@as(usize, 1), w.len);
    try testing.expectEqualStrings("cursor", str(w[0], "harness"));
    try testing.expectEqualStrings("The connected Cursor login's API key has expired \u{2014} connect again.", str(w[0], "message"));

    try rig.badParams("ListAgentAccounts", "{\"forceUsage\":\"yes\"}", "invalid type: string \"yes\", expected a boolean");
    try rig.badParams("ListAgentAccounts", "null", "invalid type: null, expected struct ListAgentAccountsParams");
}

test "agent_logins: usage never spends the live login's refresh token" {
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    const routes = [_]Route{
        .{ .needle = "POST /v1/oauth/token", .body = "{\"access_token\":\"fresh\",\"refresh_token\":\"rotated\",\"expires_in\":28800}" },
        .{ .needle = "/api/oauth/usage", .status = 401, .body = "" },
    };
    const srv = try Server.start(testing.io, &routes);
    defer srv.deinit();
    al.claude_usage_url = try std.fmt.allocPrint(a, "{s}/api/oauth/usage", .{srv.base(a)});
    al.claude_token_url = try std.fmt.allocPrint(a, "{s}/v1/oauth/token", .{srv.base(a)});
    const creds_a = "{\"claudeAiOauth\":{\"accessToken\":\"access-a\",\"refreshToken\":\"token-a\"},\"mcpOAuth\":{\"keep\":true}}";
    const id_a = idFor(.claude_code, "uuid-a");
    try slots.writeSlot(a, testing.io, rig.reg.config, .{ .id = &id_a, .harness = .claude_code, .account_key = "uuid-a", .profile = .{ .email = "a@example.invalid", .auth_kind = .oauth }, .credentials = util.parseJson(a, creds_a).?, .saved_at = 0 });
    try rig.write("home/.claude/.credentials.json", creds_a);
    // Caught mid-write: Claude Code rewrites this file all the time.
    try rig.write("home/.claude.json", "{\"oauthAccount\": {\"emailAdd");
    _ = try rig.ok("ListAgentAccounts", "{\"forceUsage\":true}");
    try testing.expectEqual(@as(u32, 0), srv.hitCount(0));

    try rig.write("home/.claude.json", "{\"oauthAccount\":{\"accountUuid\":\"uuid-b\",\"emailAddress\":\"b@example.invalid\"}}");
    try rig.write("home/.claude/.credentials.json", "{\"claudeAiOauth\":{\"accessToken\":\"access-b\",\"refreshToken\":\"token-b\"}}");
    _ = try rig.ok("ListAgentAccounts", "{\"forceUsage\":true}");
    try testing.expectEqual(@as(u32, 1), srv.hitCount(0));
    try testing.expect(std.mem.indexOf(u8, srv.logged(a), "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"token-a\",\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\"}") != null);
    const saved = slots.parseSlot(a, rig.read(try std.fmt.allocPrint(a, "data/agent-accounts/claude-code/{s}.json", .{&id_a})).?).?;
    const oauth = util.get(saved.credentials, "claudeAiOauth").?;
    try testing.expectEqualStrings("rotated", util.strField(oauth, "refreshToken").?);
    try testing.expectEqualStrings("fresh", util.strField(oauth, "accessToken").?);
    try testing.expect(util.get(saved.credentials, "mcpOAuth") != null);
}

// ── activate / forget ──────────────────────────────────────────────────────

test "agent_logins: activate swaps Codex and Claude logins; errors and bad params" {
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    // Codex: save B, sign in as A, switch back to B.
    const auth_b = try codexAuth(a, "acct-b", "b@example.invalid", "access-b");
    try rig.write("home/.codex/auth.json", auth_b);
    _ = try rig.ok("ListAgentAccounts", "{}");
    try rig.write("home/.codex/auth.json", try codexAuth(a, "acct-a", "a@example.invalid", "access-a"));
    const after = try rig.ok("ActivateAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"codex\",\"accountId\":\"{s}\"}}", .{&idFor(.codex, "acct-b")}));
    try testing.expect(util.valueEql(util.parseJson(a, rig.read("home/.codex/auth.json").?).?, util.parseJson(a, auth_b).?));
    const accs = accountsOf(after);
    try testing.expectEqual(@as(usize, 2), accs.len);
    try testing.expectEqualStrings("b@example.invalid", str(accs[0], "email"));
    try testing.expect(accs[0].object.get("active").?.bool);
    try testing.expect(!accs[1].object.get("active").?.bool);

    // Claude: the slot's login with the live MCP OAuth; identity merged.
    const id_b = idFor(.claude_code, "uuid-b");
    try slots.writeSlot(a, testing.io, rig.reg.config, .{
        .id = &id_b,
        .harness = .claude_code,
        .account_key = "uuid-b",
        .profile = .{ .email = "b@example.invalid", .auth_kind = .oauth },
        .credentials = util.parseJson(a, "{\"claudeAiOauth\":{\"accessToken\":\"access-b\"},\"mcpOAuth\":{\"stale\":true}}").?,
        .claude_config = util.parseJson(a, "{\"oauthAccount\":{\"accountUuid\":\"uuid-b\",\"emailAddress\":\"b@example.invalid\"}}").?,
        .saved_at = 1,
    });
    try rig.write("home/.claude.json", "{\"numStartups\":3,\"oauthAccount\":{\"accountUuid\":\"uuid-a\",\"emailAddress\":\"a@example.invalid\"},\"userID\":\"uid-a\",\"projects\":{}}");
    try rig.write("home/.claude/.credentials.json", "{\"claudeAiOauth\":{\"accessToken\":\"access-a\"},\"mcpOAuth\":{\"live\":true}}");
    _ = try rig.ok("ActivateAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"claude-code\",\"accountId\":\"{s}\"}}", .{&id_b}));
    try testing.expectEqualStrings("{\"claudeAiOauth\":{\"accessToken\":\"access-b\"},\"mcpOAuth\":{\"live\":true}}", rig.read("home/.claude/.credentials.json").?);
    try testing.expectEqualStrings("{\"numStartups\":3,\"oauthAccount\":{\"accountUuid\":\"uuid-b\",\"emailAddress\":\"b@example.invalid\"},\"projects\":{}}", rig.read("home/.claude.json").?);
    // The replaced login was snapshotted first.
    try testing.expect(rig.exists(try std.fmt.allocPrint(a, "data/agent-accounts/claude-code/{s}.json", .{&idFor(.claude_code, "uuid-a")})));

    try rig.failed("ActivateAgentAccount", "{\"harness\":\"codex\",\"accountId\":\"0000000000000000\"}", "That saved login no longer exists \u{2014} refresh and try again.");
    try rig.write("home/.claude.json", "{not json");
    try rig.failed("ActivateAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"claude-code\",\"accountId\":\"{s}\"}}", .{&id_b}), "~/.claude.json exists but could not be parsed \u{2014} not switching to avoid wiping it. Fix or remove the file and try again.");
    try rig.badParams("ActivateAgentAccount", "{\"harness\":\"codex\"}", "missing field `accountId`");
    try rig.badParams("ActivateAgentAccount", "{\"harness\":\"nope\",\"accountId\":\"x\"}", "unknown variant `nope`, expected one of `claude-code`, `codex`, `cursor`, `devin`, `grok`, `hermes`, `graff`, `pi`, `opencode`, `antigravity`, `exo`, `mock`");
    try rig.badParams("ActivateAgentAccount", "null", "invalid type: null, expected struct AgentAccountParams");
}

test "agent_logins: forget drops a saved login, signs the live one out, refuses other ids" {
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    try rig.write("home/.codex/auth.json", try codexAuth(a, "acct-b", "b@example.invalid", "access-b"));
    _ = try rig.ok("ListAgentAccounts", "{}");
    try rig.write("home/.codex/auth.json", try codexAuth(a, "acct-a", "a@example.invalid", "access-a"));
    const id_a = idFor(.codex, "acct-a");
    const id_b = idFor(.codex, "acct-b");
    const left = try rig.ok("ForgetAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"codex\",\"accountId\":\"{s}\"}}", .{&id_b}));
    try testing.expectEqual(@as(usize, 1), accountsOf(left).len);
    try testing.expect(rig.exists("home/.codex/auth.json"));
    const none = try rig.ok("ForgetAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"codex\",\"accountId\":\"{s}\"}}", .{&id_a}));
    try testing.expectEqual(@as(usize, 0), accountsOf(none).len);
    try testing.expect(!rig.exists("home/.codex/auth.json"));

    // Claude: removing the live login keeps the machine's MCP OAuth.
    try rig.write("home/.claude.json", "{\"oauthAccount\":{\"accountUuid\":\"uuid-a\",\"emailAddress\":\"a@example.invalid\"},\"theme\":\"dark\"}");
    try rig.write("home/.claude/.credentials.json", "{\"claudeAiOauth\":{\"accessToken\":\"x\"},\"mcpOAuth\":{\"live\":true}}");
    _ = try rig.ok("ForgetAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"claude-code\",\"accountId\":\"{s}\"}}", .{&idFor(.claude_code, "uuid-a")}));
    try testing.expectEqualStrings("{\"mcpOAuth\":{\"live\":true}}", rig.read("home/.claude/.credentials.json").?);
    try testing.expectEqualStrings("{\"theme\":\"dark\"}", rig.read("home/.claude.json").?);

    try rig.failed("ForgetAgentAccount", "{\"harness\":\"codex\",\"accountId\":\"../../etc/passwd\"}", "Unknown account.");
    try rig.badParams("ForgetAgentAccount", "{\"accountId\":\"x\"}", "missing field `harness`");
    try rig.badParams("ForgetAgentAccount", "{\"harness\":5,\"accountId\":\"x\"}", "invalid type: integer `5`, expected string or map");
}

// ── Claude paste-code ──────────────────────────────────────────────────────

test "agent_logins: Claude paste-code login exchanges the code and adopts the first login" {
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    const routes = [_]Route{
        .{ .needle = "POST /v1/oauth/token", .body = "{\"access_token\":\"access-new\",\"refresh_token\":\"refresh-new\",\"expires_in\":3600,\"scope\":\"user:inference user:profile\"}" },
        .{ .needle = "/api/oauth/profile", .body = "{\"account\":{\"uuid\":\"uuid-new\",\"email_address\":\"new@example.invalid\",\"display_name\":\"New\"},\"organization\":{\"uuid\":\"org-1\",\"name\":\"Fixture Org\",\"organization_type\":\"claude_pro\"}}" },
    };
    const srv = try Server.start(testing.io, &routes);
    defer srv.deinit();
    al.claude_token_url = try std.fmt.allocPrint(a, "{s}/v1/oauth/token", .{srv.base(a)});
    al.claude_profile_url = try std.fmt.allocPrint(a, "{s}/api/oauth/profile", .{srv.base(a)});

    const start = try rig.ok("StartAgentLogin", "{\"harness\":\"claude-code\"}");
    try testing.expectEqualStrings("paste-code", str(start, "mode"));
    const url = str(start, "url");
    try testing.expect(std.mem.startsWith(u8, url, "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key%20user%3Aprofile%20user%3Ainference&code_challenge="));
    const verifier = url[std.mem.indexOf(u8, url, "&state=").? + 7 ..];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var cb: [43]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, url, try std.fmt.allocPrint(a, "code_challenge={s}&code_challenge_method=S256", .{std.base64.url_safe_no_pad.Encoder.encode(&cb, &digest)})) != null);
    const id = str(start, "loginId");
    try testing.expect(start.object.get("code") == null);

    const poll = try rig.ok("PollAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{id}));
    try testing.expectEqualStrings("pending", str(poll, "status"));
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"  #st \"}}", .{id}), "That code looks empty \u{2014} paste the whole code.");
    try rig.failed("CompleteAgentLogin", "{\"loginId\":\"nope\",\"code\":\"c#s\"}", "This sign-in attempt expired \u{2014} start again.");

    const snap = try rig.ok("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\" code-1#state-1 \"}}", .{id}));
    const accs = accountsOf(snap);
    try testing.expectEqual(@as(usize, 1), accs.len);
    try testing.expectEqualStrings("new@example.invalid", str(accs[0], "email"));
    try testing.expectEqualStrings("Pro", str(accs[0], "planLabel"));
    try testing.expectEqualStrings("Fixture Org", str(accs[0], "organization"));
    try testing.expect(accs[0].object.get("active").?.bool);
    const log = srv.logged(a);
    try testing.expect(std.mem.indexOf(u8, log, try std.fmt.allocPrint(a, "{{\"grant_type\":\"authorization_code\",\"code\":\"code-1\",\"state\":\"state-1\",\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\",\"redirect_uri\":\"https://console.anthropic.com/oauth/code/callback\",\"code_verifier\":\"{s}\"}}", .{verifier})) != null);
    // No live login before: the new one became it.
    const live = util.parseJson(a, rig.read("home/.claude/.credentials.json").?).?;
    const oauth = util.get(live, "claudeAiOauth").?;
    try testing.expectEqualStrings("access-new", util.strField(oauth, "accessToken").?);
    try testing.expectEqualStrings("pro", util.strField(oauth, "subscriptionType").?);
    try testing.expectEqual(@as(usize, 2), util.get(oauth, "scopes").?.array.items.len);
    const cfg = util.parseJson(a, rig.read("home/.claude.json").?).?;
    try testing.expectEqualStrings("Fixture Org", util.strField(util.get(cfg, "oauthAccount").?, "organizationName").?);
    // The flow is gone.
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"c#s\"}}", .{id}), "This sign-in attempt expired \u{2014} start again.");
    try rig.badParams("CompleteAgentLogin", "{\"loginId\":\"x\"}", "missing field `code`");
}

test "agent_logins: Claude code exchange failures carry Anthropic's answer" {
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    const rejected = [_]Route{.{ .needle = "POST /v1/oauth/token", .status = 400, .body = "{\"error\":\"invalid_grant\"}" }};
    const srv = try Server.start(testing.io, &rejected);
    defer srv.deinit();
    al.claude_token_url = try std.fmt.allocPrint(a, "{s}/v1/oauth/token", .{srv.base(a)});
    const id = str(try rig.ok("StartAgentLogin", "{\"harness\":\"claude-code\"}"), "loginId");
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"c#s\"}}", .{id}), "Anthropic rejected the code (400 Bad Request): {\"error\":\"invalid_grant\"}");

    const empty = [_]Route{.{ .needle = "POST /v1/oauth/token", .body = "{\"access_token\":\"only-access\"}" }};
    const srv2 = try Server.start(testing.io, &empty);
    defer srv2.deinit();
    al.claude_token_url = try std.fmt.allocPrint(a, "{s}/v1/oauth/token", .{srv2.base(a)});
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"c\"}}", .{id}), "Anthropic returned no usable tokens \u{2014} try signing in again.");

    al.claude_token_url = "http://127.0.0.1:9/v1/oauth/token";
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"c\"}}", .{id}), "token exchange failed: error sending request for url (http://127.0.0.1:9/v1/oauth/token)");
}

// ── Codex ──────────────────────────────────────────────────────────────────

test "agent_logins: codex login prints its page, poll adopts the first login and cleans up" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    try rig.failed("StartAgentLogin", "{\"harness\":\"codex\"}", "The `codex` CLI was not found on this device \u{2014} install it first. (codex (searched PATH, the login shell's PATH, ~/.local/bin, ~/.codex/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CODEX_EXECUTABLE to override))");

    const auth = try codexAuth(a, "acct-new", "new@example.invalid", "access-new");
    test_codex = try rig.script("codex", try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\[ "$1" = login ] || exit 9
        \\echo "$BROWSER" > '{s}/browser.txt'
        \\printf 'Starting local login server.\nNavigate to this URL to authenticate:\n\nhttps://auth.openai.com/oauth/authorize?client_id=fixture&state=s1\n\n' >&2
        \\i=0; while [ ! -f '{s}/go' ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
        \\printf '%s' '{s}' > "$CODEX_HOME/auth.json"
        \\
    , .{ rig.base, rig.base, auth }));
    const start = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\"}");
    try testing.expectEqualStrings("browser", str(start, "mode"));
    try testing.expectEqualStrings("https://auth.openai.com/oauth/authorize?client_id=fixture&state=s1", str(start, "url"));
    const id = str(start, "loginId");
    const home = try std.fmt.allocPrint(a, "data/agent-accounts/.login-{s}", .{id});
    try testing.expect(rig.exists(home));
    try testing.expectEqualStrings("pending", str(try rig.ok("PollAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{id})), "status"));
    try testing.expect(std.mem.endsWith(u8, std.mem.trim(u8, rig.read("browser.txt").?, "\n"), "/data/agent-accounts/.noop-browser"));
    try rig.write("go", "1");
    const done = try rig.pollDone(id);
    try testing.expectEqualStrings("done", str(done, "status"));
    try testing.expect(util.valueEql(util.parseJson(a, rig.read("home/.codex/auth.json").?).?, util.parseJson(a, auth).?));
    try testing.expect(!rig.exists(home));
    try rig.failed("PollAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{id}), "This sign-in attempt expired \u{2014} start again.");
    const accs = accountsOf(try rig.ok("ListAgentAccounts", "{}"));
    try testing.expectEqualStrings("new@example.invalid", str(accs[0], "email"));
}

test "agent_logins: codex login failures and cancel" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    test_codex = try rig.script("codex", "#!/bin/sh\necho 'Error: port 1455 is already in use' >&2\nexit 1\n");
    const start = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\"}");
    try testing.expectEqualStrings("", str(start, "url"));
    const failed = try rig.pollDone(str(start, "loginId"));
    try testing.expectEqualStrings("error", str(failed, "status"));
    try testing.expectEqualStrings("Error: port 1455 is already in use", str(failed, "message"));

    test_codex = try rig.script("codex2", "#!/bin/sh\nexit 0\n");
    const quiet = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\"}");
    try testing.expectEqualStrings("The sign-in finished without credentials.", str(try rig.pollDone(str(quiet, "loginId")), "message"));

    test_codex = try rig.script("codex3", "#!/bin/sh\nprintf 'https://auth.openai.com/oauth/authorize?x=1\\n' >&2\nsleep 30\n");
    const slow = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\"}");
    const id = str(slow, "loginId");
    const cancel = try rig.ok("CancelAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{id}));
    try testing.expect(cancel.object.get("ok").?.bool);
    try testing.expect(!rig.exists(try std.fmt.allocPrint(a, "data/agent-accounts/.login-{s}", .{id})));
    try rig.failed("PollAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{id}), "This sign-in attempt expired \u{2014} start again.");
    // Cancelling again (or an unknown id) is still ok.
    _ = try rig.ok("CancelAgentLogin", "{\"loginId\":\"nope\"}");
    try rig.badParams("CancelAgentLogin", "{}", "missing field `loginId`");
    try rig.badParams("PollAgentLogin", "{\"loginId\":7}", "invalid type: integer `7`, expected a string");

    // A new start supersedes a pending one (codex holds a fixed port).
    const first = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\"}");
    _ = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\"}");
    try rig.failed("PollAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{str(first, "loginId")}), "This sign-in attempt expired \u{2014} start again.");
}

test "agent_logins: codex recovery by device code attaches later viewers; the RPC's gates" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    try rig.failed("StartAgentLogin", "{\"harness\":\"codex\",\"deviceAuth\":true}", "Device authorization is supported only for explicit Codex recovery.");
    try rig.failed("StartAgentLogin", "{\"harness\":\"claude-code\",\"reauthenticate\":true,\"deviceAuth\":true}", "Device authorization is supported only for explicit Codex recovery.");
    try rig.failed("StartAgentLogin", "{\"harness\":\"codex\",\"relayBrowser\":true}", "Finishing sign-in on another device is supported only for graff's ChatGPT sign-in.");
    try rig.failed("StartAgentLogin", "{\"harness\":\"graff\"}", "Say which graff provider to sign in to.");
    try rig.failed("StartAgentLogin", "{\"harness\":\"devin\"}", "agent logins are not supported for Devin");
    const ag = try rig.call("StartAgentLogin", "{\"harness\":\"antigravity\"}");
    try testing.expectEqual(std.meta.Tag(al.Reply).not_ported, ag.tag);
    try rig.badParams("StartAgentLogin", "{}", "missing field `harness`");
    try rig.badParams("StartAgentLogin", "{\"harness\":\"codex\",\"deviceAuth\":\"yes\"}", "invalid type: string \"yes\", expected a boolean");
    try rig.badParams("StartAgentLogin", "{\"harness\":\"codex\",\"reauthenticate\":null}", "invalid type: null, expected a boolean");
    try rig.badParams("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":1}", "invalid type: integer `1`, expected a string");
    try rig.badParams("StartAgentLogin", "[]", "invalid type: sequence, expected struct StartAgentLoginParams");

    try rig.write("home/.codex/auth.json", try codexAuth(a, "acct-old", "old@example.invalid", "expired"));
    test_codex = try rig.script("codex", "#!/bin/sh\n[ \"$2\" = --device-auth ] || exit 3\nprintf '1. Open this link in your browser and sign in to your account\\n  \\033[94mhttps://auth.openai.com/codex/device\\033[0m\\n\\n2. Enter this one-time code (expires in 15 minutes)\\n  \\033[94mABCD-EFGH\\033[0m\\n'\nsleep 30\n");
    const s1 = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\",\"reauthenticate\":true,\"deviceAuth\":true}");
    try testing.expectEqualStrings("device-code", str(s1, "mode"));
    try testing.expectEqualStrings("https://auth.openai.com/codex/device", str(s1, "url"));
    try testing.expectEqualStrings("ABCD-EFGH", str(s1, "code"));
    // The live login was snapshotted before the recovery.
    try testing.expect(rig.exists(try std.fmt.allocPrint(a, "data/agent-accounts/codex/{s}.json", .{&idFor(.codex, "acct-old")})));
    const s2 = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\",\"reauthenticate\":true,\"deviceAuth\":true}");
    try testing.expectEqualStrings(str(s1, "loginId"), str(s2, "loginId"));
    _ = try rig.ok("CancelAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{str(s1, "loginId")}));
    const s3 = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\",\"reauthenticate\":true,\"deviceAuth\":true}");
    try testing.expect(!std.mem.eql(u8, str(s1, "loginId"), str(s3, "loginId")));
    _ = try rig.ok("CancelAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{str(s3, "loginId")}));

    test_codex = try rig.script("codex-silent", "#!/bin/sh\nexit 1\n");
    try rig.failed("StartAgentLogin", "{\"harness\":\"codex\",\"reauthenticate\":true,\"deviceAuth\":true}", "Device sign-in did not start. Update the agent CLI and enable device-code login in your ChatGPT security settings, then try again.");
}

test "agent_logins: an approved codex recovery replaces the live login with the renewed one" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    try rig.write("home/.codex/auth.json", try codexAuth(a, "acct-other", "other@example.invalid", "expired"));
    const renewed = try codexAuth(a, "acct-same", "same@example.invalid", "renewed");
    test_codex = try rig.script("codex", try std.fmt.allocPrint(a, "#!/bin/sh\n[ -z \"$BROWSER\" ] || exit 4\nprintf '%s' '{s}' > \"$CODEX_HOME/auth.json\"\n", .{renewed}));
    const s = try rig.ok("StartAgentLogin", "{\"harness\":\"codex\",\"reauthenticate\":true}");
    try testing.expectEqualStrings("host-browser", str(s, "mode"));
    try testing.expectEqualStrings("", str(s, "url"));
    try testing.expectEqualStrings("done", str(try rig.pollDone(str(s, "loginId")), "status"));
    try testing.expect(util.valueEql(util.parseJson(a, rig.read("home/.codex/auth.json").?).?, util.parseJson(a, renewed).?));
}

// ── Cursor ─────────────────────────────────────────────────────────────────

test "agent_logins: cursor shim login mints into a throwaway store and becomes the live key" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    try rig.failed("StartAgentLogin", "{\"harness\":\"cursor\"}", "Could not start the Cursor login: CursorSdkShimUnavailable");
    test_shim = try rig.script("shim", "#!/bin/sh\n[ \"$1\" = login ] || exit 9\necho '{\"ev\":\"auth-url\",\"url\":\"https://cursor.example/loginDeepControl?challenge=c\"}'\nprintf '%s' '{\"apiKey\":\"cursor-new-key\",\"email\":\"cur@example.invalid\",\"apiKeyExpiresAtMs\":32503680000000}' > \"$2\"\necho '{\"ev\":\"logged-in\"}'\n");
    const s = try rig.ok("StartAgentLogin", "{\"harness\":\"cursor\"}");
    try testing.expectEqualStrings("browser", str(s, "mode"));
    try testing.expectEqualStrings("https://cursor.example/loginDeepControl?challenge=c", str(s, "url"));
    try testing.expectEqualStrings("done", str(try rig.pollDone(str(s, "loginId")), "status"));
    try testing.expectEqualStrings("cursor-new-key", util.strField(util.parseJson(a, rig.read("home/.cursor/sdk/auth.json").?).?, "apiKey").?);

    test_shim = try rig.script("shim-fatal", "#!/bin/sh\necho '{\"ev\":\"fatal\",\"message\":\"Login timed out.\"}'\nexit 1\n");
    const f = try rig.ok("StartAgentLogin", "{\"harness\":\"cursor\"}");
    try testing.expectEqualStrings("", str(f, "url"));
    try testing.expectEqualStrings("Login timed out.", str(try rig.pollDone(str(f, "loginId")), "message"));
}

// ── graff ──────────────────────────────────────────────────────────────────

const graff_mock =
    \\#!/bin/sh
    \\[ "$1" = login ] || exit 9
    \\echo "$GRAFF_NO_BROWSER|$NO_COLOR|$HOME|${PATH%%:*}" > "$HOME/../graff-env-$2"
    \\case "$2" in
    \\xai)
    \\  printf '\nTo log in to Grok (xAI), open this URL (browser should open automatically):\n\n  https://accounts.x.ai/device?user_code=ABCD-1234\n\nand confirm the code:  ABCD-1234\n\nwaiting for authorization\n'
    \\  i=0; while [ ! -f "$HOME/../go-xai" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
    \\  mkdir -p "$HOME/.xai/credentials"; echo '{}' > "$HOME/.xai/credentials/graff-oauth.json"
    \\  echo "✓ logged into Grok (xAI)" ;;
    \\kimi)
    \\  printf 'open this URL:\n\n  https://www.kimi.com/code/authorize_device?user_code=WXYZ\n\n'
    \\  sleep 0.3; echo "✗ the code expired — run graff login kimi again" ;;
    \\zai) ;;
    \\anthropic)
    \\  printf 'If it does not open, visit:\n\n  https://platform.example/oauth/authorize?state=s\n\n'
    \\  read code; echo "✓ graff will use your Anthropic Console sign-in ($code)" ;;
    \\claude-agent)
    \\  if [ -f "$HOME/.claude.json" ]; then echo "✓ graff will use Claude Code"; else echo "✗ Claude Code is not signed in. Run claude and /login."; fi ;;
    \\chatgpt-new)
    \\  printf '\nSign in with ChatGPT:\n\nhttps://auth.openai.com/api/accounts/authorize?client_id=c&redirect_uri=http%%3A%%2F%%2F127.0.0.1%%3A__PORT__%%2Fauth%%2Fcallback&state=st4te\n\nwaiting for the sign-in on http://127.0.0.1:__PORT__/auth/callback …\n'
    \\  i=0; while [ ! -f "$HOME/../go-chatgpt" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
    \\  mkdir -p "$HOME/.graff/credentials"
    \\  echo '{"email":"a@example.invalid","client_id":"oaiapp_1","access_token":"t","scopes":["chatgpt.tokens.use.direct"]}' > "$HOME/.graff/credentials/chatgpt-new.json"
    \\  echo "✓ signed in to ChatGPT as a@example.invalid; plan usage is on." ;;
    \\esac
    \\
;

test "agent_logins: graff sign-ins offer the link and code and finish when the credential lands" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    try rig.failed("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"xai\"}", "The `graff` CLI was not found on this device \u{2014} install it first. (graff (searched PATH, the login shell's PATH, ~/.harness/bin, the app bundle, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install codegraff, then `graff login`; set GRAFF_EXECUTABLE to override))");
    test_graff = try rig.script("graff", graff_mock);
    try rig.failed("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"codex\"}", "graff can't sign in to codex from here");
    try rig.failed("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"xai\",\"relayBrowser\":true}", "Finishing sign-in on another device is supported only for graff's ChatGPT sign-in.");

    const s = try rig.ok("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"xai\"}");
    try testing.expectEqualStrings("browser", str(s, "mode"));
    try testing.expectEqualStrings("https://accounts.x.ai/device?user_code=ABCD-1234", str(s, "url"));
    try testing.expectEqualStrings("ABCD-1234", str(s, "code"));
    const env_line = std.mem.trim(u8, rig.read("graff-env-xai").?, "\n");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "1|1|{s}|{s}/data/agent-accounts/.noop-open", .{ rig.home, rig.base }), env_line);
    try testing.expectEqualStrings("pending", str(try rig.ok("PollAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{str(s, "loginId")})), "status"));
    try rig.write("go-xai", "1");
    const done = try rig.pollDone(str(s, "loginId"));
    try testing.expectEqualStrings("done", str(done, "status"));
    try testing.expect(done.object.get("message") == null);
    // The relayed completion is refused for a sign-in finishing on this host.
    const k = try rig.ok("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"kimi\"}");
    try testing.expectEqualStrings("https://www.kimi.com/code/authorize_device?user_code=WXYZ", str(k, "url"));
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"x\"}}", .{str(k, "loginId")}), "This sign-in finishes in the execution device's browser.");
    const kd = try rig.pollDone(str(k, "loginId"));
    try testing.expectEqualStrings("error", str(kd, "status"));
    try testing.expectEqualStrings("the code expired \u{2014} run graff login kimi again", str(kd, "message"));
    try rig.failed("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"zai\"}", "The sign-in did not finish.");
}

test "agent_logins: graff's ChatGPT sign-in relayed from another device, and on the host" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    const go = try rig.path("go-chatgpt");
    const routes = [_]Route{.{ .needle = "GET /auth/callback?code=abc&state=st4te", .body = "signed in", .touch = go }};
    const srv = try Server.start(testing.io, &routes);
    defer srv.deinit();
    const port = try std.fmt.allocPrint(a, "{d}", .{srv.port});
    test_graff = try rig.script("graff", try std.mem.replaceOwned(u8, a, graff_mock, "__PORT__", port));

    const s = try rig.ok("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"chatgpt-new\",\"relayBrowser\":true}");
    try testing.expectEqualStrings("relay-browser", str(s, "mode"));
    try testing.expect(std.mem.startsWith(u8, str(s, "url"), "https://auth.openai.com/api/accounts/authorize?client_id=c&redirect_uri="));
    // The relayed graff keeps its no-op opener first on PATH.
    try testing.expect(std.mem.indexOf(u8, rig.read("graff-env-chatgpt-new").?, ".noop-open") != null);
    const id = str(s, "loginId");
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"http://127.0.0.1:{s}/auth/callback?code=abc&state=old\"}}", .{ id, port }), "That sign-in belongs to an older attempt. Sign in again.");
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"http://localhost:{s}/auth/callback?code=abc&state=st4te\"}}", .{ id, port }), "That isn't the address ChatGPT sent you to. Sign in again.");
    const ok = try rig.ok("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\" http://127.0.0.1:{s}/auth/callback?code=abc&state=st4te \"}}", .{ id, port }));
    try testing.expect(ok.object.get("ok").?.bool);
    try testing.expectEqual(@as(u32, 1), srv.hitCount(0));

    // On the host: no URL leaves it; the first sign-in confirms plan usage.
    Io.Dir.cwd().deleteFile(testing.io, go) catch {};
    Io.Dir.cwd().deleteTree(testing.io, try rig.path("home/.graff")) catch {};
    const h = try rig.ok("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"chatgpt-new\"}");
    try testing.expectEqualStrings("host-browser", str(h, "mode"));
    try testing.expectEqualStrings("", str(h, "url"));
    try testing.expect(std.mem.indexOf(u8, rig.read("graff-env-chatgpt-new").?, ".noop-open") == null);
    try rig.write("go-chatgpt", "1");
    const done = try rig.pollDone(str(h, "loginId"));
    try testing.expectEqualStrings("done", str(done, "status"));
    try testing.expectEqualStrings("You're using your ChatGPT plan", str(done, "message"));
}

test "agent_logins: Anthropic Console code goes to graff once; the RPC routes it like Rust" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    test_graff = try rig.script("graff", graff_mock);
    const s = try rig.ok("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"anthropic\"}");
    try testing.expectEqualStrings("paste-code", str(s, "mode"));
    try testing.expectEqualStrings("https://platform.example/oauth/authorize?state=s", str(s, "url"));
    const id = str(s, "loginId");
    // `CompleteAgentLogin` asks complete_relayed_login first, which answers
    // for every graff sign-in (rpc.rs); Rust's complete_login takes the code.
    try rig.failed("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"x\"}}", .{id}), "This sign-in finishes in the execution device's browser.");
    const empty = rig.take(rig.reg.completeLogin(id, "   "));
    try testing.expectEqualStrings("That code looks empty \u{2014} paste the whole code.", empty.text);
    const done = rig.take(rig.reg.completeLogin(id, "  pasted-code#state \n"));
    try testing.expectEqual(std.meta.Tag(al.Reply).ok, done.tag);
    const again = rig.take(rig.reg.completeLogin(id, "again"));
    try testing.expectEqualStrings("This sign-in attempt expired \u{2014} start again.", again.text);
    const p = try rig.pollDone(id);
    try testing.expectEqualStrings("done", str(p, "status"));
}

test "agent_logins: graff's Claude Agent falls back to Harness's Claude sign-in, then records the choice" {
    if (!posix_only) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    const routes = [_]Route{
        .{ .needle = "POST /v1/oauth/token", .body = "{\"access_token\":\"access-ca\",\"refresh_token\":\"refresh-ca\",\"account\":{\"uuid\":\"uuid-ca\",\"email_address\":\"ca@example.invalid\"}}" },
    };
    const srv = try Server.start(testing.io, &routes);
    defer srv.deinit();
    al.claude_token_url = try std.fmt.allocPrint(a, "{s}/v1/oauth/token", .{srv.base(a)});
    test_graff = try rig.script("graff", graff_mock);
    const s = try rig.ok("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"claude-agent\"}");
    try testing.expectEqualStrings("paste-code", str(s, "mode"));
    try testing.expect(std.mem.startsWith(u8, str(s, "url"), "https://claude.ai/oauth/authorize?"));
    const snap = try rig.ok("CompleteAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\",\"code\":\"c#s\"}}", .{str(s, "loginId")}));
    try testing.expectEqualStrings("ca@example.invalid", str(accountsOf(snap)[0], "email"));
    // Signed in now: graff answers at once and the first poll reports it.
    const again = try rig.ok("StartAgentLogin", "{\"harness\":\"graff\",\"provider\":\"claude-agent\"}");
    try testing.expectEqualStrings("browser", str(again, "mode"));
    try testing.expectEqualStrings("done", str(try rig.pollDone(str(again, "loginId")), "status"));
}

// ── keychain, TTL, sweep ───────────────────────────────────────────────────

test "agent_logins: the Keychain is read and written through security, with the file as fallback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    keychain.security_bin = try rig.script("security", try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\case "$1" in
        \\find-generic-password)
        \\  [ -f '{0s}/item' ] || exit 44
        \\  for x in "$@"; do if [ "$x" = -w ]; then [ -f '{0s}/allow' ] || exit 51; cat '{0s}/item'; fi; done
        \\  exit 0 ;;
        \\add-generic-password)
        \\  [ -f '{0s}/allow' ] || {{ echo 'security: Unable to obtain authorization for this operation.' >&2; exit 1; }}
        \\  for x in "$@"; do last="$x"; done; printf '%s' "$last" > '{0s}/item'; echo "$4|$6" > '{0s}/who'; exit 0 ;;
        \\esac
        \\exit 1
        \\
    , .{rig.base}));
    try rig.write("home/.claude.json", "{\"oauthAccount\":{\"accountUuid\":\"uuid-k\",\"emailAddress\":\"k@example.invalid\"}}");
    try rig.write("item", "{\"claudeAiOauth\":{\"accessToken\":\"kc\"}}");
    // Present but denied: shown, not switchable, with the warning.
    const denied = try rig.ok("ListAgentAccounts", "{}");
    const acc = accountsOf(denied)[0];
    try testing.expect(!acc.object.get("switchable").?.bool and acc.object.get("active").?.bool);
    try testing.expect(acc.object.get("savedAt") == null);
    try testing.expectEqualStrings(keychain.denied_warning, str(denied.object.get("warnings").?.array.items[0], "message"));
    // Allowed: the item's login is snapshotted.
    try rig.write("allow", "1");
    const allowed = try rig.ok("ListAgentAccounts", "{}");
    try testing.expect(accountsOf(allowed)[0].object.get("switchable").?.bool);
    // Swapping writes the item in place (no file exists).
    const id = idFor(.claude_code, "uuid-k");
    _ = try rig.ok("ActivateAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"claude-code\",\"accountId\":\"{s}\"}}", .{&id}));
    try testing.expectEqualStrings("fixture-user|Claude Code-credentials\n", rig.read("who").?);
    try testing.expect(!rig.exists("home/.claude/.credentials.json"));
    // Refused with no item: Claude Code's own file fallback, owner-only.
    Io.Dir.cwd().deleteFile(testing.io, try rig.path("allow")) catch {};
    Io.Dir.cwd().deleteFile(testing.io, try rig.path("item")) catch {};
    _ = try rig.ok("ActivateAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"claude-code\",\"accountId\":\"{s}\"}}", .{&id}));
    try testing.expectEqualStrings("{\"claudeAiOauth\":{\"accessToken\":\"kc\"}}", rig.read("home/.claude/.credentials.json").?);
    const st = try Io.Dir.cwd().statFile(testing.io, try rig.path("home/.claude/.credentials.json"), .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
    // Refused while an item exists: the way out, and no shadowed file.
    Io.Dir.cwd().deleteFile(testing.io, try rig.path("home/.claude/.credentials.json")) catch {};
    try rig.write("item", "{\"claudeAiOauth\":{\"accessToken\":\"kc\"}}");
    try rig.write("allow", "1");
    _ = try rig.ok("ListAgentAccounts", "{}");
    Io.Dir.cwd().deleteFile(testing.io, try rig.path("allow")) catch {};
    const o = try rig.call("ActivateAgentAccount", try std.fmt.allocPrint(a, "{{\"harness\":\"claude-code\",\"accountId\":\"{s}\"}}", .{&id}));
    try testing.expectEqual(std.meta.Tag(al.Reply).failed, o.tag);
    try testing.expect(std.mem.indexOf(u8, o.text, "/login") != null);
    try testing.expect(std.mem.indexOf(u8, o.text, "Keychain write failed: security: Unable to obtain authorization for this operation.") != null);
    try testing.expect(!rig.exists("home/.claude/.credentials.json"));
}

test "agent_logins: abandoned flows are reaped past the TTL; boot sweeps throwaway homes" {
    const rig = try Rig.create();
    defer rig.destroy();
    const a = rig.al_();
    const id = str(try rig.ok("StartAgentLogin", "{\"harness\":\"claude-code\"}"), "loginId");
    al.flow_ttl_ms = -1;
    try rig.failed("PollAgentLogin", try std.fmt.allocPrint(a, "{{\"loginId\":\"{s}\"}}", .{id}), "This sign-in attempt expired \u{2014} start again.");
    al.flow_ttl_ms = 15 * 60 * 1000;

    try rig.write("data/agent-accounts/.login-stale/auth.json", "{\"tokens\":{}}");
    try rig.write("data/agent-accounts/codex/keep.json", "{}");
    const again = try al.Registry.initWithConfig(testing.allocator, testing.io, rig.reg.config);
    defer again.deinit();
    try testing.expect(!rig.exists("data/agent-accounts/.login-stale"));
    try testing.expect(rig.exists("data/agent-accounts/codex/keep.json"));
    try testing.expect(rig.reg.handle("SomethingElse", .null) == null);
}
