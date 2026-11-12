//! Bounded, stateful Luau descriptions of native UI (`crates/visual`, and
//! `harness_proto::visual::validate_visual`).
//!
//! A script initializes local state and returns a zero-argument render
//! function built from `ui.column`, `row`, `text`, `stat`, `chart`, `button`,
//! `toggle`, `slider` and `rule`. Each visual has its own VM with only the
//! base, table, string, math and utf8 libraries (output, code loading and
//! environment functions removed) frozen by Luau's sandbox, a 16 MiB memory
//! budget, and 20 ms for setup, each render, and each callback plus render.
//! A rendered tree has at most 512 nodes, depth 24, 8 KiB of text and 256
//! chart values. Tables are read with raw access only, so metatables can't
//! synthesize nodes or run code while the host reads them.
const std = @import("std");
const lua = @import("luau");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_source_bytes: usize = 64 * 1024;
pub const max_memory_bytes: usize = 16 * 1024 * 1024;
pub const call_budget_ns: i96 = 20 * std.time.ns_per_ms;
pub const max_nodes: usize = 512;
pub const max_depth: usize = 24;
pub const max_text: usize = 8 * 1024;
pub const max_series: usize = 256;
pub const title_max_chars: usize = 200;

pub const msg_deadline = "visual execution exceeded 20 ms";

/// `validate_visual`: the ingress/storage bounds (title characters, script UTF-8 bytes).
pub fn validateVisual(title: []const u8, script: []const u8) ?[]const u8 {
    const ws = " \t\r\n\x0b\x0c";
    if (std.mem.trim(u8, title, ws).len == 0 or (std.unicode.utf8CountCodepoints(title) catch title.len) > title_max_chars)
        return "visual title must be nonblank and at most 200 characters";
    if (std.mem.trim(u8, script, ws).len == 0 or script.len > max_source_bytes)
        return "visual script must be nonblank and at most 64 KiB of UTF-8";
    return null;
}

pub const Kind = enum {
    column,
    row,
    text,
    stat,
    chart,
    button,
    toggle,
    slider,
    rule,

    fn allowed(k: Kind) []const []const u8 {
        return switch (k) {
            .column, .row, .rule => &.{},
            .text => &.{"text"},
            .stat => &.{ "label", "value" },
            .chart => &.{ "label", "values", "labels" },
            .button => &.{ "label", "onClick" },
            .toggle => &.{ "label", "value", "onChange" },
            .slider => &.{ "label", "value", "min", "max", "onChange" },
        };
    }
};

const kind_names = [_][:0]const u8{ "column", "row", "text", "stat", "chart", "button", "toggle", "slider", "rule" };

pub const Node = struct {
    kind: Kind,
    text: []const u8 = "",
    children: []Node = &.{},
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 1,
    values: []f64 = &.{},
    labels: [][]const u8 = &.{},
    handler: ?u64 = null,

    /// serde's shape of `harness_visual::Node`.
    pub fn writeJson(n: Node, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{{\"kind\":\"{s}\",\"text\":{f},\"children\":[", .{ @tagName(n.kind), std.json.fmt(n.text, .{}) });
        for (n.children, 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try c.writeJson(w);
        }
        try w.print("],\"value\":{d},\"min\":{d},\"max\":{d},\"values\":[", .{ n.value, n.min, n.max });
        for (n.values, 0..) |v, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", v });
        try w.writeAll("],\"labels\":[");
        for (n.labels, 0..) |l, i| try w.print("{s}{f}", .{ if (i == 0) "" else ",", std.json.fmt(l, .{}) });
        if (n.handler) |h| try w.print("],\"handler\":{d}}}", .{h}) else try w.writeAll("],\"handler\":null}");
    }
};

pub const Input = union(enum) { click, number: f64, boolean: bool };

const Expected = union(enum) { click, boolean, number: struct { min: f64, max: f64 } };

const Handler = struct { id: u64, ref: c_int, expected: Expected };

/// Per-VM bookkeeping reachable from Luau's allocator and interrupt.
const Ctx = struct {
    io: Io,
    used: usize = 0,
    limit: usize = max_memory_bytes,
    armed: bool = false,
    start_ns: i96 = 0,

    fn now(c: *const Ctx) i96 {
        return Io.Clock.awake.now(c.io).nanoseconds;
    }

    fn arm(c: *Ctx) void {
        c.start_ns = c.now();
        c.armed = true;
    }

    fn expired(c: *const Ctx) bool {
        return c.now() - c.start_ns >= call_budget_ns;
    }
};

fn allocFn(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const ctx: *Ctx = @ptrCast(@alignCast(ud.?));
    const old: usize = if (ptr == null) 0 else osize;
    if (nsize == 0) {
        if (ptr != null) {
            lua.free(ptr);
            ctx.used -|= old;
        }
        return null;
    }
    if (nsize > old and ctx.used - old + nsize > ctx.limit) return null;
    const p = lua.realloc(ptr, nsize) orelse return null;
    ctx.used = ctx.used - old + nsize;
    return p;
}

fn interruptFn(L: *lua.State, gc: c_int) callconv(.c) void {
    // GC steps can't survive an error; only VM safepoints stop a script.
    if (gc >= 0) return;
    const ctx: *Ctx = @ptrCast(@alignCast(lua.lua_callbacks(L).userdata.?));
    if (ctx.armed and ctx.expired()) raise(L, msg_deadline);
}

fn raise(L: *lua.State, msg: []const u8) noreturn {
    lua.lua_pushlstring(L, msg.ptr, msg.len);
    lua.lua_error(L);
}

// ---------------------------------------------------------------- shared table rules

/// mlua's view of a number key or value: integral and within i64 is an Integer.
fn asInteger(n: f64) ?i64 {
    if (!std.math.isFinite(n) or @floor(n) != n) return null;
    if (n < -9.223372036854775808e18 or n >= 9.223372036854775808e18) return null;
    return @intFromFloat(n);
}

/// `properties`: only the kind's own fields (and, from a constructor's output, `__kind`).
fn propertiesError(L: *lua.State, idx: c_int, kind: Kind, tagged: bool) ?[]const u8 {
    const top = lua.lua_gettop(L);
    defer lua.lua_settop(L, top);
    if (lua.lua_checkstack(L, 4) == 0) return "visual stack exhausted";
    lua.lua_pushnil(L);
    var count: usize = 0;
    while (lua.lua_next(L, idx) != 0) : (count += 1) {
        if (count > max_nodes + 8) return "too many visual properties";
        const valid = switch (lua.lua_type(L, -2)) {
            lua.T.NUMBER => blk: {
                const i = asInteger(lua.lua_tonumberx(L, -2, null)) orelse break :blk false;
                break :blk (kind == .column or kind == .row) and i > 0 and i <= max_nodes;
            },
            lua.T.STRING => blk: {
                const name = lua.tostring(L, -2).?;
                if (tagged and std.mem.eql(u8, name, "__kind")) break :blk true;
                for (kind.allowed()) |a| if (std.mem.eql(u8, a, name)) break :blk true;
                break :blk false;
            },
            else => false,
        };
        if (!valid) return "unsupported visual property (styling is not supported)";
        lua.pop(L, 1);
    }
    return null;
}

fn constructor(L: *lua.State) callconv(.c) c_int {
    const k: usize = @intFromFloat(lua.lua_tonumberx(L, lua.upvalueindex(1), null));
    const kind: Kind = @enumFromInt(k);
    const t = lua.lua_type(L, 1);
    if (t == lua.T.STRING and kind == .text) {
        lua.lua_createtable(L, 0, 2);
        lua.lua_pushvalue(L, 1);
        lua.lua_rawsetfield(L, -2, "text");
    } else if (t == lua.T.TABLE) {
        lua.lua_pushvalue(L, 1);
    } else {
        raise(L, "visual constructors require a property table (or a text string)");
    }
    const top = lua.lua_gettop(L);
    if (propertiesError(L, top, kind, false)) |m| raise(L, m);
    lua.lua_pushstring(L, kind_names[k].ptr);
    lua.lua_rawsetfield(L, top, "__kind");
    lua.lua_settop(L, top);
    return 1;
}

fn openLib(L: *lua.State, f: lua.CFunction, name: [*:0]const u8) void {
    lua.pushcfunction(L, f, null);
    lua.lua_pushstring(L, name);
    lua.lua_call(L, 1, 0);
}

/// Libraries, removed globals and `ui`, then the sandbox (run under `lua_cpcall`).
fn setupLibraries(L: *lua.State) callconv(.c) c_int {
    openLib(L, lua.luaopen_base, "");
    openLib(L, lua.luaopen_table, "table");
    openLib(L, lua.luaopen_string, "string");
    openLib(L, lua.luaopen_math, "math");
    openLib(L, lua.luaopen_utf8, "utf8");
    // Base functions otherwise include output, environment mutation and code loading.
    // pcall/xpcall stay: the interrupt keeps firing even if script code catches it.
    for ([_][*:0]const u8{ "print", "warn", "require", "load", "loadstring", "loadfile", "dofile", "collectgarbage", "getfenv", "setfenv", "newproxy" }) |name| {
        lua.lua_pushnil(L);
        lua.lua_rawsetfield(L, lua.GLOBALSINDEX, name);
    }
    lua.lua_createtable(L, 0, kind_names.len);
    for (kind_names, 0..) |name, i| {
        lua.lua_pushnumber(L, @floatFromInt(i));
        lua.lua_pushcclosurek(L, constructor, name.ptr, 1, null);
        lua.lua_rawsetfield(L, -2, name.ptr);
    }
    lua.lua_setreadonly(L, -1, 1);
    lua.lua_rawsetfield(L, lua.GLOBALSINDEX, "ui");
    lua.luaL_sandbox(L);
    lua.luaL_sandboxthread(L);
    return 0;
}

const Load = struct { bytecode: [*]const u8, size: usize, ref: c_int = 0 };

/// Load and run the chunk; keep the render function it returns (under `lua_cpcall`).
fn loadAndRun(L: *lua.State) callconv(.c) c_int {
    const ld: *Load = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    if (lua.luau_load(L, "=visual", ld.bytecode, ld.size, 0) != 0) lua.lua_error(L);
    lua.lua_call(L, 0, 1);
    if (lua.lua_type(L, -1) != lua.T.FUNCTION) raise(L, "visual script must return a render function");
    ld.ref = lua.lua_ref(L, -1);
    return 0;
}

pub const Visual = struct {
    gpa: Allocator,
    ctx: *Ctx,
    L: *lua.State,
    renderer: c_int,
    handlers: std.ArrayList(Handler) = .empty,
    next_id: u64 = 1,
    tree: std.heap.ArenaAllocator,
    /// Why the last call failed.
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    pub fn errorText(v: *const Visual) []const u8 {
        return v.err_buf[0..v.err_len];
    }

    fn fail(v: *Visual, msg: []const u8) error{Visual} {
        v.err_len = @min(msg.len, v.err_buf.len);
        @memcpy(v.err_buf[0..v.err_len], msg[0..v.err_len]);
        return error.Visual;
    }

    /// The Luau error message on the stack top (then popped).
    fn failLua(v: *Visual) error{Visual} {
        const msg = lua.tostring(v.L, -1) orelse "visual script error";
        const e = v.fail(msg);
        lua.pop(v.L, 1);
        return e;
    }

    /// Set up a visual: run the script's setup (bounded) and keep its render
    /// function. On failure, `err` (at least 256 bytes) receives the reason.
    pub fn init(gpa: Allocator, io: Io, script: []const u8, err: []u8) !*Visual {
        const say = struct {
            fn f(out: []u8, msg: []const u8) []const u8 {
                const n = @min(out.len, msg.len);
                @memcpy(out[0..n], msg[0..n]);
                return out[0..n];
            }
        }.f;
        if (script.len > max_source_bytes) {
            _ = say(err, "visual source exceeds 64 KiB");
            return error.Visual;
        }
        const ctx = try gpa.create(Ctx);
        errdefer gpa.destroy(ctx);
        ctx.* = .{ .io = io };
        const L = lua.lua_newstate(allocFn, ctx) orelse {
            _ = say(err, "not enough memory");
            return error.Visual;
        };
        errdefer lua.lua_close(L);
        const v = try gpa.create(Visual);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .ctx = ctx, .L = L, .renderer = 0, .tree = .init(gpa) };
        errdefer v.tree.deinit();
        const cb = lua.lua_callbacks(L);
        cb.userdata = ctx;
        cb.interrupt = interruptFn;
        if (lua.lua_cpcall(L, setupLibraries, null) != lua.OK) {
            _ = say(err, lua.tostring(L, -1) orelse "visual setup failed");
            return error.Visual;
        }

        ctx.arm();
        var size: usize = 0;
        const bytecode = lua.luau_compile(script.ptr, script.len, null, &size) orelse {
            ctx.armed = false;
            _ = say(err, "not enough memory");
            return error.Visual;
        };
        defer lua.free(bytecode);
        var ld: Load = .{ .bytecode = bytecode, .size = size };
        const status = lua.lua_cpcall(L, loadAndRun, &ld);
        ctx.armed = false;
        // The host-side deadline also covers compilation and native calls.
        if (ctx.expired()) {
            _ = say(err, msg_deadline);
            return error.Visual;
        }
        if (status != lua.OK) {
            _ = say(err, lua.tostring(L, -1) orelse "visual script error");
            return error.Visual;
        }
        v.renderer = ld.ref;
        return v;
    }

    pub fn deinit(v: *Visual) void {
        lua.lua_close(v.L);
        v.handlers.deinit(v.gpa);
        v.tree.deinit();
        v.gpa.destroy(v.ctx);
        v.gpa.destroy(v);
    }

    pub fn render(v: *Visual) !*const Node {
        return v.execute(null);
    }

    /// Run one handler with its input, then render again.
    pub fn call(v: *Visual, handler: u64, input: Input) !*const Node {
        var found: ?Handler = null;
        for (v.handlers.items) |h| {
            if (h.id == handler) found = h;
        }
        const h = found orelse return v.fail("unknown or stale visual handler");
        const valid = switch (h.expected) {
            .click => input == .click,
            .boolean => input == .boolean,
            .number => |r| input == .number and std.math.isFinite(input.number) and input.number >= r.min and input.number <= r.max,
        };
        if (!valid) return v.fail("visual handler input has the wrong type or is outside its range");
        return v.execute(.{ .ref = h.ref, .input = input });
    }

    fn dropHandlers(v: *Visual, list: *std.ArrayList(Handler)) void {
        for (list.items) |h| _ = lua.lua_unref(v.L, h.ref);
        list.clearRetainingCapacity();
    }

    fn execute(v: *Visual, event: ?struct { ref: c_int, input: Input }) !*const Node {
        const L = v.L;
        if (lua.lua_checkstack(L, 4) == 0) return v.fail("visual stack exhausted");
        // The handler's function first: its reference goes with the others.
        if (event) |e| _ = lua.getref(L, e.ref);
        // Invalidate even on failure: a UI must never keep callbacks of a failed render.
        v.dropHandlers(&v.handlers);
        v.ctx.arm();
        defer v.ctx.armed = false;
        if (event) |e| {
            switch (e.input) {
                .click => {},
                .boolean => |b| lua.lua_pushboolean(L, @intFromBool(b)),
                .number => |n| lua.lua_pushnumber(L, n),
            }
            const nargs: c_int = if (e.input == .click) 0 else 1;
            if (lua.lua_pcall(L, nargs, 0, 0) != lua.OK) return v.failLua();
            if (v.ctx.expired()) return v.fail(msg_deadline);
        }
        _ = lua.getref(L, v.renderer);
        if (lua.lua_pcall(L, 0, 1, 0) != lua.OK) return v.failLua();
        if (v.ctx.expired()) {
            lua.pop(L, 1);
            return v.fail(msg_deadline);
        }
        const value_ref = lua.lua_ref(L, -1);
        lua.pop(L, 1);
        defer _ = lua.lua_unref(L, value_ref);

        _ = v.tree.reset(.retain_capacity);
        var p: Parser = .{ .v = v, .a = v.tree.allocator(), .value_ref = value_ref };
        const status = lua.lua_cpcall(L, Parser.run, &p);
        if (status != lua.OK) {
            v.dropHandlers(&p.handlers);
            p.handlers.deinit(v.gpa);
            return v.failLua();
        }
        if (p.err) |m| {
            v.dropHandlers(&p.handlers);
            p.handlers.deinit(v.gpa);
            return v.fail(m);
        }
        if (v.ctx.expired()) {
            v.dropHandlers(&p.handlers);
            p.handlers.deinit(v.gpa);
            return v.fail(msg_deadline);
        }
        v.handlers.deinit(v.gpa);
        v.handlers = p.handlers;
        return p.root.?;
    }
};

/// Validate setup and the first rendered tree; null when it passes, else why
/// not. This does not run event handlers.
pub fn check(gpa: Allocator, io: Io, script: []const u8, err: *[256]u8) ?[]const u8 {
    var buf: [256]u8 = @splat(0);
    const v = Visual.init(gpa, io, script, &buf) catch {
        const n = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
        @memcpy(err[0..n], buf[0..n]);
        return err[0..n];
    };
    defer v.deinit();
    _ = v.render() catch {
        const m = v.errorText();
        @memcpy(err[0..m.len], m);
        return err[0..m.len];
    };
    return null;
}

/// The rendered value to a `Node` tree, with the crate's bounds. Runs under
/// `lua_cpcall`; a Luau error (memory) unwinds past it, so everything it
/// allocates lives in the tree arena or in `handlers`, freed by the caller.
const Parser = struct {
    v: *Visual,
    a: Allocator,
    value_ref: c_int,
    nodes: usize = 0,
    text_bytes: usize = 0,
    series: usize = 0,
    handlers: std.ArrayList(Handler) = .empty,
    root: ?*Node = null,
    err: ?[]const u8 = null,

    fn run(L: *lua.State) callconv(.c) c_int {
        const p: *Parser = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
        _ = lua.getref(L, p.value_ref);
        const root = p.a.create(Node) catch {
            p.err = "not enough memory";
            return 0;
        };
        root.* = p.parse(L, 1) catch |e| {
            if (p.err == null) p.err = if (e == error.OutOfMemory) "not enough memory" else "visual parse failed";
            return 0;
        };
        p.root = root;
        return 0;
    }

    fn bail(p: *Parser, msg: []const u8) error{Invalid} {
        if (p.err == null) p.err = msg;
        return error.Invalid;
    }

    fn deadline(p: *Parser) !void {
        if (p.v.ctx.expired()) return p.bail(msg_deadline);
    }

    /// The value on the stack top as text (string, or a finite number).
    fn text(p: *Parser, L: *lua.State) ![]const u8 {
        const s: []const u8 = switch (lua.lua_type(L, -1)) {
            lua.T.STRING => blk: {
                const raw = lua.tostring(L, -1).?;
                if (raw.len > max_text) return p.bail("visual text exceeds 8 KiB");
                if (!std.unicode.utf8ValidateSlice(raw)) return p.bail("visual text is not valid UTF-8");
                break :blk try p.a.dupe(u8, raw);
            },
            lua.T.NUMBER => blk: {
                const n = lua.lua_tonumberx(L, -1, null);
                if (asInteger(n)) |i| break :blk try std.fmt.allocPrint(p.a, "{d}", .{i});
                if (!std.math.isFinite(n)) return p.bail("expected visual text or a finite number");
                break :blk try std.fmt.allocPrint(p.a, "{d}", .{n});
            },
            else => return p.bail("expected visual text or a finite number"),
        };
        p.text_bytes += s.len;
        if (p.text_bytes > max_text) return p.bail("visual text exceeds 8 KiB");
        return s;
    }

    fn field(L: *lua.State, idx: c_int, name: [*:0]const u8) c_int {
        return lua.lua_rawgetfield(L, idx, name);
    }

    fn label(p: *Parser, L: *lua.State, idx: c_int) ![]const u8 {
        defer lua.pop(L, 1);
        if (field(L, idx, "label") == lua.T.NIL) return "";
        return p.text(L);
    }

    fn number(p: *Parser, L: *lua.State) !f64 {
        if (lua.lua_type(L, -1) != lua.T.NUMBER) return p.bail("expected a finite number");
        const n = lua.lua_tonumberx(L, -1, null);
        if (!std.math.isFinite(n)) return p.bail("expected a finite number");
        return n;
    }

    fn numberField(p: *Parser, L: *lua.State, idx: c_int, name: [*:0]const u8) !f64 {
        _ = field(L, idx, name);
        defer lua.pop(L, 1);
        return p.number(L);
    }

    fn handler(p: *Parser, L: *lua.State, idx: c_int, name: [*:0]const u8, expected: Expected) !?u64 {
        const t = field(L, idx, name);
        defer lua.pop(L, 1);
        if (t == lua.T.NIL) return null;
        if (t != lua.T.FUNCTION) return p.bail("visual handler must be a function");
        const id = p.v.next_id;
        p.v.next_id = std.math.add(u64, id, 1) catch return p.bail("visual handler ids exhausted");
        try p.handlers.ensureUnusedCapacity(p.v.gpa, 1);
        p.handlers.appendAssumeCapacity(.{ .id = id, .ref = lua.lua_ref(L, -1), .expected = expected });
        return id;
    }

    fn arrayLength(p: *Parser, L: *lua.State, idx: c_int, limit: usize, tagged: bool) !usize {
        const len: usize = @intCast(@max(0, lua.lua_objlen(L, idx)));
        if (len > limit) return p.bail("visual array exceeds its size limit");
        const top = lua.lua_gettop(L);
        defer lua.lua_settop(L, top);
        lua.lua_pushnil(L);
        var count: usize = 0;
        while (lua.lua_next(L, idx) != 0) {
            lua.pop(L, 1);
            if (tagged and lua.lua_type(L, -1) == lua.T.STRING and std.mem.eql(u8, lua.tostring(L, -1).?, "__kind")) continue;
            const ok = lua.lua_type(L, -1) == lua.T.NUMBER and if (asInteger(lua.lua_tonumberx(L, -1, null))) |i| i > 0 and i <= len else false;
            if (!ok) return p.bail("visual arrays must be dense, with no extra properties");
            count += 1;
            if (count > limit) return p.bail("visual array exceeds its size limit");
        }
        if (count != len) return p.bail("visual arrays must be dense");
        return len;
    }

    fn requiredTable(p: *Parser, L: *lua.State) !void {
        if (lua.lua_type(L, -1) != lua.T.TABLE) return p.bail("expected an array table");
    }

    /// The node on the stack top (left there).
    fn parse(p: *Parser, L: *lua.State, depth: usize) !Node {
        try p.deadline();
        p.nodes += 1;
        if (depth > max_depth) return p.bail("visual depth exceeds 24");
        if (p.nodes > max_nodes) return p.bail("visual node count exceeds 512");
        if (lua.lua_type(L, -1) != lua.T.TABLE) return p.bail("expected a ui node");
        if (lua.lua_checkstack(L, 8) == 0) return p.bail("visual stack exhausted");
        const idx = lua.lua_gettop(L);
        const kind: Kind = blk: {
            defer lua.pop(L, 1);
            if (field(L, idx, "__kind") != lua.T.STRING) return p.bail("expected a ui node kind");
            const name = lua.tostring(L, -1).?;
            for (kind_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) break :blk @enumFromInt(i);
            return p.bail("unsupported visual node kind");
        };
        if (propertiesError(L, idx, kind, true)) |m| return p.bail(m);
        var node: Node = .{ .kind = kind };
        switch (kind) {
            .column, .row => {
                const len = try p.arrayLength(L, idx, max_nodes, true);
                const children = try p.a.alloc(Node, len);
                for (0..len) |i| {
                    _ = lua.lua_rawgeti(L, idx, @intCast(i + 1));
                    defer lua.pop(L, 1);
                    children[i] = try p.parse(L, depth + 1);
                }
                node.children = children;
            },
            .text => {
                _ = field(L, idx, "text");
                defer lua.pop(L, 1);
                node.text = try p.text(L);
            },
            .stat => {
                const lbl = try p.label(L, idx);
                _ = field(L, idx, "value");
                const value = blk: {
                    defer lua.pop(L, 1);
                    break :blk try p.text(L);
                };
                if (lbl.len > 0) p.text_bytes += 2;
                if (p.text_bytes > max_text) return p.bail("visual text exceeds 8 KiB");
                node.text = if (lbl.len == 0) value else try std.fmt.allocPrint(p.a, "{s}: {s}", .{ lbl, value });
            },
            .chart => {
                node.text = try p.label(L, idx);
                _ = field(L, idx, "values");
                defer lua.pop(L, 1);
                try p.requiredTable(L);
                const values_idx = lua.lua_gettop(L);
                const len = try p.arrayLength(L, values_idx, max_series, false);
                p.series += len;
                if (p.series > max_series) return p.bail("visual series exceeds 256 values");
                const values = try p.a.alloc(f64, len);
                for (0..len) |i| {
                    _ = lua.lua_rawgeti(L, values_idx, @intCast(i + 1));
                    defer lua.pop(L, 1);
                    values[i] = try p.number(L);
                }
                node.values = values;
                if (field(L, idx, "labels") != lua.T.NIL) {
                    defer lua.pop(L, 1);
                    try p.requiredTable(L);
                    const labels_idx = lua.lua_gettop(L);
                    if (try p.arrayLength(L, labels_idx, max_series, false) != len) return p.bail("chart labels must match its values");
                    const labels = try p.a.alloc([]const u8, len);
                    for (0..len) |i| {
                        _ = lua.lua_rawgeti(L, labels_idx, @intCast(i + 1));
                        defer lua.pop(L, 1);
                        labels[i] = try p.text(L);
                    }
                    node.labels = labels;
                } else lua.pop(L, 1);
            },
            .button => {
                node.text = try p.label(L, idx);
                node.handler = try p.handler(L, idx, "onClick", .click);
            },
            .toggle => {
                node.text = try p.label(L, idx);
                const t = field(L, idx, "value");
                const b = lua.lua_toboolean(L, -1) != 0;
                lua.pop(L, 1);
                if (t != lua.T.BOOLEAN) return p.bail("toggle value must be a boolean");
                node.value = if (b) 1 else 0;
                node.handler = try p.handler(L, idx, "onChange", .boolean);
            },
            .slider => {
                node.text = try p.label(L, idx);
                node.min = try p.numberField(L, idx, "min");
                node.max = try p.numberField(L, idx, "max");
                node.value = try p.numberField(L, idx, "value");
                if (node.min > node.max or node.value < node.min or node.value > node.max) return p.bail("invalid slider range or value");
                node.handler = try p.handler(L, idx, "onChange", .{ .number = .{ .min = node.min, .max = node.max } });
            },
            .rule => {},
        }
        return node;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectCheck(script: []const u8, want: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    const got = check(testing.allocator, testing.io, script, &buf);
    if (want) |w| {
        const g = got orelse {
            std.debug.print("expected failure containing \"{s}\", it passed\n", .{w});
            return error.TestExpectedFailure;
        };
        if (std.mem.indexOf(u8, g, w) == null) {
            std.debug.print("expected \"{s}\", got \"{s}\"\n", .{ w, g });
            return error.TestUnexpectedError;
        }
    } else if (got) |g| {
        std.debug.print("unexpected failure: {s}\n", .{g});
        return error.TestUnexpectedError;
    }
}

const dashboard =
    \\local traffic = 50
    \\local efficient = false
    \\local saved = 0
    \\return function()
    \\    return ui.column{
    \\        ui.text('Illustrative capacity scenario'),
    \\        ui.stat{label='Peak', value=traffic * 2},
    \\        ui.chart{label='Requests per second', values={traffic, traffic * 1.5, traffic * 2}, labels={'Current', 'Growth', 'Peak'}},
    \\        ui.row{ ui.toggle{label='Efficiency mode', value=efficient, onChange=function(v) efficient = v end}, ui.rule{} },
    \\        ui.slider{label='Baseline', value=traffic, min=1, max=100, onChange=function(v) traffic = v end},
    \\        ui.button{label='Save scenario', onClick=function() saved = saved + 1 end},
    \\        ui.text{text=saved},
    \\    }
    \\end
;

test "a visual renders native nodes and its handlers change local state" {
    var err: [256]u8 = undefined;
    const v = try Visual.init(testing.allocator, testing.io, dashboard, &err);
    defer v.deinit();
    const tree = try v.render();
    try testing.expectEqual(Kind.column, tree.kind);
    try testing.expectEqual(@as(usize, 7), tree.children.len);
    try testing.expectEqualStrings("Peak: 100", tree.children[1].text);
    try testing.expectEqualSlices(f64, &.{ 50, 75, 100 }, tree.children[2].values);
    try testing.expectEqualStrings("Growth", tree.children[2].labels[1]);
    const slider = tree.children[4];
    try testing.expectEqual(Kind.slider, slider.kind);
    const toggle_id = tree.children[3].children[0].handler.?;
    const slider_id = slider.handler.?;
    try testing.expect(toggle_id != slider_id);

    const after = try v.call(slider_id, .{ .number = 80 });
    try testing.expectEqualSlices(f64, &.{ 80, 120, 160 }, after.children[2].values);
    // Handler ids belong to the latest render only.
    try testing.expectError(error.Visual, v.call(slider_id, .{ .number = 10 }));
    try testing.expectEqualStrings("unknown or stale visual handler", v.errorText());
    const fresh = try v.render();
    const button = fresh.children[5].handler.?;
    try testing.expectError(error.Visual, v.call(button, .{ .number = 1 }));
    try testing.expectEqualStrings("visual handler input has the wrong type or is outside its range", v.errorText());
    const t2 = try v.render();
    try testing.expectError(error.Visual, v.call(t2.children[4].handler.?, .{ .number = 101 }));
    const t3 = try v.render();
    const clicked = try v.call(t3.children[5].handler.?, .click);
    try testing.expectEqualStrings("1", clicked.children[6].text);

    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try clicked.children[2].writeJson(&aw.writer);
    try testing.expectEqualStrings("{\"kind\":\"chart\",\"text\":\"Requests per second\",\"children\":[],\"value\":0,\"min\":0,\"max\":1,\"values\":[80,120,160],\"labels\":[\"Current\",\"Growth\",\"Peak\"],\"handler\":null}", aw.written());
}

test "visual limits: source size, memory and time" {
    const big: [max_source_bytes + 1]u8 = @splat(' ');
    try expectCheck(&big, "visual source exceeds 64 KiB");
    try expectCheck("local s = string.rep('x', 17 * 1024 * 1024) return function() return ui.text('x') end", "not enough memory");
    try expectCheck("while true do end", msg_deadline);
    try expectCheck("return function() while true do end end", msg_deadline);
    // Catching the deadline doesn't escape it.
    try expectCheck("return function() pcall(function() while true do end end) while true do end end", msg_deadline);
}

test "visual limits: nodes, depth, text and chart values" {
    try expectCheck("local c = {} for i = 1, 511 do c[i] = ui.rule{} end return function() return ui.column(c) end", null);
    try expectCheck("local c = {} for i = 1, 512 do c[i] = ui.rule{} end return function() return ui.column(c) end", "visual node count exceeds 512");
    try expectCheck("return function() local n = ui.rule{} for i = 1, 23 do n = ui.column{n} end return n end", null);
    try expectCheck("return function() local n = ui.rule{} for i = 1, 24 do n = ui.column{n} end return n end", "visual depth exceeds 24");
    try expectCheck("return function() return ui.text(string.rep('a', 8192)) end", null);
    try expectCheck("return function() return ui.text(string.rep('a', 8193)) end", "visual text exceeds 8 KiB");
    try expectCheck("return function() return ui.column{ ui.text(string.rep('a', 5000)), ui.stat{label='x', value=string.rep('b', 3200)} } end", "visual text exceeds 8 KiB");
    try expectCheck("local v = {} for i = 1, 256 do v[i] = i end return function() return ui.chart{values=v} end", null);
    try expectCheck("local v = {} for i = 1, 257 do v[i] = i end return function() return ui.chart{values=v} end", "visual array exceeds its size limit");
    try expectCheck("local v = {} for i = 1, 200 do v[i] = i end return function() return ui.column{ ui.chart{values=v}, ui.chart{values=v} } end", "visual series exceeds 256 values");
    try expectCheck("return function() return ui.chart{values={1, 0/0}} end", "expected a finite number");
}

test "visual scripts get no styling, no holes and no host access" {
    try expectCheck("return function() return ui.text{text='a', color='red'} end", "unsupported visual property (styling is not supported)");
    try expectCheck("return function() return ui.column{ [1] = ui.rule{}, [3] = ui.rule{} } end", "visual arrays must be dense");
    try expectCheck("return function() return ui.chart{values={1, 2}, labels={'a'}} end", "chart labels must match its values");
    try expectCheck("return function() return ui.slider{value=5, min=10, max=0} end", "invalid slider range or value");
    try expectCheck("return function() return ui.toggle{value=1} end", "toggle value must be a boolean");
    try expectCheck("return function() return ui.button{onClick=3} end", "visual handler must be a function");
    try expectCheck("return function() return ui.widget{} end", "attempt to call a nil value");
    try expectCheck("return function() return { __kind = 'text', text = 'forged' } end", null);
    try expectCheck("return function() return setmetatable({}, { __index = function() return 'text' end }) end", "expected a ui node kind");
    try expectCheck("return function() return 3 end", "expected a ui node");
    try expectCheck("return 3", "visual script must return a render function");
    try expectCheck("return function( end", "visual");
    for ([_][]const u8{ "print('x')", "require('x')", "load('return 1')", "loadstring('return 1')", "getfenv()", "setfenv(1, {})", "newproxy()", "collectgarbage()", "os.exit()", "io.open('x')", "debug.traceback()", "coroutine.create(print)" }) |call| {
        var script: [128]u8 = undefined;
        try expectCheck(try std.fmt.bufPrint(&script, "{s} return function() return ui.rule{{}} end", .{call}), "attempt to");
    }
    // Libraries and `ui` are frozen.
    try expectCheck("string.upper = nil return function() return ui.rule{} end", "readonly");
    try expectCheck("ui.text = nil return function() return ui.rule{} end", "readonly");
}

test "visual title and script bounds" {
    const t200: [200 * 3]u8 = blk: {
        var b: [600]u8 = undefined;
        for (0..200) |i| @memcpy(b[i * 3 ..][0..3], "\u{754c}");
        break :blk b;
    };
    try testing.expect(validateVisual(&t200, "x") == null);
    try testing.expectEqualStrings("visual title must be nonblank and at most 200 characters", validateVisual(&t200 ++ "x", "x").?);
    try testing.expectEqualStrings("visual title must be nonblank and at most 200 characters", validateVisual(" \n", "x").?);
    try testing.expectEqualStrings("visual script must be nonblank and at most 64 KiB of UTF-8", validateVisual("t", " \n\t").?);
    const s: [max_source_bytes + 1]u8 = @splat('x');
    try testing.expectEqualStrings("visual script must be nonblank and at most 64 KiB of UTF-8", validateVisual("t", &s).?);
}
