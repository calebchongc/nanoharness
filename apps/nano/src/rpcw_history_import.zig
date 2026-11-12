//! `ExternalHistoryImport`, ported from `crates/engine/src/rpc.rs`
//! (`methods::EXTERNAL_HISTORY_IMPORT`) and `crates/engine/src/external_history/`
//! (`ExternalHistory::import`/`import_one`, `entries_for`, `chat_row`, and the
//! `load` readers of `claude.rs`, `codex.rs` and `graff.rs`), with
//! `harness_doc::summarize_tool_output` (`crates/doc/src/parts.rs`).
//!
//! An import reads one session another tool wrote (never writing to it), keeps
//! what the person saw — their prompts, the agent's replies, and a row per tool
//! call with a one-line result — and writes it as a chat doc plus a chat row
//! through the paths a live chat uses. The chat id is `ext-<source>-<native
//! id>`, so importing twice is a no-op, and a session Harness itself started
//! (its native id is a chat's `harnessSessionId`) is skipped.
//!
//! Discovery is `rpcw_history.discover` (the `ExternalHistoryList` port).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const history = @import("rpcw_history.zig");
const engine_host = @import("engine_host.zig");
const chat_sandbox = @import("chat_sandbox.zig");
const session_doc = @import("session_doc.zig");
const mcp_util = @import("mcp/util.zig");

const RpcOutcome = common.RpcOutcome;

/// `PREVIEW_CHARS`: characters of the last reply kept as the chat's preview.
const preview_chars: usize = 160;
/// `harness_doc::TOOL_OUTPUT_SUMMARY_MAX`.
pub const tool_output_summary_max: usize = 160;
/// `CHAT2_DOC_EPOCH`.
const chat2_doc_epoch: u32 = 2;

// ── the neutral transcript ─────────────────────────────────────────────────

pub const Role = enum { user, assistant };

pub const Tool = struct {
    /// `ToolCall` as JSON (`{"kind":…}`).
    call_json: []const u8,
    output: ?[]const u8 = null,
    is_error: bool = false,
};

pub const Block = union(enum) {
    text: []const u8,
    tool: Tool,
};

pub const Msg = struct {
    role: Role,
    at_ms: i64,
    blocks: std.ArrayList(Block) = .empty,
};

/// What `load` returns; everything lives in `arena`.
pub const Transcript = struct {
    msgs: std.ArrayList(Msg) = .empty,
};

// ── shared helpers ─────────────────────────────────────────────────────────

fn field(v: json.Value, key: []const u8) json.Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

fn str(v: json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key);
    return if (f == .string) f.string else null;
}

fn isTrue(v: json.Value, key: []const u8) bool {
    const f = field(v, key);
    return f == .bool and f.bool;
}

fn eqStr(v: json.Value, key: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, str(v, key) orelse return false, want);
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n\x0b\x0c").len == 0;
}

/// `parse_time_ms`, 0 when absent or unreadable.
fn timeMs(line: json.Value) i64 {
    const t = str(line, "timestamp") orelse return 0;
    return mcp_util.parseRfc3339Ms(t) orelse 0;
}

/// `serde_json::Value::to_string` for a non-string value.
fn jsonText(arena: Allocator, v: json.Value) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{json.fmt(v, .{})});
}

/// The `text` of each block joined with newlines; `only_text_type` keeps just
/// blocks whose `type` is `text`. `null` when an array gives nothing and
/// `null_if_empty` is set, or the value is neither a string nor an array.
pub fn blocksText(arena: Allocator, content: json.Value, only_text_type: bool, null_if_empty: bool) !?[]const u8 {
    switch (content) {
        .string => |s| return s,
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            var n: usize = 0;
            for (arr.items) |b| {
                if (only_text_type and !eqStr(b, "type", "text")) continue;
                const t = str(b, "text") orelse continue;
                if (n > 0) try out.append(arena, '\n');
                try out.appendSlice(arena, t);
                n += 1;
            }
            if (n == 0 and null_if_empty) return null;
            return out.items;
        },
        else => return null,
    }
}

/// `harness_doc::summarize_tool_output`: fence lines dropped, trimmed; short
/// enough is kept whole, longer is its first non-empty line cut to 160
/// characters plus `…`; nothing left is `null`. Pure.
pub fn summarizeToolOutput(arena: Allocator, text: []const u8) !?[]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        // `str::lines` drops one trailing `\r` per line.
        const l = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, l, " \t\r\n\x0b\x0c"), "```")) continue;
        if (!first) try kept.append(arena, '\n');
        try kept.appendSlice(arena, l);
        first = false;
    }
    // `str::lines` yields no empty final line after a trailing newline.
    const stripped = std.mem.trim(u8, kept.items, " \t\r\n\x0b\x0c");
    if (stripped.len == 0) return null;
    const count = std.unicode.utf8CountCodepoints(stripped) catch stripped.len;
    if (count <= tool_output_summary_max) return stripped;
    var it = std.mem.splitScalar(u8, stripped, '\n');
    var line: []const u8 = stripped;
    while (it.next()) |l| {
        if (!isBlank(l)) {
            line = l;
            break;
        }
    }
    line = std.mem.trimEnd(u8, line, " \t\r\n\x0b\x0c");
    var end: usize = 0;
    var chars: usize = 0;
    while (end < line.len and chars < tool_output_summary_max) : (chars += 1) {
        end += std.unicode.utf8ByteSequenceLength(line[end]) catch 1;
    }
    return try std.fmt.allocPrint(arena, "{s}…", .{line[0..@min(end, line.len)]});
}

/// A JSON `ToolCall` (`#[serde(tag = "kind", rename_all = "camelCase")]`).
const Call = union(enum) {
    exec: []const u8,
    read_file: []const u8,
    write_file: []const u8,
    edit_file: []const u8,
    apply_patch,
    search: struct { pattern: []const u8, path: ?[]const u8 },
    glob: []const u8,
    web_fetch: []const u8,
    web_search: []const u8,
    mcp: struct { server: []const u8, tool: []const u8 },
    unknown: []const u8,

    fn toJson(self: Call, arena: Allocator) ![]const u8 {
        const j = struct {
            fn s(v: []const u8) @TypeOf(json.fmt(v, .{})) {
                return json.fmt(v, .{});
            }
        }.s;
        return switch (self) {
            .exec => |c| std.fmt.allocPrint(arena, "{{\"kind\":\"exec\",\"command\":{f}}}", .{j(c)}),
            .read_file => |p| std.fmt.allocPrint(arena, "{{\"kind\":\"readFile\",\"path\":{f}}}", .{j(p)}),
            .write_file => |p| std.fmt.allocPrint(arena, "{{\"kind\":\"writeFile\",\"path\":{f}}}", .{j(p)}),
            .edit_file => |p| std.fmt.allocPrint(arena, "{{\"kind\":\"editFile\",\"path\":{f}}}", .{j(p)}),
            .apply_patch => "{\"kind\":\"applyPatch\"}",
            .search => |x| if (x.path) |p|
                std.fmt.allocPrint(arena, "{{\"kind\":\"search\",\"pattern\":{f},\"path\":{f}}}", .{ j(x.pattern), j(p) })
            else
                std.fmt.allocPrint(arena, "{{\"kind\":\"search\",\"pattern\":{f}}}", .{j(x.pattern)}),
            .glob => |p| std.fmt.allocPrint(arena, "{{\"kind\":\"glob\",\"pattern\":{f}}}", .{j(p)}),
            .web_fetch => |u| std.fmt.allocPrint(arena, "{{\"kind\":\"webFetch\",\"url\":{f}}}", .{j(u)}),
            .web_search => |q| std.fmt.allocPrint(arena, "{{\"kind\":\"webSearch\",\"query\":{f}}}", .{j(q)}),
            .mcp => |m| std.fmt.allocPrint(arena, "{{\"kind\":\"mcp\",\"server\":{f},\"tool\":{f}}}", .{ j(m.server), j(m.tool) }),
            .unknown => |n| std.fmt.allocPrint(arena, "{{\"kind\":\"unknown\",\"name\":{f}}}", .{j(n)}),
        };
    }
};

/// Push `block` onto the current assistant turn, starting one (at `at_ms`)
/// when a person spoke last. Returns the block's (message, block) position.
fn pushAssistant(arena: Allocator, t: *Transcript, at_ms: i64, block: Block) !struct { usize, usize } {
    const items = t.msgs.items;
    if (items.len == 0 or items[items.len - 1].role != .assistant) {
        try t.msgs.append(arena, .{ .role = .assistant, .at_ms = at_ms });
    }
    const m = t.msgs.items.len - 1;
    try t.msgs.items[m].blocks.append(arena, block);
    return .{ m, t.msgs.items[m].blocks.items.len - 1 };
}

fn pushUser(arena: Allocator, t: *Transcript, at_ms: i64, text: []const u8) !void {
    var msg: Msg = .{ .role = .user, .at_ms = at_ms };
    try msg.blocks.append(arena, .{ .text = text });
    try t.msgs.append(arena, msg);
}

const CallIndex = std.StringHashMapUnmanaged(struct { usize, usize });

fn toolAt(t: *Transcript, calls: *const CallIndex, id: ?[]const u8) ?*Tool {
    const pos = calls.get(id orelse return null) orelse return null;
    const b = &t.msgs.items[pos[0]].blocks.items[pos[1]];
    return switch (b.*) {
        .tool => |*tool| tool,
        .text => null,
    };
}

/// A JSONL file read line by line (`BufReader::lines`).
pub const Lines = struct {
    file: std.Io.File,
    io: std.Io,
    buf: [64 * 1024]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    line: std.Io.Writer.Allocating,
    done: bool = false,

    pub fn open(gpa: Allocator, io: std.Io, path: []const u8) !*Lines {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const self = try gpa.create(Lines);
        self.* = .{ .file = file, .io = io, .line = .init(gpa) };
        self.reader = file.reader(io, &self.buf);
        return self;
    }

    pub fn close(self: *Lines, gpa: Allocator) void {
        self.line.deinit();
        self.file.close(self.io);
        gpa.destroy(self);
    }

    /// The next line without its `\n` (and one `\r`), valid until the next
    /// call; `error.InvalidUtf8` for a line that is not UTF-8.
    fn next(self: *Lines) !?[]const u8 {
        if (self.done) return null;
        self.line.clearRetainingCapacity();
        const r = &self.reader.interface;
        _ = try r.streamDelimiterLimit(&self.line.writer, '\n', .unlimited);
        if (r.buffered().len > 0) r.toss(1) else self.done = true;
        const raw = self.line.written();
        if (self.done and raw.len == 0) return null;
        const text = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return text;
    }

    /// Whether another line follows (`lines.peek().is_some()`).
    fn more(self: *Lines) bool {
        if (self.done) return false;
        _ = self.reader.interface.peekByte() catch return false;
        return true;
    }
};

/// `json_lines`: parsed lines; malformed lines are skipped, and reading
/// stops at an I/O error or a line that is not UTF-8.
pub const JsonLines = struct {
    lines: *Lines,
    arena: Allocator,

    pub fn next(self: *JsonLines) ?json.Value {
        while (true) {
            const text = (self.lines.next() catch return null) orelse return null;
            return json.parseFromSliceLeaky(json.Value, self.arena, text, .{ .allocate = .alloc_always }) catch continue;
        }
    }
};

pub const LoadError = struct { message: []const u8 };

/// `std::io::Error`'s display for what opening or reading a file can hit.
pub fn ioMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied, error.PermissionDenied => "Permission denied (os error 13)",
        error.IsDir => "Is a directory (os error 21)",
        error.InvalidUtf8 => "stream did not contain valid UTF-8",
        else => @errorName(err),
    };
}

// ── Claude Code (claude.rs) ────────────────────────────────────────────────

/// `claude::tool_call`: Claude Code's tool names mapped to Harness's; only the
/// argument that names the target is kept.
fn claudeCall(name: []const u8, input: json.Value) Call {
    const s = struct {
        fn get(v: json.Value, key: []const u8) []const u8 {
            return str(v, key) orelse "";
        }
    }.get;
    const eql = std.mem.eql;
    if (eql(u8, name, "Bash")) return .{ .exec = s(input, "command") };
    if (eql(u8, name, "Read")) return .{ .read_file = s(input, "file_path") };
    if (eql(u8, name, "Write")) return .{ .write_file = s(input, "file_path") };
    if (eql(u8, name, "Edit") or eql(u8, name, "MultiEdit")) return .{ .edit_file = s(input, "file_path") };
    if (eql(u8, name, "Grep")) return .{ .search = .{ .pattern = s(input, "pattern"), .path = str(input, "path") } };
    if (eql(u8, name, "Glob")) return .{ .glob = s(input, "pattern") };
    if (eql(u8, name, "WebFetch")) return .{ .web_fetch = s(input, "url") };
    if (eql(u8, name, "WebSearch")) return .{ .web_search = s(input, "query") };
    if (std.mem.startsWith(u8, name, "mcp__")) {
        const rest = name["mcp__".len..];
        if (std.mem.indexOf(u8, rest, "__")) |i| return .{ .mcp = .{ .server = rest[0..i], .tool = rest[i + 2 ..] } };
    }
    return .{ .unknown = name };
}

fn loadClaude(arena: Allocator, io: std.Io, path: []const u8) !Transcript {
    var t: Transcript = .{};
    const lines = try Lines.open(arena, io, path);
    defer lines.close(arena);
    var jl: JsonLines = .{ .lines = lines, .arena = arena };
    var calls: CallIndex = .empty;
    while (jl.next()) |line| {
        if (isTrue(line, "isSidechain") or isTrue(line, "isMeta")) continue;
        const at_ms = timeMs(line);
        const content = field(field(line, "message"), "content");
        const kind = str(line, "type") orelse continue;
        if (std.mem.eql(u8, kind, "user")) {
            if (content == .array) {
                for (content.array.items) |block| {
                    if (!eqStr(block, "type", "tool_result")) continue;
                    const tool = toolAt(&t, &calls, str(block, "tool_use_id")) orelse continue;
                    // `result_text`: a string, or every block's `text`.
                    const result = try blocksText(arena, field(block, "content"), false, true);
                    tool.output = if (result) |r| try summarizeToolOutput(arena, r) else null;
                    tool.is_error = isTrue(block, "is_error");
                }
            }
            // `user_text`: a string, or the `text` blocks.
            if (try blocksText(arena, content, true, true)) |text| {
                if (!history.isScaffolding(text)) try pushUser(arena, &t, at_ms, text);
            }
        } else if (std.mem.eql(u8, kind, "assistant")) {
            // One assistant turn spans several lines; they stay one message
            // until a person speaks again.
            var blocks: std.ArrayList(Block) = .empty;
            var ids: std.ArrayList(?[]const u8) = .empty;
            switch (content) {
                .string => |s| if (!isBlank(s)) {
                    try blocks.append(arena, .{ .text = s });
                    try ids.append(arena, null);
                },
                .array => |items| for (items.items) |item| {
                    const it = str(item, "type") orelse continue;
                    if (std.mem.eql(u8, it, "text")) {
                        const tx = str(item, "text") orelse continue;
                        if (isBlank(tx)) continue;
                        try blocks.append(arena, .{ .text = tx });
                        try ids.append(arena, null);
                    } else if (std.mem.eql(u8, it, "tool_use")) {
                        const call = claudeCall(str(item, "name") orelse "tool", field(item, "input"));
                        try blocks.append(arena, .{ .tool = .{ .call_json = try call.toJson(arena) } });
                        try ids.append(arena, str(item, "id"));
                    }
                },
                else => {},
            }
            if (blocks.items.len == 0) continue;
            for (blocks.items, ids.items) |b, id| {
                const pos = try pushAssistant(arena, &t, at_ms, b);
                if (id) |cid| try calls.put(arena, cid, pos);
            }
        }
    }
    return t;
}

// ── Codex (codex.rs) ───────────────────────────────────────────────────────

/// `command_text`: `["bash","-lc","script"]` is the script; any other argv is joined.
fn codexCommand(arena: Allocator, args: json.Value) ![]const u8 {
    const c = field(args, "command");
    const command = if (c == .null) field(args, "cmd") else c;
    switch (command) {
        .string => |s| return s,
        .array => |argv| {
            var parts: std.ArrayList([]const u8) = .empty;
            for (argv.items) |a| if (a == .string) try parts.append(arena, a.string);
            const p = parts.items;
            if (p.len == 3 and std.mem.startsWith(u8, p[1], "-") and std.mem.endsWith(u8, p[1], "c")) return p[2];
            return std.mem.join(arena, " ", p);
        },
        else => return "",
    }
}

fn codexCall(arena: Allocator, name: []const u8, arguments: []const u8) !Call {
    const args = json.parseFromSliceLeaky(json.Value, arena, arguments, .{ .allocate = .alloc_always }) catch @as(json.Value, .null);
    for ([_][]const u8{ "shell", "container.exec", "exec_command", "shell_command", "local_shell" }) |n| {
        if (std.mem.eql(u8, name, n)) return .{ .exec = try codexCommand(arena, args) };
    }
    if (std.mem.eql(u8, name, "apply_patch")) return .apply_patch;
    return .{ .unknown = name };
}

/// `output_text`: plain text, or a JSON object whose `output` is the text
/// (failed when `metadata.exit_code` is non-zero).
fn codexOutput(arena: Allocator, output: json.Value) !struct { []const u8, bool } {
    const raw = if (output == .string) output.string else try jsonText(arena, output);
    const obj = json.parseFromSliceLeaky(json.Value, arena, raw, .{ .allocate = .alloc_always }) catch return .{ raw, false };
    if (obj != .object) return .{ raw, false };
    const text = str(obj, "output") orelse return .{ raw, false };
    const code = field(field(obj, "metadata"), "exit_code");
    return .{ text, code == .integer and code.integer != 0 };
}

/// `codex::load`. Unlike the other readers a malformed record aborts the
/// import (only a truncated final record is tolerated): a silently cut
/// conversation would be saved for good.
fn loadCodex(arena: Allocator, io: std.Io, path: []const u8, err_out: *LoadError) !Transcript {
    var t: Transcript = .{};
    const lines = try Lines.open(arena, io, path);
    defer lines.close(arena);
    var calls: CallIndex = .empty;
    var index: usize = 0;
    while (true) : (index += 1) {
        const text = (lines.next() catch |e| {
            err_out.message = ioMessage(e);
            return error.LoadFailed;
        }) orelse break;
        if (isBlank(text)) continue;
        const line = json.parseFromSliceLeaky(json.Value, arena, text, .{ .allocate = .alloc_always }) catch |e| {
            if (e == error.UnexpectedEndOfInput and !lines.more()) break;
            err_out.message = try std.fmt.allocPrint(arena, "Codex history contains an invalid JSON record at line {d}", .{index + 1});
            return error.LoadFailed;
        };
        if (!eqStr(line, "type", "response_item")) continue;
        const at_ms = timeMs(line);
        const p = field(line, "payload");
        const kind = str(p, "type") orelse continue;
        if (std.mem.eql(u8, kind, "message")) {
            const role = str(p, "role") orelse continue;
            // `message_text`: a string, or every block's `text`.
            const msg_text = (try blocksText(arena, field(p, "content"), false, false)) orelse "";
            if (std.mem.eql(u8, role, "user")) {
                if (!history.isScaffolding(msg_text)) try pushUser(arena, &t, at_ms, msg_text);
            } else if (std.mem.eql(u8, role, "assistant")) {
                if (!isBlank(msg_text)) _ = try pushAssistant(arena, &t, at_ms, .{ .text = msg_text });
            }
        } else if (std.mem.eql(u8, kind, "function_call") or std.mem.eql(u8, kind, "custom_tool_call")) {
            const name = str(p, "name") orelse "tool";
            const args = (if (std.mem.eql(u8, kind, "function_call")) str(p, "arguments") else str(p, "input")) orelse "";
            const call = try codexCall(arena, name, args);
            const pos = try pushAssistant(arena, &t, at_ms, .{ .tool = .{ .call_json = try call.toJson(arena) } });
            if (str(p, "call_id")) |cid| try calls.put(arena, cid, pos);
        } else if (std.mem.eql(u8, kind, "function_call_output") or std.mem.eql(u8, kind, "custom_tool_call_output")) {
            const tool = toolAt(&t, &calls, str(p, "call_id")) orelse continue;
            const out = try codexOutput(arena, field(p, "output"));
            tool.output = try summarizeToolOutput(arena, out[0]);
            tool.is_error = out[1];
        }
    }
    return t;
}

// ── graff (graff.rs) ───────────────────────────────────────────────────────

/// `graff::load`: graff's transcript has no timestamps, so entries are
/// stamped just after the file's last write, one millisecond apart.
fn loadGraff(arena: Allocator, io: std.Io, path: []const u8, updated_at: i64) !Transcript {
    var t: Transcript = .{};
    const lines = try Lines.open(arena, io, path);
    defer lines.close(arena);
    var jl: JsonLines = .{ .lines = lines, .arena = arena };
    var calls: CallIndex = .empty;
    var tick: i64 = 0;
    while (jl.next()) |line| {
        const kind = str(line, "type") orelse "";
        const role = str(line, "role") orelse "";
        if (std.mem.eql(u8, kind, "function_call")) {
            const name = str(line, "name") orelse "tool";
            const args: json.Value = if (str(line, "arguments")) |a|
                json.parseFromSliceLeaky(json.Value, arena, a, .{ .allocate = .alloc_always }) catch .null
            else
                .null;
            var call: Call = .{ .unknown = name };
            for ([_][]const u8{ "shell", "bash", "run_command", "exec" }) |n| {
                if (std.mem.eql(u8, name, n)) call = .{ .exec = str(args, "command") orelse str(args, "cmd") orelse "" };
            }
            const items = t.msgs.items;
            const at = if (items.len == 0 or items[items.len - 1].role != .assistant) blk: {
                tick += 1;
                break :blk updated_at + tick;
            } else 0;
            const pos = try pushAssistant(arena, &t, at, .{ .tool = .{ .call_json = try call.toJson(arena) } });
            if (str(line, "call_id")) |cid| try calls.put(arena, cid, pos);
        } else if (std.mem.eql(u8, kind, "function_call_output")) {
            const tool = toolAt(&t, &calls, str(line, "call_id")) orelse continue;
            const out = field(line, "output");
            const text = if (out == .string) out.string else try jsonText(arena, out);
            tool.output = try summarizeToolOutput(arena, text);
        } else if (std.mem.eql(u8, role, "user")) {
            // `text_of`: a string, or every block's `text`.
            const text = (try blocksText(arena, field(line, "content"), false, false)) orelse "";
            if (!history.isScaffolding(text)) {
                tick += 1;
                try pushUser(arena, &t, updated_at + tick, text);
            }
        } else if (std.mem.eql(u8, role, "assistant")) {
            const text = (try blocksText(arena, field(line, "content"), false, false)) orelse "";
            if (isBlank(text)) continue;
            const items = t.msgs.items;
            if (items.len > 0 and items[items.len - 1].role == .assistant) {
                try t.msgs.items[items.len - 1].blocks.append(arena, .{ .text = text });
            } else {
                tick += 1;
                var msg: Msg = .{ .role = .assistant, .at_ms = updated_at + tick };
                try msg.blocks.append(arena, .{ .text = text });
                try t.msgs.append(arena, msg);
            }
        }
    }
    return t;
}

/// `load`: one session's conversation.
pub fn load(arena: Allocator, io: std.Io, s: history.Session, err_out: *LoadError) !Transcript {
    return switch (s.source) {
        .claude => loadClaude(arena, io, s.path) catch |e| {
            err_out.message = ioMessage(e);
            return error.LoadFailed;
        },
        .codex => loadCodex(arena, io, s.path, err_out) catch |e| {
            if (e != error.LoadFailed) err_out.message = ioMessage(e);
            return error.LoadFailed;
        },
        .graff => loadGraff(arena, io, s.path, s.updated_at) catch |e| {
            err_out.message = ioMessage(e);
            return error.LoadFailed;
        },
    };
}

// ── import ─────────────────────────────────────────────────────────────────

fn label(s: history.Source) []const u8 {
    return switch (s) {
        .claude => "Claude Code",
        .codex => "Codex",
        .graff => "graff",
    };
}

/// `entries_for` + `SessionDoc::push_message`: one entry per message
/// (`{chat}-{n}`), one part per block (`{chat}-{n}-{i}`); replies complete,
/// tool rows resolved.
pub fn buildDoc(gpa: Allocator, arena: Allocator, chat_id: []const u8, device_id: []const u8, t: Transcript) !session_doc.SessionDoc {
    var doc = try session_doc.SessionDoc.init(gpa, chat_id, device_id);
    errdefer doc.deinit();
    for (t.msgs.items, 0..) |m, n| {
        const msg_id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ chat_id, n });
        switch (m.role) {
            .user => {
                const part_id = try std.fmt.allocPrint(arena, "{s}-0", .{msg_id});
                try doc.appendUserMessage(msg_id, part_id, m.blocks.items[0].text, m.at_ms);
            },
            .assistant => {
                try doc.beginAssistantMessage(msg_id, m.at_ms);
                for (m.blocks.items, 0..) |b, i| {
                    const part_id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ msg_id, i });
                    switch (b) {
                        .text => |text| _ = try doc.appendPartDelta(msg_id, part_id, "text", text),
                        .tool => |tool| try doc.upsertToolPart(msg_id, part_id, tool.call_json, tool.output, true, tool.is_error),
                    }
                }
                try doc.setMessageStatus(msg_id, "complete");
            },
        }
    }
    return doc;
}

/// `chat_row`'s preview: the last non-blank reply text, one line, 160 characters.
fn lastReply(arena: Allocator, t: Transcript) !?[]const u8 {
    var mi = t.msgs.items.len;
    while (mi > 0) {
        mi -= 1;
        const m = t.msgs.items[mi];
        if (m.role != .assistant) continue;
        var bi = m.blocks.items.len;
        while (bi > 0) {
            bi -= 1;
            switch (m.blocks.items[bi]) {
                .text => |text| if (!isBlank(text)) return try history.oneLine(arena, text, preview_chars),
                .tool => {},
            }
        }
    }
    return null;
}

fn optDupe(gpa: Allocator, s: ?[]const u8) !?[]u8 {
    return if (s) |v| try gpa.dupe(u8, v) else null;
}

/// `import_one`: the doc first, then the row (once it shows the chat is
/// clickable, and its doc is already in place).
pub fn importOne(host: *engine_host.EngineHost, io: std.Io, s: history.Session, err_out: *LoadError, arena: Allocator) ![]const u8 {
    const gpa = host.gpa;
    const chat_id = try std.fmt.allocPrint(arena, "ext-{s}-{s}", .{ s.source.slug(), s.id });
    const t = try load(arena, io, s, err_out);
    if (t.msgs.items.len == 0) {
        err_out.message = "no conversation in the file";
        return error.LoadFailed;
    }
    var doc = try buildDoc(gpa, arena, chat_id, host.device_id, t);
    defer doc.deinit();
    const bytes = try doc.exportSnapshot(gpa);
    defer gpa.free(bytes);
    const now = host.nowMs();
    host.store.saveSnapshotWithCursor(chat_id, bytes, 0, chat2_doc_epoch, now) catch |e| {
        err_out.message = try std.fmt.allocPrint(arena, "store: {s}", .{@errorName(e)});
        return error.LoadFailed;
    };
    if (host.docs.getPtr(chat_id)) |open_doc| open_doc.importSnapshot(bytes) catch {};

    const last_at = t.msgs.items[t.msgs.items.len - 1].at_ms;
    const id_c = try gpa.dupe(u8, chat_id);
    var rec: engine_host.ChatRecord = .{
        .id = id_c,
        .space_id = null,
        .device_id = &.{},
        .harness = &.{},
    };
    errdefer rec.deinit(gpa);
    rec.device_id = try gpa.dupe(u8, host.device_id);
    // Imported conversations continue in graff; a graff import resumes its
    // own recorded session.
    rec.harness = try gpa.dupe(u8, "graff");
    rec.title = try gpa.dupe(u8, s.title);
    rec.cwd = try optDupe(gpa, s.cwd);
    rec.preview = try optDupe(gpa, try lastReply(arena, t));
    rec.harness_session_id = if (s.source == .graff) try gpa.dupe(u8, s.id) else null;
    rec.sandbox = chat_sandbox.Sandbox.workspace_write;
    rec.created_at_ms = s.started_at;
    rec.last_message_at_ms = last_at;
    rec.last_seen_at_ms = last_at;
    try host.chats.append(gpa, rec);
    host.enqueueChatUpsertOp(rec);
    host.markChatTailDirty(chat_id);
    return chat_id;
}

const Key = struct { source: history.Source, id: []const u8 };

/// `ExternalHistoryImport { sessions?: [{source, id}], cwd? }` →
/// `{imported, skipped, errors, chatIds}`.
pub fn externalHistoryImport(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const o = common.obj(params);
    const cwd: ?[]const u8 = if (o) |m| common.str(m, "cwd") else null;

    var keys: ?[]const Key = null;
    if (o) |m| if (m.get("sessions")) |sv| if (sv != .null) {
        if (sv != .array) return common.failed("bad sessions: invalid type: expected a sequence", .{});
        var list: std.ArrayList(Key) = .empty;
        for (sv.array.items) |k| {
            if (k != .object) return common.failed("bad sessions: invalid type: expected struct Key", .{});
            const src_v = k.object.get("source") orelse return common.failed("bad sessions: missing field `source`", .{});
            if (src_v != .string) return common.failed("bad sessions: invalid type: expected a string for `source`", .{});
            const src = std.meta.stringToEnum(history.Source, src_v.string) orelse
                return common.failed("bad sessions: unknown variant `{s}`, expected one of `claude`, `codex`, `graff`", .{src_v.string});
            const id_v = k.object.get("id") orelse return common.failed("bad sessions: missing field `id`", .{});
            if (id_v != .string) return common.failed("bad sessions: invalid type: expected a string for `id`", .{});
            try list.append(arena, .{ .source = src, .id = id_v.string });
        }
        keys = list.items;
    };
    const io = host.io orelse return common.failed("conversation import unavailable", .{});

    // The roots `ExternalHistoryList` uses.
    const home = common.homeDir() orelse "/";
    const claude_dir = if (common.getenvNonEmpty("CLAUDE_CONFIG_DIR")) |d| d else try std.fs.path.join(arena, &.{ home, ".claude" });
    const codex_home = if (common.getenvNonEmpty("CODEX_HOME")) |d| d else try std.fs.path.join(arena, &.{ home, ".codex" });
    var projects: std.ArrayList([]const u8) = .empty;
    if (cwd) |c| if (c.len > 0) try projects.append(arena, c);
    for (host.chats.items) |chat| {
        const c = chat.cwd orelse continue;
        if (c.len == 0) continue;
        for (projects.items) |p| {
            if (std.mem.eql(u8, p, c)) break;
        } else try projects.append(arena, try arena.dupe(u8, c));
    }

    // `known`, read once before any import (as Rust does).
    var known_chats: std.StringHashMapUnmanaged(void) = .empty;
    var known_native: std.StringHashMapUnmanaged(void) = .empty;
    for (host.chats.items) |chat| {
        try known_chats.put(arena, try arena.dupe(u8, chat.id), {});
        if (chat.harness_session_id) |n| try known_native.put(arena, try arena.dupe(u8, n), {});
    }

    var found = try history.discover(gpa, io, .{ .claude_dir = claude_dir, .codex_home = codex_home }, projects.items, cwd);
    defer {
        for (found.items) |*s| s.deinit(gpa);
        found.deinit(gpa);
    }

    var imported: usize = 0;
    var skipped: usize = 0;
    var errors: std.ArrayList([]const u8) = .empty;
    var chat_ids: std.ArrayList([]const u8) = .empty;
    for (found.items) |s| {
        if (keys) |ks| {
            for (ks) |k| {
                if (k.source == s.source and std.mem.eql(u8, k.id, s.id)) break;
            } else continue;
        }
        const ext_id = try std.fmt.allocPrint(arena, "ext-{s}-{s}", .{ s.source.slug(), s.id });
        if (known_chats.contains(ext_id) or known_native.contains(s.id)) {
            skipped += 1;
            continue;
        }
        var err: LoadError = .{ .message = "" };
        if (importOne(host, io, s, &err, arena)) |chat_id| {
            imported += 1;
            try chat_ids.append(arena, chat_id);
        } else |e| {
            const msg = if (e == error.LoadFailed) err.message else @errorName(e);
            try errors.append(arena, try std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ label(s.source), s.id, msg }));
        }
    }

    if (imported > 0) {
        host.saveRegistryCacheFile();
        host.wakeBgSync();
        const ch_json = try host.chatsJson();
        defer gpa.free(ch_json);
        try host.broadcastWatch(.chats, null, ch_json);
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"imported\":{d},\"skipped\":{d},\"errors\":[", .{ imported, skipped });
    for (errors.items, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{f}", .{json.fmt(e, .{})});
    }
    try w.writeAll("],\"chatIds\":[");
    for (chat_ids.items, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{f}", .{json.fmt(c, .{})});
    }
    try w.writeAll("]}");
    return .{ .unary_json = try aw.toOwnedSlice() };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    env: common.TestEnv,
    host: engine_host.EngineHost,

    fn init() !*Fx {
        const gpa = testing.allocator;
        const f = try gpa.create(Fx);
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, testing.io, &f.tmp);
        f.env = try common.TestEnv.init(gpa, f.base);
        f.env.install();
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = testing.io;
        return f;
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        f.host.deinit();
        f.env.deinit();
        gpa.free(f.base);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    fn write(f: *Fx, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn import(f: *Fx, params_text: []const u8) !json.Parsed(json.Value) {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        const out = try f.host.handle("ExternalHistoryImport", p.value);
        switch (out) {
            .unary_json => |body| {
                defer testing.allocator.free(body);
                return json.parseFromSlice(json.Value, testing.allocator, body, .{});
            },
            .err => |e| {
                std.debug.print("unexpected error: {any}\n", .{e});
                return error.UnexpectedError;
            },
            else => return error.UnexpectedOutcome,
        }
    }

    fn chat(f: *Fx, id: []const u8) ?*engine_host.ChatRecord {
        for (f.host.chats.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    /// The imported doc as the engine stored it.
    fn doc(f: *Fx, id: []const u8) !session_doc.SessionDoc {
        const bytes = f.host.store.loadSnapshot(id) orelse return error.NoSnapshot;
        var d = try session_doc.SessionDoc.init(testing.allocator, id, "reader");
        errdefer d.deinit();
        try d.importSnapshot(bytes);
        return d;
    }
};

fn num(v: json.Value, key: []const u8) i64 {
    return v.object.get(key).?.integer;
}

test "rpcw_history_import summarizeToolOutput keeps short output, cuts long output, drops fences" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ok\nok", (try summarizeToolOutput(a, "```\nok\nok\n```\n")).?);
    try testing.expect((try summarizeToolOutput(a, "  \n```txt\n```\n")) == null);
    var long: [400]u8 = @splat('x');
    long[3] = '\n';
    const cut = (try summarizeToolOutput(a, &long)).?;
    try testing.expectEqualStrings("xxx…", cut);
    var wide: std.ArrayList(u8) = .empty;
    for (0..200) |_| try wide.appendSlice(a, "é");
    const w = (try summarizeToolOutput(a, wide.items)).?;
    try testing.expectEqual(@as(usize, 161), try std.unicode.utf8CountCodepoints(w));
    try testing.expect(std.mem.endsWith(u8, w, "é…"));
}

test "rpcw_history_import a Claude Code session becomes a graff chat with its conversation, once" {
    const f = try Fx.init();
    defer f.deinit();
    try f.write(".claude/projects/-w-app/s1.jsonl",
        \\{"type":"user","cwd":"/w/app","sessionId":"s1","timestamp":"2026-09-01T10:00:01Z","message":{"role":"user","content":"fix the login bug"}}
        \\{"type":"assistant","timestamp":"2026-09-01T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"make test","description":"dropped"}}]}}
        \\{"type":"user","isMeta":true,"timestamp":"2026-09-01T10:00:02Z","message":{"content":"meta line"}}
        \\{"type":"user","timestamp":"2026-09-01T10:00:03Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","is_error":true,"content":[{"type":"text","text":"```\n1 failed\n```"}]}]}}
        \\{"type":"assistant","timestamp":"2026-09-01T10:00:04Z","message":{"content":[{"type":"tool_use","id":"tu2","name":"mcp__docs__search","input":{}},{"type":"text","text":"Fixed it."}]}}
        \\{"type":"assistant","isSidechain":true,"timestamp":"2026-09-01T10:00:05Z","message":{"content":"sidechain reply"}}
        \\
    );
    var out = try f.import("{}");
    defer out.deinit();
    try testing.expectEqual(@as(i64, 1), num(out.value, "imported"));
    try testing.expectEqual(@as(i64, 0), num(out.value, "skipped"));
    try testing.expectEqual(@as(usize, 0), out.value.object.get("errors").?.array.items.len);
    try testing.expectEqualStrings("ext-claude-s1", out.value.object.get("chatIds").?.array.items[0].string);

    const c = f.chat("ext-claude-s1").?;
    try testing.expectEqualStrings("fix the login bug", c.title.?);
    try testing.expectEqualStrings("/w/app", c.cwd.?);
    try testing.expectEqualStrings("Fixed it.", c.preview.?);
    try testing.expectEqualStrings("graff", c.harness);
    try testing.expectEqualStrings("dev-synthetic", c.device_id);
    try testing.expect(c.harness_session_id == null);
    try testing.expectEqual(chat_sandbox.Sandbox.workspace_write, c.sandbox.?);
    // The reply merges two lines and keeps the first one's time.
    try testing.expectEqual(@as(i64, 1788256802000), c.last_message_at_ms);
    try testing.expectEqual(@as(?u32, 2), f.host.store.snapshotEpoch("ext-claude-s1"));

    var d = try f.doc("ext-claude-s1");
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.messages.items.len);
    const user = d.messages.items[0];
    try testing.expectEqualStrings("ext-claude-s1-0", user.id);
    try testing.expectEqualStrings("user", user.role);
    try testing.expectEqual(@as(i64, 1788256801000), user.created_at);
    try testing.expectEqualStrings("fix the login bug", user.parts.items[0].text.items);
    const reply = d.messages.items[1];
    try testing.expectEqualStrings("assistant", reply.role);
    try testing.expectEqualStrings("complete", reply.status.?);
    try testing.expectEqual(@as(usize, 4), reply.parts.items.len);
    try testing.expectEqualStrings("ext-claude-s1-1-1", reply.parts.items[1].id);
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"make test\"}", reply.parts.items[1].call_json.?);
    try testing.expectEqualStrings("1 failed", reply.parts.items[1].output.?);
    try testing.expect(reply.parts.items[1].is_error and reply.parts.items[1].resolved);
    try testing.expectEqualStrings("{\"kind\":\"mcp\",\"server\":\"docs\",\"tool\":\"search\"}", reply.parts.items[2].call_json.?);
    try testing.expect(reply.parts.items[2].output == null);
    try testing.expectEqualStrings("Fixed it.", reply.parts.items[3].text.items);

    // The edge gets the chat row; a second import skips it.
    var pushed = false;
    for (f.host.pending_registry_ops.items) |op| {
        if (std.mem.indexOf(u8, op, "\"ext-claude-s1\"") != null and std.mem.indexOf(u8, op, "\"kind\":\"chats\"") != null) pushed = true;
    }
    try testing.expect(pushed);
    var again = try f.import("{}");
    defer again.deinit();
    try testing.expectEqual(@as(i64, 0), num(again.value, "imported"));
    try testing.expectEqual(@as(i64, 1), num(again.value, "skipped"));
    try testing.expectEqual(@as(usize, 1), f.host.chats.items.len);
}

test "rpcw_history_import Codex rollouts: argv scripts, exit codes, a truncated tail, and a broken record" {
    const f = try Fx.init();
    defer f.deinit();
    try f.write(".codex/sessions/2026/11/01/rollout-ok.jsonl",
        \\{"type":"session_meta","payload":{"id":"cx-ok","cwd":"/w/cx"}}
        \\{"type":"response_item","timestamp":"2026-11-01T08:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context/>"}]}}
        \\{"type":"response_item","timestamp":"2026-11-01T08:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"run the tests"}]}}
        \\{"type":"response_item","timestamp":"2026-11-01T08:00:02Z","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"make test\"]}","call_id":"c1"}}
        \\{"type":"response_item","timestamp":"2026-11-01T08:00:03Z","payload":{"type":"function_call_output","call_id":"c1","output":"{\"output\":\"2 failed\",\"metadata\":{\"exit_code\":1}}"}}
        \\{"type":"response_item","timestamp":"2026-11-01T08:00:04Z","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch","call_id":"c2"}}
        \\{"type":"response_item","timestamp":"2026-11-01T08:00:05Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Two tests fail."}]}}
        \\{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_te
    );
    try f.write(".codex/sessions/2026/11/02/rollout-bad.jsonl",
        \\{"type":"session_meta","payload":{"id":"cx-bad","cwd":"/w/cx"}}
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":"hello there"}}
        \\{not json at all}
        \\{"type":"response_item","payload":{"type":"message","role":"assistant","content":"hi"}}
        \\
    );
    var out = try f.import("{}");
    defer out.deinit();
    try testing.expectEqual(@as(i64, 1), num(out.value, "imported"));
    const errs = out.value.object.get("errors").?.array.items;
    try testing.expectEqual(@as(usize, 1), errs.len);
    try testing.expectEqualStrings("Codex cx-bad: Codex history contains an invalid JSON record at line 3", errs[0].string);
    try testing.expect(f.chat("ext-codex-cx-bad") == null);

    const c = f.chat("ext-codex-cx-ok").?;
    try testing.expectEqualStrings("run the tests", c.title.?);
    try testing.expectEqualStrings("Two tests fail.", c.preview.?);
    var d = try f.doc("ext-codex-cx-ok");
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.messages.items.len);
    const parts = d.messages.items[1].parts.items;
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"make test\"}", parts[0].call_json.?);
    try testing.expectEqualStrings("2 failed", parts[0].output.?);
    try testing.expect(parts[0].is_error);
    try testing.expectEqualStrings("{\"kind\":\"applyPatch\"}", parts[1].call_json.?);
    try testing.expectEqualStrings("Two tests fail.", parts[2].text.items);
}

test "rpcw_history_import graff sessions keep their own resume id and are stamped after the last write" {
    const f = try Fx.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const project = try std.fs.path.join(gpa, &.{ f.base, "proj" });
    defer gpa.free(project);
    try f.write("proj/.graff/sessions/g-1.transcript.jsonl",
        \\{"role":"system","content":"You are graff"}
        \\{"role":"user","content":"write the notes"}
        \\{"type":"function_call","name":"bash","arguments":"{\"cmd\":\"ls\"}","call_id":"k1"}
        \\{"type":"function_call_output","call_id":"k1","output":{"files":2}}
        \\{"role":"assistant","content":[{"type":"text","text":"Done."}]}
        \\
    );
    const params = try std.fmt.allocPrint(gpa, "{{\"cwd\":{f},\"sessions\":[{{\"source\":\"graff\",\"id\":\"g-1\"}}]}}", .{json.fmt(project, .{})});
    defer gpa.free(params);
    var out = try f.import(params);
    defer out.deinit();
    try testing.expectEqual(@as(i64, 1), num(out.value, "imported"));
    const c = f.chat("ext-graff-g-1").?;
    try testing.expectEqualStrings("g-1", c.harness_session_id.?);
    try testing.expectEqualStrings(project, c.cwd.?);
    var d = try f.doc("ext-graff-g-1");
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.messages.items.len);
    const t0 = d.messages.items[0].created_at;
    try testing.expectEqual(t0 + 1, d.messages.items[1].created_at);
    try testing.expectEqual(t0 + 1, c.last_message_at_ms);
    const parts = d.messages.items[1].parts.items;
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"ls\"}", parts[0].call_json.?);
    try testing.expectEqualStrings("{\"files\":2}", parts[0].output.?);
    try testing.expectEqualStrings("Done.", parts[1].text.items);
}

test "rpcw_history_import takes only the named sessions and skips what Harness started" {
    const f = try Fx.init();
    defer f.deinit();
    const gpa = testing.allocator;
    try f.write(".claude/projects/-x/a.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"first one\"}}\n{\"type\":\"assistant\",\"message\":{\"content\":\"ok\"}}\n");
    try f.write(".claude/projects/-x/started.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"started here\"}}\n");
    try f.host.chats.append(gpa, .{ .id = try gpa.dupe(u8, "chat-1"), .space_id = null, .device_id = try gpa.dupe(u8, "dev-synthetic"), .harness = try gpa.dupe(u8, "claude-code"), .harness_session_id = try gpa.dupe(u8, "started") });

    var none = try f.import("{\"sessions\":[{\"source\":\"codex\",\"id\":\"a\"}]}");
    defer none.deinit();
    try testing.expectEqual(@as(i64, 0), num(none.value, "imported"));
    try testing.expectEqual(@as(i64, 0), num(none.value, "skipped"));

    var all = try f.import("{\"sessions\":null}");
    defer all.deinit();
    try testing.expectEqual(@as(i64, 1), num(all.value, "imported"));
    try testing.expectEqual(@as(i64, 1), num(all.value, "skipped"));
    try testing.expectEqualStrings("ext-claude-a", all.value.object.get("chatIds").?.array.items[0].string);
}

test "rpcw_history_import refuses malformed session keys and an engine without I/O" {
    const f = try Fx.init();
    defer f.deinit();
    var p = try json.parseFromSlice(json.Value, testing.allocator, "{\"sessions\":[{\"source\":\"cursor\",\"id\":\"x\"}]}", .{});
    defer p.deinit();
    const bad = try f.host.handle("ExternalHistoryImport", p.value);
    try testing.expectEqualStrings("bad sessions: unknown variant `cursor`, expected one of `claude`, `codex`, `graff`", bad.err.exec_error);
    var q = try json.parseFromSlice(json.Value, testing.allocator, "{\"sessions\":[{\"source\":\"codex\"}]}", .{});
    defer q.deinit();
    const missing = try f.host.handle("ExternalHistoryImport", q.value);
    try testing.expectEqualStrings("bad sessions: missing field `id`", missing.err.exec_error);
    f.host.io = null;
    const no_io = try f.host.handle("ExternalHistoryImport", .{ .object = .empty });
    try testing.expectEqualStrings("conversation import unavailable", no_io.err.exec_error);
}
