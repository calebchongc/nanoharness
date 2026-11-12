//! Harness as a connected app of browse (justrach/browse#4, protocol
//! `v1-p256-sig`, browse `docs/connected-apps.md`; spec in
//! `docs/browse-connected-apps.md`), ported from
//! `crates/engine/src/browse_link/mod.rs` and the `BrowseLinkStatus`,
//! `BrowseLinkPair` and `BrowseLinkDisconnect` handlers in
//! `crates/engine/src/rpc.rs`.
//!
//! - Discovery: browse writes `connect.json`
//!   (`~/Library/Application Support/browse/Agent/connect.json`, or
//!   `HARNESS_BROWSE_CONNECT`) while Connected apps is on:
//!   `{"protocol":[...],"port":N,"browse_key":b64,"pid":N}`. A file whose
//!   process is gone (a crashed browse) doesn't count.
//! - Pairing: `POST /pair` with Harness's public key; both apps show the same
//!   six digits; the user confirms in browse; a background thread asks
//!   `/pair/status` (signed) every second until the user answers or the offer
//!   expires. browse's key is pinned from then on (`browse-link.json`, 0600,
//!   no secret; the private key is in the `KeyStore`).
//! - Every signed answer is checked against the pinned key before anything in
//!   it is believed; a signed `unknown_client` forgets the pairing.
//!
//! The run relay (`proxy.rs`, `mcp_server_for_run`, `end_run`) isn't ported:
//! none of the three RPCs uses it.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;
const Environ = std.process.Environ;

pub const wire = @import("browse_link_wire.zig");
pub const keystore = @import("browse_link_keystore.zig");
pub const http = @import("browse_link_http.zig");

pub const KeyStore = keystore.KeyStore;
pub const STATE_FILE = "browse-link.json";
const APP_NAME = "Harness";

/// `connect_file()`: `HARNESS_BROWSE_CONNECT` (non-empty), else
/// `$HOME/Library/Application Support/browse/Agent/connect.json`, else none.
pub fn connectFilePath(gpa: Allocator, env: *const Environ.Map) !?[]u8 {
    if (env.get("HARNESS_BROWSE_CONNECT")) |v| if (v.len > 0) return try gpa.dupe(u8, v);
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(gpa, &.{ home, "Library/Application Support/browse/Agent/connect.json" });
}

// ── connect.json ───────────────────────────────────────────────────────────

/// What `connect.json` says (owned).
const Found = struct {
    port: u16,
    browse_key: []u8,

    fn deinit(self: *Found, gpa: Allocator) void {
        gpa.free(self.browse_key);
    }
};

fn readFound(gpa: Allocator, io: Io, path: []const u8) ?Found {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(bytes);
    var parsed = json.parseFromSlice(json.Value, gpa, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    // `#[serde(default)] protocol: Vec<String>`.
    var speaks = false;
    if (o.get("protocol")) |p| switch (p) {
        .null => {},
        .array => |a| for (a.items) |item| {
            if (item != .string) return null;
            if (std.mem.eql(u8, item.string, wire.PROTOCOL)) speaks = true;
        },
        else => return null,
    };
    const port: u16 = switch (o.get("port") orelse return null) {
        .integer => |n| std.math.cast(u16, n) orelse return null,
        else => return null,
    };
    const key = switch (o.get("browse_key") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const pid: ?i32 = if (o.get("pid")) |p| switch (p) {
        .null => null,
        .integer => |n| std.math.cast(i32, n) orelse return null,
        else => return null,
    } else null;
    if (!speaks) return null;
    // A file left behind by a browse that crashed.
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (pid) |p| {
            std.posix.kill(p, @enumFromInt(0)) catch |e| switch (e) {
                error.ProcessNotFound => return null,
                else => {},
            };
        }
    }
    return .{ .port = port, .browse_key = gpa.dupe(u8, key) catch return null };
}

// ── browse-link.json ───────────────────────────────────────────────────────

/// The pairing Harness keeps. No secret.
const Pairing = struct {
    client_id: []u8,
    /// browse's key at pairing, pinned: answers must be signed by it.
    browse_key: []u8,
    scopes: [][]u8,
    paired_at: i64,

    fn deinit(self: *Pairing, gpa: Allocator) void {
        gpa.free(self.client_id);
        gpa.free(self.browse_key);
        freeStrings(gpa, self.scopes);
    }

    fn clone(self: Pairing, gpa: Allocator) !Pairing {
        const client_id = try gpa.dupe(u8, self.client_id);
        errdefer gpa.free(client_id);
        const browse_key = try gpa.dupe(u8, self.browse_key);
        errdefer gpa.free(browse_key);
        return .{ .client_id = client_id, .browse_key = browse_key, .scopes = try dupeStrings(gpa, self.scopes), .paired_at = self.paired_at };
    }

    /// serde: every field required, unknown ones ignored.
    fn parse(gpa: Allocator, bytes: []const u8) ?Pairing {
        var parsed = json.parseFromSlice(json.Value, gpa, bytes, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const o = parsed.value.object;
        const client_id = stringField(o, "clientId") orelse return null;
        const browse_key = stringField(o, "browseKey") orelse return null;
        const paired_at = switch (o.get("pairedAt") orelse return null) {
            .integer => |n| n,
            else => return null,
        };
        const scopes_v = o.get("scopes") orelse return null;
        if (scopes_v != .array) return null;
        for (scopes_v.array.items) |s| if (s != .string) return null;
        const scopes = stringList(gpa, scopes_v) catch return null;
        errdefer freeStrings(gpa, scopes);
        const cid = gpa.dupe(u8, client_id) catch {
            freeStrings(gpa, scopes);
            return null;
        };
        const bk = gpa.dupe(u8, browse_key) catch {
            gpa.free(cid);
            freeStrings(gpa, scopes);
            return null;
        };
        return .{ .client_id = cid, .browse_key = bk, .scopes = scopes, .paired_at = paired_at };
    }

    /// `serde_json::to_vec_pretty`.
    fn toJson(self: Pairing, gpa: Allocator) ![]u8 {
        return json.Stringify.valueAlloc(gpa, .{
            .clientId = self.client_id,
            .browseKey = self.browse_key,
            .scopes = self.scopes,
            .pairedAt = self.paired_at,
        }, .{ .whitespace = .indent_2 });
    }
};

fn stringField(o: json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn freeStrings(gpa: Allocator, list: []const []u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn dupeStrings(gpa: Allocator, list: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (list) |s| {
        out[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return out;
}

/// `string_list`: the strings of an array (others skipped), else empty.
fn stringList(gpa: Allocator, value: ?json.Value) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    if (value) |v| if (v == .array) for (v.array.items) |item| {
        if (item == .string) try out.append(gpa, try gpa.dupe(u8, item.string));
    };
    return out.toOwnedSlice(gpa);
}

fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

// ── errors ─────────────────────────────────────────────────────────────────

/// A refusal or failure talking to browse (`LinkError`).
pub const LinkError = union(enum) {
    /// Not running, or Connected apps is off.
    unavailable,
    /// browse doesn't know this client any more (revoked, forgotten).
    unknown_client,
    /// The answer wasn't signed by the pinned browse key.
    untrusted,
    /// browse refused: status, error code, and the body's `tool`/`scope`.
    refused: struct { status: u16, code: []u8, tool: ?[]u8, scope: ?[]u8 },
    transport: []u8,

    pub fn deinit(self: *LinkError, gpa: Allocator) void {
        switch (self.*) {
            .refused => |r| {
                gpa.free(r.code);
                if (r.tool) |t| gpa.free(t);
                if (r.scope) |s| gpa.free(s);
            },
            .transport => |m| gpa.free(m),
            else => {},
        }
    }

    /// The text Rust's `Display` gives (owned).
    pub fn message(self: LinkError, gpa: Allocator) ![]u8 {
        return switch (self) {
            .unavailable => gpa.dupe(u8, "browse isn't running with Settings › Agent › Connected apps on"),
            .unknown_client => gpa.dupe(u8, "browse no longer knows Harness; connect again in Settings"),
            .untrusted => gpa.dupe(u8, "the answer wasn't signed by the browse Harness paired with"),
            .refused => |r| blk: {
                if (std.mem.eql(u8, r.code, "out_of_scope")) if (r.tool) |tool| {
                    if (r.scope == null or std.mem.eql(u8, r.scope.?, "none"))
                        break :blk std.fmt.allocPrint(gpa, "browse doesn't let connected apps use {s}", .{tool});
                    break :blk std.fmt.allocPrint(gpa, "{s} needs the {s} scope, which Harness wasn't given; the user can allow it in browse › Settings › Agent › Connected apps", .{ tool, r.scope.? });
                };
                if (std.mem.eql(u8, r.code, "declined")) break :blk gpa.dupe(u8, "the user didn't allow Harness to use their tabs in browse");
                if (std.mem.eql(u8, r.code, "stale")) break :blk gpa.dupe(u8, "browse refused the request as stale; check this Mac's clock");
                break :blk std.fmt.allocPrint(gpa, "browse refused ({d} {s})", .{ r.status, r.code });
            },
            .transport => |m| std.fmt.allocPrint(gpa, "couldn't reach browse: {s}", .{m}),
        };
    }
};

/// reqwest's text for a request that failed before an answer.
fn sendFailure(gpa: Allocator, port: u16, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "error sending request for url (http://127.0.0.1:{d}{s})", .{ port, path });
}

pub const Answer = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Answer, gpa: Allocator) void {
        gpa.free(self.body);
    }
};

pub const Signed = union(enum) {
    ok: Answer,
    err: LinkError,

    pub fn deinit(self: *Signed, gpa: Allocator) void {
        switch (self.*) {
            .ok => |*a| a.deinit(gpa),
            .err => |*e| e.deinit(gpa),
        }
    }
};

fn nowMs(io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

/// `signed_post`: one signed request to browse at `port`, its answer's
/// signature checked against `pinned` before anything in it is believed
/// (refusals included: an unsigned `unknown_client` from whatever holds the
/// port must not unpair Harness).
pub fn signedPost(gpa: Allocator, io: Io, port: u16, key: wire.KeyPair, client_id: []const u8, pinned: wire.PublicKey, path: []const u8, body: []const u8, timeout_ms: u32) !Signed {
    var headers = try wire.signRequest(gpa, io, key, client_id, path, body, nowMs(io));
    defer headers.deinit(gpa);
    var stamp_buf: [24]u8 = undefined;
    const stamp = std.fmt.bufPrint(&stamp_buf, "{d}", .{headers.timestamp_ms}) catch unreachable;
    var response = http.post(gpa, io, port, path, &.{
        .{ .name = "X-Client-Id", .value = headers.client_id },
        .{ .name = "X-Timestamp", .value = stamp },
        .{ .name = "X-Nonce", .value = &headers.nonce },
        .{ .name = "X-Signature", .value = headers.signature },
    }, body, timeout_ms) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectFailed => .{ .err = .unavailable },
        error.SendFailed => .{ .err = .{ .transport = try sendFailure(gpa, port, path) } },
        error.BodyFailed => .{ .err = .{ .transport = try gpa.dupe(u8, "request or response body error") } },
    };
    errdefer response.deinit(gpa);
    if (!wire.answerIsSigned(pinned, response.body, &headers.nonce, response.signature)) {
        response.deinit(gpa);
        return .{ .err = .untrusted };
    }
    if (response.status >= 400) {
        defer response.deinit(gpa);
        var code: []const u8 = "";
        var tool: ?[]const u8 = null;
        var scope: ?[]const u8 = null;
        var parsed = json.parseFromSlice(json.Value, gpa, response.body, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        if (parsed) |p| if (p.value == .object) {
            code = stringField(p.value.object, "error") orelse "";
            tool = stringField(p.value.object, "tool");
            scope = stringField(p.value.object, "scope");
        };
        if (response.status == 401 and std.mem.eql(u8, code, "unknown_client")) return .{ .err = .unknown_client };
        const owned_code = try gpa.dupe(u8, code);
        errdefer gpa.free(owned_code);
        const owned_tool = if (tool) |t| try gpa.dupe(u8, t) else null;
        errdefer if (owned_tool) |t| gpa.free(t);
        const owned_scope = if (scope) |s| try gpa.dupe(u8, s) else null;
        return .{ .err = .{ .refused = .{ .status = response.status, .code = owned_code, .tool = owned_tool, .scope = owned_scope } } };
    }
    if (response.signature) |s| gpa.free(s);
    return .{ .ok = .{ .status = response.status, .body = response.body } };
}

// ── the link ───────────────────────────────────────────────────────────────

/// What Settings shows (`BrowseLinkStatus`), owned.
pub const Status = struct {
    /// browse is running with Connected apps on.
    browse_running: bool = false,
    paired: bool = false,
    scopes: [][]u8 = &.{},
    /// While pairing: the six digits browse should also show.
    pairing_code: ?[6]u8 = null,
    /// The running browse isn't the one Harness paired with.
    key_mismatch: bool = false,
    @"error": ?[]u8 = null,

    pub fn deinit(self: *Status, gpa: Allocator) void {
        freeStrings(gpa, self.scopes);
        if (self.@"error") |e| gpa.free(e);
        self.* = .{};
    }

    /// The reply's JSON (`#[serde(rename_all = "camelCase")]`, nulls kept).
    pub fn toJson(self: *const Status, gpa: Allocator) ![]u8 {
        return json.Stringify.valueAlloc(gpa, .{
            .browseRunning = self.browse_running,
            .paired = self.paired,
            .scopes = self.scopes,
            .pairingCode = if (self.pairing_code) |*c| @as(?[]const u8, c) else null,
            .keyMismatch = self.key_mismatch,
            .@"error" = self.@"error",
        }, .{});
    }
};

/// `start_pair`'s outcome: the six digits, or the error text (owned).
pub const PairResult = union(enum) {
    code: [6]u8,
    failed: []u8,
};

const Pending = struct {
    /// Which `startPair` this is, so an older pairing's thread can't clear a
    /// newer one's code when it finishes.
    generation: u64,
    code: [6]u8,
    poller: *Poller,
};

/// The background `/pair/status` poll of one pairing.
const Poller = struct {
    link: *Link,
    generation: u64,
    port: u16,
    key: wire.KeyPair,
    client_id: []u8,
    browse_key: []u8,
    expires_ms: u64,
    /// Set to abort (Rust's `task.abort()`): the thread stops at its next
    /// wait and records nothing.
    cancel: Io.Event = .unset,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn destroy(self: *Poller, gpa: Allocator) void {
        gpa.free(self.client_id);
        gpa.free(self.browse_key);
        gpa.destroy(self);
    }

    fn run(self: *Poller) void {
        const link = self.link;
        const outcome = self.poll() catch |e| switch (e) {
            error.Aborted => {
                self.done.store(true, .release);
                return;
            },
            else => link.gpa.dupe(u8, @errorName(e)) catch null,
        };
        link.mutex.lockUncancelable(link.io);
        const current = if (link.pending) |p| p.generation == self.generation else false;
        if (current and !self.cancel.isSet()) {
            if (outcome) |message| link.setErrorLocked(message);
            link.pending = null;
        } else if (outcome) |message| link.gpa.free(message);
        link.mutex.unlock(link.io);
        self.done.store(true, .release);
    }

    fn aborted(self: *Poller) bool {
        return self.cancel.isSet();
    }

    /// `poll_pairing`: null when paired, else the error text (owned).
    fn poll(self: *Poller) anyerror!?[]u8 {
        const link = self.link;
        const gpa = link.gpa;
        const io = link.io;
        const pinned = wire.parsePublicKey(self.browse_key) orelse return try gpa.dupe(u8, "browse's key is malformed");
        const deadline = Io.Clock.awake.now(io).nanoseconds + @as(i96, self.expires_ms) * std.time.ns_per_ms;
        while (Io.Clock.awake.now(io).nanoseconds < deadline) {
            self.cancel.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(link.poll_interval_ms), .clock = .awake } }) catch {};
            if (self.aborted()) return error.Aborted;
            var answer = try signedPost(gpa, io, self.port, self.key, self.client_id, pinned, "/pair/status", "{}", link.request_timeout_ms);
            defer answer.deinit(gpa);
            if (self.aborted()) return error.Aborted;
            const body = switch (answer) {
                .ok => |a| a.body,
                .err => |e| switch (e) {
                    .transport => continue,
                    else => return try e.message(gpa),
                },
            };
            var parsed = json.parseFromSlice(json.Value, gpa, body, .{}) catch null;
            defer if (parsed) |*p| p.deinit();
            const reply: ?json.ObjectMap = if (parsed) |p| (if (p.value == .object) p.value.object else null) else null;
            const s = (if (reply) |o| stringField(o, "status") else null) orelse continue;
            if (std.mem.eql(u8, s, "pending")) continue;
            if (std.mem.eql(u8, s, "paired")) {
                const scopes = try stringList(gpa, if (reply) |o| o.get("scopes") else null);
                errdefer freeStrings(gpa, scopes);
                link.mutex.lockUncancelable(io);
                defer link.mutex.unlock(io);
                // Cancelled (or started again) while browse was asking.
                if (link.generation != self.generation) {
                    freeStrings(gpa, scopes);
                    return try gpa.dupe(u8, "Pairing was cancelled.");
                }
                const client_id = try gpa.dupe(u8, self.client_id);
                errdefer gpa.free(client_id);
                const browse_key = try gpa.dupe(u8, self.browse_key);
                link.saveLocked(.{
                    .client_id = client_id,
                    .browse_key = browse_key,
                    .scopes = scopes,
                    .paired_at = @divFloor(nowMs(io), 1000),
                });
                return null;
            }
            if (std.mem.eql(u8, s, "declined")) return try gpa.dupe(u8, "Pairing was declined in browse.");
            if (std.mem.eql(u8, s, "expired")) return try gpa.dupe(u8, "The pairing code expired. Try again.");
            return try std.fmt.allocPrint(gpa, "unexpected pairing status: {s}", .{s});
        }
        return try gpa.dupe(u8, "browse didn't answer in time. Try again.");
    }
};

pub const Link = struct {
    /// Thread-safe: the pairing thread uses it too.
    gpa: Allocator,
    io: Io,
    state_file: []u8,
    keys: KeyStore,
    connect_file: ?[]u8,

    mutex: Io.Mutex = .init,
    pairing: ?Pairing = null,
    pending: ?Pending = null,
    /// `pairings_started`.
    generation: u64 = 0,
    last_error: ?[]u8 = null,
    /// Every pairing thread not yet joined.
    pollers: std.ArrayList(*Poller) = .empty,

    /// How often a pairing asks browse (Rust: 1 s).
    poll_interval_ms: u32 = 1_000,
    /// One request's deadline (Rust's client: 180 s).
    request_timeout_ms: u32 = 180_000,
    /// `refresh`'s deadline (Rust: 3 s).
    refresh_timeout_ms: u32 = 3_000,

    /// `BrowseLink::new`: takes `state_file`, `keys` and `connect_file`
    /// (owned by `gpa` from here on); reads a saved pairing.
    pub fn create(gpa: Allocator, io: Io, state_file: []u8, keys: KeyStore, connect_file: ?[]u8) !*Link {
        const self = try gpa.create(Link);
        self.* = .{ .gpa = gpa, .io = io, .state_file = state_file, .keys = keys, .connect_file = connect_file };
        if (Io.Dir.cwd().readFileAlloc(io, state_file, gpa, .limited(1 << 20))) |bytes| {
            defer gpa.free(bytes);
            self.pairing = Pairing.parse(gpa, bytes);
        } else |_| {}
        return self;
    }

    /// For a data dir: `<data_dir>/browse-link.json`, the platform key store,
    /// and `connect.json` from `env`.
    pub fn forDataDir(gpa: Allocator, io: Io, data_dir: []const u8, env: *const Environ.Map) !*Link {
        const state_file = try std.fs.path.join(gpa, &.{ data_dir, STATE_FILE });
        errdefer gpa.free(state_file);
        const keys = try keystore.forDataDir(gpa, data_dir);
        errdefer keys.deinit(gpa);
        const connect = try connectFilePath(gpa, env);
        errdefer if (connect) |c| gpa.free(c);
        return create(gpa, io, state_file, keys, connect);
    }

    /// Stops any pairing (waiting for its thread) and frees everything.
    pub fn destroy(self: *Link) void {
        const gpa = self.gpa;
        self.mutex.lockUncancelable(self.io);
        for (self.pollers.items) |p| p.cancel.set(self.io);
        self.pending = null;
        self.mutex.unlock(self.io);
        for (self.pollers.items) |p| {
            if (p.thread) |t| t.join();
            p.destroy(gpa);
        }
        self.pollers.deinit(gpa);
        if (self.pairing) |*p| p.deinit(gpa);
        if (self.last_error) |e| gpa.free(e);
        gpa.free(self.state_file);
        if (self.connect_file) |c| gpa.free(c);
        self.keys.deinit(gpa);
        gpa.destroy(self);
    }

    fn found(self: *Link) ?Found {
        return readFound(self.gpa, self.io, self.connect_file orelse return null);
    }

    fn setErrorLocked(self: *Link, message: ?[]u8) void {
        if (self.last_error) |old| self.gpa.free(old);
        self.last_error = message;
    }

    /// `save`, with the mutex held: write (0600) or remove the state file,
    /// and keep `pairing` (taken).
    fn saveLocked(self: *Link, pairing: ?Pairing) void {
        if (pairing) |p| {
            if (p.toJson(self.gpa)) |bytes| {
                defer self.gpa.free(bytes);
                keystore.writePrivate(self.gpa, self.io, self.state_file, bytes) catch {};
            } else |_| {}
        } else {
            Io.Dir.cwd().deleteFile(self.io, self.state_file) catch {};
        }
        if (self.pairing) |*old| old.deinit(self.gpa);
        self.pairing = pairing;
    }

    /// Cancel the pending pairing, if any (mutex held).
    fn abortPendingLocked(self: *Link) void {
        if (self.pending) |p| p.poller.cancel.set(self.io);
        self.pending = null;
    }

    /// Join the pairing threads that have finished.
    fn reap(self: *Link) void {
        self.mutex.lockUncancelable(self.io);
        var finished: std.ArrayList(*Poller) = .empty;
        defer finished.deinit(self.gpa);
        var i: usize = 0;
        while (i < self.pollers.items.len) {
            const p = self.pollers.items[i];
            if (p.done.load(.acquire)) {
                finished.append(self.gpa, p) catch break;
                _ = self.pollers.swapRemove(i);
            } else i += 1;
        }
        self.mutex.unlock(self.io);
        for (finished.items) |p| {
            if (p.thread) |t| t.join();
            p.destroy(self.gpa);
        }
    }

    /// `status`: what Settings shows (owned by `gpa`).
    pub fn status(self: *Link, gpa: Allocator) !Status {
        var f = self.found();
        defer if (f) |*x| x.deinit(self.gpa);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: Status = .{
            .browse_running = f != null,
            .paired = self.pairing != null,
            .pairing_code = if (self.pending) |p| p.code else null,
            .key_mismatch = if (f != null and self.pairing != null) !std.mem.eql(u8, f.?.browse_key, self.pairing.?.browse_key) else false,
        };
        errdefer out.deinit(gpa);
        if (self.pairing) |p| out.scopes = try dupeStrings(gpa, p.scopes);
        if (self.last_error) |e| out.@"error" = try gpa.dupe(u8, e);
        return out;
    }

    /// `start_pair`: the six digits to show. A thread polls browse until the
    /// user confirms, declines, or the offer expires. Blocks for one loopback
    /// request to `/pair` (up to `request_timeout_ms`).
    pub fn startPair(self: *Link, gpa: Allocator) !PairResult {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        self.generation += 1;
        const generation = self.generation;
        self.abortPendingLocked();
        self.setErrorLocked(null);
        self.mutex.unlock(io);
        self.reap();

        var f = self.found() orelse return .{ .failed = try (LinkError{ .unavailable = {} }).message(gpa) };
        defer f.deinit(self.gpa);
        const key = switch (self.keys.loadOrCreate(self.gpa, io)) {
            .key => |k| k,
            .failed => |m| {
                defer self.gpa.free(m);
                return .{ .failed = try gpa.dupe(u8, m) };
            },
        };
        const client_key = wire.publicKeyB64(key);
        const nonce = wire.nonce(io);
        const body = try json.Stringify.valueAlloc(gpa, .{
            .client_key = @as([]const u8, &client_key),
            .name = APP_NAME,
            .nonce = @as([]const u8, &nonce),
            .protocol = [_][]const u8{wire.PROTOCOL},
        }, .{});
        defer gpa.free(body);
        var response = http.post(gpa, io, f.port, "/pair", &.{}, body, self.request_timeout_ms) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const detail = try sendFailure(gpa, f.port, "/pair");
                defer gpa.free(detail);
                return .{ .failed = try (LinkError{ .transport = detail }).message(gpa) };
            },
        };
        defer response.deinit(gpa);
        // `response.json().await.unwrap_or_default()`.
        var parsed = json.parseFromSlice(json.Value, gpa, response.body, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        const reply: ?json.ObjectMap = if (parsed) |p| (if (p.value == .object) p.value.object else null) else null;
        if (response.status != 200) {
            const code = if (reply) |o| stringField(o, "error") else null;
            if (code) |c| {
                if (std.mem.eql(u8, c, "connected_apps_off"))
                    return .{ .failed = try gpa.dupe(u8, "Turn on Connected apps in browse (Settings › Agent), then try again.") };
                if (std.mem.eql(u8, c, "pairing_in_progress"))
                    return .{ .failed = try gpa.dupe(u8, "browse is already pairing with another app. Finish or cancel that first.") };
            }
            return .{ .failed = try std.fmt.allocPrint(gpa, "browse refused pairing ({d} {s})", .{ response.status, code orelse "" }) };
        }
        const client_id = (if (reply) |o| stringField(o, "client_id") else null) orelse "";
        const browse_key = (if (reply) |o| stringField(o, "browse_key") else null) orelse "";
        const protocol = (if (reply) |o| stringField(o, "protocol") else null) orelse "";
        // The answer to /pair isn't signed; the key it names must be the one
        // browse published, and the six digits are what stops a swap.
        if (client_id.len == 0 or !std.mem.eql(u8, browse_key, f.browse_key) or !std.mem.eql(u8, protocol, wire.PROTOCOL))
            return .{ .failed = try gpa.dupe(u8, "browse's pairing answer didn't match what it published") };
        const code = try wire.pairingCode(gpa, browse_key, &client_key, &nonce) orelse
            return .{ .failed = try gpa.dupe(u8, "couldn't derive the pairing code") };
        const expires_in: u64 = blk: {
            const v = (if (reply) |o| o.get("expires_in") else null) orelse break :blk 120;
            break :blk if (v == .integer and v.integer >= 0) @intCast(v.integer) else 120;
        };

        const poller = try self.gpa.create(Poller);
        poller.* = .{
            .link = self,
            .generation = generation,
            .port = f.port,
            .key = key,
            .client_id = self.gpa.dupe(u8, client_id) catch |e| {
                self.gpa.destroy(poller);
                return e;
            },
            .browse_key = self.gpa.dupe(u8, browse_key) catch |e| {
                self.gpa.free(poller.client_id);
                self.gpa.destroy(poller);
                return e;
            },
            .expires_ms = (expires_in +| 5) *| 1000,
        };
        // Held until the pairing is recorded, so the thread can't finish (and
        // clear it) before its code is up.
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.generation != generation) {
            poller.destroy(self.gpa);
            return .{ .failed = try gpa.dupe(u8, "Another pairing started.") };
        }
        self.pollers.append(self.gpa, poller) catch |e| {
            poller.destroy(self.gpa);
            return e;
        };
        poller.thread = std.Thread.spawn(.{}, Poller.run, .{poller}) catch |e| {
            _ = self.pollers.pop();
            poller.destroy(self.gpa);
            return e;
        };
        self.pending = .{ .generation = generation, .code = code, .poller = poller };
        return .{ .code = code };
    }

    /// Stop pairing, or forget a pairing (Disconnect). browse's own list
    /// keeps the app until the user revokes it there or it expires unused.
    pub fn disconnect(self: *Link) void {
        self.mutex.lockUncancelable(self.io);
        self.generation += 1;
        self.abortPendingLocked();
        self.setErrorLocked(null);
        self.saveLocked(null);
        self.mutex.unlock(self.io);
        self.keys.delete(self.io);
        self.reap();
    }

    const Target = struct {
        found: Found,
        key: wire.KeyPair,
        pairing: Pairing,
        pinned: wire.PublicKey,

        fn deinit(self: *Target, gpa: Allocator) void {
            self.found.deinit(gpa);
            self.pairing.deinit(gpa);
        }
    };

    /// `target`: the paired browse to talk to right now, if there is one.
    fn target(self: *Link) !union(enum) { ok: Target, err: LinkError } {
        var pairing = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const p = self.pairing orelse return .{ .err = .unknown_client };
            break :blk try p.clone(self.gpa);
        };
        errdefer pairing.deinit(self.gpa);
        var f = self.found() orelse {
            pairing.deinit(self.gpa);
            return .{ .err = .unavailable };
        };
        if (!std.mem.eql(u8, f.browse_key, pairing.browse_key)) {
            f.deinit(self.gpa);
            pairing.deinit(self.gpa);
            return .{ .err = .untrusted };
        }
        const key = self.keys.load(self.gpa, self.io) orelse {
            f.deinit(self.gpa);
            pairing.deinit(self.gpa);
            return .{ .err = .unknown_client };
        };
        const pinned = wire.parsePublicKey(pairing.browse_key) orelse {
            f.deinit(self.gpa);
            pairing.deinit(self.gpa);
            return .{ .err = .untrusted };
        };
        return .{ .ok = .{ .found = f, .key = key, .pairing = pairing, .pinned = pinned } };
    }

    /// `request`: a signed POST to the paired browse. `unknown_client`
    /// forgets the pairing.
    pub fn request(self: *Link, gpa: Allocator, path: []const u8, body: []const u8, timeout_ms: u32) !Signed {
        var t = switch (try self.target()) {
            .ok => |t| t,
            .err => |e| return .{ .err = e },
        };
        defer t.deinit(self.gpa);
        const result = try signedPost(gpa, self.io, t.found.port, t.key, t.pairing.client_id, t.pinned, path, body, timeout_ms);
        if (result == .err and result.err == .unknown_client) {
            const message = try self.gpa.dupe(u8, "browse no longer knows Harness (revoked, or unused for 30 days). Connect again.");
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.saveLocked(null);
            self.setErrorLocked(message);
        }
        return result;
    }

    /// `refresh`: Settings' view brought up to date (the scopes the user has
    /// now; whether browse still knows Harness). Best effort, at most
    /// `refresh_timeout_ms`; without browse it changes nothing.
    pub fn refresh(self: *Link) void {
        self.refreshInner() catch {};
    }

    fn refreshInner(self: *Link) !void {
        const gpa = self.gpa;
        switch (try self.target()) {
            .ok => |t| {
                var tt = t;
                tt.deinit(gpa);
            },
            .err => |e| {
                var ee = e;
                ee.deinit(gpa);
                return;
            },
        }
        var answer = try self.request(gpa, "/pair/status", "{}", self.refresh_timeout_ms);
        defer answer.deinit(gpa);
        const body = switch (answer) {
            .ok => |a| a.body,
            .err => return,
        };
        var parsed = json.parseFromSlice(json.Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const s = stringField(parsed.value.object, "status") orelse return;
        if (!std.mem.eql(u8, s, "paired")) return;
        const scopes = try stringList(gpa, parsed.value.object.get("scopes"));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = self.pairing orelse {
            freeStrings(gpa, scopes);
            return;
        };
        if (sameStrings(current.scopes, scopes)) {
            freeStrings(gpa, scopes);
            return;
        }
        var next = current.clone(gpa) catch |e| {
            freeStrings(gpa, scopes);
            return e;
        };
        freeStrings(gpa, next.scopes);
        next.scopes = scopes;
        self.saveLocked(next);
    }

    // ── the three RPCs ────────────────────────────────────────────────────

    /// `BrowseLinkStatus`: refresh, then the status as JSON (owned by `gpa`).
    /// Can block for up to `refresh_timeout_ms` (3 s) on a paired browse.
    pub fn rpcStatus(self: *Link, gpa: Allocator) ![]u8 {
        self.refresh();
        var s = try self.status(gpa);
        defer s.deinit(gpa);
        return s.toJson(gpa);
    }

    /// `BrowseLinkPair`: `{"code":"123456"}`, or the error text the RPC
    /// fails with.
    pub fn rpcPair(self: *Link, gpa: Allocator) !Reply {
        return switch (try self.startPair(gpa)) {
            .code => |c| .{ .json = try std.fmt.allocPrint(gpa, "{{\"code\":\"{s}\"}}", .{&c}) },
            .failed => |m| .{ .failed = m },
        };
    }

    /// `BrowseLinkDisconnect`: `{"ok":true}`.
    pub fn rpcDisconnect(self: *Link, gpa: Allocator) ![]u8 {
        self.disconnect();
        return gpa.dupe(u8, "{\"ok\":true}");
    }
};

/// An RPC's answer: its JSON, or the text it fails with (`RpcError::Failed`).
/// Both owned by the caller's allocator.
pub const Reply = union(enum) {
    json: []u8,
    failed: []u8,

    pub fn deinit(self: Reply, gpa: Allocator) void {
        switch (self) {
            .json, .failed => |s| gpa.free(s),
        }
    }
};

// ── one link per data dir (`BrowseLink::shared`) ───────────────────────────

/// Links outlive any request (a pairing in progress keeps running), so they
/// use a thread-safe process allocator and are never freed.
const long_gpa = std.heap.smp_allocator;
var registry_mutex: Io.Mutex = .init;
var registry: std.StringHashMapUnmanaged(*Link) = .empty;

/// The link for `data_dir`, made on first use (`connect.json`'s location
/// read from `env` then).
pub fn shared(io: Io, data_dir: []const u8, env: *const Environ.Map) !*Link {
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (registry.get(data_dir)) |link| return link;
    const key = try long_gpa.dupe(u8, data_dir);
    errdefer long_gpa.free(key);
    const link = try Link.forDataDir(long_gpa, io, data_dir, env);
    errdefer link.destroy();
    try registry.put(long_gpa, key, link);
    return link;
}

/// `BrowseLinkStatus` for the engine: `{"browseRunning":…,"paired":…,
/// "scopes":[…],"pairingCode":…,"keyMismatch":…,"error":…}`. Asks a paired,
/// running browse `/pair/status` first (up to 3 s).
pub fn status(gpa: Allocator, io: Io, data_dir: []const u8, env: *const Environ.Map) ![]u8 {
    return (try shared(io, data_dir, env)).rpcStatus(gpa);
}

/// `BrowseLinkPair` for the engine: `.json` = `{"code":"NNNNNN"}`, or
/// `.failed` = the error text. One loopback request to browse's `/pair`
/// (immediate on a running browse; up to 180 s if it hangs); the wait for the
/// user runs on a background thread.
pub fn pair(gpa: Allocator, io: Io, data_dir: []const u8, env: *const Environ.Map) !Reply {
    return (try shared(io, data_dir, env)).rpcPair(gpa);
}

/// `BrowseLinkDisconnect` for the engine: `{"ok":true}`. Local only.
pub fn disconnect(gpa: Allocator, io: Io, data_dir: []const u8, env: *const Environ.Map) ![]u8 {
    return (try shared(io, data_dir, env)).rpcDisconnect(gpa);
}

// ── tests ──────────────────────────────────────────────────────────────────

test {
    _ = wire;
    _ = keystore;
    _ = http;
    _ = @import("browse_link_tests.zig");
}
