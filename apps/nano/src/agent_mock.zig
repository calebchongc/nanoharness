//! The engine's `mock` harness (`crates/harness/src/mock.rs`, with the script
//! `crates/engine/src/registry.rs` `default_registry` registers): replays a
//! fixed transcript without a model, an account or a process. It is how the
//! dev rig and the engine's own tests run a turn end to end.
//!
//! Knobs read from the run's environment, as Rust reads them:
//! `HARNESS_MOCK_DELAY_MS` spaces the events out; `HARNESS_MOCK_QUESTION`
//! asks two questions mid-stream and waits for the answer;
//! `HARNESS_MOCK_ERROR` appends the scripted error before Done.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const agent_turn = @import("agent_turn.zig");
const Turn = agent_turn.Turn;
const Event = agent_turn.Event;
const Call = agent_turn.Call;

pub const adapter: agent_turn.Adapter = .{
    .name = "mock",
    .run = run,
    .interrupt = interrupt,
    .steer = steer,
    .answer = answer,
    // `supports_steering` + `SteeringMode::StepBoundary`.
    .steers_mid_turn = true,
};

const Step = union(enum) {
    text: []const u8,
    tool: struct { id: []const u8, command: []const u8 },
    result: []const u8,
};

/// `default_registry`'s MockHarness script, up to its Done.
const script = [_]Step{
    .{ .text = "## Streaming pipeline\n\nEvery turn flows through the same path:\n\n" },
    .{ .text = "1. **Doc command** — the composer queues a durable `run` entry\n2. **Host executor** — the chat's host device marks it processed, then dispatches\n3. **Fold** — events fold into parts and diff into the Loro doc every 120ms\n\n" },
    .{ .tool = .{ .id = "mock-tool-1", .command = "cargo test --workspace" } },
    .{ .result = "mock-tool-1" },
    .{ .tool = .{ .id = "mock-tool-2", .command = "git log -5 --oneline --decorate && git merge-base HEAD origin/main" } },
    .{ .result = "mock-tool-2" },
    .{ .text = "The `SegmentWriter` appends into `LoroText` so the oplog stays RLE-merged:\n\n```rust\nfolded = fold_event_into_parts(&folded, &event);\nwriter.sync(&folded)?; // 120ms coalesced commits\n```\n\nSynced to every device through the session room. *Mock harness reporting in.*" },
};

pub const error_text = "Claude usage limit reached — try again after the limit resets.";

/// `question_script`.
const questions = [_]agent_turn.Question{
    .{ .id = "q-sync", .header = "Question", .question = "Which sync strategy should the rewrite use?", .options = &.{ "Poll the doc host every 120ms", "Event-driven fold with coalesced commits", "Hybrid: event-driven with a polling fallback" } },
    .{ .id = "q-gates", .header = "Question", .question = "Which suites should gate the merge?", .options = &.{ "Unit tests", "End-to-end (two-device)", "Golden screenshots" }, .multiSelect = true },
};

fn knobOn(t: *Turn, name: []const u8) bool {
    const v = t.req.env.get(name) orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// The answer to the open question, set by `answer` (under `t.mu`).
const State = struct {
    answered: bool = false,
    /// Every picked label, joined by `**, **` (arena-owned).
    picked: []const u8 = "",
};

/// Sleep `ms` in short steps; false once the turn is interrupted.
fn pause(t: *Turn, ms: u64) bool {
    var left = ms;
    while (true) {
        if (t.interrupted.load(.acquire)) return false;
        if (left == 0) return true;
        const step = @min(left, 10);
        Io.sleep(t.io, .fromMilliseconds(@intCast(step)), .awake) catch return false;
        left -= step;
    }
}

fn interruptedDone(t: *Turn) void {
    t.emit(.{ .done = .{ .status = .interrupted } });
}

fn run(t: *Turn) !void {
    const a = t.arena.allocator();
    const delay: u64 = if (t.req.env.get("HARNESS_MOCK_DELAY_MS")) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
    if (knobOn(t, "HARNESS_MOCK_QUESTION")) return runQuestion(t, delay);

    for (script) |step| {
        if (!pause(t, delay)) return interruptedDone(t);
        switch (step) {
            .text => |s| t.emit(.{ .text = s }),
            .tool => |c| t.emit(.{ .tool_call = .{ .id = c.id, .call = try (Call{ .exec = c.command }).toJson(a) } }),
            .result => |id| t.emit(.{ .tool_result = .{ .id = id, .is_error = false } }),
        }
    }
    if (knobOn(t, "HARNESS_MOCK_ERROR")) {
        if (!pause(t, delay)) return interruptedDone(t);
        t.emit(.{ .err = error_text });
    }
    if (!pause(t, delay)) return interruptedDone(t);
    t.emit(.{ .done = .{ .status = .completed } });
}

fn runQuestion(t: *Turn, delay: u64) !void {
    const step: u64 = if (delay == 0) 50 else delay;
    var st: State = .{};
    t.mu.lockUncancelable(t.io);
    t.state = &st;
    t.mu.unlock(t.io);
    defer {
        t.mu.lockUncancelable(t.io);
        t.state = null;
        t.mu.unlock(t.io);
    }
    if (!pause(t, step)) return interruptedDone(t);
    t.emit(.{ .text = "Before I wire the reconciliation path I need two decisions from you.\n\n" });
    if (!pause(t, step)) return interruptedDone(t);
    try t.ask(0, "", &questions);
    while (true) {
        t.mu.lockUncancelable(t.io);
        const done = st.answered;
        t.mu.unlock(t.io);
        if (done) break;
        if (!pause(t, 10)) return interruptedDone(t);
    }
    if (!pause(t, step)) return interruptedDone(t);
    const picked = if (st.picked.len == 0) "your defaults" else st.picked;
    t.emit(.{ .text = try std.fmt.allocPrint(t.arena.allocator(), "Locked in: **{s}**. Proceeding with the plan.", .{picked}) });
    t.emit(.{ .done = .{ .status = .completed } });
}

fn answer(t: *Turn, _: *const agent_turn.Pending, answers: ?[]const agent_turn.Answer) void {
    // `request_input(..).await.unwrap_or_default()`: a dismissal is no answer.
    var joined: std.ArrayList(u8) = .empty;
    if (answers) |as| for (as) |ans| for (ans.labels) |l| {
        if (joined.items.len > 0) joined.appendSlice(t.gpa, "**, **") catch {};
        joined.appendSlice(t.gpa, l) catch {};
    };
    defer joined.deinit(t.gpa);
    t.mu.lockUncancelable(t.io);
    defer t.mu.unlock(t.io);
    const st: *State = @ptrCast(@alignCast(t.state orelse return));
    st.picked = t.arena.allocator().dupe(u8, joined.items) catch "";
    st.answered = true;
}

/// The mock has no process: the run loop sees `interrupted` and ends.
fn interrupt(_: *Turn) void {}

/// The mock's steering mailbox accepts and ignores the message.
fn steer(_: *Turn, _: []const u8) bool {
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testkit = @import("agent_testkit.zig");

test "mock: a turn replays the default script and completes" {
    const rig = try testkit.Rig.create(.{ .harness = "mock", .override_var = "HARNESS_MOCK_UNUSED", .script = "" });
    defer rig.destroy();
    try rig.run("m-1", "hello");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "*Mock harness reporting in.*") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"call\":{\"kind\":\"exec\",\"command\":\"cargo test --workspace\"},\"resolved\":true,\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "Ack from") == null);
}

test "mock: the question knob waits for the answer and quotes it" {
    const rig = try testkit.Rig.create(.{ .harness = "mock", .override_var = "HARNESS_MOCK_QUESTION", .script = "" });
    defer rig.destroy();
    try rig.env.put("HARNESS_MOCK_QUESTION", "1");
    try rig.run("m-1", "ask me");
    try rig.waitQuestion(5000);
    try rig.answerOpen("q-sync", "Unit tests");
    try rig.waitIdle(5000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "Locked in: **Unit tests**. Proceeding with the plan.") != null);
}
