//! `ExternalHistoryList`, ported from `crates/engine/src/external_history/`
//! (`mod.rs` `ExternalHistory::list`, `discover`, the shared head readers,
//! and the `claude.rs`, `codex.rs` and `graff.rs` session finders).
//!
//! Conversations other tools keep on disk — Claude Code
//! (`<claude config>/projects/<encoded cwd>/<id>.jsonl`), Codex
//! (`<codex home>/{sessions,archived_sessions}/**/<rollout>.jsonl`) and graff
//! (`<project>/.graff/sessions/<id>.transcript.jsonl`) — newest first, minus
//! the ones already in Harness (imported, or started by Harness). Nothing here
//! writes to those files; only the head of each is read.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const common = @import("rpcw_common.zig");
const engine_host = @import("engine_host.zig");

const RpcOutcome = common.RpcOutcome;

const min_title_chars: usize = 2;
const title_chars: usize = 90;
const head_lines: usize = 400;
const graff_suffix = ".transcript.jsonl";

pub const Source = enum {
    claude,
    codex,
    graff,

    pub fn slug(s: Source) []const u8 {
        return @tagName(s);
    }
};

pub const Session = struct {
    source: Source,
    id: []u8,
    path: []u8,
    cwd: ?[]u8,
    title: []u8,
    started_at: i64,
    updated_at: i64,
    size: u64,

    pub fn deinit(self: *Session, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.path);
        if (self.cwd) |c| gpa.free(c);
        gpa.free(self.title);
    }
};

// ── shared helpers (mod.rs) ────────────────────────────────────────────────

/// `is_scaffolding`: not a person's words (environment blocks, echoes, reminders).
pub fn isScaffolding(text: []const u8) bool {
    const t = std.mem.trimStart(u8, text, " \t\r\n\x0b\x0c");
    return t.len == 0 or t[0] == '<' or
        std.mem.startsWith(u8, t, "Caveat:") or
        std.mem.startsWith(u8, t, "# AGENTS.md") or
        std.mem.startsWith(u8, t, "[Request interrupted");
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// `one_line`: whitespace runs collapse to one space; longer than `max`
/// characters is cut to `max - 1` and ends with `…`.
pub fn oneLine(gpa: Allocator, text: []const u8, max: usize) ![]u8 {
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(gpa);
    var words = std.mem.tokenizeAny(u8, text, " \t\n\r\x0b\x0c");
    while (words.next()) |w| {
        if (flat.items.len > 0) try flat.append(gpa, ' ');
        try flat.appendSlice(gpa, w);
    }
    const count = std.unicode.utf8CountCodepoints(flat.items) catch flat.items.len;
    if (count <= max) return gpa.dupe(u8, flat.items);
    // Cut after `max - 1` characters.
    var cut: usize = 0;
    var chars: usize = 0;
    while (cut < flat.items.len and chars < max -| 1) : (chars += 1) {
        cut += std.unicode.utf8ByteSequenceLength(flat.items[cut]) catch 1;
    }
    var head = flat.items[0..@min(cut, flat.items.len)];
    while (head.len > 0 and isSpace(head[head.len - 1])) head = head[0 .. head.len - 1];
    return std.fmt.allocPrint(gpa, "{s}…", .{head});
}

/// `file_times`: (first write, last write, size); birth time where the
/// platform keeps one, else the last write.
fn fileTimes(gpa: Allocator, io: std.Io, path: []const u8) struct { i64, i64, u64 } {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ 0, 0, 0 };
    const modified: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
    var created: i64 = 0;
    if (comptime builtin.os.tag == .macos and builtin.link_libc) {
        if (gpa.dupeSentinel(u8, path, 0)) |z| {
            defer gpa.free(z);
            var cst: std.c.Stat = undefined;
            if (std.c.stat(z, &cst) == 0) {
                const b = cst.birthtime();
                created = @as(i64, @intCast(b.sec)) * 1000 + @divTrunc(@as(i64, @intCast(b.nsec)), std.time.ns_per_ms);
            }
        } else |_| {}
    }
    created = @min(created, modified);
    return .{ if (created == 0) modified else created, modified, st.size };
}

/// `json_lines(..).take(HEAD_LINES)`: up to 400 parsed lines from the head of a
/// JSONL file. Malformed lines are skipped; reading stops at a line that is
/// not UTF-8 (Rust's `lines().map_while(Ok)`).
const HeadReader = struct {
    gpa: Allocator,
    file: std.Io.File,
    io: std.Io,
    buf: [64 * 1024]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    line: std.Io.Writer.Allocating,
    parsed: usize = 0,
    done: bool = false,
    current: ?json.Parsed(json.Value) = null,

    fn open(gpa: Allocator, io: std.Io, path: []const u8) ?*HeadReader {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        const self = gpa.create(HeadReader) catch {
            file.close(io);
            return null;
        };
        self.* = .{ .gpa = gpa, .file = file, .io = io, .line = .init(gpa) };
        self.reader = file.reader(io, &self.buf);
        return self;
    }

    fn close(self: *HeadReader) void {
        if (self.current) |*c| c.deinit();
        self.line.deinit();
        self.file.close(self.io);
        self.gpa.destroy(self);
    }

    /// The next parsed line, valid until the following call.
    fn next(self: *HeadReader) ?json.Value {
        if (self.current) |*c| {
            c.deinit();
            self.current = null;
        }
        while (!self.done and self.parsed < head_lines) {
            self.line.clearRetainingCapacity();
            const r = &self.reader.interface;
            _ = r.streamDelimiterLimit(&self.line.writer, '\n', .limited(64 * 1024 * 1024)) catch {
                self.done = true;
                return null;
            };
            // Consume the delimiter, or note the end of the file.
            if (r.buffered().len > 0) r.toss(1) else self.done = true;
            const text = std.mem.trimEnd(u8, self.line.written(), "\r");
            if (self.done and text.len == 0) return null;
            if (!std.unicode.utf8ValidateSlice(text)) {
                self.done = true;
                return null;
            }
            const parsed = json.parseFromSlice(json.Value, self.gpa, text, .{}) catch continue;
            self.parsed += 1;
            self.current = parsed;
            return parsed.value;
        }
        return null;
    }
};

fn field(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strField(v: json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn isTrue(v: json.Value, key: []const u8) bool {
    const f = field(v, key) orelse return false;
    return f == .bool and f.bool;
}

/// `session_from_head`: a session when the file holds a prompt worth a title.
fn sessionFromHead(gpa: Allocator, io: std.Io, source: Source, id: []const u8, path: []const u8, cwd: ?[]const u8, prompt: ?[]const u8) !?Session {
    const p = prompt orelse return null;
    const title = try oneLine(gpa, p, title_chars);
    errdefer gpa.free(title);
    if ((std.unicode.utf8CountCodepoints(title) catch title.len) < min_title_chars) {
        gpa.free(title);
        return null;
    }
    const times = fileTimes(gpa, io, path);
    const id_c = try gpa.dupe(u8, id);
    errdefer gpa.free(id_c);
    const path_c = try gpa.dupe(u8, path);
    errdefer gpa.free(path_c);
    return .{
        .source = source,
        .id = id_c,
        .path = path_c,
        .cwd = if (cwd) |c| try gpa.dupe(u8, c) else null,
        .title = title,
        .started_at = times[0],
        .updated_at = times[1],
        .size = times[2],
    };
}

/// Text joined from a content value: a string, or the `text` of each block
/// (`only_text_type`: just blocks whose `type` is `text`).
fn contentText(gpa: Allocator, content: ?json.Value, only_text_type: bool) !?[]u8 {
    const c = content orelse return null;
    switch (c) {
        .string => |s| return try gpa.dupe(u8, s),
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var n: usize = 0;
            for (arr.items) |b| {
                if (only_text_type) {
                    const t = strField(b, "type") orelse continue;
                    if (!std.mem.eql(u8, t, "text")) continue;
                }
                const text = strField(b, "text") orelse continue;
                if (n > 0) try out.append(gpa, '\n');
                try out.appendSlice(gpa, text);
                n += 1;
            }
            if (only_text_type and n == 0) {
                out.deinit(gpa);
                return null;
            }
            return try out.toOwnedSlice(gpa);
        },
        else => return if (only_text_type) null else try gpa.dupe(u8, ""),
    }
}

// ── Claude Code (claude.rs) ────────────────────────────────────────────────

/// `encode_cwd`: every non-alphanumeric character becomes `-`.
pub fn encodeCwd(gpa: Allocator, cwd: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.unicode.Utf8View.initUnchecked(cwd).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (cp.len == 1 and std.ascii.isAlphanumeric(cp[0])) try out.append(gpa, cp[0]) else try out.append(gpa, '-');
    }
    return out.toOwnedSlice(gpa);
}

fn claudeHead(gpa: Allocator, io: std.Io, path: []const u8) !?Session {
    const base = std.fs.path.basename(path);
    const id = base[0 .. base.len - ".jsonl".len];
    const hr = HeadReader.open(gpa, io, path) orelse return null;
    defer hr.close();
    var cwd: ?[]u8 = null;
    defer if (cwd) |c| gpa.free(c);
    var prompt: ?[]u8 = null;
    defer if (prompt) |p| gpa.free(p);
    while (hr.next()) |line| {
        if (isTrue(line, "isSidechain")) continue;
        if (cwd == null) if (strField(line, "cwd")) |c| {
            cwd = try gpa.dupe(u8, c);
        };
        if (prompt == null and std.mem.eql(u8, strField(line, "type") orelse "", "user") and !isTrue(line, "isMeta")) {
            const msg = field(line, "message");
            const content = if (msg) |m| field(m, "content") else null;
            if (try contentText(gpa, content, true)) |text| {
                if (isScaffolding(text)) gpa.free(text) else prompt = text;
            }
        }
        if (cwd != null and prompt != null) break;
    }
    return sessionFromHead(gpa, io, .claude, id, path, cwd, prompt);
}

fn discoverClaude(gpa: Allocator, io: std.Io, config_dir: []const u8, cwd: ?[]const u8, out: *std.ArrayList(Session)) !void {
    const projects = try std.fs.path.join(gpa, &.{ config_dir, "projects" });
    defer gpa.free(projects);
    var dir = std.Io.Dir.cwd().openDir(io, projects, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const wanted = if (cwd) |c| try encodeCwd(gpa, c) else null;
    defer if (wanted) |w| gpa.free(w);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (wanted) |w| if (!std.mem.eql(u8, entry.name, w)) continue;
        const sub = try std.fs.path.join(gpa, &.{ projects, entry.name });
        defer gpa.free(sub);
        var files = std.Io.Dir.cwd().openDir(io, sub, .{ .iterate = true }) catch continue;
        defer files.close(io);
        var fit = files.iterate();
        while (fit.next(io) catch null) |file| {
            if (!std.mem.endsWith(u8, file.name, ".jsonl") or file.name.len == ".jsonl".len) continue;
            const path = try std.fs.path.join(gpa, &.{ sub, file.name });
            defer gpa.free(path);
            if (try claudeHead(gpa, io, path)) |s| try out.append(gpa, s);
        }
    }
}

// ── Codex (codex.rs) ───────────────────────────────────────────────────────

fn rolloutFiles(gpa: Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                defer gpa.free(path);
                try rolloutFiles(gpa, io, path, out);
            },
            .file => if (std.mem.endsWith(u8, entry.name, ".jsonl") and entry.name.len > ".jsonl".len) {
                try out.append(gpa, path);
            } else gpa.free(path),
            else => gpa.free(path),
        }
    }
}

fn codexHead(gpa: Allocator, io: std.Io, path: []const u8, want_cwd: ?[]const u8) !?Session {
    const hr = HeadReader.open(gpa, io, path) orelse return null;
    defer hr.close();
    var id: ?[]u8 = null;
    defer if (id) |x| gpa.free(x);
    var cwd: ?[]u8 = null;
    defer if (cwd) |c| gpa.free(c);
    var prompt: ?[]u8 = null;
    defer if (prompt) |p| gpa.free(p);
    while (hr.next()) |line| {
        const kind = strField(line, "type") orelse "";
        const payload = field(line, "payload") orelse json.Value{ .null = {} };
        if (std.mem.eql(u8, kind, "session_meta")) {
            if (field(payload, "source")) |src| if (field(src, "subagent")) |sa| if (sa == .object) return null;
            if (id) |x| gpa.free(x);
            id = if (strField(payload, "id")) |s| try gpa.dupe(u8, s) else null;
            if (cwd) |c| gpa.free(c);
            cwd = if (strField(payload, "cwd")) |s| try gpa.dupe(u8, s) else null;
            if (want_cwd) |want| if (cwd) |have| if (!std.mem.eql(u8, want, have)) return null;
        } else if (std.mem.eql(u8, kind, "response_item") and prompt == null and
            std.mem.eql(u8, strField(payload, "type") orelse "", "message") and
            std.mem.eql(u8, strField(payload, "role") orelse "", "user"))
        {
            const text = (try contentText(gpa, field(payload, "content"), false)) orelse try gpa.dupe(u8, "");
            if (isScaffolding(text)) gpa.free(text) else prompt = text;
        }
        if (id != null and prompt != null) break;
    }
    if (want_cwd != null and cwd == null) return null;
    const native = id orelse return null;
    return sessionFromHead(gpa, io, .codex, native, path, cwd, prompt);
}

fn discoverCodex(gpa: Allocator, io: std.Io, codex_home: []const u8, cwd: ?[]const u8, out: *std.ArrayList(Session)) !void {
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    for ([_][]const u8{ "sessions", "archived_sessions" }) |sub| {
        const dir = try std.fs.path.join(gpa, &.{ codex_home, sub });
        defer gpa.free(dir);
        try rolloutFiles(gpa, io, dir, &files);
    }
    for (files.items) |path| {
        if (try codexHead(gpa, io, path, cwd)) |s| try out.append(gpa, s);
    }
}

// ── graff (graff.rs) ───────────────────────────────────────────────────────

fn samePath(a: []const u8, b: []const u8) bool {
    const ta = if (a.len > 1) std.mem.trimEnd(u8, a, "/") else a;
    const tb = if (b.len > 1) std.mem.trimEnd(u8, b, "/") else b;
    return std.mem.eql(u8, ta, tb);
}

fn discoverGraff(gpa: Allocator, io: std.Io, projects: []const []const u8, cwd: ?[]const u8, out: *std.ArrayList(Session)) !void {
    for (projects) |project| {
        if (cwd) |c| if (!samePath(project, c)) continue;
        const sessions = try std.fs.path.join(gpa, &.{ project, ".graff", "sessions" });
        defer gpa.free(sessions);
        var dir = std.Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, graff_suffix)) continue;
            const id = entry.name[0 .. entry.name.len - graff_suffix.len];
            const path = try std.fs.path.join(gpa, &.{ sessions, entry.name });
            defer gpa.free(path);
            var prompt: ?[]u8 = null;
            defer if (prompt) |p| gpa.free(p);
            if (HeadReader.open(gpa, io, path)) |hr| {
                defer hr.close();
                while (hr.next()) |line| {
                    if (!std.mem.eql(u8, strField(line, "role") orelse "", "user")) continue;
                    const text = (try contentText(gpa, field(line, "content"), false)) orelse try gpa.dupe(u8, "");
                    if (isScaffolding(text)) {
                        gpa.free(text);
                        continue;
                    }
                    prompt = text;
                    break;
                }
            }
            if (try sessionFromHead(gpa, io, .graff, id, path, project, prompt)) |s| try out.append(gpa, s);
        }
    }
}

// ── the listing ────────────────────────────────────────────────────────────

pub const Roots = struct {
    claude_dir: []const u8,
    codex_home: []const u8,
};

/// `discover`: every tool's sessions, newest write first.
pub fn discover(gpa: Allocator, io: std.Io, roots: Roots, projects: []const []const u8, cwd: ?[]const u8) !std.ArrayList(Session) {
    var found: std.ArrayList(Session) = .empty;
    errdefer {
        for (found.items) |*s| s.deinit(gpa);
        found.deinit(gpa);
    }
    try discoverClaude(gpa, io, roots.claude_dir, cwd, &found);
    try discoverCodex(gpa, io, roots.codex_home, cwd, &found);
    try discoverGraff(gpa, io, projects, cwd, &found);
    std.mem.sort(Session, found.items, {}, struct {
        fn newer(_: void, a: Session, b: Session) bool {
            return a.updated_at > b.updated_at;
        }
    }.newer);
    return found;
}

fn writeSession(w: *std.Io.Writer, s: Session) !void {
    try w.print("{{\"source\":\"{s}\",\"id\":{f},\"path\":{f},\"cwd\":", .{ s.source.slug(), json.fmt(s.id, .{}), json.fmt(s.path, .{}) });
    if (s.cwd) |c| try w.print("{f}", .{json.fmt(c, .{})}) else try w.writeAll("null");
    try w.print(",\"title\":{f},\"startedAt\":{d},\"updatedAt\":{d},\"size\":{d}}}", .{ json.fmt(s.title, .{}), s.started_at, s.updated_at, s.size });
}

/// `ExternalHistoryList { cwd?, limit? }` → sessions not in Harness yet,
/// newest first, at most `limit` (200).
pub fn externalHistoryList(host: *engine_host.EngineHost, params: json.Value) !RpcOutcome {
    const gpa = host.gpa;
    const o = common.obj(params);
    const cwd: ?[]const u8 = if (o) |m| common.str(m, "cwd") else null;
    const limit: usize = if (o) |m| (if (m.get("limit")) |v| (if (v == .integer and v.integer >= 0) @as(usize, @intCast(v.integer)) else 200) else 200) else 200;
    const io = host.io orelse return common.failed("conversation import unavailable", .{});

    // `AgentAccountsConfig::detect`: CLAUDE_CONFIG_DIR / CODEX_HOME or the home defaults.
    const home = common.homeDir() orelse "/";
    const claude_dir = if (common.getenvNonEmpty("CLAUDE_CONFIG_DIR")) |d| try gpa.dupe(u8, d) else try std.fs.path.join(gpa, &.{ home, ".claude" });
    defer gpa.free(claude_dir);
    const codex_home = if (common.getenvNonEmpty("CODEX_HOME")) |d| try gpa.dupe(u8, d) else try std.fs.path.join(gpa, &.{ home, ".codex" });
    defer gpa.free(codex_home);

    // `projects`: `cwd`, then every chat's folder; `known`: chat ids and the
    // native session ids Harness itself started.
    var projects: std.ArrayList([]const u8) = .empty;
    defer projects.deinit(gpa);
    if (cwd) |c| if (c.len > 0) try projects.append(gpa, c);
    for (host.chats.items) |chat| {
        const c = chat.cwd orelse continue;
        if (c.len == 0) continue;
        for (projects.items) |p| {
            if (std.mem.eql(u8, p, c)) break;
        } else try projects.append(gpa, c);
    }

    var found = try discover(gpa, io, .{ .claude_dir = claude_dir, .codex_home = codex_home }, projects.items, cwd);
    defer {
        for (found.items) |*s| s.deinit(gpa);
        found.deinit(gpa);
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    var n: usize = 0;
    for (found.items) |s| {
        if (n >= limit) break;
        if (isKnown(host, s)) continue;
        if (n > 0) try w.writeByte(',');
        try writeSession(w, s);
        n += 1;
    }
    try w.writeByte(']');
    return .{ .unary_json = try aw.toOwnedSlice() };
}

/// `Known::is_known`: `ext-<slug>-<id>` is a chat, or `id` is a chat's
/// native session id.
fn isKnown(host: *engine_host.EngineHost, s: Session) bool {
    var buf: [512]u8 = undefined;
    const chat_id = std.fmt.bufPrint(&buf, "ext-{s}-{s}", .{ s.source.slug(), s.id }) catch "";
    for (host.chats.items) |chat| {
        if (chat_id.len > 0 and std.mem.eql(u8, chat.id, chat_id)) return true;
        if (chat.harness_session_id) |native| if (std.mem.eql(u8, native, s.id)) return true;
    }
    return false;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fx = struct {
    tmp: testing.TmpDir,
    base: []u8,
    env: common.TestEnv,
    host: engine_host.EngineHost,

    fn init() !*Fx {
        const gpa = testing.allocator;
        const io = testing.io;
        const f = try gpa.create(Fx);
        f.tmp = testing.tmpDir(.{});
        f.base = try common.tmpPath(gpa, io, &f.tmp);
        f.env = try common.TestEnv.init(gpa, f.base);
        f.env.install();
        f.host = try engine_host.EngineHost.init(gpa, "dev-synthetic", "Synthetic");
        f.host.io = io;
        return f;
    }

    fn deinit(f: *Fx) void {
        const gpa = testing.allocator;
        f.host.deinit();
        f.env.deinit();
        gpa.free(f.base);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    fn write(f: *Fx, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    /// Set a file's modification time (`touch -t CCYYMMDDhhmm`) so ordering is fixed.
    fn touch(f: *Fx, sub: []const u8, stamp: []const u8) !void {
        const path = try std.fs.path.join(testing.allocator, &.{ f.base, sub });
        defer testing.allocator.free(path);
        var r = try common.run(testing.allocator, testing.io, &.{ "/usr/bin/touch", "-m", "-t", stamp, path }, null, 10_000);
        defer r.deinit(testing.allocator);
        if (!r.success()) return error.TouchFailed;
    }

    fn list(f: *Fx, params_text: []const u8) !json.Parsed(json.Value) {
        var p = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
        defer p.deinit();
        const out = try f.host.handle("ExternalHistoryList", p.value);
        defer testing.allocator.free(out.unary_json);
        return json.parseFromSlice(json.Value, testing.allocator, out.unary_json, .{});
    }
};

test "rpcw_history titles, scaffolding and cwd encoding follow external_history" {
    const gpa = testing.allocator;
    try testing.expect(isScaffolding("  <environment_context>"));
    try testing.expect(isScaffolding("Caveat: the messages below"));
    try testing.expect(isScaffolding("[Request interrupted by user]"));
    try testing.expect(!isScaffolding("Fix the login bug"));
    const t = try oneLine(gpa, "  Fix\n the   login\tbug ", 90);
    defer gpa.free(t);
    try testing.expectEqualStrings("Fix the login bug", t);
    const long = try oneLine(gpa, "abcdef ghij", 8);
    defer gpa.free(long);
    try testing.expectEqualStrings("abcdef…", long);
    const enc = try encodeCwd(gpa, "/Users/synthetic/my proj.é");
    defer gpa.free(enc);
    try testing.expectEqualStrings("-Users-synthetic-my-proj--", enc);
}

test "rpcw_history ExternalHistoryList finds Claude, Codex and graff sessions newest first" {
    const f = try Fx.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const project = try std.fs.path.join(gpa, &.{ f.base, "proj" });
    defer gpa.free(project);
    const enc = try encodeCwd(gpa, project);
    defer gpa.free(enc);

    // Claude Code: a sidechain line and scaffolding are skipped for the title.
    const claude_path = try std.fmt.allocPrint(gpa, ".claude/projects/{s}/c-1.jsonl", .{enc});
    defer gpa.free(claude_path);
    const claude_body = try std.fmt.allocPrint(gpa,
        \\{{"type":"user","isSidechain":true,"cwd":"/elsewhere","message":{{"content":"sidechain"}}}}
        \\not json
        \\{{"type":"user","cwd":{f},"message":{{"content":"<command-name>/clear</command-name>"}}}}
        \\{{"type":"user","message":{{"content":[{{"type":"text","text":"Fix the   login\nbug"}}]}}}}
        \\
    , .{json.fmt(project, .{})});
    defer gpa.free(claude_body);
    try f.write(claude_path, claude_body);
    try f.touch(claude_path, "202001010000");
    // An empty start (no prompt) is not offered.
    const empty_path = try std.fmt.allocPrint(gpa, ".claude/projects/{s}/c-empty.jsonl", .{enc});
    defer gpa.free(empty_path);
    try f.write(empty_path, "{\"type\":\"summary\"}\n");

    // Codex: a sub-agent thread is not a conversation.
    const codex_body = try std.fmt.allocPrint(gpa,
        \\{{"type":"session_meta","payload":{{"id":"0199aaaa-0000-7000-8000-000000000001","cwd":{f}}}}}
        \\{{"type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"# AGENTS.md instructions"}}]}}}}
        \\{{"type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"Add dark mode"}}]}}}}
        \\
    , .{json.fmt(project, .{})});
    defer gpa.free(codex_body);
    try f.write(".codex/sessions/2026/11/01/rollout-a.jsonl", codex_body);
    try f.touch(".codex/sessions/2026/11/01/rollout-a.jsonl", "202401010000");
    try f.write(".codex/archived_sessions/rollout-sub.jsonl", "{\"type\":\"session_meta\",\"payload\":{\"id\":\"sub\",\"source\":{\"subagent\":{\"review\":true}}}}\n{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":\"Review this\"}}\n");

    // graff: found through the cwd's .graff/sessions.
    try f.write("proj/.graff/sessions/g-1.transcript.jsonl", "{\"role\":\"system\",\"content\":\"You are graff\"}\n{\"role\":\"user\",\"content\":\"Write the release notes\"}\n");
    try f.touch("proj/.graff/sessions/g-1.transcript.jsonl", "202201010000");

    const params = try std.fmt.allocPrint(gpa, "{{\"cwd\":{f}}}", .{json.fmt(project, .{})});
    defer gpa.free(params);
    var parsed = try f.list(params);
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("codex", rows[0].object.get("source").?.string);
    try testing.expectEqualStrings("0199aaaa-0000-7000-8000-000000000001", rows[0].object.get("id").?.string);
    try testing.expectEqualStrings("Add dark mode", rows[0].object.get("title").?.string);
    try testing.expectEqualStrings("graff", rows[1].object.get("source").?.string);
    try testing.expectEqualStrings("g-1", rows[1].object.get("id").?.string);
    try testing.expectEqualStrings("Write the release notes", rows[1].object.get("title").?.string);
    try testing.expectEqualStrings(project, rows[1].object.get("cwd").?.string);
    try testing.expectEqualStrings("claude", rows[2].object.get("source").?.string);
    try testing.expectEqualStrings("c-1", rows[2].object.get("id").?.string);
    try testing.expectEqualStrings("Fix the login bug", rows[2].object.get("title").?.string);
    try testing.expectEqualStrings(project, rows[2].object.get("cwd").?.string);
    try testing.expect(rows[2].object.get("size").?.integer > 0);
    try testing.expect(rows[2].object.get("updatedAt").?.integer >= rows[2].object.get("startedAt").?.integer);

    // limit
    const limited = try std.fmt.allocPrint(gpa, "{{\"cwd\":{f},\"limit\":1}}", .{json.fmt(project, .{})});
    defer gpa.free(limited);
    var one = try f.list(limited);
    defer one.deinit();
    try testing.expectEqual(@as(usize, 1), one.value.array.items.len);

    // A different cwd filters every source.
    var other = try f.list("{\"cwd\":\"/nonexistent-synthetic\"}");
    defer other.deinit();
    try testing.expectEqual(@as(usize, 0), other.value.array.items.len);
}

test "rpcw_history ExternalHistoryList hides sessions already in Harness" {
    const f = try Fx.init();
    defer f.deinit();
    const gpa = testing.allocator;
    try f.write(".claude/projects/-x/imported.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"Already imported\"}}\n");
    try f.write(".claude/projects/-x/started.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"Started by Harness\"}}\n");
    try f.write(".claude/projects/-x/fresh.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"Fresh one\"}}\n");
    try f.host.chats.append(gpa, .{ .id = try gpa.dupe(u8, "ext-claude-imported"), .space_id = null, .device_id = try gpa.dupe(u8, "dev-synthetic"), .harness = try gpa.dupe(u8, "graff") });
    try f.host.chats.append(gpa, .{ .id = try gpa.dupe(u8, "chat-1"), .space_id = null, .device_id = try gpa.dupe(u8, "dev-synthetic"), .harness = try gpa.dupe(u8, "claude-code"), .harness_session_id = try gpa.dupe(u8, "started") });
    var parsed = try f.list("{}");
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("fresh", rows[0].object.get("id").?.string);
    try testing.expect(rows[0].object.get("cwd").? == .null);
}
