//! Model discovery shared by every harness's live catalog, ported from
//! `crates/harness/src/{catalog.rs, catalog_failure.rs, model_context.rs}` and
//! `crates/engine/src/model_catalogs.rs`:
//!
//! - `Failure`: `CatalogFailure` and the `HarnessError`s a probe can return,
//!   with `classify` (the stable codes) and their display text.
//! - `Model`: `harness_proto::Model`, written and read in its wire shape.
//! - `computeContext`: the credential/binary fingerprint (`ModelContext`) a
//!   catalog is cached under: binary path, version, mtime and size, the
//!   harness's auth files, and its environment variables, hashed with SHA-256.
//! - `MemCache`: the per-harness in-memory catalog (`catalog::Catalog`):
//!   coalesced refreshes, three attempts, cooldowns, and never publishing a
//!   catalog from a login that changed mid-request.
//! - `list`: `model_catalogs::list`, the disk cache under
//!   `{data_dir}/model-catalogs/{harness}/{context}.json` and its rules (serve
//!   disk within 100 ms while the live refresh finishes in the background,
//!   retire disk on auth/missing-binary failures, curated rows for a
//!   logged-out Claude, static rows only as a last resort).
//!
//! Std-only (plus `agent_proc.zig` for the environment), so it is testable
//! with `zig test src/catalog_core.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const Sha256 = std.crypto.hash.sha2.Sha256;
const agent_proc = @import("agent_proc.zig");
const harness_version = @import("harness_version.zig");

/// Long-lived catalog state (memory caches, background refreshes) outlives
/// any request, so it uses a thread-safe process allocator.
pub const long_gpa = std.heap.smp_allocator;

// ── environment ────────────────────────────────────────────────────────────

/// Tests replace the whole environment; the engine passes its own test
/// override through here too.
pub var env_override: ?*const Environ.Map = null;

/// The environment probes see (owned copy).
pub fn currentEnv(gpa: Allocator) !Environ.Map {
    if (env_override) |m| return m.clone(gpa);
    return agent_proc.currentEnv(gpa);
}

/// Resolves a harness's CLI (wire id → owned absolute path, or null when it is
/// not installed). The engine points this at its own executable discovery
/// (`rpcw_executables.zig`); tests point it at mock scripts.
pub const ResolveCli = *const fn (gpa: Allocator, io: Io, id: []const u8) anyerror!?[]u8;
pub var resolve_cli: ResolveCli = resolveNone;

fn resolveNone(_: Allocator, _: Io, _: []const u8) anyerror!?[]u8 {
    return null;
}

/// `home_or_current_dir`: HOME (non-empty), else the current directory.
pub fn homeOrCwd(gpa: Allocator, io: Io, env: *const Environ.Map) ![]u8 {
    if (env.get("HOME")) |h| if (h.len > 0) return gpa.dupe(u8, h);
    if (builtin.os.tag == .windows) if (env.get("USERPROFILE")) |h| if (h.len > 0) return gpa.dupe(u8, h);
    const z = Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch return gpa.dupe(u8, ".");
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}

/// `model_context::root(variable, fallback)`.
pub fn envRoot(gpa: Allocator, env: *const Environ.Map, variable: []const u8, fallback: []const []const u8) ![]u8 {
    if (env.get(variable)) |v| if (v.len > 0) return gpa.dupe(u8, v);
    return std.fs.path.join(gpa, fallback);
}

// ── failures ───────────────────────────────────────────────────────────────

pub const Code = enum {
    timeout,
    failed,
    missing_executable,
    auth_required,

    pub fn str(c: Code) []const u8 {
        return switch (c) {
            .timeout => "timeout",
            .failed => "failed",
            .missing_executable => "missing_executable",
            .auth_required => "auth_required",
        };
    }

    /// Only transient failures may serve a stale catalog.
    pub fn allowsStale(c: Code) bool {
        return c == .timeout or c == .failed;
    }
};

/// `CatalogFailure::classify` for an error's display text.
pub fn classify(text: []const u8) Code {
    var lower_buf: [1024]u8 = undefined;
    const n = @min(text.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], text[0..n]);
    if (contains(lower, "enoent") or contains(lower, "harness binary not found") or contains(lower, "no such file or directory"))
        return .missing_executable;
    var parts = std.mem.tokenizeAny(u8, lower, &nonAlnum());
    var auth_status = false;
    while (parts.next()) |p| {
        if (std.mem.eql(u8, p, "401") or std.mem.eql(u8, p, "403")) auth_status = true;
    }
    if (auth_status) return .auth_required;
    for ([_][]const u8{ "not logged in", "authentication", "unauthenticated", "not authenticated", "unauthorized", "auth_required", "api key" }) |pat| {
        if (contains(lower, pat)) return .auth_required;
    }
    for ([_][]const u8{ "timeout", "timed out", "deadline has elapsed", "did not complete within" }) |pat| {
        if (contains(lower, pat)) return .timeout;
    }
    return .failed;
}

fn nonAlnum() [256 - 62]u8 {
    var out: [256 - 62]u8 = undefined;
    var i: usize = 0;
    for (0..256) |c| {
        const b: u8 = @intCast(c);
        if (std.ascii.isAlphanumeric(b)) continue;
        out[i] = b;
        i += 1;
    }
    return out;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// `catalog::needs_cooldown`: repeating these cannot heal them.
pub fn needsCooldown(text: []const u8) bool {
    var lower_buf: [1024]u8 = undefined;
    const n = @min(text.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], text[0..n]);
    for ([_][]const u8{ "rate limit", "rate-limit", "429", "unauthenticated", "unauthorized", "not authenticated", "auth_required", "401", "api key" }) |pat| {
        if (contains(lower, pat)) return true;
    }
    return false;
}

/// A discovery error: either `HarnessError::Discovery(CatalogFailure)` or
/// another `HarnessError`, whose full display text is kept with the code
/// `CatalogFailure::classify` gives it.
pub const Failure = struct {
    code: Code,
    discovery: bool,
    len: usize = 0,
    buf: [1024]u8 = undefined,

    fn make(code: Code, discovery: bool, text: []const u8) Failure {
        var f: Failure = .{ .code = code, .discovery = discovery };
        f.len = @min(text.len, f.buf.len);
        @memcpy(f.buf[0..f.len], text[0..f.len]);
        return f;
    }

    /// `CatalogFailure { code, message }`.
    pub fn discoveryFailure(code: Code, msg: []const u8) Failure {
        return make(code, true, msg);
    }

    /// A non-discovery `HarnessError` by its display text.
    pub fn other(text: []const u8) Failure {
        return make(classify(text), false, text);
    }

    /// `HarnessError::Protocol(msg)`.
    pub fn protocol(comptime fmt: []const u8, args: anytype) Failure {
        var tmp: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "harness protocol error: " ++ fmt, args) catch tmp[0..];
        return other(text);
    }

    /// `HarnessError::NotInstalled(what)`.
    pub fn notInstalled(what: []const u8) Failure {
        var tmp: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "harness binary not found: {s}", .{what}) catch tmp[0..];
        return make(.missing_executable, false, text);
    }

    /// `HarnessError::Io(e)`: `NotFound` reads as a missing executable and
    /// `TimedOut` as a timeout, whatever the text.
    pub fn ioError(kind: enum { not_found, timed_out, other }, msg: []const u8) Failure {
        var tmp: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "io: {s}", .{msg}) catch tmp[0..];
        return make(switch (kind) {
            .not_found => .missing_executable,
            .timed_out => .timeout,
            .other => classify(text),
        }, false, text);
    }

    /// The message: a CatalogFailure's message, or the error's display.
    pub fn message(self: *const Failure) []const u8 {
        return self.buf[0..self.len];
    }

    /// `HarnessError::to_string()`.
    pub fn display(self: *const Failure, out: []u8) []const u8 {
        if (!self.discovery) return std.fmt.bufPrint(out, "{s}", .{self.message()}) catch out;
        return std.fmt.bufPrint(out, "model discovery {s}: {s}", .{ self.code.str(), self.message() }) catch out;
    }

    /// `CatalogFailure::from(error)`.
    pub fn intoDiscovery(self: Failure) Failure {
        if (self.discovery) return self;
        return make(self.code, true, self.message());
    }
};

// ── the model wire shape ───────────────────────────────────────────────────

/// `ReasoningLevel` (serde lowercase).
pub const reasoning_levels = [_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "ultracode", "ultrathink" };

pub fn isReasoningLevel(text: []const u8) bool {
    for (reasoning_levels) |l| if (std.mem.eql(u8, l, text)) return true;
    return false;
}

pub const Choice = struct { id: []const u8, label: []const u8 };

pub const ModelOption = struct {
    id: []const u8,
    label: []const u8,
    choices: []const Choice,
    default_choice: []const u8,
};

/// `harness_proto::Model`.
pub const Model = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
    reasoning_levels: []const []const u8 = &.{},
    options: []const ModelOption = &.{},
    maker: ?[]const u8 = null,
    billing: ?[]const u8 = null,
    context: ?u64 = null,

    /// serde's field order and `skip_serializing_if`s.
    pub fn write(m: Model, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{{\"id\":{f},\"label\":{f}", .{ json.fmt(m.id, .{}), json.fmt(m.label, .{}) });
        if (m.description) |d| try w.print(",\"description\":{f}", .{json.fmt(d, .{})});
        try w.writeAll(",\"reasoningLevels\":[");
        for (m.reasoning_levels, 0..) |l, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{f}", .{json.fmt(l, .{})});
        }
        try w.writeAll("],\"options\":[");
        for (m.options, 0..) |o, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"id\":{f},\"label\":{f},\"choices\":[", .{ json.fmt(o.id, .{}), json.fmt(o.label, .{}) });
            for (o.choices, 0..) |c, j| {
                if (j > 0) try w.writeByte(',');
                try w.print("{{\"id\":{f},\"label\":{f}}}", .{ json.fmt(c.id, .{}), json.fmt(c.label, .{}) });
            }
            try w.print("],\"defaultChoice\":{f}}}", .{json.fmt(o.default_choice, .{})});
        }
        try w.writeByte(']');
        if (m.maker) |x| try w.print(",\"maker\":{f}", .{json.fmt(x, .{})});
        if (m.billing) |x| try w.print(",\"billing\":{f}", .{json.fmt(x, .{})});
        if (m.context) |x| try w.print(",\"context\":{d}", .{x});
        try w.writeByte('}');
    }
};

/// A `Vec<Model>` as the JSON array the RPC returns. Caller owns it.
pub fn modelsJson(gpa: Allocator, models: []const Model) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeByte('[');
    for (models, 0..) |m, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try m.write(&aw.writer);
    }
    try aw.writer.writeByte(']');
    return aw.toOwnedSlice();
}

fn reqStr(o: json.ObjectMap, key: []const u8) error{Invalid}![]const u8 {
    const v = o.get(key) orelse return error.Invalid;
    return if (v == .string) v.string else error.Invalid;
}

fn optStr(o: json.ObjectMap, key: []const u8) error{Invalid}!?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => error.Invalid,
    };
}

/// serde's `Deserialize for Model`, strict like serde: wrong types and
/// unknown reasoning levels fail; unknown fields are ignored. Strings
/// borrow `v`; slices are allocated in `arena`.
pub fn parseModel(arena: Allocator, v: json.Value) !Model {
    if (v != .object) return error.Invalid;
    const o = v.object;
    var m: Model = .{ .id = try reqStr(o, "id"), .label = try reqStr(o, "label") };
    m.description = try optStr(o, "description");
    m.maker = try optStr(o, "maker");
    m.billing = try optStr(o, "billing");
    if (o.get("context")) |c| switch (c) {
        .null => {},
        .integer => |n| m.context = if (n >= 0) @intCast(n) else return error.Invalid,
        else => return error.Invalid,
    };
    if (o.get("reasoningLevels")) |rl| {
        if (rl != .array) return error.Invalid;
        const levels = try arena.alloc([]const u8, rl.array.items.len);
        for (rl.array.items, 0..) |item, i| {
            if (item != .string or !isReasoningLevel(item.string)) return error.Invalid;
            levels[i] = item.string;
        }
        m.reasoning_levels = levels;
    }
    if (o.get("options")) |ov| {
        if (ov != .array) return error.Invalid;
        const opts = try arena.alloc(ModelOption, ov.array.items.len);
        for (ov.array.items, 0..) |item, i| {
            if (item != .object) return error.Invalid;
            const io_ = item.object;
            const cv = io_.get("choices") orelse return error.Invalid;
            if (cv != .array) return error.Invalid;
            const choices = try arena.alloc(Choice, cv.array.items.len);
            for (cv.array.items, 0..) |c, j| {
                if (c != .object) return error.Invalid;
                choices[j] = .{ .id = try reqStr(c.object, "id"), .label = try reqStr(c.object, "label") };
            }
            opts[i] = .{ .id = try reqStr(io_, "id"), .label = try reqStr(io_, "label"), .choices = choices, .default_choice = try reqStr(io_, "defaultChoice") };
        }
        m.options = opts;
    }
    return m;
}

/// A JSON array of models, validated and re-serialized (`Vec<Model>`
/// through serde), or `error.Invalid`.
pub fn normalizeModelsJson(gpa: Allocator, value: json.Value) ![]u8 {
    if (value != .array) return error.Invalid;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const models = try arena.alloc(Model, value.array.items.len);
    for (value.array.items, 0..) |item, i| models[i] = try parseModel(arena, item);
    return modelsJson(gpa, models);
}

/// `true` for `[]` (and anything that is not a non-empty array).
pub fn isEmptyCatalog(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 2 or t[0] != '[') return true;
    return std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n").len == 0;
}

// ── the credential/binary context (`model_context.rs`) ─────────────────────

pub const Context = struct {
    /// `format!("{:x}", sha256)`.
    hash: [64]u8,
    binary_path: []u8,
    binary_version: ?[]u8,

    pub fn deinit(self: *Context, gpa: Allocator) void {
        gpa.free(self.binary_path);
        if (self.binary_version) |v| gpa.free(v);
    }

    pub fn clone(self: Context, gpa: Allocator) !Context {
        const p = try gpa.dupe(u8, self.binary_path);
        errdefer gpa.free(p);
        return .{ .hash = self.hash, .binary_path = p, .binary_version = if (self.binary_version) |v| try gpa.dupe(u8, v) else null };
    }

    /// `ModelContext::key`: SHA-256 of the hex hash.
    pub fn key(self: *const Context) [32]u8 {
        var out: [32]u8 = undefined;
        Sha256.hash(&self.hash, &out, .{});
        return out;
    }
};

pub fn hashField(h: *Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    h.update(bytes);
}

/// `hash_files`: each path, then 1 + its bytes, or 0 when it does not
/// exist. Other read errors fail the context.
pub fn hashFiles(gpa: Allocator, io: Io, h: *Sha256, files: []const []const u8) !void {
    for (files) |path| {
        hashField(h, path);
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => {
                h.update(&.{0});
                continue;
            },
            else => return e,
        };
        defer gpa.free(bytes);
        h.update(&.{1});
        hashField(h, bytes);
    }
}

/// Rust's `format!("{:?}", metadata.modified().ok())` on Unix.
pub fn modifiedDebug(buf: []u8, st: Io.File.Stat) []const u8 {
    const ns = st.mtime.nanoseconds;
    const sec = @divFloor(ns, std.time.ns_per_s);
    const nsec = @mod(ns, std.time.ns_per_s);
    return std.fmt.bufPrint(buf, "Some(SystemTime {{ tv_sec: {d}, tv_nsec: {d} }}):{d}", .{ sec, nsec, st.size }) catch buf[0..0];
}

/// The auth/config files each harness's catalog depends on.
fn contextFiles(gpa: Allocator, io: Io, id: []const u8, env: *const Environ.Map, home: []const u8, out: *std.ArrayList([]u8)) !void {
    const eq = std.mem.eql;
    if (eq(u8, id, "codex")) {
        const root = try envRoot(gpa, env, "CODEX_HOME", &.{ home, ".codex" });
        defer gpa.free(root);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, "auth.json" }));
    } else if (eq(u8, id, "claude-code")) {
        const root = try envRoot(gpa, env, "CLAUDE_CONFIG_DIR", &.{ home, ".claude" });
        defer gpa.free(root);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, "settings.json" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, ".credentials.json" }));
    } else if (eq(u8, id, "cursor")) {
        try out.append(gpa, try std.fs.path.join(gpa, &.{ home, ".cursor/sdk/auth.json" }));
    } else if (eq(u8, id, "opencode")) {
        const data = try envRoot(gpa, env, "XDG_DATA_HOME", &.{ home, ".local/share" });
        defer gpa.free(data);
        const config = try envRoot(gpa, env, "XDG_CONFIG_HOME", &.{ home, ".config" });
        defer gpa.free(config);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ data, "opencode/auth.json" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ config, "opencode/opencode.json" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ config, "opencode/opencode.jsonc" }));
        const cwd_z = try Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
        defer gpa.free(cwd_z);
        var dir: ?[]const u8 = cwd_z;
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            for ([_][]const u8{ "opencode.json", "opencode.jsonc", ".opencode/opencode.json", ".opencode/opencode.jsonc" }) |name| {
                try out.append(gpa, try std.fs.path.join(gpa, &.{ d, name }));
            }
        }
        if (env.get("OPENCODE_CONFIG")) |p| try out.append(gpa, try gpa.dupe(u8, p));
    } else if (eq(u8, id, "grok")) {
        const root = try envRoot(gpa, env, "GROK_HOME", &.{ home, ".grok" });
        defer gpa.free(root);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, "auth.json" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, "config.toml" }));
    } else if (eq(u8, id, "hermes")) {
        const root = try envRoot(gpa, env, "HERMES_HOME", &.{ home, ".hermes" });
        defer gpa.free(root);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, "auth.json" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, ".env" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, "config.yaml" }));
    } else if (eq(u8, id, "pi")) {
        const root = try envRoot(gpa, env, "PI_CODING_AGENT_DIR", &.{ home, ".pi/agent" });
        defer gpa.free(root);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, "auth.json" }));
    } else if (eq(u8, id, "devin")) {
        const data = try envRoot(gpa, env, "XDG_DATA_HOME", &.{ home, ".local/share" });
        defer gpa.free(data);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ data, "devin/credentials.toml" }));
        if (builtin.os.tag == .macos) try out.append(gpa, try std.fs.path.join(gpa, &.{ home, "Library/Application Support/devin/credentials.toml" }));
        if (builtin.os.tag == .windows) {
            const appdata = try envRoot(gpa, env, "APPDATA", &.{ home, "AppData/Roaming" });
            defer gpa.free(appdata);
            try out.append(gpa, try std.fs.path.join(gpa, &.{ appdata, "devin/credentials.toml" }));
        }
    }
}

fn envPrefixes(id: []const u8) []const []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, id, "codex")) return &.{ "CODEX_", "OPENAI_" };
    if (eq(u8, id, "claude-code")) return &.{ "CLAUDE_", "ANTHROPIC_", "AWS_" };
    if (eq(u8, id, "opencode")) return &.{ "OPENCODE_", "OPENAI_", "ANTHROPIC_", "GOOGLE_" };
    if (eq(u8, id, "grok")) return &.{ "GROK_", "XAI_" };
    if (eq(u8, id, "hermes")) return &.{ "HERMES_", "OPENAI_", "ANTHROPIC_" };
    if (eq(u8, id, "graff")) return &.{ "GRAFF_", "CODEGRAFF_" };
    if (eq(u8, id, "pi")) return &.{ "PI_", "OPENAI_", "ANTHROPIC_" };
    if (eq(u8, id, "devin")) return &.{"DEVIN_"};
    if (eq(u8, id, "antigravity")) return &.{ "GEMINI_", "GOOGLE_" };
    if (eq(u8, id, "cursor")) return &.{"CURSOR_"};
    return &.{};
}

/// `model_context::context(id, binary, extra)`: id is the wire id
/// (`claude-code`, `codex`, …). Read errors other than "not found" fail.
pub fn computeContext(gpa: Allocator, io: Io, id: []const u8, binary: []const u8, extra: []const []const u8, env: *const Environ.Map) !Context {
    const home = try homeOrCwd(gpa, io, env);
    defer gpa.free(home);
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try contextFiles(gpa, io, id, env, home, &files);
    const canonical: []u8 = if (Io.Dir.cwd().realPathFileAlloc(io, binary, gpa)) |z| blk: {
        defer gpa.free(z);
        break :blk try gpa.dupe(u8, z);
    } else |_| try gpa.dupe(u8, binary);
    errdefer gpa.free(canonical);
    var vbuf: [128]u8 = undefined;
    const version = harness_version.binaryVersionString(io, canonical, &vbuf);

    var h = Sha256.init(.{});
    hashField(&h, canonical);
    hashField(&h, version orelse "unknown");
    if (Io.Dir.cwd().statFile(io, canonical, .{})) |st| {
        var mbuf: [128]u8 = undefined;
        hashField(&h, modifiedDebug(&mbuf, st));
    } else |_| {}
    try hashFiles(gpa, io, &h, @ptrCast(files.items));
    try hashFiles(gpa, io, &h, extra);

    // Prefixed environment variables, sorted by (key, value).
    const prefixes = envPrefixes(id);
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = env.iterator();
    while (it.next()) |e| {
        for (prefixes) |p| if (std.mem.startsWith(u8, e.key_ptr.*, p)) {
            try keys.append(gpa, e.key_ptr.*);
            break;
        };
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (keys.items) |k| {
        hashField(&h, k);
        hashField(&h, env.get(k).?);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return .{
        .hash = std.fmt.bytesToHex(digest, .lower),
        .binary_path = canonical,
        .binary_version = if (version) |v| try gpa.dupe(u8, v) else null,
    };
}

// ── the in-memory catalog (`catalog::Catalog`) ─────────────────────────────

pub const Source = enum {
    live,
    cache,
    static,

    pub fn str(s: Source) []const u8 {
        return @tagName(s);
    }
};

/// A successful catalog: the models as their JSON array (owned by the
/// caller's allocator) and where they came from.
pub const Catalog = struct {
    models: []u8,
    source: Source,
};

pub const Result = union(enum) {
    ok: Catalog,
    err: Failure,
};

pub const KeyResult = union(enum) { ok: [32]u8, err: Failure };

/// What one discovery attempt returns: the models JSON array (owned by
/// `gpa`, possibly `[]`) or a failure.
pub const Discovered = union(enum) { ok: []u8, err: Failure };

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub const MemCache = struct {
    mutex: Io.Mutex = .init,
    context: ?[32]u8 = null,
    /// Owned by `long_gpa`.
    models: ?[]u8 = null,
    retry_at: ?i96 = null,
    err: ?Failure = null,
    completed_at: ?i96 = null,

    pub fn reset(self: *MemCache, key: ?[32]u8) void {
        if (self.models) |m| long_gpa.free(m);
        self.* = .{ .mutex = self.mutex, .context = key };
    }

    /// `cached_for(key)`: the last good catalog for `key`, without waiting.
    pub fn cachedFor(self: *MemCache, gpa: Allocator, io: Io, key: [32]u8) ?[]u8 {
        if (!self.mutex.tryLock()) return null;
        defer self.mutex.unlock(io);
        if (self.context == null or !std.mem.eql(u8, &self.context.?, &key)) return null;
        const m = self.models orelse return null;
        return gpa.dupe(u8, m) catch null;
    }

    /// Tests: let the next call refresh.
    pub fn expire(self: *MemCache, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.retry_at = null;
    }

    fn cached(self: *const MemCache, gpa: Allocator, source: Source) !Result {
        if (self.models) |m| return .{ .ok = .{ .models = try gpa.dupe(u8, m), .source = source } };
        return .{ .err = self.err orelse Failure.discoveryFailure(.failed, "Harness model catalog is unavailable; retry") };
    }

    /// `get_with_timeout(force, timeout, context, discover)`.
    /// `keyer.key()` → `KeyResult`; `discoverer.discover(gpa, io, budget_ms)`
    /// → `Discovered` (one attempt, bounded by `budget_ms`).
    pub fn getWithTimeout(self: *MemCache, gpa: Allocator, io: Io, force: bool, timeout_ms: u64, keyer: anytype, discoverer: anytype) !Result {
        const requested_at = nowNs(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const key = switch (keyer.key()) {
            .ok => |k| k,
            .err => |f| return .{ .err = f },
        };
        if (self.context == null or !std.mem.eql(u8, &self.context.?, &key)) self.reset(key);
        if ((self.completed_at != null and self.completed_at.? >= requested_at) or
            (!force and self.retry_at != null and nowNs(io) < self.retry_at.?))
        {
            return self.cached(gpa, .cache);
        }

        const started = nowNs(io);
        const deadline = started + @as(i96, timeout_ms) * std.time.ns_per_ms;
        var models: ?[]u8 = null;
        var failure = Failure.discoveryFailure(.failed, "model catalog unavailable");
        var timed_out = false;
        attempts: for (0..3) |attempt| {
            if (attempt > 0) {
                const pause: i96 = @as(i96, 250 * @as(i96, @intCast(attempt))) * std.time.ns_per_ms;
                if (nowNs(io) + pause >= deadline) {
                    timed_out = true;
                    break;
                }
                io.sleep(.fromNanoseconds(@intCast(pause)), .awake) catch {};
            }
            const remaining = deadline - nowNs(io);
            if (remaining <= 0) {
                timed_out = true;
                break;
            }
            switch (try discoverer.discover(gpa, io, @as(u64, @intCast(@divFloor(remaining, std.time.ns_per_ms))))) {
                .ok => |m| {
                    if (!isEmptyCatalog(m)) {
                        models = m;
                        break :attempts;
                    }
                    gpa.free(m);
                    failure = Failure.discoveryFailure(.failed, "Harness returned an empty model catalog");
                },
                .err => |f| failure = f.intoDiscovery(),
            }
            if (nowNs(io) >= deadline) {
                timed_out = true;
                break;
            }
            if (!failure.code.allowsStale() or needsCooldown(failure.message())) break;
        }
        if (models == null and timed_out) failure = Failure.discoveryFailure(.timeout, "Harness model discovery timed out");
        defer if (models) |m| gpa.free(m);

        // Never publish a response from a login that changed during the request.
        const after = keyer.key();
        if (after == .err or !std.mem.eql(u8, &after.ok, &key)) {
            self.reset(null);
            if (after == .err) return .{ .err = after.err };
            return .{ .err = Failure.protocol("Harness credentials changed during model discovery; retry", .{}) };
        }
        const source: Source = if (models != null) .live else .cache;
        self.completed_at = nowNs(io);
        if (models) |m| {
            const copy = try long_gpa.dupe(u8, m);
            if (self.models) |old| long_gpa.free(old);
            self.models = copy;
            self.err = null;
            self.retry_at = nowNs(io) + 60 * std.time.ns_per_s;
        } else {
            if (!failure.code.allowsStale()) {
                if (self.models) |old| long_gpa.free(old);
                self.models = null;
            }
            const cooldown: i96 = if (!failure.code.allowsStale() or needsCooldown(failure.message())) 60 else 10;
            self.err = failure;
            self.retry_at = nowNs(io) + cooldown * std.time.ns_per_s;
        }
        return self.cached(gpa, source);
    }
};

// ── the disk cache and `ListModels` (`model_catalogs.rs`) ──────────────────

pub const ContextResult = union(enum) {
    /// `None`: a live-only catalog (graff: OS keychain credentials).
    none,
    ok: Context,
    err: Failure,
};

/// One harness's discovery surface (`Harness::{model_context,
/// model_catalog, fallback_models}`).
pub const Harness = struct {
    /// Wire id: the disk cache folder.
    id: []const u8,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `model_context()`; a returned context is owned by `gpa`.
        modelContext: *const fn (ptr: *anyopaque, gpa: Allocator, io: Io) anyerror!ContextResult,
        /// `model_catalog(force)`; models owned by `gpa`.
        modelCatalog: *const fn (ptr: *anyopaque, gpa: Allocator, io: Io, force: bool) anyerror!Result,
        /// `fallback_models()` as a JSON array (`[]` when none), owned by `gpa`.
        fallbackModels: *const fn (ptr: *anyopaque, gpa: Allocator) anyerror![]u8,
    };

    pub fn modelContext(h: Harness, gpa: Allocator, io: Io) !ContextResult {
        return h.vtable.modelContext(h.ptr, gpa, io);
    }
    pub fn modelCatalog(h: Harness, gpa: Allocator, io: Io, force: bool) !Result {
        return h.vtable.modelCatalog(h.ptr, gpa, io, force);
    }
    pub fn fallbackModels(h: Harness, gpa: Allocator) ![]u8 {
        return h.vtable.fallbackModels(h.ptr, gpa);
    }
};

pub fn location(gpa: Allocator, root: []const u8, id: []const u8, ctx: *const Context) ![]u8 {
    const name = try std.fmt.allocPrint(gpa, "{s}.json", .{&ctx.hash});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ root, "model-catalogs", id, name });
}

/// `read(path, context)`: the saved catalog when schema 1, same binary
/// version and non-empty; anything else (missing, corrupt) is null.
pub fn readSaved(gpa: Allocator, io: Io, path: []const u8, ctx: *const Context) ?[]u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch return null;
    defer gpa.free(text);
    var parsed = json.parseFromSlice(json.Value, gpa, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    const schema = o.get("schema_version") orelse return null;
    if (schema != .integer or schema.integer < 0) return null;
    const fetched = o.get("fetched_at") orelse return null;
    if (fetched != .integer or fetched.integer < 0) return null;
    const saved_version: ?[]const u8 = if (o.get("binary_version")) |bv| switch (bv) {
        .null => null,
        .string => |s| s,
        else => return null,
    } else null;
    const catalog = o.get("catalog") orelse return null;
    const models = normalizeModelsJson(gpa, catalog) catch return null;
    if (schema.integer != 1 or !optEql(saved_version, ctx.binary_version) or isEmptyCatalog(models)) {
        gpa.free(models);
        return null;
    }
    return models;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// `save(path, context, models)`: empty catalogs are never written; the file
/// is staged beside its target (mode 0600), synced and renamed into place.
pub fn save(gpa: Allocator, io: Io, path: []const u8, ctx: *const Context, models: []const u8) !void {
    if (isEmptyCatalog(models)) return;
    const parent = std.fs.path.dirname(path).?;
    try Io.Dir.cwd().createDirPath(io, parent);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const fetched_at = @max(0, Io.Clock.real.now(io).toSeconds());
    try aw.writer.print("{{\"schema_version\":1,\"fetched_at\":{d},\"binary_version\":", .{fetched_at});
    if (ctx.binary_version) |v| try aw.writer.print("{f}", .{json.fmt(v, .{})}) else try aw.writer.writeAll("null");
    try aw.writer.print(",\"catalog\":{s}}}", .{models});
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    const stem = path[0 .. path.len - std.fs.path.extension(path).len];
    const staging = try std.fmt.allocPrint(gpa, "{s}.{x}.partial", .{ stem, &rnd });
    defer gpa.free(staging);
    const ok = blk: {
        const file = Io.Dir.cwd().createFile(io, staging, .{ .exclusive = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) }) catch |e| break :blk e;
        defer file.close(io);
        file.writeStreamingAll(io, aw.written()) catch |e| break :blk e;
        file.sync(io) catch |e| break :blk e;
        break :blk {};
    };
    ok catch |e| {
        Io.Dir.cwd().deleteFile(io, staging) catch {};
        return e;
    };
    Io.Dir.cwd().rename(staging, Io.Dir.cwd(), path, io) catch |e| {
        Io.Dir.cwd().deleteFile(io, staging) catch {};
        return e;
    };
}

/// The outcome of `ListModels`: the models array, or the error text the RPC
/// replies with (`RpcError::Failed(e.to_string())`).
pub const ListResult = union(enum) {
    ok: []u8,
    err: Failure,

    pub fn deinit(self: ListResult, gpa: Allocator) void {
        if (self == .ok) gpa.free(self.ok);
    }
};

fn contextUnchanged(h: Harness, gpa: Allocator, io: Io, ctx: *const Context) bool {
    var now = h.modelContext(gpa, io) catch return false;
    switch (now) {
        .ok => |*c| {
            defer c.deinit(gpa);
            return std.mem.eql(u8, &c.hash, &ctx.hash);
        },
        else => return false,
    }
}

/// The live refresh `list` starts: it runs to completion (saving or
/// retiring the disk file) even when `list` already answered from disk.
const Refresh = struct {
    harness: Harness,
    io: Io,
    force: bool,
    ctx: Context,
    path: []u8,
    done: std.atomic.Value(bool) = .init(false),
    /// 2 while both the caller and the worker hold it.
    refs: std.atomic.Value(u8) = .init(2),
    result: ?Result = null,
    /// `Err(Protocol("model discovery context changed; retry"))`.
    context_changed: bool = false,

    fn run(self: *Refresh) void {
        const gpa = long_gpa;
        const result: Result = self.harness.modelCatalog(gpa, self.io, self.force) catch |e| .{ .err = Failure.protocol("model discovery failed: {s}", .{@errorName(e)}) };
        if (!contextUnchanged(self.harness, gpa, self.io, &self.ctx)) {
            if (result == .ok) gpa.free(result.ok.models);
            self.context_changed = true;
        } else {
            switch (result) {
                .err => |f| if (!f.code.allowsStale() and self.path.len > 0) {
                    // A revoked credential must not be resurrected from disk.
                    Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
                },
                .ok => |c| {
                    const persist = c.source == .live or (c.source == .cache and blk: {
                        const on_disk = readSaved(gpa, self.io, self.path, &self.ctx);
                        defer if (on_disk) |d| gpa.free(d);
                        break :blk on_disk == null;
                    });
                    if (persist and self.path.len > 0) save(gpa, self.io, self.path, &self.ctx, c.models) catch {};
                },
            }
            self.result = result;
        }
        self.done.store(true, .release);
    }

    fn runAndRelease(self: *Refresh) void {
        self.run();
        self.release();
    }

    fn release(self: *Refresh) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = long_gpa;
        if (self.result) |r| if (r == .ok) gpa.free(r.ok.models);
        self.ctx.deinit(gpa);
        gpa.free(self.path);
        gpa.destroy(self);
    }
};

/// How long `list` waits for a live refresh when it has a disk catalog.
pub var disk_grace_ms: u64 = 100;

/// `model_catalogs::list(root, harness, force)`. `root` is the data dir
/// (null: no disk cache, as an engine without one).
pub fn list(gpa: Allocator, io: Io, root: ?[]const u8, h: Harness, force: bool) !ListResult {
    var ctx_res = try h.modelContext(gpa, io);
    var ctx = switch (ctx_res) {
        .err => |f| return .{ .err = f.intoDiscovery() },
        .none => {
            const r = try h.modelCatalog(gpa, io, force);
            return switch (r) {
                .ok => |c| .{ .ok = c.models },
                .err => |f| .{ .err = f },
            };
        },
        .ok => |*c| c,
    };
    defer ctx.deinit(gpa);
    _ = &ctx_res;

    const path: ?[]u8 = if (root) |r| try location(gpa, r, h.id, ctx) else null;
    defer if (path) |p| gpa.free(p);
    const disk: ?[]u8 = if (path) |p| readSaved(gpa, io, p, ctx) else null;
    defer if (disk) |d| gpa.free(d);

    // The refresh owns its lifetime; returning disk early must not cancel it.
    const refresh = try long_gpa.create(Refresh);
    refresh.* = .{
        .harness = h,
        .io = io,
        .force = force,
        .ctx = ctx.clone(long_gpa) catch |e| {
            long_gpa.destroy(refresh);
            return e;
        },
        .path = long_gpa.dupe(u8, path orelse "") catch |e| {
            refresh.ctx.deinit(long_gpa);
            long_gpa.destroy(refresh);
            return e;
        },
        .refs = .init(1),
    };
    var finished = false;
    if (disk != null) {
        refresh.refs.store(2, .release);
        if (std.Thread.spawn(.{}, Refresh.runAndRelease, .{refresh})) |th| {
            th.detach();
            const until = nowNs(io) + @as(i96, disk_grace_ms) * std.time.ns_per_ms;
            while (!refresh.done.load(.acquire) and nowNs(io) < until) io.sleep(.fromMilliseconds(5), .awake) catch {};
            finished = refresh.done.load(.acquire);
        } else |_| {
            refresh.refs.store(1, .release);
            refresh.run();
            finished = true;
        }
    } else {
        refresh.run();
        finished = true;
    }
    defer refresh.release();

    if (!contextUnchanged(h, gpa, io, ctx)) return .{ .err = Failure.protocol("model discovery context changed; retry", .{}) };

    if (finished and refresh.context_changed) {
        return .{ .err = Failure.protocol("model discovery context changed; retry", .{}) };
    }
    if (finished) if (refresh.result) |r| switch (r) {
        .ok => |c| if (!isEmptyCatalog(c.models)) return .{ .ok = try gpa.dupe(u8, c.models) },
        .err => |f| if (!f.code.allowsStale()) {
            // Claude intentionally offers its manifest even while logged out.
            if (std.mem.eql(u8, h.id, "claude-code") and f.code == .auth_required) {
                return .{ .ok = try h.fallbackModels(gpa) };
            }
            return .{ .err = f.intoDiscovery() };
        },
    };
    if (disk) |d| return .{ .ok = try gpa.dupe(u8, d) };
    const fallback = try h.fallbackModels(gpa);
    if (isEmptyCatalog(fallback)) {
        gpa.free(fallback);
        return .{ .err = Failure.protocol("model catalog unavailable; retry", .{}) };
    }
    return .{ .ok = fallback };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "catalog_core classify gives conservative stable codes" {
    const cases = [_]struct { []const u8, Code }{
        .{ "not logged in", .auth_required },
        .{ "Authentication failed", .auth_required },
        .{ "unauthenticated", .auth_required },
        .{ "invalid API key", .auth_required },
        .{ "HTTP 401", .auth_required },
        .{ "status: 403", .auth_required },
        .{ "spawn ENOENT", .missing_executable },
        .{ "operation timed out", .timeout },
        .{ "model v401 not found", .failed },
        .{ "rate limit 429", .failed },
    };
    for (cases) |c| try testing.expectEqual(c[1], classify(c[0]));
    try testing.expect(needsCooldown("Rate limit exceeded"));
    try testing.expect(!needsCooldown("offline"));
    var buf: [256]u8 = undefined;
    const f = Failure.protocol("not logged in", .{});
    try testing.expectEqual(Code.auth_required, f.code);
    try testing.expectEqualStrings("harness protocol error: not logged in", f.display(&buf));
    try testing.expectEqualStrings("model discovery auth_required: harness protocol error: not logged in", f.intoDiscovery().display(&buf));
    try testing.expectEqual(Code.missing_executable, Failure.ioError(.not_found, "whatever").code);
    try testing.expectEqual(Code.missing_executable, Failure.notInstalled("claude").code);
}

test "catalog_core models round-trip in serde's shape and reject what serde rejects" {
    const gpa = testing.allocator;
    const rows = [_]Model{
        .{ .id = "a", .label = "A", .reasoning_levels = &.{ "low", "high" }, .options = &.{.{ .id = "fast", .label = "Fast", .choices = &.{ .{ .id = "on", .label = "On" }, .{ .id = "off", .label = "Off" } }, .default_choice = "off" }} },
        .{ .id = "b", .label = "B", .description = "d", .maker = "openai", .billing = "plan", .context = 272000 },
    };
    const text = try modelsJson(gpa, &rows);
    defer gpa.free(text);
    try testing.expectEqualStrings(
        "[{\"id\":\"a\",\"label\":\"A\",\"reasoningLevels\":[\"low\",\"high\"],\"options\":[{\"id\":\"fast\",\"label\":\"Fast\",\"choices\":[{\"id\":\"on\",\"label\":\"On\"},{\"id\":\"off\",\"label\":\"Off\"}],\"defaultChoice\":\"off\"}]}," ++
            "{\"id\":\"b\",\"label\":\"B\",\"description\":\"d\",\"reasoningLevels\":[],\"options\":[],\"maker\":\"openai\",\"billing\":\"plan\",\"context\":272000}]",
        text,
    );
    var p = try json.parseFromSlice(json.Value, gpa, text, .{});
    defer p.deinit();
    const again = try normalizeModelsJson(gpa, p.value);
    defer gpa.free(again);
    try testing.expectEqualStrings(text, again);
    for ([_][]const u8{ "[{\"id\":\"x\"}]", "[{\"id\":\"x\",\"label\":\"X\",\"reasoningLevels\":[\"turbo\"]}]", "{}", "[{\"id\":1,\"label\":\"X\"}]" }) |bad| {
        var q = try json.parseFromSlice(json.Value, gpa, bad, .{});
        defer q.deinit();
        try testing.expectError(error.Invalid, normalizeModelsJson(gpa, q.value));
    }
    try testing.expect(isEmptyCatalog("[]"));
    try testing.expect(isEmptyCatalog(" [ ] "));
    try testing.expect(!isEmptyCatalog(text));
}

test "catalog_core context hash changes with auth files and env, never with secrets in it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base_z);
    const base: []const u8 = base_z;
    try tmp.dir.createDirPath(io, "home/.codex");
    try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = "#!/bin/sh\necho codex-cli 1.2.3\n", .flags = .{ .permissions = .executable_file } });
    const bin = try std.fs.path.join(gpa, &.{ base, "codex" });
    defer gpa.free(bin);
    const home = try std.fs.path.join(gpa, &.{ base, "home" });
    defer gpa.free(home);
    var env = Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    var c1 = try computeContext(gpa, io, "codex", bin, &.{}, &env);
    defer c1.deinit(gpa);
    try testing.expectEqualStrings("1.2.3", c1.binary_version.?);
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.codex/auth.json", .data = "account-one" });
    var c2 = try computeContext(gpa, io, "codex", bin, &.{}, &env);
    defer c2.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c1.hash, &c2.hash));
    try testing.expect(std.mem.indexOf(u8, &c2.hash, "account") == null);
    try env.put("OPENAI_API_KEY", "synthetic");
    var c3 = try computeContext(gpa, io, "codex", bin, &.{}, &env);
    defer c3.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, &c2.hash, &c3.hash));
    // Unrelated variables do not change it; removing the file restores it.
    try env.put("UNRELATED", "x");
    try tmp.dir.deleteFile(io, "home/.codex/auth.json");
    _ = env.swapRemove("OPENAI_API_KEY");
    var c4 = try computeContext(gpa, io, "codex", bin, &.{}, &env);
    defer c4.deinit(gpa);
    try testing.expectEqualSlices(u8, &c1.hash, &c4.hash);
}

/// A scripted discovery source for the cache tests.
const Script = struct {
    key_val: u8 = 1,
    /// Changes `key_val` to this during discovery when set.
    swap_to: ?u8 = null,
    calls: usize = 0,
    responses: []const Discovered = &.{},
    sleep_ms: u64 = 0,

    pub fn key(self: *Script) KeyResult {
        return .{ .ok = @splat(self.key_val) };
    }
    pub fn discover(self: *Script, gpa: Allocator, io: Io, budget_ms: u64) !Discovered {
        _ = budget_ms;
        const i = self.calls;
        self.calls += 1;
        if (self.sleep_ms > 0) io.sleep(.fromMilliseconds(@intCast(self.sleep_ms)), .awake) catch {};
        if (self.swap_to) |k| self.key_val = k;
        const r = self.responses[@min(i, self.responses.len - 1)];
        return switch (r) {
            .ok => |m| .{ .ok = try gpa.dupe(u8, m) },
            .err => |f| .{ .err = f },
        };
    }
};

const good = "[{\"id\":\"good\",\"label\":\"good\",\"reasoningLevels\":[],\"options\":[]}]";

fn expectModels(r: Result, want: []const u8, source: Source) !void {
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

test "catalog_core MemCache retries transient failures and never publishes empty catalogs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var cache: MemCache = .{};
    defer cache.reset(null);
    var s: Script = .{ .responses = &.{ .{ .err = Failure.protocol("temporary transport error", .{}) }, .{ .ok = @constCast("[]") }, .{ .ok = @constCast(good) } } };
    try expectModels(try cache.getWithTimeout(gpa, io, false, 20_000, &s, &s), good, .live);
    try testing.expectEqual(@as(usize, 3), s.calls);
    // Within the cooldown: cached, no probe.
    try expectModels(try cache.getWithTimeout(gpa, io, false, 20_000, &s, &s), good, .cache);
    try testing.expectEqual(@as(usize, 3), s.calls);
    // A forced refresh that returns empty keeps the last good catalog.
    var e: Script = .{ .responses = &.{.{ .ok = @constCast("[]") }} };
    try expectModels(try cache.getWithTimeout(gpa, io, true, 20_000, &e, &e), good, .cache);
    try testing.expectEqual(Code.failed, cache.err.?.code);
}

test "catalog_core MemCache drops the catalog on auth failure and cools down until force or a new login" {
    const gpa = testing.allocator;
    const io = testing.io;
    var cache: MemCache = .{};
    defer cache.reset(null);
    var s: Script = .{ .responses = &.{.{ .ok = @constCast(good) }} };
    try expectModels(try cache.getWithTimeout(gpa, io, false, 20_000, &s, &s), good, .live);
    var bad: Script = .{ .responses = &.{.{ .err = Failure.protocol("401 unauthorized", .{}) }} };
    const r1 = try cache.getWithTimeout(gpa, io, true, 20_000, &bad, &bad);
    try testing.expect(r1 == .err and r1.err.code == .auth_required);
    try testing.expectEqual(@as(usize, 1), bad.calls);
    const r2 = try cache.getWithTimeout(gpa, io, false, 20_000, &bad, &bad);
    try testing.expect(r2 == .err);
    try testing.expectEqual(@as(usize, 1), bad.calls);
    _ = try cache.getWithTimeout(gpa, io, true, 20_000, &bad, &bad);
    try testing.expectEqual(@as(usize, 2), bad.calls);
    bad.key_val = 2;
    _ = try cache.getWithTimeout(gpa, io, false, 20_000, &bad, &bad);
    try testing.expectEqual(@as(usize, 3), bad.calls);
}

test "catalog_core MemCache never publishes a catalog from a login that changed mid-probe" {
    const gpa = testing.allocator;
    const io = testing.io;
    var cache: MemCache = .{};
    defer cache.reset(null);
    var s: Script = .{ .key_val = 3, .swap_to = 4, .responses = &.{.{ .ok = @constCast(good) }} };
    const r = try cache.getWithTimeout(gpa, io, false, 20_000, &s, &s);
    try testing.expect(r == .err);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("harness protocol error: Harness credentials changed during model discovery; retry", r.err.display(&buf));
    try testing.expect(cache.models == null);
}

test "catalog_core MemCache bounds a hung discovery and a cold failure is not a catalog" {
    const gpa = testing.allocator;
    const io = testing.io;
    var cache: MemCache = .{};
    defer cache.reset(null);
    var s: Script = .{ .sleep_ms = 300, .responses = &.{.{ .err = Failure.protocol("offline", .{}) }} };
    const r = try cache.getWithTimeout(gpa, io, false, 200, &s, &s);
    try testing.expect(r == .err);
    try testing.expectEqual(Code.timeout, r.err.code);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("model discovery timeout: Harness model discovery timed out", r.err.display(&buf));
    try testing.expectEqual(@as(usize, 1), s.calls);
}

/// A fake harness for `list`.
const FakeHarness = struct {
    id: []const u8 = "codex",
    account: u8 = 1,
    fail: ?Failure = null,
    delay_ms: u64 = 0,
    source: Source = .live,
    models: []const u8 = good,
    swap_during: ?u8 = null,
    calls: std.atomic.Value(usize) = .init(0),

    fn harness(self: *FakeHarness) Harness {
        return .{ .id = self.id, .ptr = self, .vtable = &.{ .modelContext = ctxFn, .modelCatalog = catFn, .fallbackModels = fbFn } };
    }
    fn ctxFn(ptr: *anyopaque, gpa: Allocator, _: Io) anyerror!ContextResult {
        const self: *FakeHarness = @ptrCast(@alignCast(ptr));
        var hash: [64]u8 = @splat('0');
        hash[0] = '0' + self.account;
        return .{ .ok = .{ .hash = hash, .binary_path = try gpa.dupe(u8, "fixture"), .binary_version = try gpa.dupe(u8, "1.0.0") } };
    }
    fn catFn(ptr: *anyopaque, gpa: Allocator, io: Io, _: bool) anyerror!Result {
        const self: *FakeHarness = @ptrCast(@alignCast(ptr));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (self.delay_ms > 0) io.sleep(.fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
        if (self.swap_during) |a| self.account = a;
        if (self.fail) |f| return .{ .err = f };
        return .{ .ok = .{ .models = try gpa.dupe(u8, self.models), .source = self.source } };
    }
    fn fbFn(_: *anyopaque, gpa: Allocator) anyerror![]u8 {
        return gpa.dupe(u8, "[{\"id\":\"static\",\"label\":\"Live\",\"reasoningLevels\":[],\"options\":[]}]");
    }
};

fn expectList(r: ListResult, want: []const u8) !void {
    switch (r) {
        .ok => |m| {
            defer testing.allocator.free(m);
            try testing.expectEqualStrings(want, m);
        },
        .err => |f| {
            std.debug.print("unexpected failure: {s}\n", .{f.message()});
            return error.TestUnexpectedResult;
        },
    }
}

const static_rows = "[{\"id\":\"static\",\"label\":\"Live\",\"reasoningLevels\":[],\"options\":[]}]";

test "catalog_core list persists live catalogs and serves disk before static for the same context" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_z);
    var probe: FakeHarness = .{};
    try expectList(try list(gpa, io, root_z, probe.harness(), true), good);
    // A restarted engine whose probe fails gets the disk catalog.
    var restarted: FakeHarness = .{ .fail = Failure.protocol("offline", .{}) };
    try expectList(try list(gpa, io, root_z, restarted.harness(), false), good);
    // Another account has no disk: static rows, and nothing is written.
    restarted.account = 2;
    try expectList(try list(gpa, io, root_z, restarted.harness(), false), static_rows);
    var name: [64 + 5]u8 = undefined;
    @memset(name[0..64], '0');
    name[0] = '2';
    @memcpy(name[64..], ".json");
    const p = try std.fs.path.join(gpa, &.{ root_z, "model-catalogs", "codex", &name });
    defer gpa.free(p);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, p, .{}));
}

test "catalog_core list retires disk on auth and missing-binary failures" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_][]const u8{ "not logged in", "spawn ENOENT" }) |message| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root_z);
        var probe: FakeHarness = .{};
        try expectList(try list(gpa, io, root_z, probe.harness(), false), good);
        probe.fail = Failure.protocol("{s}", .{message});
        probe.delay_ms = 0;
        const r = try list(gpa, io, root_z, probe.harness(), true);
        try testing.expect(r == .err);
        try testing.expect(!r.err.code.allowsStale());
        // Give a background refresh a moment, then the file must be gone.
        io.sleep(.fromMilliseconds(50), .awake) catch {};
        var c = (try FakeHarness.ctxFn(&probe, gpa, io)).ok;
        defer c.deinit(gpa);
        const path = try location(gpa, root_z, "codex", &c);
        defer gpa.free(path);
        try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
    }
}

test "catalog_core list gives a logged-out Claude its curated rows instead of disk" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_z);
    var probe: FakeHarness = .{ .id = "claude-code" };
    try expectList(try list(gpa, io, root_z, probe.harness(), false), good);
    probe.fail = Failure.protocol("authentication required", .{});
    try expectList(try list(gpa, io, root_z, probe.harness(), true), static_rows);
}

test "catalog_core list saves a cache-sourced catalog only when disk is missing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_z);
    var probe: FakeHarness = .{ .source = .cache };
    try expectList(try list(gpa, io, root_z, probe.harness(), false), good);
    var c = (try FakeHarness.ctxFn(&probe, gpa, io)).ok;
    defer c.deinit(gpa);
    const path = try location(gpa, root_z, "codex", &c);
    defer gpa.free(path);
    const saved = readSaved(gpa, io, path, &c).?;
    defer gpa.free(saved);
    try testing.expectEqualStrings(good, saved);
}

test "catalog_core list answers from disk when the live probe is slow and saves it later" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_z);
    const probe = try long_gpa.create(FakeHarness);
    defer long_gpa.destroy(probe);
    probe.* = .{};
    var c = (try FakeHarness.ctxFn(probe, gpa, io)).ok;
    defer c.deinit(gpa);
    const path = try location(gpa, root_z, "codex", &c);
    defer gpa.free(path);
    const old = "[{\"id\":\"old-live\",\"label\":\"good\",\"reasoningLevels\":[],\"options\":[]}]";
    try save(gpa, io, path, &c, old);
    probe.delay_ms = 250;
    try expectList(try list(gpa, io, root_z, probe.harness(), false), old);
    io.sleep(.fromMilliseconds(400), .awake) catch {};
    const saved = readSaved(gpa, io, path, &c).?;
    defer gpa.free(saved);
    try testing.expectEqualStrings(good, saved);
}

test "catalog_core list never publishes or persists an account swapped during the probe" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_z);
    var probe: FakeHarness = .{ .swap_during = 2 };
    const r = try list(gpa, io, root_z, probe.harness(), false);
    try testing.expect(r == .err);
    const dir = try std.fs.path.join(gpa, &.{ root_z, "model-catalogs" });
    defer gpa.free(dir);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, dir, .{}));
}

test "catalog_core saved catalogs reject corrupt, empty, future and other-version files" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_z);
    const path = try std.fs.path.join(gpa, &.{ root_z, "catalog.json" });
    defer gpa.free(path);
    var c: Context = .{ .hash = @splat('a'), .binary_path = try gpa.dupe(u8, "fixture"), .binary_version = try gpa.dupe(u8, "1.0.0") };
    defer c.deinit(gpa);
    try testing.expect(readSaved(gpa, io, path, &c) == null);
    try save(gpa, io, path, &c, good);
    const back = readSaved(gpa, io, path, &c).?;
    gpa.free(back);
    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(io, path, .{});
        try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
    }
    var other = try c.clone(gpa);
    defer other.deinit(gpa);
    gpa.free(other.binary_version.?);
    other.binary_version = try gpa.dupe(u8, "2.0.0");
    try testing.expect(readSaved(gpa, io, path, &other) == null);
    for ([_][]const u8{
        "broken",
        "{\"schema_version\":2,\"fetched_at\":0,\"binary_version\":\"1.0.0\",\"catalog\":" ++ good ++ "}",
        "{\"schema_version\":1,\"fetched_at\":0,\"binary_version\":\"1.0.0\",\"catalog\":[]}",
    }) |text| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
        try testing.expect(readSaved(gpa, io, path, &c) == null);
    }
    // Empty catalogs are never written.
    const p2 = try std.fs.path.join(gpa, &.{ root_z, "empty.json" });
    defer gpa.free(p2);
    try save(gpa, io, p2, &c, "[]");
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, p2, .{}));
}
