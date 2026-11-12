//! Agent CLI discovery, ported from `crates/harness/src/executable.rs`
//! (`find_on_paths`, node version manager bins), `shell_env.rs` (the login
//! shell's PATH snapshot), each harness's `installed()` probe
//! (`claude/mod.rs`, `codex/mod.rs`, `cursor/mod.rs`, `pi/mod.rs`,
//! `opencode/mod.rs`, `acp/mod.rs`, `archive_install.rs`) and the installer
//! availability rules of `install.rs` (`methods`, `available`, `can_install`).
//!
//! Probes never spawn an agent: they check files only. The one spawn is the
//! login shell's PATH snapshot, captured once per process (as Rust caches it).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");

pub const HarnessId = enum {
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
    pub fn wire(id: HarnessId) []const u8 {
        return switch (id) {
            .mock => "mock",
            .graff => "graff",
            .claude_code => "claude-code",
            .codex => "codex",
            .cursor => "cursor",
            .devin => "devin",
            .grok => "grok",
            .hermes => "hermes",
            .pi => "pi",
            .opencode => "opencode",
            .antigravity => "antigravity",
            .exo => "exo",
        };
    }

    /// `{id:?}` (Rust's Debug), used in error text.
    pub fn debugName(id: HarnessId) []const u8 {
        return switch (id) {
            .mock => "Mock",
            .graff => "Graff",
            .claude_code => "ClaudeCode",
            .codex => "Codex",
            .cursor => "Cursor",
            .devin => "Devin",
            .grok => "Grok",
            .hermes => "Hermes",
            .pi => "Pi",
            .opencode => "Opencode",
            .antigravity => "Antigravity",
            .exo => "Exo",
        };
    }

    pub fn parse(text: []const u8) ?HarnessId {
        for (std.meta.tags(HarnessId)) |id| {
            if (std.mem.eql(u8, text, id.wire())) return id;
        }
        return null;
    }
};

/// serde's error for an unknown `HarnessId` variant.
pub fn unknownVariantText(text: []const u8) []const u8 {
    return common.errText(
        "unknown variant `{s}`, expected one of `claude-code`, `codex`, `cursor`, `devin`, `grok`, `hermes`, `graff`, `pi`, `opencode`, `antigravity`, `exo`, `mock`",
        .{text},
    );
}

// ── login shell PATH (shell_env.rs) ────────────────────────────────────────

const begin_marker = "__HARNESS_SHELL_ENV_BEGIN__";
const end_marker = "__HARNESS_SHELL_ENV_END__";

var shell_cache_mutex: std.Io.Mutex = .init;
var shell_cache_done = false;
var shell_cache: ?[]u8 = null;

/// `parse_snapshot_path`: the PATH between the last begin marker and the end marker.
pub fn parseSnapshotPath(output: []const u8) ?[]const u8 {
    const begin = std.mem.lastIndexOf(u8, output, begin_marker) orelse return null;
    const after = output[begin + begin_marker.len ..];
    const end = std.mem.indexOf(u8, after, end_marker) orelse return null;
    var lines = std.mem.splitScalar(u8, after[0..end], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "PATH=") and line.len > "PATH=".len) return line["PATH=".len..];
    }
    return null;
}

fn userShell(io: std.Io) ?[]const u8 {
    var candidates: [4][]const u8 = undefined;
    var n: usize = 0;
    if (common.getenvNonEmpty("SHELL")) |s| {
        candidates[n] = s;
        n += 1;
    }
    for ([_][]const u8{ "/bin/zsh", "/bin/bash", "/bin/sh" }) |c| {
        candidates[n] = c;
        n += 1;
    }
    for (candidates[0..n]) |p| {
        const name = std.fs.path.basename(p);
        if (name.len == 0 or std.mem.eql(u8, name, "nologin") or std.mem.eql(u8, name, "false")) continue;
        if (common.isRunnable(io, p)) return p;
    }
    return null;
}

fn captureLoginShellPath(gpa: Allocator, io: std.Io) ?[]u8 {
    if (comptime builtin.os.tag == .windows) return null;
    if (common.getenvNonEmpty("HARNESS_NO_LOGIN_SHELL") != null) return null;
    const shell = userShell(io) orelse return null;
    const name = std.fs.path.basename(shell);
    const script = "echo " ++ begin_marker ++ "; env; echo " ++ end_marker;
    const attempts: []const []const []const u8 = if (std.mem.eql(u8, name, "csh") or std.mem.eql(u8, name, "tcsh"))
        &.{&.{"-c"}}
    else if (std.mem.eql(u8, name, "fish"))
        &.{ &.{ "-l", "-c" }, &.{"-c"} }
    else
        &.{ &.{ "-l", "-i", "-c" }, &.{ "-l", "-c" } };
    for (attempts) |flags| {
        var argv: [8][]const u8 = undefined;
        var k: usize = 0;
        for ([_][]const u8{ "/usr/bin/env", "HARNESS_RESOLVING_ENVIRONMENT=1", "TERM=dumb", shell }) |a| {
            argv[k] = a;
            k += 1;
        }
        for (flags) |f| {
            argv[k] = f;
            k += 1;
        }
        argv[k] = script;
        k += 1;
        var r = common.run(gpa, io, argv[0..k], null, 5_000) catch continue;
        defer r.deinit(gpa);
        if (parseSnapshotPath(r.stdout)) |path| return gpa.dupe(u8, path) catch null;
    }
    return null;
}

/// `shell_env::login_shell_path`. Cached for the process; a test environment
/// is never cached (and disables it with `HARNESS_NO_LOGIN_SHELL`).
pub fn loginShellPath(gpa: Allocator, io: std.Io) ?[]u8 {
    if (common.env_override != null) return captureLoginShellPath(gpa, io);
    shell_cache_mutex.lockUncancelable(io);
    defer shell_cache_mutex.unlock(io);
    if (!shell_cache_done) {
        shell_cache = captureLoginShellPath(std.heap.page_allocator, io);
        shell_cache_done = true;
    }
    return if (shell_cache) |p| gpa.dupe(u8, p) catch null else null;
}

// ── find_on_paths (executable.rs) ──────────────────────────────────────────

/// `node_version_manager_bins_with` (Unix branch).
fn appendNodeManagerBins(gpa: Allocator, io: std.Io, out: *std.ArrayList([]u8)) !void {
    if (common.getenvNonEmpty("FNM_DIR")) |fnm| try out.append(gpa, try std.fs.path.join(gpa, &.{ fnm, "aliases", "default", "bin" }));
    const home = common.homeDir() orelse return;
    const fnm_roots = [_][]const []const u8{
        &.{ ".local", "share", "fnm" },
        &.{ "Library", "Application Support", "fnm" },
        &.{".fnm"},
    };
    for (fnm_roots) |parts| {
        var segs: std.ArrayList([]const u8) = .empty;
        defer segs.deinit(gpa);
        try segs.append(gpa, home);
        try segs.appendSlice(gpa, parts);
        try segs.appendSlice(gpa, &.{ "aliases", "default", "bin" });
        try out.append(gpa, try std.fs.path.join(gpa, segs.items));
    }
    try out.append(gpa, try std.fs.path.join(gpa, &.{ home, ".volta", "bin" }));
    try out.append(gpa, try std.fs.path.join(gpa, &.{ home, ".bun", "bin" }));
    try out.append(gpa, try std.fs.path.join(gpa, &.{ home, "Library", "pnpm" }));
    try out.append(gpa, try std.fs.path.join(gpa, &.{ home, ".local", "share", "pnpm" }));
    const nvm = try std.fs.path.join(gpa, &.{ home, ".nvm", "versions", "node" });
    defer gpa.free(nvm);
    var dir = std.Io.Dir.cwd().openDir(io, nvm, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var versions: std.ArrayList([]u8) = .empty;
    defer versions.deinit(gpa);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        try versions.append(gpa, try std.fs.path.join(gpa, &.{ nvm, entry.name, "bin" }));
    }
    std.mem.sort([]u8, versions.items, {}, struct {
        fn gt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.gt);
    try out.appendSlice(gpa, versions.items);
}

fn appendPathDirs(gpa: Allocator, path: []const u8, exe: []const u8, out: *std.ArrayList([]u8)) !void {
    var dirs = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        try out.append(gpa, try std.fs.path.join(gpa, &.{ dir, exe }));
    }
}

/// `find_on_paths(exe, extra)`: PATH, the login shell's PATH, `extra` file
/// paths, then node version manager bins; among the runnable candidates,
/// the PATH-preferred one unless a later one reports a newer version
/// (`newest_candidate`, harness_version.zig).
pub fn findOnPaths(gpa: Allocator, io: std.Io, exe: []const u8, extra: []const []const u8) !?[]u8 {
    var candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (candidates.items) |c| gpa.free(c);
        candidates.deinit(gpa);
    }
    if (common.getenv("PATH")) |path| try appendPathDirs(gpa, path, exe, &candidates);
    if (loginShellPath(gpa, io)) |shell_path| {
        defer gpa.free(shell_path);
        try appendPathDirs(gpa, shell_path, exe, &candidates);
    }
    for (extra) |e| try candidates.append(gpa, try gpa.dupe(u8, e));
    var bins: std.ArrayList([]u8) = .empty;
    defer {
        for (bins.items) |b| gpa.free(b);
        bins.deinit(gpa);
    }
    try appendNodeManagerBins(gpa, io, &bins);
    for (bins.items) |b| try candidates.append(gpa, try std.fs.path.join(gpa, &.{ b, exe }));
    var runnable: std.ArrayList([]const u8) = .empty;
    defer runnable.deinit(gpa);
    for (candidates.items) |c| if (common.isRunnable(io, c)) try runnable.append(gpa, c);
    return @import("harness_version.zig").newestCandidate(gpa, io, exe, runnable.items);
}

pub fn hasExe(gpa: Allocator, io: std.Io, exe: []const u8) bool {
    const found = findOnPaths(gpa, io, exe, &.{}) catch return false;
    if (found) |f| {
        gpa.free(f);
        return true;
    }
    return false;
}

// ── installed() probes ─────────────────────────────────────────────────────

/// Tests root the fixed system install dirs (`/opt/homebrew/bin`, …) in a
/// temporary directory so the machine's own CLIs never leak in.
pub var system_prefix: []const u8 = "";

const Probe = struct {
    env_override: ?[]const u8,
    cli: []const u8,
    /// Home-relative extra install paths.
    home_extra: []const []const []const u8,
    abs_extra: []const []const u8,
};

fn probeFor(id: HarnessId) Probe {
    return switch (id) {
        .claude_code => .{ .env_override = "CLAUDE_CODE_EXECUTABLE", .cli = "claude", .home_extra = &.{ &.{ ".claude", "local", "claude" }, &.{ ".local", "bin", "claude" } }, .abs_extra = &.{ "/opt/homebrew/bin/claude", "/usr/local/bin/claude" } },
        .codex => .{ .env_override = "CODEX_EXECUTABLE", .cli = "codex", .home_extra = &.{ &.{ ".local", "bin", "codex" }, &.{ ".codex", "bin", "codex" }, &.{ ".npm-global", "bin", "codex" } }, .abs_extra = &.{ "/opt/homebrew/bin/codex", "/usr/local/bin/codex" } },
        .cursor => .{ .env_override = null, .cli = "cursor-agent", .home_extra = &.{ &.{ ".local", "bin", "cursor-agent" }, &.{ ".cursor", "bin", "cursor-agent" } }, .abs_extra = &.{} },
        .devin => .{ .env_override = "DEVIN_EXECUTABLE", .cli = "devin", .home_extra = &.{&.{ ".local", "bin", "devin" }}, .abs_extra = &.{ "/opt/homebrew/bin/devin", "/usr/local/bin/devin" } },
        .grok => .{ .env_override = "GROK_EXECUTABLE", .cli = "grok", .home_extra = &.{ &.{ ".local", "bin", "grok" }, &.{ ".grok", "bin", "grok" }, &.{ ".npm-global", "bin", "grok" } }, .abs_extra = &.{ "/opt/homebrew/bin/grok", "/usr/local/bin/grok" } },
        .hermes => .{ .env_override = "HERMES_EXECUTABLE", .cli = "hermes", .home_extra = &.{ &.{ ".local", "bin", "hermes" }, &.{ ".hermes", "bin", "hermes" } }, .abs_extra = &.{ "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes" } },
        .graff => .{ .env_override = "GRAFF_EXECUTABLE", .cli = "graff", .home_extra = &.{ &.{ ".harness", "bin", "graff" }, &.{ ".local", "bin", "graff" } }, .abs_extra = &.{ "/opt/homebrew/bin/graff", "/usr/local/bin/graff" } },
        .pi => .{ .env_override = "PI_EXECUTABLE", .cli = "pi", .home_extra = &.{ &.{ ".local", "bin", "pi" }, &.{ ".npm-global", "bin", "pi" } }, .abs_extra = &.{ "/opt/homebrew/bin/pi", "/usr/local/bin/pi" } },
        .opencode => .{ .env_override = "OPENCODE_EXECUTABLE", .cli = "opencode", .home_extra = &.{ &.{ ".opencode", "bin", "opencode" }, &.{ ".local", "bin", "opencode" }, &.{ ".bun", "bin", "opencode" }, &.{ ".npm-global", "bin", "opencode" } }, .abs_extra = &.{ "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode" } },
        .antigravity => .{ .env_override = "ANTIGRAVITY_ACP_EXECUTABLE", .cli = "agy_acp_server", .home_extra = &.{}, .abs_extra = &.{} },
        .exo => .{ .env_override = "EXO_ACP_EXECUTABLE", .cli = "exo-cli", .home_extra = &.{ &.{ "bin", "exo-cli" }, &.{ ".local", "bin", "exo-cli" } }, .abs_extra = &.{} },
        .mock => .{ .env_override = null, .cli = "mock", .home_extra = &.{}, .abs_extra = &.{} },
    };
}

fn extraPaths(gpa: Allocator, p: Probe, home: ?[]const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |x| gpa.free(x);
        out.deinit(gpa);
    }
    if (home) |h| for (p.home_extra) |parts| {
        var segs: std.ArrayList([]const u8) = .empty;
        defer segs.deinit(gpa);
        try segs.append(gpa, h);
        try segs.appendSlice(gpa, parts);
        try out.append(gpa, try std.fs.path.join(gpa, segs.items));
    };
    for (p.abs_extra) |a| try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ system_prefix, a }));
    return out;
}

/// `graff_install_paths()`: the managed copy (when a file), the bundled
/// copy, `~/.local/bin`, then the system install dirs.
fn graffExtras(gpa: Allocator, io: std.Io) !std.ArrayList([]u8) {
    const hv = @import("harness_version.zig");
    const home = common.homeDir();
    const managed = if (home) |h| try std.fs.path.join(gpa, &.{ h, ".harness", "bin", "graff" }) else null;
    defer if (managed) |m| gpa.free(m);
    const bundled = hv.bundledGraff(gpa, io);
    defer if (bundled) |b| gpa.free(b);
    return hv.graffInstallPaths(gpa, home, if (managed) |m| common.isFile(io, m) else false, bundled, system_prefix);
}

fn findWithExtras(gpa: Allocator, io: std.Io, exe: []const u8, p: Probe, home: ?[]const u8) !bool {
    var extra = try extraPaths(gpa, p, home);
    defer {
        for (extra.items) |x| gpa.free(x);
        extra.deinit(gpa);
    }
    // The managed graff (`~/.harness/bin/graff`) only counts when it is a file.
    const found = try findOnPaths(gpa, io, exe, @ptrCast(extra.items));
    if (found) |f| {
        gpa.free(f);
        return true;
    }
    return false;
}

/// The CLI a harness launches: its validated `*_EXECUTABLE` override, else the
/// first runnable candidate of `find_on_paths(cli, install dirs)`.
pub fn resolveCli(gpa: Allocator, io: std.Io, id: HarnessId) !?[]u8 {
    const p = probeFor(id);
    if (p.env_override) |var_name| {
        const value = if (id == .pi) common.getenv(var_name) else common.getenvNonEmpty(var_name);
        if (value) |v| return if (common.isFile(io, v)) try gpa.dupe(u8, v) else null;
    }
    // graff also lives in the app-managed and bundled copies
    // (`graff_install_paths`).
    var extra = if (id == .graff) try graffExtras(gpa, io) else try extraPaths(gpa, p, common.homeDir());
    defer {
        for (extra.items) |x| gpa.free(x);
        extra.deinit(gpa);
    }
    return findOnPaths(gpa, io, p.cli, @ptrCast(extra.items));
}

/// `crate::adapter_install::adapters_root` (Unix).
pub fn adaptersRoot(gpa: Allocator) !?[]u8 {
    if (common.getenvNonEmpty("HARNESS_ADAPTERS_DIR")) |d| return try gpa.dupe(u8, d);
    if (common.getenvNonEmpty("HARNESS_DATA_DIR")) |d| return try std.fs.path.join(gpa, &.{ d, "adapters" });
    const home = common.homeDir() orelse return null;
    return try std.fs.path.join(gpa, &.{ home, ".harness", "adapters" });
}

/// The antigravity ACP archive pinned for this platform (`antigravity_archive`).
pub const ArchivePin = struct { name: []const u8, version: []const u8, entry: []const u8, sha512: []const u8 };

pub fn antigravityArchive() ?ArchivePin {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    const sha: []const u8 = if (os == .macos and arch == .aarch64)
        "c0049b1f423ffdf0e6a79a6caa104a27b6368522b1eb2c67d9eeed1424af2a07898a66b475b0824a734a0bdd01264473a7d67d1550357a8607fb136507b0afae"
    else if (os == .linux and arch == .x86_64)
        "dd9b778479dbfc753661d63ff66a3235e7249e8451af12adc11d26509172de1ff50452c3af57684009bb944314bd587b2be200bab17df743a2706ce4067d6731"
    else if (os == .linux and arch == .aarch64)
        "d907f928609ff2232bfeeec9177fe925d3e02e1773295cfb30097e5c4e134758021bff916ba5ae2e2e2ff81d374564349f268f92a4577bc88370537011473e29"
    else if (os == .windows and arch == .x86_64)
        "515c0af1d00164ca3a608f4ef04caa4ef8045ffa94a3ef2405c9b43c87c7a74c9f71a232c81917353dc3f2d49b69230f935d2ebfa28f7ee021b5aa088f3fa554"
    else if (os == .windows and arch == .aarch64)
        "ae3f4c2d2255c03d4d9548e10a760a107c41c99e4c6c710bd82758791e4fd497b75bdef0cd2cfd7fdff1a5bb2fee7afd81f5d043da92ab52dce5505dd2aa58b3"
    else
        return null;
    return .{ .name = "antigravity-acp", .version = "1.2.1", .entry = if (os == .windows) "agy_acp_server.exe" else "agy_acp_server.par", .sha512 = sha };
}

/// `archive_install::installed_entry`: the OK marker holds the pin's sha512.
fn archiveInstalled(gpa: Allocator, io: std.Io, pin: ArchivePin) !bool {
    const root = (try adaptersRoot(gpa)) orelse return false;
    defer gpa.free(root);
    const marker = try std.fs.path.join(gpa, &.{ root, pin.name, pin.version, ".harness-install-ok" });
    defer gpa.free(marker);
    const text = std.Io.Dir.cwd().readFileAlloc(io, marker, gpa, .limited(4096)) catch return false;
    defer gpa.free(text);
    if (!std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), pin.sha512)) return false;
    const entry = try std.fs.path.join(gpa, &.{ root, pin.name, pin.version, pin.entry });
    defer gpa.free(entry);
    return common.isFile(io, entry);
}

/// Each harness's `installed()`.
pub fn installed(gpa: Allocator, io: std.Io, id: HarnessId) !bool {
    // MockHarness keeps the trait default: always installed.
    if (id == .mock) return true;
    const p = probeFor(id);
    if (p.env_override) |var_name| {
        // Pi reads PI_EXECUTABLE even when empty; the others filter empties.
        const value = if (id == .pi) common.getenv(var_name) else common.getenvNonEmpty(var_name);
        if (value) |v| return common.isFile(io, v);
    }
    const home = common.homeDir();
    switch (id) {
        .antigravity => {
            if (antigravityArchive()) |pin| if (try archiveInstalled(gpa, io, pin)) return true;
            // `find_server`: the server on PATH, then its `.par`/`.exe` names.
            for ([_][]const u8{ "agy_acp_server", "agy_acp_server.par", "agy_acp_server.exe" }) |name| {
                if (hasExe(gpa, io, name)) return true;
            }
            return false;
        },
        .exo => {
            // The bridge is `harness exo-acp`, served only by the Rust engine
            // binary named `harness`; this engine has no bridge, so the server
            // lookup is PATH alone.
            if (!hasExe(gpa, io, "harness-exo-acp")) return false;
            const socket = if (common.getenvNonEmpty("EXO_AGENT_CLI_SOCKET")) |s|
                try gpa.dupe(u8, s)
            else if (home) |h|
                try std.fs.path.join(gpa, &.{ h, ".exo", "agent-cli.sock" })
            else
                null;
            defer if (socket) |s| gpa.free(s);
            if (socket) |s| if (common.pathExists(io, s)) return true;
            return findWithExtras(gpa, io, p.cli, p, home);
        },
        .pi => return findWithExtras(gpa, io, p.cli, p, home orelse "."),
        else => return findWithExtras(gpa, io, p.cli, p, home),
    }
}

// ── installer availability (install.rs) ────────────────────────────────────

pub const Method = union(enum) {
    archive,
    graff_release,
    shell: struct { script: []const u8, shell: []const u8 },
    npm: struct { package: []const u8, ignore_scripts: bool },
    brew,
};

/// `methods(id, platform)` for this (Unix) platform.
pub fn methods(id: HarnessId) []const Method {
    const mac = builtin.os.tag == .macos;
    return switch (id) {
        .mock, .exo => &.{},
        .graff => &.{.graff_release},
        .antigravity => &.{.archive},
        .claude_code => &.{.{ .shell = .{ .script = "curl -fsSL https://claude.ai/install.sh | bash", .shell = "bash" } }},
        .codex => &.{ .{ .shell = .{ .script = "curl -fsSL https://chatgpt.com/codex/install.sh | sh", .shell = "sh" } }, .{ .npm = .{ .package = "@openai/codex", .ignore_scripts = false } } },
        .cursor => &.{.{ .shell = .{ .script = "curl https://cursor.com/install -fsS | bash", .shell = "bash" } }},
        .opencode => &.{ .{ .shell = .{ .script = "curl -fsSL https://opencode.ai/install | bash", .shell = "bash" } }, .{ .npm = .{ .package = "@opencode/cli", .ignore_scripts = false } } },
        .pi => &.{ .{ .shell = .{ .script = "curl -fsSL https://pi.dev/install.sh | sh", .shell = "sh" } }, .{ .npm = .{ .package = "@earendil-works/pi-coding-agent", .ignore_scripts = true } } },
        .grok => &.{ .{ .shell = .{ .script = "curl -fsSL https://x.ai/cli/install.sh | bash", .shell = "bash" } }, .{ .npm = .{ .package = "@xai-official/grok", .ignore_scripts = false } } },
        .hermes => &.{.{ .shell = .{ .script = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash", .shell = "bash" } }},
        .devin => if (mac)
            &.{ .brew, .{ .shell = .{ .script = "curl -fsSL https://cli.devin.ai/install.sh | bash", .shell = "bash" } } }
        else
            &.{.{ .shell = .{ .script = "curl -fsSL https://cli.devin.ai/install.sh | bash", .shell = "bash" } }},
    };
}

/// `available(method, platform, has, archive)`.
pub fn available(method: Method, ctx: anytype, archive: bool) bool {
    return switch (method) {
        .archive => archive,
        .graff_release => ctx.has("tar"),
        .shell => |s| ctx.has("sh") and ctx.has("curl") and ctx.has(s.shell),
        .npm => ctx.has("npm") and ctx.has("sh"),
        .brew => ctx.has("brew") and ctx.has("sh"),
    };
}

const LiveHas = struct {
    gpa: Allocator,
    io: std.Io,
    fn has(self: LiveHas, name: []const u8) bool {
        return hasExe(self.gpa, self.io, name);
    }
};

/// `install::can_install`.
pub fn canInstall(gpa: Allocator, io: std.Io, id: HarnessId) bool {
    const ctx: LiveHas = .{ .gpa = gpa, .io = io };
    const archive = id == .antigravity and antigravityArchive() != null;
    for (methods(id)) |m| {
        if (available(m, ctx, archive)) return true;
    }
    return false;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeExe(io: std.Io, dir: std.Io.Dir, sub: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub, .data = "#!/bin/sh\nexit 0\n", .flags = .{ .permissions = .executable_file } });
}

test "rpcw_executables parses the login shell snapshot like shell_env.rs" {
    try testing.expectEqualStrings("/a:/b", parseSnapshotPath("noise\n" ++ begin_marker ++ "\nHOME=/h\nPATH=/a:/b\r\n" ++ end_marker ++ "\n").?);
    try testing.expect(parseSnapshotPath(begin_marker ++ "\nPATH=\n" ++ end_marker) == null);
    try testing.expect(parseSnapshotPath("PATH=/x\n") == null);
    try testing.expectEqualStrings("/late", parseSnapshotPath(begin_marker ++ "\nPATH=/early\n" ++ begin_marker ++ "\nPATH=/late\n" ++ end_marker).?);
}

test "rpcw_executables detects CLIs on PATH, install dirs, overrides and node managers" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try common.tmpPath(gpa, io, &tmp);
    defer gpa.free(base);
    const home = try std.fs.path.join(gpa, &.{ base, "home" });
    defer gpa.free(home);
    const bin = try std.fs.path.join(gpa, &.{ base, "bin" });
    defer gpa.free(bin);
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "bin");
    var env = try common.TestEnv.init(gpa, home);
    defer env.deinit();
    try env.map.put("PATH", bin);
    try env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
    env.install();
    system_prefix = base;
    defer system_prefix = "";

    for ([_]HarnessId{ .claude_code, .codex, .cursor, .opencode, .pi, .devin, .grok, .hermes, .exo }) |id| {
        try testing.expect(!try installed(gpa, io, id));
    }
    try testing.expect(try installed(gpa, io, .mock));

    // On PATH.
    try writeExe(io, tmp.dir, "bin/codex");
    try testing.expect(try installed(gpa, io, .codex));
    // A file without an execute bit is not runnable.
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/grok", .data = "x" });
    try testing.expect(!try installed(gpa, io, .grok));
    // Home install dirs.
    try writeExe(io, tmp.dir, "home/.claude/local/claude");
    try testing.expect(try installed(gpa, io, .claude_code));
    try writeExe(io, tmp.dir, "home/.cursor/bin/cursor-agent");
    try testing.expect(try installed(gpa, io, .cursor));
    try writeExe(io, tmp.dir, "home/.harness/bin/graff");
    try testing.expect(try installed(gpa, io, .graff));
    // Node version managers.
    try writeExe(io, tmp.dir, "home/.nvm/versions/node/v22.1.0/bin/pi");
    try testing.expect(try installed(gpa, io, .pi));
    try writeExe(io, tmp.dir, "home/.bun/bin/opencode");
    try testing.expect(try installed(gpa, io, .opencode));
    // An override must point at a file; a dangling one reads not installed.
    try env.map.put("CODEX_EXECUTABLE", "/nonexistent-synthetic/codex");
    try testing.expect(!try installed(gpa, io, .codex));
    const codex_path = try std.fs.path.join(gpa, &.{ bin, "codex" });
    defer gpa.free(codex_path);
    try env.map.put("DEVIN_EXECUTABLE", codex_path);
    try testing.expect(try installed(gpa, io, .devin));
    // Exo needs the bridge, which this engine does not ship.
    try writeExe(io, tmp.dir, "home/bin/exo-cli");
    try testing.expect(!try installed(gpa, io, .exo));
    // The antigravity archive counts once its OK marker matches the pin.
    if (antigravityArchive()) |pin| {
        const dir = try std.fmt.allocPrint(gpa, "home/.harness/adapters/{s}/{s}", .{ pin.name, pin.version });
        defer gpa.free(dir);
        try tmp.dir.createDirPath(io, dir);
        const entry = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, pin.entry });
        defer gpa.free(entry);
        try writeExe(io, tmp.dir, entry);
        const marker = try std.fmt.allocPrint(gpa, "{s}/.harness-install-ok", .{dir});
        defer gpa.free(marker);
        try tmp.dir.writeFile(io, .{ .sub_path = marker, .data = "wrong" });
        try testing.expect(!try installed(gpa, io, .antigravity));
        try tmp.dir.writeFile(io, .{ .sub_path = marker, .data = pin.sha512 });
        try testing.expect(try installed(gpa, io, .antigravity));
    }
}

test "rpcw_executables installer availability follows install.rs prerequisites" {
    const Fake = struct {
        missing: []const u8,
        fn has(self: @This(), name: []const u8) bool {
            return !std.mem.eql(u8, name, self.missing) and !std.mem.eql(u8, self.missing, "*");
        }
    };
    for (std.meta.tags(HarnessId)) |id| {
        try testing.expectEqual(id == .mock or id == .exo, methods(id).len == 0);
        for (methods(id)) |m| {
            try testing.expect(available(m, Fake{ .missing = "" }, true));
            try testing.expect(!available(m, Fake{ .missing = "*" }, false));
        }
    }
    try testing.expect(!available(.graff_release, Fake{ .missing = "tar" }, true));
    try testing.expect(!available(methods(.claude_code)[0], Fake{ .missing = "bash" }, true));
    try testing.expect(available(methods(.codex)[0], Fake{ .missing = "bash" }, true));
    try testing.expect(!available(methods(.codex)[1], Fake{ .missing = "npm" }, true));
    if (builtin.os.tag == .macos) try testing.expect(methods(.devin)[0] == .brew);
}

test "rpcw_executables resolveCli launches the newest graff: a newer managed copy beats an older one on PATH" {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try common.tmpPath(gpa, io, &tmp);
    defer gpa.free(base);
    const home = try std.fs.path.join(gpa, &.{ base, "home" });
    defer gpa.free(home);
    const bin = try std.fs.path.join(gpa, &.{ base, "bin" });
    defer gpa.free(bin);
    try tmp.dir.createDirPath(io, "home/.harness/bin");
    try tmp.dir.createDirPath(io, "bin");
    var env = try common.TestEnv.init(gpa, home);
    defer env.deinit();
    try env.map.put("PATH", bin);
    try env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
    env.install();
    system_prefix = base;
    defer system_prefix = "";
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/graff", .data = "#!/bin/sh\necho 'graff 0.0.302.4'\n", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.harness/bin/graff", .data = "#!/bin/sh\necho 'graff 0.0.302.25'\n", .flags = .{ .permissions = .executable_file } });
    @import("harness_version.zig").invalidateVersions(io, &.{"graff"});
    const got = (try resolveCli(gpa, io, .graff)).?;
    defer gpa.free(got);
    try testing.expect(std.mem.endsWith(u8, got, "/home/.harness/bin/graff"));
}
