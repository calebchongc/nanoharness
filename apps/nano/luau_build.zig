//! Luau, pinned in `build.zig.zon` and built from its C++ sources with Zig's
//! C++ compiler for every target (macOS, iOS, Linux, Windows): the VM, the
//! compiler, the parser and the bytecode builder. No prebuilt binaries.
//!
//! The C API is `extern "C"` with `LUA_USE_LONGJMP=1` (Luau's own setting
//! for non-C++ hosts), so errors raised under Zig frames unwind by longjmp,
//! never by C++ exceptions. Luau is always optimized: a sandbox measures
//! its 20 ms budgets against it, and Debug's C sanitizers aren't for it.
const std = @import("std");

const include_dirs = [_][]const u8{
    "Common/include", "Ast/include", "Bytecode/include", "Compiler/include", "VM/include", "VM/src", "Compiler/src",
};

const sources = [_][]const u8{
    "Common/src/BytecodeWire.cpp",   "Common/src/StringUtils.cpp",      "Common/src/TimeTrace.cpp",
    "Ast/src/Allocator.cpp",         "Ast/src/Ast.cpp",                 "Ast/src/Confusables.cpp",
    "Ast/src/Cst.cpp",               "Ast/src/Lexer.cpp",               "Ast/src/Location.cpp",
    "Ast/src/Parser.cpp",            "Ast/src/PrettyPrinter.cpp",       "Bytecode/src/BytecodeBuilder.cpp",
    "Bytecode/src/BytecodeDump.cpp", "Bytecode/src/BytecodeGraph.cpp",  "Bytecode/src/Sccp.cpp",
    "Compiler/src/Compiler.cpp",     "Compiler/src/Builtins.cpp",       "Compiler/src/BuiltinFolding.cpp",
    "Compiler/src/ConstantFolding.cpp", "Compiler/src/CostModel.cpp",   "Compiler/src/TableShape.cpp",
    "Compiler/src/Types.cpp",        "Compiler/src/ValueTracking.cpp",  "Compiler/src/lcode.cpp",
    "VM/src/lapi.cpp",               "VM/src/laux.cpp",                 "VM/src/lbaselib.cpp",
    "VM/src/lbitlib.cpp",            "VM/src/lbuffer.cpp",              "VM/src/lbuflib.cpp",
    "VM/src/lbuiltins.cpp",          "VM/src/lcorolib.cpp",             "VM/src/ldblib.cpp",
    "VM/src/ldebug.cpp",             "VM/src/ldo.cpp",                  "VM/src/lfunc.cpp",
    "VM/src/lgc.cpp",                "VM/src/lgcdebug.cpp",             "VM/src/linit.cpp",
    "VM/src/lmathlib.cpp",           "VM/src/lmem.cpp",                 "VM/src/lnumprint.cpp",
    "VM/src/lobject.cpp",            "VM/src/loslib.cpp",               "VM/src/lperf.cpp",
    "VM/src/lstate.cpp",             "VM/src/lstring.cpp",              "VM/src/lstrlib.cpp",
    "VM/src/ltable.cpp",             "VM/src/ltablib.cpp",              "VM/src/ltm.cpp",
    "VM/src/ludata.cpp",             "VM/src/lutf8lib.cpp",             "VM/src/lveclib.cpp",
    "VM/src/lintlib.cpp",            "VM/src/lvmexecute.cpp",           "VM/src/lclass.cpp",
    "VM/src/lclasslib.cpp",          "VM/src/lvector.cpp",              "VM/src/lvmload.cpp",
    "VM/src/lvmutils.cpp",
};

const flags = [_][]const u8{
    "-std=c++17",
    "-fno-sanitize=undefined",
    "-DLUA_USE_LONGJMP=1",
    "-DLUA_API=extern \"C\"",
    "-DLUACODE_API=extern \"C\"",
};

/// The `luau` module: `luau/luau.zig` (the C API in Zig) plus the library.
pub fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const dep = b.dependency("luau", .{});
    const mod = b.createModule(.{
        .root_source_file = b.path("luau/luau.zig"),
        .target = target,
        .optimize = if (optimize == .debug) .fast else optimize,
        .link_libcpp = true,
    });
    for (include_dirs) |dir| mod.addIncludePath(dep.path(dir));
    mod.addCSourceFiles(.{ .root = dep.path(""), .files = &sources, .flags = &flags });
    return mod;
}
