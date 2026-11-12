//! `CodegraffCancelJob` and `CodegraffGithubRunnerAction`, ported from
//! `crates/engine/src/codegraff_auth.rs` (`cancel_job`, `cancel_error`,
//! `urlencode`), `codegraff_auth/github_runners.rs` (`RunnerAction`,
//! `request_for`, `github_runner_action`, `missing`, `generic_message`) and
//! `codegraff_auth/sandboxes.rs` (`sandbox_call`, `Failure::sentence`), and
//! `crates/engine/src/auth.rs` (`validate_secure_url`).
//!
//! Both call the Codegraff gateway with the signed-in Codegraff key the
//! engine's `AuthManager` holds (its key file, or `CODEGRAFF_API_KEY`).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");

const RpcOutcome = common.RpcOutcome;

const runners_path = "/v1/github/runners";
pub const max_concurrent: i64 = 8;

/// `urlencode`: RFC 3986 unreserved bytes pass, the rest are `%XX`.
pub fn urlencode(gpa: Allocator, segment: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (segment) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') {
            try out.append(gpa, b);
        } else {
            try out.print(gpa, "%{X:0>2}", .{b});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `validate_secure_url`: HTTPS, or plain HTTP to 127.0.0.1 / [::1].
pub fn validateSecureUrl(name: []const u8, raw: []const u8) ?[]const u8 {
    if (auth_host.isSecureUrl(raw)) return null;
    _ = std.Uri.parse(raw) catch return common.errText("{s} URL is invalid", .{name});
    return common.errText("{s} must use HTTPS (plain HTTP is allowed only on loopback)", .{name});
}

/// A gateway message as a sentence: first letter capitalised, one final period.
fn sentenceOf(message: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, message, ".");
    if (trimmed.len == 0) return common.errText(".", .{});
    return common.errText("{c}{s}.", .{ std.ascii.toUpper(trimmed[0]), trimmed[1..] });
}

fn errorMessage(body: ?json.Value) ?[]const u8 {
    const b = body orelse return null;
    if (b != .object) return null;
    const err = b.object.get("error") orelse return null;
    if (err != .object) return null;
    const m = err.object.get("message") orelse return null;
    if (m != .string) return null;
    const t = std.mem.trim(u8, m.string, " \t\r\n");
    return if (t.len == 0) null else t;
}

fn errorType(body: ?json.Value) ?[]const u8 {
    const b = body orelse return null;
    if (b != .object) return null;
    const err = b.object.get("error") orelse return null;
    if (err != .object) return null;
    const t = err.object.get("type") orelse return null;
    return if (t == .string) t.string else null;
}

/// `cancel_error`.
pub fn cancelError(status: u16, body: ?json.Value) []const u8 {
    if (errorMessage(body)) |m| return sentenceOf(m);
    if (status == 409) return "This job is already posting its result or has finished.";
    return common.errText("CodeGraff couldn't cancel the job ({d}).", .{status});
}

/// `sandboxes::Failure`.
pub const Failure = struct {
    status: u16,
    body: ?json.Value = null,
    message: ?[]const u8 = null,

    /// `Failure::sentence`.
    pub fn sentence(self: Failure, fallback: []const u8) []const u8 {
        if (errorType(self.body)) |t| {
            if (std.mem.eql(u8, t, "insufficient_credits")) return "Your Codegraff credit is used up. Add credit and try again.";
            if (std.mem.eql(u8, t, "sandbox_not_running")) return "The sandbox isn't running. Start it first.";
            if (std.mem.eql(u8, t, "insufficient_scope")) return "This Codegraff sign-in can't manage sandboxes. Sign in again.";
            if (std.mem.eql(u8, t, "harness_cloud_unavailable")) return "Harness cloud isn't available yet. Try again later.";
        }
        const message: ?[]const u8 = if (self.message) |m| blk: {
            const t = std.mem.trim(u8, m, " \t\r\n");
            break :blk if (t.len == 0) null else t;
        } else errorMessage(self.body);
        if (message) |m| return sentenceOf(m);
        if (self.status == 0) return common.errText("{s}.", .{fallback});
        return common.errText("{s} ({d}).", .{ fallback, self.status });
    }
};

/// `missing`: a gateway without the runner routes.
pub fn missingRoute(status: u16) bool {
    return status == 404 or status == 501;
}

/// `generic_message`: a 404 that says no more than "not found".
pub fn genericMessage(body: ?json.Value) bool {
    const b = body orelse return true;
    const v: ?json.Value = blk: {
        if (b != .object) break :blk null;
        if (b.object.get("error")) |e| {
            if (e == .object) {
                if (e.object.get("message")) |m| break :blk m;
            } else break :blk e;
        }
        break :blk b.object.get("message");
    };
    const m = v orelse return true;
    if (m != .string) return true;
    var buf: [64]u8 = undefined;
    const t = std.mem.trimEnd(u8, std.mem.trim(u8, m.string, " \t\r\n"), ".");
    if (t.len == 0) return true;
    if (t.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, t);
    return std.mem.eql(u8, lower, "not found") or std.mem.eql(u8, lower, "not_found") or std.mem.eql(u8, lower, "404 not found");
}

const Reply = struct { status: u16, body: []u8 };

/// One gateway request; a transport failure is `couldn't reach CodeGraff: …`.
fn gatewayRequest(host: *engine_host.EngineHost, io: std.Io, method: []const u8, url: []const u8, key: []const u8, body: ?[]const u8) union(enum) { ok: Reply, unreachable_: []const u8 } {
    const r = auth_host.AuthManager.edgeRequestPooled(&host.auth.h2_pool, host.gpa, io, method, url, key, &.{}, body) catch |e|
        return .{ .unreachable_ = common.errText("couldn't reach CodeGraff: {s}", .{@errorName(e)}) };
    return .{ .ok = .{ .status = r.status, .body = r.body } };
}

/// `CodegraffCancelJob { id }` → `{"ok":true}`.
pub fn cancelJob(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const id = if (common.obj(params)) |o| common.str(o, "id") else null;
    const job = id orelse return common.failed("missing job id", .{});
    const key = host.auth.codegraff_api_key orelse return common.failed("Sign in with Codegraff first", .{});
    if (validateSecureUrl("CodeGraff gateway", host.auth.codegraff_gateway)) |m| return .{ .err = .{ .exec_error = m } };
    const io = host.io orelse return common.failed("couldn't reach CodeGraff: no I/O", .{});
    const enc = try urlencode(gpa, job);
    defer gpa.free(enc);
    const url = try std.fmt.allocPrint(gpa, "{s}/v1/jobs/{s}/cancel", .{ host.auth.codegraff_gateway, enc });
    defer gpa.free(url);
    const reply = switch (gatewayRequest(host, io, "POST", url, key, null)) {
        .unreachable_ => |m| return .{ .err = .{ .exec_error = m } },
        .ok => |r| r,
    };
    defer gpa.free(reply.body);
    if (reply.status >= 200 and reply.status < 300) return .{ .unary_json = try gpa.dupe(u8, "{\"ok\":true}") };
    var parsed = json.parseFromSlice(json.Value, gpa, reply.body, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    return common.failedMsg(cancelError(reply.status, if (parsed) |p| p.value else null));
}

// ── GitHub CI runner actions ───────────────────────────────────────────────

pub const RunnerAction = union(enum) {
    installation: struct { installation_id: []const u8, monthly: ?i64, untrusted: ?i64, max_concurrent: ?i64 },
    repo: struct { installation_id: []const u8, full_name: []const u8, enabled: ?bool, default_size: ?[]const u8 },
    disconnect: struct { installation_id: []const u8 },
};

const Parse = union(enum) { ok: RunnerAction, bad: []const u8 };

/// `id_text`: trimmed text, a number's digits, anything else empty.
fn idText(gpa: Allocator, v: json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| std.mem.trim(u8, s, " \t\r\n"),
        .integer => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
        .number_string => |s| s,
        .float => |f| try std.fmt.allocPrint(gpa, "{d}", .{f}),
        else => "",
    };
}

fn optInt(o: json.ObjectMap, key: []const u8) union(enum) { ok: ?i64, bad } {
    const v = o.get(key) orelse return .{ .ok = null };
    return switch (v) {
        .null => .{ .ok = null },
        .integer => |i| .{ .ok = i },
        else => .bad,
    };
}

/// `serde_json::from_value::<RunnerAction>` (internally tagged by `action`).
/// `arena` owns any text made for numeric ids.
pub fn parseRunnerAction(arena: Allocator, params: json.Value) !Parse {
    const o = common.obj(params) orelse return .{ .bad = "invalid type: expected internally tagged enum RunnerAction" };
    const tag_v = o.get("action") orelse return .{ .bad = "missing field `action`" };
    if (tag_v != .string) return .{ .bad = "invalid type: expected a variant name for `action`" };
    const tag = tag_v.string;
    const id_v = o.get("installationId");
    if (std.mem.eql(u8, tag, "installation")) {
        const id = try idText(arena, id_v orelse return .{ .bad = "missing field `installationId`" });
        const monthly = switch (optInt(o, "monthlyBudgetMicroUsd")) {
            .ok => |x| x,
            .bad => return .{ .bad = "invalid type: expected i64 for `monthlyBudgetMicroUsd`" },
        };
        const untrusted = switch (optInt(o, "untrustedBudgetMicroUsd")) {
            .ok => |x| x,
            .bad => return .{ .bad = "invalid type: expected i64 for `untrustedBudgetMicroUsd`" },
        };
        const maxc = switch (optInt(o, "maxConcurrent")) {
            .ok => |x| x,
            .bad => return .{ .bad = "invalid type: expected u32 for `maxConcurrent`" },
        };
        if (maxc) |m| if (m < 0 or m > std.math.maxInt(u32)) return .{ .bad = "invalid value: expected u32 for `maxConcurrent`" };
        return .{ .ok = .{ .installation = .{ .installation_id = id, .monthly = monthly, .untrusted = untrusted, .max_concurrent = maxc } } };
    } else if (std.mem.eql(u8, tag, "repo")) {
        const id = try idText(arena, id_v orelse return .{ .bad = "missing field `installationId`" });
        const name_v = o.get("fullName") orelse return .{ .bad = "missing field `fullName`" };
        if (name_v != .string) return .{ .bad = "invalid type: expected a string for `fullName`" };
        const enabled: ?bool = if (o.get("enabled")) |e| switch (e) {
            .bool => |b| b,
            .null => null,
            else => return .{ .bad = "invalid type: expected a boolean for `enabled`" },
        } else null;
        const size: ?[]const u8 = if (o.get("defaultSize")) |s| switch (s) {
            .string => |t| t,
            .null => null,
            else => return .{ .bad = "invalid type: expected a string for `defaultSize`" },
        } else null;
        return .{ .ok = .{ .repo = .{ .installation_id = id, .full_name = name_v.string, .enabled = enabled, .default_size = size } } };
    } else if (std.mem.eql(u8, tag, "disconnect")) {
        const id = try idText(arena, id_v orelse return .{ .bad = "missing field `installationId`" });
        return .{ .ok = .{ .disconnect = .{ .installation_id = id } } };
    }
    return .{ .bad = common.errText("unknown variant `{s}`, expected one of `installation`, `repo`, `disconnect`", .{tag}) };
}

pub const Request = struct { method: []const u8, path: []const u8, body: ?[]const u8 };

/// `request_for`: the method, path and JSON body for an action, or why it
/// can't be sent. Pure.
pub fn requestFor(arena: Allocator, action: RunnerAction) !union(enum) { ok: Request, refused: []const u8 } {
    const id = switch (action) {
        inline else => |a| a.installation_id,
    };
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return .{ .refused = "Pick a GitHub installation first." };
    const installation = try std.fmt.allocPrint(arena, runners_path ++ "/installations/{s}", .{try urlencode(arena, id)});
    switch (action) {
        .installation => |a| {
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            var fields: usize = 0;
            try w.writeByte('{');
            inline for (.{ .{ "monthlyBudgetMicroUsd", a.monthly }, .{ "untrustedBudgetMicroUsd", a.untrusted } }) |pair| {
                if (pair[1]) |amount| {
                    if (amount < 0) return .{ .refused = "A budget can't be negative." };
                    if (fields > 0) try w.writeByte(',');
                    try w.print("\"" ++ pair[0] ++ "\":{d}", .{amount});
                    fields += 1;
                }
            }
            if (a.max_concurrent) |m| {
                if (m < 1 or m > max_concurrent) return .{ .refused = common.errText("Concurrent jobs must be between 1 and {d}.", .{max_concurrent}) };
                if (fields > 0) try w.writeByte(',');
                try w.print("\"maxConcurrent\":{d}", .{m});
                fields += 1;
            }
            if (fields == 0) return .{ .refused = "Nothing to change." };
            try w.writeByte('}');
            return .{ .ok = .{ .method = "PATCH", .path = installation, .body = aw.written() } };
        },
        .repo => |a| {
            const full_name = std.mem.trim(u8, a.full_name, " \t\r\n");
            if (full_name.len == 0) return .{ .refused = "Pick a repository first." };
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.print("{{\"fullName\":{f}", .{json.fmt(full_name, .{})});
            var fields: usize = 1;
            if (a.enabled) |e| {
                try w.print(",\"enabled\":{}", .{e});
                fields += 1;
            }
            if (a.default_size) |raw| {
                const size = std.mem.trim(u8, raw, " \t\r\n");
                if (size.len == 0) return .{ .refused = "Pick a size." };
                try w.print(",\"defaultSize\":{f}", .{json.fmt(size, .{})});
                fields += 1;
            }
            if (fields == 1) return .{ .refused = "Nothing to change." };
            try w.writeByte('}');
            return .{ .ok = .{ .method = "PATCH", .path = try std.fmt.allocPrint(arena, "{s}/repos", .{installation}), .body = aw.written() } };
        },
        .disconnect => return .{ .ok = .{ .method = "DELETE", .path = installation, .body = null } },
    }
}

/// `CodegraffGithubRunnerAction { action, installationId, … }` → `{"ok":true}`.
pub fn githubRunnerAction(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const action = switch (try parseRunnerAction(arena, params)) {
        .bad => |m| return common.failed("bad GitHub CI action: {s}", .{m}),
        .ok => |a| a,
    };
    const req = switch (try requestFor(arena, action)) {
        .refused => |m| return .{ .err = .{ .exec_error = m } },
        .ok => |r| r,
    };
    const fallback: []const u8 = switch (action) {
        .installation => "CodeGraff couldn't save the GitHub CI settings",
        .repo => "CodeGraff couldn't change the repository",
        .disconnect => "CodeGraff couldn't disconnect GitHub",
    };
    // `sandbox_call`: local failures (no key, insecure gateway, no network)
    // are status 0 with their own message.
    const key = host.auth.codegraff_api_key orelse
        return common.failedMsg((Failure{ .status = 0, .message = "Sign in with Codegraff first" }).sentence(fallback));
    if (validateSecureUrl("CodeGraff gateway", host.auth.codegraff_gateway)) |m| {
        const owned = try arena.dupe(u8, m);
        return common.failedMsg((Failure{ .status = 0, .message = owned }).sentence(fallback));
    }
    const io = host.io orelse return common.failedMsg((Failure{ .status = 0, .message = "couldn't reach CodeGraff: no I/O" }).sentence(fallback));
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ host.auth.codegraff_gateway, req.path });
    const reply = switch (gatewayRequest(host, io, req.method, url, key, req.body)) {
        .unreachable_ => |m| {
            const owned = try arena.dupe(u8, m);
            return common.failedMsg((Failure{ .status = 0, .message = owned }).sentence(fallback));
        },
        .ok => |r| r,
    };
    defer gpa.free(reply.body);
    if (reply.status >= 200 and reply.status < 300) return .{ .unary_json = try gpa.dupe(u8, "{\"ok\":true}") };
    const body: ?json.Value = json.parseFromSliceLeaky(json.Value, arena, reply.body, .{}) catch null;
    if (missingRoute(reply.status) and genericMessage(body)) return common.failed("GitHub CI isn't available on Codegraff yet.", .{});
    return common.failedMsg((Failure{ .status = reply.status, .body = body }).sentence(fallback));
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const net = std.Io.net;

/// A loopback HTTP/1.1 gateway that answers every request with `status` and
/// `body`, recording the request line, auth header and body of the last one.
const FakeGateway = struct {
    server: net.Server,
    port: u16,
    status: u16 = 200,
    body: []const u8 = "{}",
    stop: std.atomic.Value(bool) = .init(false),
    last: [2048]u8 = undefined,
    last_len: usize = 0,
    thread: ?std.Thread = null,

    fn start(self: *FakeGateway) !void {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        self.server = try addr.listen(testing.io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    fn loop(self: *FakeGateway) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.server.accept(testing.io) catch return;
            defer stream.close(testing.io);
            if (self.stop.load(.acquire)) return;
            var rbuf: [4096]u8 = undefined;
            var reader = stream.reader(testing.io, &rbuf);
            var n: usize = 0;
            var content_len: usize = 0;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch break;
                const t = std.mem.trimEnd(u8, line, "\r\n");
                if (n + t.len + 1 < self.last.len and (n == 0 or std.ascii.startsWithIgnoreCase(t, "authorization:"))) {
                    @memcpy(self.last[n .. n + t.len], t);
                    self.last[n + t.len] = '\n';
                    n += t.len + 1;
                }
                if (std.ascii.startsWithIgnoreCase(t, "content-length:")) {
                    content_len = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " "), 10) catch 0;
                }
                if (t.len == 0) break;
            }
            if (content_len > 0 and n + content_len < self.last.len) {
                reader.interface.readSliceAll(self.last[n .. n + content_len]) catch {};
                n += content_len;
            }
            self.last_len = n;
            var wbuf: [1024]u8 = undefined;
            var w = stream.writer(testing.io, &wbuf);
            w.interface.print("HTTP/1.1 {d} X\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.status, self.body.len, self.body }) catch {};
            w.interface.flush() catch {};
        }
    }

    fn shutdown(self: *FakeGateway) void {
        self.stop.store(true, .release);
        if (net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
            if (addr.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }

    fn lastRequest(self: *FakeGateway) []const u8 {
        return self.last[0..self.last_len];
    }
};

const Fx = struct {
    host: engine_host.EngineHost,
    gw: FakeGateway = undefined,

    fn init(signed_in: bool) !*Fx {
        const gpa = testing.allocator;
        const f = try gpa.create(Fx);
        f.* = .{ .host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic") };
        f.host.io = testing.io;
        f.gw = .{ .server = undefined, .port = 0 };
        try f.gw.start();
        gpa.free(f.host.auth.codegraff_gateway);
        f.host.auth.codegraff_gateway = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{f.gw.port});
        if (signed_in) {
            if (f.host.auth.codegraff_api_key) |k| gpa.free(k);
            f.host.auth.codegraff_api_key = try gpa.dupe(u8, "cg-synthetic-key");
        }
        return f;
    }

    fn deinit(f: *Fx) void {
        f.gw.shutdown();
        f.host.deinit();
        testing.allocator.destroy(f);
    }

    fn call(f: *Fx, method: []const u8, params_text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        return f.host.handle(method, p.value);
    }
};

fn expectFailed(outcome: RpcOutcome, expected: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .exec_error => |m| try testing.expectEqualStrings(expected, m),
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

test "rpcw_codegraff CodegraffCancelJob posts the cancel and words the gateway's refusals" {
    const f = try Fx.init(true);
    defer f.deinit();
    const ok = try f.call("CodegraffCancelJob", "{\"id\":\"job 7/a\"}");
    defer testing.allocator.free(ok.unary_json);
    try testing.expectEqualStrings("{\"ok\":true}", ok.unary_json);
    try testing.expect(std.mem.startsWith(u8, f.gw.lastRequest(), "POST /v1/jobs/job%207%2Fa/cancel HTTP/1.1\n"));
    try testing.expect(std.mem.indexOf(u8, f.gw.lastRequest(), "Bearer cg-synthetic-key") != null);

    f.gw.status = 409;
    f.gw.body = "{}";
    try expectFailed(try f.call("CodegraffCancelJob", "{\"id\":\"j1\"}"), "This job is already posting its result or has finished.");
    f.gw.status = 404;
    f.gw.body = "{\"error\":{\"message\":\"job not found.\"}}";
    try expectFailed(try f.call("CodegraffCancelJob", "{\"id\":\"j1\"}"), "Job not found.");
    f.gw.status = 500;
    f.gw.body = "oops";
    try expectFailed(try f.call("CodegraffCancelJob", "{\"id\":\"j1\"}"), "CodeGraff couldn't cancel the job (500).");
    try expectFailed(try f.call("CodegraffCancelJob", "{}"), "missing job id");
}

test "rpcw_codegraff CodegraffCancelJob needs a sign-in and a secure gateway" {
    const f = try Fx.init(false);
    defer f.deinit();
    if (f.host.auth.codegraff_api_key == null) {
        try expectFailed(try f.call("CodegraffCancelJob", "{\"id\":\"j1\"}"), "Sign in with Codegraff first");
    }
    f.host.auth.codegraff_api_key = try testing.allocator.dupe(u8, "cg-synthetic-key");
    testing.allocator.free(f.host.auth.codegraff_gateway);
    f.host.auth.codegraff_gateway = try testing.allocator.dupe(u8, "http://gateway.example.invalid");
    try expectFailed(try f.call("CodegraffCancelJob", "{\"id\":\"j1\"}"), "CodeGraff gateway must use HTTPS (plain HTTP is allowed only on loopback)");
}

test "rpcw_codegraff runner actions build request_for's requests and refusals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { params: []const u8, method: []const u8, path: []const u8, body: ?[]const u8 };
    const cases = [_]Case{
        .{ .params = "{\"action\":\"installation\",\"installationId\":42,\"monthlyBudgetMicroUsd\":5000000,\"maxConcurrent\":3}", .method = "PATCH", .path = "/v1/github/runners/installations/42", .body = "{\"monthlyBudgetMicroUsd\":5000000,\"maxConcurrent\":3}" },
        .{ .params = "{\"action\":\"repo\",\"installationId\":\" 42 \",\"fullName\":\" octo/app \",\"enabled\":false,\"defaultSize\":\"large\"}", .method = "PATCH", .path = "/v1/github/runners/installations/42/repos", .body = "{\"fullName\":\"octo/app\",\"enabled\":false,\"defaultSize\":\"large\"}" },
        .{ .params = "{\"action\":\"disconnect\",\"installationId\":\"in/1\"}", .method = "DELETE", .path = "/v1/github/runners/installations/in%2F1", .body = null },
    };
    for (cases) |c| {
        const v = try json.parseFromSliceLeaky(json.Value, a, c.params, .{});
        const action = (try parseRunnerAction(a, v)).ok;
        const req = (try requestFor(a, action)).ok;
        try testing.expectEqualStrings(c.method, req.method);
        try testing.expectEqualStrings(c.path, req.path);
        if (c.body) |b| try testing.expectEqualStrings(b, req.body.?) else try testing.expect(req.body == null);
    }
    const refusals = [_][2][]const u8{
        .{ "{\"action\":\"installation\",\"installationId\":\" \",\"maxConcurrent\":2}", "Pick a GitHub installation first." },
        .{ "{\"action\":\"installation\",\"installationId\":\"1\"}", "Nothing to change." },
        .{ "{\"action\":\"installation\",\"installationId\":\"1\",\"untrustedBudgetMicroUsd\":-1}", "A budget can't be negative." },
        .{ "{\"action\":\"installation\",\"installationId\":\"1\",\"maxConcurrent\":9}", "Concurrent jobs must be between 1 and 8." },
        .{ "{\"action\":\"repo\",\"installationId\":\"1\",\"fullName\":\" \"}", "Pick a repository first." },
        .{ "{\"action\":\"repo\",\"installationId\":\"1\",\"fullName\":\"o/r\"}", "Nothing to change." },
        .{ "{\"action\":\"repo\",\"installationId\":\"1\",\"fullName\":\"o/r\",\"defaultSize\":\"\"}", "Pick a size." },
        .{ "{\"action\":\"disconnect\",\"installationId\":true}", "Pick a GitHub installation first." },
    };
    for (refusals) |r| {
        const v = try json.parseFromSliceLeaky(json.Value, a, r[0], .{});
        const action = (try parseRunnerAction(a, v)).ok;
        try testing.expectEqualStrings(r[1], (try requestFor(a, action)).refused);
    }
    try testing.expect(genericMessage(null));
    try testing.expect(genericMessage(try json.parseFromSliceLeaky(json.Value, a, "{\"error\":\"Not Found.\"}", .{})));
    try testing.expect(!genericMessage(try json.parseFromSliceLeaky(json.Value, a, "{\"error\":{\"message\":\"installation 42 is gone\"}}", .{})));
}

test "rpcw_codegraff CodegraffGithubRunnerAction sends the change and words failures like sandbox_call" {
    const f = try Fx.init(true);
    defer f.deinit();
    const ok = try f.call("CodegraffGithubRunnerAction", "{\"action\":\"repo\",\"installationId\":7,\"fullName\":\"octo/app\",\"enabled\":true}");
    defer testing.allocator.free(ok.unary_json);
    try testing.expectEqualStrings("{\"ok\":true}", ok.unary_json);
    const last = f.gw.lastRequest();
    try testing.expect(std.mem.startsWith(u8, last, "PATCH /v1/github/runners/installations/7/repos HTTP/1.1\n"));
    try testing.expect(std.mem.endsWith(u8, last, "{\"fullName\":\"octo/app\",\"enabled\":true}"));

    f.gw.status = 404;
    f.gw.body = "{\"error\":{\"message\":\"Not found\"}}";
    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"action\":\"disconnect\",\"installationId\":\"7\"}"), "GitHub CI isn't available on Codegraff yet.");
    f.gw.body = "{\"error\":{\"message\":\"installation 7 is gone\"}}";
    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"action\":\"disconnect\",\"installationId\":\"7\"}"), "Installation 7 is gone.");
    f.gw.status = 402;
    f.gw.body = "{\"error\":{\"type\":\"insufficient_credits\",\"message\":\"x\"}}";
    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"action\":\"installation\",\"installationId\":\"7\",\"maxConcurrent\":2}"), "Your Codegraff credit is used up. Add credit and try again.");
    f.gw.status = 500;
    f.gw.body = "";
    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"action\":\"installation\",\"installationId\":\"7\",\"maxConcurrent\":2}"), "CodeGraff couldn't save the GitHub CI settings (500).");

    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"installationId\":\"7\"}"), "bad GitHub CI action: missing field `action`");
    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"action\":\"pause\",\"installationId\":\"7\"}"), "bad GitHub CI action: unknown variant `pause`, expected one of `installation`, `repo`, `disconnect`");
    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"action\":\"repo\",\"installationId\":\"7\"}"), "bad GitHub CI action: missing field `fullName`");

    testing.allocator.free(f.host.auth.codegraff_api_key.?);
    f.host.auth.codegraff_api_key = null;
    try expectFailed(try f.call("CodegraffGithubRunnerAction", "{\"action\":\"disconnect\",\"installationId\":\"7\"}"), "Sign in with Codegraff first.");
}
