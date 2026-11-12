//! The zero-Rust gate: harness-nano builds, tests and packages with no Rust
//! toolchain and nothing from the Rust tree. `zig build no-rust` runs it over
//! this folder, and a unit test runs it over the same files, so either fails
//! when:
//!
//! - the build graph (`build.zig`, `build.zig.zon`, `*_build.zig`) or a file
//!   under `scripts/` mentions Cargo, rustc or rustup, or the Rust crates'
//!   folder, at all (comments included: the build graph names no Rust input);
//! - a Zig source under `src/` holds a relative path that walks out of this
//!   app into the crates' folder or a root Cargo file (a test that reads Rust
//!   source). Prose naming the Rust reference is fine there.
const std = @import("std");

pub const Rule = enum { build, source };

pub const Hit = struct { needle: []const u8, offset: usize };

pub const Finding = struct { path: []const u8, line: usize, needle: []const u8 };

// Built from pieces so this file passes its own `source` rule.
const crates_dir = "crates" ++ "/";
const words = [_][]const u8{ "cargo", "rustc", "rustup" };
const escapes = [_][]const u8{ "../" ++ crates_dir, "../" ++ "Cargo." };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The first forbidden mention in a build-graph or script file: Cargo,
/// rustc or rustup as a word (any case), or the crates' folder.
pub fn findInBuildFile(text: []const u8) ?Hit {
    var best: ?Hit = null;
    for (words) |word| {
        var from: usize = 0;
        while (std.ascii.findIgnoreCasePos(text, from, word)) |at| : (from = at + 1) {
            const before_ok = at == 0 or !isIdent(text[at - 1]);
            const end = at + word.len;
            const after_ok = end == text.len or !isIdent(text[end]);
            if (before_ok and after_ok) {
                if (best == null or at < best.?.offset) best = .{ .needle = word, .offset = at };
                break;
            }
        }
    }
    if (std.mem.indexOf(u8, text, crates_dir)) |at| {
        if (best == null or at < best.?.offset) best = .{ .needle = crates_dir, .offset = at };
    }
    return best;
}

/// The first relative path in a Zig source that leaves this app for the
/// crates' folder or a root Cargo file.
pub fn findInSource(text: []const u8) ?Hit {
    var best: ?Hit = null;
    for (escapes) |needle| if (std.mem.indexOf(u8, text, needle)) |at| {
        if (best == null or at < best.?.offset) best = .{ .needle = needle, .offset = at };
    };
    return best;
}

/// Which rule a path (relative to apps/nano, `/`-separated) is held to, or
/// null for files the gate doesn't read.
pub fn ruleFor(path: []const u8) ?Rule {
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return .build;
    if (std.mem.indexOfScalar(u8, path, '/') == null and std.mem.endsWith(u8, path, "_build.zig")) return .build;
    if (std.mem.startsWith(u8, path, "scripts/")) return .build;
    if (std.mem.startsWith(u8, path, "src/") and std.mem.endsWith(u8, path, ".zig")) return .source;
    return null;
}

pub fn check(rule: Rule, text: []const u8) ?Hit {
    return switch (rule) {
        .build => findInBuildFile(text),
        .source => findInSource(text),
    };
}

/// 1-based line of `offset`.
pub fn lineOf(text: []const u8, offset: usize) usize {
    return 1 + std.mem.count(u8, text[0..@min(offset, text.len)], "\n");
}

/// Every finding under `nano` (apps/nano), at most one per file, in `arena`.
pub fn scan(arena: std.mem.Allocator, io: std.Io, nano: std.Io.Dir) ![]Finding {
    var found: std.ArrayList(Finding) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    {
        var it = nano.iterate();
        while (try it.next(io)) |e| if (e.kind == .file) try paths.append(arena, try arena.dupe(u8, e.name));
    }
    for ([_][]const u8{ "scripts", "src" }) |sub| {
        var dir = nano.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| if (e.kind == .file) {
            const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, e.path });
            std.mem.replaceScalar(u8, rel, '\\', '/');
            try paths.append(arena, rel);
        };
    }
    for (paths.items) |path| {
        const rule = ruleFor(path) orelse continue;
        const text = try nano.readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
        if (check(rule, text)) |hit| try found.append(arena, .{ .path = path, .line = lineOf(text, hit.offset), .needle = hit.needle });
    }
    return found.items;
}

/// `no-rust-gate [apps/nano]`: lists each finding and fails if there is one.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const root = if (args.len > 1) args[1] else ".";
    var nano = try std.Io.Dir.cwd().openDir(init.io, root, .{ .iterate = true });
    defer nano.close(init.io);
    const findings = try scan(arena, init.io, nano);
    for (findings) |f| std.debug.print("{s}:{d}: references Rust ({s})\n", .{ f.path, f.line, f.needle });
    if (findings.len > 0) {
        std.debug.print("no-rust gate: {d} file(s) reach for Rust; the Zig app must build and test without it\n", .{findings.len});
        std.process.exit(1);
    }
}

const testing = std.testing;

test "build files: Cargo, rustc, rustup and the crates folder are refused" {
    try testing.expectEqualStrings("cargo", findInBuildFile("set -e\ncargo run -p x\n").?.needle);
    try testing.expectEqualStrings("cargo", findInBuildFile("awk '...' ../../" ++ "Cargo.toml").?.needle);
    try testing.expectEqualStrings("rustc", findInBuildFile("RUSTC=rustc make").?.needle);
    try testing.expectEqualStrings("rustup", findInBuildFile("rustup target add x").?.needle);
    try testing.expectEqualStrings(crates_dir, findInBuildFile("b.path(\"../../" ++ crates_dir ++ "ui/assets\")").?.needle);
    // The earliest mention wins.
    const both = "x " ++ crates_dir ++ " then cargo";
    try testing.expectEqual(@as(usize, 2), findInBuildFile(both).?.offset);
}

test "build files: words that merely contain the names pass" {
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("const cargo_free = true; // supercargo, rustcase"));
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("zig build --release=safe\ncodesign --force --sign -\n"));
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("the crates of oranges"));
}

test "sources: only a path out of the app into the Rust tree is refused" {
    try testing.expectEqual(@as(?Hit, null), findInSource("//! The Zig port of `" ++ crates_dir ++ "engine` (prose is fine)."));
    try testing.expectEqual(@as(?Hit, null), findInSource("\"/work/demo/Cargo.toml\""));
    const reads = "readFileAlloc(io, \"../../" ++ crates_dir ++ "rpc/src/lib.rs\", a, .unlimited)";
    try testing.expectEqualStrings(escapes[0], findInSource(reads).?.needle);
    try testing.expectEqualStrings(escapes[1], findInSource("b.path(\"../../" ++ "Cargo.toml\")").?.needle);
}

test "ruleFor: the build graph and scripts by name, Zig sources by folder" {
    try testing.expectEqual(Rule.build, ruleFor("build.zig").?);
    try testing.expectEqual(Rule.build, ruleFor("build.zig.zon").?);
    try testing.expectEqual(Rule.build, ruleFor("file_icons_build.zig").?);
    try testing.expectEqual(Rule.build, ruleFor("scripts/bundle.sh").?);
    try testing.expectEqual(Rule.build, ruleFor("scripts/test_bundle.py").?);
    try testing.expectEqual(Rule.source, ruleFor("src/engine_host.zig").?);
    try testing.expectEqual(@as(?Rule, null), ruleFor("src/engine_contract.json"));
    try testing.expectEqual(@as(?Rule, null), ruleFor("README.md"));
    try testing.expectEqual(@as(?Rule, null), ruleFor("parity/check.py"));
}

test "lineOf counts from one" {
    try testing.expectEqual(@as(usize, 1), lineOf("abc", 1));
    try testing.expectEqual(@as(usize, 3), lineOf("a\nb\ncargo", 4));
}

test "a synthetic app folder: the gate finds each offender once, on its line" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "const std = @import(\"std\");\n// fine\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = ".{ .version = \"1.2.3\" }\n" });
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/ok.sh", .data = "zig build\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/bad.sh", .data = "#!/bin/sh\n\ncargo build\n" });
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/bad.zig", .data = "const p = \"../../" ++ crates_dir ++ "x.rs\";\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ok.zig", .data = "//! mirrors " ++ crates_dir ++ "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "cargo test\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), io, tmp.dir);
    try testing.expectEqual(@as(usize, 2), findings.len);
    var saw_script = false;
    var saw_source = false;
    for (findings) |f| {
        if (std.mem.eql(u8, f.path, "scripts/bad.sh")) {
            saw_script = true;
            try testing.expectEqual(@as(usize, 3), f.line);
        }
        if (std.mem.eql(u8, f.path, "src/deep/bad.zig")) saw_source = true;
    }
    try testing.expect(saw_script and saw_source);
}

test "this app's build graph, scripts and sources need nothing from Rust" {
    const nano_dir = @import("parity_options").nano_dir;
    var nano = try std.Io.Dir.cwd().openDir(testing.io, nano_dir, .{ .iterate = true });
    defer nano.close(testing.io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), testing.io, nano);
    for (findings) |f| std.debug.print("{s}:{d}: references Rust ({s})\n", .{ f.path, f.line, f.needle });
    try testing.expectEqual(@as(usize, 0), findings.len);
}
