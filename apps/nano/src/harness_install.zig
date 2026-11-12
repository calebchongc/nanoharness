//! The `InstallHarness` / `CancelInstall` RPCs' installers, ported from
//! `crates/harness/src/install.rs` (`methods`, `available`, `selected`,
//! `can_install`, `manual_command`, `cli_and_dir`, `post_install`,
//! `configure`, `command`, `install_harness`, `install_with_command`,
//! `capture`, `run`) and `crates/engine/src/rpc.rs` (`Installations` —
//! one install per harness, "already installing" — `run_requested_install`,
//! and `install_harness_with`'s `can_install` gate).
//!
//! The graff release lives in `harness_install_graff.zig`, the pinned
//! Antigravity archive in `harness_install_archive.zig`, and the shared
//! cancel/deadline/HTTP plumbing in `harness_install_net.zig`.
//!
//! What the RPC glue calls:
//!
//! ```zig
//! var installing = registry.begin(gpa, io, id) catch |e| switch (e) {
//!     error.AlreadyInstalling => return rpcFailed(harness_install.already_installing),
//!     error.OutOfMemory => return error.OutOfMemory,
//! };
//! defer installing.end();
//! const failed = try harness_install.requestInstall(gpa, io, id, .{
//!     .beta = beta, .cancel = installing.token, .installed = probe,
//! });
//! // null: enable an off-by-default harness, reply with fresh descriptors;
//! // otherwise reply `RpcError::Failed(failed)` (owned text).
//! ```
//!
//! and `CancelInstall` calls `registry.cancel(io, id)`.
//!
//! Rust emits no progress events while installing: the reply is the only
//! signal. Shell, npm, PowerShell and Homebrew installers run with no
//! integrity check of their own, as in Rust.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const posix = std.posix;
const agent_proc = @import("agent_proc.zig");
const harness_version = @import("harness_version.zig");
pub const net = @import("harness_install_net.zig");
pub const graff = @import("harness_install_graff.zig");
pub const archive = @import("harness_install_archive.zig");

pub const Failure = net.Failure;
pub const Error = net.Error;
pub const Cancel = net.Cancel;
const fail = net.fail;
const is_windows = net.is_windows;

/// `DEADLINE`: 15 minutes for any one install.
pub const deadline_ms_default: u64 = 15 * 60 * 1000;

/// `HarnessId` (tags match `rpcw_executables.HarnessId`).
pub const Id = enum {
    mock,
    graff,
    claude_code,
    codex,
    cursor,
    devin,
    grok,
    hermes,
    pi,
    opencode,
    antigravity,
    exo,

    /// serde `kebab-case`.
    pub fn wire(id: Id) []const u8 {
        return switch (id) {
            .claude_code => "claude-code",
            inline else => |t| @tagName(t),
        };
    }

    pub fn parse(text: []const u8) ?Id {
        for (std.meta.tags(Id)) |id| if (std.mem.eql(u8, text, id.wire())) return id;
        return null;
    }
};

pub const Platform = enum {
    unix,
    mac,
    windows,

    pub fn current() Platform {
        return if (is_windows) .windows else if (builtin.os.tag == .macos) .mac else .unix;
    }
};

pub const Method = union(enum) {
    archive,
    /// codegraff's checksummed GitHub release into `~/.harness/bin/graff`.
    graff_release,
    shell: struct { script: []const u8, shell: []const u8 },
    npm: struct { package: []const u8, ignore_scripts: bool },
    power_shell: []const u8,
    brew,
};

const claude_sh: Method = .{ .shell = .{ .script = "curl -fsSL https://claude.ai/install.sh | bash", .shell = "bash" } };
const codex_sh: Method = .{ .shell = .{ .script = "curl -fsSL https://chatgpt.com/codex/install.sh | sh", .shell = "sh" } };
const codex_npm: Method = .{ .npm = .{ .package = "@openai/codex", .ignore_scripts = false } };
const cursor_sh: Method = .{ .shell = .{ .script = "curl https://cursor.com/install -fsS | bash", .shell = "bash" } };
const opencode_sh: Method = .{ .shell = .{ .script = "curl -fsSL https://opencode.ai/install | bash", .shell = "bash" } };
const opencode_npm: Method = .{ .npm = .{ .package = "@opencode/cli", .ignore_scripts = false } };
const pi_sh: Method = .{ .shell = .{ .script = "curl -fsSL https://pi.dev/install.sh | sh", .shell = "sh" } };
const pi_npm: Method = .{ .npm = .{ .package = "@earendil-works/pi-coding-agent", .ignore_scripts = true } };
const grok_sh: Method = .{ .shell = .{ .script = "curl -fsSL https://x.ai/cli/install.sh | bash", .shell = "bash" } };
const grok_npm: Method = .{ .npm = .{ .package = "@xai-official/grok", .ignore_scripts = false } };
const hermes_sh: Method = .{ .shell = .{ .script = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash", .shell = "bash" } };
const devin_sh: Method = .{ .shell = .{ .script = "curl -fsSL https://cli.devin.ai/install.sh | bash", .shell = "bash" } };

/// `methods(id, platform)`, in preference order.
pub fn methods(id: Id, platform: Platform) []const Method {
    const windows = platform == .windows;
    return switch (id) {
        // Exo's setup is interactive (API key, names) and needs Docker.
        .mock, .exo => &.{},
        .graff => if (windows) &.{} else &.{.graff_release},
        .antigravity => &.{.archive},
        .claude_code => if (windows) &.{.{ .power_shell = "irm https://claude.ai/install.ps1 | iex" }} else &.{claude_sh},
        .codex => if (windows) &.{ .{ .power_shell = "irm https://chatgpt.com/codex/install.ps1 | iex" }, codex_npm } else &.{ codex_sh, codex_npm },
        .cursor => if (windows) &.{.{ .power_shell = "irm 'https://cursor.com/install?win32=true' | iex" }} else &.{cursor_sh},
        .opencode => if (windows) &.{opencode_npm} else &.{ opencode_sh, opencode_npm },
        .pi => if (windows) &.{pi_npm} else &.{ pi_sh, pi_npm },
        .grok => if (windows) &.{grok_npm} else &.{ grok_sh, grok_npm },
        .hermes => if (windows) &.{.{ .power_shell = "irm https://hermes-agent.nousresearch.com/install.ps1 | iex" }} else &.{hermes_sh},
        .devin => switch (platform) {
            .windows => &.{.{ .power_shell = "irm https://static.devin.ai/cli/setup.ps1 | iex" }},
            .mac => &.{ .brew, devin_sh },
            .unix => &.{devin_sh},
        },
    };
}

/// `available(method, platform, has, archive)`; `has` is any value with
/// `fn has(self, name) bool`.
pub fn available(method: Method, platform: Platform, has: anytype, archive_pinned: bool) bool {
    return switch (method) {
        .archive => archive_pinned,
        .graff_release => has.has("tar"),
        .shell => |s| has.has("sh") and has.has("curl") and has.has(s.shell),
        .npm => has.has("npm") and (platform == .windows or has.has("sh")),
        .power_shell => has.has("powershell"),
        .brew => has.has("brew") and has.has("sh"),
    };
}

/// `manual_command`: the portable documented fallback shown to viewers of a
/// device without installer prerequisites.
pub fn manualCommand(id: Id) ?[]const u8 {
    return switch (id) {
        .claude_code => "curl -fsSL https://claude.ai/install.sh | bash",
        .codex => "npm install -g @openai/codex",
        .cursor => "curl https://cursor.com/install -fsS | bash",
        .opencode => "npm install -g @opencode/cli",
        .pi => "npm install -g --ignore-scripts @earendil-works/pi-coding-agent",
        .grok => "npm install -g @xai-official/grok",
        .hermes => "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
        .devin => "curl -fsSL https://cli.devin.ai/install.sh | bash",
        .exo => "curl -fsSL https://raw.githubusercontent.com/exoharness/exo/main/setup.sh -o setup.sh && bash setup.sh",
        .antigravity, .graff, .mock => null,
    };
}

pub const CliDir = struct { cli: []const u8, dir: []const u8 };

/// `cli_and_dir`: the CLI an install provides and where it usually lands.
pub fn cliAndDir(id: Id) CliDir {
    return switch (id) {
        .claude_code => .{ .cli = "claude", .dir = "~/.local/bin" },
        .codex => .{ .cli = "codex", .dir = "~/.local/bin or the npm global bin" },
        .cursor => .{ .cli = "cursor-agent", .dir = "~/.local/bin or ~/.cursor/bin" },
        .opencode => .{ .cli = "opencode", .dir = "~/.opencode/bin or the npm global bin" },
        .pi => .{ .cli = "pi", .dir = "the npm global bin" },
        .grok => .{ .cli = "grok", .dir = "~/.grok/bin or the npm global bin" },
        .hermes => .{ .cli = "hermes", .dir = "~/.local/bin or ~/.hermes/bin" },
        .graff => .{ .cli = "graff", .dir = "~/.harness/bin" },
        .devin => .{ .cli = "devin", .dir = "~/.local/bin" },
        .antigravity => .{ .cli = "agy_acp_server", .dir = "~/.harness/adapters" },
        .exo => .{ .cli = "exo-cli", .dir = "~/bin" },
        .mock => .{ .cli = "mock", .dir = "PATH" },
    };
}

/// `invalidate_versions`: forget cached `--version` probes of the CLI
/// (Cursor's is also `agent`).
pub fn invalidateVersions(io: Io, id: Id) void {
    const cli = cliAndDir(id).cli;
    if (id == .cursor) harness_version.invalidateVersions(io, &.{ cli, "agent" }) else harness_version.invalidateVersions(io, &.{cli});
}

/// The engine's "is the CLI installed now?" probe (each harness's `installed()`).
pub const InstalledFn = *const fn (gpa: Allocator, io: Io, id: Id) bool;

/// `post_install`.
pub fn postInstall(gpa: Allocator, io: Io, id: Id, installed: InstalledFn) Allocator.Error!?Failure {
    if (installed(gpa, io, id)) return null;
    const c = cliAndDir(id);
    return try fail(gpa, .install, "installer finished but `{s}` was not found on PATH; open a new terminal or add {s} to PATH", .{ c.cli, c.dir });
}

// ── finding tools (`executable::find_on_paths`, `adapter_install::find_npm`) ──

/// The login shell's PATH (`shell_env::login_shell_path`); tests replace it.
pub var login_shell_path: *const fn (gpa: Allocator, io: Io, env: *const Environ.Map) ?[]const u8 = defaultLoginShellPath;

fn defaultLoginShellPath(gpa: Allocator, io: Io, env: *const Environ.Map) ?[]const u8 {
    return agent_proc.loginShellPath(gpa, io, env);
}

const path_sep: u8 = if (is_windows) ';' else ':';

fn isRunnable(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    if (is_windows) return true;
    return (@as(u32, @intCast(st.permissions.toMode())) & 0o111) != 0;
}

fn search(gpa: Allocator, io: Io, env: *const Environ.Map, name: []const u8) agent_proc.Search {
    return .{
        .name = name,
        .path_env = env.get("PATH"),
        .login_path = login_shell_path(gpa, io, env),
        .home = net.homeDir(env),
        .fnm_dir = net.getNonEmpty(env, "FNM_DIR"),
    };
}

/// `find_on_paths(name, [])` (owned): among the runnable candidates on PATH,
/// the login shell's PATH and the Node version managers' bins, the
/// PATH-preferred one unless a later one reports a newer version.
pub fn findOnPaths(gpa: Allocator, io: Io, env: *const Environ.Map, name: []const u8) Allocator.Error!?[]u8 {
    const s = search(gpa, io, env, name);
    var list = agent_proc.candidatePaths(gpa, s) catch return error.OutOfMemory;
    defer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    var runnable: std.ArrayList([]const u8) = .empty;
    defer runnable.deinit(gpa);
    for (list.items) |p| if (isRunnable(io, p)) try runnable.append(gpa, p);
    if (runnable.items.len == 0) return agent_proc.findExecutable(gpa, io, s) catch return error.OutOfMemory;
    return harness_version.newestCandidate(gpa, io, name, runnable.items) catch return error.OutOfMemory;
}

/// Whether `find_on_paths(name, [])` finds anything (no version probes).
fn onPaths(gpa: Allocator, io: Io, env: *const Environ.Map, name: []const u8) bool {
    const found = agent_proc.findExecutable(gpa, io, search(gpa, io, env, name)) catch return false;
    if (found) |f| gpa.free(f);
    return found != null;
}

/// `find_npm` (owned): npm on Unix; on Windows, `npm-cli.js` beside the first
/// `node` that has one.
pub fn findNpm(gpa: Allocator, io: Io, env: *const Environ.Map) Allocator.Error!?[]u8 {
    if (!is_windows) return findOnPaths(gpa, io, env, "npm");
    const s = search(gpa, io, env, "node.exe");
    var list = agent_proc.candidatePaths(gpa, s) catch return error.OutOfMemory;
    defer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    for (list.items) |node| {
        if (!isRunnable(io, node)) continue;
        const cli = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(node) orelse ".", "node_modules", "npm", "bin", "npm-cli.js" });
        if (net.isFile(io, cli)) return cli;
        gpa.free(cli);
    }
    return null;
}

/// `resolve(name)` (owned): npm through `find_npm`, the rest through `find_on_paths`.
fn resolve(gpa: Allocator, io: Io, env: *const Environ.Map, name: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.eql(u8, name, "npm")) return findNpm(gpa, io, env);
    return findOnPaths(gpa, io, env, name);
}

const LiveHas = struct {
    gpa: Allocator,
    io: Io,
    env: *const Environ.Map,

    pub fn has(self: LiveHas, name: []const u8) bool {
        if (std.mem.eql(u8, name, "npm") and is_windows) {
            const npm = findNpm(self.gpa, self.io, self.env) catch return false;
            if (npm) |n| self.gpa.free(n);
            return npm != null;
        }
        return onPaths(self.gpa, self.io, self.env, name);
    }
};

/// `selected(id)`: the first available method on this device. The archive
/// method needs `archive_pin` (`acp::can_install`).
pub fn selected(gpa: Allocator, io: Io, id: Id, archive_pin: ?archive.ArchivePin) Allocator.Error!?Method {
    var env = try net.currentEnv(gpa);
    defer env.deinit();
    const platform = Platform.current();
    const has: LiveHas = .{ .gpa = gpa, .io = io, .env = &env };
    const pinned = id == .antigravity and archive_pin != null;
    for (methods(id, platform)) |m| if (available(m, platform, has, pinned)) return m;
    return null;
}

/// `can_install(id)` with this platform's pinned archive.
pub fn canInstall(gpa: Allocator, io: Io, id: Id) bool {
    return canInstallWith(gpa, io, id, archive.antigravityArchive());
}

pub fn canInstallWith(gpa: Allocator, io: Io, id: Id, archive_pin: ?archive.ArchivePin) bool {
    return (selected(gpa, io, id, archive_pin) catch null) != null;
}

// ── the installer command ──────────────────────────────────────────────────

/// `configure`: the installer's environment from `base`: agent-nesting
/// variables and every `HARNESS_*` removed; PATH = PATH + the login shell's
/// PATH + npm's directory; `CI=1`, `NONINTERACTIVE=1`, `TERM=dumb`.
pub fn configureEnv(gpa: Allocator, io: Io, base: *const Environ.Map) Allocator.Error!Environ.Map {
    var env = try base.clone(gpa);
    errdefer env.deinit();
    for (agent_proc.stripped_env) |k| _ = env.swapRemove(k);
    var drop: std.ArrayList([]const u8) = .empty;
    defer {
        for (drop.items) |k| gpa.free(k);
        drop.deinit(gpa);
    }
    for (env.keys()) |k| if (std.mem.startsWith(u8, k, "HARNESS_")) try drop.append(gpa, try gpa.dupe(u8, k));
    for (drop.items) |k| _ = env.swapRemove(k);

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    var first = true;
    const add = struct {
        fn f(list: *std.ArrayList(u8), a: Allocator, is_first: *bool, seg: []const u8) Allocator.Error!void {
            if (!is_first.*) try list.append(a, path_sep);
            is_first.* = false;
            try list.appendSlice(a, seg);
        }
    }.f;
    if (base.get("PATH")) |p| {
        var it = std.mem.splitScalar(u8, p, path_sep);
        while (it.next()) |seg| try add(&path, gpa, &first, seg);
    }
    if (login_shell_path(gpa, io, base)) |p| {
        var it = std.mem.splitScalar(u8, p, path_sep);
        while (it.next()) |seg| try add(&path, gpa, &first, seg);
    }
    // npm can be found in a managed toolchain even when shell startup was disabled.
    if (try findNpm(gpa, io, base)) |npm| {
        defer gpa.free(npm);
        if (std.fs.path.dirname(npm)) |d| try add(&path, gpa, &first, d);
    }
    try env.put("PATH", path.items);
    try env.put("CI", "1");
    try env.put("NONINTERACTIVE", "1");
    try env.put("TERM", "dumb");
    return env;
}

/// An installer process to start: exact argv and its configured environment.
pub const Command = struct {
    gpa: Allocator,
    argv: [][]u8,
    env: Environ.Map,

    pub fn deinit(c: *Command) void {
        for (c.argv) |a| c.gpa.free(a);
        c.gpa.free(c.argv);
        c.env.deinit();
    }
};

fn makeArgv(gpa: Allocator, parts: []const []const u8) Allocator.Error![][]u8 {
    const argv = try gpa.alloc([]u8, parts.len);
    var n: usize = 0;
    errdefer {
        for (argv[0..n]) |a| gpa.free(a);
        gpa.free(argv);
    }
    for (parts) |p| {
        argv[n] = try gpa.dupe(u8, p);
        n += 1;
    }
    return argv;
}

/// `shell_command(script)`: `sh -c script`.
fn shellArgv(gpa: Allocator, io: Io, env: *const Environ.Map, script: []const u8) Error!net.Result([][]u8) {
    const sh = (try resolve(gpa, io, env, "sh")) orelse return .{ .err = try fail(gpa, .install, "sh not found", .{}) };
    defer gpa.free(sh);
    return .{ .ok = try makeArgv(gpa, &.{ sh, "-c", script }) };
}

/// `command(method)`: Rust's exact argv per method, configured.
pub fn command(gpa: Allocator, io: Io, method: Method, platform: Platform) Error!net.Result(Command) {
    var env = try net.currentEnv(gpa);
    defer env.deinit();
    const argv_r: net.Result([][]u8) = switch (method) {
        .power_shell => |script| blk: {
            const ps = (try resolve(gpa, io, &env, "powershell")) orelse break :blk .{ .err = try missing(gpa) };
            defer gpa.free(ps);
            break :blk .{ .ok = try makeArgv(gpa, &.{ ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script }) };
        },
        .npm => |n| if (platform == .windows) blk: {
            const npm = (try resolve(gpa, io, &env, "npm")) orelse break :blk .{ .err = try missing(gpa) };
            defer gpa.free(npm);
            break :blk .{ .ok = try makeArgv(gpa, if (n.ignore_scripts)
                &.{ npm, "install", "-g", "--ignore-scripts", n.package }
            else
                &.{ npm, "install", "-g", n.package }) };
        } else blk: {
            const script = try std.fmt.allocPrint(gpa, "npm install -g {s}{s}", .{ if (n.ignore_scripts) "--ignore-scripts " else "", n.package });
            defer gpa.free(script);
            break :blk try shellArgv(gpa, io, &env, script);
        },
        .shell => |s| try shellArgv(gpa, io, &env, s.script),
        .brew => try shellArgv(gpa, io, &env, "brew install --cask devin-cli"),
        // Archives and graff releases have separate executors.
        .archive, .graff_release => unreachable,
    };
    const argv = switch (argv_r) {
        .ok => |a| a,
        .err => |f| return .{ .err = f },
    };
    errdefer {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
    }
    return .{ .ok = .{ .gpa = gpa, .argv = argv, .env = try configureEnv(gpa, io, &env) } };
}

fn missing(gpa: Allocator) Allocator.Error!Failure {
    return fail(gpa, .install, "installer prerequisite is no longer available", .{});
}

// ── running an installer (`run`, `capture`) ────────────────────────────────

/// `capture`'s per-stream line state: bytes up to a `\n` or `\r` form a line
/// (at most 4096 kept; the rest of an over-long line is dropped until its
/// newline, so a credential split across reads never leaks as an unmarked
/// continuation); each line is redacted before it enters the tail.
pub const Capture = struct {
    line: [4096]u8 = undefined,
    len: usize = 0,
    ended: bool = false,

    pub fn feed(c: *Capture, gpa: Allocator, tail: *agent_proc.StderrTail, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n' or b == '\r') {
                c.push(gpa, tail);
                c.len = 0;
            } else if (c.len < c.line.len) {
                c.line[c.len] = b;
                c.len += 1;
            }
        }
    }

    /// End of stream: the partial line goes in too.
    pub fn finish(c: *Capture, gpa: Allocator, tail: *agent_proc.StderrTail) void {
        if (c.ended) return;
        c.ended = true;
        c.push(gpa, tail);
        c.len = 0;
    }

    fn push(c: *Capture, gpa: Allocator, tail: *agent_proc.StderrTail) void {
        const text = lossy(gpa, c.line[0..c.len]) catch return;
        defer gpa.free(text);
        const clean = agent_proc.redactSecrets(gpa, text) catch return;
        defer gpa.free(clean);
        tail.push(clean);
    }
};

/// `String::from_utf8_lossy`: invalid sequences become U+FFFD.
fn lossy(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (n > 0 and i + n <= bytes.len and (std.unicode.utf8Decode(bytes[i .. i + n]) catch null) != null) {
            try out.appendSlice(gpa, bytes[i .. i + n]);
            i += n;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Rust's `ExitStatus` display on Unix.
fn exitStatusText(buf: []u8, term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| std.fmt.bufPrint(buf, "exit status: {d}", .{code}) catch "exit status",
        .signal => |sig| std.fmt.bufPrint(buf, "signal: {d} (SIG{s})", .{ @backingInt(sig), @tagName(sig) }) catch "signal",
        .stopped => |sig| std.fmt.bufPrint(buf, "stopped (not terminated) by signal: {d} (SIG{s})", .{ @backingInt(sig), @tagName(sig) }) catch "stopped",
        .unknown => |v| std.fmt.bufPrint(buf, "unrecognised wait status: {d}", .{v}) catch "unknown",
    };
}

const Waiter = struct {
    child: *std.process.Child,
    io: Io,
    term: ?std.process.Child.Term = null,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(w: *Waiter) void {
        w.term = w.child.wait(w.io) catch |e| blk: {
            w.err = e;
            break :blk null;
        };
        w.done.store(true, .release);
    }
};

const GroupSignal = enum { TERM, KILL };

fn signalGroup(pid: posix.pid_t, sig: GroupSignal) void {
    if (comptime is_windows) return;
    posix.kill(-pid, switch (sig) {
        .TERM => .TERM,
        .KILL => .KILL,
    }) catch {};
}

/// Whether any process of the group is still alive (`kill(-pgid, 0)`).
fn groupAlive(pid: posix.pid_t) bool {
    if (comptime is_windows) return false;
    const r = posix.system.kill(-pid, @fromBackingInt(0));
    return switch (posix.errno(r)) {
        .SUCCESS, .PERM => true,
        else => false,
    };
}

fn sleepMs(io: Io, ms: u64) void {
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// `run(command, cancel, deadline)`: start the installer in its own process
/// group with stdin null, keep a redacted tail of stdout and stderr, and
/// finish on cancel ("installation cancelled"), the deadline ("installation
/// timed out after 15 minutes", Rust's text whatever the deadline) or exit
/// with both streams closed. The group then gets SIGTERM, 100 ms, SIGKILL.
pub fn run(gpa: Allocator, io: Io, argv: []const []const u8, env: *const Environ.Map, cancel: *const Cancel, deadline_ms: u64) Error!?Failure {
    if (cancel.isCancelled()) return try fail(gpa, .install, "installation cancelled", .{});
    if (comptime !std.process.can_spawn) return try fail(gpa, .install, "unsupported platform", .{});
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (is_windows) null else 0,
        .create_no_window = true,
    }) catch |e| {
        if (e == error.Canceled) return error.Canceled;
        return try fail(gpa, .install, "{s}", .{net.ioText(e)});
    };
    const pid = child.id.?;
    // The pipes are read here; `wait` (on the waiter thread) must not close them.
    const out_file = child.stdout.?;
    const err_file = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer out_file.close(io);
    defer err_file.close(io);
    var waiter: Waiter = .{ .child = &child, .io = io };
    const waiter_thread = std.Thread.spawn(.{}, Waiter.run, .{&waiter}) catch {
        signalGroup(pid, .KILL);
        Waiter.run(&waiter);
        return try fail(gpa, .install, "could not wait for the installer", .{});
    };

    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ out_file, err_file });
    var tail: agent_proc.StderrTail = .{};
    var caps: [2]Capture = .{ .{}, .{} };
    var open = true;
    var reason: ?[]const u8 = null;
    var caller_cancelled = false;
    const start = net.nowNs(io);
    const deadline_ns: i64 = @intCast(deadline_ms * std.time.ns_per_ms);
    while (true) {
        if (cancel.isCancelled()) {
            reason = "installation cancelled";
            break;
        }
        if (net.nowNs(io) - start >= deadline_ns) {
            reason = "installation timed out after 15 minutes";
            break;
        }
        if (!open and waiter.done.load(.acquire)) break;
        if (open) {
            mr.fill(1024, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |e| switch (e) {
                error.Timeout => {},
                error.Canceled => {
                    caller_cancelled = true;
                    reason = "installation cancelled";
                },
                else => open = false,
            };
            for (&caps, 0..) |*cap, i| {
                const r = mr.reader(i);
                cap.feed(gpa, &tail, r.buffered());
                r.toss(r.bufferedLen());
                if (mr.streams.contexts()[i].err != null) cap.finish(gpa, &tail);
            }
            if (!open) for (&caps) |*cap| cap.finish(gpa, &tail);
            if (caller_cancelled) break;
        } else {
            io.sleep(.fromMilliseconds(10), .awake) catch {
                caller_cancelled = true;
                reason = "installation cancelled";
                break;
            };
        }
    }

    // `Child::shutdown(100 ms)`: TERM the group, give it 100 ms to go, KILL it;
    // then reap the leader (TERM, 100 ms, KILL) and KILL the group once more.
    const prev = io.swapCancelProtection(.blocked);
    if (comptime is_windows) {
        if (!waiter.done.load(.acquire)) _ = std.os.windows.ntdll.NtTerminateProcess(pid, @fromBackingInt(@intCast(@as(u32, 1))));
    } else {
        signalGroup(pid, .TERM);
        var waited: u64 = 0;
        while (groupAlive(pid)) : (waited += 10) {
            if (waited >= 100) {
                signalGroup(pid, .KILL);
                break;
            }
            sleepMs(io, 10);
        }
        if (!waiter.done.load(.acquire)) {
            signalGroup(pid, .TERM);
            var w: u64 = 0;
            while (!waiter.done.load(.acquire) and w < 100) : (w += 10) sleepMs(io, 10);
            if (!waiter.done.load(.acquire)) posix.kill(pid, .KILL) catch {};
        }
        signalGroup(pid, .KILL);
    }
    waiter_thread.join();
    mr.deinit();
    _ = io.swapCancelProtection(prev);
    if (caller_cancelled) return error.Canceled;

    var status_buf: [96]u8 = undefined;
    const why: []const u8 = reason orelse if (waiter.term) |t|
        (if (t == .exited and t.exited == 0) return null else exitStatusText(&status_buf, t))
    else
        net.ioText(waiter.err orelse error.Unexpected);
    const snap = tail.snapshot(gpa) catch null;
    defer if (snap) |s| gpa.free(s);
    if (reason == null and waiter.term != null) {
        return try fail(gpa, .install, "installer exited with {s}{s}{s}", .{ why, if (snap != null) "\n" else "", snap orelse "" });
    }
    return try fail(gpa, .install, "{s}{s}{s}", .{ why, if (snap != null) "\n" else "", snap orelse "" });
}

// ── install_harness ────────────────────────────────────────────────────────

pub const Options = struct {
    beta: bool = false,
    cancel: *const Cancel,
    installed: InstalledFn,
    deadline_ms: u64 = deadline_ms_default,
    /// This platform's pinned Antigravity archive (`acp::antigravity_archive`).
    archive_pin: ?archive.ArchivePin = archive.antigravityArchive(),
    /// `install_with_command` (the `installer-fixture` seam): run this shell
    /// script instead of the selected installer.
    script: ?[]const u8 = null,
};

fn noop(_: void) void {}

const GraffTask = struct {
    gpa: Allocator,
    io: Io,
    beta: bool,
    result: ?(Error!net.Result(graff.Outcome)) = null,

    fn run(t: *GraffTask) void {
        t.result = if (t.beta) graff.updateManagedBeta(t.gpa, t.io) else graff.updateManaged(t.gpa, t.io);
    }

    fn free(t: *GraffTask) void {
        const r = t.result orelse return;
        const v = r catch return;
        switch (v) {
            .ok => |o| o.deinit(t.gpa),
            .err => |f| f.deinit(t.gpa),
        }
        t.result = null;
    }
};

const ArchiveTask = struct {
    gpa: Allocator,
    io: Io,
    id: Id,
    pin: ?archive.ArchivePin,
    result: ?(Error!?Failure) = null,

    fn run(t: *ArchiveTask) void {
        t.result = archive.installHarness(t.gpa, t.io, t.id == .antigravity, t.pin);
    }

    fn free(t: *ArchiveTask) void {
        const r = t.result orelse return;
        const v = r catch return;
        if (v) |f| f.deinit(t.gpa);
        t.result = null;
    }
};

fn stopped(gpa: Allocator, s: net.Stop) Allocator.Error!Failure {
    return switch (s) {
        .cancelled => fail(gpa, .install, "installation cancelled", .{}),
        .timed_out, .stalled => fail(gpa, .install, "installation timed out after 15 minutes", .{}),
    };
}

fn runGraffRelease(gpa: Allocator, io: Io, opts: Options) Error!?Failure {
    var t: GraffTask = .{ .gpa = gpa, .io = io, .beta = opts.beta };
    const g = try net.guard(io, .{ .cancel = opts.cancel, .deadline_ms = opts.deadline_ms }, GraffTask.run, .{&t}, noop);
    switch (g) {
        .stopped => |s| {
            t.free();
            return try stopped(gpa, s);
        },
        .done => {},
    }
    return switch (try t.result.?) {
        .ok => |o| blk: {
            o.deinit(gpa);
            break :blk null;
        },
        .err => |f| f.rekind(.install),
    };
}

fn runArchive(gpa: Allocator, io: Io, id: Id, opts: Options) Error!?Failure {
    var t: ArchiveTask = .{ .gpa = gpa, .io = io, .id = id, .pin = opts.archive_pin };
    const g = try net.guard(io, .{ .cancel = opts.cancel, .deadline_ms = opts.deadline_ms }, ArchiveTask.run, .{&t}, noop);
    switch (g) {
        .stopped => |s| {
            t.free();
            return try stopped(gpa, s);
        },
        .done => return try t.result.?,
    }
}

/// `install::install_harness`: install `id` with its selected method, then
/// require the CLI to resolve. Only the explicit Install RPC may call this.
pub fn installHarness(gpa: Allocator, io: Io, id: Id, opts: Options) Error!?Failure {
    if (opts.beta and id != .graff) return try fail(gpa, .install, "beta updates are only available for Graff", .{});
    const method = (try selected(gpa, io, id, opts.archive_pin)) orelse
        return try fail(gpa, .install, "No supported installer or required tools available on this device", .{});
    const result: ?Failure = switch (method) {
        .graff_release => try runGraffRelease(gpa, io, opts),
        .archive => try runArchive(gpa, io, id, opts),
        else => blk: {
            var cmd = switch (try command(gpa, io, method, Platform.current())) {
                .ok => |c| c,
                .err => |f| return f,
            };
            defer cmd.deinit();
            break :blk try run(gpa, io, @ptrCast(cmd.argv), &cmd.env, opts.cancel, opts.deadline_ms);
        },
    };
    invalidateVersions(io, id);
    if (result) |f| return f;
    return postInstall(gpa, io, id, opts.installed);
}

/// `install::install_with_command`: `script` as the installer, configured
/// like any other.
pub fn installWithCommand(gpa: Allocator, io: Io, id: Id, script: []const u8, opts: Options) Error!?Failure {
    var env = try net.currentEnv(gpa);
    defer env.deinit();
    const argv = switch (try shellArgv(gpa, io, &env, script)) {
        .ok => |a| a,
        .err => |f| return f,
    };
    var cmd: Command = .{ .gpa = gpa, .argv = argv, .env = undefined };
    cmd.env = configureEnv(gpa, io, &env) catch |e| {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
        return e;
    };
    defer cmd.deinit();
    const result = try run(gpa, io, @ptrCast(cmd.argv), &cmd.env, opts.cancel, opts.deadline_ms);
    invalidateVersions(io, id);
    if (result) |f| return f;
    return postInstall(gpa, io, id, opts.installed);
}

pub const no_installer = "No supported installer or required tools available on this device";

/// The `InstallHarness` RPC up to its reply (`install_harness_with` +
/// `run_requested_install`): null on success, else the `RpcError::Failed`
/// text (owned). On success the glue enables an off-by-default harness and
/// replies with fresh `ListHarnesses` descriptors.
pub fn requestInstall(gpa: Allocator, io: Io, id: Id, opts: Options) Error!?[]u8 {
    if (!canInstallWith(gpa, io, id, opts.archive_pin)) return try gpa.dupe(u8, no_installer);
    const failure = (if (opts.script) |s|
        try installWithCommand(gpa, io, id, s, opts)
    else
        try installHarness(gpa, io, id, opts)) orelse return null;
    defer failure.deinit(gpa);
    return try failure.display(gpa);
}

// ── one install per harness (`Installations`) ──────────────────────────────

pub const already_installing = "already installing";

/// The engine's in-flight installs, shared by every RPC service of a device.
pub const Registry = struct {
    mutex: Io.Mutex = .init,
    tokens: [std.meta.tags(Id).len]?*Cancel = @splat(null),

    /// `Installations::begin`: `error.AlreadyInstalling` ("already
    /// installing") while `id` has an install in flight.
    pub fn begin(r: *Registry, gpa: Allocator, io: Io, id: Id) error{ AlreadyInstalling, OutOfMemory }!Installing {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        const slot = &r.tokens[@backingInt(id)];
        if (slot.* != null) return error.AlreadyInstalling;
        const token = try gpa.create(Cancel);
        token.* = .{};
        slot.* = token;
        return .{ .registry = r, .id = id, .token = token, .gpa = gpa, .io = io };
    }

    /// `Installations::cancel` (the `CancelInstall` RPC): no-op when idle.
    pub fn cancel(r: *Registry, io: Io, id: Id) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (r.tokens[@backingInt(id)]) |t| t.cancel();
    }
};

/// An install in flight; `end` (Rust's `Drop`) cancels its token and frees
/// the harness for the next install.
pub const Installing = struct {
    registry: *Registry,
    id: Id,
    token: *Cancel,
    gpa: Allocator,
    io: Io,

    pub fn end(self: *Installing) void {
        self.token.cancel();
        self.registry.mutex.lockUncancelable(self.io);
        self.registry.tokens[@backingInt(self.id)] = null;
        self.registry.mutex.unlock(self.io);
        self.gpa.destroy(self.token);
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    _ = net;
    _ = graff;
    _ = archive;
}

const AllHas = struct {
    yes: bool,
    missing: ?[]const u8 = null,
    pub fn has(self: AllHas, name: []const u8) bool {
        if (self.missing) |m| return !std.mem.eql(u8, m, name);
        return self.yes;
    }
};

const all_ids = [_]Id{ .claude_code, .codex, .cursor, .opencode, .pi, .grok, .hermes, .devin, .antigravity, .mock };

test "install methods follow the platform and prerequisite matrix" {
    for ([_]Platform{ .unix, .mac, .windows }) |platform| {
        for (all_ids) |id| {
            const list = methods(id, platform);
            try testing.expectEqual(id == .mock, list.len == 0);
            for (list) |m| {
                try testing.expect(available(m, platform, AllHas{ .yes = true }, true));
                try testing.expect(!available(m, platform, AllHas{ .yes = false }, false));
                switch (m) {
                    .shell => |s| {
                        try testing.expect(platform != .windows);
                        for ([_][]const u8{ "sh", "curl", s.shell }) |gone| {
                            try testing.expect(!available(m, platform, AllHas{ .yes = true, .missing = gone }, true));
                        }
                    },
                    .power_shell => try testing.expectEqual(Platform.windows, platform),
                    .brew => try testing.expectEqual(Platform.mac, platform),
                    else => {},
                }
            }
        }
    }
    try testing.expect(methods(.devin, .mac)[0] == .brew);
    try testing.expect(methods(.graff, .mac)[0] == .graff_release and methods(.graff, .mac).len == 1);
    try testing.expect(methods(.graff, .unix)[0] == .graff_release);
    try testing.expectEqual(@as(usize, 0), methods(.graff, .windows).len);
    try testing.expect(!available(.graff_release, .mac, AllHas{ .yes = true, .missing = "tar" }, true));
    try testing.expectEqualStrings("sh", methods(.codex, .unix)[0].shell.shell);
    try testing.expect(methods(.pi, .windows)[0].npm.ignore_scripts);
    // npm on Windows needs no sh.
    try testing.expect(available(methods(.pi, .windows)[0], .windows, AllHas{ .yes = true, .missing = "sh" }, false));
    try testing.expect(Id.parse("claude-code").? == .claude_code);
    try testing.expectEqualStrings("claude-code", Id.claude_code.wire());
}

fn notInstalled(_: Allocator, _: Io, _: Id) bool {
    return false;
}

test "manual commands and the missing-binary guidance" {
    const gpa = testing.allocator;
    for (all_ids) |id| {
        try testing.expectEqual(!(id == .mock or id == .antigravity), manualCommand(id) != null);
        const c = cliAndDir(id);
        try testing.expect(c.cli.len > 0 and c.dir.len > 0);
    }
    const f = (try postInstall(gpa, testing.io, .codex, notInstalled)).?;
    defer f.deinit(gpa);
    const t = try f.display(gpa);
    defer gpa.free(t);
    try testing.expectEqualStrings("adapter install failed: installer finished but `codex` was not found on PATH; open a new terminal or add ~/.local/bin or the npm global bin to PATH", t);
}

test "capture keeps a bounded, redacted tail across reads" {
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendNTimes(gpa, 'x', 200_000);
    try bytes.appendSlice(gpa, "\nAuthorization: Bearer private-token\napi_key=secret\n");
    var tail: agent_proc.StderrTail = .{};
    var cap: Capture = .{};
    // Odd read sizes so a credential straddles reads.
    var i: usize = 0;
    while (i < bytes.items.len) : (i += 1021) cap.feed(gpa, &tail, bytes.items[i..@min(i + 1021, bytes.items.len)]);
    cap.finish(gpa, &tail);
    const text = (try tail.snapshot(gpa)).?;
    defer gpa.free(text);
    try testing.expect(text.len <= 1400);
    try testing.expect(std.mem.indexOf(u8, text, "private-token") == null);
    try testing.expect(std.mem.indexOf(u8, text, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, text, "[REDACTED]") != null);
    // Carriage returns end lines too, and invalid UTF-8 is replaced.
    var t2: agent_proc.StderrTail = .{};
    var c2: Capture = .{};
    c2.feed(gpa, &t2, "progress 10%\rprogress 100%\r\xffdone");
    c2.finish(gpa, &t2);
    const s2 = (try t2.snapshot(gpa)).?;
    defer gpa.free(s2);
    try testing.expectEqualStrings("progress 10%\nprogress 100%\n\u{FFFD}done", s2);
}

// ── fixtures: a synthetic HOME and PATH of fake tools ──

fn noLogin(_: Allocator, _: Io, _: *const Environ.Map) ?[]const u8 {
    return null;
}

const Fixture = struct {
    rig: graff.Rig,
    bin: []u8,

    /// HOME under a temp dir, PATH = `<tmp>/bin` only (plus `extra_path`).
    fn init(f: *Fixture, extra_path: []const u8) !void {
        try f.rig.init();
        errdefer f.rig.deinit();
        f.bin = try f.rig.path("bin");
        try f.rig.tmp.dir.createDirPath(testing.io, "bin");
        const p = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ f.bin, extra_path });
        defer testing.allocator.free(p);
        try f.rig.env.put("PATH", p);
        login_shell_path = noLogin;
        installed_probe_path = null;
    }

    fn deinit(f: *Fixture) void {
        login_shell_path = defaultLoginShellPath;
        if (installed_probe_path) |p| testing.allocator.free(p);
        installed_probe_path = null;
        testing.allocator.free(f.bin);
        f.rig.deinit();
    }

    fn tool(f: *Fixture, name: []const u8, body: []const u8) !void {
        const sub = try std.fmt.allocPrint(testing.allocator, "bin/{s}", .{name});
        defer testing.allocator.free(sub);
        try f.rig.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = body, .flags = .{ .permissions = .executable_file } });
    }

    /// `sh` that runs the real shell: the fake tools are the only other things on PATH.
    fn shell(f: *Fixture) !void {
        try f.tool("sh", "#!/bin/sh\nexec /bin/sh \"$@\"\n");
    }

    /// The installed probe looks for `<tmp>/<sub>`.
    fn probe(f: *Fixture, sub: []const u8) !void {
        installed_probe_path = try f.rig.path(sub);
    }

    fn read(f: *Fixture, sub: []const u8) ![]u8 {
        return f.rig.tmp.dir.readFileAlloc(testing.io, sub, testing.allocator, .limited(64 * 1024));
    }
};

var installed_probe_path: ?[]u8 = null;

fn probeInstalled(_: Allocator, io: Io, _: Id) bool {
    const p = installed_probe_path orelse return false;
    return net.isFile(io, p);
}

fn testOpts(cancel: *const Cancel) Options {
    return .{ .cancel = cancel, .installed = probeInstalled, .deadline_ms = 20_000 };
}

test "command builds Rust's exact argv for shell, npm, brew and PowerShell and configures the environment" {
    if (is_windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    // No sh yet: the shell methods can't build.
    const none = try command(gpa, testing.io, codex_sh, .unix);
    defer none.err.deinit(gpa);
    try testing.expectEqualStrings("sh not found", none.err.msg);
    const no_ps = try command(gpa, testing.io, .{ .power_shell = "x" }, .windows);
    defer no_ps.err.deinit(gpa);
    try testing.expectEqualStrings("installer prerequisite is no longer available", no_ps.err.msg);

    try f.shell();
    try f.tool("npm", "#!/bin/sh\nexit 0\n");
    try f.tool("powershell", "#!/bin/sh\nexit 0\n");
    try f.rig.env.put("HARNESS_DATA_DIR", "/secret/data");
    try f.rig.env.put("CLAUDECODE", "1");
    const sh = try std.fs.path.join(gpa, &.{ f.bin, "sh" });
    defer gpa.free(sh);
    const npm = try std.fs.path.join(gpa, &.{ f.bin, "npm" });
    defer gpa.free(npm);
    const ps = try std.fs.path.join(gpa, &.{ f.bin, "powershell" });
    defer gpa.free(ps);
    const cases = [_]struct { m: Method, p: Platform, want: []const []const u8 }{
        .{ .m = codex_sh, .p = .unix, .want = &.{ sh, "-c", "curl -fsSL https://chatgpt.com/codex/install.sh | sh" } },
        .{ .m = pi_npm, .p = .unix, .want = &.{ sh, "-c", "npm install -g --ignore-scripts @earendil-works/pi-coding-agent" } },
        .{ .m = codex_npm, .p = .mac, .want = &.{ sh, "-c", "npm install -g @openai/codex" } },
        .{ .m = .brew, .p = .mac, .want = &.{ sh, "-c", "brew install --cask devin-cli" } },
        .{ .m = pi_npm, .p = .windows, .want = &.{ npm, "install", "-g", "--ignore-scripts", "@earendil-works/pi-coding-agent" } },
        .{ .m = .{ .power_shell = "irm https://claude.ai/install.ps1 | iex" }, .p = .windows, .want = &.{ ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "irm https://claude.ai/install.ps1 | iex" } },
    };
    for (cases) |c| {
        var cmd = (try command(gpa, testing.io, c.m, c.p)).ok;
        defer cmd.deinit();
        try testing.expectEqual(c.want.len, cmd.argv.len);
        for (c.want, cmd.argv) |w, a| try testing.expectEqualStrings(w, a);
        try testing.expectEqualStrings("1", cmd.env.get("CI").?);
        try testing.expectEqualStrings("1", cmd.env.get("NONINTERACTIVE").?);
        try testing.expectEqualStrings("dumb", cmd.env.get("TERM").?);
        try testing.expect(cmd.env.get("HARNESS_DATA_DIR") == null);
        try testing.expect(cmd.env.get("CLAUDECODE") == null);
        // PATH, then the login shell's (none here), then npm's directory.
        const want_path = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ f.bin, f.bin });
        defer gpa.free(want_path);
        try testing.expectEqualStrings(want_path, cmd.env.get("PATH").?);
    }
}

test "run: success, failure with a redacted tail, timeout and a pre-cancelled token" {
    if (is_windows or !std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(":/usr/bin:/bin");
    defer f.deinit();
    try f.rig.env.put("CLAUDECODE", "1");
    var env = try configureEnv(gpa, testing.io, &f.rig.env);
    defer env.deinit();
    var cancel: Cancel = .{};
    try testing.expect((try run(gpa, testing.io, &.{ "/bin/sh", "-c", "test \"$CI\" = 1 && test -z \"$CLAUDECODE\" && test ! -t 0" }, &env, &cancel, 5000)) == null);

    const failed = (try run(gpa, testing.io, &.{ "/bin/sh", "-c", "echo stdout-message; echo 'api_key=private' >&2; exit 7" }, &env, &cancel, 5000)).?;
    defer failed.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, failed.msg, "installer exited with exit status: 7\n"));
    try testing.expect(std.mem.indexOf(u8, failed.msg, "stdout-message") != null);
    try testing.expect(std.mem.indexOf(u8, failed.msg, "[REDACTED]") != null);
    try testing.expect(std.mem.indexOf(u8, failed.msg, "private") == null);

    const started = net.nowNs(testing.io);
    const slow = (try run(gpa, testing.io, &.{ "/bin/sh", "-c", "echo starting; sleep 60" }, &env, &cancel, 300)).?;
    defer slow.deinit(gpa);
    try testing.expectEqualStrings("installation timed out after 15 minutes\nstarting", slow.msg);
    try testing.expect(net.nowNs(testing.io) - started < 5 * std.time.ns_per_s);

    cancel.cancel();
    const pre = (try run(gpa, testing.io, &.{ "/bin/sh", "-c", "exit 0" }, &env, &cancel, 5000)).?;
    defer pre.deinit(gpa);
    try testing.expectEqualStrings("installation cancelled", pre.msg);
}

const Bg = struct {
    id: Id,
    opts: Options,
    result: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(b: *Bg) void {
        b.result = requestInstall(testing.allocator, testing.io, b.id, b.opts) catch |e| blk: {
            b.err = e;
            break :blk null;
        };
    }
};

fn waitForFile(f: *Fixture, sub: []const u8) !void {
    var waited: u32 = 0;
    while (!f.rig.exists(sub)) : (waited += 10) {
        if (waited > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
}

fn processGone(pid: posix.pid_t) bool {
    const r = posix.system.kill(pid, @fromBackingInt(0));
    return posix.errno(r) == .SRCH;
}

test "cancelling through the registry kills the installer's descendants; a second install is refused meanwhile" {
    if (is_windows or !std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(":/usr/bin:/bin");
    defer f.deinit();
    try f.shell();
    try f.tool("curl", "#!/bin/sh\nexit 0\n");
    try f.probe("bin/codex");
    const pidfile = try f.rig.path("pid");
    defer gpa.free(pidfile);
    const script = try std.fmt.allocPrint(gpa, "sleep 60 & echo $! > '{s}'; wait", .{pidfile});
    defer gpa.free(script);

    var registry: Registry = .{};
    var installing = try registry.begin(gpa, testing.io, .codex);
    var bg: Bg = .{ .id = .codex, .opts = testOpts(installing.token) };
    bg.opts.script = script;
    const th = try std.Thread.spawn(.{}, Bg.run, .{&bg});
    var joined = false;
    defer if (!joined) {
        registry.cancel(testing.io, .codex);
        th.join();
    };
    try waitForFile(&f, "pid");
    try testing.expectError(error.AlreadyInstalling, registry.begin(gpa, testing.io, .codex));
    // Another harness is independent.
    var other = try registry.begin(gpa, testing.io, .pi);
    other.end();
    registry.cancel(testing.io, .codex);
    th.join();
    joined = true;
    installing.end();
    try testing.expect(bg.err == null);
    defer if (bg.result) |r| gpa.free(r);
    try testing.expectEqualStrings("adapter install failed: installation cancelled", bg.result.?);
    // The backgrounded `sleep` died with its group.
    const text = try f.read("pid");
    defer gpa.free(text);
    const pid = try std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
    var waited: u32 = 0;
    while (!processGone(pid)) : (waited += 10) {
        if (waited > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    // Finished: the harness can install again.
    var again = try registry.begin(gpa, testing.io, .codex);
    again.end();
}

test "install_harness: shell installer through fake curl, npm fallback, failure text and post-install miss" {
    if (is_windows or !std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try f.shell();
    try f.probe("bin/codex");
    const log = try f.rig.path("curl.log");
    defer gpa.free(log);
    const codex = try std.fs.path.join(gpa, &.{ f.bin, "codex" });
    defer gpa.free(codex);
    // curl prints an installer that drops a codex into PATH; nothing leaves the machine.
    const curl = try std.fmt.allocPrint(gpa, "#!/bin/sh\necho \"$@\" >> '{s}'\nprintf '%s\\n' \"printf '#!/bin/sh\\\\necho codex-cli 1.0.0\\\\n' > '{s}'\" \"/bin/chmod +x '{s}'\"\n", .{ log, codex, codex });
    defer gpa.free(curl);
    try f.tool("curl", curl);
    var cancel: Cancel = .{};
    const ok = try requestInstall(gpa, testing.io, .codex, testOpts(&cancel));
    defer if (ok) |m| gpa.free(m);
    if (ok) |m| std.debug.print("unexpected: {s}\n", .{m});
    try testing.expect(ok == null);
    const logged = try f.read("curl.log");
    defer gpa.free(logged);
    try testing.expectEqualStrings("-fsSL https://chatgpt.com/codex/install.sh\n", logged);
    try testing.expect(f.rig.exists("bin/codex"));

    // Without curl, npm installs it: `sh -c "npm install -g @openai/codex"`.
    try f.rig.tmp.dir.deleteFile(testing.io, "bin/curl");
    try f.rig.tmp.dir.deleteFile(testing.io, "bin/codex");
    const npm_log = try f.rig.path("npm.log");
    defer gpa.free(npm_log);
    const npm = try std.fmt.allocPrint(gpa, "#!/bin/sh\necho \"$@\" >> '{s}'\nprintf '#!/bin/sh\\n' > '{s}'\n/bin/chmod +x '{s}'\n", .{ npm_log, codex, codex });
    defer gpa.free(npm);
    try f.tool("npm", npm);
    const via_npm = try requestInstall(gpa, testing.io, .codex, testOpts(&cancel));
    defer if (via_npm) |m| gpa.free(m);
    try testing.expect(via_npm == null);
    const npm_logged = try f.read("npm.log");
    defer gpa.free(npm_logged);
    try testing.expectEqualStrings("install -g @openai/codex\n", npm_logged);

    // An installer that fails: its output (redacted) is the error.
    try f.rig.tmp.dir.deleteFile(testing.io, "bin/codex");
    try f.tool("npm", "#!/bin/sh\necho fixture failure\necho 'api_key=private' >&2\nexit 3\n");
    const failed = (try requestInstall(gpa, testing.io, .codex, testOpts(&cancel))).?;
    defer gpa.free(failed);
    try testing.expect(std.mem.startsWith(u8, failed, "adapter install failed: installer exited with exit status: 3\n"));
    try testing.expect(std.mem.indexOf(u8, failed, "fixture failure") != null);
    try testing.expect(std.mem.indexOf(u8, failed, "[REDACTED]") != null);
    try testing.expect(std.mem.indexOf(u8, failed, "private") == null);

    // An installer that succeeds without providing the CLI.
    try f.tool("npm", "#!/bin/sh\nexit 0\n");
    const missed = (try requestInstall(gpa, testing.io, .codex, testOpts(&cancel))).?;
    defer gpa.free(missed);
    try testing.expectEqualStrings("adapter install failed: installer finished but `codex` was not found on PATH; open a new terminal or add ~/.local/bin or the npm global bin to PATH", missed);
}

test "install_harness: missing prerequisites, beta outside graff, and a timed-out installer" {
    if (is_windows or !std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    var cancel: Cancel = .{};
    const none = (try requestInstall(gpa, testing.io, .codex, testOpts(&cancel))).?;
    defer gpa.free(none);
    try testing.expectEqualStrings("No supported installer or required tools available on this device", none);
    const direct = (try installHarness(gpa, testing.io, .codex, testOpts(&cancel))).?;
    defer direct.deinit(gpa);
    try testing.expectEqualStrings("No supported installer or required tools available on this device", direct.msg);
    const mock = (try requestInstall(gpa, testing.io, .mock, testOpts(&cancel))).?;
    defer gpa.free(mock);
    try testing.expectEqualStrings(no_installer, mock);

    try f.shell();
    try f.tool("curl", "#!/bin/sh\necho '/bin/sleep 60'\n");
    const beta = (try installHarness(gpa, testing.io, .codex, .{ .beta = true, .cancel = &cancel, .installed = probeInstalled })).?;
    defer beta.deinit(gpa);
    const beta_text = try beta.display(gpa);
    defer gpa.free(beta_text);
    try testing.expectEqualStrings("adapter install failed: beta updates are only available for Graff", beta_text);

    var opts = testOpts(&cancel);
    opts.deadline_ms = 300;
    const slow = (try requestInstall(gpa, testing.io, .codex, opts)).?;
    defer gpa.free(slow);
    try testing.expectEqualStrings("adapter install failed: installation timed out after 15 minutes", slow);
}

test "install_harness: a cancelled graff download places nothing; the verified release installs" {
    if (is_windows or !std.process.can_spawn or graff.assetName() == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(":/usr/bin:/bin");
    defer f.deinit();
    try f.probe("home/.harness/bin/graff");
    // A tarball built from a fake graff.
    const asset = graff.assetName().?;
    const dir_name = asset[0 .. asset.len - ".tar.gz".len];
    const sub = try std.fmt.allocPrint(gpa, "stage/{s}/graff", .{dir_name});
    defer gpa.free(sub);
    try f.rig.tmp.dir.createDirPath(testing.io, std.fs.path.dirname(sub).?);
    try f.rig.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "#!/bin/sh\necho 'graff 0.0.302.7'\n", .flags = .{ .permissions = .executable_file } });
    const stage = try f.rig.path("stage");
    defer gpa.free(stage);
    const out = try f.rig.path("g.tar.gz");
    defer gpa.free(out);
    const res = try std.process.run(gpa, testing.io, .{ .argv = &.{ "/usr/bin/tar", "-czf", out, "-C", stage, dir_name }, .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } } });
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    const tarball = try f.rig.tmp.dir.readFileAlloc(testing.io, "g.tar.gz", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(tarball);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const sums = try std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ &std.fmt.bytesToHex(digest, .lower), asset });
    defer gpa.free(sums);
    const asset_path = try std.fmt.allocPrint(gpa, "/dl/v0.0.302.7/{s}", .{asset});
    defer gpa.free(asset_path);
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{
        .{ .path = "/api/releases/latest", .body = "{\"tag_name\":\"v0.0.302.7\"}" },
        .{ .path = "/dl/v0.0.302.7/SHA256SUMS", .body = sums },
        .{ .path = asset_path, .body = tarball, .stall_after = 16, .stall_ms = 10_000 },
    });
    defer srv.shutdown();
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    graff.api_base = try std.fmt.bufPrint(&b1, "http://127.0.0.1:{d}/api", .{srv.port});
    graff.releases_base = try std.fmt.bufPrint(&b2, "http://127.0.0.1:{d}/dl", .{srv.port});
    defer {
        graff.releases_base = "https://github.com/justrach/codegraff/releases/download";
        graff.api_base = "https://api.github.com/repos/justrach/codegraff";
    }

    // The tarball stalls mid-body; CancelInstall stops it and nothing lands.
    var registry: Registry = .{};
    var installing = try registry.begin(gpa, testing.io, .graff);
    var bg: Bg = .{ .id = .graff, .opts = testOpts(installing.token) };
    const th = try std.Thread.spawn(.{}, Bg.run, .{&bg});
    var waited: u32 = 0;
    while (srv.hitCount(asset_path) == 0) : (waited += 10) {
        if (waited > 10_000) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    const started = net.nowNs(testing.io);
    registry.cancel(testing.io, .graff);
    th.join();
    installing.end();
    defer if (bg.result) |r| gpa.free(r);
    try testing.expectEqualStrings("adapter install failed: installation cancelled", bg.result.?);
    try testing.expect(net.nowNs(testing.io) - started < 5 * std.time.ns_per_s);
    try testing.expect(!f.rig.exists("home/.harness/bin/graff"));

    // The same release served whole installs, and the CLI resolves after.
    var full: net.TestServer = undefined;
    try full.start(testing.io, &.{
        .{ .path = "/api/releases/latest", .body = "{\"tag_name\":\"v0.0.302.7\"}" },
        .{ .path = "/dl/v0.0.302.7/SHA256SUMS", .body = sums },
        .{ .path = asset_path, .body = tarball },
    });
    defer full.shutdown();
    graff.api_base = try std.fmt.bufPrint(&b1, "http://127.0.0.1:{d}/api", .{full.port});
    graff.releases_base = try std.fmt.bufPrint(&b2, "http://127.0.0.1:{d}/dl", .{full.port});
    var cancel: Cancel = .{};
    const ok = try requestInstall(gpa, testing.io, .graff, testOpts(&cancel));
    defer if (ok) |m| gpa.free(m);
    if (ok) |m| std.debug.print("unexpected: {s}\n", .{m});
    try testing.expect(ok == null);
    try testing.expect(f.rig.exists("home/.harness/bin/graff"));
}

test "install_harness: antigravity from a loopback archive, a wrong pin, and no pin" {
    if (is_windows or !std.process.can_spawn or graff.assetName() == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(":/usr/bin:/bin");
    defer f.deinit();
    const adapters = try f.rig.path("adapters");
    defer gpa.free(adapters);
    try f.rig.env.put("HARNESS_ADAPTERS_DIR", adapters);

    const zip = try archive.testZip(gpa, &.{.{ .name = "agy_acp_server.par", .data = "#!/bin/sh\n" }});
    defer gpa.free(zip);
    const sha = archive.sha512Hex(zip);
    var srv: net.TestServer = undefined;
    try srv.start(testing.io, &.{.{ .path = "/agy.zip", .body = zip }});
    defer srv.shutdown();
    const url = try srv.url(gpa, "/agy.zip");
    defer gpa.free(url);
    try f.probe("adapters/antigravity-acp/1.2.1/agy_acp_server.par");
    var cancel: Cancel = .{};
    var opts = testOpts(&cancel);
    opts.archive_pin = .{ .name = "antigravity-acp", .version = "1.2.1", .url = url, .entry = "agy_acp_server.par", .sha512 = &sha };
    const ok = try requestInstall(gpa, testing.io, .antigravity, opts);
    defer if (ok) |m| gpa.free(m);
    try testing.expect(ok == null);

    // A wrong pin: rejected, nothing placed.
    try f.rig.tmp.dir.deleteTree(testing.io, "adapters");
    const wrong = archive.sha512Hex("other");
    opts.archive_pin.?.sha512 = &wrong;
    const bad = (try requestInstall(gpa, testing.io, .antigravity, opts)).?;
    defer gpa.free(bad);
    try testing.expect(std.mem.startsWith(u8, bad, "adapter install failed: download of the Antigravity ACP server ("));
    try testing.expect(std.mem.indexOf(u8, bad, "SHA-512 mismatch") != null);
    try testing.expect(!f.rig.exists("adapters/antigravity-acp"));

    // No pin on this platform: Antigravity can't install.
    opts.archive_pin = null;
    const unpinned = (try requestInstall(gpa, testing.io, .antigravity, opts)).?;
    defer gpa.free(unpinned);
    try testing.expectEqualStrings(no_installer, unpinned);
}
