//! One agent turn, adapter-neutral (`crates/harness/src/lib.rs` `Harness::run`
//! + `RunControls`, `crates/proto/src/agent.rs` `AgentEvent`/`ToolCall`).
//!
//! A `Turn` runs on its own thread. The adapter drives the agent process and
//! reports `Event`s through the `Sink` (the engine folds them into the chat's
//! document). RPC threads reach a live turn to answer its questions, steer it
//! or interrupt it; those calls only write to the agent's stdin or signal it.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const agent_proc = @import("agent_proc.zig");
const AgentProc = agent_proc.AgentProc;

/// `SandboxLevel`.
pub const Sandbox = enum {
    read_only,
    workspace_write,
    danger_full_access,

    pub fn wire(self: Sandbox) []const u8 {
        return switch (self) {
            .read_only => "read-only",
            .workspace_write => "workspace-write",
            .danger_full_access => "danger-full-access",
        };
    }
};

/// `Autonomy::apply`: read-only and workspace force `auto_approve = false`;
/// full-access keeps the request's own value.
pub fn applyAutonomy(autonomy: []const u8, request_auto_approve: bool) struct { sandbox: Sandbox, auto_approve: bool } {
    if (std.mem.eql(u8, autonomy, "read-only")) return .{ .sandbox = .read_only, .auto_approve = false };
    if (std.mem.eql(u8, autonomy, "workspace")) return .{ .sandbox = .workspace_write, .auto_approve = false };
    return .{ .sandbox = .danger_full_access, .auto_approve = request_auto_approve };
}

/// What the run asks for (`RunRequest`), all borrowed from the turn's arena.
pub const Request = struct {
    chat_id: []const u8,
    harness: []const u8,
    prompt: []const u8,
    cwd: []const u8,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    /// `modelOptions` (option id → choice) as JSON.
    model_options_json: ?[]const u8 = null,
    sandbox: Sandbox = .danger_full_access,
    auto_approve: bool = false,
    /// Harness-native session id to resume.
    resume_id: ?[]const u8 = null,
    /// The engine's environment (child envs derive from it).
    env: *const Environ.Map,
    /// An executable the host already knows (graff's managed copy).
    exe_hint: ?[]const u8 = null,
    /// Graff settings carried from the host.
    graff_draft_subagents: bool = false,
    graff_compact_pct: i64 = 0,
    device_name: ?[]const u8 = null,
};

pub const DoneStatus = enum { completed, interrupted, errored };

/// The subset of `AgentEvent` the document folds.
pub const Event = union(enum) {
    session_started: []const u8,
    text: []const u8,
    reasoning: []const u8,
    /// `call` is `ToolCall` JSON, already sanitized for the doc.
    tool_call: struct { id: []const u8, call: []const u8 },
    tool_result: struct { id: []const u8, is_error: bool },
    /// `AssistantMessageCompleted`: the next text starts a new part.
    message_completed,
    input_requested: struct { request_id: []const u8, questions: []const u8 },
    input_resolved: []const u8,
    err: []const u8,
    done: struct { status: DoneStatus, err: ?[]const u8 = null, session_id: ?[]const u8 = null },
};

pub const Sink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, t: *Turn, ev: Event) void,
};

/// `UserInputAnswer`.
pub const Answer = struct {
    questionId: []const u8,
    labels: []const []const u8,
};

/// `UserInputQuestion`.
pub const Question = struct {
    id: []const u8,
    header: []const u8,
    question: []const u8,
    options: []const []const u8 = &.{},
    multiSelect: bool = false,
    prefill: ?[]const u8 = null,
    multiline: bool = false,
};

/// An open question the agent is waiting on.
pub const Pending = struct {
    request_id: []u8,
    /// Adapter-defined tag.
    kind: u8,
    /// Adapter-defined payload (e.g. the agent's own request id).
    data: []u8,
    /// The questions as sent (`[Question]` JSON).
    questions: []u8,

    fn deinit(self: Pending, gpa: Allocator) void {
        gpa.free(self.request_id);
        gpa.free(self.data);
        gpa.free(self.questions);
    }
};

pub const Adapter = struct {
    /// Display name used in crash messages ("claude", "codex app-server", …).
    name: []const u8,
    /// Run the turn to its end on the turn's thread. Emit `.done` once; the
    /// runner reports an error or a missing Done itself.
    run: *const fn (t: *Turn) anyerror!void,
    /// Ask the agent to stop (from an RPC thread). The runner escalates to
    /// signals if the agent keeps going.
    interrupt: *const fn (t: *Turn) void,
    /// Deliver a steer mid-turn; false = the adapter can't now.
    steer: ?*const fn (t: *Turn, text: []const u8) bool = null,
    /// Reply to a pending question; `answers == null` dismisses it.
    answer: *const fn (t: *Turn, p: *const Pending, answers: ?[]const Answer) void,
    /// `steering_mode == StepBoundary` (steers delivered mid-turn).
    steers_mid_turn: bool = false,
};

/// Turn threads that haven't fully exited (shutdown and tests wait on it).
pub var active_threads: std.atomic.Value(usize) = .init(0);

/// Wait up to `ms` for every turn thread to exit; true when none remain.
pub fn waitAllExited(io: Io, ms: u32) bool {
    var waited: u32 = 0;
    while (active_threads.load(.acquire) != 0) : (waited += 10) {
        if (waited >= ms) return false;
        Io.sleep(io, .fromMilliseconds(10), .awake) catch return false;
    }
    return true;
}

/// Whether `resolveExe` may search the disk (PATH, the login shell, the
/// install dirs). Off in test builds, so a test can never start an agent CLI
/// installed on the machine running it: tests name their mock through the
/// adapter's override variable.
pub var allow_exe_search: bool = !@import("builtin").is_test;

pub const interrupt_grace_ms: u32 = 2000;

/// Longest a resume waits for the previous process on its session: the
/// interrupt and kill graces plus slack (`live_sessions::WAIT`).
pub const session_wait_ms: u32 = 10_000;

/// Native sessions whose agent process is still alive
/// (`claude/live_sessions.rs`): two processes on one session drop the new
/// prompt, so a resume waits for the old one to be reaped.
const SessionHold = struct { id: []u8, owner: *const Turn };
var sessions_mu: Io.Mutex = .init;
var live_sessions: std.ArrayList(SessionHold) = .empty;
const sessions_gpa = std.heap.smp_allocator;

fn sessionOpen(io: Io, id: []const u8) bool {
    sessions_mu.lockUncancelable(io);
    defer sessions_mu.unlock(io);
    for (live_sessions.items) |h| if (std.mem.eql(u8, h.id, id)) return true;
    return false;
}
pub const kill_grace_ms: u32 = 3000;

pub const Turn = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    req: Request,
    adapter: *const Adapter,
    sink: Sink,
    /// The assistant entry events fold into (the host may rotate it on a steer).
    asst_id: []u8,
    /// Guards `proc`, `pending`, `asst_id` swaps and adapter shared state.
    mu: Io.Mutex = .init,
    proc: ?*AgentProc = null,
    pending: std.ArrayList(Pending) = .empty,
    input_seq: u32 = 0,
    interrupted: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    /// Set under `emit_mu` with the Done.
    done_emitted: bool = false,
    /// Serializes `emit`, so an event from another thread can't reach the
    /// host after (or while) Done frees its side.
    emit_mu: Io.Mutex = .init,
    /// A detailed failure message an adapter sets before returning an error.
    fail_msg: ?[]u8 = null,
    /// Adapter state (owned by the adapter's `run`, read by its callbacks under `mu`).
    state: ?*anyopaque = null,
    refs: std.atomic.Value(u32) = .init(1),

    pub fn create(gpa: Allocator, io: Io, adapter: *const Adapter, sink: Sink, asst_id: []const u8) !*Turn {
        const t = try gpa.create(Turn);
        errdefer gpa.destroy(t);
        t.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .req = undefined,
            .adapter = adapter,
            .sink = sink,
            .asst_id = try gpa.dupe(u8, asst_id),
        };
        return t;
    }

    pub fn retain(self: *Turn) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    pub fn release(self: *Turn) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.pending.items) |p| p.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        if (self.fail_msg) |m| self.gpa.free(m);
        self.gpa.free(self.asst_id);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Start the turn's (detached) thread.
    pub fn start(self: *Turn) !void {
        self.retain();
        errdefer self.release();
        _ = active_threads.fetchAdd(1, .acq_rel);
        errdefer _ = active_threads.fetchSub(1, .acq_rel);
        const th = try std.Thread.spawn(.{}, runThread, .{self});
        th.detach();
    }

    fn runThread(self: *Turn) void {
        self.runToEnd();
        self.release();
        _ = active_threads.fetchSub(1, .acq_rel);
    }

    fn runToEnd(self: *Turn) void {
        self.adapter.run(self) catch |err| {
            if (!self.done_emitted) {
                const msg = self.fail_msg orelse (std.fmt.allocPrint(self.gpa, "harness protocol error: {t}", .{err}) catch null);
                if (self.fail_msg == null) self.fail_msg = msg;
                const status: DoneStatus = if (self.interrupted.load(.acquire)) .interrupted else .errored;
                self.emit(.{ .done = .{ .status = status, .err = if (status == .errored) msg else null } });
            }
        };
        self.dismissAll();
        if (!self.done_emitted) {
            const status: DoneStatus = if (self.interrupted.load(.acquire)) .interrupted else .errored;
            self.emit(.{ .done = .{ .status = status, .err = if (status == .errored) "harness stream ended without Done" else null } });
        }
        self.mu.lockUncancelable(self.io);
        const proc = self.proc;
        self.mu.unlock(self.io);
        if (proc) |p| {
            // `shutdown_child`: EOF first, then TERM and KILL if it lingers.
            p.closeStdin();
            p.escalate(kill_grace_ms, kill_grace_ms * 2);
            _ = p.wait();
            self.mu.lockUncancelable(self.io);
            self.proc = null;
            self.mu.unlock(self.io);
            p.destroy();
        }
        // The child is reaped: its native session is free for the next run.
        self.releaseSessions();
        self.finished.store(true, .release);
    }

    /// Report `ev` to the host. Nothing is reported after Done: the host
    /// frees its side of the turn with it.
    pub fn emit(self: *Turn, ev: Event) void {
        self.emit_mu.lockUncancelable(self.io);
        defer self.emit_mu.unlock(self.io);
        if (self.done_emitted) return;
        if (ev == .done) self.done_emitted = true;
        self.sink.emitFn(self.sink.ctx, self, ev);
    }

    /// Record a failure message (owned copy) for the runner's Done.
    pub fn fail(self: *Turn, comptime fmt: []const u8, args: anytype) error{TurnFailed} {
        if (self.fail_msg) |m| self.gpa.free(m);
        self.fail_msg = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
        return error.TurnFailed;
    }

    pub fn setProc(self: *Turn, p: *AgentProc) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.proc = p;
    }

    /// Mark native session `id` as open in this turn's process until the
    /// process is reaped (`live_sessions::register`). A newer hold on the
    /// same id replaces an older one.
    pub fn holdSession(self: *Turn, id: []const u8) void {
        const copy = sessions_gpa.dupe(u8, id) catch return;
        sessions_mu.lockUncancelable(self.io);
        defer sessions_mu.unlock(self.io);
        var i: usize = 0;
        while (i < live_sessions.items.len) {
            if (std.mem.eql(u8, live_sessions.items[i].id, id)) {
                sessions_gpa.free(live_sessions.swapRemove(i).id);
            } else i += 1;
        }
        live_sessions.append(sessions_gpa, .{ .id = copy, .owner = self }) catch sessions_gpa.free(copy);
    }

    /// Drop this turn's holds (only its own: a newer run may hold the id now).
    fn releaseSessions(self: *Turn) void {
        sessions_mu.lockUncancelable(self.io);
        defer sessions_mu.unlock(self.io);
        var i: usize = 0;
        while (i < live_sessions.items.len) {
            if (live_sessions.items[i].owner == self) {
                sessions_gpa.free(live_sessions.swapRemove(i).id);
            } else i += 1;
        }
    }

    /// Wait until no process holds session `id`, at most `ms`, and no longer
    /// than this turn stays uninterrupted (`wait_until_closed`). True when
    /// the session was free in time.
    pub fn waitSessionClosed(self: *Turn, id: []const u8, ms: u32) bool {
        var waited: u32 = 0;
        while (true) : (waited += 20) {
            if (!sessionOpen(self.io, id)) return true;
            if (waited >= ms or self.interrupted.load(.acquire)) return false;
            Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return false;
        }
    }

    /// Write one line to the agent (any thread). False if it's gone.
    pub fn send(self: *Turn, line: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        const p = self.proc;
        self.mu.unlock(self.io);
        const proc = p orelse return false;
        proc.writeLine(line) catch return false;
        return true;
    }

    /// Open a question for the user; `kind`/`data` come back to `Adapter.answer`.
    pub fn ask(self: *Turn, kind: u8, data: []const u8, questions: []const Question) !void {
        const qjson = try json.Stringify.valueAlloc(self.gpa, questions, .{ .emit_null_optional_fields = false });
        errdefer self.gpa.free(qjson);
        const d = try self.gpa.dupe(u8, data);
        errdefer self.gpa.free(d);
        self.mu.lockUncancelable(self.io);
        self.input_seq += 1;
        var rnd: [6]u8 = undefined;
        self.io.random(&rnd);
        const rid = std.fmt.allocPrint(self.gpa, "in-{x}-{d}", .{ rnd, self.input_seq }) catch |e| {
            self.mu.unlock(self.io);
            return e;
        };
        self.pending.append(self.gpa, .{ .request_id = rid, .kind = kind, .data = d, .questions = qjson }) catch |e| {
            self.mu.unlock(self.io);
            self.gpa.free(rid);
            return e;
        };
        self.mu.unlock(self.io);
        self.emit(.{ .input_requested = .{ .request_id = rid, .questions = qjson } });
    }

    fn takePending(self: *Turn, request_id: ?[]const u8) ?Pending {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.pending.items, 0..) |p, i| {
            if (request_id == null or std.mem.eql(u8, p.request_id, request_id.?)) return self.pending.orderedRemove(i);
        }
        return null;
    }

    pub fn hasPending(self: *Turn, request_id: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.pending.items) |p| if (std.mem.eql(u8, p.request_id, request_id)) return true;
        return false;
    }

    /// Answer (or with null, dismiss) an open question. False if not pending.
    pub fn respond(self: *Turn, request_id: []const u8, answers: ?[]const Answer) bool {
        const p = self.takePending(request_id) orelse return false;
        defer p.deinit(self.gpa);
        self.adapter.answer(self, &p, answers);
        return true;
    }

    /// Dismiss every open question (turn end / interrupt).
    pub fn dismissAll(self: *Turn) void {
        while (self.takePending(null)) |p| {
            defer p.deinit(self.gpa);
            self.adapter.answer(self, &p, null);
        }
    }

    /// Interrupt: ask the adapter to stop, dismiss open questions, then
    /// SIGTERM the group after 2 s and SIGKILL it 3 s later.
    pub fn interrupt(self: *Turn) void {
        if (self.interrupted.swap(true, .acq_rel)) return;
        self.adapter.interrupt(self);
        self.dismissAll();
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.proc) |p| p.escalate(interrupt_grace_ms, interrupt_grace_ms + kill_grace_ms);
    }

    /// The child env every adapter starts from (`apply_run_environment`,
    /// `owned::configure`, `compose_child_path`). Caller owns.
    pub fn childEnv(self: *Turn, exe: []const u8) !Environ.Map {
        var env = try self.req.env.clone(self.gpa);
        errdefer env.deinit();
        for (agent_proc.stripped_env) |k| _ = env.orderedRemove(k);
        _ = env.orderedRemove("HARNESS_BUILD_WAIT_DIR");
        const login = if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(self.gpa, self.io, self.req.env);
        const path = try agent_proc.composeChildPath(self.gpa, exe, env.get("PATH"), login);
        defer self.gpa.free(path);
        try env.put("PATH", path);
        return env;
    }

    /// Resolve an agent CLI (`resolve_*_executable`): `override_var` (must
    /// exist), the host's hint, then the search. Errors carry Rust's texts.
    pub fn resolveExe(self: *Turn, name: []const u8, override_var: []const u8, extra: []const []const u8, hint: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        if (self.req.env.get(override_var)) |v| if (v.len > 0) {
            Io.Dir.cwd().access(self.io, v, .{}) catch return self.fail("harness binary not found: {s} does not exist", .{v});
            return a.dupe(u8, v);
        };
        if (self.req.exe_hint) |h| return a.dupe(u8, h);
        if (!allow_exe_search) return self.fail("harness binary not found: {s}", .{hint});
        const login = if (self.req.env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(self.gpa, self.io, self.req.env);
        const found = try agent_proc.findExecutable(self.gpa, self.io, .{
            .name = name,
            .path_env = self.req.env.get("PATH"),
            .login_path = login,
            .home = self.req.env.get("HOME"),
            .extra = extra,
            .fnm_dir = self.req.env.get("FNM_DIR"),
        });
        const f = found orelse return self.fail("harness binary not found: {s}", .{hint});
        defer self.gpa.free(f);
        return a.dupe(u8, f);
    }

    /// Spawn the agent and register it for interrupts; maps spawn errors to
    /// Rust's messages.
    pub fn spawn(self: *Turn, argv: []const []const u8, env: *const Environ.Map, opts: agent_proc.SpawnOpts) !*AgentProc {
        const p = AgentProc.spawn(self.gpa, self.io, argv, self.req.cwd, env, opts) catch |err| switch (err) {
            error.NotInstalled => return self.fail("harness binary not found: {s} (version unknown)", .{argv[0]}),
            error.MissingCwd => return self.fail("Project folder is missing: {s}", .{self.req.cwd}),
            else => return self.fail("io: {t}", .{err}),
        };
        self.setProc(p);
        if (self.interrupted.load(.acquire)) p.escalate(0, kill_grace_ms);
        return p;
    }

    /// `crash_message` for this turn's process.
    pub fn crash(self: *Turn, proc: *AgentProc) []const u8 {
        const term = proc.wait();
        const tail = proc.stderrTail(self.gpa);
        defer if (tail) |s| self.gpa.free(s);
        const msg = agent_proc.crashMessage(self.arena.allocator(), self.adapter.name, term, tail) catch return "agent exited unexpectedly";
        return msg;
    }
};

// ---------------------------------------------------------------------------
// JSON helpers shared by adapters
// ---------------------------------------------------------------------------

pub fn str(v: ?json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn get(v: json.Value, key: []const u8) ?json.Value {
    return if (v == .object) v.object.get(key) else null;
}

pub fn getStr(v: json.Value, key: []const u8) ?[]const u8 {
    return str(get(v, key));
}

pub fn getBool(v: json.Value, key: []const u8) ?bool {
    const x = get(v, key) orelse return null;
    return if (x == .bool) x.bool else null;
}

/// `ToolCall` JSON as the doc stores it (`sanitize_tool_call`: no file
/// contents, edit strings, fetch prompts or tool inputs, except a spawn's
/// model/subagent keys).
pub const Call = union(enum) {
    exec: []const u8,
    read_file: []const u8,
    write_file: []const u8,
    edit_file: []const u8,
    apply_patch: ?[]const u8,
    search: struct { pattern: []const u8, path: ?[]const u8 = null },
    glob: []const u8,
    web_fetch: []const u8,
    web_search: []const u8,
    todo: []const TodoItem,
    mcp: struct { server: []const u8, tool: []const u8 },
    unknown: struct { name: []const u8, input: ?json.Value = null },

    pub const TodoItem = struct { text: []const u8, done: bool };

    pub fn toJson(self: Call, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        switch (self) {
            .exec => |c| try w.print("{{\"kind\":\"exec\",\"command\":{f}}}", .{json.fmt(c, .{})}),
            .read_file => |p| try w.print("{{\"kind\":\"readFile\",\"path\":{f}}}", .{json.fmt(p, .{})}),
            .write_file => |p| try w.print("{{\"kind\":\"writeFile\",\"path\":{f}}}", .{json.fmt(p, .{})}),
            .edit_file => |p| try w.print("{{\"kind\":\"editFile\",\"path\":{f}}}", .{json.fmt(p, .{})}),
            .apply_patch => |p| if (p) |path|
                try w.print("{{\"kind\":\"applyPatch\",\"path\":{f}}}", .{json.fmt(path, .{})})
            else
                try w.writeAll("{\"kind\":\"applyPatch\"}"),
            .search => |s| if (s.path) |path|
                try w.print("{{\"kind\":\"search\",\"pattern\":{f},\"path\":{f}}}", .{ json.fmt(s.pattern, .{}), json.fmt(path, .{}) })
            else
                try w.print("{{\"kind\":\"search\",\"pattern\":{f}}}", .{json.fmt(s.pattern, .{})}),
            .glob => |p| try w.print("{{\"kind\":\"glob\",\"pattern\":{f}}}", .{json.fmt(p, .{})}),
            .web_fetch => |u| try w.print("{{\"kind\":\"webFetch\",\"url\":{f}}}", .{json.fmt(u, .{})}),
            .web_search => |q| try w.print("{{\"kind\":\"webSearch\",\"query\":{f}}}", .{json.fmt(q, .{})}),
            .todo => |items| {
                try w.writeAll("{\"kind\":\"todo\",\"items\":[");
                for (items, 0..) |it, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.print("{{\"text\":{f},\"done\":{}}}", .{ json.fmt(it.text, .{}), it.done });
                }
                try w.writeAll("]}");
            },
            .mcp => |m| try w.print("{{\"kind\":\"mcp\",\"server\":{f},\"tool\":{f}}}", .{ json.fmt(m.server, .{}), json.fmt(m.tool, .{}) }),
            .unknown => |u| {
                try w.print("{{\"kind\":\"unknown\",\"name\":{f}", .{json.fmt(u.name, .{})});
                if (std.mem.eql(u8, u.name, compaction_tool)) {
                    if (u.input) |in| try w.print(",\"input\":{f}", .{json.fmt(in, .{})});
                } else if (isSpawnName(u.name)) if (u.input) |in| if (in == .object) {
                    var kept = false;
                    for (subagent_input_keep) |k| if (in.object.get(k)) |v| {
                        try w.writeAll(if (kept) "," else ",\"input\":{");
                        kept = true;
                        try w.print("{f}:{f}", .{ json.fmt(k, .{}), json.fmt(v, .{}) });
                    };
                    if (kept) try w.writeByte('}');
                };
                try w.writeByte('}');
            },
        }
        return aw.toOwnedSlice();
    }
};

/// `COMPACTION_TOOL_NAME`: its chip keeps its token counts.
pub const compaction_tool = "Compact context";

const subagent_input_keep = [_][]const u8{ "model", "modelId", "model_id", "subagent_model", "subagent_type" };

fn isSpawnName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Agent") or std.mem.startsWith(u8, name, "Agent: ");
}

/// True when any answer label is "yes" (case-insensitive).
pub fn answeredYes(answers: ?[]const Answer) bool {
    const as = answers orelse return false;
    for (as) |a| for (a.labels) |l| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l, " "), "yes")) return true;
    return false;
}

/// The labels answered for `question_id` (empty when none).
pub fn labelsFor(answers: ?[]const Answer, question_id: []const u8) []const []const u8 {
    const as = answers orelse return &.{};
    for (as) |a| if (std.mem.eql(u8, a.questionId, question_id)) return a.labels;
    return &.{};
}

/// A Yes/No approval question.
pub fn yesNo(id: []const u8, header: []const u8, question: []const u8) [1]Question {
    return .{.{ .id = id, .header = header, .question = question, .options = &.{ "Yes", "No" } }};
}

/// Parse `[UserInputAnswer]` from the RespondInput command (`answers` array).
pub fn parseAnswers(a: Allocator, v: ?json.Value) ![]Answer {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var out: std.ArrayList(Answer) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const qid = getStr(item, "questionId") orelse getStr(item, "question_id") orelse continue;
        var labels: std.ArrayList([]const u8) = .empty;
        if (get(item, "labels")) |ls| if (ls == .array) for (ls.array.items) |l| if (l == .string) try labels.append(a, l.string);
        try out.append(a, .{ .questionId = qid, .labels = labels.items });
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "agent_turn: autonomy maps to sandbox and auto-approve like Autonomy::apply" {
    const ro = applyAutonomy("read-only", true);
    try testing.expectEqual(Sandbox.read_only, ro.sandbox);
    try testing.expect(!ro.auto_approve);
    const ws = applyAutonomy("workspace", true);
    try testing.expectEqual(Sandbox.workspace_write, ws.sandbox);
    try testing.expect(!ws.auto_approve);
    const full = applyAutonomy("full-access", true);
    try testing.expectEqual(Sandbox.danger_full_access, full.sandbox);
    try testing.expect(full.auto_approve);
}

test "agent_turn: tool calls are sanitized for the doc" {
    const gpa = testing.allocator;
    var parsed = try json.parseFromSlice(json.Value, gpa, "{\"subagent_type\":\"explore\",\"prompt\":\"secret plan\"}", .{});
    defer parsed.deinit();
    const spawn = try (Call{ .unknown = .{ .name = "Agent: look around", .input = parsed.value } }).toJson(gpa);
    defer gpa.free(spawn);
    try testing.expectEqualStrings("{\"kind\":\"unknown\",\"name\":\"Agent: look around\",\"input\":{\"subagent_type\":\"explore\"}}", spawn);
    const other = try (Call{ .unknown = .{ .name = "NotebookEdit", .input = parsed.value } }).toJson(gpa);
    defer gpa.free(other);
    try testing.expectEqualStrings("{\"kind\":\"unknown\",\"name\":\"NotebookEdit\"}", other);
    const todo = try (Call{ .todo = &.{ .{ .text = "a", .done = true }, .{ .text = "b", .done = false } } }).toJson(gpa);
    defer gpa.free(todo);
    try testing.expectEqualStrings("{\"kind\":\"todo\",\"items\":[{\"text\":\"a\",\"done\":true},{\"text\":\"b\",\"done\":false}]}", todo);
}

test "agent_turn: answers parse and yes is case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "[{\"questionId\":\"q1\",\"labels\":[\"YES\"]}]", .{});
    const as = try parseAnswers(arena.allocator(), v);
    try testing.expect(answeredYes(as));
    try testing.expectEqualStrings("YES", labelsFor(as, "q1")[0]);
    try testing.expect(!answeredYes(null));
}
