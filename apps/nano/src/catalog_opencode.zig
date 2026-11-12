//! OpenCode's live model catalog, ported from `crates/harness/src/opencode/mod.rs`
//! (`OpencodeHarness::{model_context, model_catalog, probe_models}`,
//! `Server::{spawn, get_raw, get_response, get, get_json, provider_catalog}`,
//! `Protocol::detect`, `models_from_providers`, `catalog_from_v2_models`,
//! `agent_option`, `variant_to_level`, `truncate_body`).
//!
//! Discovery boots a short-lived `opencode serve --port P --hostname
//! 127.0.0.1` with a per-probe Basic password, waits for a version-bearing
//! health answer (which also tells the 1.x wire from 2.x), then reads the
//! catalog: 1.x's `GET /provider` filtered to connected providers, or 2.x's
//! `GET /api/model` folded into the same shape plus `GET /api/agent` as an
//! "Agent" option on every row. Rows are `provider/model`, sorted by label
//! within each provider, with the reasoning levels their variants advertise.
//!
//! Std-only (plus `catalog_core.zig`, `agent_proc.zig`,
//! `harness_version.zig`): `zig test catalog_opencode.zig`. HTTP is a small
//! HTTP/1.1 client over loopback TCP with per-request deadlines.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const core = @import("catalog_core.zig");
const agent_proc = @import("agent_proc.zig");
const harness_version = @import("harness_version.zig");
const Failure = core.Failure;

/// Wire id (disk cache folder, `resolve_cli` id).
pub const id = "opencode";
/// `INSTALL_HINT`, the `HarnessError::NotInstalled` text.
pub const install_hint = "opencode (searched PATH, the login shell's PATH, ~/.opencode/bin, ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE, %APPDATA%\\npm, and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; install with `curl -fsSL https://opencode.ai/install | bash` or `npm install -g @opencode/cli`, then `opencode auth login`; set OPENCODE_EXECUTABLE to override)";

const startup_env = "HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS";
const default_startup_secs: u64 = 300;

/// `HEALTH_POLL`.
pub var health_poll_ms: u64 = 150;
/// `get_raw`'s bound on each health probe.
pub var health_timeout_ms: u64 = 2_000;
/// `CALL_TIMEOUT`.
pub var call_timeout_ms: u64 = 60_000;
/// 2.x: the pause before re-reading an empty `/api/model`.
pub var v2_empty_retry_ms: u64 = 2_000;
/// `OpencodeHarness::kill_grace`.
pub var kill_grace_ms: u32 = 3_000;
/// The loopback port `opencode serve` is told to bind (`free_localhost_port`).
pub var pick_port: *const fn (io: Io) anyerror!u16 = freeLocalhostPort;
/// Largest response body read.
const max_body = 512 * 1024 * 1024;

// ── the harness ────────────────────────────────────────────────────────────

const State = struct {
    cache: core.MemCache = .{},
};

var state: State = .{};

const vtable: core.Harness.VTable = .{
    .modelContext = modelContextFn,
    .modelCatalog = modelCatalogFn,
    .fallbackModels = fallbackModelsFn,
};

/// OpenCode's discovery surface (process-global state: its in-memory catalog).
pub fn harness() core.Harness {
    return .{ .id = id, .ptr = &state, .vtable = &vtable };
}

/// Forget the in-memory catalog.
pub fn resetForTests() void {
    if (state.cache.models) |m| core.long_gpa.free(m);
    state.cache = .{};
}

/// `startup_timeout`: `$HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS` (> 0), else 300.
pub fn startupSecs(env: *const Environ.Map) u64 {
    const v = env.get(startup_env) orelse return default_startup_secs;
    const n = std.fmt.parseInt(u64, v, 10) catch return default_startup_secs;
    return if (n > 0) n else default_startup_secs;
}

fn modelContextFn(_: *anyopaque, gpa: Allocator, io: Io) anyerror!core.ContextResult {
    return modelContext(gpa, io);
}

fn modelCatalogFn(_: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!core.Result {
    // `self.model_context()?` before the cache.
    var ctx = try modelContext(gpa, io);
    switch (ctx) {
        .ok => |*c| c.deinit(gpa),
        .err => |f| return .{ .err = f },
        .none => {},
    }
    var env = try core.currentEnv(gpa);
    const startup = startupSecs(&env);
    env.deinit();
    var probe: Probe = .{ .gpa = gpa, .io = io };
    return state.cache.getWithTimeout(gpa, io, force, startup * 3 * 1000 + 1000, &probe, &probe);
}

/// No `fallback_models` override.
fn fallbackModelsFn(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
    return gpa.dupe(u8, "[]");
}

/// `model_context`: the CLI (resolved through `catalog_core.resolve_cli`),
/// opencode's auth and config files, and its environment.
pub fn modelContext(gpa: Allocator, io: Io) !core.ContextResult {
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    const exe = (core.resolve_cli(gpa, io, id) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) }) orelse
        return .{ .err = Failure.notInstalled(install_hint) };
    defer gpa.free(exe);
    const ctx = core.computeContext(gpa, io, id, exe, &.{}, &env) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .err = Failure.ioError(.other, @errorName(e)) },
    };
    return .{ .ok = ctx };
}

const Probe = struct {
    gpa: Allocator,
    io: Io,

    pub fn key(self: *Probe) core.KeyResult {
        var res = modelContext(self.gpa, self.io) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) };
        switch (res) {
            .ok => |*c| {
                defer c.deinit(self.gpa);
                return .{ .ok = c.key() };
            },
            .err => |f| return .{ .err = f },
            .none => return .{ .err = Failure.protocol("opencode model context", .{}) },
        }
    }

    pub fn discover(_: *Probe, gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
        return probeModels(gpa, io, budget_ms);
    }
};

// ── HTTP/1.1 over loopback ─────────────────────────────────────────────────

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn freeLocalhostPort(io: Io) anyerror!u16 {
    // No SO_REUSEPORT (Zig's `reuse_address` sets it): another process's
    // listener must never share the port opencode is told to bind.
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = try addr.listen(io, .{});
    defer srv.deinit(io);
    return srv.socket.address.ip4.port;
}

pub const Response = struct { status: u16, body: []const u8 };

/// reqwest's `connect_timeout(2 s)` in `http_client`.
pub var connect_timeout_ms: u64 = 2_000;

/// A loopback connect bounded by a deadline (`Io`'s own connect has no
/// timeout). A connect still pending at the deadline is abandoned: its
/// thread closes the late socket and frees the state.
const Connect = struct {
    io: Io,
    port: u16,
    /// 0 pending, 1 finished, 2 abandoned by the caller.
    state: std.atomic.Value(u8) = .init(0),
    stream: ?net.Stream = null,

    fn run(self: *Connect) void {
        const addr = net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        const stream = addr.connect(self.io, .{ .mode = .stream }) catch null;
        self.stream = stream;
        if (self.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
            if (stream) |st| st.close(self.io);
            core.long_gpa.destroy(self);
        }
    }

    fn open(io: Io, port: u16, deadline: i96) ?net.Stream {
        const c = core.long_gpa.create(Connect) catch return null;
        c.* = .{ .io = io, .port = port };
        const th = std.Thread.spawn(.{}, run, .{c}) catch {
            core.long_gpa.destroy(c);
            return null;
        };
        th.detach();
        while (c.state.load(.acquire) == 0 and nowNs(io) < deadline) Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        if (c.state.cmpxchgStrong(0, 2, .acq_rel, .acquire) == null) return null;
        const stream = c.stream;
        core.long_gpa.destroy(c);
        return stream;
    }
};

/// Shuts a socket down at its deadline, unblocking a stalled read.
const Watch = struct {
    io: Io,
    stream: net.Stream,
    deadline: i96,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watch) void {
        while (!self.done.load(.acquire)) {
            if (nowNs(self.io) >= self.deadline) {
                self.fired.store(true, .release);
                self.stream.shutdown(self.io, .both) catch {};
                return;
            }
            Io.sleep(self.io, .fromMilliseconds(5), .awake) catch return;
        }
    }
};

/// A complete response in `raw`, null when more bytes are needed, or
/// `error.BadResponse` when the peer closed on an incomplete one.
pub fn parseResponse(a: Allocator, raw: []const u8, eof: bool) !?Response {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return if (eof) error.BadResponse else null;
    var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    var parts = std.mem.tokenizeScalar(u8, lines.next() orelse "", ' ');
    _ = parts.next();
    const status = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return error.BadResponse;
    var length: ?usize = null;
    var chunked = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.findIgnoreCase(value, "chunked") != null) chunked = true;
    }
    const rest = raw[head_end + 4 ..];
    if (status == 204 or status == 304) return .{ .status = status, .body = "" };
    if (chunked) {
        // Decode only once the terminal chunk can have arrived.
        if (!eof and !std.mem.endsWith(u8, rest, "0\r\n\r\n")) return null;
        var body: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        while (true) {
            const nl = std.mem.indexOfPos(u8, rest, at, "\r\n") orelse return if (eof) error.BadResponse else null;
            const size_text = rest[at..nl];
            const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
            const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_text[0..semi], " \t"), 16) catch return error.BadResponse;
            at = nl + 2;
            if (size == 0) return .{ .status = status, .body = body.items };
            if (rest.len < at + size + 2) return if (eof) error.BadResponse else null;
            try body.appendSlice(a, rest[at .. at + size]);
            at += size + 2;
        }
    }
    if (length) |n| {
        if (rest.len >= n) return .{ .status = status, .body = rest[0..n] };
        return if (eof) error.BadResponse else null;
    }
    return if (eof) .{ .status = status, .body = rest } else null;
}

/// `StatusCode`'s display: `"401 Unauthorized"`.
fn statusText(buf: []u8, code: u16) []const u8 {
    const phrase = if (code < 1024) (@as(std.http.Status, @enumFromInt(@as(u10, @intCast(code)))).phrase() orelse "<unknown status code>") else "<unknown status code>";
    return std.fmt.bufPrint(buf, "{d} {s}", .{ code, phrase }) catch "";
}

/// `truncate_body`: trimmed, at most 300 bytes (on a character boundary) + `…`.
pub fn truncateBody(buf: []u8, body: []const u8) []const u8 {
    const t = std.mem.trim(u8, body, " \t\r\n\x0b\x0c");
    if (t.len <= 300) return t;
    var end: usize = 300;
    while (end > 0 and (t[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.bufPrint(buf, "{s}…", .{t[0..end]}) catch t[0..end];
}

// ── the server ─────────────────────────────────────────────────────────────

const Protocol = enum { v1, v2 };

const Server = struct {
    gpa: Allocator,
    io: Io,
    proc: *agent_proc.AgentProc,
    port: u16,
    /// `Basic base64("opencode:<password>")`.
    auth: []u8,
    protocol: Protocol = .v1,
    /// The probe's overall budget (awake clock, ns).
    budget_end: i96,

    fn destroy(self: *Server, grace_ms: u32) void {
        // `shutdown_child`: TERM the group, KILL it after the grace.
        self.proc.escalate(0, grace_ms);
        _ = self.proc.wait();
        self.proc.destroy();
        self.gpa.free(self.auth);
    }

    /// One GET; null on a transport failure (refused, reset, deadline).
    fn get(self: *Server, a: Allocator, path: []const u8, timeout_ms: u64) ?Response {
        const now = nowNs(self.io);
        const deadline = @min(now + @as(i96, timeout_ms) * std.time.ns_per_ms, self.budget_end);
        const stream = Connect.open(self.io, self.port, @min(deadline, now + @as(i96, connect_timeout_ms) * std.time.ns_per_ms)) orelse return null;
        defer stream.close(self.io);
        var watch: Watch = .{ .io = self.io, .stream = stream, .deadline = deadline };
        const th = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch null;
        const resp = self.exchange(a, stream, path) catch null;
        watch.done.store(true, .release);
        if (th) |t| t.join();
        if (watch.fired.load(.acquire)) return null;
        return resp;
    }

    fn exchange(self: *Server, a: Allocator, stream: net.Stream, path: []const u8) !Response {
        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: {s}\r\nAccept: application/json\r\nConnection: close\r\n\r\n", .{ path, self.port, self.auth });
        try w.interface.flush();
        var rbuf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        const r = &reader.interface;
        var raw: std.ArrayList(u8) = .empty;
        while (true) {
            const chunk = r.peekGreedy(1) catch |e| switch (e) {
                error.EndOfStream => return (try parseResponse(a, raw.items, true)).?,
                else => return error.ReadFailed,
            };
            if (raw.items.len + chunk.len > max_body) return error.TooLarge;
            try raw.appendSlice(a, chunk);
            r.toss(chunk.len);
            if (try parseResponse(a, raw.items, false)) |resp| return resp;
        }
    }

    const Got = union(enum) { ok: []const u8, err: Failure };

    /// `get_response`: a 2xx body, or `opencode GET {path}: …`.
    fn getOk(self: *Server, a: Allocator, path: []const u8) Got {
        const resp = self.get(a, path, call_timeout_ms) orelse
            return .{ .err = Failure.protocol("opencode GET {s}: error sending request for url (http://127.0.0.1:{d}{s})", .{ path, self.port, path }) };
        if (resp.status / 100 != 2) {
            var sbuf: [64]u8 = undefined;
            var tbuf: [320]u8 = undefined;
            return .{ .err = Failure.protocol("opencode GET {s}: {s} {s}", .{ path, statusText(&sbuf, resp.status), truncateBody(&tbuf, resp.body) }) };
        }
        return .{ .ok = resp.body };
    }
};

const SpawnResult = union(enum) { ok: *Server, err: Failure };

/// A v4 UUID's text, from `io.random`.
fn uuid(io: Io) [36]u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] }) catch unreachable;
    return out;
}

/// `binary_hint`: `"{path} (version {version|unknown})"`.
fn binaryHint(buf: []u8, io: Io, exe: []const u8) []const u8 {
    var vbuf: [128]u8 = undefined;
    const v = harness_version.binaryVersionString(io, exe, &vbuf) orelse "unknown";
    return std.fmt.bufPrint(buf, "{s} (version {s})", .{ exe, v }) catch exe;
}

/// `Server::spawn`: boot `opencode serve` on a loopback port with a fresh
/// password and wait for a version-bearing health answer.
fn spawnServer(gpa: Allocator, io: Io, env: *const Environ.Map, exe: []const u8, startup_secs: u64, budget_end: i96) !SpawnResult {
    const port = pick_port(io) catch return .{ .err = Failure.protocol("no free localhost port for opencode serve", .{}) };
    const password = uuid(io);
    var child_env = try env.clone(gpa);
    defer child_env.deinit();
    _ = child_env.swapRemove("HARNESS_BUILD_WAIT_DIR");
    try child_env.put("OPENCODE_SERVER_PASSWORD", &password);
    try child_env.put("OPENCODE_CLIENT", "harness");
    const login = if (env.get("HARNESS_DISABLE_SHELL_ENV") != null) null else agent_proc.loginShellPath(gpa, io, env, null);
    const path = try agent_proc.composeChildPath(gpa, exe, env.get("PATH"), login);
    defer gpa.free(path);
    try child_env.put("PATH", path);
    var port_buf: [8]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
    const proc = agent_proc.AgentProc.spawn(gpa, io, &.{ exe, "serve", "--port", port_text, "--hostname", "127.0.0.1" }, null, &child_env, .{ .stdin = false, .stdout = false }) catch |e| switch (e) {
        error.NotInstalled, error.FileNotFound => {
            var hbuf: [1024]u8 = undefined;
            return .{ .err = Failure.notInstalled(binaryHint(&hbuf, io, exe)) };
        },
        else => return .{ .err = Failure.ioError(.other, @errorName(e)) },
    };
    const cred = "opencode:" ++ password;
    var b64: [std.base64.standard.Encoder.calcSize(cred.len)]u8 = undefined;
    const auth = std.fmt.allocPrint(gpa, "Basic {s}", .{std.base64.standard.Encoder.encode(&b64, cred)}) catch |e| {
        proc.destroy();
        return e;
    };
    const server = gpa.create(Server) catch |e| {
        gpa.free(auth);
        proc.destroy();
        return e;
    };
    server.* = .{ .gpa = gpa, .io = io, .proc = proc, .port = port, .auth = auth, .budget_end = budget_end };

    const deadline = @min(nowNs(io) + @as(i96, startup_secs) * std.time.ns_per_s, budget_end);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        // An exited child fails fast with its stderr tail.
        if (proc.stderr_closed.load(.acquire)) {
            proc.armDeadline(1000);
            const term = proc.wait();
            const tail = proc.stderrTail(gpa);
            defer if (tail) |t| gpa.free(t);
            const msg = try agent_proc.crashMessage(gpa, "opencode serve", term, tail);
            defer gpa.free(msg);
            server.destroy(0);
            gpa.destroy(server);
            return .{ .err = Failure.protocol("{s}", .{msg}) };
        }
        switch (try detect(server, arena_state.allocator())) {
            .found => |p| {
                server.protocol = p;
                return .{ .ok = server };
            },
            .err => |f| {
                server.destroy(1000);
                gpa.destroy(server);
                return .{ .err = f };
            },
            .none => {},
        }
        if (nowNs(io) >= deadline) {
            server.destroy(1000);
            gpa.destroy(server);
            return .{ .err = Failure.protocol("opencode serve did not become healthy within {d}s (raise " ++ startup_env ++ " if this machine's plugin load is genuinely slow)", .{startup_secs}) };
        }
        Io.sleep(io, .fromMilliseconds(@intCast(health_poll_ms)), .awake) catch {};
    }
}

const Detected = union(enum) { none, found: Protocol, err: Failure };

/// `Protocol::detect`: newest to oldest; a JSON answer with a version names
/// the wire, 401/403 is a rejected password, anything else is still booting.
fn detect(server: *Server, a: Allocator) !Detected {
    const probes = [_]struct { []const u8, Protocol }{
        .{ "/api/info", .v2 },
        .{ "/api/status", .v2 },
        .{ "/api/health", .v2 },
        .{ "/global/health", .v1 },
    };
    for (probes) |p| {
        const resp = server.get(a, p[0], health_timeout_ms) orelse continue;
        if (resp.status == 401 or resp.status == 403) {
            var sbuf: [64]u8 = undefined;
            return .{ .err = Failure.protocol("opencode authentication rejected at {s}: {s}", .{ p[0], statusText(&sbuf, resp.status) }) };
        }
        if (resp.status / 100 != 2) continue;
        const v = json.parseFromSliceLeaky(json.Value, a, resp.body, .{}) catch continue;
        if (versionOf(v) != null) return .{ .found = p[1] };
    }
    return .none;
}

fn nonBlank(v: ?json.Value) ?[]const u8 {
    const s = v orelse return null;
    if (s != .string or std.mem.trim(u8, s.string, " \t\r\n").len == 0) return null;
    return s.string;
}

fn versionOf(v: json.Value) ?[]const u8 {
    if (nonBlank(field(v, "version"))) |s| return s;
    const data = field(v, "data") orelse return null;
    return nonBlank(field(data, "version"));
}

fn field(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

// ── the provider catalog ───────────────────────────────────────────────────

/// A value decoded and dropped (`serde::de::IgnoredAny`).
const Ignored = struct {
    pub fn jsonParse(_: Allocator, source: anytype, _: json.ParseOptions) !Ignored {
        try source.skipValue();
        return .{};
    }
    pub fn jsonParseFromValue(_: Allocator, _: json.Value, _: json.ParseOptions) !Ignored {
        return .{};
    }
};

const Limit = struct { context: ?u64 = null };

/// `ProviderModel`.
const WireModel = struct {
    limit: Limit = .{},
    name: ?[]const u8 = null,
    variants: ?json.ArrayHashMap(Ignored) = null,
};

/// `Provider`.
const WireProvider = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    models: ?json.ArrayHashMap(WireModel) = null,
};

/// `ProviderCatalog` (`GET /provider`).
const WireCatalog = struct {
    all: ?[]const WireProvider = null,
    connected: ?[]const []const u8 = null,
};

/// `V2Model` / `V2ModelList` (`GET /api/model`).
const V2Variant = struct { id: []const u8 };
const V2Model = struct {
    providerID: []const u8,
    id: []const u8,
    name: ?[]const u8 = null,
    limit: Limit = .{},
    variants: []const V2Variant = &.{},
    enabled: ?bool = null,
};
const V2ModelList = struct { data: []const V2Model = &.{} };

const parse_options: json.ParseOptions = .{ .ignore_unknown_fields = true, .duplicate_field_behavior = .use_last, .allocate = .alloc_always };

/// The provider catalog as `models_from_providers` reads it: each
/// provider's models in key order (a `BTreeMap`), each with its sorted
/// variant ids.
pub const CatalogModel = struct { key: []const u8, name: ?[]const u8, variants: []const []const u8 };
pub const CatalogProvider = struct { id: ?[]const u8, name: ?[]const u8, models: ?[]const CatalogModel };
pub const ProviderCatalog = struct { all: []const CatalogProvider, connected: []const []const u8 };

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortedKeys(a: Allocator, map: anytype) ![]const []const u8 {
    const keys = try a.dupe([]const u8, map.map.keys());
    std.mem.sort([]const u8, keys, {}, lessStr);
    return keys;
}

/// Decode `GET /provider`'s body (unknown fields skipped, not built).
pub fn decodeV1(a: Allocator, body: []const u8) !ProviderCatalog {
    const wire = try json.parseFromSliceLeaky(WireCatalog, a, body, parse_options);
    const all = wire.all orelse &.{};
    const providers = try a.alloc(CatalogProvider, all.len);
    for (all, providers) |p, *out| {
        out.* = .{ .id = p.id, .name = p.name, .models = null };
        const map = p.models orelse continue;
        const keys = try sortedKeys(a, map);
        const models = try a.alloc(CatalogModel, keys.len);
        for (keys, models) |k, *m| {
            const wm = map.map.get(k).?;
            m.* = .{ .key = k, .name = wm.name, .variants = if (wm.variants) |v| try sortedKeys(a, v) else &.{} };
        }
        out.models = models;
    }
    return .{ .all = providers, .connected = wire.connected orelse &.{} };
}

/// `catalog_from_v2_models`: disabled models dropped, providers in first-seen
/// order named by their id, models keyed (last wins) and sorted by id.
pub fn foldV2(a: Allocator, list: []const V2Model) !ProviderCatalog {
    var order: std.ArrayList([]const u8) = .empty;
    for (list) |m| {
        if (m.enabled != null and !m.enabled.?) continue;
        for (order.items) |o| {
            if (std.mem.eql(u8, o, m.providerID)) break;
        } else try order.append(a, m.providerID);
    }
    const providers = try a.alloc(CatalogProvider, order.items.len);
    for (order.items, providers) |pid, *out| {
        var models: std.ArrayList(CatalogModel) = .empty;
        for (list) |m| {
            if (m.enabled != null and !m.enabled.?) continue;
            if (!std.mem.eql(u8, m.providerID, pid)) continue;
            var variants: std.ArrayList([]const u8) = .empty;
            for (m.variants) |v| {
                for (variants.items) |seen| {
                    if (std.mem.eql(u8, seen, v.id)) break;
                } else try variants.append(a, v.id);
            }
            std.mem.sort([]const u8, variants.items, {}, lessStr);
            const row: CatalogModel = .{ .key = m.id, .name = m.name, .variants = variants.items };
            for (models.items) |*existing| {
                if (std.mem.eql(u8, existing.key, m.id)) {
                    existing.* = row;
                    break;
                }
            } else try models.append(a, row);
        }
        std.mem.sort(CatalogModel, models.items, {}, struct {
            fn lt(_: void, x: CatalogModel, y: CatalogModel) bool {
                return std.mem.lessThan(u8, x.key, y.key);
            }
        }.lt);
        out.* = .{ .id = pid, .name = pid, .models = models.items };
    }
    return .{ .all = providers, .connected = &.{} };
}

/// `variant_to_level`.
pub fn variantToLevel(v: []const u8) ?[]const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "minimal", "minimal" }, .{ "low", "low" },     .{ "medium", "medium" },
        .{ "high", "high" },       .{ "xhigh", "xhigh" }, .{ "x-high", "xhigh" },
        .{ "max", "max" },
    };
    for (map) |e| if (std.mem.eql(u8, e[0], v)) return e[1];
    return null;
}

fn levelRank(level: []const u8) usize {
    for (core.reasoning_levels, 0..) |l, i| if (std.mem.eql(u8, l, level)) return i;
    return core.reasoning_levels.len;
}

/// `models_from_providers`: connected providers only (all of them when
/// `connected` is empty), each provider's rows sorted by label.
pub fn modelsFromProviders(a: Allocator, cat: ProviderCatalog) ![]core.Model {
    var out: std.ArrayList(core.Model) = .empty;
    for (cat.all) |p| {
        const pid = p.id orelse continue;
        if (cat.connected.len > 0) {
            for (cat.connected) |c| {
                if (std.mem.eql(u8, c, pid)) break;
            } else continue;
        }
        const pname = p.name orelse pid;
        const models = p.models orelse continue;
        const start = out.items.len;
        for (models) |m| {
            var levels: std.ArrayList([]const u8) = .empty;
            for (m.variants) |v| if (variantToLevel(v)) |l| {
                for (levels.items) |seen| {
                    if (std.mem.eql(u8, seen, l)) break;
                } else try levels.append(a, l);
            };
            std.mem.sort([]const u8, levels.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return levelRank(x) < levelRank(y);
                }
            }.lt);
            try out.append(a, .{
                .id = try std.fmt.allocPrint(a, "{s}/{s}", .{ pid, m.key }),
                .label = m.name orelse m.key,
                .description = pname,
                .reasoning_levels = levels.items,
            });
        }
        std.mem.sort(core.Model, out.items[start..], {}, struct {
            fn lt(_: void, x: core.Model, y: core.Model) bool {
                return std.mem.lessThan(u8, x.label, y.label);
            }
        }.lt);
    }
    return out.items;
}

/// `agent_option`: "Server default", then the visible primary agents.
pub fn agentOption(a: Allocator, agents: json.Value) !core.ModelOption {
    var choices: std.ArrayList(core.Choice) = .empty;
    try choices.append(a, .{ .id = "", .label = "Server default" });
    if (field(agents, "data")) |data| if (data == .array) for (data.array.items) |agent| {
        if (field(agent, "hidden")) |h| if (h == .bool and h.bool) continue;
        if (field(agent, "mode")) |m| if (m == .string and std.mem.eql(u8, m.string, "subagent")) continue;
        const aid = field(agent, "id") orelse continue;
        const name = field(agent, "name") orelse continue;
        if (aid != .string or name != .string or aid.string.len == 0) continue;
        try choices.append(a, .{ .id = aid.string, .label = name.string });
    };
    return .{ .id = "agent", .label = "Agent", .choices = choices.items, .default_choice = "" };
}

// ── discovery ──────────────────────────────────────────────────────────────

/// `probe_models`: one short-lived server answers the catalog.
pub fn probeModels(gpa: Allocator, io: Io, budget_ms: u64) !core.Discovered {
    var env = try core.currentEnv(gpa);
    defer env.deinit();
    const exe = (core.resolve_cli(gpa, io, id) catch |e| return .{ .err = Failure.ioError(.other, @errorName(e)) }) orelse
        return .{ .err = Failure.notInstalled(install_hint) };
    defer gpa.free(exe);
    const budget_end = nowNs(io) + @as(i96, budget_ms) * std.time.ns_per_ms;
    const server = switch (try spawnServer(gpa, io, &env, exe, startupSecs(&env), budget_end)) {
        .ok => |s| s,
        .err => |f| return .{ .err = f },
    };
    defer {
        server.destroy(kill_grace_ms);
        gpa.destroy(server);
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rows = switch (try catalog(server, a)) {
        .ok => |r| r,
        .err => |f| return .{ .err = f },
    };
    return .{ .ok = try core.modelsJson(gpa, rows) };
}

const Rows = union(enum) { ok: []core.Model, err: Failure };

fn catalog(server: *Server, a: Allocator) !Rows {
    const cat: ProviderCatalog = switch (server.protocol) {
        .v1 => blk: {
            const body = switch (server.getOk(a, "/provider")) {
                .ok => |b| b,
                .err => |f| return .{ .err = f },
            };
            break :blk decodeV1(a, body) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return .{ .err = Failure.protocol("opencode GET /provider: {s}", .{@errorName(e)}) },
            };
        },
        .v2 => blk: {
            // The 2.x catalog syncs shortly after health opens: an empty
            // list right then is a race, not a fact.
            var attempt: usize = 0;
            while (true) : (attempt += 1) {
                const body = switch (server.getOk(a, "/api/model")) {
                    .ok => |b| b,
                    .err => |f| return .{ .err = f },
                };
                const list = json.parseFromSliceLeaky(V2ModelList, a, body, parse_options) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => return .{ .err = Failure.protocol("opencode GET /api/model: {s}", .{@errorName(e)}) },
                };
                if (list.data.len > 0 or attempt == 4) break :blk try foldV2(a, list.data);
                Io.sleep(server.io, .fromMilliseconds(@intCast(v2_empty_retry_ms)), .awake) catch {};
            }
        },
    };
    const rows = try modelsFromProviders(a, cat);
    if (server.protocol == .v2) {
        const body = switch (server.getOk(a, "/api/agent")) {
            .ok => |b| b,
            .err => |f| return .{ .err = f },
        };
        const agents = json.parseFromSliceLeaky(json.Value, a, body, .{}) catch
            return .{ .err = Failure.protocol("opencode GET /api/agent: error decoding response body", .{}) };
        const option = try a.alloc(core.ModelOption, 1);
        option[0] = try agentOption(a, agents);
        for (rows) |*m| m.options = option;
    }
    if (rows.len == 0) return .{ .err = Failure.protocol("opencode advertised no models (`opencode auth login` to configure a provider)", .{}) };
    return .{ .ok = rows };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

var test_cli: ?[]const u8 = null;

fn testResolve(gpa: Allocator, _: Io, wire: []const u8) anyerror!?[]u8 {
    if (!std.mem.eql(u8, wire, id)) return null;
    const p = test_cli orelse return null;
    return try gpa.dupe(u8, p);
}

/// A mock `opencode`: records its argv, password and client name, then
/// idles like a server (or fails to boot in mode `exit`).
const mock_opencode =
    \\#!/bin/sh
    \\d='@DIR@'
    \\if [ "$1" = "--version" ]; then echo "1.4.0"; exit 0; fi
    \\printf '%s\n' "$*" >> "$d/args"
    \\printf '%s\n' "$OPENCODE_SERVER_PASSWORD" > "$d/password"
    \\printf '%s\n' "$OPENCODE_CLIENT" > "$d/client"
    \\read -r mode < "$d/mode"
    \\case "$mode" in
    \\  exit) echo "opencode: invalid config" >&2; exit 3;;
    \\esac
    \\exec /bin/sleep 30
    \\
;

const Reply = struct { status: []const u8 = "200 OK", body: []const u8 = "{}", hang: bool = false };

/// The in-process stand-in for `opencode serve`'s HTTP side.
const Mock = struct {
    io: Io,
    server: net.Server,
    port: u16,
    respond: *const fn (path: []const u8, seen: usize) Reply,
    mu: Io.Mutex = .init,
    paths: std.ArrayList([]u8) = .empty,
    auths: std.ArrayList([]u8) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// One per connection, so a stray connection from another process on
    /// this machine cannot stall the probe's requests.
    workers: std.ArrayList(std.Thread) = .empty,

    fn start(self: *Mock, respond: *const fn ([]const u8, usize) Reply) !void {
        const io = testing.io;
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{ .io = io, .server = try addr.listen(io, .{}), .port = 0, .respond = respond };
        self.port = self.server.socket.address.ip4.port;
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Polls so a stop never depends on a wake-up connection getting through.
    fn acceptLoop(self: *Mock) void {
        while (!self.stop.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 20) catch return;
            if (ready == 0) continue;
            const conn = self.server.accept(self.io) catch return;
            const th = std.Thread.spawn(.{}, serve, .{ self, conn }) catch {
                conn.close(self.io);
                continue;
            };
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.workers.append(testing.allocator, th) catch th.join();
        }
    }

    fn count(self: *Mock, path: []const u8) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var n: usize = 0;
        for (self.paths.items) |p| if (std.mem.eql(u8, p, path)) {
            n += 1;
        };
        return n;
    }

    fn serve(self: *Mock, conn: net.Stream) void {
        defer conn.close(self.io);
        // A stray connection that never sends a request is dropped.
        var watch: Watch = .{ .io = self.io, .stream = conn, .deadline = nowNs(self.io) + 3 * std.time.ns_per_s };
        const th = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch null;
        defer {
            watch.done.store(true, .release);
            if (th) |t| t.join();
        }
        var rbuf: [8192]u8 = undefined;
        var r = conn.reader(self.io, &rbuf);
        const line = (r.interface.takeDelimiter('\n') catch null) orelse return;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next();
        const path = testing.allocator.dupe(u8, it.next() orelse "") catch return;
        var auth: []u8 = testing.allocator.dupe(u8, "") catch return;
        while (r.interface.takeDelimiter('\n') catch null) |h| {
            const hl = std.mem.trimEnd(u8, h, "\r");
            if (hl.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(hl, "authorization:")) {
                testing.allocator.free(auth);
                auth = testing.allocator.dupe(u8, std.mem.trim(u8, hl["authorization:".len..], " ")) catch return;
            }
        }
        const seen = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.paths.append(testing.allocator, path) catch {};
            self.auths.append(testing.allocator, auth) catch {};
            var n: usize = 0;
            for (self.paths.items) |p| if (std.mem.eql(u8, p, path)) {
                n += 1;
            };
            break :blk n;
        };
        const reply = self.respond(path, seen);
        if (reply.hang) {
            while (!self.stop.load(.acquire)) Io.sleep(self.io, .fromMilliseconds(10), .awake) catch return;
            return;
        }
        var wb: [1024]u8 = undefined;
        var w = conn.writer(self.io, &wb);
        // Large bodies go out chunked, in pieces, to exercise reassembly.
        if (reply.body.len > 64) {
            w.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n", .{reply.status}) catch return;
            var at: usize = 0;
            while (at < reply.body.len) {
                const n = @min(97, reply.body.len - at);
                w.interface.print("{x}\r\n{s}\r\n", .{ n, reply.body[at .. at + n] }) catch return;
                w.interface.flush() catch return;
                at += n;
            }
            w.interface.writeAll("0\r\n\r\n") catch return;
        } else {
            w.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ reply.status, reply.body.len, reply.body }) catch return;
        }
        w.interface.flush() catch {};
    }

    fn stopAndFree(self: *Mock) void {
        self.stop.store(true, .release);
        if (self.thread) |th| th.join();
        for (self.workers.items) |th| th.join();
        self.workers.deinit(testing.allocator);
        self.server.deinit(self.io);
        for (self.paths.items) |p| testing.allocator.free(p);
        self.paths.deinit(testing.allocator);
        for (self.auths.items) |p| testing.allocator.free(p);
        self.auths.deinit(testing.allocator);
    }
};

var mock_port: u16 = 0;

fn mockPort(_: Io) anyerror!u16 {
    return mock_port;
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: Environ.Map,
    cli: []u8,
    saved_pick: *const fn (Io) anyerror!u16,
    saved_connect: u64,
    saved_health: u64,

    fn init(mode: []const u8) !*Fixture {
        const gpa = testing.allocator;
        const io = testing.io;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.tmp = testing.tmpDir(.{});
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
        try f.tmp.dir.createDirPath(io, "home");
        const script = try std.mem.replaceOwned(u8, gpa, mock_opencode, "@DIR@", f.root);
        defer gpa.free(script);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "opencode", .data = script, .flags = .{ .permissions = .executable_file } });
        f.cli = try std.fs.path.join(gpa, &.{ f.root, "opencode" });
        f.env = Environ.Map.init(gpa);
        const home = try std.fs.path.join(gpa, &.{ f.root, "home" });
        defer gpa.free(home);
        try f.env.put("HOME", home);
        try f.env.put("PATH", "/usr/bin:/bin");
        try f.env.put("HARNESS_DISABLE_SHELL_ENV", "1");
        try f.env.put(startup_env, "15");
        try f.tmp.dir.writeFile(io, .{ .sub_path = "mode", .data = mode });
        core.env_override = &f.env;
        core.resolve_cli = testResolve;
        test_cli = f.cli;
        f.saved_pick = pick_port;
        pick_port = mockPort;
        // Loopback connects on a loaded machine can stall for a SYN
        // retransmit (1 s, then 2 s); don't let that turn into a retry.
        f.saved_connect = connect_timeout_ms;
        f.saved_health = health_timeout_ms;
        connect_timeout_ms = 10_000;
        health_timeout_ms = 10_000;
        resetForTests();
        return f;
    }

    fn read(f: *Fixture, name: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
    }

    fn deinit(f: *Fixture) void {
        const gpa = testing.allocator;
        resetForTests();
        core.env_override = null;
        test_cli = null;
        pick_port = f.saved_pick;
        connect_timeout_ms = f.saved_connect;
        health_timeout_ms = f.saved_health;
        f.env.deinit();
        gpa.free(f.cli);
        gpa.free(f.root);
        f.tmp.cleanup();
        gpa.destroy(f);
    }
};

fn expectRows(r: core.Result, want: []const u8, source: core.Source) !void {
    switch (r) {
        .ok => |c| {
            defer testing.allocator.free(c.models);
            try testing.expectEqualStrings(want, c.models);
            try testing.expectEqual(source, c.source);
        },
        .err => |f| {
            std.debug.print("unexpected failure: {s}\n", .{f.message()});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFailure(r: core.Discovered, want: []const u8) !void {
    switch (r) {
        .ok => |m| {
            defer testing.allocator.free(m);
            std.debug.print("unexpected catalog: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
        .err => |f| {
            var buf: [1024]u8 = undefined;
            try testing.expectEqualStrings(want, f.display(&buf));
        },
    }
}

const v1_catalog =
    \\{"all":[{"id":"anthropic","name":"Anthropic","models":{"claude-opus-5":{"name":"Claude Opus 5","variants":{"max":{},"low":{"nested":[{"unused":1}]},"high":{},"medium":{},"turbo":{}},"limit":{"context":200000},"cost":{"input":1}},"claude-haiku-4-5":{"name":"Claude Haiku 4.5","variants":null},"a-model":{"name":null}},"options":{"unused":[true,null]}},{"id":"opencode","name":"OpenCode Zen","models":{"big-pickle":{"name":"Big Pickle"}}},{"name":"no id","models":{"m":{}}},{"id":"empty","models":null}],"default":{"x":"y"},"connected":["anthropic","empty"]}
;

const v1_rows =
    "[{\"id\":\"anthropic/claude-haiku-4-5\",\"label\":\"Claude Haiku 4.5\",\"description\":\"Anthropic\",\"reasoningLevels\":[],\"options\":[]}," ++
    "{\"id\":\"anthropic/claude-opus-5\",\"label\":\"Claude Opus 5\",\"description\":\"Anthropic\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"max\"],\"options\":[]}," ++
    "{\"id\":\"anthropic/a-model\",\"label\":\"a-model\",\"description\":\"Anthropic\",\"reasoningLevels\":[],\"options\":[]}]";

fn v1Server(path: []const u8, seen: usize) Reply {
    if (std.mem.eql(u8, path, "/global/health")) {
        // Still booting on the first poll.
        if (seen == 1) return .{ .status = "503 Service Unavailable", .body = "booting" };
        return .{ .body = "{\"healthy\":true,\"version\":\"1.4.0\"}" };
    }
    if (std.mem.eql(u8, path, "/provider")) return .{ .body = v1_catalog };
    return .{ .status = "404 Not Found", .body = "<html>not found</html>" };
}

test "catalog_opencode 1.x: boots serve with a password and lists connected providers' models" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("serve");
    defer f.deinit();
    var mock: Mock = undefined;
    try mock.start(v1Server);
    defer mock.stopAndFree();
    mock_port = mock.port;
    try expectRows(try harness().modelCatalog(gpa, io, false), v1_rows, .live);

    const args = try f.read("args");
    defer gpa.free(args);
    // Every launch is `serve` on the chosen port (a stalled loopback connect
    // on a loaded machine may cost one retried attempt).
    const want_args = try std.fmt.allocPrint(gpa, "serve --port {d} --hostname 127.0.0.1", .{mock.port});
    defer gpa.free(want_args);
    var launches = std.mem.tokenizeScalar(u8, args, '\n');
    var n_launches: usize = 0;
    while (launches.next()) |l| : (n_launches += 1) try testing.expectEqualStrings(want_args, l);
    try testing.expect(n_launches >= 1);
    const client = try f.read("client");
    defer gpa.free(client);
    try testing.expectEqualStrings("harness\n", client);
    const password = try f.read("password");
    defer gpa.free(password);
    const cred = try std.fmt.allocPrint(gpa, "opencode:{s}", .{std.mem.trimEnd(u8, password, "\n")});
    defer gpa.free(cred);
    var b64: [128]u8 = undefined;
    const want_auth = try std.fmt.allocPrint(gpa, "Basic {s}", .{std.base64.standard.Encoder.encode(&b64, cred)});
    defer gpa.free(want_auth);
    try testing.expectEqual(@as(usize, 36), std.mem.trimEnd(u8, password, "\n").len);
    // The launch that answered used its own password on the catalog call.
    var last_provider_auth: ?[]const u8 = null;
    for (mock.paths.items, mock.auths.items) |p, auth| {
        if (std.mem.eql(u8, p, "/provider")) last_provider_auth = auth;
    }
    try testing.expectEqualStrings(want_auth, last_provider_auth.?);
    // Booting (503) is polled through, then the catalog is read.
    try testing.expect(mock.count("/global/health") >= 2);
    try testing.expectEqual(n_launches, mock.count("/provider"));

    // The server never answers now: a forced refresh keeps the last good
    // catalog (a transient failure).
    mock_port = try freeLocalhostPort(io);
    try f.env.put(startup_env, "1");
    try expectRows(try harness().modelCatalog(gpa, io, true), v1_rows, .cache);
}

const v2_models_json =
    \\{"location":{"directory":"/w"},"data":[{"providerID":"opencode","id":"muse","name":"Muse","limit":{"context":1000000},"variants":[{"id":"low","settings":{"x":1}},{"id":"x-high"},{"id":"low"}],"enabled":true},{"providerID":"opencode","id":"plain","enabled":true},{"providerID":"dead","id":"off","enabled":false},{"providerID":"zeta","id":"b"},{"providerID":"opencode","id":"alpha","name":"Zed"}]}
;

const v2_agents_json =
    \\{"data":[{"id":"build","name":"Build","mode":"primary","hidden":false},{"id":"sub","name":"Sub","mode":"subagent"},{"id":"hid","name":"Hid","hidden":true},{"id":"","name":"Empty"},{"id":"plan","name":"Plan","mode":"all"}]}
;

fn v2Server(path: []const u8, seen: usize) Reply {
    if (std.mem.eql(u8, path, "/api/info")) return .{ .body = "{\"data\":{\"version\":\"2.0.11\"}}" };
    if (std.mem.eql(u8, path, "/api/model")) {
        if (seen == 1) return .{ .body = "{\"data\":[]}" };
        return .{ .body = v2_models_json };
    }
    if (std.mem.eql(u8, path, "/api/agent")) return .{ .body = v2_agents_json };
    return .{ .status = "404 Not Found", .body = "" };
}

const agent_opt = "\"options\":[{\"id\":\"agent\",\"label\":\"Agent\",\"choices\":[{\"id\":\"\",\"label\":\"Server default\"},{\"id\":\"build\",\"label\":\"Build\"},{\"id\":\"plan\",\"label\":\"Plan\"}],\"defaultChoice\":\"\"}]";
const v2_rows =
    "[{\"id\":\"opencode/muse\",\"label\":\"Muse\",\"description\":\"opencode\",\"reasoningLevels\":[\"low\",\"xhigh\"]," ++ agent_opt ++ "}," ++
    "{\"id\":\"opencode/alpha\",\"label\":\"Zed\",\"description\":\"opencode\",\"reasoningLevels\":[]," ++ agent_opt ++ "}," ++
    "{\"id\":\"opencode/plain\",\"label\":\"plain\",\"description\":\"opencode\",\"reasoningLevels\":[]," ++ agent_opt ++ "}," ++
    "{\"id\":\"zeta/b\",\"label\":\"b\",\"description\":\"zeta\",\"reasoningLevels\":[]," ++ agent_opt ++ "}]";

test "catalog_opencode 2.x: settles an empty model list and adds the agent option to every row" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("serve");
    defer f.deinit();
    const saved = v2_empty_retry_ms;
    defer v2_empty_retry_ms = saved;
    v2_empty_retry_ms = 50;
    var mock: Mock = undefined;
    try mock.start(v2Server);
    defer mock.stopAndFree();
    mock_port = mock.port;
    try expectRows(try harness().modelCatalog(gpa, io, false), v2_rows, .live);
    // The empty first list was re-read rather than believed; agents are
    // read once, with the models.
    try testing.expectEqual(@as(usize, 2), mock.count("/api/model"));
    try testing.expectEqual(@as(usize, 1), mock.count("/api/agent"));
}

fn rejectServer(path: []const u8, _: usize) Reply {
    if (std.mem.eql(u8, path, "/api/info")) return .{ .status = "401 Unauthorized", .body = "" };
    return .{ .status = "404 Not Found", .body = "" };
}

fn failingServer(path: []const u8, _: usize) Reply {
    if (std.mem.eql(u8, path, "/global/health")) return .{ .body = "{\"version\":\"1.4.0\"}" };
    if (std.mem.eql(u8, path, "/provider")) return .{ .status = "500 Internal Server Error", .body = "  {\"name\":\"UnknownError\",\"data\":{\"message\":\"Check server logs for details.\"}}  " };
    return .{ .status = "404 Not Found", .body = "" };
}

fn malformedServer(path: []const u8, _: usize) Reply {
    if (std.mem.eql(u8, path, "/global/health")) return .{ .body = "{\"version\":\"1.4.0\"}" };
    if (std.mem.eql(u8, path, "/provider")) return .{ .body = "{\"all\":[{\"id\":\"x\",\"models\":{\"m\":{\"limit\":{\"context\":\"big\"}}}}]}" };
    return .{ .status = "404 Not Found", .body = "" };
}

fn emptyServer(path: []const u8, _: usize) Reply {
    if (std.mem.eql(u8, path, "/global/health")) return .{ .body = "{\"version\":\"1.4.0\"}" };
    if (std.mem.eql(u8, path, "/provider")) return .{ .body = "{\"all\":[{\"id\":\"x\",\"models\":{}}],\"connected\":[\"y\"]}" };
    return .{ .status = "404 Not Found", .body = "" };
}

fn hungServer(path: []const u8, _: usize) Reply {
    if (std.mem.eql(u8, path, "/global/health")) return .{ .body = "{\"version\":\"1.4.0\"}" };
    if (std.mem.eql(u8, path, "/provider")) return .{ .hang = true };
    return .{ .status = "404 Not Found", .body = "" };
}

fn bootingServer(path: []const u8, _: usize) Reply {
    if (std.mem.eql(u8, path, "/global/health")) return .{ .hang = true };
    // A web UI catch-all: no version, so not the API.
    return .{ .body = "{\"ok\":true}" };
}

test "catalog_opencode rejected passwords, HTTP errors, malformed and empty catalogs fail the probe" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("serve");
    defer f.deinit();
    const cases = [_]struct { *const fn ([]const u8, usize) Reply, []const u8, core.Code }{
        .{ rejectServer, "harness protocol error: opencode authentication rejected at /api/info: 401 Unauthorized", .auth_required },
        .{ failingServer, "harness protocol error: opencode GET /provider: 500 Internal Server Error {\"name\":\"UnknownError\",\"data\":{\"message\":\"Check server logs for details.\"}}", .failed },
        .{ malformedServer, "harness protocol error: opencode GET /provider: InvalidCharacter", .failed },
        .{ emptyServer, "harness protocol error: opencode advertised no models (`opencode auth login` to configure a provider)", .failed },
    };
    for (cases) |c| {
        var mock: Mock = undefined;
        try mock.start(c[0]);
        defer mock.stopAndFree();
        mock_port = mock.port;
        const r = try probeModels(gpa, io, 20_000);
        try expectFailure(r, c[1]);
        try testing.expectEqual(c[2], r.err.code);
    }
}

test "catalog_opencode a hung call, a server that never turns healthy and one that exits are bounded" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("serve");
    defer f.deinit();
    const saved_call = call_timeout_ms;
    const saved_health = health_timeout_ms;
    defer {
        call_timeout_ms = saved_call;
        health_timeout_ms = saved_health;
    }
    call_timeout_ms = 300;
    health_timeout_ms = 200;
    const started = nowNs(io);
    {
        var mock: Mock = undefined;
        try mock.start(hungServer);
        defer mock.stopAndFree();
        mock_port = mock.port;
        const want = try std.fmt.allocPrint(gpa, "harness protocol error: opencode GET /provider: error sending request for url (http://127.0.0.1:{d}/provider)", .{mock.port});
        defer gpa.free(want);
        try expectFailure(try probeModels(gpa, io, 20_000), want);
    }
    {
        var mock: Mock = undefined;
        try mock.start(bootingServer);
        defer mock.stopAndFree();
        mock_port = mock.port;
        try f.env.put(startup_env, "1");
        try expectFailure(try probeModels(gpa, io, 20_000), "harness protocol error: opencode serve did not become healthy within 1s (raise HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS if this machine's plugin load is genuinely slow)");
    }
    try f.tmp.dir.writeFile(io, .{ .sub_path = "mode", .data = "exit" });
    try f.env.put(startup_env, "15");
    mock_port = try freeLocalhostPort(io);
    const r = try probeModels(gpa, io, 20_000);
    try expectFailure(r, "harness protocol error: opencode serve exited unexpectedly (exit code 3): opencode: invalid config");
    try testing.expect(nowNs(io) - started < 15 * std.time.ns_per_s);
}

test "catalog_opencode not installed and a vanished binary are missing executables" {
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("serve");
    defer f.deinit();
    test_cli = null;
    const r = try harness().modelCatalog(gpa, io, false);
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings("harness binary not found: " ++ install_hint, r.err.display(&buf));
    try testing.expectEqual(core.Code.missing_executable, r.err.code);
    test_cli = "/nonexistent/opencode-harness-test";
    const gone = try probeModels(gpa, io, 20_000);
    try expectFailure(gone, "harness binary not found: /nonexistent/opencode-harness-test (version unknown)");
    const fb = try harness().fallbackModels(gpa);
    defer gpa.free(fb);
    try testing.expectEqualStrings("[]", fb);
}

test "catalog_opencode context follows opencode's config and environment" {
    const gpa = testing.allocator;
    const io = testing.io;
    const f = try Fixture.init("serve");
    defer f.deinit();
    const config = try std.fs.path.join(gpa, &.{ f.root, "config" });
    defer gpa.free(config);
    try f.env.put("XDG_CONFIG_HOME", config);
    var c1 = (try modelContext(gpa, io)).ok;
    defer c1.deinit(gpa);
    try f.tmp.dir.createDirPath(io, "config/opencode");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "config/opencode/opencode.json", .data = "{\"model\":\"synthetic/x\"}" });
    var c2 = (try modelContext(gpa, io)).ok;
    defer c2.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c1.hash, &c2.hash));
    try f.env.put("OPENCODE_SYNTHETIC", "1");
    var c3 = (try modelContext(gpa, io)).ok;
    defer c3.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c2.hash, &c3.hash));
}

test "catalog_opencode mapping: missing connected falls back to all, null optionals, variant ladders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try decodeV1(a, "{\"all\":[{\"id\":\"a\",\"models\":{\"m1\":{}}},{\"id\":\"b\",\"models\":{\"m2\":{}}}]}");
    try testing.expectEqual(@as(usize, 2), (try modelsFromProviders(a, all)).len);
    const empty_connected = try decodeV1(a, "{\"all\":[{\"id\":\"a\",\"models\":{\"m1\":{}}},{\"id\":\"b\",\"models\":{\"m2\":{}}}],\"connected\":[]}");
    try testing.expectEqual(@as(usize, 2), (try modelsFromProviders(a, empty_connected)).len);
    const nulls = try decodeV1(a, "{\"all\":[{\"id\":\"local\",\"name\":null,\"models\":{\"small\":{\"name\":null,\"variants\":null},\"thinking\":{\"variants\":{\"high\":{\"nested\":[{\"unused\":\"configuration\"}]}},\"capabilities\":{\"large\":[1,2,3]},\"limit\":{\"context\":200000}}}},{\"id\":\"empty\",\"models\":null}],\"connected\":null}");
    const rows = try modelsFromProviders(a, nulls);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("local/small", rows[0].id);
    try testing.expectEqualStrings("local", rows[0].description.?);
    try testing.expectEqual(@as(usize, 0), rows[0].reasoning_levels.len);
    try testing.expectEqualStrings("high", rows[1].reasoning_levels[0]);
    try testing.expectError(error.UnexpectedToken, decodeV1(a, "{\"all\":[{\"id\":\"x\",\"models\":{\"m\":{\"limit\":null}}}]}"));
    const opt = try agentOption(a, .null);
    try testing.expectEqual(@as(usize, 1), opt.choices.len);
    var tbuf: [320]u8 = undefined;
    const long: [400]u8 = @splat('x');
    try testing.expectEqualStrings(long[0..300] ++ "…", truncateBody(&tbuf, &long));
    try testing.expectEqualStrings("short", truncateBody(&tbuf, "  short \n"));
}

test "catalog_opencode HTTP responses parse by length, chunks and close" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try parseResponse(a, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab", false)) == null);
    try testing.expectError(error.BadResponse, parseResponse(a, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab", true));
    const cl = (try parseResponse(a, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nab", false)).?;
    try testing.expectEqualStrings("ab", cl.body);
    const ch = (try parseResponse(a, "HTTP/1.1 404 Not Found\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\n\r\n", false)).?;
    try testing.expectEqual(@as(u16, 404), ch.status);
    try testing.expectEqualStrings("abcde", ch.body);
    const closed = (try parseResponse(a, "HTTP/1.0 200 OK\r\n\r\nrest", true)).?;
    try testing.expectEqualStrings("rest", closed.body);
    var sbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("403 Forbidden", statusText(&sbuf, 403));
}
