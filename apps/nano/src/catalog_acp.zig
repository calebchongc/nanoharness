//! Live model catalogs of the ACP harnesses, ported from
//! `crates/harness/src/acp/{mod.rs, antigravity_paths.rs}` and the parts of
//! `crates/harness/src/jsonrpc.rs` a discovery probe touches:
//!
//! - The `AcpAgentSpec`s' discovery surface (id, display name, launch args,
//!   install hint, static fallback rows, effort-in-model-id, timeouts) for
//!   grok, hermes, antigravity, exo, devin and graff.
//! - `discover_models`: initialize → (grok: authenticate) → `session/new`,
//!   then `models_from_session` (config options first, legacy
//!   `availableModels` as fallback, catalog enrichment, `[1m]` folding,
//!   trait pass-through) and `group_effort_variants` for antigravity.
//! - `model_context` (binary + antigravity's credential files), `model_catalog`
//!   (the per-harness `MemCache`, timeout `discovery * 3 + 1 s`),
//!   `fallback_models` and `models` for grok/hermes/antigravity/exo.
//! - Shared plumbing `catalog_graff.zig` and `catalog_devin.zig` reuse: the
//!   line-based JSON-RPC client (`request` / `request_draining`), agent spawn
//!   (`spawn_agent`'s environment), one-shot command capture, Rust's
//!   `ExitStatus` text.
//!
//! Std-only (plus `catalog_core.zig`, `harness_version.zig`, `agent_proc.zig`),
//! so it is testable with `zig test catalog_acp.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const core = @import("catalog_core.zig");
const harness_version = @import("harness_version.zig");
const agent_proc = @import("agent_proc.zig");
const AgentProc = agent_proc.AgentProc;
const Failure = core.Failure;
const Model = core.Model;
const ModelOption = core.ModelOption;
const Choice = core.Choice;

const is_windows = builtin.os.tag == .windows;

// ── constants and engine-provided values ───────────────────────────────────

/// `DEFAULT_MODEL_DISCOVERY_TIMEOUT`.
pub const default_discovery_timeout_ms: u64 = 10_000;
/// `ANTIGRAVITY_DISCOVERY_TIMEOUT`: the one-file server unpacks on launch.
pub const antigravity_discovery_timeout_ms: u64 = 90_000;
/// `AcpHarness::kill_grace`: SIGTERM → SIGKILL.
pub const kill_grace_ms: u32 = 3_000;

/// `env!("CARGO_PKG_VERSION")`: `initialize.clientInfo.version` and graff's
/// `GRAFF_HOST_APP`. The engine sets it to its build version.
pub var client_version: []const u8 = "0.0.0";

// ── reasoning levels ───────────────────────────────────────────────────────

/// An index into `core.reasoning_levels` (`ReasoningLevel`'s order).
pub const Level = u8;

pub fn levelName(l: Level) []const u8 {
    return core.reasoning_levels[l];
}

/// `norm_id`: ASCII alphanumerics only, lowercased.
pub fn normId(arena: Allocator, id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (id) |c| if (std.ascii.isAlphanumeric(c)) try out.append(arena, std.ascii.toLower(c));
    return out.items;
}

fn normIs(id: []const u8, want: []const u8) bool {
    var i: usize = 0;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (i >= want.len or std.ascii.toLower(c) != want[i]) return false;
        i += 1;
    }
    return i == want.len;
}

/// `reasoning_from_value`.
pub fn reasoningFromValue(value: []const u8) ?Level {
    if (normIs(value, "off")) return 0;
    for (core.reasoning_levels, 0..) |name, i| if (normIs(value, name)) return @intCast(i);
    return null;
}

// ── specs ──────────────────────────────────────────────────────────────────

/// The discovery-relevant part of `AcpAgentSpec`.
pub const Spec = struct {
    /// Wire id (`HarnessId`'s serde name).
    id: []const u8,
    display_name: []const u8,
    /// `args`: what puts the binary in ACP-serving mode.
    args: []const []const u8,
    /// `install_hint`: the `NotInstalled` text.
    install_hint: []const u8,
    /// `models()`: the static fallback rows.
    models: []const Model,
    effort_in_model_id: bool = false,
    /// Grok must `authenticate` before `session/new` in the probe.
    discovery_auth_method: ?[]const u8 = null,
    discovery_timeout_ms: u64 = default_discovery_timeout_ms,
};

const grok_effort = [_][]const u8{ "low", "medium", "high", "xhigh" };

pub const grok_models = [_]Model{
    .{ .id = "grok-4.7", .label = "Grok 4.7", .description = "SpaceXAI's latest frontier model — 500k context", .reasoning_levels = &grok_effort },
    .{ .id = "grok-4.7-build-fast", .label = "Grok 4.7 Fast", .description = "Fast variant of Grok 4.7", .reasoning_levels = &grok_effort },
    .{ .id = "grok-4.6", .label = "Grok 4.6", .description = "xAI's coding model — 500k context", .reasoning_levels = &grok_effort },
    .{ .id = "grok-4.5", .label = "Grok 4.5", .description = "xAI's coding model — 500k context", .reasoning_levels = &grok_effort },
};

pub const devin_models = [_]Model{
    .{ .id = "swe-1-7-medium", .label = "SWE-1.7 Medium", .description = "Devin's default coding model" },
    .{ .id = "claude-fable-5-1-high", .label = "Claude Fable 5.1 High", .description = "Anthropic's frontier model through Devin" },
    .{ .id = "adaptive", .label = "Adaptive", .description = "Devin picks the model per request" },
};

pub const hermes_models = [_]Model{
    .{ .id = "hermes-4-405b", .label = "Hermes 4 405B", .description = "Nous Research's hybrid-reasoning flagship" },
    .{ .id = "hermes-4-70b", .label = "Hermes 4 70B", .description = "Faster Hermes 4 — same post-training, 70B" },
};

pub const exo_models = [_]Model{
    .{ .id = "default", .label = "Exo default", .description = "Runs the model configured in Exo (`./exo.sh --model`)" },
};

pub const antigravity_models = [_]Model{
    .{ .id = "gemini-3.7-flash", .label = "Gemini 3.7 Flash", .reasoning_levels = &.{ "low", "medium", "high" } },
    .{ .id = "gemini-3.1-pro", .label = "Gemini 3.1 Pro", .reasoning_levels = &.{ "low", "high" } },
};

/// The archive install layout the managed antigravity server lives in
/// (`{adapters}/antigravity-acp/1.2.1/agy_acp_server.{par,exe}`).
pub const antigravity_archive_name = "antigravity-acp";
pub const antigravity_archive_version = "1.2.1";

pub const specs = struct {
    pub const grok: Spec = .{
        .id = "grok",
        .display_name = "Grok",
        .args = &.{ "--no-auto-update", "agent", "--no-leader", "stdio" },
        .install_hint = "grok (searched PATH, the login shell's PATH, ~/.local/bin, ~/.grok/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; install with `curl -fsSL https://x.ai/cli/install.sh | bash` or `npm install -g @xai-official/grok`; set GROK_EXECUTABLE to override)",
        .models = &grok_models,
        .discovery_auth_method = "grok.com",
    };
    pub const devin: Spec = .{
        .id = "devin",
        .display_name = "Devin",
        .args = &.{"acp"},
        .install_hint = "devin (searched PATH, the login shell's PATH, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install with `curl -fsSL https://cli.devin.ai/install.sh | bash` or `brew install --cask devin-cli`, then `devin auth login`; set DEVIN_EXECUTABLE to override)",
        .models = &devin_models,
    };
    pub const hermes: Spec = .{
        .id = "hermes",
        .display_name = "Hermes",
        .args = &.{"acp"},
        .install_hint = "hermes (searched PATH, the login shell's PATH, ~/.local/bin, ~/.hermes/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; install with `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`, then `cd ~/.hermes/hermes-agent && uv pip install -e '.[acp]'` for the ACP server; set HERMES_EXECUTABLE to override)",
        .models = &hermes_models,
    };
    pub const graff: Spec = .{
        .id = "graff",
        .display_name = "graff",
        .args = &.{ "acp", "--yolo" },
        .install_hint = "graff (searched PATH, the login shell's PATH, ~/.harness/bin, the app bundle, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install codegraff, then `graff login`; set GRAFF_EXECUTABLE to override)",
        .models = &.{},
    };
    pub const exo: Spec = .{
        .id = "exo",
        .display_name = "Exo",
        .args = &.{"exo-acp"},
        .install_hint = "Exo's agent-cli adapter (install Exo from https://github.com/exoharness/exo, start it with `./exo.sh --setup agent-cli`, and link `exo/scripts/exo-cli` onto PATH; set EXO_AGENT_CLI_SOCKET if the socket isn't ~/.exo/agent-cli.sock)",
        .models = &exo_models,
    };
    pub const antigravity: Spec = .{
        .id = "antigravity",
        .display_name = "Antigravity",
        // The registry launches linux builds with an empty `--uid`.
        .args = if (builtin.os.tag == .linux) &.{"--uid="} else &.{},
        .install_hint = "Antigravity's ACP server is not installed (the agy CLI does not include it): install it from Settings, or set ANTIGRAVITY_ACP_EXECUTABLE to it",
        .models = &antigravity_models,
        .effort_in_model_id = true,
        .discovery_timeout_ms = antigravity_discovery_timeout_ms,
    };
};

// ── small JSON helpers ─────────────────────────────────────────────────────

pub fn field(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn strField(v: json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn arrField(v: json.Value, key: []const u8) ?[]const json.Value {
    const f = field(v, key) orelse return null;
    return if (f == .array) f.array.items else null;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, a.?, b);
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// `Value::as_u64`: a non-negative integer.
pub fn asU64(v: ?json.Value) ?u64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn asI64(v: ?json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// serde_json's compact `Value::to_string` (keys sorted, as its `BTreeMap`).
pub fn writeSerde(w: *std.Io.Writer, v: json.Value) std.Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| if (@floor(f) == f and @abs(f) < 1e16) try w.print("{d}.0", .{f}) else try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeSerdeString(w, s),
        .array => |a| {
            try w.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeSerde(w, item);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            var keys_buf: [64][]const u8 = undefined;
            const n = @min(o.count(), keys_buf.len);
            for (o.keys()[0..n], 0..) |k, i| keys_buf[i] = k;
            const keys = keys_buf[0..n];
            std.mem.sort([]const u8, keys, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            try w.writeByte('{');
            for (keys, 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try writeSerdeString(w, k);
                try w.writeByte(':');
                try writeSerde(w, o.get(k).?);
            }
            try w.writeByte('}');
        },
    }
}

fn writeSerdeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn serdeAlloc(arena: Allocator, v: json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeSerde(&aw.writer, v);
    return aw.written();
}

// ── JSON-RPC error rendering (`jsonrpc.rs`) ────────────────────────────────

/// `HarnessError::ReauthRequired`'s display.
pub const reauth_text = "ChatGPT sign-in expired or was rejected. Sign in again to continue.";

/// `ReauthProvider::from_acp`.
fn reauthFromAcp(data: json.Value) bool {
    if (!eqlOpt(strField(data, "kind"), "reauth_required")) return false;
    const provider = strField(data, "provider") orelse return false;
    const command: []const u8, const args: []const []const u8 = if (std.mem.eql(u8, provider, "chatgpt-new"))
        .{ "graff", &.{ "login", "chatgpt-new" } }
    else if (std.mem.eql(u8, provider, "codex"))
        .{ "codex", &.{"login"} }
    else
        return false;
    const login = field(data, "login") orelse return false;
    if (!eqlOpt(strField(login, "command"), command)) return false;
    const got = arrField(login, "args") orelse return false;
    if (got.len != args.len) return false;
    for (got, args) |g, a| if (g != .string or !std.mem.eql(u8, g.string, a)) return false;
    return true;
}

/// `KeyRejected::from_acp`: the provider id.
fn keyRejectedFromAcp(data: json.Value) ?[]const u8 {
    if (!eqlOpt(strField(data, "kind"), "api_key_rejected")) return null;
    const provider = std.mem.trim(u8, strField(data, "provider") orelse return null, " \t\r\n");
    if (provider.len == 0 or provider.len > 64) return null;
    for (provider) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return null;
    return provider;
}

/// `run_errors::key_rejected_message`.
pub fn keyRejectedMessage(arena: Allocator, provider: []const u8, raw: []const u8) ![]const u8 {
    const message = std.mem.trim(u8, raw, " \t\r\n");
    const lower = try std.ascii.allocLowerString(arena, message);
    for ([_][]const u8{ "api key was rejected", "fallback api key", "sign-in is not affected" }) |needle| {
        if (std.mem.indexOf(u8, lower, needle) != null) return message;
    }
    const p = if (provider.len == 0) "The" else provider;
    if (message.len == 0) return std.fmt.allocPrint(arena, "{s} API key was rejected. Your sign-in is not affected.", .{p});
    return std.fmt.allocPrint(arena, "{s} API key was rejected: {s}", .{ p, message });
}

/// `response_error`: the agent's rejection reason with its code and data.
pub fn responseError(arena: Allocator, err: json.Value) ![]const u8 {
    const message = strField(err, "message") orelse return serdeAlloc(arena, err);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, message);
    if (asI64(field(err, "code"))) |code| try out.print(arena, " (code {d})", .{code});
    if (field(err, "data")) |data| if (data != .null) {
        const detail = if (data == .string) data.string else try serdeAlloc(arena, data);
        if (detail.len > 0) {
            try out.appendSlice(arena, ": ");
            try out.appendSlice(arena, detail);
        }
    };
    return out.items;
}

/// `response_failure` as `RpcClient::request` returns it for `method`.
pub fn responseFailure(arena: Allocator, method: []const u8, err: json.Value) !Failure {
    const code = asI64(field(err, "code"));
    const data = field(err, "data");
    if (code != null and code.? == -32000) if (data) |d| if (reauthFromAcp(d)) return Failure.other(reauth_text);
    if (data) |d| if (keyRejectedFromAcp(d)) |provider| {
        return Failure.other(try keyRejectedMessage(arena, provider, strField(err, "message") orelse ""));
    };
    if (code != null and code.? == -32603 and (data == null or data.? == .null)) {
        if (strField(err, "message")) |m| if (std.mem.startsWith(u8, m, "chatgpt-new api error [token_expired]:")) return Failure.other(reauth_text);
    }
    return Failure.protocol("{s}: {s}", .{ method, try responseError(arena, err) });
}

/// `response_id`: integers, numeric strings and integral floats.
fn responseId(v: json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.2e18) @intFromFloat(f) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

// ── the line-based JSON-RPC client ─────────────────────────────────────────

pub const Outcome = union(enum) { ok: json.Value, err: Failure };

/// `RpcClient` + `request_draining`, single-threaded over an `AgentProc`'s
/// stdio. Values live in `arena`.
pub const Rpc = struct {
    arena: Allocator,
    proc: *AgentProc,
    next_id: i64 = 0,
    /// Notifications and server requests read while a plain `request`
    /// waited; the next draining request handles them (Rust's channel).
    queued: std.ArrayList(json.Value) = .empty,
    closed: bool = false,

    const auth_prefix = "Open the following link to authenticate the ACP server: ";

    fn send(self: *Rpc, line: []const u8) void {
        // A dead child's stdin is tolerated, as `write_loop` does.
        self.proc.writeLine(line) catch {};
    }

    /// The next JSON-RPC object from stdout, null at end of stream.
    fn readMessage(self: *Rpc) ?json.Value {
        while (true) {
            const raw = (self.proc.readLine() catch null) orelse {
                self.closed = true;
                return null;
            };
            const line = std.mem.trim(u8, raw, " \t\r\n");
            if (std.mem.startsWith(u8, line, auth_prefix) or line.len == 0) continue;
            const v = json.parseFromSliceLeaky(json.Value, self.arena, line, .{ .allocate = .alloc_always, .duplicate_field_behavior = .use_last }) catch continue;
            if (v != .object) continue;
            if (v.object.get("jsonrpc")) |ver| if (!(ver == .string and std.mem.eql(u8, ver.string, "2.0"))) continue;
            return v;
        }
    }

    fn respond(self: *Rpc, id: json.Value, result: []const u8) void {
        const line = std.fmt.allocPrint(self.arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{s}}}", .{ json.fmt(id, .{}), result }) catch return;
        self.send(line);
    }

    fn respondError(self: *Rpc, id: json.Value, code: i64, message: []const u8) void {
        const line = std.fmt.allocPrint(self.arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{ json.fmt(id, .{}), code, json.fmt(message, .{}) }) catch return;
        self.send(line);
    }

    /// `handle_server_request` outside a live turn.
    fn serverRequest(self: *Rpc, id: json.Value, method: []const u8, params: json.Value) void {
        if (std.mem.eql(u8, method, "session/request_permission")) {
            const options = arrField(params, "options") orelse &.{};
            const chosen = preferredAllowOption(options);
            if (chosen) |option_id| {
                const result = std.fmt.allocPrint(self.arena, "{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":{f}}}}}", .{json.fmt(option_id, .{})}) catch return;
                self.respond(id, result);
            } else self.respond(id, "{\"outcome\":{\"outcome\":\"cancelled\"}}");
        } else if (std.mem.eql(u8, method, "elicitation/create")) {
            self.respond(id, "{\"action\":\"cancel\"}");
        } else {
            const msg = std.fmt.allocPrint(self.arena, "unsupported method: {s}", .{method}) catch return;
            self.respondError(id, -32601, msg);
        }
    }

    const Drain = struct {
        retain: bool,
        requested: ?[]const u8,
        metadata: std.ArrayList(json.Value) = .empty,
    };

    fn handleIncoming(self: *Rpc, msg: json.Value, d: *Drain) void {
        const method = strField(msg, "method") orelse return;
        const params = field(msg, "params") orelse json.Value.null;
        if (msg.object.get("id")) |id| {
            if (std.mem.eql(u8, method, "session/request_permission") and !optEql(strField(params, "sessionId"), d.requested)) {
                self.respond(id, "{\"outcome\":{\"outcome\":\"cancelled\"}}");
            } else self.serverRequest(id, method, params);
            return;
        }
        if (!d.retain or !std.mem.eql(u8, method, "session/update")) return;
        const update = field(params, "update") orelse return;
        const kind = strField(update, "sessionUpdate") orelse return;
        for ([_][]const u8{ "config_option_update", "available_commands_update", "current_mode_update" }) |k| {
            if (std.mem.eql(u8, kind, k)) {
                if (d.metadata.items.len == 32) _ = d.metadata.orderedRemove(0);
                d.metadata.append(self.arena, params) catch {};
                return;
            }
        }
    }

    /// Send `method` with `params` (JSON text) and wait for its response.
    /// `drain` is `request_draining`: server requests are answered and the
    /// session metadata `session/new` raced is folded into the response.
    pub fn request(self: *Rpc, method: []const u8, params: []const u8, drain: bool) Outcome {
        if (self.closed) return .{ .err = Failure.protocol("{s}: app-server exited before responding", .{method}) };
        self.next_id += 1;
        const id = self.next_id;
        const line = std.fmt.allocPrint(self.arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ id, json.fmt(method, .{}), params }) catch
            return .{ .err = Failure.protocol("{s}: out of memory", .{method}) };
        self.send(line);
        // Discovery requests never carry a `sessionId`.
        var d: Drain = .{
            .retain = drain and (std.mem.eql(u8, method, "session/new") or std.mem.eql(u8, method, "session/load")),
            .requested = null,
        };
        if (drain) {
            for (self.queued.items) |m| self.handleIncoming(m, &d);
            self.queued.clearRetainingCapacity();
        }
        while (self.readMessage()) |msg| {
            const o = msg.object;
            if (strField(msg, "method") == null) {
                const idv = o.get("id") orelse continue;
                if (o.get("result") == null and o.get("error") == null) continue;
                const rid = responseId(idv) orelse continue;
                if (rid != id) continue;
                if (o.get("error")) |e| {
                    return .{ .err = responseFailure(self.arena, method, e) catch Failure.protocol("{s}: out of memory", .{method}) };
                }
                var result = o.get("result").?;
                if (drain) applyMetadata(self.arena, &result, d.metadata.items, d.requested) catch {};
                return .{ .ok = result };
            }
            if (drain) self.handleIncoming(msg, &d) else self.queued.append(self.arena, msg) catch {};
        }
        return .{ .err = Failure.protocol("{s}: app-server exited before responding", .{method}) };
    }
};

/// `preferred_allow_option`.
fn preferredAllowOption(options: []const json.Value) ?[]const u8 {
    const pick = blk: {
        for ([_][]const u8{ "allow_always", "allow_once" }) |kind| {
            for (options) |o| if (eqlOpt(strField(o, "kind"), kind)) break :blk o;
        }
        if (options.len > 0) break :blk options[0];
        return null;
    };
    const id = strField(pick, "optionId") orelse "";
    return if (id.len > 0) id else null;
}

fn setKey(arena: Allocator, target: *json.Value, key: []const u8, value: json.Value) !void {
    // serde's `IndexMut` turns a null into an object.
    if (target.* == .null) target.* = .{ .object = json.ObjectMap.empty };
    if (target.* != .object) return;
    try target.object.put(arena, key, value);
}

/// The tail of `request_draining_for_session`: retained session metadata
/// for this session overrides the response's.
fn applyMetadata(arena: Allocator, response: *json.Value, metadata: []const json.Value, requested: ?[]const u8) !void {
    const sid: ?[]const u8 = strField(response.*, "sessionId") orelse requested;
    for (metadata) |params| {
        if (!optEql(strField(params, "sessionId"), sid)) continue;
        const update = field(params, "update") orelse continue;
        const kind = strField(update, "sessionUpdate") orelse continue;
        if (std.mem.eql(u8, kind, "config_option_update")) {
            if (field(update, "configOptions")) |c| if (c == .array) try setKey(arena, response, "configOptions", c);
        } else if (std.mem.eql(u8, kind, "available_commands_update")) {
            if (field(update, "availableCommands")) |c| if (c == .array) try setKey(arena, response, "availableCommands", c);
        } else if (std.mem.eql(u8, kind, "current_mode_update")) {
            const mode = field(update, "currentModeId") orelse continue;
            if (mode != .string) continue;
            const modes = field(response.*, "modes");
            var obj: json.Value = if (modes != null and modes.? == .object) modes.? else .{ .object = json.ObjectMap.empty };
            try obj.object.put(arena, "currentModeId", mode);
            try setKey(arena, response, "modes", obj);
        }
    }
}

/// `initialize_params_with_subagents`.
pub fn initializeParams(arena: Allocator, id: []const u8, graff_subagents: bool) ![]const u8 {
    const base = "{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false";
    const caps: []const u8 = if (std.mem.eql(u8, id, "devin"))
        base ++ ",\"_meta\":{\"cognition.ai/subagentSupport\":true}}"
    else if (std.mem.eql(u8, id, "graff"))
        (if (graff_subagents)
            base ++ ",\"elicitation\":{\"form\":{}},\"session\":{\"compaction\":{}},\"subagents\":{},\"_meta\":{\"graff/backgroundSubagents\":true}}"
        else
            base ++ ",\"elicitation\":{\"form\":{}},\"session\":{\"compaction\":{}}}")
    else
        base ++ "}";
    return std.fmt.allocPrint(arena, "{{\"protocolVersion\":1,\"clientInfo\":{{\"name\":\"harness\",\"title\":\"Harness\",\"version\":{f}}},\"clientCapabilities\":{s}}}", .{ json.fmt(client_version, .{}), caps });
}

// ── `models_from_session` ──────────────────────────────────────────────────

/// `claude::catalog::context_window()` with its default.
fn contextWindow(default_choice: []const u8) ModelOption {
    return .{
        .id = "contextWindow",
        .label = "Context Window",
        .choices = &.{ .{ .id = "200k", .label = "200K" }, .{ .id = "1m", .label = "1M" } },
        .default_choice = default_choice,
    };
}

/// `strip_context_hint`.
pub fn stripContextHint(id: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, id, "[1m]")) return id[0 .. id.len - 4];
    if (std.mem.endsWith(u8, id, "-1m")) return id[0 .. id.len - 3];
    return null;
}

/// `strip_trailing_parenthetical`.
fn stripTrailingParenthetical(name: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, name, " (") orelse return name;
    if (!std.mem.endsWith(u8, name, ")")) return name;
    return std.mem.trimEnd(u8, name[0..at], " \t\r\n");
}

/// `trait_from_config_option`.
pub fn traitFromConfigOption(arena: Allocator, option: json.Value) !?ModelOption {
    if (strField(option, "category")) |c| {
        for ([_][]const u8{ "mode", "model", "thought_level" }) |skip| if (std.mem.eql(u8, c, skip)) return null;
    }
    const id = strField(option, "id") orelse return null;
    const label = strField(option, "name") orelse id;
    const ty = strField(option, "type") orelse return null;
    if (std.mem.eql(u8, ty, "select")) {
        const opts = arrField(option, "options") orelse return null;
        var choices: std.ArrayList(Choice) = .empty;
        for (opts) |c| {
            const cid = strField(c, "value") orelse continue;
            try choices.append(arena, .{ .id = cid, .label = strField(c, "name") orelse cid });
        }
        const default_choice = strField(option, "currentValue") orelse (if (choices.items.len > 0) choices.items[0].id else return null);
        if (choices.items.len <= 1) return null;
        return .{ .id = id, .label = label, .choices = choices.items, .default_choice = default_choice };
    }
    if (std.mem.eql(u8, ty, "boolean")) {
        const on = if (field(option, "currentValue")) |v| v == .bool and v.bool else false;
        return .{ .id = id, .label = label, .choices = &.{ .{ .id = "off", .label = "Off" }, .{ .id = "on", .label = "On" } }, .default_choice = if (on) "on" else "off" };
    }
    return null;
}

const Builder = struct {
    arena: Allocator,
    catalog: []const Model,
    ladder: []const []const u8,

    fn exact(b: *const Builder, id: []const u8) !?*const Model {
        const n = try normId(b.arena, id);
        for (b.catalog) |*m| if (std.mem.eql(u8, try normId(b.arena, m.id), n)) return m;
        return null;
    }

    fn alias(b: *const Builder, id: []const u8) !?*const Model {
        const n = try normId(b.arena, id);
        if (n.len == 0) return null;
        for (n) |c| if (!std.ascii.isAlphabetic(c)) return null;
        for (b.catalog) |*m| if (std.mem.indexOf(u8, try normId(b.arena, m.id), n) != null) return m;
        return null;
    }

    fn build(b: *const Builder, id: []const u8, name: ?[]const u8, description: ?[]const u8, options: []const ModelOption) !Model {
        const ex = try b.exact(id);
        const aliased = if (ex == null) try b.alias(id) else null;
        const known = ex orelse aliased;
        const label = if (aliased) |m| m.label else name orelse (if (known) |m| m.label else id);
        const desc = (if (aliased) |m| m.description else null) orelse description orelse (if (known) |m| m.description else null);
        const levels = if (known != null and known.?.reasoning_levels.len > 0) known.?.reasoning_levels else b.ladder;
        return .{ .id = id, .label = label, .description = desc, .reasoning_levels = levels, .options = options };
    }
};

fn findCategory(options: []const json.Value, category: []const u8) ?json.Value {
    for (options) |o| if (eqlOpt(strField(o, "category"), category)) return o;
    return null;
}

/// `models_from_session(session_response, catalog)`. Everything is
/// allocated in (or borrowed from values in) `arena`.
pub fn modelsFromSession(arena: Allocator, session: json.Value, catalog: []const Model) ![]Model {
    const config_options = arrField(session, "configOptions") orelse &.{};

    // The effort ladder, lowest to highest, deduplicated.
    var bits: u16 = 0;
    if (findCategory(config_options, "thought_level")) |o| if (arrField(o, "options")) |opts| for (opts) |c| {
        if (strField(c, "value")) |v| if (reasoningFromValue(v)) |l| {
            bits |= @as(u16, 1) << @intCast(l);
        };
    };
    var ladder: std.ArrayList([]const u8) = .empty;
    for (0..core.reasoning_levels.len) |i| if (bits & (@as(u16, 1) << @intCast(i)) != 0) try ladder.append(arena, core.reasoning_levels[i]);

    var wire: std.ArrayList(ModelOption) = .empty;
    for (config_options) |o| if (try traitFromConfigOption(arena, o)) |t| try wire.append(arena, t);

    const b: Builder = .{ .arena = arena, .catalog = catalog, .ladder = ladder.items };
    var out: std.ArrayList(Model) = .empty;

    const model_select: []const json.Value = if (findCategory(config_options, "model")) |o| arrField(o, "options") orelse &.{} else &.{};
    if (model_select.len > 0) {
        var raw_ids: std.ArrayList([]const u8) = .empty;
        for (model_select) |o| if (strField(o, "value")) |v| try raw_ids.append(arena, v);
        var has_real = false;
        for (raw_ids.items) |r| if (!normIs(r, "default")) {
            has_real = true;
        };
        for (model_select) |o| {
            const id = strField(o, "value") orelse continue;
            if (has_real and normIs(id, "default")) continue;
            const name = strField(o, "name");
            const description = strField(o, "description");
            var options: std.ArrayList(ModelOption) = .empty;
            try options.appendSlice(arena, wire.items);
            if (stripContextHint(id)) |base| {
                // A 1M variant whose base is advertised folds into that row.
                var base_listed = false;
                for (raw_ids.items) |r| if (std.mem.eql(u8, r, base)) {
                    base_listed = true;
                };
                if (base_listed) continue;
                // An orphan 1M variant presents as its base, pinned to 1M.
                try options.append(arena, contextWindow("1m"));
                const folded: ?[]const u8 = if (name) |n| blk: {
                    const s = stripTrailingParenthetical(n);
                    break :blk if (s.len > 0) s else null;
                } else null;
                try out.append(arena, try b.build(base, folded, description, options.items));
                continue;
            }
            for (raw_ids.items) |r| if (stripContextHint(r)) |rb| if (std.mem.eql(u8, rb, id)) {
                try options.append(arena, contextWindow("200k"));
                break;
            };
            try out.append(arena, try b.build(id, name, description, options.items));
        }
        return out.items;
    }

    // Legacy `models.availableModels`: the catalog's own option sets apply.
    const legacy: []const json.Value = if (field(session, "models")) |m| arrField(m, "availableModels") orelse &.{} else &.{};
    for (legacy) |m| {
        const id = strField(m, "modelId") orelse continue;
        const opts: []const ModelOption = if (try b.exact(id)) |k| k.options else &.{};
        try out.append(arena, try b.build(id, strField(m, "name"), strField(m, "description"), opts));
    }
    return out.items;
}

// ── `group_effort_variants` ────────────────────────────────────────────────

const effort_suffixes = [_]struct { id: []const u8, label: []const u8, level: Level }{
    .{ .id = "-low", .label = " (Low)", .level = 2 },
    .{ .id = "-medium", .label = " (Medium)", .level = 3 },
    .{ .id = "-high", .label = " (High)", .level = 4 },
};

const Variant = struct { level: Level, id: []const u8 };

const EffortGroup = struct {
    id: []const u8,
    label: []const u8,
    variants: std.ArrayList(Variant) = .empty,
};

/// `effort_groups`: advertised `(id, name)` choices grouped by display name.
fn effortGroups(arena: Allocator, models: []const Model) ![]EffortGroup {
    var groups: std.ArrayList(EffortGroup) = .empty;
    for (models) |m| {
        const variant: ?struct { base: []const u8, level: Level } = blk: {
            for (effort_suffixes) |s| if (std.mem.endsWith(u8, m.label, s.label)) break :blk .{ .base = m.label[0 .. m.label.len - s.label.len], .level = s.level };
            break :blk null;
        };
        const v = variant orelse {
            try groups.append(arena, .{ .id = m.id, .label = m.label });
            continue;
        };
        const existing = for (groups.items) |*g| {
            if (g.variants.items.len > 0 and std.mem.eql(u8, g.label, v.base)) break g;
        } else null;
        if (existing) |g| {
            try g.variants.append(arena, .{ .level = v.level, .id = m.id });
        } else {
            var g: EffortGroup = .{ .id = "", .label = v.base };
            try g.variants.append(arena, .{ .level = v.level, .id = m.id });
            try groups.append(arena, g);
        }
    }
    for (groups.items) |*g| {
        if (g.variants.items.len == 0) continue;
        g.id = blk: {
            for (g.variants.items) |variant| for (effort_suffixes) |s| {
                if (std.mem.endsWith(u8, variant.id, s.id)) break :blk variant.id[0 .. variant.id.len - s.id.len];
            };
            break :blk g.variants.items[0].id;
        };
        std.mem.sort(Variant, g.variants.items, {}, struct {
            fn lt(_: void, a: Variant, c: Variant) bool {
                return a.level < c.level;
            }
        }.lt);
    }
    return groups.items;
}

/// `group_effort_variants`: effort variants fold into one row whose ladder
/// lists the levels offered; models without a level in their name pass.
pub fn groupEffortVariants(arena: Allocator, models: []const Model) ![]Model {
    const groups = try effortGroups(arena, models);
    var out: std.ArrayList(Model) = .empty;
    for (groups) |g| {
        if (g.variants.items.len == 0) {
            for (models) |m| if (std.mem.eql(u8, m.id, g.id)) {
                try out.append(arena, m);
                break;
            };
            continue;
        }
        const first = for (models) |*m| {
            if (std.mem.eql(u8, m.id, g.variants.items[0].id)) break m;
        } else continue;
        const levels = try arena.alloc([]const u8, g.variants.items.len);
        for (g.variants.items, 0..) |v, i| levels[i] = levelName(v.level);
        try out.append(arena, .{ .id = g.id, .label = g.label, .reasoning_levels = levels, .options = first.options });
    }
    return out.items;
}

// ── antigravity's home (`antigravity_paths.rs`) ────────────────────────────

pub const PathResult = union(enum) { ok: []const u8, err: Failure };

fn protocolErr(msg: []const u8) PathResult {
    return .{ .err = Failure.protocol("{s}", .{msg}) };
}

fn joinPath(arena: Allocator, base: []const u8, p: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fs.path.join(arena, &.{ base, p });
}

const PasswdResult = union(enum) { ok: struct { name: []const u8, home: []const u8 }, err: []const u8 };

/// `passwd_entry(name)` through libc's reentrant lookups.
fn passwdEntry(arena: Allocator, name: ?[]const u8) !PasswdResult {
    const lookup_failed = "cannot resolve GEMINI_HOME through the user database; set an absolute path";
    if (comptime !builtin.link_libc or is_windows) return .{ .err = lookup_failed } else return passwdLookup(arena, name, lookup_failed);
}

fn passwdLookup(arena: Allocator, name: ?[]const u8, lookup_failed: []const u8) !PasswdResult {
    const name_z: ?[:0]const u8 = if (name) |n| blk: {
        if (std.mem.indexOfScalar(u8, n, 0) != null) return .{ .err = "invalid home name in GEMINI_HOME" };
        break :blk try arena.dupeSentinel(u8, n, 0);
    } else null;
    var size: usize = 4096;
    while (true) {
        const buf = try arena.alloc(u8, size);
        var entry: std.c.passwd = undefined;
        var result: ?*std.c.passwd = null;
        const status = if (name_z) |n| std.c.getpwnam_r(n.ptr, &entry, buf.ptr, buf.len, &result) else std.c.getpwuid_r(std.c.getuid(), &entry, buf.ptr, buf.len, &result);
        if (status == @backingInt(std.c.E.RANGE) and size < 1024 * 1024) {
            size *= 2;
            continue;
        }
        if (status != 0 or result == null) return .{ .err = lookup_failed };
        const n = entry.name orelse return .{ .err = "user database returned an incomplete home entry" };
        const d = entry.dir orelse return .{ .err = "user database returned an incomplete home entry" };
        const home = try arena.dupe(u8, std.mem.span(d));
        if (!std.fs.path.isAbsolute(home)) return .{ .err = "user database returned a non-absolute home directory" };
        return .{ .ok = .{ .name = try arena.dupe(u8, std.mem.span(n)), .home = home } };
    }
}

const HomeResult = union(enum) { ok: ?[]const u8, err: []const u8 };

/// `user_home`.
fn userHome(arena: Allocator, env: *const Environ.Map) !HomeResult {
    if (is_windows) {
        if (env.get("USERPROFILE")) |h| return .{ .ok = h };
        const path = env.get("HOMEPATH") orelse return .{ .ok = null };
        return .{ .ok = try std.fmt.allocPrint(arena, "{s}{s}", .{ env.get("HOMEDRIVE") orelse "", path }) };
    }
    if (env.get("HOME")) |h| return .{ .ok = h };
    return switch (try passwdEntry(arena, null)) {
        .ok => |e| .{ .ok = e.home },
        .err => |m| .{ .err = m },
    };
}

/// `named_home`.
fn namedHome(arena: Allocator, env: *const Environ.Map, name: []const u8) !PathResult {
    if (!is_windows) return switch (try passwdEntry(arena, name)) {
        .ok => |e| .{ .ok = e.home },
        .err => |m| protocolErr(m),
    };
    const unresolved = "cannot resolve a named home in GEMINI_HOME; set an absolute path";
    const home = switch (try userHome(arena, env)) {
        .ok => |h| h orelse return protocolErr(unresolved),
        .err => |m| return protocolErr(m),
    };
    const username = env.get("USERNAME");
    if (username != null and std.mem.eql(u8, username.?, name)) return .{ .ok = home };
    if (username != null and std.mem.eql(u8, std.fs.path.basename(home), username.?)) {
        if (std.fs.path.dirname(home)) |parent| return .{ .ok = try std.fs.path.join(arena, &.{ parent, name }) };
    }
    return protocolErr(unresolved);
}

/// `expand_user(path, home)`.
fn expandUser(arena: Allocator, env: *const Environ.Map, path: []const u8, home: ?[]const u8) !PathResult {
    const sep = std.mem.indexOfAny(u8, path, if (is_windows) "/\\" else "/");
    const first = if (sep) |s| path[0..s] else path;
    if (first.len == 0 or first[0] != '~') return .{ .ok = path };
    const rest = if (sep) |s| std.mem.trimStart(u8, path[s..], "/\\") else "";
    const expanded: []const u8 = if (first.len == 1) blk: {
        const h = home orelse return protocolErr("cannot resolve ~ in GEMINI_HOME; set an absolute path");
        if (h.len == 0) return protocolErr("cannot resolve ~ in GEMINI_HOME; set an absolute path");
        break :blk h;
    } else switch (try namedHome(arena, env, first[1..])) {
        .ok => |p| p,
        .err => |f| return .{ .err = f },
    };
    if (rest.len == 0) return .{ .ok = expanded };
    return .{ .ok = try std.fs.path.join(arena, &.{ expanded, rest }) };
}

/// `antigravity_paths::home()`: GEMINI_HOME (or `~/.gemini`) resolved
/// against the child's working directory, HOME.
pub fn antigravityHome(arena: Allocator, io: Io, env: *const Environ.Map) !PathResult {
    const cwd: []const u8 = Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
    const child_cwd = if (env.get("HOME")) |h| try joinPath(arena, cwd, h) else cwd;
    const gemini_home = env.get("GEMINI_HOME");
    const home = switch (try userHome(arena, env)) {
        .ok => |h| h,
        .err => |m| return protocolErr(m),
    };
    if (gemini_home) |g| if (g.len == 0) return protocolErr("GEMINI_HOME is empty; unset it or set an absolute path before signing in");
    const path = switch (try expandUser(arena, env, gemini_home orelse "~/.gemini", home)) {
        .ok => |p| p,
        .err => |f| return .{ .err = f },
    };
    const resolved = try joinPath(arena, child_cwd, path);
    if (!std.fs.path.isAbsolute(resolved)) return protocolErr("cannot resolve GEMINI_HOME to an absolute directory; set an absolute path");
    return .{ .ok = resolved };
}

// ── launch: resolution, environment, spawn ─────────────────────────────────

/// `resolve_program(false)`: the resolver's path, or `NotInstalled(hint)`.
pub fn resolveProgram(arena: Allocator, io: Io, spec: *const Spec) PathResult {
    const found = core.resolve_cli(arena, io, spec.id) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
    return if (found) |p| .{ .ok = p } else .{ .err = Failure.notInstalled(spec.install_hint) };
}

/// Whether `exe` is the managed archive's entry (`Launch::Archive`), whose
/// launches get a private temp root.
pub fn isArchiveEntry(exe: []const u8) bool {
    const base = std.fs.path.basename(exe);
    if (!std.mem.eql(u8, base, "agy_acp_server.par") and !std.mem.eql(u8, base, "agy_acp_server.exe")) return false;
    const version_dir = std.fs.path.dirname(exe) orelse return false;
    const name_dir = std.fs.path.dirname(version_dir) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(version_dir), antigravity_archive_version) and
        std.mem.eql(u8, std.fs.path.basename(name_dir), antigravity_archive_name);
}

/// `std::env::temp_dir()`.
pub fn tempDir(env: *const Environ.Map) []const u8 {
    if (is_windows) return env.get("TMP") orelse env.get("TEMP") orelse env.get("USERPROFILE") orelse "C:\\Windows\\Temp";
    if (env.get("TMPDIR")) |t| if (t.len > 0) return t;
    return "/tmp";
}

fn processId() i64 {
    if (comptime builtin.link_libc and !is_windows) return @intCast(std.c.getpid());
    if (comptime builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    return 0;
}

var next_scratch: std.atomic.Value(u64) = .init(0);

/// `ScratchDir`: a private, uniquely named temp root; `remove` deletes it.
pub const Scratch = struct {
    path: []const u8,

    pub fn create(arena: Allocator, io: Io, env: *const Environ.Map, label: []const u8) !Scratch {
        const clean = try arena.dupe(u8, label);
        for (clean) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
            c.* = '-';
        };
        while (true) {
            const name = try std.fmt.allocPrint(arena, "harness-{s}-{d}-{d}", .{ clean, processId(), next_scratch.fetchAdd(1, .monotonic) });
            const path = try std.fs.path.join(arena, &.{ tempDir(env), name });
            Io.Dir.cwd().createDir(io, path, if (is_windows) .default_dir else .fromMode(0o700)) catch |e| switch (e) {
                error.PathAlreadyExists => continue,
                else => return e,
            };
            return .{ .path = path };
        }
    }

    pub fn remove(self: Scratch, io: Io) void {
        for (0..10) |_| {
            Io.Dir.cwd().deleteTree(io, self.path) catch {
                io.sleep(.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            return;
        }
    }
};

/// Adds a harness's own variables to a launch environment.
pub const ExtraEnv = *const fn (arena: Allocator, io: Io, env: *Environ.Map) anyerror!void;

/// `apply_run_environment(None)` + `compose_child_path`: the environment a
/// discovery child gets. `strip` is `child::configure`'s nested-agent cleanup.
pub fn commandEnv(arena: Allocator, io: Io, base: *const Environ.Map, exe: []const u8, strip: bool) !Environ.Map {
    var env = try base.clone(arena);
    if (strip) for (agent_proc.stripped_env) |k| {
        _ = env.swapRemove(k);
    };
    _ = env.swapRemove("HARNESS_BUILD_WAIT_DIR");
    const login = agent_proc.loginShellPath(arena, io, base);
    const path = try agent_proc.composeChildPath(arena, exe, base.get("PATH"), login);
    try env.put("PATH", path);
    return env;
}

pub const Spawned = struct {
    proc: *AgentProc,
    scratch: ?Scratch,

    /// `Child::shutdown(kill_grace)`: SIGTERM the group, SIGKILL after the
    /// grace, reap.
    pub fn shutdown(self: *Spawned) void {
        self.proc.signal(.TERM);
        self.proc.armDeadline(kill_grace_ms);
        _ = self.proc.wait();
    }

    pub fn destroy(self: *Spawned, io: Io) void {
        self.proc.destroy();
        if (self.scratch) |s| s.remove(io);
    }
};

pub const SpawnResult = union(enum) { ok: Spawned, err: Failure };

/// `version {v}` text of `binary_hint`.
pub fn binaryHint(arena: Allocator, io: Io, exe: []const u8) ![]const u8 {
    var vbuf: [128]u8 = undefined;
    const v = harness_version.binaryVersionString(io, exe, &vbuf);
    return std.fmt.allocPrint(arena, "{s} (version {s})", .{ exe, v orelse "unknown" });
}

/// `spawn_agent(cwd, false, &[], None)`: the server with piped stdio in its
/// own process group. `gpa` must be thread-safe (the child's stderr is
/// drained on its own thread).
pub fn spawnAgent(gpa: Allocator, arena: Allocator, io: Io, spec: *const Spec, exe: []const u8, cwd: ?[]const u8, base: *const Environ.Map, extra: ?ExtraEnv) !SpawnResult {
    var env = try commandEnv(arena, io, base, exe, true);
    if (extra) |f| try f(arena, io, &env);
    const antigravity = std.mem.eql(u8, spec.id, "antigravity");
    if (antigravity) {
        if (std.fs.path.dirname(exe)) |parent| {
            const sibling = try std.fs.path.join(arena, &.{ parent, "localharness_external" });
            const is_file = if (Io.Dir.cwd().statFile(io, sibling, .{})) |st| st.kind == .file else |_| false;
            if (is_file) {
                try env.put("ANTIGRAVITY_HARNESS_PATH", sibling);
                try env.put("PYTHONUNBUFFERED", "1");
            }
        }
        switch (try antigravityHome(arena, io, base)) {
            .ok => |h| try env.put("GEMINI_HOME", h),
            .err => |f| return .{ .err = f },
        }
        // Python's webbrowser accepts an executable template; never open one.
        if (!is_windows) try env.put("BROWSER", "/usr/bin/true %s");
    }
    var scratch: ?Scratch = null;
    if (antigravity and isArchiveEntry(exe)) {
        const s = Scratch.create(arena, io, base, "agy_acp_server") catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
        for ([_][]const u8{ "TEMP", "TMP", "TMPDIR" }) |k| try env.put(k, s.path);
        scratch = s;
    }
    errdefer if (scratch) |s| s.remove(io);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    try argv.appendSlice(arena, spec.args);
    const proc = AgentProc.spawn(gpa, io, argv.items, cwd, &env, .{}) catch |e| {
        if (scratch) |s| s.remove(io);
        return .{ .err = switch (e) {
            error.NotInstalled => Failure.notInstalled(try binaryHint(arena, io, exe)),
            error.MissingCwd => Failure.ioError(.not_found, try std.fmt.allocPrint(arena, "Project folder is missing: {s}", .{cwd orelse ""})),
            else => Failure.ioError(.other, @errorName(e)),
        } };
    };
    return .{ .ok = .{ .proc = proc, .scratch = scratch } };
}

pub fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn clampMs(ms: u64) u32 {
    return @intCast(@min(ms, std.math.maxInt(u32)));
}

// ── one-shot commands (`Command::output` under a timeout) ──────────────────

pub const Capture = struct {
    stdout: []u8,
    term: ?std.process.Child.Term,
    /// The stderr tail (its last lines), trimmed; empty when none.
    stderr: []const u8,
};

pub const CaptureResult = union(enum) { ok: Capture, timed_out, err: Failure };

/// Run `exe args` with stdin closed, collecting stdout, bounded by
/// `timeout_ms` (`tokio::time::timeout(timeout, cmd.output())`).
pub fn runCapture(gpa: Allocator, arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, timeout_ms: u64, base: *const Environ.Map) !CaptureResult {
    var env = try commandEnv(arena, io, base, exe, false);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    try argv.appendSlice(arena, args);
    const proc = AgentProc.spawn(gpa, io, argv.items, null, &env, .{ .stdin = false }) catch |e| return .{ .err = switch (e) {
        error.NotInstalled => Failure.ioError(.not_found, "No such file or directory (os error 2)"),
        else => Failure.ioError(.other, @errorName(e)),
    } };
    defer proc.destroy();
    const deadline = nowNs(io) + @as(i96, timeout_ms) * std.time.ns_per_ms;
    proc.armDeadline(clampMs(timeout_ms));
    var out: std.ArrayList(u8) = .empty;
    if (proc.child.stdout) |f| {
        var chunk: [16 * 1024]u8 = undefined;
        while (out.items.len < 64 * 1024 * 1024) {
            const n = f.readStreaming(io, &.{&chunk}) catch break;
            try out.appendSlice(arena, chunk[0..n]);
        }
    }
    const term = proc.wait();
    if (nowNs(io) >= deadline and !(term != null and term.? == .exited)) return .timed_out;
    const tail = proc.stderrTail(arena);
    return .{ .ok = .{ .stdout = out.items, .term = term, .stderr = std.mem.trim(u8, tail orelse "", " \t\r\n") } };
}

pub fn success(term: ?std.process.Child.Term) bool {
    return term != null and term.? == .exited and term.?.exited == 0;
}

/// Rust's `ExitStatus` display.
pub fn exitStatusText(arena: Allocator, term: ?std.process.Child.Term) ![]const u8 {
    const t = term orelse return "unknown";
    return switch (t) {
        .exited => |code| if (is_windows) std.fmt.allocPrint(arena, "exit code: {d}", .{code}) else std.fmt.allocPrint(arena, "exit status: {d}", .{code}),
        .signal => |sig| if (std.enums.tagName(std.posix.SIG, sig)) |name|
            std.fmt.allocPrint(arena, "signal: {d} (SIG{s})", .{ @backingInt(sig), name })
        else
            std.fmt.allocPrint(arena, "signal: {d}", .{@backingInt(sig)}),
        .stopped => |sig| std.fmt.allocPrint(arena, "stopped (not terminated) by signal: {d}", .{@backingInt(sig)}),
        .unknown => |n| std.fmt.allocPrint(arena, "unrecognised wait status: {d}", .{n}),
    };
}

// ── `discover_models` ──────────────────────────────────────────────────────

const ModelsOutcome = union(enum) { ok: []Model, err: Failure };

fn discoveryFlow(arena: Allocator, io: Io, rpc: *Rpc, spec: *const Spec, env: *const Environ.Map) !ModelsOutcome {
    switch (rpc.request("initialize", try initializeParams(arena, spec.id, false), false)) {
        .err => |f| return .{ .err = f },
        .ok => {},
    }
    // Grok rejects session/new until this process authenticates.
    if (spec.discovery_auth_method) |method| {
        const params = try std.fmt.allocPrint(arena, "{{\"methodId\":{f}}}", .{json.fmt(method, .{})});
        switch (rpc.request("authenticate", params, true)) {
            .err => |f| return .{ .err = f },
            .ok => {},
        }
    }
    const cwd = try core.homeOrCwd(arena, io, env);
    const params = try std.fmt.allocPrint(arena, "{{\"cwd\":{f},\"mcpServers\":[]}}", .{json.fmt(cwd, .{})});
    const session = switch (rpc.request("session/new", params, true)) {
        .err => |f| return .{ .err = f },
        .ok => |v| v,
    };
    // `ladder_extras` is empty for every ACP spec.
    const models = try modelsFromSession(arena, session, spec.models);
    if (spec.effort_in_model_id) return .{ .ok = try groupEffortVariants(arena, models) };
    return .{ .ok = models };
}

/// One probe: initialize → session/new, models as JSON (owned by `gpa`).
/// `deadline_ms` bounds the probe; the timeout text names `nominal_ms`.
pub fn discoverModels(gpa: Allocator, io: Io, spec: *const Spec, deadline_ms: u64, nominal_ms: u64) !core.Discovered {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try core.currentEnv(arena);
    const exe = switch (resolveProgram(arena, io, spec)) {
        .ok => |p| p,
        .err => |f| return .{ .err = f },
    };
    var spawned = switch (try spawnAgent(gpa, arena, io, spec, exe, null, &env, null)) {
        .ok => |s| s,
        .err => |f| return .{ .err = f },
    };
    defer spawned.destroy(io);
    const deadline = nowNs(io) + @as(i96, deadline_ms) * std.time.ns_per_ms;
    spawned.proc.armDeadline(clampMs(deadline_ms));
    var rpc: Rpc = .{ .arena = arena, .proc = spawned.proc };
    const outcome = try discoveryFlow(arena, io, &rpc, spec, &env);
    const timed_out = outcome == .err and nowNs(io) >= deadline;
    spawned.shutdown();
    if (timed_out) {
        var msg: std.ArrayList(u8) = .empty;
        try msg.print(arena, "{s} model discovery did not complete within {d}s", .{ spec.display_name, nominal_ms / 1000 });
        if (spawned.proc.stderrTail(arena)) |tail| try msg.print(arena, "; stderr: {s}", .{tail});
        return .{ .err = Failure.protocol("{s}", .{msg.items}) };
    }
    return switch (outcome) {
        .err => |f| .{ .err = f },
        .ok => |models| .{ .ok = try core.modelsJson(gpa, models) },
    };
}

// ── the harness surface (`model_context`, `model_catalog`, …) ──────────────

/// `model_context()` for every ACP harness but graff.
pub fn specContext(gpa: Allocator, io: Io, spec: *const Spec) !core.ContextResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try core.currentEnv(arena);
    const binary = switch (resolveProgram(arena, io, spec)) {
        .ok => |p| p,
        .err => |f| return .{ .err = f },
    };
    var extra: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, spec.id, "antigravity")) {
        const home = switch (try antigravityHome(arena, io, &env)) {
            .ok => |h| h,
            .err => |f| return .{ .err = f },
        };
        for ([_][]const u8{ "settings.json", "oauth_creds.json", "google_accounts.json", "credentials.json", "auth.json" }) |name| {
            try extra.append(arena, try std.fs.path.join(arena, &.{ home, "antigravity-acp", name }));
        }
    }
    const ctx = core.computeContext(gpa, io, spec.id, binary, extra.items, &env) catch |e| {
        if (e == error.OutOfMemory) return e;
        return .{ .err = Failure.ioError(.other, @errorName(e)) };
    };
    return .{ .ok = ctx };
}

/// `model_context().map(|c| c.unwrap().key())` for the cache.
pub const Keyer = struct {
    gpa: Allocator,
    io: Io,
    spec: *const Spec,

    pub fn key(self: *Keyer) core.KeyResult {
        var r = specContext(self.gpa, self.io, self.spec) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
        switch (r) {
            .ok => |*c| {
                defer c.deinit(self.gpa);
                return .{ .ok = c.key() };
            },
            .err => |f| return .{ .err = f },
            .none => return .{ .err = Failure.protocol("model discovery context unavailable", .{}) },
        }
    }
};

/// `self.models_cache.get_with_timeout(force, timeout * 3 + 1s, …)` after
/// `model_context()?`.
pub fn cachedCatalog(gpa: Allocator, io: Io, force: bool, spec: *const Spec, cache: *core.MemCache, timeout_ms: u64, discoverer: anytype) !core.Result {
    var ctx = try specContext(gpa, io, spec);
    switch (ctx) {
        .err => |f| return .{ .err = f },
        .ok => |*c| c.deinit(gpa),
        .none => {},
    }
    var keyer: Keyer = .{ .gpa = gpa, .io = io, .spec = spec };
    return cache.getWithTimeout(gpa, io, force, timeout_ms * 3 + 1000, &keyer, discoverer);
}

/// Process-global state of one ACP harness.
pub const State = struct {
    spec: *const Spec,
    cache: core.MemCache = .{},
    timeout_ms: std.atomic.Value(u64),

    fn init(spec: *const Spec) State {
        return .{ .spec = spec, .timeout_ms = .init(spec.discovery_timeout_ms) };
    }

    fn reset(self: *State) void {
        if (self.cache.models) |m| core.long_gpa.free(m);
        self.cache = .{};
        self.timeout_ms.store(self.spec.discovery_timeout_ms, .release);
    }

    pub fn timeout(self: *const State) u64 {
        return self.timeout_ms.load(.acquire);
    }
};

var grok_state: State = .init(&specs.grok);
var hermes_state: State = .init(&specs.hermes);
var antigravity_state: State = .init(&specs.antigravity);
var exo_state: State = .init(&specs.exo);

fn stateFor(id: []const u8) ?*State {
    for ([_]*State{ &grok_state, &hermes_state, &antigravity_state, &exo_state }) |s| {
        if (std.mem.eql(u8, s.spec.id, id)) return s;
    }
    return null;
}

const SpecDiscoverer = struct {
    spec: *const Spec,
    timeout_ms: u64,

    pub fn discover(self: *SpecDiscoverer, gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
        return discoverModels(gpa, io, self.spec, @min(self.timeout_ms, budget_ms), self.timeout_ms);
    }
};

fn ctxFn(ptr: *anyopaque, gpa: Allocator, io: Io) anyerror!core.ContextResult {
    const st: *State = @ptrCast(@alignCast(ptr));
    return specContext(gpa, io, st.spec);
}

fn catFn(ptr: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!core.Result {
    const st: *State = @ptrCast(@alignCast(ptr));
    var d: SpecDiscoverer = .{ .spec = st.spec, .timeout_ms = st.timeout() };
    return cachedCatalog(gpa, io, force, st.spec, &st.cache, d.timeout_ms, &d);
}

fn fbFn(ptr: *anyopaque, gpa: Allocator) anyerror![]u8 {
    const st: *State = @ptrCast(@alignCast(ptr));
    return core.modelsJson(gpa, st.spec.models);
}

const vtable: core.Harness.VTable = .{ .modelContext = ctxFn, .modelCatalog = catFn, .fallbackModels = fbFn };

/// The discovery surface of `grok`, `hermes`, `antigravity` or `exo`.
pub fn harness(id: []const u8) ?core.Harness {
    const st = stateFor(id) orelse return null;
    return .{ .id = st.spec.id, .ptr = st, .vtable = &vtable };
}

/// `Harness::models`: a forced live catalog; transient failures fall back
/// to the static rows, auth and missing-binary failures are returned.
pub fn harnessModels(gpa: Allocator, io: Io, id: []const u8) !core.ListResult {
    const st = stateFor(id) orelse return error.UnknownHarness;
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        switch (resolveProgram(arena_state.allocator(), io, st.spec)) {
            .err => |f| return .{ .err = f },
            .ok => {},
        }
    }
    return switch (try catFn(st, gpa, io, true)) {
        .ok => |c| .{ .ok = c.models },
        .err => |f| if (!f.code.allowsStale()) .{ .err = f } else .{ .ok = try core.modelsJson(gpa, st.spec.models) },
    };
}

/// Tests (and `with_model_discovery_timeout`): the probe bound.
pub fn setDiscoveryTimeoutMs(id: []const u8, ms: u64) void {
    if (stateFor(id)) |st| st.timeout_ms.store(ms, .release);
}

pub fn resetForTests() void {
    client_version = "0.0.0";
    for ([_]*State{ &grok_state, &hermes_state, &antigravity_state, &exo_state }) |s| s.reset();
}

// ── test support (shared with catalog_graff/catalog_devin tests) ───────────

/// A synthetic HOME, PATH and resolver for tests.
pub const TestEnv = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    env: Environ.Map,
    paths: std.ArrayList([]u8) = .empty,
    saved_resolver: core.ResolveCli,

    var entries: [8]struct { id: []const u8 = "", path: []const u8 = "" } = @splat(.{});

    fn resolve(gpa: Allocator, _: Io, id: []const u8) anyerror!?[]u8 {
        for (entries) |e| if (e.path.len > 0 and std.mem.eql(u8, e.id, id)) return try gpa.dupe(u8, e.path);
        return null;
    }

    pub fn init() !*TestEnv {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        const self = try gpa.create(TestEnv);
        errdefer gpa.destroy(self);
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .root = undefined, .env = Environ.Map.init(gpa), .saved_resolver = core.resolve_cli };
        const root_z = try self.tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root_z);
        self.root = try gpa.dupe(u8, root_z);
        for ([_][]const u8{ "home", "tmp", "bin" }) |d| try self.tmp.dir.createDirPath(io, d);
        const home = try self.path("home");
        const tmpd = try self.path("tmp");
        try self.env.put("HOME", home);
        try self.env.put("TMPDIR", tmpd);
        try self.env.put("PATH", "/usr/bin:/bin");
        try self.env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        entries = @splat(.{});
        core.env_override = &self.env;
        core.resolve_cli = resolve;
        resetForTests();
        return self;
    }

    /// `root/rel` (owned by the TestEnv).
    pub fn path(self: *TestEnv, rel: []const u8) ![]const u8 {
        const p = try std.fs.path.join(std.testing.allocator, &.{ self.root, rel });
        try self.paths.append(std.testing.allocator, p);
        return p;
    }

    /// Writes an executable `bin/name` and returns its absolute path.
    pub fn script(self: *TestEnv, name: []const u8, body: []const u8) ![]const u8 {
        const rel = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}", .{name});
        defer std.testing.allocator.free(rel);
        const parent = std.fs.path.dirname(rel).?;
        try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = body, .flags = .{ .permissions = .executable_file } });
        return self.path(rel);
    }

    /// Points the resolver for `id` at `exe`.
    pub fn bind(_: *TestEnv, id: []const u8, exe: []const u8) void {
        for (&entries) |*e| if (e.path.len == 0 or std.mem.eql(u8, e.id, id)) {
            e.* = .{ .id = id, .path = exe };
            return;
        };
    }

    pub fn read(self: *TestEnv, rel: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, rel, std.testing.allocator, .limited(1 << 20));
    }

    pub fn deinit(self: *TestEnv) void {
        const gpa = std.testing.allocator;
        resetForTests();
        core.env_override = null;
        core.resolve_cli = self.saved_resolver;
        entries = @splat(.{});
        for (self.paths.items) |p| gpa.free(p);
        self.paths.deinit(gpa);
        self.env.deinit();
        gpa.free(self.root);
        self.tmp.cleanup();
        gpa.destroy(self);
    }
};

/// A `#!/bin/sh` ACP agent: answers `--version`, logs what it receives and
/// its environment to `log`, then runs `body` (`recv` reads one frame,
/// `send '<json>'` writes one) and idles until stdin closes.
pub fn mockAgent(gpa: Allocator, log: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\if [ "$1" = "--version" ]; then echo "mock-agent 1.2.3"; exit 0; fi
        \\LOG='{s}'
        \\echo "args: $*" >> "$LOG"
        \\echo "env: GEMINI_HOME=$GEMINI_HOME BROWSER=$BROWSER TMPDIR=$TMPDIR GRAFF_AUTO_ISOLATE=$GRAFF_AUTO_ISOLATE GRAFF_CODEX_WS=$GRAFF_CODEX_WS GRAFF_HOST_APP=$GRAFF_HOST_APP CLAUDECODE=$CLAUDECODE PWD=$(pwd)" >> "$LOG"
        \\recv() {{ IFS= read -r line || exit 0; printf '%s\n' "$line" >> "$LOG"; }}
        \\send() {{ printf '%s\n' "$1"; }}
        \\{s}
        \\cat > /dev/null
        \\
    , .{ log, body });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseTest(arena: Allocator, text: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, arena, text, .{ .allocate = .alloc_always });
}

fn expectJson(want: []const u8, models_: []const Model) !void {
    const got = try core.modelsJson(testing.allocator, models_);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn ids(arena: Allocator, models_: []const Model) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (models_, 0..) |m, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, m.id);
    }
    return out.items;
}

test "catalog_acp effort values map onto the ladder" {
    try testing.expectEqual(@as(?Level, 0), reasoningFromValue("off"));
    try testing.expectEqual(@as(?Level, 5), reasoningFromValue("X-High"));
    try testing.expectEqual(@as(?Level, 9), reasoningFromValue("ultra_think"));
    try testing.expectEqual(@as(?Level, null), reasoningFromValue("turbo"));
}

test "catalog_acp advertised thought levels read lowest to highest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try parseTest(arena,
        \\{"sessionId":"s-1","configOptions":[
        \\ {"id":"model","name":"Model","category":"model","type":"select","currentValue":"grok-4.8",
        \\  "options":[{"value":"grok-4.8","name":"Grok 4.8"},{"value":"grok-4.7","name":"Grok 4.7"}]},
        \\ {"id":"reasoning_effort","name":"Reasoning Effort","category":"thought_level","type":"select","currentValue":"xhigh",
        \\  "options":[{"value":"xhigh"},{"value":"high"},{"value":"medium"},{"value":"low"},{"value":"low"}]}]}
    );
    const got = try modelsFromSession(arena, session, &grok_models);
    // grok-4.7 is enriched from the catalog (its description), grok-4.8 is not.
    try expectJson(
        "[{\"id\":\"grok-4.8\",\"label\":\"Grok 4.8\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\"],\"options\":[]}," ++
            "{\"id\":\"grok-4.7\",\"label\":\"Grok 4.7\",\"description\":\"SpaceXAI's latest frontier model — 500k context\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\"],\"options\":[]}]",
        got,
    );
}

test "catalog_acp 1m variants fold into a context window, default drops, traits pass through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const collapse = try parseTest(arena,
        \\{"configOptions":[{"id":"model","category":"model","type":"select","options":[
        \\ {"value":"claude-sonnet-5","name":"Sonnet 5"},{"value":"claude-sonnet-5[1m]","name":"Sonnet 5 (1M)"},
        \\ {"value":"claude-opus-4-6","name":"Opus 4.6"},{"value":"claude-opus-4-6-1m","name":"Opus 4.6 (1M)"},
        \\ {"value":"claude-haiku-4-5","name":"Haiku 4.5"}]}]}
    );
    const a = try modelsFromSession(arena, collapse, &.{});
    try testing.expectEqualStrings("claude-sonnet-5,claude-opus-4-6,claude-haiku-4-5", try ids(arena, a));
    try testing.expectEqualStrings("200k", a[0].options[0].default_choice);
    try testing.expectEqualStrings("contextWindow", a[1].options[0].id);
    try testing.expectEqual(@as(usize, 0), a[2].options.len);

    const orphan = try parseTest(arena,
        \\{"configOptions":[
        \\ {"id":"fast","name":"Fast mode","type":"boolean","currentValue":true},
        \\ {"id":"persona","type":"select","currentValue":"b","options":[{"value":"a","name":"A"},{"value":"b"}]},
        \\ {"id":"single","type":"select","options":[{"value":"only"}]},
        \\ {"id":"mode","category":"mode","type":"select","options":[{"value":"x"},{"value":"y"}]},
        \\ {"id":"model","category":"model","type":"select","options":[
        \\  {"value":"default","name":"Default (recommended)"},{"value":"opus[1m]","name":"Opus (1M context)"},
        \\  {"value":"claude-fable-5[1m]","name":"Fable 5"},{"value":"sonnet","name":"Sonnet"}]}]}
    );
    const b = try modelsFromSession(arena, orphan, &.{});
    try testing.expectEqualStrings("opus,claude-fable-5,sonnet", try ids(arena, b));
    try expectJson(
        "[{\"id\":\"opus\",\"label\":\"Opus\",\"reasoningLevels\":[],\"options\":[" ++
            "{\"id\":\"fast\",\"label\":\"Fast mode\",\"choices\":[{\"id\":\"off\",\"label\":\"Off\"},{\"id\":\"on\",\"label\":\"On\"}],\"defaultChoice\":\"on\"}," ++
            "{\"id\":\"persona\",\"label\":\"persona\",\"choices\":[{\"id\":\"a\",\"label\":\"A\"},{\"id\":\"b\",\"label\":\"b\"}],\"defaultChoice\":\"b\"}," ++
            "{\"id\":\"contextWindow\",\"label\":\"Context Window\",\"choices\":[{\"id\":\"200k\",\"label\":\"200K\"},{\"id\":\"1m\",\"label\":\"1M\"}],\"defaultChoice\":\"1m\"}]}]",
        b[0..1],
    );
    // Only `default` advertised: it stays.
    const only_default = try parseTest(arena,
        \\{"configOptions":[{"id":"model","category":"model","type":"select","options":[{"value":"default","name":"Default"}]}]}
    );
    try testing.expectEqualStrings("default", try ids(arena, try modelsFromSession(arena, only_default, &.{})));
}

test "catalog_acp family aliases enrich from the catalog, versioned ids never fuzzy-match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = [_]Model{
        .{ .id = "claude-opus-5-5", .label = "Opus 5.5", .description = "Flagship", .reasoning_levels = &.{ "low", "high" } },
        .{ .id = "claude-sonnet-5", .label = "Sonnet 5" },
    };
    const session = try parseTest(arena,
        \\{"configOptions":[{"id":"model","category":"model","type":"select","options":[
        \\ {"value":"opus","name":"Opus","description":"wire"},{"value":"claude-opus-9-mini","name":"Opus 9 Mini"},{"value":"claude-sonnet-5"}]}]}
    );
    const got = try modelsFromSession(arena, session, &catalog);
    try testing.expectEqualStrings("Opus 5.5", got[0].label);
    try testing.expectEqualStrings("Flagship", got[0].description.?);
    try testing.expectEqual(@as(usize, 2), got[0].reasoning_levels.len);
    try testing.expectEqualStrings("Opus 9 Mini", got[1].label);
    try testing.expectEqualStrings("Sonnet 5", got[2].label);
}

test "catalog_acp legacy availableModels keep the catalog's options for known ids" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = [_]Model{.{ .id = "gpt-sol", .label = "Sol", .options = &.{.{ .id = "serviceTier", .label = "Speed", .choices = &.{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" } }, .default_choice = "a" }} }};
    const session = try parseTest(arena,
        \\{"models":{"availableModels":[{"modelId":"gpt-sol","name":"GPT-Sol"},{"modelId":"gpt-x","name":"GPT-X"},{"name":"no id"}]}}
    );
    const got = try modelsFromSession(arena, session, &catalog);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("GPT-Sol", got[0].label);
    try testing.expectEqualStrings("serviceTier", got[0].options[0].id);
    try testing.expectEqual(@as(usize, 0), got[1].options.len);
}

test "catalog_acp effort variants group by name even when ids disagree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try parseTest(arena,
        \\{"configOptions":[{"id":"model","category":"model","type":"select","options":[
        \\ {"value":"gemini-3.8-flash-high","name":"Gemini 3.8 Flash (High)"},
        \\ {"value":"gemini-3.8-flash-medium","name":"Gemini 3.8 Flash (Medium)"},
        \\ {"value":"gemini-3.8-flash-low","name":"Gemini 3.8 Flash (Low)"},
        \\ {"value":"gemini-pro-agent","name":"Gemini 3.1 Pro (High)"},
        \\ {"value":"gemini-3.1-pro-low","name":"Gemini 3.1 Pro (Low)"},
        \\ {"value":"gemini-legacy","name":"Gemini Legacy"}]}]}
    );
    const flat = try modelsFromSession(arena, session, &antigravity_models);
    const grouped = try groupEffortVariants(arena, flat);
    try expectJson(
        "[{\"id\":\"gemini-3.8-flash\",\"label\":\"Gemini 3.8 Flash\",\"reasoningLevels\":[\"low\",\"medium\",\"high\"],\"options\":[]}," ++
            "{\"id\":\"gemini-3.1-pro\",\"label\":\"Gemini 3.1 Pro\",\"reasoningLevels\":[\"low\",\"high\"],\"options\":[]}," ++
            "{\"id\":\"gemini-legacy\",\"label\":\"Gemini Legacy\",\"reasoningLevels\":[],\"options\":[]}]",
        grouped,
    );
}

test "catalog_acp static fallback rows keep Rust's shapes" {
    const h = harness("antigravity").?;
    const rows = try h.fallbackModels(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings(
        "[{\"id\":\"gemini-3.7-flash\",\"label\":\"Gemini 3.7 Flash\",\"reasoningLevels\":[\"low\",\"medium\",\"high\"],\"options\":[]}," ++
            "{\"id\":\"gemini-3.1-pro\",\"label\":\"Gemini 3.1 Pro\",\"reasoningLevels\":[\"low\",\"high\"],\"options\":[]}]",
        rows,
    );
    try testing.expect(harness("graff") == null);
    try testing.expect(harness("codex") == null);
    const exo = try harness("exo").?.fallbackModels(testing.allocator);
    defer testing.allocator.free(exo);
    try testing.expectEqualStrings("[{\"id\":\"default\",\"label\":\"Exo default\",\"description\":\"Runs the model configured in Exo (`./exo.sh --model`)\",\"reasoningLevels\":[],\"options\":[]}]", exo);
}

test "catalog_acp RPC errors render like jsonrpc.rs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [1024]u8 = undefined;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"code\":-32000,\"message\":\"Authentication required\"}", "harness protocol error: session/new: Authentication required (code -32000)" },
        .{ "{\"code\":-32601,\"message\":\"nope\",\"data\":{\"z\":1,\"a\":\"x\"}}", "harness protocol error: session/new: nope (code -32601): {\"a\":\"x\",\"z\":1}" },
        .{ "{\"message\":\"plain\",\"data\":\"detail\"}", "harness protocol error: session/new: plain: detail" },
        .{ "{\"code\":5}", "harness protocol error: session/new: {\"code\":5}" },
        .{ "{\"code\":-32000,\"message\":\"x\",\"data\":{\"kind\":\"reauth_required\",\"provider\":\"codex\",\"login\":{\"command\":\"codex\",\"args\":[\"login\"]}}}", reauth_text },
        .{ "{\"code\":-32603,\"message\":\"chatgpt-new api error [token_expired]: gone\"}", reauth_text },
        .{ "{\"code\":-32001,\"message\":\"unauthorized\",\"data\":{\"kind\":\"api_key_rejected\",\"provider\":\"openai\"}}", "openai API key was rejected: unauthorized" },
    };
    for (cases) |c| {
        const f = try responseFailure(arena, "session/new", try parseTest(arena, c[0]));
        try testing.expectEqualStrings(c[1], f.display(&buf));
    }
    const auth = try responseFailure(arena, "session/new", try parseTest(arena, cases[0][0]));
    try testing.expectEqual(core.Code.auth_required, auth.code);
}

test "catalog_acp isArchiveEntry recognizes only the managed install layout" {
    try testing.expect(isArchiveEntry("/d/adapters/antigravity-acp/1.2.1/agy_acp_server.par"));
    try testing.expect(!isArchiveEntry("/usr/local/bin/agy_acp_server.par"));
    try testing.expect(!isArchiveEntry("/d/adapters/antigravity-acp/1.2.1/other"));
}

fn expectFailure(r: core.Result, code: core.Code, text: []const u8) !void {
    switch (r) {
        .ok => |c| {
            defer testing.allocator.free(c.models);
            std.debug.print("unexpected catalog: {s}\n", .{c.models});
            return error.TestUnexpectedResult;
        },
        .err => |f| {
            var buf: [1024]u8 = undefined;
            try testing.expectEqualStrings(text, f.display(&buf));
            try testing.expectEqual(code, f.code);
        },
    }
}

fn skipUnlessSpawn() !void {
    if (!std.process.can_spawn or is_windows) return error.SkipZigTest;
}

test "catalog_acp a missing CLI reports Rust's NotInstalled text everywhere" {
    try skipUnlessSpawn();
    const te = try TestEnv.init();
    defer te.deinit();
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_][]const u8{ "grok", "hermes", "antigravity", "exo" }) |id| {
        const h = harness(id).?;
        const st = stateFor(id).?;
        var want_buf: [1024]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "harness binary not found: {s}", .{st.spec.install_hint});
        const ctx = try h.modelContext(gpa, io);
        try testing.expect(ctx == .err);
        var buf: [1024]u8 = undefined;
        try testing.expectEqualStrings(want, ctx.err.display(&buf));
        try expectFailure(try h.modelCatalog(gpa, io, false), .missing_executable, want);
        const listed = try harnessModels(gpa, io, id);
        try testing.expect(listed == .err and listed.err.code == .missing_executable);
    }
}

test "catalog_acp grok probe authenticates, answers server requests and folds raced config updates" {
    try skipUnlessSpawn();
    const te = try TestEnv.init();
    defer te.deinit();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("grok.log");
    const body =
        \\recv
        \\send '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[{"id":"grok.com"}]}}'
        \\send 'not json at all'
        \\send '{"jsonrpc":"2.0","id":"ask","method":"session/request_permission","params":{"options":[{"optionId":"no","kind":"reject_once"},{"optionId":"yes","kind":"allow_once"}]}}'
        \\recv
        \\send '{"jsonrpc":"2.0","id":2,"result":{}}'
        \\recv
        \\recv
        \\send '{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{}}'
        \\recv
        \\send '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-1","update":{"sessionUpdate":"config_option_update","configOptions":[{"id":"model","category":"model","type":"select","options":[{"value":"grok-4.7","name":"Grok 4.7"},{"value":"grok-5","name":"Grok 5"}]},{"id":"effort","category":"thought_level","type":"select","options":[{"value":"high"},{"value":"low"}]}]}}}'
        \\send '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s-1","configOptions":[{"id":"model","category":"model","type":"select","options":[{"value":"stale","name":"Stale"}]}]}}'
    ;
    const text = try mockAgent(gpa, log, body);
    defer gpa.free(text);
    te.bind("grok", try te.script("grok", text));
    try te.env.put("CLAUDECODE", "1");
    const h = harness("grok").?;
    const r = try h.modelCatalog(gpa, io, false);
    switch (r) {
        .ok => |c| {
            defer gpa.free(c.models);
            try testing.expectEqual(core.Source.live, c.source);
            try testing.expectEqualStrings(
                "[{\"id\":\"grok-4.7\",\"label\":\"Grok 4.7\",\"description\":\"SpaceXAI's latest frontier model — 500k context\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\"],\"options\":[]}," ++
                    "{\"id\":\"grok-5\",\"label\":\"Grok 5\",\"reasoningLevels\":[\"low\",\"high\"],\"options\":[]}]",
                c.models,
            );
        },
        .err => |f| {
            std.debug.print("unexpected: {s}\n", .{f.message()});
            return error.TestUnexpectedResult;
        },
    }
    const logged = try te.read("grok.log");
    defer gpa.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "args: --no-auto-update agent --no-leader stdio") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "CLAUDECODE= ") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"method\":\"authenticate\",\"params\":{\"methodId\":\"grok.com\"}") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"id\":\"ask\",\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"yes\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"id\":7,\"error\":{\"code\":-32601,\"message\":\"unsupported method: fs/read_text_file\"}") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"protocolVersion\":1,\"clientInfo\":{\"name\":\"harness\"") != null);
    // A second call inside the cooldown is served from memory.
    const again = try h.modelCatalog(gpa, io, false);
    try testing.expect(again == .ok and again.ok.source == .cache);
    gpa.free(again.ok.models);
}

test "catalog_acp auth required, malformed and empty replies" {
    try skipUnlessSpawn();
    const te = try TestEnv.init();
    defer te.deinit();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("hermes.log");

    // session/new answers auth_required: no catalog, no static rows.
    const auth = try mockAgent(gpa, log,
        \\recv
        \\send '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        \\recv
        \\send '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}'
    );
    defer gpa.free(auth);
    te.bind("hermes", try te.script("hermes-auth", auth));
    const h = harness("hermes").?;
    try expectFailure(try h.modelCatalog(gpa, io, true), .auth_required, "model discovery auth_required: harness protocol error: session/new: Authentication required (code -32000)");
    const listed = try harnessModels(gpa, io, "hermes");
    try testing.expect(listed == .err and listed.err.code == .auth_required);

    // Garbage then exit: a transient failure; `models` falls back to static rows.
    resetForTests();
    const garbage =
        \\#!/bin/sh
        \\if [ "$1" = "--version" ]; then echo "mock-agent 1.2.3"; exit 0; fi
        \\read -r line
        \\echo '{oops'
        \\exit 3
        \\
    ;
    te.bind("hermes", try te.script("hermes-garbage", garbage));
    try expectFailure(try h.modelCatalog(gpa, io, true), .failed, "model discovery failed: harness protocol error: initialize: app-server exited before responding");
    const fallback = try harnessModels(gpa, io, "hermes");
    defer fallback.deinit(gpa);
    try testing.expect(fallback == .ok);
    try testing.expect(std.mem.indexOf(u8, fallback.ok, "\"id\":\"hermes-4-405b\"") != null);

    // An agent that advertises nothing is an empty catalog, not a live one.
    resetForTests();
    const empty = try mockAgent(gpa, log,
        \\recv
        \\send '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        \\recv
        \\send '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s"}}'
    );
    defer gpa.free(empty);
    te.bind("hermes", try te.script("hermes-empty", empty));
    try expectFailure(try h.modelCatalog(gpa, io, true), .failed, "model discovery failed: Harness returned an empty model catalog");
}

test "catalog_acp a hung probe is killed at its timeout and names its stderr" {
    try skipUnlessSpawn();
    const te = try TestEnv.init();
    defer te.deinit();
    const gpa = testing.allocator;
    const io = testing.io;
    const hung =
        \\#!/bin/sh
        \\if [ "$1" = "--version" ]; then echo "mock-agent 1.2.3"; exit 0; fi
        \\echo "booting slowly" >&2
        \\sleep 30
        \\
    ;
    te.bind("exo", try te.script("exo", hung));
    const started = nowNs(io);
    const r = try discoverModels(gpa, io, &specs.exo, 1000, 1000);
    const elapsed_ms = @divFloor(nowNs(io) - started, std.time.ns_per_ms);
    try testing.expect(elapsed_ms < 10_000);
    try testing.expect(r == .err);
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: Exo model discovery did not complete within 1s; stderr: booting slowly", r.err.display(&buf));
    try testing.expectEqual(core.Code.timeout, r.err.code);
}

test "catalog_acp antigravity groups live effort variants and hashes its credential files" {
    try skipUnlessSpawn();
    const te = try TestEnv.init();
    defer te.deinit();
    const gpa = testing.allocator;
    const io = testing.io;
    const log = try te.path("agy.log");
    const body = try mockAgent(gpa, log,
        \\recv
        \\send '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        \\recv
        \\send '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s","configOptions":[{"id":"model","category":"model","type":"select","options":[{"value":"gemini-3.7-flash-high","name":"Gemini 3.7 Flash (High)"},{"value":"gemini-3.7-flash-low","name":"Gemini 3.7 Flash (Low)"},{"value":"gemini-pro-agent","name":"Gemini 3.1 Pro (High)"}]}]}}'
    );
    defer gpa.free(body);
    // The managed archive layout: launches get a private temp root.
    const exe = try te.script("adapters/antigravity-acp/1.2.1/agy_acp_server.par", body);
    te.bind("antigravity", exe);
    const gemini = try te.path("gemini");
    try te.env.put("GEMINI_HOME", gemini);
    const h = harness("antigravity").?;
    var c1 = (try h.modelContext(gpa, io)).ok;
    defer c1.deinit(gpa);
    try te.tmp.dir.createDirPath(io, "gemini/antigravity-acp");
    try te.tmp.dir.writeFile(io, .{ .sub_path = "gemini/antigravity-acp/oauth_creds.json", .data = "synthetic" });
    var c2 = (try h.modelContext(gpa, io)).ok;
    defer c2.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c1.hash, &c2.hash));

    const r = try h.modelCatalog(gpa, io, false);
    try testing.expect(r == .ok);
    defer gpa.free(r.ok.models);
    try testing.expectEqualStrings(
        "[{\"id\":\"gemini-3.7-flash\",\"label\":\"Gemini 3.7 Flash\",\"reasoningLevels\":[\"low\",\"high\"],\"options\":[]}," ++
            "{\"id\":\"gemini-pro-agent\",\"label\":\"Gemini 3.1 Pro\",\"reasoningLevels\":[\"high\"],\"options\":[]}]",
        r.ok.models,
    );
    const logged = try te.read("agy.log");
    defer gpa.free(logged);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    try want.print(gpa, "GEMINI_HOME={s} BROWSER=/usr/bin/true %s TMPDIR=", .{gemini});
    try testing.expect(std.mem.indexOf(u8, logged, want.items) != null);
    try testing.expect(std.mem.indexOf(u8, logged, "/harness-agy-acp-server-") != null);
    // The scratch root is gone once the probe ends.
    var dir = try te.tmp.dir.openDir(io, "tmp", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "catalog_acp an empty GEMINI_HOME fails antigravity's context with Rust's text" {
    try skipUnlessSpawn();
    const te = try TestEnv.init();
    defer te.deinit();
    const gpa = testing.allocator;
    te.bind("antigravity", try te.script("agy_acp_server", "#!/bin/sh\nexit 0\n"));
    try te.env.put("GEMINI_HOME", "");
    const ctx = try harness("antigravity").?.modelContext(gpa, testing.io);
    try testing.expect(ctx == .err);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: GEMINI_HOME is empty; unset it or set an absolute path before signing in", ctx.err.display(&buf));
}
