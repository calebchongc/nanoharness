//! `CreateWorktree` / `DeleteWorktree`, ported from `crates/engine/src/rpc.rs`
//! (`methods::CREATE_WORKTREE`, `methods::DELETE_WORKTREE`),
//! `crates/engine/src/repos.rs` (`create_worktree_for_task`,
//! `worktree_base_ref`, `delete_worktree`, branch ownership records),
//! `crates/proto/src/worktree_name.rs` (`task_slug`) and
//! `crates/engine/src/agents_prepare.rs` (`.agents/linked`, `.agents/prepare`).
//!
//! Worktrees live under `$HARNESS_WORKTREES_DIR` or `~/.harness/worktrees/<repo>/<name>`
//! on a fresh `task/<name>` branch, recorded as Harness-owned in the checkout's
//! local git config so deletion only removes branches Harness created.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");

const RpcOutcome = common.RpcOutcome;

pub const own_branch_prefix = "task/";
const legacy_branch_prefix = "harness/";
const mutation_lock_name = "harness-worktree-mutations.lock";

/// How long creation waits for `.agents/prepare` (`PREPARE_WAIT`).
pub var prepare_wait_ms: i64 = 90_000;

// ── naming ─────────────────────────────────────────────────────────────────

/// `harness_proto::worktree_name::task_slug`.
pub fn taskSlug(gpa: Allocator, task: []const u8) ![]u8 {
    var first_line: []const u8 = "";
    var lines = std.mem.splitScalar(u8, task, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) {
            first_line = line;
            break;
        }
    }
    var slug: std.ArrayList(u8) = .empty;
    defer slug.deinit(gpa);
    const trimmed = std.mem.trim(u8, first_line, " \t\r");
    var it = std.unicode.Utf8View.initUnchecked(trimmed).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (cp.len == 1 and (cp[0] == '\'' or cp[0] == '"' or cp[0] == '`')) continue;
        if (cp.len == 1 and std.ascii.isAlphanumeric(cp[0])) {
            try slug.append(gpa, std.ascii.toLower(cp[0]));
        } else if (slug.items.len > 0 and slug.items[slug.items.len - 1] != '-') {
            try slug.append(gpa, '-');
        }
        if (slug.items.len >= 48) break;
    }
    const s = std.mem.trimEnd(u8, slug.items, "-");
    if (s.len == 0) return gpa.dupe(u8, "changes");
    const windows_device = std.mem.eql(u8, s, "con") or std.mem.eql(u8, s, "prn") or
        std.mem.eql(u8, s, "aux") or std.mem.eql(u8, s, "nul") or
        (s.len == 4 and (std.mem.startsWith(u8, s, "com") or std.mem.startsWith(u8, s, "lpt")) and s[3] >= '1' and s[3] <= '9');
    if (windows_device) return std.fmt.allocPrint(gpa, "{s}-task", .{s});
    return gpa.dupe(u8, s);
}

/// `ref_names_conflict`: git refs are file-like, compared case-insensitively.
pub fn refNamesConflict(existing: []const u8, candidate: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(existing, candidate)) return true;
    if (existing.len > candidate.len and std.ascii.startsWithIgnoreCase(existing, candidate) and existing[candidate.len] == '/') return true;
    if (candidate.len > existing.len and std.ascii.startsWithIgnoreCase(candidate, existing) and candidate[existing.len] == '/') return true;
    return false;
}

/// `own_branch_taken` over the lowercased branch set.
pub fn ownBranchTaken(existing: []const []const u8, candidate: []const u8) bool {
    var buf: [600]u8 = undefined;
    const branch = std.fmt.bufPrint(&buf, own_branch_prefix ++ "{s}", .{candidate}) catch return true;
    var lbuf: [600]u8 = undefined;
    const legacy = std.fmt.bufPrint(&lbuf, legacy_branch_prefix ++ "{s}", .{candidate}) catch return true;
    for (existing) |e| {
        if (refNamesConflict(e, branch)) return true;
        if (std.mem.eql(u8, e, legacy)) return true;
    }
    return false;
}

/// `pick_remote_worktree_base`: the single `refs/remotes/<remote>/<base>`, the
/// preferred remote's among several, or an ambiguity error.
pub const RemotePick = union(enum) { none, picked: []const u8, ambiguous };

pub fn pickRemoteWorktreeBase(base: []const u8, remote_refs: []const u8, preferred: ?[]const u8) RemotePick {
    var count: usize = 0;
    var only: []const u8 = "";
    var preferred_hit: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, remote_refs, '\n');
    while (lines.next()) |raw| {
        const reference = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, reference, "refs/remotes/")) continue;
        const rest = reference["refs/remotes/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        if (!std.mem.eql(u8, rest[slash + 1 ..], base)) continue;
        count += 1;
        only = reference;
        if (preferred) |p| if (std.mem.eql(u8, rest[0..slash], p)) {
            preferred_hit = reference;
        };
    }
    return switch (count) {
        0 => .none,
        1 => .{ .picked = only },
        else => if (preferred_hit) |p| .{ .picked = p } else .ambiguous,
    };
}

/// `default_worktrees_root`.
pub fn worktreesRoot(gpa: Allocator, io: std.Io) ![]u8 {
    if (common.getenvNonEmpty("HARNESS_WORKTREES_DIR")) |dir| return gpa.dupe(u8, dir);
    const home = common.homeDir() orelse "/";
    const preferred = try std.fs.path.join(gpa, &.{ home, ".harness" });
    defer gpa.free(preferred);
    const legacy = try std.fs.path.join(gpa, &.{ home, ".harnesser" });
    defer gpa.free(legacy);
    if (common.pathExists(io, preferred) or !common.pathExists(io, legacy)) {
        return std.fs.path.join(gpa, &.{ preferred, "worktrees" });
    }
    return std.fs.path.join(gpa, &.{ legacy, "worktrees" });
}

// ── git helpers ────────────────────────────────────────────────────────────

const Failure = struct { message: []const u8 };

fn Result(comptime T: type) type {
    return union(enum) { ok: T, failed: []const u8 };
}

/// `Repos::current_branch` (`"HEAD"` when detached).
fn currentBranch(gpa: Allocator, io: std.Io, path: []const u8) !Result([]u8) {
    const r = try common.git(gpa, io, &.{ "branch", "--show-current" }, path);
    switch (r) {
        .failed => |m| return .{ .failed = m },
        .ok => |out| {
            if (out.len == 0) {
                gpa.free(out);
                return .{ .ok = try gpa.dupe(u8, "HEAD") };
            }
            return .{ .ok = out };
        },
    }
}

/// Lowercased `Repos::branches` names (locals, then remote-stripped).
fn branchSet(gpa: Allocator, io: std.Io, repo: []const u8) !std.ArrayList([]u8) {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    const r = try common.git(gpa, io, &.{ "branch", "-a", "--format=%(refname)" }, repo);
    defer r.deinit(gpa);
    if (r != .ok) return names;
    var lines = std.mem.splitScalar(u8, r.ok, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var name: []const u8 = "";
        if (std.mem.startsWith(u8, line, "refs/heads/")) {
            name = line["refs/heads/".len..];
        } else if (std.mem.startsWith(u8, line, "refs/remotes/")) {
            const rest = line["refs/remotes/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            name = rest[slash + 1 ..];
        } else continue;
        if (name.len == 0 or std.mem.eql(u8, name, "HEAD")) continue;
        const lower = try std.ascii.allocLowerString(gpa, name);
        try names.append(gpa, lower);
    }
    return names;
}

/// `Repos::worktree_base_ref`.
fn worktreeBaseRef(gpa: Allocator, io: std.Io, repo: []const u8, base: []const u8) !Result([]u8) {
    if ((base.len == 40 or base.len == 64) and for (base) |c| {
        if (!std.ascii.isHex(c)) break false;
    } else true) {
        return .{ .ok = try std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{base}) };
    }
    if (std.mem.startsWith(u8, base, "refs/") or std.mem.eql(u8, base, "HEAD")) {
        return .{ .ok = try gpa.dupe(u8, base) };
    }
    for ([_][]const u8{ "refs/heads", "refs/remotes" }) |ns| {
        const qualified = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ns, base });
        if (common.gitOk(gpa, io, &.{ "show-ref", "--verify", "--quiet", qualified }, repo)) {
            return .{ .ok = qualified };
        }
        gpa.free(qualified);
    }
    const remote_refs = try common.git(gpa, io, &.{ "for-each-ref", "--format=%(refname)", "refs/remotes" }, repo);
    defer remote_refs.deinit(gpa);
    if (remote_refs == .failed) return .{ .failed = remote_refs.failed };
    const preferred = try common.git(gpa, io, &.{ "config", "--get", "checkout.defaultRemote" }, repo);
    defer preferred.deinit(gpa);
    const pref: ?[]const u8 = if (preferred == .ok) preferred.ok else null;
    return switch (pickRemoteWorktreeBase(base, remote_refs.ok, pref)) {
        .none => .{ .ok = try gpa.dupe(u8, base) },
        .picked => |p| .{ .ok = try gpa.dupe(u8, p) },
        .ambiguous => .{ .failed = common.errText(
            "Ambiguous remote branch: {s}. Choose a remote-qualified base or set checkout.defaultRemote.",
            .{base},
        ) },
    };
}

pub const CheckoutIdentity = struct {
    id: [64]u8,
    root: []u8,
    git_dir: []u8,

    pub fn deinit(self: *CheckoutIdentity, gpa: Allocator) void {
        gpa.free(self.root);
        gpa.free(self.git_dir);
    }
};

/// `Repos::checkout_identity`: `sha256(deviceId ‖ NUL ‖ canonical git dir)`.
pub fn checkoutIdentity(gpa: Allocator, io: std.Io, device_id: []const u8, path: []const u8) !Result(CheckoutIdentity) {
    var root_raw: []u8 = undefined;
    var git_dir_raw: []u8 = undefined;
    {
        const both = try common.git(gpa, io, &.{ "rev-parse", "--show-toplevel", "--path-format=absolute", "--git-dir" }, path);
        if (both == .failed) return .{ .failed = both.failed };
        defer gpa.free(both.ok);
        var lines = std.mem.splitScalar(u8, both.ok, '\n');
        const a = lines.next();
        const b = lines.next();
        const c = lines.next();
        if (a != null and b != null and c == null) {
            root_raw = try gpa.dupe(u8, a.?);
            git_dir_raw = try gpa.dupe(u8, b.?);
        } else {
            const top = try common.git(gpa, io, &.{ "rev-parse", "--show-toplevel" }, path);
            if (top == .failed) return .{ .failed = top.failed };
            const gd = try common.git(gpa, io, &.{ "rev-parse", "--path-format=absolute", "--git-dir" }, path);
            if (gd == .failed) {
                gpa.free(top.ok);
                return .{ .failed = gd.failed };
            }
            root_raw = top.ok;
            git_dir_raw = gd.ok;
        }
    }
    const root = common.canonicalize(gpa, io, root_raw) orelse try gpa.dupe(u8, root_raw);
    gpa.free(root_raw);
    const git_dir = common.canonicalize(gpa, io, git_dir_raw) orelse try gpa.dupe(u8, git_dir_raw);
    gpa.free(git_dir_raw);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(device_id);
    hasher.update(&.{0});
    hasher.update(git_dir);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .ok = .{ .id = std.fmt.bytesToHex(digest, .lower), .root = root, .git_dir = git_dir } };
}

fn ownerConfigKey(gpa: Allocator, branch: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "branch.{s}.harness-worktree", .{branch});
}

/// `record_worktree_branch_owner`: serde's `{"git_dir":…,"branch":…}`.
fn recordBranchOwner(gpa: Allocator, io: std.Io, path: []const u8, branch: []const u8, git_dir: []const u8) !?[]const u8 {
    const owner = try std.fmt.allocPrint(gpa, "{{\"git_dir\":{f},\"branch\":{f}}}", .{ json.fmt(git_dir, .{}), json.fmt(branch, .{}) });
    defer gpa.free(owner);
    const key = try ownerConfigKey(gpa, branch);
    defer gpa.free(key);
    const r = try common.git(gpa, io, &.{ "config", "--local", key, owner }, path);
    defer r.deinit(gpa);
    return if (r == .failed) r.failed else null;
}

/// `manages_worktree_branch`: a matching ownership record, or (records absent)
/// the legacy `harness/` prefix.
fn managesBranch(gpa: Allocator, io: std.Io, device_id: []const u8, path: []const u8, branch: []const u8) !bool {
    const ident = try checkoutIdentity(gpa, io, device_id, path);
    var checkout = switch (ident) {
        .failed => return false,
        .ok => |c| c,
    };
    defer checkout.deinit(gpa);
    const key = try ownerConfigKey(gpa, branch);
    defer gpa.free(key);
    const r = try common.git(gpa, io, &.{ "config", "--local", "--get", key }, path);
    defer r.deinit(gpa);
    switch (r) {
        .failed => return std.mem.startsWith(u8, branch, legacy_branch_prefix),
        .ok => |text| {
            const Owner = struct { git_dir: []const u8, branch: []const u8 };
            const parsed = json.parseFromSlice(Owner, gpa, text, .{ .ignore_unknown_fields = true }) catch return false;
            defer parsed.deinit();
            return std.mem.eql(u8, parsed.value.git_dir, checkout.git_dir) and std.mem.eql(u8, parsed.value.branch, branch);
        },
    }
}

// ── the per-repository mutation lock ───────────────────────────────────────

var process_mutations: std.Io.Mutex = .init;

const MutationGuard = struct {
    io: std.Io,
    file: std.Io.File,

    fn release(self: MutationGuard) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        process_mutations.unlock(self.io);
    }
};

/// `lock_worktree_mutations`: one in-process holder, plus an advisory lock on
/// `<common git dir>/harness-worktree-mutations.lock` across processes.
fn lockMutations(gpa: Allocator, io: std.Io, path: []const u8) !Result(MutationGuard) {
    const common_dir = try common.git(gpa, io, &.{ "rev-parse", "--git-common-dir" }, path);
    if (common_dir == .failed) return .{ .failed = common_dir.failed };
    defer gpa.free(common_dir.ok);
    const joined = if (std.fs.path.isAbsolute(common_dir.ok))
        try gpa.dupe(u8, common_dir.ok)
    else
        try std.fs.path.join(gpa, &.{ path, common_dir.ok });
    defer gpa.free(joined);
    const key = common.canonicalize(gpa, io, joined) orelse
        return .{ .failed = common.errText("No such file or directory: {s}", .{joined}) };
    defer gpa.free(key);
    const lock_path = try std.fs.path.join(gpa, &.{ key, mutation_lock_name });
    defer gpa.free(lock_path);

    process_mutations.lockUncancelable(io);
    const file = std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false }) catch |e| {
        process_mutations.unlock(io);
        return .{ .failed = common.errText("{s}: {s}", .{ lock_path, @errorName(e) }) };
    };
    while (true) {
        const got = file.tryLock(io, .exclusive) catch |e| {
            file.close(io);
            process_mutations.unlock(io);
            return .{ .failed = common.errText("{s}: {s}", .{ lock_path, @errorName(e) }) };
        };
        if (got) break;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    return .{ .ok = .{ .io = io, .file = file } };
}

// ── .agents/ preparation (agents_prepare.rs) ───────────────────────────────

/// `entry_path`: one `.agents/linked` line as a safe repository-relative path.
pub fn linkedEntryPath(line: []const u8) ?[]const u8 {
    var p = std.mem.trim(u8, line, " \t\r");
    if (p.len == 0 or p[0] == '#') return null;
    p = std.mem.trimStart(u8, p, "/");
    p = std.mem.trimEnd(u8, p, "/");
    if (p.len == 0) return null;
    var parts = std.mem.splitScalar(u8, p, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
        if (std.mem.indexOfAny(u8, part, "*?[\\") != null) return null;
    }
    return p;
}

/// `link_shared`: symlink each listed gitignored path from `repo` into `worktree`.
fn linkShared(gpa: Allocator, io: std.Io, repo: []const u8, worktree: []const u8) !usize {
    if (comptime @import("builtin").os.tag == .windows) return 0;
    if (std.mem.eql(u8, repo, worktree)) return 0;
    const wt_list = try std.fs.path.join(gpa, &.{ worktree, ".agents", "linked" });
    defer gpa.free(wt_list);
    const repo_list = try std.fs.path.join(gpa, &.{ repo, ".agents", "linked" });
    defer gpa.free(repo_list);
    const text = std.Io.Dir.cwd().readFileAlloc(io, wt_list, gpa, .limited(1 << 20)) catch
        std.Io.Dir.cwd().readFileAlloc(io, repo_list, gpa, .limited(1 << 20)) catch return 0;
    defer gpa.free(text);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rel = linkedEntryPath(line) orelse continue;
        const shared = try std.fs.path.join(gpa, &.{ repo, rel });
        defer gpa.free(shared);
        const local = try std.fs.path.join(gpa, &.{ worktree, rel });
        defer gpa.free(local);
        _ = std.Io.Dir.cwd().statFile(io, shared, .{ .follow_symlinks = false }) catch continue;
        if (std.Io.Dir.cwd().statFile(io, local, .{ .follow_symlinks = false })) |_| continue else |_| {}
        // Tracked files are never redirected.
        if (!common.gitOk(gpa, io, &.{ "-C", repo, "check-ignore", "-q", "--", rel }, null)) continue;
        if (std.fs.path.dirname(local)) |parent| {
            std.Io.Dir.cwd().createDirPath(io, parent) catch continue;
        }
        std.Io.Dir.cwd().symLink(io, shared, local, .{}) catch continue;
        n += 1;
    }
    return n;
}

pub const PrepareOutcome = enum { ok, failed, still_running, could_not_start };

const PrepareWait = struct {
    child: std.process.Child,
    io: std.Io,
    done: std.atomic.Value(u8) = .init(0), // 0 running, 1 success, 2 failed
    refs: std.atomic.Value(u8) = .init(2),
    gpa: Allocator,

    fn release(self: *PrepareWait) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.gpa.destroy(self);
    }

    fn waiter(self: *PrepareWait) void {
        const term = self.child.wait(self.io) catch {
            self.done.store(2, .release);
            self.release();
            return;
        };
        self.done.store(if (term == .exited and term.exited == 0) 1 else 2, .release);
        self.release();
    }
};

/// `run_prepare`: run the worktree's `.agents/prepare`, waiting at most
/// `wait_ms`; a longer script keeps running in the background.
pub fn runPrepare(gpa: Allocator, io: std.Io, worktree: []const u8, wait_ms: i64) !?PrepareOutcome {
    const script = try std.fs.path.join(gpa, &.{ worktree, ".agents", "prepare" });
    defer gpa.free(script);
    if (!common.isFile(io, script)) return null;
    if (comptime !std.process.can_spawn) return .could_not_start;
    const executable = common.isRunnable(io, script);
    const argv: []const []const u8 = if (executable) &.{script} else &.{ "sh", "./.agents/prepare" };
    const child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = worktree },
        .environ_map = common.env_override,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .could_not_start;
    // The waiter may outlive this request (a slow script keeps running), so
    // its state is not tied to the request allocator.
    const state_gpa = std.heap.page_allocator;
    const state = try state_gpa.create(PrepareWait);
    state.* = .{ .child = child, .io = io, .gpa = state_gpa };
    const thread = std.Thread.spawn(.{}, PrepareWait.waiter, .{state}) catch {
        var c = state.child;
        c.kill(io);
        state_gpa.destroy(state);
        return .could_not_start;
    };
    thread.detach();
    defer state.release();
    var waited: i64 = 0;
    while (waited < wait_ms) : (waited += 20) {
        switch (state.done.load(.acquire)) {
            1 => return .ok,
            2 => return .failed,
            else => {},
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch break;
    }
    return switch (state.done.load(.acquire)) {
        1 => .ok,
        2 => .failed,
        else => .still_running,
    };
}

// ── RPCs ───────────────────────────────────────────────────────────────────

pub const Worktree = struct {
    repo_path: []u8,
    path: []u8,
    branch: []u8,
    name: []u8,
    checkout_id: [64]u8,

    pub fn deinit(self: *Worktree, gpa: Allocator) void {
        gpa.free(self.repo_path);
        gpa.free(self.path);
        gpa.free(self.branch);
        gpa.free(self.name);
    }
};

/// `Repos::create_worktree_for_task`.
pub fn createWorktreeForTask(
    gpa: Allocator,
    io: std.Io,
    device_id: []const u8,
    repo_path: []const u8,
    branch: []const u8,
    task: []const u8,
) !Result(Worktree) {
    // A base or path git would read as an option is never passed to it.
    if (std.mem.startsWith(u8, branch, "-")) return .{ .failed = common.errText("Invalid worktree base: {s}", .{branch}) };
    if (std.mem.startsWith(u8, repo_path, "-")) return .{ .failed = common.errText("Invalid repository path: {s}", .{repo_path}) };
    const lock = try lockMutations(gpa, io, repo_path);
    const guard = switch (lock) {
        .failed => |m| return .{ .failed = m },
        .ok => |g| g,
    };
    var guard_held = true;
    defer if (guard_held) guard.release();

    const base_ref = switch (try worktreeBaseRef(gpa, io, repo_path, branch)) {
        .failed => |m| return .{ .failed = m },
        .ok => |b| b,
    };
    defer gpa.free(base_ref);
    const root = try worktreesRoot(gpa, io);
    defer gpa.free(root);
    const base_name = std.fs.path.basename(repo_path);
    const repo_name = if (base_name.len == 0) "repo" else base_name;
    const base = try std.fs.path.join(gpa, &.{ root, repo_name });
    defer gpa.free(base);
    std.Io.Dir.cwd().createDirPath(io, base) catch |e|
        return .{ .failed = common.errText("{s}: {s}", .{ base, @errorName(e) }) };

    var existing = try branchSet(gpa, io, repo_path);
    defer {
        for (existing.items) |n| gpa.free(n);
        existing.deinit(gpa);
    }
    const slug = try taskSlug(gpa, task);
    defer gpa.free(slug);

    var name: ?[]u8 = null;
    var attempt: usize = 1;
    while (attempt <= 1000) : (attempt += 1) {
        const candidate = if (attempt == 1) try gpa.dupe(u8, slug) else try std.fmt.allocPrint(gpa, "{s}-{d}", .{ slug, attempt });
        if (ownBranchTaken(@ptrCast(existing.items), candidate)) {
            gpa.free(candidate);
            continue;
        }
        const reserve = try std.fs.path.join(gpa, &.{ base, candidate });
        defer gpa.free(reserve);
        std.Io.Dir.cwd().createDir(io, reserve, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {
                gpa.free(candidate);
                continue;
            },
            else => {
                gpa.free(candidate);
                return .{ .failed = common.errText("{s}: {s}", .{ reserve, @errorName(e) }) };
            },
        };
        name = candidate;
        break;
    }
    const wt_name = name orelse return .{ .failed = "Could not allocate a worktree name" };
    var keep = false;
    defer if (!keep) gpa.free(wt_name);
    const path = try std.fs.path.join(gpa, &.{ base, wt_name });
    defer if (!keep) gpa.free(path);
    const branch_name = try std.fmt.allocPrint(gpa, own_branch_prefix ++ "{s}", .{wt_name});
    defer gpa.free(branch_name);

    const add = try common.git(gpa, io, &.{ "worktree", "add", "-b", branch_name, "--", path, base_ref }, repo_path);
    defer add.deinit(gpa);
    if (add == .failed) {
        // Only release our empty reservation; a hook may have written files.
        std.Io.Dir.cwd().deleteDir(io, path) catch {};
        return .{ .failed = add.failed };
    }
    var checkout = switch (try checkoutIdentity(gpa, io, device_id, path)) {
        .failed => |m| return .{ .failed = m },
        .ok => |c| c,
    };
    defer checkout.deinit(gpa);
    if (try recordBranchOwner(gpa, io, path, branch_name, checkout.git_dir)) |m| return .{ .failed = m };
    guard.release();
    guard_held = false;

    // `prepare_worktree`: user setup never holds the allocation lock.
    _ = try linkShared(gpa, io, repo_path, path);
    _ = try runPrepare(gpa, io, path, prepare_wait_ms);

    const current = switch (try currentBranch(gpa, io, path)) {
        .failed => |m| return .{ .failed = m },
        .ok => |b| b,
    };
    keep = true;
    return .{ .ok = .{
        .repo_path = try gpa.dupe(u8, repo_path),
        .path = path,
        .branch = current,
        .name = wt_name,
        .checkout_id = checkout.id,
    } };
}

/// `Repos::delete_worktree`.
pub fn deleteWorktreeAt(gpa: Allocator, io: std.Io, device_id: []const u8, repo_path: []const u8, worktree_path: []const u8) !?[]const u8 {
    if (std.mem.startsWith(u8, worktree_path, "-")) return common.errText("Invalid worktree path: {s}", .{worktree_path});
    const lock = try lockMutations(gpa, io, repo_path);
    const guard = switch (lock) {
        .failed => |m| return m,
        .ok => |g| g,
    };
    defer guard.release();
    const exists = common.pathExists(io, worktree_path);
    var branch: []u8 = try gpa.dupe(u8, "");
    defer gpa.free(branch);
    if (exists) {
        switch (try currentBranch(gpa, io, worktree_path)) {
            .ok => |b| {
                gpa.free(branch);
                branch = b;
            },
            .failed => {},
        }
    }
    const managed = try managesBranch(gpa, io, device_id, worktree_path, branch);
    if (exists) {
        // Git validates that this is a linked worktree of this repository;
        // a refusal is never bypassed with recursive deletion.
        const r = try common.git(gpa, io, &.{ "worktree", "remove", "--force", "--", worktree_path }, repo_path);
        defer r.deinit(gpa);
        if (r == .failed) return r.failed;
    }
    _ = common.gitOk(gpa, io, &.{ "worktree", "prune" }, repo_path);
    if (managed) _ = common.gitOk(gpa, io, &.{ "branch", "-D", branch }, repo_path);
    return null;
}

fn requiredString(o: json.ObjectMap, key: []const u8, alias: []const u8) union(enum) { ok: []const u8, missing, wrong } {
    const v = o.get(key) orelse o.get(alias) orelse return .missing;
    return if (v == .string) .{ .ok = v.string } else .wrong;
}

fn writeWorktree(w: *std.Io.Writer, wt: Worktree) !void {
    try w.print(
        "\"repoPath\":{f},\"path\":{f},\"branch\":{f},\"name\":{f},\"checkoutId\":\"{s}\"",
        .{ json.fmt(wt.repo_path, .{}), json.fmt(wt.path, .{}), json.fmt(wt.branch, .{}), json.fmt(wt.name, .{}), wt.checkout_id[0..] },
    );
}

/// `CreateWorktree { repoPath | repo, branch, spaceId? }` → `CreateWorktreeOutcome`.
pub fn createWorktree(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct CreateWorktreeParams", .{});
    const repo_path = switch (requiredString(o, "repoPath", "repo")) {
        .ok => |s| s,
        .missing => return common.badParams("missing field `repoPath`", .{}),
        .wrong => return common.badParams("invalid type: expected a string for `repoPath`", .{}),
    };
    const branch = switch (requiredString(o, "branch", "branch")) {
        .ok => |s| s,
        .missing => return common.badParams("missing field `branch`", .{}),
        .wrong => return common.badParams("invalid type: expected a string for `branch`", .{}),
    };
    const space_id: ?[]const u8 = if (o.get("spaceId")) |v| switch (v) {
        .string => |s| s,
        .null => null,
        else => return common.badParams("invalid type: expected a string for `spaceId`", .{}),
    } else null;
    const io = host.io orelse return common.failed("git spawn failed: no I/O", .{});

    // A project space must be this device's and be the same repository.
    var setup_space: ?*const engine_host.SpaceRecord = null;
    if (space_id) |sid| {
        const space = for (host.spaces.items) |*s| {
            if (std.mem.eql(u8, s.id, sid)) break s;
        } else return common.failed("Project space not found", .{});
        if (!std.mem.eql(u8, space.device_id, host.device_id)) return common.failed("Project space belongs to another device", .{});
        const space_root = common.canonicalize(gpa, io, space.path) orelse return common.failed("Project root is unavailable", .{});
        defer gpa.free(space_root);
        const repo_root = common.canonicalize(gpa, io, repo_path) orelse return common.failed("Worktree repository is unavailable", .{});
        defer gpa.free(repo_root);
        if (!std.mem.eql(u8, space_root, repo_root)) return common.failed("Worktree repository does not match project space", .{});
        setup_space = space;
    }

    var wt = switch (try createWorktreeForTask(gpa, io, host.device_id, repo_path, branch, "changes")) {
        .failed => |m| return .{ .err = .{ .exec_error = m } },
        .ok => |w| w,
    };
    defer wt.deinit(gpa);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('{');
    try writeWorktree(w, wt);
    if (setup_space) |space| {
        // `launch_project_setup_action`: the space's setup Action runs in a
        // new terminal in the worktree; a launch failure is reported as
        // `setupError` and the worktree is kept.
        const project_root = common.canonicalize(gpa, io, space.path) orelse try gpa.dupe(u8, space.path);
        defer gpa.free(project_root);
        try @import("rpcg_terminals.zig").writeWorktreeSetup(host, w, space.id, project_root, wt.path);
    }
    try w.writeByte('}');
    return .{ .unary_json = try aw.toOwnedSlice() };
}

/// `DeleteWorktree { repoPath | repo, worktreePath | path }` → `{"ok":true}`.
pub fn deleteWorktree(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const o = common.obj(params) orelse return common.badParams("invalid type: expected struct DeleteWorktreeParams", .{});
    const repo_path = switch (requiredString(o, "repoPath", "repo")) {
        .ok => |s| s,
        .missing => return common.badParams("missing field `repoPath`", .{}),
        .wrong => return common.badParams("invalid type: expected a string for `repoPath`", .{}),
    };
    const worktree_path = switch (requiredString(o, "worktreePath", "path")) {
        .ok => |s| s,
        .missing => return common.badParams("missing field `worktreePath`", .{}),
        .wrong => return common.badParams("invalid type: expected a string for `worktreePath`", .{}),
    };
    const io = host.io orelse return common.failed("git spawn failed: no I/O", .{});
    if (try deleteWorktreeAt(host.gpa, io, host.device_id, repo_path, worktree_path)) |m| return .{ .err = .{ .exec_error = m } };
    return .{ .unary_json = try host.gpa.dupe(u8, "{\"ok\":true}") };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    gpa: Allocator,
    io: std.Io,
    tmp: testing.TmpDir,
    base: []u8,
    repo: []u8,
    wt_root: []u8,
    env: common.TestEnv,
    arena: std.heap.ArenaAllocator,

    fn a(f: *Fixture) Allocator {
        return f.arena.allocator();
    }

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const io = testing.io;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.gpa = gpa;
        f.io = io;
        f.arena = .init(gpa);
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, io, &f.tmp);
        f.repo = try std.fs.path.join(gpa, &.{ f.base, "proj" });
        f.wt_root = try std.fs.path.join(gpa, &.{ f.base, "wt" });
        f.env = try common.TestEnv.init(gpa, f.base);
        try f.env.map.put("HARNESS_WORKTREES_DIR", f.wt_root);
        f.env.install();
        try f.sh("git init -q -b main proj && cd proj && printf 'one\\n' > a.txt && git add a.txt && git commit -q -m init");
        prepare_wait_ms = 10_000;
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.env.deinit();
        f.arena.deinit();
        f.gpa.free(f.base);
        f.gpa.free(f.repo);
        f.gpa.free(f.wt_root);
        f.tmp.cleanup();
        prepare_wait_ms = 90_000;
        f.gpa.destroy(f);
    }

    fn sh(f: *Fixture, script: []const u8) !void {
        var r = try common.run(f.gpa, f.io, &.{ "/bin/sh", "-c", script }, f.base, 30_000);
        defer r.deinit(f.gpa);
        if (!r.success()) {
            std.debug.print("fixture script failed: {s}\n{s}\n", .{ script, r.stderr });
            return error.FixtureFailed;
        }
    }

    fn gitOut(f: *Fixture, args: []const []const u8, cwd: []const u8) ![]u8 {
        const r = try common.git(f.gpa, f.io, args, cwd);
        return switch (r) {
            .ok => |o| o,
            .failed => error.GitFailed,
        };
    }
};

fn testHost(f: *Fixture) !engine_host.EngineHost {
    var host = try engine_host.EngineHost.init(f.gpa, "dev-synthetic", "Synthetic");
    host.io = f.io;
    return host;
}

fn expectExecError(outcome: RpcOutcome, expected: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .exec_error => |m| try testing.expectEqualStrings(expected, m),
            else => return error.UnexpectedErrorKind,
        },
        .unary_json => |b| {
            std.debug.print("unexpected success: {s}\n", .{b});
            testing.allocator.free(b);
            return error.ExpectedError;
        },
        else => return error.ExpectedError,
    }
}

fn expectBadParams(outcome: RpcOutcome, expected: []const u8) !void {
    switch (outcome) {
        .err => |e| switch (e) {
            .bad_params => |m| try testing.expectEqualStrings(expected, m),
            else => return error.UnexpectedErrorKind,
        },
        else => return error.ExpectedError,
    }
}

test "rpcw_worktrees task slugs, ref conflicts and remote base picks match repos.rs" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "changes", "changes" },
        .{ "Fix the `login` bug!\nmore", "fix-the-login-bug" },
        .{ "  \n\n  Don't panic  ", "dont-panic" },
        .{ "???", "changes" },
        .{ "con", "con-task" },
        .{ "COM3", "com3-task" },
        .{ "lpt0", "lpt0" },
    };
    for (cases) |c| {
        const s = try taskSlug(gpa, c[0]);
        defer gpa.free(s);
        try testing.expectEqualStrings(c[1], s);
    }
    try testing.expect(refNamesConflict("task/changes", "TASK/changes"));
    try testing.expect(refNamesConflict("task/changes/x", "task/changes"));
    try testing.expect(refNamesConflict("task", "task/changes"));
    try testing.expect(!refNamesConflict("task/changes-2", "task/changes"));
    const existing = [_][]const u8{ "main", "harness/changes" };
    try testing.expect(ownBranchTaken(&existing, "changes"));
    try testing.expect(!ownBranchTaken(&existing, "changes-2"));

    const refs = "refs/remotes/origin/feature\nrefs/remotes/fork/feature\nrefs/remotes/origin/main\n";
    try testing.expectEqualStrings("refs/remotes/origin/main", pickRemoteWorktreeBase("main", refs, null).picked);
    try testing.expect(pickRemoteWorktreeBase("feature", refs, null) == .ambiguous);
    try testing.expectEqualStrings("refs/remotes/fork/feature", pickRemoteWorktreeBase("feature", refs, "fork").picked);
    try testing.expect(pickRemoteWorktreeBase("nope", refs, null) == .none);

    try testing.expectEqualStrings(".env", linkedEntryPath("/.env").?);
    try testing.expectEqualStrings("config/local", linkedEntryPath("  config/local/ \r").?);
    for ([_][]const u8{ "", "  ", "# secrets", "/", "../x", "a/../b", "./x", "*.env", "certs/**", "a//b" }) |bad| {
        try testing.expect(linkedEntryPath(bad) == null);
    }
}

test "rpcw_worktrees CreateWorktree adds a task branch checkout, links shared files, runs prepare, and DeleteWorktree removes it" {
    const f = try Fixture.init();
    defer f.deinit();
    const gpa = f.gpa;
    try f.sh(
        \\cd proj && mkdir -p .agents && printf '.env\nprepared\n' > .gitignore &&
        \\printf '/.env\n' > .agents/linked && printf 'touch prepared\n' > .agents/prepare &&
        \\printf 'SECRET=synthetic\n' > .env && git add .gitignore .agents && git commit -q -m agents
    );
    var host = try testHost(f);
    defer host.deinit();

    var params = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(f.a(), "{{\"repoPath\":{f},\"branch\":\"main\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer params.deinit();
    const out = try host.handle("CreateWorktree", params.value);
    const body = out.unary_json;
    defer gpa.free(body);
    var reply = try json.parseFromSlice(json.Value, gpa, body, .{});
    defer reply.deinit();
    const r = reply.value.object;
    const expected_path = try std.fs.path.join(gpa, &.{ f.wt_root, "proj", "changes" });
    defer gpa.free(expected_path);
    try testing.expectEqualStrings(f.repo, r.get("repoPath").?.string);
    try testing.expectEqualStrings(expected_path, r.get("path").?.string);
    try testing.expectEqualStrings("task/changes", r.get("branch").?.string);
    try testing.expectEqualStrings("changes", r.get("name").?.string);
    try testing.expectEqual(@as(usize, 64), r.get("checkoutId").?.string.len);
    try testing.expect(r.get("setupAction") == null and r.get("setupError") == null);

    // `.agents/linked` symlinked the ignored .env; `.agents/prepare` ran.
    const env_link = try std.fs.path.join(gpa, &.{ expected_path, ".env" });
    defer gpa.free(env_link);
    var link_buf: [4096]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(f.io, env_link, &link_buf);
    try testing.expect(std.mem.endsWith(u8, link_buf[0..n], "proj/.env"));
    const prepared = try std.fs.path.join(gpa, &.{ expected_path, "prepared" });
    defer gpa.free(prepared);
    try testing.expect(common.isFile(f.io, prepared));

    // Ownership is recorded in the checkout's local config.
    const owner = try f.gitOut(&.{ "config", "--local", "--get", "branch.task/changes.harness-worktree" }, expected_path);
    defer gpa.free(owner);
    try testing.expect(std.mem.indexOf(u8, owner, "\"branch\":\"task/changes\"") != null);

    // A second request takes the next free name.
    const out2 = try host.handle("CreateWorktree", params.value);
    defer gpa.free(out2.unary_json);
    try testing.expect(std.mem.indexOf(u8, out2.unary_json, "\"name\":\"changes-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out2.unary_json, "\"branch\":\"task/changes-2\"") != null);

    // Delete removes the checkout and the Harness-owned branch.
    var del = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(f.a(), "{{\"repo\":{f},\"path\":{f}}}", .{ json.fmt(f.repo, .{}), json.fmt(expected_path, .{}) }), .{});
    defer del.deinit();
    const dout = try host.handle("DeleteWorktree", del.value);
    defer gpa.free(dout.unary_json);
    try testing.expectEqualStrings("{\"ok\":true}", dout.unary_json);
    try testing.expect(!common.pathExists(f.io, expected_path));
    try testing.expect(!common.gitOk(gpa, f.io, &.{ "show-ref", "--verify", "--quiet", "refs/heads/task/changes" }, f.repo));
    try testing.expect(common.gitOk(gpa, f.io, &.{ "show-ref", "--verify", "--quiet", "refs/heads/task/changes-2" }, f.repo));

    // Deleting a path that is already gone is a clean no-op.
    const again = try host.handle("DeleteWorktree", del.value);
    defer gpa.free(again.unary_json);
    try testing.expectEqualStrings("{\"ok\":true}", again.unary_json);
}

test "rpcw_worktrees DeleteWorktree keeps a user's branch and refuses the primary checkout" {
    const f = try Fixture.init();
    defer f.deinit();
    const gpa = f.gpa;
    try f.sh("cd proj && git worktree add -q -b task/mine ../mine main");
    const mine = try std.fs.path.join(gpa, &.{ f.base, "mine" });
    defer gpa.free(mine);

    var host = try testHost(f);
    defer host.deinit();
    // A task/ prefix alone is not ownership: the checkout goes, the branch stays.
    var del = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(f.a(), "{{\"repoPath\":{f},\"worktreePath\":{f}}}", .{ json.fmt(f.repo, .{}), json.fmt(mine, .{}) }), .{});
    defer del.deinit();
    const out = try host.handle("DeleteWorktree", del.value);
    defer gpa.free(out.unary_json);
    try testing.expect(!common.pathExists(f.io, mine));
    try testing.expect(common.gitOk(gpa, f.io, &.{ "show-ref", "--verify", "--quiet", "refs/heads/task/mine" }, f.repo));

    // The primary checkout is refused by git and never deleted recursively.
    var primary = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(f.a(), "{{\"repoPath\":{f},\"worktreePath\":{f}}}", .{ json.fmt(f.repo, .{}), json.fmt(f.repo, .{}) }), .{});
    defer primary.deinit();
    const refused = try host.handle("DeleteWorktree", primary.value);
    try testing.expect(refused == .err and refused.err == .exec_error);
    try testing.expect(std.mem.startsWith(u8, refused.err.exec_error, "git: "));
    const a_txt = try std.fs.path.join(gpa, &.{ f.repo, "a.txt" });
    defer gpa.free(a_txt);
    try testing.expect(common.isFile(f.io, a_txt));

    var missing = try json.parseFromSlice(json.Value, gpa, "{\"repoPath\":\"/x\"}", .{});
    defer missing.deinit();
    try expectBadParams(try host.handle("DeleteWorktree", missing.value), "missing field `worktreePath`");
}

test "rpcw_worktrees CreateWorktree errors: params, unknown base, ambiguous remote, project space checks" {
    const f = try Fixture.init();
    defer f.deinit();
    const gpa = f.gpa;
    var host = try testHost(f);
    defer host.deinit();
    const a = f.a();

    var no_branch = try json.parseFromSlice(json.Value, gpa, "{\"repoPath\":\"/x\"}", .{});
    defer no_branch.deinit();
    try expectBadParams(try host.handle("CreateWorktree", no_branch.value), "missing field `branch`");
    var no_repo = try json.parseFromSlice(json.Value, gpa, "{\"branch\":\"main\"}", .{});
    defer no_repo.deinit();
    try expectBadParams(try host.handle("CreateWorktree", no_repo.value), "missing field `repoPath`");

    // An unknown base fails with git's message and releases the reservation.
    var unknown = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"branch\":\"no-such-branch\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer unknown.deinit();
    const bad = try host.handle("CreateWorktree", unknown.value);
    try testing.expect(bad == .err and std.mem.startsWith(u8, bad.err.exec_error, "git: "));
    const reserved = try std.fs.path.join(gpa, &.{ f.wt_root, "proj", "changes" });
    defer gpa.free(reserved);
    try testing.expect(!common.pathExists(f.io, reserved));

    // A branch on two remotes is ambiguous until checkout.defaultRemote picks one.
    try f.sh("cd proj && git update-ref refs/remotes/origin/feature HEAD && git update-ref refs/remotes/fork/feature HEAD");
    var feature = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"branch\":\"feature\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer feature.deinit();
    try expectExecError(
        try host.handle("CreateWorktree", feature.value),
        "Ambiguous remote branch: feature. Choose a remote-qualified base or set checkout.defaultRemote.",
    );
    try f.sh("cd proj && git config checkout.defaultRemote fork");
    const picked = try host.handle("CreateWorktree", feature.value);
    defer gpa.free(picked.unary_json);
    try testing.expect(std.mem.indexOf(u8, picked.unary_json, "\"branch\":\"task/changes\"") != null);

    // Project space checks.
    var sp = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"branch\":\"main\",\"spaceId\":\"space-missing\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer sp.deinit();
    try expectExecError(try host.handle("CreateWorktree", sp.value), "Project space not found");

    const other = try std.fs.path.join(gpa, &.{ f.base, "other" });
    defer gpa.free(other);
    try f.sh("mkdir other");
    try host.spaces.append(gpa, .{ .id = try gpa.dupe(u8, "space-remote"), .device_id = try gpa.dupe(u8, "dev-elsewhere"), .path = try gpa.dupe(u8, f.repo), .name = try gpa.dupe(u8, "proj"), .git_detected = true });
    try host.spaces.append(gpa, .{ .id = try gpa.dupe(u8, "space-other"), .device_id = try gpa.dupe(u8, "dev-synthetic"), .path = try gpa.dupe(u8, other), .name = try gpa.dupe(u8, "other"), .git_detected = false });
    try host.spaces.append(gpa, .{ .id = try gpa.dupe(u8, "space-gone"), .device_id = try gpa.dupe(u8, "dev-synthetic"), .path = try gpa.dupe(u8, "/nonexistent-synthetic-root"), .name = try gpa.dupe(u8, "gone"), .git_detected = false });
    try host.spaces.append(gpa, .{ .id = try gpa.dupe(u8, "space-proj"), .device_id = try gpa.dupe(u8, "dev-synthetic"), .path = try gpa.dupe(u8, f.repo), .name = try gpa.dupe(u8, "proj"), .git_detected = true });

    inline for (.{
        .{ "space-remote", "Project space belongs to another device" },
        .{ "space-other", "Worktree repository does not match project space" },
        .{ "space-gone", "Project root is unavailable" },
    }) |c| {
        var p = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"branch\":\"main\",\"spaceId\":\"" ++ c[0] ++ "\"}}", .{json.fmt(f.repo, .{})}), .{});
        defer p.deinit();
        try expectExecError(try host.handle("CreateWorktree", p.value), c[1]);
    }
    var gone_repo = try json.parseFromSlice(json.Value, gpa, "{\"repoPath\":\"/nonexistent-synthetic-repo\",\"branch\":\"main\",\"spaceId\":\"space-proj\"}", .{});
    defer gone_repo.deinit();
    try expectExecError(try host.handle("CreateWorktree", gone_repo.value), "Worktree repository is unavailable");

    // The matching space succeeds and its setup Action starts in a terminal.
    try f.env.map.put("SHELL", "/bin/sh");
    try host.actions.append(gpa, .{ .id = try gpa.dupe(u8, "act-1"), .space_id = try gpa.dupe(u8, "space-proj"), .name = try gpa.dupe(u8, "Install"), .command = try gpa.dupe(u8, "true"), .icon = try gpa.dupe(u8, "play"), .run_on_worktree_create = true });
    var ok_space = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"branch\":\"main\",\"spaceId\":\"space-proj\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer ok_space.deinit();
    const created = try host.handle("CreateWorktree", ok_space.value);
    defer gpa.free(created.unary_json);
    try testing.expect(std.mem.indexOf(u8, created.unary_json, "\"name\":\"changes-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, created.unary_json, "\"setupAction\":{\"actionId\":\"act-1\",\"actionName\":\"Install\",\"terminal\":{\"id\":") != null);
    try testing.expect(std.mem.indexOf(u8, created.unary_json, "\"setupError\":") == null);
}

test "rpcw_worktrees runPrepare reports failure and leaves a slow script running" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.sh("mkdir -p slow/.agents fail/.agents && printf 'sleep 2\\n' > slow/.agents/prepare && printf 'exit 4\\n' > fail/.agents/prepare");
    const slow = try std.fs.path.join(f.gpa, &.{ f.base, "slow" });
    defer f.gpa.free(slow);
    const fail = try std.fs.path.join(f.gpa, &.{ f.base, "fail" });
    defer f.gpa.free(fail);
    try testing.expectEqual(PrepareOutcome.still_running, (try runPrepare(f.gpa, f.io, slow, 100)).?);
    try testing.expectEqual(PrepareOutcome.failed, (try runPrepare(f.gpa, f.io, fail, 10_000)).?);
    try testing.expect((try runPrepare(f.gpa, f.io, f.base, 100)) == null);
}

test "fix-sec 12: a base or worktree path that looks like an option never reaches git" {
    const f = try Fixture.init();
    defer f.deinit();
    const gpa = f.gpa;
    var host = try testHost(f);
    defer host.deinit();
    const a = f.a();

    var opt_base = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"branch\":\"--detach\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer opt_base.deinit();
    try expectExecError(try host.handle("CreateWorktree", opt_base.value), "Invalid worktree base: --detach");

    var opt_path = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"worktreePath\":\"--force\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer opt_path.deinit();
    try expectExecError(try host.handle("DeleteWorktree", opt_path.value), "Invalid worktree path: --force");

    // An ordinary base still works, its path after `--`.
    var ok = try json.parseFromSlice(json.Value, gpa, try std.fmt.allocPrint(a, "{{\"repoPath\":{f},\"branch\":\"main\"}}", .{json.fmt(f.repo, .{})}), .{});
    defer ok.deinit();
    const created = try host.handle("CreateWorktree", ok.value);
    defer gpa.free(created.unary_json);
    try testing.expect(std.mem.indexOf(u8, created.unary_json, "\"branch\":\"task/changes\"") != null);
}
