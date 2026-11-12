//! `McpServerAction` (and the `ListMcpServers` listing it shares), ported from
//! `crates/engine/src/mcp_servers.rs` and
//! `crates/harness/src/acp/graff_mcp.rs`: `graff mcp status|reconnect|enable|
//! disable|login [names…] --json`, run with graff's home and in the project
//! folder whose `.mcp.json` counts, its rows re-emitted as `McpServerRow`s.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const exes = @import("rpcw_executables.zig");
const engine_host = @import("engine_host.zig");

const RpcOutcome = common.RpcOutcome;

pub const Verb = enum {
    reconnect,
    enable,
    disable,
    login,

    pub fn parse(text: []const u8) ?Verb {
        return std.meta.stringToEnum(Verb, text);
    }
};

const status_timeout_ms: i64 = 60_000;
const reconnect_timeout_ms: i64 = 150_000;
const login_timeout_ms: i64 = 300_000;

const Run = union(enum) { ok: []u8, failed: []const u8 };

fn validName(name: []const u8) bool {
    return name.len > 0 and name[0] != '-';
}

/// `mcp_servers::run`: graff's stdout, or its last error line.
fn runGraffMcp(gpa: Allocator, io: std.Io, home: []const u8, verb: []const u8, names: []const []const u8, cwd: ?[]const u8, timeout_ms: i64) !Run {
    for (names) |n| if (!validName(n)) {
        return .{ .failed = common.errText("Could not resolve the graff CLI: harness protocol error: not an MCP server name: \"{s}\"", .{n}) };
    };
    const program = (try exes.resolveCli(gpa, io, .graff)) orelse
        return .{ .failed = "The `graff` CLI was not found on this device — install it first." };
    defer gpa.free(program);
    // graff finds its MCP config, caches and sign-ins from HOME
    // (`common.graffHome`, as sign-out uses).
    const home_arg = try std.fmt.allocPrint(gpa, "HOME={s}", .{home});
    defer gpa.free(home_arg);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "/usr/bin/env", "NO_COLOR=1", home_arg, program, "mcp", verb });
    if (std.mem.eql(u8, verb, "reconnect") and names.len == 0) try argv.append(gpa, "--all");
    try argv.appendSlice(gpa, names);
    // `login` is interactive (it opens the sign-in page); the rest answer JSON.
    if (!std.mem.eql(u8, verb, "login")) try argv.append(gpa, "--json");
    const dir: ?[]const u8 = if (cwd) |c| (if (common.isDir(io, c)) c else null) else null;

    var res = common.run(gpa, io, argv.items, dir, timeout_ms) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimedOut => return .{ .failed = common.errText("graff mcp {s} did not finish in time.", .{verb}) },
        else => return .{ .failed = common.errText("Could not run graff mcp {s}: {s}", .{ verb, @errorName(e) }) },
    };
    defer gpa.free(res.stderr);
    if (!res.success()) {
        defer gpa.free(res.stdout);
        return .{ .failed = common.errText("{s}", .{lastErrorLine(res.stderr, res.stdout)}) };
    }
    return .{ .ok = res.stdout };
}

/// `stderr.lines().chain(stdout.lines()).rev().find(non-empty)`.
pub fn lastErrorLine(stderr: []const u8, stdout: []const u8) []const u8 {
    for ([_][]const u8{ stdout, stderr }) |text| {
        var end = text.len;
        while (end > 0) {
            const start = if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |i| i + 1 else 0;
            const line = std.mem.trim(u8, text[start..end], " \t\r");
            if (line.len > 0) return line;
            if (start == 0) break;
            end = start - 1;
        }
    }
    return "graff exited with an error";
}

const old_graff = "This graff can't list MCP servers yet. Update graff to manage them here.";

/// `mcp_servers::parse`: the first JSON line's `servers`, as `McpServerRow`s.
pub fn rowsJson(gpa: Allocator, stdout: []const u8) !union(enum) { ok: []u8, failed: []const u8 } {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    const line = while (lines.next()) |l| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, l, " \t"), "{")) break l;
    } else return .{ .failed = old_graff };
    var parsed = json.parseFromSlice(json.Value, gpa, line, .{}) catch return .{ .failed = old_graff };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failed = old_graff };
    const servers = parsed.value.object.get("servers") orelse return .{ .failed = old_graff };
    if (servers != .array) return .{ .failed = old_graff };
    // Validate every row first: one malformed row fails the whole list.
    for (servers.array.items) |row| {
        if (row != .object) return .{ .failed = old_graff };
        const name = row.object.get("name") orelse return .{ .failed = old_graff };
        if (name != .string) return .{ .failed = old_graff };
        const state = row.object.get("state") orelse return .{ .failed = old_graff };
        if (state != .string) return .{ .failed = old_graff };
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    for (servers.array.items, 0..) |row, i| {
        if (i > 0) try w.writeByte(',');
        const o = row.object;
        try w.print("{{\"name\":{f},\"source\":{f},\"transport\":{f},\"origin\":{f},\"enabled\":{},\"state\":\"{s}\"", .{
            json.fmt(o.get("name").?.string, .{}),
            json.fmt(strOr(o, "source"), .{}),
            json.fmt(strOr(o, "transport"), .{}),
            json.fmt(strOr(o, "origin"), .{}),
            if (o.get("enabled")) |e| (e != .bool or e.bool) else true,
            knownState(o.get("state").?.string),
        });
        inline for (.{ "error", "errorCode", "detail" }) |key| {
            if (o.get(key)) |v| if (v == .string) try w.print(",\"" ++ key ++ "\":{f}", .{json.fmt(v.string, .{})});
        }
        const tool_count: i64 = if (o.get("toolCount")) |t| (if (t == .integer and t.integer >= 0) t.integer else 0) else 0;
        try w.print(",\"auth\":{f},\"toolCount\":{d},\"tools\":[", .{ json.fmt(strOr(o, "auth"), .{}), tool_count });
        if (o.get("tools")) |tools| if (tools == .array) {
            var n: usize = 0;
            for (tools.array.items) |t| {
                if (t != .object) continue;
                const tname = t.object.get("name") orelse continue;
                if (tname != .string) continue;
                if (n > 0) try w.writeByte(',');
                try w.print("{{\"name\":{f},\"description\":{f}}}", .{ json.fmt(tname.string, .{}), json.fmt(strOr(t.object, "description"), .{}) });
                n += 1;
            }
        };
        try w.writeAll("]}");
    }
    try w.writeByte(']');
    return .{ .ok = try aw.toOwnedSlice() };
}

fn strOr(o: json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// `McpServerState` with `#[serde(other)] Unknown`.
fn knownState(s: []const u8) []const u8 {
    const states = [_][]const u8{ "ready", "on_demand", "connecting", "failed", "needs_login", "off", "opt_in", "not_started" };
    for (states) |k| if (std.mem.eql(u8, s, k)) return k;
    return "unknown";
}

fn listWith(gpa: Allocator, io: std.Io, home: []const u8, cwd: ?[]const u8, names: []const []const u8) !RpcOutcome {
    const out = switch (try runGraffMcp(gpa, io, home, "status", names, cwd, status_timeout_ms)) {
        .failed => |m| return .{ .err = .{ .exec_error = m } },
        .ok => |o| o,
    };
    defer gpa.free(out);
    return switch (try rowsJson(gpa, out)) {
        .ok => |rows| .{ .unary_json = rows },
        .failed => |m| .{ .err = .{ .exec_error = m } },
    };
}

fn optString(o: json.ObjectMap, key: []const u8) union(enum) { ok: ?[]const u8, wrong } {
    const v = o.get(key) orelse return .{ .ok = null };
    return switch (v) {
        .string => |s| .{ .ok = s },
        .null => .{ .ok = null },
        else => .wrong,
    };
}

/// `ListMcpServers { cwd?, names? }` → every configured server.
pub fn listMcpServers(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct ListMcpServersParams", .{});
    const cwd = switch (optString(o, "cwd")) {
        .ok => |c| c,
        .wrong => return common.badParams("invalid type: expected a string for `cwd`", .{}),
    };
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    if (o.get("names")) |v| {
        if (v != .array) return common.badParams("invalid type: expected a sequence for `names`", .{});
        for (v.array.items) |n| {
            if (n != .string) return common.badParams("invalid type: expected a string in `names`", .{});
            try names.append(gpa, n.string);
        }
    }
    const io = host.io orelse return common.failed("Could not run graff mcp status: no I/O", .{});
    return listWith(gpa, io, common.graffHome(host), cwd, names.items);
}

/// `McpServerAction { action, name?, cwd? }` → the affected rows.
pub fn mcpServerAction(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct McpServerActionParams", .{});
    const action_v = o.get("action") orelse return common.badParams("missing field `action`", .{});
    if (action_v != .string) return common.badParams("invalid type: expected an MCP server verb for `action`", .{});
    const verb = Verb.parse(action_v.string) orelse
        return common.badParams("unknown variant `{s}`, expected one of `reconnect`, `enable`, `disable`, `login`", .{action_v.string});
    const cwd = switch (optString(o, "cwd")) {
        .ok => |c| c,
        .wrong => return common.badParams("invalid type: expected a string for `cwd`", .{}),
    };
    const name = switch (optString(o, "name")) {
        .ok => |n| n,
        .wrong => return common.badParams("invalid type: expected a string for `name`", .{}),
    };
    if (name == null and verb != .reconnect) return common.failed("Say which MCP server to {s}.", .{@tagName(verb)});
    const io = host.io orelse return common.failed("Could not run graff mcp {s}: no I/O", .{@tagName(verb)});
    const names: []const []const u8 = if (name) |n| &.{n} else &.{};
    const home = common.graffHome(host);
    switch (verb) {
        .login => {
            const out = switch (try runGraffMcp(gpa, io, home, "login", names, cwd, login_timeout_ms)) {
                .failed => |m| return .{ .err = .{ .exec_error = m } },
                .ok => |x| x,
            };
            gpa.free(out);
            return listWith(gpa, io, home, cwd, names);
        },
        .reconnect, .enable, .disable => {
            const timeout = if (verb == .reconnect) reconnect_timeout_ms else status_timeout_ms;
            const out = switch (try runGraffMcp(gpa, io, home, @tagName(verb), names, cwd, timeout)) {
                .failed => |m| return .{ .err = .{ .exec_error = m } },
                .ok => |x| x,
            };
            defer gpa.free(out);
            return switch (try rowsJson(gpa, out)) {
                .ok => |rows| .{ .unary_json = rows },
                .failed => |m| .{ .err = .{ .exec_error = m } },
            };
        },
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const fake_graff =
    \\#!/bin/sh
    \\# Synthetic graff: records its arguments and answers like `graff mcp`.
    \\echo "$PWD|$NO_COLOR|$*" >> "$HOME/calls.log"
    \\case "$2" in
    \\  login) echo "Opening the sign-in page"; exit 0 ;;
    \\esac
    \\case "$3" in
    \\  broken) echo "server broken is not configured" >&2; exit 2 ;;
    \\  old) echo "usage:"; echo "  graff mcp install"; exit 0 ;;
    \\esac
    \\echo "note: synthetic"
    \\echo '{"version":1,"servers":[{"name":"alpha","source":"project","transport":"stdio","origin":"alpha","enabled":true,"state":"on_demand","auth":"none","toolCount":1,"tools":[{"name":"search","description":"Find."}],"extra":1},{"name":"beta","state":"brand_new","error":"exited","errorCode":"WriteFailed"}]}'
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
        const bin = try std.fs.path.join(gpa, &.{ f.base, "bin" });
        defer gpa.free(bin);
        const path = try std.fmt.allocPrint(gpa, "{s}:/usr/bin:/bin", .{bin});
        defer gpa.free(path);
        try f.env.map.put("PATH", path);
        try f.tmp.dir.createDirPath(io, "bin");
        try f.tmp.dir.createDirPath(io, "project");
        if (with_graff) try f.tmp.dir.writeFile(io, .{ .sub_path = "bin/graff", .data = fake_graff, .flags = .{ .permissions = .executable_file } });
        f.env.install();
        exes.system_prefix = f.base;
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = io;
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

    fn call(f: *Fx, method: []const u8, params_text: []const u8) !RpcOutcome {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        return f.host.handle(method, p.value);
    }

    fn calls(f: *Fx) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, "calls.log", testing.allocator, .limited(1 << 16));
    }
};

fn expectErr(outcome: RpcOutcome, bad: bool, expected: []const u8) !void {
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

test "rpcw_mcp McpServerAction runs graff mcp and returns its rows" {
    const f = try Fx.init(true);
    defer f.deinit();
    const gpa = testing.allocator;
    const project = try std.fs.path.join(gpa, &.{ f.base, "project" });
    defer gpa.free(project);

    const params = try std.fmt.allocPrint(gpa, "{{\"action\":\"enable\",\"name\":\"alpha\",\"cwd\":{f}}}", .{json.fmt(project, .{})});
    defer gpa.free(params);
    const out = try f.call("McpServerAction", params);
    defer gpa.free(out.unary_json);
    try testing.expectEqualStrings(
        "[{\"name\":\"alpha\",\"source\":\"project\",\"transport\":\"stdio\",\"origin\":\"alpha\",\"enabled\":true,\"state\":\"on_demand\",\"auth\":\"none\",\"toolCount\":1,\"tools\":[{\"name\":\"search\",\"description\":\"Find.\"}]}," ++
            "{\"name\":\"beta\",\"source\":\"\",\"transport\":\"\",\"origin\":\"\",\"enabled\":true,\"state\":\"unknown\",\"error\":\"exited\",\"errorCode\":\"WriteFailed\",\"auth\":\"\",\"toolCount\":0,\"tools\":[]}]",
        out.unary_json,
    );

    // Reconnect without a name checks every switched-on server; login is
    // interactive (no --json) and is followed by a status of that server.
    const rc = try f.call("McpServerAction", "{\"action\":\"reconnect\"}");
    gpa.free(rc.unary_json);
    const login = try f.call("McpServerAction", "{\"action\":\"login\",\"name\":\"alpha\",\"cwd\":\"/nonexistent-synthetic\"}");
    gpa.free(login.unary_json);
    var list_params = try json.parseFromSlice(json.Value, gpa, "{\"names\":[\"alpha\"]}", .{});
    defer list_params.deinit();
    const listed = try listMcpServers(&f.host, list_params.value);
    gpa.free(listed.unary_json);

    const log = try f.calls();
    defer gpa.free(log);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log, "\n"), '\n');
    const first = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, first, project));
    try testing.expect(std.mem.endsWith(u8, first, "|1|mcp enable alpha --json"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "|1|mcp reconnect --all --json"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "|1|mcp login alpha"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "|1|mcp status alpha --json"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "|1|mcp status alpha --json"));
}

test "rpcw_mcp ListMcpServers through the engine dispatch runs graff mcp status" {
    const f = try Fx.init(true);
    defer f.deinit();
    const gpa = testing.allocator;
    const project = try std.fs.path.join(gpa, &.{ f.base, "project" });
    defer gpa.free(project);
    const params = try std.fmt.allocPrint(gpa, "{{\"cwd\":{f}}}", .{json.fmt(project, .{})});
    defer gpa.free(params);
    const out = try f.call("ListMcpServers", params);
    defer gpa.free(out.unary_json);
    // graff's rows, not a fixed built-in list.
    try testing.expect(std.mem.startsWith(u8, out.unary_json, "[{\"name\":\"alpha\",\"source\":\"project\""));
    try testing.expect(std.mem.indexOf(u8, out.unary_json, "harness-mcp") == null);
    const log = try f.calls();
    defer gpa.free(log);
    try testing.expect(std.mem.startsWith(u8, log, project));
    try testing.expect(std.mem.indexOf(u8, log, "|1|mcp status --json") != null);
    try expectErr(try f.call("ListMcpServers", "{\"names\":\"alpha\"}"), true, "invalid type: expected a sequence for `names`");
}

test "rpcw_mcp ListMcpServers without graff says to install it" {
    const f = try Fx.init(false);
    defer f.deinit();
    try expectErr(try f.call("ListMcpServers", "{}"), false, "The `graff` CLI was not found on this device — install it first.");
}

test "rpcw_mcp McpServerAction errors match mcp_servers.rs" {
    const f = try Fx.init(true);
    defer f.deinit();
    try expectErr(try f.call("McpServerAction", "{\"action\":\"enable\"}"), false, "Say which MCP server to enable.");
    try expectErr(try f.call("McpServerAction", "{\"action\":\"login\"}"), false, "Say which MCP server to login.");
    try expectErr(try f.call("McpServerAction", "{\"name\":\"a\"}"), true, "missing field `action`");
    try expectErr(try f.call("McpServerAction", "{\"action\":\"install\",\"name\":\"a\"}"), true, "unknown variant `install`, expected one of `reconnect`, `enable`, `disable`, `login`");
    try expectErr(try f.call("McpServerAction", "{\"action\":\"disable\",\"name\":\"broken\"}"), false, "server broken is not configured");
    try expectErr(try f.call("McpServerAction", "{\"action\":\"disable\",\"name\":\"old\"}"), false, old_graff);
    try expectErr(try f.call("McpServerAction", "{\"action\":\"enable\",\"name\":\"--all\"}"), false, "Could not resolve the graff CLI: harness protocol error: not an MCP server name: \"--all\"");
}

test "rpcw_mcp McpServerAction without graff says to install it" {
    const f = try Fx.init(false);
    defer f.deinit();
    try expectErr(try f.call("McpServerAction", "{\"action\":\"enable\",\"name\":\"alpha\"}"), false, "The `graff` CLI was not found on this device — install it first.");
}

test "rpcw_mcp lastErrorLine prefers stdout's last line, then stderr's" {
    try testing.expectEqualStrings("b", lastErrorLine("x\n", "a\nb\n\n"));
    try testing.expectEqualStrings("y", lastErrorLine("x\ny\n", "  \n"));
    try testing.expectEqualStrings("graff exited with an error", lastErrorLine("", ""));
}

test "fix-sec 13: graff mcp runs with the engine's graff home, as sign-out does" {
    const f = try Fx.init(true);
    defer f.deinit();
    const gpa = testing.allocator;
    try f.tmp.dir.createDirPath(testing.io, "graff-home");
    const graff_home = try std.fs.path.join(gpa, &.{ f.base, "graff-home" });
    defer gpa.free(graff_home);
    f.host.agent_accounts.home_dir = try gpa.dupe(u8, graff_home);

    const out = try f.call("ListMcpServers", "{}");
    defer gpa.free(out.unary_json);
    // The fake graff logs to $HOME/calls.log: the configured home, not the process's.
    var buf: [4096]u8 = undefined;
    const log = try f.tmp.dir.readFile(testing.io, "graff-home/calls.log", &buf);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, log, "\n"), "|1|mcp status --json"));
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "calls.log", .{}));
}
