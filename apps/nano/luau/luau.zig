//! The part of Luau's C API (`lua.h`, `lualib.h`, `luacode.h`, Luau 0.746)
//! the visual sandbox uses. Built by `luau_build.zig`.
pub const State = opaque {};
pub const CFunction = *const fn (L: *State) callconv(.c) c_int;
pub const Continuation = *const fn (L: *State, status: c_int) callconv(.c) c_int;
pub const Alloc = *const fn (ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque;

pub const OK: c_int = 0;
pub const MULTRET: c_int = -1;
/// `-LUAI_MAXCSTACK - 2000` and `- 2002` with `LUAI_MAXCSTACK = 8000`.
pub const REGISTRYINDEX: c_int = -10000;
pub const GLOBALSINDEX: c_int = -10002;
pub fn upvalueindex(i: c_int) c_int {
    return GLOBALSINDEX - i;
}

/// `enum lua_Type` with float vectors (`LUA_VECTOR_DOUBLE == 0`).
pub const T = struct {
    pub const NIL: c_int = 0;
    pub const BOOLEAN: c_int = 1;
    pub const LIGHTUSERDATA: c_int = 2;
    pub const NUMBER: c_int = 3;
    pub const INTEGER: c_int = 4;
    pub const VECTOR: c_int = 5;
    pub const STRING: c_int = 6;
    pub const TABLE: c_int = 7;
    pub const FUNCTION: c_int = 8;
};

pub const Callbacks = extern struct {
    userdata: ?*anyopaque,
    interrupt: ?*const fn (L: *State, gc: c_int) callconv(.c) void,
    panic: ?*const fn (L: *State, errcode: c_int) callconv(.c) void,
    // Further members are never touched from Zig.
};

pub extern fn lua_newstate(f: Alloc, ud: ?*anyopaque) ?*State;
pub extern fn lua_close(L: *State) void;
pub extern fn lua_callbacks(L: *State) *Callbacks;
pub extern fn lua_gettop(L: *State) c_int;
pub extern fn lua_settop(L: *State, idx: c_int) void;
pub extern fn lua_pushvalue(L: *State, idx: c_int) void;
pub extern fn lua_checkstack(L: *State, sz: c_int) c_int;
pub extern fn lua_type(L: *State, idx: c_int) c_int;
pub extern fn lua_tonumberx(L: *State, idx: c_int, isnum: ?*c_int) f64;
pub extern fn lua_toboolean(L: *State, idx: c_int) c_int;
pub extern fn lua_tolstring(L: *State, idx: c_int, len: ?*usize) ?[*]const u8;
pub extern fn lua_objlen(L: *State, idx: c_int) c_int;
pub extern fn lua_pushnil(L: *State) void;
pub extern fn lua_pushnumber(L: *State, n: f64) void;
pub extern fn lua_pushlstring(L: *State, s: [*]const u8, l: usize) void;
pub extern fn lua_pushstring(L: *State, s: [*:0]const u8) void;
pub extern fn lua_pushcclosurek(L: *State, f: CFunction, debugname: ?[*:0]const u8, nup: c_int, cont: ?Continuation) void;
pub extern fn lua_pushboolean(L: *State, b: c_int) void;
pub extern fn lua_rawgetfield(L: *State, idx: c_int, k: [*:0]const u8) c_int;
pub extern fn lua_rawgeti(L: *State, idx: c_int, n: c_int) c_int;
pub extern fn lua_createtable(L: *State, narr: c_int, nrec: c_int) void;
pub extern fn lua_setreadonly(L: *State, idx: c_int, enabled: c_int) void;
pub extern fn lua_rawsetfield(L: *State, idx: c_int, k: [*:0]const u8) void;
pub extern fn luau_load(L: *State, chunkname: [*:0]const u8, data: [*]const u8, size: usize, env: c_int) c_int;
pub extern fn lua_call(L: *State, nargs: c_int, nresults: c_int) void;
pub extern fn lua_pcall(L: *State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int;
pub extern fn lua_cpcall(L: *State, func: CFunction, ud: ?*anyopaque) c_int;
pub extern fn lua_error(L: *State) noreturn;
pub extern fn lua_next(L: *State, idx: c_int) c_int;
pub extern fn lua_ref(L: *State, idx: c_int) c_int;
pub extern fn lua_unref(L: *State, ref: c_int) c_int;
pub extern fn lua_touserdata(L: *State, idx: c_int) ?*anyopaque;

pub extern fn luaopen_base(L: *State) c_int;
pub extern fn luaopen_table(L: *State) c_int;
pub extern fn luaopen_string(L: *State) c_int;
pub extern fn luaopen_math(L: *State) c_int;
pub extern fn luaopen_utf8(L: *State) c_int;
pub extern fn luaL_sandbox(L: *State) void;
pub extern fn luaL_sandboxthread(L: *State) void;

/// Bytecode (or an encoded compile error) in `malloc` memory.
pub extern fn luau_compile(source: [*]const u8, size: usize, options: ?*anyopaque, outsize: *usize) ?[*]u8;
pub extern fn free(ptr: ?*anyopaque) void;
pub extern fn malloc(size: usize) ?*anyopaque;
pub extern fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;

pub fn pop(L: *State, n: c_int) void {
    lua_settop(L, -n - 1);
}

pub fn pushcfunction(L: *State, f: CFunction, name: ?[*:0]const u8) void {
    lua_pushcclosurek(L, f, name, 0, null);
}

pub fn getref(L: *State, ref: c_int) c_int {
    return lua_rawgeti(L, REGISTRYINDEX, ref);
}

pub fn tostring(L: *State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const p = lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len];
}
