//! Codex adapter (`crates/harness/src/codex/{mod,normalize,catalog,compaction}.rs`).
//!
//! `codex app-server` over newline-delimited JSON-RPC 2.0: `initialize`,
//! `thread/start` (or `thread/resume`), `turn/start`; item notifications
//! become transcript events, approval and user-input requests become
//! questions, `turn/interrupt` stops and `turn/steer` steers.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const agent_turn = @import("agent_turn.zig");
const Turn = agent_turn.Turn;
const Event = agent_turn.Event;
const Call = agent_turn.Call;
const get = agent_turn.get;
const getStr = agent_turn.getStr;

pub const adapter: agent_turn.Adapter = .{
    .name = "codex app-server",
    .run = run,
    .interrupt = interrupt,
    .steer = steer,
    .answer = answer,
    .steers_mid_turn = true,
};

pub const install_hint = "codex (searched PATH, the login shell's PATH, ~/.local/bin, ~/.codex/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CODEX_EXECUTABLE to override)";
pub const extra_paths = [_][]const u8{ "~/.local/bin/codex", "~/.codex/bin/codex", "~/.npm-global/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex" };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `codex_effort`.
pub fn effortFor(reasoning: ?[]const u8) ?[]const u8 {
    const r = reasoning orelse return null;
    if (eq(r, "minimal") or eq(r, "low")) return "low";
    if (eq(r, "medium")) return "medium";
    if (eq(r, "high")) return "high";
    if (eq(r, "xhigh") or eq(r, "ultracode") or eq(r, "ultrathink")) return "xhigh";
    if (eq(r, "max")) return "max";
    if (eq(r, "ultra")) return "ultra";
    return null;
}

pub const Policy = struct { approval: []const u8, sandbox: agent_turn.Sandbox };

/// Restricted runs (`!auto_approve && sandbox != DangerFullAccess`) ask
/// `on-request` in their own sandbox; every other run is unattended.
pub fn policyFor(req: agent_turn.Request) Policy {
    if (!req.auto_approve and req.sandbox != .danger_full_access) return .{ .approval = "on-request", .sandbox = req.sandbox };
    return .{ .approval = "never", .sandbox = .danger_full_access };
}

fn sandboxPolicyJson(s: agent_turn.Sandbox) []const u8 {
    return switch (s) {
        .read_only => "{\"type\":\"readOnly\"}",
        .workspace_write => "{\"type\":\"workspaceWrite\",\"networkAccess\":true}",
        .danger_full_access => "{\"type\":\"dangerFullAccess\"}",
    };
}

pub fn initializeParams(a: Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"clientInfo\":{{\"name\":\"harness-native\",\"title\":\"Harness\",\"version\":{f}}},\"capabilities\":{{\"experimentalApi\":true}}}}", .{json.fmt(@import("build_info").version, .{})});
}

/// The `serviceTier` model option; rides thread-start and every turn.
/// "default" means Standard and is omitted.
pub fn serviceTier(a: Allocator, req: agent_turn.Request) ?[]const u8 {
    const mo = req.model_options_json orelse return null;
    const v = json.parseFromSliceLeaky(json.Value, a, mo, .{}) catch return null;
    const tier = getStr(v, "serviceTier") orelse return null;
    return if (eq(tier, "default")) null else tier;
}

/// `thread/start` params (plus `threadId` for `thread/resume`).
pub fn threadParams(a: Allocator, req: agent_turn.Request, resume_id: ?[]const u8) ![]u8 {
    const pol = policyFor(req);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{{\"cwd\":{f},\"approvalPolicy\":{f},\"sandbox\":{f}", .{ json.fmt(req.cwd, .{}), json.fmt(pol.approval, .{}), json.fmt(pol.sandbox.wire(), .{}) });
    if (req.model) |m| try w.print(",\"model\":{f}", .{json.fmt(m, .{})});
    if (serviceTier(a, req)) |tier| try w.print(",\"serviceTier\":{f}", .{json.fmt(tier, .{})});
    if (resume_id) |r| try w.print(",\"threadId\":{f}", .{json.fmt(r, .{})});
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn inputJson(a: Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[{{\"type\":\"text\",\"text\":{f}}}]", .{json.fmt(text, .{})});
}

/// `turn/start` params.
pub fn turnParams(a: Allocator, req: agent_turn.Request, thread_id: []const u8) ![]u8 {
    const pol = policyFor(req);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{{\"threadId\":{f},\"input\":{s},\"approvalPolicy\":{f},\"sandboxPolicy\":{s},\"summary\":\"auto\"", .{ json.fmt(thread_id, .{}), try inputJson(a, req.prompt), json.fmt(pol.approval, .{}), sandboxPolicyJson(pol.sandbox) });
    if (req.model) |m| try w.print(",\"model\":{f}", .{json.fmt(m, .{})});
    if (effortFor(req.reasoning)) |e| try w.print(",\"effort\":{f}", .{json.fmt(e, .{})});
    if (serviceTier(a, req)) |tier| try w.print(",\"serviceTier\":{f}", .{json.fmt(tier, .{})});
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// `fileChange` item → its call (`file_change_call`).
fn fileChangeCall(item: json.Value) Call {
    const changes = get(item, "changes") orelse return .{ .apply_patch = null };
    if (changes != .array or changes.array.items.len != 1) return .{ .apply_patch = null };
    const c = changes.array.items[0];
    const path = getStr(c, "path") orelse return .{ .apply_patch = null };
    const kind = blk: {
        const k = get(c, "kind") orelse break :blk "update";
        if (k == .string) break :blk k.string;
        break :blk getStr(k, "type") orelse "update";
    };
    if (eq(kind, "add")) return .{ .write_file = path };
    if (eq(kind, "update")) return .{ .edit_file = path };
    return .{ .apply_patch = path };
}

fn collabName(a: Allocator, item: json.Value) ![]const u8 {
    const tool = getStr(item, "tool") orelse "";
    if (eq(tool, "spawnAgent")) return "Agent";
    if (eq(tool, "sendInput") or eq(tool, "sendMessage")) return "Send agent message";
    if (eq(tool, "wait")) return "Wait for agents";
    if (eq(tool, "closeAgent")) return "Close agent";
    if (eq(tool, "resumeAgent")) return "Resume agent";
    return std.fmt.allocPrint(a, "Agent control: {s}", .{tool});
}

/// Notification normalizer for the parent thread.
pub const Normalizer = struct {
    thread_id: []const u8 = "",
    streamed: std.ArrayList([]const u8) = .empty,
    reason_index: ?i64 = null,
    reason_tail: [2]u8 = .{ 0, 0 },
    last_tokens: ?i64 = null,

    fn itemId(params: json.Value) []const u8 {
        return getStr(params, "itemId") orelse getStr(params, "item_id") orelse "";
    }

    fn noteReasoning(self: *Normalizer, text: []const u8) void {
        if (text.len >= 2) {
            self.reason_tail = .{ text[text.len - 2], text[text.len - 1] };
        } else if (text.len == 1) {
            self.reason_tail = .{ self.reason_tail[1], text[0] };
        }
    }

    fn reasoning(self: *Normalizer, a: Allocator, out: *std.ArrayList(Event), index: ?i64, text: []const u8) !void {
        if (index) |idx| {
            if (self.reason_index) |prev| if (prev != idx and self.reason_tail[1] != 0) {
                const gap: []const u8 = if (self.reason_tail[1] != '\n') "\n\n" else if (self.reason_tail[0] != '\n') "\n" else "";
                if (gap.len > 0) {
                    try out.append(a, .{ .reasoning = gap });
                    self.noteReasoning(gap);
                }
            };
            self.reason_index = idx;
        }
        if (text.len == 0) return;
        try out.append(a, .{ .reasoning = text });
        self.noteReasoning(text);
    }

    fn intField(v: json.Value, a: []const u8, b: []const u8) ?i64 {
        const x = get(v, a) orelse get(v, b) orelse return null;
        return if (x == .integer) x.integer else null;
    }

    /// One notification → events. `done` is set for turn ends.
    pub fn apply(self: *Normalizer, a: Allocator, method: []const u8, params: json.Value, interrupted: bool, out: *std.ArrayList(Event)) !void {
        const tid = getStr(params, "threadId") orelse getStr(params, "thread_id") orelse "";
        // Subagent threads stay out of the parent transcript.
        if (tid.len > 0 and self.thread_id.len > 0 and !eq(tid, self.thread_id)) return;
        if (eq(method, "item/agentMessage/delta")) {
            const d = getStr(params, "delta") orelse getStr(params, "textDelta") orelse "";
            if (d.len == 0) return;
            const id = itemId(params);
            if (id.len > 0) try self.streamed.append(a, try a.dupe(u8, id));
            try out.append(a, .{ .text = d });
        } else if (eq(method, "item/reasoning/textDelta")) {
            try self.reasoning(a, out, intField(params, "contentIndex", "content_index"), getStr(params, "delta") orelse "");
        } else if (eq(method, "item/reasoning/summaryTextDelta")) {
            try self.reasoning(a, out, intField(params, "summaryIndex", "summary_index"), getStr(params, "delta") orelse "");
        } else if (eq(method, "item/reasoning/summaryPartAdded")) {
            try self.reasoning(a, out, intField(params, "summaryIndex", "summary_index"), "");
        } else if (eq(method, "item/started") or eq(method, "item/completed")) {
            const it = get(params, "item") orelse return;
            try self.onItem(a, it, eq(method, "item/completed"), out);
        } else if (eq(method, "thread/tokenUsage/updated")) {
            if (get(params, "tokenUsage")) |tu| if (get(tu, "last")) |last| {
                if (get(last, "totalTokens")) |tt| if (tt == .integer) {
                    self.last_tokens = tt.integer;
                };
            };
        } else if (eq(method, "turn/completed")) {
            const turn = get(params, "turn") orelse json.Value{ .null = {} };
            var err: ?[]const u8 = null;
            if (get(turn, "error")) |e| if (e == .object) {
                err = getStr(e, "message") orelse "Codex turn failed";
            };
            if (err == null and eq(getStr(turn, "status") orelse "", "failed")) err = "Codex turn failed";
            const status: agent_turn.DoneStatus = if (interrupted) .interrupted else if (err != null) .errored else .completed;
            try out.append(a, .{ .done = .{ .status = status, .err = if (status == .errored) err else null, .session_id = self.thread_id } });
        } else if (eq(method, "turn/failed")) {
            const turn = get(params, "turn") orelse json.Value{ .null = {} };
            const err = if (get(turn, "error")) |e| getStr(e, "message") else null;
            try out.append(a, .{ .done = .{ .status = if (interrupted) .interrupted else .errored, .err = err orelse "Codex turn failed", .session_id = self.thread_id } });
        } else if (eq(method, "turn/aborted")) {
            try out.append(a, .{ .done = .{ .status = .interrupted, .session_id = self.thread_id } });
        } else if (eq(method, "error")) {
            if (agent_turn.getBool(params, "willRetry") orelse false) return;
            const msg = (if (get(params, "error")) |e| getStr(e, "message") else null) orelse getStr(params, "message") orelse "Codex error";
            try out.append(a, .{ .err = msg });
        }
    }

    fn onItem(self: *Normalizer, a: Allocator, it: json.Value, completed: bool, out: *std.ArrayList(Event)) !void {
        const ty = getStr(it, "type") orelse return;
        const id = getStr(it, "id") orelse "";
        const status = getStr(it, "status") orelse "";
        if (eq(ty, "agentMessage") or eq(ty, "agent_message")) {
            if (!completed) return;
            var streamed = false;
            for (self.streamed.items) |s| if (eq(s, id)) {
                streamed = true;
            };
            if (!streamed) if (getStr(it, "text")) |t| if (t.len > 0) try out.append(a, .{ .text = t });
            try out.append(a, .{ .text = "\n\n" });
            try out.append(a, .message_completed);
        } else if (eq(ty, "commandExecution") or eq(ty, "command_execution")) {
            if (!completed) {
                const cmd = getStr(it, "command") orelse "";
                try out.append(a, .{ .tool_call = .{ .id = id, .call = try (Call{ .exec = cmd }).toJson(a) } });
            } else {
                const code = get(it, "exitCode") orelse get(it, "exit_code");
                const bad_code = if (code) |c| (c == .integer and c.integer != 0) else false;
                try out.append(a, .{ .tool_result = .{ .id = id, .is_error = eq(status, "failed") or bad_code } });
            }
        } else if (eq(ty, "fileChange") or eq(ty, "file_change")) {
            try out.append(a, .{ .tool_call = .{ .id = id, .call = try fileChangeCall(it).toJson(a) } });
            if (completed) try out.append(a, .{ .tool_result = .{ .id = id, .is_error = eq(status, "failed") or eq(status, "declined") } });
        } else if (eq(ty, "mcpToolCall") or eq(ty, "mcp_tool_call")) {
            if (!completed) {
                try out.append(a, .{ .tool_call = .{ .id = id, .call = try (Call{ .mcp = .{ .server = getStr(it, "server") orelse "", .tool = getStr(it, "tool") orelse "" } }).toJson(a) } });
            } else try out.append(a, .{ .tool_result = .{ .id = id, .is_error = eq(status, "failed") } });
        } else if (eq(ty, "webSearch") or eq(ty, "web_search")) {
            try out.append(a, .{ .tool_call = .{ .id = id, .call = try (Call{ .web_search = getStr(it, "query") orelse "" }).toJson(a) } });
            if (completed) try out.append(a, .{ .tool_result = .{ .id = id, .is_error = false } });
        } else if (eq(ty, "todoList") or eq(ty, "todo_list")) {
            var items: std.ArrayList(Call.TodoItem) = .empty;
            if (get(it, "items")) |arr| if (arr == .array) for (arr.array.items) |x| {
                const done = agent_turn.getBool(x, "completed") orelse agent_turn.getBool(x, "done") orelse false;
                try items.append(a, .{ .text = getStr(x, "text") orelse "", .done = done });
            };
            try out.append(a, .{ .tool_call = .{ .id = id, .call = try (Call{ .todo = items.items }).toJson(a) } });
            if (completed) try out.append(a, .{ .tool_result = .{ .id = id, .is_error = false } });
        } else if (eq(ty, "contextCompaction") or eq(ty, "context_compaction")) {
            if (id.len == 0) return;
            const chip = try std.fmt.allocPrint(a, "codex-compaction-{s}", .{id});
            if (!completed) {
                var input: json.ObjectMap = .empty;
                try input.put(a, "kind", .{ .string = "opaque" });
                if (self.last_tokens) |n| try input.put(a, "tokensBefore", .{ .integer = n });
                try out.append(a, .{ .tool_call = .{ .id = chip, .call = try (Call{ .unknown = .{ .name = agent_turn.compaction_tool, .input = .{ .object = input } } }).toJson(a) } });
            } else {
                try out.append(a, .{ .tool_result = .{ .id = chip, .is_error = false } });
                try out.append(a, .{ .text = "Context compacted." });
            }
        } else if (eq(ty, "exitedReviewMode") or eq(ty, "exited_review_mode")) {
            if (completed) if (getStr(it, "review")) |r| try out.append(a, .{ .text = r });
        } else if (eq(ty, "imageGeneration") or eq(ty, "image_generation")) {
            try out.append(a, .{ .tool_call = .{ .id = id, .call = try (Call{ .unknown = .{ .name = "Generate image" } }).toJson(a) } });
            if (completed) {
                try out.append(a, .{ .tool_result = .{ .id = id, .is_error = eq(status, "failed") } });
                if (getStr(it, "savedPath") == null) try out.append(a, .{ .err = if (eq(status, "failed")) "Image generation failed" else "Image generation completed without a saved file" });
            }
        } else if (eq(ty, "error")) {
            if (getStr(it, "message")) |m| try out.append(a, .{ .err = m });
        } else if (eq(ty, "collabAgentToolCall") or eq(ty, "collab_agent_tool_call")) {
            try out.append(a, .{ .tool_call = .{ .id = id, .call = try (Call{ .unknown = .{ .name = try collabName(a, it), .input = it } }).toJson(a) } });
            if (completed) try out.append(a, .{ .tool_result = .{ .id = id, .is_error = eq(status, "failed") } });
        }
    }
};

/// Approval question text (`approval_question`).
pub fn approvalQuestion(a: Allocator, method: []const u8, params: json.Value) ![2][]const u8 {
    if (std.mem.indexOf(u8, method, "commandExecution") != null) {
        var cmd: []const u8 = "";
        if (get(params, "command")) |c| switch (c) {
            .string => |s| cmd = s,
            .array => |arr| {
                var parts: std.ArrayList([]const u8) = .empty;
                for (arr.items) |p| if (p == .string) try parts.append(a, p.string);
                cmd = try std.mem.join(a, " ", parts.items);
            },
            else => {},
        };
        return .{ "Approve command", if (cmd.len == 0) "Codex wants to run a command. Allow it?" else try std.fmt.allocPrint(a, "Codex wants to run `{s}`. Allow it?", .{cmd}) };
    }
    var paths: std.ArrayList([]const u8) = .empty;
    if (get(params, "changes")) |cs| if (cs == .array) for (cs.array.items) |c| if (getStr(c, "path")) |p| try paths.append(a, p);
    return .{ "Approve file change", if (paths.items.len == 0) "Codex wants to modify files. Allow it?" else try std.fmt.allocPrint(a, "Codex wants to modify {s}. Allow it?", .{try std.mem.join(a, ", ", paths.items)}) };
}

/// `item/tool/requestUserInput` questions; ids keep the wire id.
pub fn userInputQuestions(a: Allocator, params: json.Value) ![]agent_turn.Question {
    var qs: std.ArrayList(agent_turn.Question) = .empty;
    if (get(params, "questions")) |arr| if (arr == .array) for (arr.array.items, 0..) |q, i| {
        var opts: std.ArrayList([]const u8) = .empty;
        if (get(q, "options")) |os| if (os == .array) for (os.array.items) |o| {
            if (o == .string) try opts.append(a, o.string) else if (getStr(o, "label") orelse getStr(o, "value")) |l| try opts.append(a, l);
        };
        try qs.append(a, .{
            .id = getStr(q, "id") orelse getStr(q, "questionId") orelse getStr(q, "question_id") orelse try std.fmt.allocPrint(a, "q{d}", .{i}),
            .header = getStr(q, "header") orelse getStr(q, "title") orelse getStr(q, "label") orelse "Codex question",
            .question = getStr(q, "question") orelse getStr(q, "prompt") orelse getStr(q, "text") orelse "",
            .options = opts.items,
            .multiSelect = agent_turn.getBool(q, "multiSelect") orelse agent_turn.getBool(q, "multi_select") orelse false,
        });
    };
    return qs.items;
}

const State = struct {
    thread_id: ?[]u8 = null,
    turn_id: ?[]u8 = null,
    next_id: u64 = 1,
};

fn state(t: *Turn) ?*State {
    return @ptrCast(@alignCast(t.state orelse return null));
}

/// Send a request (any thread); returns its id.
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

fn respondRaw(t: *Turn, id_json: []const u8, result_json: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    buf.print(t.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json }) catch return;
    _ = t.send(buf.items);
}

fn rpcError(a: Allocator, method: []const u8, err: json.Value) ![]u8 {
    const msg = getStr(err, "message") orelse "error";
    const code: i64 = if (get(err, "code")) |c| (if (c == .integer) c.integer else 0) else 0;
    if (get(err, "data")) |d| if (d != .null) return std.fmt.allocPrint(a, "harness protocol error: {s}: {s} (code {d}): {f}", .{ method, msg, code, json.fmt(d, .{}) });
    return std.fmt.allocPrint(a, "harness protocol error: {s}: {s} (code {d})", .{ method, msg, code });
}

const kind_approval: u8 = 1;
const kind_user_input: u8 = 2;

fn onServerRequest(t: *Turn, a: Allocator, id: json.Value, method: []const u8, params: json.Value) !void {
    const id_json = try std.fmt.allocPrint(a, "{f}", .{json.fmt(id, .{})});
    if (eq(method, "item/commandExecution/requestApproval") or eq(method, "item/fileChange/requestApproval")) {
        if (t.req.auto_approve) return respondRaw(t, id_json, "{\"decision\":\"accept\"}");
        const hq = try approvalQuestion(a, method, params);
        const q = agent_turn.yesNo("approve", hq[0], hq[1]);
        return t.ask(kind_approval, id_json, &q);
    }
    if (eq(method, "item/tool/requestUserInput")) {
        const qs = try userInputQuestions(a, params);
        if (qs.len == 0) return respondRaw(t, id_json, "{\"answers\":{}}");
        return t.ask(kind_user_input, id_json, qs);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    try buf.print(t.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"unsupported method: {s}\"}}}}", .{ id_json, method });
    _ = t.send(buf.items);
}

fn answer(t: *Turn, p: *const agent_turn.Pending, answers: ?[]const agent_turn.Answer) void {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (p.kind) {
        kind_approval => respondRaw(t, p.data, if (agent_turn.answeredYes(answers)) "{\"decision\":\"accept\"}" else "{\"decision\":\"decline\"}"),
        kind_user_input => {
            const qs = json.parseFromSliceLeaky([]agent_turn.Question, a, p.questions, .{ .ignore_unknown_fields = true }) catch return;
            var out: std.Io.Writer.Allocating = .init(a);
            const w = &out.writer;
            w.writeAll("{\"answers\":{") catch return;
            for (qs, 0..) |q, i| {
                if (i > 0) w.writeByte(',') catch return;
                w.print("{f}:{{\"answers\":{f}}}", .{ json.fmt(q.id, .{}), json.fmt(agent_turn.labelsFor(answers, q.id), .{}) }) catch return;
            }
            w.writeAll("}}") catch return;
            respondRaw(t, p.data, out.written());
        },
        else => {},
    }
}

fn interrupt(t: *Turn) void {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    t.mu.lockUncancelable(t.io);
    const st = state(t) orelse {
        t.mu.unlock(t.io);
        return;
    };
    const params = if (st.thread_id != null and st.turn_id != null)
        std.fmt.allocPrint(arena.allocator(), "{{\"threadId\":{f},\"turnId\":{f}}}", .{ json.fmt(st.thread_id.?, .{}), json.fmt(st.turn_id.?, .{}) }) catch null
    else
        null;
    t.mu.unlock(t.io);
    if (params) |p| _ = request(t, "turn/interrupt", p);
}

fn steer(t: *Turn, text: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    t.mu.lockUncancelable(t.io);
    const st = state(t) orelse {
        t.mu.unlock(t.io);
        return false;
    };
    const params = if (st.thread_id != null and st.turn_id != null)
        std.fmt.allocPrint(a, "{{\"threadId\":{f},\"expectedTurnId\":{f},\"input\":{s}}}", .{ json.fmt(st.thread_id.?, .{}), json.fmt(st.turn_id.?, .{}), inputJson(a, text) catch "[]" }) catch null
    else
        null;
    t.mu.unlock(t.io);
    const p = params orelse return false;
    return request(t, "turn/steer", p) != null;
}

fn setId(t: *Turn, field: *?[]u8, value: []const u8) void {
    t.mu.lockUncancelable(t.io);
    defer t.mu.unlock(t.io);
    if (field.*) |old| t.gpa.free(old);
    field.* = t.gpa.dupe(u8, value) catch null;
}

const Msg = struct { root: json.Value };

/// Read until the response to `id` arrives, serving requests and
/// notifications meanwhile. Null on EOF.
fn awaitResponse(t: *Turn, proc: *@import("agent_proc.zig").AgentProc, a: Allocator, id: u64, norm: *Normalizer, events: *std.ArrayList(Event)) !?json.Value {
    while (try proc.readLine()) |line| {
        const root = json.parseFromSliceLeaky(json.Value, a, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
        if (root != .object) continue;
        if (try dispatch(t, a, root, norm, events)) |rid| if (rid == id) return root;
    }
    return null;
}

/// Route one message; returns the id of a response.
fn dispatch(t: *Turn, a: Allocator, root: json.Value, norm: *Normalizer, events: *std.ArrayList(Event)) !?u64 {
    const method = getStr(root, "method");
    const id = get(root, "id");
    if (method) |m| {
        const params = get(root, "params") orelse json.Value{ .null = {} };
        if (id) |i| {
            try onServerRequest(t, a, i, m, params);
        } else {
            if (eq(m, "turn/started")) if (get(params, "turn")) |turn| if (getStr(turn, "id")) |tid| if (state(t)) |st| setId(t, &st.turn_id, tid);
            try norm.apply(a, m, params, t.interrupted.load(.acquire), events);
        }
        return null;
    }
    if (id) |i| if (i == .integer) return @intCast(i.integer);
    return null;
}

fn run(t: *Turn) !void {
    const a = t.arena.allocator();
    var st: State = .{};
    defer {
        if (st.thread_id) |s| t.gpa.free(s);
        if (st.turn_id) |s| t.gpa.free(s);
    }
    t.state = &st;
    defer {
        t.mu.lockUncancelable(t.io);
        t.state = null;
        t.mu.unlock(t.io);
    }
    const exe = try t.resolveExe("codex", "CODEX_EXECUTABLE", &extra_paths, install_hint);
    var env = try t.childEnv(exe);
    defer env.deinit();
    const proc = try t.spawn(&.{ exe, "app-server" }, &env, .{});

    var line_arena = std.heap.ArenaAllocator.init(t.gpa);
    defer line_arena.deinit();
    var norm: Normalizer = .{};
    var events: std.ArrayList(Event) = .empty;

    // Handshake.
    const la = line_arena.allocator();
    const init_id = request(t, "initialize", try initializeParams(la)) orelse return failExit(t, proc, "initialize");
    const init_resp = (try awaitResponse(t, proc, la, init_id, &norm, &events)) orelse return failExit(t, proc, "initialize");
    if (get(init_resp, "error")) |e| return t.fail("{s}", .{try rpcError(la, "initialize", e)});
    _ = t.send("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");

    var thread_resp: ?json.Value = null;
    if (t.req.resume_id) |r| {
        const rid = request(t, "thread/resume", try threadParams(la, t.req, r)) orelse return failExit(t, proc, "thread/resume");
        const resp = (try awaitResponse(t, proc, la, rid, &norm, &events)) orelse return failExit(t, proc, "thread/resume");
        if (get(resp, "error") == null) thread_resp = resp;
    }
    if (thread_resp == null) {
        const sid = request(t, "thread/start", try threadParams(la, t.req, null)) orelse return failExit(t, proc, "thread/start");
        const resp = (try awaitResponse(t, proc, la, sid, &norm, &events)) orelse return failExit(t, proc, "thread/start");
        if (get(resp, "error")) |e| return t.fail("{s}", .{try rpcError(la, "thread/start", e)});
        thread_resp = resp;
    }
    const thread_id = blk: {
        const res = get(thread_resp.?, "result") orelse break :blk null;
        const th = get(res, "thread") orelse break :blk null;
        break :blk getStr(th, "id");
    } orelse return t.fail("harness protocol error: thread/start returned no thread id", .{});
    const thread_copy = try a.dupe(u8, thread_id);
    setId(t, &st.thread_id, thread_copy);
    norm.thread_id = thread_copy;
    t.emit(.{ .session_started = thread_copy });
    if (t.interrupted.load(.acquire)) {
        t.emit(.{ .done = .{ .status = .interrupted, .session_id = thread_copy } });
        return;
    }

    const turn_id = request(t, "turn/start", try turnParams(la, t.req, thread_copy)) orelse return failExit(t, proc, "turn/start");
    for (events.items) |ev| t.emit(ev);
    events = .empty;
    _ = line_arena.reset(.retain_capacity);

    var saw_done = false;
    while (try proc.readLine()) |line| {
        defer _ = line_arena.reset(.retain_capacity);
        const lla = line_arena.allocator();
        events = .empty;
        const root = json.parseFromSliceLeaky(json.Value, lla, std.mem.trim(u8, line, " \t\r\n"), .{}) catch continue;
        if (root != .object) continue;
        const resp_id = try dispatch(t, lla, root, &norm, &events);
        if (resp_id) |rid| if (rid == turn_id) {
            if (get(root, "error")) |e| {
                t.emit(.{ .done = .{ .status = if (t.interrupted.load(.acquire)) .interrupted else .errored, .err = try rpcError(a, "turn/start", e), .session_id = thread_copy } });
                saw_done = true;
                break;
            }
            if (get(root, "result")) |res| if (get(res, "turn")) |turn| if (getStr(turn, "id")) |tid| setId(t, &st.turn_id, tid);
        };
        for (events.items) |ev| {
            if (ev == .done) saw_done = true;
            t.emit(ev);
        }
        if (saw_done) break;
    }
    if (!saw_done) {
        if (t.interrupted.load(.acquire)) {
            t.emit(.{ .done = .{ .status = .interrupted, .session_id = thread_copy } });
        } else {
            t.emit(.{ .done = .{ .status = .errored, .err = t.crash(proc), .session_id = thread_copy } });
        }
    }
    proc.closeStdin();
    proc.escalate(agent_turn.kill_grace_ms, agent_turn.kill_grace_ms * 2);
}

fn failExit(t: *Turn, proc: *@import("agent_proc.zig").AgentProc, method: []const u8) error{TurnFailed} {
    if (t.interrupted.load(.acquire)) return t.fail("interrupted", .{});
    const crash = t.crash(proc);
    return t.fail("harness protocol error: {s}: app-server exited before responding; {s}", .{ method, crash });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "codex: thread and turn params follow approval policy, sandbox and effort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var req: agent_turn.Request = .{ .chat_id = "c", .harness = "codex", .prompt = "do it", .cwd = "/w", .env = &env, .sandbox = .workspace_write, .model = "gpt-5.5", .reasoning = "ultrathink" };
    try testing.expectEqualStrings("{\"cwd\":\"/w\",\"approvalPolicy\":\"on-request\",\"sandbox\":\"workspace-write\",\"model\":\"gpt-5.5\"}", try threadParams(a, req, null));
    try testing.expectEqualStrings("{\"threadId\":\"th\",\"input\":[{\"type\":\"text\",\"text\":\"do it\"}],\"approvalPolicy\":\"on-request\",\"sandboxPolicy\":{\"type\":\"workspaceWrite\",\"networkAccess\":true},\"summary\":\"auto\",\"model\":\"gpt-5.5\",\"effort\":\"xhigh\"}", try turnParams(a, req, "th"));
    req.auto_approve = true;
    req.model = null;
    req.reasoning = null;
    try testing.expectEqualStrings("{\"cwd\":\"/w\",\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\",\"threadId\":\"old\"}", try threadParams(a, req, "old"));
    req.auto_approve = false;
    req.sandbox = .danger_full_access;
    try testing.expectEqualStrings("never", policyFor(req).approval);
}

test "codex: notifications normalize into text, reasoning, tools and Done" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n: Normalizer = .{ .thread_id = "th-1" };
    var out: std.ArrayList(Event) = .empty;
    const msgs = [_][2][]const u8{
        .{ "item/reasoning/summaryTextDelta", "{\"summaryIndex\":0,\"delta\":\"plan\"}" },
        .{ "item/reasoning/summaryTextDelta", "{\"summaryIndex\":1,\"delta\":\"next\"}" },
        .{ "item/agentMessage/delta", "{\"itemId\":\"m1\",\"delta\":\"Hi\"}" },
        .{ "item/agentMessage/delta", "{\"threadId\":\"child\",\"itemId\":\"m9\",\"delta\":\"child text\"}" },
        .{ "item/started", "{\"item\":{\"type\":\"commandExecution\",\"id\":\"c1\",\"command\":\"ls -la\"}}" },
        .{ "item/completed", "{\"item\":{\"type\":\"commandExecution\",\"id\":\"c1\",\"status\":\"completed\",\"exitCode\":2}}" },
        .{ "item/completed", "{\"item\":{\"type\":\"fileChange\",\"id\":\"f1\",\"status\":\"completed\",\"changes\":[{\"path\":\"a.zig\",\"kind\":\"update\"}]}}" },
        .{ "item/completed", "{\"item\":{\"type\":\"agentMessage\",\"id\":\"m1\",\"text\":\"Hi\"}}" },
        .{ "turn/completed", "{\"turn\":{\"id\":\"t1\",\"status\":\"completed\"}}" },
    };
    for (msgs) |m| try n.apply(a, m[0], try json.parseFromSliceLeaky(json.Value, a, m[1], .{}), false, &out);
    try testing.expectEqualStrings("plan", out.items[0].reasoning);
    try testing.expectEqualStrings("\n\n", out.items[1].reasoning);
    try testing.expectEqualStrings("next", out.items[2].reasoning);
    try testing.expectEqualStrings("Hi", out.items[3].text);
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"ls -la\"}", out.items[4].tool_call.call);
    try testing.expect(out.items[5].tool_result.is_error);
    try testing.expectEqualStrings("{\"kind\":\"editFile\",\"path\":\"a.zig\"}", out.items[6].tool_call.call);
    try testing.expectEqualStrings("\n\n", out.items[8].text);
    try testing.expect(out.items[9] == .message_completed);
    try testing.expectEqual(agent_turn.DoneStatus.completed, out.items[10].done.status);
    try testing.expectEqualStrings("th-1", out.items[10].done.session_id.?);
    const hq = try approvalQuestion(a, "item/commandExecution/requestApproval", try json.parseFromSliceLeaky(json.Value, a, "{\"command\":[\"rm\",\"-rf\",\"x\"]}", .{}));
    try testing.expectEqualStrings("Codex wants to run `rm -rf x`. Allow it?", hq[1]);
}

const testkit = @import("agent_testkit.zig");

const mock_turn =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\printf '%s\n' "$@" > "$d/argv.txt"
    \\while IFS= read -r line; do
    \\  printf '%s\n' "$line" >> "$d/stdin.txt"
    \\  case "$line" in
    \\    *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"mock"}}';;
    \\    *'"method":"thread/resume"'*) echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"no such thread"}}';;
    \\    *'"method":"thread/start"'*) id=$(printf '%s' "$line" | sed 's/.*"id":\([0-9]*\).*/\1/'); echo '{"jsonrpc":"2.0","id":'$id',"result":{"thread":{"id":"th-mock"}}}';;
    \\    *'"method":"turn/start"'*)
    \\      id=$(printf '%s' "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
    \\      echo '{"jsonrpc":"2.0","id":'$id',"result":{"turn":{"id":"turn-1"}}}'
    \\      echo '{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"th-mock","turn":{"id":"turn-1"}}}'
    \\      echo '{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"th-mock","itemId":"m1","delta":"Hello"}}'
    \\      echo '{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"th-mock","item":{"type":"commandExecution","id":"c1","command":"make test"}}}'
    \\      echo '{"jsonrpc":"2.0","id":"srv-1","method":"item/commandExecution/requestApproval","params":{"threadId":"th-mock","command":"make test"}}';;
    \\    *'"id":"srv-1"'*'"decision":"accept"'*)
    \\      echo '{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"th-mock","item":{"type":"commandExecution","id":"c1","status":"completed","exitCode":0}}}'
    \\      echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"th-mock","turn":{"id":"turn-1","status":"completed"}}}';;
    \\    *'"method":"turn/interrupt"'*)
    \\      echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"th-mock","turn":{"id":"turn-1","status":"interrupted"}}}';;
    \\  esac
    \\done
    \\
;

test "codex: a turn against a mock app-server streams, asks approval and stores the thread" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "codex", .override_var = "CODEX_EXECUTABLE", .script = mock_turn });
    defer rig.destroy();
    try rig.run("m-1", "run the tests");
    try rig.waitQuestion(5000);
    try rig.waitFor("Codex wants to run `make test`. Allow it?", 1000);
    try rig.answerOpen("approve", "Yes");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"call\":{\"kind\":\"exec\",\"command\":\"make test\"},\"resolved\":true,\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"complete\"") != null);
    try testing.expectEqualStrings("th-mock", rig.chatSessionId().?);
    const argv = try rig.readFile("argv.txt");
    defer testing.allocator.free(argv);
    try testing.expectEqualStrings("app-server\n", argv);

    // Resume: thread/resume fails, the adapter falls back to thread/start.
    try rig.run("m-2", "again");
    try rig.waitQuestion(5000);
    try rig.command("{\"kind\":\"interrupt\"}");
    try rig.waitIdle(8000);
    const stdin = try rig.readFile("stdin.txt");
    defer testing.allocator.free(stdin);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"method\":\"thread/resume\",\"params\":{\"cwd\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"threadId\":\"th-mock\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"method\":\"turn/interrupt\",\"params\":{\"threadId\":\"th-mock\",\"turnId\":\"turn-1\"}") != null);
    try testing.expect(std.mem.indexOf(u8, stdin, "\"decision\":\"decline\"") != null);
    const doc2 = try rig.docJson();
    defer testing.allocator.free(doc2);
    try testing.expect(std.mem.indexOf(u8, doc2, "\"status\":\"aborted\"") != null);
}

test "codex: a missing binary ends the turn with Rust's not-installed error" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "codex", .override_var = "CODEX_EXECUTABLE", .script = mock_turn, .missing_binary = true });
    defer rig.destroy();
    try rig.run("m-1", "hi");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "harness binary not found: /nonexistent/harness-agent-mock does not exist") != null);
}

test "codex: the service tier rides thread start and every turn, except Standard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var req: agent_turn.Request = .{ .chat_id = "c", .harness = "codex", .prompt = "hi", .cwd = "/w", .env = &env, .model = "gpt-5.5", .model_options_json = "{\"serviceTier\":\"fast\"}" };
    try testing.expect(std.mem.endsWith(u8, try threadParams(a, req, null), ",\"model\":\"gpt-5.5\",\"serviceTier\":\"fast\"}"));
    try testing.expect(std.mem.endsWith(u8, try turnParams(a, req, "th"), ",\"serviceTier\":\"fast\"}"));
    req.model_options_json = "{\"serviceTier\":\"default\"}";
    try testing.expect(std.mem.indexOf(u8, try turnParams(a, req, "th"), "serviceTier") == null);
}
