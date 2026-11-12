//! ACP agents (`crates/harness/src/acp/{mod,normalize,elicitation}.rs`):
//! graff, Devin, Grok and Hermes, driven over the Agent Client Protocol.
//!
//! One registry entry per agent fixes its executable, argv, environment and
//! extensions. A turn is `initialize`, `session/new` (or `session/load` to
//! resume), the agent's model/mode/effort selection, then `session/prompt`;
//! `session/update` notifications stream into the transcript, permission and
//! form requests become questions, and `session/cancel` interrupts.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const agent_turn = @import("agent_turn.zig");
const agent_proc = @import("agent_proc.zig");
const Turn = agent_turn.Turn;
const Event = agent_turn.Event;
const Call = agent_turn.Call;
const get = agent_turn.get;
const getStr = agent_turn.getStr;

pub const Agent = enum { graff, devin, grok, hermes };

/// `AcpAgentSpec`.
pub const Spec = struct {
    agent: Agent,
    /// Crash-message and error name.
    name: []const u8,
    exe: []const u8,
    override_var: []const u8,
    args: []const []const u8,
    extra: []const []const u8,
    hint: []const u8,
};

pub const specs = struct {
    pub const graff_spec: Spec = .{
        .agent = .graff,
        .name = "graff",
        .exe = "graff",
        .override_var = "GRAFF_EXECUTABLE",
        // Hardcoded: without it graff tells its root agent writes and bash are denied.
        .args = &.{ "acp", "--yolo" },
        .extra = &.{ "~/.harness/bin/graff", "~/.local/bin/graff", "/opt/homebrew/bin/graff", "/usr/local/bin/graff" },
        .hint = "graff (searched PATH, the login shell's PATH, ~/.harness/bin, the app bundle, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install codegraff, then `graff login`; set GRAFF_EXECUTABLE to override)",
    };
    pub const devin_spec: Spec = .{
        .agent = .devin,
        .name = "Devin",
        .exe = "devin",
        .override_var = "DEVIN_EXECUTABLE",
        .args = &.{"acp"},
        .extra = &.{ "~/.local/bin/devin", "/opt/homebrew/bin/devin", "/usr/local/bin/devin" },
        .hint = "devin (searched PATH, the login shell's PATH, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install with `curl -fsSL https://cli.devin.ai/install.sh | bash` or `brew install --cask devin-cli`, then `devin auth login`; set DEVIN_EXECUTABLE to override)",
    };
    pub const grok_spec: Spec = .{
        .agent = .grok,
        .name = "Grok",
        .exe = "grok",
        .override_var = "GROK_EXECUTABLE",
        .args = &.{ "--no-auto-update", "agent", "--no-leader", "stdio" },
        .extra = &.{ "~/.local/bin/grok", "~/.grok/bin/grok", "~/.npm-global/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok" },
        .hint = "grok (searched PATH, the login shell's PATH, ~/.local/bin, ~/.grok/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; install with `curl -fsSL https://x.ai/cli/install.sh | bash` or `npm install -g @xai-official/grok`; set GROK_EXECUTABLE to override)",
    };
    pub const hermes_spec: Spec = .{
        .agent = .hermes,
        .name = "Hermes",
        .exe = "hermes",
        .override_var = "HERMES_EXECUTABLE",
        .args = &.{"acp"},
        .extra = &.{ "~/.local/bin/hermes", "~/.hermes/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes" },
        .hint = "hermes (searched PATH, the login shell's PATH, ~/.local/bin, ~/.hermes/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; install with `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`, then `cd ~/.hermes/hermes-agent && uv pip install -e '.[acp]'` for the ACP server; set HERMES_EXECUTABLE to override)",
    };
};

fn makeAdapter(comptime spec: *const Spec, comptime mid_turn: bool) agent_turn.Adapter {
    const S = struct {
        fn runIt(t: *Turn) anyerror!void {
            return run(t, spec);
        }
    };
    return .{ .name = spec.name, .run = S.runIt, .interrupt = interrupt, .steer = steer, .answer = answer, .steers_mid_turn = mid_turn };
}

/// graff is step-boundary; the others are turn-boundary (`registry.rs`).
pub const graff = makeAdapter(&specs.graff_spec, true);
pub const devin = makeAdapter(&specs.devin_spec, false);
pub const grok = makeAdapter(&specs.grok_spec, false);
pub const hermes = makeAdapter(&specs.hermes_spec, false);

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `graff_models::normalize_legacy_id`: `provider:model` → `provider/model`.
pub fn normalizeGraffModel(a: Allocator, id: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, id, ':') orelse return id;
    const provider = id[0..colon];
    const name = id[colon + 1 ..];
    const known = [_][]const u8{ "anthropic", "claude-agent", "codegraff", "codex", "deepseek", "openai", "cerebras", "kimi", "xai", "xiaomi", "openrouter", "fugu", "mlx", "lmstudio" };
    if (name.len == 0) return id;
    for (known) |k| if (eq(provider, k)) return std.fmt.allocPrint(a, "{s}/{s}", .{ provider, name });
    return id;
}

/// The full argv for `spec`.
pub fn buildArgv(a: Allocator, spec: *const Spec, exe: []const u8, req: agent_turn.Request) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, spec.args);
    if (spec.agent == .graff) if (req.model) |m| {
        const trimmed = std.mem.trim(u8, m, " \t");
        if (trimmed.len > 0) try argv.appendSlice(a, &.{ "--model", try normalizeGraffModel(a, trimmed) });
    };
    return argv.items;
}

/// graff's extra environment (`configure_adapter_environment`).
pub fn applyGraffEnv(env: *std.process.Environ.Map, req: agent_turn.Request, a: Allocator) !void {
    try env.put("GRAFF_AUTO_ISOLATE", "0");
    if (env.get("GRAFF_CODEX_WS") == null) try env.put("GRAFF_CODEX_WS", "off");
    if (req.graff_draft_subagents) try env.put("GRAFF_ACP_DRAFT_SUBAGENTS", "1");
    if (req.graff_compact_pct != 0 and env.get("GRAFF_COMPACT_PCT") == null) try env.put("GRAFF_COMPACT_PCT", try std.fmt.allocPrint(a, "{d}", .{req.graff_compact_pct}));
    if (env.get("GRAFF_HOST_APP") == null) try env.put("GRAFF_HOST_APP", try std.fmt.allocPrint(a, "harness/{s}", .{@import("build_info").version}));
    if (env.get("GRAFF_DEVICE_NAME") == null) if (req.device_name) |d| try env.put("GRAFF_DEVICE_NAME", d);
}

/// `initialize` params (`initialize_params_with_subagents`).
pub fn initializeParams(a: Allocator, agent: Agent, draft_subagents: bool) ![]u8 {
    const caps = switch (agent) {
        .devin => "{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false,\"_meta\":{\"cognition.ai/subagentSupport\":true}}",
        .graff => if (draft_subagents)
            "{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false,\"elicitation\":{\"form\":{}},\"session\":{\"compaction\":{}},\"subagents\":{},\"_meta\":{\"graff/backgroundSubagents\":true}}"
        else
            "{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false,\"elicitation\":{\"form\":{}},\"session\":{\"compaction\":{}}}",
        else => "{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false}",
    };
    return std.fmt.allocPrint(a, "{{\"protocolVersion\":1,\"clientInfo\":{{\"name\":\"harness\",\"title\":\"Harness\",\"version\":{f}}},\"clientCapabilities\":{s}}}", .{ json.fmt(@import("build_info").version, .{}), caps });
}

/// `autonomy_modes`.
pub fn autonomyModes(req: agent_turn.Request) []const []const u8 {
    if (!req.auto_approve and req.sandbox == .read_only) return &.{ "plan", "read-only", "read_only", "readOnly", "ask" };
    if (!req.auto_approve and req.sandbox == .workspace_write) return &.{ "acceptEdits", "accept_edits", "auto", "agent", "default" };
    return &.{ "bypassPermissions", "bypass_permissions", "bypass", "yolo", "agent-full-access", "danger-full-access", "full-access" };
}

/// `default_effort_values` (graff sends the level's own name).
pub fn effortValues(agent: Agent, reasoning: ?[]const u8) []const []const u8 {
    const r = reasoning orelse return &.{};
    if (agent == .graff) return &.{r};
    if (eq(r, "none")) return &.{ "none", "off" };
    if (eq(r, "minimal")) return &.{ "minimal", "low" };
    if (eq(r, "low")) return &.{ "low", "minimal" };
    if (eq(r, "medium")) return &.{"medium"};
    if (eq(r, "high")) return &.{"high"};
    if (eq(r, "xhigh")) return &.{ "xhigh", "x-high", "high" };
    if (eq(r, "max")) return &.{ "max", "xhigh", "high" };
    if (eq(r, "ultra") or eq(r, "ultracode") or eq(r, "ultrathink")) return &.{ "ultra", "max", "high" };
    return &.{};
}

fn normId(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (std.ascii.isAlphanumeric(c)) try out.append(a, std.ascii.toLower(c));
    return out.items;
}

/// Values a select config option offers (flat or grouped).
fn optionValues(a: Allocator, opt: json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const opts = get(opt, "options") orelse return out.items;
    if (opts != .array) return out.items;
    for (opts.array.items) |o| {
        if (getStr(o, "value")) |v| try out.append(a, v);
        if (get(o, "options")) |inner| if (inner == .array) for (inner.array.items) |io| if (getStr(io, "value")) |v| try out.append(a, v);
    }
    return out.items;
}

fn pickAdvertised(a: Allocator, wanted: []const []const u8, offered: []const []const u8) !?[]const u8 {
    for (wanted) |w| {
        const nw = try normId(a, w);
        for (offered) |o| if (eq(nw, try normId(a, o))) return o;
    }
    return null;
}

/// One `session/set_config_option` to send.
pub const ConfigSet = struct { id: []const u8, value: []const u8, strict: ?[]const u8 = null };

/// `config_option_sets_with_modes`: which config options to set, from the
/// session's advertised `configOptions`.
pub fn configSets(a: Allocator, agent: Agent, req: agent_turn.Request, config_options: ?json.Value) ![]ConfigSet {
    var out: std.ArrayList(ConfigSet) = .empty;
    const opts = config_options orelse return out.items;
    if (opts != .array) return out.items;
    for (opts.array.items) |opt| {
        const id = getStr(opt, "id") orelse continue;
        const cat = getStr(opt, "category") orelse "";
        const current = getStr(opt, "currentValue") orelse "";
        const offered = try optionValues(a, opt);
        if (eq(cat, "model")) {
            if (agent == .graff) continue; // graff takes its model on argv.
            const m = req.model orelse continue;
            if (eq(m, current)) continue;
            try out.append(a, .{ .id = id, .value = m, .strict = if (agent == .devin) try std.fmt.allocPrint(a, "agent rejected requested model {s}", .{m}) else null });
        } else if (eq(cat, "mode")) {
            if (try pickAdvertised(a, autonomyModes(req), offered)) |v| if (!eq(v, current)) try out.append(a, .{ .id = id, .value = v });
        } else if (eq(cat, "thought_level")) {
            if (try pickAdvertised(a, effortValues(agent, req.reasoning), offered)) |v| if (!eq(v, current)) {
                try out.append(a, .{ .id = id, .value = v, .strict = if (agent == .graff) "graff rejected requested thought level" else null });
            };
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// session/update → events (`acp/normalize.rs`)
// ---------------------------------------------------------------------------

const placeholder_titles = [_][]const u8{ "grep", "glob", "read file", "read", "write", "edit", "edit file", "write file", "bash", "shell", "terminal", "search", "find", "fetch", "web search", "tool" };

fn isPlaceholder(title: []const u8) bool {
    for (placeholder_titles) |p| if (std.ascii.eqlIgnoreCase(title, p)) return true;
    return false;
}

fn inputPath(raw: json.Value) ?[]const u8 {
    return getStr(raw, "path") orelse getStr(raw, "file_path") orelse getStr(raw, "filePath");
}

fn locationPath(update: json.Value) ?[]const u8 {
    const locs = get(update, "locations") orelse return null;
    if (locs != .array or locs.array.items.len == 0) return null;
    return getStr(locs.array.items[0], "path");
}

fn firstDiff(update: json.Value) ?json.Value {
    const content = get(update, "content") orelse return null;
    if (content != .array) return null;
    for (content.array.items) |c| if (eq(getStr(c, "type") orelse "", "diff")) return c;
    return null;
}

fn unwrapBackticks(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') return s[1 .. s.len - 1];
    return s;
}

/// `typed_call`.
pub fn typedCall(a: Allocator, update: json.Value) ![]u8 {
    const kind = getStr(update, "kind") orelse "other";
    const title_raw = getStr(update, "title") orelse "";
    const title: ?[]const u8 = if (title_raw.len == 0 or isPlaceholder(title_raw)) null else title_raw;
    const raw = get(update, "rawInput") orelse json.Value{ .null = {} };
    const diff = firstDiff(update);
    const call: Call = blk: {
        if (eq(kind, "execute")) break :blk .{ .exec = getStr(raw, "command") orelse (if (title) |t| unwrapBackticks(t) else "") };
        if (eq(kind, "read")) break :blk .{ .read_file = inputPath(raw) orelse locationPath(update) orelse title orelse "" };
        if (eq(kind, "edit") or eq(kind, "delete") or eq(kind, "move")) {
            if (diff) |d| {
                const p = getStr(d, "path") orelse "";
                break :blk if (get(d, "oldText") == null or get(d, "oldText").? == .null) .{ .write_file = p } else .{ .edit_file = p };
            }
            const p = inputPath(raw) orelse locationPath(update);
            if (p != null and eq(kind, "edit")) break :blk .{ .edit_file = p.? };
            break :blk .{ .apply_patch = p };
        }
        if (eq(kind, "search")) {
            if (getStr(raw, "searchTerm")) |q| break :blk .{ .web_search = q };
            break :blk .{ .search = .{ .pattern = getStr(raw, "pattern") orelse getStr(raw, "globPattern") orelse getStr(raw, "query") orelse title orelse "", .path = getStr(raw, "path") } };
        }
        if (eq(kind, "fetch")) {
            if (getStr(raw, "url")) |u| break :blk .{ .web_fetch = u };
            break :blk .{ .web_search = getStr(raw, "searchTerm") orelse getStr(raw, "query") orelse title orelse "" };
        }
        if (diff) |d| {
            const p = getStr(d, "path") orelse "";
            break :blk if (get(d, "oldText") == null or get(d, "oldText").? == .null) .{ .write_file = p } else .{ .edit_file = p };
        }
        if (spawnDescription(update, raw)) |desc| break :blk .{ .unknown = .{ .name = if (desc.len > 0) try std.fmt.allocPrint(a, "Agent: {s}", .{desc}) else "Agent", .input = raw } };
        if (graffControl(a, update, title_raw)) |name| break :blk .{ .unknown = .{ .name = try name } };
        break :blk .{ .unknown = .{ .name = if (title_raw.len > 0) title_raw else kind, .input = raw } };
    };
    return call.toJson(a);
}

fn metaStr(update: json.Value, key: []const u8) ?[]const u8 {
    const meta = get(update, "_meta") orelse return null;
    return getStr(meta, key);
}

fn spawnDescription(update: json.Value, raw: json.Value) ?[]const u8 {
    if (eq(metaStr(update, "graff/toolName") orelse "", "subagent")) return getStr(raw, "description") orelse getStr(raw, "title") orelse "";
    if (eq(metaStr(update, "cognition.ai/inferenceToolName") orelse "", "run_subagent")) return getStr(raw, "title") orelse getStr(raw, "description") orelse "";
    if (get(update, "_meta")) |m| if (get(m, "x.ai/tool")) |xt| if (eq(getStr(xt, "name") orelse "", "spawn_subagent")) return getStr(raw, "description") orelse "";
    if (get(raw, "subagent_type") != null and get(raw, "prompt") != null) return getStr(raw, "description") orelse "";
    return null;
}

fn graffControl(a: Allocator, update: json.Value, title: []const u8) ?anyerror![]const u8 {
    const tool = metaStr(update, "graff/toolName") orelse title;
    const raw = get(update, "rawInput") orelse json.Value{ .null = {} };
    const id = getStr(raw, "id") orelse getStr(raw, "agent_id") orelse "";
    if (eq(tool, "agent_output")) return std.fmt.allocPrint(a, "Wait for agent {s}", .{id});
    if (eq(tool, "agent_message")) return std.fmt.allocPrint(a, "Message agent {s}", .{id});
    if (eq(tool, "subagent_resume")) return @as(anyerror![]const u8, "Resume agent");
    if (eq(tool, "load_tool_schemas")) return @as(anyerror![]const u8, "Load tools");
    return null;
}

/// `map_update` for one `session/update`.
pub fn mapUpdate(a: Allocator, update: json.Value, out: *std.ArrayList(Event)) !void {
    const kind = getStr(update, "sessionUpdate") orelse return;
    if (eq(kind, "agent_message_chunk") or eq(kind, "agent_thought_chunk")) {
        const content = get(update, "content") orelse return;
        const text = getStr(content, "text") orelse return;
        if (text.len == 0) return;
        try out.append(a, if (eq(kind, "agent_message_chunk")) .{ .text = text } else .{ .reasoning = text });
    } else if (eq(kind, "plan")) {
        var items: std.ArrayList(Call.TodoItem) = .empty;
        if (get(update, "entries")) |es| if (es == .array) for (es.array.items) |e| {
            try items.append(a, .{ .text = getStr(e, "content") orelse "", .done = eq(getStr(e, "status") orelse "", "completed") });
        };
        try out.append(a, .{ .tool_call = .{ .id = "acp-plan", .call = try (Call{ .todo = items.items }).toJson(a) } });
        try out.append(a, .{ .tool_result = .{ .id = "acp-plan", .is_error = false } });
    } else if (eq(kind, "tool_call") or eq(kind, "tool_call_update")) {
        const id = getStr(update, "toolCallId") orelse return;
        const status = getStr(update, "status") orelse "";
        const first = eq(kind, "tool_call");
        if (first or get(update, "kind") != null or get(update, "title") != null or get(update, "rawInput") != null or firstDiff(update) != null) {
            try out.append(a, .{ .tool_call = .{ .id = id, .call = try typedCall(a, update) } });
        }
        if (eq(status, "completed") or eq(status, "failed")) try out.append(a, .{ .tool_result = .{ .id = id, .is_error = eq(status, "failed") } });
    }
}

/// `stop_outcome` for a `session/prompt` result.
pub fn stopOutcome(result: json.Value, interrupted: bool) struct { status: agent_turn.DoneStatus, err: ?[]const u8 } {
    if (interrupted) return .{ .status = .interrupted, .err = null };
    const reason = getStr(result, "stopReason") orelse "end_turn";
    if (eq(reason, "cancelled")) {
        const src = metaStr(result, "graff/cancelSource") orelse "";
        const user_sources = [_][]const u8{ "acp_cancel", "json_cancel", "ui_cancel", "esc_key", "force_steer" };
        for (user_sources) |s| if (eq(src, s)) return .{ .status = .interrupted, .err = null };
        return .{ .status = .errored, .err = metaStr(result, "graff/cancelMessage") orelse "The agent stopped unexpectedly without a cancellation request. The task is incomplete." };
    }
    if (eq(reason, "error")) return .{ .status = .errored, .err = "The agent failed to complete the turn." };
    if (eq(reason, "refusal")) return .{ .status = .errored, .err = "The agent refused to continue." };
    return .{ .status = .completed, .err = null };
}

// ---------------------------------------------------------------------------
// Requests from the agent
// ---------------------------------------------------------------------------

const kind_permission: u8 = 1;
const kind_question: u8 = 2;
const kind_form: u8 = 3;

fn isPermissionKind(k: []const u8) bool {
    return eq(k, "allow_once") or eq(k, "allow_always") or eq(k, "reject_once") or eq(k, "reject_always");
}

/// `preferred_allow_option`: allow_always, allow_once, else the first.
pub fn preferredAllow(options: json.Value) ?[]const u8 {
    if (options != .array or options.array.items.len == 0) return null;
    for ([_][]const u8{ "allow_always", "allow_once" }) |want| for (options.array.items) |o| if (eq(getStr(o, "kind") orelse "", want)) return getStr(o, "optionId");
    return getStr(options.array.items[0], "optionId");
}

fn optionByKind(options: json.Value, kinds: []const []const u8) ?[]const u8 {
    if (options != .array) return null;
    for (kinds) |k| for (options.array.items) |o| if (eq(getStr(o, "kind") orelse "", k)) return getStr(o, "optionId");
    return null;
}

fn selected(a: Allocator, option_id: ?[]const u8) ![]const u8 {
    const id = option_id orelse return "{\"outcome\":{\"outcome\":\"cancelled\"}}";
    return std.fmt.allocPrint(a, "{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":{f}}}}}", .{json.fmt(id, .{})});
}

/// Form fields of an `elicitation/create` (flat schemas only).
const FormField = struct { key: []const u8, ty: []const u8, title: []const u8, choices: []const []const u8, required: bool };

fn formFields(a: Allocator, params: json.Value) !?[]FormField {
    const schema = get(params, "requestedSchema") orelse return null;
    const props = get(schema, "properties") orelse return null;
    if (props != .object) return null;
    var required: []const json.Value = &.{};
    if (get(schema, "required")) |r| if (r == .array) {
        required = r.array.items;
    };
    var out: std.ArrayList(FormField) = .empty;
    var it = props.object.iterator();
    while (it.next()) |e| {
        const ty = getStr(e.value_ptr.*, "type") orelse "string";
        var req = false;
        for (required) |r| if (r == .string and eq(r.string, e.key_ptr.*)) {
            req = true;
        };
        const supported = eq(ty, "string") or eq(ty, "boolean") or eq(ty, "integer") or eq(ty, "number");
        if (!supported) {
            if (req) return null;
            continue;
        }
        var choices: std.ArrayList([]const u8) = .empty;
        if (eq(ty, "boolean")) try choices.appendSlice(a, &.{ "Yes", "No" });
        if (get(e.value_ptr.*, "enum")) |en| if (en == .array) for (en.array.items) |c| if (c == .string) try choices.append(a, c.string);
        try out.append(a, .{ .key = e.key_ptr.*, .ty = ty, .title = getStr(e.value_ptr.*, "title") orelse getStr(e.value_ptr.*, "description") orelse e.key_ptr.*, .choices = choices.items, .required = req });
    }
    return out.items;
}

fn onRequest(t: *Turn, a: Allocator, session_id: []const u8, id: json.Value, method: []const u8, params: json.Value) !void {
    const id_json = try std.fmt.allocPrint(a, "{f}", .{json.fmt(id, .{})});
    if (eq(method, "session/request_permission")) {
        if (!eq(getStr(params, "sessionId") orelse session_id, session_id)) return respondRaw(t, id_json, "{\"outcome\":{\"outcome\":\"cancelled\"}}");
        const options = get(params, "options") orelse json.Value{ .array = .init(a) };
        const title = if (get(params, "toolCall")) |tc| getStr(tc, "title") else null;
        var is_question = false;
        if (options == .array) for (options.array.items) |o| if (!isPermissionKind(getStr(o, "kind") orelse "")) {
            is_question = true;
        };
        const data = try std.fmt.allocPrint(a, "{{\"id\":{s},\"options\":{f}}}", .{ id_json, json.fmt(options, .{}) });
        if (is_question) {
            var names: std.ArrayList([]const u8) = .empty;
            if (options == .array) for (options.array.items) |o| try names.append(a, getStr(o, "name") orelse getStr(o, "optionId") orelse "");
            const q = [_]agent_turn.Question{.{ .id = "choice", .header = "Agent question", .question = title orelse "The agent needs your input.", .options = names.items }};
            return t.ask(kind_question, data, &q);
        }
        if (!t.req.auto_approve and t.req.sandbox != .danger_full_access) {
            const text = if (title) |tt| try std.fmt.allocPrint(a, "The agent wants to run: {s}. Allow it?", .{tt}) else "The agent wants to use a tool. Allow it?";
            const q = agent_turn.yesNo("approve", "Approve tool", text);
            return t.ask(kind_permission, data, &q);
        }
        return respondRaw(t, id_json, try selected(a, preferredAllow(options)));
    }
    if (eq(method, "elicitation/create")) {
        const mode = getStr(params, "mode") orelse "form";
        const fields = (if (eq(mode, "form")) try formFields(a, params) else null) orelse return respondRaw(t, id_json, "{\"action\":\"cancel\"}");
        if (fields.len == 0) return respondRaw(t, id_json, "{\"action\":\"cancel\"}");
        const message = getStr(params, "message") orelse "The agent needs your input.";
        var qs: std.ArrayList(agent_turn.Question) = .empty;
        for (fields) |f| try qs.append(a, .{
            .id = f.key,
            .header = "Agent question",
            .question = if (fields.len > 1) try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ message, f.title }) else message,
            .options = f.choices,
        });
        const data = try std.fmt.allocPrint(a, "{{\"id\":{s},\"fields\":{f}}}", .{ id_json, json.fmt(fields, .{}) });
        return t.ask(kind_form, data, qs.items);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    try buf.print(t.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":{f}}}}}", .{ id_json, json.fmt(try std.fmt.allocPrint(a, "unsupported method: {s}", .{method}), .{}) });
    _ = t.send(buf.items);
}

fn respondRaw(t: *Turn, id_json: []const u8, result_json: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    buf.print(t.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json }) catch return;
    _ = t.send(buf.items);
}

fn answer(t: *Turn, p: *const agent_turn.Pending, answers: ?[]const agent_turn.Answer) void {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const data = json.parseFromSliceLeaky(json.Value, a, p.data, .{}) catch return;
    const id_json = std.fmt.allocPrint(a, "{f}", .{json.fmt(get(data, "id") orelse return, .{})}) catch return;
    switch (p.kind) {
        kind_permission => {
            const options = get(data, "options") orelse return;
            const pick = if (answers == null)
                null
            else if (agent_turn.answeredYes(answers))
                optionByKind(options, &.{ "allow_once", "allow_always" })
            else
                optionByKind(options, &.{ "reject_once", "reject_always" });
            respondRaw(t, id_json, selected(a, pick) catch return);
        },
        kind_question => {
            const options = get(data, "options") orelse return;
            const labels = agent_turn.labelsFor(answers, "choice");
            var pick: ?[]const u8 = null;
            if (labels.len > 0 and options == .array) for (options.array.items) |o| {
                if (eq(getStr(o, "name") orelse getStr(o, "optionId") orelse "", labels[0])) pick = getStr(o, "optionId");
            };
            respondRaw(t, id_json, selected(a, pick) catch return);
        },
        kind_form => {
            const as = answers orelse return respondRaw(t, id_json, "{\"action\":\"cancel\"}");
            if (as.len == 0) return respondRaw(t, id_json, "{\"action\":\"cancel\"}");
            const fields = get(data, "fields") orelse return;
            var content: json.ObjectMap = .empty;
            if (fields == .array) for (fields.array.items) |f| {
                const key = getStr(f, "key") orelse continue;
                const ty = getStr(f, "ty") orelse "string";
                const labels = agent_turn.labelsFor(answers, key);
                if (labels.len == 0) {
                    if (agent_turn.getBool(f, "required") orelse false) return respondRaw(t, id_json, "{\"action\":\"decline\"}");
                    continue;
                }
                const v = std.mem.trim(u8, labels[0], " \t\n");
                const value: json.Value = if (eq(ty, "boolean"))
                    .{ .bool = std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "true") }
                else if (eq(ty, "integer"))
                    .{ .integer = std.fmt.parseInt(i64, v, 10) catch return respondRaw(t, id_json, "{\"action\":\"decline\"}") }
                else if (eq(ty, "number"))
                    .{ .float = std.fmt.parseFloat(f64, v) catch return respondRaw(t, id_json, "{\"action\":\"decline\"}") }
                else
                    .{ .string = labels[0] };
                content.put(a, key, value) catch return;
            };
            const body = std.fmt.allocPrint(a, "{{\"action\":\"accept\",\"content\":{f}}}", .{json.fmt(json.Value{ .object = content }, .{})}) catch return;
            respondRaw(t, id_json, body);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// The turn
// ---------------------------------------------------------------------------

const State = struct {
    session_id: ?[]u8 = null,
    next_id: u64 = 1,
    steering_ext: bool = false,
    prompting: bool = false,
};

fn state(t: *Turn) ?*State {
    return @ptrCast(@alignCast(t.state orelse return null));
}

fn request(t: *Turn, method: []const u8, params: []const u8) ?u64 {
    t.mu.lockUncancelable(t.io);
    const st = state(t) orelse {
        t.mu.unlock(t.io);
        return null;
    };
    const id = st.next_id;
    st.next_id += 1;
    t.mu.unlock(t.io);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    buf.print(t.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ id, json.fmt(method, .{}), params }) catch return null;
    if (!t.send(buf.items)) return null;
    return id;
}

/// `session/cancel` with the user's stop reason (`cancel_params`).
pub fn cancelParams(a: Allocator, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"sessionId\":{f},\"_meta\":{{\"graff/cancelSource\":\"user\",\"graff/cancelReason\":\"stop\"}}}}", .{json.fmt(session_id, .{})});
}

fn interrupt(t: *Turn) void {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    t.mu.lockUncancelable(t.io);
    const sid: ?[]const u8 = if (state(t)) |st| (if (st.session_id) |s| arena.allocator().dupe(u8, s) catch null else null) else null;
    t.mu.unlock(t.io);
    const s = sid orelse return;
    const params = cancelParams(arena.allocator(), s) catch return;
    const line = std.fmt.allocPrint(arena.allocator(), "{{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{s}}}", .{params}) catch return;
    _ = t.send(line);
}

/// Mid-turn steering only through the `_session/steering` extension.
fn steer(t: *Turn, text: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    t.mu.lockUncancelable(t.io);
    const st = state(t);
    const ok = if (st) |s| s.steering_ext and s.prompting and s.session_id != null else false;
    const sid: []const u8 = if (ok) arena.allocator().dupe(u8, st.?.session_id.?) catch "" else "";
    t.mu.unlock(t.io);
    if (!ok) return false;
    const params = std.fmt.allocPrint(arena.allocator(), "{{\"sessionId\":{f},\"prompt\":[{{\"type\":\"text\",\"text\":{f}}}],\"_meta\":{{\"steering\":{{\"idleBehavior\":\"promptRequired\"}}}}}}", .{ json.fmt(sid, .{}), json.fmt(text, .{}) }) catch return false;
    return request(t, "_session/steering", params) != null;
}

fn rpcError(a: Allocator, method: []const u8, err: json.Value) ![]u8 {
    const msg = getStr(err, "message") orelse "error";
    const code: i64 = if (get(err, "code")) |c| (if (c == .integer) c.integer else 0) else 0;
    if (get(err, "data")) |d| if (d != .null) return std.fmt.allocPrint(a, "{s}: {s} (code {d}): {f}", .{ method, msg, code, json.fmt(d, .{}) });
    return std.fmt.allocPrint(a, "{s}: {s} (code {d})", .{ method, msg, code });
}

const handshake_timeout_ms: u32 = 120_000;

const Wire = struct {
    t: *Turn,
    proc: *agent_proc.AgentProc,
    session_id: []const u8 = "",
    events: std.ArrayList(Event) = .empty,
    /// Updates that arrived during setup (config option changes are kept).
    setup_config: ?json.Value = null,

    /// Read until the response to `id`; serve requests and fold updates.
    fn await_(self: *Wire, a: Allocator, id: u64, fold: bool) !?json.Value {
        while (try self.proc.readLine()) |line| {
            const root = json.parseFromSliceLeaky(json.Value, a, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
            if (root != .object) continue;
            if (try self.route(a, root, fold)) |rid| if (rid == id) return root;
        }
        return null;
    }

    fn route(self: *Wire, a: Allocator, root: json.Value, fold: bool) !?u64 {
        const id = get(root, "id");
        if (getStr(root, "method")) |m| {
            const params = get(root, "params") orelse json.Value{ .null = {} };
            if (id) |i| {
                if (!fold and eq(m, "session/request_permission")) {
                    // Setup traffic is accepted without a prompt (`request_draining`).
                    const id_json = try std.fmt.allocPrint(a, "{f}", .{json.fmt(i, .{})});
                    respondRaw(self.t, id_json, try selected(a, preferredAllow(get(params, "options") orelse json.Value{ .null = {} })));
                } else try onRequest(self.t, a, self.session_id, i, m, params);
                return null;
            }
            if (eq(m, "session/update")) {
                if (self.session_id.len > 0) if (getStr(params, "sessionId")) |sid| if (!eq(sid, self.session_id)) return null;
                const update = get(params, "update") orelse return null;
                if (eq(getStr(update, "sessionUpdate") orelse "", "config_option_update")) self.setup_config = get(update, "configOptions");
                if (fold) try mapUpdate(a, update, &self.events);
            }
            return null;
        }
        if (id) |i| if (i == .integer) return @intCast(i.integer);
        return null;
    }
};

fn run(t: *Turn, spec: *const Spec) !void {
    const a = t.arena.allocator();
    var st: State = .{};
    defer if (st.session_id) |s| t.gpa.free(s);
    t.state = &st;
    defer {
        t.mu.lockUncancelable(t.io);
        t.state = null;
        t.mu.unlock(t.io);
    }
    const exe = try t.resolveExe(spec.exe, spec.override_var, spec.extra, spec.hint);
    const argv = try buildArgv(a, spec, exe, t.req);
    var env = try t.childEnv(exe);
    defer env.deinit();
    if (spec.agent == .graff) try applyGraffEnv(&env, t.req, a);
    const proc = try t.spawn(argv, &env, .{});
    proc.escalate(handshake_timeout_ms, handshake_timeout_ms + agent_turn.kill_grace_ms);

    var wire: Wire = .{ .t = t, .proc = proc };
    var line_arena = std.heap.ArenaAllocator.init(t.gpa);
    defer line_arena.deinit();
    const la = line_arena.allocator();

    const init_id = request(t, "initialize", try initializeParams(la, spec.agent, t.req.graff_draft_subagents)) orelse return setupExit(t, proc, spec, "initialize");
    const init_resp = (try wire.await_(la, init_id, false)) orelse return setupExit(t, proc, spec, "initialize");
    if (get(init_resp, "error")) |e| return t.fail("harness protocol error: {s}", .{try rpcError(la, "initialize", e)});
    if (get(init_resp, "result")) |r| if (get(r, "_meta")) |m| if (get(m, "steering")) |s| {
        st.steering_ext = agent_turn.getBool(s, "supported") orelse false;
    };

    if (spec.agent == .grok) {
        const auth_id = request(t, "authenticate", "{\"methodId\":\"grok.com\"}") orelse return setupExit(t, proc, spec, "authenticate");
        const auth = (try wire.await_(la, auth_id, false)) orelse return setupExit(t, proc, spec, "authenticate");
        if (get(auth, "error") != null) return t.fail("Grok isn't signed in. Use Settings → Agents → Sign in.", .{});
    }

    // session/load to resume, else session/new.
    var session_result: ?json.Value = null;
    var session_id: []const u8 = "";
    if (t.req.resume_id) |r| {
        const params = try std.fmt.allocPrint(la, "{{\"cwd\":{f},\"mcpServers\":[],\"sessionId\":{f}}}", .{ json.fmt(t.req.cwd, .{}), json.fmt(r, .{}) });
        const lid = request(t, "session/load", params) orelse return setupExit(t, proc, spec, "session/load");
        const resp = (try wire.await_(la, lid, false)) orelse return setupExit(t, proc, spec, "session/load");
        if (get(resp, "error")) |e| {
            t.emit(.{ .err = try std.fmt.allocPrint(a, "{s} could not restore session {s}; starting a new session without the previous context: {s}", .{ spec.name, r, try rpcError(la, "session/load", e) }) });
        } else {
            session_result = get(resp, "result");
            session_id = r;
        }
    }
    if (session_id.len == 0) {
        const params = try std.fmt.allocPrint(la, "{{\"cwd\":{f},\"mcpServers\":[]}}", .{json.fmt(t.req.cwd, .{})});
        const nid = request(t, "session/new", params) orelse return setupExit(t, proc, spec, "session/new");
        const resp = (try wire.await_(la, nid, false)) orelse return setupExit(t, proc, spec, "session/new");
        if (get(resp, "error")) |e| return t.fail("harness protocol error: {s}", .{try rpcError(la, "session/new", e)});
        session_result = get(resp, "result");
        session_id = (if (session_result) |sr| getStr(sr, "sessionId") else null) orelse "";
        if (session_id.len == 0) return t.fail("harness protocol error: session/new returned no sessionId", .{});
    }
    const sid = try a.dupe(u8, session_id);
    wire.session_id = sid;
    {
        t.mu.lockUncancelable(t.io);
        defer t.mu.unlock(t.io);
        st.session_id = try t.gpa.dupe(u8, sid);
    }
    t.emit(.{ .session_started = sid });

    // Model, mode and effort.
    const config = wire.setup_config orelse (if (session_result) |sr| get(sr, "configOptions") else null);
    if (spec.agent != .graff) if (t.req.model) |m| if (session_result) |sr| if (get(sr, "models")) |models| {
        const has_model_option = blk: {
            const c = config orelse break :blk false;
            if (c != .array) break :blk false;
            for (c.array.items) |o| if (eq(getStr(o, "category") orelse "", "model")) break :blk true;
            break :blk false;
        };
        if (!has_model_option and !eq(getStr(models, "currentModelId") orelse "", m)) {
            var available: std.ArrayList([]const u8) = .empty;
            if (get(models, "availableModels")) |am| if (am == .array) for (am.array.items) |x| if (getStr(x, "modelId")) |id| try available.append(la, id);
            var advertised = false;
            for (available.items) |x| if (eq(x, m)) {
                advertised = true;
            };
            if (!advertised) return t.fail("harness protocol error: agent does not advertise requested model {s}; available models: {s}", .{ m, try std.mem.join(la, ", ", available.items) });
            const params = try std.fmt.allocPrint(la, "{{\"sessionId\":{f},\"modelId\":{f}}}", .{ json.fmt(sid, .{}), json.fmt(m, .{}) });
            const mid = request(t, "session/set_model", params) orelse return setupExit(t, proc, spec, "session/set_model");
            const resp = (try wire.await_(la, mid, false)) orelse return setupExit(t, proc, spec, "session/set_model");
            if (get(resp, "error")) |e| return t.fail("harness protocol error: agent rejected model switch to {s}: {s}", .{ m, try rpcError(la, "session/set_model", e) });
        }
    };
    for (try configSets(la, spec.agent, t.req, config)) |set| {
        const params = try std.fmt.allocPrint(la, "{{\"sessionId\":{f},\"configId\":{f},\"value\":{f}}}", .{ json.fmt(sid, .{}), json.fmt(set.id, .{}), json.fmt(set.value, .{}) });
        const cid = request(t, "session/set_config_option", params) orelse return setupExit(t, proc, spec, "session/set_config_option");
        const resp = (try wire.await_(la, cid, false)) orelse return setupExit(t, proc, spec, "session/set_config_option");
        if (get(resp, "error")) |e| if (set.strict) |msg| return t.fail("harness protocol error: {s}: {s}", .{ msg, try rpcError(la, "session/set_config_option", e) });
    }
    proc.clearDeadline();
    if (t.interrupted.load(.acquire)) {
        t.emit(.{ .done = .{ .status = .interrupted, .session_id = sid } });
        return;
    }

    // The prompt.
    const prompt_params = if (spec.agent == .grok)
        try std.fmt.allocPrint(la, "{{\"sessionId\":{f},\"prompt\":[{{\"type\":\"text\",\"text\":{f}}}],\"_meta\":{{\"promptId\":\"harness-p1\",\"requestId\":\"harness-p1\"}}}}", .{ json.fmt(sid, .{}), json.fmt(t.req.prompt, .{}) })
    else
        try std.fmt.allocPrint(la, "{{\"sessionId\":{f},\"prompt\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ json.fmt(sid, .{}), json.fmt(t.req.prompt, .{}) });
    {
        t.mu.lockUncancelable(t.io);
        defer t.mu.unlock(t.io);
        st.prompting = true;
    }
    const prompt_id = request(t, "session/prompt", prompt_params) orelse return setupExit(t, proc, spec, "session/prompt");
    _ = line_arena.reset(.retain_capacity);

    var saw_done = false;
    while (try proc.readLine()) |line| {
        defer _ = line_arena.reset(.retain_capacity);
        const lla = line_arena.allocator();
        wire.events = .empty;
        const root = json.parseFromSliceLeaky(json.Value, lla, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
        if (root != .object) continue;
        const rid = try wire.route(lla, root, true);
        for (wire.events.items) |ev| t.emit(ev);
        if (rid) |r| if (r == prompt_id) {
            saw_done = true;
            const durable = if (get(root, "result")) |res| metaStr(res, "graff/durableSessionId") else null;
            const done_sid = try a.dupe(u8, durable orelse sid);
            if (get(root, "error")) |e| {
                t.emit(.{ .done = .{ .status = if (t.interrupted.load(.acquire)) .interrupted else .errored, .err = try std.fmt.allocPrint(a, "harness protocol error: {s}", .{try rpcError(lla, "session/prompt", e)}), .session_id = done_sid } });
            } else {
                const res = get(root, "result") orelse json.Value{ .null = {} };
                const o = stopOutcome(res, t.interrupted.load(.acquire));
                t.emit(.message_completed);
                t.emit(.{ .done = .{ .status = o.status, .err = if (o.err) |e| try a.dupe(u8, e) else null, .session_id = done_sid } });
            }
            break;
        };
    }
    {
        t.mu.lockUncancelable(t.io);
        defer t.mu.unlock(t.io);
        st.prompting = false;
    }
    if (!saw_done) {
        if (t.interrupted.load(.acquire)) {
            t.emit(.{ .done = .{ .status = .interrupted, .session_id = sid } });
        } else {
            t.emit(.{ .done = .{ .status = .errored, .err = t.crash(proc), .session_id = sid } });
        }
    }
    proc.closeStdin();
    proc.escalate(agent_turn.kill_grace_ms, agent_turn.kill_grace_ms * 2);
}

fn setupExit(t: *Turn, proc: *agent_proc.AgentProc, spec: *const Spec, method: []const u8) error{TurnFailed} {
    if (t.interrupted.load(.acquire)) return t.fail("interrupted", .{});
    const crash = t.crash(proc);
    if (proc.term) |term| if (term == .signal and !t.interrupted.load(.acquire)) {
        return t.fail("{s} did not complete the ACP handshake within {d}s (the agent may be waiting for a login — try running it once in a terminal); {s}", .{ spec.name, handshake_timeout_ms / 1000, crash });
    };
    return t.fail("harness protocol error: {s}: agent exited during setup; {s}", .{ method, crash });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "acp: argv and env follow the registry (graff keeps --yolo, qualifies legacy model ids)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var req: agent_turn.Request = .{ .chat_id = "c", .harness = "graff", .prompt = "p", .cwd = "/w", .env = &env, .model = "anthropic:claude-opus-5-5", .graff_compact_pct = 80, .device_name = "Test Mac" };
    try testing.expectEqualStrings("/g acp --yolo --model anthropic/claude-opus-5-5", try std.mem.join(a, " ", try buildArgv(a, &specs.graff_spec, "/g", req)));
    req.model = "custom:thing";
    try testing.expectEqualStrings("/g acp --yolo --model custom:thing", try std.mem.join(a, " ", try buildArgv(a, &specs.graff_spec, "/g", req)));
    req.model = null;
    try testing.expectEqualStrings("/g acp --yolo", try std.mem.join(a, " ", try buildArgv(a, &specs.graff_spec, "/g", req)));
    req.model = "m";
    try testing.expectEqualStrings("/d acp", try std.mem.join(a, " ", try buildArgv(a, &specs.devin_spec, "/d", req)));
    try testing.expectEqualStrings("/x --no-auto-update agent --no-leader stdio", try std.mem.join(a, " ", try buildArgv(a, &specs.grok_spec, "/x", req)));

    var child = std.process.Environ.Map.init(a);
    try child.put("GRAFF_CODEX_WS", "on");
    try applyGraffEnv(&child, req, a);
    try testing.expectEqualStrings("0", child.get("GRAFF_AUTO_ISOLATE").?);
    try testing.expectEqualStrings("on", child.get("GRAFF_CODEX_WS").?);
    try testing.expectEqualStrings("80", child.get("GRAFF_COMPACT_PCT").?);
    try testing.expectEqualStrings("Test Mac", child.get("GRAFF_DEVICE_NAME").?);
    try testing.expect(child.get("GRAFF_ACP_DRAFT_SUBAGENTS") == null);
    try testing.expect(std.mem.indexOf(u8, try initializeParams(a, .graff, true), "\"elicitation\":{\"form\":{}},\"session\":{\"compaction\":{}},\"subagents\":{},\"_meta\":{\"graff/backgroundSubagents\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, try initializeParams(a, .devin, false), "\"_meta\":{\"cognition.ai/subagentSupport\":true}") != null);
}

test "acp: config options pick model, autonomy mode and effort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    const req: agent_turn.Request = .{ .chat_id = "c", .harness = "devin", .prompt = "p", .cwd = "/w", .env = &env, .model = "swe-2", .reasoning = "xhigh", .sandbox = .workspace_write };
    const opts = try json.parseFromSliceLeaky(json.Value, a,
        \\[{"id":"model","category":"model","currentValue":"swe-1","options":[{"value":"swe-1"},{"value":"swe-2"}]},
        \\ {"id":"mode","category":"mode","currentValue":"ask","options":[{"value":"ask"},{"group":"g","options":[{"value":"accept_edits"}]}]},
        \\ {"id":"effort","category":"thought_level","currentValue":"low","options":[{"value":"low"},{"value":"high"}]}]
    , .{});
    const sets = try configSets(a, .devin, req, opts);
    try testing.expectEqual(@as(usize, 3), sets.len);
    try testing.expectEqualStrings("swe-2", sets[0].value);
    try testing.expectEqualStrings("accept_edits", sets[1].value);
    try testing.expectEqualStrings("high", sets[2].value);
}

test "acp: session updates map to typed tool calls, plan chips and stop outcomes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Event) = .empty;
    const ups = [_][]const u8{
        "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hmm\"}}",
        "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"kind\":\"execute\",\"title\":\"`zig build`\",\"status\":\"pending\"}",
        "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\"}",
        "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t2\",\"kind\":\"edit\",\"title\":\"Edit\",\"content\":[{\"type\":\"diff\",\"path\":\"/w/a.zig\",\"oldText\":\"a\",\"newText\":\"b\"}]}",
        "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t3\",\"kind\":\"search\",\"title\":\"grep\",\"rawInput\":{\"pattern\":\"TODO\",\"path\":\"src\"},\"status\":\"failed\"}",
        "{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"step\",\"status\":\"completed\"}]}",
        "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Done\"}}",
    };
    for (ups) |u| try mapUpdate(a, try json.parseFromSliceLeaky(json.Value, a, u, .{}), &out);
    try testing.expectEqualStrings("hmm", out.items[0].reasoning);
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"zig build\"}", out.items[1].tool_call.call);
    try testing.expect(!out.items[2].tool_result.is_error);
    try testing.expectEqualStrings("{\"kind\":\"editFile\",\"path\":\"/w/a.zig\"}", out.items[3].tool_call.call);
    try testing.expectEqualStrings("{\"kind\":\"search\",\"pattern\":\"TODO\",\"path\":\"src\"}", out.items[4].tool_call.call);
    try testing.expect(out.items[5].tool_result.is_error);
    try testing.expectEqualStrings("acp-plan", out.items[6].tool_call.id);
    try testing.expectEqualStrings("Done", out.items[8].text);

    const cancelled = try json.parseFromSliceLeaky(json.Value, a, "{\"stopReason\":\"cancelled\"}", .{});
    try testing.expectEqual(agent_turn.DoneStatus.errored, stopOutcome(cancelled, false).status);
    try testing.expectEqual(agent_turn.DoneStatus.interrupted, stopOutcome(cancelled, true).status);
    const refused = try json.parseFromSliceLeaky(json.Value, a, "{\"stopReason\":\"refusal\"}", .{});
    try testing.expectEqualStrings("The agent refused to continue.", stopOutcome(refused, false).err.?);
}

const testkit = @import("agent_testkit.zig");

const mock_agent =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\printf '%s\n' "$@" > "$d/argv.txt"
    \\env > "$d/env.txt"
    \\idof() { printf '%s' "$1" | sed 's/.*"id":\([0-9]*\).*/\1/'; }
    \\while IFS= read -r line; do
    \\  printf '%s\n' "$line" >> "$d/stdin.txt"
    \\  case "$line" in
    \\    *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}';;
    \\    *'"method":"session/new"'*) echo '{"jsonrpc":"2.0","id":'$(idof "$line")',"result":{"sessionId":"acp-sess"}}';;
    \\    *'"method":"session/load"'*) echo '{"jsonrpc":"2.0","id":'$(idof "$line")',"result":{}}';;
    \\    *'"method":"session/prompt"'*)
    \\      pid=$(idof "$line"); echo "$pid" > "$d/prompt_id"
    \\      echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-sess","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}}}'
    \\      echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-sess","update":{"sessionUpdate":"tool_call","toolCallId":"tc1","kind":"execute","title":"rm -rf build","rawInput":{"command":"rm -rf build"}}}}'
    \\      echo '{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"acp-sess","toolCall":{"toolCallId":"tc1","title":"rm -rf build"},"options":[{"optionId":"ok","name":"Allow","kind":"allow_once"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}';;
    \\    *'"id":"perm-1"'*'"optionId":"ok"'*)
    \\      echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-sess","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc1","status":"completed"}}}'
    \\      echo '{"jsonrpc":"2.0","id":'$(cat "$d/prompt_id")',"result":{"stopReason":"end_turn"}}';;
    \\    *'"method":"session/cancel"'*) echo '{"jsonrpc":"2.0","id":'$(cat "$d/prompt_id")',"result":{"stopReason":"cancelled"}}';;
    \\  esac
    \\done
    \\
;

test "acp: a Devin turn against a mock agent streams, asks permission and resumes with session/load" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "devin", .override_var = "DEVIN_EXECUTABLE", .script = mock_agent });
    defer rig.destroy();
    try rig.run("m-1", "clean up");
    try rig.waitQuestion(5000);
    try rig.waitFor("The agent wants to run: rm -rf build. Allow it?", 1000);
    try rig.answerOpen("approve", "Yes");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"Hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"call\":{\"kind\":\"exec\",\"command\":\"rm -rf build\"},\"resolved\":true,\"isError\":false") != null);
    try testing.expectEqualStrings("acp-sess", rig.chatSessionId().?);

    try rig.run("m-2", "more");
    try rig.waitQuestion(5000);
    try rig.command("{\"kind\":\"interrupt\"}");
    try rig.waitIdle(8000);
    const stdin = try rig.readFile("stdin.txt");
    defer testing.allocator.free(stdin);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"method\":\"session/load\",\"params\":{\"cwd\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"acp-sess\",\"_meta\":{\"graff/cancelSource\":\"user\",\"graff/cancelReason\":\"stop\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "{\"outcome\":{\"outcome\":\"cancelled\"}}") != null);
    const doc2 = try rig.docJson();
    defer testing.allocator.free(doc2);
    try testing.expect(std.mem.indexOf(u8, doc2, "\"status\":\"aborted\"") != null);
}

test "acp: graff runs with --yolo and its environment; a missing binary is reported" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    {
        const rig = try testkit.Rig.create(.{ .harness = "graff", .override_var = "GRAFF_EXECUTABLE", .script = mock_agent, .autonomy = "full-access" });
        defer rig.destroy();
        rig.host.graff_exe = rig.script;
        try rig.run("m-1", "hi");
        try rig.waitIdle(5000);
        const argv = try rig.readFile("argv.txt");
        defer testing.allocator.free(argv);
        try testing.expectEqualStrings("acp\n--yolo\n", argv);
        const env = try rig.readFile("env.txt");
        defer testing.allocator.free(env);
        try testing.expect(std.mem.indexOf(u8, env, "GRAFF_AUTO_ISOLATE=0\n") != null);
        try testing.expect(std.mem.indexOf(u8, env, "GRAFF_CODEX_WS=off\n") != null);
        const doc = try rig.docJson();
        defer testing.allocator.free(doc);
        try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"Hi\"") != null);
    }
    {
        const rig = try testkit.Rig.create(.{ .harness = "hermes", .override_var = "HERMES_EXECUTABLE", .script = mock_agent, .missing_binary = true });
        defer rig.destroy();
        try rig.run("m-1", "hi");
        try rig.waitIdle(5000);
        const doc = try rig.docJson();
        defer testing.allocator.free(doc);
        try testing.expect(std.mem.indexOf(u8, doc, "harness binary not found: /nonexistent/harness-agent-mock does not exist") != null);
    }
}
