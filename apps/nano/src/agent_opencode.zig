//! OpenCode adapter (`crates/harness/src/opencode/mod.rs`), 1.x server API.
//!
//! `opencode serve --port P --hostname 127.0.0.1` with a per-run password;
//! the turn creates (or reuses) a session, posts `prompt_async`, and folds
//! the `/global/event` SSE bus into the transcript until the session goes
//! idle. Permission and question events become questions answered over
//! their reply endpoints; `/session/{id}/abort` interrupts. A server that
//! only speaks the 2.x API (`/api/*`) is refused with a clear error.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const builtin = @import("builtin");
const posix = std.posix;
const agent_turn = @import("agent_turn.zig");
const agent_proc = @import("agent_proc.zig");
const Turn = agent_turn.Turn;
const Event = agent_turn.Event;
const Call = agent_turn.Call;
const get = agent_turn.get;
const getStr = agent_turn.getStr;

pub const adapter: agent_turn.Adapter = .{
    .name = "opencode serve",
    .run = run,
    .interrupt = interrupt,
    .answer = answer,
    .steers_mid_turn = false,
};

pub const install_hint = "opencode (searched PATH, the login shell's PATH, ~/.opencode/bin, ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, and fnm/nvm/volta/pnpm/bun install dirs; Windows also checks USERPROFILE, %APPDATA%\\npm, and explicit NVM_SYMLINK/VOLTA_HOME/PNPM_HOME; install with `curl -fsSL https://opencode.ai/install | bash` or `npm install -g @opencode/cli`, then `opencode auth login`; set OPENCODE_EXECUTABLE to override)";
pub const extra_paths = [_][]const u8{ "~/.opencode/bin/opencode", "~/.local/bin/opencode", "~/.bun/bin/opencode", "~/.npm-global/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode" };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// HTTP/1.1 to the local server
// ---------------------------------------------------------------------------

pub const Server = struct {
    io: Io,
    port: u16,
    /// `Basic base64("opencode:<password>")`.
    auth: []const u8,
    /// Percent-encoded working directory.
    dir: []const u8,
};

/// Percent-encode keeping `A-Za-z0-9-_.~/`.
pub fn pctEncode(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/') {
            try out.append(a, c);
        } else try out.print(a, "%{X:0>2}", .{c});
    }
    return out.items;
}

pub const Response = struct { status: u16, body: []const u8 };

/// `CALL_TIMEOUT`: the bound on every request but the event stream.
pub const call_timeout_ms: u32 = 60_000;
/// A readiness probe's bound.
pub const probe_timeout_ms: u32 = 2000;
/// Largest response body read whole.
pub const max_body_bytes: usize = 32 * 1024 * 1024;
/// Largest single SSE event.
pub const max_event_bytes: usize = 64 * 1024 * 1024;

/// The next header line without its line end; a line longer than the read
/// buffer is skipped whole (null at the end of the stream).
fn headerLine(rd: *std.Io.Reader) !?[]const u8 {
    while (true) {
        const raw = rd.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = try rd.discardDelimiterInclusive('\n');
                continue;
            },
            else => |e| return e,
        };
        return std.mem.trimEnd(u8, raw orelse return null, "\r");
    }
}

/// Server-sent events, split by any line end (`\n`, `\r\n`, `\r`), with
/// each event's `data:` lines joined by `\n` (the SSE spec).
pub const Sse = struct {
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    has_data: bool = false,
    /// The last byte was `\r`: a `\n` right after it ends no second line.
    cr: bool = false,

    pub fn deinit(self: *Sse, gpa: Allocator) void {
        self.line.deinit(gpa);
        self.data.deinit(gpa);
    }

    /// Feed `bytes`; each completed event's data is appended to `out`
    /// (copied into `a`).
    pub fn feed(self: *Sse, gpa: Allocator, a: Allocator, bytes: []const u8, out: *std.ArrayList([]const u8)) !void {
        for (bytes) |b| {
            if (b == '\n' and self.cr) {
                self.cr = false;
                continue;
            }
            self.cr = b == '\r';
            if (b == '\r' or b == '\n') {
                try self.endLine(gpa, a, out);
                continue;
            }
            if (self.line.items.len + self.data.items.len >= max_event_bytes) return error.EventTooLarge;
            try self.line.append(gpa, b);
        }
    }

    fn endLine(self: *Sse, gpa: Allocator, a: Allocator, out: *std.ArrayList([]const u8)) !void {
        defer self.line.clearRetainingCapacity();
        const l = self.line.items;
        if (l.len == 0) {
            if (self.has_data) try out.append(a, try a.dupe(u8, self.data.items));
            self.data.clearRetainingCapacity();
            self.has_data = false;
            return;
        }
        const field_end = std.mem.indexOfScalar(u8, l, ':') orelse l.len;
        if (!std.mem.eql(u8, l[0..field_end], "data")) return;
        var value = if (field_end < l.len) l[field_end + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (self.has_data) try self.data.append(gpa, '\n');
        try self.data.appendSlice(gpa, value);
        self.has_data = true;
    }
};

/// Bound each read on `stream` (and each write) to `ms`; a stalled server
/// then fails the call instead of hanging the thread.
fn setTimeouts(stream: net.Stream, ms: u32) void {
    if (comptime builtin.os.tag == .windows) return;
    const tv: posix.timeval = .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    posix.setsockopt(stream.socket.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(stream.socket.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// A connection whose response head has been read.
const Conn = struct {
    stream: net.Stream,
    rbuf: [16 * 1024]u8 = undefined,
    reader: net.Stream.Reader = undefined,
    status: u16 = 0,
    chunked: bool = false,
    length: ?usize = null,
    chunk_left: usize = 0,
    done: bool = false,

    fn r(self: *Conn) *std.Io.Reader {
        return &self.reader.interface;
    }

    /// Next body bytes (any amount), null at the end of the body.
    fn next(self: *Conn) !?[]const u8 {
        if (self.done) return null;
        const rd = self.r();
        if (self.chunked) {
            if (self.chunk_left == 0) {
                const size_line = std.mem.trim(u8, (try rd.takeDelimiter('\n')) orelse return null, " \r");
                if (size_line.len == 0) return self.next();
                const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
                self.chunk_left = try std.fmt.parseInt(usize, size_line[0..semi], 16);
                if (self.chunk_left == 0) {
                    self.done = true;
                    return null;
                }
            }
            const avail = try rd.peekGreedy(1);
            const n = @min(avail.len, self.chunk_left);
            const out = avail[0..n];
            rd.toss(n);
            self.chunk_left -= n;
            if (self.chunk_left == 0) _ = rd.takeDelimiter('\n') catch {};
            return out;
        }
        if (self.length) |*left| {
            if (left.* == 0) {
                self.done = true;
                return null;
            }
            const avail = try rd.peekGreedy(1);
            const n = @min(avail.len, left.*);
            rd.toss(n);
            left.* -= n;
            return avail[0..n];
        }
        const avail = rd.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => {
                self.done = true;
                return null;
            },
            else => return err,
        };
        rd.toss(avail.len);
        return avail;
    }

    fn close(self: *Conn, io: Io) void {
        self.stream.close(io);
    }
};

/// Connect and send a request, then read the response head. `timeout_ms`
/// bounds every read and write (null: the event stream, which lives for the
/// whole run).
fn open(s: Server, gpa: Allocator, method: []const u8, path: []const u8, body: ?[]const u8, accept: []const u8, timeout_ms: ?u32) !*Conn {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", s.port);
    // A loopback connect is answered at once (accepted or refused); std's
    // threaded Io has no connect timeout yet, so reads and writes carry it.
    const stream = try addr.connect(s.io, .{ .mode = .stream });
    if (timeout_ms) |ms| setTimeouts(stream, ms);
    const c = try gpa.create(Conn);
    errdefer gpa.destroy(c);
    c.* = .{ .stream = stream };
    errdefer stream.close(s.io);
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(s.io, &wbuf);
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?";
    try w.interface.print("{s} {s}{s}directory={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: {s}\r\nx-opencode-directory: {s}\r\nAccept: {s}\r\nConnection: close\r\n", .{ method, path, sep, s.dir, s.port, s.auth, s.dir, accept });
    if (body) |b| {
        try w.interface.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{b.len});
        try w.interface.writeAll(b);
    } else if (eq(method, "POST")) {
        try w.interface.writeAll("Content-Length: 0\r\n\r\n");
    } else try w.interface.writeAll("\r\n");
    try w.interface.flush();
    c.reader = stream.reader(s.io, &c.rbuf);
    const rd = c.r();
    const status_line = (try headerLine(rd)) orelse return error.EndOfStream;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next();
    c.status = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
    while (try headerLine(rd)) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.findIgnoreCase(value, "chunked") != null) c.chunked = true;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) c.length = std.fmt.parseInt(usize, value, 10) catch null;
    }
    if (c.status == 204 or c.status == 304) c.done = true;
    return c;
}

/// One request bounded by `call_timeout_ms`; the whole response body in `a`.
pub fn request(s: Server, a: Allocator, gpa: Allocator, method: []const u8, path: []const u8, body: ?[]const u8) !Response {
    return requestWithin(s, a, gpa, method, path, body, call_timeout_ms);
}

pub fn requestWithin(s: Server, a: Allocator, gpa: Allocator, method: []const u8, path: []const u8, body: ?[]const u8, timeout_ms: u32) !Response {
    const c = try open(s, gpa, method, path, body, "application/json", timeout_ms);
    defer {
        c.close(s.io);
        gpa.destroy(c);
    }
    var out: std.ArrayList(u8) = .empty;
    while (try c.next()) |chunk| {
        if (out.items.len + chunk.len > max_body_bytes) return error.ResponseTooLarge;
        try out.appendSlice(a, chunk);
    }
    return .{ .status = c.status, .body = out.items };
}

fn httpError(a: Allocator, method: []const u8, path: []const u8, resp: Response) ![]u8 {
    const body = if (resp.body.len > 300) try std.fmt.allocPrint(a, "{s}…", .{resp.body[0..300]}) else resp.body;
    if (resp.status >= 500) return std.fmt.allocPrint(a, "opencode {s} {s}: {d} {s} (server-side fault; the body's ref keys the cause in ~/.local/share/opencode/log/opencode.log)", .{ method, path, resp.status, body });
    return std.fmt.allocPrint(a, "opencode {s} {s}: {d} {s}", .{ method, path, resp.status, body });
}

// ---------------------------------------------------------------------------
// Bus events (`handle_bus_event`, 1.x shapes)
// ---------------------------------------------------------------------------

/// `oc_tool_call`.
pub fn toolCall(a: Allocator, name: []const u8, input: json.Value) ![]u8 {
    const s = struct {
        fn f(v: json.Value, keys: []const []const u8) []const u8 {
            for (keys) |k| if (getStr(v, k)) |x| return x;
            return "";
        }
    }.f;
    const call: Call = if (eq(name, "bash"))
        .{ .exec = s(input, &.{"command"}) }
    else if (eq(name, "read"))
        .{ .read_file = s(input, &.{ "filePath", "file_path", "path" }) }
    else if (eq(name, "write"))
        .{ .write_file = s(input, &.{ "filePath", "file_path", "path" }) }
    else if (eq(name, "edit"))
        .{ .edit_file = s(input, &.{ "filePath", "file_path", "path" }) }
    else if (eq(name, "patch"))
        .{ .apply_patch = getStr(input, "filePath") orelse getStr(input, "path") }
    else if (eq(name, "grep"))
        .{ .search = .{ .pattern = s(input, &.{"pattern"}), .path = getStr(input, "path") orelse getStr(input, "include") } }
    else if (eq(name, "glob"))
        .{ .glob = s(input, &.{"pattern"}) }
    else if (eq(name, "webfetch"))
        .{ .web_fetch = s(input, &.{"url"}) }
    else if (eq(name, "websearch"))
        .{ .web_search = s(input, &.{"query"}) }
    else if (eq(name, "todowrite")) blk: {
        var items: std.ArrayList(Call.TodoItem) = .empty;
        if (get(input, "todos")) |ts| if (ts == .array) for (ts.array.items) |x| {
            try items.append(a, .{ .text = getStr(x, "content") orelse "", .done = eq(getStr(x, "status") orelse "", "completed") });
        };
        break :blk .{ .todo = items.items };
    } else if (eq(name, "task") or eq(name, "subagent")) blk: {
        const d = getStr(input, "description") orelse "";
        break :blk .{ .unknown = .{ .name = if (d.len > 0) try std.fmt.allocPrint(a, "Agent: {s}", .{d}) else "Agent", .input = input } };
    } else .{ .unknown = .{ .name = name } };
    return call.toJson(a);
}

/// Per-turn bus state for the main session.
pub const Feed = struct {
    gpa: Allocator,
    session_id: []const u8,
    /// message id → is assistant.
    roles: std.StringHashMapUnmanaged(bool) = .empty,
    /// part id → (kind, emitted bytes).
    parts: std.StringHashMapUnmanaged(struct { reasoning: bool, emitted: usize }) = .empty,
    tools_called: std.StringHashMapUnmanaged(void) = .empty,
    held: std.ArrayList([]const u8) = .empty,
    idle_ready: bool = false,
    saw_content: bool = false,
    err: ?[]const u8 = null,
    settled: bool = false,
    /// A permission or question the caller must open.
    ask: ?json.Value = null,
    ask_kind: enum { permission, question } = .permission,
    /// The idle needs a status poll before it settles.
    poll: bool = false,

    pub fn deinit(self: *Feed) void {
        var it = self.roles.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.roles.deinit(self.gpa);
        var pit = self.parts.keyIterator();
        while (pit.next()) |k| self.gpa.free(k.*);
        self.parts.deinit(self.gpa);
        var tit = self.tools_called.keyIterator();
        while (tit.next()) |k| self.gpa.free(k.*);
        self.tools_called.deinit(self.gpa);
        for (self.held.items) |h| self.gpa.free(h);
        self.held.deinit(self.gpa);
        if (self.err) |e| self.gpa.free(e);
    }

    fn sessionOf(props: json.Value) ?[]const u8 {
        if (getStr(props, "sessionID")) |s| return s;
        if (get(props, "info")) |i| if (getStr(i, "sessionID") orelse getStr(i, "id")) |s| return s;
        if (get(props, "part")) |p| if (getStr(p, "sessionID")) |s| return s;
        return null;
    }

    fn textPart(self: *Feed, a: Allocator, part: json.Value, out: *std.ArrayList(Event)) !void {
        const id = getStr(part, "id") orelse return;
        const kind = getStr(part, "type") orelse "";
        const reasoning = eq(kind, "reasoning");
        const msg = getStr(part, "messageID") orelse "";
        const role = self.roles.get(msg);
        if (role == null) {
            try self.held.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{f}", .{json.fmt(part, .{})}));
            return;
        }
        if (role.? == false) return;
        const text = getStr(part, "text") orelse "";
        const gop = try self.parts.getOrPut(self.gpa, id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, id);
            gop.value_ptr.* = .{ .reasoning = reasoning, .emitted = 0 };
        }
        if (text.len > gop.value_ptr.emitted) {
            const suffix = text[gop.value_ptr.emitted..];
            gop.value_ptr.emitted = text.len;
            self.saw_content = true;
            try out.append(a, if (reasoning) .{ .reasoning = suffix } else .{ .text = suffix });
        }
    }

    fn toolPart(self: *Feed, a: Allocator, part: json.Value, out: *std.ArrayList(Event)) !void {
        const name = getStr(part, "tool") orelse "";
        const id = (if (eq(name, "task") or eq(name, "subagent")) getStr(part, "id") else getStr(part, "callID")) orelse getStr(part, "id") orelse return;
        const st = get(part, "state") orelse json.Value{ .null = {} };
        const status = getStr(st, "status") orelse "";
        const finished = eq(status, "completed") or eq(status, "error");
        const input = get(st, "input");
        const has_input = if (input) |i| (i == .object and i.object.count() > 0) else false;
        if (has_input or finished) {
            if (!self.tools_called.contains(id) or has_input) {
                if (!self.tools_called.contains(id)) try self.tools_called.put(self.gpa, try self.gpa.dupe(u8, id), {});
                try out.append(a, .{ .tool_call = .{ .id = id, .call = try toolCall(a, name, input orelse json.Value{ .null = {} }) } });
            }
        }
        if (finished) {
            self.saw_content = true;
            try out.append(a, .{ .tool_result = .{ .id = id, .is_error = eq(status, "error") } });
        }
    }

    pub fn apply(self: *Feed, a: Allocator, envelope: json.Value, out: *std.ArrayList(Event)) !void {
        const ev = get(envelope, "payload") orelse envelope;
        const ty = getStr(ev, "type") orelse return;
        const props = get(ev, "properties") orelse json.Value{ .null = {} };
        if (eq(ty, "sync")) return;
        const sid = sessionOf(props) orelse "";
        if (!eq(sid, self.session_id)) return;
        if (eq(ty, "message.updated")) {
            const info = get(props, "info") orelse return;
            const id = getStr(info, "id") orelse return;
            const assistant = eq(getStr(info, "role") orelse "", "assistant");
            if (!self.roles.contains(id)) try self.roles.put(self.gpa, try self.gpa.dupe(u8, id), assistant);
            // Parts that arrived before their message's role.
            var i: usize = 0;
            while (i < self.held.items.len) {
                const raw = self.held.items[i];
                const part = json.parseFromSliceLeaky(json.Value, a, try a.dupe(u8, raw), .{}) catch {
                    i += 1;
                    continue;
                };
                if (eq(getStr(part, "messageID") orelse "", id)) {
                    self.gpa.free(self.held.orderedRemove(i));
                    try self.textPart(a, part, out);
                } else i += 1;
            }
        } else if (eq(ty, "message.part.updated")) {
            const part = get(props, "part") orelse return;
            const kind = getStr(part, "type") orelse "";
            if (eq(kind, "text") or eq(kind, "reasoning")) try self.textPart(a, part, out) else if (eq(kind, "tool")) try self.toolPart(a, part, out);
        } else if (eq(ty, "message.part.delta")) {
            if (!eq(getStr(props, "field") orelse "text", "text")) return;
            const pid = getStr(props, "partID") orelse return;
            const delta = getStr(props, "delta") orelse return;
            const p = self.parts.getPtr(pid) orelse return;
            p.emitted += delta.len;
            self.saw_content = true;
            try out.append(a, if (p.reasoning) .{ .reasoning = delta } else .{ .text = delta });
        } else if (eq(ty, "session.status")) {
            const st = get(props, "status") orelse return;
            const t = getStr(st, "type") orelse "";
            if (eq(t, "busy")) self.idle_ready = true else if (eq(t, "idle")) self.onIdle();
        } else if (eq(ty, "session.idle")) {
            self.onIdle();
        } else if (eq(ty, "session.error")) {
            const e = get(props, "error") orelse json.Value{ .null = {} };
            const name = getStr(e, "name") orelse "";
            if (eq(name, "MessageAbortedError")) return;
            const msg = (if (get(e, "data")) |d| getStr(d, "message") else null) orelse (if (name.len > 0) name else "opencode reported an error");
            if (self.err == null) {
                self.err = try self.gpa.dupe(u8, msg);
                try out.append(a, .{ .err = msg });
            }
        } else if (eq(ty, "permission.asked") or eq(ty, "permission.updated")) {
            self.ask = props;
            self.ask_kind = .permission;
        } else if (eq(ty, "question.asked")) {
            self.ask = props;
            self.ask_kind = .question;
        }
    }

    fn onIdle(self: *Feed) void {
        if (self.idle_ready or self.saw_content or self.err != null) self.settled = true else self.poll = true;
    }
};

// ---------------------------------------------------------------------------
// The turn
// ---------------------------------------------------------------------------

const State = struct {
    server: Server,
    session_id: []const u8 = "",
};

fn state(t: *Turn) ?*State {
    return @ptrCast(@alignCast(t.state orelse return null));
}

fn serverOf(t: *Turn) ?State {
    t.mu.lockUncancelable(t.io);
    defer t.mu.unlock(t.io);
    return if (state(t)) |s| s.* else null;
}

const kind_permission: u8 = 1;
const kind_question: u8 = 2;

/// POSTs to the server made off the calling thread: answers and interrupts
/// arrive on RPC threads holding the engine lock, and a call may take up to
/// `call_timeout_ms`. The job holds a turn reference until it's done.
const Job = struct {
    t: *Turn,
    server: Server,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    body: ?[]const u8,
    /// Tried when `path` doesn't answer 2xx (the legacy permission route).
    fallback_path: ?[]const u8 = null,
    fallback_body: ?[]const u8 = null,
    /// Nothing answered 2xx (an abort): end the server.
    kill_on_fail: bool = false,

    fn post(self: *Job, path: []const u8, body: ?[]const u8) bool {
        const r = request(self.server, self.arena.allocator(), self.t.gpa, "POST", path, body) catch return false;
        return r.status >= 200 and r.status < 300;
    }

    fn runIt(self: *Job) void {
        var ok = self.post(self.path, self.body);
        if (!ok) if (self.fallback_path) |fp| {
            ok = self.post(fp, self.fallback_body);
        };
        if (!ok and self.kill_on_fail) {
            // Nothing will settle the turn: end the server now.
            self.t.mu.lockUncancelable(self.t.io);
            defer self.t.mu.unlock(self.t.io);
            if (self.t.proc) |p| p.escalate(0, agent_turn.kill_grace_ms);
        }
        const t = self.t;
        self.arena.deinit();
        t.gpa.destroy(self);
        t.release();
        _ = agent_turn.active_threads.fetchSub(1, .acq_rel);
    }
};

/// Start a `Job` (built by `fill` in the job's arena); without a thread it
/// runs in place.
fn postAsync(t: *Turn, server: Server, fill: anytype) void {
    const job = t.gpa.create(Job) catch return;
    job.* = .{ .t = t, .server = server, .arena = .init(t.gpa), .path = "", .body = null };
    fill.apply(job) catch {
        job.arena.deinit();
        t.gpa.destroy(job);
        return;
    };
    t.retain();
    // Counted with the turn threads, so shutdown and tests wait for it.
    _ = agent_turn.active_threads.fetchAdd(1, .acq_rel);
    const th = std.Thread.spawn(.{}, Job.runIt, .{job}) catch return job.runIt();
    th.detach();
}

fn answer(t: *Turn, p: *const agent_turn.Pending, answers: ?[]const agent_turn.Answer) void {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = serverOf(t) orelse return;
    const data = json.parseFromSliceLeaky(json.Value, a, p.data, .{}) catch return;
    const id = getStr(data, "id") orelse return;
    switch (p.kind) {
        kind_permission => {
            const reply = if (agent_turn.labelsFor(answers, getStr(data, "qid") orelse "").len > 0 and agent_turn.answeredYes(answers)) "once" else "reject";
            postAsync(t, st.server, struct {
                id: []const u8,
                session_id: []const u8,
                reply: []const u8,
                fn apply(self: @This(), job: *Job) !void {
                    const ja = job.arena.allocator();
                    job.path = try std.fmt.allocPrint(ja, "/permission/{s}/reply", .{self.id});
                    job.body = try std.fmt.allocPrint(ja, "{{\"reply\":\"{s}\"}}", .{self.reply});
                    job.fallback_path = try std.fmt.allocPrint(ja, "/session/{s}/permissions/{s}", .{ self.session_id, self.id });
                    job.fallback_body = try std.fmt.allocPrint(ja, "{{\"response\":\"{s}\"}}", .{self.reply});
                }
            }{ .id = id, .session_id = st.session_id, .reply = reply });
        },
        kind_question => {
            if (answers == null) {
                postAsync(t, st.server, PathBody{ .path = std.fmt.allocPrint(a, "/question/{s}/reject", .{id}) catch return, .body = null });
                return;
            }
            const qs = json.parseFromSliceLeaky([]agent_turn.Question, a, p.questions, .{ .ignore_unknown_fields = true }) catch return;
            var out: std.Io.Writer.Allocating = .init(a);
            out.writer.writeAll("{\"answers\":[") catch return;
            for (qs, 0..) |q, i| {
                if (i > 0) out.writer.writeByte(',') catch return;
                out.writer.print("{f}", .{json.fmt(agent_turn.labelsFor(answers, q.id), .{})}) catch return;
            }
            out.writer.writeAll("]}") catch return;
            postAsync(t, st.server, PathBody{ .path = std.fmt.allocPrint(a, "/question/{s}/reply", .{id}) catch return, .body = out.written() });
        },
        else => {},
    }
}

/// A `postAsync` filler for one POST (copied into the job's arena).
const PathBody = struct {
    path: []const u8,
    body: ?[]const u8,
    kill_on_fail: bool = false,
    fn apply(self: PathBody, job: *Job) !void {
        const ja = job.arena.allocator();
        job.path = try ja.dupe(u8, self.path);
        job.body = if (self.body) |b| try ja.dupe(u8, b) else null;
        job.kill_on_fail = self.kill_on_fail;
    }
};

fn interrupt(t: *Turn) void {
    var buf: [256]u8 = undefined;
    const st = serverOf(t) orelse return;
    if (st.session_id.len == 0) return;
    const path = std.fmt.bufPrint(&buf, "/session/{s}/abort", .{st.session_id}) catch return;
    postAsync(t, st.server, PathBody{ .path = path, .body = null, .kill_on_fail = true });
}

fn freePort(io: Io) !u16 {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = addr.listen(io, .{ .reuse_address = true }) catch return error.NoFreePort;
    defer srv.deinit(io);
    return srv.socket.address.ip4.port;
}

fn openAsk(t: *Turn, a: Allocator, feed: *Feed) !void {
    const props = feed.ask orelse return;
    feed.ask = null;
    const id = getStr(props, "id") orelse return;
    switch (feed.ask_kind) {
        .permission => {
            const qid = try std.fmt.allocPrint(a, "permission:{s}", .{id});
            const data = try std.fmt.allocPrint(a, "{{\"id\":{f},\"qid\":{f}}}", .{ json.fmt(id, .{}), json.fmt(qid, .{}) });
            if (t.req.auto_approve) {
                const p = agent_turn.Pending{ .request_id = @constCast("auto"), .kind = kind_permission, .data = @constCast(data), .questions = @constCast("[]") };
                const yes = [_]agent_turn.Answer{.{ .questionId = qid, .labels = &.{"Yes"} }};
                answer(t, &p, &yes);
                return;
            }
            const q = [_]agent_turn.Question{.{ .id = qid, .header = "Permission", .question = try std.fmt.allocPrint(a, "Allow this OpenCode request once? {f}", .{json.fmt(props, .{})}), .options = &.{ "No", "Yes" } }};
            try t.ask(kind_permission, data, &q);
        },
        .question => {
            var qs: std.ArrayList(agent_turn.Question) = .empty;
            if (get(props, "questions")) |arr| if (arr == .array) for (arr.array.items, 0..) |q, i| {
                var opts: std.ArrayList([]const u8) = .empty;
                if (get(q, "options")) |os| if (os == .array) for (os.array.items) |o| {
                    if (o == .string) try opts.append(a, o.string) else if (getStr(o, "label")) |l| try opts.append(a, l);
                };
                try qs.append(a, .{ .id = try std.fmt.allocPrint(a, "q{d}", .{i}), .header = getStr(q, "header") orelse "Question", .question = getStr(q, "question") orelse "", .options = opts.items, .multiSelect = agent_turn.getBool(q, "multiple") orelse false });
            };
            try t.ask(kind_question, try std.fmt.allocPrint(a, "{{\"id\":{f}}}", .{json.fmt(id, .{})}), qs.items);
        },
    }
}

/// `prompt_async` body (`prompt_body`), with the reasoning `variant` when
/// the model advertises one.
pub fn promptBody(a: Allocator, prompt: []const u8, model: ?[]const u8, variant: ?[]const u8) ![]u8 {
    return promptBodyWith(a, prompt, model, variant, &.{});
}

/// `mime_for`.
fn mimeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_][2][]const u8{ .{ ".png", "image/png" }, .{ ".jpg", "image/jpeg" }, .{ ".jpeg", "image/jpeg" }, .{ ".gif", "image/gif" }, .{ ".webp", "image/webp" }, .{ ".pdf", "application/pdf" } };
    for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return "application/octet-stream";
}

/// `prompt_body`: the text part, then one `file` part per attachment.
pub fn promptBodyWith(a: Allocator, prompt: []const u8, model: ?[]const u8, variant: ?[]const u8, attachments: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{{\"parts\":[{{\"type\":\"text\",\"text\":{f}}}", .{json.fmt(prompt, .{})});
    for (attachments) |path| {
        const url = try std.fmt.allocPrint(a, "file://{s}", .{path});
        try w.print(",{{\"type\":\"file\",\"mime\":{f},\"filename\":{f},\"url\":{f}}}", .{ json.fmt(mimeFor(path), .{}), json.fmt(std.fs.path.basename(path), .{}), json.fmt(url, .{}) });
    }
    try w.writeByte(']');
    if (model) |m| if (std.mem.indexOfScalar(u8, m, '/')) |slash| {
        try w.print(",\"model\":{{\"providerID\":{f},\"modelID\":{f}}}", .{ json.fmt(m[0..slash], .{}), json.fmt(m[slash + 1 ..], .{}) });
    };
    if (variant) |v| try w.print(",\"variant\":{f}", .{json.fmt(v, .{})});
    try w.writeByte('}');
    return out.written();
}

/// `variant_candidates`: the variant ids a reasoning level may use, best first.
pub fn variantCandidates(reasoning: ?[]const u8) []const []const u8 {
    const r = reasoning orelse return &.{};
    if (eq(r, "none")) return &.{"none"};
    if (eq(r, "minimal")) return &.{ "minimal", "low" };
    if (eq(r, "low")) return &.{ "low", "minimal" };
    if (eq(r, "medium")) return &.{"medium"};
    if (eq(r, "high")) return &.{"high"};
    if (eq(r, "xhigh")) return &.{ "xhigh", "x-high", "high" };
    if (eq(r, "max")) return &.{ "max", "xhigh", "high" };
    if (eq(r, "ultra") or eq(r, "ultracode") or eq(r, "ultrathink")) return &.{ "ultra", "max", "high" };
    return &.{};
}

/// `pick_variant`: the requested effort as a variant the model advertises
/// in the server's `/provider` catalog (`{all: [{id, models: {id: {variants}}}]}`).
pub fn pickVariant(catalog: json.Value, model: ?[]const u8, reasoning: ?[]const u8) ?[]const u8 {
    const m = model orelse return null;
    const slash = std.mem.indexOfScalar(u8, m, '/') orelse return null;
    const candidates = variantCandidates(reasoning);
    if (candidates.len == 0) return null;
    const all = get(catalog, "all") orelse return null;
    if (all != .array) return null;
    for (all.array.items) |p| {
        if (!eq(getStr(p, "id") orelse "", m[0..slash])) continue;
        const models = get(p, "models") orelse return null;
        const info = get(models, m[slash + 1 ..]) orelse return null;
        const variants = get(info, "variants") orelse return null;
        if (variants != .object) return null;
        for (candidates) |c| if (variants.object.get(c) != null) return c;
        return null;
    }
    return null;
}

fn run(t: *Turn) !void {
    const a = t.arena.allocator();
    const io = t.io;
    const exe = try t.resolveExe("opencode", "OPENCODE_EXECUTABLE", &extra_paths, install_hint);
    const port = freePort(io) catch return t.fail("harness protocol error: no free localhost port for opencode serve", .{});
    var pw: [16]u8 = undefined;
    io.random(&pw);
    const password = try std.fmt.allocPrint(a, "{x}", .{pw});
    var env = try t.childEnv(exe);
    defer env.deinit();
    try env.put("OPENCODE_SERVER_PASSWORD", password);
    try env.put("OPENCODE_CLIENT", "harness");
    const port_s = try std.fmt.allocPrint(a, "{d}", .{port});
    const proc = try t.spawn(&.{ exe, "serve", "--port", port_s, "--hostname", "127.0.0.1" }, &env, .{ .stdin = false, .stdout = false });

    const cred = try std.fmt.allocPrint(a, "opencode:{s}", .{password});
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(cred.len));
    var st: State = .{ .server = .{ .io = io, .port = port, .auth = try std.fmt.allocPrint(a, "Basic {s}", .{std.base64.standard.Encoder.encode(b64, cred)}), .dir = try pctEncode(a, t.req.cwd) } };
    t.state = &st;
    defer {
        t.mu.lockUncancelable(io);
        t.state = null;
        t.mu.unlock(io);
    }
    const srv = st.server;

    // Readiness: newest API first; a 2.x server is refused.
    const startup_s: u64 = if (t.req.env.get("HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS")) |v| std.fmt.parseInt(u64, v, 10) catch 300 else 300;
    var waited_ms: u64 = 0;
    var ready = false;
    while (!ready) : (waited_ms += 150) {
        if (t.interrupted.load(.acquire)) return t.fail("interrupted", .{});
        if (proc.stderr_closed.load(.acquire)) return t.fail("{s}", .{t.crash(proc)});
        if (waited_ms > startup_s * 1000) return t.fail("harness protocol error: opencode serve did not become healthy within {d}s (raise HARNESS_OPENCODE_STARTUP_TIMEOUT_SECS if this machine's plugin load is genuinely slow)", .{startup_s});
        for ([_][]const u8{ "/api/info", "/api/status", "/api/health", "/global/health" }) |path| {
            var probe_arena = std.heap.ArenaAllocator.init(t.gpa);
            defer probe_arena.deinit();
            const resp = requestWithin(srv, probe_arena.allocator(), t.gpa, "GET", path, null, probe_timeout_ms) catch continue;
            if (resp.status == 401 or resp.status == 403) return t.fail("harness protocol error: opencode authentication rejected at {s}: {d}", .{ path, resp.status });
            if (resp.status < 200 or resp.status >= 300) continue;
            const v = json.parseFromSliceLeaky(json.Value, probe_arena.allocator(), resp.body, .{}) catch continue;
            const version = getStr(v, "version") orelse (if (get(v, "data")) |d| getStr(d, "version") else null) orelse continue;
            if (std.mem.trim(u8, version, " ").len == 0) continue;
            if (!eq(path, "/global/health")) return t.fail("OpenCode {s} serves the 2.x API, which this build of the engine does not support yet.", .{version});
            ready = true;
            break;
        }
        if (!ready) Io.sleep(io, .fromMilliseconds(150), .awake) catch {};
    }

    // Session: reuse the stored one when the server still has it.
    var session_id: ?[]const u8 = null;
    if (t.req.resume_id) |r| {
        const resp = request(srv, a, t.gpa, "GET", try std.fmt.allocPrint(a, "/session/{s}", .{r}), null) catch null;
        if (resp) |rr| if (rr.status >= 200 and rr.status < 300) {
            session_id = r;
        };
    }
    if (session_id == null) {
        var resp = try request(srv, a, t.gpa, "POST", "/session", "{}");
        if (resp.status >= 500) {
            Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
            resp = try request(srv, a, t.gpa, "POST", "/session", "{}");
        }
        if (resp.status < 200 or resp.status >= 300) return t.fail("harness protocol error: {s}", .{try httpError(a, "POST", "/session", resp)});
        const v = json.parseFromSliceLeaky(json.Value, a, resp.body, .{}) catch return t.fail("harness protocol error: opencode session create returned no id", .{});
        session_id = getStr(v, "id") orelse return t.fail("harness protocol error: opencode session create returned no id", .{});
    }
    const sid = session_id.?;
    {
        t.mu.lockUncancelable(io);
        defer t.mu.unlock(io);
        st.session_id = sid;
    }
    t.emit(.{ .session_started = sid });

    // The bus, then the prompt.
    const bus = open(srv, t.gpa, "GET", "/global/event", null, "text/event-stream", null) catch |err| return t.fail("harness protocol error: opencode GET /global/event: {t}", .{err});
    defer {
        bus.close(io);
        t.gpa.destroy(bus);
    }
    if (bus.status < 200 or bus.status >= 300) return t.fail("harness protocol error: opencode GET /global/event: {d}", .{bus.status});
    const prompt_path = try std.fmt.allocPrint(a, "/session/{s}/prompt_async", .{sid});
    // Variants are per model: the requested effort rides only a model that has it.
    const variant: ?[]const u8 = if (variantCandidates(t.req.reasoning).len == 0) null else blk: {
        const resp = request(srv, a, t.gpa, "GET", "/provider", null) catch break :blk null;
        if (resp.status < 200 or resp.status >= 300) break :blk null;
        const catalog = json.parseFromSliceLeaky(json.Value, a, resp.body, .{}) catch break :blk null;
        break :blk pickVariant(catalog, t.req.model, t.req.reasoning);
    };
    const presp = try request(srv, a, t.gpa, "POST", prompt_path, try promptBodyWith(a, t.req.prompt, t.req.model, variant, t.req.attachments));
    if (presp.status < 200 or presp.status >= 300) {
        const msg = try httpError(a, "POST", prompt_path, presp);
        t.emit(.{ .err = msg });
        t.emit(.{ .done = .{ .status = .errored, .err = msg, .session_id = sid } });
        return;
    }

    var feed: Feed = .{ .gpa = t.gpa, .session_id = sid };
    defer feed.deinit();
    var sse: Sse = .{};
    defer sse.deinit(t.gpa);
    var chunk_arena = std.heap.ArenaAllocator.init(t.gpa);
    defer chunk_arena.deinit();
    var line_arena = std.heap.ArenaAllocator.init(t.gpa);
    defer line_arena.deinit();
    while (!feed.settled) {
        const chunk = (bus.next() catch null) orelse break;
        defer _ = chunk_arena.reset(.retain_capacity);
        var frames: std.ArrayList([]const u8) = .empty;
        try sse.feed(t.gpa, chunk_arena.allocator(), chunk, &frames);
        for (frames.items) |data| {
            defer _ = line_arena.reset(.retain_capacity);
            const la = line_arena.allocator();
            if (data.len == 0) continue;
            const v = json.parseFromSliceLeaky(json.Value, la, data, .{}) catch continue;
            var events: std.ArrayList(Event) = .empty;
            try feed.apply(la, v, &events);
            for (events.items) |ev| t.emit(ev);
            try openAsk(t, la, &feed);
            if (feed.poll) {
                feed.poll = false;
                const resp = request(srv, la, t.gpa, "GET", "/session/status", null) catch null;
                const running = blk: {
                    const r = resp orelse break :blk true;
                    const m = json.parseFromSliceLeaky(json.Value, la, r.body, .{}) catch break :blk true;
                    const s = get(m, sid) orelse break :blk false;
                    break :blk !eq(getStr(s, "type") orelse "", "idle");
                };
                if (!running) feed.settled = true;
            }
            if (feed.settled) break;
        }
    }
    if (feed.settled) {
        const interrupted = t.interrupted.load(.acquire);
        const errored = !interrupted and feed.err != null and !feed.saw_content;
        t.emit(.message_completed);
        t.emit(.{ .done = .{ .status = if (interrupted) .interrupted else if (errored) .errored else .completed, .err = if (errored) try a.dupe(u8, feed.err.?) else null, .session_id = sid } });
    } else if (t.interrupted.load(.acquire)) {
        t.emit(.{ .done = .{ .status = .interrupted, .session_id = sid } });
    } else {
        const msg = t.crash(proc);
        t.emit(.{ .err = msg });
        t.emit(.{ .done = .{ .status = .errored, .err = msg, .session_id = sid } });
    }
    proc.escalate(0, agent_turn.kill_grace_ms);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "opencode: prompt body, percent-encoding and tool calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("{\"parts\":[{\"type\":\"text\",\"text\":\"hi\"}],\"model\":{\"providerID\":\"anthropic\",\"modelID\":\"claude-opus-5-5\"}}", try promptBody(a, "hi", "anthropic/claude-opus-5-5", null));
    try testing.expectEqualStrings("{\"parts\":[{\"type\":\"text\",\"text\":\"hi\"}]}", try promptBody(a, "hi", null, null));
    try testing.expectEqualStrings("{\"parts\":[{\"type\":\"text\",\"text\":\"hi\"}],\"model\":{\"providerID\":\"p\",\"modelID\":\"m\"},\"variant\":\"high\"}", try promptBody(a, "hi", "p/m", "high"));
    try testing.expectEqualStrings("{\"parts\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"file\",\"mime\":\"image/png\",\"filename\":\"a b.PNG\",\"url\":\"file:///w/a b.PNG\"}]}", try promptBodyWith(a, "hi", null, null, &.{"/w/a b.PNG"}));
    const catalog = try json.parseFromSliceLeaky(json.Value, a, "{\"all\":[{\"id\":\"p\",\"models\":{\"m\":{\"variants\":{\"low\":{},\"high\":{}}}}}]}", .{});
    try testing.expectEqualStrings("high", pickVariant(catalog, "p/m", "xhigh").?);
    try testing.expectEqualStrings("low", pickVariant(catalog, "p/m", "minimal").?);
    try testing.expect(pickVariant(catalog, "p/m", "medium") == null);
    try testing.expect(pickVariant(catalog, "p/other", "high") == null);
    try testing.expectEqualStrings("/w/my%20repo/a%2Bb", try pctEncode(a, "/w/my repo/a+b"));
    const input = try json.parseFromSliceLeaky(json.Value, a, "{\"filePath\":\"/w/a.ts\",\"oldString\":\"x\"}", .{});
    try testing.expectEqualStrings("{\"kind\":\"editFile\",\"path\":\"/w/a.ts\"}", try toolCall(a, "edit", input));
}

test "opencode: SSE events split on any line end and join multi-line data with a newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sse: Sse = .{};
    defer sse.deinit(testing.allocator);
    var out: std.ArrayList([]const u8) = .empty;
    // Split mid-terminator and mid-field, as a socket may deliver it.
    const pieces = [_][]const u8{ "data: {\"a\":1}\r", "\n\r\ndata: line1\ndata:line2\n\n: keepalive\n\nevent: x\nda", "ta: last\r\r" };
    for (pieces) |p| try sse.feed(testing.allocator, a, p, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("{\"a\":1}", out.items[0]);
    try testing.expectEqualStrings("line1\nline2", out.items[1]);
    try testing.expectEqualStrings("last", out.items[2]);
}

test "opencode: the bus folds parts by role, deltas, tools, errors and idle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feed: Feed = .{ .gpa = testing.allocator, .session_id = "s1" };
    defer feed.deinit();
    var out: std.ArrayList(Event) = .empty;
    const frames = [_][]const u8{
        "{\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"p1\",\"sessionID\":\"s1\",\"messageID\":\"m1\",\"type\":\"text\",\"text\":\"Hel\"}}}}",
        "{\"payload\":{\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"m1\",\"sessionID\":\"s1\",\"role\":\"assistant\"}}}}",
        "{\"payload\":{\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"s1\",\"partID\":\"p1\",\"field\":\"text\",\"delta\":\"lo\"}}}",
        "{\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"p1\",\"sessionID\":\"s1\",\"messageID\":\"m1\",\"type\":\"text\",\"text\":\"Hello!\"}}}}",
        "{\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"p2\",\"sessionID\":\"other\",\"messageID\":\"m9\",\"type\":\"text\",\"text\":\"nope\"}}}}",
        "{\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"p3\",\"callID\":\"c1\",\"sessionID\":\"s1\",\"messageID\":\"m1\",\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"error\",\"input\":{\"command\":\"make\"}}}}}}",
        "{\"payload\":{\"type\":\"session.error\",\"properties\":{\"sessionID\":\"s1\",\"error\":{\"name\":\"ProviderError\",\"data\":{\"message\":\"bad key\"}}}}}",
        "{\"payload\":{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"s1\"}}}",
    };
    for (frames) |f| try feed.apply(a, try json.parseFromSliceLeaky(json.Value, a, f, .{}), &out);
    try testing.expectEqualStrings("Hel", out.items[0].text);
    try testing.expectEqualStrings("lo", out.items[1].text);
    try testing.expectEqualStrings("!", out.items[2].text);
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"command\":\"make\"}", out.items[3].tool_call.call);
    try testing.expect(out.items[4].tool_result.is_error);
    try testing.expectEqualStrings("bad key", out.items[5].err);
    try testing.expect(feed.settled);
}

const testkit = @import("agent_testkit.zig");

const mock_serve =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\printf '%s\n' "$@" > "$d/argv.txt"
    \\env > "$d/env.txt"
    \\exec sleep 60
    \\
;

/// A 1.x opencode server in-process: the mock CLI only records its port.
const MockServer = struct {
    io: Io,
    server: net.Server,
    mu: Io.Mutex = .init,
    bus: ?net.Stream = null,
    log: std.ArrayList(u8) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Set when `acceptLoop` has returned.
    exited: Io.Event = .unset,

    fn push(self: *MockServer, event: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const s = self.bus orelse return;
        var buf: [4096]u8 = undefined;
        var w = s.writer(self.io, &buf);
        const body = std.fmt.allocPrint(testing.allocator, "data: {{\"directory\":\"/w\",\"payload\":{s}}}\r\n\r\n", .{event}) catch return;
        defer testing.allocator.free(body);
        w.interface.print("{x}\r\n{s}\r\n", .{ body.len, body }) catch return;
        w.interface.flush() catch return;
    }

    fn acceptLoop(self: *MockServer) void {
        defer self.exited.set(self.io);
        while (!self.stop.load(.acquire)) {
            const conn = self.server.accept(self.io) catch return;
            const th = std.Thread.spawn(.{}, serve, .{ self, conn }) catch {
                conn.close(self.io);
                continue;
            };
            th.detach();
        }
    }

    fn serve(self: *MockServer, conn: net.Stream) void {
        var rbuf: [8192]u8 = undefined;
        var r = conn.reader(self.io, &rbuf);
        const line = (r.interface.takeDelimiter('\n') catch null) orelse return conn.close(self.io);
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const method = it.next() orelse "";
        const target = it.next() orelse "";
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        var len: usize = 0;
        while (r.interface.takeDelimiter('\n') catch null) |h| {
            const hl = std.mem.trimEnd(u8, h, "\r");
            if (hl.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(hl, "content-length:")) len = std.fmt.parseInt(usize, std.mem.trim(u8, hl["content-length:".len..], " "), 10) catch 0;
        }
        const body = if (len > 0) (r.interface.take(len) catch "") else "";
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.log.print(testing.allocator, "{s} {s} {s}\n", .{ method, path, body }) catch {};
        }
        if (eq(path, "/global/event")) {
            var wb: [256]u8 = undefined;
            var w = conn.writer(self.io, &wb);
            w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n") catch return;
            w.interface.flush() catch return;
            self.mu.lockUncancelable(self.io);
            self.bus = conn;
            self.mu.unlock(self.io);
            return;
        }
        var status: []const u8 = "404 Not Found";
        var reply: []const u8 = "{}";
        if (eq(path, "/global/health")) {
            status = "200 OK";
            reply = "{\"healthy\":true,\"version\":\"1.4.0\"}";
        } else if (eq(method, "POST") and eq(path, "/session")) {
            status = "200 OK";
            reply = "{\"id\":\"oc-sess\"}";
        } else if (eq(method, "GET") and eq(path, "/session/oc-sess")) {
            status = "200 OK";
            reply = "{\"id\":\"oc-sess\"}";
        } else if (eq(path, "/session/oc-sess/prompt_async")) {
            status = "204 No Content";
            reply = "";
        } else if (std.mem.startsWith(u8, path, "/permission/") or eq(path, "/session/oc-sess/abort")) {
            status = "200 OK";
            reply = "true";
        }
        var wb: [512]u8 = undefined;
        var w = conn.writer(self.io, &wb);
        w.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, reply.len, reply }) catch {};
        w.interface.flush() catch {};
        conn.close(self.io);
        if (eq(path, "/session/oc-sess/prompt_async")) {
            const prompt_events = [_][]const u8{
                "{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"oc-sess\",\"status\":{\"type\":\"busy\"}}}",
                "{\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"m1\",\"sessionID\":\"oc-sess\",\"role\":\"assistant\"}}}",
                "{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"p1\",\"sessionID\":\"oc-sess\",\"messageID\":\"m1\",\"type\":\"text\",\"text\":\"Hello from OpenCode\"}}}",
                "{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"p2\",\"callID\":\"call-1\",\"sessionID\":\"oc-sess\",\"messageID\":\"m1\",\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"running\",\"input\":{\"command\":\"ls\"}}}}}",
                "{\"type\":\"permission.asked\",\"properties\":{\"id\":\"perm-1\",\"sessionID\":\"oc-sess\",\"permission\":\"bash\"}}",
            };
            for (prompt_events) |e| self.push(e);
        } else if (std.mem.startsWith(u8, path, "/permission/perm-1/reply")) {
            if (std.mem.indexOf(u8, body, "\"once\"") != null) {
                self.push("{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"p2\",\"callID\":\"call-1\",\"sessionID\":\"oc-sess\",\"messageID\":\"m1\",\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"ls\"}}}}}");
                self.push("{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"oc-sess\"}}");
            }
        } else if (eq(path, "/session/oc-sess/abort")) {
            self.push("{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"oc-sess\"}}");
        }
    }

    fn logged(self: *MockServer) []u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return testing.allocator.dupe(u8, self.log.items) catch &.{};
    }
};

fn startMock(rig: *testkit.Rig, srv: *MockServer) !void {
    var waited: u32 = 0;
    const port = while (waited < 5000) : (waited += 10) {
        if (rig.readFile("argv.txt")) |argv| {
            defer testing.allocator.free(argv);
            var lines = std.mem.splitScalar(u8, argv, '\n');
            _ = lines.next();
            _ = lines.next();
            if (lines.next()) |p| if (std.fmt.parseInt(u16, p, 10)) |n| break n else |_| {};
        } else |_| {}
        try Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    } else return error.TestTimeout;
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    srv.* = .{ .io = testing.io, .server = try addr.listen(testing.io, .{ .reuse_address = true }) };
    srv.thread = try std.Thread.spawn(.{}, MockServer.acceptLoop, .{srv});
}

fn stopMock(srv: *MockServer) void {
    srv.stop.store(true, .release);
    // Wake the blocked accept with a connection, again until the loop has
    // returned: one wake-up can be lost, and a join that never returns hangs
    // the whole suite. Past 5 s it is a failure, not a wait.
    var tries: u32 = 0;
    while (!srv.exited.isSet()) : (tries += 1) {
        if (tries >= 50) @panic("opencode mock server did not stop within 5 s");
        if (net.IpAddress.parseIp4("127.0.0.1", srv.server.socket.address.ip4.port)) |addr| {
            if (addr.connect(srv.io, .{ .mode = .stream })) |c| c.close(srv.io) else |_| {}
        } else |_| {}
        srv.exited.waitTimeout(srv.io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
    }
    if (srv.thread) |th| th.join();
    srv.server.deinit(srv.io);
    if (srv.bus) |b| b.close(srv.io);
    srv.log.deinit(testing.allocator);
}

test "opencode: a turn against a mock server streams, asks permission and settles on idle" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const rig = try testkit.Rig.create(.{ .harness = "opencode", .override_var = "OPENCODE_EXECUTABLE", .script = mock_serve });
    defer rig.destroy();
    try rig.run("m-1", "list");
    var srv: MockServer = undefined;
    try startMock(rig, &srv);
    defer stopMock(&srv);
    try rig.waitQuestion(8000);
    try rig.waitFor("Allow this OpenCode request once?", 1000);
    const rid = (try rig.openRequestId()).?;
    defer testing.allocator.free(rid);
    try rig.answerOpen("permission:perm-1", "Yes");
    try rig.waitIdle(8000);
    const doc = try rig.docJson();
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text\":\"Hello from OpenCode\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"call\":{\"kind\":\"exec\",\"command\":\"ls\"},\"resolved\":true,\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"complete\"") != null);
    try testing.expectEqualStrings("oc-sess", rig.chatSessionId().?);
    const log = srv.logged();
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "POST /session {}") != null);
    try testing.expect(std.mem.indexOf(u8, log, "POST /session/oc-sess/prompt_async {\"parts\":[{\"type\":\"text\",\"text\":\"list\"}]}") != null);
    try testing.expect(std.mem.indexOf(u8, log, "POST /permission/perm-1/reply {\"reply\":\"once\"}") != null);
    const argv = try rig.readFile("argv.txt");
    defer testing.allocator.free(argv);
    try testing.expect(std.mem.startsWith(u8, argv, "serve\n--port\n"));
    try testing.expect(std.mem.endsWith(u8, argv, "--hostname\n127.0.0.1\n"));
    const env = try rig.readFile("env.txt");
    defer testing.allocator.free(env);
    try testing.expect(std.mem.indexOf(u8, env, "OPENCODE_CLIENT=harness\n") != null);
    try testing.expect(std.mem.indexOf(u8, env, "OPENCODE_SERVER_PASSWORD=") != null);
}

test "opencode: interrupt posts abort and the entry ends aborted; a missing binary is reported" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    {
        const rig = try testkit.Rig.create(.{ .harness = "opencode", .override_var = "OPENCODE_EXECUTABLE", .script = mock_serve });
        defer rig.destroy();
        try rig.run("m-1", "list");
        var srv: MockServer = undefined;
        try startMock(rig, &srv);
        defer stopMock(&srv);
        try rig.waitQuestion(8000);
        try rig.command("{\"kind\":\"interrupt\"}");
        try rig.waitIdle(8000);
        const doc = try rig.docJson();
        defer testing.allocator.free(doc);
        try testing.expect(std.mem.indexOf(u8, doc, "\"status\":\"aborted\"") != null);
        const log = srv.logged();
        defer testing.allocator.free(log);
        try testing.expect(std.mem.indexOf(u8, log, "POST /session/oc-sess/abort") != null);
        try testing.expect(std.mem.indexOf(u8, log, "POST /permission/perm-1/reply {\"reply\":\"reject\"}") != null);
    }
    {
        const rig = try testkit.Rig.create(.{ .harness = "opencode", .override_var = "OPENCODE_EXECUTABLE", .script = mock_serve, .missing_binary = true });
        defer rig.destroy();
        try rig.run("m-1", "hi");
        try rig.waitIdle(5000);
        const doc = try rig.docJson();
        defer testing.allocator.free(doc);
        try testing.expect(std.mem.indexOf(u8, doc, "harness binary not found: /nonexistent/harness-agent-mock does not exist") != null);
    }
}
