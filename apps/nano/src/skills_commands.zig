//! `ListSkills` per harness: on-disk discovery (`skills_discovery.zig`)
//! joined with each agent CLI's own command handshake, ported from
//! `Harness::skills` in `crates/harness/src/{claude,codex,acp,opencode,pi}`:
//!
//! - Claude: `--print` stream-json + the `initialize` control request; shared
//!   skills stay, others only when the CLI advertises a same-named command.
//! - Codex: `codex app-server` `initialize` → `skills/list` (the CLI's own
//!   catalog; no disk scan).
//! - ACP agents (graff, Devin, Grok, Hermes, Antigravity, Exo): `initialize`,
//!   `session/new`, then up to 2 s for `available_commands_update`.
//! - OpenCode: `opencode serve` on a loopback port, `GET /command`.
//! - Pi: `pi --mode rpc` `get_commands` (its `skill:` namespace).
//! - Cursor: disk discovery only; Mock: `null`.
//!
//! Claude, ACP and Pi share one probe per harness and folder through
//! `skills::CommandDiscovery` (an overlapping request reuses the probe that
//! finished after it started; a later one probes again).
//!
//! Std-only (catalog_core, agent_proc, harness_version, skills_discovery),
//! tested standalone with `zig test skills_commands.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Environ = std.process.Environ;
const catalog_core = @import("catalog_core.zig");
const agent_proc = @import("agent_proc.zig");
const harness_version = @import("harness_version.zig");
const sd = @import("skills_discovery.zig");
const AgentProc = agent_proc.AgentProc;
const HarnessId = sd.HarnessId;
const Skill = sd.Skill;
const SlashCommand = sd.SlashCommand;

// ── engine-provided settings ───────────────────────────────────────────────

/// `CARGO_PKG_VERSION` in `clientInfo` and `GRAFF_HOST_APP` (the engine sets
/// it from `build_info.version`).
pub var client_version: []const u8 = "0.0.0";
/// The GUI's graff draft-subagents toggle (`graff_draft_subagents`).
pub var graff_draft_subagents: bool = false;
/// The GUI's graff compaction threshold (`graff_compact_at`; 0 = unset).
pub var graff_compact_pct: u8 = 0;
/// `graff_client::set_device_name`.
pub var graff_device_name: ?[]const u8 = null;
/// Tests shorten every probe's budget (Claude/Codex/ACP 10 s, Antigravity
/// 90 s, Pi 60 s, OpenCode startup 300 s).
pub var timeout_override_ms: ?u32 = null;
/// Grace between SIGTERM and SIGKILL when a probe child is retired.
pub var kill_grace_ms: u32 = 3000;
/// How long an ACP probe waits for `available_commands_update` after
/// `session/new` (not shortened by `timeout_override_ms`).
pub var acp_update_window_ms: u32 = 2000;

/// `ListSkills`'s reply: the JSON (`[...]`, or `null` for Mock), or the
/// error text the RPC fails with (`RpcError::Failed(e.to_string())`).
pub const Result = union(enum) {
    ok: []u8,
    err: []u8,

    pub fn deinit(self: Result, gpa: Allocator) void {
        switch (self) {
            inline else => |s| gpa.free(s),
        }
    }
};

/// `harness.skills(cwd)` for the harness with wire id `id`, serialized.
/// `gpa` must be thread-safe (probe children drain stderr on a thread).
pub fn listSkillsJson(gpa: Allocator, io: Io, id: []const u8, cwd: []const u8) !Result {
    const harness = HarnessId.fromWire(id) orelse return .{ .err = try std.fmt.allocPrint(gpa, "unknown harness: {s}", .{id}) };
    if (harness == .mock) return .{ .ok = try gpa.dupe(u8, "null") };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var c: Ctx = .{ .gpa = gpa, .arena = arena_state.allocator(), .io = io, .env = try catalog_core.currentEnv(arena_state.allocator()) };
    const skills = skillsFor(&c, harness, cwd) catch |e| switch (e) {
        error.Harness => return .{ .err = try gpa.dupe(u8, c.msg) },
        else => |x| return x,
    };
    return .{ .ok = try sd.skillsJson(gpa, skills) };
}

fn skillsFor(c: *Ctx, harness: HarnessId, cwd: []const u8) ![]const Skill {
    return switch (harness) {
        .mock => unreachable,
        .cursor => try c.discover(harness, cwd),
        .codex => try codexSkills(c, cwd),
        .claude_code => try claudeSkills(c, cwd),
        .opencode => try opencodeSkills(c, cwd),
        .pi => try piSkills(c, cwd),
        .graff, .devin, .grok, .hermes, .antigravity, .exo => try acpSkills(c, harness, cwd),
    };
}

// ── shared plumbing ────────────────────────────────────────────────────────

const Fail = error{Harness};

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    /// The engine's environment (or the test override).
    env: Environ.Map,
    msg: []const u8 = "",

    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) Fail {
        c.msg = std.fmt.allocPrint(c.arena, fmt, args) catch "out of memory";
        return error.Harness;
    }

    /// `HarnessError::Protocol(msg)`.
    fn protocol(c: *Ctx, comptime fmt: []const u8, args: anytype) Fail {
        return c.fail("harness protocol error: " ++ fmt, args);
    }

    fn discover(c: *Ctx, harness: HarnessId, cwd: []const u8) ![]Skill {
        const home = try catalog_core.homeOrCwd(c.arena, c.io, &c.env);
        return sd.discoverAt(c.arena, c.io, harness, cwd, home, &c.env);
    }

    /// The CLI for wire id `id`, or `NotInstalled(hint)`.
    fn resolve(c: *Ctx, id: []const u8, hint: []const u8) ![]const u8 {
        const found = catalog_core.resolve_cli(c.arena, c.io, id) catch |e| return c.fail("io: {s}", .{@errorName(e)});
        return found orelse return c.fail("harness binary not found: {s}", .{hint});
    }

    /// `binary_hint(exe)`: `"<path> (version <v>|unknown)"`.
    fn notInstalledBinary(c: *Ctx, exe: []const u8) Fail {
        var buf: [128]u8 = undefined;
        const v = harness_version.binaryVersionString(c.io, exe, &buf) orelse "unknown";
        return c.fail("harness binary not found: {s} (version {s})", .{ exe, v });
    }

    /// The probe child's environment: `apply_run_environment(None)`, the
    /// `owned::configure` scrub when `strip`, and `compose_child_path`.
    fn childEnv(c: *Ctx, exe: []const u8, strip: bool) !Environ.Map {
        var env = try c.env.clone(c.arena);
        _ = env.swapRemove("HARNESS_BUILD_WAIT_DIR");
        if (strip) for (agent_proc.stripped_env) |k| {
            _ = env.swapRemove(k);
        };
        const login = agent_proc.loginShellPath(c.arena, c.io, &env);
        var path = try agent_proc.composeChildPath(c.arena, exe, env.get("PATH"), login);
        // Harness's own tools (~/.harness/tools/bin) come last.
        const home = try catalog_core.homeOrCwd(c.arena, c.io, &c.env);
        const tools = try std.fs.path.join(c.arena, &.{ home, ".harness", "tools", "bin" });
        var listed = false;
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |p| if (std.mem.eql(u8, p, tools)) {
            listed = true;
        };
        if (!listed) path = if (path.len == 0) tools else try std.fmt.allocPrint(c.arena, "{s}:{s}", .{ path, tools });
        try env.put("PATH", path);
        return env;
    }

    const MissingDir = enum { binary_hint, project_folder, io_not_found };

    fn spawn(c: *Ctx, argv: []const []const u8, cwd: ?[]const u8, env: *Environ.Map, opts: agent_proc.SpawnOpts, missing: MissingDir) !*AgentProc {
        return AgentProc.spawn(c.gpa, c.io, argv, cwd, env, opts) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingCwd => switch (missing) {
                .binary_hint => return c.notInstalledBinary(argv[0]),
                .project_folder => return c.fail("io: Project folder is missing: {s}", .{cwd.?}),
                .io_not_found => return c.fail("io: No such file or directory (os error 2)", .{}),
            },
            error.NotInstalled => switch (missing) {
                .io_not_found => return c.fail("io: No such file or directory (os error 2)", .{}),
                else => return c.notInstalledBinary(argv[0]),
            },
            else => return c.fail("io: {s}", .{@errorName(e)}),
        };
    }
};

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn budgetMs(default_ms: u32) u32 {
    return timeout_override_ms orelse default_ms;
}

/// `shutdown_child`: SIGTERM the group, SIGKILL it after the grace, reap.
fn retire(proc: *AgentProc) void {
    proc.escalate(0, kill_grace_ms);
    _ = proc.wait();
    proc.destroy();
}

fn get(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getStr(v: json.Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseLine(arena: Allocator, line: []const u8) ?json.Value {
    return json.parseFromSliceLeaky(json.Value, arena, line, .{ .allocate = .alloc_always }) catch null;
}

fn sortedKeys(arena: Allocator, o: json.ObjectMap) ![]const []const u8 {
    const keys = try arena.dupe([]const u8, o.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return keys;
}

/// `Value::to_string` (serde_json's default map is ordered by key).
fn writeJson(arena: Allocator, w: *std.Io.Writer, v: json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try w.print("{f}", .{json.fmt(s, .{})}),
        .array => |a| {
            try w.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJson(arena, w, item);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            try w.writeByte('{');
            for (try sortedKeys(arena, o), 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}:", .{json.fmt(k, .{})});
                try writeJson(arena, w, o.get(k).?);
            }
            try w.writeByte('}');
        },
    }
}

fn jsonText(arena: Allocator, v: json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeJson(arena, &aw.writer, v) catch return error.OutOfMemory;
    return aw.written();
}

// ── CommandDiscovery (`skills::CommandDiscovery`) ──────────────────────────

const Cache = struct {
    mutex: Io.Mutex = .init,
    root: ?[]const u8 = null,
    completed: i96 = 0,
    state: ?std.heap.ArenaAllocator = null,
    commands: []const SlashCommand = &.{},
};

var caches: std.EnumArray(HarnessId, Cache) = .initFill(.{});

/// Tests: forget every harness's last probe.
pub fn resetCaches() void {
    // The engine's settings, as a fresh process has them.
    client_version = "0.0.0";
    graff_draft_subagents = false;
    graff_compact_pct = 0;
    graff_device_name = null;
    for (&caches.values) |*cache| {
        if (cache.state) |*s| s.deinit();
        cache.* = .{};
    }
}

fn cloneCommands(a: Allocator, commands: []const SlashCommand) ![]SlashCommand {
    const out = try a.alloc(SlashCommand, commands.len);
    for (commands, 0..) |cmd, i| out[i] = .{
        .name = try a.dupe(u8, cmd.name),
        .description = try a.dupe(u8, cmd.description),
        .input_hint = if (cmd.input_hint) |h| try a.dupe(u8, h) else null,
    };
    return out;
}

/// Share an overlapping probe (one that completed after this request
/// started), but probe again for a later request or another folder.
fn workspaceCommands(c: *Ctx, harness: HarnessId, cwd: []const u8, comptime probe: fn (*Ctx, HarnessId, []const u8) anyerror![]SlashCommand) ![]const SlashCommand {
    const cache = caches.getPtr(harness);
    const requested = nowNs(c.io);
    cache.mutex.lockUncancelable(c.io);
    defer cache.mutex.unlock(c.io);
    if (cache.root) |root| if (eql(root, cwd) and cache.completed >= requested) return cloneCommands(c.arena, cache.commands);
    const commands = try probe(c, harness, cwd);
    var state = std.heap.ArenaAllocator.init(catalog_core.long_gpa);
    errdefer state.deinit();
    const a = state.allocator();
    const saved = try cloneCommands(a, commands);
    const root = try a.dupe(u8, cwd);
    if (cache.state) |*old| old.deinit();
    cache.* = .{ .mutex = cache.mutex, .root = root, .completed = nowNs(c.io), .state = state, .commands = saved };
    return commands;
}

// ── JSON-RPC 2.0 over a child's stdio (`jsonrpc.rs`) ───────────────────────

const auth_link_prefix = "Open the following link to authenticate the ACP server: ";
const reauth_text = "ChatGPT sign-in expired or was rejected. Sign in again to continue.";

const Rpc = struct {
    c: *Ctx,
    proc: *AgentProc,
    /// The whole discovery's deadline (awake clock).
    deadline: i96,
    timeout_msg: []const u8,
    next_id: i64 = 0,
    /// Server→client requests and notifications, in arrival order.
    backlog: std.ArrayList(json.Value) = .empty,

    fn passed(self: *Rpc) bool {
        return nowNs(self.c.io) >= self.deadline;
    }

    /// Writes are best-effort (`write_loop` tolerates a closed stdin).
    fn send(self: *Rpc, line: []const u8) void {
        self.proc.writeLine(line) catch {};
    }

    fn notify(self: *Rpc, method: []const u8) !void {
        self.send(try std.fmt.allocPrint(self.c.arena, "{{\"jsonrpc\":\"2.0\",\"method\":{f}}}", .{json.fmt(method, .{})}));
    }

    fn respondError(self: *Rpc, id: json.Value, code: i64, message: []const u8) !void {
        self.send(try std.fmt.allocPrint(self.c.arena, "{{\"error\":{{\"code\":{d},\"message\":{f}}},\"id\":{s},\"jsonrpc\":\"2.0\"}}", .{ code, json.fmt(message, .{}), try jsonText(self.c.arena, id) }));
    }

    /// The next JSON-RPC object on stdout; null at end of stream.
    fn frame(self: *Rpc) !?json.Value {
        while (true) {
            const raw = (self.proc.readLine() catch null) orelse return null;
            const line = std.mem.trim(u8, raw, " \t\r\n");
            if (line.len == 0 or std.mem.startsWith(u8, line, auth_link_prefix)) continue;
            const v = parseLine(self.c.arena, line) orelse continue;
            if (v != .object) continue;
            if (v.object.get("jsonrpc")) |ver| if (!(ver == .string and eql(ver.string, "2.0"))) continue;
            return v;
        }
    }

    fn request(self: *Rpc, method: []const u8, params: []const u8) !json.Value {
        self.next_id += 1;
        const id = self.next_id;
        self.send(try std.fmt.allocPrint(self.c.arena, "{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":{f},\"params\":{s}}}", .{ id, json.fmt(method, .{}), params }));
        while (try self.frame()) |msg| {
            const m = getStr(msg, "method");
            if (m == null) {
                const idv = msg.object.get("id") orelse continue;
                if (msg.object.get("result") == null and msg.object.get("error") == null) continue;
                if (responseId(idv) != id) continue;
                if (msg.object.get("error")) |err| return responseFailure(self.c, method, err);
                return msg.object.get("result").?;
            }
            try self.backlog.append(self.c.arena, msg);
        }
        if (self.passed()) return self.c.protocol("{s}", .{self.timeout_msg});
        return self.c.protocol("{s}: app-server exited before responding", .{method});
    }
};

/// `response_id`: integers, numeric strings and integral floats.
fn responseId(v: json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .float => |f| if (@floor(f) == f and !std.math.isInf(f)) @as(?i64, @intFromFloat(f)) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn jsonEqualsStrings(v: json.Value, want: []const []const u8) bool {
    if (v != .array or v.array.items.len != want.len) return false;
    for (v.array.items, want) |item, w| if (item != .string or !eql(item.string, w)) return false;
    return true;
}

/// `ReauthProvider::from_acp`.
fn isReauth(data: json.Value) bool {
    if (!eql(getStr(data, "kind") orelse return false, "reauth_required")) return false;
    const provider = getStr(data, "provider") orelse return false;
    var command: []const u8 = undefined;
    var args: []const []const u8 = undefined;
    if (eql(provider, "chatgpt-new")) {
        command = "graff";
        args = &.{ "login", "chatgpt-new" };
    } else if (eql(provider, "codex")) {
        command = "codex";
        args = &.{"login"};
    } else return false;
    const login = get(data, "login") orelse return false;
    return eql(getStr(login, "command") orelse return false, command) and jsonEqualsStrings(get(login, "args") orelse return false, args);
}

/// `KeyRejected::from_acp`: the provider id.
fn keyRejectedProvider(data: json.Value) ?[]const u8 {
    if (!eql(getStr(data, "kind") orelse return null, "api_key_rejected")) return null;
    const provider = sd.trimUnicode(getStr(data, "provider") orelse return null);
    if (provider.len == 0 or provider.len > 64) return null;
    for (provider) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return null;
    return provider;
}

/// `run_errors::key_rejected_message`.
fn keyRejectedMessage(arena: Allocator, provider: []const u8, message_in: []const u8) ![]const u8 {
    const message = sd.trimUnicode(message_in);
    const lower = try std.ascii.allocLowerString(arena, message);
    const text = try std.mem.replaceOwned(u8, arena, lower, "\u{2019}", "'");
    for ([_][]const u8{ "api key was rejected", "fallback api key", "sign-in is not affected" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return message;
    }
    const p = if (provider.len == 0) "The" else provider;
    if (message.len == 0) return std.fmt.allocPrint(arena, "{s} API key was rejected. Your sign-in is not affected.", .{p});
    return std.fmt.allocPrint(arena, "{s} API key was rejected: {s}", .{ p, message });
}

/// `response_error`: the message, ` (code N)`, and `: data`.
fn responseError(arena: Allocator, err: json.Value) ![]const u8 {
    const message = getStr(err, "message") orelse return jsonText(arena, err);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, message);
    if (get(err, "code")) |code| if (code == .integer) try out.print(arena, " (code {d})", .{code.integer});
    if (get(err, "data")) |data| if (data != .null) {
        const detail = if (data == .string) data.string else try jsonText(arena, data);
        if (detail.len > 0) {
            try out.appendSlice(arena, ": ");
            try out.appendSlice(arena, detail);
        }
    };
    return out.items;
}

/// `response_failure` as the request's error (never returns a value).
fn responseFailure(c: *Ctx, method: []const u8, err: json.Value) !json.Value {
    const code: ?i64 = if (get(err, "code")) |x| (if (x == .integer) x.integer else null) else null;
    const data = get(err, "data");
    if (code == -32000) if (data) |d| if (isReauth(d)) return c.fail("{s}", .{reauth_text});
    if (data) |d| if (keyRejectedProvider(d)) |provider| {
        return c.fail("{s}", .{try keyRejectedMessage(c.arena, provider, getStr(err, "message") orelse "")});
    };
    if (code == -32603 and (data == null or data.? == .null) and std.mem.startsWith(u8, getStr(err, "message") orelse "", "chatgpt-new api error [token_expired]:")) {
        return c.fail("{s}", .{reauth_text});
    }
    return c.protocol("{s}: {s}", .{ method, try responseError(c.arena, err) });
}

// ── Claude (`claude/mod.rs` `skills`, `probe_initialize`) ──────────────────

const claude_hint = "claude (searched PATH, the login shell's PATH, ~/.claude/local, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CLAUDE_CODE_EXECUTABLE to override)";
const claude_probe_id = "harness-command-probe";

/// `parse_initialize_commands`: `response.response.commands`.
pub fn parseInitializeCommands(arena: Allocator, response: json.Value) ![]SlashCommand {
    const inner = get(response, "response") orelse return &.{};
    const list = get(inner, "commands") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(SlashCommand) = .empty;
    for (list.array.items) |cmd| {
        const name = sd.trimUnicode(getStr(cmd, "name") orelse continue);
        if (name.len == 0) continue;
        const hint: ?[]const u8 = if (getStr(cmd, "argumentHint")) |h| (if (sd.trimUnicode(h).len > 0) sd.trimUnicode(h) else null) else null;
        try out.append(arena, .{ .name = name, .description = getStr(cmd, "description") orelse "", .input_hint = hint });
    }
    return out.items;
}

fn claudeProbe(c: *Ctx, _: HarnessId, cwd: []const u8) anyerror![]SlashCommand {
    const exe = try c.resolve("claude-code", claude_hint);
    var env = try c.childEnv(exe, false);
    const argv = [_][]const u8{ exe, "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose" };
    const proc = try c.spawn(&argv, cwd, &env, .{}, .binary_hint);
    defer retire(proc);
    const ms = budgetMs(10_000);
    const deadline = nowNs(c.io) + @as(i96, ms) * std.time.ns_per_ms;
    proc.armDeadline(ms);
    proc.writeLine("{\"request\":{\"subtype\":\"initialize\"},\"request_id\":\"" ++ claude_probe_id ++ "\",\"type\":\"control_request\"}") catch
        return c.fail("io: Broken pipe (os error 32)", .{});
    while (proc.readLine() catch null) |line| {
        const frame = parseLine(c.arena, line) orelse continue;
        if (!eql(getStr(frame, "type") orelse "", "control_response")) continue;
        const response = get(frame, "response") orelse json.Value.null;
        if (!eql(getStr(response, "request_id") orelse "", claude_probe_id)) continue;
        if (eql(getStr(response, "subtype") orelse "", "error")) {
            return c.protocol("{s}", .{getStr(response, "error") orelse "initialize control request failed"});
        }
        return parseInitializeCommands(c.arena, response);
    }
    if (nowNs(c.io) >= deadline) return c.protocol("Claude initialize timed out", .{});
    return c.protocol("claude exited before answering the initialize control request", .{});
}

/// The CLI's advertised catalog controls availability; shared Agent Skills
/// keep their file identity.
fn claudeSkills(c: *Ctx, cwd: []const u8) ![]const Skill {
    const skills = try c.discover(.claude_code, cwd);
    const commands = try workspaceCommands(c, .claude_code, cwd, claudeProbe);
    var out: std.ArrayList(Skill) = .empty;
    for (skills) |skill_in| {
        var skill = skill_in;
        if (sd.isSharedSkill(skill.path)) {
            try out.append(c.arena, skill);
            continue;
        }
        if (!sd.validSkillCommandName(skill.name)) continue;
        for (commands) |cmd| if (eql(cmd.name, skill.name)) {
            skill.command = .{ .name = skill.name, .harness = .claude_code };
            try out.append(c.arena, skill);
            break;
        };
    }
    return out.items;
}

// ── Codex (`codex/mod.rs` `discover_skills`, `parse_skills`) ───────────────

const codex_hint = "codex (searched PATH, the login shell's PATH, ~/.local/bin, ~/.codex/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CODEX_EXECUTABLE to override)";

/// `parse_skills`: every cwd group's skills; identical name/path pairs once.
pub fn parseCodexSkills(arena: Allocator, result: json.Value) ![]Skill {
    var out: std.ArrayList(Skill) = .empty;
    const data = get(result, "data") orelse return out.items;
    if (data != .array) return out.items;
    for (data.array.items) |group| {
        const list = get(group, "skills") orelse continue;
        if (list != .array) continue;
        for (list.array.items) |s| {
            const name = getStr(s, "name") orelse continue;
            const path = getStr(s, "path") orelse continue;
            if (!sd.validInvocationName(name) or !sd.validSkillPath(path)) continue;
            var dup = false;
            for (out.items) |prev| if (eql(prev.name, name) and eql(prev.path, path)) {
                dup = true;
                break;
            };
            if (dup) continue;
            const short = if (get(s, "interface")) |i| getStr(i, "shortDescription") else null;
            const enabled = if (get(s, "enabled")) |e| (if (e == .bool) e.bool else true) else true;
            try out.append(arena, .{ .name = name, .path = path, .description = short orelse getStr(s, "description") orelse "", .enabled = enabled });
        }
    }
    return out.items;
}

fn codexSkills(c: *Ctx, cwd: []const u8) ![]const Skill {
    const exe = try c.resolve("codex", codex_hint);
    var env = try c.childEnv(exe, false);
    const argv = [_][]const u8{ exe, "app-server" };
    const proc = try c.spawn(&argv, cwd, &env, .{}, .binary_hint);
    defer retire(proc);
    const ms = budgetMs(10_000);
    var rpc: Rpc = .{ .c = c, .proc = proc, .deadline = nowNs(c.io) + @as(i96, ms) * std.time.ns_per_ms, .timeout_msg = "command discovery timed out" };
    proc.armDeadline(ms);
    _ = try rpc.request("initialize", try std.fmt.allocPrint(c.arena, "{{\"capabilities\":{{\"experimentalApi\":true}},\"clientInfo\":{{\"name\":\"harness-native\",\"title\":\"Harness\",\"version\":{f}}}}}", .{json.fmt(client_version, .{})}));
    try rpc.notify("initialized");
    const result = try rpc.request("skills/list", try std.fmt.allocPrint(c.arena, "{{\"cwds\":[{f}],\"forceReload\":true}}", .{json.fmt(cwd, .{})}));
    return parseCodexSkills(c.arena, result);
}

// ── ACP agents (`acp/mod.rs` `skills`, `discover_commands`) ────────────────

const AcpSpec = struct {
    exe_id: []const u8,
    args: []const []const u8,
    hint: []const u8,
    timeout_ms: u32 = 10_000,
};

fn acpSpec(h: HarnessId) AcpSpec {
    return switch (h) {
        .graff => .{ .exe_id = "graff", .args = &.{ "acp", "--yolo" }, .hint = "graff (searched PATH, the login shell's PATH, ~/.harness/bin, the app bundle, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install codegraff, then `graff login`; set GRAFF_EXECUTABLE to override)" },
        .devin => .{ .exe_id = "devin", .args = &.{"acp"}, .hint = "devin (searched PATH, the login shell's PATH, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install with `curl -fsSL https://cli.devin.ai/install.sh | bash` or `brew install --cask devin-cli`, then `devin auth login`; set DEVIN_EXECUTABLE to override)" },
        .grok => .{ .exe_id = "grok", .args = &.{ "--no-auto-update", "agent", "--no-leader", "stdio" }, .hint = "grok (searched PATH, the login shell's PATH, ~/.local/bin, ~/.grok/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; install with `curl -fsSL https://x.ai/cli/install.sh | bash` or `npm install -g @xai-official/grok`; set GROK_EXECUTABLE to override)" },
        .hermes => .{ .exe_id = "hermes", .args = &.{"acp"}, .hint = "hermes (searched PATH, the login shell's PATH, ~/.local/bin, ~/.hermes/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; install with `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`, then `cd ~/.hermes/hermes-agent && uv pip install -e '.[acp]'` for the ACP server; set HERMES_EXECUTABLE to override)" },
        .antigravity => .{
            .exe_id = "antigravity",
            .args = if (builtin.os.tag == .linux) &.{"--uid="} else &.{},
            .hint = "Antigravity's ACP server is not installed (the agy CLI does not include it): install it from Settings, or set ANTIGRAVITY_ACP_EXECUTABLE to it",
            .timeout_ms = 90_000,
        },
        .exo => .{ .exe_id = "exo", .args = &.{"exo-acp"}, .hint = "Exo's agent-cli adapter (install Exo from https://github.com/exoharness/exo, start it with `./exo.sh --setup agent-cli`, and link `exo/scripts/exo-cli` onto PATH; set EXO_AGENT_CLI_SOCKET if the socket isn't ~/.exo/agent-cli.sock)" },
        else => unreachable,
    };
}

fn draftSubagents(c: *Ctx, h: HarnessId) bool {
    if (h != .graff) return false;
    return graff_draft_subagents or eql(c.env.get("GRAFF_ACP_DRAFT_SUBAGENTS") orelse "", "1");
}

/// `initialize_params_with_subagents` (keys in serde_json's order).
pub fn acpInitializeParams(arena: Allocator, h: HarnessId, draft: bool) ![]u8 {
    const caps: []const u8 = switch (h) {
        .devin => "{\"_meta\":{\"cognition.ai/subagentSupport\":true},\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false}",
        .graff => if (draft)
            "{\"_meta\":{\"graff/backgroundSubagents\":true},\"elicitation\":{\"form\":{}},\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"session\":{\"compaction\":{}},\"subagents\":{},\"terminal\":false}"
        else
            "{\"elicitation\":{\"form\":{}},\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"session\":{\"compaction\":{}},\"terminal\":false}",
        else => "{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false}",
    };
    return std.fmt.allocPrint(arena, "{{\"clientCapabilities\":{s},\"clientInfo\":{{\"name\":\"harness\",\"title\":\"Harness\",\"version\":{f}}},\"protocolVersion\":1}}", .{ caps, json.fmt(client_version, .{}) });
}

/// `normalize::parse_commands`.
pub fn parseAcpCommands(arena: Allocator, value: ?json.Value) ![]SlashCommand {
    var out: std.ArrayList(SlashCommand) = .empty;
    const list = value orelse return out.items;
    if (list != .array) return out.items;
    for (list.array.items) |cmd| {
        const name = getStr(cmd, "name") orelse "";
        if (name.len == 0) continue;
        const hint = if (get(cmd, "input")) |i| getStr(i, "hint") else null;
        try out.append(arena, .{ .name = name, .description = getStr(cmd, "description") orelse "", .input_hint = hint });
    }
    return out.items;
}

/// `scan_available_commands`: the first `availableCommands` array within
/// four object levels, keys visited in serde_json's (sorted) order.
pub fn scanAvailableCommands(arena: Allocator, value: json.Value) ![]SlashCommand {
    return parseAcpCommands(arena, try scanFor(arena, value, 4));
}

fn scanFor(arena: Allocator, value: json.Value, depth: u8) !?json.Value {
    if (depth == 0 or value != .object) return null;
    if (value.object.get("availableCommands")) |cmds| if (cmds == .array) return cmds;
    for (try sortedKeys(arena, value.object)) |k| {
        if (try scanFor(arena, value.object.get(k).?, depth - 1)) |found| return found;
    }
    return null;
}

fn acpEnv(c: *Ctx, h: HarnessId, exe: []const u8) !Environ.Map {
    var env = try c.childEnv(exe, true);
    if (h == .graff) {
        // `configure_adapter_environment` + `graff_client::env`.
        try env.put("GRAFF_AUTO_ISOLATE", "0");
        if (c.env.get("GRAFF_CODEX_WS") == null) try env.put("GRAFF_CODEX_WS", "off");
        if (draftSubagents(c, h)) try env.put("GRAFF_ACP_DRAFT_SUBAGENTS", "1");
        if (graff_compact_pct != 0 and c.env.get("GRAFF_COMPACT_PCT") == null) try env.put("GRAFF_COMPACT_PCT", try std.fmt.allocPrint(c.arena, "{d}", .{graff_compact_pct}));
        if (c.env.get("GRAFF_HOST_APP") == null) try env.put("GRAFF_HOST_APP", try std.fmt.allocPrint(c.arena, "harness/{s}", .{client_version}));
        if (graff_device_name) |name| if (c.env.get("GRAFF_DEVICE_NAME") == null) try env.put("GRAFF_DEVICE_NAME", name);
    }
    if (h == .antigravity) {
        if (std.fs.path.dirname(exe)) |parent| {
            const sibling = try std.fs.path.join(c.arena, &.{ parent, "localharness_external" });
            const is_file = if (Io.Dir.cwd().statFile(c.io, sibling, .{})) |st| st.kind == .file else |_| false;
            if (is_file) {
                try env.put("ANTIGRAVITY_HARNESS_PATH", sibling);
                try env.put("PYTHONUNBUFFERED", "1");
            }
        }
        switch (try sd.antigravityHome(c.arena, c.io, &c.env)) {
            .ok => |home| try env.put("GEMINI_HOME", home),
            .err => |msg| return c.protocol("{s}", .{msg}),
        }
        // Python's webbrowser takes an executable template; never open one here.
        if (builtin.os.tag != .windows) try env.put("BROWSER", "/usr/bin/true %s");
    }
    return env;
}

/// `discover_commands(Some(cwd))`: the handshake's commands, replaced by the
/// session's `available_commands_update` when one arrives within 2 s.
fn acpProbe(c: *Ctx, h: HarnessId, cwd: []const u8) anyerror![]SlashCommand {
    const spec = acpSpec(h);
    const exe = try c.resolve(spec.exe_id, spec.hint);
    var env = try acpEnv(c, h, exe);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(c.arena, exe);
    try argv.appendSlice(c.arena, spec.args);
    const proc = try c.spawn(argv.items, if (cwd.len > 0) cwd else null, &env, .{}, .project_folder);
    defer retire(proc);
    const ms = budgetMs(spec.timeout_ms);
    var rpc: Rpc = .{ .c = c, .proc = proc, .deadline = nowNs(c.io) + @as(i96, ms) * std.time.ns_per_ms, .timeout_msg = "command discovery timed out" };
    proc.armDeadline(ms);
    const init = try rpc.request("initialize", try acpInitializeParams(c.arena, h, draftSubagents(c, h)));
    var commands = try scanAvailableCommands(c.arena, init);
    const session_cwd = if (cwd.len > 0) cwd else try catalog_core.homeOrCwd(c.arena, c.io, &c.env);
    _ = rpc.request("session/new", try std.fmt.allocPrint(c.arena, "{{\"cwd\":{f},\"mcpServers\":[]}}", .{json.fmt(session_cwd, .{})})) catch |e| switch (e) {
        // A refused session still surfaces the handshake's commands; the
        // whole discovery running out of time does not.
        error.Harness => {
            if (rpc.passed()) return e;
            return commands;
        },
        else => return e,
    };
    // A quiet agent gets 2 s; retiring it ends the read.
    proc.armDeadline(acp_update_window_ms);
    var i: usize = 0;
    while (true) {
        const msg = if (i < rpc.backlog.items.len) blk: {
            i += 1;
            break :blk rpc.backlog.items[i - 1];
        } else (try rpc.frame()) orelse {
            if (rpc.passed()) return c.protocol("command discovery timed out", .{});
            break;
        };
        const method = getStr(msg, "method") orelse continue;
        if (msg.object.get("id")) |id| {
            try rpc.respondError(id, -32601, "unsupported during discovery");
            continue;
        }
        if (!eql(method, "session/update")) continue;
        const update = get(msg.object.get("params") orelse continue, "update") orelse continue;
        if (eql(getStr(update, "sessionUpdate") orelse "", "available_commands_update")) {
            commands = try parseAcpCommands(c.arena, get(update, "availableCommands"));
            break;
        }
    }
    return commands;
}

fn acpSkills(c: *Ctx, h: HarnessId, cwd: []const u8) ![]const Skill {
    const skills = try c.discover(h, cwd);
    const commands = try workspaceCommands(c, h, cwd, acpProbe);
    var list: std.ArrayList(Skill) = .fromOwnedSlice(skills);
    try sd.attachAdvertisedCommands(c.arena, h, &list, commands);
    return list.items;
}

// ── Pi (`pi/mod.rs` `probe`, `catalog::commands`) ──────────────────────────

const pi_hint = "Pi CLI: install Pi or set PI_EXECUTABLE (the pi-acp adapter is not used)";
const pi_max_frame = 32 * 1024 * 1024;

/// `catalog::commands`: Pi's own commands, then its built-ins.
pub fn piCommandsFrom(arena: Allocator, data: json.Value) ![]SlashCommand {
    var out: std.ArrayList(SlashCommand) = .empty;
    if (get(data, "commands")) |list| if (list == .array) for (list.array.items) |cmd| {
        const name = getStr(cmd, "name") orelse continue;
        try out.append(arena, .{ .name = name, .description = getStr(cmd, "description") orelse "" });
    };
    const builtins = [_][2][]const u8{
        .{ "compact", "Compact context" },
        .{ "session", "Session statistics" },
        .{ "name", "Set session name" },
        .{ "export", "Export session to HTML" },
        .{ "autocompact", "Toggle automatic compaction" },
        .{ "steering", "Steering queue mode" },
        .{ "follow-up", "Follow-up queue mode" },
    };
    for (builtins) |b| {
        var present = false;
        for (out.items) |cmd| if (eql(cmd.name, b[0])) {
            present = true;
        };
        if (!present) try out.append(arena, .{ .name = b[0], .description = b[1] });
    }
    return out.items;
}

/// Pi 0.85.1 or newer (an unparsable version is allowed).
fn piVersionSupported(version: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, std.mem.trimStart(u8, version, "v"), ".-+ ");
    const want = [_]u64{ 0, 85, 1 };
    for (want) |w| {
        const part = it.next() orelse return true;
        const n = std.fmt.parseInt(u64, part, 10) catch return true;
        if (n != w) return n > w;
    }
    return true;
}

fn piProbe(c: *Ctx, _: HarnessId, cwd: []const u8) anyerror![]SlashCommand {
    const exe = try c.resolve("pi", pi_hint);
    var vbuf: [128]u8 = undefined;
    if (harness_version.binaryVersionString(c.io, exe, &vbuf)) |v| {
        if (!piVersionSupported(v)) return c.protocol("Pi {s} is unsupported; update Pi to 0.85.1 or newer", .{v});
    }
    var env = try c.childEnv(exe, true);
    const argv = [_][]const u8{ exe, "--mode", "rpc", "--no-themes", "--no-session" };
    const proc = try c.spawn(&argv, cwd, &env, .{}, .io_not_found);
    defer retire(proc);
    const ms = budgetMs(60_000);
    const deadline = nowNs(c.io) + @as(i96, ms) * std.time.ns_per_ms;
    proc.armDeadline(ms);
    proc.writeLine("{\"id\":\"harness-1\",\"type\":\"get_commands\"}") catch {};
    while (proc.readLine() catch null) |raw| {
        if (raw.len + 1 > pi_max_frame) return c.protocol("Pi RPC frame exceeds 32 MiB", .{});
        if (std.mem.trim(u8, raw, " \t\r\n\x0b\x0c").len == 0) continue;
        const frame = json.parseFromSliceLeaky(json.Value, c.arena, raw, .{ .allocate = .alloc_always }) catch |e|
            return c.protocol("Invalid Pi RPC JSON: {s}", .{@errorName(e)});
        const kind = getStr(frame, "type") orelse "";
        if (eql(kind, "response") and eql(getStr(frame, "id") orelse "", "harness-1")) {
            const ok = if (get(frame, "success")) |s| s == .bool and s.bool else false;
            if (!ok) return c.protocol("Pi {s}: {s}", .{ getStr(frame, "command") orelse "", getStr(frame, "error") orelse "command failed" });
            return piCommandsFrom(c.arena, get(frame, "data") orelse .null);
        }
        if (eql(kind, "extension_ui_request")) {
            // Discovery has no one to answer a dialog: cancel it.
            const method = getStr(frame, "method") orelse "";
            for ([_][]const u8{ "select", "confirm", "input", "editor" }) |m| if (eql(method, m)) {
                const id = try jsonText(c.arena, get(frame, "id") orelse .null);
                proc.writeLine(try std.fmt.allocPrint(c.arena, "{{\"cancelled\":true,\"id\":{s},\"type\":\"extension_ui_response\"}}", .{id})) catch {};
                break;
            };
        }
    }
    if (nowNs(c.io) >= deadline) return c.protocol("Pi discovery timed out", .{});
    return c.protocol("Pi stdout closed", .{});
}

fn piSkills(c: *Ctx, cwd: []const u8) ![]const Skill {
    const skills = try c.discover(.pi, cwd);
    const commands = try workspaceCommands(c, .pi, cwd, piProbe);
    var list: std.ArrayList(Skill) = .fromOwnedSlice(skills);
    try sd.attachAdvertisedCommands(c.arena, .pi, &list, commands);
    return list.items;
}

// ── OpenCode (`opencode/mod.rs` `skills`, `Server`, `commands_wire`) ───────

const opencode_hint = "opencode (searched PATH, the login shell's PATH, ~/.opencode/bin, ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE, %APPDATA%\\npm, and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; install with `curl -fsSL https://opencode.ai/install | bash` or `npm install -g @opencode/cli`, then `opencode auth login`; set OPENCODE_EXECUTABLE to override)";

/// Concurrent picker/composer probes share one boot at a time.
var opencode_probe_lock: Io.Mutex = .init;

const Protocol = enum { v1, v2 };

const HttpResponse = struct { status: u16, body: []const u8 };

/// `http::StatusCode`'s display.
fn statusText(arena: Allocator, code: u16) ![]const u8 {
    const reason: ?[]const u8 = switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => null,
    };
    return std.fmt.allocPrint(arena, "{d} {s}", .{ code, reason orelse "<unknown status code>" });
}

/// `encode_directory`: percent-encode all but `A-Za-z0-9-_.~/`.
pub fn encodeDirectory(arena: Allocator, dir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (dir) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~' or b == '/') {
            try out.append(arena, b);
        } else try out.print(arena, "%{X:0>2}", .{b});
    }
    return out.items;
}

/// `application/x-www-form-urlencoded` (reqwest's `.query`).
fn formEncode(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '*' or b == '-' or b == '.' or b == '_') {
            try out.append(arena, b);
        } else if (b == ' ') {
            try out.append(arena, '+');
        } else try out.print(arena, "%{X:0>2}", .{b});
    }
    return out.items;
}

/// `truncate_body`: trimmed, at most 300 bytes plus `…`.
fn truncateBody(arena: Allocator, body: []const u8) ![]const u8 {
    const t = sd.trimUnicode(body);
    if (t.len <= 300) return t;
    var end: usize = 300;
    while (end > 0 and (t[end] & 0xc0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}…", .{t[0..end]});
}

const HttpError = error{ Connect, Timeout, Closed, BadResponse, OutOfMemory };

/// Read once from `stream`, waiting at most until `deadline`; 0 = closed.
fn readSome(io: Io, stream: net.Stream, buf: []u8, deadline: i96) HttpError!usize {
    const left_ns = deadline - nowNs(io);
    if (left_ns <= 0) return error.Timeout;
    const left_ms: i32 = @intCast(@min(@divFloor(left_ns, std.time.ns_per_ms) + 1, std.math.maxInt(i32)));
    if (comptime builtin.os.tag == .windows) {
        const msg = stream.socket.receiveTimeout(io, buf, .{ .duration = .{ .raw = .fromMilliseconds(left_ms), .clock = .awake } }) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            else => return error.Closed,
        };
        return msg.data.len;
    } else {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, left_ms) catch return error.Closed;
        if (ready == 0) return error.Timeout;
        return std.posix.read(stream.socket.handle, buf) catch return error.Closed;
    }
}

/// Decode a chunked body; null while incomplete.
fn dechunk(arena: Allocator, raw: []const u8) HttpError!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (true) {
        const nl = std.mem.indexOfPos(u8, raw, i, "\r\n") orelse return null;
        const size_text = std.mem.trim(u8, raw[i..nl], " ");
        const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
        const size = std.fmt.parseInt(usize, size_text[0..semi], 16) catch return error.BadResponse;
        i = nl + 2;
        if (size == 0) return out.items;
        if (raw.len < i + size + 2) return null;
        try out.appendSlice(arena, raw[i .. i + size]);
        i += size + 2;
    }
}

/// One `GET` to the local server (`Connection: close`), bounded by `timeout_ms`.
fn httpGet(arena: Allocator, io: Io, port: u16, auth: []const u8, target: []const u8, extra_headers: []const u8, timeout_ms: u32) HttpError!HttpResponse {
    const deadline = nowNs(io) + @as(i96, timeout_ms) * std.time.ns_per_ms;
    const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return error.Connect;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return error.Connect;
    defer stream.close(io);
    {
        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        w.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: {s}\r\n{s}Accept: application/json\r\nConnection: close\r\n\r\n", .{ target, port, auth, extra_headers }) catch return error.Closed;
        w.interface.flush() catch return error.Closed;
    }
    var data: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    var head_end: ?usize = null;
    var length: ?usize = null;
    var chunked = false;
    var status: u16 = 0;
    while (true) {
        const n = try readSome(io, stream, &chunk, deadline);
        if (n > 0) try data.appendSlice(arena, chunk[0..n]);
        if (data.items.len > 64 * 1024 * 1024) return error.BadResponse;
        if (head_end == null) if (std.mem.indexOf(u8, data.items, "\r\n\r\n")) |he| {
            head_end = he + 4;
            var lines = std.mem.splitSequence(u8, data.items[0..he], "\r\n");
            const status_line = lines.next() orelse return error.BadResponse;
            var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
            _ = parts.next();
            status = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return error.BadResponse;
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..colon], " ");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(name, "content-length")) length = std.fmt.parseInt(usize, value, 10) catch null;
                if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.findIgnoreCase(value, "chunked") != null) chunked = true;
            }
            if (status == 204 or status == 304) return .{ .status = status, .body = "" };
        };
        if (head_end) |he| {
            const raw = data.items[he..];
            if (chunked) {
                if (try dechunk(arena, raw)) |body| return .{ .status = status, .body = body };
            } else if (length) |len| {
                if (raw.len >= len) return .{ .status = status, .body = raw[0..len] };
            }
            if (n == 0) {
                if (chunked or length != null) return error.BadResponse;
                return .{ .status = status, .body = raw };
            }
        } else if (n == 0) return error.Closed;
    }
}

const Server = struct {
    proc: *AgentProc,
    port: u16,
    auth: []const u8,
    protocol: Protocol = .v1,
};

fn freePort(io: Io) !u16 {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    return srv.socket.address.ip4.port;
}

/// `Protocol::detect`: newest API first; a version-bearing JSON answer
/// names the generation, nothing yet means still booting.
fn detectProtocol(c: *Ctx, s: *const Server) !?Protocol {
    const probes = [_]struct { []const u8, Protocol }{ .{ "/api/info", .v2 }, .{ "/api/status", .v2 }, .{ "/api/health", .v2 }, .{ "/global/health", .v1 } };
    for (probes) |p| {
        const resp = httpGet(c.arena, c.io, s.port, s.auth, p[0], "", 2000) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue,
        };
        if (resp.status == 401 or resp.status == 403) return c.protocol("opencode authentication rejected at {s}: {s}", .{ p[0], try statusText(c.arena, resp.status) });
        if (resp.status < 200 or resp.status >= 300) continue;
        const v = parseLine(c.arena, resp.body) orelse continue;
        const version = getStr(v, "version") orelse (if (get(v, "data")) |d| getStr(d, "version") else null) orelse continue;
        if (sd.trimUnicode(version).len == 0) continue;
        return p[1];
    }
    return null;
}

/// `Server::spawn`: `opencode serve` on a free loopback port with a per-run
/// Basic password, ready once a health endpoint answers with a version.
fn spawnServer(c: *Ctx, directory: []const u8) !Server {
    const exe = try c.resolve("opencode", opencode_hint);
    const port = freePort(c.io) catch return c.protocol("no free localhost port for opencode serve", .{});
    var pw: [16]u8 = undefined;
    c.io.random(&pw);
    const password = try std.fmt.allocPrint(c.arena, "{x}", .{&pw});
    var env = try c.childEnv(exe, false);
    try env.put("OPENCODE_SERVER_PASSWORD", password);
    try env.put("OPENCODE_CLIENT", "harness");
    const port_s = try std.fmt.allocPrint(c.arena, "{d}", .{port});
    const argv = [_][]const u8{ exe, "serve", "--port", port_s, "--hostname", "127.0.0.1" };
    const proc = try c.spawn(&argv, directory, &env, .{ .stdin = false, .stdout = false }, .binary_hint);
    errdefer retire(proc);
    const cred = try std.fmt.allocPrint(c.arena, "opencode:{s}", .{password});
    const b64 = try c.arena.alloc(u8, std.base64.standard.Encoder.calcSize(cred.len));
    var server: Server = .{ .proc = proc, .port = port, .auth = try std.fmt.allocPrint(c.arena, "Basic {s}", .{std.base64.standard.Encoder.encode(b64, cred)}) };

    const startup_s: u64 = if (c.env.get("HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS")) |v| std.fmt.parseInt(u64, v, 10) catch 300 else 300;
    const startup_ms: u64 = if (timeout_override_ms) |o| o else startup_s * 1000;
    const deadline = nowNs(c.io) + @as(i96, startup_ms) * std.time.ns_per_ms;
    while (true) {
        if (proc.stderr_closed.load(.acquire)) {
            const term = proc.wait();
            const tail = proc.stderrTail(c.arena);
            return c.protocol("{s}", .{try agent_proc.crashMessage(c.arena, "opencode serve", term, tail)});
        }
        if (try detectProtocol(c, &server)) |p| {
            server.protocol = p;
            return server;
        }
        if (nowNs(c.io) >= deadline) return c.protocol("opencode serve did not become healthy within {d}s (raise HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS if this machine's plugin load is genuinely slow)", .{startup_ms / 1000});
        c.io.sleep(.fromMilliseconds(150), .awake) catch {};
    }
}

/// `unwrap_data`: 2.x wraps answers in `{data}`.
fn unwrapData(v: json.Value) json.Value {
    if (get(v, "data")) |d| if (d == .object or d == .array) return d;
    return v;
}

/// `commands_wire(Some(directory))`.
fn commandsWire(c: *Ctx, s: *const Server, directory: []const u8) !json.Value {
    const path: []const u8 = if (s.protocol == .v1) "/command" else "/api/command";
    const target = if (s.protocol == .v1) try std.fmt.allocPrint(c.arena, "{s}?directory={s}", .{ path, try formEncode(c.arena, directory) }) else path;
    const header = try std.fmt.allocPrint(c.arena, "x-opencode-directory: {s}\r\n", .{try encodeDirectory(c.arena, directory)});
    const resp = httpGet(c.arena, c.io, s.port, s.auth, target, header, budgetMs(60_000)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return c.protocol("opencode GET {s}: error sending request for url (http://127.0.0.1:{d}{s})", .{ path, s.port, target }),
    };
    if (resp.status < 200 or resp.status >= 300) return c.protocol("opencode GET {s}: {s} {s}", .{ path, try statusText(c.arena, resp.status), try truncateBody(c.arena, resp.body) });
    const v = parseLine(c.arena, resp.body) orelse return c.protocol("opencode GET {s}: error decoding response body", .{path});
    return unwrapData(v);
}

/// `merge_skill_commands`: OpenCode marks skill commands with `source: skill`.
pub fn mergeOpencodeCommands(arena: Allocator, skills: *std.ArrayList(Skill), commands: json.Value) !void {
    if (commands != .array) return;
    for (commands.array.items) |cmd| {
        if (!eql(getStr(cmd, "source") orelse "", "skill")) continue;
        const name = getStr(cmd, "name") orelse continue;
        if (!sd.validSkillCommandName(name)) continue;
        var found = false;
        for (skills.items) |*s| if (eql(s.name, name)) {
            s.command = .{ .name = name, .harness = .opencode };
            found = true;
            break;
        };
        if (!found) try skills.append(arena, .{
            .name = name,
            .path = try std.fmt.allocPrint(arena, "opencode-skill:{s}", .{name}),
            .description = getStr(cmd, "description") orelse "",
            .enabled = true,
            .command = .{ .name = name, .harness = .opencode },
        });
    }
}

fn opencodeSkills(c: *Ctx, cwd: []const u8) ![]const Skill {
    const skills = try c.discover(.opencode, cwd);
    opencode_probe_lock.lockUncancelable(c.io);
    defer opencode_probe_lock.unlock(c.io);
    if (!std.unicode.utf8ValidateSlice(cwd)) return c.protocol("Project path is not UTF-8", .{});
    const server = try spawnServer(c, cwd);
    defer retire(server.proc);
    const commands = try commandsWire(c, &server, cwd);
    var list: std.ArrayList(Skill) = .fromOwnedSlice(skills);
    try mergeOpencodeCommands(c.arena, &list, commands);
    return list.items;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

var test_bin_dir: []const u8 = "";

fn testResolve(gpa: Allocator, io: Io, id: []const u8) anyerror!?[]u8 {
    const p = try std.fs.path.join(gpa, &.{ test_bin_dir, id });
    Io.Dir.cwd().access(io, p, .{}) catch {
        gpa.free(p);
        return null;
    };
    return p;
}

const Rig = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    base: []const u8,
    env: Environ.Map,

    fn create() !*Rig {
        if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
        const r = try testing.allocator.create(Rig);
        r.* = .{ .tmp = testing.tmpDir(.{}), .arena_state = .init(testing.allocator), .base = undefined, .env = .init(testing.allocator) };
        r.base = try r.tmp.dir.realPathFileAlloc(testing.io, ".", r.a());
        // `.git` at the base keeps every ancestor walk inside the rig.
        for ([_][]const u8{ "home", "bin", "repo/.git", ".git" }) |d| try r.tmp.dir.createDirPath(testing.io, d);
        try r.env.put("HOME", try r.path("home"));
        try r.env.put("PATH", "/usr/bin:/bin");
        try r.env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        try r.env.put("CLAUDECODE", "1");
        catalog_core.env_override = &r.env;
        test_bin_dir = try r.path("bin");
        catalog_core.resolve_cli = testResolve;
        timeout_override_ms = null;
        kill_grace_ms = 500;
        resetCaches();
        return r;
    }

    fn destroy(r: *Rig) void {
        catalog_core.env_override = null;
        catalog_core.resolve_cli = struct {
            fn none(_: Allocator, _: Io, _: []const u8) anyerror!?[]u8 {
                return null;
            }
        }.none;
        timeout_override_ms = null;
        kill_grace_ms = 3000;
        resetCaches();
        r.env.deinit();
        r.arena_state.deinit();
        r.tmp.cleanup();
        testing.allocator.destroy(r);
    }

    fn a(r: *Rig) Allocator {
        return r.arena_state.allocator();
    }

    fn path(r: *Rig, rel: []const u8) ![]const u8 {
        return std.fs.path.join(r.a(), &.{ r.base, rel });
    }

    fn write(r: *Rig, rel: []const u8, body: []const u8) !void {
        if (std.fs.path.dirname(rel)) |parent| try r.tmp.dir.createDirPath(testing.io, parent);
        try r.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = body });
    }

    /// A mock CLI: `bin/<id>`, a shell script that replays a handshake.
    fn script(r: *Rig, id: []const u8, body: []const u8) !void {
        const rel = try std.fmt.allocPrint(r.a(), "bin/{s}", .{id});
        try r.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = body, .flags = .{ .permissions = .executable_file } });
    }

    fn read(r: *Rig, rel: []const u8) ![]u8 {
        return r.tmp.dir.readFileAlloc(testing.io, rel, r.a(), .limited(1024 * 1024));
    }

    /// `listSkillsJson` with a wall-clock bound on the whole call.
    fn list(r: *Rig, id: []const u8, cwd_rel: []const u8, max_ms: u64) !Result {
        const start = nowNs(testing.io);
        const res = try listSkillsJson(testing.allocator, testing.io, id, try r.path(cwd_rel));
        const took_ms: u64 = @intCast(@divFloor(nowNs(testing.io) - start, std.time.ns_per_ms));
        if (took_ms > max_ms) {
            res.deinit(testing.allocator);
            std.debug.print("ListSkills took {d} ms (limit {d})\n", .{ took_ms, max_ms });
            return error.TestTimeout;
        }
        return res;
    }

    fn expectOk(r: *Rig, id: []const u8, cwd_rel: []const u8, want: []const u8) !void {
        const res = try r.list(id, cwd_rel, 30_000);
        defer res.deinit(testing.allocator);
        switch (res) {
            .ok => |text| try testing.expectEqualStrings(want, text),
            .err => |msg| {
                std.debug.print("unexpected error: {s}\n", .{msg});
                return error.TestUnexpectedResult;
            },
        }
    }

    fn expectErr(r: *Rig, id: []const u8, cwd_rel: []const u8, want: []const u8) !void {
        const res = try r.list(id, cwd_rel, 30_000);
        defer res.deinit(testing.allocator);
        switch (res) {
            .err => |msg| try testing.expectEqualStrings(want, msg),
            .ok => |text| {
                std.debug.print("unexpected success: {s}\n", .{text});
                return error.TestUnexpectedResult;
            },
        }
    }

    /// The JSON for one skill row (paths under the rig).
    fn row(r: *Rig, name: []const u8, rel: []const u8, desc: []const u8, cmd: ?[]const u8, harness: []const u8) ![]const u8 {
        const p = if (std.mem.indexOfScalar(u8, rel, ':') != null) rel else try r.path(rel);
        const head = try std.fmt.allocPrint(r.a(), "{{\"name\":\"{s}\",\"path\":\"{s}\",\"description\":\"{s}\",\"enabled\":true", .{ name, p, desc });
        if (cmd) |c| return std.fmt.allocPrint(r.a(), "{s},\"command\":{{\"name\":\"{s}\",\"harness\":\"{s}\"}}}}", .{ head, c, harness });
        return std.fmt.allocPrint(r.a(), "{s}}}", .{head});
    }
};

const version_guard =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\case "$1" in --version) echo "mock 1.0.0"; exit 0;; esac
    \\
;

test "skills_commands: Mock answers null; Cursor reads disk only; an unknown id is refused" {
    const r = try Rig.create();
    defer r.destroy();
    try r.expectOk("mock", "repo", "null");
    try r.write("repo/.cursor/skills/tidy/SKILL.md", "---\ndescription: Tidy up\n---\n");
    try r.expectOk("cursor", "repo", try std.fmt.allocPrint(r.a(), "[{s}]", .{try r.row("tidy", "repo/.cursor/skills/tidy/SKILL.md", "Tidy up", null, "")}));
    try r.expectErr("nope", "repo", "unknown harness: nope");
}

const claude_ok = version_guard ++
    \\pwd > "$d/claude.cwd"
    \\printf '%s\n' "$@" > "$d/claude.argv"
    \\env > "$d/claude.env"
    \\echo x >> "$d/claude.count"
    \\read line
    \\printf '%s\n' "$line" > "$d/claude.req"
    \\sleep 0.3
    \\echo 'not json'
    \\echo '{"type":"system","subtype":"init"}'
    \\echo '{"type":"control_response","response":{"request_id":"other","subtype":"success"}}'
    \\echo '{"type":"control_response","response":{"subtype":"success","request_id":"harness-command-probe","response":{"commands":[{"name":"review","description":"Review","argumentHint":" [path] "},{"name":"  "},{"name":"compact"}]}}}'
    \\exec sleep 30
    \\
;

test "skills_commands: Claude keeps shared skills and only advertised native ones" {
    const r = try Rig.create();
    defer r.destroy();
    try r.script("claude-code", claude_ok);
    try r.write("repo/.claude/skills/review/SKILL.md", "---\nname: review\ndescription: Review code\n---\n");
    try r.write("repo/.claude/skills/secret/SKILL.md", "---\nname: secret\n---\n");
    try r.write("repo/.agents/skills/compact/SKILL.md", "---\nname: compact\n---\n");
    const want = try std.fmt.allocPrint(r.a(), "[{s},{s}]", .{
        try r.row("compact", "repo/.agents/skills/compact/SKILL.md", "", null, ""),
        try r.row("review", "repo/.claude/skills/review/SKILL.md", "Review code", "review", "claude-code"),
    });
    try r.expectOk("claude-code", "repo", want);
    try testing.expectEqualStrings("{\"request\":{\"subtype\":\"initialize\"},\"request_id\":\"harness-command-probe\",\"type\":\"control_request\"}\n", try r.read("bin/claude.req"));
    try testing.expectEqualStrings("--print\n--input-format\nstream-json\n--output-format\nstream-json\n--verbose\n", try r.read("bin/claude.argv"));
    try testing.expectEqualStrings(try std.fmt.allocPrint(r.a(), "{s}\n", .{try r.path("repo")}), try r.read("bin/claude.cwd"));
    const env = try r.read("bin/claude.env");
    // compose_child_path: the CLI's folder first, Harness's tools last.
    try testing.expect(std.mem.indexOf(u8, env, try std.fmt.allocPrint(r.a(), "PATH={s}:/usr/bin:/bin:{s}\n", .{ try r.path("bin"), try r.path("home/.harness/tools/bin") })) != null);

    // A later request probes again; overlapping ones share a probe.
    try r.expectOk("claude-code", "repo", want);
    try testing.expectEqualStrings("x\nx\n", try r.read("bin/claude.count"));
    const T = struct {
        fn run(rr: *Rig, out: *?Result) void {
            out.* = rr.list("claude-code", "repo", 30_000) catch null;
        }
    };
    var results: [2]?Result = .{ null, null };
    const t1 = try std.Thread.spawn(.{}, T.run, .{ r, &results[0] });
    const t2 = try std.Thread.spawn(.{}, T.run, .{ r, &results[1] });
    t1.join();
    t2.join();
    for (results) |res| {
        const x = res orelse return error.TestUnexpectedResult;
        defer x.deinit(testing.allocator);
        try testing.expectEqualStrings(want, x.ok);
    }
    // The overlapping pair shared one probe.
    try testing.expectEqualStrings("x\nx\nx\n", try r.read("bin/claude.count"));
}

test "skills_commands: Claude errors: missing CLI, error reply, early exit, timeout" {
    const r = try Rig.create();
    defer r.destroy();
    try r.write("repo/.claude/skills/review/SKILL.md", "body");
    try r.expectErr("claude-code", "repo", "harness binary not found: " ++ claude_hint);
    try r.script("claude-code", version_guard ++
        \\read line
        \\echo '{"type":"control_response","response":{"subtype":"error","request_id":"harness-command-probe","error":"not logged in"}}'
        \\exec sleep 30
        \\
    );
    try r.expectErr("claude-code", "repo", "harness protocol error: not logged in");
    try r.script("claude-code", version_guard ++ "read line\nexit 3\n");
    try r.expectErr("claude-code", "repo", "harness protocol error: claude exited before answering the initialize control request");
    try r.script("claude-code", version_guard ++ "exec sleep 30\n");
    timeout_override_ms = 400;
    try r.expectErr("claude-code", "repo", "harness protocol error: Claude initialize timed out");
}

const codex_ok = version_guard ++
    \\read l
    \\echo '{"jsonrpc":"2.0","method":"noise","params":{}}'
    \\echo '{"id":1,"result":{"userAgent":"mock"}}'
    \\read l
    \\read l
    \\printf '%s\n' "$l" > "$d/codex.req"
    \\echo '{"id":"2","result":{"data":[{"cwd":"/w","skills":[{"name":"lint","path":"/w/.codex/skills/lint/SKILL.md","description":"long","interface":{"shortDescription":"Short"}},{"name":"lint","path":"/w/.codex/skills/lint/SKILL.md"},{"name":"bad name","path":"/p"},{"name":"off","path":"/w/off/SKILL.md","description":"Off","enabled":false}]}]}}'
    \\exec sleep 30
    \\
;

test "skills_commands: Codex lists skills/list's catalog; errors carry the method" {
    const r = try Rig.create();
    defer r.destroy();
    try r.script("codex", codex_ok);
    try r.expectOk("codex", "repo",
        \\[{"name":"lint","path":"/w/.codex/skills/lint/SKILL.md","description":"Short","enabled":true},{"name":"off","path":"/w/off/SKILL.md","description":"Off","enabled":false}]
    );
    try testing.expectEqualStrings(try std.fmt.allocPrint(r.a(), "{{\"id\":2,\"jsonrpc\":\"2.0\",\"method\":\"skills/list\",\"params\":{{\"cwds\":[\"{s}\"],\"forceReload\":true}}}}\n", .{try r.path("repo")}), try r.read("bin/codex.req"));
    try r.script("codex", version_guard ++
        \\read l
        \\echo '{"jsonrpc":"2.0","id":1,"result":{}}'
        \\read l
        \\read l
        \\echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"boom","data":"detail"}}'
        \\exec sleep 30
        \\
    );
    try r.expectErr("codex", "repo", "harness protocol error: skills/list: boom (code -32000): detail");
    try r.script("codex", version_guard ++ "read l\nexit 0\n");
    try r.expectErr("codex", "repo", "harness protocol error: initialize: app-server exited before responding");
    try r.script("codex", version_guard ++
        \\read l
        \\echo '{"id":1,"error":{"code":-32603,"message":"chatgpt-new api error [token_expired]: expired"}}'
        \\exec sleep 30
        \\
    );
    try r.expectErr("codex", "repo", reauth_text);
    try r.script("codex", version_guard ++ "exec sleep 30\n");
    timeout_override_ms = 400;
    try r.expectErr("codex", "repo", "harness protocol error: command discovery timed out");
}

const graff_ok = version_guard ++
    \\printf '%s\n' "$@" > "$d/graff.argv"
    \\env > "$d/graff.env"
    \\read l
    \\printf '%s\n' "$l" > "$d/graff.init"
    \\echo 'Open the following link to authenticate the ACP server: https://example.invalid'
    \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"_meta":{"availableCommands":[{"name":"from-init"}]}}}}'
    \\read l
    \\printf '%s\n' "$l" > "$d/graff.session"
    \\echo '{"jsonrpc":"2.0","id":99,"method":"fs/read_text_file","params":{}}'
    \\echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}'
    \\echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review code","input":{"hint":"path"}},{"name":"compact"}]}}}'
    \\read l
    \\printf '%s\n' "$l" > "$d/graff.reply"
    \\exec sleep 30
    \\
;

test "skills_commands: ACP binds advertised commands after session/new; shared skills stay unbound" {
    const r = try Rig.create();
    defer r.destroy();
    try r.script("graff", graff_ok);
    try r.write("repo/.claude/skills/review/SKILL.md", "---\ndescription: Native review\n---\n");
    try r.write("repo/.agents/skills/compact/SKILL.md", "Body");
    try r.expectOk("graff", "repo", try std.fmt.allocPrint(r.a(), "[{s},{s}]", .{
        try r.row("compact", "repo/.agents/skills/compact/SKILL.md", "", null, ""),
        try r.row("review", "repo/.claude/skills/review/SKILL.md", "Native review", "review", "graff"),
    }));
    try testing.expectEqualStrings("acp\n--yolo\n", try r.read("bin/graff.argv"));
    try testing.expectEqualStrings(
        \\{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"clientCapabilities":{"elicitation":{"form":{}},"fs":{"readTextFile":false,"writeTextFile":false},"session":{"compaction":{}},"terminal":false},"clientInfo":{"name":"harness","title":"Harness","version":"0.0.0"},"protocolVersion":1}}
        \\
    , try r.read("bin/graff.init"));
    try testing.expectEqualStrings(try std.fmt.allocPrint(r.a(), "{{\"id\":2,\"jsonrpc\":\"2.0\",\"method\":\"session/new\",\"params\":{{\"cwd\":\"{s}\",\"mcpServers\":[]}}}}\n", .{try r.path("repo")}), try r.read("bin/graff.session"));
    try testing.expectEqualStrings("{\"error\":{\"code\":-32601,\"message\":\"unsupported during discovery\"},\"id\":99,\"jsonrpc\":\"2.0\"}\n", try r.read("bin/graff.reply"));
    const env = try r.read("bin/graff.env");
    for ([_][]const u8{ "GRAFF_AUTO_ISOLATE=0\n", "GRAFF_CODEX_WS=off\n", "GRAFF_HOST_APP=harness/0.0.0\n" }) |line| try testing.expect(std.mem.indexOf(u8, env, line) != null);
    try testing.expect(std.mem.indexOf(u8, env, "CLAUDECODE=") == null);
}

test "skills_commands: ACP keeps the handshake's commands when session/new is refused or quiet" {
    const r = try Rig.create();
    defer r.destroy();
    try r.write("repo/.grok/skills/from-init/SKILL.md", "Body");
    try r.write("repo/.grok/skills/hidden/SKILL.md", "Body");
    try r.script("grok", version_guard ++
        \\printf '%s\n' "$@" > "$d/grok.argv"
        \\read l
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"availableCommands":[{"name":"from-init","description":"Init"}]}}'
        \\read l
        \\echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"auth required"}}'
        \\exec sleep 30
        \\
    );
    const want = try std.fmt.allocPrint(r.a(), "[{s},{s}]", .{
        try r.row("from-init", "repo/.grok/skills/from-init/SKILL.md", "", "from-init", "grok"),
        try r.row("hidden", "repo/.grok/skills/hidden/SKILL.md", "", null, ""),
    });
    try r.expectOk("grok", "repo", want);
    try testing.expectEqualStrings("--no-auto-update\nagent\n--no-leader\nstdio\n", try r.read("bin/grok.argv"));
    // A session that never sends an update: the 2 s window ends the probe.
    try r.script("grok", version_guard ++
        \\read l
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"availableCommands":[{"name":"from-init"}]}}'
        \\read l
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s"}}'
        \\exec sleep 30
        \\
    );
    const start = nowNs(testing.io);
    try r.expectOk("grok", "repo", want);
    try testing.expect(nowNs(testing.io) - start >= 1900 * std.time.ns_per_ms);
}

test "skills_commands: ACP errors: missing CLI, missing folder, exit, timeout" {
    const r = try Rig.create();
    defer r.destroy();
    try r.expectErr("devin", "repo", "harness binary not found: " ++ comptime acpSpec(.devin).hint);
    try r.script("devin", version_guard ++ "read l\nexit 1\n");
    try r.expectErr("devin", "repo", "harness protocol error: initialize: app-server exited before responding");
    const missing = try r.path("gone");
    const msg = try std.fmt.allocPrint(r.a(), "io: Project folder is missing: {s}", .{missing});
    try r.expectErr("devin", "gone", msg);
    try r.script("devin", version_guard ++ "exec sleep 30\n");
    timeout_override_ms = 400;
    try r.expectErr("devin", "repo", "harness protocol error: command discovery timed out");
    // Exo has no skill folders, but still probes its bridge.
    try r.expectErr("exo", "repo", "harness binary not found: " ++ comptime acpSpec(.exo).hint);
}

test "skills_commands: Antigravity gets GEMINI_HOME and refuses an empty one" {
    const r = try Rig.create();
    defer r.destroy();
    try r.write("gem/config/skills/g1/SKILL.md", "Body");
    try r.script("antigravity", version_guard ++
        \\env > "$d/agy.env"
        \\read l
        \\echo '{"jsonrpc":"2.0","id":1,"result":{}}'
        \\read l
        \\echo '{"jsonrpc":"2.0","id":2,"result":{}}'
        \\echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"g1"}]}}}'
        \\exec sleep 30
        \\
    );
    try r.env.put("GEMINI_HOME", try r.path("gem"));
    try r.expectOk("antigravity", "repo", try std.fmt.allocPrint(r.a(), "[{s}]", .{try r.row("g1", "gem/config/skills/g1/SKILL.md", "", "g1", "antigravity")}));
    const env = try r.read("bin/agy.env");
    try testing.expect(std.mem.indexOf(u8, env, try std.fmt.allocPrint(r.a(), "GEMINI_HOME={s}\n", .{try r.path("gem")})) != null);
    try testing.expect(std.mem.indexOf(u8, env, "BROWSER=/usr/bin/true %s\n") != null);
    try r.env.put("GEMINI_HOME", "");
    try r.expectErr("antigravity", "repo", "harness protocol error: GEMINI_HOME is empty; unset it or set an absolute path before signing in");
}

const pi_ok =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\case "$1" in --version) echo "0.90.0"; exit 0;; esac
    \\printf '%s\n' "$@" > "$d/pi.argv"
    \\read l
    \\printf '%s\n' "$l" > "$d/pi.req"
    \\echo '{"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Trust?"}'
    \\read reply
    \\printf '%s\n' "$reply" > "$d/pi.reply"
    \\echo '{"type":"agent_start"}'
    \\echo '{"type":"response","id":"harness-1","command":"get_commands","success":true,"data":{"commands":[{"name":"skill:review","description":"Review"},{"name":"skill:shared"},{"name":"skill:extra","description":"Only advertised"},{"name":"compact","description":"Custom"}]}}'
    \\exec sleep 30
    \\
;

test "skills_commands: Pi binds its skill: commands (shared ones too) and adds advertised-only rows" {
    const r = try Rig.create();
    defer r.destroy();
    try r.script("pi", pi_ok);
    try r.write("repo/.pi/skills/review.md", "---\ndescription: Flat review\n---\n");
    try r.write("repo/.agents/skills/shared/SKILL.md", "Body");
    try r.expectOk("pi", "repo", try std.fmt.allocPrint(r.a(), "[{s},{s},{s}]", .{
        try r.row("review", "repo/.pi/skills/review.md", "Flat review", "skill:review", "pi"),
        try r.row("shared", "repo/.agents/skills/shared/SKILL.md", "", "skill:shared", "pi"),
        try r.row("extra", "harness-skill:pi:extra", "Only advertised", "skill:extra", "pi"),
    }));
    try testing.expectEqualStrings("--mode\nrpc\n--no-themes\n--no-session\n", try r.read("bin/pi.argv"));
    try testing.expectEqualStrings("{\"id\":\"harness-1\",\"type\":\"get_commands\"}\n", try r.read("bin/pi.req"));
    try testing.expectEqualStrings("{\"cancelled\":true,\"id\":\"ui-1\",\"type\":\"extension_ui_response\"}\n", try r.read("bin/pi.reply"));
}

test "skills_commands: Pi errors: old version, failed command, bad JSON, missing CLI" {
    const r = try Rig.create();
    defer r.destroy();
    try r.expectErr("pi", "repo", "harness binary not found: " ++ pi_hint);
    try r.script("pi", "#!/bin/sh\ncase \"$1\" in --version) echo 0.80.0; exit 0;; esac\nexec sleep 30\n");
    try r.expectErr("pi", "repo", "harness protocol error: Pi 0.80.0 is unsupported; update Pi to 0.85.1 or newer");
    try r.script("pi", "#!/bin/sh\ncase \"$1\" in --version) echo 0.91.0; exit 0;; esac\nread l\necho '{\"type\":\"response\",\"id\":\"harness-1\",\"command\":\"get_commands\",\"success\":false,\"error\":\"boom\"}'\nexec sleep 30\n");
    try r.expectErr("pi", "repo", "harness protocol error: Pi get_commands: boom");
    try r.script("pi", "#!/bin/sh\ncase \"$1\" in --version) echo 0.92.0; exit 0;; esac\nread l\necho '{oops'\nexec sleep 30\n");
    const res = try r.list("pi", "repo", 30_000);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .err);
    try testing.expect(std.mem.startsWith(u8, res.err, "harness protocol error: Invalid Pi RPC JSON: "));
}

/// An in-process OpenCode 1.x server: the mock CLI records its port.
const MockOpencode = struct {
    rig: *Rig,
    command_status: []const u8 = "200 OK",
    command_body: []const u8 = "[]",
    log: std.ArrayList(u8) = .empty,
    mu: Io.Mutex = .init,
    stop: std.atomic.Value(bool) = .init(false),
    port: u16 = 0,
    thread: ?std.Thread = null,

    fn run(self: *MockOpencode) void {
        const io = testing.io;
        var waited: u32 = 0;
        const port = while (waited < 5000) : (waited += 10) {
            if (self.rig.tmp.dir.readFileAlloc(io, "bin/opencode.argv", testing.allocator, .limited(4096))) |argv| {
                defer testing.allocator.free(argv);
                var lines = std.mem.splitScalar(u8, argv, '\n');
                _ = lines.next();
                _ = lines.next();
                if (lines.next()) |p| if (std.fmt.parseInt(u16, p, 10)) |n| break n else |_| {};
            } else |_| {}
            io.sleep(.fromMilliseconds(10), .awake) catch {};
            if (self.stop.load(.acquire)) return;
        } else return;
        self.port = port;
        const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true }) catch return;
        defer server.deinit(io);
        while (!self.stop.load(.acquire)) {
            const conn = server.accept(io) catch return;
            self.serve(conn);
        }
    }

    fn serve(self: *MockOpencode, conn: net.Stream) void {
        const io = testing.io;
        defer conn.close(io);
        var rbuf: [8192]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        const line = (r.interface.takeDelimiter('\n') catch null) orelse return;
        var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        _ = it.next();
        const target = testing.allocator.dupe(u8, it.next() orelse "") catch return;
        defer testing.allocator.free(target);
        var dir_header: []const u8 = "";
        var auth_ok = false;
        while (r.interface.takeDelimiter('\n') catch null) |h| {
            const hl = std.mem.trimEnd(u8, h, "\r");
            if (hl.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(hl, "x-opencode-directory:")) dir_header = testing.allocator.dupe(u8, std.mem.trim(u8, hl["x-opencode-directory:".len..], " ")) catch "";
            if (std.ascii.startsWithIgnoreCase(hl, "authorization: Basic ")) auth_ok = true;
        }
        defer if (dir_header.len > 0) testing.allocator.free(dir_header);
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        var status: []const u8 = "404 Not Found";
        var body: []const u8 = "{}";
        if (!auth_ok) {
            status = "401 Unauthorized";
        } else if (eql(path, "/global/health")) {
            status = "200 OK";
            body = "{\"healthy\":true,\"version\":\"1.4.0\"}";
        } else if (eql(path, "/command")) {
            self.mu.lockUncancelable(io);
            self.log.print(testing.allocator, "{s} {s}\n", .{ target, dir_header }) catch {};
            self.mu.unlock(io);
            status = self.command_status;
            body = self.command_body;
        }
        var wb: [1024]u8 = undefined;
        var w = conn.writer(io, &wb);
        // Chunked, like Bun's server, for the command list.
        if (eql(path, "/command")) {
            w.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ status, body.len, body }) catch {};
        } else {
            w.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch {};
        }
        w.interface.flush() catch {};
    }

    fn start(self: *MockOpencode) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn finish(self: *MockOpencode) void {
        self.stop.store(true, .release);
        if (self.port != 0) if (net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
            if (addr.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
        } else |_| {};
        if (self.thread) |t| t.join();
        self.log.deinit(testing.allocator);
    }
};

const opencode_cli = version_guard ++
    \\printf '%s\n' "$@" > "$d/opencode.argv"
    \\env > "$d/opencode.env"
    \\exec sleep 30
    \\
;

test "skills_commands: OpenCode merges source:skill commands from its server" {
    const r = try Rig.create();
    defer r.destroy();
    try r.script("opencode", opencode_cli);
    try r.tmp.dir.createDirPath(testing.io, "my repo/.git");
    try r.write("my repo/.opencode/skills/lint/SKILL.md", "---\ndescription: Lint\n---\n");
    try r.write("my repo/.opencode/skills/plain/SKILL.md", "Body");
    var mock: MockOpencode = .{ .rig = r, .command_body = "[{\"name\":\"lint\",\"source\":\"skill\"},{\"name\":\"init\",\"source\":\"command\"},{\"name\":\"extra\",\"source\":\"skill\",\"description\":\"Server skill\"},{\"name\":\"bad name\",\"source\":\"skill\"}]" };
    try mock.start();
    defer mock.finish();
    timeout_override_ms = 5000;
    try r.expectOk("opencode", "my repo", try std.fmt.allocPrint(r.a(), "[{s},{s},{s}]", .{
        try r.row("lint", "my repo/.opencode/skills/lint/SKILL.md", "Lint", "lint", "opencode"),
        try r.row("plain", "my repo/.opencode/skills/plain/SKILL.md", "", null, ""),
        try r.row("extra", "opencode-skill:extra", "Server skill", "extra", "opencode"),
    }));
    const dir = try r.path("my repo");
    try testing.expectEqualStrings(try std.fmt.allocPrint(r.a(), "/command?directory={s} {s}\n", .{ try formEncode(r.a(), dir), try encodeDirectory(r.a(), dir) }), mock.log.items);
    const env = try r.read("bin/opencode.env");
    try testing.expect(std.mem.indexOf(u8, env, "OPENCODE_CLIENT=harness\n") != null);
    try testing.expect(std.mem.indexOf(u8, env, "OPENCODE_SERVER_PASSWORD=") != null);
}

test "skills_commands: OpenCode errors: HTTP failure, never healthy, early exit, missing CLI" {
    const r = try Rig.create();
    defer r.destroy();
    try r.expectErr("opencode", "repo", "harness binary not found: " ++ opencode_hint);
    try r.script("opencode", opencode_cli);
    {
        var mock: MockOpencode = .{ .rig = r, .command_status = "500 Internal Server Error", .command_body = "{\"error\":\"boom\"}" };
        try mock.start();
        defer mock.finish();
        timeout_override_ms = 5000;
        try r.expectErr("opencode", "repo", "harness protocol error: opencode GET /command: 500 Internal Server Error {\"error\":\"boom\"}");
    }
    try r.tmp.dir.deleteFile(testing.io, "bin/opencode.argv");
    timeout_override_ms = 600;
    try r.expectErr("opencode", "repo", "harness protocol error: opencode serve did not become healthy within 0s (raise HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS if this machine's plugin load is genuinely slow)");
    try r.script("opencode", version_guard ++ "echo 'fatal: config broken' >&2\nexit 2\n");
    timeout_override_ms = 5000;
    try r.expectErr("opencode", "repo", "harness protocol error: opencode serve exited unexpectedly (exit code 2): fatal: config broken");
}

test "skills_commands: pure helpers match Rust's vectors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"z":{"availableCommands":[{"name":"late"}]},"a":{"b":{"availableCommands":[{"name":"early","input":{"hint":"h"}},{"name":""}]}}}
    , .{});
    const cmds = try scanAvailableCommands(a, v);
    try testing.expectEqual(@as(usize, 1), cmds.len);
    try testing.expectEqualStrings("early", cmds[0].name);
    try testing.expectEqualStrings("h", cmds[0].input_hint.?);
    const deep = try json.parseFromSliceLeaky(json.Value, a, "{\"a\":{\"b\":{\"c\":{\"d\":{\"availableCommands\":[{\"name\":\"x\"}]}}}}}", .{});
    try testing.expectEqual(@as(usize, 0), (try scanAvailableCommands(a, deep)).len);
    const err = try json.parseFromSliceLeaky(json.Value, a, "{\"message\":\"bad\",\"code\":-32602,\"data\":{\"z\":1,\"a\":[true]}}", .{});
    try testing.expectEqualStrings("bad (code -32602): {\"a\":[true],\"z\":1}", try responseError(a, err));
    const no_msg = try json.parseFromSliceLeaky(json.Value, a, "{\"code\":1}", .{});
    try testing.expectEqualStrings("{\"code\":1}", try responseError(a, no_msg));
    try testing.expectEqual(@as(?i64, 5), responseId(.{ .string = "5" }));
    try testing.expectEqual(@as(?i64, 5), responseId(.{ .float = 5.0 }));
    try testing.expectEqual(@as(?i64, null), responseId(.{ .float = 5.5 }));
    try testing.expectEqualStrings("openai API key was rejected: nope", try keyRejectedMessage(a, "openai", " nope "));
    try testing.expectEqualStrings("openai API key was rejected. Your sign-in is not affected.", try keyRejectedMessage(a, "openai", ""));
    try testing.expectEqualStrings("Fallback API key failed", try keyRejectedMessage(a, "x", "Fallback API key failed"));
    const reauth = try json.parseFromSliceLeaky(json.Value, a, "{\"kind\":\"reauth_required\",\"provider\":\"codex\",\"login\":{\"command\":\"codex\",\"args\":[\"login\"]}}", .{});
    try testing.expect(isReauth(reauth));
    const pi = try piCommandsFrom(a, try json.parseFromSliceLeaky(json.Value, a, "{\"commands\":[{\"name\":\"compact\",\"description\":\"Mine\"},{\"description\":\"no name\"}]}", .{}));
    try testing.expectEqual(@as(usize, 7), pi.len);
    try testing.expectEqualStrings("Mine", pi[0].description);
    try testing.expect(piVersionSupported("0.85.1") and piVersionSupported("1.0.0") and !piVersionSupported("0.85.0"));
    try testing.expectEqualStrings("a/b%20c%3F", try encodeDirectory(a, "a/b c?"));
    try testing.expectEqualStrings("%2Fa+b", try formEncode(a, "/a b"));
    const long = try a.alloc(u8, 400);
    @memset(long, 'x');
    try testing.expect(std.mem.endsWith(u8, try truncateBody(a, long), "…"));
    const init = try acpInitializeParams(a, .devin, false);
    try testing.expect(std.mem.indexOf(u8, init, "\"_meta\":{\"cognition.ai/subagentSupport\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, try acpInitializeParams(a, .graff, true), "\"subagents\":{}") != null);
}
