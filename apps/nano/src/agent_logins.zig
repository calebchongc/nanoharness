//! The agent-accounts login registry and saved-login switching: a port of
//! `AgentAccounts` in `crates/engine/src/agent_accounts.rs` (with
//! `graff_logins.rs`, `device_login.rs`) and the RPC glue for
//! `ListAgentAccounts`, `ActivateAgentAccount`, `ForgetAgentAccount`,
//! `StartAgentLogin`, `CompleteAgentLogin`, `PollAgentLogin` and
//! `CancelAgentLogin` in `crates/engine/src/rpc.rs`.
//!
//! - Detection: Claude Code (`~/.claude.json` identity + `.credentials.json`
//!   or the macOS Keychain item via `security`), Codex (`$CODEX_HOME/auth.json`)
//!   and Cursor (`~/.cursor/sdk/auth.json`). Every list snapshots the live
//!   logins into slots (`agent_logins_slots.zig`).
//! - Switching (`activate`): the current login is snapshotted, then the
//!   CLI's store is overwritten from the slot. Claude keeps the machine's live
//!   MCP/plugin OAuth (`CLAUDE_SHARED_CREDENTIAL_KEYS`) and merges the identity
//!   into `~/.claude.json`.
//! - Adding (`start`…): Claude's PKCE paste-code flow; `codex login` against a
//!   throwaway `CODEX_HOME`; the Cursor shim's login mode; `graff login
//!   <provider>`, including the relayed ChatGPT sign-in and recoveries that
//!   later viewers attach to.
//!
//! Std-only: `std.http.Client` (endpoint `pub var` seams), `catalog_core`'s
//! `resolve_cli`/`env_override` seams, and `security` behind
//! `agent_logins_keychain.security_bin`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const Sha256 = std.crypto.hash.sha2.Sha256;
const util = @import("agent_logins_util.zig");
const slots_mod = @import("agent_logins_slots.zig");
const graff = @import("agent_logins_graff.zig");
const proc = @import("agent_logins_proc.zig");
const http = @import("agent_logins_http.zig");
const keychain = @import("agent_logins_keychain.zig");
const catalog_core = @import("catalog_core.zig");

pub const Harness = util.Harness;
pub const Config = slots_mod.Config;
const Slot = slots_mod.Slot;
const Detected = slots_mod.Detected;
const Profile = slots_mod.Profile;
const LoginChild = proc.LoginChild;
const LoginStart = util.LoginStart;
const LoginPoll = util.LoginPoll;
const UsageWindow = util.UsageWindow;
const UsageSnapshot = util.UsageSnapshot;

// ── constants and seams ────────────────────────────────────────────────────

/// Claude Code's public OAuth client (the CLI's own paste-code flow; PKCE).
pub const claude_client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const claude_redirect = "https://console.anthropic.com/oauth/code/callback";
pub const claude_scopes = "org:create_api_key user:profile user:inference";

/// Test builds start every endpoint on a closed loopback port, so a test that
/// forgets to point one at its fake server fails instead of reaching out.
const guard = "http://127.0.0.1:9";
pub var claude_token_url: []const u8 = if (builtin.is_test) guard ++ "/v1/oauth/token" else "https://console.anthropic.com/v1/oauth/token";
pub var claude_profile_url: []const u8 = if (builtin.is_test) guard ++ "/api/oauth/profile" else "https://api.anthropic.com/api/oauth/profile";
pub var claude_usage_url: []const u8 = if (builtin.is_test) guard ++ "/api/oauth/usage" else "https://api.anthropic.com/api/oauth/usage";
pub var codex_usage_url: []const u8 = if (builtin.is_test) guard ++ "/backend-api/wham/usage" else "https://chatgpt.com/backend-api/wham/usage";
/// The Cursor backend when the stored credential names none.
pub var cursor_default_backend: []const u8 = if (builtin.is_test) guard else "https://api2.cursor.sh";
const cursor_current_period_usage = "aiserver.v1.DashboardService/GetCurrentPeriodUsage";

/// `FLOW_TTL`: an abandoned flow is reaped past this.
pub var flow_ttl_ms: i64 = 15 * 60 * 1000;
/// `USAGE_TTL`.
pub var usage_ttl_ms: i64 = 60_000;
/// `HTTP_TIMEOUT`.
pub var http_timeout_ms: u32 = 8000;
/// `RELAY_FINISH_WAIT`.
pub var relay_finish_wait_ms: u64 = 90_000;
/// `await_login_url`'s wait for a printed authorize URL.
pub var login_url_wait_ms: u64 = 5000;
/// `await_device_login`'s wait for Codex's device prompt.
pub var device_wait_ms: u64 = 30_000;
/// How long `graff login` may take to offer its link (or finish, for claude-agent).
pub var graff_start_wait_ms: u64 = 20_000;
/// Anthropic Console: the wait for graff after the pasted code.
pub var graff_paste_wait_ms: u64 = 45_000;
/// `graff login claude-agent` run after a Claude Code sign-in.
pub var graff_record_timeout_ms: u64 = 30_000;

/// How the Cursor shim is launched (`CursorHarness::resolve_shim`): the
/// program and its leading args. The default honours
/// `CURSOR_SDK_SHIM_EXECUTABLE` only; the engine points this at its managed
/// SDK install (`agent_cursor.zig`), which this std-only module can't reach.
pub const ShimLaunch = struct { exe: []const u8, args: []const []const u8 = &.{} };
pub const ResolveShim = *const fn (a: Allocator, io: Io) anyerror!ShimLaunch;
pub var resolve_cursor_shim: ResolveShim = shimFromEnv;

fn shimFromEnv(a: Allocator, _: Io) anyerror!ShimLaunch {
    var env = try catalog_core.currentEnv(a);
    defer env.deinit();
    if (env.get("CURSOR_SDK_SHIM_EXECUTABLE")) |p| if (p.len > 0) return .{ .exe = try a.dupe(u8, p) };
    return error.CursorSdkShimUnavailable;
}

const codex_install_hint = "codex (searched PATH, the login shell's PATH, ~/.local/bin, ~/.codex/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; set CODEX_EXECUTABLE to override)";
const graff_install_hint = "graff (searched PATH, the login shell's PATH, ~/.harness/bin, the app bundle, ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin; install codegraff, then `graff login`; set GRAFF_EXECUTABLE to override)";

// ── replies ────────────────────────────────────────────────────────────────

/// One RPC answer. Every payload is owned by the registry's allocator.
pub const Reply = union(enum) {
    /// The reply JSON (`AgentAccountsSnapshot`, `AgentLoginStart`,
    /// `AgentLoginPoll` or `{"ok":true}`).
    ok: []u8,
    /// serde's parameter error (`RpcError::BadParams`).
    bad_params: []u8,
    /// Rust's `EngineError` text (`RpcError::Failed`).
    failed: []u8,
    /// A branch this port leaves out (antigravity's ACP sign-in); the text
    /// says which.
    not_ported: []u8,

    pub fn deinit(r: Reply, gpa: Allocator) void {
        switch (r) {
            inline else => |s| gpa.free(s),
        }
    }

    pub fn text(r: Reply) []const u8 {
        return switch (r) {
            inline else => |s| s,
        };
    }
};

/// Rust's `std::io::Error` display for the errors a file operation returns.
fn ioText(a: Allocator, err: anyerror) []const u8 {
    const m: []const u8 = switch (err) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied, error.PermissionDenied => "Permission denied (os error 13)",
        error.PathAlreadyExists => "File exists (os error 17)",
        error.NotDir => "Not a directory (os error 20)",
        error.IsDir => "Is a directory (os error 21)",
        error.NoSpaceLeft => "No space left on device (os error 28)",
        error.ReadOnlyFileSystem => "Read-only file system (os error 30)",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
    return std.fmt.allocPrint(a, "io: {s}", .{m}) catch "io error";
}

const Call = struct {
    arena: std.heap.ArenaAllocator,
    msg: ?[]const u8 = null,

    fn init(gpa: Allocator) Call {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(c: *Call) void {
        c.arena.deinit();
    }

    fn al(c: *Call) Allocator {
        return c.arena.allocator();
    }

    fn fail(c: *Call, comptime fmt: []const u8, args: anytype) error{Failed} {
        c.msg = std.fmt.allocPrint(c.al(), fmt, args) catch "out of memory";
        return error.Failed;
    }

    fn failText(c: *Call, m: []const u8) error{Failed} {
        c.msg = m;
        return error.Failed;
    }

    fn errText(c: *Call, err: anyerror) []const u8 {
        if (err == error.Failed) return c.msg orelse "failed";
        return ioText(c.al(), err);
    }
};

// ── login flows ────────────────────────────────────────────────────────────

const Flow = struct {
    started_ms: i64,
    kind: Kind,

    const Kind = union(enum) {
        claude: struct { verifier: []u8, then_graff: bool },
        /// `codex login` / the cursor shim against a throwaway credential dir.
        spawned: struct { harness: Harness, reauthenticate: bool, child: *LoginChild, home: []u8 },
        /// `graff login <provider>` against the real home.
        graff: struct { provider: []u8, child: *LoginChild, before: ?i96, first_registration: bool, relay: ?graff.ChatgptRelay },
    };

    fn child(f: *const Flow) ?*LoginChild {
        return switch (f.kind) {
            .claude => null,
            .spawned => |s| s.child,
            .graff => |g| g.child,
        };
    }

    /// Still waiting on the user (a child that has not exited).
    fn pending(f: *const Flow) bool {
        const c = f.child() orelse return true;
        return c.exitStatus() == null;
    }

    fn destroy(f: *Flow, gpa: Allocator) void {
        switch (f.kind) {
            .claude => |c| gpa.free(c.verifier),
            .spawned => |s| {
                s.child.release();
                gpa.free(s.home);
            },
            .graff => |g| {
                g.child.release();
                gpa.free(g.provider);
                if (g.relay) |r| r.free(gpa);
            },
        }
        gpa.destroy(f);
    }
};

const CachedUsage = struct {
    usage: ?UsageSnapshot,
    at_ms: i64,

    fn free(c: CachedUsage, gpa: Allocator) void {
        if (c.usage) |u| {
            gpa.free(u.windows);
            if (u.plan_label) |p| gpa.free(p);
        }
    }
};

/// `AgentAccount`.
const Account = struct {
    id: []const u8,
    harness: Harness,
    email: ?[]const u8,
    plan_label: ?[]const u8,
    active: bool,
    usage_windows: []const UsageWindow = &.{},
    display_name: ?[]const u8,
    organization: ?[]const u8,
    auth_kind: ?slots_mod.AuthKind,
    switchable: bool,
    saved_at: ?i64,
};

const Warning = struct { harness: Harness, message: []const u8 };

/// `AgentAccountsSnapshot`.
const Snapshot = struct {
    accounts: []const Account,
    warnings: []const Warning,

    fn toJson(s: Snapshot, a: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(a);
        var j: json.Stringify = .{ .writer = &aw.writer };
        try j.beginObject();
        try j.objectField("accounts");
        try j.beginArray();
        for (s.accounts) |acc| {
            try j.beginObject();
            try j.objectField("id");
            try j.write(acc.id);
            try j.objectField("harness");
            try j.write(acc.harness.slug());
            try j.objectField("email");
            try j.write(acc.email);
            try j.objectField("planLabel");
            try j.write(acc.plan_label);
            try j.objectField("active");
            try j.write(acc.active);
            try j.objectField("usageWindows");
            try j.beginArray();
            for (acc.usage_windows) |w| try util.writeWindow(&j, w);
            try j.endArray();
            if (acc.display_name) |x| {
                try j.objectField("displayName");
                try j.write(x);
            }
            if (acc.organization) |x| {
                try j.objectField("organization");
                try j.write(x);
            }
            if (acc.auth_kind) |k| {
                try j.objectField("authKind");
                try j.write(k.wire());
            }
            try j.objectField("switchable");
            try j.write(acc.switchable);
            if (acc.saved_at) |t| {
                try j.objectField("savedAt");
                try j.write(t);
            }
            try j.endObject();
        }
        try j.endArray();
        try j.objectField("warnings");
        try j.beginArray();
        for (s.warnings) |w| {
            try j.beginObject();
            try j.objectField("harness");
            try j.write(w.harness.slug());
            try j.objectField("message");
            try j.write(w.message);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
        return aw.toOwnedSlice();
    }
};

/// `StartAgentLoginParams`.
pub const StartParams = struct {
    harness: Harness,
    reauthenticate: bool = false,
    device_auth: bool = false,
    provider: ?[]const u8 = null,
    relay_browser: bool = false,
};

fn uuidBytes(io: Io) [16]u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return b;
}

/// `new_id`: a v4 UUID.
fn newId(a: Allocator, io: Io) ![]u8 {
    const b = uuidBytes(io);
    var hex: [32]u8 = undefined;
    _ = util.hexLower(&hex, &b);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

const ok_json = "{\"ok\":true}";

// ── the registry ───────────────────────────────────────────────────────────

/// The engine's agent-accounts service: one per engine, thread-safe. Flows
/// (and their login children) are owned here; `deinit` kills what is left.
pub const Registry = struct {
    /// Thread-safe allocator; owns every `Reply` payload.
    gpa: Allocator,
    io: Io,
    config: Config,
    /// Serializes operations that inspect and then mutate live credential
    /// stores and slots (Rust's `Inner::ops`).
    ops: Io.Mutex = .init,
    /// Guards the maps below.
    state: Io.Mutex = .init,
    flows: std.StringHashMapUnmanaged(*Flow) = .empty,
    /// Explicit recoveries in progress, one per route and account.
    reauth_starts: std.StringHashMapUnmanaged(LoginStart) = .empty,
    usage_cache: std.StringHashMapUnmanaged(CachedUsage) = .empty,
    /// Slots with a token refresh in flight (single-use refresh tokens).
    inflight_refreshes: std.StringHashMapUnmanaged(void) = .empty,

    /// `AgentAccounts::new(AgentAccountsConfig::detect(data_dir))`, with the
    /// environment from `catalog_core.currentEnv`.
    pub fn init(gpa: Allocator, io: Io, data_dir: []const u8) !*Registry {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var env = try catalog_core.currentEnv(arena.allocator());
        const cfg = try Config.detect(arena.allocator(), io, data_dir, &env);
        return initWithConfig(gpa, io, cfg);
    }

    /// With explicit paths (tests). Runs the startup sweep of `.login-*` dirs.
    pub fn initWithConfig(gpa: Allocator, io: Io, config: Config) !*Registry {
        const self = try gpa.create(Registry);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .config = try config.clone(gpa) };
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        slots_mod.sweepLoginDirs(arena.allocator(), io, self.config);
        return self;
    }

    /// `shutdown` (kill every login child, reclaim throwaway homes) and free.
    pub fn deinit(self: *Registry) void {
        self.shutdown();
        var it = self.reauth_starts.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.free(self.gpa);
        }
        self.reauth_starts.deinit(self.gpa);
        var uit = self.usage_cache.iterator();
        while (uit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.free(self.gpa);
        }
        self.usage_cache.deinit(self.gpa);
        var rit = self.inflight_refreshes.keyIterator();
        while (rit.next()) |k| self.gpa.free(k.*);
        self.inflight_refreshes.deinit(self.gpa);
        self.flows.deinit(self.gpa);
        self.config.free(self.gpa);
        self.gpa.destroy(self);
    }

    /// Engine shutdown: cancel every flow.
    pub fn shutdown(self: *Registry) void {
        while (true) {
            self.state.lockUncancelable(self.io);
            var it = self.flows.keyIterator();
            const first = it.next();
            const id: ?[]u8 = if (first) |k| self.gpa.dupe(u8, k.*) catch null else null;
            self.state.unlock(self.io);
            const i = id orelse return;
            defer self.gpa.free(i);
            self.cancelFlow(i);
        }
    }

    fn nowMs(self: *Registry) i64 {
        return @intCast(Io.Clock.real.now(self.io).toMilliseconds());
    }

    fn monoMs(self: *Registry) i64 {
        return @intCast(Io.Clock.awake.now(self.io).toMilliseconds());
    }

    fn sleepMs(self: *Registry, ms: u64) void {
        Io.sleep(self.io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
    }

    fn procEnv(_: *Registry, a: Allocator) !Environ.Map {
        return catalog_core.currentEnv(a);
    }

    fn reply(self: *Registry, c: *Call, result: anyerror![]const u8) Reply {
        const body = result catch |err| return .{ .failed = self.gpa.dupe(u8, c.errText(err)) catch &.{} };
        return .{ .ok = self.gpa.dupe(u8, body) catch &.{} };
    }

    // ── public API ─────────────────────────────────────────────────────────

    /// `ListAgentAccounts`: `list(force_usage)`. Slow when `force_usage`
    /// (one usage request per slot, 8 s each at most).
    pub fn snapshot(self: *Registry, force_usage: bool) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        return self.reply(&c, self.listJson(&c, force_usage));
    }

    /// Alias of `snapshot`, for `ListAgentAccounts` to switch to.
    pub fn snapshotJson(self: *Registry, force_usage: bool) Reply {
        return self.snapshot(force_usage);
    }

    /// `ActivateAgentAccount`: the snapshot after the swap.
    pub fn activate(self: *Registry, harness: Harness, account_id: []const u8) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        return self.reply(&c, self.activateInner(&c, harness, account_id));
    }

    /// `ForgetAgentAccount`: the snapshot after the removal.
    pub fn forget(self: *Registry, harness: Harness, account_id: []const u8) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        return self.reply(&c, self.forgetInner(&c, harness, account_id));
    }

    /// `StartAgentLogin` from its raw params: serde's parse (bad params),
    /// the RPC's branch checks and dispatch.
    pub fn start(self: *Registry, params: json.Value) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        const p = switch (parseStartParams(c.al(), params)) {
            .ok => |p| p,
            .bad => |m| return .{ .bad_params = self.gpa.dupe(u8, m) catch &.{} },
        };
        return self.startParsed(p);
    }

    /// `StartAgentLogin` with parsed params.
    pub fn startParsed(self: *Registry, p: StartParams) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        if (p.harness == .antigravity and !p.device_auth and !p.relay_browser) {
            return .{ .not_ported = self.gpa.dupe(u8, "antigravity's ACP sign-in (agent_accounts.rs start_antigravity_login) is not part of the Zig login registry") catch &.{} };
        }
        const result = self.startInner(&c, p);
        const s = result catch |err| return .{ .failed = self.gpa.dupe(u8, c.errText(err)) catch &.{} };
        return self.reply(&c, s.toJson(c.al()));
    }

    /// `CompleteAgentLogin`: a relayed ChatGPT redirect (`{"ok":true}`), an
    /// Anthropic Console code, or Claude's `code#state` (the snapshot).
    pub fn complete(self: *Registry, login_id: []const u8, code: []const u8) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        return self.reply(&c, self.completeInner(&c, login_id, code));
    }

    /// Rust's `complete_login` alone (no relay check): the path the RPC
    /// can't reach for graff's Anthropic Console sign-in (see `complete`).
    pub fn completeLogin(self: *Registry, login_id: []const u8, code: []const u8) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        return self.reply(&c, self.completeLoginInner(&c, login_id, code));
    }

    /// `PollAgentLogin`.
    pub fn poll(self: *Registry, login_id: []const u8) Reply {
        var c = Call.init(self.gpa);
        defer c.deinit();
        const r = self.pollInner(&c, login_id) catch |err| return .{ .failed = self.gpa.dupe(u8, c.errText(err)) catch &.{} };
        return self.reply(&c, r.toJson(c.al()));
    }

    /// `CancelAgentLogin`: always `{"ok":true}`.
    pub fn cancel(self: *Registry, login_id: []const u8) Reply {
        self.cancelFlow(login_id);
        return .{ .ok = self.gpa.dupe(u8, ok_json) catch &.{} };
    }

    /// Every method from its wire name and raw params (null for another method).
    pub fn handle(self: *Registry, method: []const u8, params: json.Value) ?Reply {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const eq = std.mem.eql;
        if (eq(u8, method, "StartAgentLogin")) return self.start(params);
        const which: enum { list, activate, forget, complete, poll, cancel } = if (eq(u8, method, "ListAgentAccounts"))
            .list
        else if (eq(u8, method, "ActivateAgentAccount"))
            .activate
        else if (eq(u8, method, "ForgetAgentAccount"))
            .forget
        else if (eq(u8, method, "CompleteAgentLogin"))
            .complete
        else if (eq(u8, method, "PollAgentLogin"))
            .poll
        else if (eq(u8, method, "CancelAgentLogin"))
            .cancel
        else
            return null;
        const struct_name = switch (which) {
            .list => "ListAgentAccountsParams",
            .activate, .forget => "AgentAccountParams",
            .complete => "CompleteAgentLoginParams",
            .poll, .cancel => "LoginIdParams",
        };
        const o = switch (params) {
            .object => |o| o,
            else => return self.bad(std.fmt.allocPrint(a, "invalid type: {s}, expected struct {s}", .{ util.unexpectedText(a, params) catch "?", struct_name })),
        };
        switch (which) {
            .list => {
                const force = optBool(a, o, "forceUsage", true) catch |e| return self.badErr(e, a);
                return self.snapshot(force orelse false);
            },
            .activate, .forget => {
                const h = reqHarness(a, o, "harness") catch |e| return self.badErr(e, a);
                const id = reqString(a, o, "accountId") catch |e| return self.badErr(e, a);
                return if (which == .activate) self.activate(h, id) else self.forget(h, id);
            },
            .complete => {
                const id = reqString(a, o, "loginId") catch |e| return self.badErr(e, a);
                const code = reqString(a, o, "code") catch |e| return self.badErr(e, a);
                return self.complete(id, code);
            },
            .poll, .cancel => {
                const id = reqString(a, o, "loginId") catch |e| return self.badErr(e, a);
                return if (which == .poll) self.poll(id) else self.cancel(id);
            },
        }
    }

    fn bad(self: *Registry, m: anyerror![]u8) Reply {
        const t = m catch return .{ .bad_params = &.{} };
        return .{ .bad_params = self.gpa.dupe(u8, t) catch &.{} };
    }

    fn badErr(self: *Registry, err: anyerror, a: Allocator) Reply {
        _ = a;
        return .{ .bad_params = self.gpa.dupe(u8, param_error_text orelse @errorName(err)) catch &.{} };
    }

    // ── list ───────────────────────────────────────────────────────────────

    fn listJson(self: *Registry, c: *Call, force: bool) ![]const u8 {
        self.ops.lockUncancelable(self.io);
        defer self.ops.unlock(self.io);
        return (try self.listLocked(c, force)).toJson(c.al());
    }

    fn list(self: *Registry, c: *Call, force: bool) !Snapshot {
        self.ops.lockUncancelable(self.io);
        defer self.ops.unlock(self.io);
        return self.listLocked(c, force);
    }

    /// `list_locked`: detect, auto-snapshot the live logins, assemble the view.
    /// Caller holds `ops`.
    fn listLocked(self: *Registry, c: *Call, force: bool) !Snapshot {
        const a = c.al();
        if (force) self.clearUsageCache();
        var warnings: std.ArrayList(Warning) = .empty;
        var active_keys: [3]?[]const u8 = .{ null, null, null };
        var unreadable: ?Detected = null;

        const claude = try self.detectClaude(c);
        if (claude.warning) |w| try warnings.append(a, .{ .harness = .claude_code, .message = w });
        if (claude.detected) |d| {
            active_keys[0] = d.account_key;
            if (d.credentials != null) try self.snapshotDetected(c, .claude_code, d) else unreadable = d;
        }
        if (try self.detectCodex(c)) |d| {
            active_keys[1] = d.account_key;
            try self.snapshotDetected(c, .codex, d);
        }
        if (try self.detectCursor(c)) |d| {
            active_keys[2] = d.account_key;
            try self.snapshotDetected(c, .cursor, d);
            if (!self.cursorLiveUsable(c)) try warnings.append(a, .{ .harness = .cursor, .message = "The connected Cursor login's API key has expired \u{2014} connect again." });
        }

        var accounts: std.ArrayList(Account) = .empty;
        for ([_]Harness{ .claude_code, .codex, .cursor }, 0..) |h, hi| {
            const active_key = active_keys[hi];
            const list_slots = slots_mod.readSlots(a, self.io, self.config, h);
            for (list_slots) |slot| {
                const active = if (active_key) |k| std.mem.eql(u8, k, slot.account_key) else false;
                const may_refresh = h == .claude_code and mayRefreshClaudeSlot(slot, claude.detected);
                const usage = try self.usageFor(c, h, slot, may_refresh, force);
                try accounts.append(a, .{
                    .id = slot.id,
                    .harness = h,
                    .email = slot.profile.email,
                    .plan_label = if (usage) |u| (u.plan_label orelse slot.profile.plan) else slot.profile.plan,
                    .active = active,
                    .usage_windows = if (usage) |u| u.windows else &.{},
                    .display_name = slot.profile.display_name,
                    .organization = slot.profile.organization,
                    .auth_kind = slot.profile.auth_kind,
                    .switchable = true,
                    .saved_at = slot.saved_at,
                });
            }
            if (h == .claude_code) if (unreadable) |u| {
                var has = false;
                for (list_slots) |s| {
                    if (std.mem.eql(u8, s.account_key, u.account_key)) has = true;
                }
                if (!has) {
                    const id = util.slotIdFor(h, u.account_key);
                    try accounts.append(a, .{
                        .id = try a.dupe(u8, &id),
                        .harness = h,
                        .email = u.profile.email,
                        .plan_label = u.profile.plan,
                        .active = true,
                        .display_name = u.profile.display_name,
                        .organization = u.profile.organization,
                        .auth_kind = u.profile.auth_kind,
                        .switchable = false,
                        .saved_at = null,
                    });
                }
            };
        }
        return .{ .accounts = accounts.items, .warnings = warnings.items };
    }

    // ── swap ───────────────────────────────────────────────────────────────

    fn activateInner(self: *Registry, c: *Call, harness: Harness, account_id: []const u8) ![]const u8 {
        self.ops.lockUncancelable(self.io);
        defer self.ops.unlock(self.io);
        _ = try self.listLocked(c, false);
        const slot = findSlot(slots_mod.readSlots(c.al(), self.io, self.config, harness), account_id) orelse
            return c.failText("That saved login no longer exists \u{2014} refresh and try again.");
        switch (harness) {
            .claude_code => try self.activateClaude(c, slot),
            .codex => try self.activateCodex(c, slot),
            .cursor => try self.writeCursorAuth(c, slot.credentials),
            else => return c.fail("agent accounts are not supported for {s}", .{harness.debugName()}),
        }
        return (try self.listLocked(c, false)).toJson(c.al());
    }

    fn activateClaude(self: *Registry, c: *Call, slot: Slot) !void {
        const a = c.al();
        // The slot owns the account login; live owns the MCP/plugin OAuth in
        // the same blob.
        const live = self.readClaudeCredentials(c);
        try self.writeClaudeCredentials(c, try util.composeClaudeCredentials(a, slot.credentials, live.credentials));
        // A parse failure on an EXISTING ~/.claude.json means "don't touch it".
        const file = self.config.claude_config_file;
        const cfg = slots_mod.readJson(a, self.io, file);
        if (cfg == null and slots_mod.exists(self.io, file)) {
            return c.failText("~/.claude.json exists but could not be parsed \u{2014} not switching to avoid wiping it. Fix or remove the file and try again.");
        }
        var merged = cfg orelse util.newObject();
        if (merged != .object) return c.failText("~/.claude.json is not a JSON object \u{2014} not switching.");
        var oauth_account: ?json.Value = null;
        var user_id: ?json.Value = null;
        if (slot.claude_config) |cc| {
            oauth_account = util.get(cc, "oauthAccount");
            user_id = util.get(cc, "userID");
        }
        const fallback = blk: {
            var o: json.ObjectMap = .empty;
            try o.put(a, "accountUuid", .{ .string = slot.account_key });
            try o.put(a, "emailAddress", .{ .string = slot.profile.email });
            try o.put(a, "organizationName", util.strValue(slot.profile.organization));
            try o.put(a, "displayName", util.strValue(slot.profile.display_name));
            break :blk json.Value{ .object = o };
        };
        try merged.object.put(a, "oauthAccount", oauth_account orelse fallback);
        if (user_id) |u| {
            if (u == .string) try merged.object.put(a, "userID", u) else _ = merged.object.swapRemove("userID");
        } else _ = merged.object.swapRemove("userID");
        try slots_mod.writeFileAtomic(a, self.io, file, try util.stringify(a, merged), false);
    }

    fn activateCodex(self: *Registry, c: *Call, slot: Slot) !void {
        const a = c.al();
        try Io.Dir.cwd().createDirPath(self.io, self.config.codex_home);
        try slots_mod.writeFileAtomic(a, self.io, try self.config.codexAuthFile(a), try util.stringifyPretty(a, slot.credentials), true);
    }

    fn writeCursorAuth(self: *Registry, c: *Call, credentials: json.Value) !void {
        const a = c.al();
        const file = self.config.cursor_sdk_auth_file;
        if (std.fs.path.dirname(file)) |d| try Io.Dir.cwd().createDirPath(self.io, d);
        try slots_mod.writeFileAtomic(a, self.io, file, try util.stringifyPretty(a, credentials), true);
    }

    // ── forget ─────────────────────────────────────────────────────────────

    const changed_text = "The live login changed while it was being removed \u{2014} refresh and try again.";

    fn forgetInner(self: *Registry, c: *Call, harness: Harness, account_id: []const u8) ![]const u8 {
        // A raw RPC string becomes a path: only a slot id may reach the disk.
        if (!util.isSlotId(account_id)) return c.failText("Unknown account.");
        self.ops.lockUncancelable(self.io);
        defer self.ops.unlock(self.io);
        const snap = try self.listLocked(c, false);
        var active = false;
        for (snap.accounts) |acc| {
            if (acc.harness == harness and acc.active and std.mem.eql(u8, acc.id, account_id)) active = true;
        }
        if (active) {
            const expected = (try self.liveAccountKey(c, harness)) orelse return c.failText(changed_text);
            if (!std.mem.eql(u8, &util.slotIdFor(harness, expected), account_id)) return c.failText(changed_text);
            try self.signOut(c, harness, expected);
        }
        const dir = try slots_mod.slotsDir(c.al(), self.io, self.config, harness);
        const file = try std.fs.path.join(c.al(), &.{ dir, try std.fmt.allocPrint(c.al(), "{s}.json", .{account_id}) });
        if (slots_mod.exists(self.io, file)) try Io.Dir.cwd().deleteFile(self.io, file);
        return (try self.listLocked(c, false)).toJson(c.al());
    }

    /// `live_account_key`: from the identity alone (no secret read).
    fn liveAccountKey(self: *Registry, c: *Call, harness: Harness) !?[]const u8 {
        switch (harness) {
            .claude_code => {
                const cfg = slots_mod.readJson(c.al(), self.io, self.config.claude_config_file) orelse return null;
                const oauth = util.get(cfg, "oauthAccount") orelse return null;
                return util.strField(oauth, "accountUuid") orelse util.strField(oauth, "emailAddress");
            },
            .codex => return if (try self.detectCodex(c)) |d| d.account_key else null,
            .cursor => return if (try self.detectCursor(c)) |d| d.account_key else null,
            else => return null,
        }
    }

    fn liveIs(self: *Registry, c: *Call, harness: Harness, key: []const u8) !bool {
        const live = (try self.liveAccountKey(c, harness)) orelse return false;
        return std.mem.eql(u8, live, key);
    }

    /// `adopt_if_live`: a fresh sign-in replaces the live login only when it
    /// IS the live account, or there is no (usable) live login.
    fn adoptIfLive(self: *Registry, c: *Call, slot: Slot) !void {
        const live = try self.liveAccountKey(c, slot.harness);
        const usable = if (slot.harness == .cursor) self.cursorLiveUsable(c) else live != null;
        if (usable and !(live != null and std.mem.eql(u8, live.?, slot.account_key))) return;
        switch (slot.harness) {
            .claude_code => try self.activateClaude(c, slot),
            .codex => try self.activateCodex(c, slot),
            .cursor => try self.writeCursorAuth(c, slot.credentials),
            else => {},
        }
    }

    /// `sign_out`: sign the CLI's live login out so removing its slot sticks.
    fn signOut(self: *Registry, c: *Call, harness: Harness, expected: []const u8) !void {
        const a = c.al();
        if (!try self.liveIs(c, harness, expected)) return c.failText(changed_text);
        switch (harness) {
            .claude_code => {
                const live = self.readClaudeCredentials(c);
                if (!try self.liveIs(c, harness, expected)) return c.failText(changed_text);
                if (live.credentials) |creds| {
                    var cr = creds;
                    if (cr == .object) _ = cr.object.swapRemove("claudeAiOauth");
                    try self.writeClaudeCredentials(c, cr);
                } else if (live.warning) |w| {
                    return c.fail("Couldn't sign Claude out: {s}", .{w});
                }
                const file = self.config.claude_config_file;
                if (slots_mod.readJson(a, self.io, file)) |cfg_in| {
                    var cfg = cfg_in;
                    if (cfg.object.swapRemove("oauthAccount")) try slots_mod.writeFileAtomic(a, self.io, file, try util.stringify(a, cfg), false);
                }
            },
            .codex => try slots_mod.removeIfExists(self.io, try self.config.codexAuthFile(a)),
            .cursor => try slots_mod.removeIfExists(self.io, self.config.cursor_sdk_auth_file),
            else => return c.failText("That's the live login \u{2014} it can't be removed here."),
        }
    }

    // ── starts ─────────────────────────────────────────────────────────────

    fn startInner(self: *Registry, c: *Call, p: StartParams) !LoginStart {
        if (p.device_auth and (!p.reauthenticate or p.harness != .codex)) {
            return c.failText("Device authorization is supported only for explicit Codex recovery.");
        }
        if (p.relay_browser and (p.harness != .graff or p.provider == null or !std.mem.eql(u8, p.provider.?, "chatgpt-new"))) {
            return c.failText("Finishing sign-in on another device is supported only for graff's ChatGPT sign-in.");
        }
        if (p.harness == .graff) {
            const provider = p.provider orelse return c.failText("Say which graff provider to sign in to.");
            if (p.reauthenticate) return self.startGraffReauth(c, provider, p.relay_browser);
            return self.startGraffLogin(c, provider, p.relay_browser);
        }
        if (p.harness == .codex and p.reauthenticate) return self.startCodexReauth(c, p.device_auth);
        if (p.device_auth) return c.failText("Device sign-in is not supported for this provider.");
        return self.startLogin(c, p.harness);
    }

    /// `start_login`.
    fn startLogin(self: *Registry, c: *Call, harness: Harness) !LoginStart {
        self.sweepFlows();
        return switch (harness) {
            .claude_code => self.startClaudeLogin(c, false),
            .codex => self.startCodexLogin(c, false, false),
            .cursor => self.startCursorLogin(c),
            else => c.fail("agent logins are not supported for {s}", .{harness.debugName()}),
        };
    }

    fn insertFlow(self: *Registry, login_id: []const u8, flow: *Flow) !void {
        const key = try self.gpa.dupe(u8, login_id);
        errdefer self.gpa.free(key);
        self.state.lockUncancelable(self.io);
        defer self.state.unlock(self.io);
        try self.flows.put(self.gpa, key, flow);
    }

    fn newFlow(self: *Registry, kind: Flow.Kind) !*Flow {
        const f = try self.gpa.create(Flow);
        f.* = .{ .started_ms = self.monoMs(), .kind = kind };
        return f;
    }

    /// `start_claude_login_then`: PKCE (32 random bytes as the verifier, S256).
    fn startClaudeLogin(self: *Registry, c: *Call, then_graff: bool) !LoginStart {
        const a = c.al();
        const login_id = try newId(a, self.io);
        var raw: [32]u8 = undefined;
        raw[0..16].* = uuidBytes(self.io);
        raw[16..32].* = uuidBytes(self.io);
        var vbuf: [43]u8 = undefined;
        const verifier = std.base64.url_safe_no_pad.Encoder.encode(&vbuf, &raw);
        var digest: [32]u8 = undefined;
        Sha256.hash(verifier, &digest, .{});
        var cbuf: [43]u8 = undefined;
        const challenge = std.base64.url_safe_no_pad.Encoder.encode(&cbuf, &digest);
        const url = try std.fmt.allocPrint(a, "https://claude.ai/oauth/authorize?code=true&client_id={s}&response_type=code&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}", .{
            claude_client_id, try util.urlencode(a, claude_redirect), try util.urlencode(a, claude_scopes), challenge, verifier,
        });
        const v = try self.gpa.dupe(u8, verifier);
        errdefer self.gpa.free(v);
        const flow = try self.newFlow(.{ .claude = .{ .verifier = v, .then_graff = then_graff } });
        errdefer self.gpa.destroy(flow);
        try self.insertFlow(login_id, flow);
        return .{ .login_id = login_id, .url = url, .mode = .paste_code };
    }

    /// `reap_spawned_flows`: supersede pending spawned flows for `harness`.
    fn reapSpawnedFlows(self: *Registry, harness: Harness) void {
        self.reapWhere(.{ .spawned = harness });
    }

    /// `reap_graff_flows`.
    fn reapGraffFlows(self: *Registry, provider: []const u8) void {
        self.reapWhere(.{ .graff = provider });
    }

    const Match = union(enum) { spawned: Harness, graff: []const u8, stale: i64 };

    fn reapWhere(self: *Registry, m: Match) void {
        var ids: std.ArrayList([]u8) = .empty;
        defer {
            for (ids.items) |i| self.gpa.free(i);
            ids.deinit(self.gpa);
        }
        {
            self.state.lockUncancelable(self.io);
            defer self.state.unlock(self.io);
            var it = self.flows.iterator();
            while (it.next()) |e| {
                const f = e.value_ptr.*;
                const hit = switch (m) {
                    .spawned => |h| f.kind == .spawned and f.kind.spawned.harness == h,
                    .graff => |p| f.kind == .graff and std.mem.eql(u8, f.kind.graff.provider, p),
                    .stale => |now| now - f.started_ms > flow_ttl_ms,
                };
                if (hit) ids.append(self.gpa, self.gpa.dupe(u8, e.key_ptr.*) catch continue) catch {};
            }
        }
        for (ids.items) |i| self.cancelFlow(i);
    }

    /// `sweep_flows`: the lazy `FLOW_TTL` reap.
    fn sweepFlows(self: *Registry) void {
        self.reapWhere(.{ .stale = self.monoMs() });
    }

    /// `cancel_login`: drop a flow, kill its child, reclaim its throwaway home.
    fn cancelFlow(self: *Registry, login_id: []const u8) void {
        const flow = blk: {
            self.state.lockUncancelable(self.io);
            defer self.state.unlock(self.io);
            const kv = self.flows.fetchRemove(login_id) orelse return;
            self.gpa.free(kv.key);
            break :blk kv.value;
        };
        switch (flow.kind) {
            .spawned => |s| {
                s.child.kill();
                Io.Dir.cwd().deleteTree(self.io, s.home) catch {};
            },
            .graff => |g| g.child.kill(),
            .claude => {},
        }
        flow.destroy(self.gpa);
    }

    /// A retained reference to a flow's child (null when gone or childless).
    fn flowChild(self: *Registry, login_id: []const u8) ?*LoginChild {
        self.state.lockUncancelable(self.io);
        defer self.state.unlock(self.io);
        const f = self.flows.get(login_id) orelse return null;
        const ch = f.child() orelse return null;
        return ch.retain();
    }

    /// `start_codex_reauth`: attach to a recovery already waiting on this
    /// host, else snapshot the live login and start one.
    fn startCodexReauth(self: *Registry, c: *Call, device_auth: bool) !LoginStart {
        const account = if (try self.detectCodex(c)) |d| d.account_key else "";
        const route = try util.reauthRoute(c.al(), "codex", device_auth, account);
        if (try self.pendingReauth(c, route)) |s| return s;
        _ = try self.list(c, false);
        const s = try self.startCodexLogin(c, true, device_auth);
        try self.rememberReauth(route, s);
        return s;
    }

    /// `start_graff_reauth`.
    fn startGraffReauth(self: *Registry, c: *Call, provider: []const u8, relay: bool) !LoginStart {
        const route = try util.reauthRoute(c.al(), "graff", relay, provider);
        if (try self.pendingReauth(c, route)) |s| return s;
        const s = try self.startGraffLogin(c, provider, relay);
        try self.rememberReauth(route, s);
        return s;
    }

    fn rememberReauth(self: *Registry, route: []const u8, s: LoginStart) !void {
        const owned = try s.clone(self.gpa);
        errdefer owned.free(self.gpa);
        self.state.lockUncancelable(self.io);
        defer self.state.unlock(self.io);
        const gop = try self.reauth_starts.getOrPut(self.gpa, route);
        if (gop.found_existing) {
            gop.value_ptr.free(self.gpa);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, route) catch {
                _ = self.reauth_starts.remove(route);
                return error.OutOfMemory;
            };
        }
        gop.value_ptr.* = owned;
    }

    /// `pending_reauth`: the recovery waiting for `route` while its flow is pending.
    fn pendingReauth(self: *Registry, c: *Call, route: []const u8) !?LoginStart {
        self.sweepFlows();
        self.state.lockUncancelable(self.io);
        defer self.state.unlock(self.io);
        const s = self.reauth_starts.get(route) orelse return null;
        const live = if (self.flows.get(s.login_id)) |f| f.pending() else false;
        if (live) return try s.clone(c.al());
        if (self.reauth_starts.fetchRemove(route)) |kv| {
            self.gpa.free(kv.key);
            kv.value.free(self.gpa);
        }
        return null;
    }

    fn rootDir(self: *Registry, a: Allocator) ![]u8 {
        return self.config.rootDir(a);
    }

    /// `ensure_noop_browser`: `{root}/.noop-browser` (Unix only).
    fn noopBrowser(self: *Registry, a: Allocator) ?[]u8 {
        if (builtin.os.tag == .windows) return null;
        const root = self.rootDir(a) catch return null;
        const p = std.fs.path.join(a, &.{ root, ".noop-browser" }) catch return null;
        return if (graff.ensureNoopScript(a, self.io, p)) p else null;
    }

    /// A throwaway credential home under the accounts root.
    fn loginHome(self: *Registry, a: Allocator, login_id: []const u8) ![]u8 {
        const home = try std.fs.path.join(a, &.{ try self.rootDir(a), try std.fmt.allocPrint(a, ".login-{s}", .{login_id}) });
        try Io.Dir.cwd().createDirPath(self.io, home);
        return home;
    }

    /// `start_codex_login`: `codex login` against a throwaway `CODEX_HOME`.
    fn startCodexLogin(self: *Registry, c: *Call, reauthenticate: bool, device_auth: bool) !LoginStart {
        const a = c.al();
        self.reapSpawnedFlows(.codex);
        const login_id = try newId(a, self.io);
        const home = try self.loginHome(a, login_id);
        const exe = (catalog_core.resolve_cli(a, self.io, "codex") catch |err| {
            Io.Dir.cwd().deleteTree(self.io, home) catch {};
            return c.fail("Could not resolve the codex CLI for login: {s}", .{@errorName(err)});
        }) orelse {
            Io.Dir.cwd().deleteTree(self.io, home) catch {};
            return c.fail("The `codex` CLI was not found on this device \u{2014} install it first. ({s})", .{codex_install_hint});
        };
        var child_env = try proc.childEnv(a, self.io, exe, null);
        try child_env.put("CODEX_HOME", home);
        if (!reauthenticate) if (self.noopBrowser(a)) |b| try child_env.put("BROWSER", b);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ exe, "login" });
        if (device_auth) try argv.append(a, "--device-auth");
        const child = LoginChild.spawn(self.io, argv.items, &child_env, false) catch |err| {
            Io.Dir.cwd().deleteTree(self.io, home) catch {};
            return switch (err) {
                error.NotFound => c.failText("The `codex` CLI was not found on this device \u{2014} install it first."),
                else => c.fail("Could not start codex login: {s}", .{@errorName(err)}),
            };
        };
        const watch = child.retain();
        defer watch.release();
        const owned_home = self.gpa.dupe(u8, home) catch |e| {
            child.kill();
            child.release();
            return e;
        };
        const flow = self.newFlow(.{ .spawned = .{ .harness = .codex, .reauthenticate = reauthenticate, .child = child, .home = owned_home } }) catch |e| {
            child.kill();
            child.release();
            self.gpa.free(owned_home);
            return e;
        };
        self.insertFlow(login_id, flow) catch |e| {
            child.kill();
            flow.destroy(self.gpa);
            return e;
        };
        if (device_auth) return self.awaitDeviceLogin(c, login_id, watch);
        const url: []const u8 = if (reauthenticate) "" else try self.awaitLoginUrl(c, watch, .openai);
        return .{ .login_id = login_id, .url = url, .mode = if (reauthenticate) .host_browser else .browser };
    }

    /// `await_device_login`: Codex's device prompt within `device_wait_ms`.
    fn awaitDeviceLogin(self: *Registry, c: *Call, login_id: []const u8, child: *LoginChild) !LoginStart {
        const deadline = self.monoMs() + @as(i64, @intCast(device_wait_ms));
        while (true) {
            const out = try child.outputDupe(c.al());
            if (try util.codexDeviceCode(c.al(), login_id, out)) |code| {
                return .{ .login_id = login_id, .url = util.codex_device_url, .mode = .device_code, .code = code };
            }
            if (child.exitStatus() != null or self.monoMs() > deadline) {
                self.cancelFlow(login_id);
                return c.failText("Device sign-in did not start. Update the agent CLI and enable device-code login in your ChatGPT security settings, then try again.");
            }
            self.sleepMs(100);
        }
    }

    const UrlScan = enum { openai, cursor };

    /// `await_login_url`: the printed authorize URL, or "" when the child
    /// exits or stays silent past `login_url_wait_ms`.
    fn awaitLoginUrl(self: *Registry, c: *Call, child: *LoginChild, scan: UrlScan) ![]const u8 {
        const deadline = self.monoMs() + @as(i64, @intCast(login_url_wait_ms));
        while (true) {
            const out = try child.outputDupe(c.al());
            const found = switch (scan) {
                .openai => util.scanOpenaiUrl(out),
                .cursor => util.scanCursorUrl(c.al(), out),
            };
            if (found) |u| return u;
            if (child.exitStatus() != null or self.monoMs() > deadline) return "";
            self.sleepMs(100);
        }
    }

    /// `start_cursor_login`: the shim's login mode minting into a throwaway store.
    fn startCursorLogin(self: *Registry, c: *Call) !LoginStart {
        const a = c.al();
        self.reapSpawnedFlows(.cursor);
        const login_id = try newId(a, self.io);
        const home = try self.loginHome(a, login_id);
        const launch = resolve_cursor_shim(a, self.io) catch |err| {
            Io.Dir.cwd().deleteTree(self.io, home) catch {};
            return c.fail("Could not start the Cursor login: {s}", .{@errorName(err)});
        };
        var child_env = try proc.childEnv(a, self.io, launch.exe, null);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, launch.exe);
        try argv.appendSlice(a, launch.args);
        try argv.appendSlice(a, &.{ "login", try std.fs.path.join(a, &.{ home, "auth.json" }) });
        const child = LoginChild.spawn(self.io, argv.items, &child_env, false) catch |err| {
            Io.Dir.cwd().deleteTree(self.io, home) catch {};
            return c.fail("Could not start the Cursor login: {s}", .{@errorName(err)});
        };
        const watch = child.retain();
        defer watch.release();
        const owned_home = self.gpa.dupe(u8, home) catch |e| {
            child.kill();
            child.release();
            return e;
        };
        const flow = self.newFlow(.{ .spawned = .{ .harness = .cursor, .reauthenticate = false, .child = child, .home = owned_home } }) catch |e| {
            child.kill();
            child.release();
            self.gpa.free(owned_home);
            return e;
        };
        self.insertFlow(login_id, flow) catch |e| {
            child.kill();
            flow.destroy(self.gpa);
            return e;
        };
        return .{ .login_id = login_id, .url = try self.awaitLoginUrl(c, watch, .cursor), .mode = .browser };
    }

    // ── graff sign-ins ─────────────────────────────────────────────────────

    /// `start_graff_login_with`.
    fn startGraffLogin(self: *Registry, c: *Call, provider: []const u8, relay_browser: bool) !LoginStart {
        const a = c.al();
        self.sweepFlows();
        const penv = try self.procEnv(a);
        const home = self.config.graff_home;
        if ((try graff.credentialPath(a, self.io, home, provider, &penv)) == null) {
            return c.fail("graff can't sign in to {s} from here", .{provider});
        }
        const is_chatgpt = std.mem.eql(u8, provider, "chatgpt-new");
        if (relay_browser and !is_chatgpt) return c.fail("{s} sign-in can't be finished on another device", .{provider});
        self.reapGraffFlows(provider);
        const root = try self.rootDir(a);
        const no_open: ?[]u8 = if (Io.Dir.cwd().createDirPath(self.io, root)) graff.noOpenDir(a, self.io, root) else |_| null;
        if (relay_browser and no_open == null) return c.failText("This execution device can't hand its ChatGPT sign-in to another device.");
        const exe = (catalog_core.resolve_cli(a, self.io, "graff") catch |err| {
            return c.fail("Could not resolve the graff CLI for sign-in: {s}", .{@errorName(err)});
        }) orelse return c.fail("The `graff` CLI was not found on this device \u{2014} install it first. ({s})", .{graff_install_hint});
        var child_env = try proc.childEnv(a, self.io, exe, if (is_chatgpt and !relay_browser) null else no_open);
        try child_env.put("NO_COLOR", "1");
        if (is_chatgpt) _ = child_env.swapRemove("GRAFF_NO_BROWSER") else try child_env.put("GRAFF_NO_BROWSER", "1");
        if (builtin.os.tag != .windows) try child_env.put("HOME", home);
        const pastes_code = std.mem.eql(u8, provider, "anthropic");
        const before = graff.credentialStamp(a, self.io, home, provider, &penv);
        const first_registration = is_chatgpt and !(if (graff.chatgptRecord(a, self.io, home, &penv)) |r| r.registered else false);
        const child = LoginChild.spawn(self.io, &.{ exe, "login", provider }, &child_env, pastes_code) catch |err| return switch (err) {
            error.NotFound => c.failText("The `graff` CLI was not found on this device \u{2014} install it first."),
            else => c.fail("Could not start graff login: {s}", .{@errorName(err)}),
        };
        const watch = child.retain();
        defer watch.release();
        const login_id = newId(a, self.io) catch |e| {
            child.kill();
            child.release();
            return e;
        };
        const owned_provider = self.gpa.dupe(u8, provider) catch |e| {
            child.kill();
            child.release();
            return e;
        };
        const flow = self.newFlow(.{ .graff = .{ .provider = owned_provider, .child = child, .before = before, .first_registration = first_registration, .relay = null } }) catch |e| {
            child.kill();
            child.release();
            self.gpa.free(owned_provider);
            return e;
        };
        self.insertFlow(login_id, flow) catch |e| {
            child.kill();
            flow.destroy(self.gpa);
            return e;
        };
        const deadline = self.monoMs() + @as(i64, @intCast(graff_start_wait_ms));
        if (relay_browser) {
            // Hand out the page only once graff listens for its callback.
            const relay = while (true) {
                if (try graff.scanChatgptRelay(a, try watch.outputDupe(a))) |r| break r;
                if (watch.exitStatus() != null or self.monoMs() > deadline) {
                    self.cancelFlow(login_id);
                    return c.failText("ChatGPT sign-in did not start on the execution device. Update graff there and try again.");
                }
                self.sleepMs(100);
            };
            {
                self.state.lockUncancelable(self.io);
                defer self.state.unlock(self.io);
                if (self.flows.get(login_id)) |f| if (f.kind == .graff) {
                    if (f.kind.graff.relay) |old| old.free(self.gpa);
                    f.kind.graff.relay = relay.clone(self.gpa) catch null;
                };
            }
            return .{ .login_id = login_id, .url = relay.url, .mode = .relay_browser };
        }
        if (is_chatgpt) {
            while (true) {
                const out = try watch.outputDupe(a);
                if (std.mem.indexOf(u8, out, "waiting for the sign-in on ") != null or watch.exitStatus() != null) break;
                if (self.monoMs() > deadline) {
                    self.cancelFlow(login_id);
                    return c.failText("ChatGPT sign-in did not start on the execution device. Try again there.");
                }
                self.sleepMs(100);
            }
            // Authorization URLs can carry id_token_hint: they stay on the host.
            return .{ .login_id = login_id, .url = "", .mode = .host_browser };
        }
        if (std.mem.eql(u8, provider, "claude-agent")) {
            while (watch.exitStatus() == null) {
                if (self.monoMs() > deadline) {
                    self.cancelFlow(login_id);
                    return c.failText("Claude Code did not answer in time. Check that `claude` runs on this device.");
                }
                self.sleepMs(100);
            }
            const out = try watch.outputDupe(a);
            if (!try graff.sawSuccess(a, out)) {
                self.cancelFlow(login_id);
                // No Claude Code login yet: Harness's own Claude Code sign-in
                // makes one, then graff records the choice (complete).
                if (try graff.claudeCodeSignedOut(a, out)) return self.startClaudeLogin(c, true);
                return c.failText(try graff.failureMessage(a, out));
            }
            return .{ .login_id = login_id, .url = "", .mode = .browser };
        }
        const url = while (true) {
            if (graff.scanLoginUrl(try watch.outputDupe(a))) |u| break try a.dupe(u8, u);
            if (watch.exitStatus() != null or self.monoMs() > deadline) break null;
            self.sleepMs(100);
        };
        const out = try watch.outputDupe(a);
        const u = url orelse {
            const message = if (std.mem.trim(u8, out, &std.ascii.whitespace).len == 0 and watch.exitStatus() == null)
                "graff did not offer a sign-in link in time \u{2014} check the connection and try again."
            else
                try graff.failureMessage(a, out);
            self.cancelFlow(login_id);
            return c.failText(message);
        };
        const code = graff.scanDeviceCode(out);
        return .{ .login_id = login_id, .url = u, .mode = if (pastes_code) .paste_code else .browser, .code = if (code) |x| try a.dupe(u8, x) else null };
    }

    const GraffSnap = struct { provider: []const u8, child: *LoginChild, before: ?i96, first_registration: bool, relay: ?graff.ChatgptRelay };

    /// A graff flow's fields copied into `a`, its child retained.
    fn graffFlow(self: *Registry, a: Allocator, login_id: []const u8) !?GraffSnap {
        self.state.lockUncancelable(self.io);
        defer self.state.unlock(self.io);
        const f = self.flows.get(login_id) orelse return null;
        if (f.kind != .graff) return null;
        const g = f.kind.graff;
        return .{
            .provider = try a.dupe(u8, g.provider),
            .child = g.child.retain(),
            .before = g.before,
            .first_registration = g.first_registration,
            .relay = if (g.relay) |r| try r.clone(a) else null,
        };
    }

    /// `poll_graff_login`; null when `login_id` isn't a graff sign-in.
    fn pollGraffLogin(self: *Registry, c: *Call, login_id: []const u8) !?LoginPoll {
        const a = c.al();
        const g = (try self.graffFlow(a, login_id)) orelse return null;
        defer g.child.release();
        const exit = g.child.exitStatus() orelse return .{ .status = .pending };
        const out = try g.child.outputDupe(a);
        const penv = try self.procEnv(a);
        const stamp = graff.credentialStamp(a, self.io, self.config.graff_home, g.provider, &penv);
        const is_chatgpt = std.mem.eql(u8, g.provider, "chatgpt-new");
        const changed = stamp != null and (g.before == null or stamp.? != g.before.?);
        const landed = exit.code != null and exit.code.? == 0 and
            (if (is_chatgpt) changed and try graff.chatgptPlanGranted(a, out) else changed or try graff.sawSuccess(a, out));
        self.cancelFlow(login_id);
        if (landed) return .{ .status = .done, .message = if (is_chatgpt and g.first_registration) graff.chatgpt_plan_confirmation else null };
        const message: []const u8 = if (is_chatgpt)
            (if (try graff.chatgptPlanDenied(a, out)) graff.chatgpt_plan_off else "ChatGPT sign-in did not grant plan access. Sign in again and allow plan usage.")
        else
            try graff.failureMessage(a, out);
        return .{ .status = .@"error", .message = message };
    }

    /// `complete_graff_paste`: hand Anthropic's code to `ant auth login`
    /// (run by graff); null when `login_id` is not such a sign-in.
    fn completeGraffPaste(self: *Registry, c: *Call, login_id: []const u8, code_in: []const u8) !?void {
        const a = c.al();
        const g = (try self.graffFlow(a, login_id)) orelse return null;
        defer g.child.release();
        if (!std.mem.eql(u8, g.provider, "anthropic")) return null;
        const code = std.mem.trim(u8, code_in, &std.ascii.whitespace);
        if (code.len == 0) return c.failText("That code looks empty \u{2014} paste the whole code.");
        g.child.writeStdinOnce(try std.fmt.allocPrint(a, "{s}\n", .{code})) catch |err| switch (err) {
            error.NoStdin => return c.failText("This sign-in attempt expired \u{2014} start again."),
            else => return c.fail("Could not hand the code to the sign-in: {s}", .{@errorName(err)}),
        };
        _ = g.child.waitExit(graff_paste_wait_ms);
        const out = try g.child.outputDupe(a);
        if (try graff.sawSuccess(a, out)) return {};
        return c.failText(try graff.failureMessage(a, out));
    }

    /// `complete_relayed_login`: deliver the redirect another device landed
    /// on to graff's loopback callback; null when not a graff sign-in.
    fn completeRelayed(self: *Registry, c: *Call, login_id: []const u8, landed: []const u8) !?void {
        const a = c.al();
        const g = (try self.graffFlow(a, login_id)) orelse return null;
        defer g.child.release();
        const relay = g.relay orelse return c.failText("This sign-in finishes in the execution device's browser.");
        const callback = switch (try graff.relayedCallback(a, relay, landed)) {
            .ok => |u| u,
            .err => |m| return c.failText(m),
        };
        const started = self.monoMs();
        // graff answers only after its code exchange; only a refused
        // connection means its listener is gone.
        _ = http.send(a, self.io, .{ .url = callback, .timeout_ms = @intCast(relay_finish_wait_ms) }) catch |err| switch (err) {
            error.Connect => {
                const p = try self.pollGraffLogin(c, login_id);
                if (p) |pp| if (pp.status == .@"error") if (pp.message) |m| {
                    return c.fail("The sign-in on the execution device already ended: {s}", .{m});
                };
                return c.failText("The execution device is no longer waiting for this sign-in. Start again.");
            },
            else => http.Response{ .status = 0, .body = &.{} },
        };
        while (g.child.exitStatus() == null and self.monoMs() - started < @as(i64, @intCast(relay_finish_wait_ms))) self.sleepMs(200);
        if (try self.pollGraffLogin(c, login_id)) |p| if (p.status == .@"error") {
            return c.failText(p.message orelse "The sign-in did not finish.");
        };
    }

    /// `record_graff_claude_agent`: Claude Code is signed in now.
    fn recordGraffClaudeAgent(self: *Registry, c: *Call) !void {
        const a = c.al();
        const exe = (catalog_core.resolve_cli(a, self.io, "graff") catch |err| {
            return c.fail("Could not run graff: {s}", .{@errorName(err)});
        }) orelse return c.fail("Could not run graff: harness binary not found: {s}", .{graff_install_hint});
        var child_env = try proc.childEnv(a, self.io, exe, null);
        try child_env.put("NO_COLOR", "1");
        try child_env.put("GRAFF_NO_BROWSER", "1");
        if (builtin.os.tag != .windows) try child_env.put("HOME", self.config.graff_home);
        const cap = proc.runCapture(a, self.io, &.{ exe, "login", "claude-agent" }, &child_env, graff_record_timeout_ms) catch |err| {
            return c.fail("Could not run graff login: {s}", .{@errorName(err)});
        };
        if (cap.timed_out) return c.failText("graff did not finish the Claude Agent sign-in.");
        const text = try std.mem.concat(a, u8, &.{ cap.stdout, cap.stderr });
        if (try graff.sawSuccess(a, text)) return;
        return c.failText(try graff.failureMessage(a, text));
    }

    // ── complete / poll ────────────────────────────────────────────────────

    /// The RPC's `CompleteAgentLogin`: `complete_relayed_login` first (it
    /// answers for EVERY graff flow), then `complete_login`.
    fn completeInner(self: *Registry, c: *Call, login_id: []const u8, code: []const u8) ![]const u8 {
        if (try self.completeRelayed(c, login_id, code)) |_| return ok_json;
        return self.completeLoginInner(c, login_id, code);
    }

    /// `complete_login`: an Anthropic Console code for graff, else Claude's
    /// `code#state` exchanged for tokens and saved as a slot.
    fn completeLoginInner(self: *Registry, c: *Call, login_id: []const u8, code: []const u8) ![]const u8 {
        const a = c.al();
        if (try self.completeGraffPaste(c, login_id, code)) |_| {
            return (try self.list(c, false)).toJson(a);
        }
        var verifier: []const u8 = undefined;
        var then_graff = false;
        {
            self.state.lockUncancelable(self.io);
            defer self.state.unlock(self.io);
            const f = self.flows.get(login_id);
            if (f == null or f.?.kind != .claude) {
                verifier = "";
            } else {
                verifier = try a.dupe(u8, f.?.kind.claude.verifier);
                then_graff = f.?.kind.claude.then_graff;
            }
        }
        if (verifier.len == 0) return c.failText("This sign-in attempt expired \u{2014} start again.");
        const trimmed = std.mem.trim(u8, code, &std.ascii.whitespace);
        var auth_code = trimmed;
        var state = verifier;
        if (std.mem.indexOfScalar(u8, trimmed, '#')) |h| {
            auth_code = trimmed[0..h];
            state = trimmed[h + 1 ..];
        }
        if (auth_code.len == 0) return c.failText("That code looks empty \u{2014} paste the whole code.");

        const body = try jsonBody(a, &.{
            .{ "grant_type", "authorization_code" }, .{ "code", auth_code },               .{ "state", state },
            .{ "client_id", claude_client_id },      .{ "redirect_uri", claude_redirect }, .{ "code_verifier", verifier },
        });
        const res = http.send(a, self.io, .{ .method = .POST, .url = claude_token_url, .json_body = body, .timeout_ms = 15_000 }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return c.fail("token exchange failed: error sending request for url ({s})", .{claude_token_url});
        };
        if (!res.ok()) {
            return c.fail("Anthropic rejected the code ({d} {s}): {s}", .{ res.status, statusPhrase(res.status), firstChars(res.body, 200) });
        }
        const token = util.parseJson(a, res.body) orelse return c.failText("token exchange returned junk: error decoding response body");
        const access = util.strField(token, "access_token");
        const refresh = util.strField(token, "refresh_token");
        const expires_in = util.asI64(util.get(token, "expires_in")) orelse 3600;
        if (access == null or refresh == null) return c.failText("Anthropic returned no usable tokens \u{2014} try signing in again.");

        // Best-effort profile fetch — fills in the plan/org like Claude Code.
        const profile: ?json.Value = blk: {
            const r = http.send(a, self.io, .{ .url = claude_profile_url, .bearer = access.?, .headers = &.{.{ .name = "anthropic-beta", .value = "oauth-2025-04-20" }}, .timeout_ms = http_timeout_ms }) catch break :blk null;
            if (!r.ok()) break :blk null;
            break :blk util.parseJson(a, r.body);
        };
        const empty = util.newObject();
        const p_account = if (profile) |p| util.get(p, "account") orelse empty else empty;
        const p_org = if (profile) |p| util.get(p, "organization") orelse empty else empty;
        const t_account = util.get(token, "account") orelse empty;
        const t_org = util.get(token, "organization") orelse empty;

        const email = util.strField(p_account, "email_address") orelse util.strField(t_account, "email_address") orelse
            return c.failText("Could not identify the signed-in account.");
        const account_uuid = util.strField(p_account, "uuid") orelse util.strField(t_account, "uuid") orelse email;
        const org_name = util.strField(p_org, "name") orelse util.strField(t_org, "name");
        const org_type = util.strField(p_org, "organization_type");
        const rate_tier = util.strField(p_org, "rate_limit_tier");
        const display_name = util.strField(p_account, "display_name") orelse util.strField(p_account, "full_name");
        const subscription: ?[]const u8 = if (org_type) |t| (if (std.mem.eql(u8, t, "claude_max")) "max" else if (std.mem.eql(u8, t, "claude_pro")) "pro" else if (std.mem.eql(u8, t, "claude_team")) "team" else if (std.mem.eql(u8, t, "claude_enterprise")) "enterprise" else null) else null;

        var scopes = json.Array.init(a);
        var sit = std.mem.splitScalar(u8, util.strField(token, "scope") orelse claude_scopes, ' ');
        while (sit.next()) |s| try scopes.append(.{ .string = s });
        var oauth: json.ObjectMap = .empty;
        try oauth.put(a, "accessToken", .{ .string = access.? });
        try oauth.put(a, "refreshToken", .{ .string = refresh.? });
        try oauth.put(a, "expiresAt", .{ .integer = self.nowMs() + expires_in * 1000 });
        try oauth.put(a, "scopes", .{ .array = scopes });
        if (subscription) |s| try oauth.put(a, "subscriptionType", .{ .string = s });
        var oauth_account: json.ObjectMap = .empty;
        try oauth_account.put(a, "accountUuid", .{ .string = account_uuid });
        try oauth_account.put(a, "emailAddress", .{ .string = email });
        try oauth_account.put(a, "organizationUuid", util.strValue(util.strField(p_org, "uuid") orelse util.strField(t_org, "uuid")));
        try oauth_account.put(a, "organizationName", util.strValue(org_name));
        try oauth_account.put(a, "displayName", util.strValue(display_name));
        if (org_type) |t| try oauth_account.put(a, "organizationType", .{ .string = t });
        if (rate_tier) |t| try oauth_account.put(a, "organizationRateLimitTier", .{ .string = t });
        var creds: json.ObjectMap = .empty;
        try creds.put(a, "claudeAiOauth", .{ .object = oauth });
        var cc: json.ObjectMap = .empty;
        try cc.put(a, "oauthAccount", .{ .object = oauth_account });
        const id = util.slotIdFor(.claude_code, account_uuid);
        const slot: Slot = .{
            .id = try a.dupe(u8, &id),
            .harness = .claude_code,
            .account_key = account_uuid,
            .profile = .{ .email = email, .display_name = display_name, .organization = org_name, .plan = try util.claudePlan(a, org_type, rate_tier), .auth_kind = .oauth },
            .credentials = .{ .object = creds },
            .claude_config = .{ .object = cc },
            .saved_at = self.nowMs(),
        };
        {
            self.ops.lockUncancelable(self.io);
            defer self.ops.unlock(self.io);
            try slots_mod.writeSlot(a, self.io, self.config, slot);
            try self.adoptIfLive(c, slot);
            self.removeFlowQuiet(login_id);
            if (!then_graff) return (try self.listLocked(c, false)).toJson(a);
        }
        try self.recordGraffClaudeAgent(c);
        return (try self.list(c, false)).toJson(a);
    }

    /// Remove a flow without killing anything (a finished Claude flow).
    fn removeFlowQuiet(self: *Registry, login_id: []const u8) void {
        const flow = blk: {
            self.state.lockUncancelable(self.io);
            defer self.state.unlock(self.io);
            const kv = self.flows.fetchRemove(login_id) orelse return;
            self.gpa.free(kv.key);
            break :blk kv.value;
        };
        flow.destroy(self.gpa);
    }

    fn pollInner(self: *Registry, c: *Call, login_id: []const u8) !LoginPoll {
        const a = c.al();
        self.sweepFlows();
        if (try self.pollGraffLogin(c, login_id)) |p| return p;
        const Spawned = struct { harness: Harness, home: []const u8, child: *LoginChild, reauthenticate: bool };
        const sp: Spawned = blk: {
            self.state.lockUncancelable(self.io);
            defer self.state.unlock(self.io);
            const f = self.flows.get(login_id) orelse return c.failText("This sign-in attempt expired \u{2014} start again.");
            switch (f.kind) {
                .claude => return .{ .status = .pending },
                .graff => return .{ .status = .pending },
                .spawned => |s| break :blk .{ .harness = s.harness, .home = try a.dupe(u8, s.home), .child = s.child.retain(), .reauthenticate = s.reauthenticate },
            }
        };
        defer sp.child.release();
        const auth_path = try std.fs.path.join(a, &.{ sp.home, "auth.json" });
        const detected: ?Detected = if (slots_mod.readJson(a, self.io, auth_path)) |auth| switch (sp.harness) {
            .codex => try slots_mod.parseCodexAuth(a, auth),
            .cursor => try slots_mod.parseCursorAuth(a, auth, self.nowMs()),
            else => null,
        } else null;
        if (detected) |d| {
            self.ops.lockUncancelable(self.io);
            defer self.ops.unlock(self.io);
            try self.snapshotDetected(c, sp.harness, d);
            const id = util.slotIdFor(sp.harness, d.account_key);
            if (findSlot(slots_mod.readSlots(a, self.io, self.config, sp.harness), &id)) |slot| {
                if (sp.reauthenticate and sp.harness == .codex) {
                    // Approval explicitly replaces the expired login; activate()
                    // would snapshot the old credentials over this renewed slot.
                    try self.activateCodex(c, slot);
                } else {
                    try self.adoptIfLive(c, slot);
                }
            }
            self.cancelFlow(login_id);
            return .{ .status = .done };
        }
        if (sp.child.exitStatus()) |exit| {
            self.cancelFlow(login_id);
            const message: []const u8 = if (exit.code != null and exit.code.? == 0)
                "The sign-in finished without credentials."
            else
                util.spawnedFailureText(a, try sp.child.outputDupe(a));
            return .{ .status = .@"error", .message = message };
        }
        return .{ .status = .pending };
    }

    // ── detection ──────────────────────────────────────────────────────────

    const ClaudeDetect = struct { detected: ?Detected = null, warning: ?[]const u8 = null };

    fn detectClaude(self: *Registry, c: *Call) !ClaudeDetect {
        const a = c.al();
        const cfg = slots_mod.readJson(a, self.io, self.config.claude_config_file) orelse return .{};
        const oauth = util.get(cfg, "oauthAccount") orelse return .{};
        const email = util.strField(oauth, "emailAddress") orelse return .{};
        const creds = self.readClaudeCredentials(c);
        var cc: json.ObjectMap = .empty;
        try cc.put(a, "oauthAccount", oauth);
        if (util.get(cfg, "userID")) |uid| if (uid == .string) try cc.put(a, "userID", uid);
        return .{
            .detected = .{
                .account_key = util.strField(oauth, "accountUuid") orelse email,
                .profile = .{
                    .email = email,
                    .display_name = util.strField(oauth, "displayName"),
                    .organization = util.strField(oauth, "organizationName"),
                    .plan = try util.claudePlan(a, util.strField(oauth, "organizationType"), util.strField(oauth, "organizationRateLimitTier")),
                    .auth_kind = .oauth,
                },
                .credentials = creds.credentials,
                .claude_config = .{ .object = cc },
            },
            .warning = creds.warning,
        };
    }

    fn detectCodex(self: *Registry, c: *Call) !?Detected {
        const a = c.al();
        const auth = slots_mod.readJson(a, self.io, try self.config.codexAuthFile(a)) orelse return null;
        return slots_mod.parseCodexAuth(a, auth);
    }

    fn detectCursor(self: *Registry, c: *Call) !?Detected {
        const a = c.al();
        const auth = slots_mod.readJson(a, self.io, self.config.cursor_sdk_auth_file) orelse return null;
        return slots_mod.parseCursorAuth(a, auth, self.nowMs());
    }

    fn cursorLiveUsable(self: *Registry, c: *Call) bool {
        const auth = slots_mod.readJson(c.al(), self.io, self.config.cursor_sdk_auth_file) orelse return false;
        return slots_mod.cursorKeyUsable(auth, self.nowMs());
    }

    /// `snapshot_detected`: persist a detected login into its slot.
    fn snapshotDetected(self: *Registry, c: *Call, harness: Harness, d: Detected) !void {
        const creds = d.credentials orelse return;
        const id = util.slotIdFor(harness, d.account_key);
        try slots_mod.writeSlot(c.al(), self.io, self.config, .{
            .id = &id,
            .harness = harness,
            .account_key = d.account_key,
            .profile = d.profile,
            .credentials = creds,
            .claude_config = d.claude_config,
            .saved_at = self.nowMs(),
        });
    }

    fn user(_: *Registry, a: Allocator) []const u8 {
        const e = catalog_core.currentEnv(a) catch return "unknown";
        return e.get("USER") orelse "unknown";
    }

    /// `read_claude_credentials`: the file, else (macOS) the Keychain item.
    fn readClaudeCredentials(self: *Registry, c: *Call) keychain.Read {
        const a = c.al();
        const file = self.config.claudeCredsFile(a) catch return .{};
        if (slots_mod.readJson(a, self.io, file)) |creds| return .{ .credentials = creds };
        if (builtin.os.tag == .macos) return keychain.readCredentials(a, self.io, self.user(a));
        return .{};
    }

    /// `write_claude_credentials`: the Keychain item in place when no
    /// credentials file exists (macOS), else (or when the Keychain refuses
    /// and holds no item) the file, atomically and owner-only.
    fn writeClaudeCredentials(self: *Registry, c: *Call, credentials: json.Value) !void {
        const a = c.al();
        const text = try util.stringify(a, credentials);
        const file = try self.config.claudeCredsFile(a);
        if (builtin.os.tag == .macos and !slots_mod.exists(self.io, file)) {
            const err = try keychain.writeCredentials(a, self.io, self.user(a), text);
            if (err == null) return;
            if (keychain.hasItem(a, self.io)) {
                return c.fail("macOS Keychain wouldn't update the Claude Code login, so it can't be switched here. Run `claude` in a terminal and sign in with /login, then refresh. ({s})", .{err.?});
            }
        }
        try Io.Dir.cwd().createDirPath(self.io, self.config.claude_config_dir);
        try slots_mod.writeFileAtomic(a, self.io, file, text, true);
    }

    // ── usage ──────────────────────────────────────────────────────────────

    fn clearUsageCache(self: *Registry) void {
        self.state.lockUncancelable(self.io);
        defer self.state.unlock(self.io);
        var it = self.usage_cache.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.free(self.gpa);
        }
        self.usage_cache.clearRetainingCapacity();
    }

    /// `usage_for`: cached (60 s), else probed only when forced.
    fn usageFor(self: *Registry, c: *Call, harness: Harness, slot: Slot, may_refresh: bool, force: bool) !?UsageSnapshot {
        const a = c.al();
        const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ harness.slug(), slot.account_key });
        {
            self.state.lockUncancelable(self.io);
            defer self.state.unlock(self.io);
            if (self.usage_cache.get(key)) |hit| if (self.monoMs() - hit.at_ms < usage_ttl_ms) {
                const u = hit.usage orelse return null;
                return .{ .windows = try a.dupe(UsageWindow, u.windows), .plan_label = if (u.plan_label) |p| try a.dupe(u8, p) else null };
            };
        }
        if (!force) return null;
        const usage: ?UsageSnapshot = switch (harness) {
            .claude_code => try self.claudeUsage(c, slot, may_refresh),
            .codex => try self.codexUsage(c, slot),
            .cursor => try self.cursorUsage(c, slot),
            else => null,
        };
        const owned: ?UsageSnapshot = if (usage) |u| .{
            .windows = try self.gpa.dupe(UsageWindow, u.windows),
            .plan_label = if (u.plan_label) |p| try self.gpa.dupe(u8, p) else null,
        } else null;
        const entry: CachedUsage = .{ .usage = owned, .at_ms = self.monoMs() };
        self.state.lockUncancelable(self.io);
        defer self.state.unlock(self.io);
        const gop = self.usage_cache.getOrPut(self.gpa, key) catch {
            entry.free(self.gpa);
            return usage;
        };
        if (gop.found_existing) {
            gop.value_ptr.free(self.gpa);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch {
                _ = self.usage_cache.remove(key);
                entry.free(self.gpa);
                return usage;
            };
        }
        gop.value_ptr.* = entry;
        return usage;
    }

    fn claudeUsage(self: *Registry, c: *Call, slot: Slot, may_refresh: bool) !?UsageSnapshot {
        const oauth = util.get(slot.credentials, "claudeAiOauth") orelse return null;
        const token = util.strField(oauth, "accessToken") orelse return null;
        const first = try self.claudeUsageRequest(c, token);
        if (first.ok) return first.usage;
        if (!may_refresh) return null;
        const fresh = (try self.refreshClaudeSlot(c, slot)) orelse return null;
        const again = try self.claudeUsageRequest(c, fresh);
        return if (again.ok) again.usage else null;
    }

    const UsageProbe = struct { ok: bool, usage: ?UsageSnapshot = null };

    /// `claude_usage_request`: not ok (worth a refresh) on any failure.
    fn claudeUsageRequest(self: *Registry, c: *Call, token: []const u8) !UsageProbe {
        const a = c.al();
        const res = http.send(a, self.io, .{ .url = claude_usage_url, .bearer = token, .headers = &.{.{ .name = "anthropic-beta", .value = "oauth-2025-04-20" }}, .timeout_ms = http_timeout_ms }) catch |e| {
            if (e == error.OutOfMemory) return e;
            return .{ .ok = false };
        };
        if (!res.ok()) return .{ .ok = false };
        const body = util.parseJson(a, res.body) orelse return .{ .ok = false };
        return .{ .ok = true, .usage = try util.claudeUsageWindows(a, body) };
    }

    fn codexUsage(self: *Registry, c: *Call, slot: Slot) !?UsageSnapshot {
        const a = c.al();
        const tokens = util.get(slot.credentials, "tokens") orelse return null;
        const token = util.strField(tokens, "access_token") orelse return null;
        const res = http.send(a, self.io, .{ .url = codex_usage_url, .bearer = token, .headers = &.{.{ .name = "chatgpt-account-id", .value = util.strField(tokens, "account_id") orelse "" }}, .timeout_ms = http_timeout_ms }) catch |e| {
            if (e == error.OutOfMemory) return e;
            return null;
        };
        if (!res.ok()) return null;
        return util.codexUsage(a, util.parseJson(a, res.body) orelse return null);
    }

    fn cursorUsage(self: *Registry, c: *Call, slot: Slot) !?UsageSnapshot {
        const a = c.al();
        const key = util.strField(slot.credentials, "apiKey") orelse return null;
        const backend = std.mem.trimEnd(u8, util.strField(slot.credentials, "backendUrl") orelse cursor_default_backend, "/");
        const ex = http.send(a, self.io, .{ .method = .POST, .url = try std.fmt.allocPrint(a, "{s}/auth/exchange_user_api_key", .{backend}), .bearer = key, .json_body = "{}", .timeout_ms = http_timeout_ms }) catch |e| {
            if (e == error.OutOfMemory) return e;
            return null;
        };
        if (!ex.ok()) return null;
        const session = util.parseJson(a, ex.body) orelse return null;
        const token = util.strField(session, "accessToken") orelse return null;
        const res = http.send(a, self.io, .{ .method = .POST, .url = try std.fmt.allocPrint(a, "{s}/{s}", .{ backend, cursor_current_period_usage }), .bearer = token, .headers = &.{.{ .name = "Connect-Protocol-Version", .value = "1" }}, .json_body = "{}", .timeout_ms = http_timeout_ms }) catch |e| {
            if (e == error.OutOfMemory) return e;
            return null;
        };
        if (!res.ok()) return null;
        const w = util.cursorUsageWindow(util.parseJson(a, res.body) orelse return null) orelse return null;
        return .{ .windows = try a.dupe(UsageWindow, &.{w}) };
    }

    /// `refresh_claude_slot`: single-flight per slot.
    fn refreshClaudeSlot(self: *Registry, c: *Call, slot: Slot) !?[]const u8 {
        {
            self.state.lockUncancelable(self.io);
            defer self.state.unlock(self.io);
            if (self.inflight_refreshes.contains(slot.id)) return null;
            const k = try self.gpa.dupe(u8, slot.id);
            self.inflight_refreshes.put(self.gpa, k, {}) catch {
                self.gpa.free(k);
                return error.OutOfMemory;
            };
        }
        defer {
            self.state.lockUncancelable(self.io);
            if (self.inflight_refreshes.fetchRemove(slot.id)) |kv| self.gpa.free(kv.key);
            self.state.unlock(self.io);
        }
        return self.refreshClaudeSlotOnce(c, slot);
    }

    fn refreshClaudeSlotOnce(self: *Registry, c: *Call, slot: Slot) !?[]const u8 {
        const a = c.al();
        const oauth = util.get(slot.credentials, "claudeAiOauth") orelse return null;
        const refresh = util.strField(oauth, "refreshToken") orelse return null;
        const body = try jsonBody(a, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", refresh }, .{ "client_id", claude_client_id } });
        const res = http.send(a, self.io, .{ .method = .POST, .url = claude_token_url, .json_body = body, .timeout_ms = http_timeout_ms }) catch |e| {
            if (e == error.OutOfMemory) return e;
            return null;
        };
        if (!res.ok()) return null;
        const reply_v = util.parseJson(a, res.body) orelse return null;
        const access = util.strField(reply_v, "access_token") orelse return null;
        const expires_in = util.asI64(util.get(reply_v, "expires_in")) orelse 3600;
        var updated = try util.cloneValue(a, oauth);
        if (updated == .object) {
            try updated.object.put(a, "accessToken", .{ .string = access });
            try updated.object.put(a, "refreshToken", .{ .string = util.strField(reply_v, "refresh_token") orelse refresh });
            try updated.object.put(a, "expiresAt", .{ .integer = self.nowMs() + expires_in * 1000 });
        }
        var refreshed = slot;
        // Keep sibling keys (mcpOAuth, pluginSecrets, …).
        refreshed.credentials = try util.withClaudeAiOauth(a, slot.credentials, updated);
        refreshed.saved_at = self.nowMs();
        slots_mod.writeSlot(a, self.io, self.config, refreshed) catch {};
        return access;
    }
};

fn findSlot(list_slots: []const Slot, id: []const u8) ?Slot {
    for (list_slots) |s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

/// `may_refresh_claude_slot`: only a slot plainly for another account than
/// the live one, holding its own refresh token.
pub fn mayRefreshClaudeSlot(slot: Slot, live: ?Detected) bool {
    const l = live orelse return false;
    if (std.mem.eql(u8, slot.account_key, l.account_key) or std.ascii.eqlIgnoreCase(slot.profile.email, l.profile.email)) return false;
    const slot_token = refreshTokenOf(slot.credentials) orelse return false;
    const live_token = refreshTokenOf(l.credentials orelse return false) orelse return false;
    return !std.mem.eql(u8, slot_token, live_token);
}

fn refreshTokenOf(creds: json.Value) ?[]const u8 {
    return util.strField(util.get(creds, "claudeAiOauth") orelse return null, "refreshToken");
}

fn jsonBody(a: Allocator, pairs: []const [2][]const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    var j: json.Stringify = .{ .writer = &aw.writer };
    try j.beginObject();
    for (pairs) |p| {
        try j.objectField(p[0]);
        try j.write(p[1]);
    }
    try j.endObject();
    return aw.toOwnedSlice();
}

fn firstChars(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len and count < n) : (count += 1) i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return s[0..@min(i, s.len)];
}

/// reqwest `StatusCode`'s canonical reason.
fn statusPhrase(code: u16) []const u8 {
    const s: std.http.Status = @fromBackingInt(@intCast(code));
    return s.phrase() orelse "<unknown status code>";
}

// ── params (serde's messages) ──────────────────────────────────────────────

threadlocal var param_error_text: ?[]const u8 = null;

fn badParam(a: Allocator, comptime fmt: []const u8, args: anytype) error{BadParams} {
    param_error_text = std.fmt.allocPrint(a, fmt, args) catch "invalid params";
    return error.BadParams;
}

fn reqString(a: Allocator, o: json.ObjectMap, name: []const u8) error{BadParams}![]const u8 {
    const v = o.get(name) orelse return badParam(a, "missing field `{s}`", .{name});
    if (v != .string) return badParam(a, "invalid type: {s}, expected a string", .{util.unexpectedText(a, v) catch "?"});
    return v.string;
}

fn reqHarness(a: Allocator, o: json.ObjectMap, name: []const u8) error{BadParams}!Harness {
    const v = o.get(name) orelse return badParam(a, "missing field `{s}`", .{name});
    if (v != .string) return badParam(a, "invalid type: {s}, expected string or map", .{util.unexpectedText(a, v) catch "?"});
    return Harness.parse(v.string) orelse badParam(a, "{s}", .{util.unknownVariantText(a, v.string) catch "unknown variant"});
}

/// `bool` with `#[serde(default)]` (`null` is a type error), or
/// `Option<bool>` when `nullable`.
fn optBool(a: Allocator, o: json.ObjectMap, name: []const u8, nullable: bool) error{BadParams}!?bool {
    const v = o.get(name) orelse return null;
    return switch (v) {
        .bool => |b| b,
        .null => if (nullable) null else badParam(a, "invalid type: null, expected a boolean", .{}),
        else => badParam(a, "invalid type: {s}, expected a boolean", .{util.unexpectedText(a, v) catch "?"}),
    };
}

fn optString(a: Allocator, o: json.ObjectMap, name: []const u8) error{BadParams}!?[]const u8 {
    const v = o.get(name) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => badParam(a, "invalid type: {s}, expected a string", .{util.unexpectedText(a, v) catch "?"}),
    };
}

pub const ParsedStart = union(enum) { ok: StartParams, bad: []const u8 };

/// `StartAgentLoginParams` from raw params, with serde's messages.
pub fn parseStartParams(a: Allocator, params: json.Value) ParsedStart {
    const o = switch (params) {
        .object => |o| o,
        else => return .{ .bad = std.fmt.allocPrint(a, "invalid type: {s}, expected struct StartAgentLoginParams", .{util.unexpectedText(a, params) catch "?"}) catch "invalid params" },
    };
    const p = parseStartFields(a, o) catch return .{ .bad = param_error_text orelse "invalid params" };
    return .{ .ok = p };
}

fn parseStartFields(a: Allocator, o: json.ObjectMap) error{BadParams}!StartParams {
    return .{
        .harness = try reqHarness(a, o, "harness"),
        .reauthenticate = (try optBool(a, o, "reauthenticate", false)) orelse false,
        .device_auth = (try optBool(a, o, "deviceAuth", false)) orelse false,
        .provider = try optString(a, o, "provider"),
        .relay_browser = (try optBool(a, o, "relayBrowser", false)) orelse false,
    };
}

test {
    _ = @import("agent_logins_util.zig");
    _ = @import("agent_logins_graff.zig");
    _ = @import("agent_logins_slots.zig");
    _ = @import("agent_logins_proc.zig");
    _ = @import("agent_logins_http.zig");
    _ = @import("agent_logins_tests.zig");
}
