//! A seam for external commands the engine runs (`xcrun simctl`, `npm`,
//! `node`, update installers): production goes through `std.process.run`
//! with a hard deadline; tests swap in `FakeRunner`, which answers from
//! recorded, made-up output and never spawns anything.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Term = enum { exited, signaled, timed_out, spawn_failed };

pub const Output = struct {
    term: Term,
    code: u8 = 0,
    stdout: []u8,
    stderr: []u8,

    pub fn ok(self: Output) bool {
        return self.term == .exited and self.code == 0;
    }

    pub fn deinit(self: *Output, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// Every command has a deadline; a hang is a failure, never a wait.
    timeout_ms: u64,
};

pub const Runner = struct {
    ctx: ?*anyopaque = null,
    run_fn: *const fn (ctx: ?*anyopaque, gpa: Allocator, req: Request) Allocator.Error!Output,

    pub fn run(self: Runner, gpa: Allocator, req: Request) Allocator.Error!Output {
        return self.run_fn(self.ctx, gpa, req);
    }
};

/// Runs real processes. Keep the struct alive as long as its `runner()`.
pub const SystemRunner = struct {
    io: std.Io,

    pub fn runner(self: *SystemRunner) Runner {
        return .{ .ctx = self, .run_fn = runSystem };
    }

    fn runSystem(ctx: ?*anyopaque, gpa: Allocator, req: Request) Allocator.Error!Output {
        const self: *SystemRunner = @ptrCast(@alignCast(ctx.?));
        if (comptime !std.process.can_spawn) {
            return .{ .term = .spawn_failed, .stdout = try gpa.dupe(u8, ""), .stderr = try gpa.dupe(u8, "") };
        }
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(req.timeout_ms)),
            .clock = .awake,
        } };
        const res = std.process.run(gpa, self.io, .{
            .argv = req.argv,
            .cwd = if (req.cwd) |c| .{ .path = c } else .inherit,
            .stdout_limit = .limited(64 << 20),
            .stderr_limit = .limited(16 << 20),
            .timeout = timeout.toDeadline(self.io),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return .{ .term = .timed_out, .stdout = try gpa.dupe(u8, ""), .stderr = try gpa.dupe(u8, "") },
            else => return .{ .term = .spawn_failed, .stdout = try gpa.dupe(u8, ""), .stderr = try gpa.dupe(u8, @errorName(err)) },
        };
        return switch (res.term) {
            .exited => |code| .{ .term = .exited, .code = code, .stdout = res.stdout, .stderr = res.stderr },
            else => .{ .term = .signaled, .code = 0, .stdout = res.stdout, .stderr = res.stderr },
        };
    }
};

/// The value of an environment variable, from the process environment (libc).
pub fn getenv(name: [:0]const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    const v = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}

/// A recorded command answer for `FakeRunner`.
pub const Script = struct {
    /// The space-joined argv must start with this.
    prefix: []const u8,
    term: Term = .exited,
    code: u8 = 0,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    /// Side effect run before answering (for example: what `npm ci` writes).
    effect: ?*const fn (ctx: ?*anyopaque, req: Request) void = null,
    effect_ctx: ?*anyopaque = null,
};

/// Answers commands from `scripts` (first unused match, else the last match;
/// unknown commands fail to spawn) and records every command line.
pub const FakeRunner = struct {
    gpa: Allocator,
    scripts: []const Script,
    used: [32]bool = @splat(false),
    calls: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: Allocator, scripts: []const Script) FakeRunner {
        return .{ .gpa = gpa, .scripts = scripts };
    }

    pub fn deinit(self: *FakeRunner) void {
        for (self.calls.items) |c| self.gpa.free(c);
        self.calls.deinit(self.gpa);
    }

    pub fn runner(self: *FakeRunner) Runner {
        return .{ .ctx = self, .run_fn = runFake };
    }

    pub fn called(self: *const FakeRunner, needle: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.indexOf(u8, c, needle) != null) n += 1;
        }
        return n;
    }

    fn runFake(ctx: ?*anyopaque, gpa: Allocator, req: Request) Allocator.Error!Output {
        const self: *FakeRunner = @ptrCast(@alignCast(ctx.?));
        const line = try std.mem.join(self.gpa, " ", req.argv);
        try self.calls.append(self.gpa, line);
        var pick: ?usize = null;
        var last: ?usize = null;
        for (self.scripts, 0..) |s, i| {
            if (!std.mem.startsWith(u8, line, s.prefix)) continue;
            last = i;
            if (pick == null and !self.used[i]) pick = i;
        }
        const idx = pick orelse last orelse {
            return .{ .term = .spawn_failed, .stdout = try gpa.dupe(u8, ""), .stderr = try gpa.dupe(u8, "FileNotFound") };
        };
        self.used[idx] = true;
        const s = self.scripts[idx];
        if (s.effect) |eff| eff(s.effect_ctx, req);
        return .{
            .term = s.term,
            .code = s.code,
            .stdout = try gpa.dupe(u8, s.stdout),
            .stderr = try gpa.dupe(u8, s.stderr),
        };
    }
};

test "FakeRunner answers in order, repeats the last match, and records calls" {
    const gpa = std.testing.allocator;
    var fake = FakeRunner.init(gpa, &.{
        .{ .prefix = "a b", .stdout = "one" },
        .{ .prefix = "a b", .stdout = "two" },
        .{ .prefix = "c", .term = .timed_out },
    });
    defer fake.deinit();
    const r = fake.runner();
    var o1 = try r.run(gpa, .{ .argv = &.{ "a", "b", "x" }, .timeout_ms = 10 });
    defer o1.deinit(gpa);
    var o2 = try r.run(gpa, .{ .argv = &.{ "a", "b" }, .timeout_ms = 10 });
    defer o2.deinit(gpa);
    var o3 = try r.run(gpa, .{ .argv = &.{ "a", "b" }, .timeout_ms = 10 });
    defer o3.deinit(gpa);
    var o4 = try r.run(gpa, .{ .argv = &.{"c"}, .timeout_ms = 10 });
    defer o4.deinit(gpa);
    var o5 = try r.run(gpa, .{ .argv = &.{"zzz"}, .timeout_ms = 10 });
    defer o5.deinit(gpa);
    try std.testing.expectEqualStrings("one", o1.stdout);
    try std.testing.expectEqualStrings("two", o2.stdout);
    try std.testing.expectEqualStrings("two", o3.stdout);
    try std.testing.expect(o1.ok());
    try std.testing.expectEqual(Term.timed_out, o4.term);
    try std.testing.expectEqual(Term.spawn_failed, o5.term);
    try std.testing.expectEqual(@as(usize, 3), fake.called("a b"));
}

test "SystemRunner enforces its deadline on a command that hangs" {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var sys: SystemRunner = .{ .io = std.testing.io };
    var out = try sys.runner().run(gpa, .{ .argv = &.{ "/bin/sleep", "5" }, .timeout_ms = 200 });
    defer out.deinit(gpa);
    try std.testing.expectEqual(Term.timed_out, out.term);
    var ok = try sys.runner().run(gpa, .{ .argv = &.{ "/bin/echo", "hi" }, .timeout_ms = 5000 });
    defer ok.deinit(gpa);
    try std.testing.expect(ok.ok());
    try std.testing.expectEqualStrings("hi\n", ok.stdout);
}
