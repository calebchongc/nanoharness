//! Claude Code adapter (`crates/harness/src/claude/{mod,normalize,wire,catalog}.rs`).
//!
//! `claude --print --input-format stream-json --output-format stream-json …`
//! with the prompt and steers written to stdin as user messages, permission
//! prompts over the stdio control protocol, and `result` ending the turn.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const agent_turn = @import("agent_turn.zig");
const Turn = agent_turn.Turn;
const Event = agent_turn.Event;
const Call = agent_turn.Call;
const getStr = agent_turn.getStr;
const get = agent_turn.get;

pub const adapter: agent_turn.Adapter = .{
    .name = "claude",
    .run = run,
    .interrupt = interrupt,
    .steer = steer,
    .answer = answer,
    .steers_mid_turn = true,
};

pub const install_hint = "claude (searched PATH, the login shell's PATH, ~/.claude/local, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CLAUDE_CODE_EXECUTABLE to override)";
pub const extra_paths = [_][]const u8{ "~/.claude/local/claude", "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude" };

/// `to_effort` (`catalog.rs`).
pub fn effortFor(reasoning: ?[]const u8, model: ?[]const u8) ?[]const u8 {
    const r = reasoning orelse return null;
    if (eq(r, "minimal") or eq(r, "low")) return "low";
    if (eq(r, "medium")) return "medium";
    if (eq(r, "high")) return "high";
    if (eq(r, "xhigh") or eq(r, "ultracode")) return if (supportsXhigh(model orelse "")) "xhigh" else "max";
    if (eq(r, "max") or eq(r, "ultra")) return "max";
    return null;
}

fn supportsXhigh(model: []const u8) bool {
    const fams = [_][]const u8{ "fable-5", "opus-4-7", "opus-4-8", "opus-4-9", "opus-5", "opus-6", "opus-7", "opus-8", "opus-9", "sonnet-5", "sonnet-6", "sonnet-7", "sonnet-8", "sonnet-9" };
    for (fams) |f| if (std.mem.indexOf(u8, model, f) != null) return true;
    return false;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn optionOn(opts: ?json.Value, key: []const u8) bool {
    const o = opts orelse return false;
    const v = get(o, key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .string => |s| eq(s, "on") or eq(s, "true"),
        else => false,
    };
}

/// `build_command`: the argv after the executable.
pub fn buildArgv(a: Allocator, exe: []const u8, req: agent_turn.Request, model_options: ?json.Value) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ exe, "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--thinking-display", "summarized", "--permission-prompt-tool", "stdio" });
    if (req.model) |m| {
        const one_m = if (model_options) |o| (if (getStr(o, "contextWindow")) |cw| eq(cw, "1m") else false) else false;
        try argv.appendSlice(a, &.{ "--model", if (one_m) try std.fmt.allocPrint(a, "{s}[1m]", .{m}) else m });
    }
    if (effortFor(req.reasoning, req.model)) |e| try argv.appendSlice(a, &.{ "--effort", e });
    if (req.auto_approve) {
        try argv.appendSlice(a, &.{ "--permission-mode", "bypassPermissions", "--dangerously-skip-permissions" });
    } else switch (req.sandbox) {
        .read_only => try argv.appendSlice(a, &.{ "--permission-mode", "plan" }),
        .workspace_write => try argv.appendSlice(a, &.{ "--permission-mode", "acceptEdits" }),
        .danger_full_access => try argv.appendSlice(a, &.{ "--permission-mode", "default" }),
    }
    if (req.resume_id) |r| try argv.append(a, try std.fmt.allocPrint(a, "--resume={s}", .{r}));
    if (optionOn(model_options, "chrome")) try argv.append(a, "--chrome");
    var settings: std.ArrayList(u8) = .empty;
    if (optionOn(model_options, "fastMode")) try settings.appendSlice(a, "\"fastMode\":true");
    if (optionOn(model_options, "thinking")) {
        if (settings.items.len > 0) try settings.append(a, ',');
        try settings.appendSlice(a, "\"alwaysThinkingEnabled\":true");
    }
    if (req.reasoning) |r| if (eq(r, "ultracode")) {
        if (settings.items.len > 0) try settings.append(a, ',');
        try settings.appendSlice(a, "\"ultracode\":true");
    };
    if (settings.items.len > 0) try argv.appendSlice(a, &.{ "--settings", try std.fmt.allocPrint(a, "{{{s}}}", .{settings.items}) });
    return argv.items;
}

/// A user message line (`wire.rs`), with Ultrathink's prefix.
pub fn userLine(a: Allocator, text: []const u8, reasoning: ?[]const u8) ![]u8 {
    const ultra = if (reasoning) |r| eq(r, "ultrathink") and !std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t\n"), "/") else false;
    const body = if (ultra) try std.fmt.allocPrint(a, "Ultrathink:\n{s}", .{text}) else text;
    return std.fmt.allocPrint(a, "{{\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":{f}}},\"parent_tool_use_id\":null}}", .{json.fmt(body, .{})});
}

/// `decode_tool_use`.
pub fn decodeToolUse(a: Allocator, name: []const u8, input: json.Value) ![]u8 {
    const s = struct {
        fn f(v: json.Value, k: []const u8) []const u8 {
            return getStr(v, k) orelse "";
        }
    }.f;
    const call: Call = if (eq(name, "Bash"))
        .{ .exec = s(input, "command") }
    else if (eq(name, "Read"))
        .{ .read_file = s(input, "file_path") }
    else if (eq(name, "Write"))
        .{ .write_file = s(input, "file_path") }
    else if (eq(name, "Edit"))
        .{ .edit_file = s(input, "file_path") }
    else if (eq(name, "Grep"))
        .{ .search = .{ .pattern = s(input, "pattern"), .path = getStr(input, "path") } }
    else if (eq(name, "Glob"))
        .{ .glob = s(input, "pattern") }
    else if (eq(name, "WebFetch"))
        .{ .web_fetch = s(input, "url") }
    else if (eq(name, "WebSearch"))
        .{ .web_search = s(input, "query") }
    else if (eq(name, "TodoWrite")) blk: {
        var items: std.ArrayList(Call.TodoItem) = .empty;
        if (get(input, "todos")) |todos| if (todos == .array) for (todos.array.items) |t| {
            try items.append(a, .{ .text = s(t, "content"), .done = eq(s(t, "status"), "completed") });
        };
        break :blk .{ .todo = items.items };
    } else if (eq(name, "Agent") or eq(name, "Task")) blk: {
        const d = s(input, "description");
        break :blk .{ .unknown = .{ .name = if (d.len > 0) try std.fmt.allocPrint(a, "Agent: {s}", .{d}) else "Agent", .input = input } };
    } else if (eq(name, "Workflow")) blk: {
        const title = workflowTitle(input);
        var obj = if (input == .object) try input.object.clone(a) else json.ObjectMap.empty;
        try obj.put(a, "subagent_type", .{ .string = "workflow" });
        break :blk .{ .unknown = .{ .name = try std.fmt.allocPrint(a, "Agent: {s}", .{title}), .input = .{ .object = obj } } };
    } else if (std.mem.startsWith(u8, name, "mcp__")) blk: {
        const rest = name["mcp__".len..];
        const sep = std.mem.indexOf(u8, rest, "__") orelse break :blk Call{ .unknown = .{ .name = name } };
        break :blk .{ .mcp = .{ .server = rest[0..sep], .tool = rest[sep + 2 ..] } };
    } else .{ .unknown = .{ .name = name, .input = input } };
    return call.toJson(a);
}

fn workflowTitle(input: json.Value) []const u8 {
    if (getStr(input, "script")) |script| {
        if (std.mem.indexOf(u8, script, "description")) |i| {
            const rest = script[i + "description".len ..];
            if (std.mem.indexOfAny(u8, rest, "\"'")) |q0| {
                const quote = rest[q0];
                if (std.mem.indexOfScalarPos(u8, rest, q0 + 1, quote)) |q1| if (q1 > q0 + 1) return rest[q0 + 1 .. q1];
            }
        }
    }
    if (getStr(input, "name")) |n| if (n.len > 0) return n;
    return "Workflow";
}

/// `assistant_error_text`.
pub fn assistantErrorText(a: Allocator, code: []const u8) ![]const u8 {
    const table = .{
        .{ "authentication_failed", "Authentication failed — sign in to Claude again." },
        .{ "oauth_org_not_allowed", "This organization isn't allowed to use Claude here." },
        .{ "billing_error", "Billing error — check your Claude plan or payment method." },
        .{ "rate_limit", "Claude usage limit reached — try again after the limit resets." },
        .{ "overloaded", "Claude is overloaded right now — try again shortly." },
        .{ "invalid_request", "The request was rejected as invalid." },
        .{ "model_not_found", "The selected model isn't available." },
        .{ "server_error", "Claude had a server error — try again." },
        .{ "max_output_tokens", "The reply hit the maximum output length." },
        .{ "unknown", "Claude returned an unspecified error." },
    };
    inline for (table) |e| if (eq(code, e[0])) return e[1];
    return std.fmt.allocPrint(a, "Claude error: {s}", .{code});
}

fn rateWindow(kind: []const u8) []const u8 {
    if (eq(kind, "five_hour")) return "5-hour";
    if (eq(kind, "seven_day") or eq(kind, "seven_day_overage_included")) return "weekly";
    if (eq(kind, "seven_day_opus")) return "weekly (Opus)";
    if (eq(kind, "seven_day_sonnet")) return "weekly (Sonnet)";
    if (eq(kind, "overage")) return "overage";
    return "usage";
}

/// The result frame's error (`normalize.rs`).
fn resultError(a: Allocator, root: json.Value) !?[]const u8 {
    var parts: std.ArrayList(u8) = .empty;
    var only_diag = false;
    if (get(root, "errors")) |errs| if (errs == .array) for (errs.array.items) |e| {
        const text = if (e == .string) e.string else try json.Stringify.valueAlloc(a, e, .{});
        if (std.mem.indexOf(u8, text, "[ede_diagnostic]") != null) {
            only_diag = true;
            continue;
        }
        if (parts.items.len > 0) try parts.appendSlice(a, "; ");
        try parts.appendSlice(a, text);
    };
    if (parts.items.len > 0) return parts.items;
    const sub = getStr(root, "subtype") orelse "";
    if (eq(sub, "error_max_turns")) return "The run hit the maximum number of turns.";
    if (eq(sub, "error_max_budget_usd")) return "The run hit its cost budget.";
    if (eq(sub, "error_max_structured_output_retries")) return "The run exhausted its structured-output retries.";
    if (only_diag) return null;
    return "The run ended with an error.";
}

/// One stdout frame → events, plus control requests for the caller.
pub const Normalizer = struct {
    session_seen: bool = false,
    session_id: ?[]const u8 = null,

    pub const Out = struct {
        events: std.ArrayList(Event) = .empty,
        /// A `can_use_tool` control request: (request_id, tool_name, input).
        control: ?struct { request_id: []const u8, tool: []const u8, input: json.Value } = null,
    };

    /// `a` must outlive the events (an arena per line).
    pub fn apply(self: *Normalizer, a: Allocator, line: []const u8, interrupted: bool) !Out {
        var out: Out = .{};
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return out;
        const root = json.parseFromSliceLeaky(json.Value, a, trimmed, .{}) catch return out;
        if (root != .object) return out;
        const ty = getStr(root, "type") orelse return out;
        // Frames from inside a subagent stay out of the parent transcript.
        const tagged = if (get(root, "parent_tool_use_id")) |p| p == .string else false;
        if (eq(ty, "system")) {
            const sub = getStr(root, "subtype") orelse "";
            if (eq(sub, "init") and !self.session_seen) {
                self.session_seen = true;
                if (getStr(root, "session_id")) |sid| {
                    self.session_id = try a.dupe(u8, sid);
                    try out.events.append(a, .{ .session_started = self.session_id.? });
                }
            } else if (eq(sub, "compact_boundary")) {
                const uuid = getStr(root, "uuid") orelse "boundary";
                const id = try std.fmt.allocPrint(a, "claude-compaction-{s}", .{uuid});
                var input = json.ObjectMap.empty;
                try input.put(a, "kind", .{ .string = "summary" });
                if (get(root, "compact_metadata")) |m| {
                    if (get(m, "pre_tokens")) |pt| try input.put(a, "tokensBefore", pt);
                    if (get(m, "trigger")) |tr| try input.put(a, "trigger", tr);
                }
                const call = try (Call{ .unknown = .{ .name = "Compact context", .input = .{ .object = input } } }).toJson(a);
                try out.events.append(a, .{ .tool_call = .{ .id = id, .call = call } });
                try out.events.append(a, .{ .tool_result = .{ .id = id, .is_error = false } });
            }
        } else if (eq(ty, "stream_event")) {
            if (tagged) return out;
            const ev = get(root, "event") orelse return out;
            if (!eq(getStr(ev, "type") orelse "", "content_block_delta")) return out;
            const delta = get(ev, "delta") orelse return out;
            const dt = getStr(delta, "type") orelse "";
            if (eq(dt, "text_delta")) {
                if (getStr(delta, "text")) |t| try out.events.append(a, .{ .text = t });
            } else if (eq(dt, "thinking_delta")) {
                if (getStr(delta, "thinking")) |t| try out.events.append(a, .{ .reasoning = t });
            }
        } else if (eq(ty, "assistant")) {
            if (tagged) return out;
            const msg = get(root, "message") orelse return out;
            if (get(msg, "content")) |content| if (content == .array) for (content.array.items) |block| {
                if (!eq(getStr(block, "type") orelse "", "tool_use")) continue;
                const id = getStr(block, "id") orelse continue;
                const name = getStr(block, "name") orelse "";
                const input = get(block, "input") orelse json.Value{ .null = {} };
                try out.events.append(a, .{ .tool_call = .{ .id = id, .call = try decodeToolUse(a, name, input) } });
            };
            if (getStr(root, "error")) |code| try out.events.append(a, .{ .err = try assistantErrorText(a, code) });
            try out.events.append(a, .message_completed);
        } else if (eq(ty, "user")) {
            if (tagged) return out;
            const msg = get(root, "message") orelse return out;
            if (get(msg, "content")) |content| if (content == .array) for (content.array.items) |block| {
                if (!eq(getStr(block, "type") orelse "", "tool_result")) continue;
                const id = getStr(block, "tool_use_id") orelse continue;
                const is_err = agent_turn.getBool(block, "is_error") orelse false;
                try out.events.append(a, .{ .tool_result = .{ .id = id, .is_error = is_err } });
            };
        } else if (eq(ty, "rate_limit_event")) {
            const info = get(root, "rate_limit_info") orelse return out;
            if (eq(getStr(info, "status") orelse "", "rejected")) {
                const msg = try std.fmt.allocPrint(a, "Claude {s} limit reached — the turn was blocked. Try again after it resets.", .{rateWindow(getStr(info, "rateLimitType") orelse "")});
                try out.events.append(a, .{ .err = msg });
            }
        } else if (eq(ty, "result")) {
            const sid = getStr(root, "session_id") orelse self.session_id;
            const ok = eq(getStr(root, "subtype") orelse "", "success");
            if (interrupted) {
                try out.events.append(a, .{ .done = .{ .status = .interrupted, .session_id = sid } });
            } else if (ok) {
                try out.events.append(a, .{ .done = .{ .status = .completed, .session_id = sid } });
            } else {
                try out.events.append(a, .{ .done = .{ .status = .errored, .err = try resultError(a, root), .session_id = sid } });
            }
        } else if (eq(ty, "control_request")) {
            const rid = getStr(root, "request_id") orelse return out;
            const req = get(root, "request") orelse return out;
            if (!eq(getStr(req, "subtype") orelse "", "can_use_tool")) return out;
            out.control = .{ .request_id = rid, .tool = getStr(req, "tool_name") orelse "", .input = get(req, "input") orelse .{ .object = .empty } };
        }
        return out;
    }
};

/// `control_response` envelope around `payload`.
pub fn controlResponse(a: Allocator, request_id: []const u8, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":{f},\"response\":{s}}}}}", .{ json.fmt(request_id, .{}), payload });
}

pub fn allowPayload(a: Allocator, input: json.Value) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"behavior\":\"allow\",\"updatedInput\":{f}}}", .{json.fmt(input, .{})});
}

pub const deny_payload = "{\"behavior\":\"deny\",\"message\":\"The user declined this tool call\"}";

/// AskUserQuestion's `input.questions[]` as `UserInputQuestion`s.
pub fn askQuestions(a: Allocator, input: json.Value) ![]agent_turn.Question {
    var qs: std.ArrayList(agent_turn.Question) = .empty;
    if (get(input, "questions")) |arr| if (arr == .array) for (arr.array.items, 0..) |q, i| {
        var opts: std.ArrayList([]const u8) = .empty;
        if (get(q, "options")) |os| if (os == .array) for (os.array.items) |o| {
            if (o == .string) try opts.append(a, o.string) else if (getStr(o, "label") orelse getStr(o, "value")) |l| try opts.append(a, l);
        };
        try qs.append(a, .{
            .id = try std.fmt.allocPrint(a, "q{d}", .{i}),
            .header = getStr(q, "header") orelse getStr(q, "title") orelse "Question",
            .question = getStr(q, "question") orelse getStr(q, "prompt") orelse "",
            .options = opts.items,
            .multiSelect = agent_turn.getBool(q, "multiSelect") orelse agent_turn.getBool(q, "multi_select") orelse false,
        });
    };
    return qs.items;
}

/// The allow payload for answered AskUserQuestion: the input plus
/// `answers: {question: label | [labels]}`.
pub fn askAnswersPayload(a: Allocator, input: json.Value, answers: []const agent_turn.Answer) ![]u8 {
    const qs = try askQuestions(a, input);
    var obj = if (input == .object) try input.object.clone(a) else json.ObjectMap.empty;
    var ans = json.ObjectMap.empty;
    for (qs) |q| {
        const labels = agent_turn.labelsFor(answers, q.id);
        if (q.multiSelect) {
            var arr = json.Array.init(a);
            for (labels) |l| try arr.append(.{ .string = l });
            try ans.put(a, q.question, .{ .array = arr });
        } else {
            try ans.put(a, q.question, .{ .string = try std.mem.join(a, "\n\n", labels) });
        }
    }
    try obj.put(a, "answers", .{ .object = ans });
    return allowPayload(a, .{ .object = obj });
}

const kind_approve: u8 = 1;
const kind_ask: u8 = 2;

fn approvalQuestion(a: Allocator, tool: []const u8, input: json.Value) ![]const u8 {
    const detail = getStr(input, "command") orelse getStr(input, "file_path") orelse getStr(input, "path") orelse getStr(input, "url");
    if (detail) |d| return std.fmt.allocPrint(a, "Claude wants to use {s} on `{s}`. Allow it?", .{ tool, d });
    return std.fmt.allocPrint(a, "Claude wants to use {s}. Allow it?", .{tool});
}

fn restricted(req: agent_turn.Request) bool {
    return !req.auto_approve and req.sandbox != .danger_full_access;
}

fn run(t: *Turn) !void {
    const a = t.arena.allocator();
    const exe = try t.resolveExe("claude", "CLAUDE_CODE_EXECUTABLE", &extra_paths, install_hint);
    const opts: ?json.Value = if (t.req.model_options_json) |mo| json.parseFromSliceLeaky(json.Value, a, mo, .{}) catch null else null;
    const argv = try buildArgv(a, exe, t.req, opts);
    var env = try t.childEnv(exe);
    defer env.deinit();
    // A previous run's process may still be exiting: two processes on one
    // session drop the new prompt (`live_sessions.rs`).
    if (t.req.resume_id) |r| if (!t.waitSessionClosed(r, agent_turn.session_wait_ms)) {
        std.log.warn("harness-engine: previous claude process still open on {s}; resuming anyway", .{r});
    };
    const proc = try t.spawn(argv, &env, .{});
    _ = t.send(try userLine(a, t.req.prompt, t.req.reasoning));

    var norm: Normalizer = .{};
    var held = false;
    var line_arena = std.heap.ArenaAllocator.init(t.gpa);
    defer line_arena.deinit();
    var saw_done = false;
    while (try proc.readLine()) |line| {
        defer _ = line_arena.reset(.retain_capacity);
        const la = line_arena.allocator();
        const out = try norm.apply(la, line, t.interrupted.load(.acquire));
        if (!held) if (norm.session_id) |sid| {
            t.holdSession(sid);
            held = true;
        };
        for (out.events.items) |ev| {
            if (ev == .done) saw_done = true;
            t.emit(ev);
        }
        if (out.control) |c| try onControl(t, la, c.request_id, c.tool, c.input);
        if (saw_done) break;
    }
    if (!saw_done) {
        if (t.interrupted.load(.acquire)) {
            t.emit(.{ .done = .{ .status = .interrupted, .session_id = norm.session_id } });
        } else {
            t.emit(.{ .done = .{ .status = .errored, .err = t.crash(proc), .session_id = norm.session_id } });
        }
    }
    proc.closeStdin();
    proc.armDeadline(agent_turn.kill_grace_ms);
}

fn onControl(t: *Turn, a: Allocator, request_id: []const u8, tool: []const u8, input: json.Value) !void {
    const data = try std.fmt.allocPrint(a, "{{\"request_id\":{f},\"tool\":{f},\"input\":{f}}}", .{ json.fmt(request_id, .{}), json.fmt(tool, .{}), json.fmt(input, .{}) });
    if (eq(tool, "AskUserQuestion")) {
        try t.ask(kind_ask, data, try askQuestions(a, input));
        return;
    }
    if (restricted(t.req)) {
        const q = agent_turn.yesNo("approve", "Approve tool", try approvalQuestion(a, tool, input));
        try t.ask(kind_approve, data, &q);
        return;
    }
    _ = t.send(try controlResponse(a, request_id, try allowPayload(a, input)));
}

fn answer(t: *Turn, p: *const agent_turn.Pending, answers: ?[]const agent_turn.Answer) void {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const data = json.parseFromSliceLeaky(json.Value, a, p.data, .{}) catch return;
    const rid = getStr(data, "request_id") orelse return;
    const input = get(data, "input") orelse json.Value{ .null = {} };
    const payload: []const u8 = switch (p.kind) {
        kind_approve => if (agent_turn.answeredYes(answers)) allowPayload(a, input) catch return else deny_payload,
        kind_ask => if (answers) |as| askAnswersPayload(a, input, as) catch return else deny_payload,
        else => return,
    };
    _ = t.send(controlResponse(a, rid, payload) catch return);
}

var interrupt_seq: std.atomic.Value(u32) = .init(0);

fn interrupt(t: *Turn) void {
    var buf: [128]u8 = undefined;
    const n = interrupt_seq.fetchAdd(1, .acq_rel) + 1;
    const line = std.fmt.bufPrint(&buf, "{{\"type\":\"control_request\",\"request_id\":\"int_{d}\",\"request\":{{\"subtype\":\"interrupt\"}}}}", .{n}) catch return;
    _ = t.send(line);
}

fn steer(t: *Turn, text: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const line = userLine(arena.allocator(), text, t.req.reasoning) catch return false;
    return t.send(line);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testReq(env: *const std.process.Environ.Map) agent_turn.Request {
    return .{ .chat_id = "c", .harness = "claude-code", .prompt = "hi", .cwd = "/tmp", .env = env };
}

test "claude: argv matches build_command for model, effort, permission mode and resume" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var req = testReq(&env);
    req.model = "claude-opus-4-6";
    req.reasoning = "xhigh";
    req.sandbox = .workspace_write;
    req.resume_id = "sess-1";
    const argv = try buildArgv(a, "/bin/claude", req, null);
    const joined = try std.mem.join(a, " ", argv);
    try testing.expectEqualStrings("/bin/claude --print --input-format stream-json --output-format stream-json --verbose --include-partial-messages --thinking-display summarized --permission-prompt-tool stdio --model claude-opus-4-6 --effort max --permission-mode acceptEdits --resume=sess-1", joined);

    req.model = "claude-opus-5-5";
    req.auto_approve = true;
    req.resume_id = null;
    req.reasoning = "ultracode";
    const opts = try json.parseFromSliceLeaky(json.Value, a, "{\"contextWindow\":\"1m\",\"fastMode\":true}", .{});
    const argv2 = try std.mem.join(a, " ", try buildArgv(a, "claude", req, opts));
    try testing.expect(std.mem.indexOf(u8, argv2, "--model claude-opus-5-5[1m] --effort xhigh --permission-mode bypassPermissions --dangerously-skip-permissions --settings {\"fastMode\":true,\"ultracode\":true}") != null);

    req.auto_approve = false;
    req.sandbox = .read_only;
    req.reasoning = null;
    const argv3 = try std.mem.join(a, " ", try buildArgv(a, "claude", req, null));
    try testing.expect(std.mem.endsWith(u8, argv3, "--permission-mode plan"));
    try testing.expectEqualStrings("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Ultrathink:\\nfix it\"},\"parent_tool_use_id\":null}", try userLine(a, "fix it", "ultrathink"));
}

test "claude: stream-json frames normalize into text, reasoning, tools, errors and Done" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n: Normalizer = .{};
    const lines = [_][]const u8{
        "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s-1\",\"model\":\"m\"}",
        "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s-2\"}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}}",
        "{\"type\":\"stream_event\",\"parent_tool_use_id\":\"t9\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"child\"}}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hi\"},{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}},{\"type\":\"tool_use\",\"id\":\"tu2\",\"name\":\"mcp__docs__search\",\"input\":{}}]}}",
        "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu1\",\"is_error\":true}]}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[]},\"error\":\"rate_limit\"}",
        "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"session_id\":\"s-1\"}",
    };
    var evs: std.ArrayList(Event) = .empty;
    for (lines) |l| evs.appendSlice(a, (try n.apply(a, l, false)).events.items) catch unreachable;
    try testing.expectEqualStrings("s-1", evs.items[0].session_started);
    try testing.expectEqualStrings("hmm", evs.items[1].reasoning);
    try testing.expectEqualStrings("Hi", evs.items[2].text);
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"ls\"}", evs.items[3].tool_call.call);
    try testing.expectEqualStrings("{\"kind\":\"mcp\",\"server\":\"docs\",\"tool\":\"search\"}", evs.items[4].tool_call.call);
    try testing.expect(evs.items[5] == .message_completed);
    try testing.expect(evs.items[6].tool_result.is_error);
    try testing.expectEqualStrings("Claude usage limit reached — try again after the limit resets.", evs.items[7].err);
    const done = evs.items[9].done;
    try testing.expectEqual(agent_turn.DoneStatus.errored, done.status);
    try testing.expectEqualStrings("The run hit the maximum number of turns.", done.err.?);
    try testing.expectEqual(@as(usize, 10), evs.items.len);

    const ctl = try n.apply(a, "{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"rm x\"}}}", false);
    try testing.expectEqualStrings("r1", ctl.control.?.request_id);
    try testing.expectEqualStrings("Claude wants to use Bash on `rm x`. Allow it?", try approvalQuestion(a, "Bash", ctl.control.?.input));
    const ask_in = try json.parseFromSliceLeaky(json.Value, a, "{\"questions\":[{\"header\":\"Pick\",\"question\":\"Which?\",\"options\":[{\"label\":\"A\"},\"B\"],\"multiSelect\":false}]}", .{});
    const payload = try askAnswersPayload(a, ask_in, &.{.{ .questionId = "q0", .labels = &.{"B"} }});
    try testing.expect(std.mem.indexOf(u8, payload, "\"answers\":{\"Which?\":\"B\"}") != null);
}

const testkit = @import("agent_testkit.zig");

const mock_turn =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\printf '%s\n' "$@" >> "$d/argv.txt"
    \\pwd > "$d/cwd.txt"
    \\IFS= read -r first
    \\printf '%s\n' "$first" > "$d/stdin.txt"
    \\echo '{"type":"system","subtype":"init","session_id":"sess-mock","model":"m"}'
    \\echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}'
    \\echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}}'
    \\echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}'
    \\echo '{"type":"control_request","request_id":"cr1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}'
    \\IFS= read -r resp
    \\case "$resp" in *'"behavior":"allow"'*) ok=allowed;; *) ok=denied;; esac
    \\echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","is_error":false}]}}'
    \\echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" '$ok'"}}}'
    \\echo '{"type":"result","subtype":"success","session_id":"sess-mock"}'
    \\
;

test "claude: a turn against a mock CLI streams, asks permission, runs the tool and resumes next time" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "claude-code", .override_var = "CLAUDE_CODE_EXECUTABLE", .script = mock_turn });
    defer rig.destroy();
    try rig.run("m-1", "list files");
    try rig.waitQuestion(5000);
    try rig.waitFor("Claude wants to use Bash on `ls`. Allow it?", 1000);
    try rig.answerOpen("approve", "Yes");
    try rig.waitIdle(5000);

    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    // Text after a tool call starts a new part (`fold_event_into_parts`).
    try testing.expect(std.mem.indexOf(u8, doc, "{\"id\":\"t0\",\"kind\":\"text\",\"text\":\"Hello world\"}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "{\"id\":\"t3\",\"kind\":\"text\",\"text\":\" allowed\"}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"call\":{\"kind\":\"exec\",\"command\":\"ls\"},\"resolved\":true,\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"kind\":\"input\",\"requestId\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"options\":[\"Yes\",\"No\"],\"multiSelect\":false,\"multiline\":false}],\"resolved\":true") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"complete\"") != null);
    try testing.expectEqualStrings("sess-mock", rig.chatSessionId().?);
    const stdin = try rig.readFile("stdin.txt");
    defer testing.allocator.free(stdin);
    try testing.expectEqualStrings("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"list files\"},\"parent_tool_use_id\":null}\n", stdin);

    // The second turn resumes the stored session.
    try rig.run("m-2", "again");
    try rig.waitQuestion(5000);
    try rig.answerOpen("approve", "No");
    try rig.waitIdle(5000);
    const doc2 = try rig.docJson();
    defer testing.allocator.free(doc2);
    try testing.expect(std.mem.indexOf(u8, doc2, "\" denied\"") != null);
    const argv = try rig.readFile("argv.txt");
    defer testing.allocator.free(argv);
    try testing.expect(std.mem.indexOf(u8, argv, "--permission-mode\nacceptEdits\n") != null);
    try testing.expect(std.mem.indexOf(u8, argv, "--resume=sess-mock\n") != null);
}

const mock_interrupt =
    \\#!/bin/sh
    \\IFS= read -r first
    \\echo '{"type":"system","subtype":"init","session_id":"sess-int"}'
    \\echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Working"}}}'
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"subtype":"interrupt"'*) echo '{"type":"result","subtype":"error_during_execution","session_id":"sess-int"}';;
    \\    *'"type":"user"'*) echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Steered"}}}'; echo '{"type":"result","subtype":"success","session_id":"sess-int"}';;
    \\  esac
    \\done
    \\
;

test "claude: interrupt sends the control request and the entry ends aborted" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "claude-code", .override_var = "CLAUDE_CODE_EXECUTABLE", .script = mock_interrupt, .autonomy = "full-access" });
    defer rig.destroy();
    try rig.run("m-1", "long task");
    try rig.waitFor("Working", 5000);
    try rig.command("{\"kind\":\"interrupt\"}");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"aborted\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"kind\":\"error\"") == null);
}

test "claude: a steer mid-turn is delivered and continues in a new entry" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "claude-code", .override_var = "CLAUDE_CODE_EXECUTABLE", .script = mock_interrupt, .autonomy = "full-access" });
    defer rig.destroy();
    try rig.run("m-1", "long task");
    try rig.waitFor("Working", 5000);
    try rig.command("{\"kind\":\"steer\",\"messageId\":\"s-1\",\"prompt\":\"also do this\"}");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    const steer_at = std.mem.indexOf(u8, doc, "\"text\":\"also do this\"").?;
    const working_at = std.mem.indexOf(u8, doc, "\"text\":\"Working\"").?;
    const steered_at = std.mem.indexOf(u8, doc, "\"text\":\"Steered\"").?;
    try testing.expect(working_at < steer_at and steer_at < steered_at);
}

test "claude: a missing binary ends the turn with Rust's not-installed error" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "claude-code", .override_var = "CLAUDE_CODE_EXECUTABLE", .script = mock_turn, .missing_binary = true });
    defer rig.destroy();
    try rig.run("m-1", "hi");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"kind\":\"error\",\"message\":\"harness binary not found: /nonexistent/harness-agent-mock does not exist\"") != null);
}

const mock_crash =
    \\#!/bin/sh
    \\IFS= read -r first
    \\echo 'boom: Bearer sk-secret' >&2
    \\exit 3
    \\
;

test "claude: a CLI that exits without a result surfaces the crash message" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "claude-code", .override_var = "CLAUDE_CODE_EXECUTABLE", .script = mock_crash });
    defer rig.destroy();
    try rig.run("m-1", "hi");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "claude exited unexpectedly (exit code 3): boom: Bearer [REDACTED]") != null);
}

const mock_live_session =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\case "$*" in *--resume=*)
    \\  if [ -f "$d/first-exited" ]; then echo yes > "$d/second-saw"; else echo no > "$d/second-saw"; fi;;
    \\esac
    \\IFS= read -r first
    \\echo '{"type":"system","subtype":"init","session_id":"sess-live"}'
    \\echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Working"}}}'
    \\case "$*" in *--resume=*) ;; *) while [ ! -f "$d/go" ]; do sleep 0.05; done;; esac
    \\echo '{"type":"result","subtype":"success","session_id":"sess-live"}'
    \\case "$*" in *--resume=*) ;; *) sleep 1; touch "$d/first-exited";; esac
    \\
;

test "claude: a queued turn resumes only after the previous claude process exited" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "claude-code", .override_var = "CLAUDE_CODE_EXECUTABLE", .script = mock_live_session, .autonomy = "full-access" });
    defer rig.destroy();
    try rig.run("m-1", "first");
    try rig.waitFor("Working", 5000);
    try rig.call("QueueMessage", "{\"chatId\":\"chat-1\",\"id\":\"q-1\",\"text\":\"second\",\"holdForTurnEnd\":true}");
    const go = try std.fmt.allocPrint(testing.allocator, "{s}/go", .{rig.dir});
    defer testing.allocator.free(go);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = go, .data = "" });
    try rig.waitIdle(15000);
    const saw = try rig.readFile("second-saw");
    defer testing.allocator.free(saw);
    try testing.expectEqualStrings("yes\n", saw);
}
