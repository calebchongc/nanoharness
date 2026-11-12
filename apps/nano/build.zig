const std = @import("std");
const manifest = @import("build.zig.zon");
const build_rules = @import("src/build_rules.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_optimize = build_rules.httpZigOptimize(optimize, target.result.os.tag);
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // HTTPS with ALPN h2 for what the app asks the network itself (releases,
    // the edge); the engine's own socket is a local WebSocket (src/ws.zig).
    const http_zig = b.dependency("http_zig", .{ .target = target, .optimize = lib_optimize }).module("http_zig");
    // Harness's bundled fonts (assets/fonts), in a module that embeds them:
    // Geist isn't installed on most Macs.
    const font_files = b.addWriteFiles();
    _ = font_files.addCopyDirectory(b.path("assets/fonts"), "fonts", .{ .include_extensions = &.{".ttf"} });
    const fonts_root = font_files.add("fonts.zig",
        \\//! Geist and Geist Mono, as the GPUI app bundles them.
        \\pub const all = [_][]const u8{
        \\    @embedFile("fonts/Geist.ttf"),
        \\    @embedFile("fonts/Geist-Italic.ttf"),
        \\    @embedFile("fonts/Geist-Medium.ttf"),
        \\    @embedFile("fonts/Geist-MediumItalic.ttf"),
        \\    @embedFile("fonts/Geist-SemiBold.ttf"),
        \\    @embedFile("fonts/Geist-SemiBoldItalic.ttf"),
        \\    @embedFile("fonts/Geist-Bold.ttf"),
        \\    @embedFile("fonts/Geist-BoldItalic.ttf"),
        \\    @embedFile("fonts/GeistMono.ttf"),
        \\    @embedFile("fonts/GeistMono-Italic.ttf"),
        \\    @embedFile("fonts/GeistMono-Medium.ttf"),
        \\    @embedFile("fonts/GeistMono-MediumItalic.ttf"),
        \\    @embedFile("fonts/GeistMono-SemiBold.ttf"),
        \\    @embedFile("fonts/GeistMono-SemiBoldItalic.ttf"),
        \\    @embedFile("fonts/GeistMono-Bold.ttf"),
        \\    @embedFile("fonts/GeistMono-BoldItalic.ttf"),
        \\};
        \\
    );
    const fonts = b.createModule(.{ .root_source_file = fonts_root });
    // Harness's SVGs, rasterized at the screen's density,
    // not a second, pre-rendered copy of the icon set.
    const icon_files = b.addWriteFiles();
    _ = icon_files.addCopyDirectory(b.path("assets/icons"), "icons", .{ .include_extensions = &.{".svg"} });
    const icons_root = icon_files.add("icons_svg.zig",
        \\pub fn get(comptime name: []const u8) []const u8 {
        \\    return @embedFile("icons/" ++ name ++ ".svg");
        \\}
        \\
    );
    const icons_svg = b.createModule(.{ .root_source_file = icons_root });
    const file_icons_data = @import("file_icons_build.zig").module(b);
    // The desktop catalog (checked in, edited directly): GPUI deliberately
    // recolors its Codegraff themes without changing the mobile palette.
    const theme_files = b.addWriteFiles();
    _ = theme_files.addCopyFile(b.path("themes.json"), "themes.json");
    _ = theme_files.addCopyFile(b.path("ios_themes.json"), "ios_themes.json");
    const themes_root = theme_files.add("themes_json.zig",
        \\//! The built-in theme catalog, as JSON.
        \\pub const json = @embedFile("themes.json");
        \\
    );
    const themes_json = b.createModule(.{ .root_source_file = themes_root });
    const ios_themes_root = theme_files.add("ios_themes_json.zig",
        \\//! The mobile 19-family theme catalog, as JSON.
        \\pub const json = @embedFile("ios_themes.json");
        \\
    );
    const ios_themes_json = b.createModule(.{ .root_source_file = ios_themes_root });
    // Harness's version: build.zig.zon's, the one place a release sets it
    // (scripts/bundle.sh and the iOS bundle read the same field).
    const info_opts = b.addOptions();
    info_opts.addOption([]const u8, "version", manifest.version);
    const info_mod = info_opts.createModule();
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "build_info", .module = info_mod },
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "http_zig", .module = http_zig },
        .{ .name = "fonts", .module = fonts },
        .{ .name = "icons_svg", .module = icons_svg },
        .{ .name = "file_icons_data", .module = file_icons_data },
        .{ .name = "themes_json", .module = themes_json },
        .{ .name = "ios_themes_json", .module = ios_themes_json },
    };

    // `zig build no-rust`: fails when the build graph, scripts/ or a test
    // reaches for Rust (its toolchain or its sources); src/no_rust_gate.zig.
    // Built for the host, so it runs under any -Dtarget.
    const gate = b.addExecutable(.{ .name = "no-rust-gate", .root_module = b.createModule(.{
        .root_source_file = b.path("src/no_rust_gate.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    gate.use_llvm = true;
    const run_gate = b.addRunArtifact(gate);
    run_gate.addDirectoryArg(b.path("."));
    b.step("no-rust", "Fail if the build, scripts or tests need Rust").dependOn(&run_gate.step);

    const exe = b.addExecutable(.{ .name = "harness-nano", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = imports,
    }) });

    if (target.result.os.tag == .ios) {
        exe.use_llvm = true;
        linkSqlite(b, exe.root_module, target);
        const ios = @import("nanoui").ios;
        const app_bundle = ios.app(b, exe, .{
            .name = "Harness",
            .id = "harness.codegraff.ios",
            .version = manifest.version,
            .multiple_windows = true,
            .assets = b.path("assets/ios/Assets.xcassets"),
            .info =
                \\    <key>CFBundleURLTypes</key>
                \\    <array>
                \\        <dict>
                \\            <key>CFBundleURLName</key>
                \\            <string>harness.codegraff.ios</string>
                \\            <key>CFBundleURLSchemes</key>
                \\            <array><string>harness</string></array>
                \\        </dict>
                \\    </array>
                \\    <key>NSAppTransportSecurity</key>
                \\    <dict>
                \\        <key>NSAllowsLocalNetworking</key>
                \\        <true/>
                \\    </dict>
            ,
        });
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = app_bundle,
            .install_dir = .prefix,
            .install_subdir = "ios/Harness.app",
        }).step);
        return;
    }

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run harness-nano").dependOn(&run.step);

    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this text");
    const tests = b.addTest(.{ .filters = if (test_filter) |filter| &.{filter} else &.{}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    // The vectors the Rust side runs too (protocol/desktop, at the repo root).
    const protocol = b.root.joinString(b.allocator, "../../protocol/desktop") catch @panic("OOM");
    const opts = b.addOptions();
    opts.addOption([]const u8, "protocol_dir", protocol);
    // And the app rules the phones share (apps/parity/vectors).
    opts.addOption([]const u8, "vectors_dir", b.root.joinString(b.allocator, "../parity/vectors") catch @panic("OOM"));
    // This folder, for the zero-Rust gate's test (src/no_rust_gate.zig).
    opts.addOption([]const u8, "nano_dir", b.root.joinString(b.allocator, ".") catch @panic("OOM"));
    tests.root_module.addOptions("parity_options", opts);
    b.step("test", "Run harness-nano tests").dependOn(&b.addRunArtifact(tests).step);

    // `zig build snap -- scene.json out-dir`: the window drawn offscreen
    // from a made-up scene, a PNG per step asked for (src/snap.zig).
    const snap = b.addExecutable(.{ .name = "harness-nano-snap", .root_module = b.createModule(.{
        .root_source_file = b.path("src/snap.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.installArtifact(snap);
    const run_snap = b.addRunArtifact(snap);
    run_snap.addPassthruArgs();
    b.step("snap", "Draw a scene offscreen to PNGs").dependOn(&run_snap.step);

    // `zig build profile -- replay.json out-dir`: the GPUI app's UI-only
    // resource replay, for bench/resource.py to measure (src/profile.zig).
    const profile = b.addExecutable(.{ .name = "harness-nano-profile", .root_module = b.createModule(.{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.installArtifact(profile);

    // `zig build vectors`: rewrite protocol/desktop/requests.json from the
    // request builders, after changing one on purpose.
    const vectors = b.addExecutable(.{ .name = "parity-vectors", .root_module = b.createModule(.{
        .root_source_file = b.path("src/vectors_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    const write_vectors = b.addRunArtifact(vectors);
    write_vectors.addArg(b.pathJoin(&.{ protocol, "requests.json" }));
    b.step("vectors", "Write protocol/desktop/requests.json").dependOn(&write_vectors.step);

    // `zig build engine`: the Zig headless engine daemon (`ws://127.0.0.1:27664`).
    const engine_imports: []const std.Build.Module.Import = &.{
        .{ .name = "build_info", .module = info_mod },
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "http_zig", .module = http_zig },
    };
    const engine_exe = b.addExecutable(.{ .name = "harness-engine", .root_module = b.createModule(.{
        .root_source_file = b.path("src/engine_main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = engine_imports,
    }) });
    b.installArtifact(engine_exe);
    const run_engine = b.addRunArtifact(engine_exe);
    run_engine.addPassthruArgs();
    b.step("engine", "Run the Zig harness-engine daemon").dependOn(&run_engine.step);

    // Large UI artifacts must never use Zig's self-hosted backend.
    inline for (.{ exe, tests, snap, profile, vectors, engine_exe }) |artifact| {
        artifact.use_llvm = true;
        linkSqlite(b, artifact.root_module, target);
    }
}

/// SQLite for `module` (docs_store.zig): the SDK's libsqlite3 on Apple
/// platforms, otherwise one static library compiled from the pinned
/// amalgamation (fetched only for those targets; src/build_rules.zig).
fn linkSqlite(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (!build_rules.sqliteFromSource(target.result.os.tag)) {
        module.linkSystemLibrary("sqlite3", .{});
        return;
    }
    const State = struct {
        var lib: ?*std.Build.Step.Compile = null;
    };
    const lib = State.lib orelse blk: {
        const dep = b.lazyDependency("sqlite", .{}) orelse return;
        const sqlite_module = b.createModule(.{ .target = target, .optimize = .fast, .link_libc = true });
        sqlite_module.addCSourceFile(.{ .file = dep.path("sqlite3.c"), .flags = &build_rules.sqlite_flags });
        const lib = b.addLibrary(.{ .name = "sqlite3", .linkage = .static, .root_module = sqlite_module });
        State.lib = lib;
        break :blk lib;
    };
    module.linkLibrary(lib);
}
