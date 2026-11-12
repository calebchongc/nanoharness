//! The zero-Rust gate: harness-nano builds, tests and packages with no Rust
//! toolchain and nothing from the Rust tree. `zig build no-rust` runs it over
//! this folder (and the repository's packaging scripts), and a unit test runs
//! it over the same files, so either fails when:
//!
//! - the build graph (`build.zig`, `build.zig.zon`, `*_build.zig`), a file
//!   under `scripts/`, a script under `bench/` or `parity/`, or the
//!   repository's `scripts/package-*` runs Cargo, rustc or rustup, or names
//!   the Rust crates' folder, a Cargo manifest or the Rust CLI's folder, in
//!   its code (comments are prose: "no cargo here" or "cargo-culted" pass);
//! - a Zig source under `src/` holds a relative path that walks out of this
//!   app into the crates' folder, a root Cargo file or the Rust CLI, or an
//!   argv naming `cargo`, `rustc` or `rustup` (a test that runs Rust). Prose
//!   naming the Rust reference is fine there.
const std = @import("std");

pub const Rule = enum { build, source };

pub const Hit = struct { needle: []const u8, offset: usize };

pub const Finding = struct { path: []const u8, line: usize, needle: []const u8 };

// Built from pieces so this file passes its own rules.
const crates_dir = "crates" ++ "/";
const words = [_][]const u8{ "car" ++ "go", "rus" ++ "tc", "rus" ++ "tup" };
const quoted = [_][]const u8{ "\"" ++ "cargo\"", "\"" ++ "rustc\"", "\"" ++ "rustup\"" };
const cargo_files = [_][]const u8{ "Cargo" ++ ".toml", "Cargo" ++ ".lock" };
const rust_cli = "apps/" ++ "harness";
const escapes = [_][]const u8{ "../" ++ crates_dir, "../" ++ "Cargo.", "../" ++ "harness/", "../" ++ rust_cli };

/// A character that continues a word: `cargo-culted`, `cargo_free`,
/// `$CargoProfile` and `supercargo` are other words, not Cargo.
fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// The code on `line`: a whole-line `#` or `//` comment is prose, and so is
/// a trailing ` #` or ` //` one.
fn codeOf(line: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "#") or std.mem.startsWith(u8, t, "//")) return "";
    var end = line.len;
    for ([_][]const u8{ " #", "\t#", " //", "\t//" }) |marker| {
        if (std.mem.indexOf(u8, line, marker)) |at| end = @min(end, at);
    }
    return line[0..end];
}

fn earlier(best: *?Hit, needle: []const u8, at: usize) void {
    if (best.* == null or at < best.*.?.offset) best.* = .{ .needle = needle, .offset = at };
}

/// `apps/harness` as a path: followed by `/`, a quote, a space, `)` or the
/// end (an icon's `apps/harness.png` install path is something else).
fn findRustCli(text: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, rust_cli)) |at| : (from = at + 1) {
        const end = at + rust_cli.len;
        if (end == text.len) return at;
        switch (text[end]) {
            '/', '"', '\'', ' ', '\t', '\r', '\n', '`', ')' => return at,
            else => {},
        }
    }
    return null;
}

/// The first forbidden mention in one line of code (offsets within it).
fn findInCode(code: []const u8) ?Hit {
    var best: ?Hit = null;
    for (words) |word| {
        var from: usize = 0;
        while (std.ascii.findIgnoreCasePos(code, from, word)) |at| : (from = at + 1) {
            const before_ok = at == 0 or !isWordChar(code[at - 1]);
            const end = at + word.len;
            const after_ok = end == code.len or !isWordChar(code[end]) and code[end] != '.';
            if (before_ok and after_ok) {
                earlier(&best, word, at);
                break;
            }
        }
    }
    for (cargo_files) |f| if (std.mem.indexOf(u8, code, f)) |at| earlier(&best, words[0], at);
    if (std.mem.indexOf(u8, code, crates_dir)) |at| earlier(&best, crates_dir, at);
    if (findRustCli(code)) |at| earlier(&best, rust_cli, at);
    return best;
}

/// The first forbidden mention in a build-graph or script file, in its code.
pub fn findInBuildFile(text: []const u8) ?Hit {
    var start: usize = 0;
    while (start <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const code = codeOf(text[start..nl]);
        if (findInCode(code)) |hit| return .{ .needle = hit.needle, .offset = start + hit.offset };
        if (nl == text.len) break;
        start = nl + 1;
    }
    return null;
}

/// The first relative path in a Zig source that leaves this app for the
/// Rust tree, or an argv that runs a Rust tool.
pub fn findInSource(text: []const u8) ?Hit {
    var best: ?Hit = null;
    for (escapes) |needle| if (std.mem.indexOf(u8, text, needle)) |at| earlier(&best, needle, at);
    for (quoted) |needle| if (std.mem.indexOf(u8, text, needle)) |at| earlier(&best, needle, at);
    return best;
}

fn isScript(path: []const u8) bool {
    for ([_][]const u8{ ".py", ".sh", ".ps1", ".zig", ".js", ".mjs" }) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

/// Which rule a path (relative to apps/nano, `/`-separated; the repository's
/// scripts as `../../scripts/...`) is held to, or null for files the gate
/// doesn't read.
pub fn ruleFor(path: []const u8) ?Rule {
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return .build;
    if (std.mem.indexOfScalar(u8, path, '/') == null and std.mem.endsWith(u8, path, "_build.zig")) return .build;
    if (std.mem.startsWith(u8, path, "scripts/")) return .build;
    if ((std.mem.startsWith(u8, path, "bench/") or std.mem.startsWith(u8, path, "parity/")) and isScript(path)) return .build;
    if (std.mem.startsWith(u8, path, "../../scripts/package-")) return .build;
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

/// Every finding under `nano` (apps/nano) and the repository's packaging
/// scripts (`repo_scripts`, the root `scripts/` folder), at most one per
/// file, in `arena`.
pub fn scan(arena: std.mem.Allocator, io: std.Io, nano: std.Io.Dir, repo_scripts: ?std.Io.Dir) ![]Finding {
    var found: std.ArrayList(Finding) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    {
        var it = nano.iterate();
        while (try it.next(io)) |e| if (e.kind == .file) try paths.append(arena, try arena.dupe(u8, e.name));
    }
    for ([_][]const u8{ "scripts", "src", "bench", "parity" }) |sub| {
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
    if (repo_scripts) |dir| {
        var it = dir.iterate();
        while (try it.next(io)) |e| if (e.kind == .file) {
            const rel = try std.fmt.allocPrint(arena, "../../scripts/{s}", .{e.name});
            const rule = ruleFor(rel) orelse continue;
            const text = try dir.readFileAlloc(io, e.name, arena, .limited(16 * 1024 * 1024));
            if (check(rule, text)) |hit| try found.append(arena, .{ .path = rel, .line = lineOf(text, hit.offset), .needle = hit.needle });
        };
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
    var repo_scripts = try nano.openDir(init.io, "../../scripts", .{ .iterate = true });
    defer repo_scripts.close(init.io);
    const findings = try scan(arena, init.io, nano, repo_scripts);
    for (findings) |f| std.debug.print("{s}:{d}: references Rust ({s})\n", .{ f.path, f.line, f.needle });
    if (findings.len > 0) {
        std.debug.print("no-rust gate: {d} file(s) reach for Rust; the Zig app must build and test without it\n", .{findings.len});
        std.process.exit(1);
    }
}

const testing = std.testing;

test "build files: Cargo, rustc, rustup and the crates folder are refused" {
    try testing.expectEqualStrings(words[0], findInBuildFile("set -e\ncargo run -p x\n").?.needle);
    try testing.expectEqualStrings(words[0], findInBuildFile("awk '...' ../../" ++ "Cargo.toml").?.needle);
    try testing.expectEqualStrings(words[1], findInBuildFile("RUSTC=rustc make").?.needle);
    try testing.expectEqualStrings(words[2], findInBuildFile("rustup target add x").?.needle);
    try testing.expectEqualStrings(crates_dir, findInBuildFile("b.path(\"../../" ++ crates_dir ++ "ui/assets\")").?.needle);
    // The earliest mention wins.
    const both = "x " ++ crates_dir ++ " then cargo";
    try testing.expectEqual(@as(usize, 2), findInBuildFile(both).?.offset);
}

test "fix-sec 20: an argv or a path to the Rust CLI is caught; comments and other words pass" {
    // Argv forms: Python, PowerShell, a subshell, a Zig array.
    try testing.expectEqualStrings(words[0], findInBuildFile("subprocess.run([\"cargo\", \"build\"])\n").?.needle);
    try testing.expectEqualStrings(words[0], findInBuildFile("& cargo build --release\n").?.needle);
    try testing.expectEqualStrings(words[1], findInBuildFile("v=$(rustc --version)\n").?.needle);
    try testing.expectEqualStrings(quoted[0], findInSource("const argv = &.{ \"" ++ "cargo\", \"test\" };").?.needle);
    try testing.expectEqualStrings("\"" ++ "rustc\"", findInSource("run(&.{\"" ++ "rustc\"})").?.needle);
    // The Rust CLI's folder.
    try testing.expectEqualStrings(rust_cli, findInBuildFile("cp ../../" ++ rust_cli ++ "/target/x .\n").?.needle);
    try testing.expectEqualStrings(rust_cli, findInBuildFile("p = REPO / \"" ++ rust_cli ++ "\"\n").?.needle);
    try testing.expectEqualStrings("../" ++ "harness/", findInSource("readFileAlloc(io, \"../" ++ "harness/src/main.rs\")").?.needle);
    // Prose in comments, and other words.
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("# no cargo, no Rust binary\nzig build\n"));
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("    # this used to be cargo-culted\n"));
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("zig build  # unlike cargo\n"));
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("[string]$CargoProfile = 'dist'\n"));
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("echo cargo-culted\n"));
    try testing.expectEqual(@as(?Hit, null), findInBuildFile("dst: /usr/share/icons/hicolor/scalable/" ++ rust_cli ++ ".svg\n"));
    try testing.expectEqual(@as(?Hit, null), findInSource("//! The Zig port of `" ++ rust_cli ++ "/src/main.rs`."));
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

test "ruleFor: the build graph, scripts, bench and parity scripts, packaging scripts and Zig sources" {
    try testing.expectEqual(Rule.build, ruleFor("build.zig").?);
    try testing.expectEqual(Rule.build, ruleFor("build.zig.zon").?);
    try testing.expectEqual(Rule.build, ruleFor("file_icons_build.zig").?);
    try testing.expectEqual(Rule.build, ruleFor("scripts/bundle.sh").?);
    try testing.expectEqual(Rule.build, ruleFor("scripts/test_bundle.py").?);
    try testing.expectEqual(Rule.build, ruleFor("bench/make_replay.py").?);
    try testing.expectEqual(Rule.build, ruleFor("parity/check.py").?);
    try testing.expectEqual(Rule.build, ruleFor("../../scripts/package-macos.sh").?);
    try testing.expectEqual(Rule.build, ruleFor("../../scripts/package-windows.ps1").?);
    try testing.expectEqual(Rule.source, ruleFor("src/engine_host.zig").?);
    try testing.expectEqual(@as(?Rule, null), ruleFor("src/engine_contract.json"));
    try testing.expectEqual(@as(?Rule, null), ruleFor("parity/scenes/file-identities-dark.json"));
    try testing.expectEqual(@as(?Rule, null), ruleFor("README.md"));
    try testing.expectEqual(@as(?Rule, null), ruleFor("../../scripts/heavy-build.sh"));
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
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/ok.sh", .data = "zig build\n# no cargo needed\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/bad.sh", .data = "#!/bin/sh\n\ncargo build\n" });
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/bad.zig", .data = "const p = \"../../" ++ crates_dir ++ "x.rs\";\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ok.zig", .data = "//! mirrors " ++ crates_dir ++ "x\n" });
    try tmp.dir.createDirPath(io, "bench");
    try tmp.dir.writeFile(io, .{ .sub_path = "bench/bad.py", .data = "import subprocess\nsubprocess.run([\"cargo\", \"build\"])\n" });
    try tmp.dir.createDirPath(io, "parity/scenes");
    try tmp.dir.writeFile(io, .{ .sub_path = "parity/scenes/s.json", .data = "{\"path\": \"Cargo.toml\"}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "cargo test\n" });
    try tmp.dir.createDirPath(io, "repo-scripts");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo-scripts/package-linux.sh", .data = "# no cargo\ncp ../" ++ rust_cli ++ "/x .\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo-scripts/other.sh", .data = "cargo build\n" });
    var repo_scripts = try tmp.dir.openDir(io, "repo-scripts", .{ .iterate = true });
    defer repo_scripts.close(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), io, tmp.dir, repo_scripts);
    try testing.expectEqual(@as(usize, 4), findings.len);
    var saw: [4]bool = @splat(false);
    for (findings) |f| {
        if (std.mem.eql(u8, f.path, "scripts/bad.sh")) {
            saw[0] = true;
            try testing.expectEqual(@as(usize, 3), f.line);
        }
        if (std.mem.eql(u8, f.path, "src/deep/bad.zig")) saw[1] = true;
        if (std.mem.eql(u8, f.path, "bench/bad.py")) saw[2] = true;
        if (std.mem.eql(u8, f.path, "../../scripts/package-linux.sh")) {
            saw[3] = true;
            try testing.expectEqual(@as(usize, 2), f.line);
        }
    }
    try testing.expect(saw[0] and saw[1] and saw[2] and saw[3]);
}

test "this app's build graph, scripts and sources need nothing from Rust" {
    const nano_dir = @import("parity_options").nano_dir;
    var nano = try std.Io.Dir.cwd().openDir(testing.io, nano_dir, .{ .iterate = true });
    defer nano.close(testing.io);
    var repo_scripts = try nano.openDir(testing.io, "../../scripts", .{ .iterate = true });
    defer repo_scripts.close(testing.io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), testing.io, nano, repo_scripts);
    for (findings) |f| std.debug.print("{s}:{d}: references Rust ({s})\n", .{ f.path, f.line, f.needle });
    try testing.expectEqual(@as(usize, 0), findings.len);
}
